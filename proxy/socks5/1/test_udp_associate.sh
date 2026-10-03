#!/bin/bash
# lifecycle 模块使用 __global 可变全局变量，编译代理需 -enable-globals
case " ${VFLAGS:-} " in
  *" -enable-globals "*) ;;
  *) export VFLAGS="${VFLAGS:-} -enable-globals" ;;
esac
# 自动测试脚本：验证 issue #26 SOCKS5 UDP ASSOCIATE（RFC 1928 §4.3）。
# 拓扑：python UDP echo server + socks5 代理 + python UDP 客户端；全部本地。

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

WORK_DIR="$(mktemp -d)"
# 注意：proxy/socks5/1/proxy.socks5 是仓库跟踪的预编译二进制，二进制输出必须放到 WORK_DIR
SOCKS5_BINARY="$WORK_DIR/proxy_socks5_bin"
SOCKS5_SRC="./proxy.socks5.v"

PROXY_PORT=5960
PROXY_PORT_DENY=5961
ECHO_PORT=18087

PIDS=""
failed=0

cleanup() {
    echo "--- 清理 ---"
    # Windows Git Bash 对原生 exe 的 SIGTERM 可能不生效，统一 kill -9
    for pid in $PIDS; do
        kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
    rm -f "$SOCKS5_BINARY"
}
trap cleanup EXIT

# Windows 上 python3 可能是 Microsoft Store 占位 stub，探测后回退到 python
if python3 -c "" >/dev/null 2>&1; then
    PY=python3
else
    PY=python
fi

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

check() {
    # check <名称> <python 退出码>
    name="$1"
    rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        echo "✅ $name"
    else
        echo "❌ $name"
        failed=$((failed + 1))
    fi
}

echo "--- 正在编译 ---"
v -o "$SOCKS5_BINARY" "$SOCKS5_SRC" || exit 1

echo "--- 启动 UDP echo 上游 ---"
ECHO_PORT="$ECHO_PORT" "$PY" - > "$WORK_DIR/echo.log" 2>&1 <<'PY' &
import os
import socket

srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(os.environ["ECHO_PORT"])))
while True:
    data, addr = srv.recvfrom(65535)
    srv.sendto(data, addr)
PY
PIDS="$PIDS $!"
sleep 0.5

echo "--- 启动 SOCKS5 代理（带认证） ---"
SOCKS5_AUTH_USERNAME="u" SOCKS5_AUTH_PASSWORD="p" SOCKS5_LISTEN_ADDR="127.0.0.1:$PROXY_PORT" \
    SOCKS5_IDLE_TIMEOUT=30 \
    "$SOCKS5_BINARY" > "$WORK_DIR/proxy.log" 2>&1 &
PIDS="$PIDS $!"
wait_for_port "127.0.0.1" "$PROXY_PORT" || { echo "❌ 代理未监听"; cat "$WORK_DIR/proxy.log"; exit 1; }

# 公共：完成 greeting + user/pass + UDP ASSOCIATE 握手，返回 (tcp_sock, udp_sock, relay_port)
read -r -d '' UDP_CLIENT <<'PY' || true
import socket, sys

def associate(proxy_port, user="u", passwd="p", udp_bind_port=0):
    tcp = socket.create_connection(("127.0.0.1", proxy_port), timeout=5)
    tcp.sendall(bytes([5, 1, 2]))
    assert tcp.recv(2) == bytes([5, 2]), "method select failed"
    u, p = user.encode(), passwd.encode()
    tcp.sendall(bytes([1, len(u)]) + u + bytes([len(p)]) + p)
    assert tcp.recv(2) == bytes([1, 0]), "auth failed"
    # UDP ASSOCIATE to 0.0.0.0:0
    tcp.sendall(bytes([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
    rep = tcp.recv(10)
    assert len(rep) == 10 and rep[0] == 5 and rep[1] == 0, f"associate reply {rep!r}"
    assert rep[3] == 1, "expect IPv4 BND"
    relay_port = int.from_bytes(rep[8:10], "big")
    assert relay_port > 0
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", udp_bind_port))
    udp.settimeout(3)
    return tcp, udp, relay_port

def udp_packet(frag, atyp, dst, port, payload):
    hdr = bytes([0, 0, frag, atyp])
    if atyp == 1:
        hdr += socket.inet_aton(dst)
    elif atyp == 3:
        b = dst.encode()
        hdr += bytes([len(b)]) + b
    elif atyp == 4:
        hdr += socket.inet_pton(socket.AF_INET6, dst)
    hdr += port.to_bytes(2, "big")
    return hdr + payload

def parse_packet(pkt):
    assert pkt[0] == 0 and pkt[1] == 0, f"RSV!=0: {pkt[:4]!r}"
    frag, atyp = pkt[2], pkt[3]
    if atyp == 1:
        off = 10
        dst = socket.inet_ntoa(pkt[4:8])
    elif atyp == 3:
        dlen = pkt[4]
        off = 7 + dlen
        dst = pkt[5:5+dlen].decode()
    else:
        off = 22
        dst = socket.inet_ntop(socket.AF_INET6, pkt[4:20])
    port = int.from_bytes(pkt[off-2:off], "big")
    return frag, atyp, dst, port, pkt[off:]
PY

echo "--- 测试 1: IPv4 UDP echo 端到端 ---"
PROXY_PORT="$PROXY_PORT" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
payload = b"udp-associate-echo"
udp.sendto(udp_packet(0, 1, "127.0.0.1", echo_port, payload), ("127.0.0.1", relay))
pkt, _ = udp.recvfrom(65535)
frag, atyp, dst, port, data = parse_packet(pkt)
assert frag == 0 and atyp == 1, (frag, atyp)
assert dst == "127.0.0.1" and port == echo_port, (dst, port)
assert data == payload, data
tcp.close(); udp.close()
print("  IPv4 echo roundtrip OK")
PY
check "IPv4 UDP echo 端到端" "$?"

echo "--- 测试 2: FRAG≠0 数据报被丢弃 ---"
PROXY_PORT="$PROXY_PORT" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os, socket
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
udp.sendto(udp_packet(1, 1, "127.0.0.1", echo_port, b"frag"), ("127.0.0.1", relay))
try:
    udp.recvfrom(65535)
    raise SystemExit("FRAG!=0 不应有回包")
except socket.timeout:
    pass
tcp.close(); udp.close()
print("  FRAG datagram dropped")
PY
check "FRAG≠0 丢弃" "$?"

echo "--- 测试 3: 域名 ATYP 数据报端到端 ---"
PROXY_PORT="$PROXY_PORT" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
payload = b"udp-domain-echo"
udp.sendto(udp_packet(0, 3, "localhost", echo_port, payload), ("127.0.0.1", relay))
pkt, _ = udp.recvfrom(65535)
frag, atyp, dst, port, data = parse_packet(pkt)
assert data == payload, data
# 回传封装应保留客户端使用的域名形式
assert atyp == 3 and dst == "localhost", (atyp, dst)
tcp.close(); udp.close()
print("  domain echo roundtrip OK")
PY
check "域名 ATYP 端到端（回传保留域名形式）" "$?"

echo "--- 测试 4: 未注册外源数据报被丢弃 ---"
PROXY_PORT="$PROXY_PORT" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os, socket
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
# 客户端先正常发一报（建立关联与映射）
udp.sendto(udp_packet(0, 1, "127.0.0.1", echo_port, b"first"), ("127.0.0.1", relay))
udp.recvfrom(65535)
# 另一个本地 UDP socket（不同源端口）冒充外源向 relay 端口塞数据
stranger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
stranger.settimeout(2)
stranger.sendto(b"garbage-from-stranger", ("127.0.0.1", relay))
# 客户端不应收到任何额外数据报
try:
    udp.recvfrom(65535)
    raise SystemExit("外源数据报不应被转发给客户端")
except socket.timeout:
    pass
stranger.close(); tcp.close(); udp.close()
print("  foreign datagram dropped")
PY
check "未注册外源数据报丢弃" "$?"

echo "--- 测试 5: TCP 控制连接断开 → relay 回收 ---"
PROXY_PORT="$PROXY_PORT" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os, socket, time
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
udp.sendto(udp_packet(0, 1, "127.0.0.1", echo_port, b"before-close"), ("127.0.0.1", relay))
udp.recvfrom(65535)
tcp.close()
time.sleep(2.5)  # 等 watcher 置 done + 主循环 1s 轮询退出
udp.sendto(udp_packet(0, 1, "127.0.0.1", echo_port, b"after-close"), ("127.0.0.1", relay))
try:
    udp.recvfrom(65535)
    raise SystemExit("控制连接断开后 relay 应已回收")
except socket.timeout:
    pass  # Linux：端口无监听时静默超时
except ConnectionResetError:
    pass  # Windows：ICMP port unreachable 转成 reset，同为 relay 已回收的证据
udp.close()
print("  relay reaped after control close")
PY
check "控制连接断开回收 relay" "$?"
if grep -q "udp associate: relay closed" "$WORK_DIR/proxy.log"; then
    echo "✅ 代理日志确认 relay 关闭"
else
    echo "❌ 代理日志未见 relay 关闭记录"
    failed=$((failed + 1))
fi

echo "--- 测试 6: 目标在 deny 名单 → 数据报静默丢弃 ---"
cat > "$WORK_DIR/deny.toml" <<EOF
listen = "127.0.0.1:$PROXY_PORT_DENY"
idle_timeout_seconds = 30
[auth]
user = "u"
password = "p"
[rules]
deny = ["127.0.0.1"]
EOF
SOCKS5_LISTEN_ADDR="127.0.0.1:$PROXY_PORT_DENY" \
    "$SOCKS5_BINARY" --config "$WORK_DIR/deny.toml" > "$WORK_DIR/proxy_deny.log" 2>&1 &
PIDS="$PIDS $!"
wait_for_port "127.0.0.1" "$PROXY_PORT_DENY" || { echo "❌ deny 代理未监听"; cat "$WORK_DIR/proxy_deny.log"; exit 1; }
PROXY_PORT="$PROXY_PORT_DENY" ECHO_PORT="$ECHO_PORT" "$PY" - <<PY
$(echo "$UDP_CLIENT")
import os, socket
proxy_port = int(os.environ["PROXY_PORT"]); echo_port = int(os.environ["ECHO_PORT"])
tcp, udp, relay = associate(proxy_port)
udp.sendto(udp_packet(0, 1, "127.0.0.1", echo_port, b"denied"), ("127.0.0.1", relay))
try:
    udp.recvfrom(65535)
    raise SystemExit("deny 目标不应收到回包")
except socket.timeout:
    pass
tcp.close(); udp.close()
print("  denied datagram dropped")
PY
check "deny 名单目标静默丢弃" "$?"
if grep -q "policy: udp target 127.0.0.1 denied by rules" "$WORK_DIR/proxy_deny.log"; then
    echo "✅ deny 日志佐证策略生效"
else
    echo "❌ deny 日志未见策略记录"
    failed=$((failed + 1))
fi

echo "--- 测试完成 ---"

if [[ $failed -eq 0 ]]; then
    echo "=== All UDP ASSOCIATE tests PASSED ==="
    exit 0
else
    echo "=== $failed test(s) FAILED ==="
    exit 1
fi
