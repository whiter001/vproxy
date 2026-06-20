# vpcli

命令行参数解析（issue #4）。

## API

| 函数 | 用途 |
| --- | --- |
| `parse_http_args(os.args) !HttpConfig` | 解析 HTTP 代理 CLI，返回 Config（含 CLI > env > default 三级优先级解析结果） |
| `parse_socks5_args(os.args) !Socks5Config` | 同上，SOCKS5 代理 |
| `print_http_help()` | 打印 HTTP usage |
| `print_socks5_help()` | 打印 SOCKS5 usage |
| `version` | 当前版本号常量 |

## 支持的选项

HTTP 与 SOCKS5 几乎一致（SOCKS5 没有 `--auth-basic`，因为 SOCKS5 用 RFC 1929 子协议协商）：

| 短选项 | 长选项 | 说明 |
| --- | --- | --- |
| `-l <addr>` | `--listen` | 监听地址（覆盖 `PROXY_LISTEN_ADDR` / `SOCKS5_LISTEN_ADDR`） |
| `-u <name>` | `--user` | 用户名 |
| `-p <pwd>` | `--pass` | 密码 |
| `-b <b64>` | `--auth-basic` | 预编码的 Basic 凭据（HTTP only） |
| `-n` | `--no-auth` | 关闭鉴权 |
| `-c <path>` | `--config` | 配置文件（issue #6 预留） |
| `-f <fmt>` | `--log-format` | `text\|json`（默认 `text`） |
|  | `--log-level` | `debug\|info\|warn\|error`（默认 `info`） |
| `-h` | `--help` | 打印 usage |
| `-v` | `--version` | 打印版本 |

## 优先级

```
命令行 > 环境变量 > 默认值
```

例如：
```bash
PROXY_LISTEN_ADDR=:8888 ./proxy.1 -l :9991    # -l 生效，监听 :9991
./proxy.1                                       # 默认 :5777
PROXY_LISTEN_ADDR=:8888 ./proxy.1              # env 生效，监听 :8888
```

## 子命令

显式子命令 `serve` 可写可不写：
```bash
./proxy.1 serve -l :9991   # 等价 ./proxy.1 -l :9991
./proxy.1 serve --help     # 等价 ./proxy.1 --help
```

未来 `gen-ca` / `bench` 等子命令可在 `strip_executable_and_subcommand` 的 `is_serve_or_help` 中扩展。

## 用法示例

```v
import vpcli

fn main() {
    cfg := vpcli.parse_http_args(os.args) or {
        eprintln('parse error: ${err}')
        C.exit(1)
    }
    if cfg.show_help {
        vpcli.print_http_help()
        return
    }
    if cfg.show_version {
        println('vproxy ${vpcli.version}')
        return
    }
    listen_addr := cfg.listen_addr
    // ... 启动代理 ...
}
```

## 设计要点

- **手动 strip exe + subcommand**：调用 `flag.FlagParser` 之前手动去掉 `os.args[0]`（executable）和可能的子命令。**不要**调用 `fp.skip_executable()`，否则它会把第一个 flag 当成 exe 删掉，导致 `--help` 等无法解析（panic: index out of range）。
- **`bool_opt` / `string_opt` 用 `or { default }` 模式**：每个 flag 自己决定缺省值，调用方无需关心"是否提供"。
- **未识别选项 → 非零退出**：`fp.finalize()` 返回 error 时调用 `C.exit(1)`，并打印 usage。

## 测试

```bash
bash proxy/vpcli/test_cli.sh
```

8 条断言：
1. HTTP --help
2. HTTP --version
3. HTTP -l 覆盖 PROXY_LISTEN_ADDR
4. HTTP 仅 env
5. HTTP 未识别选项退出码 1 + usage
6. HTTP 显式子命令 serve
7. HTTP 未识别子命令退出码 1
8. SOCKS5 --help / -l