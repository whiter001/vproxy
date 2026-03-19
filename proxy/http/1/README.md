# 一级 HTTP 代理

这是一个基于 V 语言的一级 HTTP 代理实现，支持：

- `CONNECT` 隧道
- 普通 `HTTP` 请求转发
- `Proxy-Authorization: Basic ...` 鉴权

## 运行

```bash
v run proxy/http/1/proxy.1.v
```

## 环境变量

- `PROXY_LISTEN_ADDR`：监听地址，默认 `:5777`
- `PROXY_AUTH_USER`：代理用户名，默认 `user`
- `PROXY_AUTH_PASS`：代理密码，默认 `pwd`
- `PROXY_AUTH_BASIC`：直接提供 Base64 编码后的 `username:password`

## 示例

```bash
curl -x user:pwd@127.0.0.1:5777 https://httpbin.org/get
curl -x http://user:pwd@127.0.0.1:5777 http://httpbin.org/ip
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
