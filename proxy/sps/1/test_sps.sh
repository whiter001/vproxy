#!/bin/bash
# lifecycle 模块使用 __global 可变全局变量，编译代理需 -enable-globals
case " ${VFLAGS:-} " in
  *" -enable-globals "*) ;;
  *) export VFLAGS="${VFLAGS:-} -enable-globals" ;;
esac
# SPS 单端口多协议集成测试（issue #29）：同一监听口按首字节识别 HTTP / SOCKS5。
# 结构与 helper 参照 proxy/socks5/1/test_full.sh（本地全量、无外网依赖）。
#
# 覆盖：
#   1. HTTP 代理路径：curl -x http://httpuser:httppass@sps → 本地上游 200
#   2. SOCKS5 路径（同一端口）：curl -x socks5://s5user:s5pass@sps → 本地上游 200
#   3. HTTP 无凭据 → 407
#   4. SOCKS5 错误凭据 → 握手失败（curl 非 0）
#   5. 垃圾首字节（0x01，非 SOCKS5/HTTP）→ 连接被关闭，进程不崩
#
# 注：上游用 python3 的 ThreadingHTTPServer 在本地起（CI ubuntu 自带 python3）；
# wait_for_port 优先 nc，回退 bash /dev/tcp（本地无 nc 时仍可探测）。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

PROXY_SOURCE="proxy/sps/1/proxy.sps.v"
PROXY_PORT=5780
LISTEN_ADDR="127.0.0.1:5780"
UPSTREAM_PORT=18083
HTTP_USER="httpuser"
HTTP_PASS="httppass"
S5_USER="s5user"
S5_PASS="s5pass"
WORK_DIR="$(mktemp -d)"
PROXY_BIN="$WORK_DIR/proxy_sps_bin"
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
        # 无 nc 的环境（如 Windows Git Bash）：bash /dev/tcp 回退。
        # 放子 shell 里执行，fd 随子 shell 退出自动关闭。
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
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
    fi
}

echo "--- 正在编译 ---"
(cd "$repo_root" && v -o "$PROXY_BIN" "$PROXY_SOURCE") || {
    echo "❌ 编译失败"
    exit 1
}

echo "--- 启动本地 HTTP 上游 ---"
UPSTREAM_PORT="$UPSTREAM_PORT" python3 - > "$WORK_DIR/upstream.stdout" 2>&1 <<'PY' &
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(os.environ["UPSTREAM_PORT"])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        body = b"sps-upstream-ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
UPSTREAM_PID=$!
wait_for_port "127.0.0.1" "$UPSTREAM_PORT" || {
    echo "❌ 本地上游未监听 $UPSTREAM_PORT"
    cat "$WORK_DIR/upstream.stdout"
    exit 1
}

echo "--- 启动 SPS（HTTP 鉴权 + SOCKS5 鉴权，同一端口） ---"
"$PROXY_BIN" \
    --listen "$LISTEN_ADDR" \
    --http-user "$HTTP_USER" --http-pass "$HTTP_PASS" \
    --socks5-user "$S5_USER" --socks5-pass "$S5_PASS" \
    --idle-timeout 300 > "$PROXY_LOG" 2>&1 &
PROXY_PID=$!
wait_for_port "127.0.0.1" "$PROXY_PORT" || {
    echo "❌ SPS 未监听 $PROXY_PORT"
    cat "$PROXY_LOG"
    exit 1
}

echo "--- 测试 1: HTTP 代理路径（http://httpuser:httppass@） ---"
STATUS=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
    --proxy "http://${HTTP_USER}:${HTTP_PASS}@127.0.0.1:$PROXY_PORT" \
    "http://127.0.0.1:$UPSTREAM_PORT/")
assert_eq "200" "$STATUS" "HTTP 带凭据 GET 成功"

echo "--- 测试 2: SOCKS5 路径（同一端口 socks5://s5user:s5pass@） ---"
STATUS=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
    --proxy "socks5://${S5_USER}:${S5_PASS}@127.0.0.1:$PROXY_PORT" \
    "http://127.0.0.1:$UPSTREAM_PORT/")
assert_eq "200" "$STATUS" "SOCKS5 带凭据 GET 成功（同端口）"

echo "--- 测试 3: HTTP 无凭据 → 407 ---"
STATUS=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
    --proxy "http://127.0.0.1:$PROXY_PORT" \
    "http://127.0.0.1:$UPSTREAM_PORT/")
assert_eq "407" "$STATUS" "HTTP 无凭据被 407 拦截"

echo "--- 测试 4: SOCKS5 错误凭据 → 握手失败 ---"
if curl -sS --max-time 10 -o /dev/null \
    --proxy "socks5://${S5_USER}:wrongpass@127.0.0.1:$PROXY_PORT" \
    "http://127.0.0.1:$UPSTREAM_PORT/" 2>/dev/null; then
    echo "❌ SOCKS5 错误密码竟然握手成功"
    failed=$((failed + 1))
else
    echo "✅ SOCKS5 错误密码握手失败（curl 非 0）"
fi

echo "--- 测试 5: 垃圾首字节 → 连接被关闭，进程不崩 ---"
if PROXY_PORT="$PROXY_PORT" python3 - <<'PY'
import os
import socket

port = int(os.environ["PROXY_PORT"])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
# 首字节 0x01：既不是 0x05（SOCKS5）也不是 A-Z（HTTP 方法首字母）
s.sendall(b"\x01")
s.settimeout(5)
try:
    data = s.recv(1024)
except socket.timeout:
    raise SystemExit("proxy did not close connection after garbage first byte")
if data != b"":
    raise SystemExit(f"expected clean close, got {data!r}")
s.close()
print("  connection closed by proxy")
PY
then
    echo "✅ 垃圾首字节连接被关闭"
else
    echo "❌ 垃圾首字节连接未被正确关闭"
    failed=$((failed + 1))
fi
if kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "✅ SPS 进程未崩溃"
else
    echo "❌ SPS 进程已崩溃"
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
