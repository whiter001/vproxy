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
- V 单元测试（`v test`，覆盖 xor / socks5_dial / lifecycle / HTTP 代理纯函数）
- `scripts/test_real.sh` 真网端到端（HTTP / SOCKS5 / SOCKS4 → httpbin.org，含鉴权拒绝用例）
- `proxy/http/1/test_websocket.sh` + `proxy/socks4/1/test_protocol.sh` + `proxy/lifecycle/test_lifecycle.sh` + `proxy/vpcli/test_cli.sh`（无外网依赖）

## 单元测试

```bash
v test proxy/http/1 proxy/mproxy/xor proxy/mproxy/socks5_dial proxy/lifecycle
```

## 真网实测

```bash
bash scripts/test_real.sh          # httpbin.org 不可达时默认跳过（exit 0）
REQUIRE_NET=1 bash scripts/test_real.sh  # 不可达时硬失败（CI 语义）
```

## 服务压测

```bash
bash scripts/stress_test.sh
# 可选参数：STRESS_REQUESTS=2000 STRESS_CONCURRENCY=100
```

> 中继 teardown：所有代理（http / mproxy / socks4 / socks5）的双向中继采用**半关闭传播**
> （half-close）——任一方向 EOF 时仅对写目标发 FIN（`net.shutdown(how: .write)`），另一方向
> 继续中继直至完成；两个 socket 由连接级 defer 在 WaitGroup 结束后各关闭恰好一次，避免并发
> 双 close 导致的 fd 复用误关（Connection reset / EBADF）。压测（`scripts/stress_test.sh`）通过。
