// proxy/mproxy/1/mproxy.serve.v
//
// mproxy serve 模式：HTTP 转发 + HTTPS CONNECT 隧道，可选 `-u` SOCKS5 upstream
// 链式转发。V 语言现代版，对应原 C 版 mproxy.c 中 io_flag==FLG_NONE 路径。
//
// 架构（与 vproxy 一致）：
// - listen → accept → goroutine handle_client
// - handle_client 解析 HTTP / CONNECT
// - 通过 socks5_dial.dial() 或 net.dial_tcp() 获取上游 socket
// - 双向 io.cp 透传
// - 优雅退出：lifecycle.install_signal_handlers + drain inflight WaitGroup
//
// 复用：
// - proxy/lifecycle/lifecycle.v：信号处理 / idle timeout
// - proxy/mproxy/socks5_dial/socks5_dial.v：SOCKS5 upstream 拨号

module main

import flag
import io
import lifecycle
import net
import os
import socks5_dial
import sync
import sync.stdatomic
import time

const default_listen = ':8080'
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

// 块作用：解析命令行 + 环境变量
// 处理问题：CLI > env > default，与 vproxy 命名风格对齐
// -l PROXY_LISTEN_ADDR 或 MPROXY_LISTEN_ADDR
// -u MPROXY_UPSTREAM
// -i MPROXY_IDLE_TIMEOUT
fn parse_args(args []string) !Config {
	mut rest := args[1..]
	// 去掉 subcommand "serve"（与 vpcli 风格一致）
	if rest.len > 0 && !rest[0].starts_with('-')
		&& (rest[0] == 'serve' || rest[0] == 'help' || rest[0] == 'version') {
		if rest[0] == 'help' {
			return Config{
				show_help: true
			}
		}
		if rest[0] == 'version' {
			return Config{
				show_version: true
			}
		}
		rest = rest[1..]
	}

	mut fp := flag.new_flag_parser(rest)
	fp.application('vproxy mproxy serve')
	fp.description('Minimal HTTP forward proxy with optional SOCKS5 upstream chaining')

	listen := fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or {
		''
	}
	upstream := fp.string_opt('upstream', `u`,
		'SOCKS5 upstream URL (socks5://[user:pass@]host:port)', flag.FlagConfig{ val_desc: 'url' }) or {
		''
	}
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
		if idle == 0 {
			idle_dur = time.infinite
		} else {
			idle_dur = time.Duration(idle) * time.second
		}
	} else {
		// 从 env 读取
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
	println('Usage: vproxy mproxy serve [options]')
	println('')
	println('Minimal HTTP forward proxy with optional SOCKS5 upstream.')
	println('')
	println('Options:')
	println('  -l, --listen addr   listen address (default :8080)')
	println('  -u, --upstream url  SOCKS5 upstream URL (e.g. socks5://user:pass@host:port)')
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
		println('mproxy 0.1.0')
		return
	}

	// 如果有 upstream URL，预先解析（fail-fast）
	mut upstream_cfg := socks5_dial.UpstreamConfig{}
	if cfg.upstream_url != '' {
		upstream_cfg = socks5_dial.parse_url(cfg.upstream_url) or {
			eprintln('invalid -u upstream URL: ${err}')
			C.exit(1)
		}
		eprintln('mproxy serve: listen=${cfg.listen_addr} upstream=${cfg.upstream_url}')
	} else {
		eprintln('mproxy serve: listen=${cfg.listen_addr} (direct)')
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

// 块作用：解析 HTTP 头（找 \r\n\r\n），限制 64KB
// 处理问题：与 vproxy proxy.1.v:369-403 相同模式，独立复制避免改 vproxy
fn read_request_head(mut socket net.TcpConn) !([]u8, []u8) {
	mut data := []u8{}
	mut buf := []u8{len: 8192}
	for {
		n := socket.read(mut buf) or { return err }
		if n <= 0 {
			return error('Bad request')
		}
		data << buf[..n]
		if data.len > max_header_size {
			return error('Request too large')
		}
		header_end := find_header_end_from(data,
			if data.len > n + 3 { data.len - n - 3 } else { 0 })
		if header_end >= 0 {
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

// 块作用：客户端连接处理
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
	if method != 'CONNECT' && method != 'GET' && method != 'POST' && method != 'HEAD' {
		send_simple_response(mut socket, '405 Method Not Allowed', 'Unsupported method\n')
		return
	}

	target := first_parts[1]

	mut upstream_host := ''
	mut request_path := ''
	if method == 'CONNECT' {
		upstream_host = normalize_authority(target, default_https_port)
	} else {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			// 退化到 Host 头
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
		send_simple_response(mut socket, '400 Bad Request', 'Missing upstream target\n')
		return
	}

	// dial 上游：直连或经 SOCKS5
	host_only, mut port_u16 := parse_host_port(upstream_host)
	if port_u16 == 0 {
		port_u16 = if method == 'CONNECT' { u16(443) } else { u16(80) }
	}

	// 用辅助函数 dial_upstream 统一返回类型（&net.TcpConn），避免 if/else 分支类型推断不一致
	mut upstream := dial_upstream(use_upstream, upstream_cfg, host_only, port_u16) or {
		eprintln('upstream dial failed: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return
	}
	defer {
		upstream.close() or {}
	}
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	if method == 'CONNECT' {
		socket.write_string(connection_established) or { return }
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
		forwarded << 'Via: 1.1 mproxy'
		forwarded << ''
		request_blob := forwarded.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or { return }
		if pending_body.len > 0 {
			upstream.write(pending_body) or { return }
		}
	}

	if method == 'HEAD' {
		io.cp(mut upstream, mut socket) or {}
	} else {
		relay_both_ways(mut socket, mut upstream)
	}
}

// 块作用：双向 io.cp 中继（与 vproxy 模式一致）
fn relay_both_ways(mut a net.TcpConn, mut b net.TcpConn) {
	wg := sync.new_waitgroup()
	wg.add(2)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut a, mut b, wg)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut b, mut a, wg)
	wg.wait()
}

// 块作用：拆分 host:port，返回 (host, port)。port=0 表示原串无端口
fn parse_host_port(s string) (string, u16) {
	colon_idx := s.last_index(':') or { return s, u16(0) }
	host := s[..colon_idx]
	port := s[colon_idx + 1..].u16()
	return host, port
}

// 块作用：统一上游 dial：直连或经 SOCKS5（避免调用方 if/else 类型推断问题）
fn dial_upstream(use_upstream bool, cfg socks5_dial.UpstreamConfig, host string, port u16) !&net.TcpConn {
	if use_upstream {
		return socks5_dial.dial(cfg, host, port)
	}
	return net.dial_tcp('${host}:${port}')
}

// 块作用：补默认端口
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

// 块作用：拆绝对 URI / authority / path
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

fn send_simple_response(mut socket net.TcpConn, status_line string, message string) {
	body := message
	response := 'HTTP/1.1 ${status_line}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	socket.write_string(response) or {}
}
