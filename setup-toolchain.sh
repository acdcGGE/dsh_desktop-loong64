#!/usr/bin/env bash
# =============================================================================
# setup-toolchain.sh —— 组装 loong64 构建工具链 (Node 24 + pnpm 11)
#
# 适配仓库的 build.sh / sync-upstream.sh / build-node-addon.sh / package-desktop.sh
# 都假定工具链在 $BUILD/toolchain/node/bin (node 与 pnpm 同目录)。
# 本机实际布局却是:
#   Node 24.14.0 loong64 : <其它工作区>/zcode-loong64-port/opt/node-v24.14.0-linux-loong64
#   pnpm 11.28.5        : $BUILD/toolchain/pnpm
# 且系统 PATH 里只有 node v20.15.1、没有 pnpm。pnpm 11 要求 Node >= 22.13
# (内部 require("node:sqlite")), dsh 的 package.json engines 更要求 >= 24.9.0,
# 所以 build-node-addon.sh 里"沿用当前 PATH 中的 node/pnpm"这条回退必然失败。
#
# 本脚本用符号链接把两处拼成脚本期望的布局; 幂等, 不复制 128 MiB 的 node。
# 可用 DSH_NODE24_DIR / DSH_PNPM_ROOT 覆盖探测结果。
#
# 换一台机器时, 先把这两样备齐 (本脚本不联网下载):
#   1) Node 24 loong64: 解压 node-v24.x-linux-loong64.tar.xz (unofficial-builds.nodejs.org
#      或本机归档), 用 DSH_NODE24_DIR=/path/to/node-v24.x-linux-loong64 指给本脚本。
#   2) pnpm 11: 从龙芯镜像装到自定义前缀 ——
#       npm install --global pnpm@11.28.5 --prefix "$BUILD/toolchain/pnpm" \
#         --registry https://registry.loongnix.cn:5873 --no-audit --no-fund
#      注意 npm 用 --prefix 自定义前缀时 **不会**把 <prefix>/bin 加进 PATH, 这正是
#      原构建脚本报 "pnpm: 未找到命令" 的原因; 组装链接即是为消除这个路径错位。
#      (pnpm 11 还要求 Node >= 22.13: 内部 require("node:sqlite"), 系统 node 20 跑不了。)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(cd "$HERE/.." && pwd)"
DEST="$BUILD/toolchain/node"
BIN="$DEST/bin"
PNPM_ROOT="${DSH_PNPM_ROOT:-$BUILD/toolchain/pnpm}"

# ---- 1. 定位 loong64 Node 24 ----
find_node24() {
  local d
  if [[ -n "${DSH_NODE24_DIR:-}" && -x "$DSH_NODE24_DIR/bin/node" ]]; then
    printf '%s\n' "$DSH_NODE24_DIR"
    return 0
  fi
  for d in \
      "$BUILD"/toolchain/node-v24.* \
      /opt/node-v24.*-linux-loong64 \
      /usr/local/node-v24.*-linux-loong64 \
      "$HOME"/WorkBuddy/*/zcode-loong64-port/opt/node-v24.*-linux-loong64 ; do
    [[ -x "$d/bin/node" ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

NODE24="$(find_node24)" || {
  echo "错误: 未找到 Node 24 (loong64)。请设置 DSH_NODE24_DIR=/path/to/node-v24.x-linux-loong64" >&2
  exit 1
}
NODE_VER="$("$NODE24/bin/node" --version)"
NODE_MAJOR="${NODE_VER#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
if (( NODE_MAJOR < 24 )); then
  echo "错误: $NODE24/bin/node 是 $NODE_VER, dsh 要求 Node >= 24.9.0" >&2
  exit 1
fi

# ---- 2. 定位 pnpm ----
if [[ ! -e "$PNPM_ROOT/bin/pnpm" ]]; then
  echo "错误: 未找到 pnpm: $PNPM_ROOT/bin/pnpm" >&2
  exit 1
fi

# ---- 3. 组装 $BUILD/toolchain/node/bin ----
mkdir -p "$BIN"
# 链接到 node24 自带的 npm/npx (它们本身是相对符号链接, 会相对 $NODE24/bin 解析)
for name in node npm npx; do
  [[ -e "$NODE24/bin/$name" ]] && ln -sfn "$NODE24/bin/$name" "$BIN/$name"
done
for name in pnpm pnpx; do
  [[ -e "$PNPM_ROOT/bin/$name" ]] && ln -sfn "$PNPM_ROOT/bin/$name" "$BIN/$name"
done
# package-desktop.sh 会 cp -r "$NODE_BIN/../include" 填充 node-gyp 头文件缓存
if [[ ! -e "$DEST/include" && ! -L "$DEST/include" ]]; then
  ln -s "$NODE24/include" "$DEST/include"
fi

# ---- 4. 验证: 必须能在同一 PATH 下跑通 pnpm 11 ----
export PATH="$BIN:$PATH"
echo "==> Node 24 源:   $NODE24"
echo "==> pnpm 源:      $PNPM_ROOT"
echo "==> 组装目录:     $BIN"
echo "    node  $(command -v node) -> $(node --version)"
echo "    pnpm  $(command -v pnpm) -> $(pnpm --version)"
[[ "$(node --version)" == "$NODE_VER" ]] || { echo "错误: PATH 中 node 不是工具链 node" >&2; exit 1; }
node -e 'require("node:sqlite")' >/dev/null 2>&1 || {
  echo "错误: 该 node 不支持 node:sqlite, pnpm 11 无法运行" >&2
  exit 1
}
PNPM_MAJOR="$(pnpm --version)"; PNPM_MAJOR="${PNPM_MAJOR%%.*}"
(( PNPM_MAJOR >= 10 )) || { echo "错误: pnpm 版本过低: $(pnpm --version)" >&2; exit 1; }

echo
echo "==> 工具链就绪。使用前先:"
echo "    export PATH=\"$BIN:\$PATH\""
echo "    或在 sync-upstream.sh / build.sh 中自动前置该目录。"
