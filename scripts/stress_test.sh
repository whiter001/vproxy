#!/usr/bin/env bash
# 服务压测：HTTP 代理（无鉴权模式）在并发下的成功率 / QPS / 延迟。
#
# 本地运行：
#   bash scripts/stress_test.sh
#
# 可调参数（env）：
#   STRESS_REQUESTS    总请求数（默认 2000）
#   STRESS_CONCURRENCY 并发数（默认 100）
#
# 行为：
#   - 启动本地 Python HTTP 上游（18080，accept backlog 1024）与 HTTP 代理
#     （127.0.0.1:5777，PROXY_REQUIRE_AUTH=0）。
#   - 优先用 `ab -n 2000 -c 100 -X <proxy>`（走 HTTP 代理）；无 ab 时回落 Python
#     ThreadPoolExecutor 并发客户端（100 线程 × 20 轮 = 2000 请求）。
#   - 断言：完成请求数 = 期望值、失败 0、非 2xx 0、压测后代理进程仍存活；输出 QPS/延迟。
#   - 任一断言失败 exit 1；trap 清理上游/代理进程与编译产物。
#
# 已知问题：V 版代理的 io.cp 双向中继在连接关闭时存在双 close 竞争（fd 复用会被
# 误关），高并发下会出现 Connection reset / EBADF，导致本脚本失败。这是代理的真实
# 并发缺陷（非脚本问题），修复中继 teardown（graceful shutdown / 单 owner close）
# 后即可通过。详见 pr-report。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

PROXY_PORT=5777
UPSTREAM_PORT=18080
TOTAL_REQUESTS="${STRESS_REQUESTS:-2000}"
CONCURRENCY="${STRESS_CONCURRENCY:-100}"

WORK_DIR="$(mktemp -d)"
PROXY_BIN="$WORK_DIR/proxy_http"
UPSTREAM_PY="$WORK_DIR/upstream.py"
UPSTREAM_LOG="$WORK_DIR/upstream.log"
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
    for _ in $(seq 1 50); do
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

# 编译代理（无鉴权模式）
echo "--- 正在编译 HTTP 代理 ---"
(cd "$repo_root" && v -o "$PROXY_BIN" proxy/http/1/proxy.1.v) || fail "编译失败"

# 本地 HTTP 上游：固定 body
# 注意 request_queue_size 必须调大（socketserver 默认 5）：
# 高并发下 accept backlog 溢出会导致上游侧 ECONNABORTED，干扰对代理本身的测量。
cat > "$UPSTREAM_PY" <<'PY'
import http.server
import os
import socketserver

PORT = int(os.environ["UPSTRESS_PORT"])


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        return

    def do_GET(self):
        body = b"stress-ok"
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

echo "--- 启动上游与代理 ---"
UPSTRESS_PORT="$UPSTREAM_PORT" python3 "$UPSTREAM_PY" > "$UPSTREAM_LOG" 2>&1 &
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$UPSTREAM_PORT" || fail "上游未监听 $UPSTREAM_PORT"

export PROXY_REQUIRE_AUTH=0
export PROXY_LISTEN_ADDR="127.0.0.1:$PROXY_PORT"
"$PROXY_BIN" > "$PROXY_LOG" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PROXY_PORT" || fail "代理未监听 $PROXY_PORT"

echo ""
echo "=== 压测（${TOTAL_REQUESTS} 请求 / 并发 ${CONCURRENCY}）==="

if command -v ab >/dev/null 2>&1; then
    echo "--- 使用 ab（-X 走 HTTP 代理） ---"
    ab -n "$TOTAL_REQUESTS" -c "$CONCURRENCY" -s 10 -q \
        -X "127.0.0.1:$PROXY_PORT" \
        "http://127.0.0.1:$UPSTREAM_PORT/stress" > "$WORK_DIR/ab.out" 2>&1
    AB_RC=$?
    if [ "$AB_RC" -ne 0 ]; then
        echo "--- ab 输出 ---"
        cat "$WORK_DIR/ab.out"
        echo "--- 代理日志（诊断用）---"
        grep -vE "Client handled|Active:" "$PROXY_LOG" | grep -vE "^\s*$" | tail -15
        fail "ab 退出码 $AB_RC"
    fi

    complete=$(grep -E '^Complete requests:' "$WORK_DIR/ab.out" | awk '{print $3}')
    failed_reqs=$(grep -E '^Failed requests:' "$WORK_DIR/ab.out" | awk '{print $3}')
    non2xx=$(grep -E '^Non-2xx responses:' "$WORK_DIR/ab.out" | awk '{print $3}')
    qps=$(grep -E '^Requests per second:' "$WORK_DIR/ab.out" | awk '{print $4}')
    mean_latency=$(grep -E '^Time per request:' "$WORK_DIR/ab.out" | head -1 | awk '{print $4}')

    [ "${complete:-0}" -eq "$TOTAL_REQUESTS" ] \
        || fail "Complete requests=${complete}（期望 ${TOTAL_REQUESTS}）"
    [ "${failed_reqs:-0}" -eq 0 ] || fail "Failed requests=${failed_reqs}（期望 0）"
    [ "${non2xx:-0}" -eq 0 ] || fail "Non-2xx responses=${non2xx}（期望 0）"

    echo "✅ Complete requests: $complete"
    echo "✅ Failed requests: $failed_reqs"
    echo "✅ Non-2xx responses: $non2xx"
    echo "✅ Requests per second: $qps"
    echo "✅ Mean latency per request: $mean_latency ms"
else
    echo "--- ab 不可用，回落 Python 并发客户端 ---"
    python3 - "$PROXY_PORT" "$UPSTREAM_PORT" "$TOTAL_REQUESTS" "$CONCURRENCY" <<'PY'
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

proxy_port = int(sys.argv[1])
upstream_port = int(sys.argv[2])
total = int(sys.argv[3])
concurrency = int(sys.argv[4])

errors = []
latencies = []
lock = __import__("threading").Lock()
success = [0]  # 用列表让 worker 闭包可写；线程安全由 lock 保证


def one_request(_):
    t0 = time.perf_counter()
    try:
        s = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
        req = (
            f"GET http://127.0.0.1:{upstream_port}/stress HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{upstream_port}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode()
        s.sendall(req)
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
        status_line = data.split(b"\r\n", 1)[0]
        status = int(status_line.split(b" ", 2)[1]) if b" " in status_line else 0
        if status == 200 and b"stress-ok" in data:
            with lock:
                success[0] += 1
        else:
            with lock:
                errors.append(f"status={status}")
    except Exception as e:  # noqa: BLE001
        with lock:
            errors.append(repr(e))
    finally:
        with lock:
            latencies.append(time.perf_counter() - t0)


t_start = time.perf_counter()
with ThreadPoolExecutor(max_workers=concurrency) as pool:
    list(pool.map(one_request, range(total)))
t_end = time.perf_counter()

ok = success[0]
bad = len(errors)
elapsed = t_end - t_start
qps = total / elapsed if elapsed > 0 else 0.0
avg = (sum(latencies) / len(latencies)) * 1000 if latencies else 0.0
print(f"total={total} ok={ok} errors={bad}")
print(f"elapsed={elapsed:.3f}s qps={qps:.1f} avg_latency={avg:.3f}ms")
if bad != 0 or ok != total:
    print("first errors:", errors[:10])
    sys.exit(1)
PY
    PY_RC=$?
    if [ "$PY_RC" -ne 0 ]; then
        echo "--- 代理日志（诊断用）---"
        grep -vE "Client handled|Active:" "$PROXY_LOG" | grep -vE "^\s*$" | tail -15
        fail "Python 并发压测失败（部分请求未返回 200）"
    fi
fi

# 压测后代理必须还活着
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    fail "压测后代理进程已退出"
fi
echo "✅ 压测后代理进程存活"

echo ""
echo "=== All stress tests PASSED ==="
exit 0
