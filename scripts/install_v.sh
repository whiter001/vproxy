#!/usr/bin/env bash
# 安装 V 预编译包（固定版本），供 CI 各 build/test job 使用。
#
# 为什么不用 vlang/setup-v：该 action 从源码 bootstrap V——
# master 源码配滚动 vc 在 windows runner 上编译崩溃（issue #12），
# stable tag 源码配滚动 vc 又在全平台触发 v1→v2 编译内存爆限（10GiB）。
# 预编译 zip 不经过任何 bootstrap，下载即用，且版本固定可复现。
#
# 例外：ci.yml 的 format job 仍用 setup-v 跟踪 master，因为 fmt 门禁需要
# 与本地开发的 V master fmt 输出对齐（两版本 fmt 换行策略有差异）。
# 因此代码必须同时满足：0.5.2 可编译 + master fmt 输出稳定——
# 不要用 0.5.2 release 之后才进 master 的语言特性。
#
# 版本通过 VPROXY_V_VERSION 覆盖；默认与本地开发推荐版本一致。

set -euo pipefail

V_VERSION="${VPROXY_V_VERSION:-0.5.2}"

case "$(uname -s)" in
	Linux)
		case "$(uname -m)" in
			x86_64) asset=v_linux.zip ;;
			aarch64 | arm64) asset=v_linux_arm64.zip ;;
			*)
				echo "install_v: unsupported linux arch: $(uname -m)" >&2
				exit 1
				;;
		esac
		;;
	Darwin)
		case "$(uname -m)" in
			x86_64) asset=v_macos_x86_64.zip ;;
			arm64) asset=v_macos_arm64.zip ;;
			*)
				echo "install_v: unsupported macos arch: $(uname -m)" >&2
				exit 1
				;;
		esac
		;;
	MINGW* | MSYS* | CYGWIN*)
		asset=v_windows.zip
		;;
	*)
		echo "install_v: unsupported os: $(uname -s)" >&2
		exit 1
		;;
esac

work="${RUNNER_TEMP:-/tmp}/vproxy-v-install"
mkdir -p "$work"
url="https://github.com/vlang/v/releases/download/${V_VERSION}/${asset}"
echo "install_v: downloading ${url}"
curl -fsSL --retry 3 --retry-all-errors -o "$work/v.zip" "$url"

if [ "$asset" = "v_windows.zip" ]; then
	# Git Bash 的 unzip 在 windows runner 上不保证存在；PowerShell 必有
	win_work=$(cygpath -w "$work")
	powershell -NoProfile -Command "Expand-Archive -LiteralPath '${win_work}\\v.zip' -DestinationPath '${win_work}' -Force"
else
	unzip -q -o "$work/v.zip" -d "$work"
fi

# zip 内为顶层 v/ 目录（v 可执行文件 + vlib + cmd + thirdparty）
vdir="$work/v"
if [ ! -f "$vdir/v" ] && [ ! -f "$vdir/v.exe" ]; then
	echo "install_v: unexpected archive layout:" >&2
	ls -la "$work" >&2
	exit 1
fi
chmod +x "$vdir/v" 2>/dev/null || true

if [ -n "${GITHUB_PATH:-}" ]; then
	echo "$vdir" >>"$GITHUB_PATH"
fi
export PATH="$vdir:$PATH"
v version
