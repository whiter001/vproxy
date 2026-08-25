# SOCKS5 Proxy

当前目录按层级组织代理实现：

- `1/`：一级 SOCKS5 代理

一级代理的入口在 `1/proxy.socks5.v`，默认监听 `:5778`。

## 协议支持

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| SOCKS5 握手（RFC 1928） | ✅ | greeting 协商 + 地址类型解析（IPv4 / Domain / IPv6） |
| 用户名/密码认证（RFC 1929） | ✅ | `SOCKS5_AUTH_USERNAME` + `SOCKS5_AUTH_PASSWORD` |
| 无认证模式 | ✅ | 客户端不提供 user/pass 时（开放代理，见下方安全提示） |
| TCP CONNECT | ✅ | 含 IPv4 / Domain / IPv6 三种 atyp |
| 协议字段校验 | ✅ | 拒绝非零 RSV（issue #3） |
| BIND | ❌ | 当前返回 `command_not_supported`，未实现 |
| UDP ASSOCIATE | ❌ | 当前返回 `command_not_supported`，未实现（参见 issue #3） |

> **注意**：早期 README 曾声称「UDP 关联（UDP ASSOCIATE）」已支持，**这是错误的**——
> 代码对非 CONNECT 命令一律返回 `rep=7 command_not_supported`（`proxy.socks5.v` 的 `handle_request`）。
> 协议矩阵以本表为准，另见 [docs/PROTOCOL.md](../../docs/PROTOCOL.md)。

## ⚠️ 安全提示

- **默认监听 `0.0.0.0:5778`**，未绑定内网地址时任何客户端都能连入。
- **未设置 `SOCKS5_AUTH_USERNAME` + `SOCKS5_AUTH_PASSWORD` 时，代理以无认证模式运行**——任何客户端
  只要声明支持 method 0x00 即可免密使用，**等于开放代理**。切勿直接暴露到公网。
- **即便配置了凭据**，若客户端只声明 no-auth（method 0x00），当前实现仍会放行（认证只是「优先选择」而非
  「强制要求」）。要真正强制认证，请在受信网络边界（防火墙 / 监听地址）上做限制。
- 建议：显式设置 `SOCKS5_AUTH_USERNAME/PASSWORD`，并把 `SOCKS5_LISTEN_ADDR` 绑定到内网或 `127.0.0.1`。

## 运行

```bash
v run proxy/socks5/1/proxy.socks5.v
```

## 环境变量

| 变量                   | 默认值  | 说明              |
| ---------------------- | ------- | ----------------- |
| `SOCKS5_LISTEN_ADDR`   | `:5778` | 监听地址          |
| `SOCKS5_AUTH_USERNAME` | 无      | 认证用户名        |
| `SOCKS5_AUTH_PASSWORD` | 无      | 认证密码          |
| `SOCKS5_NO_AUTH`       | `0`     | 设为 `1` 禁用认证 |

完整环境变量与命令行参数（issue #4）、生命周期（issue #5）见 [`1/README.md`](1/README.md)。

## 示例

```bash
# 无认证（开放代理，仅限受信网络）
curl --socks5 127.0.0.1:5778 https://httpbin.org/get

# 用户名密码认证
SOCKS5_AUTH_USERNAME=user SOCKS5_AUTH_PASSWORD=pwd \
  v run proxy/socks5/1/proxy.socks5.v
curl --socks5-user user:pwd 127.0.0.1:5778 https://httpbin.org/get
```

## 测试

```bash
bash proxy/socks5/1/test_protocol.sh   # RFC 1928/1929 协议合规（无外网依赖）
bash proxy/socks5/1/test_ipv6.sh       # IPv6 目标 + 协议字段校验（issue #3）
```
