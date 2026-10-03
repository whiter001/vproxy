// proxy/sps/1/proxy.sps.v
//
// SPS：单端口多协议代理（issue #29）。同一监听口按**首字节**自动识别协议：
//
//   0x05            → SOCKS5（RFC 1928，首字节即 VER）
//   'A'..'Z'        → HTTP 代理（请求方法首字母，GET/POST/CONNECT/... 均为大写 ASCII）
//   其他（含 EOF）   → 拒绝：记一行日志后关闭连接
//
// 处理逻辑完全复用可 import 模块（issue #29 前置拆分）：
// - HTTP：httpsrv.handle_client_preface（preface 传入已预读的首字节）
// - SOCKS5：socks5srv.handle_client_ver（ver_already_read 传入已预读的 0x05）
//
// 边界（有意不做）：
// - SOCKS4 首字节 0x04 与 SS 等协议不在识别范围，按未知协议拒绝。
// - 首字节读取同样受 --idle-timeout 约束：客户端连上后不发送数据，
//   idle 超时后连接被关闭。
module main

import httpsrv
import lifecycle
import net
import policy
import socks5srv
import sync.stdatomic
import time
import upstream as upx
import vpcli
import os

// 块作用：入口函数
// 处理问题：
// - issue #29：单端口多协议 — 首字节识别 HTTP / SOCKS5
// - HTTP 侧鉴权 fail-fast 语义与 http 代理一致（issue #1）
// - SOCKS5 侧 --no-socks5-auth / SOCKS5_NO_AUTH=1 覆盖已配置凭据（与 socks5 一致）
fn main() {
	cfg := vpcli.parse_sps_args(os.args) or {
		eprintln('parse error: ${err}')
		C.exit(1)
	}
	if cfg.show_help {
		vpcli.print_sps_help()
		return
	}
	if cfg.show_version {
		println('vproxy ${vpcli.version}')
		return
	}

	// HTTP 侧鉴权（issue #1）：缺凭据 fail-fast，与 http 代理一致
	expected_auth, require_auth := httpsrv.proxy_auth_config(cfg.http_basic, cfg.http_user, cfg.http_pass,
		cfg.http_require_auth) or {
		eprintln('Error: ${err}')
		eprintln('       Set PROXY_AUTH_USER and PROXY_AUTH_PASS,')
		eprintln('       or PROXY_AUTH_BASIC=<base64(user:pass)>,')
		eprintln('       or PROXY_REQUIRE_AUTH=0 to disable authentication.')
		C.exit(1)
	}

	// SOCKS5 侧：--no-socks5-auth / SOCKS5_NO_AUTH=1 must override configured credentials.
	s5_user := if cfg.s5_no_auth { '' } else { cfg.s5_user }
	s5_pass := if cfg.s5_no_auth { '' } else { cfg.s5_pass }

	// 上级代理（issue #27）：配置了 --parent 则全部流量经上级转发；URL 非法 fail-fast。
	mut parent := ?upx.Parent(none)
	mut parent_safe := ''
	if cfg.parent != '' {
		p := upx.parse_parent(cfg.parent) or {
			eprintln('Error: invalid --parent "${cfg.parent}": ${err}')
			C.exit(1)
		}
		parent = p
		parent_safe = p.safe_str()
	}

	if cfg.config_file != '' {
		eprintln('Config loaded from ${cfg.config_file}')
	}
	// 打印生效配置：password / auth_basic 一律打码，避免敏感信息进启动日志
	// （EffectiveConfig 只有一组 auth 字段，这里展示 HTTP 侧凭据）
	vpcli.print_effective_config(vpcli.EffectiveConfig{
		label:        'sps'
		listen_addr:  cfg.listen_addr
		auth_user:    cfg.http_user
		auth_pass:    cfg.http_pass
		auth_basic:   cfg.http_basic
		log_level:    cfg.log_level
		log_format:   cfg.log_format
		metrics_addr: cfg.metrics_addr
		idle_timeout: cfg.idle_timeout
		allow_rules:  cfg.allow_rules
		deny_rules:   cfg.deny_rules
		client_allow: cfg.client_allow
		client_deny:  cfg.client_deny
		parent:       parent_safe
	})

	// 策略配置（issue #30）：目标黑白名单 + 客户端 IP 黑白名单（两个协议栈共用）
	rules := policy.Rules{
		allow:        cfg.allow_rules
		deny:         cfg.deny_rules
		client_allow: cfg.client_allow
		client_deny:  cfg.client_deny
	}

	idle_dur := cfg.idle_timeout

	// SOCKS5 UDP ASSOCIATE（issue #26）的 relay 绑定地址与 TCP 监听同 host
	relay_host := cfg.listen_addr.all_before_last(':')

	stats_http := &httpsrv.Stats{}
	stats_s5 := &socks5srv.Stats{}

	// Option 跨 go 边界会触发 V 0.5.2 C codegen bug（issue #12），循环外解包一次，
	// dispatch 与下游 handle_client_* 均按值 + 标志传递。
	mut parent_val := upx.Parent{}
	mut has_parent := false
	if p := parent {
		parent_val = p
		has_parent = true
	}

	lifecycle.install_signal_handlers()

	mut server := net.listen_tcp(.ip, cfg.listen_addr) or {
		eprintln('Failed to listen on ${cfg.listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('SPS proxy listening on ${cfg.listen_addr} (idle_timeout=${idle_dur}) ...')

	// 周期性检查停止标志；不设超时则 SIGTERM 后 accept() 永远阻塞。
	server.set_accept_timeout(1 * time.second)
	for {
		if lifecycle.should_stop() {
			eprintln('shutdown: stop signal received, closing listener')
			break
		}
		mut socket := server.accept() or {
			// accept timeout 是正常路径（每 1s 返回一次）；其他错误才报
			if lifecycle.should_stop() {
				break
			}
			// V 0.5.x 在 macOS 上的 accept 超时错误消息是 'net: op timed out; code: 9'，
			// 旧版是 'accept timeout'。两者都接受，避免每秒钟打印一行错误日志。
			msg := err.msg()
			if msg == 'accept timeout' || msg.contains('op timed out') {
				continue
			}
			eprintln('Failed to accept client: ${err}')
			continue
		}
		go dispatch(mut socket, stats_http, stats_s5, expected_auth, require_auth, idle_dur, rules,
			parent_val, has_parent, s5_user, s5_pass, relay_host)
	}

	// 等两个协议栈的所有 in-flight 连接退出后 main 返回，进程退出码 0
	active_http := stdatomic.load_i64(&stats_http.active_conns)
	active_s5 := stdatomic.load_i64(&stats_s5.active_conns)
	if active_http > 0 || active_s5 > 0 {
		eprintln('shutdown: draining ${active_http + active_s5} in-flight connection(s)...')
	}
	stats_http.inflight.wait()
	stats_s5.inflight.wait()
	eprintln('shutdown: complete')
}

// 块作用：首字节嗅探与协议分发（issue #29）
// 处理问题：
// 1. 先 apply_idle_timeout 再读 1 字节：客户端连上不发包时受 idle timeout 约束，
//    读失败 / EOF / 超时 → 静默关闭（只记一行日志）。
// 2. in-flight 计数在 dispatch 内完成（与 socks5srv.serve / httpsrv.serve 的 accept
//    循环一致）：handle_client_ver / handle_client_preface 的 defer 只负责减计数，
//    这里必须先 add，否则优雅退出的 drain 会漏等尚未来得及 spawn 的连接。
// 3. 命中协议后 socket 的关闭与 idle timeout 的（重复）设置都交给
//    handle_client_ver / handle_client_preface，这里不再 close，避免双关。
// 4. 未识别的首字节（含 SOCKS4 的 0x04）：拒绝并关闭；本进程不崩溃，服务继续。
fn dispatch(mut socket net.TcpConn, stats_http &httpsrv.Stats, stats_s5 &socks5srv.Stats,
	expected_auth string, require_auth bool, idle_dur time.Duration, rules policy.Rules,
	parent upx.Parent, has_parent bool, s5_user string, s5_pass string, relay_host string) {
	lifecycle.apply_idle_timeout(mut socket, idle_dur)

	mut first_byte := []u8{len: 1}
	n := socket.read(mut first_byte) or {
		eprintln('sps: failed to read protocol first byte: ${err}')
		socket.close() or {}
		return
	}
	if n <= 0 {
		eprintln('sps: client closed before sending first byte')
		socket.close() or {}
		return
	}
	b := first_byte[0]

	if b == u8(5) {
		// SOCKS5：首字节即 VER=0x05，已预读，交给 socks5srv 续读 NMETHODS/METHODS
		stdatomic.add_i64(&stats_s5.active_conns, 1)
		stats_s5.inflight.add(1)
		go socks5srv.handle_client_ver(mut socket, stats_s5, idle_dur, s5_user, s5_pass, rules,
			parent, has_parent, relay_host, b)
		return
	}

	if b >= `A` && b <= `Z` {
		// HTTP：请求方法首字母（GET/POST/CONNECT/HEAD/... 均为大写 ASCII），
		// 预读字节作为请求头解析的初始缓冲
		stdatomic.add_i64(&stats_http.active_conns, 1)
		stats_http.inflight.add(1)
		go httpsrv.handle_client_preface(mut socket, stats_http, expected_auth, require_auth,
			idle_dur, rules, parent, has_parent, [b])
		return
	}

	eprintln('sps: unrecognized protocol (first byte 0x${b:02x}), closing connection')
	socket.close() or {}
}
