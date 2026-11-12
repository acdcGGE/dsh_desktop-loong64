#!/usr/bin/env bash
# ============================================================
# sync-upstream.sh —— 拉取上游更新并重新构建 loong64 桌面端
# ------------------------------------------------------------
# 默认行为 (dry-run): 仅检测上游是否有新版本, 打印将执行的步骤,
#                     不修改任何文件、不重新构建。
#
# 真正执行:  ./sync-upstream.sh --apply [--tag <tag>] [--yes] [--with-tarball]
#   --tag <tag>      指定要切换到的上游 tag (默认: 按语义化版本取上游最新, 含 rc/alpha 预发布)
#   --yes            跳过"确认"交互 (用于自动化/CI)
#   --with-tarball   额外产出 tar.gz 可分发包 (默认不产, 见下方说明)
#   --formats "deb pkg"  覆盖 upstream.conf 的 PACKAGE_FORMATS
#
# 执行流程 (--apply):
#   1. git fetch --tags 上游源码工作树
#   2. 切换到目标 tag (detached); 工作树脏时先 git stash (可恢复)
#   3. 重新运行 apply-adaption.sh  (施加 loong64 适配补丁)
#   4. update-runtime-lock.sh     (锁里写入 linux-loong64 目标, 决定 TS 类型)
#   5. build-node-addon.sh        (重建 loong64 原生平台包)
#   6. pnpm install               (新 tag 的依赖可能变化)
#   6b. install-loong64-bindings.sh (补齐上游未声明的 loong64 原生绑定; 必须在 install 之后)
#   7. pnpm run build:lib
#   8. pnpm run build:desktop
#   9. 重新运行 package-desktop.sh (打包 electron 目录)
#  10. 打包: make-deb.sh / make-pkg.sh (按 PACKAGE_FORMATS)
#  11. 回写 upstream.conf 的 LOCAL_VERSION / LOCAL_COMMIT
#
# 注意: build-wheels.sh / build-node-addon.sh 耗时很长(本机编译 numpy 等),
#       仅在 primary-runtime 锁版本变化时才有必要, 故不在本流程内自动执行;
#       若新版本的 python/numpy 版本有变化, 请先手动运行这两个脚本。
#
# 说明: 默认只产 deb + pkg.tar.zst (PACKAGE_FORMATS 控制);
#       需要 tar.gz 可分发包时加 --with-tarball (会调用 make-dist.sh)。
#       所有产物都落在同一个 dist/ 下, 互不清空。
#
# 安全: 该脚本只动上游源码工作树与构建产物, 不会删除 dist 历史包;
#       切换 tag 前的本地改动存入 git stash, 不会丢失。
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/upstream.conf"
[[ -f "$CONF" ]] && source "$CONF"

REPO="${UPSTREAM_REPO:-deepseek-ai/deepseek-harness}"
LOCAL_VER="${LOCAL_VERSION:-未知}"
LOCAL_COMMIT="${LOCAL_COMMIT:-}"
LOCAL_DIR="${UPSTREAM_LOCAL_DIR:-../dsh}"
FORMATS="${PACKAGE_FORMATS:-deb pkg}"
# 解析为绝对路径: 相对路径基于脚本所在目录, 而非调用者的 CWD
if [[ "$LOCAL_DIR" != /* ]]; then
  LOCAL_DIR="$(cd "$HERE/$LOCAL_DIR" 2>/dev/null && pwd)" || LOCAL_DIR="$HERE/$LOCAL_DIR"
fi

APPLY=0
TARGET_TAG=""
YES=0
WITH_TARBALL=0
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    --apply) APPLY=1 ;;
    --yes)   YES=1 ;;
    --with-tarball) WITH_TARBALL=1 ;;
    --tag)     i=$((i+1)); TARGET_TAG="${args[i]}" ;;
    --formats) i=$((i+1)); FORMATS="${args[i]}" ;;
  esac
done

echo "=================================================="
echo " dsh_desktop-loong64 —— 上游同步"
echo "=================================================="
echo "[本地] 已构建版本: $LOCAL_VER (${LOCAL_COMMIT:0:12})"
echo "[上游] 仓库: $REPO"
echo "[本地] 源码树: $LOCAL_DIR"
echo "[产出] 包格式: ${FORMATS:-（无）}$([[ "$WITH_TARBALL" == 1 ]] && echo ' + tarball')"
echo

# ---- 确定目标 tag ----
# 上游以预发布(rc/alpha)为主, releases/latest 会返回空, 而 tags?per_page=1 按提交时间排序,
# 遇到 rc.6 / rc.10 这种会取错。故统一走 check-upstream.sh 的语义化版本排序结果。
API="https://api.github.com"
UA="dsh-desktop-loong64-updater"
if [[ -z "$TARGET_TAG" ]]; then
  if [[ -x "$HERE/check-upstream.sh" ]]; then
    echo "==> 按语义化版本查询上游最新(含预发布) ..."
    TARGET_TAG="$("$HERE/check-upstream.sh" --json 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("latest",""))' 2>/dev/null)"
    [[ -n "$TARGET_TAG" ]] && echo "    上游最新: $TARGET_TAG"
  fi
  # 兜底: check-upstream.sh 不可用时走原来的接口 (结果可能不含预发布)
  if [[ -z "$TARGET_TAG" ]]; then
    echo "==> 查询最新 Release ..."
    rel_json="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" \
      -H "User-Agent: $UA" "$API/repos/$REPO/releases/latest" 2>/dev/null)"
    TARGET_TAG="$(printf '%s' "$rel_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
    if [[ -z "$TARGET_TAG" ]]; then
      echo "    无 Latest Release（多为预发布），改用最新 tag ..."
      tags_json="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" \
        -H "User-Agent: $UA" "$API/repos/$REPO/tags?per_page=1" 2>/dev/null)"
      TARGET_TAG="$(printf '%s' "$tags_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0].get("name",""))' 2>/dev/null)"
    fi
  fi
  if [[ -z "$TARGET_TAG" ]]; then
    echo "错误: 无法获取最新 Release/Tag (GitHub API 不可达或限流)" >&2
    exit 1
  fi
fi
echo "==> 目标 tag: $TARGET_TAG"
echo

if [[ "$APPLY" == 0 ]]; then
  echo "---- DRY-RUN: 以下是将要执行的步骤 (加 --apply 才真正执行) ----"
  cat <<PLAN
  1. git -C "$LOCAL_DIR" fetch --tags origin
  2. git -C "$LOCAL_DIR" stash (若有本地适配改动) && checkout "$TARGET_TAG"  (detached HEAD)
  3. "$HERE/apply-adaption.sh" "$LOCAL_DIR"
  4. "$HERE/update-runtime-lock.sh" "$LOCAL_DIR"
  5. "$HERE/build-node-addon.sh" "$LOCAL_DIR"
  6. (cd "$LOCAL_DIR" && pnpm install)
  6b. python3 "$HERE/install-loong64-bindings.sh"
  7. (cd "$LOCAL_DIR" && pnpm run build:lib)
  8. (cd "$LOCAL_DIR" && pnpm run build:desktop)
  9. "$HERE/package-desktop.sh"
 10. 打包: $FORMATS$([[ "$WITH_TARBALL" == 1 ]] && echo ' + tarball')
 11. 更新 upstream.conf:
       LOCAL_VERSION=$TARGET_TAG (去掉 dsh-v/ 前缀)
       LOCAL_COMMIT=<切换后的 HEAD>
PLAN
  echo
  echo "确认要执行真实同步? 运行: ./sync-upstream.sh --apply --tag $TARGET_TAG"
  exit 0
fi

# =================== 真正执行 ===================
if [[ "$YES" == 0 ]]; then
  read -r -p "将对 $LOCAL_DIR 切换到 $TARGET_TAG 并重新构建, 确认? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 1 ;; esac
fi

if [[ ! -e "$LOCAL_DIR/.git" ]]; then
  echo "错误: 未找到本地上游 git 工作树: $LOCAL_DIR" >&2
  exit 1
fi

echo "==> [1/11] git fetch --tags"
git -C "$LOCAL_DIR" fetch --tags origin || { echo "fetch 失败"; exit 1; }

# 在动工作树之前做只读兼容性预检: 上游每个 rc 都可能重构代码块, 以前要等
# [3/11] apply-adaption 才报锚点失配, 那时工作树已经 checkout + stash, 处于半适配
# 状态。这里用 git archive 把目标 tag 导出到临时目录, 验证失败就直接退出,
# 工作树和 stash 保持原样。
echo "    补丁兼容性预检 ($TARGET_TAG, 只读, 不改工作树)"
PRECHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$PRECHECK_DIR"' EXIT
git -C "$LOCAL_DIR" archive "$TARGET_TAG" | tar -x -C "$PRECHECK_DIR" \
  || { echo "错误: 无法导出 $TARGET_TAG 源码用于预检" >&2; exit 1; }
if ! "$HERE/apply-adaption.sh" --check "$PRECHECK_DIR" > /tmp/dsh-adaption-check.log 2>&1; then
  cat /tmp/dsh-adaption-check.log >&2
  echo "错误: 适配补丁与 $TARGET_TAG 不兼容, 已中止; 工作树未做任何改动。" >&2
  echo "      按上面的清单更新 apply-adaption.sh 的锚点后重试。" >&2
  exit 1
fi
tail -1 /tmp/dsh-adaption-check.log
if [[ "${DSH_SYNC_PRECHECK_ONLY:-0}" == 1 ]]; then
  echo "==> 仅预检模式: 工作树/stash 均未改动, 退出"
  exit 0
fi
rm -rf "$PRECHECK_DIR"

echo "==> [2/11] checkout $TARGET_TAG"
# 工作树上有 loong64 适配补丁造成的本地修改, 直接 checkout 会被 git 拒绝。
# 适配补丁在 [3/6] 会重新施加, 因此这里先把改动存进 stash (可恢复, 非破坏性)。
STASH_MSG="dsh-loong64-adaption-$(date +%Y%m%d-%H%M%S)"
STASHED=0
DIRTY=0
if ! git -C "$LOCAL_DIR" diff --quiet || ! git -C "$LOCAL_DIR" diff --cached --quiet; then
  DIRTY=1
fi
if [[ "$DIRTY" == 1 ]]; then
  echo "    检测到本地修改(loong64 适配), 先存入 stash: $STASH_MSG"
  # 只 stash 已跟踪文件的改动, 不带 -u:
  # 未跟踪的正是我们的适配产物(patches/*.patch、native/system/packages/linux-loong64),
  # 一并卷走会让后续 pnpm install 报 "stale workspace patch decision"。
  if git -C "$LOCAL_DIR" stash push -m "$STASH_MSG"; then
    STASHED=1
    echo "    已暂存, 可恢复: git -C \"$LOCAL_DIR\" stash pop"
  else
    echo "    错误: stash 失败, 请手动处理工作树后重试 (git -C \"$LOCAL_DIR\" status)" >&2
    exit 1
  fi
fi
git -C "$LOCAL_DIR" checkout -q "$TARGET_TAG" 2>&1 || { echo "checkout 失败"; exit 1; }
NEW_COMMIT="$(git -C "$LOCAL_DIR" rev-parse HEAD)"
NEW_VER="$TARGET_TAG"
# 归一化版本号 (去掉 dsh-v / v 前缀)
NEW_VER="$(printf '%s' "$NEW_VER" | sed -E 's/^dsh-v//; s/^v//')"
echo "    新 commit: ${NEW_COMMIT:0:12}  新版本: $NEW_VER"

echo "==> [3/11] apply-adaption.sh"
"$HERE/apply-adaption.sh" "$LOCAL_DIR" || { echo "apply-adaption 失败"; exit 1; }

# 换 tag 后依赖与构建产物都会变, 必须重装并重新编译, 否则会打包到旧产物
# loong64 工具链 node 需在 PATH 中
NODE_BIN="$HERE/../toolchain/node/bin"
[[ -d "$NODE_BIN" ]] && export PATH="$NODE_BIN:$PATH"

# 必做: primary-runtime 锁的 targets 决定 PrimaryRuntimeTarget 类型
# (prepare.ts: `export type PrimaryRuntimeTarget = keyof typeof lock.targets`),
# 缺 linux-loong64 会让 build:lib 的 tsc 直接报类型不匹配。
echo "==> [4/11] update-runtime-lock.sh"
"$HERE/update-runtime-lock.sh" "$LOCAL_DIR" || { echo "update-runtime-lock 失败"; exit 1; }

# 必做: native/system/packages/linux-loong64 是未跟踪目录, checkout 前的 stash
# 可能带走其中的 package.json/LICENSE, 这里重建平台包与原生二进制。
echo "==> [5/11] build-node-addon.sh"
"$HERE/build-node-addon.sh" "$LOCAL_DIR" || { echo "build-node-addon 失败"; exit 1; }

echo "==> [6/11] pnpm install"
( cd "$LOCAL_DIR" && pnpm install ) || { echo "pnpm install 失败"; exit 1; }

# 上游 optionalDependencies 从不声明 loong64; 不补绑定会在 build:lib 报
# "Cannot find native binding" (rc.1 构建时的实际故障)。必须与 build.sh 同序。
echo "==> [6b/11] install-loong64-bindings.sh"
python3 "$HERE/install-loong64-bindings.sh" || { echo "install-loong64-bindings 失败"; exit 1; }

echo "==> [7/11] pnpm run build:lib"
( cd "$LOCAL_DIR" && pnpm run build:lib ) || { echo "build:lib 失败"; exit 1; }

echo "==> [8/11] pnpm run build:desktop"
( cd "$LOCAL_DIR" && pnpm run build:desktop ) || { echo "build:desktop 失败"; exit 1; }

echo "==> [9/11] package-desktop.sh"
"$HERE/package-desktop.sh" || { echo "package-desktop 失败"; exit 1; }

# 自动定位新构建的 unpacked 目录
UNPACKED="$LOCAL_DIR/apps/desktop/.desktop-build/targets/linux-loong64/unsigned-artifacts/linux-loong64-unpacked"
if [[ ! -x "$UNPACKED/deepseek-harness" ]]; then
  echo "错误: 未找到新构建产物: $UNPACKED" >&2
  exit 1
fi

echo "==> [10/11] 打包 ($FORMATS$([[ "$WITH_TARBALL" == 1 ]] && echo ' + tarball'))"
for f in $FORMATS; do
  case "$f" in
    deb) "$HERE/make-deb.sh" "$UNPACKED" || { echo "make-deb 失败"; exit 1; } ;;
    pkg) "$HERE/make-pkg.sh" "$UNPACKED" || { echo "make-pkg 失败"; exit 1; } ;;
    tarball|tar|dist) "$HERE/make-dist.sh" "$UNPACKED" || { echo "make-dist 失败"; exit 1; } ;;
    *) echo "    忽略未知包格式: $f" ;;
  esac
done
if [[ "$WITH_TARBALL" == 1 ]]; then
  "$HERE/make-dist.sh" "$UNPACKED" || { echo "make-dist 失败"; exit 1; }
fi
# 汇总校验值 (覆盖 dist 下所有大件)
# deb 文件名以下划线开头 (deepseek-harness_0.2.2~rc.2-1_loong64.deb), 不能用连字符 glob,
# 否则 SHA256SUMS 只列 pkg, 发布后用户无法校验 deb。
( cd "$HERE/dist" && sha256sum deepseek-harness_*.deb deepseek-harness-*.pkg.tar.zst \
    deepseek-harness-*-linux-loong64.tar.gz 2>/dev/null > SHA256SUMS ) || true

echo "==> [11/11] 回写 upstream.conf"
sed -i "s|^LOCAL_VERSION=.*|LOCAL_VERSION=\"$NEW_VER\"|" "$CONF"
sed -i "s|^LOCAL_COMMIT=.*|LOCAL_COMMIT=\"$NEW_COMMIT\"|" "$CONF"
sed -i "s|^LOCAL_COMMIT_DATE=.*|LOCAL_COMMIT_DATE=\"$(date '+%Y-%m-%d')\"|" "$CONF"
grep -q '^LAST_UPSTREAM_VERSION=' "$CONF" && \
  sed -i "s|^LAST_UPSTREAM_VERSION=.*|LAST_UPSTREAM_VERSION=\"$TARGET_TAG\"|" "$CONF" || \
  printf 'LAST_UPSTREAM_VERSION="%s"\n' "$TARGET_TAG" >> "$CONF"

echo
echo "=================================================="
echo " 同步完成!"
echo " 新版本: $NEW_VER (${NEW_COMMIT:0:12})"
echo " 可分发包: $HERE/dist/"
echo "=================================================="
if [[ "$STASHED" == 1 ]]; then
  echo
  echo "提示: 切换前的 loong64 适配改动已保存在 git stash: $STASH_MSG"
  echo "      本次已基于新 tag 重新施加适配, 通常无需还原。如需清理:"
  echo "        git -C \"$LOCAL_DIR\" stash drop      # 丢弃"
  echo "        git -C \"$LOCAL_DIR\" stash pop       # 还原(会与新 tag 冲突, 慎用)"
fi
exit 0
