// proxy/vpcli/toml_config.v
//
// TOML 配置文件加载（issue #6）。
//
// 配置优先级：命令行 > 环境变量 > 配置文件 > 内置默认。
//
// 注意：
// - V 标准库 toml 模块的语法错误不带文件路径和行号，必须用原文做行号定位
//   （best-effort，定位不到时至少报文件路径与错误原文，绝不谎报行号）。
// - toml.Any 的 `.string()/.int()/.bool()` 在类型不匹配时静默失真
//   （如 int 的 .string() 返回 "Any(300)"），因此所有字段必须用 match
//   做显式类型校验，不能直接转换。
// - 未知键 / 非法取值一律 fail-fast，不 warn 后忽略。
module vpcli

import os
import time
import toml

// TomlConfig 是 proxy.toml 的解析结果（与需求 schema 一一对应）。
// 只承载「配置文件层」的值；CLI / env 的合并由 parse_*_args 完成。
pub struct TomlConfig {
pub mut:
	listen_addr          string
	auth_user            string
	auth_pass            string
	log_level            string
	log_format           string
	metrics_addr         string
	idle_timeout_seconds ?int // none 表示文件里没有显式设置该键
	allow_rules          []string
	deny_rules           []string
}

// 顶层允许的键；之外的键一律 fail-fast。
const top_level_keys = ['listen', 'auth', 'log', 'metrics_addr', 'idle_timeout_seconds', 'rules']

const auth_keys = ['user', 'password']
const log_keys = ['level', 'format']
const rules_keys = ['allow', 'deny']
const valid_log_levels = ['debug', 'info', 'warn', 'error']
const valid_log_formats = ['text', 'json']

// 块作用：加载并校验 proxy.toml
// 处理问题：
// 1. 语法错误定位行号（toml 模块不提供，自己兜底）
// 2. 每个字段做显式类型校验，避免 toml.Any 静默失真
// 3. 未知键 / 非法取值 fail-fast，错误信息含 path:line
pub fn load_toml_config(path string) !TomlConfig {
	content := os.read_file(path) or { return error('config file ${path}: ${err}') }
	index := build_line_index(content)
	doc := toml.parse_text(content) or {
		line := syntax_err_line(content, err.msg())
		msg := 'invalid TOML syntax: ${err.msg()}'
		if line > 0 {
			return error('config file ${path}:${line}: ${msg}')
		}
		return error('config file ${path}: ${msg}')
	}

	// 顶层未知键检查
	top := doc.to_any()
	if top is map[string]toml.Any {
		for k, _ in top {
			if k !in top_level_keys {
				return cfg_error(path, index, k, 'unknown key "${k}"')
			}
		}
	}

	mut cfg := TomlConfig{}
	cfg.listen_addr = get_string_field(doc, 'listen', path, index)!
	cfg.metrics_addr = get_string_field(doc, 'metrics_addr', path, index)!

	// auth 表（table_value 对「键存在但类型不是表」返回 error，用 or 传播保证 fail-fast）
	auth_tbl := table_value(doc, 'auth', path, index) or { return err }
	for k, _ in auth_tbl {
		if k !in auth_keys {
			return cfg_error(path, index, 'auth.${k}', 'unknown key "auth.${k}"')
		}
	}
	cfg.auth_user = get_string_field(doc, 'auth.user', path, index)!
	cfg.auth_pass = get_string_field(doc, 'auth.password', path, index)!

	// log 表
	log_tbl := table_value(doc, 'log', path, index) or { return err }
	for k, _ in log_tbl {
		if k !in log_keys {
			return cfg_error(path, index, 'log.${k}', 'unknown key "log.${k}"')
		}
	}
	cfg.log_level = get_string_field(doc, 'log.level', path, index)!
	cfg.log_format = get_string_field(doc, 'log.format', path, index)!
	if cfg.log_level != '' && cfg.log_level !in valid_log_levels {
		return cfg_error(path, index, 'log.level',
			'log.level must be one of debug|info|warn|error, got "${cfg.log_level}"')
	}
	if cfg.log_format != '' && cfg.log_format !in valid_log_formats {
		return cfg_error(path, index, 'log.format',
			'log.format must be text|json, got "${cfg.log_format}"')
	}

	// rules 表
	rules_tbl := table_value(doc, 'rules', path, index) or { return err }
	for k, _ in rules_tbl {
		if k !in rules_keys {
			return cfg_error(path, index, 'rules.${k}', 'unknown key "rules.${k}"')
		}
	}
	cfg.allow_rules = get_string_array_field(doc, 'rules.allow', path, index)!
	cfg.deny_rules = get_string_array_field(doc, 'rules.deny', path, index)!

	// idle_timeout_seconds：整数；缺省保持 none
	if iv := doc.value_opt('idle_timeout_seconds') {
		match iv {
			i64 {
				cfg.idle_timeout_seconds = int(iv)
			}
			int {
				cfg.idle_timeout_seconds = int(iv)
			}
			else {
				return cfg_error(path, index, 'idle_timeout_seconds',
					'key "idle_timeout_seconds" must be an integer, got ${any_type_name(iv)}')
			}
		}
	}

	return cfg
}

// 块作用：读取字符串字段
// 处理问题：缺省返回 ''（表示未在文件里配置）；类型不对则 fail-fast。
fn get_string_field(doc toml.Doc, key string, path string, index map[string]int) !string {
	val := doc.value_opt(key) or { return '' }
	match val {
		string {
			return val
		}
		else {
			return cfg_error(path, index, key,
				'key "${key}" must be a string, got ${any_type_name(val)}')
		}
	}
}

// 块作用：读取字符串数组字段
// 处理问题：元素逐个校验为 string；缺省返回空数组。
fn get_string_array_field(doc toml.Doc, key string, path string, index map[string]int) ![]string {
	val := doc.value_opt(key) or { return []string{} }
	match val {
		[]toml.Any {
			mut arr := []string{}
			for it in val {
				match it {
					string {
						arr << it
					}
					else {
						return cfg_error(path, index, key,
							'key "${key}" must be an array of strings, element is ${any_type_name(it)}')
					}
				}
			}
			return arr
		}
		else {
			return cfg_error(path, index, key,
				'key "${key}" must be an array of strings, got ${any_type_name(val)}')
		}
	}
}

// 块作用：读取 TOML 表（auth / log / rules）
// 处理问题：缺省返回空表；键存在但类型不是表时 fail-fast。
fn table_value(doc toml.Doc, key string, path string, index map[string]int) !map[string]toml.Any {
	val := doc.value_opt(key) or { return map[string]toml.Any{} }
	match val {
		map[string]toml.Any {
			return val
		}
		else {
			return cfg_error(path, index, key,
				'key "${key}" must be a table, got ${any_type_name(val)}')
		}
	}
}

// 构造带 path:line 前缀的错误信息；行号定位不到时退化为 path。
fn cfg_error(path string, index map[string]int, key string, msg string) IError {
	line := line_of_key(index, key)
	if line > 0 {
		return error('config file ${path}:${line}: ${msg}')
	}
	return error('config file ${path}: ${msg}')
}

// toml.Any 的可读类型名（match 的 else 分支里 typeof 拿不到具体变体名）。
fn any_type_name(a toml.Any) string {
	match a {
		string {
			return 'string'
		}
		bool {
			return 'boolean'
		}
		i64, int {
			return 'integer'
		}
		f32, f64 {
			return 'float'
		}
		map[string]toml.Any {
			return 'table'
		}
		[]toml.Any {
			return 'array'
		}
		else {
			return 'unknown'
		}
	}
}

// 块作用：为每个配置键建立「key → 行号」索引（best-effort）
// 处理问题：
// 1. 支持 `[table]` 头（含 `[[array-of-table]]`）
// 2. 支持内联表 / 数组跨行：用花括号/方括号深度跳过值内部的行
// 3. 注释（#）与字符串内容不参与解析
// 4. 点分键（`auth.user = ...`）直接注册完整键
fn build_line_index(content string) map[string]int {
	mut index := map[string]int{}
	mut current_table := ''
	mut depth := 0
	lines := content.split_into_lines()
	for i, raw in lines {
		line_no := i + 1
		line := raw.trim_space()
		if line == '' {
			continue
		}
		// 表头 [name] / [[name]]
		if line.starts_with('[') {
			close_idx := line.index(']') or { continue }
			mut name := line[1..close_idx].trim_space()
			if name.starts_with('[') {
				name = name[1..].trim_space()
			}
			current_table = name
			index[current_table] = line_no
			continue
		}
		depth_at_start := depth
		mut in_string := false
		mut str_char := u8(0)
		mut key := ''
		mut after_eq := false
		mut j := 0
		for j < line.len {
			c := line[j]
			if in_string {
				if c == `\\` {
					j += 2
					continue
				}
				if c == str_char {
					in_string = false
				}
				j++
				continue
			}
			if c == `"` || c == `'` {
				in_string = true
				str_char = c
				j++
				continue
			}
			if c == `#` {
				break // 注释到行尾
			}
			if !after_eq {
				if c == `=` {
					key = line[..j].trim_space()
					after_eq = true
				}
				j++
				continue
			}
			if c == `{` || c == `[` {
				depth++
			} else if c == `}` || c == `]` {
				depth--
			}
			j++
		}
		if key != '' && depth_at_start == 0 {
			key = key.trim('"').trim("'")
			full_key := if current_table != '' { '${current_table}.${key}' } else { key }
			index[full_key] = line_no
		}
	}
	return index
}

// 查 key 所在行；找不到时逐级回退到父键（如 auth.user → auth）。
fn line_of_key(index map[string]int, key string) int {
	if key in index {
		return index[key]
	}
	mut parts := key.split('.')
	for parts.len > 1 {
		parts = parts[..parts.len - 1].clone()
		parent := parts.join('.')
		if parent in index {
			return index[parent]
		}
	}
	return 0
}

// 块作用：尽力定位语法错误所在行
// 处理问题（toml 解析器错误不带行号）：
// 1. 优先从错误消息的 excerpt（`in this (excerpt): "..."` / `in this text "..."`）
//    里提取片段，在原文按行匹配；
// 2. 提取不到（如 "bare key expected" 这类无 excerpt 错误）时，
//    用渐进前缀解析：从第 1 行开始逐行拼接重新 parse，第一个失败的
//    前缀所在行即错误行（配置文件通常很小，O(n²) 可接受）；
// 3. 都定位不到返回 0，调用方只报文件路径，不谎报行号。
fn syntax_err_line(content string, err_msg string) int {
	lines := content.split_into_lines()
	for frag in error_excerpt_fragments(err_msg) {
		for i, raw in lines {
			if raw.contains(frag) {
				return i + 1
			}
		}
	}
	mut buf := ''
	for i, raw in lines {
		if i > 0 {
			buf += '\n'
		}
		buf += raw
		_ := toml.parse_text(buf) or { return i + 1 }
	}
	return 0
}

// 从解析器错误消息里提取 excerpt 片段。
// 形如 `in this (excerpt): "...erminated\n..."` 或 `in this text "... "a", "b"\n..."`。
// 只取 excerpt（含首尾省略号的那个大引号段），不做普通 token 猜测，避免误导性行号。
fn error_excerpt_fragments(err_msg string) []string {
	mut fragments := []string{}
	mut marker_end := -1
	for marker in ['in this (excerpt): ', 'in this text '] {
		idx := err_msg.index(marker) or { -1 }
		if idx >= 0 {
			marker_end = idx + marker.len
			break
		}
	}
	if marker_end < 0 {
		return fragments
	}
	open := err_msg.index_after('"', marker_end) or { -1 }
	close := err_msg.last_index('"') or { -1 }
	if open < 0 || close <= open {
		return fragments
	}
	frag := err_msg[open + 1..close].trim('.').trim(' ').trim('"')
	if frag != '' {
		fragments << unescape_toml_err(frag)
	}
	return fragments
}

// 把 toml 解析器 excerpt 里的转义还原成真实字符，便于在原文按行匹配。
fn unescape_toml_err(s string) string {
	return s.replace('\\n', '\n').replace('\\r', '\r').replace('\\t', '\t').replace('\\"', '"').replace('\\\\',
		'\\')
}

// 打码：非空字符串统一显示为 ******。
pub fn mask_secret(s string) string {
	if s == '' {
		return ''
	}
	return '******'
}

// 生效配置的展示载体，供三个代理 main 打印统一格式的启动日志。
pub struct EffectiveConfig {
pub:
	label        string
	listen_addr  string
	auth_user    string
	auth_pass    string
	auth_basic   string
	log_level    string
	log_format   string
	metrics_addr string
	idle_timeout time.Duration
	allow_rules  []string
	deny_rules   []string
}

// 打印生效配置（密码类字段一律打码）。
pub fn print_effective_config(cfg EffectiveConfig) {
	eprintln('--- Effective config (${cfg.label}) ---')
	eprintln('listen = ${cfg.listen_addr}')
	if cfg.auth_user != '' {
		eprintln('auth.user = ${cfg.auth_user}')
	}
	if cfg.auth_pass != '' {
		eprintln('auth.password = ${mask_secret(cfg.auth_pass)}')
	}
	if cfg.auth_basic != '' {
		eprintln('auth.basic = ${mask_secret(cfg.auth_basic)}')
	}
	eprintln('log.level = ${cfg.log_level}')
	eprintln('log.format = ${cfg.log_format}')
	if cfg.metrics_addr != '' {
		eprintln('metrics_addr = ${cfg.metrics_addr}')
	}
	if cfg.idle_timeout == time.infinite {
		eprintln('idle_timeout_seconds = disabled')
	} else {
		// Duration 别名 i64，直接插值会走 Duration.str()（60 纳秒显示为 "60ns"），
		// 先转成整数再打印秒数。
		secs := i64(cfg.idle_timeout / time.second)
		eprintln('idle_timeout_seconds = ${secs}')
	}
	if cfg.allow_rules.len > 0 {
		eprintln('rules.allow = ${cfg.allow_rules}')
	}
	if cfg.deny_rules.len > 0 {
		eprintln('rules.deny = ${cfg.deny_rules}')
	}
}
