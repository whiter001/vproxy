#!/bin/bash
# lifecycle 模块使用 __global 可变全局变量，编译代理需 -enable-globals
case " ${VFLAGS:-} " in
  *" -enable-globals "*) ;;
  *) export VFLAGS="${VFLAGS:-} -enable-globals" ;;
esac
# 自动测试脚本：验证 issue #27 上级代理级联（http:// 与 socks5:// parent）。
# 拓扑：client -> child --parent--> parent -> 本地 echo 上游；全部本地，无外网依赖。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

HTTP_BINARY="./proxy.1"
SOCKS5_BINARY="./proxy.socks5"
HTTP_SRC="../http/1/proxy.1.v"
SOCKS5_SRC="../socks5/1/proxy.socks5.v"

HTTP_UPSTREAM_PORT=18085
ECHO_UPSTREAM_PORT=18086
PA_PORT=5950   # 上级 A：http 代理（带认证）
CA_PORT=5951   # 子级 A：http --parent http://上级A
PB_PORT=5952   # 上级 B：socks5 代理（带认证）
CB_PORT=5953   # 子级 B：http --parent socks5://上级B
CC_PORT=5954   # 子级 C：socks5 --parent socks5://上级B
CD_PORT=5955   # 子级 D：http --parent http://127.0.0.1:1（死上级）
CE_PORT=5956   # 子级 E：http --parent 凭据错误的上级A

U_USER="parentuser"
U_PASS="parentpass"

WORK_DIR="$(mktemp -d)"
PIDS=""
failed=0

cleanup() {
    echo "--- 清理 ---"
    # Windows Git Bash 对原生 exe 的 SIGTERM 可能不生效，统一 kill -9
    for pid in $PIDS; do
        kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
    rm -f "$HTTP_BINARY" "$SOCKS5_BINARY"
}
trap cleanup EXIT

# Windows 上 python3 可能是 Microsoft Store 占位 stub，探测后回退到 python
if python3 -c "" >/dev/null 2>&1; then
    PY=python3
else
    PY=python
fi

wait_for_port() {
    host="$1"
    port="$2"
    for _ in $(seq 1 50); do
        # /dev/tcp 探测：不依赖 nc（Windows Git Bash 无 nc）
        if (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1; then
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

echo "--- 正在编译 ---"
v -o "$HTTP_BINARY" "$HTTP_SRC"
v -o "$SOCKS5_BINARY" "$SOCKS5_SRC"

cat > "$WORK_DIR/upstream_servers.py" <<'PY'
#!/usr/bin/env python3
import os
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = int(os.environ["HTTP_UPSTREAM_PORT"])
ECHO_PORT = int(os.environ["ECHO_UPSTREAM_PORT"])


class EchoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_GET(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


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
tcp_server = ThreadedTCPServer(("127.0.0.1", ECHO_PORT), EchoTCPHandler)
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
HTTP_UPSTREAM_PORT="$HTTP_UPSTREAM_PORT" ECHO_UPSTREAM_PORT="$ECHO_UPSTREAM_PORT" \
    "$PY" "$WORK_DIR/upstream_servers.py" > "$WORK_DIR/upstream.stdout" 2>&1 &
PIDS="$PIDS $!"
wait_for_port "127.0.0.1" "$HTTP_UPSTREAM_PORT"
wait_for_port "127.0.0.1" "$ECHO_UPSTREAM_PORT"

echo "--- 启动上级与子级代理 ---"
# 上级 A：http 代理（带认证）
PROXY_AUTH_USER="$U_USER" PROXY_AUTH_PASS="$U_PASS" PROXY_LISTEN_ADDR="127.0.0.1:$PA_PORT" \
    $HTTP_BINARY > "$WORK_DIR/parent_a.log" 2>&1 &
PIDS="$PIDS $!"
# 子级 A：--parent http://上级A（子级自身免认证）
PROXY_REQUIRE_AUTH=0 PROXY_LISTEN_ADDR="127.0.0.1:$CA_PORT" \
    $HTTP_BINARY --parent "http://$U_USER:$U_PASS@127.0.0.1:$PA_PORT" > "$WORK_DIR/child_a.log" 2>&1 &
PIDS="$PIDS $!"
# 上级 B：socks5 代理（带认证）
SOCKS5_AUTH_USERNAME="$U_USER" SOCKS5_AUTH_PASSWORD="$U_PASS" SOCKS5_LISTEN_ADDR="127.0.0.1:$PB_PORT" \
    $SOCKS5_BINARY > "$WORK_DIR/parent_b.log" 2>&1 &
PIDS="$PIDS $!"
# 子级 B：http --parent socks5://上级B
PROXY_REQUIRE_AUTH=0 PROXY_LISTEN_ADDR="127.0.0.1:$CB_PORT" \
    $HTTP_BINARY --parent "socks5://$U_USER:$U_PASS@127.0.0.1:$PB_PORT" > "$WORK_DIR/child_b.log" 2>&1 &
PIDS="$PIDS $!"
# 子级 C：socks5 --parent socks5://上级B
SOCKS5_NO_AUTH=1 SOCKS5_LISTEN_ADDR="127.0.0.1:$CC_PORT" \
    $SOCKS5_BINARY --parent "socks5://$U_USER:$U_PASS@127.0.0.1:$PB_PORT" > "$WORK_DIR/child_c.log" 2>&1 &
PIDS="$PIDS $!"
# 子级 D：死上级
PROXY_REQUIRE_AUTH=0 PROXY_LISTEN_ADDR="127.0.0.1:$CD_PORT" \
    $HTTP_BINARY --parent "http://127.0.0.1:1" > "$WORK_DIR/child_d.log" 2>&1 &
PIDS="$PIDS $!"
# 子级 E：上级 A 凭据错误
PROXY_REQUIRE_AUTH=0 PROXY_LISTEN_ADDR="127.0.0.1:$CE_PORT" \
    $HTTP_BINARY --parent "http://bad:wrong@127.0.0.1:$PA_PORT" > "$WORK_DIR/child_e.log" 2>&1 &
PIDS="$PIDS $!"

for p in "$PA_PORT" "$CA_PORT" "$PB_PORT" "$CB_PORT" "$CC_PORT" "$CD_PORT" "$CE_PORT"; do
    wait_for_port "127.0.0.1" "$p" || { echo "❌ 端口 $p 未就绪"; cat "$WORK_DIR"/*.log; exit 1; }
done

echo "--- 测试 1: http->http 级联，明文 GET ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$CA_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello")
assert_eq "200" "$STATUS" "http->http 级联 GET 成功"

echo "--- 测试 2: http->http 级联，CONNECT 隧道（双层 CONNECT） ---"
CA_PORT="$CA_PORT" ECHO_UPSTREAM_PORT="$ECHO_UPSTREAM_PORT" "$PY" - <<'PY'
import os
import socket

proxy_port = int(os.environ["CA_PORT"])
echo_port = int(os.environ["ECHO_UPSTREAM_PORT"])

s = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
req = f"CONNECT 127.0.0.1:{echo_port} HTTP/1.1\r\nHost: 127.0.0.1:{echo_port}\r\n\r\n"
s.sendall(req.encode())
resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk:
        raise SystemExit("child closed before CONNECT completed")
    resp += chunk
assert b"200 Connection Established" in resp, resp.decode("utf-8", "replace")
payload = b"ping-two-level-chain"
s.sendall(payload)
echo = s.recv(len(payload))
assert echo == payload, f"echo mismatch: {echo!r}"
s.close()
print("  two-level CONNECT echo OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ 双层 CONNECT 隧道可用"
else
    echo "❌ 双层 CONNECT 隧道不可用"
    failed=$((failed + 1))
fi
# 上级 A 日志应出现到 echo 上游的 CONNECT 记录，证明流量确实走了上级
if grep -q "CONNECT: tunnel established to 127.0.0.1:$ECHO_UPSTREAM_PORT" "$WORK_DIR/parent_a.log"; then
    echo "✅ 上级 A 日志确认流量经上级转发"
else
    echo "❌ 上级 A 日志未见转发记录"
    failed=$((failed + 1))
fi

echo "--- 测试 3: http->socks5 级联，明文 GET ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$CB_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello")
assert_eq "200" "$STATUS" "http->socks5 级联 GET 成功"

echo "--- 测试 4: socks5->socks5 级联 ---"
CC_PORT="$CC_PORT" ECHO_UPSTREAM_PORT="$ECHO_UPSTREAM_PORT" "$PY" - <<'PY'
import os
import socket

port = int(os.environ["CC_PORT"])
echo_port = int(os.environ["ECHO_UPSTREAM_PORT"])

s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(bytes([5, 1, 0]))
resp = s.recv(2)
assert resp == bytes([5, 0]), f"greeting reply {resp!r}"
req = bytes([5, 1, 0, 1, 127, 0, 0, 1]) + echo_port.to_bytes(2, "big")
s.sendall(req)
reply = s.recv(10)
assert len(reply) == 10 and reply[1] == 0, f"reply {reply!r}"
payload = b"socks5-two-level"
s.sendall(payload)
assert s.recv(len(payload)) == payload
s.close()
print("  socks5->socks5 chain echo OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ socks5->socks5 级联可用"
else
    echo "❌ socks5->socks5 级联不可用"
    failed=$((failed + 1))
fi

echo "--- 测试 5: 死上级 → 502 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$CD_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello") || true
assert_eq "502" "$STATUS" "上级不可达返回 502"

echo "--- 测试 6: 上级认证失败（凭据错误）→ 上级 407 透传给客户端 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$CE_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello") || true
assert_eq "407" "$STATUS" "上级 407 正确透传"

echo "--- 测试 7: 非法 --parent URL 启动 fail-fast ---"
PROXY_REQUIRE_AUTH=0 $HTTP_BINARY --parent "1.2.3.4:8080" > "$WORK_DIR/bad_parent.log" 2>&1
if [[ $? -ne 0 ]] && grep -q "invalid --parent" "$WORK_DIR/bad_parent.log"; then
    echo "✅ 非法 parent URL 启动失败且报错清晰"
else
    echo "❌ 非法 parent URL 未 fail-fast"
    cat "$WORK_DIR/bad_parent.log"
    failed=$((failed + 1))
fi

echo "--- 测试完成 ---"

if [[ $failed -eq 0 ]]; then
    echo "=== All tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi
