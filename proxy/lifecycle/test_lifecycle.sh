#!/usr/bin/env bash
# issue #5 回归测试：HTTP + SOCKS5 代理的 lifecycle 行为。
#
# 覆盖：
#   1. SIGTERM 后优雅退出（退出码 0、drain 提示、不会卡住）
#   2. SO_REUSEADDR 默认开启：杀掉代理后立即重启不报 address already in use
#   3. idle timeout：静默连接在超时内被关闭（read 端先 EOF）
#
# 备注：
#   - TCP_NODELAY 由 V 标准库默认开启（vlib/net/tcp.c.v:673），
#     抓包验证需要 root/tcpdump，本测试不强制覆盖；SO_REUSEADDR 同理。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
http_src="${script_dir}/../http/1/proxy.1.v"
socks5_src="${script_dir}/../socks5/1/proxy.socks5.v"
http_bin="${script_dir}/http_lifecycle_bin"
socks5_bin="${script_dir}/socks5_lifecycle_bin"
http_log="${script_dir}/http_lifecycle.log"
socks5_log="${script_dir}/socks5_lifecycle.log"
listen_addr="127.0.0.1:5780"
auth_user="lcuser"
auth_pass="lcpass"

rm -f "$http_bin" "$socks5_bin" "$http_log" "$socks5_log"

echo "--- 正在编译 ---"
v -o "$http_bin" "$http_src"
v -o "$socks5_bin" "$socks5_src"

failed=0

cleanup_pid() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

wait_port() {
    local port="$1"
    for _ in {1..50}; do
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}

wait_port_free() {
    local port="$1"
    for _ in {1..50}; do
        if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}

# ---------------------------------------------------------------------------
echo "--- 测试 1: HTTP SIGTERM 优雅退出（退出码 0 + drain 日志）---"
PROXY_LISTEN_ADDR="$listen_addr" \
PROXY_AUTH_USER="$auth_user" PROXY_AUTH_PASS="$auth_pass" \
"$http_bin" > "$http_log" 2>&1 &
http_pid=$!
wait_port 5780 || { echo "❌ HTTP proxy 未监听"; cat "$http_log"; failed=$((failed+1)); }

# 让它在监听状态下呆一会
sleep 0.3
kill -TERM "$http_pid"
# 给 3s 让它优雅退出
for _ in {1..30}; do
    if ! kill -0 "$http_pid" 2>/dev/null; then break; fi
    sleep 0.1
done

if kill -0 "$http_pid" 2>/dev/null; then
    echo "❌ HTTP proxy 没在 3s 内退出"
    kill -KILL "$http_pid" 2>/dev/null
    failed=$((failed+1))
else
    wait "$http_pid" || rc=$?
    rc=${rc:-0}
    if [[ $rc -eq 0 ]]; then
        echo "✅ HTTP SIGTERM 退出码 0"
    else
        echo "❌ HTTP SIGTERM 退出码 $rc（期望 0）"
        failed=$((failed+1))
    fi
    if grep -q "shutdown:" "$http_log"; then
        echo "✅ drain 日志存在"
    else
        echo "❌ 缺少 shutdown: 日志"
        cat "$http_log"
        failed=$((failed+1))
    fi
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: HTTP SO_REUSEADDR —— 杀掉立即重启不冲突 ---"
# 第一次启动 + 立即杀掉（保留 TIME_WAIT 套接字）
PROXY_LISTEN_ADDR="$listen_addr" \
PROXY_AUTH_USER="$auth_user" PROXY_AUTH_PASS="$auth_pass" \
"$http_bin" > "$http_log" 2>&1 &
first_pid=$!
wait_port 5780
kill -TERM "$first_pid"
wait "$first_pid" 2>/dev/null

# 立即重启，应该能 bind 同一端口（SO_REUSEADDR 兜住 TIME_WAIT）
PROXY_LISTEN_ADDR="$listen_addr" \
PROXY_AUTH_USER="$auth_user" PROXY_AUTH_PASS="$auth_pass" \
"$http_bin" > "$http_log" 2>&1 &
second_pid=$!
if wait_port 5780; then
    echo "✅ SO_REUSEADDR 生效：杀掉后立即重启成功"
else
    echo "❌ 端口仍被占用（SO_REUSEADDR 未生效？）"
    cat "$http_log"
    failed=$((failed+1))
fi
cleanup_pid "$second_pid"
wait_port_free 5780

# ---------------------------------------------------------------------------
echo "--- 测试 3: HTTP idle timeout —— 静默连接在超时内被关闭 ---"
PROXY_LISTEN_ADDR="$listen_addr" \
PROXY_AUTH_USER="$auth_user" PROXY_AUTH_PASS="$auth_pass" \
PROXY_IDLE_TIMEOUT=2 \
"$http_bin" > "$http_log" 2>&1 &
http_pid=$!
wait_port 5780

# 开一个 TCP 连接但不发送任何 HTTP 数据。代理的 read_request_head 会在
# ~2s 后超时，发送 400 Bad Request 后关闭连接。
exec 9<>/dev/tcp/127.0.0.1/5780 || true
# 给 4s（超时 2s + 关闭 + 1s 余量）
sleep 4

# 把代理回写的所有字节读完，然后看 read 是否拿到 EOF
timeout_data=$(timeout 2 cat <&9 2>/dev/null | wc -c)
exec 9<&- 2>/dev/null || true
exec 9>&- 2>/dev/null || true

# 期望：代理发了 400 响应（~100 字节），然后关闭。我们至少要看到一些字节
# 且之后不能再读到更多（已经 EOF / 端口已关）。
if [[ "$timeout_data" -ge 50 ]] && grep -q "Client handled in 2" "$http_log"; then
    echo "✅ idle 客户端在 ~2s 后被关闭（代理发了 400 后断开，读到 ${timeout_data} 字节响应）"
else
    echo "❌ idle timeout 行为异常：读到 ${timeout_data} 字节，log 中无 2s 处理记录"
    cat "$http_log"
    failed=$((failed+1))
fi

kill -TERM "$http_pid"
wait "$http_pid" 2>/dev/null

# ---------------------------------------------------------------------------
echo "--- 测试 4: SOCKS5 SIGTERM 优雅退出 ---"
SOCKS5_LISTEN_ADDR="127.0.0.1:5781" \
SOCKS5_IDLE_TIMEOUT=300 \
"$socks5_bin" > "$socks5_log" 2>&1 &
socks5_pid=$!
wait_port 5781 || { echo "❌ SOCKS5 proxy 未监听"; cat "$socks5_log"; failed=$((failed+1)); }
sleep 0.2
kill -TERM "$socks5_pid"
for _ in {1..30}; do
    if ! kill -0 "$socks5_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$socks5_pid" 2>/dev/null; then
    echo "❌ SOCKS5 proxy 没在 3s 内退出"
    kill -KILL "$socks5_pid" 2>/dev/null
    failed=$((failed+1))
else
    wait "$socks5_pid" || rc=$?
    rc=${rc:-0}
    if [[ $rc -eq 0 ]] && grep -q "shutdown:" "$socks5_log"; then
        echo "✅ SOCKS5 SIGTERM 退出码 0 + drain 日志"
    else
        echo "❌ SOCKS5 退出异常 rc=$rc"
        cat "$socks5_log"
        failed=$((failed+1))
    fi
fi

# ---------------------------------------------------------------------------
echo "--- 清理 ---"
rm -f "$http_bin" "$socks5_bin" "$http_log" "$socks5_log"

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All lifecycle tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi