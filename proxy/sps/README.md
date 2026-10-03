# SPS — 单端口多协议代理（issue #29）

SPS（single-port multi-protocol）在**同一个监听口**上同时提供 HTTP 代理与 SOCKS5 代理：
accept 后只预读**首字节**，按其值判定协议，再把连接（连同预读字节）交给对应的处理模块。
处理逻辑完全复用 `proxy/httpsrv`（HTTP）与 `proxy/socks5srv`（SOCKS5）两个可 import 模块，
本入口只做监听、嗅探、分发与优雅退出。

## 嗅探规则

| 首字节 | 判定 | 处理 |
| --- | --- | --- |
| `0x05` | SOCKS5（RFC 1928 的 VER 字节） | `socks5srv.handle_client_ver`，预读字节作为 VER，续读 NMETHODS/METHODS |
| `A`-`Z`（大写 ASCII） | HTTP 代理（请求方法首字母：`GET`/`POST`/`CONNECT`/`HEAD`/…） | `httpsrv.handle_client_preface`，预读字节作为请求头初始缓冲 |
| 其他（含 `0x00`-`0x04`、小写字母、EOF/超时） | 未识别 | 记一行日志后**直接关闭连接**，不影响服务与其他连接 |

- 预读字节不会丢失：SOCKS5 路径经 `ver_already_read` 传入，HTTP 路径经 `preface` 传回请求头解析器。
- 首字节读取同样受 `--idle-timeout` 约束：客户端连上后不发送任何数据，idle 超时后连接被关闭。
- 恶意 / 探测连接只消耗一次「读 1 字节」的成本，进程不崩溃。

## 编译与启动

```bash
v -o proxy.sps proxy/sps/1/proxy.sps.v

# HTTP 与 SOCKS5 各自独立的凭据，同一端口：
./proxy.sps --listen :5780 \
  --http-user alice --http-pass secret \
  --socks5-user bob --socks5-pass s3cret

# 同一端口、两种协议：
curl -x http://alice:secret@127.0.0.1:5780 http://httpbin.org/get
curl -x socks5://bob:s3cret@127.0.0.1:5780 http://httpbin.org/ip
```

HTTP 侧鉴权语义与 http 代理一致（issue #1）：默认要求鉴权，未配置凭据且未显式关闭时
**fail-fast 退出**（退出码 1）；SOCKS5 侧语义与 socks5 代理一致：未配置凭据即**无认证模式**
（切勿暴露公网）。两个协议栈共用 `policy.Rules`（目标黑白名单 + 客户端 IP 黑白名单，issue #30）
与 `--parent` 上级级联（issue #27）。

## 选项与环境变量

优先级均为 CLI > 环境变量 > `proxy.toml` > 内置默认（TOML 键与 http/socks5 共用同一 schema，
见 [proxy/vpcli/README.md](../vpcli/README.md)）。

| CLI | 环境变量 | 默认 | 说明 |
| --- | --- | --- | --- |
| `-l, --listen <addr>` | `SPS_LISTEN_ADDR` | `:5780` | 监听地址 |
| `--http-user <name>` | `PROXY_AUTH_USER` | 空 | HTTP 侧用户名 |
| `--http-pass <pwd>` | `PROXY_AUTH_PASS` | 空 | HTTP 侧密码 |
| `--http-basic <b64>` | `PROXY_AUTH_BASIC` | 空 | HTTP 侧预编码 Basic 凭据（优先于 user/pass） |
| `-n, --no-http-auth` | `PROXY_REQUIRE_AUTH=0` | 关闭鉴权 | 显式关闭 HTTP 侧鉴权 |
| `--socks5-user <name>` | `SOCKS5_AUTH_USERNAME` | 空 | SOCKS5 侧用户名 |
| `--socks5-pass <pwd>` | `SOCKS5_AUTH_PASSWORD` | 空 | SOCKS5 侧密码 |
| `--no-socks5-auth` | `SOCKS5_NO_AUTH=1` | — | 显式关闭 SOCKS5 侧鉴权（覆盖已配置凭据） |
| `-c, --config <path>` | — | CWD 下 `proxy.toml` | TOML 配置文件 |
| `-f, --log-format <fmt>` | — | `text` | 日志格式：`text` / `json` |
| `--log-level <lvl>` | — | `info` | 日志级别 |
| `-i, --idle-timeout <sec>` | `SPS_IDLE_TIMEOUT` | `300` | 空闲超时秒数；`0` 禁用 |
| `--parent <url>` | `SPS_PARENT` | 空 | 上级代理 `http://` / `socks5://`（可带 user:pass@） |
| `-h, --help` / `-v, --version` | — | — | 帮助 / 版本 |

环境变量特意复用现有命名：HTTP 侧沿用 `PROXY_AUTH_*`（与 http 代理一致），SOCKS5 侧沿用
`SOCKS5_AUTH_*`（与 socks5 代理一致），通用项使用 `SPS_*` 前缀。

## 边界说明

- **不在识别范围**：SOCKS4（首字节 `0x04`）、Shadowsocks 及其他协议一律按未识别拒绝。
  需要它们请使用对应的独立入口（`proxy/socks4/1/`）。
- **首字节受 idle-timeout 约束**：静默客户端在超时后被回收，长连接探测工具请调大
  `--idle-timeout` 或置 0（禁用）。
- **HTTP 首字母必须大写**：识别依据是请求方法首字母 `A`-`Z`（RFC 7231 方法均为大写）。
  发送小写方法的非标客户端会被当作未识别协议拒绝。
- SOCKS5 的 CONNECT / UDP ASSOCIATE 在 SPS 下与独立 socks5 代理行为一致（relay 与 TCP
  监听同 host）；`--parent` 级联语义同 socks5 代理。
- `proxy.toml` 的 `[auth]` 表是单一凭据对：未通过 CLI/env 显式区分时，HTTP 侧与 SOCKS5 侧
  会回落到同一对文件凭据；需要两侧不同凭据请用 CLI flags 或环境变量。

## 本地验证

```bash
bash proxy/sps/1/test_sps.sh   # 同端口 HTTP/SOCKS5 鉴权、407、错误凭据、垃圾首字节
```
