#!/usr/bin/env bash
# mproxy XOR 隧道端到端测试。
#
# 覆盖：
#   1. 端到端 XOR 编解码对称：client → server → upstream → 响应
#   2. CONNECT 隧道过 XOR（client → server → CONNECT → upstream echo）
#   3. XOR 自逆属性验证

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
serve_bin="${script_dir}/mproxy_server_test_bin"
client_bin="${script_dir}/mproxy_client_test_bin"

rm -f "$serve_bin" "$client_bin"

echo "--- 正在编译 ---"
v -o "$serve_bin" "${script_dir}/mproxy.server.v"
v -o "$client_bin" "${script_dir}/mproxy.client.v"

# 起 HTTP 上游 + echo 上游（共享一个 Python 进程）
python3 - <<'PY' > "${script_dir}/upstream_test.log" 2>&1 &
import socket, threading, time, socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = 18092
CONNECT_PORT = 18093

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'tunneled hello'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while True:
                data = self.request.recv(4096)
                if not data: return
                self.request.sendall(data)
        except OSError: pass
        finally: self.request.close()

http_srv = ThreadingHTTPServer(('127.0.0.1', HTTP_PORT), H)
http_srv.daemon_threads = True
http_srv.allow_reuse_address = True
threading.Thread(target=http_srv.serve_forever, daemon=True).start()

srv2 = socketserver.ThreadingTCPServer(('127.0.0.1', CONNECT_PORT), EchoHandler)
srv2.daemon_threads = True
srv2.allow_reuse_address = True
threading.Thread(target=srv2.serve_forever, daemon=True).start()
time.sleep(120)
PY
upstream_pid=$!
# 等上游端口就绪
for _ in {1..100}; do
    if nc -z 127.0.0.1 18092 2>/dev/null && nc -z 127.0.0.1 18093 2>/dev/null; then break; fi
    sleep 0.1
done

# 起 mproxy.server
echo "--- 启动 mproxy.server (XOR 解码端) ---"
"${serve_bin}" -l 127.0.0.1:5890 > "${script_dir}/mproxy_server_test.log" 2>&1 &
server_pid=$!

# 起 mproxy.client
echo "--- 启动 mproxy.client (XOR 编码端) ---"
"${client_bin}" -l 127.0.0.1:5891 -r 127.0.0.1:5890 > "${script_dir}/mproxy_client_test.log" 2>&1 &
client_pid=$!

cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$server_pid"; cleanup_pid "$client_pid"; cleanup_pid "$upstream_pid"; rm -f "$serve_bin" "$client_bin" "${script_dir}/mproxy_server_test.log" "${script_dir}/mproxy_client_test.log" "${script_dir}/upstream_test.log"; rm -rf "${script_dir}/__pycache__"' EXIT

for _ in {1..50}; do
    if nc -z 127.0.0.1 5890 2>/dev/null && nc -z 127.0.0.1 5891 2>/dev/null; then break; fi
    sleep 0.1
done

failed=0

echo ""
echo "=== mproxy XOR 隧道测试 ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: 端到端 GET via client → server → upstream ---"
status=$(curl -sS --max-time 5 -o /tmp/mproxy_tunnel_t1.out -w '%{http_code}' \
    -x http://127.0.0.1:5891 http://127.0.0.1:18092/test 2>/dev/null || echo TIMEOUT)
body=$(cat /tmp/mproxy_tunnel_t1.out 2>/dev/null || echo)
if [[ "$status" == "200" ]] && [[ "$body" == *"tunneled hello"* ]]; then
    echo "✅ 端到端 GET 200 + body OK"
else
    echo "❌ GET 异常 status=$status body=$body"
    failed=$((failed + 1))
fi
rm -f /tmp/mproxy_tunnel_t1.out

# ---------------------------------------------------------------------------
echo "--- 测试 2: CONNECT 隧道过 XOR ---"
python3 - <<'PY'
import socket
s = socket.create_connection(('127.0.0.1', 5891), timeout=5)
s.sendall(b'CONNECT 127.0.0.1:18093 HTTP/1.1\r\nHost: 127.0.0.1:18093\r\n\r\n')
resp = b''
while b'\r\n\r\n' not in resp:
    chunk = s.recv(1024)
    if not chunk: break
    resp += chunk
assert b'200 Connection Established' in resp, f'expected 200, got {resp[:80]!r}'
payload = b'ping-via-xor-connect'
s.sendall(payload)
got = s.recv(len(payload))
assert got == payload, f'echo mismatch: {got!r}'
print('  CONNECT through XOR tunnel OK')
s.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ CONNECT 过 XOR 隧道"
else
    echo "❌ CONNECT 过 XOR 隧道失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: XOR 自逆属性 ---"
python3 - <<'PY'
raw = b'GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n'
xored = bytes(b ^ 1 for b in raw)
restored = bytes(b ^ 1 for b in xored)
assert restored == raw, 'XOR round-trip failed'
print(f'  XOR {len(raw)} bytes round-trip OK')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ XOR 自逆属性"
else
    echo "❌ XOR 自逆失败"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== mproxy 隧道测试 PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- mproxy.server log ---"
    cat "${script_dir}/mproxy_server_test.log"
    echo "--- mproxy.client log ---"
    cat "${script_dir}/mproxy_client_test.log"
    exit 1
fi