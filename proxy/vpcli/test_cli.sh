#!/usr/bin/env bash
# issue #4 回归测试：HTTP + SOCKS5 代理的 CLI 参数解析。
#
# 覆盖：
#   1. --help / --version  退出码 0 + 输出
#   2. -l <addr>           覆盖 PROXY_LISTEN_ADDR（CLI > env）
#   3. PROXY_LISTEN_ADDR   env 变量生效
#   4. 未识别选项          退出码 1
#   5. 显式子命令 serve    与省略等价
#   6. SOCKS5 同样行为

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
http_bin="${script_dir}/../http/1/proxy_cli_test_bin"
socks5_bin="${script_dir}/../socks5/1/proxy_cli_test_bin"
http_src="${script_dir}/../http/1/proxy.1.v"
socks5_src="${script_dir}/../socks5/1/proxy.socks5.v"

rm -f "$http_bin" "$socks5_bin"

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

# ---------------------------------------------------------------------------
echo "--- 测试 1: HTTP --help ---"
output=$("$http_bin" --help 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'vproxy http serve' && echo "$output" | grep -q -- '-l, --listen'; then
    echo "✅ HTTP --help 退出码 0 且包含 usage"
else
    echo "❌ HTTP --help rc=$rc"
    echo "$output" | head -5
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 2: HTTP --version ---"
output=$("$http_bin" --version 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'vproxy 0.'; then
    echo "✅ HTTP --version 输出 vproxy X.Y.Z"
else
    echo "❌ HTTP --version rc=$rc output=$output"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 3: HTTP -l 覆盖 PROXY_LISTEN_ADDR ---"
PROXY_LISTEN_ADDR=127.0.0.1:8888 \
PROXY_AUTH_USER=u PROXY_AUTH_PASS=p \
"$http_bin" -l 127.0.0.1:9991 > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'Listen on 127.0.0.1:9991' /tmp/cli_h.log; then
    echo "✅ -l 覆盖 env（CLI > env 优先级）"
else
    echo "❌ -l 未覆盖 env"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 4: HTTP 仅设 PROXY_LISTEN_ADDR ---"
PROXY_LISTEN_ADDR=127.0.0.1:9992 \
PROXY_AUTH_USER=u PROXY_AUTH_PASS=p \
"$http_bin" > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'Listen on 127.0.0.1:9992' /tmp/cli_h.log; then
    echo "✅ PROXY_LISTEN_ADDR env 生效"
else
    echo "❌ env 未生效"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 5: HTTP 未识别选项 ---"
"$http_bin" --totally-unknown > /tmp/cli_h.log 2>&1
rc=$?
# finalize 失败会调用 eprintln + 返回 error，main 走 C.exit(1)
if [[ $rc -ne 0 ]] && grep -qi 'unknown\|Usage:' /tmp/cli_h.log; then
    echo "✅ 未识别选项退出码 ${rc} 且打印 usage"
else
    echo "❌ 未识别选项 rc=$rc"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 6: HTTP 显式子命令 serve ---"
PROXY_AUTH_USER=u PROXY_AUTH_PASS=p "$http_bin" serve -l 127.0.0.1:9993 > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'Listen on 127.0.0.1:9993' /tmp/cli_h.log; then
    echo "✅ 显式 'serve' 子命令与省略等价"
else
    echo "❌ 'serve' 子命令未生效"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 7: HTTP 未识别子命令 ---"
"$http_bin" frobnicate > /tmp/cli_h.log 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q 'unknown subcommand' /tmp/cli_h.log; then
    echo "✅ 未识别子命令退出码 ${rc}"
else
    echo "❌ 未识别子命令 rc=$rc"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 8: SOCKS5 --help / -l ---"
output=$("$socks5_bin" --help 2>&1)
if echo "$output" | grep -q 'vproxy socks5 serve' && echo "$output" | grep -q -- '-l, --listen'; then
    echo "✅ SOCKS5 --help OK"
else
    echo "❌ SOCKS5 --help 异常"
    echo "$output" | head -5
    failed=$((failed + 1))
fi

"$socks5_bin" -l 127.0.0.1:9994 > /tmp/cli_s.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'SOCKS5 proxy listening on 127.0.0.1:9994' /tmp/cli_s.log; then
    echo "✅ SOCKS5 -l 生效"
else
    echo "❌ SOCKS5 -l 未生效"
    cat /tmp/cli_s.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 清理 ---"
rm -f "$http_bin" "$socks5_bin" /tmp/cli_h.log /tmp/cli_s.log
pkill -f h_check 2>/dev/null
pkill -f s_check 2>/dev/null

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All CLI tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi