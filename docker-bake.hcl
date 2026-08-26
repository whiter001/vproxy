# 本地构建入口：docker buildx bake
# 用法：docker buildx bake          # 构建 vproxy:latest（native 平台）
#       docker buildx bake --push  # 构建并推送（需要配置 registry）
# 多架构构建（需 buildx + binfmt 模拟）：
#       docker buildx bake --set default.platforms=linux/amd64,linux/arm64
#
# 可覆盖 V 版本：docker buildx bake --set default.args.V_VERSION=0.5.2

variable "V_VERSION" {
  default = "0.5.2"
}

target "default" {
  dockerfile = "Dockerfile"
  context    = "."
  tags       = ["vproxy:latest"]
  args = {
    V_VERSION = V_VERSION
  }
}
