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
		stdatomic.add_i64(&stats.active_conns, 1)
		go handle_client(mut socket, stats, expected_auth)
	}
}

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
		lower := line.to_lower()
		if lower.starts_with('proxy-authorization:') {
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
	provided_cred := proxy_authorization[6..].trim_space()
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
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed\n')
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
		mut content_length := 0
		mut is_chunked := false
		for i, line in header_str_lines {
			if i == 0 {
				continue // skip request line, already added as forwarded_first_line
			}
			if line == '' {
				continue // skip empty lines from headers
			}
			lower := line.to_lower()
			if lower.starts_with('proxy-authorization:') || lower.starts_with('proxy-connection:') {
				continue
			}
			if lower.starts_with('host:') {
				has_host_header = true
			}
			if lower.starts_with('content-length:') {
				content_length = line.all_after(':').trim_space().int()
			}
			if lower.starts_with('transfer-encoding:') && lower.contains('chunked') {
				is_chunked = true
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

		// Forward request body if present
		if is_chunked {
			send_simple_response(mut socket, '501 Not Implemented', 'Chunked request body is not supported\n')
			return
		} else if content_length > 0 {
			forward_request_body(mut socket, mut upstream, mut pending_body, content_length) or {
				eprintln('Failed to forward request body: ${err}')
				return
			}
		}
	}

	// Bidirectional copy: spawn both directions
	if method == 'HEAD' {
		// HEAD responses have no body, only copy upstream -> client
		io.cp(mut upstream, mut socket) or {}
	} else {
		mut wg := sync.new_waitgroup()
		wg.add(2)
		go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
			defer {
				wg.done()
				dst.close() or {} // Close destination to signal EOF or error
			}
			io.cp(mut src, mut dst) or {}
		}(mut socket, mut upstream, mut wg)
		go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
			defer {
				wg.done()
				dst.close() or {} // Close destination to signal EOF or error
			}
			io.cp(mut src, mut dst) or {}
		}(mut upstream, mut socket, mut wg)
		wg.wait()
	}
}

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

fn read_request_head(mut socket net.TcpConn) !([]u8, []u8) {
	mut data := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := socket.read(mut buf) or { return err }
		if n <= 0 {
			return error('Bad request')
		}
		data << buf[..n]
		if data.len > 65536 {
			return error('Request too large')
		}
		header_end := find_header_end(data)
		if header_end >= 0 {
			return data[..header_end], data[header_end + 4..]
		}
	}
	return error('Bad request')
}

fn find_header_end(data []u8) int {
	if data.len < 4 {
		return -1
	}
	for i := 0; i + 3 < data.len; i++ {
		if data[i] == `\r` && data[i + 1] == `\n` && data[i + 2] == `\r` && data[i + 3] == `\n` {
			return i
		}
	}
	return -1
}

fn forward_request_body(mut socket net.TcpConn, mut upstream net.TcpConn, mut pending_body []u8, content_length int) ! {
	mut remaining := content_length
	if pending_body.len > 0 {
		take := if pending_body.len < remaining { pending_body.len } else { remaining }
		if take > 0 {
			upstream.write(pending_body[..take]) or { return err }
			remaining -= take
		}
	}
	mut buf := []u8{len: 4096}
	for remaining > 0 {
		read_size := if remaining < buf.len { remaining } else { buf.len }
		n := socket.read(mut buf[..read_size]) or { return err }
		if n <= 0 {
			return error('Unexpected EOF while reading request body')
		}
		upstream.write(buf[..n]) or { return err }
		remaining -= n
	}
}
