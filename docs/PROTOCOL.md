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
| 客户端 keep-alive | ✅ | HTTP/1.1 默认复用；CONNECT / WebSocket / chunked 请求体为一次性连接 |

### 不支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
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
| UDP ASSOCIATE（RFC 1928 §4.3） | ✅ | IPv4 / 域名 / IPv6 目标均可转发；FRAG≠0 丢弃；详见下文「UDP ASSOCIATE 语义」 |
| RSV 字段校验（RFC 1928） | ✅ | 非零 RSV 拒绝（issue #3） |
| 用户名/密码认证（RFC 1929） | ✅ | 版本 1 子协议，`SOCKS5_AUTH_USERNAME/PASSWORD` |
| BND.ADDR 全零 | ✅ | reply 中 BND.ADDR 写 0，端口为 0（RFC 允许，客户端忽略） |

### 不支持的请求

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| BIND（RFC 1928 §4.2） | ❌ | 返回 `rep=7 command_not_supported` |

> 配置 `SOCKS5_AUTH_USERNAME/PASSWORD` 时，客户端必须支持 RFC 1929；`SOCKS5_NO_AUTH=1` 或 `--no-auth` 可显式关闭认证。
> BIND 的实现需要反向连接监听状态机，相关工作讨论见 issue #3 / #26。
> 早期 README 曾声称 UDP ASSOCIATE 已支持，与实际代码不符，已修正；自 issue #26 起真正实现。

### UDP ASSOCIATE 语义（issue #26）

- relay 绑定在与 TCP 监听同 host 的地址上（临时端口），reply 的 BND.PORT 为实际端口，BND.ADDR 按惯例回全 0。
- 客户端身份：首个源 IP 等于 TCP 控制连接对端 IP 的 UDP 数据报发送者；之后仅接受该源（防本机抢注）。
- 目标 → 客户端回传仅对「客户端先联系过」的目标生效；封装头保留客户端当初使用的 ATYP 形式（域名目标回传域名）。
- FRAG≠0 的数据报按 RFC 丢弃（不支持分片重组）；目标域名逐报文 resolve（无 DNS 缓存）；目标 family 与 relay socket 不一致时丢弃。
- 目标黑白名单（issue #30）同样约束 UDP 转发，拒绝即静默丢弃（UDP 无错误应答）。
- 生命周期：TCP 控制连接断开（含 `--idle-timeout` 无数据超时，默认 300s）即回收 relay；长会话将 `SOCKS5_IDLE_TIMEOUT` 置 0。
- 级联（`--parent`，issue #27）不穿透 UDP：配置上级时 UDP ASSOCIATE 仍走本机直连。

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

## SPS 协议嗅探（`proxy/sps/1/proxy.sps.v`，issue #29）

SPS 在**同一个监听口**上同时服务 HTTP 代理与 SOCKS5 代理：accept 后只预读**首字节**，
按其值判定协议，再把连接连同预读字节交给对应模块（`httpsrv` / `socks5srv`）：

| 首字节 | 判定 | 行为 |
| --- | --- | --- |
| `0x05` | SOCKS5（RFC 1928 的 VER 字节） | 续读 NMETHODS/METHODS 进入标准 SOCKS5 流程，预读的 VER 不要求客户端重发 |
| `A`-`Z`（大写 ASCII） | HTTP 代理（请求方法首字母） | 预读字节作为请求头初始缓冲进入 HTTP 流程（含 CONNECT / WebSocket） |
| 其他（含 `0x00`-`0x04`、小写字母、EOF / 读超时） | 未识别 | 记日志后直接关闭连接，不发送任何协议应答；服务与其他连接不受影响 |

识别规则说明：

- SOCKS4 首字节为 `0x04`、Shadowsocks 等协议不在识别范围内，一律按未识别拒绝（不做 SS/SOCKS4 分流）。
- HTTP 方法按 RFC 7231 均为大写，故大写 `A`-`Z` 首字母是安全判据；小写方法的非标客户端会被拒绝。
- 首字节读取受 `--idle-timeout` 约束：客户端连上后不发送数据，超时后连接被回收。
- 两个协议栈共用同一套 `policy.Rules`（issue #30）与 `--parent` 级联（issue #27）；
  HTTP 侧凭据（`PROXY_AUTH_*` / `--http-*`）与 SOCKS5 侧凭据（`SOCKS5_AUTH_*` / `--socks5-*`）
  相互独立，鉴权语义分别与 http / socks5 代理一致。
- 预读字节不丢失：SOCKS5 路径经 `ver_already_read` 传入，HTTP 路径经 `preface` 回灌给请求头解析器。

## 访问控制（issue #30）

三个代理共用同一套黑白名单（`proxy/policy`），经 `proxy.toml` 的 `[rules]` 配置：

| 键 | 作用 | HTTP 拒绝 | SOCKS5 拒绝 | SOCKS4 拒绝 |
| --- | --- | --- | --- | --- |
| `allow` / `deny` | 目标域名 / IP | `403 Forbidden` | `rep=2`（not allowed） | `CD=0x5B`（rejected） |
| `client_allow` / `client_deny` | 客户端 IP | 直接关闭（无响应） | 直接关闭 | 直接关闭 |

规则形式：精确域名、`*.example.com` 通配（含根域）、IPv4 CIDR、裸 IPv4。
语义：allow 非空 = 白名单（必须命中）；deny 命中即拒；两表皆空 = 全放行。

## 上级代理级联（issue #27）

HTTP 与 SOCKS5 代理支持 `--parent` / `PROXY_PARENT` / `SOCKS5_PARENT` / TOML `parent` 键把全部流量转发到上级（配置即强制走上级）：

| 上级 scheme | HTTP 代理行为 | SOCKS5 代理行为 |
| --- | --- | --- |
| `http://[user:pass@]host:port` | CONNECT 走 RFC 7231 隧道；明文 / WebSocket 改发 absolute-form 请求行 | 经上级 CONNECT 隧道转发 |
| `socks5://[user:pass@]host:port` | 经上级 RFC 1928 CONNECT 转发 | 同左（复用 `mproxy/socks5_dial`） |

- 上级认证：URL 内嵌 `user:pass@`（HTTP 上级注入 `Proxy-Authorization`，SOCKS5 上级走 RFC 1929）。
- 失败语义：上级不可达 → HTTP `502` / SOCKS5 `rep=5`；HTTP 上级对明文转发的 407 等响应按原语义透传给客户端。
- 级联 TLS（`https://` 上级）当前不支持：relay 层基于 `net.TcpConn` 具体类型与半关闭传播，接入 SSL 需要单独重构，见 issue #27 讨论。
- SOCKS4 不支持上级代理。

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
bash proxy/policy/test_policy.sh        # 黑白名单运行时强制（issue #30）
bash proxy/upstream/test_upstream.sh    # 上级代理级联（issue #27）
bash proxy/socks5/1/test_udp_associate.sh # UDP ASSOCIATE（issue #26）
bash proxy/sps/1/test_sps.sh            # SPS 单端口多协议嗅探（issue #29）
```

真网端到端（依赖 httpbin.org，不可达时跳过）：

```bash
bash scripts/test_real.sh
REQUIRE_NET=1 bash scripts/test_real.sh   # CI 语义：不可达时硬失败
```
