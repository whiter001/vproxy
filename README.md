# vproxy

V 语言实现的一级代理集合，支持 HTTP（含 CONNECT 与 WebSocket）、SOCKS5、SOCKS4/SOCKS4a。

## 格式化

```bash
bash scripts/fmt.sh
```

## CI

Push 到 `main` 或创建 PR 时，GitHub Actions 会执行：

- V 代码格式检查
- 多平台编译检查（http / socks5 / socks4 × linux / darwin / windows）
- `proxy/http/1/test_full.sh` + httpbin 端到端（HTTP / SOCKS5 / SOCKS4）
- `proxy/http/1/test_websocket.sh` + `proxy/socks4/1/test_protocol.sh` + `proxy/lifecycle/test_lifecycle.sh` + `proxy/vpcli/test_cli.sh`（无外网依赖）
