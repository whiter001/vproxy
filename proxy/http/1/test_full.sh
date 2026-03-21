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
UPSTREAM_PID=""
PROXY_PID=""

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

    def _write_json(self, payload, status=200):
        data = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
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

echo "--- 测试 4: CONNECT 隧道 ---"
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

payload = b"ping-through-connect"
sock.sendall(payload)
echo = sock.recv(len(payload))
if echo != payload:
    raise SystemExit(f"echo mismatch: {echo!r}")
sock.close()
print("CONNECT OK")
PY
echo "✅ CONNECT 隧道可用"

echo "--- 测试完成 ---"
