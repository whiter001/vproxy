#!/usr/bin/env bash
# issue #4 回归测试：HTTP + SOCKS5 代理的 CLI 参数解析；issue #6 TOML 配置文件。
#
# 覆盖：
#   1. --help / --version  退出码 0 + 输出
#   2. -l <addr>           覆盖 PROXY_LISTEN_ADDR（CLI > env）
#   3. PROXY_LISTEN_ADDR   env 变量生效
#   4. 未识别选项          退出码 1
#   5. 显式子命令 serve    与省略等价
#   6. SOCKS5 同样行为
#   7. --config TOML 加载 + 生效配置日志（密码打码）
#   8. CLI > env > file > default 四级优先级
#   9. 坏 TOML / 未知键 fail-fast（退出码非 0 + path:line）
#  10. SOCKS5 文件 auth 接线（正确凭据放行 / 错误凭据拒绝）

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
http_bin="${script_dir}/../http/1/proxy_cli_test_bin"
socks5_bin="${script_dir}/../socks5/1/proxy_cli_test_bin"
socks4_bin="${script_dir}/../socks4/1/proxy_cli_test_bin"
http_src="${script_dir}/../http/1/proxy.1.v"
socks5_src="${script_dir}/../socks5/1/proxy.socks5.v"
socks4_src="${script_dir}/../socks4/1/proxy.socks4.v"

rm -f "$http_bin" "$socks5_bin" "$socks4_bin"

echo "--- 正在编译 ---"
v -o "$http_bin" "$http_src"
v -o "$socks5_bin" "$socks5_src"
v -o "$socks4_bin" "$socks4_src"

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
echo "--- 测试 12: SOCKS5_NO_AUTH 覆盖配置的 user/pass ---"
SOCKS5_AUTH_USERNAME=env_u SOCKS5_AUTH_PASSWORD=env_p \
SOCKS5_NO_AUTH=1 \
"$socks5_bin" -l 127.0.0.1:9998 > /tmp/cli_s.log 2>&1 &
pid=$!
sleep 0.8
# Python 客户端用 no-auth 应被接受（0x00）
python3 - <<PY
import socket, sys
try:
    s = socket.create_connection(('127.0.0.1', 9998), timeout=3)
    s.sendall(b'\x05\x01\x00')
    rep = s.recv(2)
    if rep == b'\x05\x00':
        print('NOAUTH_ACCEPTED')
    else:
        print(f'NOAUTH_REJECTED: rep={rep!r}', file=sys.stderr)
        sys.exit(1)
finally:
    s.close()
PY
noauth_rc=$?
if [[ $noauth_rc -eq 0 ]]; then
    echo "✅ SOCKS5_NO_AUTH=1 覆盖 user/pass，no-auth 客户端获 0x00"
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
echo "--- 测试 14: SOCKS4 --help ---"
output=$("$socks4_bin" --help 2>&1)
if echo "$output" | grep -q 'vproxy socks4 serve' && echo "$output" | grep -q -- '-l, --listen' \
    && echo "$output" | grep -q -- '-u, --user'; then
    echo "✅ SOCKS4 --help OK"
else
    echo "❌ SOCKS4 --help 异常"
    echo "$output" | head -5
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 15: SOCKS4 -l 覆盖 SOCKS4_LISTEN_ADDR ---"
SOCKS4_LISTEN_ADDR=127.0.0.1:8800 SOCKS4_NO_AUTH=1 \
"$socks4_bin" -l 127.0.0.1:9991 > /tmp/cli_s4.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'SOCKS4 proxy listening on 127.0.0.1:9991' /tmp/cli_s4.log; then
    echo "✅ SOCKS4 -l 覆盖 env"
else
    echo "❌ SOCKS4 -l 未覆盖 env"
    cat /tmp/cli_s4.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 16: SOCKS4 SOCKS4_LISTEN_ADDR env 生效 ---"
SOCKS4_LISTEN_ADDR=127.0.0.1:9992 SOCKS4_NO_AUTH=1 \
"$socks4_bin" > /tmp/cli_s4.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'SOCKS4 proxy listening on 127.0.0.1:9992' /tmp/cli_s4.log; then
    echo "✅ SOCKS4_LISTEN_ADDR env 生效"
else
    echo "❌ SOCKS4 env 未生效"
    cat /tmp/cli_s4.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 17: SOCKS4 --no-auth（无需 SOCKS4_NO_AUTH=1） ---"
unset SOCKS4_AUTH_USER SOCKS4_NO_AUTH
"$socks4_bin" -l 127.0.0.1:9993 -n > /tmp/cli_s4.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'SOCKS4 proxy listening on 127.0.0.1:9993' /tmp/cli_s4.log; then
    echo "✅ SOCKS4 -n 启动成功"
else
    echo "❌ SOCKS4 -n 启动失败"
    cat /tmp/cli_s4.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 18: SOCKS4_NO_AUTH=1 允许任意 USERID ---"
# 即使设了 SOCKS4_AUTH_USER=alice，SOCKS4_NO_AUTH=1 应让 bob 也通过
SOCKS4_AUTH_USER=alice SOCKS4_NO_AUTH=1 \
"$socks4_bin" -l 127.0.0.1:9994 > /tmp/cli_s4.log 2>&1 &
pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 9994 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
python3 - <<PY
import socket
s = socket.create_connection(('127.0.0.1', 9994), timeout=3)
# 发 bob（非 alice），SOCKS4_NO_AUTH=1 应放行
import struct
req = b'\x04\x01' + struct.pack('>H', 80) + bytes([127,0,0,1]) + b'bob\x00'
s.sendall(req)
reply = s.recv(8)
# 期望 0x5A 或 0x5B（取决于上游是否通），关键是 verifier 不阻止。
# 用 unreachable 端口 1 保证 0x5B，但证明 SOCKS4_NO_AUTH 旁路了 USERID 检查。
if reply[1] in (0x5A, 0x5B):
    print(f'USERID_BYPASS_OK cd={reply[1]:#x}')
else:
    raise SystemExit(f'expected 0x5A/0x5B, got {reply.hex()}')
s.close()
PY
if [[ $? -eq 0 ]]; then
    echo "✅ SOCKS4_NO_AUTH=1 旁路 USERID 校验"
else
    echo "❌ SOCKS4_NO_AUTH=1 未旁路"
    cat /tmp/cli_s4.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
# issue #6：TOML 配置文件
echo "--- 测试 19: HTTP --config 加载 TOML + 生效配置日志（密码打码） ---"
cat > /tmp/proxy_cfg_test.toml <<'TOML'
listen = "127.0.0.1:10091"
auth = { user = "alice", password = "secret" }
log = { level = "info", format = "text" }
metrics_addr = "127.0.0.1:9090"
idle_timeout_seconds = 300

[rules]
allow = ["*.example.com"]
deny = ["evil.test"]
TOML
unset PROXY_LISTEN_ADDR PROXY_AUTH_USER PROXY_AUTH_PASS PROXY_AUTH_BASIC PROXY_REQUIRE_AUTH
"$http_bin" --config /tmp/proxy_cfg_test.toml > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
ok=1
grep -q 'Config loaded from /tmp/proxy_cfg_test.toml' /tmp/cli_h.log || ok=0
grep -q -- '--- Effective config (http) ---' /tmp/cli_h.log || ok=0
grep -q 'listen = 127.0.0.1:10091' /tmp/cli_h.log || ok=0
grep -q 'auth.user = alice' /tmp/cli_h.log || ok=0
grep -Fq 'auth.password = ******' /tmp/cli_h.log || ok=0
grep -q 'metrics_addr = 127.0.0.1:9090' /tmp/cli_h.log || ok=0
grep -q 'rules.allow' /tmp/cli_h.log || ok=0
if [[ $ok -eq 1 ]]; then
    echo "✅ --config 加载 + 生效配置日志 + 密码打码"
else
    echo "❌ --config 加载异常"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 20: 优先级 CLI > env > file ---"
# file=10091, env=10092, CLI=10093
PROXY_LISTEN_ADDR=127.0.0.1:10092 \
PROXY_AUTH_USER=u PROXY_AUTH_PASS=p \
"$http_bin" --config /tmp/proxy_cfg_test.toml > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'Listen on 127.0.0.1:10092' /tmp/cli_h.log; then
    echo "✅ env 覆盖 file（env > file）"
else
    echo "❌ env 未覆盖 file"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

PROXY_LISTEN_ADDR=127.0.0.1:10092 \
PROXY_AUTH_USER=u PROXY_AUTH_PASS=p \
"$http_bin" --config /tmp/proxy_cfg_test.toml -l 127.0.0.1:10093 > /tmp/cli_h.log 2>&1 &
pid=$!
sleep 0.8
if grep -q 'Listen on 127.0.0.1:10093' /tmp/cli_h.log; then
    echo "✅ CLI 覆盖 env（CLI > env > file）"
else
    echo "❌ CLI 未覆盖 env"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 测试 21: 坏 TOML 语法 fail-fast（非零退出 + path:line） ---"
printf 'listen = "1"\n[auth\nuser="x"\n' > /tmp/proxy_bad.toml
unset PROXY_LISTEN_ADDR PROXY_AUTH_USER PROXY_AUTH_PASS PROXY_AUTH_BASIC
"$http_bin" --config /tmp/proxy_bad.toml > /tmp/cli_h.log 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q '/tmp/proxy_bad.toml:2:' /tmp/cli_h.log; then
    echo "✅ 坏 TOML 退出码 $rc 且报 path:line"
else
    echo "❌ 坏 TOML 未 fail-fast rc=$rc"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 22: 未知键 fail-fast（非零退出 + path:line） ---"
printf 'listen = "127.0.0.1:10091"\nbogus_key = "x"\n' > /tmp/proxy_unknown.toml
"$http_bin" --config /tmp/proxy_unknown.toml > /tmp/cli_h.log 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q '/tmp/proxy_unknown.toml:2:' /tmp/cli_h.log \
    && grep -q 'unknown key "bogus_key"' /tmp/cli_h.log; then
    echo "✅ 未知键退出码 $rc 且报 path:line + 键名"
else
    echo "❌ 未知键未 fail-fast rc=$rc"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 23: 类型错误 fail-fast（int 当 string） ---"
printf 'listen = "127.0.0.1:10091"\nmetrics_addr = 123\n' > /tmp/proxy_type.toml
"$http_bin" --config /tmp/proxy_type.toml > /tmp/cli_h.log 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q '/tmp/proxy_type.toml:2:' /tmp/cli_h.log \
    && grep -q 'must be a string' /tmp/cli_h.log; then
    echo "✅ 类型错误退出码 $rc 且报 path:line"
else
    echo "❌ 类型错误未 fail-fast rc=$rc"
    cat /tmp/cli_h.log
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------------------
echo "--- 测试 24: SOCKS5 文件 auth 接线（正确凭据放行 / 错误凭据拒绝） ---"
cat > /tmp/proxy_socks5_cfg.toml <<'TOML'
listen = "127.0.0.1:10094"
auth = { user = "alice", password = "secret" }
idle_timeout_seconds = 60
TOML
unset SOCKS5_AUTH_USERNAME SOCKS5_AUTH_PASSWORD SOCKS5_NO_AUTH
"$socks5_bin" --config /tmp/proxy_socks5_cfg.toml > /tmp/cli_s.log 2>&1 &
pid=$!
for _ in {1..50}; do
    if nc -z 127.0.0.1 10094 >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 10094 >/dev/null 2>&1; then
    echo "❌ SOCKS5 未监听 10094"
    cat /tmp/cli_s.log
    failed=$((failed + 1))
else
    # 生效配置日志：password 打码 + idle_timeout 来自文件
    if grep -Fq 'auth.password = ******' /tmp/cli_s.log \
        && grep -q 'idle_timeout_seconds = 60' /tmp/cli_s.log; then
        echo "✅ SOCKS5 生效配置日志（password 打码 + idle_timeout=60）"
    else
        echo "❌ SOCKS5 生效配置日志缺失"
        cat /tmp/cli_s.log
        failed=$((failed + 1))
    fi
    python3 - <<PY
import socket, sys
# 错误凭据应被拒绝（0x01）
s = socket.create_connection(('127.0.0.1', 10094), timeout=3)
s.sendall(b'\x05\x01\x02')
rep = s.recv(2)
if rep != b'\x05\x02':
    print(f'expected userpass method, got {rep!r}', file=sys.stderr); sys.exit(1)
s.sendall(b'\x01\x05alice\x06wrong!')
rep = s.recv(2)
if rep != b'\x01\x01':
    print(f'expected auth failure 0x01, got {rep!r}', file=sys.stderr); sys.exit(1)
s.close()
# 正确凭据应放行（0x00），随后 connect 到 unreachable 端口应得 rep 5
s = socket.create_connection(('127.0.0.1', 10094), timeout=3)
s.sendall(b'\x05\x01\x02')
rep = s.recv(2)
s.sendall(b'\x01\x05alice\x06secret')
rep = s.recv(2)
if rep != b'\x01\x00':
    print(f'expected auth ok 0x00, got {rep!r}', file=sys.stderr); sys.exit(1)
s.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x01')
rep = s.recv(4)
if len(rep) < 2 or rep[1] != 5:
    print(f'expected reply 5 (conn refused), got {rep!r}', file=sys.stderr); sys.exit(1)
s.close()
print('SOCKS5_FILE_AUTH_OK')
PY
    if [[ $? -eq 0 ]]; then
        echo "✅ SOCKS5 文件 auth 接线生效（错误拒绝 / 正确放行）"
    else
        echo "❌ SOCKS5 文件 auth 接线异常"
        cat /tmp/cli_s.log
        failed=$((failed + 1))
    fi
fi
cleanup_pid "$pid"

# ---------------------------------------------------------------------------
echo "--- 清理 ---"
rm -f "$http_bin" "$socks5_bin" "$socks4_bin" /tmp/cli_h.log /tmp/cli_s.log /tmp/cli_s4.log
rm -f /tmp/proxy_cfg_test.toml /tmp/proxy_socks5_cfg.toml /tmp/proxy_bad.toml /tmp/proxy_unknown.toml /tmp/proxy_type.toml
pkill -f h_check 2>/dev/null
pkill -f s_check 2>/dev/null
pkill -f s4_check 2>/dev/null

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All CLI tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi
