#!/usr/bin/env bash
# issue #3 回归测试：SOCKS5 代理处理 IPv6 atyp=4 目标。
#
# 验证：
#   1. CONNECT reply 字节数 = 4（固定头）+ 16（IPv6）+ 2（port）= 22
#   2. reply[0]=0x05, reply[1]=0x00 (success), reply[3]=0x04 (atyp IPv6)
#   3. 通过代理访问 [::1] 上的 echo 服务能正常回显

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_ipv6_bin"
proxy_log="${script_dir}/proxy_ipv6.log"
proxy_addr="127.0.0.1:5778"
echo_port=18901
echo_log="${script_dir}/echo_ipv6.log"

# 检查本机是否支持 IPv6。macOS / Linux 一般都有 ::1，但容器/精简系统可能没有。
if ! python3 -c "import socket; socket.socket(socket.AF_INET6, socket.SOCK_STREAM).bind(('::1', 0))" 2>/dev/null; then
    echo "⚠️  本机不支持 IPv6（::1），跳过测试"
    exit 0
fi

rm -f "$proxy_bin" "$proxy_log" "$echo_log"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.socks5.v"

echo "--- 启动 IPv6 echo upstream ---"
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time
srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('::1', $echo_port))
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
            if not data:
                break
            c.sendall(data)
    except OSError:
        pass
    finally:
        c.close()
threading.Thread(target=serve, daemon=True).start()
time.sleep(60)
PY
echo_pid=$!
sleep 0.8

echo "--- 启动 SOCKS5 proxy ---"
SOCKS5_LISTEN_ADDR="$proxy_addr" "$proxy_bin" > "$proxy_log" 2>&1 &
proxy_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5778 >/dev/null 2>&1; then break; fi
    sleep 0.1
done

failed=0

cleanup() {
    [[ -n "${proxy_pid:-}" ]] && kill "$proxy_pid" 2>/dev/null || true
    [[ -n "${echo_pid:-}" ]] && kill "$echo_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "$proxy_bin" "$proxy_log" "$echo_log"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "--- 测试 1: Python 客户端发 atyp=4 CONNECT，回包格式校验 ---"
python3 - <<PY
import socket, struct, sys
proxy = socket.create_connection(('127.0.0.1', 5778), timeout=5)

# greeting: no-auth
proxy.sendall(b'\x05\x01\x00')
g = proxy.recv(2)
assert g == b'\x05\x00', f'greeting rep mismatch: {g!r}'

# request: atyp=4 (IPv6), addr=::1, port=echo_port
req = b'\x05\x01\x00\x04' + b'\x00' * 15 + b'\x01' + struct.pack('>H', $echo_port)
proxy.sendall(req)
reply = b''
while len(reply) < 4:
    chunk = proxy.recv(4096)
    if not chunk: break
    reply += chunk
# Reply must be exactly 22 bytes for IPv6 CONNECT success (4 hdr + 16 addr + 2 port).
# Since we may get extra bytes (e.g. data), only check the first 22.
header = reply[:4]
body = reply[4:22]
assert len(body) == 18, f'IPv6 reply body must be 18 bytes (16+2), got {len(body)} (full reply {reply!r})'
ver, rep, rsv, atyp = header[0], header[1], header[2], header[3]
assert ver == 5, f'ver={ver}'
assert rep == 0, f'rep={rep} (expect success)'
assert rsv == 0, f'rsv={rsv}'
assert atyp == 4, f'atyp={atyp} (expect IPv6=4)'
print('reply header OK')

# Round-trip echo
payload = b'ping-ipv6-via-socks5'
proxy.sendall(payload)
got = b''
while len(got) < len(payload):
    chunk = proxy.recv(4096)
    if not chunk: break
    got += chunk
assert got == payload, f'echo mismatch: sent {payload!r}, got {got!r}'
print('echo round-trip OK')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ IPv6 atyp=4 CONNECT + 回显通过"
else
    echo "❌ IPv6 测试失败"
    cat "$proxy_log"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: send_reply 字节数 = 22（IPv6）---"
# 用 Python 抓回包原始字节，验证 4 头 + 16 addr + 2 port = 22 字节
python3 - <<PY
import socket, struct
proxy = socket.create_connection(('127.0.0.1', 5778), timeout=5)
proxy.sendall(b'\x05\x01\x00')
proxy.recv(2)
# atyp=4, addr=::1, port=18901
req = b'\x05\x01\x00\x04' + b'\x00' * 15 + b'\x01' + struct.pack('>H', $echo_port)
proxy.sendall(req)
# recv exactly 22 bytes
buf = b''
while len(buf) < 22:
    chunk = proxy.recv(22 - len(buf))
    if not chunk: break
    buf += chunk
assert len(buf) == 22, f'expected 22 bytes for IPv6 reply, got {len(buf)}: {buf!r}'
ver, rep, rsv, atyp = buf[0], buf[1], buf[2], buf[3]
assert (ver, rep, rsv, atyp) == (5, 0, 0, 4), f'header wrong: {(ver,rep,rsv,atyp)}'
print(f'reply bytes OK: 22 bytes, ver=5 rep=0 rsv=0 atyp=4')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ IPv6 reply 22 字节格式正确"
else
    echo "❌ IPv6 reply 字节数错误"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 拒绝非零 RSV ---"
python3 - <<PY
import socket
proxy = socket.create_connection(('127.0.0.1', 5778), timeout=5)
proxy.sendall(b'\x05\x01\x00')  # greeting
proxy.recv(2)
# CONNECT atyp=1, but RSV=0xFF (invalid)
proxy.sendall(b'\x05\x01\xFF\x01' + b'\x7f\x00\x00\x01' + b'\x00\x50')
reply = proxy.recv(4)
assert reply[0] == 5 and reply[1] != 0, f'expected server failure, got {reply!r}'
print(f'RSV=0xFF rejected with rep={reply[1]}')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 非零 RSV 被拒绝"
else
    echo "❌ RSV 校验失败"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All IPv6 / protocol tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi