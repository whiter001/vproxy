# SOCKS5 一级代理

入口文件：`proxy.socks5.v`

## 协议支持

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| SOCKS5 (RFC 1928) | ✅ | 完整握手 |
| 用户名/密码认证 (RFC 1929) | ✅ | `SOCKS5_AUTH_USERNAME/PASSWORD` |
| 无认证模式 | ✅ | 客户端不提供 user/pass 时 |
| TCP CONNECT | ✅ | 含 IPv4 / Domain / IPv6 三种 atyp |
| IPv6 目标 (atyp=4) | ✅ | 修复了 `hex()` 去前导 0 导致 `dial_tcp` 失败的 bug |
| 协议字段校验 | ✅ | 拒绝非零 RSV（issue #3） |
| BIND | ❌ | 当前返回 `command_not_supported`，未实现 |
| UDP ASSOCIATE | ❌ | 当前返回 `command_not_supported`，未实现 |

## 已知限制

- **BIND / UDP ASSOCIATE 未实现**：早期 README 声称支持，实际代码仅返回 `command_not_supported`。实现这两个命令需要 UDP 套接字转发或 BIND 监听状态机，工作量较大；当前 vproxy 只覆盖 CONNECT 用例。如有需求请开 issue。
- **BND.ADDR 始终为 0**：reply 包里绑地址统一写 `0.0.0.0` / `::` / 空域，端口为 0。RFC 1928 允许这种做法，绝大多数 SOCKS5 客户端忽略 BND.ADDR。

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
| `SOCKS5_IDLE_TIMEOUT`  | `300`   | 单连接最大空闲秒数（issue #5，`0` 禁用） |

## 测试脚本

```bash
# 无认证 TCP 测试
curl --socks5 127.0.0.1:5778 https://httpbin.org/get

# 认证 TCP 测试
curl --socks5-user user:pwd --socks5 127.0.0.1:5778 https://httpbin.org/ip

# 运行完整测试
./test_full.sh

# IPv6 + 协议字段校验（issue #3）
./test_ipv6.sh
```

## 生命周期（issue #5）

| 行为 | 实现 |
| --- | --- |
| SIGINT / SIGTERM 优雅退出 | accept 1s 超时轮询 `lifecycle.should_stop()`；drain in-flight 连接后退出码 0 |
| 慢客户端 idle timeout | `SOCKS5_IDLE_TIMEOUT` 环境变量（默认 300s），客户端 + upstream 都生效 |
| SO_REUSEADDR / TCP_NODELAY | V 标准库默认开启 |
