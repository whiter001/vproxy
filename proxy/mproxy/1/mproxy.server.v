// proxy/mproxy/1/mproxy.server.v
//
// mproxy server 模式：XOR 隧道 server。
//
// listen on -l，接受 mproxy client 发来的 XOR 编码字节 → 反向 XOR ^ 1 还原
// → 解析 HTTP 请求 → dial 上游（直连或经 SOCKS5）→ 双向 io.cp 中继，
// 出方向再 XOR ^ 1 让 client 端能还原。
//
// 对应原 C 版 mproxy.c 中 io_flag == R_C_DEC 路径（server 端接收数据时解码、
// 发送时编码）。
//
// 架构（与 mproxy.serve 类似）：
// - listen → accept → goroutine handle_client
// - 解析 XOR 还原后的 HTTP 请求
// - 通过 socks5_dial.dial() 或 net.dial_tcp() 获取上游 socket
// - 双向 io.cp，client→upstream 解码（已 XOR 还原），upstream→client 再编码
//
// 复用：
// - proxy/lifecycle/lifecycle.v：信号处理 / idle timeout
// - proxy/mproxy/xor/xor.v：xor.apply XOR helper
// - proxy/mproxy/socks5_dial/socks5_dial.v：SOCKS5 upstream 拨号

module main

import flag
import lifecycle
import net
import os
import socks5_dial
import sync
import sync.stdatomic
import time
import xor

const default_listen = ':8081'
const connection_established = 'HTTP/1.1 200 Connection Established\r\n\r\n'
const default_http_port = ':80'
const default_https_port = ':443'
const max_header_size = 65536

struct Stats {
mut:
	active_conns i64
	inflight     sync.WaitGroup
}

struct Config {
mut:
	listen_addr  string
	upstream_url string
	idle_timeout time.Duration
	show_help    bool
	show_version bool
}

fn parse_args(args []string) !Config {
	mut rest := args[1..]
	if rest.len > 0 && !rest[0].starts_with('-') {
		sub := rest[0]
		if sub == 'help' {
			return Config{
				show_help: true
			}
		}
		if sub == 'version' {
			return Config{
				show_version: true
			}
		}
		if sub != 'server' {
			return error('unknown subcommand "${sub}" (expected: server | help | version)')
		}
		rest = rest[1..]
	}

	mut fp := flag.new_flag_parser(rest)
	fp.application('vproxy mproxy server')
	fp.description('XOR tunnel server: receive XOR data from mproxy client, forward to upstream HTTP')

	listen := fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or {
		''
	}
	upstream := fp.string_opt('upstream', `u`, 'SOCKS5 upstream URL', flag.FlagConfig{
		val_desc: 'url'
	}) or { '' }
	idle := fp.int_opt('idle', `i`, 'idle timeout in seconds (0 to disable)', flag.FlagConfig{
		val_desc: 'sec'
	}) or { -1 }
	help := fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	version := fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or { false }
	fp.finalize() or { return error(err.msg()) }

	final_listen := if listen != '' { listen } else { os.getenv_opt('MPROXY_LISTEN_ADDR') or {
			default_listen} }
	final_upstream := if upstream != '' { upstream } else { os.getenv_opt('MPROXY_UPSTREAM') or {
			''} }

	mut idle_dur := time.Duration(300) * time.second
	if idle >= 0 {
		idle_dur = if idle == 0 { time.infinite } else { time.Duration(idle) * time.second }
	} else {
		env_idle := os.getenv_opt('MPROXY_IDLE_TIMEOUT') or { '' }
		if env_idle != '' {
			secs := env_idle.int()
			if secs > 0 {
				idle_dur = time.Duration(secs) * time.second
			} else if secs == 0 {
				idle_dur = time.infinite
			}
		}
	}

	return Config{
		listen_addr:  final_listen
		upstream_url: final_upstream
		idle_timeout: idle_dur
		show_help:    help
		show_version: version
	}
}

fn print_help() {
	println('Usage: vproxy mproxy server [options]')
	println('')
	println('XOR tunnel server. Listens for XOR-encoded bytes from mproxy client, decodes,')
	println('forwards HTTP to upstream (direct or via SOCKS5), encodes response back.')
	println('')
	println('Options:')
	println('  -l, --listen addr   listen address (default :8081)')
	println('  -u, --upstream url  SOCKS5 upstream URL (empty = direct)')
	println('  -i, --idle sec      idle timeout in seconds (default 300, 0 to disable)')
	println('  -h, --help          show help and exit')
	println('  -v, --version       show version and exit')
	println('')
	println('Env vars: MPROXY_LISTEN_ADDR, MPROXY_UPSTREAM, MPROXY_IDLE_TIMEOUT')
}

fn main() {
	cfg := parse_args(os.args) or {
		eprintln('parse error: ${err}')
		C.exit(1)
	}
	if cfg.show_help {
		print_help()
		return
	}
	if cfg.show_version {
		println('mproxy server 0.1.0')
		return
	}

	mut upstream_cfg := socks5_dial.UpstreamConfig{}
	if cfg.upstream_url != '' {
		upstream_cfg = socks5_dial.parse_url(cfg.upstream_url) or {
			eprintln('invalid -u upstream URL: ${err}')
			C.exit(1)
		}
		eprintln('mproxy server: listen=${cfg.listen_addr} upstream=${cfg.upstream_url}')
	} else {
		eprintln('mproxy server: listen=${cfg.listen_addr} (direct)')
	}

	lifecycle.install_signal_handlers()
	idle_dur := cfg.idle_timeout

	mut server := net.listen_tcp(.ip, cfg.listen_addr) or {
		eprintln('Failed to listen on ${cfg.listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or {}
	}

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
			msg := err.msg()
			if msg == 'accept timeout' || msg.contains('op timed out') {
				continue
			}
			eprintln('Failed to accept client: ${err}')
			continue
		}
		stdatomic.add_i64(&stats.active_conns, 1)
		stats.inflight.add(1)
		go handle_client(mut socket, stats, upstream_cfg, cfg.upstream_url != '', idle_dur)
	}

	active := stdatomic.load_i64(&stats.active_conns)
	if active > 0 {
		eprintln('shutdown: draining ${active} in-flight connection(s)...')
	}
	stats.inflight.wait()
	eprintln('shutdown: complete')
}

// 块作用：从 XOR 编码的 socket 读 HTTP 请求头，按字节 XOR ^ 1 解码
// 处理问题：mproxy client 发送时 XOR ^ 1 编码，server 端需解码才能还原原始 HTTP。
// 这里按 buffer 读取（4096B/批），不是 byte-by-byte，因为 V 0.5.x 的 socket.read
// 在 len=1 时容易触发额外 accept/connection 行为。
fn read_xor_request_head(mut socket net.TcpConn) !([]u8, []u8) {
	mut data := []u8{}
	for {
		mut buf := []u8{len: 4096}
		mut n := socket.read(mut buf) or { return err }
		if n <= 0 {
			if data.len == 0 {
				return error('Bad request')
			}
			return error('incomplete request')
		}
		// 解码这一批字节
		for i in 0 .. n {
			buf[i] = buf[i] ^ 1
			data << buf[i]
		}
		if data.len > max_header_size {
			return error('Request too large')
		}
		// 检查末尾 4 字节是否是 \r\n\r\n
		if data.len >= 4 && data[data.len - 4] == `\r` && data[data.len - 3] == `\n`
			&& data[data.len - 2] == `\r` && data[data.len - 1] == `\n` {
			header_end := data.len - 4
			return data[..header_end], data[header_end + 4..]
		}
	}
	return error('Bad request')
}

// 块作用：客户端连接处理
// 1. 读 XOR 编码的 HTTP 请求头
// 2. 解析 method / target / Host
// 3. dial 上游（直连或 SOCKS5）
// 4. CONNECT 回 200 + 双向；非 CONNECT 转发 header + body
// 5. 出方向再 XOR ^ 1，让 client 能还原
fn handle_client(mut socket net.TcpConn, stats &Stats, upstream_cfg socks5_dial.UpstreamConfig,
	use_upstream bool, idle_dur time.Duration) {
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

	header_bytes, mut pending_body := read_xor_request_head(mut socket) or {
		eprintln('Failed to read XOR request head: ${err}')
		return
	}

	header_str := header_bytes.bytestr()
	first_line := header_str.all_before('\r\n')
	if first_line == '' {
		eprintln('Empty first line from XOR client')
		return
	}
	first_parts := first_line.split(' ')
	if first_parts.len < 3 {
		eprintln('Malformed first line: ${first_line}')
		return
	}

	method := first_parts[0].to_upper()
	target := first_parts[1]

	mut upstream_host := ''
	mut request_path := ''
	if method == 'CONNECT' {
		upstream_host = normalize_authority(target, default_https_port)
	} else {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			mut host_line := ''
			for line in header_str.split('\r\n') {
				if line.to_lower().starts_with('host:') {
					host_line = line.all_after(':').trim_space()
					break
				}
			}
			upstream_host = normalize_authority(host_line, default_http_port)
		} else {
			upstream_host = normalize_authority(upstream_host, default_http_port)
		}
	}

	if upstream_host == '' {
		eprintln('Missing upstream target')
		return
	}

	host_only, mut port_u16 := parse_host_port(upstream_host)
	if port_u16 == 0 {
		port_u16 = if method == 'CONNECT' { u16(443) } else { u16(80) }
	}

	mut upstream := dial_upstream(use_upstream, upstream_cfg, host_only, port_u16) or {
		eprintln('upstream dial failed: ${err}')
		return
	}
	defer {
		upstream.close() or {}
	}
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	if method == 'CONNECT' {
		// 回 200 Connection Established 给 client 端（编码后）
		encoded_resp := encode_string(connection_established)
		socket.write(encoded_resp) or { return }
	} else {
		// 改写首行为 origin form
		header_str_lines := header_str.split('\r\n')
		mut forwarded := []string{}
		forwarded << '${method} ${request_path} HTTP/1.1'
		mut has_host := false
		for i, line in header_str_lines {
			if i == 0 {
				continue
			}
			if line == '' {
				continue
			}
			lower := line.to_lower()
			if lower.starts_with('proxy-authorization:') || lower.starts_with('authorization:')
				|| lower.starts_with('proxy-connection:') {
				continue
			}
			if lower.starts_with('host:') {
				has_host = true
			}
			forwarded << line
		}
		if !has_host {
			forwarded << 'Host: ${upstream_host}'
		}
		forwarded << 'Via: 1.1 mproxy-server'
		forwarded << ''
		request_blob := forwarded.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or { return }
		if pending_body.len > 0 {
			upstream.write(pending_body) or { return }
		}
	}

	wg := sync.new_waitgroup()
	wg.add(2)
	// upstream → client：响应按字节 XOR ^ 1 编码后再发
	//（upstream 返回的是 raw 数据；server 编码后 client 解码还原）
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		xor_pipe(mut src, mut dst) or {}
	}(mut upstream, mut socket, wg)
	// client → upstream：client 发来的是已编码字节，server 端 XOR ^ 1 解码后 raw 转发给 upstream
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		xor_pipe(mut src, mut dst) or {}
	}(mut socket, mut upstream, wg)
	wg.wait()
}

// 块作用：把字符串编码成 XOR 字节序列，用于发送连接已建立响应给 client
fn encode_string(s string) []u8 {
	mut bytes := s.bytes()
	xor.apply(mut bytes)
	return bytes
}

// 块作用：io.cp 的 XOR 包装
fn xor_pipe(mut src net.TcpConn, mut dst net.TcpConn) ! {
	mut buf := []u8{len: 8192}
	for {
		n := src.read(mut buf) or { return err }
		if n <= 0 {
			return
		}
		mut payload := buf[..n].clone()
		xor.apply(mut payload)
		dst.write(payload) or { return err }
	}
}

// 块作用：统一上游 dial
fn dial_upstream(use_upstream bool, cfg socks5_dial.UpstreamConfig, host string, port u16) !&net.TcpConn {
	if use_upstream {
		return socks5_dial.dial(cfg, host, port)
	}
	return net.dial_tcp('${host}:${port}')
}

fn parse_host_port(s string) (string, u16) {
	colon_idx := s.last_index(':') or { return s, u16(0) }
	host := s[..colon_idx]
	port := s[colon_idx + 1..].u16()
	return host, port
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
