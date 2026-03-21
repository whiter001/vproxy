---
name: vproxy-instructions
description: "vproxy 项目通用指令及 V 语言开发规范 (https://vlang.io/)"
---

# vproxy 项目开发指令

本指令集旨在指导 GitHub Copilot 在 vproxy 仓库中生成和改进高质量的 V 语言（Vlang）代码。

## V 语言开发准则 (Vlang Guidelines)

V 是一种简洁、快速且安全的编译型语言。在处理本项目的 `.v` 文件时，请遵循以下原则：

1. **查阅文档**: 始终以 [Vlang 官方文档 (https://vlang.io/)](https://vlang.io/) 为准，确保使用的是最新的语法和特性。
2. **零值安全**: V 语言要求变量必须在声明时初始化。禁止从未初始化的变量中读取。
3. **不可变性**: 变量默认是不可变的（immutable）。仅在必要时使用 `mut` 关键字标记可变变量。
4. **错误处理**: V 强制要求显式处理 Result/Option 类型。
   - 使用 `or { ... }` 块处理错误或默认值。
   - 使用 `?` 向上抛出错误。
5. **内存管理**: 了解 V 的 GC 及实验性的 Autofree 模式。编写代码时，尽量避免循环引用。
6. **代码风格准则 (`v fmt`)**: V 代码应保持极致简洁。避免冗余的括号、分号等。
7. **并发模型**: 使用 `go` 关键字开启轻量级线程，并结合 `chan` 进行通信。

## 项目结构惯约

- [proxy/http/](proxy/http/): 核心 HTTP 代理实现
- [.github/agents/vlang.agent.md](.github/agents/vlang.agent.md): V 语言开发专家代理定义

当用户询问有关 V 语言语法、标准库或最佳实践的问题时，请主动引导用户查阅 [vlang.io](https://vlang.io/) 以获取权威答案。
