// proxy/lifecycle/lifecycle.v
//
// 进程级生命周期管理：信号处理、停止标志、连接 idle timeout。
// 解决 issue #5 的两个子项（SO_REUSEADDR / TCP_NODELAY 已由 V 标准库默认开启，
// 见 vlib/net/tcp.c.v:661-674 set_default_options）：
//
//   1. 优雅退出（SIGINT / SIGTERM）
//   2. 慢客户端 idle timeout
//
// 用法：
//   import lifecycle
//   lifecycle.install_signal_handlers()
//   idle_dur := lifecycle.idle_timeout_from_env('PROXY_IDLE_TIMEOUT')
//   // accept loop:
//   for {
//       if lifecycle.should_stop() { break }
//       socket := server.accept() or { continue }
//       lifecycle.apply_idle_timeout(mut socket, idle_dur)
//       go handle(...)
//   }
module lifecycle

import net
import os
import sync.stdatomic
import time

// 默认 idle timeout 秒数。300s = 5 分钟，对慢客户端与挂死连接足够宽松。
pub const default_idle_timeout_seconds = 300

// 模块级 atomic stop flag。signal handler 仅写入；主循环用 should_stop() 轮询。
// 注意：仅在 main 线程上轮询才能及时响应信号；goroutine 里读也能用，但响应延迟。
const stop_flag = i64(0)

fn signal_handler(_sig os.Signal) {
	// signal context 里只做原子写；不做 V 高级操作（不可重入 / 不可阻塞）。
	stdatomic.store_i64(&stop_flag, 1)
}

// 块作用：注册 SIGINT / SIGTERM 信号处理器
// 处理问题（issue #5）：Ctrl-C / kill -TERM 后能优雅退出，而不是卡在 wg.wait()
pub fn install_signal_handlers() {
	os.signal_opt(.int, signal_handler) or {
		eprintln('lifecycle: failed to install SIGINT handler: ${err}')
	}
	os.signal_opt(.term, signal_handler) or {
		eprintln('lifecycle: failed to install SIGTERM handler: ${err}')
	}
}

// 块作用：查询是否收到停止信号
pub fn should_stop() bool {
	return stdatomic.load_i64(&stop_flag) == 1
}

// 块作用：从环境变量读取 idle timeout（秒）。0 或负值表示禁用。
// 处理问题：默认 300s 防止慢客户端长期占 fd；运维可通过 PROXY_IDLE_TIMEOUT=0 关掉。
pub fn idle_timeout_from_env(env_var string) time.Duration {
	raw := os.getenv_opt(env_var) or {
		return time.Duration(default_idle_timeout_seconds) * time.second
	}
	secs := raw.int()
	if secs <= 0 {
		return time.infinite
	}
	return time.Duration(secs) * time.second
}

// 块作用：在已接受连接上设置 read/write timeout
// 处理问题：io.cp 会按 read_timeout 触发超时错误，defer 关闭 socket 释放 fd。
pub fn apply_idle_timeout(mut conn net.TcpConn, dur time.Duration) {
	if dur == time.infinite {
		return
	}
	conn.set_read_timeout(dur)
	conn.set_write_timeout(dur)
}
