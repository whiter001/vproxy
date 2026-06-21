# SOCKS4 / SOCKS4a 一级代理

入口文件：`proxy.socks4.v`

## 协议支持

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| SOCKS4 CONNECT (CD=1) | ✅ | 仅 CONNECT；BIND/UDP_ASSOC 不在 SOCKS4 协议范围内 |
| SOCKS4a 域名转发 | ✅ | DSTIP=`0.0.0.X`（X≠0）时识别 trailing domain，proxy 解析域名 |
| USERID 校验 | ✅ | `SOCKS4_AUTH_USER` 设置时校验，否则接受任意 USERID |
| `--no-auth` / `SOCKS4_NO_AUTH=1` | ✅ | 完全跳过 USERID 校验 |
| IPv6 目标 | ❌ | SOCKS4 协议本身只支持 IPv4（4 字节 DSTIP），SOCKS4a 仅在此之上扩展出域名 |

## 与 SOCKS5 的差异

- **没有 handshake**：SOCKS4 客户端发完请求即收 reply，没有 greeting/auth 协商阶段。
- **没有 password 字段**：USERID 仅作标识，不是凭据；proxy 校验逻辑是"必须匹配 `SOCKS4_AUTH_USER`"。
- **reply VN=0**：原始 spec 要求 reply VN 为 NULL（0x00），与 request VN=4 区分。
- **BND.ADDR/PORT 字段**：SOCKS4 reply 固定 8 字节（VN + CD + DSTPORT + DSTIP），其中 DSTPORT/DSTIP 回显请求里的值即可。

## 运行

```bash
v run proxy/socks4/1/proxy.socks4.v
```

## 命令行（issue #4）

```
Usage: vproxy socks4 serve [options]

  -l, --listen addr         监听地址（覆盖 SOCKS4_LISTEN_ADDR）
  -u, --user name           期望 USERID（覆盖 SOCKS4_AUTH_USER；空 = 接受任意）
  -n, --no-auth             完全跳过 USERID 校验（等价 SOCKS4_NO_AUTH=1）
  -c, --config path         配置文件（issue #6 预留）
  -f, --log-format fmt      日志格式 text|json
      --log-level lvl       日志级别 debug|info|warn|error
  -h, --help                显示帮助
  -v, --version             显示版本
```

优先级：**命令行 > 环境变量 > 默认值**。

```bash
./proxy.socks4                          # 默认 :5779
./proxy.socks4 -l :8888                 # 监听 :8888
SOCKS4_LISTEN_ADDR=:7777 ./proxy.socks4 # env 生效
./proxy.socks4 serve --version          # 显式子命令与省略等价
```

## 环境变量

| 变量                  | 默认值  | 说明                                            |
| --------------------- | ------- | ----------------------------------------------- |
| `SOCKS4_LISTEN_ADDR`  | `:5779` | 监听地址                                        |
| `SOCKS4_AUTH_USER`    | _空_    | 期望 USERID；未设置时接受任意 USERID             |
| `SOCKS4_NO_AUTH`      | `0`     | 设为 `1` 完全跳过 USERID 校验                   |
| `SOCKS4_IDLE_TIMEOUT` | `300`   | 单连接最大空闲秒数（issue #5，`0` 禁用）        |

## 测试脚本

```bash
# 无网络依赖的协议合规测试
./test_protocol.sh
```

## 生命周期（issue #5）

| 行为 | 实现 |
| --- | --- |
| SIGINT / SIGTERM 优雅退出 | accept 1s 超时轮询 `lifecycle.should_stop()`；drain in-flight 连接后退出码 0 |
| 慢客户端 idle timeout | `SOCKS4_IDLE_TIMEOUT` 环境变量（默认 300s），客户端 + upstream 都生效 |
| SO_REUSEADDR / TCP_NODELAY | V 标准库默认开启 |