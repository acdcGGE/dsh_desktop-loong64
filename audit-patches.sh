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
#     例: ./audit-patches.sh dsh-v0.2.2-alpha.3 ../dsh-0.2.2
#
# 退出码:
#   0  全部补丁可施加 (含"已适配/幂等跳过")
#   1  存在失配 (清单打到 stdout)
#   2  参数或环境问题
#
# 实现要点:
#   - 从 apply-adaption.sh 的 python heredoc 里用 ast 抽取全部 patch() 调用,
#     拿到 pid/path/old/new/all_occurrences
#   - **按补丁顺序累计修改后再校验下一个锚点**: 有些补丁(如 P15d/P28/P30a)的
#     锚点是前序补丁生成的, 静态逐条比对 pristine 文件会把它们误报成失配
#   - 只解析字面量参数; 动态拼接的锚点(参数为表达式)无法静态校验, 单独列出
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-}"
LOCAL_DIR="${2:-${UPSTREAM_LOCAL_DIR:-$HERE/../dsh-0.2.2}}"

if [[ -z "$TAG" ]]; then
  echo "用法: ./audit-patches.sh <tag> [源码树]" >&2
  exit 2
fi
if [[ "$LOCAL_DIR" != /* ]]; then
  LOCAL_DIR="$(cd "$HERE/$LOCAL_DIR" 2>/dev/null && pwd)" || LOCAL_DIR="$HERE/$LOCAL_DIR"
fi
[[ -e "$LOCAL_DIR/.git" ]] || { echo "错误: 未找到 git 工作树: $LOCAL_DIR" >&2; exit 2; }

# tag 可能还没 fetch 到本地, 先尝试一次 (失败不影响, 后面 git show 会报错)
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

python3 - "$HERE/apply-adaption.sh" "$LOCAL_DIR" "$TAG" <<'PYEOF'
import ast, re, subprocess, sys

script, repo, tag = sys.argv[1], sys.argv[2], sys.argv[3]

src = open(script, encoding='utf-8').read()
m = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.S)
if not m:
    print("错误: 无法从 apply-adaption.sh 中抽取 python 补丁主体"); sys.exit(2)
body = m.group(1)

try:
    tree = ast.parse(body)
except SyntaxError as e:
    print(f"错误: 补丁主体解析失败: {e}"); sys.exit(2)

def cv(n):
    return n.value if isinstance(n, ast.Constant) else None

calls = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'patch':
        a = node.args
        if len(a) < 3:
            continue
        pid, path, old = cv(a[0]), cv(a[1]), cv(a[2])
        if not (isinstance(pid, str) and isinstance(path, str) and isinstance(old, str)):
            continue
        new = cv(a[3]) if len(a) > 3 else None
        # 第 5 个位置参数 True = 替换全部出现
        allocc = len(a) > 4 and isinstance(a[4], ast.Constant) and a[4].value is True
        for kw in node.keywords:
            if kw.arg in ('all_occurrences', 'all') and isinstance(kw.value, ast.Constant):
                allocc = bool(kw.value.value)
        calls.append((node.lineno, pid, path, old, new, allocc))
calls.sort(key=lambda c: c[0])

files = {}
def read(p):
    if p not in files:
        r = subprocess.run(['git', '-C', repo, 'show', f'{tag}:{p}'],
                           capture_output=True, text=True)
        files[p] = r.stdout if r.returncode == 0 else None
    return files[p]

fails, ok, skipped, dyn = [], 0, 0, 0
for _, pid, path, old, new, allocc in calls:
    s = read(path)
    if s is None:
        fails.append((pid, '目标 tag 下文件不存在', path)); continue
    if new is None:
        dyn += 1
        continue
    if f'loong64-adaption[{pid}]' in s or new in s:
        skipped += 1
        continue
    cnt = s.count(old)
    if cnt == 0:
        fails.append((pid, '锚点未找到', path)); continue
    if cnt > 1 and not allocc:
        fails.append((pid, f'锚点出现 {cnt} 次(patch 未声明替换全部)', path)); continue
    files[path] = s.replace(old, new)
    ok += 1

total = len(calls)
print(f"补丁总数 {total}: 可施加 {ok}, 幂等跳过 {skipped}, 动态参数未校验 {dyn}, 失配 {len(fails)}")
if fails:
    print()
    print("失配清单 (需人工重新适配):")
    for pid, why, path in fails:
        print(f"  [X] {pid:<6} {why:<32} <- {path}")
    sys.exit(1)
print("结论: 全部补丁均可施加 ✓")
sys.exit(0)
PYEOF
