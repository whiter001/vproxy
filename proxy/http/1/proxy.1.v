module main

import encoding.base64
import io
import net
import os
import sync
import sync.stdatomic
import time

const valid_methods = ['CONNECT', 'POST', 'GET', 'HEAD', 'OPTIONS', 'DELETE', 'PATCH', 'PUT']
const connection_established = 'HTTP/1.1 200 Connection Established\r\n\r\n'
const default_listen_addr = ':5777'
const default_http_port = ':80'
const default_https_port = ':443'

struct Stats {
mut:
	active_conns i64
}

// 块作用：入口函数
// 处理问题：初始化配置（环境变量）、建立监听、统计活跃连接、分发请求到协程
fn main() {
	listen_addr := os.getenv_opt('PROXY_LISTEN_ADDR') or { default_listen_addr }
	expected_auth := proxy_auth_value()

	mut server := net.listen_tcp(.ip, listen_addr) or {
		eprintln('Failed to listen on ${listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('Listen on ${listen_addr} ...')

	stats := &Stats{}
	for {
		mut socket := server.accept() or {
			eprintln('Failed to accept client: ${err}')
			continue
		}
		stdatomic.add_i64(&stats.active_conns, 1) // 原子计数器
		go handle_client(mut socket, stats, expected_auth)
	}
}

// 块作用：认证值计算
// 处理问题：支持 PROXY_AUTH_BASIC 或 (PROXY_AUTH_USER + PROXY_AUTH_PASS) 环境变量
fn proxy_auth_value() string {
	if basic := os.getenv_opt('PROXY_AUTH_BASIC') {
		if basic != '' {
			return basic
		}
	}

	user := os.getenv_opt('PROXY_AUTH_USER') or { 'user' }
	pass := os.getenv_opt('PROXY_AUTH_PASS') or { 'pwd' }
	return base64.encode_str('${user}:${pass}')
}

// 块作用：客户端连接处理
// 处理问题：
// 1. 读取并解析 HTTP 头部
// 2. 校验 Proxy Basic Auth（认证）
// 3. 处理 CONNECT 隧道（HTTPS/TCP 代理）
// 4. 处理普通 HTTP 转发及相关头部修改
fn handle_client(mut socket net.TcpConn, stats &Stats, expected_auth string) {
	start := time.now()
	defer {
		stdatomic.add_i64(&stats.active_conns, -1)
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		eprintln('Client handled in ${duration}s. Active: ${stdatomic.load_i64(&stats.active_conns)}')
	}

	header_bytes, mut pending_body := read_request_head(mut socket) or {
		send_simple_response(mut socket, '400 Bad Request', '${err}\n')
		return
	}

	header_str := header_bytes.bytestr()
	first_line := header_str.all_before('\r\n')
	if first_line == '' {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return
	}

	first_parts := first_line.split(' ')
	if first_parts.len < 3 {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return
	}

	method := first_parts[0].to_upper()
	if !valid_methods.contains(method) {
		send_simple_response(mut socket, '405 Method Not Allowed', 'Unsupported method\n')
		return
	}

	target := first_parts[1]
	version := first_parts[2]

	header_lines := header_str.split('\r\n')
	mut proxy_authorization := ''
	mut host_header := ''

	for line in header_lines {
		if line == '' {
			continue
		}
		lower := line.to_lower()
		if lower.starts_with('proxy-authorization:') || lower.starts_with('authorization:') {
			proxy_authorization = line.all_after(':').trim_space()
		} else if lower.starts_with('host:') {
			host_header = line.all_after(':').trim_space()
		}
	}

	if !proxy_authorization.starts_with('Basic ') {
		gmt := time.now().custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
		response := 'HTTP/1.1 407 Proxy Authentication Required\r\nDate: ${gmt}\r\nProxy-Authenticate: Basic realm="V Proxy"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'
		socket.write_string(response) or {}
		return
	}
	provided_cred := proxy_authorization[6..].trim_space().replace('\n', '').replace('\r',
		'')
	if provided_cred != expected_auth {
		gmt := time.now().custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
		response := 'HTTP/1.1 407 Proxy Authentication Required\r\nDate: ${gmt}\r\nProxy-Authenticate: Basic realm="V Proxy"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'
		socket.write_string(response) or {}
		return
	}

	mut upstream_host := ''
	mut request_path := ''
	mut forwarded_first_line := first_line

	if method == 'CONNECT' {
		upstream_host = normalize_authority(target, default_https_port)
		if upstream_host == '' {
			send_simple_response(mut socket, '400 Bad Request', 'Missing CONNECT target\n')
			return
		}
	} else {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			upstream_host = host_header
		}
		if upstream_host == '' {
			send_simple_response(mut socket, '400 Bad Request', 'Missing Host header\n')
			return
		}
		upstream_host = normalize_authority(upstream_host, default_http_port)
		forwarded_first_line = '${method} ${request_path} ${version}'
	}

	mut upstream := net.dial_tcp(upstream_host) or {
		eprintln('Failed to connect to ${upstream_host}: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return
	}
	defer {
		upstream.close() or {}
	}

	if method == 'CONNECT' {
		socket.write_string(connection_established) or {
			eprintln('Failed to send CONNECT response: ${err}')
			return
		}
	} else {
		// Parse headers from header_str
		header_str_lines := header_str.split('\r\n')
		mut forwarded_headers := []string{}
		forwarded_headers << forwarded_first_line

		mut has_host_header := false
		for i, line in header_str_lines {
			if i == 0 {
				continue // 忽略第一行（请求行），已在 forwarded_first_line 处理
			}
			if line == '' {
				continue // 忽略空行
			}
			lower := line.to_lower()
			// 移除代理相关的头部，防止循环代理或泄露验证信息
			if lower.starts_with('proxy-authorization:') || lower.starts_with('authorization:')
				|| lower.starts_with('proxy-connection:') {
				continue
			}
			if lower.starts_with('host:') {
				has_host_header = true
			}
			forwarded_headers << line
		}
		if !has_host_header && upstream_host != '' {
			forwarded_headers << 'Host: ${upstream_host}'
		}
		forwarded_headers << 'Via: 1.1 v-proxy'
		forwarded_headers << 'Proxy-Agent: V-Proxy/1.0'
		forwarded_headers << ''
		request_blob := forwarded_headers.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or {
			eprintln('Failed to forward request: ${err}')
			return
		}

		// --- 优化：流式转发 Body ---
		// 不再区分 Content-Length 或 Chunked，
		// 直接将之前读取 header 时多读到的 body 部分发送给上游，
		// 剩余部分交给后续的双向 io.cp 透传。
		if pending_body.len > 0 {
			upstream.write(pending_body) or {
				eprintln('Failed to forward pending body: ${err}')
				return
			}
		}
	}

	// 块作用：建立双向数据通道
	// 处理问题：通过协程实现全双工通信，支持 CONNECT 隧道及普通 HTTP 的流式响应（含 Chunked）
	if method == 'HEAD' {
		// HEAD 响应没有 body，仅单向复制响应头
		io.cp(mut upstream, mut socket) or {}
	} else {
		mut wg := sync.new_waitgroup()
		wg.add(2)
		// 协程 1: 客户端 -> 上游
		go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
			defer {
				src.close() or {}
				dst.close() or {}
				wg.done()
			}
			io.cp(mut src, mut dst) or {}
		}(mut socket, mut upstream, mut wg)
		// 协程 2: 上游 -> 客户端
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
}

// 块作用：目标解析
// 处理问题：从请求路径中提取 Host 和 Path，处理绝对 URL 和相对路径
fn split_target(target string) (string, string) {
	mut authority := ''
	mut path := '/'

	if target.starts_with('http://') || target.starts_with('https://') {
		without_scheme := target.all_after('://')
		slash_index := without_scheme.index('/') or { -1 }
		if slash_index >= 0 {
			authority = without_scheme[..slash_index]
			path = without_scheme[slash_index..]
		} else {
			authority = without_scheme
		}
	} else if target.starts_with('/') {
		path = target
	} else {
		authority = target
	}

	if path == '' {
		path = '/'
	}

	return authority, path
}

fn normalize_authority(authority string, default_port string) string {
	mut result := authority.trim_space()
	if result == '' {
		return result
	}
	if !result.contains(':') {
		result += default_port
	}
	return result
}

fn send_simple_response(mut socket net.TcpConn, status_line string, message string) {
	body := message
	response := 'HTTP/1.1 ${status_line}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	socket.write_string(response) or {}
}

// 块作用：读取头部原始字节
// 处理问题：持续读取直至发现 \r\n\r\n 标志，限制头部最大长度 64KB
fn read_request_head(mut socket net.TcpConn) !([]u8, []u8) {
	mut data := []u8{}
	mut buf := []u8{len: 8192}
	for {
		n := socket.read(mut buf) or { return err }
		if n <= 0 {
			return error('Bad request')
		}
		data << buf[..n]
		if data.len > 65536 {
			return error('Request too large')
		}
		header_end := find_header_end_from(data, if data.len > n + 3 { data.len - n - 3 } else { 0 })
		if header_end >= 0 {
			// 返回 (头部字节数组, 剩余已读取的 body 部分)
			return data[..header_end], data[header_end + 4..]
		}
	}
	return error('Bad request')
}

fn find_header_end_from(data []u8, start int) int {
	if data.len < 4 {
		return -1
	}
	mut i := if start > 0 { start } else { 0 }
	for i + 3 < data.len {
		if data[i] == `\r` && data[i + 1] == `\n` && data[i + 2] == `\r` && data[i + 3] == `\n` {
			return i
		}
		i++
	}
	return -1
}
