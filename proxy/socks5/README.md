# SOCKS5 Proxy

当前目录按层级组织代理实现：

- `1/`：一级 SOCKS5 代理

一级代理的入口在 `1/proxy.socks5.v`，默认监听 `:5778`。

---

## 一级 SOCKS5 代理

这是一个基于 V 语言的 SOCKS5 代理实现，支持：

- **用户名/密码认证**（RFC 1929）
- **无认证模式**
- **TCP 连接**（BIND/RELAY）
- **UDP 关联**（UDP ASSOCIATE）

## 运行

```bash
v run proxy/socks5/1/proxy.socks5.v
```

## 环境变量

- `SOCKS5_LISTEN_ADDR`：监听地址，默认 `:5778`
- `SOCKS5_AUTH_USERNAME`：用户名（可选）
- `SOCKS5_AUTH_PASSWORD`：密码（可选）
- `SOCKS5_NO_AUTH`：设为 `1` 则禁用认证

## 示例

```bash
# 无认证
curl --socks5 127.0.0.1:5778 https://httpbin.org/get

# 用户名密码认证
curl --socks5-user user:pwd 127.0.0.1:5778 https://httpbin.org/get
```

## Curl 测试

```bash
# 无认证测试
curl --fail --silent --show-error \
  --socks5 127.0.0.1:5778 \
  https://httpbin.org/get

# 认证模式测试（需设置环境变量）
SOCKS5_AUTH_USERNAME=user SOCKS5_AUTH_PASSWORD=pwd \
curl --fail --silent --show-error \
  --socks5-user user:pwd \
  --socks5 127.0.0.1:5778 \
  https://httpbin.org/ip
```
