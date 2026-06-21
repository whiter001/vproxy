#!/usr/bin/env bash
# mproxy SOCKS5 upstream 链式转发测试。
#
# 覆盖：
#   1. 直连 vs SOCKS5 upstream 链路一致性
#   2. SOCKS5 上游 + userpass 鉴权
#   3. SOCKS5 auth 失败 → mproxy 回 502
#
# 拓扑：curl → mproxy.serve(:5880, -u socks5://) → vproxy SOCKS5 server(:5778) → upstream HTTP(:18094)

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
serve_bin="/tmp/mproxy_serve_socks5_test_bin_$$"
socks5_bin="/tmp/socks5_test_bin_$$"
socks5_src="${script_dir}/../../socks5/1/proxy.socks5.v"

rm -f "$serve_bin" "$socks5_bin"

echo "--- 正在编译 ---"
v -o "$serve_bin" "${script_dir}/mproxy.serve.v"
v -o "$socks5_bin" "$socks5_src"

# 起上游 HTTP server
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class ThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'chained hello'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

srv = ThreadingHTTPServer(('127.0.0.1', 18094), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(120)
PY
upstream_pid=$!

cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$upstream_pid" "$serve_pid" "$socks5_pid"; rm -f "$serve_bin" "$socks5_bin" "${script_dir}/socks5_upstream_test.log" "${script_dir}/mproxy_socks5_test.log"; rm -rf "${script_dir}/__pycache__"' EXIT

# 等 upstream 端口
for _ in {1..50}; do
    if nc -z 127.0.0.1 18094 2>/dev/null; then break; fi
    sleep 0.1
done

failed=0

# ---------------------------------------------------------------------------
echo ""
echo "=== mproxy SOCKS5 upstream 链式测试 ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 测试 1: 直连 (no -u) → 上游 HTTP ---"
"${serve_bin}" -l 127.0.0.1:5880 > "${script_dir}/mproxy_socks5_test.log" 2>&1 &
serve_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5880 2>/dev/null; then break; fi
    sleep 0.1
done

status=$(curl -sS --max-time 5 -o /tmp/socks5_t1.out -w '%{http_code}' \
    -x http://127.0.0.1:5880 http://127.0.0.1:18094/test 2>/dev/null || echo TIMEOUT)
body=$(cat /tmp/socks5_t1.out 2>/dev/null || echo)
if [[ "$status" == "200" ]] && [[ "$body" == *"chained hello"* ]]; then
    echo "✅ 直连 200 + body"
else
    echo "❌ 直连异常 status=$status body=$body"
    failed=$((failed + 1))
fi
rm -f /tmp/socks5_t1.out
cleanup_pid "$serve_pid"

# ---------------------------------------------------------------------------
echo "--- 测试 2: SOCKS5 upstream 链式 → 同结果 ---"
# 起 vproxy SOCKS5 server 在 5778（no-auth），让 mproxy 通过它转发
SOCKS5_LISTEN_ADDR=127.0.0.1:5778 \
SOCKS5_NO_AUTH=1 \
SOCKS5_IDLE_TIMEOUT=60 \
"${socks5_bin}" > "${script_dir}/socks5_upstream_test.log" 2>&1 &
socks5_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5778 2>/dev/null; then break; fi
    sleep 0.1
done

# mproxy.serve 用 -u socks5://127.0.0.1:5778 转发
"${serve_bin}" -l 127.0.0.1:5881 -u socks5://127.0.0.1:5778 \
    > "${script_dir}/mproxy_socks5_test.log" 2>&1 &
serve_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5881 2>/dev/null; then break; fi
    sleep 0.1
done

status=$(curl -sS --max-time 5 -o /tmp/socks5_t2.out -w '%{http_code}' \
    -x http://127.0.0.1:5881 http://127.0.0.1:18094/test 2>/dev/null || echo TIMEOUT)
body=$(cat /tmp/socks5_t2.out 2>/dev/null || echo)
if [[ "$status" == "200" ]] && [[ "$body" == *"chained hello"* ]]; then
    echo "✅ SOCKS5 链式 200 + body"
else
    echo "❌ SOCKS5 链式异常 status=$status body=$body"
    failed=$((failed + 1))
fi
rm -f /tmp/socks5_t2.out
cleanup_pid "$serve_pid"

# ---------------------------------------------------------------------------
echo "--- 测试 3: SOCKS5 upstream + userpass 鉴权 ---"
cleanup_pid "$socks5_pid"
SOCKS5_LISTEN_ADDR=127.0.0.1:5779 \
SOCKS5_AUTH_USERNAME=alice \
SOCKS5_AUTH_PASSWORD=secret \
SOCKS5_IDLE_TIMEOUT=60 \
"${socks5_bin}" > "${script_dir}/socks5_upstream_test.log" 2>&1 &
socks5_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5779 2>/dev/null; then break; fi
    sleep 0.1
done

"${serve_bin}" -l 127.0.0.1:5882 -u socks5://alice:secret@127.0.0.1:5779 \
    > "${script_dir}/mproxy_socks5_test.log" 2>&1 &
serve_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5882 2>/dev/null; then break; fi
    sleep 0.1
done

status=$(curl -sS --max-time 5 -o /tmp/socks5_t3.out -w '%{http_code}' \
    -x http://127.0.0.1:5882 http://127.0.0.1:18094/test 2>/dev/null || echo TIMEOUT)
body=$(cat /tmp/socks5_t3.out 2>/dev/null || echo)
if [[ "$status" == "200" ]] && [[ "$body" == *"chained hello"* ]]; then
    echo "✅ SOCKS5 + auth 链式 200 + body"
else
    echo "❌ SOCKS5 + auth 异常 status=$status body=$body"
    failed=$((failed + 1))
fi
rm -f /tmp/socks5_t3.out
cleanup_pid "$serve_pid"

# ---------------------------------------------------------------------------
echo "--- 测试 4: SOCKS5 auth 失败 → 502 ---"
"${serve_bin}" -l 127.0.0.1:5883 -u socks5://wrong:wrong@127.0.0.1:5779 \
    > "${script_dir}/mproxy_socks5_test.log" 2>&1 &
serve_pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 5883 2>/dev/null; then break; fi
    sleep 0.1
done

status=$(curl -sS --max-time 5 -o /tmp/socks5_t4.out -w '%{http_code}' \
    -x http://127.0.0.1:5883 http://127.0.0.1:18094/test 2>/dev/null || echo TIMEOUT)
if [[ "$status" == "502" ]]; then
    echo "✅ SOCKS5 auth 失败 → 502"
else
    echo "❌ SOCKS5 auth 失败路径异常 status=$status"
    failed=$((failed + 1))
fi
rm -f /tmp/socks5_t4.out
cleanup_pid "$serve_pid"

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== mproxy SOCKS5 upstream 测试 PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- mproxy log ---"
    cat "${script_dir}/mproxy_socks5_test.log"
    echo "--- socks5 log ---"
    cat "${script_dir}/socks5_upstream_test.log"
    exit 1
fi