# mproxy — 现代版 HTTP / XOR 代理

> ⚠️ **安全警告**：mproxy 的 XOR "加密"仅翻转字节最低位，**不是真正的加密**，
> 任何攻击者看一字节即可还原。本工具仅用于过 DPI / GFW，**不保护敏感流量**。

V 语言重新实现的 [whiter001/mproxy](https://gitee.com/whiter001/mproxy)，
配合 vproxy 的 `lifecycle` + `vpcli` 风格：SIGINT/SIGTERM 优雅退出、idle timeout、
结构化日志、集成测试。

## 三个模式

| 模式 | 文件 | 默认端口 | 用途 |
| --- | --- | --- | --- |
| `serve` | `mproxy.serve.v` | `:8080` | HTTP 转发代理 + HTTPS CONNECT，可选 `-u` SOCKS5 upstream 链式转发 |
| `client` | `mproxy.client.v` | `:8080` | XOR 隧道 client：listen → XOR 编码 → 远端 `server` |
| `server` | `mproxy.server.v` | `:8081` | XOR 隧道 server：解码 XOR → 解析 HTTP → 上游（直连或 SOCKS5） |

## 与原 C 版 mproxy 的差异

| 维度 | C 版 mproxy | 本仓库 V 版 |
| --- | --- | --- |
| 语言 | C | V |
| 双向中继 | `fork()` + 双进程 | `io.cp` 两 goroutine |
| "加密" | `buffer[i] ^= 1` | 同左（**不是真加密**） |
| 鉴权 | 无 | 可选 `MPROXY_REQUIRE_AUTH` |
| 上游 | 直接 dial | 直接 dial 或 `-u` SOCKS5 链式转发 |
| 生命周期 | 无 | SIGINT/SIGTERM drain + idle timeout（复用 `proxy/lifecycle/`） |
| 测试 | 无 | bash + Python ThreadedTCPServer，10+ 测试场景 |

## 运行

```bash
# serve 模式
v run proxy/mproxy/1/mproxy.serve.v

# client 模式（连接到远端 mproxy server）
v run proxy/mproxy/1/mproxy.client.v -r vps.example.com:8081

# server 模式（接受 mproxy client 连入）
v run proxy/mproxy/1/mproxy.server.v

# SOCKS5 upstream 链式（所有模式支持）
v run proxy/mproxy/1/mproxy.serve.v -u socks5://user:pass@upstream:1080
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MPROXY_LISTEN_ADDR` | 模式相关 | 监听地址 |
| `MPROXY_UPSTREAM` | _空_ | SOCKS5 upstream URL（`-u` 选项覆盖） |
| `MPROXY_REMOTE` | _空_ | 远端 mproxy server 地址（client 模式必填） |
| `MPROXY_IDLE_TIMEOUT` | `300` | 单连接最大空闲秒数（`0` 禁用） |

## 测试

```bash
bash proxy/mproxy/1/test_serve.sh             # HTTP / CONNECT / 502 / SOCKS5
bash proxy/mproxy/1/test_tunnel.sh            # XOR 隧道端到端 + CONNECT over XOR
bash proxy/mproxy/1/test_socks5_upstream.sh   # SOCKS5 upstream 链式 + auth 失败
```

全本地运行，无外网依赖。

## 复用模块

| 模块 | 路径 | 用途 |
| --- | --- | --- |
| `lifecycle` | `proxy/lifecycle/lifecycle.v` | 信号处理 / idle timeout / graceful drain |
| `xor` | `proxy/mproxy/xor/xor.v` | XOR ^ 1 编解码（10 行） |
| `socks5_dial` | `proxy/mproxy/socks5_dial/socks5_dial.v` | SOCKS5 客户端拨号（RFC 1928 + 1929） |

## CI

`.github/workflows/ci.yml` build 矩阵包含 `mproxy.serve / mproxy.client / mproxy.server` 三个 src × 4 targets。
test-websocket job 运行 mproxy 三个本地测试套件。