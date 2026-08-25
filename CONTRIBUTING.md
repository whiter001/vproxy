# 贡献指南（Contributing）

感谢你参与 vproxy 开发。vproxy 是 V 语言实现的一级代理集合（HTTP / SOCKS5 / SOCKS4a / mproxy），
本文件约定开发流程与提交规范。

## 先读这些

- [.github/agents/vlang.agent.md](.github/agents/vlang.agent.md) — **V 语言开发专家代理**（处理 `.v` 文件、V 语法、性能优化时参考）
- [copilot-instructions.md](copilot-instructions.md) — 项目通用开发指令（V 语言准则、错误处理、不可变性等）
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — 协议支持矩阵（改代码前确认是否破坏契约）
- [docs/DEPLOY.md](docs/DEPLOY.md) — 部署形态与加固建议
- [docs/SECURITY.md](docs/SECURITY.md) — 安全问题请私下报告，勿公开 0-day 细节

## 开发流程

1. **格式化**：改完 `.v` 代码后运行 `bash scripts/fmt.sh`（CI 会以 `git diff --exit-code` 检查格式）。
2. **单元测试**：

   ```bash
   v test proxy/http/1 proxy/mproxy/xor proxy/mproxy/socks5_dial proxy/lifecycle
   ```

3. **本地集成测试**（无外网依赖）：

   ```bash
   bash proxy/http/1/test_full.sh
   bash proxy/http/1/test_websocket.sh
   bash proxy/socks5/1/test_protocol.sh
   bash proxy/socks4/1/test_protocol.sh
   bash proxy/lifecycle/test_lifecycle.sh
   bash proxy/vpcli/test_cli.sh
   bash proxy/mproxy/1/test_serve.sh
   ```

4. **真网端到端**（可选，依赖 httpbin.org）：

   ```bash
   bash scripts/test_real.sh
   ```

5. **提交**：PR 请在描述中关联 issue（`fix #N` / `ref #N`）。仓库历史使用语义化提交信息，
   如 `fix(http): ...`、`docs: ...`、`test(socks5): ...`。

## 约束

- 不引入未在 CI 矩阵（linux / darwin / windows）验证的依赖。
- 改协议行为前，先更新对应 `1/README.md` 与 `docs/PROTOCOL.md` 的协议矩阵。
- mproxy 的 XOR 不是加密，文档需如实标注。
