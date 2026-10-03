// proxy/policy/policy.v
//
// 目标域名与客户端 IP 黑白名单（issue #30）。
//
// 规则形式（allow / deny / client_allow / client_deny 共用同一套语法）：
// - 精确域名：`example.com`
// - 通配：`*.example.com`，匹配 example.com 本身及所有子域
// - IPv4 CIDR：`10.0.0.0/8`，匹配作为 IPv4 字面量的目标或客户端
// - 裸 IPv4：`1.2.3.4`，精确匹配
//
// 判定语义：
// - allow 非空时必须命中 allow（白名单模式）
// - 命中 deny 一律拒绝
// - 两表皆空 = 全放行
//
// host 传入前由调用方剥掉端口（net.split_address）。
module policy

import net

// Rules 是三个代理共用的策略配置载体，由 vpcli 解析后经 main 透传到连接处理。
pub struct Rules {
pub:
	allow        []string
	deny         []string
	client_allow []string
	client_deny  []string
}

// 目标侧判定：host 为剥掉端口的目标（域名或 IP 字面量）。
pub fn target_allowed(host string, allow []string, deny []string) bool {
	return allowed(host, allow, deny)
}

// 客户端侧判定：ip 为客户端 IPv4/IPv6 字面量（不带端口）。
pub fn client_allowed(ip string, allow []string, deny []string) bool {
	return allowed(ip, allow, deny)
}

// 块作用：取 TCP 连接对端的 IP 字面量（不带端口）
// 处理问题：peer_addr().str() 形如 "1.2.3.4:5678" / "[::1]:5678"，
// 统一走 net.split_address 剥离端口，供 client_allowed 判定。
pub fn peer_ip(socket &net.TcpConn) !string {
	addr := socket.peer_addr()!
	host, _ := net.split_address(addr.str())!
	return host
}

// 块作用：统一判定入口
// 处理问题：allow 白名单优先（非空必须命中），deny 次之（命中即拒），默认放行。
fn allowed(value string, allow []string, deny []string) bool {
	if allow.len > 0 && !matches_any(value, allow) {
		return false
	}
	if matches_any(value, deny) {
		return false
	}
	return true
}

fn matches_any(value string, rules []string) bool {
	for rule in rules {
		if match_rule(value, rule) {
			return true
		}
	}
	return false
}

// 块作用：单条规则匹配
// 处理问题：按规则形态分发 CIDR / 通配 / 精确比较；空规则不命中任何值。
fn match_rule(value string, rule string) bool {
	r := rule.trim_space()
	if r == '' {
		return false
	}
	if r.contains('/') {
		return match_cidr(value, r)
	}
	if r.starts_with('*.') {
		suffix := r[2..].to_lower()
		v := value.to_lower()
		return v == suffix || v.ends_with('.${suffix}')
	}
	return value.to_lower() == r.to_lower()
}

// 块作用：IPv4 CIDR 匹配（如 10.0.0.0/8）
// 处理问题：域名与 IPv6 不是 IPv4 字面量，一律不命中；非法 CIDR 写法同样不命中。
fn match_cidr(ip string, cidr string) bool {
	parts := cidr.split('/')
	if parts.len != 2 {
		return false
	}
	base := parse_ipv4(parts[0]) or { return false }
	addr := parse_ipv4(ip) or { return false }
	bits := parts[1].int()
	if bits < 0 || bits > 32 {
		return false
	}
	if bits == 0 {
		return true
	}
	mask := u32(0xffffffff) << u32(32 - bits)
	return (base & mask) == (addr & mask)
}

// 块作用：严格解析 IPv4 字面量为 u32
// 处理问题：string.int() 只取数字前缀（"1a".int()==1），必须逐字符校验，
// 否则 "10.0.0.1x" 这类值会被误判为合法 IPv4 而命中 CIDR。
fn parse_ipv4(s string) !u32 {
	parts := s.split('.')
	if parts.len != 4 {
		return error('not ipv4')
	}
	mut result := u32(0)
	for p in parts {
		if p.len == 0 || p.len > 3 {
			return error('not ipv4')
		}
		for c in p {
			if c < `0` || c > `9` {
				return error('not ipv4')
			}
		}
		n := p.int()
		if n > 255 {
			return error('not ipv4')
		}
		result = (result << 8) | u32(n)
	}
	return result
}
