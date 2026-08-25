# 一级 HTTP 代理

这是一个基于 V 语言的一级 HTTP 代理实现，支持：

- `CONNECT` 隧道
- 普通 `HTTP` 请求转发
- **WebSocket 代理**（HTTP/1.1 `Upgrade: websocket` 握手 + 帧透传，RFC 6455）
- `Proxy-Authorization: Basic ...` 鉴权（默认必填，可关闭）
- 优雅退出（SIGINT/SIGTERM）+ 慢客户端 idle timeout（issue #5）
- **客户端连接 keep-alive**（同一 TCP 连接复用处理多个请求，RFC 7230 §6.3）
- `CONNECT` 200 响应携带 `Via` / `Proxy-Agent`（RFC 7230 §5.7.1 / §6.2）
- 命令行参数（issue #4）：`-l/-u/-p/-b/-n/-c/-f/--log-level/-h/-v`

## ⚠️ 安全提示

自 issue #1 起，**未配置凭据时进程会直接退出**（fail-fast），不再回落到默认的 `user:pwd`。
生产部署请：

1. 显式设置 `PROXY_AUTH_USER` 与 `PROXY_AUTH_PASS`（或 `PROXY_AUTH_BASIC`）。
2. 监听地址建议绑定到内网或 `127.0.0.1`，例如 `PROXY_LISTEN_ADDR=127.0.0.1:5777`。
3. 如需在受信网络内完全开放（如内网透明代理），显式设置 `PROXY_REQUIRE_AUTH=0`。

## 运行

```bash
v run proxy/http/1/proxy.1.v
```

## 命令行（issue #4）

```
Usage: vproxy http serve [options]

  -l, --listen addr         监听地址（覆盖 PROXY_LISTEN_ADDR）
  -u, --user name           用户名（覆盖 PROXY_AUTH_USER）
  -p, --pass pwd            密码（覆盖 PROXY_AUTH_PASS）
  -b, --auth-basic b64      预编码的 Basic 凭据（覆盖 PROXY_AUTH_BASIC）
  -n, --no-auth             关闭鉴权（等价 PROXY_REQUIRE_AUTH=0）
  -c, --config path         配置文件（issue #6 预留）
  -f, --log-format fmt      日志格式 text|json（默认 text）
      --log-level lvl       日志级别 debug|info|warn|error（默认 info）
  -h, --help                显示帮助
  -v, --version             显示版本
```

优先级：**命令行 > 环境变量 > 默认值**。

```bash
./proxy.1                          # 默认 :5777
./proxy.1 -l :8888                 # 监听 :8888
PROXY_LISTEN_ADDR=:7777 ./proxy.1  # env 生效
./proxy.1 serve --help             # 显式子命令与省略等价
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROXY_LISTEN_ADDR` | `:5777` | 监听地址 |
| `PROXY_REQUIRE_AUTH` | `1` | 设为 `0` 关闭鉴权（对齐 SOCKS5 的 `SOCKS5_NO_AUTH`） |
| `PROXY_AUTH_USER` | _无_ | 代理用户名；**未设置时进程 fail-fast** |
| `PROXY_AUTH_PASS` | _无_ | 代理密码；**未设置时进程 fail-fast** |
| `PROXY_AUTH_BASIC` | _无_ | 直接提供 Base64 编码后的 `username:password`，优先级最高 |
| `PROXY_IDLE_TIMEOUT` | `300` | 单连接最大空闲秒数（issue #5，`0` 禁用） |

## 生命周期（issue #5）

| 行为 | 实现 |
| --- | --- |
| SIGINT / SIGTERM 优雅退出 | `lifecycle.install_signal_handlers()` + `set_accept_timeout(1s)` 周期性检查停止标志；收到信号后停止 accept，等在飞连接完成 |
| 在飞连接 drain | 主循环退出后 `sync.WaitGroup.wait()` 等待所有 `handle_client` 返回 |
| 慢客户端 idle timeout | `lifecycle.apply_idle_timeout()` 设置 `set_read_timeout` / `set_write_timeout` |
| SO_REUSEADDR | V 标准库默认开启（`vlib/net/tcp.c.v:662`） |
| TCP_NODELAY | V 标准库默认开启（`vlib/net/tcp.c.v:673`） |

退出码约定：
- `0`：正常退出（SIGTERM 后 drain 完成）
- `1`：配置错误（缺凭据等，参见 issue #1）

## 连接中继（relay teardown）

双向数据通道（CONNECT 隧道、WebSocket 101 透传、chunked 请求体退化透传）由两个 `io.cp`
goroutine 中继。任一方向 EOF 时，该方向只对写目标做 TCP 半关闭（`net.shutdown(how: .write)`，
发 FIN 不释放 fd），让对端读到 EOF 后自行关闭；另一方向继续中继直至完成。两个 fd 由
`handle_client` 的 defer 在 `wg.wait()` 后各关闭恰好一次——避免旧实现「两个 goroutine 并发
close 同一 fd」导致的 fd 复用误关新连接（高并发 Connection reset / EBADF），也避免 close 与
对端 goroutine 阻塞 recv 竞争。对应测试：`test_full.sh` 测试 7（半关闭传播）。

普通 HTTP 的响应体不经过双向中继：对上游强制 `Connection: close` 后单向 `io.cp`
（上游 → 客户端）直到上游 EOF 即响应结束，且**不**对客户端发送 FIN，客户端连接可继续复用。

## keep-alive（客户端连接复用）

- 客户端侧：`handle_client` 循环调用 `process_request` 处理同一连接上的多个请求，直到
  idle timeout、客户端关闭或错误响应（`400/405/407/502`，均带 `Connection: close`）。
- HTTP/1.1 默认持久连接，`Connection: close` 显式关闭；HTTP/1.0 需显式 `keep-alive`。
- 上游侧：每个请求独立新建连接并在请求结束时关闭（转发时强制 `Connection: close`），
  响应体靠上游 EOF 定界，无需解析 Content-Length / chunked。
- 响应头会剥离上游的 `Connection: close`，按客户端连接是否复用改写为
  `Connection: keep-alive` / `close`，否则 curl 等客户端看到 `close` 后不会复用连接。
- `CONNECT` 与 WebSocket 恒为一次性，不走 keep-alive 循环。
- 客户端侧支持背靠背/流水线请求：`read_request_head` 多读的字节（下一请求、或
  Content-Length body 超出部分）会作为下一轮读取的初始缓冲，不会被丢弃；请求体读取按
  声明的 Content-Length 精确截断，不会把提前到达的下一请求误写上游。
- 已知限制：close-delimited 请求体（有 body 但既无 Content-Length 也无
  Transfer-Encoding，HTTP/1.1 下无效）不转发；上游响应体靠 EOF 定界。

## 示例

```bash
# 鉴权模式（默认）
PROXY_AUTH_USER=alice PROXY_AUTH_PASS=secret \
  v run proxy/http/1/proxy.1.v
curl -x alice:secret@127.0.0.1:5777 https://httpbin.org/get

# 关闭鉴权（仅受信网络使用）
PROXY_REQUIRE_AUTH=0 \
  PROXY_LISTEN_ADDR=127.0.0.1:5777 \
  v run proxy/http/1/proxy.1.v
curl -x http://127.0.0.1:5777 http://httpbin.org/ip

# 自定义 idle timeout = 60s
PROXY_IDLE_TIMEOUT=60 v run proxy/http/1/proxy.1.v
```

## Curl 测试

```bash
curl --fail --silent --show-error \
  -x http://alice:secret@127.0.0.1:5777 \
  https://httpbin.org/get
```

## 集成测试

```bash
bash proxy/http/1/test_full.sh         # 本地 upstreams：鉴权 / 头部 / Chunked / CONNECT
bash proxy/http/1/test_fail_fast.sh    # 未设凭据 fail-fast（issue #1）
bash proxy/http/1/test_websocket.sh    # WebSocket 握手 / 帧透传 / 非 101 透传
bash proxy/http/1/test_keepalive.sh    # keep-alive 复用 / CONNECT Via / HEAD 独立路径
bash proxy/lifecycle/test_lifecycle.sh # 优雅退出 / SO_REUSEADDR / idle timeout（issue #5）
bash proxy/vpcli/test_cli.sh           # CLI 参数解析（issue #4）
```