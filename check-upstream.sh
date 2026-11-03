#!/usr/bin/env bash
# ============================================================
# check-upstream.sh —— 检查 deepseek-harness 上游是否有更新
# ------------------------------------------------------------
# 功能:
#   1. 通过 GitHub API 查询官方仓库最新 Release / Tag / commit
#   2. 与本地已构建版本 (upstream.conf 的 LOCAL_VERSION) 做语义化版本比较
#   3. 若本地存在 dsh 源码工作树, 额外做 git commit 级精确比对
#   4. 顺带报告第三方龙芯移植参考仓库的最近更新
#
# 用法:
#   ./check-upstream.sh           正常检查 (会写回 LAST_CHECKED)
#   ./check-upstream.sh --quiet   仅在有更新时输出结论
#   ./check-upstream.sh --no-git  跳过本地 git 工作树比对
#
# 注意: GitHub API 未认证限速 60 次/小时, 偶发失败会自动跳过该项。
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/upstream.conf"
[[ -f "$CONF" ]] && source "$CONF"

REPO="${UPSTREAM_REPO:-deepseek-ai/deepseek-harness}"
REF_REPO="${REFERENCE_REPO:-Chen-Yuanmeng/dsh-loongarch-adaption}"
LOCAL_VER="${LOCAL_VERSION:-未知}"
LOCAL_COMMIT="${LOCAL_COMMIT:-}"
LOCAL_DIR="${UPSTREAM_LOCAL_DIR:-../dsh}"

API="https://api.github.com"
UA="dsh-desktop-loong64-updater"

QUIET=0
NO_GIT=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --no-git) NO_GIT=1 ;;
  esac
done

# ---- GitHub API 封装 (带超时与缺失容忍) ----
gh_get() {
  curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" \
    -H "User-Agent: $UA" "$API/$1" 2>/dev/null
}

# ---- 语义化版本比较 ----
# 返回 0 表示上游比本地新, 1 表示一致或更旧, 2 表示无法比较
version_compare() {
  # $1=上游版本字符串  $2=本地版本字符串
  python3 - "$1" "$2" <<'PY'
import sys, re
def norm(v):
    v=(v or "").strip()
    for p in ("dsh-v","dsh-","v"):
        if v.startswith(p): v=v[len(p):]
    return v
def parse(v):
    v=norm(v)
    m=re.match(r'^(\d+)\.(\d+)\.(\d+)(?:[-.](rc|beta|alpha|pre)\.?(\d+))?$', v)
    if not m: return None
    maj,minr,pat,pre,pren=m.groups()
    # 发布版(pre 为空)最"新"于同号预发布
    rank={"":2,"rc":1,"pre":0,"beta":-1,"alpha":-2}.get(pre or "",2)
    return (int(maj),int(minr),int(pat),rank,int(pren or 0))
u,l=parse(sys.argv[1]),parse(sys.argv[2])
if u is None or l is None:
    print(2); sys.exit(0)
if u>l: print(0)
else:   print(1)
PY
}

NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

[[ "$QUIET" == 0 ]] && {
echo "=================================================="
echo " dsh_desktop-loong64 —— 上游更新检查"
echo " 时间: $NOW"
echo "=================================================="
echo
echo "[本地] 已构建版本 : $LOCAL_VER"
[[ -n "$LOCAL_COMMIT" ]] && echo "[本地] 构建 commit : ${LOCAL_COMMIT:0:12} (${LOCAL_COMMIT_DATE:-})"
echo
}

# ---- 1. 官方上游: 最新 release ----
[[ "$QUIET" == 0 ]] && echo "--- 官方上游 $REPO ---"
rel_json="$(gh_get "repos/$REPO/releases/latest")"
rel_tag=""; rel_pub=""
if [[ -n "$rel_json" ]]; then
  rel_tag="$(printf '%s' "$rel_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
  rel_pub="$(printf '%s' "$rel_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("published_at",""))' 2>/dev/null)"
  [[ "$QUIET" == 0 ]] && echo "  最新 Release: ${rel_tag:-（无）}  发布于 ${rel_pub:-未知}"
else
  [[ "$QUIET" == 0 ]] && echo "  (无 Latest Release（多为预发布），改用 tag 列表比较)"
fi

# ---- 2. tag 列表 ----
tags_json="$(gh_get "repos/$REPO/tags?per_page=10")"
latest_tag="${rel_tag:-}"
[[ "$QUIET" == 0 && -n "$tags_json" ]] && echo "  最近 tag:"
if [[ -n "$tags_json" ]]; then
  printf '%s' "$tags_json" | python3 -c '
import sys,json
for t in json.load(sys.stdin)[:10]:
    print("    -", t.get("name",""))
' 2>/dev/null
  if [[ -z "$latest_tag" ]]; then
    latest_tag="$(printf '%s' "$tags_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0].get("name",""))' 2>/dev/null)"
  fi
fi

# ---- 3. 默认分支最新 commit ----
commit_json="$(gh_get "repos/$REPO/commits?per_page=1")"
c_sha=""; c_date=""; c_msg=""
if [[ -n "$commit_json" ]]; then
  c_sha="$(printf '%s' "$commit_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["sha"])' 2>/dev/null)"
  c_date="$(printf '%s' "$commit_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["commit"]["author"]["date"])' 2>/dev/null)"
  c_msg="$(printf '%s' "$commit_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["commit"]["message"].splitlines()[0])' 2>/dev/null)"
  [[ "$QUIET" == 0 ]] && {
    echo "  默认分支最新 commit: ${c_sha:0:12} @ $c_date"
    echo "    $c_msg"
  }
fi

# ---- 4. 版本比较结论 ----
CONCLUSION=""
if [[ -n "$latest_tag" ]]; then
  cmp="$(version_compare "$latest_tag" "$LOCAL_VER")"
  if [[ "$cmp" == "0" ]]; then
    CONCLUSION="上游有更新可用: 最新 ${latest_tag}  vs  本地 ${LOCAL_VER}"
  elif [[ "$cmp" == "1" ]]; then
    CONCLUSION="本地版本 ${LOCAL_VER} 已是最新 (上游最新 tag ${latest_tag}) ✓"
  else
    CONCLUSION="无法判定 (本地 ${LOCAL_VER} / 上游 ${latest_tag} 版本格式异常)"
  fi
else
  CONCLUSION="未能从 GitHub 获取版本信息, 请稍后重试 (可能限流)"
fi

[[ "$QUIET" == 0 ]] && {
echo
echo "[结论] $CONCLUSION"
}

# ---- 5. 本地 dsh 工作树 git 比对 ----
if [[ "$NO_GIT" == 0 ]]; then
  [[ "$QUIET" == 0 ]] && echo
  [[ "$QUIET" == 0 ]] && echo "--- 本地上游源码 ($LOCAL_DIR) ---"
  if [[ -d "$LOCAL_DIR/.git" ]]; then
    pushd "$LOCAL_DIR" >/dev/null 2>&1 || true
    cur="$(git rev-parse HEAD 2>/dev/null)"
    br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ "$QUIET" == 0 ]] && echo "  当前 HEAD : ${cur:0:12} ($br)"
    [[ "$QUIET" == 0 && -n "$LOCAL_COMMIT" ]] && echo "  构建记录 : ${LOCAL_COMMIT:0:12}"
    if [[ -n "$cur" && -n "$LOCAL_COMMIT" && "$cur" == "$LOCAL_COMMIT" ]]; then
      [[ "$QUIET" == 0 ]] && echo "  与构建时一致 ✓ (如需看上游新 commit 可先 git fetch)"
    elif [[ -n "$cur" && -n "$LOCAL_COMMIT" ]]; then
      [[ "$QUIET" == 0 ]] && echo "  与构建记录不同 (可能已切换/拉取)"
    fi
    # 解析远程默认分支
    def_branch="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{print $2}' | sed 's#refs/heads/##')"
    [[ -z "$def_branch" ]] && def_branch="master"
    if git fetch --quiet origin "refs/heads/$def_branch:refs/remotes/origin/$def_branch" 2>/dev/null; then
      if git rev-parse -q --verify "origin/$def_branch" >/dev/null 2>&1 && [[ -n "${LOCAL_COMMIT:-$cur}" ]]; then
        base="${LOCAL_COMMIT:-$cur}"
        if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
          # 浅克隆历史被截断, rev-list 无法可靠计算差异, 以 tag 版本比较为准
          [[ "$QUIET" == 0 ]] && echo "  本地为浅克隆(shallow), 无法精确计算 commit 差异; 请以上方 tag 版本比较结论为准"
        else
          ahead="$(git rev-list --count "origin/$def_branch..$base" 2>/dev/null)"
          behind="$(git rev-list --count "$base..origin/$def_branch" 2>/dev/null)"
          [[ "$QUIET" == 0 ]] && echo "  fetch 后: 本地领先 $ahead / 落后上游(分支 $def_branch) $behind 个 commit"
        fi
      else
        [[ "$QUIET" == 0 ]] && echo "  (无法确定构建 commit, 跳过计数)"
      fi
    else
      [[ "$QUIET" == 0 ]] && echo "  (git fetch 失败或离线; 跳过远程比对)"
    fi
    popd >/dev/null 2>&1 || true
  else
    [[ "$QUIET" == 0 ]] && echo "  (未找到本地 git 工作树, 仅做版本号比较)"
  fi
fi

# ---- 6. 参考仓库 ----
[[ "$QUIET" == 0 ]] && echo
[[ "$QUIET" == 0 ]] && echo "--- 参考仓库 $REF_REPO ---"
ref_json="$(gh_get "repos/$REF_REPO/commits?per_page=1")"
if [[ -n "$ref_json" ]]; then
  r_sha="$(printf '%s' "$ref_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["sha"])' 2>/dev/null)"
  r_date="$(printf '%s' "$ref_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["commit"]["author"]["date"])' 2>/dev/null)"
  [[ "$QUIET" == 0 ]] && echo "  最近更新: ${r_sha:0:12} @ $r_date"
else
  [[ "$QUIET" == 0 ]] && echo "  (GitHub API 不可达或限流)"
fi

# ---- 7. 写回 LAST_CHECKED ----
if command -v gawk >/dev/null 2>&1; then
  gawk -i inplace -v k="LAST_CHECKED" -v v="\"$NOW\"" 'BEGIN{FS="="} $1==k{$0=k"="v} {print}' "$CONF" 2>/dev/null || true
  gawk -i inplace -v k="LAST_UPSTREAM_VERSION" -v v="\"${latest_tag:-}\"" 'BEGIN{FS="="} $1==k{$0=k"="v} {print}' "$CONF" 2>/dev/null || true
else
  # 退化方案: 用 sed 替换 (兼容无 gawk)
  sed -i "s|^LAST_CHECKED=.*|LAST_CHECKED=\"$NOW\"|" "$CONF" 2>/dev/null || true
  sed -i "s|^LAST_UPSTREAM_VERSION=.*|LAST_UPSTREAM_VERSION=\"${latest_tag:-}\"|" "$CONF" 2>/dev/null || true
fi

# 安静模式: 仅当确实有更新才输出
if [[ "$QUIET" == 1 ]]; then
  if [[ "$CONCLUSION" == 上游有更新可用* ]]; then
    echo "[$(date '+%H:%M:%S')] $CONCLUSION"
  fi
fi

[[ "$QUIET" == 0 ]] && echo
[[ "$QUIET" == 0 ]] && echo "检查完成。发现更新可运行: ./sync-upstream.sh"
exit 0
