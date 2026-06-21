#!/usr/bin/env bash
# 回归测试：HTTP 代理在 dial 上游失败时返回 502 Bad Gateway。
#
# 覆盖 proxy.1.v 的 net.dial_tcp() 失败分支：
#   send_simple_response(mut socket, '502 Bad Gateway', ...)
#
# 用 127.0.0.1:1（基本不可能被占）模拟不可达上游，避免依赖网络。
# 关键：必须带 Basic Auth，否则会被 407 拦截看不到 502。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_bin="${script_dir}/proxy_upstream_502_bin"
log_file="${script_dir}/proxy_upstream_502.log"
listen_addr="127.0.0.1:5782"
user="upuser"
pass="uppass"
# Basic auth for "upuser:uppass"
auth_b64=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')

rm -f "$proxy_bin" "$log_file"

echo "--- 正在编译 ---"
v -o "$proxy_bin" "${script_dir}/proxy.1.v"

echo "--- 启动代理 ---"
PROXY_LISTEN_ADDR="$listen_addr" \
    PROXY_AUTH_USER="$user" PROXY_AUTH_PASS="$pass" \
    "$proxy_bin" > "$log_file" 2>&1 &
proxy_pid=$!

# 等端口可用
for _ in {1..50}; do
    if nc -z 127.0.0.1 5782 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 5782 >/dev/null 2>&1; then
    echo "❌ HTTP proxy 未监听 5782"
    cat "$log_file"
    exit 1
fi

failed=0

cleanup_pid() {
    [[ -n "${1:-}" ]] || return
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'cleanup_pid "$proxy_pid"; rm -f "$proxy_bin" "$log_file"' EXIT

# ---------------------------------------------------------------------------
echo "--- 测试 1: nc raw 请求应回 502 Bad Gateway ---"
# 故意把 GET 指向 :1（基本没人监听），走代理 → 触发 dial 失败 → 502
# 用 -w 5 给 nc 5s 收响应（代理 close 后 nc 也退出）
response=$(printf 'GET http://127.0.0.1:1/ping HTTP/1.1\r\nHost: 127.0.0.1:1\r\nProxy-Authorization: Basic %s\r\nConnection: close\r\n\r\n' \
    "$auth_b64" | nc -w 5 127.0.0.1 5782 2>/dev/null || true)

if echo "$response" | grep -q '502 Bad Gateway'; then
    echo "✅ 收到 502 Bad Gateway 响应"
else
    echo "❌ 未收到 502，代理响应如下："
    echo "$response" | head -10
    echo "--- proxy 日志 ---"
    cat "$log_file"
    failed=$((failed + 1))
fi

if echo "$response" | grep -q 'Upstream connection failed'; then
    echo "✅ 502 body 含 'Upstream connection failed' 解释"
else
    echo "❌ 502 body 缺少上游失败原因"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: curl 也应看到 502 ---"
status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    --proxy-user "${user}:${pass}" \
    -x "http://${listen_addr}" \
    "http://127.0.0.1:1/refused" 2>/dev/null || echo "TIMEOUT")

if [[ "$status" == "502" ]]; then
    echo "✅ curl 看到 502"
else
    echo "❌ curl 看到 $status（期望 502）"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: 不带 auth 仍应被 407 拦截（确认我们走的不是未鉴权路径） ---"
status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    -x "http://${listen_addr}" \
    "http://127.0.0.1:1/refused" 2>/dev/null || echo "TIMEOUT")

if [[ "$status" == "407" ]]; then
    echo "✅ 无 auth → 407（确认鉴权在 502 之前生效）"
else
    echo "❌ 无 auth 应得到 407，实际 $status"
    failed=$((failed + 1))
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All 502 tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi
