# vpcli

命令行参数解析（issue #4）+ TOML 配置文件（issue #6）。

## API

| 函数 | 用途 |
| --- | --- |
| `parse_http_args(os.args) !HttpConfig` | 解析 HTTP 代理 CLI，返回 Config（CLI > env > file > default 四级优先级） |
| `parse_socks5_args(os.args) !Socks5Config` | 同上，SOCKS5 代理 |
| `parse_socks4_args(os.args) !Socks4Config` | 同上，SOCKS4 代理 |
| `load_toml_config(path) !TomlConfig` | 加载并校验 proxy.toml（未知键 / 类型错误 fail-fast，错误含 path:line） |
| `print_effective_config(EffectiveConfig)` | 打印生效配置（password / auth_basic 打码） |
| `mask_secret(s string) string` | 非空字符串统一打码为 `******` |
| `print_http_help()` / `print_socks5_help()` / `print_socks4_help()` | 打印各代理 usage |
| `version` | 当前版本号常量 |

## 支持的选项

HTTP、SOCKS5、SOCKS4 几乎一致（HTTP 独有 `--auth-basic`；SOCKS4 无 `--pass`，USERID 仅作标识）：

| 短选项 | 长选项 | 说明 |
| --- | --- | --- |
| `-l <addr>` | `--listen` | 监听地址（覆盖 `PROXY_LISTEN_ADDR` / `SOCKS5_LISTEN_ADDR` / `SOCKS4_LISTEN_ADDR`） |
| `-u <name>` | `--user` | 用户名 |
| `-p <pwd>` | `--pass` | 密码（SOCKS4 无此选项） |
| `-b <b64>` | `--auth-basic` | 预编码的 Basic 凭据（HTTP only） |
| `-n` | `--no-auth` | 关闭鉴权 |
| `-c <path>` | `--config` | TOML 配置文件路径；未指定时若 CWD 存在 `proxy.toml` 则自动加载 |
| `-f <fmt>` | `--log-format` | `text\|json`（默认 `text`） |
|  | `--log-level` | `debug\|info\|warn\|error`（默认 `info`） |
| `-h` | `--help` | 打印 usage（不加载配置文件） |
| `-v` | `--version` | 打印版本（不加载配置文件） |

## 优先级

```
命令行 > 环境变量 > 配置文件 > 默认值
```

例如：
```bash
PROXY_LISTEN_ADDR=:8888 ./proxy.1 -l :9991    # -l 生效，监听 :9991
./proxy.1                                       # 默认 :5777
PROXY_LISTEN_ADDR=:8888 ./proxy.1              # env 生效，监听 :8888
PROXY_LISTEN_ADDR=:8888 ./proxy.1 --config /etc/vproxy.toml   # env 覆盖文件
./proxy.1 --config /etc/vproxy.toml            # 文件值生效（listen/auth/log/...）
```

## TOML 配置文件（proxy.toml）

schema 与需求一致：

```toml
listen = "0.0.0.0:5777"
auth = { user = "alice", password = "secret" }
log = { level = "info", format = "text" }
metrics_addr = "127.0.0.1:9090"
idle_timeout_seconds = 300

[rules]
allow = ["*.example.com", "10.0.0.0/8"]
deny  = ["evil.test"]
```

行为约定：

- **加载**：`--config <path>` 显式指定优先；未指定时仅当 CWD 存在 `proxy.toml` 才加载，否则完全无文件层（等同旧版）。`--help` / `--version` 不加载。
- **fail-fast**：语法错误、未知键、类型错误、非法取值（如 `log.level = "verbose"`）一律启动失败（退出码 1），错误信息含 `文件路径:行号`。行号通过「key → 行号」索引与语法错误渐进定位得到，定位不到时至少报文件路径，不谎报行号。
- **类型校验**：V 标准库 `toml` 的 `.string()/.int()/.bool()` 在类型不匹配时会静默失真（如 int 的 `.string()` 返回 `Any(123)`），因此所有字段用 `match` 显式校验，坏配置不会「看起来成功」。
- **打码**：启动日志打印生效配置（`--- Effective config ---`），`auth.password` 与 `auth_basic` 一律显示为 `******`。
- `metrics_addr` 与 `[rules]` 当前只解析、校验并进入生效配置日志；metrics server 与域名过滤的运行时强制属于后续功能。

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
- **配置文件合并发生在 parse_*_args 内部**：`--help`/`--version` 返回的 Config 不加载文件层；四个代理共用 `load_file_layer` 与 `parse_idle_timeout_merged`。

## 测试

```bash
bash proxy/vpcli/test_cli.sh
v test proxy/vpcli
```

`test_cli.sh` 覆盖 CLI 解析 + TOML 配置：help/version、CLI > env、未识别选项、子命令、SOCKS5/SOCKS4 行为、`--config` 生效配置日志与密码打码、CLI > env > file 优先级、坏 TOML / 未知键 / 类型错误 fail-fast、SOCKS5 文件 auth 接线。