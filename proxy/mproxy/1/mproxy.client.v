// proxy/mproxy/1/mproxy.client.v
//
// mproxy client 模式：XOR 隧道 client。
//
// listen on -l，接受本地客户端 TCP 连接 → dial -r 远端 mproxy server →
// 双向 io.cp 中继，过程中所有字节按 ^ 1 翻转（"加密"）。
//
// 对应原 C 版 mproxy.c 中 io_flag == W_S_ENC 路径（client 端发送数据时编码、
// 接收时由 server 端解码）。
//
// 架构（与 mproxy.serve 类似）：
// - listen → accept → goroutine handle_client
// - 客户端 ↔ 远端双向 io.cp，goroutine 内 XOR 包一层
// - 优雅退出：复用 lifecycle.install_signal_handlers + drain
//
// 复用：
// - proxy/lifecycle/lifecycle.v：信号处理 / idle timeout
// - proxy/mproxy/xor/xor.v：xor.apply XOR helper

module main

import flag
import io
import lifecycle
import net
import os
import sync
import sync.stdatomic
import time
import xor

const default_listen = ':8080'

struct Stats {
mut:
	active_conns i64
	inflight     sync.WaitGroup
}

struct Config {
mut:
	listen_addr  string
	remote       string // 远端 mproxy server 地址，必填
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
		if sub != 'client' {
			return error('unknown subcommand "${sub}" (expected: client | help | version)')
		}
		rest = rest[1..]
	}

	mut fp := flag.new_flag_parser(rest)
	fp.application('vproxy mproxy client')
	fp.description('XOR tunnel client: local listen -> XOR encode -> remote mproxy server')

	listen := fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or {
		''
	}
	remote := fp.string_opt('remote', `r`, 'remote mproxy server (host:port)', flag.FlagConfig{
		val_desc: 'host:port'
	}) or { '' }
	idle := fp.int_opt('idle', `i`, 'idle timeout in seconds (0 to disable)', flag.FlagConfig{
		val_desc: 'sec'
	}) or { -1 }
	help := fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	version := fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or { false }
	fp.finalize() or { return error(err.msg()) }

	final_listen := if listen != '' { listen } else { os.getenv_opt('MPROXY_LISTEN_ADDR') or {
			default_listen} }
	final_remote := if remote != '' { remote } else { os.getenv_opt('MPROXY_REMOTE') or { '' } }

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

	if final_remote == '' {
		return error('missing -r remote HOST:PORT (or MPROXY_REMOTE env)')
	}

	return Config{
		listen_addr:  final_listen
		remote:       final_remote
		idle_timeout: idle_dur
		show_help:    help
		show_version: version
	}
}

fn print_help() {
	println('Usage: vproxy mproxy client [options]')
	println('')
	println('XOR tunnel client. Listens locally, forwards to remote mproxy server with XOR ^ 1.')
	println('')
	println('Options:')
	println('  -l, --listen addr      listen address (default :8080)')
	println('  -r, --remote host:port remote mproxy server (required)')
	println('  -i, --idle sec         idle timeout in seconds (default 300, 0 to disable)')
	println('  -h, --help             show help and exit')
	println('  -v, --version          show version and exit')
	println('')
	println('Env vars: MPROXY_LISTEN_ADDR, MPROXY_REMOTE, MPROXY_IDLE_TIMEOUT')
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
		println('mproxy client 0.1.0')
		return
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

	eprintln('mproxy client: listen=${cfg.listen_addr} remote=${cfg.remote}')

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
		go handle_client(mut socket, cfg.remote, stats, idle_dur)
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
// 1. dial 远端 mproxy server（直连，不做 SOCKS5；如有需求可加 -u 选项）
// 2. 双向 io.cp 中继，两方向都 XOR ^ 1（客户端发送时编码，服务端解码）
fn handle_client(mut socket net.TcpConn, remote string, stats &Stats, idle_dur time.Duration) {
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

	mut upstream := net.dial_tcp(remote) or {
		eprintln('Failed to dial remote ${remote}: ${err}')
		socket.close() or {}
		return
	}
	defer {
		upstream.close() or {}
	}
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	wg := sync.new_waitgroup()
	wg.add(2)
	// 客户端 → 远端：编码（client 写出方向）
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		xor_pipe(mut src, mut dst) or {}
	}(mut socket, mut upstream, wg)
	// 远端 → 客户端：解码（远端 server 端把响应编码过来，client 端需解码还原）
	go fn (mut src net.TcpConn, mut dst net.TcpConn, wg &sync.WaitGroup) {
		defer {
			src.close() or {}
			dst.close() or {}
			wg.done()
		}
		xor_pipe(mut src, mut dst) or {}
	}(mut upstream, mut socket, wg)
	wg.wait()
}

// 块作用：io.cp 的 XOR 包装版本——拷贝每批字节后 XOR ^ 1 再写出去
// 处理问题：io.cp 内部走 Reader/Writer 接口，不能中途插入字节变换。
// 手动循环 read → xor → write。
fn xor_pipe(mut src net.TcpConn, mut dst net.TcpConn) ! {
	for {
		mut buf := []u8{len: 4096}
		mut n := src.read(mut buf) or { return err }
		if n <= 0 {
			return
		}
		// XOR buffer 中的有效字节
		for i in 0 .. n {
			buf[i] = buf[i] ^ 1
		}
		dst.write(buf[..n]) or { return err }
	}
}
