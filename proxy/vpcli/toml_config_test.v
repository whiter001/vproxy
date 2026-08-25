module vpcli

import os
import time

// 写临时 TOML 文件，返回路径；写失败直接 assert 失败。
fn write_tmp_toml(name string, content string) string {
	path := os.join_path(os.temp_dir(), 'vpcli_${name}.toml')
	os.write_file(path, content) or { assert false, 'write ${path}: ${err}' }
	return path
}

fn test_load_toml_config_valid() {
	path := write_tmp_toml('valid',
		'listen = "0.0.0.0:5777"\nauth = { user = "alice", password = "secret" }\nlog = { level = "info", format = "json" }\nmetrics_addr = "127.0.0.1:9090"\nidle_timeout_seconds = 300\n\n[rules]\nallow = ["*.example.com", "10.0.0.0/8"]\ndeny = ["evil.test"]\n')
	defer {
		os.rm(path) or {}
	}
	cfg := load_toml_config(path)!
	assert cfg.listen_addr == '0.0.0.0:5777'
	assert cfg.auth_user == 'alice'
	assert cfg.auth_pass == 'secret'
	assert cfg.log_level == 'info'
	assert cfg.log_format == 'json'
	assert cfg.metrics_addr == '127.0.0.1:9090'
	assert cfg.idle_timeout_seconds == ?int(300)
	assert cfg.allow_rules == ['*.example.com', '10.0.0.0/8']
	assert cfg.deny_rules == ['evil.test']
}

fn test_load_toml_config_missing_key_defaults() {
	// 空文件：所有字段走默认（空字符串 / none / 空数组），不报错。
	path := write_tmp_toml('empty', '')
	defer {
		os.rm(path) or {}
	}
	cfg := load_toml_config(path)!
	assert cfg.listen_addr == ''
	assert cfg.auth_user == ''
	assert cfg.auth_pass == ''
	assert cfg.idle_timeout_seconds == none
	assert cfg.allow_rules.len == 0
	assert cfg.deny_rules.len == 0
}

fn test_load_toml_config_type_error_with_line() {
	path := write_tmp_toml('bad_listen', 'listen = "0.0.0.0:5777"\nmetrics_addr = 123\n')
	defer {
		os.rm(path) or {}
	}
	// 类型不对（int 当 string）必须 fail-fast，且错误含 path:line
	if _ := load_toml_config(path) {
		assert false, 'listen=123 应报类型错误'
	} else {
		msg := err.msg()
		assert msg.contains(path), '错误应含文件路径: ${msg}'
		assert msg.contains(':2:'), '错误应含行号 2: ${msg}'
		assert msg.contains('must be a string'), '错误应说明类型要求: ${msg}'
	}
}

fn test_load_toml_config_inline_table_type_error() {
	path := write_tmp_toml('bad_auth', 'auth = "not-a-table"\n')
	defer {
		os.rm(path) or {}
	}
	if _ := load_toml_config(path) {
		assert false, 'auth=string 应报表类型错误'
	} else {
		msg := err.msg()
		assert msg.contains(path), '错误应含文件路径: ${msg}'
		assert msg.contains(':1:'), '错误应含行号 1: ${msg}'
		assert msg.contains('must be a table'), '错误应说明类型要求: ${msg}'
	}
}

fn test_load_toml_config_syntax_error_with_line() {
	// `[auth` 缺右括号：语法错误，必须含路径 + 行号（行号来自渐进前缀解析）
	path := write_tmp_toml('bad_syntax', 'listen = "1"\n[auth\nuser="x"\n')
	defer {
		os.rm(path) or {}
	}
	if _ := load_toml_config(path) {
		assert false, '坏语法应报错'
	} else {
		msg := err.msg()
		assert msg.contains(path), '错误应含文件路径: ${msg}'
		assert msg.contains('invalid TOML syntax'), '错误应说明语法问题: ${msg}'
		// 行号定位是 best-effort：至少要求定位到第 2 行（[auth 所在行）
		assert msg.contains(':2:'), '错误应含行号 2: ${msg}'
	}
}

fn test_load_toml_config_unknown_key() {
	path := write_tmp_toml('unknown_key', 'listen = "0.0.0.0:5777"\nbogus_key = "x"\n')
	defer {
		os.rm(path) or {}
	}
	if _ := load_toml_config(path) {
		assert false, '未知顶层键应报错'
	} else {
		msg := err.msg()
		assert msg.contains(path), '错误应含文件路径: ${msg}'
		assert msg.contains(':2:'), '错误应含行号 2: ${msg}'
		assert msg.contains('unknown key "bogus_key"'), '错误应指出未知键: ${msg}'
	}
}

fn test_load_toml_config_invalid_log_level() {
	path := write_tmp_toml('bad_level', 'log = { level = "verbose" }\n')
	defer {
		os.rm(path) or {}
	}
	if _ := load_toml_config(path) {
		assert false, '非法 log.level 应报错'
	} else {
		msg := err.msg()
		assert msg.contains(path), '错误应含文件路径: ${msg}'
		assert msg.contains(':1:'), '错误应含行号 1: ${msg}'
		assert msg.contains('log.level must be one of'), '错误应说明合法取值: ${msg}'
	}
}

fn test_build_line_index() {
	content := 'listen = "0.0.0.0:5777"\nauth = { user = "alice", password = "secret" }\nlog = { level = "info" }\nmetrics_addr = "127.0.0.1:9090"\n\n[rules]\nallow = ["*.example.com"]\ndeny = ["evil.test"]\n'
	index := build_line_index(content)
	assert index['listen'] == 1
	assert index['auth'] == 2 // 内联表只注册顶层键
	assert index['log'] == 3
	assert index['metrics_addr'] == 4
	assert index['rules'] == 6
	assert index['rules.allow'] == 7
	assert index['rules.deny'] == 8
	// 点分键 auth.user 不在索引中，line_of_key 应回退到父键 auth 所在行
	assert line_of_key(index, 'auth.user') == 2
	assert line_of_key(index, 'rules.allow') == 7
	assert line_of_key(index, 'not_present') == 0
}

fn test_mask_secret() {
	assert mask_secret('') == ''
	assert mask_secret('secret') == '******'
	assert mask_secret('a') == '******'
}

fn test_load_file_layer_skip_and_missing() {
	// --help/--version 场景：skip=true 时不加载，返回空配置
	cfg, path := load_file_layer('', true)!
	assert path == ''
	assert cfg.listen_addr == ''
	assert cfg.auth_user == ''

	// 显式指定不存在的路径：fail-fast
	if _, _ := load_file_layer('/nonexistent_vpcli.toml', false) {
		assert false, '不存在的配置文件应报错'
	} else {
		assert err.msg().contains('/nonexistent_vpcli.toml')
	}
}

fn test_parse_idle_timeout_merged() {
	os.unsetenv('PROXY_IDLE_TIMEOUT')
	// 未设置：file 缺省 → default
	assert parse_idle_timeout_merged('PROXY_IDLE_TIMEOUT', none, 300) == time.Duration(300) * time.second
	// 未设置：file 提供 → file 生效
	assert parse_idle_timeout_merged('PROXY_IDLE_TIMEOUT', 60, 300) == time.Duration(60) * time.second
	// 未设置：file 为 0 → 禁用
	assert parse_idle_timeout_merged('PROXY_IDLE_TIMEOUT', 0, 300) == time.infinite
	// env 覆盖 file
	os.setenv('PROXY_IDLE_TIMEOUT', '120', true)
	assert parse_idle_timeout_merged('PROXY_IDLE_TIMEOUT', 60, 300) == time.Duration(120) * time.second
	os.unsetenv('PROXY_IDLE_TIMEOUT')
	// env 为 0 → 禁用
	os.setenv('PROXY_IDLE_TIMEOUT', '0', true)
	assert parse_idle_timeout_merged('PROXY_IDLE_TIMEOUT', 60, 300) == time.infinite
	os.unsetenv('PROXY_IDLE_TIMEOUT')
}

fn test_merge_priority_http() {
	cfg_path := write_tmp_toml('priority',
		'listen = "0.0.0.0:5777"\nauth = { user = "alice", password = "secret" }\nidle_timeout_seconds = 60\nlog = { level = "warn" }\n')
	defer {
		os.rm(cfg_path) or {}
	}
	os.unsetenv('PROXY_LISTEN_ADDR')
	os.unsetenv('PROXY_AUTH_USER')
	os.unsetenv('PROXY_AUTH_PASS')
	os.unsetenv('PROXY_IDLE_TIMEOUT')

	// file 层生效（CLI / env 都未设置）
	cfg_file := parse_http_args(['px', 'serve', '--config', cfg_path])!
	assert cfg_file.listen_addr == '0.0.0.0:5777'
	assert cfg_file.auth_user == 'alice'
	assert cfg_file.auth_pass == 'secret'
	assert cfg_file.idle_timeout == time.Duration(60) * time.second
	assert cfg_file.log_level == 'warn'
	assert cfg_file.config_file == cfg_path

	// env 覆盖 file
	os.setenv('PROXY_LISTEN_ADDR', '127.0.0.1:8888', true)
	cfg_env := parse_http_args(['px', 'serve', '--config', cfg_path])!
	assert cfg_env.listen_addr == '127.0.0.1:8888'
	// auth 未设 env，仍走 file
	assert cfg_env.auth_user == 'alice'

	// CLI 覆盖 env（也覆盖 file）
	cfg_cli := parse_http_args(['px', 'serve', '--config', cfg_path, '-l', '127.0.0.1:9999'])!
	assert cfg_cli.listen_addr == '127.0.0.1:9999'
	os.unsetenv('PROXY_LISTEN_ADDR')

	// 文件未配置字段 → 内置默认
	minimal := write_tmp_toml('minimal', 'log = { level = "debug" }\n')
	defer {
		os.rm(minimal) or {}
	}
	cfg_default := parse_http_args(['px', 'serve', '--config', minimal])!
	assert cfg_default.listen_addr == ':5777'
	assert cfg_default.log_level == 'debug'
	assert cfg_default.idle_timeout == time.Duration(300) * time.second
}
