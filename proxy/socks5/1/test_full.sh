#!/bin/bash
# SOCKS5 全量本地测试：本地 TCP echo 上游 + CONNECT 隧道 + 鉴权成功/失败。
# 原 test_full.sh 的 4 个用例全部依赖 httpbin.org 外网，改造成与 HTTP 版
# test_full.sh 一致的全本地模式，CI 主流程可直接运行，无外网抖动。
#
# 覆盖：
#   1. 鉴权模式：错误密码 → userpass 子协商失败 (ver=1, status=0x01)
#   2. 鉴权模式：不提供凭据 / 无可接受方法 → (ver=5, method=0xFF)
#   3. 鉴权模式：正确凭据 → CONNECT 隧道 + echo 回显
#   4. 无鉴权模式：CONNECT 隧道 + echo 回显
#
# 注：SOCKS5 客户端用 Python socket 做握手（不能用 curl——curl 对裸 TCP echo
# 上游会按 HTTP 解析失败）。风格参考同目录 test_protocol.sh。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

PROXY_SOURCE="proxy/socks5/1/proxy.socks5.v"
PROXY_PORT=5778
LISTEN_ADDR="127.0.0.1:5778"
ECHO_PORT=18082
USER="testuser"
PASS="testpass"
WORK_DIR="$(mktemp -d)"
PROXY_BIN="$WORK_DIR/proxy_socks5_bin"
PROXY_LOG="$WORK_DIR/proxy.log"
UPSTREAM_PID=""
PROXY_PID=""
failed=0

cleanup() {
    echo "--- 清理 ---"
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    if [ -n "$UPSTREAM_PID" ]; then
        kill "$UPSTREAM_PID" 2>/dev/null || true
        wait "$UPSTREAM_PID" 2>/dev/null || true
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

# 重启代理：restart_proxy <user> <pass>；user/pass 为空则无鉴权模式。
# 每次重启前先杀掉旧实例，避免端口被旧进程占用。
restart_proxy() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        PROXY_PID=""
    fi
    local user="${1:-}"
    local pass="${2:-}"
    SOCKS5_LISTEN_ADDR="$LISTEN_ADDR" \
        SOCKS5_AUTH_USERNAME="$user" SOCKS5_AUTH_PASSWORD="$pass" \
        SOCKS5_IDLE_TIMEOUT=300 \
        "$PROXY_BIN" > "$PROXY_LOG" 2>&1 &
    PROXY_PID=$!
    wait_for_port "127.0.0.1" "$PROXY_PORT" || {
        echo "❌ SOCKS5 代理未监听 $PROXY_PORT"
        cat "$PROXY_LOG"
        exit 1
    }
}

echo "--- 正在编译 ---"
(cd "$repo_root" && v -o "$PROXY_BIN" "$PROXY_SOURCE") || {
    echo "❌ 编译失败"
    exit 1
}

echo "--- 启动本地 TCP echo 上游 ---"
python3 - "$ECHO_PORT" > "$WORK_DIR/echo.stdout" 2>&1 <<'PY' &
import socket
import sys
import threading
import time

port = int(sys.argv[1])

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(16)


def echo(conn):
    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            conn.sendall(data)
    except OSError:
        pass
    finally:
        conn.close()


def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=lambda c=conn: echo(c), daemon=True).start()


threading.Thread(target=serve, daemon=True).start()
try:
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    pass
PY
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$ECHO_PORT" || {
    echo "❌ echo 上游未监听 $ECHO_PORT"
    exit 1
}

echo "--- 启动代理（鉴权模式） ---"
restart_proxy "$USER" "$PASS"

echo "--- 测试 1: 错误密码 → 鉴权失败 (status=0x01) ---"
if python3 - "$PROXY_PORT" <<'PY'
import socket
import sys

proxy_port = int(sys.argv[1])
proxy = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
# greeting：只声明 userpass 方法
proxy.sendall(b"\x05\x01\x02")
g = proxy.recv(2)
assert g == b"\x05\x02", f"greeting rep: {g!r} (expect 05 02)"
# userpass 子协商：testuser / wrongpass
auth = b"\x01\x08testuser\x08wrongpass"
proxy.sendall(auth)
status = proxy.recv(2)
assert status == b"\x01\x01", f"auth status: {status!r} (expect 01 01)"
proxy.close()
print("  auth rejected: ver=1 status=0x01")
PY
then
    echo "✅ 错误密码被拒"
else
    echo "❌ 错误密码未返回 0x01"
    failed=$((failed + 1))
fi

echo "--- 测试 2: 鉴权模式不提供凭据 → 无可接受方法 (0xFF) ---"
# 客户端只声明 GSSAPI(0x01)，不含 no-auth / userpass → 代理无可接受方法。
if python3 - "$PROXY_PORT" <<'PY'
import socket
import sys

proxy_port = int(sys.argv[1])
proxy = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
proxy.sendall(b"\x05\x01\x01")
g = proxy.recv(2)
assert g == b"\x05\xff", f"greeting rep: {g!r} (expect 05 ff)"
proxy.close()
print("  no acceptable method: ver=5 method=0xff")
PY
then
    echo "✅ 不提供凭据被拒"
else
    echo "❌ 不提供凭据未被拒绝"
    failed=$((failed + 1))
fi

echo "--- 测试 3: 正确凭据 → CONNECT 隧道 + echo 回显 ---"
if python3 - "$PROXY_PORT" "$ECHO_PORT" <<'PY'
import socket
import struct
import sys

proxy_port = int(sys.argv[1])
echo_port = int(sys.argv[2])

proxy = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
proxy.sendall(b"\x05\x01\x02")
assert proxy.recv(2) == b"\x05\x02", "greeting rep"
auth = b"\x01\x08testuser\x08testpass"
proxy.sendall(auth)
assert proxy.recv(2) == b"\x01\x00", "auth status"
# CONNECT 127.0.0.1:echo_port（IPv4）
req = b"\x05\x01\x00\x01" + bytes([127, 0, 0, 1]) + struct.pack(">H", echo_port)
proxy.sendall(req)
# IPv4 CONNECT reply 固定 10 字节（4 头 + 4 addr + 2 port）
reply = b""
while len(reply) < 10:
    chunk = proxy.recv(10 - len(reply))
    if not chunk:
        break
    reply += chunk
assert len(reply) == 10, f"reply len: {len(reply)} {reply!r}"
assert reply[0] == 5 and reply[1] == 0 and reply[3] == 1, f"reply header: {reply[:4]!r}"
# 隧道回显
payload = b"ping-through-socks5-auth"
proxy.sendall(payload)
got = b""
while len(got) < len(payload):
    chunk = proxy.recv(4096)
    if not chunk:
        break
    got += chunk
assert got == payload, f"echo: sent {payload!r} got {got!r}"
proxy.close()
print("  auth + CONNECT + echo OK")
PY
then
    echo "✅ 鉴权成功 + CONNECT 隧道可用"
else
    echo "❌ 鉴权成功 + CONNECT 链路失败"
    failed=$((failed + 1))
fi

echo "--- 重启代理（无鉴权模式） ---"
restart_proxy "" ""

echo "--- 测试 4: 无鉴权模式 CONNECT 隧道 + echo 回显 ---"
if python3 - "$PROXY_PORT" "$ECHO_PORT" <<'PY'
import socket
import struct
import sys

proxy_port = int(sys.argv[1])
echo_port = int(sys.argv[2])

proxy = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
proxy.sendall(b"\x05\x01\x00")
assert proxy.recv(2) == b"\x05\x00", "greeting rep"
req = b"\x05\x01\x00\x01" + bytes([127, 0, 0, 1]) + struct.pack(">H", echo_port)
proxy.sendall(req)
reply = b""
while len(reply) < 10:
    chunk = proxy.recv(10 - len(reply))
    if not chunk:
        break
    reply += chunk
assert len(reply) == 10, f"reply len: {len(reply)} {reply!r}"
assert reply[0] == 5 and reply[1] == 0 and reply[3] == 1, f"reply header: {reply[:4]!r}"
payload = b"ping-through-socks5-noauth"
proxy.sendall(payload)
got = b""
while len(got) < len(payload):
    chunk = proxy.recv(4096)
    if not chunk:
        break
    got += chunk
assert got == payload, f"echo: sent {payload!r} got {got!r}"
proxy.close()
print("  no-auth CONNECT + echo OK")
PY
then
    echo "✅ 无鉴权模式 CONNECT 隧道可用"
else
    echo "❌ 无鉴权模式 CONNECT 链路失败"
    failed=$((failed + 1))
fi

echo "--- 测试完成 ---"
if [[ $failed -eq 0 ]]; then
    echo "=== All tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    echo "--- proxy log ---"
    cat "$PROXY_LOG"
    exit 1
fi
