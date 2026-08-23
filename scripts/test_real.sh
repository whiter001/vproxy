#!/usr/bin/env bash
# 真网端到端实测脚本：HTTP / SOCKS5 / SOCKS4 代理 → httpbin.org。
#
# 从 CI 内联用例抽出，可在本地直接复用：
#   bash scripts/test_real.sh
#
# 行为：
#   - httpbin.org 不可达时默认打印跳过并 exit 0（避免离线/CI 环境 flaky）。
#     设置 REQUIRE_NET=1 可改为硬失败（对齐 CI 现有内联用例的严格语义）。
#   - 任一用例失败立即 exit 1（set -u + trap 清理进程）。
#
# 环境变量（显式 export，issue #1 fail-fast）：
#   PROXY_AUTH_USER / PROXY_AUTH_PASS   HTTP 代理凭据
#   SOCKS5_AUTH_USERNAME / SOCKS5_AUTH_PASSWORD  SOCKS5 代理凭据

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

HTTP_PORT=5777
SOCKS5_PORT=5778
SOCKS4_PORT=5779

USER="testuser"
PASS="testpass"

WORK_DIR="$(mktemp -d)"
HTTP_BIN="$WORK_DIR/proxy_http"
SOCKS5_BIN="$WORK_DIR/proxy_socks5"
SOCKS4_BIN="$WORK_DIR/proxy_socks4"
HTTP_PID=""
SOCKS5_PID=""
SOCKS4_PID=""

cleanup() {
    if [ -n "$HTTP_PID" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
    if [ -n "$SOCKS5_PID" ]; then
        kill "$SOCKS5_PID" 2>/dev/null || true
    fi
    if [ -n "$SOCKS4_PID" ]; then
        kill "$SOCKS4_PID" 2>/dev/null || true
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

# 前置检查：httpbin 可达性
if ! curl --fail --silent --show-error --max-time 5 https://httpbin.org/get -o /dev/null; then
    if [ "${REQUIRE_NET:-0}" = "1" ]; then
        echo "❌ httpbin.org 不可达且 REQUIRE_NET=1，失败退出"
        exit 1
    fi
    echo "⚠️ httpbin.org 不可达，跳过真网实测（离线环境）"
    exit 0
fi

echo "--- 正在编译 ---"
(cd "$repo_root" && v -o "$HTTP_BIN" proxy/http/1/proxy.1.v) || exit 1
(cd "$repo_root" && v -o "$SOCKS5_BIN" proxy/socks5/1/proxy.socks5.v) || exit 1
(cd "$repo_root" && v -o "$SOCKS4_BIN" proxy/socks4/1/proxy.socks4.v) || exit 1

echo "--- 启动代理 ---"
export PROXY_LISTEN_ADDR="127.0.0.1:$HTTP_PORT"
export PROXY_AUTH_USER="$USER"
export PROXY_AUTH_PASS="$PASS"
"$HTTP_BIN" > "$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!

export SOCKS5_LISTEN_ADDR="127.0.0.1:$SOCKS5_PORT"
export SOCKS5_AUTH_USERNAME="$USER"
export SOCKS5_AUTH_PASSWORD="$PASS"
"$SOCKS5_BIN" > "$WORK_DIR/socks5.log" 2>&1 &
SOCKS5_PID=$!

export SOCKS4_LISTEN_ADDR="127.0.0.1:$SOCKS4_PORT"
export SOCKS4_NO_AUTH=1
"$SOCKS4_BIN" > "$WORK_DIR/socks4.log" 2>&1 &
SOCKS4_PID=$!

wait_for_port "127.0.0.1" "$HTTP_PORT" || { echo "❌ HTTP proxy 未监听 $HTTP_PORT"; cat "$WORK_DIR/http.log"; exit 1; }
wait_for_port "127.0.0.1" "$SOCKS5_PORT" || { echo "❌ SOCKS5 proxy 未监听 $SOCKS5_PORT"; cat "$WORK_DIR/socks5.log"; exit 1; }
wait_for_port "127.0.0.1" "$SOCKS4_PORT" || { echo "❌ SOCKS4 proxy 未监听 $SOCKS4_PORT"; cat "$WORK_DIR/socks4.log"; exit 1; }

fail() {
    echo "❌ $1"
    exit 1
}

# ---------------------------------------------------------------------------
echo "--- 测试 1: HTTP 代理 带鉴权 GET ---"
curl --fail --silent --show-error --max-time 15 \
    --proxy-user "$USER:$PASS" \
    -x "127.0.0.1:$HTTP_PORT" \
    "https://httpbin.org/get" -o /dev/null \
    || fail "HTTP GET 带鉴权失败"

echo "--- 测试 2: HTTP 代理 带鉴权 POST ---"
curl --fail --silent --show-error --max-time 15 \
    --proxy-user "$USER:$PASS" \
    -x "127.0.0.1:$HTTP_PORT" \
    -X POST -H 'Content-Type: application/json' -d '{"probe":1}' \
    "http://httpbin.org/post" -o /dev/null \
    || fail "HTTP POST 带鉴权失败"

echo "--- 测试 3: HTTP 代理 HTTPS CONNECT 隧道 ---"
curl --fail --silent --show-error --max-time 15 \
    --proxy-user "$USER:$PASS" \
    -x "127.0.0.1:$HTTP_PORT" \
    "https://httpbin.org/get" -o /dev/null \
    || fail "HTTPS CONNECT 隧道失败"

echo "--- 测试 4: HTTP 代理 无鉴权 → 407 ---"
STATUS=$(curl --silent --show-error --max-time 15 \
    -o /dev/null -w "%{http_code}" \
    -x "127.0.0.1:$HTTP_PORT" \
    "http://httpbin.org/get")
[ "$STATUS" = "407" ] || fail "无鉴权请求状态码 ${STATUS}（期望 407）"

echo "--- 测试 5: HTTP 代理 错误凭据 → 407 ---"
STATUS=$(curl --silent --show-error --max-time 15 \
    -o /dev/null -w "%{http_code}" \
    --proxy-user "wrong:wrong" \
    -x "127.0.0.1:$HTTP_PORT" \
    "http://httpbin.org/get")
[ "$STATUS" = "407" ] || fail "错误凭据请求状态码 ${STATUS}（期望 407）"

# ---------------------------------------------------------------------------
# 注：SOCKS5 用例用 --socks5（本地解析 DNS 后发 IPv4）而不是 --socks5-hostname。
# 原因是 curl/libcurl 对 ATYP=3 且 BND.ADDR 长度=0 的 SOCKS5 回复会挂起
# （RFC 1928 允许空 BND.ADDR，Python/本仓 socks5_dial 客户端均正常）；
# 与 CI 现有内联用例保持一致。
echo "--- 测试 6: SOCKS5 代理 带鉴权 ---"
curl --fail --silent --show-error --max-time 15 \
    --proxy-user "$USER:$PASS" \
    --socks5 "127.0.0.1:$SOCKS5_PORT" \
    "https://httpbin.org/get" -o /dev/null \
    || fail "SOCKS5 带鉴权失败"

echo "--- 测试 7: SOCKS5 代理 错误凭据应拒绝 ---"
if curl --fail --silent --show-error --max-time 15 \
    --proxy-user "wrong:wrong" \
    --socks5 "127.0.0.1:$SOCKS5_PORT" \
    "https://httpbin.org/get" -o /dev/null 2>/dev/null; then
    fail "SOCKS5 错误凭据居然成功了"
fi

# ---------------------------------------------------------------------------
echo "--- 测试 8: SOCKS4 代理（无鉴权模式）---"
curl --fail --silent --show-error --max-time 15 \
    --socks4 "127.0.0.1:$SOCKS4_PORT" \
    "https://httpbin.org/get" -o /dev/null \
    || fail "SOCKS4 代理失败"

# ---------------------------------------------------------------------------
echo ""
echo "=== All real-network tests PASSED ==="
exit 0
