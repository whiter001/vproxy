module main

import os
import policy
import socks5srv
import upstream as upx
import vpcli

// 块作用：入口函数
// 处理问题：
// - issue #4：CLI 参数解析（vpcli.parse_socks5_args）
// 监听 / accept / 优雅退出循环见 socks5srv.serve（issue #29 前置拆分）。
fn main() {
	cfg := vpcli.parse_socks5_args(os.args) or {
		eprintln('parse error: ${err}')
		C.exit(1)
	}
	if cfg.show_help {
		vpcli.print_socks5_help()
		return
	}
	if cfg.show_version {
		println('vproxy ${vpcli.version}')
		return
	}

	listen_addr := cfg.listen_addr
	// --no-auth / SOCKS5_NO_AUTH=1 must override configured credentials.
	expected_user := if cfg.no_auth { '' } else { cfg.auth_user }
	expected_pass := if cfg.no_auth { '' } else { cfg.auth_pass }

	// 上级代理（issue #27）：配置了 --parent 则全部流量经上级转发；URL 非法 fail-fast。
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
	// 打印生效配置：auth.password 打码，避免敏感信息进启动日志
	vpcli.print_effective_config(vpcli.EffectiveConfig{
		label:        'socks5'
		listen_addr:  cfg.listen_addr
		auth_user:    cfg.auth_user
		auth_pass:    cfg.auth_pass
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

	// 策略配置（issue #30）：目标黑白名单 + 客户端 IP 黑白名单
	rules := policy.Rules{
		allow:        cfg.allow_rules
		deny:         cfg.deny_rules
		client_allow: cfg.client_allow
		client_deny:  cfg.client_deny
	}

	idle_dur := cfg.idle_timeout

	// UDP ASSOCIATE（issue #26）的 relay 绑定地址与 TCP 监听同 host；
	// listen 非法时 vpcli 已 fail-fast。IPv6 保留方括号（[::]:0 为规范形式）。
	relay_host := listen_addr.all_before_last(':')

	socks5srv.serve(cfg.listen_addr, expected_user, expected_pass, idle_dur, rules, parent, relay_host)
}
