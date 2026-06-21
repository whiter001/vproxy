// proxy/mproxy/socks5_dial/socks5_dial.v
//
// SOCKS5 客户端拨号 helper（RFC 1928 + RFC 1929），让 mproxy 的 serve / server
// 模式可以把上游 TCP 连接转发到一个 SOCKS5 代理（链式转发）。
//
// 用法：
//   cfg := socks5_dial.parse_url('socks5://user:pass@1.2.3.4:1080') or { ... }
//   sock := socks5_dial.dial(cfg, 'example.com', 443) or { ... }
//   // 此后 sock 已通过 SOCKS5 CONNECT 到 example.com:443，可直接 io.cp 双向中继
//
// 字节格式参照 proxy/socks5/1/proxy.socks5.v:123-313 反向实现。
module socks5_dial

import net

const socks5_version = u8(5)
const socks5_auth_no_auth = u8(0)
const socks5_auth_userpass = u8(2)
const socks5_auth_no_acceptable = u8(0xff)

const socks5_cmd_connect = u8(1)
const socks5_atyp_ipv4 = u8(1)
const socks5_atyp_domain = u8(3)
const socks5_atyp_ipv6 = u8(4)

const socks5_userpass_version = u8(1)
const socks5_userpass_success = u8(0)
const socks5_userpass_fail = u8(1)

pub struct UpstreamConfig {
pub mut:
	host string
	port u16
	user string
	pass string
}

// 块作用：解析 SOCKS5 upstream URL
// 处理问题：
// - 三种格式：`socks5://[user:pass@]host:port`、`socks5://host:port`、`host:port`
// - 后两种等价（无 auth）
// - 不支持 IPv6 字面量作为 upstream（本期省略；本仓 SOCKS5 server 也不支持 IPv6 字面量 upstream）
pub fn parse_url(url string) !UpstreamConfig {
	mut rest := url
	if rest.starts_with('socks5://') {
		rest = rest.all_after('socks5://')
	}

	mut cfg := UpstreamConfig{}

	// 检查 user:pass@ 前缀
	if rest.contains('@') {
		parts := rest.split('@')
		if parts.len != 2 {
			return error('invalid SOCKS5 URL (expected user:pass@host:port)')
		}
		creds := parts[0].split(':')
		if creds.len != 2 {
			return error('invalid SOCKS5 URL (expected user:pass@host:port)')
		}
		cfg.user = creds[0]
		cfg.pass = creds[1]
		rest = parts[1]
	}

	// 解析 host:port
	colon_idx := rest.last_index(':') or { return error('invalid SOCKS5 URL (missing port)') }
	cfg.host = rest[..colon_idx]
	port_str := rest[colon_idx + 1..]
	port := port_str.u16()
	if port == 0 {
		return error('invalid port "${port_str}"')
	}
	cfg.port = port

	if cfg.host == '' {
		return error('empty SOCKS5 host')
	}
	return cfg
}

// 块作用：通过 SOCKS5 代理建立到 target 的 TCP 连接
// 处理问题：
// 1. greeting：先 no-auth，若 server 选 userpass 再走 RFC 1929 子协商
// 2. CONNECT：target 是 IPv4 字面量用 atyp=1；否则用 atyp=3（domain）
// 3. reply rep=0 才算 granted；非 0 返回 error
// 4. 返回的 socket 已可双向读写，调用方直接 io.cp 透传即可
pub fn dial(cfg UpstreamConfig, target_host string, target_port u16) !&net.TcpConn {
	addr := '${cfg.host}:${cfg.port}'
	mut sock := net.dial_tcp(addr) or { return error('dial SOCKS5 ${addr}: ${err}') }

	// greeting
	if cfg.user != '' {
		sock.write([u8(socks5_version), u8(2), socks5_auth_no_auth, socks5_auth_userpass]) or {
			return error('write greeting: ${err}')
		}
	} else {
		sock.write([u8(socks5_version), u8(1), socks5_auth_no_auth]) or {
			return error('write greeting: ${err}')
		}
	}

	mut greet := []u8{len: 2}
	sock.read(mut greet) or { return error('read greeting reply: ${err}') }
	if greet[0] != socks5_version {
		sock.close() or {}
		return error('SOCKS5 version mismatch: ${greet[0]}')
	}

	if greet[1] == socks5_auth_userpass {
		if cfg.user == '' {
			sock.close() or {}
			return error('SOCKS5 server requires auth but URL has no credentials')
		}
		// RFC 1929: ver=1, ulen, uname, plen, passwd
		mut auth_pkt := []u8{}
		auth_pkt << socks5_userpass_version
		auth_pkt << u8(cfg.user.len)
		auth_pkt << cfg.user.bytes()
		auth_pkt << u8(cfg.pass.len)
		auth_pkt << cfg.pass.bytes()
		sock.write(auth_pkt) or { return error('write userpass: ${err}') }

		mut auth_rep := []u8{len: 2}
		sock.read(mut auth_rep) or { return error('read userpass reply: ${err}') }
		if auth_rep[1] != socks5_userpass_success {
			sock.close() or {}
			return error('SOCKS5 userpass auth failed (status=${auth_rep[1]})')
		}
	} else if greet[1] == socks5_auth_no_auth {
		// OK
	} else {
		sock.close() or {}
		return error('SOCKS5 no acceptable method (reply=${greet[1]})')
	}

	// CONNECT 请求
	mut req := []u8{}
	req << socks5_version
	req << socks5_cmd_connect
	req << u8(0) // RSV
	// 判定 target 是 IPv4 字面量还是 domain（简化：不处理 IPv6 upstream target）
	if target_host.contains('.') && !target_host.contains(':')
		&& is_all_digits_and_dots(target_host) {
		parts := target_host.split('.')
		if parts.len == 4 {
			req << socks5_atyp_ipv4
			for p in parts {
				n := p.u8()
				if n > 127 {
					// u8 returns 0 on parse fail; treat as error
					sock.close() or {}
					return error('invalid IPv4 octet "${p}"')
				}
				req << n
			}
		} else {
			req << socks5_atyp_domain
			req << u8(target_host.len)
			req << target_host.bytes()
		}
	} else {
		req << socks5_atyp_domain
		if target_host.len > 255 {
			sock.close() or {}
			return error('domain too long: ${target_host.len}')
		}
		req << u8(target_host.len)
		req << target_host.bytes()
	}
	req << u8(target_port >> 8)
	req << u8(target_port & 0xff)

	sock.write(req) or { return error('write CONNECT: ${err}') }

	// reply: 至少 4 字节头（VER REP RSV ATYP），加上 BND.ADDR + BND.PORT
	mut reply_hdr := []u8{len: 4}
	sock.read(mut reply_hdr) or { return error('read CONNECT reply: ${err}') }
	if reply_hdr[1] != 0 {
		sock.close() or {}
		return error('SOCKS5 CONNECT refused (rep=${reply_hdr[1]})')
	}
	// 消费 BND.ADDR + BND.PORT（用 read 而不是 recv，避免阻塞；client 忽略 BND 内容）
	match reply_hdr[3] {
		socks5_atyp_ipv4 {
			mut bnd := []u8{len: 4 + 2}
			sock.read(mut bnd) or { return error('read BND: ${err}') }
		}
		socks5_atyp_ipv6 {
			mut bnd := []u8{len: 16 + 2}
			sock.read(mut bnd) or { return error('read BND: ${err}') }
		}
		socks5_atyp_domain {
			mut len_buf := []u8{len: 1}
			sock.read(mut len_buf) or { return error('read BND domain len: ${err}') }
			mut bnd := []u8{len: int(len_buf[0]) + 2}
			sock.read(mut bnd) or { return error('read BND: ${err}') }
		}
		else {
			sock.close() or {}
			return error('unknown ATYP in reply: ${reply_hdr[3]}')
		}
	}

	// 转移所有权：sock 是 mut 绑定，V 视为 &net.TcpConn；按签名直接返回
	return sock
}

// 块作用：检查字符串是否全是数字和点（IPv4 字面量粗判）
// 处理问题：SOCKS5 atyp=1 编码需要 IPv4 4 字节；domain 用 atyp=3。粗判足够，
// 非 IPv4 字面量都走 domain；server 端会做最终校验（getaddrinfo）。
fn is_all_digits_and_dots(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c != `.` && (c < `0` || c > `9`) {
			return false
		}
	}
	return true
}
