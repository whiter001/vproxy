module socks5srv

import io
import lifecycle
import net
import policy
import sync
import sync.stdatomic
import time
import upstream as upx

const socks5_version = u8(5)
const socks5_auth_no_auth = u8(0)
const socks5_auth_userpass = u8(2)
const socks5_auth_no_acceptable = u8(0xff)

const socks5_cmd_connect = u8(1)
const socks5_cmd_udp_associate = u8(3)
const socks5_atyp_ipv4 = u8(1)
const socks5_atyp_domain = u8(3)
const socks5_atyp_ipv6 = u8(4)

const socks5_rep_success = u8(0)
const socks5_rep_server_failure = u8(1)
const socks5_rep_not_allowed = u8(2)
const socks5_rep_connection_refused = u8(5)
const socks5_rep_command_not_supported = u8(7)
const socks5_rep_address_not_supported = u8(8)

pub struct Stats {
mut:
	active_conns i64
	inflight     sync.WaitGroup
}

// 块作用：根据 atyp 构造 dial 地址字符串
// 处理问题（issue #3）：IPv6 必须用方括号包裹，否则 port 段会被吃进 host。
//   getaddrinfo 接受 `2001:db8::1` 与 `::1:80` 等无括号写法，但严格客户端
//   可能拒绝；用 `[ipv6]:port` 是最稳的形式。
fn dial_addr(target_host string, target_port u16, atyp u8) string {
	if atyp == socks5_atyp_ipv6 {
		return '[${target_host}]:${target_port}'
	}
	return '${target_host}:${target_port}'
}

// 块作用：监听 / accept / 优雅退出主循环
// （原 socks5 main() 中的生命周期部分，issue #29 抽出供单端口多协议入口复用）
pub fn serve(listen_addr string, expected_user string, expected_pass string, idle_dur time.Duration,
	rules policy.Rules, parent ?upx.Parent, relay_host string) {
	lifecycle.install_signal_handlers()

	mut server := net.listen_tcp(.ip, listen_addr) or {
		eprintln('Failed to listen on ${listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('SOCKS5 proxy listening on ${listen_addr} (idle_timeout=${idle_dur}) ...')

	stats := &Stats{}
	// Option 跨 go 边界会触发 V 0.5.2 C codegen bug（_option 类型在 thread-arg
	// 结构体中声明不全，issue #12），在循环外解包为值 + 标志，循环内按值传递。
	mut parent_val := upx.Parent{}
	mut has_parent := false
	if p := parent {
		parent_val = p
		has_parent = true
	}
	// 周期性检查停止标志；不设超时则 SIGTERM 后 accept() 永远阻塞。
	server.set_accept_timeout(1 * time.second)

	for {
		if lifecycle.should_stop() {
			eprintln('shutdown: stop signal received, closing listener')
			break
		}
		mut socket := server.accept() or {
			if lifecycle.should_stop() {
				break
			}
			if err.msg() == 'accept timeout' {
				continue
			}
			eprintln('Failed to accept client: ${err}')
			continue
		}
		stdatomic.add_i64(&stats.active_conns, 1)
		stats.inflight.add(1)
		go handle_client_ver(mut socket, stats, idle_dur, expected_user, expected_pass, rules,
			parent_val, has_parent, relay_host, 0)
	}

	active := stdatomic.load_i64(&stats.active_conns)
	if active > 0 {
		eprintln('shutdown: draining ${active} in-flight connection(s)...')
	}
	stats.inflight.wait()
	eprintln('shutdown: complete')
}

pub fn handle_client_ver(mut socket net.TcpConn, stats &Stats, idle_dur time.Duration, expected_user string,
	expected_pass string, rules policy.Rules, parent upx.Parent, has_parent bool, relay_host string, ver_already_read u8) {
	lifecycle.apply_idle_timeout(mut socket, idle_dur)
	start := time.now()
	defer {
		stdatomic.add_i64(&stats.active_conns, -1)
		stats.inflight.done()
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		secs := f64(duration) / 1e9
		eprintln('Client handled in ${secs}s. Active: ${stdatomic.load_i64(&stats.active_conns)}')
	}

	// 客户端 IP 黑白名单（issue #30）
	peer := policy.peer_ip(socket) or { '' }
	if !policy.client_allowed(peer, rules.client_allow, rules.client_deny) {
		eprintln('policy: client ${peer} denied by client rules')
		return
	}

	if !handle_greeting_and_auth(mut socket, expected_user, expected_pass, ver_already_read) {
		return
	}

	// parent 按值传入（go 边界的 Option 会触发 V 0.5.2 C codegen bug，见 serve），
	// 下游常规调用用 Option 语义，这里重新包装。
	parent_opt := if has_parent { ?upx.Parent(parent) } else { ?upx.Parent(none) }
	handle_request(mut socket, idle_dur, rules, parent_opt, relay_host)
}

fn handle_greeting_and_auth(mut socket net.TcpConn, expected_user string, expected_pass string, ver_already_read u8) bool {
	mut greeting := []u8{len: 2}
	if ver_already_read != 0 {
		// 单端口多协议前置（issue #29）：VER 字节已被预读时直接使用（0 为哨兵，
		// 0x00 不是合法 SOCKS 版本号），只补读 NMETHODS 与 METHODS。
		greeting[0] = ver_already_read
		read_exact(mut socket, mut greeting[1..]) or {
			eprintln('Failed to read greeting: ${err}')
			return false
		}
	} else {
		read_exact(mut socket, mut greeting) or {
			eprintln('Failed to read greeting: ${err}')
			return false
		}
	}

	ver := greeting[0]
	nmethods := greeting[1]

	if ver != socks5_version {
		eprintln('Unsupported SOCKS version: ${ver}')
		socket.write([u8(5), socks5_auth_no_acceptable]) or {}
		return false
	}

	mut methods := []u8{len: int(nmethods)}
	read_exact(mut socket, mut methods) or {
		eprintln('Failed to read methods: ${err}')
		return false
	}

	auth_username := expected_user
	auth_password := expected_pass
	auth_required := auth_username != '' && auth_password != ''

	if auth_required {
		has_userpass := methods.contains(socks5_auth_userpass)
		if has_userpass {
			socket.write([u8(5), socks5_auth_userpass]) or {}
			return handle_userpass_auth(mut socket, auth_username, auth_password)
		}
		// 鉴权开启时，客户端未提供 userpass 方法（即使同时声明 0x00 no-auth）一律拒绝，
		// 防止仅声明 no-auth 绕过凭据校验（security: auth bypass）。
		socket.write([u8(5), socks5_auth_no_acceptable]) or {}
		return false
	}

	if methods.contains(socks5_auth_no_auth) {
		socket.write([u8(5), socks5_auth_no_auth]) or {}
		return true
	}

	socket.write([u8(5), socks5_auth_no_acceptable]) or {}
	return false
}

fn handle_userpass_auth(mut socket net.TcpConn, expected_user string, expected_pass string) bool {
	mut header := []u8{len: 2}
	read_exact(mut socket, mut header) or {
		eprintln('Failed to read auth header: ${err}')
		return false
	}

	ver := header[0]
	user_len := int(header[1])

	if ver != 1 {
		socket.write([u8(1), socks5_auth_no_acceptable]) or {}
		return false
	}

	mut user_bytes := []u8{len: user_len}
	read_exact(mut socket, mut user_bytes) or {
		return false
	}

	mut pass_len_buf := []u8{len: 1}
	read_exact(mut socket, mut pass_len_buf) or { return false }
	pass_len := int(pass_len_buf[0])

	mut pass_bytes := []u8{len: pass_len}
	read_exact(mut socket, mut pass_bytes) or {
		return false
	}

	user := user_bytes.bytestr()
	pass := pass_bytes.bytestr()

	if user == expected_user && pass == expected_pass {
		socket.write([u8(1), u8(0)]) or {}
		return true
	}

	socket.write([u8(1), u8(0x01)]) or {}
	return false
}

fn handle_request(mut socket net.TcpConn, idle_dur time.Duration, rules policy.Rules, parent ?upx.Parent, relay_host string) {
	mut header := []u8{len: 4}
	read_exact(mut socket, mut header) or {
		eprintln('Failed to read request header: ${err}')
		send_reply(mut socket, socks5_rep_server_failure, socks5_atyp_ipv4, 0)
		return
	}

	ver := header[0]
	cmd := header[1]
	rsv := header[2]
	atyp := header[3]

	if ver != socks5_version {
		send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
		return
	}
	// RFC 1928 §4: RSV MUST be 0x00. 拒绝非零请求可避免畸形客户端绕过处理。
	if rsv != 0 {
		eprintln('Invalid RSV: ${rsv}')
		send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
		return
	}

	mut target_host := ''
	mut target_port := u16(0)

	match atyp {
		socks5_atyp_ipv4 {
			mut addr := []u8{len: 4}
			read_exact(mut socket, mut addr) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			target_host = addr.map(it.str()).join('.')
			mut port := []u8{len: 2}
			read_exact(mut socket, mut port) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		socks5_atyp_domain {
			mut domain_len := []u8{len: 1}
			read_exact(mut socket, mut domain_len) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			mut domain_bytes := []u8{len: int(domain_len[0])}
			read_exact(mut socket, mut domain_bytes) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			target_host = domain_bytes.bytestr()
			mut port := []u8{len: 2}
			read_exact(mut socket, mut port) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		socks5_atyp_ipv6 {
			mut addr := []u8{len: 16}
			read_exact(mut socket, mut addr) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			mut parts := []string{len: 8}
			// issue #3: hex() 会去前导 0，拼接成 `2001:db8:0:0:...:1` 这种带零段的串
			// 在某些严格客户端会被拒绝。hex_full() 固定 4 位零填充，得到 RFC 5952 标准形式。
			for i := 0; i < 8; i++ {
				val := (u16(addr[i * 2]) << 8) | u16(addr[i * 2 + 1])
				parts[i] = val.hex_full()
			}
			target_host = parts.join(':')
			mut port := []u8{len: 2}
			read_exact(mut socket, mut port) or {
				send_reply(mut socket, socks5_rep_server_failure, atyp, 0)
				return
			}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		else {
			send_reply(mut socket, socks5_rep_address_not_supported, atyp, 0)
			return
		}
	}

	match cmd {
		socks5_cmd_connect {
			handle_connect(mut socket, target_host, target_port, atyp, idle_dur, rules, parent)
		}
		socks5_cmd_udp_associate {
			// 请求的 DST.ADDR/DST.PORT 按 RFC 1928 §4.3 仅是客户端「预期」
			// 发送 UDP 的地址提示（常为 0.0.0.0:0），relay 按实际源地址工作。
			handle_udp_associate(mut socket, atyp, relay_host, rules)
		}
		else {
			// BIND 当前未实现（docs/PROTOCOL.md 已说明）。
			send_reply(mut socket, socks5_rep_command_not_supported, atyp, 0)
		}
	}
}

// 处理问题：
// - issue #3：用 dial_addr 拼装 host:port（IPv6 加方括号）
// - issue #3：send_reply 用 atyp 输出对应长度（10/22/7+N）
// - issue #5：upstream 应用 idle timeout
// - issue #30：拨号前做目标黑白名单判定，拒绝回 rep=2（not allowed by ruleset）
// - issue #27：配置了 parent 则经上级建连，失败回 rep=5（connection refused）
fn handle_connect(mut socket net.TcpConn, target_host string, target_port u16, atyp u8,
	idle_dur time.Duration, rules policy.Rules, parent ?upx.Parent) {
	if !policy.target_allowed(target_host, rules.allow, rules.deny) {
		eprintln('policy: target ${target_host} denied by rules')
		send_reply(mut socket, socks5_rep_not_allowed, atyp, 0)
		return
	}

	addr_str := dial_addr(target_host, target_port, atyp)
	mut upstream := if p := parent {
		p.dial(addr_str) or {
			eprintln('Failed to connect to ${addr_str} via parent ${p.safe_str()}: ${err}')
			send_reply(mut socket, socks5_rep_connection_refused, atyp, 0)
			return
		}
	} else {
		net.dial_tcp(addr_str) or {
			eprintln('Failed to connect to ${addr_str}: ${err}')
			send_reply(mut socket, socks5_rep_connection_refused, atyp, 0)
			return
		}
	}
	defer {
		upstream.close() or {}
	}
	// 给 upstream 同样设置 idle timeout，避免慢上游长时间占用 fd
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	// 回写成功 reply，回包 ATYP 与请求一致（RFC 1928 §6）。
	send_reply(mut socket, socks5_rep_success, atyp, 0)

	// 双向 io.cp 中继（半关闭传播）
	// 半关闭语义：本方向 EOF/错误 → 向 dst 发 FIN，让对端感知 EOF，另一方向继续中继；
	// 两个 socket 由 handle_client 外层 defer 在 wg.wait() 后各关一次，
	// 避免双关（fd 复用误杀新连接）及 close 与对端 goroutine 阻塞 recv 竞争。
	mut wg := sync.new_waitgroup()
	wg.add(2)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut socket, mut upstream, mut wg)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut upstream, mut socket, mut wg)
	wg.wait()
}

// 块作用：发送 SOCKS5 reply
// 处理问题（issue #3）：
// 1. 按请求 ATYP 输出对应长度的包（IPv4=10 字节 / IPv6=22 字节 / domain=变长）
// 2. BND.ADDR 始终为 0（IPv4: 0.0.0.0 / IPv6: :: / domain: 空），BND.PORT 为 0
// 3. 大多数 SOCKS5 客户端忽略 BND.ADDR，但严格客户端（如 curl）会校验包长度
fn send_reply(mut socket net.TcpConn, rep u8, req_atyp u8, bind_port u16) {
	mut reply := []u8{}
	reply << socks5_version
	reply << rep
	reply << u8(0) // RSV
	reply << req_atyp

	match req_atyp {
		socks5_atyp_ipv4 {
			reply << []u8{len: 4} // BND.ADDR = 0.0.0.0
			reply << u8(bind_port >> 8)
			reply << u8(bind_port & 0xff)
		}
		socks5_atyp_ipv6 {
			reply << []u8{len: 16} // BND.ADDR = ::
			reply << u8(bind_port >> 8)
			reply << u8(bind_port & 0xff)
		}
		socks5_atyp_domain {
			reply << u8(0) // BND.ADDR length = 0
			reply << u8(bind_port >> 8)
			reply << u8(bind_port & 0xff)
		}
		else {
			// 未知 atyp：回 IPv4 全 0，避免写错字节长度。
			reply << []u8{len: 4}
			reply << u8(bind_port >> 8)
			reply << u8(bind_port & 0xff)
		}
	}

	socket.write(reply) or { eprintln('Failed to send reply: ${err}') }
}

// TCP read may return fewer bytes than requested; protocol fields must be read in full.
fn read_exact(mut socket net.TcpConn, mut buf []u8) ! {
	mut total := 0
	for total < buf.len {
		n := socket.read(mut buf[total..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		total += n
	}
}

// 块作用：UDP ASSOCIATE（RFC 1928 §4.3，issue #26）
// 处理问题：
// - 在与 TCP 监听同 host 的地址上绑定 UDP relay（临时端口），reply 带回 BND.PORT；
// - 客户端 → relay 的数据报按 RFC 1928 UDP 封装头（RSV(2) FRAG(1) ATYP DST.PORT）
//   解封后转发到目标；目标 → relay 的数据报按客户端当初使用的 ATYP 形式封装回传；
// - TCP 控制连接断开（含 idle 超时）即回收 relay：watcher 置 done，主循环靠
//   1s 读超时轮询退出（close UDP socket 无法可靠唤醒阻塞中的 recvfrom，跨平台）。
// 明确边界：
// - FRAG≠0 丢弃（不支持分片重组，RFC 允许 MUST drop）；
// - 非客户端源的首个数据报丢弃：客户端 = TCP 对端 IP 匹配的首个 UDP 源；
// - 未在映射表中的外源数据报丢弃（relay 只对「客户端先发过」的目标回传）；
// - 目标域名每个数据报都重新 resolve（v1 不做 DNS 缓存）；
// - 目标 family 与 relay socket 不一致时丢弃（如 IPv4 relay 到不了 IPv6 目标）；
// - relay 生命周期受 --idle-timeout 约束（控制连接无数据即 idle），长会话置 0；
// - 级联（--parent，issue #27）不适用于 UDP：上级为 socks5 时亦不穿透 UDP。
fn handle_udp_associate(mut socket net.TcpConn, req_atyp u8, relay_host string, rules policy.Rules) {
	mut udp := net.listen_udp('${relay_host}:0') or {
		eprintln('udp associate: listen failed: ${err}')
		send_reply(mut socket, socks5_rep_server_failure, req_atyp, 0)
		return
	}
	defer {
		udp.close() or {}
	}

	local := net.addr_from_socket_handle(udp.sock.handle)
	local_port := local.port() or { 0 }
	relay_family := local.family()
	// BND.ADDR 惯例回全 0（客户端用 TCP 同一目标地址即可），ATYP 与 relay family 一致
	reply_atyp := if relay_family == .ip6 { socks5_atyp_ipv6 } else { socks5_atyp_ipv4 }
	send_reply(mut socket, socks5_rep_success, reply_atyp, local_port)
	eprintln('udp associate: relay on ${local}')

	// 控制连接监视：读到 EOF / 错误（含 idle 超时）即结束关联。
	// 控制连接按 RFC 不承载数据，读到的垃圾字节直接忽略。
	mut done := i64(0)
	mut wg := sync.new_waitgroup()
	wg.add(1)
	go fn (mut socket net.TcpConn, mut wg sync.WaitGroup, done &i64) {
		defer {
			wg.done()
		}
		mut one := []u8{len: 1}
		for {
			socket.read(mut one) or { break }
		}
		stdatomic.store_i64(done, 1)
	}(mut socket, mut wg, &done)

	udp.set_read_timeout(1 * time.second)
	peer := policy.peer_ip(socket) or { '' }
	mut client := ?net.Addr(none)
	mut headers := map[string][]u8{}
	mut buf := []u8{len: 65535}
	for stdatomic.load_i64(&done) == 0 {
		n, src := udp.read(mut buf) or {
			if err.msg().contains('timed out') {
				continue
			}
			eprintln('udp associate: relay read error: ${err}')
			break
		}
		if n <= 0 {
			continue
		}
		data := unsafe { buf[..n] } // 同步处理完毕才读下一报文，无需拷贝
		if c := client {
			if src.str() == c.str() {
				udp_forward_to_target(mut udp, data, mut headers, relay_family, rules)
			} else {
				// 目标 → 客户端：只回传「客户端先联系过」的目标，其余外源一律丢弃
				prefix := headers[src.str()] or { continue }
				mut out := []u8{cap: prefix.len + data.len}
				out << prefix
				out << data
				udp.write_to(c, out) or {
					eprintln('udp associate: write to client failed: ${err}')
				}
			}
		} else {
			// 首报文定客户端：源 IP 必须等于 TCP 控制连接对端 IP，
			// 防止本机其他进程抢注关联
			src_host, _ := net.split_address(src.str()) or { continue }
			if peer != '' && src_host == peer {
				client = src
				udp_forward_to_target(mut udp, data, mut headers, relay_family, rules)
			}
		}
	}

	// 唤醒 watcher（shutdown read → read 返回 EOF），等其退出后再返回，
	// 避免 watcher 的 read 与 handle_client defer 的 close 竞争同一 socket
	net.shutdown(socket.sock.handle, how: .read)
	wg.wait()
	eprintln('udp associate: relay closed')
}

// 客户端 → 目标：解封 RFC 1928 UDP 请求头并转发
fn udp_forward_to_target(mut udp net.UdpConn, data []u8, mut headers map[string][]u8,
	relay_family net.AddrFamily, rules policy.Rules) {
	if data.len < 4 {
		return
	}
	if data[0] != 0 || data[1] != 0 {
		return // RSV 必须为 0
	}
	if data[2] != 0 {
		return // FRAG≠0：不支持分片，按 RFC 丢弃
	}
	atyp := data[3]
	mut off := 0
	mut dst_host := ''
	mut dst_port := u16(0)
	match atyp {
		socks5_atyp_ipv4 {
			if data.len < 10 {
				return
			}
			dst_host = data[4..8].map(it.str()).join('.')
			dst_port = (u16(data[8]) << 8) | u16(data[9])
			off = 10
		}
		socks5_atyp_domain {
			dlen := int(data[4])
			if data.len < 5 + dlen + 2 {
				return
			}
			dst_host = data[5..5 + dlen].bytestr()
			dst_port = (u16(data[5 + dlen]) << 8) | u16(data[6 + dlen])
			off = 7 + dlen
		}
		socks5_atyp_ipv6 {
			if data.len < 22 {
				return
			}
			mut parts := []string{len: 8}
			for i := 0; i < 8; i++ {
				val := (u16(data[4 + i * 2]) << 8) | u16(data[5 + i * 2])
				parts[i] = val.hex_full()
			}
			dst_host = parts.join(':')
			dst_port = (u16(data[20]) << 8) | u16(data[21])
			off = 22
		}
		else {
			return
		}
	}

	// 目标黑白名单（issue #30）：UDP 无错误应答，拒绝即静默丢弃
	if !policy.target_allowed(dst_host, rules.allow, rules.deny) {
		eprintln('policy: udp target ${dst_host} denied by rules')
		return
	}

	// 解析目标 Addr；IPv4/IPv6 字面量直接构造，域名逐报文 resolve
	mut dst_addr := net.Addr{}
	if atyp == socks5_atyp_ipv4 {
		mut ip4 := [4]u8{}
		for i in 0 .. 4 {
			ip4[i] = data[4 + i]
		}
		dst_addr = net.new_ip(dst_port, ip4)
	} else if atyp == socks5_atyp_ipv6 {
		mut ip6 := [16]u8{}
		for i in 0 .. 16 {
			ip6[i] = data[4 + i]
		}
		dst_addr = net.new_ip6(dst_port, ip6)
	} else {
		addrs := net.resolve_addrs_fuzzy('${dst_host}:${dst_port}', .udp) or {
			eprintln('udp associate: resolve ${dst_host} failed: ${err}')
			return
		}
		mut picked := false
		for a in addrs {
			if a.family() == relay_family {
				dst_addr = a
				picked = true
				break
			}
		}
		if !picked {
			eprintln('udp associate: no ${relay_family} address for ${dst_host}')
			return
		}
	}
	if dst_addr.family() != relay_family {
		eprintln('udp associate: target family mismatch, drop')
		return
	}

	// 记录回传封装头（保留客户端使用的原 ATYP 形式）；map 上限防内存膨胀
	if headers.len < 1024 {
		headers[dst_addr.str()] = data[..off].clone()
	}
	udp.write_to(dst_addr, data[off..]) or {
		eprintln('udp associate: write to ${dst_addr} failed: ${err}')
	}
}
