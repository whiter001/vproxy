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

> 注意：当前 V 版代理的 io.cp 双向中继 teardown 存在并发缺陷（双 close 竞争导致 fd 复用被误关），
> 高并发（≥2 并发）下会出现 Connection reset / EBADF，压测会如实失败并输出代理日志；
> 修复该 teardown 后压测即可通过。详见提交报告。
