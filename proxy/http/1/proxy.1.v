module main

import httpsrv
import os
import policy
import upstream as upx
import vpcli

// 块作用：入口函数
// 处理问题：
// - issue #4：CLI 参数解析（vpcli.parse_http_args）
// - issue #1：PROXY_REQUIRE_AUTH=0 / fail-fast 配置
// 监听 / accept / 优雅退出循环见 httpsrv.serve（issue #29 前置拆分）。
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

	expected_auth, require_auth := httpsrv.proxy_auth_config(cfg.auth_basic, cfg.auth_user, cfg.auth_pass, cfg.require_auth) or {
		eprintln('Error: ${err}')
		eprintln('       Set PROXY_AUTH_USER and PROXY_AUTH_PASS,')
		eprintln('       or PROXY_AUTH_BASIC=<base64(user:pass)>,')
		eprintln('       or PROXY_REQUIRE_AUTH=0 to disable authentication.')
		C.exit(1)
	}

	// 上级代理（issue #27）：配置了 --parent 则全部流量经上级转发（强制走上级）；
	// URL 非法时 fail-fast，不以半可用状态启动。
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
	vpcli.print_effective_config(vpcli.EffectiveConfig{
		label:        'http'
		listen_addr:  cfg.listen_addr
		auth_user:    cfg.auth_user
		auth_pass:    cfg.auth_pass
		auth_basic:   cfg.auth_basic
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

	// 策略配置（issue #30）：目标域名黑白名单 + 客户端 IP 黑白名单
	rules := policy.Rules{
		allow:        cfg.allow_rules
		deny:         cfg.deny_rules
		client_allow: cfg.client_allow
		client_deny:  cfg.client_deny
	}

	idle_dur := cfg.idle_timeout
	httpsrv.serve(cfg.listen_addr, expected_auth, require_auth, idle_dur, rules, parent)
}
