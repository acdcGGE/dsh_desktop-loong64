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

# 工具链目录缺失时自动组装 (Node 24 + pnpm 11 必须在同一 PATH 前缀)
[[ -x "$BUILD/toolchain/node/bin/node" && -x "$BUILD/toolchain/node/bin/pnpm" ]] \
  || "$HERE/setup-toolchain.sh"
export PATH="$BUILD/toolchain/node/bin:$PATH"
export DSH_DESKTOP_NPM_REGISTRY="$REGISTRY"
export npm_config_registry="$REGISTRY"
export DSH_DESKTOP_ELECTRON_DIST="$ELECTRON_DIST"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=3072}"
export DSH_DESKTOP_UNSIGNED=1
# node-gyp 编译 node-pty 等原生模块时需下载 Node 头文件; nodejs.org 在国内常不可达,
# 默认走 npmmirror 镜像 (node-gyp 原生识别 NODEJS_ORG_MIRROR)。
# 注意: prepare-dsh.ts 会把 XDG_CACHE_HOME 重定向到每次清空的构建临时目录,
#   故 ~/.cache/node-gyp 里已缓存的头文件用不上, 必须靠此镜像变量。
export NODEJS_ORG_MIRROR="${NODEJS_ORG_MIRROR:-https://npmmirror.com/mirrors/node}"

echo "==> 构建根:        $BUILD"
echo "==> 上游源码:      $DSH"
echo "==> Electron dist: $ELECTRON_DIST"
echo "==> npm 镜像:      $REGISTRY"
echo "==> Node 头文件源: $NODEJS_ORG_MIRROR"
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

# 7) 校验构建机已安装 Python 运行时所需的系统库 (原生轮子链接本机库, 不再打包进产物)
#    这些包同时会被 make-deb.sh 写进 .deb 的 Depends, 目标机 dpkg -i 时由 apt 安装。
cd "$HERE"
python3 "$HERE/check-runtime-libs.py"

# 8) 打包: 原生轮子链接 /usr/lib 下的系统库, 构建机已装好, 无需 LD_LIBRARY_PATH 注入
./package-desktop.sh

# 9) 产出分发包 (.deb / .pkg.tar.zst 均自带依赖声明, 不再注入任何系统库)
./make-deb.sh
./make-pkg.sh
./make-dist.sh

echo
echo "==> 构建完成. 产物位于: $HERE/dist/"
