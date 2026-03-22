module main

import io
import net
import os
import sync
import sync.stdatomic
import time

const default_listen_addr = ':5778'

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
}

fn main() {
	listen_addr := os.getenv_opt('SOCKS5_LISTEN_ADDR') or { default_listen_addr }

	mut server := net.listen_tcp(.ip, listen_addr) or {
		eprintln('Failed to listen on ${listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('SOCKS5 proxy listening on ${listen_addr} ...')

	stats := &Stats{}

	for {
		mut socket := server.accept() or {
			eprintln('Failed to accept client: ${err}')
			continue
		}
		stdatomic.add_i64(&stats.active_conns, 1)
		go handle_client(mut socket, stats)
	}
}

fn handle_client(mut socket net.TcpConn, stats &Stats) {
	start := time.now()
	defer {
		stdatomic.add_i64(&stats.active_conns, -1)
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		eprintln('Client handled in ${duration}s. Active: ${stdatomic.load_i64(&stats.active_conns)}')
	}

	if !handle_greeting_and_auth(mut socket) {
		return
	}

	handle_request(mut socket)
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

fn handle_request(mut socket net.TcpConn) {
	mut header := []u8{len: 4}
	n := socket.read(mut header) or {
		eprintln('Failed to read request header: ${err}')
		send_reply(mut socket, socks5_rep_server_failure, '', 0)
		return
	}
	if n < 4 {
		send_reply(mut socket, socks5_rep_server_failure, '', 0)
		return
	}

	ver := header[0]
	cmd := header[1]
	atyp := header[3]

	if ver != socks5_version {
		send_reply(mut socket, socks5_rep_server_failure, '', 0)
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
			for i := 0; i < 8; i++ {
				val := (u16(addr[i * 2]) << 8) | u16(addr[i * 2 + 1])
				parts[i] = val.hex()
			}
			target_host = parts.join(':')
			mut port := []u8{len: 2}
			socket.read(mut port) or {}
			target_port = (u16(port[0]) << 8) | u16(port[1])
		}
		else {
			send_reply(mut socket, socks5_rep_address_not_supported, '', 0)
			return
		}
	}

	match cmd {
		socks5_cmd_connect {
			handle_connect(mut socket, target_host, target_port)
		}
		else {
			send_reply(mut socket, socks5_rep_command_not_supported, '', 0)
		}
	}
}

fn handle_connect(mut socket net.TcpConn, target_host string, target_port u16) {
	mut upstream := net.dial_tcp('${target_host}:${target_port}') or {
		eprintln('Failed to connect to ${target_host}:${target_port}: ${err}')
		send_reply(mut socket, socks5_rep_connection_refused, '', 0)
		return
	}
	defer {
		upstream.close() or {}
	}

	send_reply(mut socket, socks5_rep_success, '0.0.0.0', 0)

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

fn send_reply(mut socket net.TcpConn, rep u8, bind_addr string, bind_port u16) {
	mut reply := []u8{len: 10}
	reply[0] = socks5_version
	reply[1] = rep
	reply[2] = 0
	reply[3] = socks5_atyp_ipv4

	addr_parts := bind_addr.split('.')
	if addr_parts.len == 4 {
		for i, part in addr_parts {
			reply[4 + i] = u8(part.int())
		}
	} else {
		reply[4] = 0
		reply[5] = 0
		reply[6] = 0
		reply[7] = 0
	}

	reply[8] = u8(bind_port >> 8)
	reply[9] = u8(bind_port & 0xff)

	socket.write(reply) or {
		eprintln('Failed to send reply: ${err}')
	}
}
