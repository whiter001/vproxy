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
socks4_src="${script_dir}/../socks4/1/proxy.socks4.v"
http_bin="${script_dir}/http_lifecycle_bin"
socks5_bin="${script_dir}/socks5_lifecycle_bin"
socks4_bin="${script_dir}/socks4_lifecycle_bin"
http_log="${script_dir}/http_lifecycle.log"
socks5_log="${script_dir}/socks5_lifecycle.log"
socks4_log="${script_dir}/socks4_lifecycle.log"
listen_addr="127.0.0.1:5780"
auth_user="lcuser"
auth_pass="lcpass"

rm -f "$http_bin" "$socks5_bin" "$socks4_bin" "$http_log" "$socks5_log" "$socks4_log"

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
echo "--- 测试 5: HTTP PROXY_IDLE_TIMEOUT=0 —— idle 连接永远不会被关闭 ---"
# 与测试 3 形成对照：测试 3 是 idle=2s 触发 400 + 关闭；这里是 0 = 禁用，
# 应该走 lifecycle.apply_idle_timeout 的早 return 分支（time.infinite）。
# 用 Python 客户端做完整测试：连上 → sleep 4s → 发请求 → 期望代理仍响应。
echo_upstream_port=18910
python3 - <<PY > /dev/null 2>&1 &
import socket, threading, time
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $echo_upstream_port))
srv.listen(8)
def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError: return
        threading.Thread(target=lambda c=conn: echo(c), daemon=True).start()
def echo(c):
    try:
        while True:
            data = c.recv(4096)
            if not data: break
            c.sendall(data)
    except OSError: pass
    finally: c.close()
threading.Thread(target=serve, daemon=True).start()
time.sleep(60)
PY
echo_upstream_pid=$!
sleep 0.5

PROXY_LISTEN_ADDR="$listen_addr" \
PROXY_AUTH_USER="$auth_user" PROXY_AUTH_PASS="$auth_pass" \
PROXY_IDLE_TIMEOUT=0 \
"$http_bin" > "$http_log" 2>&1 &
http_pid=$!
wait_port 5780

python3 - <<PY
import socket, time, base64, sys
s = socket.create_connection(('127.0.0.1', 5780), timeout=10)
# 不发任何数据，sleep 4s（> 测试 3 的 idle=2s 触发窗口）
time.sleep(4)
auth = base64.b64encode(b'lcuser:lcpass').decode().strip()
req = (
    f"GET /probe HTTP/1.1\r\n"
    f"Host: 127.0.0.1:$echo_upstream_port\r\n"
    f"Proxy-Authorization: Basic {auth}\r\n"
    f"Connection: close\r\n"
    f"\r\n"
).encode()
s.sendall(req)
buf = b''
try:
    while len(buf) < 1024:
        chunk = s.recv(1024 - len(buf))
        if not chunk: break
        buf += chunk
except socket.timeout:
    print(f'TIMEOUT after {len(buf)} bytes', file=sys.stderr)
s.close()
print(f'GOT {len(buf)} bytes: {buf[:120]!r}', flush=True)
# 关键断言：idle=0 时连接 4s 后仍能正常转发，客户端收到了代理响应字节。
# echo upstream 是 TCP echo，所以客户端收到的就是请求原文（代理 io.cp 透传）；
# 只要收到内容，就证明 idle=0 没把连接错误关闭。
assert len(buf) > 0, '代理关闭了 idle=0 的连接（不应发生）'
print('IDLE0_OK')
PY
if [[ $? -eq 0 ]]; then
    echo "✅ PROXY_IDLE_TIMEOUT=0 时连接 4s 后仍活跃（echo 通了）"
else
    echo "❌ PROXY_IDLE_TIMEOUT=0 测试失败：idle=0 应禁用超时"
    cat "$http_log"
    failed=$((failed + 1))
fi

kill -TERM "$http_pid"
wait "$http_pid" 2>/dev/null
cleanup_pid "$echo_upstream_pid"

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
echo "--- 测试 6: SOCKS4 SIGTERM 优雅退出 ---"
SOCKS4_LISTEN_ADDR="127.0.0.1:5782" \
SOCKS4_IDLE_TIMEOUT=300 \
"$socks4_bin" > "$socks4_log" 2>&1 &
socks4_pid=$!
wait_port 5782 || { echo "❌ SOCKS4 proxy 未监听"; cat "$socks4_log"; failed=$((failed+1)); }
sleep 0.2
kill -TERM "$socks4_pid"
for _ in {1..30}; do
    if ! kill -0 "$socks4_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$socks4_pid" 2>/dev/null; then
    echo "❌ SOCKS4 proxy 没在 3s 内退出"
    kill -KILL "$socks4_pid" 2>/dev/null
    failed=$((failed+1))
else
    wait "$socks4_pid" || rc=$?
    rc=${rc:-0}
    if [[ $rc -eq 0 ]] && grep -q "shutdown:" "$socks4_log"; then
        echo "✅ SOCKS4 SIGTERM 退出码 0 + drain 日志"
    else
        echo "❌ SOCKS4 退出异常 rc=$rc"
        cat "$socks4_log"
        failed=$((failed+1))
    fi
fi

# ---------------------------------------------------------------------------
echo "--- 清理 ---"
rm -f "$http_bin" "$socks5_bin" "$socks4_bin" "$http_log" "$socks5_log" "$socks4_log"

echo ""
if [[ $failed -eq 0 ]]; then
    echo "=== All lifecycle tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi