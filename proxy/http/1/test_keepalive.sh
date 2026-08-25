#!/bin/bash
# keep-alive / CONNECT Via / HEAD 独立路径集成测试。
#
# 覆盖（对应需求验收项）：
#   1. 同一 TCP 连接上连续多个 GET（+POST body）全部成功，响应头带 Connection: keep-alive，
#      证明客户端 socket 被复用（keep-alive）。
#   2. raw CONNECT 的 200 响应头含 Via: 1.1 v-proxy 与 Proxy-Agent: V-Proxy/1.0。
#   3. HEAD 请求：响应头后无 body；HEAD 后客户端再发垃圾数据，上游收不到任何额外字节；
#      Connection: close 的 HEAD 后连接关闭。
#   4. 背靠背/流水线请求（一次连发两个 GET）：第二个请求不能被静默丢弃。
#   5. HEAD + Content-Length：HEAD 不得读客户端 body 转发上游（阻塞问题 1）。
#   6. 拆包 + 多请求同段：body 读取按 CL 精确截断，不得把下一请求误写上游（阻塞问题 2b）。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

PROXY_BINARY="$script_dir/proxy_keepalive_bin"
V_SOURCE="./proxy.1.v"
PORT=5799
HTTP_UPSTREAM_PORT=18100
CONNECT_UPSTREAM_PORT=18101
USER="testuser"
PASS="testpass"
WORK_DIR="$(mktemp -d)"
UPSTREAM_LOG="$WORK_DIR/upstream.log"
UPSTREAM_PID=""
PROXY_PID=""
failed=0

export PROXY_AUTH_USER="$USER"
export PROXY_AUTH_PASS="$PASS"
export PROXY_LISTEN_ADDR="127.0.0.1:$PORT"

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

echo "--- 正在编译 ---"
v -o "$PROXY_BINARY" "$V_SOURCE" || {
    echo "❌ 编译失败"
    exit 1
}

cat > "$WORK_DIR/upstream_servers.py" <<'PY'
#!/usr/bin/env python3
import os
import socketserver
import threading

HTTP_PORT = int(os.environ["HTTP_UPSTREAM_PORT"])
CONNECT_PORT = int(os.environ["CONNECT_UPSTREAM_PORT"])
LOG_FILE = os.environ["UPSTREAM_LOG"]

lock = threading.Lock()
accept_count = 0


def log_line(text: str) -> None:
    with lock:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(text)
            if not text.endswith("\n"):
                f.write("\n")


class HTTPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        global accept_count
        with lock:
            accept_count += 1
            my_id = accept_count
        log_line(f"ACCEPT {my_id}")
        try:
            buf = b""
            while b"\r\n\r\n" not in buf:
                d = self.request.recv(4096)
                if not d:
                    return
                buf += d
            head, _, rest = buf.partition(b"\r\n\r\n")
            first_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
            method = first_line.split(" ", 1)[0]
            log_line(f"REQ {my_id} {first_line}")
            for line in head.decode(errors="replace").split("\r\n"):
                if line:
                    log_line(f"HEADER {my_id} {line}")

            # 读取请求体（Content-Length），保证请求边界完整
            cl = 0
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    cl = int(line.split(b":", 1)[1].strip())
            body = rest
            while len(body) < cl:
                d = self.request.recv(4096)
                if not d:
                    break
                body += d
            log_line(f"BODY {my_id} {body.decode(errors='replace')}")

            if method == "CONNECT":
                # 隧道模式：回显（本脚本走单独的 echo upstream，这里保留兜底）
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                while True:
                    d = self.request.recv(4096)
                    if not d:
                        return
                    self.request.sendall(d)
                return

            if method == "HEAD":
                # HEAD：只发响应头，不发 body（Content-Length 仍声明）
                self.request.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: text/plain\r\n"
                    b"Content-Length: 2\r\n"
                    b"Connection: close\r\n"
                    b"\r\n"
                )
            else:
                body_out = b"OK"
                self.request.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: text/plain\r\n"
                    b"Content-Length: " + str(len(body_out)).encode() + b"\r\n"
                    b"Connection: close\r\n"
                    b"\r\n" + body_out
                )
        except OSError:
            pass
        finally:
            try:
                self.request.close()
            except OSError:
                pass


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while True:
                d = self.request.recv(4096)
                if not d:
                    return
                self.request.sendall(d)
        except OSError:
            pass
        finally:
            try:
                self.request.close()
            except OSError:
                pass


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


http_server = ThreadedTCPServer(("127.0.0.1", HTTP_PORT), HTTPHandler)
echo_server = ThreadedTCPServer(("127.0.0.1", CONNECT_PORT), EchoHandler)
threading.Thread(target=http_server.serve_forever, daemon=True).start()
threading.Thread(target=echo_server.serve_forever, daemon=True).start()

try:
    while True:
        threading.Event().wait(3600)
except KeyboardInterrupt:
    pass
finally:
    http_server.shutdown()
    echo_server.shutdown()
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

# ---------------------------------------------------------------------------
echo "--- 测试 1: 同一 TCP 连接连续 5 次 GET + POST body + 再 GET（keep-alive）---"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" \
    UPSTREAM_LOG="$UPSTREAM_LOG" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")


def read_head(sock):
    resp = b""
    while b"\r\n\r\n" not in resp:
        d = sock.recv(4096)
        if not d:
            raise RuntimeError("closed before head: " + repr(resp))
        resp += d
    head, _, rest = resp.partition(b"\r\n\r\n")
    return head, rest


def read_full_response(sock):
    head, rest = read_head(sock)
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            cl = int(line.split(b":", 1)[1].strip())
    while len(rest) < cl:
        d = sock.recv(4096)
        if not d:
            break
        rest += d
    return head, rest[:cl]


s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
# 5 次 GET
for i in range(5):
    req = (
        f"GET http://127.0.0.1:{http_upstream}/g{i} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{http_upstream}\r\n"
        f"Proxy-Authorization: Basic {auth}\r\n"
        f"\r\n"
    ).encode()
    s.sendall(req)
    head, body = read_full_response(s)
    assert b"200 OK" in head, f"GET #{i} status: {head[:80]!r}"
    assert b"Connection: keep-alive" in head, f"GET #{i} missing keep-alive: {head[:120]!r}"
    assert body == b"OK", f"GET #{i} body: {body!r}"
    print(f"  GET #{i} -> 200 OK, Connection: keep-alive")

# POST 带 body（Content-Length 流式转发 + 请求边界）
post_req = (
    f"POST http://127.0.0.1:{http_upstream}/upload HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"Content-Length: 4\r\n"
    f"\r\n"
).encode()
s.sendall(post_req + b"PING")
head, body = read_full_response(s)
assert b"200 OK" in head, f"POST status: {head[:80]!r}"
assert body == b"OK", f"POST body: {body!r}"
print("  POST(Content-Length:4) -> 200 OK")

# POST 后连接仍可复用：再来一次 GET
s.sendall(
    (
        f"GET http://127.0.0.1:{http_upstream}/after-post HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{http_upstream}\r\n"
        f"Proxy-Authorization: Basic {auth}\r\n"
        f"\r\n"
    ).encode()
)
head, body = read_full_response(s)
assert b"200 OK" in head, f"GET after POST status: {head[:80]!r}"
assert body == b"OK", f"GET after POST body: {body!r}"
print("  GET after POST -> 200 OK (同一客户端连接继续复用)")

s.close()
print("KEEPALIVE_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 同连接连续请求全部成功"
else
    echo "❌ keep-alive 复用失败"
    failed=$((failed + 1))
fi

# 校验上游：收到 7 个请求，且每个都带 Connection: close（代理强制、不跨请求复用上游）
REQ_COUNT=$(grep -c "^REQ " "$UPSTREAM_LOG" || true)
if [[ "$REQ_COUNT" -ne 7 ]]; then
    echo "❌ 上游应收到 7 个请求，实际 $REQ_COUNT"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游收到 $REQ_COUNT 个请求（每个请求独立上游连接）"
fi
CLOSE_COUNT=$(grep -ci "^HEADER .*Connection: close" "$UPSTREAM_LOG" || true)
if [[ "$CLOSE_COUNT" -ne 7 ]]; then
    echo "❌ 上游请求应全部带 Connection: close，实际 $CLOSE_COUNT"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游请求均带 Connection: close"
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: CONNECT 200 响应含 Via / Proxy-Agent ---"
PORT="$PORT" CONNECT_UPSTREAM_PORT="$CONNECT_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
connect_upstream = int(os.environ["CONNECT_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = (
    f"CONNECT 127.0.0.1:{connect_upstream} HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{connect_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"\r\n"
).encode()
s.sendall(req)

resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk:
        raise SystemExit("proxy closed before CONNECT completed")
    resp += chunk

assert b"200 Connection Established" in resp, resp
assert b"Via: 1.1 v-proxy" in resp, f"CONNECT response missing Via: {resp!r}"
assert b"Proxy-Agent: V-Proxy/1.0" in resp, f"CONNECT response missing Proxy-Agent: {resp!r}"
print(f"  CONNECT 200 头含 Via 与 Proxy-Agent")

# 隧道打通后回显验证
payload = b"ping-through-connect"
s.sendall(payload)
echo = s.recv(len(payload))
assert echo == payload, f"echo mismatch: {echo!r}"
s.close()
print("CONNECT_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ CONNECT 200 含 Via / Proxy-Agent，且隧道可用"
else
    echo "❌ CONNECT Via/Proxy-Agent 失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3a: HEAD（Connection: close）→ 响应头无 body，连接关闭 ---"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = (
    f"HEAD http://127.0.0.1:{http_upstream}/ HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"Connection: close\r\n"
    f"\r\n"
).encode()
s.sendall(req)

resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk:
        raise SystemExit("closed before HEAD head")
    resp += chunk
head, _, rest = resp.partition(b"\r\n\r\n")
assert b"200 OK" in head, head
assert len(rest) == 0, f"HEAD 不应有 body: {rest!r}"

# Connection: close → 代理应关闭连接
s.settimeout(3)
extra = s.recv(4096)
assert extra == b"", f"Connection: close 后应收到 EOF，实际 {extra!r}"
s.close()
print("HEAD_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ HEAD 无 body 且 Connection: close 后连接关闭"
else
    echo "❌ HEAD close 路径失败"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3b: HEAD（keep-alive）→ 无 body；随后发垃圾数据，上游收不到 ---"
: > "$UPSTREAM_LOG"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = (
    f"HEAD http://127.0.0.1:{http_upstream}/ HTTP/1.1\r\n"  # 无 Connection 头 → HTTP/1.1 默认 keep-alive
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"\r\n"
).encode()
s.sendall(req)

resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk:
        raise SystemExit("closed before HEAD head")
    resp += chunk
head, _, rest = resp.partition(b"\r\n\r\n")
assert b"200 OK" in head, head
assert b"Connection: keep-alive" in head, f"HEAD 应复用连接: {head!r}"
assert len(rest) == 0, f"HEAD 不应有 body: {rest!r}"

# HEAD 后发垃圾数据：代理应视作畸形请求回 400，且绝不上行到上游
s.sendall(b"GARBAGE\r\n\r\n")
resp2 = b""
while b"\r\n\r\n" not in resp2:
    chunk = s.recv(4096)
    if not chunk:
        break
    resp2 += chunk
assert b"400 Bad Request" in resp2, f"垃圾数据应返回 400: {resp2[:80]!r}"
print(f"  HEAD(keep-alive) 无 body；垃圾数据 -> 400 Bad Request")
s.close()
print("HEAD_KEEPALIVE_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ HEAD keep-alive 后垃圾数据被代理拦截（400）"
else
    echo "❌ HEAD keep-alive 路径失败"
    failed=$((failed + 1))
fi
if grep -q "GARBAGE" "$UPSTREAM_LOG"; then
    echo "❌ 上游收到了 HEAD 后的垃圾数据"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游未收到 HEAD 后的任何额外字节"
fi

# ---------------------------------------------------------------------------
echo "--- 测试 4: 背靠背/流水线请求（一次连发两个 GET）---"
: > "$UPSTREAM_LOG"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")


def read_head(sock):
    resp = b""
    while b"\r\n\r\n" not in resp:
        d = sock.recv(4096)
        if not d:
            raise RuntimeError("closed before head: " + repr(resp))
        resp += d
    head, _, rest = resp.partition(b"\r\n\r\n")
    return head, rest


def read_full_response(sock):
    head, rest = read_head(sock)
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            cl = int(line.split(b":", 1)[1].strip())
    while len(rest) < cl:
        d = sock.recv(4096)
        if not d:
            break
        rest += d
    return head, rest[:cl]


s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
# 一次性连发两个请求：第二个请求会被读入 pending_body，不得被丢弃
blob = b""
for i in range(2):
    blob += (
        f"GET http://127.0.0.1:{http_upstream}/pipe{i} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{http_upstream}\r\n"
        f"Proxy-Authorization: Basic {auth}\r\n"
        f"\r\n"
    ).encode()
s.sendall(blob)
for i in range(2):
    head, body = read_full_response(s)
    assert b"200 OK" in head, f"pipelined GET #{i} status: {head[:80]!r}"
    assert body == b"OK", f"pipelined GET #{i} body: {body!r}"
    print(f"  pipelined GET #{i} -> 200 OK")
s.close()
print("PIPELINE_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 一次连发两个 GET 全部成功（无静默丢弃/挂起）"
else
    echo "❌ 流水线请求失败"
    failed=$((failed + 1))
fi
PIPE_REQ_COUNT=$(grep -c "^REQ " "$UPSTREAM_LOG" || true)
if [[ "$PIPE_REQ_COUNT" -ne 2 ]]; then
    echo "❌ 上游应收到 2 个请求，实际 $PIPE_REQ_COUNT"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游收到 $PIPE_REQ_COUNT 个请求"
fi

# ---------------------------------------------------------------------------
echo "--- 测试 5: HEAD + Content-Length（不应读/转发 body 到上游）---"
: > "$UPSTREAM_LOG"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = (
    f"HEAD http://127.0.0.1:{http_upstream}/ HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"Content-Length: 8\r\n"
    f"\r\n"
).encode()
# HEAD 携带 Content-Length + body：HEAD 无请求体语义，代理不得把 body 转发上游
s.sendall(req + b"HEADMARK")

resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk:
        raise SystemExit("closed before HEAD head")
    resp += chunk
head, _, rest = resp.partition(b"\r\n\r\n")
assert b"200 OK" in head, head
assert len(rest) == 0, f"HEAD 不应有 body: {rest!r}"
s.close()
print("HEAD_CL_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ HEAD + Content-Length 正常响应且无 body"
else
    echo "❌ HEAD + Content-Length 失败"
    failed=$((failed + 1))
fi
if grep -q "HEADMARK" "$UPSTREAM_LOG"; then
    echo "❌ 上游收到了 HEAD 携带的 body 字节（HEAD 读/转了客户端 → 上游）"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游未收到 HEAD 的 body 字节（HEAD 路径无反向写入）"
fi

# ---------------------------------------------------------------------------
echo "--- 测试 6: 拆包 + 多请求同段（body 按 CL 精确截断）---"
: > "$UPSTREAM_LOG"
PORT="$PORT" HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" USER="$USER" PASS="$PASS" python3 - <<'PY'
import base64
import os
import socket
import time

proxy_port = int(os.environ["PORT"])
http_upstream = int(os.environ["HTTP_UPSTREAM_PORT"])
user = os.environ["USER"]
password = os.environ["PASS"]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")


def read_head(sock):
    resp = b""
    while b"\r\n\r\n" not in resp:
        d = sock.recv(4096)
        if not d:
            raise RuntimeError("closed before head: " + repr(resp))
        resp += d
    head, _, rest = resp.partition(b"\r\n\r\n")
    return head, rest


def read_full_response(sock):
    head, rest = read_head(sock)
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            cl = int(line.split(b":", 1)[1].strip())
    while len(rest) < cl:
        d = sock.recv(4096)
        if not d:
            break
        rest += d
    return head, rest[:cl]


s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = (
    f"POST http://127.0.0.1:{http_upstream}/split HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"Content-Length: 4\r\n"
    f"\r\n"
).encode()
# 头 + 部分 body 先发，让代理进入 body 读取循环
s.sendall(req + b"PI")
time.sleep(0.3)
# 剩余 body + 下一个请求一起发送：若 body 读取不按 CL 截断，会把下一请求误写上游
s.sendall(b"NG" + (
    f"GET http://127.0.0.1:{http_upstream}/after-split HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{http_upstream}\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"\r\n"
).encode())

head, body = read_full_response(s)
assert b"200 OK" in head, f"POST status: {head[:80]!r}"
assert body == b"OK", f"POST body: {body!r}"
print("  POST(split body) -> 200 OK")

# 第二个请求必须被独立解析并响应（不得被吞进 POST body）
head2, body2 = read_full_response(s)
assert b"200 OK" in head2, f"GET after split status: {head2[:80]!r}"
assert body2 == b"OK", f"GET after split body: {body2!r}"
print("  GET after split -> 200 OK")
s.close()
print("SPLIT_OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 拆包 body + 下一请求同段：两个请求均成功"
else
    echo "❌ 拆包 body 场景失败（下一请求可能被误写上游/挂起）"
    failed=$((failed + 1))
fi
if ! grep -q "^BODY .*PING$" "$UPSTREAM_LOG"; then
    echo "❌ 上游 POST body 应为恰好 PING（CL=4），实际："
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游 POST body 恰好 PING（按 CL 精确截断）"
fi
if ! grep -q "GET /after-split" "$UPSTREAM_LOG"; then
    echo "❌ 上游未收到拆包后的第二个 GET 请求"
    cat "$UPSTREAM_LOG"
    failed=$((failed + 1))
else
    echo "✅ 上游独立收到拆包后的第二个 GET"
fi

echo "--- 测试完成 ---"

if [[ $failed -eq 0 ]]; then
    echo "=== All keep-alive tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- proxy log ---"
    cat "$WORK_DIR/proxy.log"
    exit 1
fi
