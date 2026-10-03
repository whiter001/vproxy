module upstream

// parse_parent / safe_str：表驱动覆盖两种 scheme、认证段、错误分支（issue #27）。

fn test_parse_parent_valid() {
	p1 := parse_parent('http://1.2.3.4:8080')!
	assert p1.scheme == .http
	assert p1.host == '1.2.3.4'
	assert p1.port == u16(8080)
	assert p1.user == ''
	assert p1.pass == ''

	p2 := parse_parent('http://user:pass@proxy.local:3128')!
	assert p2.scheme == .http
	assert p2.host == 'proxy.local'
	assert p2.port == u16(3128)
	assert p2.user == 'user'
	assert p2.pass == 'pass'

	p3 := parse_parent('socks5://1.2.3.4:1080')!
	assert p3.scheme == .socks5
	assert p3.host == '1.2.3.4'
	assert p3.port == u16(1080)

	p4 := parse_parent('socks5://u:p@127.0.0.1:1080')!
	assert p4.scheme == .socks5
	assert p4.user == 'u'
	assert p4.pass == 'p'
}

fn test_parse_parent_invalid() {
	cases := [
		'1.2.3.4:8080', // 缺 scheme
		'ftp://1.2.3.4:8080', // 未知 scheme
		'http://1.2.3.4', // 缺端口
		'http://1.2.3.4:0', // 非法端口
		'http://1.2.3.4:99999', // 端口超界（防 u16 回绕）
		'http://1.2.3.4:-1', // 负端口
		'http://1.2.3.4:abc', // 非数字端口
		'http://:8080', // 空 host
		'http://user@1.2.3.4:8080', // 认证段缺 pass
		'http://a@b@1.2.3.4:8080', // 多余 @
		'', // 空串
	]
	for c in cases {
		if _ := parse_parent(c) {
			assert false, 'parse_parent(${c}) 应报错却成功'
		}
	}
}

fn test_safe_str_masks_password() {
	p := parse_parent('http://alice:s3cret@1.2.3.4:8080')!
	s := p.safe_str()
	assert s == 'http://alice:******@1.2.3.4:8080'
	assert !s.contains('s3cret')

	p2 := parse_parent('socks5://1.2.3.4:1080')!
	assert p2.safe_str() == 'socks5://1.2.3.4:1080'
}
