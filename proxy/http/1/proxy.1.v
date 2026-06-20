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
const default_http_port = ':80'
const default_https_port = ':443'

// 代理标识，注入到转发的请求/响应头（RFC 7230 §5.7 / §6.2）。
const proxy_via_header = 'Via: 1.1 v-proxy'
const proxy_agent_header = 'Proxy-Agent: V-Proxy/1.0'
// HTTP 头最大长度（64KB），防恶意客户端用超长 header 占内存。
const max_header_bytes = 65536
// 通用拷贝 buffer 大小。
const copy_buffer_size = 8192

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
			if err.msg() == 'accept timeout' {
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

// 块作用：客户端连接处理（issue #2：HTTP keep-alive）
// 在同一 socket 上循环处理多个 HTTP 请求，直到：
//   1. 客户端或上游发 Connection: close
//   2. 空闲超时（idle_dur）
//   3. 读写错误
// CONNECT 隧道走独立路径（handle_connect_tunnel），消费整个连接。
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

	mut keep_alive := true
	for keep_alive {
		keep_alive = handle_one_http_request(mut socket, expected_auth, require_auth) or {
			// 解析 / 转发错误：关 socket 退出（defer 会清理）
			return
		}
	}
}

// 块作用：处理单次 HTTP 请求
// 处理问题（issue #2）：
//   - sub-1: CONNECT 响应补 Via/Proxy-Agent + Date
//   - sub-2: HEAD 路径独立（写响应头后立即停止，不读响应体、不反向读 socket）
//   - sub-3: keep-alive：依据 HTTP 版本 + Connection 头判断是否复用 socket
// 返回：(client_keep_alive && upstream_keep_alive)；error 由调用方关连接。
fn handle_one_http_request(mut socket net.TcpConn, expected_auth string, require_auth bool) !bool {
	header_bytes, mut pending_body := read_request_head(mut socket) or {
		send_simple_response(mut socket, '400 Bad Request', '${err}\n')
		return false
	}

	header_str := header_bytes.bytestr()
	first_line := header_str.all_before('\r\n')
	if first_line == '' {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return false
	}

	first_parts := first_line.split(' ')
	if first_parts.len < 3 {
		send_simple_response(mut socket, '400 Bad Request', 'Bad request\n')
		return false
	}

	method := first_parts[0].to_upper()
	if !valid_methods.contains(method) {
		send_simple_response(mut socket, '405 Method Not Allowed', 'Unsupported method\n')
		return false
	}

	target := first_parts[1]
	version := first_parts[2]

	header_lines := header_str.split('\r\n')
	mut proxy_authorization := ''
	mut host_header := ''
	mut connection_value := ''
	for line in header_lines {
		if line == '' {
			continue
		}
		lower := line.to_lower()
		if lower.starts_with('proxy-authorization:') || lower.starts_with('authorization:') {
			proxy_authorization = line.all_after(':').trim_space()
		} else if lower.starts_with('host:') {
			host_header = line.all_after(':').trim_space()
		} else if lower.starts_with('connection:') {
			connection_value = line.all_after(':').trim_space().to_lower()
		}
	}

	if require_auth {
		if !proxy_authorization.starts_with('Basic ') {
			send_proxy_auth_required(mut socket)
			return false
		}
		provided_cred := proxy_authorization[6..].trim_space().replace('\n', '').replace('\r', '')
		if provided_cred != expected_auth {
			send_proxy_auth_required(mut socket)
			return false
		}
	}

	client_keep_alive := should_keep_alive(version, connection_value)

	if method == 'CONNECT' {
		// CONNECT 隧道消费整个连接（RFC 7230 §6.2 - hop-by-hop tunnel）
		handle_connect_tunnel(mut socket, target) or { return false }
		return false
	}

	// 普通 HTTP 转发
	mut upstream_host := ''
	mut request_path := ''
	mut forwarded_first_line := first_line

	upstream_host, request_path = split_target(target)
	if upstream_host == '' {
		upstream_host = host_header
	}
	if upstream_host == '' {
		send_simple_response(mut socket, '400 Bad Request', 'Missing Host header\n')
		return false
	}
	upstream_host = normalize_authority(upstream_host, default_http_port)
	forwarded_first_line = '${method} ${request_path} ${version}'

	mut upstream := net.dial_tcp(upstream_host) or {
		eprintln('Failed to connect to ${upstream_host}: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return false
	}
	defer {
		upstream.close() or {}
	}
	// 给 upstream 同样设 read timeout，避免慢上游卡住 keep-alive 循环。
	lifecycle.apply_idle_timeout(mut upstream, idle_dur)

	// 构造转发请求头：去 hop-by-hop + 鉴权头，补 Host/Via/Proxy-Agent。
	mut forwarded_headers := []string{}
	forwarded_headers << forwarded_first_line
	mut has_host_header := false
	for i, line in header_lines {
		if i == 0 {
			continue // 请求行已在 forwarded_first_line 处理
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
			has_host_header = true
		}
		forwarded_headers << line
	}
	if !has_host_header && upstream_host != '' {
		forwarded_headers << 'Host: ${upstream_host}'
	}
	forwarded_headers << proxy_via_header
	forwarded_headers << proxy_agent_header
	forwarded_headers << ''
	request_blob := forwarded_headers.join('\r\n') + '\r\n'
	upstream.write_string(request_blob) or {
		eprintln('Failed to forward request: ${err}')
		return false
	}

	// 转发请求体（按 Content-Length / chunked / 无体 分别处理），
	// 否则 keep-alive 循环里无法分清"body 还没传完"和"等响应"的边界。
	forward_request_body(mut socket, mut upstream, header_lines, pending_body) or {
		eprintln('Failed to forward request body: ${err}')
		return false
	}

	// 读响应头 + 注入 Via/Proxy-Agent + 转发
	resp_head_bytes, mut resp_pending_body := read_response_head(mut upstream) or {
		eprintln('Failed to read response head: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream response error\n')
		return false
	}
	resp_head_str := resp_head_bytes.bytestr()
	upstream_keep_alive := parse_response_keep_alive(resp_head_str)

	mut final_resp_head := inject_proxy_headers_into_response(resp_head_str)
	socket.write_string(final_resp_head) or {
		eprintln('Failed to write response head: ${err}')
		return false
	}

	// 块作用：HEAD 路径独立（issue #2 sub-2）
	// HEAD 响应无 body（RFC 7230 §3.3.3），即使上游发了 Content-Length / chunked，
	// 代理也只转响应头就停。socket 不再被反向读取。
	if method == 'HEAD' {
		return client_keep_alive
	}

	forward_response_body(mut upstream, mut socket, resp_head_str, resp_pending_body) or {
		eprintln('Failed to forward response body: ${err}')
		return false
	}

	return client_keep_alive && upstream_keep_alive
}

// 块作用：CONNECT 隧道（issue #2 sub-1 + sub-2 独立路径）
// 200 响应补 Date / Via / Proxy-Agent（RFC 7230 §5.7 / §6.2），
// 然后双向 io.cp 透传 TLS 字节，直到任一端关闭。
fn handle_connect_tunnel(mut socket net.TcpConn, target string) ! {
	upstream_host := normalize_authority(target, default_https_port)
	if upstream_host == '' {
		send_simple_response(mut socket, '400 Bad Request', 'Missing CONNECT target\n')
		return
	}
	mut upstream := net.dial_tcp(upstream_host) or {
		eprintln('Failed to connect to ${upstream_host}: ${err}')
		send_simple_response(mut socket, '502 Bad Gateway', 'Upstream connection failed: ${err}\n')
		return
	}
	defer {
		upstream.close() or {}
	}

	gmt := time.now().custom_format('ddd, DD MMM YYYY HH:mm:ss') + ' GMT'
	resp := 'HTTP/1.1 200 Connection Established\r\nDate: ${gmt}\r\n${proxy_via_header}\r\n${proxy_agent_header}\r\n\r\n'
	socket.write_string(resp) or {
		eprintln('Failed to send CONNECT response: ${err}')
		return
	}

	mut wg := sync.new_waitgroup()
	wg.add(2)
	go tunnel_copy(mut socket, mut upstream, mut wg)
	go tunnel_copy(mut upstream, mut socket, mut wg)
	wg.wait()
}

// 块作用：隧道单向复制协程
// 处理问题：抽出双协程共享结构，让 handle_connect_tunnel 主体更易读。
fn tunnel_copy(mut src net.TcpConn, mut dst net.TcpConn, mut wg sync.WaitGroup) {
	defer {
		src.close() or {}
		dst.close() or {}
		wg.done()
	}
	io.cp(mut src, mut dst) or {}
}

// 块作用：根据 HTTP 版本 + Connection 头判断是否 keep-alive
// 处理问题（issue #2 sub-3）：
//   - HTTP/1.1 默认 keep-alive，Connection: close 关
//   - HTTP/1.0 默认 close，Connection: keep-alive 开
//   - 其它版本一律 close
fn should_keep_alive(version string, connection_value string) bool {
	if version == 'HTTP/1.1' {
		return connection_value != 'close'
	}
	if version == 'HTTP/1.0' {
		return connection_value == 'keep-alive'
	}
	return false
}

// 块作用：从响应头解析 keep-alive
// 处理问题：响应 Connection 头优先级与请求侧一致；解析失败按 close 处理。
fn parse_response_keep_alive(header_str string) bool {
	first_line := header_str.all_before('\r\n')
	parts := first_line.split(' ')
	if parts.len < 1 {
		return false
	}
	version := parts[0]
	mut connection_value := ''
	for line in header_str.split('\r\n') {
		if line == '' {
			break
		}
		lower := line.to_lower()
		if lower.starts_with('connection:') {
			connection_value = line.all_after(':').trim_space().to_lower()
		}
	}
	return should_keep_alive(version, connection_value)
}

// 块作用：向响应头注入 Via / Proxy-Agent（幂等）
// 处理问题：上游可能已带这些头，去重避免重复；连接行为 RFC 7230 §5.7.1
// 允许多 Via 拼接但简单起见这里覆盖。
fn inject_proxy_headers_into_response(head string) string {
	mut lines := head.split('\r\n')
	mut header_end := -1
	for i, line in lines {
		if line == '' {
			header_end = i
			break
		}
	}
	if header_end < 0 {
		return head
	}
	mut new_lines := []string{}
	mut has_via := false
	mut has_agent := false
	for i, line in lines {
		if i == header_end {
			break
		}
		lower := line.to_lower()
		if lower.starts_with('via:') {
			has_via = true
		}
		if lower.starts_with('proxy-agent:') {
			has_agent = true
		}
		new_lines << line
	}
	if !has_via {
		new_lines << proxy_via_header
	}
	if !has_agent {
		new_lines << proxy_agent_header
	}
	new_lines << ''
	return new_lines.join('\r\n') + '\r\n'
}

// 块作用：从请求头提取 body framing
// 处理问题：Content-Length / chunked / 无体 三类；任意解析失败按 -1 / false。
fn parse_request_framing(header_lines []string) (int, bool) {
	mut content_length := -1
	mut chunked := false
	for line in header_lines {
		if line == '' {
			break
		}
		lower := line.to_lower()
		if lower.starts_with('content-length:') {
			content_length = line.all_after(':').trim_space().int()
		} else if lower.starts_with('transfer-encoding:') {
			if 'chunked' in line.all_after(':').trim_space().to_lower() {
				chunked = true
			}
		}
	}
	return content_length, chunked
}

// 块作用：转发请求体（已写入头部之后）
// 处理问题（issue #2 sub-3）：keep-alive 模式下必须明确读完请求体，
// 否则下一轮 "读响应" 会读到客户端的下一个请求头，破坏协议分帧。
fn forward_request_body(mut src net.TcpConn, mut dst net.TcpConn, header_lines []string,
	pending_body []u8) ! {
	content_length, chunked := parse_request_framing(header_lines)

	if pending_body.len > 0 {
		dst.write(pending_body)!
	}
	if chunked {
		pipe_chunked_remaining(mut src, mut dst)!
	} else if content_length >= 0 {
		mut remaining := content_length - pending_body.len
		if remaining > 0 {
			pipe_n_bytes(mut src, mut dst, remaining)!
		}
	}
	// 无 Content-Length / chunked：GET/HEAD/OPTIONS/DELETE 等，body 长度 0
}

// 块作用：从响应头提取 body framing
// 处理问题：响应侧比请求多 Connection: close 兜底（无 CL 也无 chunked 时按 EOF 读）。
fn parse_response_framing(header_lines []string) (int, bool, bool) {
	mut content_length := -1
	mut chunked := false
	mut connection_close := false
	for line in header_lines {
		if line == '' {
			break
		}
		lower := line.to_lower()
		if lower.starts_with('content-length:') {
			content_length = line.all_after(':').trim_space().int()
		} else if lower.starts_with('transfer-encoding:') {
			if 'chunked' in line.all_after(':').trim_space().to_lower() {
				chunked = true
			}
		} else if lower.starts_with('connection:') {
			if 'close' in line.all_after(':').trim_space().to_lower() {
				connection_close = true
			}
		}
	}
	return content_length, chunked, connection_close
}

// 块作用：转发响应体（响应头已发出之后）
// 处理问题（issue #2 sub-3）：按 framing 把上游 body 转给客户端；
// 无 framing 时按 io.cp 读至 EOF（HTTP/1.0 默认行为）。
fn forward_response_body(mut src net.TcpConn, mut dst net.TcpConn, header_str string,
	pending_body []u8) ! {
	header_lines := header_str.split('\r\n')
	content_length, chunked, _ := parse_response_framing(header_lines)

	if pending_body.len > 0 {
		dst.write(pending_body)!
	}
	if chunked {
		pipe_chunked_remaining(mut src, mut dst)!
	} else if content_length >= 0 {
		mut remaining := content_length - pending_body.len
		if remaining > 0 {
			pipe_n_bytes(mut src, mut dst, remaining)!
		}
	} else {
		// 无明确 framing，按 EOF 透传；调用方需要靠 upstream_close 决定是否 keep-alive
		io.cp(mut src, mut dst)!
	}
}

// 块作用：管道传输恰好 n 字节
// 处理问题：用于 Content-Length 已知场景；中途 src 关闭则报错，避免静默丢包。
fn pipe_n_bytes(mut src net.TcpConn, mut dst net.TcpConn, n int) ! {
	if n <= 0 {
		return
	}
	mut remaining := n
	mut buf := []u8{len: copy_buffer_size}
	for remaining > 0 {
		to_read := if remaining > buf.len { buf.len } else { remaining }
		r := src.read(mut buf[..to_read]) or { return err }
		if r <= 0 {
			return error('source closed prematurely: need ${remaining} more bytes')
		}
		dst.write(buf[..r]) or { return err }
		remaining -= r
	}
}

// 块作用：chunked 解码 + 透传
// 处理问题（issue #2 sub-3）：HTTP/1.1 chunked 编码是 keep-alive 唯一
// 不依赖 Content-Length 的 framing，必须正确解析 chunk-size（含 ;ext）
// 和终止 chunk 0\r\n\r\n。
fn pipe_chunked_remaining(mut src net.TcpConn, mut dst net.TcpConn) ! {
	mut buf := []u8{len: 1}
	for {
		// 读 chunk-size 行（含可选 ;ext），以 \r\n 结尾
		mut size_line := []u8{}
		for {
			r := src.read(mut buf) or { return err }
			if r == 0 {
				return error('unexpected EOF reading chunk size')
			}
			size_line << buf[0]
			if buf[0] == `\n` {
				break
			}
		}
		mut size_str := size_line.bytestr()
		if size_str.ends_with('\r\n') {
			size_str = size_str[..size_str.len - 2]
		} else if size_str.ends_with('\n') {
			size_str = size_str[..size_str.len - 1]
		}
		// 去掉 chunk extension
		if size_str.contains(';') {
			size_str = size_str.all_before(';')
		}
		size_str = size_str.trim_space()
		chunk_size := parse_hex(size_str)!
		if chunk_size == 0 {
			// 终止 chunk：读 trailer 段直到空行
			mut trailer := []u8{}
			for {
				mut b := []u8{len: 1}
				r := src.read(mut b) or { return err }
				if r == 0 {
					break
				}
				trailer << b[0]
				if b[0] == `\n` {
					// 仅 "\r\n" 即空行，trailer 结束
					if trailer.len == 2 {
						return
					}
					trailer.clear()
				}
			}
			return
		}
		pipe_n_bytes(mut src, mut dst, chunk_size)!
		// 消费 chunk-data 后的 CRLF
		mut crlf := []u8{len: 2}
		mut got := 0
		for got < 2 {
			r := src.read(mut crlf[got..]) or { return err }
			if r == 0 {
				return error('unexpected EOF after chunk data')
			}
			got += r
		}
	}
}

// 块作用：解析十六进制字符串（chunked chunk-size）
// 处理问题：V 内置 int() 不支持 hex，需要手动实现。
fn parse_hex(s string) !int {
	if s.len == 0 {
		return error('empty hex')
	}
	mut result := 0
	for c in s {
		mut d := -1
		match c {
			`0` { d = 0 }
			`1` { d = 1 }
			`2` { d = 2 }
			`3` { d = 3 }
			`4` { d = 4 }
			`5` { d = 5 }
			`6` { d = 6 }
			`7` { d = 7 }
			`8` { d = 8 }
			`9` { d = 9 }
			`a`, `A` { d = 10 }
			`b`, `B` { d = 11 }
			`c`, `C` { d = 12 }
			`d`, `D` { d = 13 }
			`e`, `E` { d = 14 }
			`f`, `F` { d = 15 }
			else { return error('invalid hex char in chunk size: ${c}') }
		}
		result = (result << 4) | d
	}
	return result
}

// 块作用：目标解析
// 处理问题：从请求路径中提取 Host 和 Path，处理绝对 URL 和相对路径
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
	mut buf := []u8{len: copy_buffer_size}
	for {
		n := socket.read(mut buf) or { return err }
		if n <= 0 {
			return error('Bad request')
		}
		data << buf[..n]
		if data.len > max_header_bytes {
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

// 块作用：读取上游响应头部（与 read_request_head 同样的边界检测）
// 处理问题（issue #2 sub-3）：keep-alive 循环需要拿到完整响应头才能解析 framing。
fn read_response_head(mut src net.TcpConn) !([]u8, []u8) {
	mut data := []u8{}
	mut buf := []u8{len: copy_buffer_size}
	for {
		n := src.read(mut buf) or { return err }
		if n <= 0 {
			return error('Upstream closed before response head complete')
		}
		data << buf[..n]
		if data.len > max_header_bytes {
			return error('Response head too large')
		}
		start := if data.len > n + 3 { data.len - n - 3 } else { 0 }
		header_end := find_header_end_from(data, start)
		if header_end >= 0 {
			return data[..header_end + 4], data[header_end + 4..]
		}
	}
	return error('Bad response')
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