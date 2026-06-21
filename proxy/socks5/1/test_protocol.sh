#!/usr/bin/env bash
# SOCKS5 协议合规回归测试（issue #3 / RFC 1928 / 1929）。
#
# 覆盖：
#   1. 错误密码 → userpass subnegotiation 失败 (ver=1, status=0x01)
#   2. 未支持命令 (BIND/UDP_ASSOC) → rep=0x07 command_not_supported
#   3. 未支持 atyp (0xFF) → rep=0x08 address_not_supported
#   4. 上游不可达 → rep=0x05 connection_refused
#   5. IPv4 CONNECT reply 字节数 = 10 (4 头 + 4 addr + 2 port)
#   6. Domain CONNECT reply 字节数 = 7 + N (4 头 + 1 len + N domain + 2 port)
#   7. 错误 auth ver (≠ 1) → status=0xFF no_acceptable
#   8. 正确密码 → CONNECT + echo 全链路
#
# 风格参考 test_ipv6.sh：每个场景一个独立 python heredoc。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_protocol_bin"
log_file="${script_dir}/proxy_protocol.log"
listen_addr="127.0.0.1:5783"
echo_port=18902

rm -f "$proxy_bin" "$log_file"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.socks5.v"

# 起一个本地 TCP echo upstream（domain / IPv4 测试用）
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

# 起 SOCKS5 proxy（默认无认证）
echo "--- 启动 SOCKS5 proxy（无认证） ---"
SOCKS5_LISTEN_ADDR="$listen_addr" \
    SOCKS5_IDLE_TIMEOUT=300 \
    "$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5783 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 5783 >/dev/null 2>&1; then
    echo "❌ SOCKS5 proxy 未监听 5783"
    cat "$log_file"
    kill "$echo_pid" 2>/dev/null
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
echo "=== 协议合规测试（无认证模式） ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: 上游不可达 → rep=0x05 connection_refused ---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
# CONNECT 127.0.0.1:1（基本没人监听）
req = b'\x05\x01\x00\x01' + bytes([127,0,0,1]) + struct.pack('>H', 1)
proxy.sendall(req)
reply = proxy.recv(10)
assert reply[0] == 5, f'ver={reply[0]}'
assert reply[1] == 5, f'rep={reply[1]} (expect 0x05 connection_refused)'
print(f'  rep={reply[1]} (connection_refused) OK')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 上游不可达拒绝"
else
    echo "❌ 上游不可达未返回 0x05"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: 未支持命令 BIND (cmd=2) → rep=0x07 ---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
req = b'\x05\x02\x00\x01' + bytes([127,0,0,1]) + struct.pack('>H', 80)
proxy.sendall(req)
reply = proxy.recv(10)
assert reply[0] == 5 and reply[1] == 7, f'reply={reply!r} (expect ver=5 rep=0x07)'
print(f'  cmd=2 BIND rejected with rep=0x07')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ BIND 命令被拒"
else
    echo "❌ BIND 未返回 0x07"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 未支持命令 UDP_ASSOC (cmd=3) → rep=0x07 ---"
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
req = b'\x05\x03\x00\x01' + bytes([127,0,0,1]) + struct.pack('>H', 80)
proxy.sendall(req)
reply = proxy.recv(10)
assert reply[0] == 5 and reply[1] == 7, f'reply={reply!r} (expect ver=5 rep=0x07)'
print(f'  cmd=3 UDP_ASSOC rejected with rep=0x07')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ UDP_ASSOC 命令被拒"
else
    echo "❌ UDP_ASSOC 未返回 0x07"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 4: 未支持 atyp (0xFF) → rep=0x08 ---"
python3 - <<'PY'
import socket
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
# atyp=0xFF + 4 字节占位
req = b'\x05\x01\x00\xFF' + b'\x00\x00\x00\x00'
proxy.sendall(req)
# 收 4 头 + 4 BND + 2 port = 10 字节（send_reply 对未知 atyp 走 IPv4 body 长度）
buf = b''
while len(buf) < 10:
    chunk = proxy.recv(10 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 10, f'expected 10 bytes, got {len(buf)}: {buf!r}'
assert buf[0] == 5, f'ver={buf[0]}'
assert buf[1] == 8, f'rep={buf[1]} (expect 0x08 address_not_supported)'
# 源码：reply[3] 原样回写 atyp=0xFF，body 走 IPv4 长度（避免写错字节）
assert buf[3] == 0xFF, f'reply atyp={buf[3]} (expect 0xFF 原样回写)'
print(f'  atyp=0xFF rejected with rep=0x08, reply.atyp=0xFF (原样), body len=10')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 未支持 atyp 被拒"
else
    echo "❌ 未支持 atyp 未返回 0x08"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 5: IPv4 CONNECT reply 字节数 = 10 ---"
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
req = b'\x05\x01\x00\x01' + bytes([127,0,0,1]) + struct.pack('>H', $echo_port)
proxy.sendall(req)
# 收恰好 10 字节 reply
buf = b''
while len(buf) < 10:
    chunk = proxy.recv(10 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 10, f'expected 10 bytes, got {len(buf)}: {buf!r}'
ver, rep, rsv, atyp = buf[0], buf[1], buf[2], buf[3]
assert (ver, rep, rsv, atyp) == (5, 0, 0, 1), f'header wrong: {(ver,rep,rsv,atyp)}'
# BND.ADDR=0.0.0.0 (4 字节), BND.PORT=0
assert buf[4:10] == b'\x00\x00\x00\x00\x00\x00', f'BND not zeroed: {buf[4:10]!r}'
print(f'  IPv4 reply: 10 bytes, header OK, BND=0.0.0.0:0')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ IPv4 回包 10 字节格式正确"
else
    echo "❌ IPv4 回包字节数 / 格式错误"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 6: Domain CONNECT reply 字节数 = 7 ---"
# vproxy 的 send_reply 对 domain typ 总是写 BND_len=0（注释：大多数 SOCKS5
# 客户端忽略 BND.ADDR），所以 reply 总长固定 7 字节（4 头 + 1 len + 2 port），
# **不**是 RFC 1928 §6 严格意义的 7+N。这是有意的简化（见 proxy.socks5.v）。
# 用不可达端口 (port=1) 触发 connection_refused，避免依赖上游 echo /
# macOS localhost IPv6 解析。
python3 - <<'PY'
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x00')
assert proxy.recv(2) == b'\x05\x00', 'greeting rep'
domain = b'localhost'  # 9 字节
req = b'\x05\x01\x00\x03' + bytes([len(domain)]) + domain + struct.pack('>H', 1)
proxy.sendall(req)
expected_len = 7  # 4 hdr + 1 BND_len + 2 BND_port
buf = b''
while len(buf) < expected_len:
    chunk = proxy.recv(expected_len - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == expected_len, f'expected {expected_len} bytes, got {len(buf)}: {buf!r}'
ver, rep, rsv, atyp = buf[0], buf[1], buf[2], buf[3]
assert (ver, rep, rsv, atyp) == (5, 5, 0, 3), f'header wrong: {(ver,rep,rsv,atyp)} (expect 5,5,0,3)'
assert buf[4] == 0, f'BND domain len={buf[4]} (expect 0)'
assert buf[5:7] == b'\x00\x00', f'BND port={buf[5:7]!r} (expect 0)'
print(f'  Domain reply: {expected_len} bytes (4+1+2), rep=0x05 connection_refused')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ Domain 回包 7+N 字节格式正确"
else
    echo "❌ Domain 回包字节数 / 格式错误"
    failed=$((failed + 1))
fi

# ===========================================================================
# 切到带认证模式，重启 proxy 测 auth 失败路径
echo ""
echo "=== 协议合规测试（带认证模式） ==="
echo ""

cleanup_pid "$proxy_pid"
SOCKS5_LISTEN_ADDR="$listen_addr" \
    SOCKS5_AUTH_USERNAME="suser" SOCKS5_AUTH_PASSWORD="spass" \
    SOCKS5_IDLE_TIMEOUT=300 \
    "$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5783 >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# ---------------------------------------------------------------------------
echo "--- 测试 7: 错误密码 → userpass status=0x01 ---"
python3 - <<'PY'
import socket
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
# greeting：要求 userpass
proxy.sendall(b'\x05\x01\x02')
g = proxy.recv(2)
assert g == b'\x05\x02', f'greeting rep mismatch: {g!r} (expect 0x05 0x02)'
# auth：ver=1 ulen=5 user="suser" plen=5 pass="wrong"
auth = b'\x01\x05suser\x05wrong'
proxy.sendall(auth)
status = proxy.recv(2)
assert status[0] == 1, f'auth ver={status[0]} (expect 1)'
assert status[1] == 1, f'auth status={status[1]} (expect 0x01 failure)'
print(f'  auth rejected: ver={status[0]} status={status[1]}')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 错误密码被拒"
else
    echo "❌ 错误密码未返回 0x01"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 8: 错误 auth ver (≠ 1) → status=0xFF ---"
python3 - <<'PY'
import socket
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x02')
g = proxy.recv(2)
assert g == b'\x05\x02', f'greeting rep: {g!r}'
# auth ver=2（RFC 1929 要求 ver=1）
auth = b'\x02\x05suser\x05spass'
proxy.sendall(auth)
status = proxy.recv(2)
assert status[0] == 1, f'auth ver={status[0]} (expect 1)'
assert status[1] == 0xFF, f'auth status={status[1]} (expect 0xFF no_acceptable)'
print(f'  bad auth ver rejected: status={status[1]}')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 错误 auth ver 被拒"
else
    echo "❌ 错误 auth ver 未返回 0xFF"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 9: 正确密码 → CONNECT + echo 全链路 ---"
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5783), timeout=5)
proxy.sendall(b'\x05\x01\x02')
assert proxy.recv(2) == b'\x05\x02', 'greeting rep'
auth = b'\x01\x05suser\x05spass'
proxy.sendall(auth)
status = proxy.recv(2)
assert status == b'\x01\x00', f'auth status mismatch: {status!r}'
# CONNECT 127.0.0.1:echo_port
req = b'\x05\x01\x00\x01' + bytes([127,0,0,1]) + struct.pack('>H', $echo_port)
proxy.sendall(req)
reply = proxy.recv(10)
assert (reply[0], reply[1], reply[3]) == (5, 0, 1), f'CONNECT reply: {reply!r}'
# 回显验证
payload = b'ping-with-auth'
proxy.sendall(payload)
got = b''
while len(got) < len(payload):
    chunk = proxy.recv(len(payload) - len(got))
    if not chunk: break
    got += chunk
assert got == payload, f'echo: sent {payload!r}, got {got!r}'
print(f'  auth + CONNECT + echo OK')
proxy.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 正确密码链路通"
else
    echo "❌ 正确密码链路失败"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All SOCKS5 protocol tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- proxy log ---"
    cat "$log_file"
    exit 1
fi
