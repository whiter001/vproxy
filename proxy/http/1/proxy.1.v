module main

import encoding.base64
import io
import lifecycle
import net
import os
import sync
import sync.stdatomic
import time
import vpcli

const valid_methods = ['CONNECT', 'POST', 'GET', 'HEAD', 'OPTIONS', 'DELETE', 'PATCH', 'PUT']
// RFC 7230 §5.7.1 / §6.2：代理应在响应中声明自己（Via / Proxy-Agent），
// 与普通 HTTP 转发路径注入的头部保持一致。
const connection_established = 'HTTP/1.1 200 Connection Established\r\nVia: 1.1 v-proxy\r\nProxy-Agent: V-Proxy/1.0\r\n\r\n'
const default_http_port = ':80'
const default_https_port = ':443'

struct Stats {
mut:
	active_conns i64
	inflight     sync.WaitGroup // 跟踪在飞连接，用于优雅退出（issue #5）
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

// 块作用：客户端连接处理（keep-alive 请求循环）
// 处理问题：
// 1. 读取并解析 HTTP 头部
// 2. 校验 Proxy Basic Auth（认证，issue #1：require_auth=false 时跳过）
// 3. 处理 CONNECT 隧道（HTTPS/TCP 代理）
// 4. 处理普通 HTTP 转发及相关头部修改
// 5. issue #5：应用 idle timeout；defer 通知 inflight WaitGroup 让优雅退出能 drain
// 6. keep-alive：复用客户端 socket，循环处理同一连接上的多个请求，直到
//    idle timeout / 客户端关闭 / 错误响应（Connection: close）。
fn handle_client(mut socket net.TcpConn, stats &Stats, expected_auth string, require_auth bool,
	idle_dur time.Duration) {
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

	// keep-alive 循环：process_request 返回 true 表示连接可复用。
	// 注意：首请求前读到空连接（EOF）会返回 400；已处理过请求后再 EOF 属正常关闭，静默结束。
	mut first_request := true
	// 上一轮 read_request_head 多读的字节（可能含流水线/背靠背的下一请求、或 CL body
	// 超出部分），作为下一轮读取的初始缓冲，避免被静默丢弃。
	mut carry_body := []u8{}
	for {
		keep_alive := process_request(mut socket, expected_auth, require_auth, idle_dur,
			first_request, mut carry_body) or { break }
		first_request = false
		if !keep_alive {
			break
		}
	}
}

// 块作用：处理单个 HTTP 请求（keep-alive 循环的一次迭代）
// 处理问题：
// 1. 读取并解析请求头、鉴权、目标解析
// 2. 按方法分发：CONNECT 隧道 / WebSocket 透传 / 普通 HTTP 转发
// 3. 上游连接按请求新建、请求结束即关闭（对上游强制 Connection: close，
//    响应体靠 EOF 定界，避免完整解析 Content-Length/chunked）。
// 返回 true 表示客户端连接可复用；false 或 error 表示连接关闭。
// error 仅在读取失败 / 上游关闭时返回，不发送响应；首请求解析失败会先发 400。
fn process_request(mut socket net.TcpConn, expected_auth string, require_auth bool,
	idle_dur time.Duration, first_request bool, mut carry_body []u8) !bool {
	header_bytes, mut pending_body := read_request_head(mut socket, carry_body) or {
		if first_request {
			send_simple_response(mut socket, '400 Bad Request', '${err}\n')
		}
		return err
	}

	header_str := header_bytes.bytestr()
	first_line := header_str.all_before('\r\n')
	if first_line == '' {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return error('close')
	}

	first_parts := first_line.split(' ')
	if first_parts.len < 3 {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return error('close')
	}

	method := first_parts[0].to_upper()
	if !valid_methods.contains(method) {
		send_simple_response(mut socket, '405 Method Not Allowed', 'Unsupported method\n')
		return error('close')
	}

	target := first_parts[1]
	version := first_parts[2]

	header_lines := header_str.split('\r\n')
	mut proxy_authorization := ''
	mut host_header := ''
	mut upgrade_value := ''
	mut connection_value := ''
	mut content_length := 0
	mut transfer_encoding := ''

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
		} else if starts_with_ci(line, 'content-length:') {
			content_length = line.all_after(':').trim_space().int()
		} else if starts_with_ci(line, 'transfer-encoding:') {
			transfer_encoding = line.all_after(':').trim_space().to_lower()
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
			send_proxy_auth_required(mut socket)
			return error('close')
		}
		provided_cred := proxy_authorization[6..].trim_space().replace('\n', '').replace('\r', '')
		if provided_cred != expected_auth {
			send_proxy_auth_required(mut socket)
			return error('close')
		}
	}

	// keep-alive 决策（RFC 7230 §6.3）：HTTP/1.1 默认持久连接，Connection: close 覆盖；
	// HTTP/1.0 需显式 keep-alive token。CONNECT / WebSocket 恒为一次性，不走循环。
	mut keep_alive := connection_keep_alive(version, connection_value)
	if method == 'CONNECT' || is_websocket {
		keep_alive = false
	}

	mut upstream_host := ''
	mut request_path := ''
	mut forwarded_first_line := first_line

	if method == 'CONNECT' {
		upstream_host = normalize_authority(target, default_https_port)
		if upstream_host == '' {
			send_simple_response(mut socket, '400 Bad Request', 'Missing CONNECT target\n')
			return error('close')
		}
	} else if is_websocket {
		upstream_host, request_path = split_target(target)
		if upstream_host == '' {
			upstream_host = host_header
		}
		if upstream_host == '' {
			send_simple_response(mut socket, '400 Bad Request', 'Missing ws/wss target\n')
			return error('close')
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
			send_simple_response(mut socket, '400 Bad Request', 'Missing Host header\n')
			return error('close')
		}
		upstream_host = normalize_authority(upstream_host, default_http_port)
		forwarded_first_line = '${method} ${request_path} ${version}'
	}

	mut upstream := net.dial_tcp(upstream_host) or {
		eprintln('Failed to connect to ${upstream_host}: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return error('close')
	}
	defer {
		upstream.close() or {}
	}
	// 上游连接不跨请求复用，并设 read timeout：避免上游不尊重 Connection: close 时
	// io.cp 永久阻塞在 read 上（缓解「上游延迟关闭」风险）。
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	if method == 'CONNECT' {
		socket.write_string(connection_established) or {
			eprintln('Failed to send CONNECT response: ${err}')
			return error('close')
		}
		eprintln('CONNECT: tunnel established to ${upstream_host}')
		relay_both_ways(mut socket, mut upstream)
		return false
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
			eprintln('Failed to forward WebSocket upgrade: ${err}')
			return false
		}
		if pending_body.len > 0 {
			upstream.write(pending_body) or {
				eprintln('Failed to forward pending body: ${err}')
				return false
			}
		}

		// 读上游 handshake response 直到 \r\n\r\n，复用 find_header_end_from
		mut resp_buf := []u8{}
		mut read_buf := []u8{len: 8192}
		mut header_end := -1
		for header_end < 0 {
			nn := upstream.read(mut read_buf) or {
				eprintln('Failed to read upstream WebSocket response: ${err}')
				return false
			}
			if nn <= 0 {
				eprintln('WebSocket upstream closed before handshake response')
				return false
			}
			resp_buf << read_buf[..nn]
			if resp_buf.len > 65536 {
				eprintln('WebSocket upstream response too large')
				return false
			}
			header_end = find_header_end_from(resp_buf, if resp_buf.len > nn + 3 {
				resp_buf.len - nn - 3
			} else {
				0
			})
		}

		// 透传整个 response 给客户端（headers + 任何已读的额外字节）
		socket.write(resp_buf) or {
			eprintln('Failed to forward WebSocket response: ${err}')
			return false
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
			eprintln('WebSocket upstream returned non-101: ${status_line}')
			return false
		}
		eprintln('WebSocket: 101 handshake OK, entering relay')
		relay_both_ways(mut socket, mut upstream)
		return false
	} else {
		// 块作用：普通 HTTP 转发
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
			// 移除代理相关的头部，防止循环代理或泄露验证信息；
			// 同时剥离 Connection / Proxy-Connection（由代理统一管理 keep-alive 语义）
			if starts_with_ci(line, 'proxy-authorization:')
				|| starts_with_ci(line, 'authorization:')
				|| starts_with_ci(line, 'proxy-connection:') || starts_with_ci(line, 'connection:') {
				continue
			}
			if method == 'HEAD' && (starts_with_ci(line, 'content-length:')
				|| starts_with_ci(line, 'transfer-encoding:')) {
				// HEAD 无请求体（RFC 7231 §4.3.2）：剥掉 CL/TE，避免上游等待不存在的 body
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
		// 强制上游 Connection: close：响应体靠 EOF 定界，且上游连接不跨请求复用
		forwarded_headers << 'Connection: close'
		forwarded_headers << ''
		request_blob := forwarded_headers.join('\r\n') + '\r\n'
		upstream.write_string(request_blob) or {
			eprintln('Failed to forward request: ${err}')
			return error('close')
		}

		has_chunked_body := transfer_encoding.contains('chunked')
		if has_chunked_body {
			// chunked 请求体：退化为双向 relay 透传（不做 chunked 帧解析），
			// 请求结束后连接不复用（relay 会向客户端发 FIN，语义上连接已结束）。
			// 上游已强制 Connection: close，响应仍能靠 EOF 定界，test_full.sh 测试 3 保持通过。
			if pending_body.len > 0 {
				upstream.write(pending_body) or {
					eprintln('Failed to forward pending body: ${err}')
					return error('close')
				}
			}
			relay_both_ways(mut socket, mut upstream)
			return false
		}

		// Content-Length 请求体：流式转发恰好 CL 字节，保证请求边界清晰
		// （keep-alive 下不能靠 relay 双向透传，否则无法知道请求体何时结束）。
		// HEAD 无请求体语义（RFC 7231 §4.3.2）：一律跳过 body 转发，不读客户端 → 上游。
		if method != 'HEAD' && content_length > 0 {
			mut body_forwarded := 0
			if pending_body.len > 0 {
				send_len := if pending_body.len > content_length {
					content_length
				} else {
					pending_body.len
				}
				upstream.write(pending_body[..send_len]) or {
					eprintln('Failed to forward body: ${err}')
					return error('close')
				}
				body_forwarded = send_len
				// 超出 CL 的字节可能是下一请求，回灌给下一轮请求解析
				pending_body = pending_body[send_len..].clone()
			}
			mut body_buf := []u8{len: 16384}
			for body_forwarded < content_length {
				remaining := content_length - body_forwarded
				read_len := if remaining < body_buf.len { remaining } else { body_buf.len }
				// 只读剩余 CL 字节：避免把提前到达的下一请求误当作 body 写入上游
				// （拆包 + 多请求同段的场景下读多会破坏上游连接帧边界）。
				n := socket.read(mut body_buf[..read_len]) or {
					eprintln('Failed to read request body: ${err}')
					return error('close')
				}
				if n <= 0 {
					eprintln('Client closed while sending request body')
					return error('close')
				}
				upstream.write(body_buf[..n]) or {
					eprintln('Failed to forward request body: ${err}')
					return error('close')
				}
				body_forwarded += n
			}
		}

		// 读上游响应头（复用 read_request_head 的读取逻辑，直到 \r\n\r\n）
		resp_head, resp_pending := read_response_head(mut upstream) or {
			eprintln('Upstream closed before response: ${err}')
			return error('close')
		}
		resp_lines := resp_head.bytestr().split('\r\n')

		// 若响应既无 Content-Length 也无 Transfer-Encoding（close-delimited），
		// 客户端只能靠连接 EOF 判断响应结束，因此本连接不可复用。
		if method != 'HEAD' && !response_has_body_length(resp_lines) {
			keep_alive = false
		}

		// 改写响应头：剥离上游的 Connection / Proxy-Connection（上游被强制 close），
		// 按本连接是否复用补 Connection: keep-alive / close。
		rewritten := rewrite_response_connection(resp_lines, keep_alive)
		socket.write_string(rewritten.join('\r\n') + '\r\n') or {
			eprintln('Failed to forward response head: ${err}')
			return error('close')
		}
		if resp_pending.len > 0 {
			socket.write(resp_pending) or {
				eprintln('Failed to forward response body: ${err}')
				return error('close')
			}
		}

		// 把本轮回灌缓冲写回：pending_body 中未被消费的字节（流水线下一请求、或 CL body
		// 超出部分）作为下一轮 read_request_head 的初始缓冲，避免被静默丢弃。
		carry_body = pending_body.clone()

		if method == 'HEAD' {
			// HEAD 独立路径：仅单向转发响应头，不读客户端 → 上游，也不复制 body。
			// HEAD 响应无 body（RFC 7231 §4.3.2），defer 关闭上游即完成；
			// 客户端侧连接按 keep_alive 决策继续复用。
			return keep_alive
		}

		// 普通响应体：单向 io.cp(upstream → socket) 直到上游 EOF
		// （对上游强制了 Connection: close，EOF 即响应结束）。
		// 注意：与 relay_both_ways 不同，此处**不能**对客户端 shutdown(WRITE)——
		// 发 FIN 会告诉客户端连接结束，keep-alive 复用失效。
		io.cp(mut upstream, mut socket) or {}
		return keep_alive
	}
}

// 块作用：双向 io.cp 中继（graceful teardown，单 owner close）
// 处理问题：修复并发双 close 竞态（Connection reset / EBADF）。
// 旧实现的两个 relay goroutine 各自 defer close(src)+close(dst)，同一 fd 会被并发
// close 2~3 次；先 close 释放的 fd 号被 accept 复用给新连接后，第二个 close 会把
// 新连接误关，高并发下必现。现在每个方向只对写目标 dst 做 TCP 半关闭
// （net.shutdown(handle, how: .write)，发 FIN 但不释放 fd），让对端读到 EOF 后自行
// 关闭，从而让另一方向的 io.cp 及时返回；两个 fd 的完整 close 由 handle_client 的
// defer（socket）与 dial 后的 defer（upstream）各执行恰好一次，杜绝 fd 复用误关。
// 仅用于一次性路径：CONNECT 隧道、WebSocket 101 透传、chunked 请求体退化透传。
fn relay_both_ways(mut a net.TcpConn, mut b net.TcpConn) {
	mut wg := sync.new_waitgroup()
	wg.add(2)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut a, mut b, mut wg)
	go fn (mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
		defer {
			net.shutdown(dst.sock.handle, how: .write)
			wg.done()
		}
		io.cp(mut src, mut dst) or {}
	}(mut b, mut a, mut wg)
	wg.wait()
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

// 块作用：判定客户端连接是否可复用（keep-alive）
// 处理问题（RFC 7230 §6.3）：HTTP/1.1 默认持久连接，Connection: close 显式关闭；
// HTTP/1.0 需显式 keep-alive token；close 与 keep-alive 并存时 close 优先。
// CONNECT / WebSocket 由调用方另行强制为一次性。
fn connection_keep_alive(version string, connection_value string) bool {
	mut has_close := false
	mut has_keep_alive := false
	for token in connection_value.split(',') {
		t := token.trim_space()
		if t == 'close' {
			has_close = true
		} else if t == 'keep-alive' {
			has_keep_alive = true
		}
	}
	if has_close {
		return false
	}
	if version == 'HTTP/1.1' {
		return true
	}
	return has_keep_alive
}

// 块作用：改写上游响应头的 Connection 字段
// 处理问题：对上游强制了 Connection: close，响应头必然带 Connection: close；
// 若原样透传，keep-alive 客户端看到后不会复用连接（验收项「同连接连续 5 次 GET」必挂）。
// 剥离上游的 Connection / Proxy-Connection，按本连接是否复用补对应的 token。
// head 为 split('\r\n') 后的响应头行列表；返回列表以 '' 结尾，
// 调用方 join('\r\n') + '\r\n' 后即得到完整的 "\r\n\r\n" 终止。
fn rewrite_response_connection(head []string, keep_alive bool) []string {
	mut out := []string{}
	for line in head {
		if line == '' {
			continue // 跳过空行（含尾部终止空行，末尾统一补）
		}
		if starts_with_ci(line, 'connection:') || starts_with_ci(line, 'proxy-connection:') {
			continue
		}
		out << line
	}
	if keep_alive {
		out << 'Connection: keep-alive'
	} else {
		out << 'Connection: close'
	}
	out << '' // 终止空行占位
	return out
}

// 块作用：判断响应头是否声明了响应体长度（Content-Length 或 Transfer-Encoding）
// 处理问题：close-delimited 响应（两者皆无）只能靠连接 EOF 定界，
// keep-alive 下客户端无法判断响应结束，必须改为关闭连接。
fn response_has_body_length(head []string) bool {
	for line in head {
		if starts_with_ci(line, 'content-length:') || starts_with_ci(line, 'transfer-encoding:') {
			return true
		}
	}
	return false
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
// 处理问题：持续读取直至发现 \r\n\r\n 标志，限制头部最大长度 64KB。
// initial 为上一轮 keep-alive 多读的字节（流水线/背靠背的下一请求、或 CL body 超出部分），
// 先在其中寻找完整请求头，避免已读入的下一请求被丢弃导致循环永久阻塞。
fn read_request_head(mut socket net.TcpConn, initial []u8) !([]u8, []u8) {
	mut data := initial.clone()
	mut buf := []u8{len: 8192}
	mut header_end := find_header_end_from(data, 0)
	for header_end < 0 {
		n := socket.read(mut buf) or { return err }
		if n <= 0 {
			return error('Bad request')
		}
		data << buf[..n]
		if data.len > 65536 {
			return error('Request too large')
		}
		header_end = find_header_end_from(data, if data.len > n + 3 { data.len - n - 3 } else { 0 })
	}
	// 返回 (头部字节数组, 剩余已读取的 body 部分)
	return data[..header_end], data[header_end + 4..]
}

// 块作用：读取上游响应头（复用 read_request_head 的读取逻辑，无初始缓冲）
fn read_response_head(mut upstream net.TcpConn) !([]u8, []u8) {
	return read_request_head(mut upstream, []u8{})
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
