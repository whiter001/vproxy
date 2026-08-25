#!/bin/bash
# test_metrics.sh — Prometheus /metrics 端点 + 累计 counters 的端到端验收。
#
# 覆盖验收标准：
#   1. curl <metrics-addr>/metrics 返回 Prometheus 文本格式（HELP/TYPE/采样行齐全）
#   2. 1 次鉴权失败 → vproxy_errors_total{kind="auth_failed"} = 1
#      1 次正常转发 → vproxy_connections_total{proto="http",status="ok"} = 1
#   3. 持有一条未关闭连接 → vproxy_active_conns{proto="http"} = 1
#      并与 ss -tn 中到代理端口的 ESTAB 连接数对账（ss 可用时）
#
# 全部使用本地 upstream，避免外网波动导致误判。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

PROXY_BINARY="./proxy.1"
V_SOURCE="./proxy.1.v"
PROXY_PORT=15790
METRICS_PORT=19090
UPSTREAM_PORT=18090
USER="metricsuser"
PASS="metricspass"
WORK_DIR="$(mktemp -d)"
PROXY_PID=""
UPSTREAM_PID=""
failed=0

export PROXY_AUTH_USER="$USER"
export PROXY_AUTH_PASS="$PASS"

cleanup() {
    echo "--- 清理 ---"
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
    if [ -n "$UPSTREAM_PID" ]; then
        kill "$UPSTREAM_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
    rm -f "$PROXY_BINARY"
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

assert_eq() {
    expected="$1"
    actual="$2"
    message="$3"
    if [ "$expected" = "$actual" ]; then
        echo "✅ $message"
    else
        echo "❌ $message: 期望 ${expected}，实际 ${actual}"
        failed=$((failed + 1))
        return 1
    fi
}

fetch_metrics() {
    curl -sS --max-time 5 "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null
}

echo "--- 正在编译 ---"
v -o "$PROXY_BINARY" "$V_SOURCE"

cat > "$WORK_DIR/upstream.py" <<'PY'
#!/usr/bin/env python3
import http.server
import os
import socketserver
import threading

UPSTREAM_PORT = int(os.environ["UPSTREAM_PORT"])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello-metrics"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


srv = socketserver.TCPServer(("127.0.0.1", UPSTREAM_PORT), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
import time
try:
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    pass
PY

echo "--- 启动上游服务 ---"
UPSTREAM_PORT="$UPSTREAM_PORT" python3 "$WORK_DIR/upstream.py" > "$WORK_DIR/upstream.log" 2>&1 &
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$UPSTREAM_PORT"

echo "--- 启动代理 (--metrics-addr 127.0.0.1:${METRICS_PORT}) ---"
"$PROXY_BINARY" -l "127.0.0.1:$PROXY_PORT" --metrics-addr "127.0.0.1:$METRICS_PORT" \
    > "$WORK_DIR/proxy.log" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PROXY_PORT"
wait_for_port "127.0.0.1" "$METRICS_PORT"

# ---------------------------------------------------------------------------
echo "--- 测试 1: /metrics 返回 Prometheus 文本格式 ---"
METRICS=$(fetch_metrics)
if [ -z "$METRICS" ]; then
    echo "❌ /metrics 无响应"
    cat "$WORK_DIR/proxy.log"
    failed=$((failed + 1))
else
    missing=""
    for needle in \
        "# HELP vproxy_active_conns 当前活跃连接数" \
        "# TYPE vproxy_active_conns gauge" \
        "# HELP vproxy_connections_total 累计连接数" \
        "# TYPE vproxy_connections_total counter" \
        "# HELP vproxy_bytes_total 累计字节" \
        "# TYPE vproxy_bytes_total counter" \
        "# HELP vproxy_errors_total 错误累计" \
        "# TYPE vproxy_errors_total counter" \
        'vproxy_active_conns{proto="http"} 0' \
        'vproxy_connections_total{proto="http",status="ok"} 0' \
        'vproxy_bytes_total{dir="in"} 0' \
        'vproxy_bytes_total{dir="out"} 0' \
        'vproxy_errors_total{kind="auth_failed"} 0' \
        'vproxy_errors_total{kind="upstream_connect"} 0' \
        'vproxy_errors_total{kind="idle_timeout"} 0'; do
        if ! echo "$METRICS" | grep -qF "$needle"; then
            missing="$missing\n  [缺少] $needle"
        fi
    done
    if [ -z "$missing" ]; then
        echo "✅ /metrics 含全部 HELP/TYPE/采样行"
    else
        echo "❌ /metrics 缺少预期行:$missing"
        echo "$METRICS"
        failed=$((failed + 1))
    fi
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: 1 次鉴权失败 → auth_failed = 1 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PROXY_PORT" \
    --proxy-user "$USER:wrongpass" \
    "http://127.0.0.1:$UPSTREAM_PORT/auth-fail")
assert_eq "407" "$STATUS" "错误凭据被拦截（407）"

METRICS=$(fetch_metrics)
if echo "$METRICS" | grep -q '^vproxy_errors_total{kind="auth_failed"} 1$'; then
    echo "✅ vproxy_errors_total{kind=\"auth_failed\"} = 1"
else
    echo "❌ auth_failed 计数不为 1"
    echo "$METRICS" | grep 'auth_failed'
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 1 次正常转发 → connections_total{status=ok} = 1 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PROXY_PORT" \
    --proxy-user "$USER:$PASS" \
    "http://127.0.0.1:$UPSTREAM_PORT/ok")
assert_eq "200" "$STATUS" "带凭据请求转发成功（200）"

METRICS=$(fetch_metrics)
if echo "$METRICS" | grep -q '^vproxy_connections_total{proto="http",status="ok"} 1$'; then
    echo "✅ vproxy_connections_total{proto=\"http\",status=\"ok\"} = 1"
else
    echo "❌ connections_total{ok} 计数不为 1"
    echo "$METRICS" | grep 'connections_total'
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 4: 持有一条未关闭连接 → active_conns = 1（与 ss -tn 对账）---"
# 保持一条已 accept 但未发送数据的连接（阻塞在 read_request_head），
# 同时用 ss -tn 统计到代理端口的 ESTAB 连接数做人工对账。
PROXY_PORT="$PROXY_PORT" python3 - <<'PY' &
import os
import socket
import time
s = socket.create_connection(("127.0.0.1", int(os.environ["PROXY_PORT"])), timeout=5)
time.sleep(6)
s.close()
PY
hold_pid=$!
sleep 1

METRICS=$(fetch_metrics)
if echo "$METRICS" | grep -q '^vproxy_active_conns{proto="http"} 1$'; then
    echo "✅ vproxy_active_conns{proto=\"http\"} = 1（持有一条连接）"
else
    echo "❌ active_conns 不为 1"
    echo "$METRICS" | grep 'active_conns'
    failed=$((failed + 1))
fi

if command -v ss >/dev/null 2>&1; then
    estab=$(ss -tn state established 2>/dev/null | grep -c ":$PROXY_PORT" || true)
    if [ "$estab" -ge 1 ]; then
        echo "✅ ss -tn 显示 $estab 条到代理端口 :$PROXY_PORT 的 ESTAB（对账通过）"
    else
        echo "❌ ss -tn 未观察到到代理端口的 ESTAB 连接"
        failed=$((failed + 1))
    fi
else
    echo "（ss 不可用，跳过 ESTAB 对账）"
fi

wait "$hold_pid" 2>/dev/null || true
sleep 0.5
METRICS=$(fetch_metrics)
if echo "$METRICS" | grep -q '^vproxy_active_conns{proto="http"} 0$'; then
    echo "✅ 连接关闭后 active_conns 回落为 0"
else
    echo "❌ 连接关闭后 active_conns 仍为 1"
    echo "$METRICS" | grep 'active_conns'
    failed=$((failed + 1))
fi

echo "--- 测试完成 ---"

if [[ $failed -eq 0 ]]; then
    echo "=== All metrics tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi
