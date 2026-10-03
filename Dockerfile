# syntax=docker/dockerfile:1
# vproxy 多阶段构建：debian builder 内以预编译 V 0.5.2 编译 -prod 二进制，debian slim 运行层。
#
# 构建：
#   docker build -t vproxy:latest .
# 运行（HTTP 代理，默认监听 :5777）：
#   docker run --rm -e PROXY_REQUIRE_AUTH=0 -p 5777:5777 vproxy:latest
# 切换其他代理（以 SOCKS5 为例）：
#   docker run --rm -e PROXY_REQUIRE_AUTH=0 -p 5778:5778 \
#     --entrypoint /usr/local/bin/proxy.socks5 vproxy:latest
# 鉴权经环境变量传入：
#   HTTP   PROXY_AUTH_USER / PROXY_AUTH_PASS（未配置凭据且未显式关闭时 fail-fast 退出）
#   SOCKS5 SOCKS5_AUTH_USERNAME / SOCKS5_AUTH_PASSWORD
#   SOCKS4 SOCKS4_AUTH_USER
#
# 注：曾尝试 musl 全静态 + scratch 运行层，但 V vendored libgc(boehm) 依赖 getcontext，
# musl 不提供该接口导致链接失败；故运行层用 debian:bookworm-slim（动态 glibc，镜像 ~85MB）。
# 镜像内含 proxy.http / proxy.socks5 / proxy.socks4 三个二进制。
FROM debian:bookworm-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*
# 与 CI stable 对齐的预编译 V 0.5.2（同 scripts/install_v.sh 源，不经源码 bootstrap）
RUN curl -fsSL -o /tmp/v.zip https://github.com/vlang/v/releases/download/0.5.2/v_linux.zip \
    && unzip -q /tmp/v.zip -d /opt && mv /opt/v /opt/vlang && rm /tmp/v.zip
ENV PATH=/opt/vlang:$PATH
WORKDIR /src
COPY . .
RUN v -prod -enable-globals -o /out/proxy.http proxy/http/1/proxy.1.v \
    && v -prod -enable-globals -o /out/proxy.socks5 proxy/socks5/1/proxy.socks5.v \
    && v -prod -enable-globals -o /out/proxy.socks4 proxy/socks4/1/proxy.socks4.v \
    && strip /out/proxy.http /out/proxy.socks5 /out/proxy.socks4

FROM debian:bookworm-slim
COPY --from=builder /out/proxy.http /out/proxy.socks5 /out/proxy.socks4 /usr/local/bin/
EXPOSE 5777 5778 5779
ENTRYPOINT ["/usr/local/bin/proxy.http"]
