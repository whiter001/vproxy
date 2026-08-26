# syntax=docker/dockerfile:1
# vproxy 多阶段静态构建：builder 从源码构建 V 编译器 + 代理，scratch 运行层。
#
# 为什么从源码构建 V：
# - `vlang/setup-v` 是 GitHub Action，不是 Docker 镜像；
# - 官方 `thevlang/vlang` 镜像已停更（README 停在 V 0.2.x），无法编译本项目使用的 0.5.x 语法。
#
# 为什么加 -static：
# - V 在 Linux 下默认输出动态链接 glibc 的二进制；加 `-static` 后产物无任何外部依赖，
#   可直接放进 scratch（Docker 会自动挂载 /etc/resolv.conf，域名解析可用）。

FROM ubuntu:24.04 AS builder

# 与 CI 对齐的 V 版本（V 的 git tag 形如 `0.5.2`，不带 v 前缀）
ARG V_VERSION=0.5.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 从源码构建 V 编译器
RUN git clone --depth 1 --branch "${V_VERSION}" https://github.com/vlang/v /opt/v \
    && make -C /opt/v

WORKDIR /app

# 仅复制构建代理所需的源码
COPY proxy/ ./proxy/

# 与 CI build job 相同 flag（-prod 消除 bounds check，-cflags "-O3" 对齐优化级别），
# 另加 -static 以便放进 scratch 运行层；-cc gcc 显式指定 C 编译器，
# 消除 V 默认 C 编译器选择的不确定性（本镜像内仅有 gcc）。
# 未启用 -autofree：V 0.5.2 的 V3 后端编译本项目会被 SIGKILL（编译期 OOM），见 PR 说明。
# mkdir -p /out 必须先于编译：V 的 V3 后端在输出目录不存在时报
# "failed to create C build directory ... No such file or directory"（已实测复现）。
RUN mkdir -p /out \
    && /opt/v/v -prod -cc gcc -cflags "-O3 -static" -o /out/vproxy proxy/http/1/proxy.1.v

FROM scratch

COPY --from=builder /out/vproxy /vproxy

# 开箱即用默认值：
# - require_auth 默认 true 且未设置凭据时程序会直接退出，必须显式关闭；
# - 默认监听 :5777（与 vpcli 默认一致）。
ENV PROXY_REQUIRE_AUTH=0
ENV PROXY_LISTEN_ADDR=:5777
EXPOSE 5777

ENTRYPOINT ["/vproxy"]
