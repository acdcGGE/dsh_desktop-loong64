#!/usr/bin/env bash
# =============================================================================
# build-node-addon.sh —— 为 dsh 构建 loong64 的 node-addon-system 平台包
#
# 1. 创建 native/system/packages/linux-loong64/ 平台包骨架
# 2. 重跑 workspace pnpm install 链接新包
# 3. 用官方 scripts/build.ts 编译 bin/landlock-run (静态) 与
#    bin/glibc/system.node (Node-API v8)
#
# 依赖: apply-adaption.sh 已打 P8/P9/P10 补丁; 工具链 node 在 PATH 中
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH="${1:-$(cd "$HERE/.." && pwd)/dsh}"
PKG_DIR="$DSH/native/system/packages/linux-loong64"

[[ -d "$DSH/native/system" ]] || { echo "错误: $DSH 不是 dsh 仓库" >&2; exit 1; }

echo "==> 创建平台包骨架: $PKG_DIR"
mkdir -p "$PKG_DIR"
cp "$DSH/native/system/packages/linux-x64/LICENSE" "$PKG_DIR/LICENSE"

cat > "$PKG_DIR/package.json" <<'EOF'
{
  "name": "@deepseek-ai/node-addon-system-linux-loong64",
  "version": "0.1.2",
  "description": "Linux LoongArch64 system binaries: static Landlock launcher and glibc Node-API flock addon",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/deepseek-ai/deepseek-harness.git",
    "directory": "native/system/packages/linux-loong64"
  },
  "os": [
    "linux"
  ],
  "cpu": [
    "loong64"
  ],
  "files": [
    "README.md",
    "bin/",
    "prebuilds.json"
  ],
  "scripts": {
    "prepack": "node ../../scripts/verify-launcher-binary.mjs"
  },
  "engines": {
    "node": ">=20"
  },
  "license": "BSD-3-Clause",
  "publishConfig": {
    "access": "public"
  }
}
EOF

cat > "$PKG_DIR/prebuilds.json" <<'EOF'
{
  "platform": "linux-loong64",
  "binaries": [
    {
      "tool": "landlock-run",
      "kind": "static-musl",
      "path": "bin/landlock-run"
    },
    {
      "tool": "flock",
      "kind": "node-api",
      "napi": 8,
      "libc": "glibc",
      "path": "bin/glibc/system.node"
    }
  ]
}
EOF

cat > "$PKG_DIR/README.md" <<'EOF'
---
description: "Prebuilt Landlock launcher and POSIX flock addon for Linux LoongArch64."
kind: "package-library"
---
# @deepseek-ai/node-addon-system-linux-loong64

English | [中文](README.zh.md)

This platform package contains the static executable `bin/landlock-run` and the Node-API v8 addon `bin/glibc/system.node`. The entry chooses the addon matching the running Node process's libc; the Landlock executable serves both libc systems.

This package is a LoongArch64 adaptation maintained outside the upstream release flow. See the workspace [support matrix](../../docs/support-matrix.md).
EOF

cat > "$PKG_DIR/README.zh.md" <<'EOF'
---
description: "预编译的 Landlock 启动器与 POSIX flock 插件，适用于 Linux 龙芯架构。"
kind: "package-library"
---
# @deepseek-ai/node-addon-system-linux-loong64

[English](README.md) | 中文

本平台包包含静态可执行文件 `bin/landlock-run` 与 Node-API v8 插件 `bin/glibc/system.node`。入口包会根据运行中 Node 进程的 libc 选择对应插件；Landlock 可执行文件同时服务两种 libc 系统。

本包为龙芯架构适配产物，由社区维护，不在上游发布流程内。参见工作区[支持矩阵](../../docs/support-matrix.md)。
EOF

echo "==> 重新链接 workspace (识别新平台包)"
cd "$DSH"
if [[ -d "$HERE/../toolchain/node/bin" ]]; then
  export PATH="$(cd "$HERE/../toolchain/node/bin" && pwd):$PATH"
else
  echo "    (未找到 $HERE/../toolchain/node/bin, 沿用当前 PATH 中的 node/pnpm)"
fi
pnpm install --no-frozen-lockfile 2>&1 | tail -3

echo "==> 编译原生二进制 (landlock-run + flock)"
cd "$DSH/native/system"
pnpm run build:native 2>&1 | tail -15

echo
echo "==> 构建结果:"
ls -la "$PKG_DIR/bin/" "$PKG_DIR/bin/glibc/" 2>/dev/null
# file 命令在某些最小化系统上未安装, 仅作信息展示, 缺失不应中断构建
command -v file >/dev/null 2>&1 && { file "$PKG_DIR/bin/landlock-run" 2>/dev/null | cut -c1-120; } || true

echo
echo "==> 验证 (prepack 检查):"
node "$DSH/native/system/scripts/verify-launcher-binary.mjs" "$PKG_DIR"
