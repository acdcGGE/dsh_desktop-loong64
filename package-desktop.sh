#!/usr/bin/env bash
# =============================================================================
# package-desktop.sh —— 构建并打包 linux-loong64 (LoongArch64) dsh 桌面端
#
# 前置: apply-adaption.sh / build-wheels.sh / build-node-addon.sh /
#       update-runtime-lock.sh / pnpm run build:lib + build:desktop 均已执行
#
# 产出: dsh/apps/desktop/.desktop-build/targets/linux-loong64/artifacts/
#         linux-loong64-unpacked/   可直接运行的 Electron 应用目录
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 上一级目录(dsh-build), 内含 dsh 源码树与 toolchain。
# 用父目录而非按目录名裁剪, 这样工程目录改名也不会失效。
BUILD="$(cd "$HERE/.." && pwd)"
DSH="$BUILD/dsh"
# 工具链可放在旧位置 ($BUILD/toolchain/node/bin), 也可直接沿用 PATH 中的 node
# (例如本机复用其他目录下的 Node 24)。以实际能找到 node 的路径为准。
NODE_BIN="${DSH_NODE_BIN:-$BUILD/toolchain/node/bin}"
if [[ ! -x "$NODE_BIN/node" ]]; then
  NODE_BIN="$(dirname "$(command -v node)")"
fi
# 旧默认值 /usr/lib/electron44 在本机不存在; 优先用同级 electron-loong64 目录
ELECTRON_DIST="${DSH_DESKTOP_ELECTRON_DIST:-}"
if [[ ! -x "$ELECTRON_DIST/electron" ]]; then
  for d in "$BUILD/electron-loong64/electron-43.7.7" /usr/lib/electron44; do
    [[ -x "$d/electron" ]] || continue
    ELECTRON_DIST="$d"
    break
  done
fi

export PATH="$NODE_BIN:$PATH"
export DSH_DESKTOP_TARGET_PLATFORM=linux
export DSH_DESKTOP_TARGET_ARCH=loong64
export DSH_DESKTOP_ELECTRON_DIST="$ELECTRON_DIST"
export DSH_LOONG64_RIPGREP_SHIM="$HERE/shims/@vscode+ripgrep-linux-loong64"
# 本地构建没有官方签名凭据, 走 unsigned 路径
export DSH_DESKTOP_UNSIGNED=1
# 官方发布时才由 dotenv 提供; 本地构建自行指定
export DSH_DESKTOP_APP_ID="${DSH_DESKTOP_APP_ID:-com.deepseek.harness}"
# 强制更新策略服务地址: 本地构建填占位 origin (桌面端启动后可在设置中改为自建服务)
POLICY_ORIGIN="${DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN:-https://localhost}"
export DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN="$POLICY_ORIGIN"
export DSH_DESKTOP_MANDATORY_UPDATE_CONFIG="${DSH_DESKTOP_MANDATORY_UPDATE_CONFIG:-{\"allowedAuthOrigins\":[\"$POLICY_ORIGIN\"]}}"
# 龙芯 npm 镜像: runtime 依赖中的 loong64 平台包只有该源提供
export DSH_DESKTOP_NPM_REGISTRY="${DSH_DESKTOP_NPM_REGISTRY:-https://registry.loongnix.cn:5873}"
# 自动更新源: 本地构建填占位值 (桌面端不会真的从该地址拉取, 除非自行部署发布服务)
export DOWNLOAD_TEST_ORIGIN="${DOWNLOAD_TEST_ORIGIN:-https://localhost}"
export DOWNLOAD_TEST_RELEASE_ID="${DOWNLOAD_TEST_RELEASE_ID:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
export NODE_OPTIONS=--max-old-space-size=3072

# node-pty 没有 loong64 预编译包, 会回退 node-gyp 编译; 预先用本地 Node 头文件填充
# gyp 缓存, 避免它在构建时去 nodejs.org 下载 headers (该地址在龙芯网络上经常超时)
GYP_CACHE="$HOME/.cache/node-gyp/$("$NODE_BIN/node" --version | sed 's/^v//')"
if [[ ! -f "$GYP_CACHE/installVersion" ]]; then
  mkdir -p "$GYP_CACHE"
  cp -r "$NODE_BIN/../include" "$GYP_CACHE/include"
  echo 9 > "$GYP_CACHE/installVersion"
  echo "==> node-gyp 头文件缓存: $GYP_CACHE"
fi

[[ -x "$ELECTRON_DIST/electron" ]] || { echo "错误: $ELECTRON_DIST/electron 不存在或不可执行" >&2; exit 1; }
[[ -f "$DSH_LOONG64_RIPGREP_SHIM/bin/rg" ]] || { echo "错误: ripgrep shim 缺失, 先运行 apply-adaption.sh" >&2; exit 1; }

echo "==> 目标:      linux-loong64"
echo "==> Electron:  $ELECTRON_DIST ($("$ELECTRON_DIST/electron" --version))"
echo "==> Node:      $(node --version)  pnpm: $(pnpm --version)"

cd "$DSH"
# --unsigned 是 CLI 参数(不是环境变量): 跳过签名/公证凭据校验
exec pnpm --dir apps/desktop exec tsx scripts/package-target.ts --dir --unsigned
