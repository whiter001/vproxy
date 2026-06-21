#!/usr/bin/env bash
# HTTP/1.1 WebSocket 代理回归测试（RFC 6455）。
#
# 覆盖：
#   1. 101 Switching Protocols + 帧回环
#   2. 上游返回 404（非 101）→ 透传给客户端，连接关闭（不进入 relay）
#   3. 鉴权缺失 → 407 Proxy Authentication Required
#
# 用裸 socket + 手写 RFC 6455 帧，避免依赖 Python websockets 库。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_websocket_bin"
log_file="${script_dir}/proxy_websocket.log"
listen_addr="127.0.0.1:5785"
ws_port=19003
bad_ws_port=19004

rm -f "$proxy_bin" "$log_file"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.1.v"

# 起一个标准 WebSocket echo upstream (接受握手 + 帧透传)
python3 - <<PY > /dev/null 2>&1 &
import socket, base64, threading, time

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $ws_port))
srv.listen(8)

def ws_echo(c):
    try:
        # 读握手直到 \r\n\r\n
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = c.recv(4096)
            if not d: return
            buf += d
        # 算 Sec-WebSocket-Accept
        key = b''
        for line in buf.split(b'\r\n'):
            if line.lower().startswith(b'sec-websocket-key:'):
                key = line.split(b':', 1)[1].strip()
        accept = base64.b64encode(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        c.sendall(
            b'HTTP/1.1 101 Switching Protocols\r\n'
            b'Upgrade: websocket\r\n'
            b'Connection: Upgrade\r\n'
            b'Sec-WebSocket-Accept: ' + accept + b'\r\n\r\n'
        )
        # 帧透传（不解掩码）
        while True:
            d = c.recv(4096)
            if not d: break
            c.sendall(d)
    except OSError:
        pass
    finally:
        c.close()

def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=ws_echo, args=(conn,), daemon=True).start()
threading.Thread(target=serve, daemon=True).start()
time.sleep(120)
PY
ws_pid=$!
sleep 0.5

# 起一个返回 404 的「坏」WebSocket upstream
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $bad_ws_port))
srv.listen(8)

def bad(c):
    try:
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = c.recv(4096)
            if not d: return
            buf += d
        c.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 11\r\nConnection: close\r\n\r\nNot Found!\n')
    except OSError:
        pass
    finally:
        c.close()

def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=bad, args=(conn,), daemon=True).start()
threading.Thread(target=serve, daemon=True).start()
time.sleep(120)
PY
bad_pid=$!
sleep 0.5

# 起 HTTP 代理（默认要求认证）
echo "--- 启动 HTTP proxy（要求鉴权） ---"
export PROXY_LISTEN_ADDR="$listen_addr"
export PROXY_AUTH_USER="alice"
export PROXY_AUTH_PASS="secret"
export PROXY_IDLE_TIMEOUT=300
"$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5785 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 5785 >/dev/null 2>&1; then
    echo "❌ HTTP proxy 未监听 5785"
    cat "$log_file"
    cleanup_pid "$ws_pid"; cleanup_pid "$bad_pid"
    exit 1
fi

failed=0
cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$proxy_pid"; cleanup_pid "$ws_pid"; cleanup_pid "$bad_pid"; rm -f "$proxy_bin" "$log_file"' EXIT

# ===========================================================================
echo ""
echo "=== WebSocket 代理测试 ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: 101 handshake + 帧回环 ---"
python3 - <<PY
import socket, base64, os
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
handshake = (
    f'GET ws://127.0.0.1:$ws_port/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:$ws_port\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'  # alice:secret base64
    f'\r\n'
).encode()
client.sendall(handshake)

# 读握手响应
resp = b''
while b'\r\n\r\n' not in resp:
    d = client.recv(4096)
    if not d: break
    resp += d
status = resp.split(b'\r\n', 1)[0]
assert b'101' in status, f'expected 101, got {status!r}'
print(f'  handshake: {status.decode()}')

# 发一个文本帧「hello」，上游 echo 透传
# 帧头：FIN+text=0x81, len=5, masking-key=4 bytes, payload='hello'
frame = b'\x81\x85\x00\x00\x00\x00' + b'hello'
client.sendall(frame)
echoed = client.recv(11)
assert b'hello' in echoed, f'frame echo: {echoed.hex()}'
print(f'  frame echo: {echoed.hex()} OK')
client.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 101 + 帧回环"
else
    echo "❌ 101/帧回环失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: 上游返回 404（非 101）→ 透传 + 关闭 ---"
python3 - <<PY
import socket, base64, os
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
handshake = (
    f'GET ws://127.0.0.1:$bad_ws_port/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:$bad_ws_port\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'
    f'\r\n'
).encode()
client.sendall(handshake)
client.settimeout(3)
resp = b''
while True:
    try:
        d = client.recv(4096)
        if not d: break
        resp += d
        if b'Not Found!' in resp: break
    except socket.timeout:
        break
assert b'404' in resp, f'expected 404, got {resp[:100]!r}'
assert b'Not Found!' in resp, f'expected body, got {resp!r}'
crlf = b'\r\n'
print(f'  non-101 response: {resp.split(crlf, 1)[0].decode()}')
# 验证 Proxy-Authorization 没被透传到上游（通过重读日志更稳；这里只看响应）
client.settimeout(2)
try:
    extra = client.recv(4096)
    assert extra == b'', f'expected close after body, got {extra!r}'
except socket.timeout:
    raise AssertionError('connection should close after body')
print(f'  connection closed after body (proxy did NOT enter relay)')
client.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 非 101 透传 + 关闭"
else
    echo "❌ 非 101 处理失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 缺 Proxy-Authorization → 407 ---"
python3 - <<PY
import socket, base64, os
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
handshake = (
    f'GET ws://127.0.0.1:$ws_port/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:$ws_port\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'\r\n'  # 故意省略 Proxy-Authorization
).encode()
client.sendall(handshake)
client.settimeout(3)
resp = b''
while b'\r\n\r\n' not in resp:
    d = client.recv(4096)
    if not d: break
    resp += d
status = resp.split(b'\r\n', 1)[0]
assert b'407' in status, f'expected 407, got {status!r}'
print(f'  auth missing: {status.decode()}')
client.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 鉴权拒绝"
else
    echo "❌ 鉴权拒绝失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 4: Proxy-Authorization 不应被透传到上游 ---"
# 启动一个会记录所有收到 header 的 upstream
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $ws_port + 10))
srv.listen(8)
log = open('/tmp/ws_header_log.txt', 'w')
def record(c):
    try:
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = c.recv(4096)
            if not d: return
            buf += d
        log.write(buf.decode(errors='replace'))
        log.flush()
        key = b''
        for line in buf.split(b'\r\n'):
            if line.lower().startswith(b'sec-websocket-key:'):
                key = line.split(b':', 1)[1].strip()
        import base64
        accept = base64.b64encode(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        time.sleep(0.5)
    except OSError: pass
    finally: c.close()
def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError: return
        threading.Thread(target=record, args=(conn,), daemon=True).start()
threading.Thread(target=serve, daemon=True).start()
time.sleep(120)
PY
rec_pid=$!
sleep 0.5

python3 - <<PY
import socket, base64, os, time
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
handshake = (
    f'GET ws://127.0.0.1:{$ws_port + 10}/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:{$ws_port + 10}\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'  # 故意携带
    f'\r\n'
).encode()
client.sendall(handshake)
resp = b''
while b'\r\n\r\n' not in resp:
    d = client.recv(4096)
    if not d: break
    resp += d
assert b'101' in resp.split(b'\r\n', 1)[0], f'expected 101, got {resp[:50]!r}'
client.close()
time.sleep(0.3)
PY
cleanup_pid "$rec_pid"
if grep -qi 'Proxy-Authorization' /tmp/ws_header_log.txt; then
    echo "❌ Proxy-Authorization 泄漏到上游"
    cat /tmp/ws_header_log.txt | head -20
    failed=$((failed + 1))
else
    echo "✅ Proxy-Authorization 未泄漏到上游"
fi
rm -f /tmp/ws_header_log.txt

# ---------------------------------------------------------------------------
echo "--- 测试 5: wss:// scheme → 转发到 :8443，Host 头不丢端口 ---"
# 关键验证：proxy 正确识别 wss:// scheme，不退化到 ws:// 的 :80。
# Recording upstream on 8443，客户端发 wss://127.0.0.1:8443/
python3 - <<PY > /dev/null 2>&1 &
import socket, base64, threading, time
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 8443))
srv.listen(8)
log = open('/tmp/wss_header_log.txt', 'w')
def record(c):
    try:
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = c.recv(4096)
            if not d: return
            buf += d
        log.write(buf.decode(errors='replace'))
        log.flush()
        key = b''
        for line in buf.split(b'\r\n'):
            if line.lower().startswith(b'sec-websocket-key:'):
                key = line.split(b':', 1)[1].strip()
        accept = base64.b64encode(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        time.sleep(0.3)
    except OSError: pass
    finally: c.close()
def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError: return
        threading.Thread(target=record, args=(conn,), daemon=True).start()
threading.Thread(target=serve, daemon=True).start()
time.sleep(120)
PY
wss_pid=$!
sleep 0.5

python3 - <<PY
import socket, base64, os, time
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
# wss:// scheme + 显式端口 8443；proxy 应正确剥掉 wss:// 并 dial :8443
handshake = (
    f'GET wss://127.0.0.1:8443/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:8443\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'
    f'\r\n'
).encode()
client.sendall(handshake)
resp = b''
while b'\r\n\r\n' not in resp:
    d = client.recv(4096)
    if not d: break
    resp += d
assert b'101' in resp.split(b'\r\n', 1)[0], f'expected 101, got {resp[:60]!r}'
client.close()
time.sleep(0.3)
PY
cleanup_pid "$wss_pid"
# 验证上游收到的请求：第一行是 origin form（剥掉 wss://），Host 仍是 8443
if [[ ! -f /tmp/wss_header_log.txt ]]; then
    echo "❌ wss 测试未生成上游日志"
    failed=$((failed + 1))
elif ! grep -q '^GET / HTTP/1.1' /tmp/wss_header_log.txt; then
    echo "❌ wss 请求行未转 origin form（应 'GET / HTTP/1.1'）"
    head -3 /tmp/wss_header_log.txt
    failed=$((failed + 1))
elif ! grep -qi '^Host: 127.0.0.1:8443' /tmp/wss_header_log.txt; then
    echo "❌ wss Host 头丢失端口（应 'Host: 127.0.0.1:8443'）"
    head -3 /tmp/wss_header_log.txt
    failed=$((failed + 1))
else
    echo "✅ wss:// 转发正确（origin form + Host 保留端口）"
fi
rm -f /tmp/wss_header_log.txt

# ---------------------------------------------------------------------------
echo "--- 测试 6: Upgrade 头大小写不敏感（WebSocket / websocket / WEBSOCKET）---"
python3 - <<PY
import socket, base64, os
for upgrade_value in ('websocket', 'WebSocket', 'WEBSOCKET'):
    client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    handshake = (
        f'GET ws://127.0.0.1:$ws_port/ HTTP/1.1\r\n'
        f'Host: 127.0.0.1:$ws_port\r\n'
        f'Upgrade: {upgrade_value}\r\n'
        f'Connection: Upgrade\r\n'
        f'Sec-WebSocket-Key: {key}\r\n'
        f'Sec-WebSocket-Version: 13\r\n'
        f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'
        f'\r\n'
    ).encode()
    client.sendall(handshake)
    resp = b''
    while b'\r\n\r\n' not in resp:
        d = client.recv(4096)
        if not d: break
        resp += d
    if b'101' not in resp.split(b'\r\n', 1)[0]:
        raise AssertionError(f'Upgrade: {upgrade_value} did not get 101, got {resp[:60]!r}')
    client.close()
    print(f'  Upgrade: {upgrade_value!r} → 101 OK')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ Upgrade 头大小写不敏感"
else
    echo "❌ Upgrade 头大小写处理有 bug"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 7: 头部总长 = 64KB 边界（just-under 应通过，just-over 应 400/丢弃）---"
python3 - <<PY
import socket, base64, os
# 64KB 边界 = read_request_head 的 'data.len > 65536' 拒绝阈值。
# just-under：总 header（含 Sec-WebSocket-Key 等）约 65000 字节
# just-over：再加 padding 让总 header > 65536 字节
key = base64.b64encode(os.urandom(16)).decode()
# 关键 header ≈ 226B；padding 选 64000 (under) 和 65600 (over) 让总长分别 < / > 65536
under_handshake = (
    f'GET ws://127.0.0.1:$ws_port/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:$ws_port\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'
    f'X-Pad: ' + 'a' * 64000 + '\r\n'
    f'\r\n'
).encode()
assert len(under_handshake) < 65536, f'just-under test misconfigured: {len(under_handshake)}'
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
client.sendall(under_handshake)
resp = b''
client.settimeout(3)
while b'\r\n\r\n' not in resp:
    d = client.recv(4096)
    if not d: break
    resp += d
assert b'101' in resp.split(b'\r\n', 1)[0], f'just-under should be 101, got {resp[:80]!r}'
client.close()
print(f'  just-under ({len(under_handshake)} B) → 101 OK')

# just-over：再加 padding 让总 header > 65536
key2 = base64.b64encode(os.urandom(16)).decode()
over_handshake = (
    f'GET ws://127.0.0.1:$ws_port/ HTTP/1.1\r\n'
    f'Host: 127.0.0.1:$ws_port\r\n'
    f'Upgrade: websocket\r\n'
    f'Connection: Upgrade\r\n'
    f'Sec-WebSocket-Key: {key2}\r\n'
    f'Sec-WebSocket-Version: 13\r\n'
    f'Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n'
    f'X-Pad: ' + 'a' * 65600 + '\r\n'
    f'\r\n'
).encode()
assert len(over_handshake) > 65536, f'just-over test misconfigured: {len(over_handshake)}'
client = socket.create_connection(('127.0.0.1', 5785), timeout=5)
client.sendall(over_handshake)
client.settimeout(3)
resp2 = b''
try:
    while True:
        d = client.recv(4096)
        if not d: break
        resp2 += d
        if b'\r\n\r\n' in resp2: break
except socket.timeout:
    pass
# 期望：proxy 发 400 Bad Request 然后关连接；或直接 close
assert (b'400' in resp2) or (resp2 == b''), f'just-over ({len(over_handshake)} B) should be 400 or close, got {resp2[:80]!r}'
print(f'  just-over ({len(over_handshake)} B) → {"400 Bad Request" if b"400" in resp2 else "closed"}')
client.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 64KB 头边界正确（under 通过 / over 拒绝）"
else
    echo "❌ 64KB 边界处理有 bug"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All WebSocket tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- proxy log ---"
    cat "$log_file"
    exit 1
fi