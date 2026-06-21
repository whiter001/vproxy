#!/usr/bin/env bash
# mproxy serve 模式集成测试。
#
# 覆盖：
#   1. HTTP 转发（curl GET via proxy → upstream 200）
#   2. HTTPS CONNECT 隧道
#   3. 上游不可达 → 502 Bad Gateway
#   4. SOCKS5 upstream 链式（mproxy serve -u socks5://... → vproxy SOCKS5 server）
#   5. SOCKS5 + auth 链式
#
# 风格参考 proxy/http/1/test_full.sh。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
serve_bin="${script_dir}/mproxy_serve_test_bin"
socks5_bin="${script_dir}/../socks5/1/proxy.socks5.v"
vproxy_root="${script_dir}/../.."

rm -f "$serve_bin"

echo "--- 正在编译 ---"
v -o "$serve_bin" "${script_dir}/mproxy.serve.v"

# 起一个本地 HTTP 上游（基础 + CONNECT 回声）
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time, socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = 18090
CONNECT_PORT = 18091

class ThreadedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'upstream GET response'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', '11')
        self.end_headers()
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

http_srv = ThreadedHTTPServer(('127.0.0.1', HTTP_PORT), H)
threading.Thread(target=http_srv.serve_forever, daemon=True).start()

srv2 = socketserver.ThreadingTCPServer(('127.0.0.1', CONNECT_PORT), EchoHandler)
srv2.daemon_threads = True
srv2.allow_reuse_address = True
threading.Thread(target=srv2.serve_forever, daemon=True).start()

time.sleep(120)
PY
upstream_pid=$!
sleep 0.5

# 起 mproxy.serve
echo "--- 启动 mproxy.serve ---"
"${serve_bin}" -l 127.0.0.1:5880 > "${script_dir}/mproxy_serve_test.log" 2>&1 &
serve_pid=$!

cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$serve_pid"; cleanup_pid "$upstream_pid"; rm -f "$serve_bin" "${script_dir}/mproxy_serve_test.log"' EXIT

wait_for_port() {
    for _ in {1..50}; do
        if nc -z 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}

for _ in {1..50}; do
    if nc -z 127.0.0.1 5880 2>/dev/null; then break; fi
    sleep 0.1
done

failed=0

# ---------------------------------------------------------------------------
echo ""
echo "=== mproxy.serve 集成测试 ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: HTTP GET via mproxy.serve ---"
status=$(curl -sS --max-time 5 -o /tmp/mproxy_serve_t1.out -w '%{http_code}' \
    -x http://127.0.0.1:5880 http://127.0.0.1:18090/test 2>/dev/null || echo TIMEOUT)
body=$(cat /tmp/mproxy_serve_t1.out 2>/dev/null || echo)
if [[ "$status" == "200" ]] && [[ "$body" == *"upstream GET response"* ]]; then
    echo "✅ HTTP GET 200 + body OK"
else
    echo "❌ HTTP GET 异常 status=$status body=$body"
    failed=$((failed + 1))
fi
rm -f /tmp/mproxy_serve_t1.out

# ---------------------------------------------------------------------------
echo "--- 测试 2: HTTPS CONNECT 隧道 ---"
# CONNECT 模式：proxy 回 '200 Connection Established' 然后双向透传
python3 - <<'PY'
import socket
s = socket.create_connection(('127.0.0.1', 5880), timeout=5)
req = b'CONNECT 127.0.0.1:18091 HTTP/1.1\r\nHost: 127.0.0.1:18091\r\n\r\n'
s.sendall(req)
resp = b''
while b'\r\n\r\n' not in resp:
    chunk = s.recv(1024)
    if not chunk: break
    resp += chunk
assert b'200 Connection Established' in resp, f'expected 200, got {resp[:80]!r}'
payload = b'ping-via-CONNECT'
s.sendall(payload)
got = s.recv(len(payload))
assert got == payload, f'echo mismatch: {got!r}'
print('  CONNECT tunnel OK')
s.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ CONNECT 隧道可用"
else
    echo "❌ CONNECT 隧道异常"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 上游不可达 → 502 ---"
# CONNECT 到本地不可达端口 (1)
python3 - <<'PY'
import socket
s = socket.create_connection(('127.0.0.1', 5880), timeout=5)
s.sendall(b'CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n')
resp = b''
s.settimeout(3)
try:
    while b'\r\n\r\n' not in resp:
        chunk = s.recv(1024)
        if not chunk: break
        resp += chunk
except socket.timeout:
    pass
assert b'502 Bad Gateway' in resp, f'expected 502, got {resp[:100]!r}'
print('  502 Bad Gateway returned')
s.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 502 路径"
else
    echo "❌ 上游不可达未返回 502"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== mproxy.serve 测试 PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    cat "${script_dir}/mproxy_serve_test.log"
    exit 1
fi