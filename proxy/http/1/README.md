# 一级 HTTP 代理

这是一个基于 V 语言的一级 HTTP 代理实现，支持：

- `CONNECT` 隧道
- 普通 `HTTP` 请求转发
- `Proxy-Authorization: Basic ...` 鉴权（默认必填，可关闭）

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

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROXY_LISTEN_ADDR` | `:5777` | 监听地址 |
| `PROXY_REQUIRE_AUTH` | `1` | 设为 `0` 关闭鉴权（对齐 SOCKS5 的 `SOCKS5_NO_AUTH`） |
| `PROXY_AUTH_USER` | _无_ | 代理用户名；**未设置时进程 fail-fast** |
| `PROXY_AUTH_PASS` | _无_ | 代理密码；**未设置时进程 fail-fast** |
| `PROXY_AUTH_BASIC` | _无_ | 直接提供 Base64 编码后的 `username:password`，优先级最高 |

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
```

## Curl 测试

可以用下面的命令验证代理是否能正常访问 `httpbin.org/get`，并分别覆盖 `HTTPS CONNECT` 和普通 `HTTP` 转发：

```bash
curl --fail --silent --show-error \
  -x http://user:pwd@127.0.0.1:5777 \
  https://httpbin.org/get

curl --fail --silent --show-error \
  -x http://user:pwd@127.0.0.1:5777 \
  http://httpbin.org/get
```

本地完整集成测试：

```bash
bash proxy/http/1/test_full.sh    # 启动本地 upstream，覆盖鉴权 / 头部 / Chunked / CONNECT
bash proxy/http/1/test_fail_fast.sh  # 验证未设凭据时 fail-fast
```
