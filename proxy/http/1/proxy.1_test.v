module main

import encoding.base64

// split_target：绝对 URL / 相对路径 / 裸 authority / wss 保端口。
fn test_split_target() {
	// 绝对 URL：剥掉 scheme，拆出 authority 与 path
	auth, path := split_target('http://example.com/hello?q=1')
	assert auth == 'example.com'
	assert path == '/hello?q=1'

	// 相对路径：authority 为空，path 保留原样
	auth2, path2 := split_target('/health')
	assert auth2 == ''
	assert path2 == '/health'

	// 裸 authority：无 path 时默认 '/'
	auth3, path3 := split_target('example.com:8080')
	assert auth3 == 'example.com:8080'
	assert path3 == '/'

	// https / wss scheme 同样剥掉
	auth4, path4 := split_target('wss://example.com/ws')
	assert auth4 == 'example.com'
	assert path4 == '/ws'
}

// normalize_authority：无端口补默认，有端口保留，空串返回空。
fn test_normalize_authority() {
	assert normalize_authority('example.com', ':80') == 'example.com:80'
	assert normalize_authority('example.com:8080', ':80') == 'example.com:8080'
	assert normalize_authority('', ':80') == ''
	// 空白会被 trim
	assert normalize_authority('  example.com  ', ':443') == 'example.com:443'
}

// proxy_auth_config：鉴权开关、auth_basic 优先、缺凭据报错。
fn test_proxy_auth_config() {
	// require_auth=false：返回 ('', false)
	basic, required := proxy_auth_config('', '', '', false) or {
		assert false, 'require_auth=false 不应报错: ${err}'
		return
	}
	assert basic == ''
	assert required == false

	// auth_basic 优先于 user/pass
	basic2, required2 := proxy_auth_config('bXl1c2VyOm15cGFzcw==', 'other', 'creds', true) or {
		assert false, 'auth_basic 模式不应报错: ${err}'
		return
	}
	assert basic2 == 'bXl1c2VyOm15cGFzcw=='
	assert required2 == true

	// 缺 user 或 pass → error（fail-fast）
	if _, _ := proxy_auth_config('', '', '', true) {
		assert false, '缺凭据应报错但成功了'
	}
	if _, _ := proxy_auth_config('', 'user', '', true) {
		assert false, '缺 pass 应报错但成功了'
	}

	// 提供 user/pass → base64(user:pass)
	basic3, required3 := proxy_auth_config('', 'user', 'pass', true) or {
		assert false, 'user/pass 模式不应报错: ${err}'
		return
	}
	assert basic3 == base64.encode_str('user:pass')
	assert required3 == true
}

// find_header_end_from：定位 \r\n\r\n。
fn test_find_header_end_from() {
	data := 'GET / HTTP/1.1\r\nHost: a\r\n\r\nbody'.bytes()
	assert find_header_end_from(data, 0) == 23
	// start 参数可从上次扫描位置继续
	assert find_header_end_from(data, 20) == 23
	// 未找到返回 -1
	assert find_header_end_from('no header terminator'.bytes(), 0) == -1
	// 长度不足 4 直接 -1
	assert find_header_end_from([]u8{len: 3}, 0) == -1
}

// connection_keep_alive：HTTP/1.1 默认持久；Connection: close 覆盖；
// HTTP/1.0 需显式 keep-alive；close 与 keep-alive 并存时 close 优先。
fn test_connection_keep_alive() {
	// HTTP/1.1 无 Connection 头 → 默认持久
	assert connection_keep_alive('HTTP/1.1', '') == true
	// HTTP/1.1 显式 keep-alive → 持久
	assert connection_keep_alive('HTTP/1.1', 'keep-alive') == true
	// HTTP/1.1 显式 close → 不持久
	assert connection_keep_alive('HTTP/1.1', 'close') == false
	// 逗号分隔列表：close 覆盖 keep-alive（RFC 7230 §6.3）
	assert connection_keep_alive('HTTP/1.1', 'keep-alive, close') == false
	// HTTP/1.0 无 keep-alive token → 不持久
	assert connection_keep_alive('HTTP/1.0', '') == false
	// HTTP/1.0 显式 keep-alive → 持久
	assert connection_keep_alive('HTTP/1.0', 'keep-alive') == true
	// 调用处已 to_lower：这里直接验证小写 token 的列表解析
	assert connection_keep_alive('HTTP/1.1', 'upgrade, keep-alive') == true
}

// rewrite_response_connection：剥离上游 Connection / Proxy-Connection，
// 按 keep_alive 补 Connection: keep-alive / close，并保证以 '' 结尾（终止空行占位）。
fn test_rewrite_response_connection() {
	// 剥离上游 Connection: close，补 keep-alive
	lines := ['HTTP/1.1 200 OK', 'Content-Type: text/plain', 'Connection: close', '']
	rewritten := rewrite_response_connection(lines, true)
	assert rewritten == ['HTTP/1.1 200 OK', 'Content-Type: text/plain', 'Connection: keep-alive',
		'']

	// 不复用时补 Connection: close
	rewritten2 := rewrite_response_connection(lines, false)
	assert rewritten2 == ['HTTP/1.1 200 OK', 'Content-Type: text/plain', 'Connection: close', '']

	// 上游无 Connection 头时也正常补全
	lines2 := ['HTTP/1.1 200 OK', '']
	rewritten3 := rewrite_response_connection(lines2, true)
	assert rewritten3 == ['HTTP/1.1 200 OK', 'Connection: keep-alive', '']

	// Proxy-Connection 同样剥离
	lines3 := ['HTTP/1.1 200 OK', 'Proxy-Connection: keep-alive', '']
	rewritten4 := rewrite_response_connection(lines3, true)
	assert rewritten4 == ['HTTP/1.1 200 OK', 'Connection: keep-alive', '']

	// 头以裸状态行结尾（无尾部 \r\n）时也以 '' 收尾，保证 join 后为完整 \r\n\r\n
	lines4 := ['HTTP/1.1 200 OK']
	rewritten5 := rewrite_response_connection(lines4, true)
	assert rewritten5 == ['HTTP/1.1 200 OK', 'Connection: keep-alive', '']
	assert rewritten5.join('\r\n') + '\r\n' == 'HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n'
}

// response_has_body_length：有 Content-Length 或 Transfer-Encoding 才认为响应体可定界。
fn test_response_has_body_length() {
	assert response_has_body_length(['HTTP/1.1 200 OK', 'Content-Length: 5', '']) == true
	assert response_has_body_length(['HTTP/1.1 200 OK', 'Transfer-Encoding: chunked', '']) == true
	assert response_has_body_length(['HTTP/1.1 200 OK', 'Connection: close', '']) == false
	// 大小写不敏感
	assert response_has_body_length(['HTTP/1.1 200 OK', 'content-length: 5', '']) == true
}
