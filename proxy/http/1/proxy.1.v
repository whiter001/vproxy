module main

import encoding.base64
import io
import net
import os
import sync
import time

const valid_methods = ['CONNECT', 'POST', 'GET', 'HEAD', 'OPTIONS', 'DELETE', 'PATCH', 'PUT']
const connection_established = 'HTTP/1.1 200 Connection Established\r\n\r\n'
const default_listen_addr = ':5777'
const default_http_port = ':80'
const default_https_port = ':443'

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

	mut client_num := 0
	for {
		mut socket := server.accept() or {
			eprintln('Failed to accept client: ${err}')
			continue
		}
		client_num++
		go handle_client(mut socket, client_num, expected_auth)
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

fn handle_client(mut socket net.TcpConn, client_num int, expected_auth string) {
	start := time.now()
	defer {
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		eprintln('${client_num} client handled in ${duration}s')
	}

	// Read raw socket to avoid buffered reader issues with request body
	mut header_bytes := []u8{}
	for {
		mut buf := []u8{len: 1}
		n := socket.read(mut buf) or {
			send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
			return
		}
		if n == 0 {
			send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
			return
		}
		header_bytes << buf[0]
		// Check for end of headers (\r\n\r\n)
		if header_bytes.len >= 4 {
			end := header_bytes.len - 4
			if header_bytes[end..].hex() == '0d0a0d0a' {
				break
			}
		}
		// Safety limit
		if header_bytes.len > 65536 {
			send_simple_response(mut socket, '400 Bad Request', 'Request too large\n')
			return
		}
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
		if content_length > 0 {
			mut body_buf := []u8{len: content_length}
			mut total_read := 0
			for total_read < content_length {
				n := socket.read(mut body_buf[total_read..]) or { break }
				if n == 0 {
					break
				}
				total_read += n
			}
			if total_read > 0 {
				upstream.write(body_buf[..total_read]) or {
					eprintln('Failed to forward request body: ${err}')
					return
				}
			}
		}
	}

	// Bidirectional copy: spawn both directions, wait for both to complete
	if method == 'HEAD' {
		// HEAD responses have no body, only copy upstream -> client
		io.cp(mut upstream, mut socket) or { eprintln('Proxy copy failed: ${err}') }
	} else {
		mut wg := sync.new_waitgroup()
		wg.add(2)
		go fn (mut src io.Reader, mut dst io.Writer, mut wg sync.WaitGroup) {
			io.cp(mut src, mut dst) or { eprintln('copy error: ${err}') }
			wg.done()
		}(mut socket, mut upstream, mut wg)
		go fn (mut src io.Reader, mut dst io.Writer, mut wg sync.WaitGroup) {
			io.cp(mut src, mut dst) or { eprintln('copy error: ${err}') }
			wg.done()
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
