# 协议说明（Protocol）

本文描述 vproxy 各代理的协议支持范围：**哪些 RFC 覆盖、哪些不覆盖**。以当前 `main` 代码为准。

## HTTP 代理（`proxy/http/1/proxy.1.v`）

### 支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| HTTP/1.1 请求转发（RFC 7230/7231） | ✅ | 请求行 + 头部透传，注入 `Via: 1.1 v-proxy` 与 `Proxy-Agent: V-Proxy/1.0` |
| 方法白名单 | ✅ | `CONNECT / POST / GET / HEAD / OPTIONS / DELETE / PATCH / PUT`，其余返回 `405` |
| CONNECT 隧道（RFC 7231 §4.3.6） | ✅ | `HTTP/1.1 200 Connection Established` 后进入双向中继 |
| WebSocket（RFC 6455） | ✅ | `Upgrade: websocket` 握手 + 101 后帧透传 |
| Proxy Basic 认证（RFC 7617） | ✅ | `Proxy-Authorization: Basic ...`，默认必填；未通过返回 `407` |
| 流式 Body | ✅ | `Content-Length` / `Chunked` 均通过 `io.cp` 双向透传，不缓冲整个 body |
| 绝对 URL 与 origin form | ✅ | `GET http://host/path` 与 `GET /path` 均支持 |

### 不支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 客户端 keep-alive 连接复用 | ❌ | **每 TCP 连接单请求**，无 keep-alive 循环；错误响应均带 `Connection: close` |
| HTTPS 中间人 / TLS 解密 | ❌ | 仅 CONNECT 隧道透传，不做 MITM |
| HTTP/2 | ❌ | 仅 HTTP/1.1 明文与隧道 |
| 缓存 / 透明代理 | ❌ | 纯转发，无缓存；不拦截 80 端口流量（需配合 iptables 等） |
| 请求头上限 | — | 64KB（超过返回 `400 Request too large`） |

## SOCKS5（`proxy/socks5/1/proxy.socks5.v`）

### 支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 握手协商（RFC 1928） | ✅ | greeting（VER/NMETHODS/METHODS）+ method 选择 |
| CONNECT（RFC 1928 §4） | ✅ | 目标地址 IPv4（atyp=1）/ 域名（atyp=3）/ IPv6（atyp=4）均支持 |
| RSV 字段校验（RFC 1928） | ✅ | 非零 RSV 拒绝（issue #3） |
| 用户名/密码认证（RFC 1929） | ✅ | 版本 1 子协议，`SOCKS5_AUTH_USERNAME/PASSWORD` |
| BND.ADDR 全零 | ✅ | reply 中 BND.ADDR 写 0，端口为 0（RFC 允许，客户端忽略） |

### 不支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| BIND（RFC 1928 §4.2） | ❌ | 返回 `rep=7 command_not_supported` |
| UDP ASSOCIATE（RFC 1928 §4.3） | ❌ | 返回 `rep=7 command_not_supported` |
| 强制认证 | ❌ | 配置凭据后仅「优先选择」RFC 1929；客户端只声明 no-auth 时仍放行 |

> BIND / UDP ASSOCIATE 的实现需要 UDP 转发或 BIND 监听状态机，相关工作讨论见 issue #3。
> 早期 README 曾声称 UDP ASSOCIATE 已支持，与实际代码不符，已修正。

## SOCKS4 / SOCKS4a（`proxy/socks4/1/proxy.socks4.v`）

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| CONNECT（CD=1） | ✅ | SOCKS4 协议仅定义 CONNECT |
| SOCKS4a 域名转发 | ✅ | DSTIP=`0.0.0.X`（X≠0）时读 trailing domain，由代理解析 |
| USERID 校验 | ✅ | 设置 `SOCKS4_AUTH_USER` 时校验；否则接受任意 USERID（即无认证开放模式） |
| IPv6 目标 | ❌ | SOCKS4/4a 协议本身只支持 IPv4（4 字节 DSTIP） |

差异要点：

- **没有 handshake / 口令字段**：客户端发完请求即收 reply；USERID 仅是标识字段。
- reply 固定 8 字节（VN + CD + DSTPORT + DSTIP），VN 为 0x00。

## 验证方式

本地脚本（无外网依赖）验证上述行为：

```bash
bash proxy/http/1/test_full.sh          # 鉴权 / 头部 / Chunked / CONNECT / HEAD
bash proxy/http/1/test_websocket.sh     # WebSocket 握手 / 帧透传 / 非 101 透传
bash proxy/http/1/test_fail_fast.sh     # 未设凭据 fail-fast
bash proxy/http/1/test_upstream_502.sh  # 上游不可达 → 502
bash proxy/http/1/test_relay_concurrent.sh  # 并发中继 teardown
bash proxy/socks5/1/test_protocol.sh    # RFC 1928/1929 协议合规（含 command_not_supported）
bash proxy/socks5/1/test_ipv6.sh        # IPv6 目标 + RSV 校验
bash proxy/socks4/1/test_protocol.sh    # SOCKS4/4a 协议合规
bash proxy/lifecycle/test_lifecycle.sh  # 优雅退出 / idle timeout
bash proxy/vpcli/test_cli.sh            # CLI 参数解析
```

真网端到端（依赖 httpbin.org，不可达时跳过）：

```bash
bash scripts/test_real.sh
REQUIRE_NET=1 bash scripts/test_real.sh   # CI 语义：不可达时硬失败
```
