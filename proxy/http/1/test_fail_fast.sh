#!/usr/bin/env bash
# issue #1 回归测试：
#   1. 未配置凭据时进程 fail-fast（exit code != 0）
#   2. PROXY_REQUIRE_AUTH=0 时启动成功且免认证可转发
#   3. 错误日志清晰指出缺失变量

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_fail_fast_bin"
log_file="${script_dir}/proxy_fail_fast.log"
listen_addr="127.0.0.1:5779"  # 与默认 :5777 错开，避免本地已有代理干扰

# 清理旧产物
rm -f "$proxy_bin" "$log_file"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.1.v"

failed=0

cleanup_pid() {
    if [[ -n "${1:-}" ]]; then
        kill "$1" >/dev/null 2>&1 || true
        wait "$1" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
echo "--- 测试 1: 未设凭据应 fail-fast ---"
# 显式 unset，避免继承环境
unset PROXY_AUTH_USER PROXY_AUTH_PASS PROXY_AUTH_BASIC PROXY_REQUIRE_AUTH
PROXY_LISTEN_ADDR="$listen_addr" "$proxy_bin" > "$log_file" 2>&1 &
pid=$!
# 给 1s 让进程启动并退出
for _ in {1..10}; do
    if ! kill -0 "$pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if kill -0 "$pid" 2>/dev/null; then
    echo "❌ 进程未退出（应 fail-fast）"
    cleanup_pid "$pid"
    failed=$((failed + 1))
else
    wait "$pid"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "❌ 进程退出码为 0（应为非 0）"
        failed=$((failed + 1))
    else
        echo "✅ 进程以退出码 $rc 退出"
    fi

    if grep -q "PROXY_AUTH_USER and PROXY_AUTH_PASS" "$log_file"; then
        echo "✅ 错误日志提示缺失 PROXY_AUTH_USER/PASS"
    else
        echo "❌ 错误日志缺少关键提示"
        cat "$log_file"
        failed=$((failed + 1))
    fi

    if grep -q "PROXY_REQUIRE_AUTH=0" "$log_file"; then
        echo "✅ 错误日志提示可用 PROXY_REQUIRE_AUTH=0 关闭鉴权"
    else
        echo "❌ 错误日志缺少关闭鉴权的提示"
        failed=$((failed + 1))
    fi
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: PROXY_REQUIRE_AUTH=0 应启动成功，免认证可转发 ---"
PROXY_REQUIRE_AUTH=0 PROXY_LISTEN_ADDR="$listen_addr" "$proxy_bin" > "$log_file" 2>&1 &
pid=$!

# 等端口可用
ready=0
for _ in {1..50}; do
    if nc -z 127.0.0.1 5779 >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done

if [[ $ready -ne 1 ]]; then
    echo "❌ PROXY_REQUIRE_AUTH=0 下代理未监听 5779"
    cat "$log_file"
    cleanup_pid "$pid"
    failed=$((failed + 1))
else
    echo "✅ 代理在 5779 上监听"
    # 启一个本地 echo upstream（Python）
    upstream_port=18900
    upstream_log="${script_dir}/upstream_failfast.log"
    python3 - <<PY > /dev/null 2>&1 &
import http.server, socketserver, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(("127.0.0.1", $upstream_port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
import time; time.sleep(60)
PY
    upstream_pid=$!
    sleep 0.5

    # 不带 auth 头应直接 200
    status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        --proxy "http://$listen_addr" \
        "http://127.0.0.1:$upstream_port/ping")
    if [[ "$status" == "200" ]]; then
        echo "✅ 未带 Proxy-Authorization 头直接得到 200"
    else
        echo "❌ 未鉴权请求状态码 $status（期望 200）"
        failed=$((failed + 1))
    fi

    cleanup_pid "$upstream_pid"
    cleanup_pid "$pid"
fi

# ---------------------------------------------------------------------------
echo "--- 清理 ---"
rm -f "$proxy_bin" "$log_file" "${script_dir}/upstream_failfast.log"

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All fail-fast tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi