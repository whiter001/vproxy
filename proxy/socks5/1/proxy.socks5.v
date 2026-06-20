module main

import io
import lifecycle
import net
import os
import sync
import sync.stdatomic
import time
import vpcli

const socks5_version = u8(5)
const socks5_auth_no_auth = u8(0)
const socks5_auth_userpass = u8(2)
const socks5_auth_no_acceptable = u8(0xff)

const socks5_cmd_connect = u8(1)
const socks5_atyp_ipv4 = u8(1)
const socks5_atyp_domain = u8(3)
const socks5_atyp_ipv6 = u8(4)

const socks5_rep_success = u8(0)
const socks5_rep_server_failure = u8(1)
const socks5_rep_connection_refused = u8(5)
const socks5_rep_command_not_supported = u8(7)
const socks5_rep_address_not_supported = u8(8)

struct Stats {
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

fn main() {
	cfg := vpcli.parse_socks5_args(os.args) or { C.exit(1) }
	if cfg.show_help {
		vpcli.print_socks5_help()
		return
	}
	if cfg.show_version {
		println('vproxy ${vpcli.version}')
		return
	}

	listen_addr := cfg.listen_addr

	lifecycle.install_signal_handlers()
	idle_dur := lifecycle.idle_timeout_from_env('SOCKS5_IDLE_TIMEOUT')

	mut server := net.listen_tcp(.ip, listen_addr) or {
		eprintln('Failed to listen on ${listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('SOCKS5 proxy listening on ${listen_addr} (idle_timeout=${idle_dur}) ...')

	stats := &Stats{}
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
		go handle_client(mut socket, stats, idle_dur)
	}

	active := stdatomic.load_i64(&stats.active_conns)
	if active > 0 {
		eprintln('shutdown: draining ${active} in-flight connection(s)...')
	}
	stats.inflight.wait()
	eprintln('shutdown: complete')
}

fn handle_client(mut socket net.TcpConn, stats &Stats, idle_dur time.Duration) {
	lifecycle.apply_idle_timeout(mut socket, idle_dur)
	start := time.now()
	defer {
		stdatomic.add_i64(&stats.active_conns, -1)
		stats.inflight.done()
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		eprintln('Client handled in ${duration}s. Active: ${stdatomic.load_i64(&stats.active_conns)}')
	}

	if !handle_greeting_and_auth(mut socket) {
		return
	}

	handle_request(mut socket, idle_dur)
}

fn handle_greeting_and_auth(mut socket net.TcpConn) bool {
	mut greeting := []u8{len: 2}
	n := socket.read(mut greeting) or {
		eprintln('Failed to read greeting: ${err}')
		return false
	}
	if n < 2 {
		eprintln('Greeting too short')
		return false
	}

	ver := greeting[0]
	nmethods := greeting[1]

	if ver != socks5_version {
		eprintln('Unsupported SOCKS version: ${ver}')
		socket.write([u8(5), socks5_auth_no_acceptable]) or {}
		return false
	}

	mut methods := []u8{len: int(nmethods)}
	mut read := 0
	for read < int(nmethods) {
		r := socket.read(mut methods[read..]) or { break }
		if r <= 0 {
			break
		}
		read += r
	}

	auth_username := os.getenv_opt('SOCKS5_AUTH_USERNAME') or { '' }
	auth_password := os.getenv_opt('SOCKS5_AUTH_PASSWORD') or { '' }
	auth_required := auth_username != '' && auth_password != ''

	if auth_required {
		has_userpass := methods.contains(socks5_auth_userpass)
		has_no_auth := methods.contains(socks5_auth_no_auth)
		if !has_userpass && !has_no_auth {
			socket.write([u8(5), socks5_auth_no_acceptable]) or {}
			return false
		}
		if has_userpass {
			socket.write([u8(5), socks5_auth_userpass]) or {}
			return handle_userpass_auth(mut socket, auth_username, auth_password)
		}
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
	n := socket.read(mut header) or {
		eprintln('Failed to read auth header: ${err}')
		return false
	}
	if n < 2 {
		return false
	}

	ver := header[0]
	user_len := int(header[1])

	if ver != 1 {
		socket.write([u8(1), socks5_auth_no_acceptable]) or {}
		return false
	}

	mut user_bytes := []u8{len: user_len}
	mut read := 0
	for read < user_len {
		r := socket.read(mut user_bytes[read..]) or { break }
		if r <= 0 {
			break
		}
		read += r
	}

	mut pass_len_buf := []u8{len: 1}
	socket.read(mut pass_len_buf) or {}
	pass_len := int(pass_len_buf[0])

	mut pass_bytes := []u8{len: pass_len}
	read = 0
	for read < pass_len {
		r := socket.read(mut pass_bytes[read..]) or { break }
		if r <= 0 {
			break
		}
		read += r
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

fn handle_request(mut socket net.TcpConn, idle_dur time.Duration) {
	mut header := []u8{len: 4}
	n := socket.read(mut header) or {
		eprintln('Failed to read request header: ${err}')
		send_reply(mut socket, socks5_rep_server_failure, socks5_atyp_ipv4, 0)
		return
	}
	if n < 4 {
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
			socket.read(mut addr) or {}
			target_host = addr.map(it.str()).join('.')
			mut port := []u8{len: 2}
			socket.read(mut port) or {}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		socks5_atyp_domain {
			mut domain_len := []u8{len: 1}
			socket.read(mut domain_len) or {}
			mut domain_bytes := []u8{len: int(domain_len[0])}
			socket.read(mut domain_bytes) or {}
			target_host = domain_bytes.bytestr()
			mut port := []u8{len: 2}
			socket.read(mut port) or {}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		socks5_atyp_ipv6 {
			mut addr := []u8{len: 16}
			socket.read(mut addr) or {}
			mut parts := []string{len: 8}
			// issue #3: hex() 会去前导 0，拼接成 `2001:db8:0:0:...:1` 这种带零段的串
			// 在某些严格客户端会被拒绝。hex_full() 固定 4 位零填充，得到 RFC 5952 标准形式。
			for i := 0; i < 8; i++ {
				val := (u16(addr[i * 2]) << 8) | u16(addr[i * 2 + 1])
				parts[i] = val.hex_full()
			}
			target_host = parts.join(':')
			mut port := []u8{len: 2}
			socket.read(mut port) or {}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		else {
			send_reply(mut socket, socks5_rep_address_not_supported, atyp, 0)
			return
		}
	}

	match cmd {
		socks5_cmd_connect {
			handle_connect(mut socket, target_host, target_port, atyp, idle_dur)
		}
		else {
			// BIND / UDP ASSOCIATE 当前未实现（README 已说明）。
			send_reply(mut socket, socks5_rep_command_not_supported, atyp, 0)
		}
	}
}

// 处理问题：
// - issue #3：用 dial_addr 拼装 host:port（IPv6 加方括号）
// - issue #3：send_reply 用 atyp 输出对应长度（10/22/7+N）
// - issue #5：upstream 应用 idle timeout
fn handle_connect(mut socket net.TcpConn, target_host string, target_port u16, atyp u8,
	idle_dur time.Duration) {
	addr_str := dial_addr(target_host, target_port, atyp)
	mut upstream := net.dial_tcp(addr_str) or {
		eprintln('Failed to connect to ${addr_str}: ${err}')
		send_reply(mut socket, socks5_rep_connection_refused, atyp, 0)
		return
	}
	defer {
		upstream.close() or {}
	}
	// 给 upstream 同样设置 idle timeout，避免慢上游长时间占用 fd
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	// 回写成功 reply，回包 ATYP 与请求一致（RFC 1928 §6）。
	send_reply(mut socket, socks5_rep_success, atyp, 0)

	mut wg := sync.new_waitgroup()
	wg.add(2)

	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut socket, mut upstream, mut wg)

	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
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
