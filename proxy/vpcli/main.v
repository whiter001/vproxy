// proxy/vpcli/main.v
//
// 命令行参数解析（issue #4）。
//
// 提供 HTTP / SOCKS5 代理的 CLI > env > default 三级优先级配置解析。
// 支持子命令 `serve`（默认）；未来扩展 `gen-ca` / `bench` 留口。
//
// 用法（HTTP）：
//   import vpcli
//   cfg := vpcli.parse_http_args(os.args) or { exit(1) }
//   if cfg.show_help { vpcli.print_http_help(); exit(0) }
//   if cfg.show_version { println('vproxy ${vpcli.version}'); exit(0) }
//   listen_addr := cfg.listen_addr
//
// 注意：
// - 本模块只解析标志；具体逻辑（如 `PROXY_REQUIRE_AUTH=0` 关闭鉴权）
//   由调用方在拿到 Config 后处理。
// - 配置文件 TOML 加载（issue #6）暂未实现，`--config` 参数保留为预留。
// - 模块名用 `vpcli` 而不是 `cli`，避免与 V 标准库的 cli 子命令框架撞名。
// - 调用 flag.FlagParser 之前手动 strip 掉 exe + subcommand，**不**调用
//   fp.skip_executable()，否则它会把第一个 flag 当成可执行路径删掉。
module vpcli

import flag
import os
import time

pub const version = '0.2.0'

// HTTP 代理配置（CLI > env > default 三级优先级）
pub struct HttpConfig {
pub mut:
	listen_addr  string
	auth_user    string
	auth_pass    string
	auth_basic   string
	require_auth bool // false 表示关闭鉴权（CLI --no-auth 或 env PROXY_REQUIRE_AUTH=0）
	idle_timeout time.Duration
	log_format   string
	log_level    string
	config_file  string
	show_help    bool
	show_version bool
}

// SOCKS5 代理配置
pub struct Socks5Config {
pub mut:
	listen_addr  string
	auth_user    string
	auth_pass    string
	no_auth      bool
	idle_timeout time.Duration
	log_format   string
	log_level    string
	config_file  string
	show_help    bool
	show_version bool
}

// 块作用：解析 HTTP 代理命令行参数
// 处理问题（issue #4）：
// 1. 子命令分发：`serve`（默认）/ `--help` / `--version`
// 2. CLI > env > default 三级优先级：`-l :1234` 覆盖 PROXY_LISTEN_ADDR
// 3. 未识别选项返回 error，调用方决定退出码
pub fn parse_http_args(args []string) !HttpConfig {
	rest, sub_error := strip_executable_and_subcommand(args)
	if sub_error != '' {
		return error(sub_error)
	}

	mut fp := flag.new_flag_parser(rest)
	fp.application('vproxy http serve')
	fp.version(version)
	fp.description('V-language HTTP forward proxy (CONNECT + Basic auth)')

	listen := fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or {
		''
	}
	user := fp.string_opt('user', `u`, 'username', flag.FlagConfig{ val_desc: 'name' }) or { '' }
	pass := fp.string_opt('pass', `p`, 'password', flag.FlagConfig{ val_desc: 'pwd' }) or { '' }
	basic := fp.string_opt('auth-basic', `b`, 'pre-encoded Basic credential (base64(user:pass))', flag.FlagConfig{
		val_desc: 'b64'
	}) or { '' }
	no_auth := fp.bool_opt('no-auth', `n`, 'disable authentication', flag.FlagConfig{}) or { false }
	config_file := fp.string_opt('config', `c`, 'config file (reserved for issue #6)', flag.FlagConfig{
		val_desc: 'path'
	}) or { '' }
	log_format := fp.string_opt('log-format', `f`, 'log format: text|json', flag.FlagConfig{
		val_desc: 'fmt'
	}) or { 'text' }
	log_level := fp.string_opt('log-level', 0, 'log level: debug|info|warn|error', flag.FlagConfig{
		val_desc: 'lvl'
	}) or { 'info' }
	show_help := fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	show_version := fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or {
		false
	}

	// 未识别选项：vpcli 已经在 finalize 失败时打印 err + usage，
	// 这里返回错误让调用方决定退出码
	fp.finalize() or { return error(err.msg()) }

	// 三级优先级：CLI > env > default
	final_listen := if listen != '' { listen } else { os.getenv_opt('PROXY_LISTEN_ADDR') or {
			':5777'} }
	final_user := if user != '' { user } else { os.getenv_opt('PROXY_AUTH_USER') or { '' } }
	final_pass := if pass != '' { pass } else { os.getenv_opt('PROXY_AUTH_PASS') or { '' } }
	final_basic := if basic != '' { basic } else { os.getenv_opt('PROXY_AUTH_BASIC') or { '' } }

	mut require_auth := true
	if no_auth {
		require_auth = false
	} else if os.getenv_opt('PROXY_REQUIRE_AUTH') or { '' } == '0' {
		require_auth = false
	}

	return HttpConfig{
		listen_addr:  final_listen
		auth_user:    final_user
		auth_pass:    final_pass
		auth_basic:   final_basic
		require_auth: require_auth
		idle_timeout: parse_idle_timeout('PROXY_IDLE_TIMEOUT', 300)
		log_format:   log_format
		log_level:    log_level
		config_file:  config_file
		show_help:    show_help
		show_version: show_version
	}
}

// 块作用：解析 SOCKS5 代理命令行参数
pub fn parse_socks5_args(args []string) !Socks5Config {
	rest, sub_error := strip_executable_and_subcommand(args)
	if sub_error != '' {
		return error(sub_error)
	}

	mut fp := flag.new_flag_parser(rest)
	fp.application('vproxy socks5 serve')
	fp.version(version)
	fp.description('V-language SOCKS5 proxy (RFC 1928/1929, CONNECT + user/pass auth)')

	listen := fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or {
		''
	}
	user := fp.string_opt('user', `u`, 'username', flag.FlagConfig{ val_desc: 'name' }) or { '' }
	pass := fp.string_opt('pass', `p`, 'password', flag.FlagConfig{ val_desc: 'pwd' }) or { '' }
	no_auth := fp.bool_opt('no-auth', `n`, 'disable authentication', flag.FlagConfig{}) or { false }
	config_file := fp.string_opt('config', `c`, 'config file (reserved for issue #6)', flag.FlagConfig{
		val_desc: 'path'
	}) or { '' }
	log_format := fp.string_opt('log-format', `f`, 'log format: text|json', flag.FlagConfig{
		val_desc: 'fmt'
	}) or { 'text' }
	log_level := fp.string_opt('log-level', 0, 'log level: debug|info|warn|error', flag.FlagConfig{
		val_desc: 'lvl'
	}) or { 'info' }
	show_help := fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	show_version := fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or {
		false
	}

	fp.finalize() or { return error(err.msg()) }

	final_listen := if listen != '' { listen } else { os.getenv_opt('SOCKS5_LISTEN_ADDR') or {
			':5778'} }
	final_user := if user != '' { user } else { os.getenv_opt('SOCKS5_AUTH_USERNAME') or { '' } }
	final_pass := if pass != '' { pass } else { os.getenv_opt('SOCKS5_AUTH_PASSWORD') or { '' } }

	mut final_no_auth := false
	if no_auth {
		final_no_auth = true
	} else if os.getenv_opt('SOCKS5_NO_AUTH') or { '' } == '1' {
		final_no_auth = true
	}

	return Socks5Config{
		listen_addr:  final_listen
		auth_user:    final_user
		auth_pass:    final_pass
		no_auth:      final_no_auth
		idle_timeout: parse_idle_timeout('SOCKS5_IDLE_TIMEOUT', 300)
		log_format:   log_format
		log_level:    log_level
		config_file:  config_file
		show_help:    show_help
		show_version: show_version
	}
}

// 块作用：剥离 os.args 的 exe 路径和子命令
// 处理问题：flag.FlagParser 默认假设 args[0] 是 exe，不能再调 skip_executable()。
// 我们手动 strip 掉 exe + 可能的子命令（`serve`），剩下的就是纯 flag 数组。
// 返回：(剩余 flags, 错误信息)。错误信息非空时表示子命令未识别。
fn strip_executable_and_subcommand(args []string) ([]string, string) {
	if args.len <= 1 {
		return []string{}, ''
	}
	rest := args[1..] // strip exe
	if rest.len > 0 && !rest[0].starts_with('-') {
		sub := rest[0]
		if !is_serve_or_help(sub) {
			eprintln('Error: unknown subcommand "${sub}"')
			eprintln('Run with --help for usage.')
			return []string{}, 'unknown subcommand: ${sub}'
		}
		return rest[1..], ''
	}
	return rest, ''
}

fn is_serve_or_help(s string) bool {
	return s == 'serve' || s == '--help' || s == '-h' || s == '--version' || s == '-v'
		|| s == 'help' || s == 'version'
}

// 打印 HTTP 代理 usage（含版本、子命令说明、选项表）
pub fn print_http_help() {
	mut fp := flag.new_flag_parser([]string{})
	fp.application('vproxy http serve')
	fp.version(version)
	fp.description('V-language HTTP forward proxy (CONNECT + Basic auth)')
	fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or { '' }
	fp.string_opt('user', `u`, 'username', flag.FlagConfig{ val_desc: 'name' }) or { '' }
	fp.string_opt('pass', `p`, 'password', flag.FlagConfig{ val_desc: 'pwd' }) or { '' }
	fp.string_opt('auth-basic', `b`, 'pre-encoded Basic credential (base64(user:pass))', flag.FlagConfig{
		val_desc: 'b64'
	}) or { '' }
	fp.bool_opt('no-auth', `n`, 'disable authentication', flag.FlagConfig{}) or { false }
	fp.string_opt('config', `c`, 'config file (reserved for issue #6)', flag.FlagConfig{
		val_desc: 'path'
	}) or { '' }
	fp.string_opt('log-format', `f`, 'log format: text|json', flag.FlagConfig{ val_desc: 'fmt' }) or {
		''
	}
	fp.string_opt('log-level', 0, 'log level: debug|info|warn|error', flag.FlagConfig{
		val_desc: 'lvl'
	}) or { '' }
	fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or { false }
	fp.finalize() or {}
	println(fp.usage())
}

pub fn print_socks5_help() {
	mut fp := flag.new_flag_parser([]string{})
	fp.application('vproxy socks5 serve')
	fp.version(version)
	fp.description('V-language SOCKS5 proxy (RFC 1928/1929, CONNECT + user/pass auth)')
	fp.string_opt('listen', `l`, 'listen address', flag.FlagConfig{ val_desc: 'addr' }) or { '' }
	fp.string_opt('user', `u`, 'username', flag.FlagConfig{ val_desc: 'name' }) or { '' }
	fp.string_opt('pass', `p`, 'password', flag.FlagConfig{ val_desc: 'pwd' }) or { '' }
	fp.bool_opt('no-auth', `n`, 'disable authentication', flag.FlagConfig{}) or { false }
	fp.string_opt('config', `c`, 'config file (reserved for issue #6)', flag.FlagConfig{
		val_desc: 'path'
	}) or { '' }
	fp.string_opt('log-format', `f`, 'log format: text|json', flag.FlagConfig{ val_desc: 'fmt' }) or {
		''
	}
	fp.string_opt('log-level', 0, 'log level: debug|info|warn|error', flag.FlagConfig{
		val_desc: 'lvl'
	}) or { '' }
	fp.bool_opt('help', `h`, 'show help and exit', flag.FlagConfig{}) or { false }
	fp.bool_opt('version', `v`, 'show version and exit', flag.FlagConfig{}) or { false }
	fp.finalize() or {}
	println(fp.usage())
}

fn parse_idle_timeout(env_var string, default_seconds int) time.Duration {
	raw := os.getenv_opt(env_var) or { return time.Duration(default_seconds) * time.second }
	secs := raw.int()
	if secs <= 0 {
		return time.infinite
	}
	return time.Duration(secs) * time.second
}
