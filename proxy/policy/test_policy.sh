#!/bin/bash
# lifecycle 模块使用 __global 可变全局变量，编译代理需 -enable-globals
case " ${VFLAGS:-} " in
  *" -enable-globals "*) ;;
  *) export VFLAGS="${VFLAGS:-} -enable-globals" ;;
esac
# 自动测试脚本：验证 issue #30 目标域名黑白名单 + 客户端 IP 黑白名单的运行时强制。
# 所有上游都在本地启动，避免外网依赖。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

# Windows 上 python3 可能是 Microsoft Store 占位 stub，探测后回退到 python
if python3 -c "" >/dev/null 2>&1; then
    PY=python3
else
    PY=python
fi

HTTP_BINARY="./proxy.1"
SOCKS5_BINARY="./proxy.socks5"
HTTP_SRC="../http/1/proxy.1.v"
SOCKS5_SRC="../socks5/1/proxy.socks5.v"

# 端口分配（避开其它测试脚本用的 57xx/1808x）
HTTP_A_PORT=5897   # deny 规则
HTTP_B_PORT=5898   # allow 白名单
HTTP_C_PORT=5899   # client_deny
S5_A_PORT=5900     # socks5 正向（deny 不命中）
S5_B_PORT=5901     # socks5 反向（deny 命中）
HTTP_UPSTREAM_PORT=18083
ECHO_UPSTREAM_PORT=18084

WORK_DIR="$(mktemp -d)"
UPSTREAM_LOG="$WORK_DIR/upstream.log"
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

# --- 策略配置文件 ---
cat > "$WORK_DIR/http_a.toml" <<EOF
listen = "127.0.0.1:$HTTP_A_PORT"
[rules]
deny = ["blocked.test", "10.0.0.0/8"]
EOF

cat > "$WORK_DIR/http_b.toml" <<EOF
listen = "127.0.0.1:$HTTP_B_PORT"
[rules]
allow = ["127.0.0.0/8"]
EOF

cat > "$WORK_DIR/http_c.toml" <<EOF
listen = "127.0.0.1:$HTTP_C_PORT"
[rules]
client_deny = ["127.0.0.0/8"]
EOF

cat > "$WORK_DIR/s5_a.toml" <<EOF
listen = "127.0.0.1:$S5_A_PORT"
[rules]
deny = ["10.9.9.9"]
EOF

cat > "$WORK_DIR/s5_b.toml" <<EOF
listen = "127.0.0.1:$S5_B_PORT"
[rules]
deny = ["127.0.0.1"]
EOF

echo "--- 启动代理（全部关闭鉴权，专注策略路径） ---"
PROXY_REQUIRE_AUTH=0 $HTTP_BINARY --config "$WORK_DIR/http_a.toml" > "$WORK_DIR/http_a.log" 2>&1 &
PIDS="$PIDS $!"
PROXY_REQUIRE_AUTH=0 $HTTP_BINARY --config "$WORK_DIR/http_b.toml" > "$WORK_DIR/http_b.log" 2>&1 &
PIDS="$PIDS $!"
PROXY_REQUIRE_AUTH=0 $HTTP_BINARY --config "$WORK_DIR/http_c.toml" > "$WORK_DIR/http_c.log" 2>&1 &
PIDS="$PIDS $!"
$SOCKS5_BINARY --no-auth --config "$WORK_DIR/s5_a.toml" > "$WORK_DIR/s5_a.log" 2>&1 &
PIDS="$PIDS $!"
$SOCKS5_BINARY --no-auth --config "$WORK_DIR/s5_b.toml" > "$WORK_DIR/s5_b.log" 2>&1 &
PIDS="$PIDS $!"

for p in "$HTTP_A_PORT" "$HTTP_B_PORT" "$HTTP_C_PORT" "$S5_A_PORT" "$S5_B_PORT"; do
    wait_for_port "127.0.0.1" "$p" || { echo "❌ 端口 $p 未就绪"; cat "$WORK_DIR"/*.log; exit 1; }
done

echo "--- 测试 1: deny 域名经 CONNECT 得 403（无需 DNS，拨号前拦截） ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_A_PORT" \
    "http://blocked.test:$ECHO_UPSTREAM_PORT/") || true
assert_eq "403" "$STATUS" "deny 域名被 403 拦截"

echo "--- 测试 2: 未命中 deny 的 CONNECT 隧道正常 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_A_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello")
assert_eq "200" "$STATUS" "未命中 deny 的目标放行"

echo "--- 测试 3: deny CIDR 命中的目标经 CONNECT 得 403 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_A_PORT" \
    "http://10.1.2.3:$ECHO_UPSTREAM_PORT/") || true
assert_eq "403" "$STATUS" "deny CIDR 命中的目标被 403 拦截"

echo "--- 测试 4: allow 白名单（CIDR）内目标放行 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_B_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello")
assert_eq "200" "$STATUS" "白名单内的目标放行"

echo "--- 测试 5: allow 白名单外目标得 403 ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_B_PORT" \
    "http://localhost:$HTTP_UPSTREAM_PORT/") || true
assert_eq "403" "$STATUS" "白名单外的目标被 403 拦截"

echo "--- 测试 6: 客户端 IP 黑名单拒绝连接（无响应） ---"
STATUS=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$HTTP_C_PORT" \
    "http://127.0.0.1:$HTTP_UPSTREAM_PORT/hello") || true
assert_eq "000" "$STATUS" "client_deny 命中的客户端得不到任何响应"

echo "--- 测试 7: SOCKS5 deny 未命中 → CONNECT 成功（rep=0） ---"
S5_PORT="$S5_A_PORT" ECHO_UPSTREAM_PORT="$ECHO_UPSTREAM_PORT" "$PY" - <<'PY'
import os
import socket

port = int(os.environ["S5_PORT"])
echo_port = int(os.environ["ECHO_UPSTREAM_PORT"])

s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(bytes([5, 1, 0]))
resp = s.recv(2)
assert resp == bytes([5, 0]), f"greeting reply {resp!r}"

req = bytes([5, 1, 0, 1, 127, 0, 0, 1]) + echo_port.to_bytes(2, "big")
s.sendall(req)
reply = s.recv(10)
assert len(reply) == 10, f"short reply {reply!r}"
assert reply[1] == 0, f"expected rep=0, got rep={reply[1]}"
payload = b"policy-socks5-pass"
s.sendall(payload)
assert s.recv(len(payload)) == payload
s.close()
print("  socks5 rep=0 + echo OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ SOCKS5 未命中 deny 的目标放行"
else
    echo "❌ SOCKS5 未命中 deny 的目标未放行"
    failed=$((failed + 1))
fi

echo "--- 测试 8: SOCKS5 deny 命中 → rep=2（not allowed） ---"
S5_PORT="$S5_B_PORT" ECHO_UPSTREAM_PORT="$ECHO_UPSTREAM_PORT" "$PY" - <<'PY'
import os
import socket

port = int(os.environ["S5_PORT"])
echo_port = int(os.environ["ECHO_UPSTREAM_PORT"])

s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(bytes([5, 1, 0]))
resp = s.recv(2)
assert resp == bytes([5, 0]), f"greeting reply {resp!r}"

req = bytes([5, 1, 0, 1, 127, 0, 0, 1]) + echo_port.to_bytes(2, "big")
s.sendall(req)
reply = s.recv(10)
assert len(reply) == 10, f"short reply {reply!r}"
assert reply[1] == 2, f"expected rep=2, got rep={reply[1]}"
s.close()
print("  socks5 rep=2 OK")
PY
if [[ $? -eq 0 ]]; then
    echo "✅ SOCKS5 deny 命中的目标回 rep=2"
else
    echo "❌ SOCKS5 deny 命中的目标未回 rep=2"
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
