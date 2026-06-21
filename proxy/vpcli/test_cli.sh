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
echo "--- 测试 9: HTTP -u/-p 覆盖 PROXY_AUTH_USER/PASS env ---"
# 关键：CLI 的 user/pass 必须能赢过 env
PROXY_LISTEN_ADDR=127.0.0.1:9995 \
PROXY_AUTH_USER=env_user PROXY_AUTH_PASS=env_pass \
"$http_bin" -l 127.0.0.1:9995 -u cli_user -p cli_pass > /tmp/cli_h.log 2>&1 &
pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 9995 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 9995 >/dev/null 2>&1; then
    echo "❌ 代理未监听 9995"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
else
    # 起一个本地 echo upstream（Python）
    python3 - <<PY > /dev/null 2>&1 &
import http.server, socketserver, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(("127.0.0.1", 18099), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
import time; time.sleep(30)
PY
    upstream_pid=$!
    sleep 0.5

    # 用 CLI 凭据 cli_user:cli_pass 应得 200（证明 CLI 覆盖 env）
    status_cli=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        --proxy-user "cli_user:cli_pass" \
        -x "http://127.0.0.1:9995" \
        "http://127.0.0.1:18099/check" 2>/dev/null || echo "TIMEOUT")
    # 用 env 凭据 env_user:env_pass 应得 407（证明 CLI 把 env 覆盖了）
    status_env=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        --proxy-user "env_user:env_pass" \
        -x "http://127.0.0.1:9995" \
        "http://127.0.0.1:18099/check" 2>/dev/null || echo "TIMEOUT")

    if [[ "$status_cli" == "200" ]]; then
        echo "✅ -u/-p 凭据生效（CLI 凭据通过）"
    else
        echo "❌ CLI 凭据未生效：$status_cli（期望 200）"
        failed=$((failed + 1))
    fi
    if [[ "$status_env" == "407" ]]; then
        echo "✅ env 凭据被 CLI 覆盖（env_user 应失败）"
    else
        echo "❌ env 凭据未被覆盖：$status_env（期望 407）"
        failed=$((failed + 1))
    fi

    cleanup_pid "$upstream_pid"
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 10: HTTP --no-auth（无需 PROXY_REQUIRE_AUTH=0） ---"
# 关键：CLI -n 必须能关闭鉴权，且不依赖 env
unset PROXY_AUTH_USER PROXY_AUTH_PASS PROXY_AUTH_BASIC PROXY_REQUIRE_AUTH
PROXY_LISTEN_ADDR=127.0.0.1:9996 \
"$http_bin" -l 127.0.0.1:9996 -n > /tmp/cli_h.log 2>&1 &
pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 9996 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 9996 >/dev/null 2>&1; then
    echo "❌ 代理未监听 9996"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
else
    # 检查日志里有 WARN 提示
    if grep -q 'authentication disabled' /tmp/cli_h.log; then
        echo "✅ -n 关闭鉴权（日志含 WARN）"
    else
        echo "❌ 日志缺少 'authentication disabled' 提示"
        cat /tmp/cli_h.log
        failed=$((failed + 1))
    fi
    # 不带凭据 curl 应得 200 / 404 / 502（非 407）—— 关键是鉴权已通过，
    # 不被 407 拦截。状态码本身取决于 upstream 是否存在（前面的测试 9 cleanup 过）。
    status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        -x "http://127.0.0.1:9996" \
        "http://127.0.0.1:18099/noauth" 2>/dev/null || echo "TIMEOUT")
    if [[ "${status:-TIMEOUT}" != "407" ]]; then
        echo "✅ -n 后无凭据不被 407 拦截（status=${status:-?}）"
    else
        echo "❌ -n 后无凭据应通过鉴权，状态码 ${status:-?}"
        failed=$((failed + 1))
    fi
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 11: SOCKS5 --no-auth（无需 SOCKS5_NO_AUTH=1） ---"
unset SOCKS5_AUTH_USERNAME SOCKS5_AUTH_PASSWORD SOCKS5_NO_AUTH
"$socks5_bin" -l 127.0.0.1:9997 -n > /tmp/cli_s.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'SOCKS5 proxy listening on 127.0.0.1:9997' /tmp/cli_s.log; then
    echo "✅ SOCKS5 -n 启动成功"
else
    echo "❌ SOCKS5 -n 启动失败"
    cat /tmp/cli_s.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 12: SOCKS5_NO_AUTH=1 绕过 SOCKS5_AUTH_USERNAME/PASSWORD ---"
# 关键：即使设了 user/pass env，SOCKS5_NO_AUTH=1 应允许 no-auth 客户端
SOCKS5_AUTH_USERNAME=env_u SOCKS5_AUTH_PASSWORD=env_p \
SOCKS5_NO_AUTH=1 \
"$socks5_bin" -l 127.0.0.1:9998 > /tmp/cli_s.log 2>&1 &
pid=$!
sleep 0.8
# Python 客户端用 no-auth 应能进 greeting
python3 - <<PY
import socket, sys
try:
    s = socket.create_connection(('127.0.0.1', 9998), timeout=3)
    s.sendall(b'\x05\x01\x00')
    rep = s.recv(2)
    if rep == b'\x05\x00':
        print('NOAUTH_OK')
    else:
        print(f'NOAUTH_FAIL: rep={rep!r}', file=sys.stderr)
        sys.exit(1)
finally:
    s.close()
PY
noauth_rc=$?
if [[ $noauth_rc -eq 0 ]]; then
    echo "✅ SOCKS5_NO_AUTH=1 允许免认证（即便 env 设了 user/pass）"
else
    echo "❌ SOCKS5_NO_AUTH=1 未生效"
    cat /tmp/cli_s.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 13: HTTP -b 覆盖 PROXY_AUTH_BASIC ---"
# 起一个本地 echo upstream（前面测试 9/10 cleanup 过）
python3 - <<PY > /dev/null 2>&1 &
import http.server, socketserver, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(("127.0.0.1", 18100), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
import time; time.sleep(30)
PY
upstream_pid=$!
sleep 0.5

unset PROXY_AUTH_USER PROXY_AUTH_PASS PROXY_AUTH_BASIC PROXY_REQUIRE_AUTH
# basic = base64("cli_user:cli_pass")
basic_b64=$(printf 'cli_user:cli_pass' | base64 | tr -d '\n')
PROXY_LISTEN_ADDR=127.0.0.1:9999 \
PROXY_AUTH_BASIC="d3JvbmdfdXNlcjp3cm9uZ19wYXNz" \
"$http_bin" -l 127.0.0.1:9999 -b "$basic_b64" > /tmp/cli_h.log 2>&1 &
pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 9999 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 9999 >/dev/null 2>&1; then
    echo "❌ 代理未监听 9999"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
else
    # 用 CLI basic 凭据（cli_user:cli_pass）应得 200
    status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        --proxy-user "cli_user:cli_pass" \
        -x "http://127.0.0.1:9999" \
        "http://127.0.0.1:18100/bcheck" 2>/dev/null)
    # 用 env basic 凭据（wrong_user:wrong_pass）应得 407
    status_wrong=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        --proxy-user "wrong_user:wrong_pass" \
        -x "http://127.0.0.1:9999" \
        "http://127.0.0.1:18100/bcheck" 2>/dev/null)

    if [[ "${status:-?}" == "200" ]]; then
        echo "✅ -b 凭据生效（CLI basic 通过）"
    else
        echo "❌ CLI basic 凭据未生效：${status:-?}（期望 200）"
        failed=$((failed + 1))
    fi
    if [[ "${status_wrong:-?}" == "407" ]]; then
        echo "✅ env basic 被 CLI 覆盖"
    else
        echo "❌ env basic 未被覆盖：${status_wrong:-?}（期望 407）"
        failed=$((failed + 1))
    fi
fi
cleanup_pid "$pid"
cleanup_pid "$upstream_pid"

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