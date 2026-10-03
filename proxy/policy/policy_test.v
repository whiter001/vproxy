module policy

// 目标/客户端规则匹配：表驱动覆盖精确、通配（含根域）、CIDR、裸 IP、
// 空表、allow 白名单优先与 deny 命中拒绝语义（issue #30）。

struct Case {
	value string
	allow []string
	deny  []string
	want  bool
}

fn run_cases(cases []Case) {
	for c in cases {
		got := target_allowed(c.value, c.allow, c.deny)
		assert got == c.want, 'target_allowed(${c.value}, allow=${c.allow}, deny=${c.deny}) = ${got}, want ${c.want}'
	}
}

fn test_empty_rules_allow_all() {
	run_cases([
		Case{'example.com', [], [], true},
		Case{'1.2.3.4', [], [], true},
	])
}

fn test_exact_domain() {
	run_cases([
		Case{'example.com', ['example.com'], [], true},
		Case{'sub.example.com', ['example.com'], [], false},
		Case{'example.com', [], ['example.com'], false},
		Case{'sub.example.com', [], ['example.com'], true},
		// 大小写不敏感
		Case{'Example.COM', ['example.com'], [], true},
	])
}

fn test_wildcard() {
	// *.example.com 同时匹配根域与所有子域
	run_cases([
		Case{'example.com', ['*.example.com'], [], true},
		Case{'sub.example.com', ['*.example.com'], [], true},
		Case{'a.b.example.com', ['*.example.com'], [], true},
		Case{'notexample.com', ['*.example.com'], [], false},
		Case{'example.com.evil.test', ['*.example.com'], [], false},
		Case{'sub.example.com', [], ['*.example.com'], false},
	])
}

fn test_cidr() {
	run_cases([
		Case{'10.1.2.3', ['10.0.0.0/8'], [], true},
		Case{'11.0.0.1', ['10.0.0.0/8'], [], false},
		Case{'10.1.2.3', [], ['10.0.0.0/8'], false},
		Case{'192.168.1.1', ['0.0.0.0/0'], [], true},
		Case{'10.0.0.1', ['10.0.0.1/32'], [], true},
		Case{'10.0.0.2', ['10.0.0.1/32'], [], false},
		// 域名不命中 CIDR
		Case{'example.com', ['10.0.0.0/8'], [], false},
		// 非法 CIDR 不命中（allow 非空 -> 拒绝）
		Case{'10.1.2.3', ['10.0.0.0/33'], [], false},
	])
}

fn test_bare_ip() {
	run_cases([
		Case{'1.2.3.4', ['1.2.3.4'], [], true},
		Case{'1.2.3.5', ['1.2.3.4'], [], false},
		Case{'1.2.3.4', [], ['1.2.3.4'], false},
		// 严格 IPv4 解析：带尾随垃圾的串不得当作 IPv4 命中 CIDR
		Case{'10.0.0.1x', ['10.0.0.0/8'], [], false},
	])
}

fn test_allow_then_deny() {
	// allow 白名单先行（非空必须命中），deny 再拒
	run_cases([
		Case{'a.example.com', ['*.example.com'], ['a.example.com'], false},
		Case{'b.example.com', ['*.example.com'], ['a.example.com'], true},
		Case{'other.test', ['*.example.com'], [], false},
	])
}

fn test_client_allowed() {
	assert client_allowed('127.0.0.1', [], []) == true
	assert client_allowed('127.0.0.1', [], ['127.0.0.0/8']) == false
	assert client_allowed('127.0.0.1', ['127.0.0.1'], []) == true
	assert client_allowed('::1', ['127.0.0.0/8'], []) == false
	assert client_allowed('1.2.3.4', ['1.2.3.0/24'], ['1.2.3.4']) == false
}
