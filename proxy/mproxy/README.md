# proxy/mproxy/

V 语言实现的现代版 mproxy，对应原 [whiter001/mproxy](https://gitee.com/whiter001/mproxy) C 版。

三个独立二进制：

- `mproxy.serve.v` — HTTP 转发代理 + 可选 SOCKS5 upstream 链式转发
- `mproxy.client.v` — XOR 隧道 client（端到端字节级 XOR ^ 1）
- `mproxy.server.v` — XOR 隧道 server（解码 XOR + 解析 HTTP + 转发到上游）

详细文档：[`1/README.md`](1/README.md)。