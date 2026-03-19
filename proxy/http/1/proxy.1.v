module main

import encoding.base64
import io
import net
import os
import time

const valid_methods = ['CONNECT', 'POST', 'GET', 'OPTIONS', 'DELETE', 'PATCH', 'PUT']
const connection_established = 'HTTP/1.1 200 Connection established\r\nConnection: close\r\n\r\n'
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
		duration := time.since(start)
		eprintln('${client_num} client handled in ${duration}s')
	}
	defer {
		socket.close() or {}
	}

	mut reader := io.new_buffered_reader(reader: socket)
	defer {
		reader.free()
	}

	first_line := reader.read_line() or {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return
	}
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

	mut header_lines := []string{cap: 16}
	header_lines << first_line
	mut proxy_authorization := ''
	mut host_header := ''

	for {
		line := reader.read_line() or {
			send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
			return
		}
		if line == '' {
			break
		}

		lower := line.to_lower()
		if lower.starts_with('proxy-authorization:') {
			proxy_authorization = line.all_after(':').trim_space()
		} else if lower.starts_with('host:') {
			host_header = line.all_after(':').trim_space()
		}
		header_lines << line
	}

	if proxy_authorization != 'Basic ${expected_auth}' {
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
		mut forwarded_headers := []string{cap: header_lines.len + 1}
		forwarded_headers << forwarded_first_line

		mut has_host_header := false
		for line in header_lines[1..] {
			lower := line.to_lower()
			if lower.starts_with('proxy-authorization:') || lower.starts_with('proxy-connection:') {
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
		forwarded_headers << ''
		request_blob := forwarded_headers.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or {
			eprintln('Failed to forward request: ${err}')
			return
		}
	}

	go io.cp(mut upstream, mut socket)
	io.cp(mut socket, mut upstream) or { eprintln('Proxy copy failed: ${err}') }
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
