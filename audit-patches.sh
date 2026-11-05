#!/usr/bin/env bash
# ============================================================
# audit-patches.sh —— 切换上游 tag 前的补丁适配性预检
# ------------------------------------------------------------
# 用途:
#   apply-adaption.sh 的补丁靠"锚点文本精确匹配"施加, 上游一旦重构相关代码,
#   锚点就会失配, 而这类失败要到跑到 apply-adaption 那一步才暴露 —— 那时已经
#   切了 tag、装了依赖, 白跑十几分钟。本脚本在切换之前用目标 tag 的**原始文件**
#   做一次全量模拟, 提前列出会失配的补丁。
#
# 用法:
#   ./audit-patches.sh <tag> [源码树]
#     例: ./audit-patches.sh dsh-v0.2.2-rc.1 ../dsh
#
# 退出码:
#   0  全部补丁可施加 (含"已适配/幂等跳过")
#   1  存在失配 (清单打到 stdout)
#   2  参数或环境问题
#
# 实现:
#   薄封装 —— 把目标 tag 用 git archive 导出到临时目录, 再调用
#   `apply-adaption.sh --check <dir>` 做只读模拟。检查逻辑与真实打补丁共用
#   同一份代码, 因此天然支持多候选锚点 [(old,new), ...]、动态拼接的锚点,
#   以及"前序补丁生成后序锚点"的链式依赖, 不会与 apply-adaption.sh 漂移。
#   (旧版本用 ast 静态抽取 patch() 参数, 遇到列表/表达式参数会静默漏检。)
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-}"
LOCAL_DIR="${2:-${UPSTREAM_LOCAL_DIR:-$HERE/../dsh}}"

if [[ -z "$TAG" ]]; then
  echo "用法: ./audit-patches.sh <tag> [源码树]" >&2
  exit 2
fi
if [[ "$LOCAL_DIR" != /* ]]; then
  LOCAL_DIR="$(cd "$HERE/$LOCAL_DIR" 2>/dev/null && pwd)" || LOCAL_DIR="$HERE/$LOCAL_DIR"
fi
[[ -e "$LOCAL_DIR/.git" ]] || { echo "错误: 未找到 git 工作树: $LOCAL_DIR" >&2; exit 2; }

# tag 可能还没 fetch 到本地, 先尝试一次
git -C "$LOCAL_DIR" rev-parse -q --verify "$TAG^{commit}" >/dev/null 2>&1 || \
  git -C "$LOCAL_DIR" fetch --tags --quiet origin 2>/dev/null || true

if ! git -C "$LOCAL_DIR" rev-parse -q --verify "$TAG^{commit}" >/dev/null 2>&1; then
  echo "错误: tag 不存在或无法解析: $TAG" >&2
  exit 2
fi

echo "=== 补丁适配性预检 ==="
echo "  目标 tag : $TAG"
echo "  源码树   : $LOCAL_DIR"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! git -C "$LOCAL_DIR" archive "$TAG" | tar -x -C "$TMP"; then
  echo "错误: 无法导出 $TAG 源码" >&2
  exit 2
fi

LOG="$(mktemp)"
trap 'rm -rf "$TMP" "$LOG"' EXIT
"$HERE/apply-adaption.sh" --check "$TMP" >"$LOG" 2>&1
rc=$?
case "$rc" in
  0)
    grep -E "^==> 预检通过" "$LOG"
    exit 0
    ;;
  10)
    cat "$LOG"
    exit 1
    ;;
  *)
    cat "$LOG" >&2
    exit 2
    ;;
esac
