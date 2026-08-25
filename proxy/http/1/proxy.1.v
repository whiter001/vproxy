module main

import encoding.base64
import lifecycle
import net
import os
import strings
import sync
import sync.stdatomic
import time
import vpcli

const valid_methods = ['CONNECT', 'POST', 'GET', 'HEAD', 'OPTIONS', 'DELETE', 'PATCH', 'PUT']
const connection_established = 'HTTP/1.1 200 Connection Established\r\n\r\n'
const default_http_port = ':80'
const default_https_port = ':443'

struct Stats {
mut:
	active_conns                  i64
	connections_ok_total          i64            // 成功建立转发/隧道的连接累计
	errors_auth_failed_total      i64            // 鉴权失败累计
	errors_upstream_connect_total i64            // 上游连接失败累计
	errors_idle_timeout_total     i64            // idle timeout 累计（读超时）
	bytes_in                      i64            // 客户端 → 上游 转发字节累计
	bytes_out                     i64            // 上游 → 客户端 转发字节累计
	inflight                      sync.WaitGroup // 跟踪在飞连接，用于优雅退出（issue #5）
}

// 块作用：入口函数
// 处理问题：
// - issue #4：CLI 参数解析（vpcli.parse_http_args）
// - issue #1：PROXY_REQUIRE_AUTH=0 / fail-fast 配置
// - issue #5：SIGINT/SIGTERM 优雅退出 + idle timeout
fn main() {
	cfg := vpcli.parse_http_args(os.args) or {
		eprintln('parse error: ${err}')
		C.exit(1)
	}
	if cfg.show_help {
		vpcli.print_http_help()
		return
	}
	if cfg.show_version {
		println('vproxy ${vpcli.version}')
		return
	}

	expected_auth, require_auth := proxy_auth_config(cfg.auth_basic, cfg.auth_user, cfg.auth_pass,
		cfg.require_auth) or {
		eprintln('Error: ${err}')
		eprintln('       Set PROXY_AUTH_USER and PROXY_AUTH_PASS,')
		eprintln('       or PROXY_AUTH_BASIC=<base64(user:pass)>,')
		eprintln('       or PROXY_REQUIRE_AUTH=0 to disable authentication.')
		C.exit(1)
	}

	lifecycle.install_signal_handlers()
	idle_dur := cfg.idle_timeout

	mut server := net.listen_tcp(.ip, cfg.listen_addr) or {
		eprintln('Failed to listen on ${cfg.listen_addr}: ${err}')
		return
	}
	defer {
		server.close() or { eprintln('Error closing server: ${err}') }
	}

	eprintln('Listen on ${cfg.listen_addr} (idle_timeout=${idle_dur}) ...')

	stats := &Stats{}
	if cfg.metrics_addr != '' {
		go metrics_server(cfg.metrics_addr, stats)
	}
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
		stdatomic.add_i64(&stats.active_conns, 1) // 原子计数器
		stats.inflight.add(1)
		go handle_client(mut socket, stats, expected_auth, require_auth, idle_dur)
	}

	// 等所有 in-flight handle_client 退出后 main 返回，进程退出码 0
	active := stdatomic.load_i64(&stats.active_conns)
	if active > 0 {
		eprintln('shutdown: draining ${active} in-flight connection(s)...')
	}
	stats.inflight.wait()
	eprintln('shutdown: complete')
}

// 块作用：鉴权 fail-fast + 凭据编码
// 处理问题（issue #1 + issue #4）：
// 1. PROXY_REQUIRE_AUTH=false 关闭鉴权
// 2. auth_basic 优先于 user/pass
// 3. 缺凭据时返回 error，由 main 退出（fail-fast）
// 参数由 vpcli 解析后传入（CLI > env > default）。
// 返回：(Base64 编码的期望凭据, 是否要求鉴权)。require_auth=false 时第一个值无意义。
fn proxy_auth_config(auth_basic string, user string, pass string, require_auth bool) !(string, bool) {
	if !require_auth {
		eprintln('WARN: authentication disabled (PROXY_REQUIRE_AUTH=0)')
		return '', false
	}

	if auth_basic != '' {
		return auth_basic, true
	}

	if user == '' || pass == '' {
		return error('PROXY_AUTH_USER and PROXY_AUTH_PASS must be set')
	}

	return base64.encode_str('${user}:${pass}'), true
}

// 块作用：Prometheus /metrics 文本渲染
// 处理问题：把 Stats 原子计数转成 Prometheus 文本格式（HELP/TYPE/采样行）。
// proto 固定为 "http"（本代理语义）；所有值用 stdatomic.load_i64 原子读，避免与
// 各 handle_client goroutine 的 add_i64 竞争。输出以换行结尾。
fn render_metrics(stats &Stats) string {
	mut sb := strings.new_builder(512)
	sb.write_string('# HELP vproxy_active_conns 当前活跃连接数\n')
	sb.write_string('# TYPE vproxy_active_conns gauge\n')
	sb.write_string('vproxy_active_conns{proto="http"} ${stdatomic.load_i64(&stats.active_conns)}\n')
	sb.write_string('\n')
	sb.write_string('# HELP vproxy_connections_total 累计连接数\n')
	sb.write_string('# TYPE vproxy_connections_total counter\n')
	sb.write_string('vproxy_connections_total{proto="http",status="ok"} ${stdatomic.load_i64(&stats.connections_ok_total)}\n')
	sb.write_string('\n')
	sb.write_string('# HELP vproxy_bytes_total 累计字节\n')
	sb.write_string('# TYPE vproxy_bytes_total counter\n')
	sb.write_string('vproxy_bytes_total{dir="in"} ${stdatomic.load_i64(&stats.bytes_in)}\n')
	sb.write_string('vproxy_bytes_total{dir="out"} ${stdatomic.load_i64(&stats.bytes_out)}\n')
	sb.write_string('\n')
	sb.write_string('# HELP vproxy_errors_total 错误累计\n')
	sb.write_string('# TYPE vproxy_errors_total counter\n')
	sb.write_string('vproxy_errors_total{kind="auth_failed"} ${stdatomic.load_i64(&stats.errors_auth_failed_total)}\n')
	sb.write_string('vproxy_errors_total{kind="upstream_connect"} ${stdatomic.load_i64(&stats.errors_upstream_connect_total)}\n')
	sb.write_string('vproxy_errors_total{kind="idle_timeout"} ${stdatomic.load_i64(&stats.errors_idle_timeout_total)}\n')
	return sb.str()
}

// 块作用：metrics HTTP 监听（最小实现，不引入 net.http.Server 的 worker pool）
// 处理问题：独立于代理主监听的端口暴露 /metrics。绑定失败只告警不拖垮主进程；
// accept 超时（1s）与主循环一致，配合 lifecycle.should_stop() 优雅退出。
fn metrics_server(addr string, stats &Stats) {
	mut server := net.listen_tcp(.ip, addr) or {
		eprintln('Metrics: failed to listen on ${addr}: ${err}')
		return
	}
	defer {
		server.close() or {}
	}
	server.set_accept_timeout(1 * time.second)
	eprintln('Metrics on ${addr} (Prometheus /metrics) ...')
	for {
		if lifecycle.should_stop() {
			return
		}
		mut conn := server.accept() or { continue }
		go handle_metrics_conn(mut conn, stats)
	}
}

// 块作用：处理单个 /metrics 请求
// 处理问题：只读一次请求头（上限 2KB），请求行以 GET /metrics 开头则返回文本，
// 否则 404。给连接设读超时，防止恶意客户端挂死不释放 goroutine。
fn handle_metrics_conn(mut conn net.TcpConn, stats &Stats) {
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(5 * time.second)
	mut data := []u8{}
	mut buf := []u8{len: 2048}
	for data.len < 2048 {
		n := conn.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		data << buf[..n]
		if find_header_end_from(data, 0) >= 0 {
			break
		}
	}
	if data.bytestr().starts_with('GET /metrics') {
		body := render_metrics(stats)
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n') or {
			return
		}
		conn.write_string(body) or { return }
		return
	}
	conn.write_string('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n') or {}
}

// 块作用：客户端连接处理
// 处理问题：
// 1. 读取并解析 HTTP 头部
// 2. 校验 Proxy Basic Auth（认证，issue #1：require_auth=false 时跳过）
// 3. 处理 CONNECT 隧道（HTTPS/TCP 代理）
// 4. 处理普通 HTTP 转发及相关头部修改
// 5. issue #5：应用 idle timeout；defer 通知 inflight WaitGroup 让优雅退出能 drain
fn handle_client(mut socket net.TcpConn, stats &Stats, expected_auth string, require_auth bool,
	idle_dur time.Duration) {
	lifecycle.apply_idle_timeout(mut socket, idle_dur)
	start := time.now()
	// ok 标志：只有真正建立了上游连接并开始转发/隧道才算 "ok"。
	// 鉴权失败 / 上游连接失败 / 畸形请求等非成功路径在 return 前置 false。
	mut ok := true
	defer {
		if ok {
			stdatomic.add_i64(&stats.connections_ok_total, 1)
		}
		stdatomic.add_i64(&stats.active_conns, -1)
		stats.inflight.done()
		socket.close() or {}
	}
	defer {
		duration := time.since(start)
		eprintln('Client handled in ${duration}s. Active: ${stdatomic.load_i64(&stats.active_conns)}')
	}

	header_bytes, mut pending_body := read_request_head(mut socket) or {
		ok = false
		send_simple_response(mut socket, '400 Bad Request', '${err}\n')
		return
	}

	header_str := header_bytes.bytestr()
	first_line := header_str.all_before('\r\n')
	if first_line == '' {
		ok = false
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return
	}

	first_parts := first_line.split(' ')
	if first_parts.len < 3 {
		ok = false
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return
	}

	method := first_parts[0].to_upper()
	if !valid_methods.contains(method) {
		ok = false
		send_simple_response(mut socket, '405 Method Not Allowed', 'Unsupported method\n')
		return
	}

	target := first_parts[1]
	version := first_parts[2]

	header_lines := header_str.split('\r\n')
	mut proxy_authorization := ''
	mut host_header := ''
	mut upgrade_value := ''
	mut connection_value := ''

	for line in header_lines {
		if line == '' {
			continue
		}
		if starts_with_ci(line, 'proxy-authorization:') || starts_with_ci(line, 'authorization:') {
			proxy_authorization = line.all_after(':').trim_space()
		} else if starts_with_ci(line, 'host:') {
			host_header = line.all_after(':').trim_space()
		} else if starts_with_ci(line, 'upgrade:') {
			upgrade_value = line.all_after(':').trim_space().to_lower()
		} else if starts_with_ci(line, 'connection:') {
			connection_value = line.all_after(':').trim_space().to_lower()
		}
	}

	// WebSocket 检测：RFC 6455 §4.1 要求同时存在 Upgrade: websocket 与 Connection: Upgrade
	// （后者可能是逗号分隔列表，如 "keep-alive, Upgrade"）。
	mut is_websocket := upgrade_value == 'websocket'
	if is_websocket {
		for token in connection_value.split(',') {
			if token.trim_space() == 'upgrade' {
				is_websocket = true
				break
			}
		}
		if !is_websocket {
			// Upgrade 是 websocket 但 Connection 没列出 upgrade：仍按 WebSocket 处理
			// （某些宽松客户端会省略 Connection 头）
			is_websocket = true
		}
	}

	if require_auth {
		if !proxy_authorization.starts_with('Basic ') {
			ok = false
			stdatomic.add_i64(&stats.errors_auth_failed_total, 1)
			send_proxy_auth_required(mut socket)
			return
		}
		provided_cred := proxy_authorization[6..].trim_space().replace('\n', '').replace('\r', '')
		if provided_cred != expected_auth {
			ok = false
			stdatomic.add_i64(&stats.errors_auth_failed_total, 1)
			send_proxy_auth_required(mut socket)
			return
		}
	}

	mut upstream_host := ''
	mut request_path := ''
	mut forwarded_first_line := first_line

	if method == 'CONNECT' {
		upstream_host = normalize_authority(target, default_https_port)
		if upstream_host == '' {
			ok = false
			send_simple_response(mut socket, '400 Bad Request', 'Missing CONNECT target\n')
			return
		}
	} else if is_websocket {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			upstream_host = host_header
		}
		if upstream_host == '' {
			ok = false
			send_simple_response(mut socket, '400 Bad Request', 'Missing ws/wss target\n')
			return
		}
		// ws:// → :80, wss:// → :443（split_target 已剥掉 scheme）
		mut ws_default := default_http_port
		if target.starts_with('wss://') {
			ws_default = default_https_port
		}
		upstream_host = normalize_authority(upstream_host, ws_default)
		forwarded_first_line = '${method} ${request_path} ${version}'
	} else {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			upstream_host = host_header
		}
		if upstream_host == '' {
			ok = false
			send_simple_response(mut socket, '400 Bad Request', 'Missing Host header\n')
			return
		}
		upstream_host = normalize_authority(upstream_host, default_http_port)
		forwarded_first_line = '${method} ${request_path} ${version}'
	}

	mut upstream := net.dial_tcp(upstream_host) or {
		ok = false
		stdatomic.add_i64(&stats.errors_upstream_connect_total, 1)
		eprintln('Failed to connect to ${upstream_host}: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return
	}
	defer {
		upstream.close() or {}
	}

	if method == 'CONNECT' {
		socket.write_string(connection_established) or {
			ok = false
			eprintln('Failed to send CONNECT response: ${err}')
			return
		}
	} else if is_websocket {
		// 块作用：WebSocket 握手 + 透传
		// 处理问题（RFC 6455）：
		// 1. 重写请求行：absolute URI → origin form（上游是 origin server，不接受 ws:// 前缀）
		// 2. 保留 Upgrade/Connection/Sec-WebSocket-*/Origin；剥离 Proxy-* 防凭据泄露
		// 3. **不**注入 Via/Proxy-Agent：部分 WebSocket 服务端对未知头挑剔
		// 4. 读上游响应直到 \r\n\r\n：状态码 == 101 则进入双向中继，否则透传给客户端并关闭
		mut ws_headers := []string{}
		ws_headers << forwarded_first_line
		mut has_host_header := false
		for i, line in header_lines {
			if i == 0 {
				continue // 已用 forwarded_first_line 代替
			}
			if line == '' {
				continue
			}
			if starts_with_ci(line, 'proxy-authorization:')
				|| starts_with_ci(line, 'authorization:')
				|| starts_with_ci(line, 'proxy-connection:') {
				continue
			}
			if starts_with_ci(line, 'host:') {
				has_host_header = true
			}
			ws_headers << line
		}
		if !has_host_header && upstream_host != '' {
			ws_headers << 'Host: ${upstream_host}'
		}
		ws_headers << ''
		request_blob := ws_headers.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or {
			ok = false
			eprintln('Failed to forward WebSocket upgrade: ${err}')
			return
		}
		if pending_body.len > 0 {
			upstream.write(pending_body) or {
				ok = false
				eprintln('Failed to forward pending body: ${err}')
				return
			}
			stdatomic.add_i64(&stats.bytes_in, pending_body.len)
		}

		// 读上游 handshake response 直到 \r\n\r\n，复用 find_header_end_from
		mut resp_buf := []u8{}
		mut read_buf := []u8{len: 8192}
		mut header_end := -1
		for header_end < 0 {
			nn := upstream.read(mut read_buf) or {
				ok = false
				eprintln('Failed to read upstream WebSocket response: ${err}')
				return
			}
			if nn <= 0 {
				ok = false
				eprintln('WebSocket upstream closed before handshake response')
				return
			}
			resp_buf << read_buf[..nn]
			if resp_buf.len > 65536 {
				ok = false
				eprintln('WebSocket upstream response too large')
				return
			}
			header_end = find_header_end_from(resp_buf, if resp_buf.len > nn + 3 {
				resp_buf.len - nn - 3
			} else {
				0
			})
		}

		// 透传整个 response 给客户端（headers + 任何已读的额外字节）
		socket.write(resp_buf) or {
			ok = false
			eprintln('Failed to forward WebSocket response: ${err}')
			return
		}

		// 校验状态码：必须是 101 Switching Protocols
		resp_head_str := resp_buf[..header_end].bytestr()
		status_line := resp_head_str.all_before('\r\n')
		mut is_101 := false
		// HTTP/1.1 形式：「HTTP/1.1 101 Switching Protocols」
		status_parts := status_line.split(' ')
		if status_parts.len >= 2 && status_parts[0].starts_with('HTTP/') {
			is_101 = status_parts[1] == '101'
		}
		if !is_101 {
			ok = false
			eprintln('WebSocket upstream returned non-101: ${status_line}')
			return
		}
		eprintln('WebSocket: 101 handshake OK, entering relay')
		relay_both_ways(mut socket, mut upstream, stats)
		return
	} else {
		// 复用上面已 split 的 header_lines，避免对同一 header 重复 split
		mut forwarded_headers := []string{}
		forwarded_headers << forwarded_first_line

		mut has_host_header := false
		for i, line in header_lines {
			if i == 0 {
				continue // 忽略第一行（请求行），已在 forwarded_first_line 处理
			}
			if line == '' {
				continue // 忽略空行
			}
			// 移除代理相关的头部，防止循环代理或泄露验证信息
			if starts_with_ci(line, 'proxy-authorization:')
				|| starts_with_ci(line, 'authorization:')
				|| starts_with_ci(line, 'proxy-connection:') {
				continue
			}
			if starts_with_ci(line, 'host:') {
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
			ok = false
			eprintln('Failed to forward request: ${err}')
			return
		}

		// --- 优化：流式转发 Body ---
		// 不再区分 Content-Length 或 Chunked，
		// 直接将之前读取 header 时多读到的 body 部分发送给上游，
		// 剩余部分交给后续的双向 io.cp 透传。
		if pending_body.len > 0 {
			upstream.write(pending_body) or {
				ok = false
				eprintln('Failed to forward pending body: ${err}')
				return
			}
			stdatomic.add_i64(&stats.bytes_in, pending_body.len)
		}
	}

	// 块作用：建立双向数据通道
	// 处理问题：通过协程实现全双工通信，支持 CONNECT 隧道及普通 HTTP 的流式响应（含 Chunked）
	if method == 'HEAD' {
		// HEAD 响应没有 body，仅单向复制响应头
		copy_counted(mut upstream, mut socket, stats, 'out')
	} else {
		relay_both_ways(mut socket, mut upstream, stats)
	}
}

// 块作用：双向中继（graceful teardown，单 owner close）+ 字节计数
// 处理问题：修复并发双 close 竞态（Connection reset / EBADF）。
// 旧实现的两个 relay goroutine 各自 defer close(src)+close(dst)，同一 fd 会被并发
// close 2~3 次；先 close 释放的 fd 号被 accept 复用给新连接后，第二个 close 会把
// 新连接误关，高并发下必现。现在每个方向只对写目标 dst 做 TCP 半关闭
// （net.shutdown(handle, how: .write)，发 FIN 但不释放 fd），让对端读到 EOF 后自行
// 关闭，从而让另一方向的中继及时返回；两个 fd 的完整 close 由 handle_client 的
// defer（socket）与 dial 后的 defer（upstream）各执行恰好一次，杜绝 fd 复用误关。
// 与旧实现 io.cp 的区别：copy_counted 额外按方向累计 bytes_in/bytes_out，
// 不 close 任何 fd（半关闭与 close 语义与 io.cp 版本完全一致）。
fn relay_both_ways(mut a net.TcpConn, mut b net.TcpConn, stats &Stats) {
	mut wg := sync.new_waitgroup()
	wg.add(2)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, stats &Stats, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		copy_counted(mut src, mut dst, stats, 'in')
	}(mut a, mut b, stats, mut wg)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, stats &Stats, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		copy_counted(mut src, mut dst, stats, 'out')
	}(mut b, mut a, stats, mut wg)
	wg.wait()
}

// 块作用：带字节计数与 idle_timeout 识别的单方向复制
// 处理问题：替代 relay 热路径上的 io.cp：
// 1. 每轮 read/write 后原子累加 bytes_in/bytes_out（纯内存操作，零额外 syscall）。
// 2. 仅 'in' 方向（客户端 → 上游）的 read 超时计入 errors_idle_timeout_total：
//    relay_both_ways 的两个方向同时空闲时，客户端侧与上游侧 read 都会超时，
//    只有客户端侧计数，避免同一空闲事件被两个方向各计一次（双计）。
//    write 失败（含超时）不计数，由读侧错误路径覆盖。
// 3. 不在本函数内 close 任何 fd：fd 的完整关闭仍由 handle_client 的 defer 各执行
//    恰好一次，保持与 io.cp 版本一致的半关闭/单 owner close 约定。
fn copy_counted(mut src net.TcpConn, mut dst net.TcpConn, stats &Stats, dir string) {
	mut buf := []u8{len: 64 * 1024}
	for {
		n := src.read(mut buf) or {
			if dir == 'in' && err.code() == net.err_timed_out_code {
				stdatomic.add_i64(&stats.errors_idle_timeout_total, 1)
			}
			return
		}
		if n <= 0 {
			return
		}
		dst.write(buf[..n]) or { return }
		if dir == 'in' {
			stdatomic.add_i64(&stats.bytes_in, n)
		} else {
			stdatomic.add_i64(&stats.bytes_out, n)
		}
	}
}

// 块作用：目标解析
// 处理问题：从请求路径中提取 Host 和 Path，处理绝对 URL 和相对路径。
// 识别 http://、https://、ws://、wss:// 四种 scheme（WebSocket 代理用）。
fn split_target(target string) (string, string) {
	mut authority := ''
	mut path := '/'

	if target.starts_with('http://') || target.starts_with('https://')
		|| target.starts_with('ws://') || target.starts_with('wss://') {
		without_scheme := if target.starts_with('wss://') {
			target.all_after('wss://')
		} else if target.starts_with('ws://') {
			target.all_after('ws://')
		} else if target.starts_with('https://') {
			target.all_after('https://')
		} else {
			target.all_after('http://')
		}
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

// 块作用：无分配的大小写不敏感前缀比较（仅处理 ASCII A-Z）
// 处理问题：HTTP 头名为 ASCII；等价于 `line.to_lower().starts_with(prefix)`，
// 但不产生 `to_lower()` 的中间字符串分配（每行一次，热路径上值得省）。
fn starts_with_ci(line string, prefix string) bool {
	if line.len < prefix.len {
		return false
	}
	for i in 0 .. prefix.len {
		mut c := line[i]
		if c >= `A` && c <= `Z` {
			c = c + 32
		}
		if c != prefix[i] {
			return false
		}
	}
	return true
}

fn send_simple_response(mut socket net.TcpConn, status_line string, message string) {
	body := message
	response := 'HTTP/1.1 ${status_line}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.len}\r\n\r\n${body}'
	socket.write_string(response) or {}
}

// 块作用：返回 407 Proxy Authentication Required
// 处理问题：抽取重复的 407 响应构造逻辑，便于统一维护
fn send_proxy_auth_required(mut socket net.TcpConn) {
	gmt := time.now().custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
	response := 'HTTP/1.1 407 Proxy Authentication Required\r\nDate: ${gmt}\r\nProxy-Authenticate: Basic realm="V Proxy"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'
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
		header_end := find_header_end_from(data,
			if data.len > n + 3 { data.len - n - 3 } else { 0 })
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
