#!/usr/bin/env bash
# ============================================================
# check-upstream.sh —— 追踪 deepseek-harness 上游更新 (含 rc 预发布)
# ------------------------------------------------------------
# 功能:
#   1. 拉取 GitHub 的 releases (含 pre-release) 与 tags, 按**语义化版本号**
#      取最大值 (而不是按时间取 tags[0]), 因此 rc.N -> rc.N+1 能被正确识别
#   2. 分别给出"上游最新(含 rc)" / "上游最新 rc" / "上游最新正式版"
#   3. 与本地已构建版本 (upstream.conf 的 LOCAL_VERSION) 比较
#   4. 若本地存在 dsh 源码工作树, 额外做 git commit 级精确比对
#   5. 顺带报告第三方龙芯移植参考仓库的最近更新
#
# 用法:
#   ./check-upstream.sh              正常检查 (会写回 LAST_CHECKED 等字段)
#   ./check-upstream.sh --quiet      仅在有更新时输出一行 (适合 cron)
#   ./check-upstream.sh --json       输出机器可读 JSON (只输出 JSON)
#   ./check-upstream.sh --no-git     跳过本地 git 工作树比对
#   ./check-upstream.sh --sync       发现新版本时直接调用 sync-upstream.sh --apply
#   ./check-upstream.sh --fixtures D 离线调试: 从目录 D 读 releases.json / tags.json
#
# 退出码 (便于自动化分支):
#   0  已是最新 / 无法判定
#   10 上游有更新可用
#   1  参数错误
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
JSON=0
SYNC=0
FIXTURES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --no-git) NO_GIT=1 ;;
    --json) JSON=1; QUIET=0; NO_GIT=1 ;;
    --sync) SYNC=1 ;;
    --fixtures) shift; FIXTURES="${1:-}" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REL_JSON="$TMP/releases.json"
TAG_JSON="$TMP/tags.json"
SUMMARY="$TMP/summary.json"
REPORT="$TMP/report.txt"

# ---- GitHub API 封装 (带超时与缺失容忍) ----
gh_get() {
  curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" \
    -H "User-Agent: $UA" "$API/$1" 2>/dev/null
}

# ---- 取数据 (支持离线 fixture, 便于限流时复现) ----
if [[ -n "$FIXTURES" ]]; then
  [[ -f "$FIXTURES/releases.json" ]] && cp "$FIXTURES/releases.json" "$REL_JSON" || echo '[]' > "$REL_JSON"
  [[ -f "$FIXTURES/tags.json" ]] && cp "$FIXTURES/tags.json" "$TAG_JSON" || echo '[]' > "$TAG_JSON"
else
  gh_get "repos/$REPO/releases?per_page=30" > "$REL_JSON" || echo '[]' > "$REL_JSON"
  gh_get "repos/$REPO/tags?per_page=30"     > "$TAG_JSON" || echo '[]' > "$TAG_JSON"
fi

NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---- 版本分析与报告 (Python) ----
python3 - "$REL_JSON" "$TAG_JSON" "$LOCAL_VER" "$SUMMARY" "$REPORT" "$NOW" "$REPO" <<'PY'
import sys, json, re

rel_path, tag_path, local_ver, summary_path, report_path, now, repo = sys.argv[1:8]

def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []

def norm(v):
    v = (v or "").strip()
    for p in ("dsh-v", "dsh-", "v"):
        if v.startswith(p):
            v = v[len(p):]
    return v

PRE_RANK = {"": 2, "rc": 1, "pre": 0, "beta": -1, "alpha": -2}

def parse(v):
    """返回可比较的元组; 无法解析返回 None"""
    v = norm(v)
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:[-.](rc|beta|alpha|pre)\.?(\d+))?$", v)
    if not m:
        return None
    maj, minr, pat, pre, pren = m.groups()
    return (int(maj), int(minr), int(pat), PRE_RANK.get(pre or "", 2), int(pren or 0))

KIND_LABEL = {"stable": "正式版", "rc": "rc", "alpha": "alpha", "beta": "beta", "pre": "pre"}

def kind_of(tag, prerelease):
    """区分 stable / rc / alpha / beta / pre。
    版本号后缀优先 (alpha.3 要标成 alpha, 而不是笼统的"预发布"); 其次看 GitHub 的 prerelease 标记。"""
    m = re.search(r"(?:^|[-.])(rc|alpha|beta|pre)\.?(\d+)$", norm(tag).lower())
    if m:
        return m.group(1)
    return "pre" if prerelease else "stable"

entries = {}   # norm_tag -> dict(tag, kind, published, prerelease)
for r in load(rel_path):
    tag = r.get("tag_name") or ""
    if not tag or r.get("draft"):
        continue
    entries[norm(tag)] = {
        "tag": tag,
        "kind": kind_of(tag, bool(r.get("prerelease"))),
        "published": (r.get("published_at") or "")[:10],
        "prerelease": bool(r.get("prerelease")),
    }
for t in load(tag_path):
    tag = t.get("name") or ""
    if not tag:
        continue
    key = norm(tag)
    if key in entries:
        continue
    entries[key] = {
        "tag": tag,
        "kind": kind_of(tag, None),
        "published": "",
        "prerelease": None,
    }

versioned = [(parse(e["tag"]), e) for e in entries.values()]
versioned = [(k, e) for k, e in versioned if k is not None]
versioned.sort(key=lambda kv: kv[0], reverse=True)

latest_any = versioned[0] if versioned else None
rcs = [(k, e) for k, e in versioned if e["kind"] == "rc"]
prers = [(k, e) for k, e in versioned if e["kind"] != "stable"]
stables = [(k, e) for k, e in versioned if e["kind"] == "stable"]
latest_rc = rcs[0] if rcs else None
latest_prer = prers[0] if prers else None
latest_stable = stables[0] if stables else None

local_key = parse(local_ver)
if latest_any and local_key:
    update = latest_any[0] > local_key
    cmp_ok = True
else:
    update = False
    cmp_ok = False

def fmt(entry):
    if not entry:
        return "（无）"
    _, e = entry
    label = KIND_LABEL.get(e["kind"], e["kind"])
    tagtxt = e["tag"] if e["kind"] == "stable" else f"{e['tag']}  [{label}]"
    return f"{tagtxt}{('  发布于 ' + e['published']) if e['published'] else ''}"

lines = []
lines.append("==================================================")
lines.append(" dsh_desktop-loong64 —— 上游更新追踪 (含 rc)")
lines.append(f" 时间: {now}")
lines.append("==================================================")
lines.append("")
lines.append(f"[本地] 已构建版本 : {local_ver}")
lines.append("")
lines.append(f"--- 官方上游 {repo} ---")
lines.append(f"  上游最新 (含预发布): {fmt(latest_any)}")
lines.append(f"  上游最新 rc        : {fmt(latest_rc)}")
lines.append(f"  上游最新正式版     : {fmt(latest_stable)}")
if prers:
    lines.append("  最近预发布 (按版本号降序, 前 5):")
    for _, e in prers[:5]:
        pub = f"  {e['published']}" if e["published"] else ""
        label = KIND_LABEL.get(e["kind"], e["kind"])
        lines.append(f"    - {e['tag']}  [{label}]{pub}")
if stables:
    lines.append("  最近正式版 (前 3):")
    for _, e in stables[:3]:
        pub = f"  {e['published']}" if e["published"] else ""
        lines.append(f"    - {e['tag']}{pub}")

lines.append("")
if not cmp_ok:
    conclusion = f"无法判定 (本地 {local_ver} / 上游 {fmt(latest_any)})"
elif update:
    kind = latest_any[1]["kind"]
    conclusion = f"上游有更新可用: {latest_any[1]['tag']}  vs  本地 {local_ver}  ({KIND_LABEL.get(kind, kind)} 更新)"
else:
    conclusion = f"本地版本 {local_ver} 已是最新 (上游最新 {fmt(latest_any)}) ✓"
lines.append(f"[结论] {conclusion}")

with open(report_path, "w") as f:
    f.write("\n".join(lines) + "\n")

summary = {
    "local": local_ver,
    "latest": latest_any[1]["tag"] if latest_any else "",
    "latest_kind": latest_any[1]["kind"] if latest_any else "",
    "latest_rc": latest_rc[1]["tag"] if latest_rc else "",
    "latest_prerelease": latest_prer[1]["tag"] if latest_prer else "",
    "latest_stable": latest_stable[1]["tag"] if latest_stable else "",
    "update": bool(update),
    "comparable": cmp_ok,
    "prereleases_recent": [e["tag"] for _, e in prers[:5]],
    "rc_recent": [e["tag"] for _, e in rcs[:5]],
    "checked_at": now,
}
with open(summary_path, "w") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)
PY

LATEST_ANY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["latest"])' "$SUMMARY" 2>/dev/null)"
LATEST_RC="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["latest_rc"])' "$SUMMARY" 2>/dev/null)"
HAS_UPDATE="$(python3 -c 'import json,sys;print("1" if json.load(open(sys.argv[1]))["update"] else "0")' "$SUMMARY" 2>/dev/null)"
CONCLUSION="$(grep '^\[结论\]' "$REPORT" 2>/dev/null | sed 's/^\[结论\] //')"

# ---- 人类可读输出 ----
if [[ "$JSON" == 0 ]]; then
  if [[ "$QUIET" == 1 ]]; then
    [[ "$HAS_UPDATE" == "1" ]] && echo "[$(date '+%H:%M:%S')] $CONCLUSION"
  else
    cat "$REPORT"
  fi
fi

# ---- 本地 git 工作树比对 (安静模式跳过, 保证 --quiet 只输出一行) ----
if [[ "$NO_GIT" == 0 && "$QUIET" == 0 ]]; then
  echo
  echo "--- 本地上游源码 ($LOCAL_DIR) ---"
  # .git 可能是目录(普通克隆), 也可能是文件(git worktree / submodule), 故用 -e
  if [[ -e "$LOCAL_DIR/.git" ]]; then
    pushd "$LOCAL_DIR" >/dev/null 2>&1 || true
    cur="$(git rev-parse HEAD 2>/dev/null)"
    br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "  当前 HEAD : ${cur:0:12} ($br)"
    [[ -n "$LOCAL_COMMIT" ]] && echo "  构建记录 : ${LOCAL_COMMIT:0:12}"
    if [[ -n "$cur" && -n "$LOCAL_COMMIT" && "$cur" == "$LOCAL_COMMIT" ]]; then
      echo "  与构建时一致 ✓ (如需看上游新 commit 可先 git fetch)"
    elif [[ -n "$cur" && -n "$LOCAL_COMMIT" ]]; then
      echo "  与构建记录不同 (可能已切换/拉取)"
    fi
    # 解析远程默认分支
    def_branch="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{print $2}' | sed 's#refs/heads/##')"
    [[ -z "$def_branch" ]] && def_branch="master"
    if git fetch --quiet origin "refs/heads/$def_branch:refs/remotes/origin/$def_branch" 2>/dev/null; then
      if git rev-parse -q --verify "origin/$def_branch" >/dev/null 2>&1 && [[ -n "${LOCAL_COMMIT:-$cur}" ]]; then
        base="${LOCAL_COMMIT:-$cur}"
        if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
          # 浅克隆历史被截断, rev-list 无法可靠计算差异, 以 tag 版本比较为准
          echo "  本地为浅克隆(shallow), 无法精确计算 commit 差异; 请以上方 tag 版本比较结论为准"
        else
          ahead="$(git rev-list --count "origin/$def_branch..$base" 2>/dev/null)"
          behind="$(git rev-list --count "$base..origin/$def_branch" 2>/dev/null)"
          echo "  fetch 后: 本地领先 $ahead / 落后上游(分支 $def_branch) $behind 个 commit"
        fi
      else
        echo "  (无法确定构建 commit, 跳过计数)"
      fi
    else
      echo "  (git fetch 失败或离线; 跳过远程比对)"
    fi
    popd >/dev/null 2>&1 || true
  else
    echo "  (未找到本地 git 工作树, 仅做版本号比较)"
  fi

  # ---- 参考仓库 ----
  echo
  echo "--- 参考仓库 $REF_REPO ---"
  ref_json="$(gh_get "repos/$REF_REPO/commits?per_page=1")"
  if [[ -n "$ref_json" ]]; then
    r_sha="$(printf '%s' "$ref_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["sha"])' 2>/dev/null)"
    r_date="$(printf '%s' "$ref_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["commit"]["author"]["date"])' 2>/dev/null)"
    echo "  最近更新: ${r_sha:0:12} @ $r_date"
  else
    echo "  (GitHub API 不可达或限流)"
  fi
fi

# ---- 写回 upstream.conf ----
set_conf() {
  local k="$1" v="$2"
  if command -v gawk >/dev/null 2>&1; then
    gawk -i inplace -v k="$k" -v v="\"$v\"" 'BEGIN{FS="="} $1==k{$0=k"="v} {print}' "$CONF" 2>/dev/null || true
  else
    sed -i "s|^$k=.*|$k=\"$v\"|" "$CONF" 2>/dev/null || true
  fi
}
set_conf LAST_CHECKED "$NOW"
set_conf LAST_UPSTREAM_VERSION "$LATEST_ANY"
set_conf LAST_SEEN_RC "$LATEST_RC"

# ---- JSON 输出 (放在最后, 保证 stdout 只有 JSON) ----
if [[ "$JSON" == 1 ]]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d, ensure_ascii=False, indent=2))' "$SUMMARY"
fi

# ---- 可选: 发现更新直接同步 ----
if [[ "$SYNC" == 1 && "$HAS_UPDATE" == "1" && -n "$LATEST_ANY" ]]; then
  echo
  echo "==> --sync: 调用 sync-upstream.sh --apply --tag $LATEST_ANY"
  "$HERE/sync-upstream.sh" --apply --tag "$LATEST_ANY" --yes
  exit $?
fi

# ---- 收尾 ----
if [[ "$JSON" == 0 && "$QUIET" == 0 ]]; then
  echo
  echo "检查完成。发现更新可运行: ./sync-upstream.sh --apply --tag <tag>"
fi

[[ "$HAS_UPDATE" == "1" ]] && exit 10
exit 0
