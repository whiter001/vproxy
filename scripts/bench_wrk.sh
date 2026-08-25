#!/usr/bin/env bash
# wrk 吞吐基准：v -prod 编译 HTTP 代理 → 本地 HTTP 上游 → wrk 打代理。
#
# 用法：
#   bash scripts/bench_wrk.sh
#
# 输出：
#   $PWD/bench-results.txt（含日期、commit、wrk 完整输出：Requests/sec、延迟分位）
#
# 可调参数（env）：
#   WRK_DURATION    压测时长（默认 10s）
#   WRK_THREADS     wrk 线程数（默认 2）
#   WRK_CONNECTIONS wrk 连接数（默认 20）
#
# 注意：
#   - wrk 不原生支持 HTTP 代理，必须用 Lua 脚本发 absolute-form 请求行
#     （wrk.request()），让请求经代理转发到本地上游。
#   - HTTP 代理每连接只处理一个请求（无 keep-alive 循环），Lua 里显式
#     Connection: close，每请求新建连接，与代理真实能力对齐。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

BENCH_RESULTS_FILE="${BENCH_RESULTS_FILE:-$PWD/bench-results.txt}"
PROXY_PORT=5777
UPSTREAM_PORT=18080
WRK_DURATION="${WRK_DURATION:-10s}"
WRK_THREADS="${WRK_THREADS:-2}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-20}"

WORK_DIR="$(mktemp -d)"
PROXY_BIN="$WORK_DIR/proxy_http"
UPSTREAM_PY="$WORK_DIR/upstream.py"
PROXY_LOG="$WORK_DIR/proxy.log"
UPSTREAM_PID=""
PROXY_PID=""

cleanup() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
    if [ -n "$UPSTREAM_PID" ]; then
        kill "$UPSTREAM_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

wait_for_port() {
    host="$1"
    port="$2"
    for _ in $(seq 1 100); do
        if nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

fail() {
    echo "❌ $1"
    exit 1
}

if ! command -v wrk >/dev/null 2>&1; then
    echo "❌ wrk 未安装。Ubuntu: sudo apt-get update && sudo apt-get install -y wrk"
    exit 1
fi

echo "--- 编译 HTTP 代理（v -prod）---"
(cd "$repo_root" && v -prod -o "$PROXY_BIN" proxy/http/1/proxy.1.v) || fail "v -prod 编译失败"

# 本地 HTTP 上游：固定小 body。request_queue_size 调大，避免高并发下 accept
# backlog 溢出导致上游侧丢连接，干扰对代理本身的测量（同 stress_test.sh）。
cat > "$UPSTREAM_PY" <<'PY'
import http.server
import os
import socketserver

PORT = int(os.environ["BENCH_UPSTREAM_PORT"])


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        return

    def do_GET(self):
        body = b"bench-ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 1024


srv = Server(("127.0.0.1", PORT), H)
srv.serve_forever()
PY

echo "--- 启动上游与代理（无鉴权模式） ---"
BENCH_UPSTREAM_PORT="$UPSTREAM_PORT" python3 "$UPSTREAM_PY" > "$WORK_DIR/upstream.log" 2>&1 &
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$UPSTREAM_PORT" || fail "上游未监听 $UPSTREAM_PORT"

export PROXY_REQUIRE_AUTH=0
export PROXY_LISTEN_ADDR="127.0.0.1:$PROXY_PORT"
"$PROXY_BIN" > "$PROXY_LOG" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PROXY_PORT" || fail "代理未监听 $PROXY_PORT"

# wrk Lua 脚本：发 absolute-form 请求行，让请求经 HTTP 代理转发到本地上游。
cat > "$WORK_DIR/bench_http.lua" <<LUA
wrk.method = "GET"
local upstream = os.getenv("BENCH_UPSTREAM_HOST") or "127.0.0.1:$UPSTREAM_PORT"

function request()
    return "GET http://" .. upstream .. "/bench HTTP/1.1\\r\\n" ..
           "Host: " .. upstream .. "\\r\\n" ..
           "User-Agent: wrk-bench\\r\\n" ..
           "Connection: close\\r\\n" ..
           "\\r\\n"
end
LUA

echo "--- wrk 压测（${WRK_THREADS} 线程 / ${WRK_CONNECTIONS} 连接 / ${WRK_DURATION}）---"
BENCH_UPSTREAM_HOST="127.0.0.1:$UPSTREAM_PORT" \
    wrk -t "$WRK_THREADS" -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" \
        -s "$WORK_DIR/bench_http.lua" \
        "http://127.0.0.1:$PROXY_PORT/bench" > "$WORK_DIR/wrk.out" 2>&1
WRK_RC=$?
if [ "$WRK_RC" -ne 0 ]; then
    echo "--- wrk 输出 ---"
    cat "$WORK_DIR/wrk.out"
    fail "wrk 退出码 $WRK_RC"
fi

# 压测后代理必须还活着
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    fail "压测后代理进程已退出"
fi

# 汇总关键指标
req_per_sec=$(grep -E '^Requests/sec:' "$WORK_DIR/wrk.out" | awk '{print $2}')
lat50=$(grep -E '^ *50%' "$WORK_DIR/wrk.out" | awk '{print $2}')
lat75=$(grep -E '^ *75%' "$WORK_DIR/wrk.out" | awk '{print $2}')
lat90=$(grep -E '^ *90%' "$WORK_DIR/wrk.out" | awk '{print $2}')
lat99=$(grep -E '^ *99%' "$WORK_DIR/wrk.out" | awk '{print $2}')

# 写入结果文件（含日期 / commit）
{
    echo "=== vproxy wrk benchmark (v -prod) ==="
    echo "date:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "commit: $(cd "$repo_root" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "config: threads=$WRK_THREADS connections=$WRK_CONNECTIONS duration=$WRK_DURATION upstream=127.0.0.1:$UPSTREAM_PORT"
    echo ""
    echo "Requests/sec: ${req_per_sec:-N/A}"
    echo "Latency 50%:  ${lat50:-N/A}"
    echo "Latency 75%:  ${lat75:-N/A}"
    echo "Latency 90%:  ${lat90:-N/A}"
    echo "Latency 99%:  ${lat99:-N/A}"
    echo ""
    echo "--- full wrk output ---"
    cat "$WORK_DIR/wrk.out"
} > "$BENCH_RESULTS_FILE"

echo "✅ 压测后代理进程存活"
echo "✅ Requests/sec: ${req_per_sec:-N/A} (50% ${lat50:-N/A} / 75% ${lat75:-N/A} / 90% ${lat90:-N/A} / 99% ${lat99:-N/A})"
echo "✅ 结果已写入 $BENCH_RESULTS_FILE"
echo ""
echo "=== wrk benchmark PASSED ==="
exit 0
