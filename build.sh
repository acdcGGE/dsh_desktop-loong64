#!/usr/bin/env bash
# =============================================================================
# build.sh —— dsh 桌面端 loong64 一键构建 (适配层入口)
#
# 前置要求 (需用户自备, 本脚本不下载):
#   1) 同级 dsh/            : 已 git checkout 目标 tag 的上游源码
#   2) 同级 toolchain/node  : loong64 版 Node 24 + pnpm (加入 PATH)
#   3) 同级 electron-loong64/electron-43.7.7/ : darkyzhou/electron-loong64 v43.7.7 解压目录
#   4) dsh 已应用适配补丁 (本脚本会自动调用 apply-adaption.sh, 幂等)
#
# 关键顺序: pnpm install 必须在 install-loong64-bindings.sh 之前,
#           否则 install 会把手动放入的 loong64 原生绑定剪除。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(cd "$HERE/.." && pwd)"
DSH="${DSH_SRC_TREE:-$BUILD/dsh}"
ELECTRON_DIST="${DSH_DESKTOP_ELECTRON_DIST:-$BUILD/electron-loong64/electron-43.7.7}"
REGISTRY="${DSH_DESKTOP_NPM_REGISTRY:-https://registry.loongnix.cn:5873}"

export PATH="$BUILD/toolchain/node/bin:$PATH"
export DSH_DESKTOP_NPM_REGISTRY="$REGISTRY"
export npm_config_registry="$REGISTRY"
export DSH_DESKTOP_ELECTRON_DIST="$ELECTRON_DIST"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=3072}"
export DSH_DESKTOP_UNSIGNED=1

echo "==> 构建根:        $BUILD"
echo "==> 上游源码:      $DSH"
echo "==> Electron dist: $ELECTRON_DIST"
echo "==> npm 镜像:      $REGISTRY"
[[ -d "$DSH/.git" || -e "$DSH/.git" ]] || { echo "错误: 未找到 dsh 源码工作树: $DSH" >&2; exit 1; }
[[ -x "$ELECTRON_DIST/electron" ]] || { echo "错误: 未找到 electron 二进制, 请先放置 darkyzhou/electron-loong64 v43.7.7 到 $ELECTRON_DIST" >&2; exit 1; }

# 1) loong64 适配补丁 (幂等)
"$HERE/apply-adaption.sh"

# 2) 原生系统包骨架 + 编译 (landlock-run / system.node)
"$HERE/build-node-addon.sh"

# 3) 运行时锁写入 linux-loong64 源
"$HERE/update-runtime-lock.sh"

# 4) 安装依赖
cd "$DSH"
pnpm install --no-frozen-lockfile

# 5) 补齐 loong64 原生绑定 (必须在 pnpm install 之后!)
python3 "$HERE/install-loong64-bindings.sh"

# 6) 编译
pnpm run build:lib
pnpm run build:desktop

# 7) 打包
cd "$HERE"
./package-desktop.sh
./make-deb.sh
./make-dist.sh

echo
echo "==> 构建完成. 产物位于: $HERE/dist/"
