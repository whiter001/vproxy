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
