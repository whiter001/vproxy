# lifecycle

进程级生命周期管理（issue #5）。

## API

| 函数 | 用途 |
| --- | --- |
| `install_signal_handlers()` | 注册 SIGINT / SIGTERM 处理器，只做原子写 |
| `should_stop() bool` | 主循环轮询，收到信号后返回 true |
| `idle_timeout_from_env(env_var) time.Duration` | 从环境变量读取 idle 超时秒数，`0` 表示禁用 |
| `apply_idle_timeout(mut net.TcpConn, dur)` | 在已接受连接上设置 read/write timeout |

## 用法

```v
import lifecycle

lifecycle.install_signal_handlers()
idle_dur := lifecycle.idle_timeout_from_env('PROXY_IDLE_TIMEOUT')

mut server := net.listen_tcp(.ip, listen_addr) or { ... }
server.set_accept_timeout(1 * time.second)  // 让 accept 周期性返回以检查 should_stop

for {
    if lifecycle.should_stop() { break }
    mut socket := server.accept() or {
        if err.msg() == 'accept timeout' { continue }
        ...
    }
    lifecycle.apply_idle_timeout(mut socket, idle_dur)
    go handle(mut socket)
}
```

## 设计要点

- **signal context 极简**：handler 只调 `stdatomic.store_i64`，避免在中断上下文做不可重入 / 阻塞的 V 操作。
- **accept 必须带超时**：阻塞 `accept()` 不会被信号唤醒；通过 `set_accept_timeout(1s)` 让主循环周期性检查停止标志。
- **drain**：调用方在 accept 循环退出后用 `sync.WaitGroup.wait()` 等所有 in-flight goroutine 完成。

## 子项覆盖

| issue #5 子项 | 状态 | 备注 |
| --- | --- | --- |
| 1. 优雅退出（SIGINT/SIGTERM） | ✅ | 本模块 |
| 2. SO_REUSEADDR / SO_REUSEPORT | ✅ | V 标准库默认开启（`vlib/net/tcp.c.v:662`） |
| 3. TCP_NODELAY | ✅ | V 标准库默认开启（`vlib/net/tcp.c.v:673`） |
| 4. idle timeout | ✅ | 本模块 |

## 测试

```bash
bash proxy/lifecycle/test_lifecycle.sh
```

覆盖 4 条断言：
1. HTTP SIGTERM 优雅退出（退出码 0 + drain 日志）
2. SO_REUSEADDR 杀掉立即重启不冲突
3. HTTP idle timeout 静默连接关闭
4. SOCKS5 SIGTERM 优雅退出