#!/usr/bin/env bash
# =============================================================================
# setup-toolchain.sh —— 组装 loong64 构建工具链 (Node 24 + pnpm 11)
#
# 适配仓库的 build.sh / sync-upstream.sh / build-node-addon.sh / package-desktop.sh
# 都假定工具链在 $BUILD/toolchain/node/bin (node 与 pnpm 同目录)。
#
# 组件一律**从网络拉取**, 不使用本机散落的 Node/pnpm 安装 (避免环境差异):
#   - Node 24 loong64: unofficial-builds.nodejs.org 的 linux-loong64 tar.xz
#   - Node 头文件:     npmmirror 的 headers tar.gz (node-gyp 编 node-pty 用)
#   - pnpm 11:         龙芯 npm 镜像的 pnpm tgz, 失败回退 npmjs
# 下载物按版本缓存在 $BUILD/toolchain/, 命中缓存即跳过下载; 脚本幂等。
# 要强制重新下载, 用 DSH_FORCE_DOWNLOAD=1 或删掉 toolchain 下对应缓存文件。
#
# 可用环境变量覆盖:
#   DSH_NODE_VERSION     要下载的 Node 24 版本, 默认 24.14.0
#   DSH_NODE24_URL       自定义 Node loong64 tar.xz 地址
#   DSH_NODE_HEADERS_URL 自定义 Node headers tar.gz 地址
#   DSH_PNPM_ROOT        pnpm 安装前缀, 默认 $BUILD/toolchain/pnpm
#   DSH_PNPM_VERSION     要下载的 pnpm 版本, 默认 11.28.5
#   DSH_PNPM_REGISTRY    pnpm tgz 下载镜像, 默认龙芯镜像
#   DSH_FORCE_DOWNLOAD=1 忽略已有缓存, 强制联网重新下载
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(cd "$HERE/.." && pwd)"
TOOLCHAIN="$BUILD/toolchain"
DEST="$TOOLCHAIN/node"
BIN="$DEST/bin"
PNPM_ROOT="${DSH_PNPM_ROOT:-$TOOLCHAIN/pnpm}"

NODE_VERSION="${DSH_NODE_VERSION:-24.14.0}"
PNPM_VERSION="${DSH_PNPM_VERSION:-11.28.5}"
NODE_URL="${DSH_NODE24_URL:-https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-loong64.tar.xz}"
HEADERS_URL="${DSH_NODE_HEADERS_URL:-https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-headers.tar.gz}"
PNPM_REGISTRY="${DSH_PNPM_REGISTRY:-https://registry.loongnix.cn:5873}"
FORCE_DOWNLOAD="${DSH_FORCE_DOWNLOAD:-0}"

# 日志一律写 stderr: fetch_node24 的 stdout 用来回传目录路径,
# 混进日志会让调用方拿到多行字符串当路径用
log()  { printf '%s\n' "$*" >&2; }
die()  { echo "错误: $*" >&2; exit 1; }

# 下载到 .part 再原子改名, 避免中断留下半个缓存包
download() {
  local url="$1" out="$2" tmp="$2.part.$$"
  log "==> 下载 $url"
  if ! curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$out"
}

# ---- 1. 下载 loong64 Node 24 (只认本脚本下载的缓存, 不用本机散落安装) ----
fetch_node24() {
  local archive="$TOOLCHAIN/node-v${NODE_VERSION}-linux-loong64.tar.xz"
  local dir="$TOOLCHAIN/node-v${NODE_VERSION}-linux-loong64"
  mkdir -p "$TOOLCHAIN"
  if [[ ! -x "$dir/bin/node" || "$FORCE_DOWNLOAD" == 1 ]]; then
    [[ -f "$archive" && "$FORCE_DOWNLOAD" != 1 ]] || download "$NODE_URL" "$archive" \
      || die "Node 下载失败; 可用 DSH_NODE24_URL / DSH_NODE_VERSION 指定可用归档"
    log "==> 解压 Node v$NODE_VERSION 到 $dir"
    tar -xJf "$archive" -C "$TOOLCHAIN"
    [[ -x "$dir/bin/node" ]] || die "归档中未找到 node-v${NODE_VERSION}-linux-loong64/bin/node"
  fi
  printf '%s\n' "$dir"
}

# 某些本地 Node 目录 (如应用自带 runtime) 没有 include/, node-gyp 编 node-pty 会失败
ensure_headers() {
  local dir="$1"
  [[ -f "$dir/include/node/node.h" ]] && return 0
  local archive="$TOOLCHAIN/node-v${NODE_VERSION}-headers.tar.gz"
  local hdir="$TOOLCHAIN/node-v${NODE_VERSION}-headers"
  [[ -f "$archive" ]] || download "$HEADERS_URL" "$archive" \
    || die "Node 头文件下载失败; 可用 DSH_NODE_HEADERS_URL 指定镜像"
  mkdir -p "$hdir"
  tar -xzf "$archive" -C "$hdir" --strip-components=1
  [[ -f "$hdir/include/node/node.h" ]] || die "头文件归档缺少 include/node/node.h"
  if [[ -L "$dir/include" ]]; then
    ln -sfn "$hdir/include" "$dir/include"
  elif [[ ! -e "$dir/include" ]]; then
    ln -s "$hdir/include" "$dir/include"
  else
    die "$dir/include 已存在但不是符号链接且缺少 node.h, 请手工处理"
  fi
  log "==> Node 头文件: $hdir/include"
}

NODE24="$(fetch_node24)"
NODE_VER="$("$NODE24/bin/node" --version)" || die "$NODE24/bin/node 无法执行"
NODE_MAJOR="${NODE_VER#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
(( NODE_MAJOR >= 24 )) || die "$NODE24/bin/node 是 $NODE_VER, dsh 要求 Node >= 24.9.0"
ensure_headers "$NODE24"

# ---- 2. 定位 / 下载 pnpm ----
fetch_pnpm() {
  local archive="$TOOLCHAIN/pnpm-${PNPM_VERSION}.tgz"
  mkdir -p "$PNPM_ROOT"
  if [[ ! -f "$archive" ]]; then
    if ! download "$PNPM_REGISTRY/pnpm/-/pnpm-${PNPM_VERSION}.tgz" "$archive"; then
      log "==> 龙芯镜像不可用, 回退 registry.npmjs.org"
      download "https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_VERSION}.tgz" "$archive" \
        || die "pnpm 下载失败; 可用 DSH_PNPM_REGISTRY / DSH_PNPM_VERSION 指定"
    fi
  fi
  log "==> 解压 pnpm $PNPM_VERSION 到 $PNPM_ROOT"
  tar -xzf "$archive" -C "$PNPM_ROOT" --strip-components=1
  [[ -f "$PNPM_ROOT/bin/pnpm.cjs" ]] || die "pnpm 归档缺少 bin/pnpm.cjs"

  # npm 的 pnpm 包只有 .cjs 入口, 这里补两个可执行 wrapper 供构建脚本调用
  cat > "$PNPM_ROOT/bin/pnpm" <<EOF
#!/usr/bin/env bash
exec "$NODE24/bin/node" "$PNPM_ROOT/bin/pnpm.cjs" "\$@"
EOF
  cat > "$PNPM_ROOT/bin/pnpx" <<EOF
#!/usr/bin/env bash
exec "$NODE24/bin/node" "$PNPM_ROOT/bin/pnpx.cjs" "\$@"
EOF
  chmod +x "$PNPM_ROOT/bin/pnpm" "$PNPM_ROOT/bin/pnpx"
}

if [[ ! -e "$PNPM_ROOT/bin/pnpm" || "$FORCE_DOWNLOAD" == 1 ]]; then
  fetch_pnpm
fi

# ---- 3. 组装 $BUILD/toolchain/node/bin ----
mkdir -p "$BIN"
# 链接到 node24 自带的 npm/npx (若存在; 它们本身可能是相对符号链接)
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
log "==> Node 24 源:   $NODE24"
log "==> pnpm 源:      $PNPM_ROOT"
log "==> 组装目录:     $BIN"
log "    node  $(command -v node) -> $(node --version)"
log "    pnpm  $(command -v pnpm) -> $(pnpm --version)"
[[ "$(node --version)" == "$NODE_VER" ]] || die "PATH 中 node 不是工具链 node"
[[ -f "$NODE24/include/node/node.h" ]] || die "缺少 Node 头文件: $NODE24/include/node/node.h"
node -e 'require("node:sqlite")' >/dev/null 2>&1 || die "该 node 不支持 node:sqlite, pnpm 11 无法运行"
PNPM_MAJOR="$(pnpm --version)"; PNPM_MAJOR="${PNPM_MAJOR%%.*}"
(( PNPM_MAJOR >= 10 )) || die "pnpm 版本过低: $(pnpm --version)"

log ""
log "==> 工具链就绪。使用前先:"
log "    export PATH=\"$BIN:\$PATH\""
log "    或在 sync-upstream.sh / build.sh 中自动前置该目录。"
