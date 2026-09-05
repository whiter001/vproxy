# 部署指南（Deployment）

本文覆盖 vproxy 的常见部署形态：systemd（Linux）、launchd（macOS）、Windows Service，
以及 Docker 方式。以 HTTP 代理为例，SOCKS5 / SOCKS4 的部署方式相同，替换二进制与端口即可。

> 各代理默认监听地址：HTTP `:5777`、SOCKS5 `:5778`、SOCKS4 `:5779`。

## 部署前置检查清单

- [ ] **设置凭据**：HTTP 必须设置 `PROXY_AUTH_USER` + `PROXY_AUTH_PASS`（否则 fail-fast 退出）；
      SOCKS5 设置 `SOCKS5_AUTH_USERNAME` + `SOCKS5_AUTH_PASSWORD`；
      SOCKS4 设置 `SOCKS4_AUTH_USER`。
- [ ] **监听地址**：默认 `0.0.0.0`。仅本机使用时绑定 `127.0.0.1`；局域网使用绑定内网地址；
      公网部署务必配合凭据 + 防火墙。
- [ ] **防火墙**：只放行需要暴露的端口；SOCKS5/SOCKS4 无凭据时即为开放代理，严禁暴露公网。
- [ ] **mproxy**：XOR 仅翻转字节最低位，**不是真加密**，只用于过 DPI，不保护敏感流量
      （见 [`proxy/mproxy/1/README.md`](../proxy/mproxy/1/README.md)）。

## 编译产物

CI 按 `bin/proxy.<代理>.<平台>` 产出（见 `.github/workflows/ci.yml`），例如：

- Linux x86_64：`bin/proxy.http.linux-x86_64`
- macOS ARM64：`bin/proxy.http.darwin-arm64`
- Windows x86_64：`bin/proxy.http.windows-x86_64.exe`

本地编译：

```bash
v -o bin/proxy.http.linux-x86_64 proxy/http/1/proxy.1.v
v -o bin/proxy.socks5.linux-x86_64 proxy/socks5/1/proxy.socks5.v
v -o bin/proxy.socks4.linux-x86_64 proxy/socks4/1/proxy.socks4.v
```

## systemd（Linux）

`/etc/systemd/system/vproxy-http.service`：

```ini
[Unit]
Description=vproxy HTTP proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/vproxy/bin/proxy.http.linux-x86_64
Environment=PROXY_LISTEN_ADDR=0.0.0.0:5777
Environment=PROXY_AUTH_USER=foo
Environment=PROXY_AUTH_PASS=bar
Environment=PROXY_IDLE_TIMEOUT=300
Restart=on-failure
RestartSec=3
# 安全加固建议
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vproxy-http
systemctl status vproxy-http
```

> 凭据会出现在 `systemctl status` / `/proc/<pid>/environ` 中；对高安全要求环境，
> 可改用 `EnvironmentFile=` 指向 `600` 权限的文件。

## launchd（macOS）

`~/Library/LaunchAgents/com.vproxy.http.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vproxy.http</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/vproxy/bin/proxy.http.darwin-arm64</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PROXY_LISTEN_ADDR</key>
    <string>127.0.0.1:5777</string>
    <key>PROXY_AUTH_USER</key>
    <string>foo</string>
    <key>PROXY_AUTH_PASS</key>
    <string>bar</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/vproxy-http.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/vproxy-http.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.vproxy.http.plist
launchctl start com.vproxy.http
```

## Windows Service

### 方式一：`sc.exe`（内置）

```bat
sc.exe create vproxy-http binPath= "C:\vproxy\bin\proxy.http.windows-x86_64.exe" start= auto
sc.exe config vproxy-http obj= ".\yourdomain\svcuser" password= "***"
sc.exe start vproxy-http
```

环境变量在服务注册表项中设置：

```bat
reg add "HKLM\SYSTEM\CurrentControlSet\Services\vproxy-http" /v Environment /t REG_MULTI_SZ /d "PROXY_LISTEN_ADDR=0.0.0.0:5777\0PROXY_AUTH_USER=foo\0PROXY_AUTH_PASS=bar" /f
```

### 方式二：NSSM（推荐，支持自愈与环境变量）

```bat
nssm install vproxy-http "C:\vproxy\bin\proxy.http.windows-x86_64.exe"
nssm set vproxy-http AppEnvironmentExtra PROXY_LISTEN_ADDR=0.0.0.0:5777 PROXY_AUTH_USER=foo PROXY_AUTH_PASS=bar
nssm set vproxy-http AppRestartDelay 3000
nssm start vproxy-http
```

## Docker

仓库当前不含 Dockerfile，也没有容器镜像发布 job。请使用 CI 生成的对应平台二进制自行制作镜像，
并将入口设置为该二进制；不要直接依赖未由本仓库发布流程生成的 GHCR 镜像。

## 加固建议

1. 对外只暴露必要端口，并用防火墙限定来源 IP。
2. HTTP 始终开启 `PROXY_REQUIRE_AUTH=1`（默认）并设置强凭据。
3. SOCKS5/SOCKS4 部署到公网前，确认已设置凭据、绑定内网地址、并在边界限制来源。
4. 使用非特权账户运行（systemd `User=` / launchd 一般用户 / NSSM `AppDirectory` + 服务账户）。
5. 定期更新到最新 release（安全修复见 [SECURITY.md](SECURITY.md)）。
