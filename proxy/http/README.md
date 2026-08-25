# HTTP Proxy

当前目录按层级组织代理实现：

- `1/`：一级 HTTP 代理

一级代理的入口在 `1/proxy.1.v`，默认监听 `:5777`，可通过环境变量调整。

## 鉴权（`PROXY_REQUIRE_AUTH`）

- 默认 `1`（必须鉴权）：客户端需携带 `Proxy-Authorization: Basic ...`（RFC 7617），否则返回 `407 Proxy Authentication Required`。
- 设为 `0` 关闭鉴权：启动时打印 `WARN: authentication disabled (PROXY_REQUIRE_AUTH=0)`，跳过校验。**仅限受信网络使用**。
- 关闭鉴权的同时，请把 `PROXY_LISTEN_ADDR` 绑定到内网或 `127.0.0.1`，避免成为开放代理。
- 与 SOCKS5 的 `SOCKS5_NO_AUTH` 对齐；但 HTTP 有 fail-fast：未设置凭据且未显式关闭鉴权时进程直接退出（退出码 1）。

## Keep-alive 行为

**当前实现为每 TCP 连接单请求**：`handle_client` 只读取一次请求头、处理、中继、返回并关闭连接，
**没有 keep-alive 循环**（不解析 `Connection: keep-alive`，不复用连接处理后续请求）。
错误响应（`400/405/502`）与 `407` 均带 `Connection: close`。

因此每请求一次握手 + 一次 TLS 的成本无法复用；高并发长连接场景可搭配连接池客户端。
历史 PR #16（issue #2）曾尝试支持 keep-alive，但当前 main 未包含该实现。

## 最大 Header 大小

`read_request_head` 将请求头限制在 **64KB（65536 字节）**：读取过程中累计超过该上限即返回
`400 Bad Request`（body 为 `Request too large`）。超出 64KB 的超大头、大 Cookie 场景会失败。

## 参考

- [1/README.md](1/README.md) — 一级代理完整文档（命令行 / 环境变量 / 生命周期 / 中继 teardown）
- [docs/PROTOCOL.md](../../docs/PROTOCOL.md) — HTTP 代理协议支持矩阵
