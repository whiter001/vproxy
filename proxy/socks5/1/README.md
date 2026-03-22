# SOCKS5 一级代理

入口文件：`proxy.socks5.v`

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

## 测试脚本

```bash
# 无认证 TCP 测试
curl --socks5 127.0.0.1:5778 https://httpbin.org/get

# 认证 TCP 测试
curl --socks5-user user:pwd --socks5 127.0.0.1:5778 https://httpbin.org/ip

# 运行完整测试
./test_full.sh
```

## 协议支持

- SOCKS5 (RFC 1928)
- 用户名/密码认证 (RFC 1929)
- TCP CONNECT
- UDP ASSOCIATE
