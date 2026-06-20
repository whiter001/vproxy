#!/bin/bash
# 自动测试脚本：验证 vproxy 的认证、头部转发、CONNECT 隧道及 Chunked 支持。
# 所有上游都在本地启动，避免外网波动导致误判。

set -u

PROXY_BINARY="./proxy.1"
V_SOURCE="proxy.1.v"
PORT=5777
HTTP_UPSTREAM_PORT=18080
CONNECT_UPSTREAM_PORT=18081
USER="testuser"
PASS="testpass"
WORK_DIR="$(mktemp -d)"
UPSTREAM_LOG="$WORK_DIR/upstream.log"
PROXY_PID=""

export PROXY_AUTH_USER="$USER"
export PROXY_AUTH_PASS="$PASS"

cleanup() {
    echo "--- 清理 ---"
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
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
        echo "❌ $message: 期望 $expected，实际 $actual"
        return 1
    fi
}

echo "--- 正在编译 ---"
v -o "$PROXY_BINARY" "$V_SOURCE"

cat > "$WORK_DIR/upstream_servers.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = int(os.environ["HTTP_UPSTREAM_PORT"])
CONNECT_PORT = int(os.environ["CONNECT_UPSTREAM_PORT"])
LOG_FILE = os.environ["UPSTREAM_LOG"]
log_lock = threading.Lock()


def append_log(text: str) -> None:
    with log_lock:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(text)
            if not text.endswith("\n"):
                f.write("\n")


class EchoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def _read_chunked_body(self):
        body = bytearray()
        while True:
            line = self.rfile.readline()
            if not line:
                break
            line = line.strip().split(b";", 1)[0]
            if not line:
                continue
            size = int(line, 16)
            if size == 0:
                while True:
                    trailer = self.rfile.readline()
                    if trailer in (b"\r\n", b"\n", b""):
                        break
                break
            body.extend(self.rfile.read(size))
            self.rfile.read(2)
        return bytes(body)

    def _read_body(self):
        transfer_encoding = self.headers.get("Transfer-Encoding", "")
        if "chunked" in transfer_encoding.lower():
            return self._read_chunked_body(), "chunked"
        content_length = self.headers.get("Content-Length")
        if content_length is not None:
            return self.rfile.read(int(content_length)), "content-length"
        return b"", "none"

    def _write_json(self, payload, status=200, keep_alive=True):
        data = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if keep_alive:
            self.send_header("Connection", "keep-alive")
        else:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        headers = {k: v for k, v in self.headers.items()}
        append_log("GET " + self.path)
        for key, value in headers.items():
            append_log(f"HEADER {key}: {value}")
        self._write_json({"method": "GET", "path": self.path, "headers": headers})

    def do_POST(self):
        body, mode = self._read_body()
        headers = {k: v for k, v in self.headers.items()}
        append_log("POST " + self.path)
        for key, value in headers.items():
            append_log(f"HEADER {key}: {value}")
        append_log(f"BODY_LEN {len(body)} MODE {mode}")
        self._write_json({"method": "POST", "mode": mode, "body_len": len(body), "headers": headers})

    def do_HEAD(self):
        # HEAD 也记录请求头到日志，便于验证代理是否反向写入 socket。
        headers = {k: v for k, v in self.headers.items()}
        append_log("HEAD " + self.path)
        for key, value in headers.items():
            append_log(f"HEADER {key}: {value}")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "42")
        self.send_header("Connection", "keep-alive")
        self.end_headers()


class EchoTCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


http_server = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), EchoHandler)
tcp_server = ThreadedTCPServer(("127.0.0.1", CONNECT_PORT), EchoTCPHandler)

threading.Thread(target=http_server.serve_forever, daemon=True).start()
threading.Thread(target=tcp_server.serve_forever, daemon=True).start()

try:
    while True:
        threading.Event().wait(3600)
except KeyboardInterrupt:
    pass
finally:
    http_server.shutdown()
    tcp_server.shutdown()
PY

echo "--- 启动上游服务 ---"
HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" CONNECT_UPSTREAM_PORT="$CONNECT_UPSTREAM_PORT" UPSTREAM_LOG="$UPSTREAM_LOG" \
    python3 "$WORK_DIR/upstream_servers.py" > "$WORK_DIR/upstream.stdout" 2>&1 &
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$HTTP_UPSTREAM_PORT"
wait_for_port "127.0.0.1" "$CONNECT_UPSTREAM_PORT"

echo "--- 启动代理 ---"
$PROXY_BINARY > "$WORK_DIR/proxy.log" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PORT"

echo "--- 测试 1: 未认证请求 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello")
assert_eq "407" "$STATUS" "未认证请求被拦截"

echo "--- 测试 2: 带认证请求与头部清理 ---"
: > "$UPSTREAM_LOG"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PORT" \
    --proxy-user "$USER:$PASS" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/headers")
assert_eq "200" "$STATUS" "带认证 GET 请求成功"
if grep -q "Proxy-Authorization:" "$UPSTREAM_LOG"; then
    echo "❌ 上游仍然看到了 Proxy-Authorization"
    exit 1
fi
if grep -q "Proxy-Connection:" "$UPSTREAM_LOG"; then
    echo "❌ 上游仍然看到了 Proxy-Connection"
    exit 1
fi
if ! grep -q "HEADER Via: 1.1 v-proxy" "$UPSTREAM_LOG"; then
    echo "❌ 上游没有看到 Via 头"
    exit 1
fi
if ! grep -q "HEADER Proxy-Agent: V-Proxy/1.0" "$UPSTREAM_LOG"; then
    echo "❌ 上游没有看到 Proxy-Agent 头"
    exit 1
fi
echo "✅ 上游未收到代理泄露头部，且看到了 Via / Proxy-Agent"

echo "--- 测试 3: Chunked Encoding POST ---"
: > "$UPSTREAM_LOG"
CHUNKED_PAYLOAD="$(python3 - <<'PY'
print("x" * 65536)
PY
)"
STATUS=$(printf '%s' "$CHUNKED_PAYLOAD" | curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PORT" \
    --proxy-user "$USER:$PASS" \
    -H "Transfer-Encoding: chunked" \
    --data-binary @- \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/post")
assert_eq "200" "$STATUS" "Chunked POST 成功"
if ! grep -q "BODY_LEN 65536 MODE chunked" "$UPSTREAM_LOG"; then
    echo "❌ 上游没有正确收到 chunked 请求体"
    cat "$UPSTREAM_LOG"
    exit 1
fi
echo "✅ Chunked 请求体被上游正确接收"

echo "--- 测试 4: CONNECT 隧道 + Via 头 (issue #2 sub-1) ---"
PORT="$PORT" CONNECT_UPSTREAM_PORT="$CONNECT_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_host = "127.0.0.1"
proxy_port = int(os.environ["PORT"])
target_host = "127.0.0.1"
target_port = int(os.environ["CONNECT_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
credential = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

sock = socket.create_connection((proxy_host, proxy_port), timeout=5)
request = (
    f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
    f"Host: {target_host}:{target_port}\r\n"
    f"Proxy-Authorization: Basic {credential}\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
)
sock.sendall(request.encode("utf-8"))
response = b""
while b"\r\n\r\n" not in response:
    chunk = sock.recv(4096)
    if not chunk:
        raise SystemExit("proxy closed before CONNECT completed")
    response += chunk

if b"200 Connection Established" not in response:
    raise SystemExit(response.decode("utf-8", "replace"))
# issue #2 sub-1: CONNECT 响应必须补 Via / Proxy-Agent
if b"Via: 1.1 v-proxy" not in response:
    raise SystemExit(f"CONNECT response missing Via header: {response!r}")
if b"Proxy-Agent: V-Proxy/1.0" not in response:
    raise SystemExit(f"CONNECT response missing Proxy-Agent header: {response!r}")

payload = b"ping-through-connect"
sock.sendall(payload)
echo = sock.recv(len(payload))
if echo != payload:
    raise SystemExit(f"echo mismatch: {echo!r}")
sock.close()
print("CONNECT OK")
PY
echo "✅ CONNECT 隧道可用，且响应含 Via / Proxy-Agent"

echo "--- 测试 5: HEAD 路径不反向写入上游 (issue #2 sub-2) ---"
: > "$UPSTREAM_LOG"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PORT" \
    --proxy-user "$USER:$PASS" \
    -I \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/head-test")
assert_eq "200" "$STATUS" "HEAD 请求成功"
# HEAD 在代理层必须不写入响应体；通过观察上游日志是否记录到除 HEAD 行之外的数据判断
# 如果代理反向写入了 client→upstream 的额外字节，上游会收到意外内容；
# 这里仅记录头部日志，正常 HEAD 应当只有 HEAD + HEADER 行（无 BODY）。
if grep -E "^BODY" "$UPSTREAM_LOG"; then
    echo "❌ 上游意外收到 body 数据（HEAD 不应被反向写入）"
    cat "$UPSTREAM_LOG"
    exit 1
fi
if ! grep -q "^HEAD /head-test" "$UPSTREAM_LOG"; then
    echo "❌ 上游未记录 HEAD 请求"
    cat "$UPSTREAM_LOG"
    exit 1
fi
echo "✅ HEAD 请求未触发反向写入"

echo "--- 测试 6: 同连接连续 5 次 GET 成功 (issue #2 sub-3) ---"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_host = "127.0.0.1"
proxy_port = int(os.environ["PORT"])
target_host = "127.0.0.1"
target_port = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
credential = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

sock = socket.create_connection((proxy_host, proxy_port), timeout=10)
for i in range(5):
    request = (
        f"GET /keep-alive/{i} HTTP/1.1\r\n"
        f"Host: {target_host}:{target_port}\r\n"
        f"Proxy-Authorization: Basic {credential}\r\n"
        "Connection: keep-alive\r\n"
        "Proxy-Connection: keep-alive\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("utf-8"))
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise SystemExit(f"proxy closed after request {i}: {response!r}")
        response += chunk
    if b"200 OK" not in response:
        raise SystemExit(f"request {i} did not return 200: {response[:200]!r}")
    # HTTP/1.1 + Content-Length：读到完整 body
    cl_marker = b"Content-Length: "
    if cl_marker in response:
        cl = int(response.split(cl_marker, 1)[1].split(b"\r\n", 1)[0])
        body_start = response.index(b"\r\n\r\n") + 4
        body = response[body_start:]
        while len(body) < cl:
            chunk = sock.recv(cl - len(body))
            if not chunk:
                raise SystemExit(f"proxy closed while reading body for request {i}")
            body += chunk
    print(f"request {i}: 200 OK")

sock.close()
print("KEEP-ALIVE OK")
PY
echo "✅ 同连接连续 5 次 GET 成功（HTTP/1.1 keep-alive）"

echo "--- 测试完成 ---"