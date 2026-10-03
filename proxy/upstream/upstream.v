// proxy/upstream/upstream.v
//
// 上级代理（parent proxy）级联（issue #27）。
//
// HTTP / SOCKS5 代理均可配置 --parent 把全部流量转发到上级：
// - http://[user:pass@]host:port —— 上级为 HTTP 代理，CONNECT 语义走 RFC 7231 隧道
// - socks5://[user:pass@]host:port —— 上级为 SOCKS5 代理，复用 mproxy/socks5_dial
//
// 级联 TLS（https:// 上级）不在本模块范围：relay 层基于 net.TcpConn 具体类型 +
// 半关闭传播，接入 SSLConn 需要单独的抽象重构，见 issue #27 评论。
module upstream

import encoding.base64
import net
import mproxy.socks5_dial

pub enum Scheme {
	http
	socks5
}

pub struct Parent {
pub:
	scheme Scheme
	host   string
	port   u16
	user   string
	pass   string
}

// 块作用：解析上级代理 URL
// 处理问题：
// - 必须显式带 scheme（http:// 或 socks5://），避免「猜协议」的隐性行为
// - 可选 user:pass@ 认证段；host:port 用 last_index(':') 切分（与 socks5_dial 一致，
//   IPv6 字面量上级本期不支持）
pub fn parse_parent(url string) !Parent {
	mut rest := url.trim_space()
	mut scheme := Scheme.http
	if rest.starts_with('http://') {
		rest = rest.all_after('http://')
	} else if rest.starts_with('socks5://') {
		scheme = .socks5
		rest = rest.all_after('socks5://')
	} else {
		return error('invalid parent URL "${url}" (expect http:// or socks5:// scheme)')
	}

	mut user := ''
	mut pass := ''
	if rest.contains('@') {
		parts := rest.split('@')
		if parts.len != 2 {
			return error('invalid parent URL (expected user:pass@host:port)')
		}
		creds := parts[0].split(':')
		if creds.len != 2 {
			return error('invalid parent URL (expected user:pass@host:port)')
		}
		user = creds[0]
		pass = creds[1]
		rest = parts[1]
	}

	colon_idx := rest.last_index(':') or {
		return error('invalid parent URL "${url}" (missing port)')
	}
	host := rest[..colon_idx]
	port_str := rest[colon_idx + 1..]
	// 显式校验再转换：string.u16() 对溢出/负值静默回绕（99999→34463、-1→65535），
	// 配置错误必须 fail-fast 而不是悄悄拨到别的端口。
	for c in port_str {
		if !c.is_digit() {
			return error('invalid parent port "${port_str}"')
		}
	}
	port_int := port_str.int()
	if port_int <= 0 || port_int > 65535 {
		return error('invalid parent port "${port_str}"')
	}
	port := u16(port_int)
	if host == '' {
		return error('invalid parent URL "${url}" (empty host)')
	}
	return Parent{
		scheme: scheme
		host:   host
		port:   port
		user:   user
		pass:   pass
	}
}

// 块作用：脱敏的上级描述（日志用）
// 处理问题：URL 内嵌的 password 不得进启动日志，user 保留便于核对配置。
pub fn (p Parent) safe_str() string {
	scheme_str := if p.scheme == .socks5 { 'socks5' } else { 'http' }
	auth := if p.user != '' { '${p.user}:******@' } else { '' }
	return '${scheme_str}://${auth}${p.host}:${p.port}'
}

// 块作用：经上级代理建立到 target 的 TCP 连接（CONNECT 语义）
// 处理问题：
// - target 为 "host:port"（IPv6 用 [addr]:port），经 net.split_address 切分
// - socks5 上级：复用 socks5_dial（greeting + RFC1929 + CONNECT）
// - http 上级：自身实现 CONNECT 握手，2xx 才算隧道建立
pub fn (p Parent) dial(target string) !&net.TcpConn {
	if p.scheme == .socks5 {
		host, port := net.split_address(target) or {
			return error('invalid target "${target}": ${err}')
		}
		cfg := socks5_dial.UpstreamConfig{
			host: p.host
			port: p.port
			user: p.user
			pass: p.pass
		}
		return socks5_dial.dial(cfg, host, port)
	}
	return p.dial_http_connect(target)
}

// 块作用：HTTP 上级 CONNECT 握手
// 处理问题：
// - 上级有凭据时注入 Proxy-Authorization（Basic）
// - 响应头上限 64KB，状态码 2xx 判定与 curl 一致（CONNECT 成功语义）
// - 失败时关闭 socket，不泄漏 fd
fn (p Parent) dial_http_connect(target string) !&net.TcpConn {
	addr := '${p.host}:${p.port}'
	mut sock := net.dial_tcp(addr) or { return error('dial parent ${addr}: ${err}') }

	mut lines := [
		'CONNECT ${target} HTTP/1.1',
		'Host: ${target}',
	]
	if p.user != '' {
		cred := base64.encode_str('${p.user}:${p.pass}')
		lines << 'Proxy-Authorization: Basic ${cred}'
	}
	lines << ''
	sock.write_string(lines.join('\r\n') + '\r\n') or {
		sock.close() or {}
		return error('write CONNECT to parent: ${err}')
	}

	// 读响应头直到 \r\n\r\n（上限 64KB）。逐字节读取：隧道建立后 relay 直接读
	// 原始 socket，没有回推缓冲，块读取会把目标首包（SSH/SMTP 等先发 Banner
	// 的协议）与 CONNECT 响应同段的字节吞掉。
	mut data := []u8{}
	mut one := []u8{len: 1}
	for {
		n := sock.read(mut one) or {
			sock.close() or {}
			return error('read CONNECT response from parent: ${err}')
		}
		if n <= 0 {
			sock.close() or {}
			return error('parent closed before CONNECT response')
		}
		data << one[0]
		if data.len > 65536 {
			sock.close() or {}
			return error('parent CONNECT response too large')
		}
		if find_header_end(data) >= 0 {
			break
		}
	}

	head := data[..find_header_end(data)].bytestr()
	status_line := head.all_before('\r\n')
	parts := status_line.split(' ')
	if parts.len < 2 || !parts[0].starts_with('HTTP/') {
		sock.close() or {}
		return error('invalid CONNECT response from parent: ${status_line}')
	}
	code := parts[1].int()
	if code < 200 || code >= 300 {
		sock.close() or {}
		return error('parent CONNECT failed: ${status_line}')
	}
	return sock
}

fn find_header_end(data []u8) int {
	if data.len < 4 {
		return -1
	}
	for i in 0 .. data.len - 3 {
		if data[i] == `\r` && data[i + 1] == `\n` && data[i + 2] == `\r` && data[i + 3] == `\n` {
			return i
		}
	}
	return -1
}
