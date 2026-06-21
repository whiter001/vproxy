module main

import io
import lifecycle
import net
import os
import sync
import sync.stdatomic
import time
import vpcli

// SOCKS4 协议常量（原始 socks-04.txt spec，NEC）。
// reply VN 必须是 0x00（NULL）；与 request VN=4 区分。
const socks4_version = u8(4)
const socks4_reply_vn = u8(0)
const socks4_cmd_connect = u8(1)

// Reply codes（CD 字段）
// 注：spec 还定义了 0x5C (ident unreachable) 和 0x5D (ident mismatch)，但 vproxy 不实现 identd。
const socks4_cd_granted = u8(0x5A)
const socks4_cd_rejected = u8(0x5B)

struct Stats {
mut:
	active_conns i64
	inflight     sync.WaitGroup
}

fn main() {
	cfg := vpcli.parse_socks4_args(os.args) or {
		eprintln('parse error: ${err}')
		C.exit(1)
	}
	if cfg.show_help {
		vpcli.print_socks4_help()
		return
	}
	if cfg.show_version {
		println('vproxy ${vpcli.version}')
		return
	}

	listen_addr := cfg.listen_addr
	expected_user := cfg.auth_user
	skip_auth := cfg.no_auth

	lifecycle.install_signal_handlers()
	idle_dur := cfg.idle_timeout

	mut server := net.listen_tcp(.ip, listen_addr) or {
		eprintln('Failed to listen on ${listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('SOCKS4 proxy listening on ${listen_addr} (idle_timeout=${idle_dur}, no_auth=${skip_auth}) ...')

	stats := &Stats{}
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
			// V 0.5.x 在 macOS 上的 accept 超时错误消息是 'net: op timed out; code: 9'，
			// 旧版是 'accept timeout'。两者都接受，避免每秒钟打印一行错误日志。
			msg := err.msg()
			if msg == 'accept timeout' || msg.contains('op timed out') {
				continue
			}
			eprintln('Failed to accept client: ${err}')
			continue
		}
		stdatomic.add_i64(&stats.active_conns, 1)
		stats.inflight.add(1)
		go handle_client(mut socket, stats, expected_user, skip_auth, idle_dur)
	}

	active := stdatomic.load_i64(&stats.active_conns)
	if active > 0 {
		eprintln('shutdown: draining ${active} in-flight connection(s)...')
	}
	stats.inflight.wait()
	eprintln('shutdown: complete')
}

// 块作用：客户端连接处理
// 处理问题：
// 1. 解析 SOCKS4 请求（含 SOCKS4a 域名模式）
// 2. USERID 校验（--no-auth 或期望 USERID 为空时跳过）
// 3. 上游 dial + 双向 io.cp 中继（issue #5：idle timeout 应用到客户端与上游）
// 4. SIGTERM drain 通过 inflight WaitGroup 完成
fn handle_client(mut socket net.TcpConn, stats &Stats, expected_user string, skip_auth bool,
	idle_dur time.Duration) {
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

	request := parse_request(mut socket) or {
		eprintln('Failed to parse SOCKS4 request: ${err}')
		return
	}

	// USERID 校验：
	// - skip_auth（--no-auth / SOCKS4_NO_AUTH=1）：跳过校验
	// - expected_user 非空：USERID 必须匹配；不匹配回 0x5B 并关闭
	// - expected_user 空：接受任意 USERID（与 SOCKS5 行为一致）
	if !skip_auth && expected_user != '' && request.userid != expected_user {
		eprintln('USERID mismatch: got "${request.userid}", expected "${expected_user}"')
		send_reply(mut socket, socks4_cd_rejected, request.port, request.dst_ip_bytes)
		return
	}

	addr_str := dial_addr(request.target_host, request.port)
	mut upstream := net.dial_tcp(addr_str) or {
		eprintln('Failed to connect to ${addr_str}: ${err}')
		send_reply(mut socket, socks4_cd_rejected, request.port, request.dst_ip_bytes)
		return
	}
	defer {
		upstream.close() or {}
	}
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	send_reply(mut socket, socks4_cd_granted, request.port, request.dst_ip_bytes)

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

// 块作用：SOCKS4 请求解析结果
// 处理问题：USERID 留给上层鉴权使用；target_host 在 SOCKS4a 模式下为域名，
// SOCKS4 模式下为 IPv4 字面量；dst_ip_bytes 用于回复时回显（reply 必须 echo DSTIP）。
struct ParsedRequest {
pub mut:
	userid       string
	target_host  string
	port         u16
	dst_ip_bytes []u8 // 4 字节 DSTIP 原值，用于 reply 回显
}

// 块作用：解析 SOCKS4 / SOCKS4a 请求
// 处理问题：
// 1. SOCKS4 不分 greeting 阶段，VN=4 在请求第一字节
// 2. SOCKS4a 探测：DSTIP[0..3]==0x00 && DSTIP[3]!=0（0.0.0.X），其后为 NUL 终止域名
// 3. 边界：VN!=4、CD!=1 → 关闭连接（不发送 reply，因为 reply VN 必须为 0）
// 4. 最大用户/域名长度 256 字节，超出视为畸形
fn parse_request(mut socket net.TcpConn) !ParsedRequest {
	mut header := []u8{len: 8}
	n := socket.read(mut header) or { return error('read header: ${err}') }
	if n < 8 {
		return error('header too short (got ${n})')
	}

	ver := header[0]
	cd := header[1]
	if ver != socks4_version {
		return error('unsupported version ${ver}')
	}
	if cd != socks4_cmd_connect {
		// SOCKS4 spec 定义 CD=1 (CONNECT), CD=2 (BIND)；BIND 极少使用且本实现不支持。
		// 用 connection_refused 语义返回 rejected 即可。
		return error('unsupported command ${cd}')
	}

	port := (u16(header[2]) << 8) | u16(header[3])
	dst_ip_bytes := header[4..8].clone()

	userid := read_nul_string(mut socket) or { return error('read userid: ${err}') }

	// SOCKS4a 探测：前三字节为 0，第四字节非 0。
	mut target_host := ''
	if header[4] == 0 && header[5] == 0 && header[6] == 0 && header[7] != 0 {
		domain := read_nul_string(mut socket) or { return error('read domain: ${err}') }
		if domain == '' {
			return error('empty SOCKS4a domain')
		}
		target_host = domain
	} else {
		target_host = '${header[4]}.${header[5]}.${header[6]}.${header[7]}'
	}

	return ParsedRequest{
		userid:       userid
		target_host:  target_host
		port:         port
		dst_ip_bytes: dst_ip_bytes
	}
}

// 块作用：读取 NUL 终止字符串（最大 256 字节）
// 处理问题：SOCKS4 没有长度前缀，必须按字节读到 NUL；硬上限避免恶意客户端耗尽内存。
fn read_nul_string(mut socket net.TcpConn) !string {
	mut bytes := []u8{}
	mut buf := []u8{len: 1}
	for {
		n := socket.read(mut buf) or { return error(err.msg()) }
		if n <= 0 {
			return error('unexpected EOF in NUL-terminated string')
		}
		if buf[0] == 0 {
			break
		}
		bytes << buf[0]
		if bytes.len > 256 {
			return error('string too long')
		}
	}
	return bytes.bytestr()
}

// 块作用：构造 dial 地址（IPv4 字面量或域名）
// 处理问题：SOCKS4 不支持 IPv6，所以无需方括号包裹；域名交给 getaddrinfo 解析。
fn dial_addr(target_host string, target_port u16) string {
	return '${target_host}:${target_port}'
}

// 块作用：发送 SOCKS4 reply（8 字节）
// 处理问题：reply 固定格式 VN=0 + CD + DSTPORT(2) + DSTIP(4)；DSTPORT/DSTIP 必须
// 回显客户端请求中的值（spec 要求），CD 决定下游是否进入中继。
fn send_reply(mut socket net.TcpConn, cd u8, port u16, dst_ip_bytes []u8) {
	mut reply := []u8{}
	reply << socks4_reply_vn
	reply << cd
	reply << u8(port >> 8)
	reply << u8(port & 0xff)
	reply << dst_ip_bytes
	socket.write(reply) or { eprintln('Failed to send reply: ${err}') }
}
