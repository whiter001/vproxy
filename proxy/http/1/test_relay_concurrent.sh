#!/usr/bin/env bash
# 并发中继回归测试：验证 io.cp 双向中继 teardown 的「双 close 竞态」已修复。
#
# 背景：旧实现的两个 relay goroutine 各自 defer close(src)+close(dst)，同一 fd 被并发
# close 2~3 次；先 close 释放的 fd 号被 accept 复用于新连接后，第二个 close 会把新连接
# 误关，导致 Connection reset / EBADF。本测试对 HTTP relay 与 CONNECT 隧道各发起多轮
# 并发连接，修复前应稳定失败（部分请求非 200 / 隧道回显失败），修复后必须 0 失败。
#
# 本地运行：
#   bash proxy/http/1/test_relay_concurrent.sh
#
# 可调参数（env）：
#   RELAY_ROUNDS       每 worker 请求数（默认 50）
#   RELAY_WORKERS      并发 worker 数（默认 8）
#
# 断言：HTTP 全部 200、CONNECT 回显全部一致、压测后代理进程存活；任一失败 exit 1。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

PROXY_PORT=5799
HTTP_UPSTREAM_PORT=18100
CONNECT_UPSTREAM_PORT=18101
ROUNDS="${RELAY_ROUNDS:-50}"
WORKERS="${RELAY_WORKERS:-8}"

WORK_DIR="$(mktemp -d)"
PROXY_BIN="$WORK_DIR/proxy_relay"
UPSTREAM_PY="$WORK_DIR/upstream.py"
PROXY_LOG="$WORK_DIR/proxy.log"
PROXY_PID=""
UPSTREAM_PID=""

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

echo "--- 正在编译 HTTP 代理 ---"
(cd "$repo_root" && v -o "$PROXY_BIN" proxy/http/1/proxy.1.v) || fail "编译失败"

# 本地上游：HTTP 固定 body + CONNECT echo 隧道
cat > "$UPSTREAM_PY" <<PY
import http.server
import os
import socketserver
import threading

HTTP_PORT = int(os.environ["RELAY_HTTP_PORT"])
CONNECT_PORT = int(os.environ["RELAY_CONNECT_PORT"])


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        return

    def do_GET(self):
        body = b"relay-ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class HttpServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 1024


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)


class EchoServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 1024


http_srv = HttpServer(("127.0.0.1", HTTP_PORT), H)
echo_srv = EchoServer(("127.0.0.1", CONNECT_PORT), EchoHandler)
threading.Thread(target=http_srv.serve_forever, daemon=True).start()
threading.Thread(target=echo_srv.serve_forever, daemon=True).start()
try:
    threading.Event().wait(3600)
except KeyboardInterrupt:
    pass
finally:
    http_srv.shutdown()
    echo_srv.shutdown()
PY

echo "--- 启动上游与代理 ---"
RELAY_HTTP_PORT="$HTTP_UPSTREAM_PORT" RELAY_CONNECT_PORT="$CONNECT_UPSTREAM_PORT" \
    python3 "$UPSTREAM_PY" > /dev/null 2>&1 &
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$HTTP_UPSTREAM_PORT" || fail "HTTP 上游未监听"
wait_for_port "127.0.0.1" "$CONNECT_UPSTREAM_PORT" || fail "CONNECT 上游未监听"

export PROXY_REQUIRE_AUTH=0
export PROXY_LISTEN_ADDR="127.0.0.1:$PROXY_PORT"
"$PROXY_BIN" > "$PROXY_LOG" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PROXY_PORT" || fail "代理未监听"

echo "--- 并发中继压测（HTTP + CONNECT，${WORKERS} workers × ${ROUNDS} 轮）---"
python3 - "$PROXY_PORT" "$HTTP_UPSTREAM_PORT" "$CONNECT_UPSTREAM_PORT" "$ROUNDS" "$WORKERS" <<'PY'
import socket
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

proxy_port = int(sys.argv[1])
http_port = int(sys.argv[2])
connect_port = int(sys.argv[3])
rounds = int(sys.argv[4])
workers = int(sys.argv[5])

lock = threading.Lock()
errors = []
ok_http = [0]
ok_connect = [0]


def http_once(i):
    try:
        s = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
        req = (
            f"GET http://127.0.0.1:{http_port}/ HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{http_port}\r\n"
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
        status = data.split(b"\r\n", 1)[0]
        ok = b"200 OK" in status and b"relay-ok" in data
        if ok:
            with lock:
                ok_http[0] += 1
        else:
            with lock:
                errors.append(f"http#{i} status={status[:40]!r}")
    except Exception as e:  # noqa: BLE001
        with lock:
            errors.append(f"http#{i} {e!r}")


def connect_once(i):
    try:
        s = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
        req = (
            f"CONNECT 127.0.0.1:{connect_port} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{connect_port}\r\n"
            "\r\n"
        ).encode()
        s.sendall(req)
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
        if b"200 Connection Established" not in resp:
            raise RuntimeError(f"CONNECT rejected: {resp[:60]!r}")
        payload = f"tunnel-{i}".encode()
        s.sendall(payload)
        echo = s.recv(len(payload))
        s.close()
        if echo != payload:
            raise RuntimeError(f"echo mismatch: {echo!r} != {payload!r}")
        with lock:
            ok_connect[0] += 1
    except Exception as e:  # noqa: BLE001
        with lock:
            errors.append(f"connect#{i} {e!r}")


def task(n):
    if n % 2 == 0:
        http_once(n)
    else:
        connect_once(n)


with ThreadPoolExecutor(max_workers=workers) as pool:
    list(pool.map(task, range(rounds * 2)))

total_http = rounds
total_connect = rounds
bad = len(errors)
print(f"http_ok={ok_http[0]}/{total_http} connect_ok={ok_connect[0]}/{total_connect} errors={bad}")
if bad != 0:
    print("first errors:", errors[:10])
    sys.exit(1)
PY
PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then
    echo "--- 代理日志（诊断用）---"
    grep -vE "Client handled|Active:" "$PROXY_LOG" | grep -vE "^\s*$" | tail -15
    fail "并发中继失败（HTTP/CONNECT 存在非成功请求）"
fi

# 压测后代理必须还活着
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    fail "压测后代理进程已退出"
fi
echo "✅ 压测后代理进程存活"

echo ""
echo "=== All relay concurrency tests PASSED ==="
exit 0
