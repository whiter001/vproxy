module socks5_dial

// parse_url 正常分支：表驱动覆盖三种格式。
fn test_parse_url_valid() {
	cases := [
		['socks5://1.2.3.4:1080', '1.2.3.4', '1080', '', ''],
		['socks5://user:pass@1.2.3.4:1080', '1.2.3.4', '1080', 'user', 'pass'],
		['1.2.3.4:1080', '1.2.3.4', '1080', '', ''],
		['socks5://example.com:1080', 'example.com', '1080', '', ''],
	]
	for c in cases {
		cfg := parse_url(c[0]) or {
			assert false, 'parse_url(${c[0]}) 不应报错: ${err}'
			return
		}
		assert cfg.host == c[1]
		assert cfg.port == u16(c[2].int())
		assert cfg.user == c[3]
		assert cfg.pass == c[4]
	}
}

// parse_url 错误分支：缺端口、空 host、port 0、多余 @。
fn test_parse_url_errors() {
	bad_urls := [
		'socks5://1.2.3.4', // 缺端口
		'socks5://:1080', // 空 host
		'socks5://1.2.3.4:0', // port 0
		'socks5://a:b@c:d@1.2.3.4:1080', // 多个 @
		'socks5://user@1.2.3.4:1080', // 只有 user 无 pass
	]
	for u in bad_urls {
		if _ := parse_url(u) {
			assert false, 'parse_url(${u}) 应报错但成功了'
		}
	}
}

// 私有函数 is_all_digits_and_dots：IPv4 字面量粗判。
fn test_is_all_digits_and_dots() {
	assert is_all_digits_and_dots('1.2.3.4') == true
	assert is_all_digits_and_dots('0.0.0.0') == true
	assert is_all_digits_and_dots('example.com') == false
	assert is_all_digits_and_dots('') == false
	assert is_all_digits_and_dots('1.2.3.4a') == false
	assert is_all_digits_and_dots('1.2.3') == true // 粗判只看字符集
}
