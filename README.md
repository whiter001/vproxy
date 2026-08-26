# vproxy

V 语言实现的一级代理集合，支持 HTTP（含 CONNECT 与 WebSocket）、SOCKS5、SOCKS4/SOCKS4a。

## 格式化

```bash
bash scripts/fmt.sh
```

## 构建（-prod 优化）

CI 与发布均使用 `-prod`（消除 bounds check、启用优化），并叠加 `-cflags "-O3"`：

```bash
# HTTP 代理（darwin-arm64 实测约 413 KiB，示例值，随 V 版本浮动；Linux 尺寸由 CI size-check 把关 < 1 MiB）
v -prod -cflags "-O3" -o proxy.http proxy/http/1/proxy.1.v

# 交叉编译 darwin（启用仓库预置的 defines）
v -d cross_compile_macos_arm64 -prod -cflags "-O3" -o proxy.http.darwin-arm64 proxy/http/1/proxy.1.v
```

> 未启用 `-autofree`：V 0.5.2 的 V3 后端编译本项目时会被 SIGKILL（编译期内存膨胀），
> 见 CI 注释与 PR 说明。`-prod -cflags "-O3"` 已满足 < 1 MiB；
> 吞吐实测（keep-alive 长连接负载）约 +1.25%，**验收 2「较 debug +30%」未达成**——
> 瓶颈在 relay/调度与上游，不在 bounds check，未通过改业务代码硬凑，详见 PR 报告。

## Docker

多阶段静态构建，运行层为 `scratch`（产物无 glibc 依赖）：

```bash
# 本地构建（docker buildx bake，生成 vproxy:latest）
docker buildx bake

# 或直接用 docker build
docker build -t vproxy:latest .

# 开箱即用：默认 PROXY_REQUIRE_AUTH=0、监听 :5777
docker run --rm -p 5777:5777 vproxy:latest

# 使用代理
curl -x http://127.0.0.1:5777 http://example.com/
```

构建参数 `V_VERSION` 固定 V 编译器 tag（默认 `0.5.2`），可用
`docker buildx bake --set default.args.V_VERSION=<tag>` 覆盖。

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
