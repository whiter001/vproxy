module lifecycle

import os
import time

const test_env_var = 'PROXY_IDLE_TIMEOUT'

// 测试辅助：临时设置环境变量，返回一个恢复函数。
// 测试完必须调用恢复，避免污染其它测试与真实环境。
fn with_env(value string) fn () {
	old := os.getenv_opt(test_env_var) or { '' }
	os.setenv(test_env_var, value, true)
	return fn [old] () {
		match old {
			'' {
				os.unsetenv(test_env_var)
			}
			else {
				os.setenv(test_env_var, old, true)
			}
		}
	}
}

// 环境变量未设置时返回默认 300s。
fn test_idle_timeout_default() {
	restore := with_env('__unset_marker_that_is_never_a_real_timeout__')
	// 先用任意值覆盖，再确保变量实际存在，避免环境恰好被外部设置。
	restore()
	os.unsetenv(test_env_var)
	dur := idle_timeout_from_env(test_env_var)
	expected := time.Duration(default_idle_timeout_seconds) * time.second
	assert dur == expected
}

// 自定义正整数秒数换算为 time.Duration。
fn test_idle_timeout_custom() {
	restore := with_env('2')
	dur := idle_timeout_from_env(test_env_var)
	assert dur == 2 * time.second
	restore()
}

// 0 与负值表示禁用（time.infinite）。
fn test_idle_timeout_zero_and_negative() {
	for raw in ['0', '-1'] {
		restore := with_env(raw)
		dur := idle_timeout_from_env(test_env_var)
		assert dur == time.infinite, 'PROXY_IDLE_TIMEOUT=${raw} 应返回 infinite'
		restore()
	}
}
