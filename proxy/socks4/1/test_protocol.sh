#!/usr/bin/env bash
# SOCKS4 / SOCKS4a 协议合规回归测试。
#
# 覆盖（镜像 proxy/socks5/1/test_protocol.sh 风格）：
#   1. IPv4 CONNECT + echo 全链路
#   2. SOCKS4a 域名转发 (DSTIP=0.0.0.X + trailing domain)
#   3. 上游不可达 → 0x5B rejected
#   4. USERID 校验：匹配 / 不匹配
#   5. 错 VN（0x05）→ 立即关闭，不回 reply
#   6. SOCKS4_NO_AUTH=1 覆盖鉴权检查
#
# 风格参考 test_ipv6.sh：每个场景一个独立 python heredoc。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_protocol_bin"
log_file="${script_dir}/proxy_protocol.log"
listen_addr="127.0.0.1:5784"
echo_port=18904

rm -f "$proxy_bin" "$log_file"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.socks4.v"

# 起一个本地 TCP echo upstream
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $echo_port))
srv.listen(8)
def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=lambda c=conn: echo(c), daemon=True).start()
def echo(c):
    try:
        while True:
            data = c.recv(4096)
            if not data: break
            c.sendall(data)
    except OSError:
        pass
    finally:
        c.close()
threading.Thread(target=serve, daemon=True).start()
time.sleep(120)
PY
echo_pid=$!
sleep 0.5

# 起 SOCKS4 proxy（默认无认证 / USERID 校验，期望 USERID=alice）
echo "--- 启动 SOCKS4 proxy（期望 USERID=alice） ---"
SOCKS4_LISTEN_ADDR="$listen_addr" \
    SOCKS4_AUTH_USER="alice" \
    SOCKS4_IDLE_TIMEOUT=300 \
    "$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5784 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 5784 >/dev/null 2>&1; then
    echo "❌ SOCKS4 proxy 未监听 5784"
    cat "$log_file"
    cleanup_pid "$echo_pid"
    exit 1
fi

failed=0

cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$proxy_pid"; cleanup_pid "$echo_pid"; rm -f "$proxy_bin" "$log_file"' EXIT

# ===========================================================================
echo ""
echo "=== SOCKS4 / SOCKS4a 协议合规测试 ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: IPv4 CONNECT reply 格式 + echo 全链路 ---"
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=5)
port_bytes = struct.pack('>H', $echo_port)
req = b'\x04\x01' + port_bytes + bytes([127,0,0,1]) + b'alice\x00'
proxy.sendall(req)
# reply: VN=0 CD=0x5A DSTPORT(2) DSTIP(4) = 8 字节
buf = b''
while len(buf) < 8:
    chunk = proxy.recv(8 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 8, f'expected 8 bytes, got {len(buf)}: {buf!r}'
ver, cd = buf[0], buf[1]
assert (ver, cd) == (0, 0x5A), f'reply header wrong: ver={ver} cd={cd:#x}'
assert buf[2:4] == port_bytes, f'echo DSTPORT mismatch: {buf[2:4].hex()}'
assert buf[4:8] == bytes([127,0,0,1]), f'echo DSTIP mismatch: {buf[4:8].hex()}'
# echo 验证
payload = b'ping-socks4'
proxy.sendall(payload)
got = b''
while len(got) < len(payload):
    chunk = proxy.recv(len(payload) - len(got))
    if not chunk: break
    got += chunk
assert got == payload, f'echo: sent {payload!r}, got {got!r}'
print(f'  reply: ver=0 cd=0x5A DSTPORT={port_bytes.hex()} DSTIP=7f000001')
print(f'  echo round-trip OK')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ IPv4 CONNECT + echo"
else
    echo "❌ IPv4 CONNECT 失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: SOCKS4a 域名转发 (DSTIP=0.0.0.1, domain=localhost) ---"
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=5)
port_bytes = struct.pack('>H', $echo_port)
# DSTIP = 0.0.0.1 → SOCKS4a 模式；USERID=alice NUL-terminated；DOMAIN=localhost NUL-terminated
req = b'\x04\x01' + port_bytes + bytes([0,0,0,1]) + b'alice\x00' + b'localhost\x00'
proxy.sendall(req)
buf = b''
while len(buf) < 8:
    chunk = proxy.recv(8 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 8, f'expected 8 bytes, got {len(buf)}: {buf!r}'
ver, cd = buf[0], buf[1]
assert (ver, cd) == (0, 0x5A), f'reply: ver={ver} cd={cd:#x} (expect 0x5A granted)'
# SOCKS4a 模式下 reply 的 DSTIP 仍是请求里的 0.0.0.1
assert buf[4:8] == bytes([0,0,0,1]), f'reply DSTIP should echo 0.0.0.1, got {buf[4:8].hex()}'
proxy.sendall(b'domain-test')
got = b''
while len(got) < 11:
    chunk = proxy.recv(11 - len(got))
    if not chunk: break
    got += chunk
assert got == b'domain-test', f'echo via domain: {got!r}'
print(f'  SOCKS4a domain resolved & echoed')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ SOCKS4a 域名转发"
else
    echo "❌ SOCKS4a 域名转发失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 上游不可达 → 0x5B rejected ---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=5)
req = b'\x04\x01' + struct.pack('>H', 1) + bytes([127,0,0,1]) + b'alice\x00'
proxy.sendall(req)
buf = b''
while len(buf) < 8:
    chunk = proxy.recv(8 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 8, f'expected 8 bytes, got {len(buf)}: {buf!r}'
ver, cd = buf[0], buf[1]
assert ver == 0 and cd == 0x5B, f'reply: ver={ver} cd={cd:#x} (expect 0/0x5B)'
print(f'  unreachable upstream rejected with 0x5B')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 上游不可达被拒"
else
    echo "❌ 上游不可达未返回 0x5B"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 4: USERID 不匹配 → 0x5B rejected ---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=5)
# 配置期望 USERID=alice，客户端发 bob
req = b'\x04\x01' + struct.pack('>H', 18904) + bytes([127,0,0,1]) + b'bob\x00'
proxy.sendall(req)
buf = b''
while len(buf) < 8:
    chunk = proxy.recv(8 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 8, f'expected 8 bytes, got {len(buf)}: {buf!r}'
ver, cd = buf[0], buf[1]
assert ver == 0 and cd == 0x5B, f'reply: ver={ver} cd={cd:#x} (expect 0/0x5B)'
print(f'  USERID mismatch rejected with 0x5B')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ USERID 不匹配被拒"
else
    echo "❌ USERID 不匹配未返回 0x5B"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 5: 错 VN（0x05）→ 立即关闭 ---"
python3 - <<'PY'
import socket
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=3)
proxy.sendall(b'\x05\x01\x00\x00\x00\x00\x00\x00')
proxy.settimeout(2)
data = proxy.recv(8)
# 错误：reply VN 必须是 0x00（NULL），不能从非 SOCKS4 客户端构造合法 reply。
# vproxy 行为：直接关闭 socket（parse_request 返回 error → handle_client defer 关）。
assert data == b'', f'expected connection close (b""), got {data!r}'
print(f'  bad VN connection closed immediately')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 错 VN 立即关闭"
else
    echo "❌ 错 VN 未立即关闭"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 5b: SOCKS4 BIND (CD=2) → 立即关闭（SOCKS4 spec 不实现 BIND）---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=3)
# CD=2 = BIND，spec 定义但 vproxy 不实现。期望：parse_request 检测 cd != 1 返回 error，
# handle_client 直接关闭连接，不发 reply（与错 VN 行为一致）。
req = b'\x04\x02' + struct.pack('>H', 80) + bytes([127,0,0,1]) + b'alice\x00'
proxy.sendall(req)
proxy.settimeout(2)
data = proxy.recv(8)
assert data == b'', f'expected close, got {data!r}'
print(f'  BIND (CD=2) connection closed')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ BIND 命令被拒"
else
    echo "❌ BIND 未立即关闭"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 5c: 无效 CD（3, 99）→ 立即关闭 ---"
python3 - <<'PY'
import socket, struct
for cd_byte in (3, 99):
    proxy = socket.create_connection(('127.0.0.1', 5784), timeout=3)
    req = bytes([4, cd_byte]) + struct.pack('>H', 80) + bytes([127,0,0,1]) + b'alice\x00'
    proxy.sendall(req)
    proxy.settimeout(2)
    data = proxy.recv(8)
    assert data == b'', f'CD={cd_byte}: expected close, got {data!r}'
    proxy.close()
print(f'  CD=3 and CD=99 both closed immediately')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 无效 CD 被拒"
else
    echo "❌ 无效 CD 未立即关闭"
    failed=$((failed + 1))
fi

# ===========================================================================
# 切到 --no-auth 模式：重启 proxy，SOCKS4_NO_AUTH=1 跳过 USERID 校验
echo ""
echo "=== SOCKS4_NO_AUTH=1 覆盖鉴权 ==="
echo ""

cleanup_pid "$proxy_pid"
SOCKS4_LISTEN_ADDR="$listen_addr" \
    SOCKS4_AUTH_USER="alice" \
    SOCKS4_NO_AUTH=1 \
    SOCKS4_IDLE_TIMEOUT=300 \
    "$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5784 >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# ---------------------------------------------------------------------------
echo "--- 测试 6: SOCKS4_NO_AUTH=1 接受任意 USERID ---"
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5784), timeout=5)
port_bytes = struct.pack('>H', $echo_port)
# 即使 SOCKS4_AUTH_USER=alice 配置存在，--no-auth 应让任意 USERID 通过
req = b'\x04\x01' + port_bytes + bytes([127,0,0,1]) + b'whoever\x00'
proxy.sendall(req)
buf = b''
while len(buf) < 8:
    chunk = proxy.recv(8 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 8, f'expected 8 bytes, got {len(buf)}: {buf!r}'
ver, cd = buf[0], buf[1]
assert (ver, cd) == (0, 0x5A), f'reply: ver={ver} cd={cd:#x} (expect 0x5A)'
proxy.sendall(b'no-auth-ok')
got = b''
while len(got) < 10:
    chunk = proxy.recv(10 - len(got))
    if not chunk: break
    got += chunk
assert got == b'no-auth-ok', f'echo: {got!r}'
print(f'  SOCKS4_NO_AUTH=1 bypassed USERID check')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ SOCKS4_NO_AUTH 覆盖鉴权"
else
    echo "❌ SOCKS4_NO_AUTH 未生效"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All SOCKS4 / SOCKS4a protocol tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- proxy log ---"
    cat "$log_file"
    exit 1
fi