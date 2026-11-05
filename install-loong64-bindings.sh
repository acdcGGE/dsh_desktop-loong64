#!/usr/bin/env python3
# =============================================================================
# install-loong64-bindings.py
#
# 问题背景:
#   dsh 构建链依赖多个 Rust / NAPI 原生包 (如 rolldown, lightningcss, oxc 系列)。
#   这些包的上游 optionalDependencies 只声明了 x64 / arm64 等常见平台,
#   并为这些平台发布预编译 .node 绑定; 但 **loong64 从未被声明**, 因此:
#     1) pnpm install 不会拉取 loong64 绑定;
#     2) 运行时 require('@xxx/binding-linux-loong64-gnu') 抛 "找不到模块" 崩溃。
#
# 解法:
#   龙芯官方 npm 镜像 registry.loongnix.cn:5873 已经为这些包构建了 loong64 绑定,
#   只是上游没把它们写进 optionalDependencies。本脚本扫描 pnpm 虚拟 store 中每个
#   包的 optionalDependencies, 找出"声明了其他平台原生绑定但未声明 linux-loong64-gnu"
#   的家族, 从 loongnix 镜像拉取对应版本的 linux-loong64-gnu 绑定, 安装到该包的
#   node_modules 下, 使加载器能成功 require。
#
# 重要顺序:
#   **必须在 pnpm install 之后运行**, 否则 install 会把我手动放入的绑定剪除。
#   幂等 (已存在则跳过) + 校验 shasum。
#
# 用法:
#   python3 install-loong64-bindings.sh
#   DSH_BUILD_DIR=/path/to/build-root python3 install-loong64-bindings.sh
# =============================================================================
import os, re, json, subprocess, sys, tempfile, shutil

# 构建根目录: 默认取本脚本所在目录的父目录 (即 dsh_desktop-loong64 的上级),
# 可用环境变量 DSH_BUILD_DIR 覆盖。
HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.environ.get("DSH_BUILD_DIR", os.path.dirname(HERE))
DSH = os.environ.get("DSH_SRC_TREE", os.path.join(BUILD, "dsh"))
PNPM = os.path.join(DSH, "node_modules", ".pnpm")
REGISTRY = os.environ.get("DSH_DESKTOP_NPM_REGISTRY", "https://registry.loongnix.cn:5873")
TMP = tempfile.mkdtemp()

if not os.path.isdir(PNPM):
    print(f"错误: 未找到 pnpm store: {PNPM}", file=sys.stderr)
    print("请先在本仓库同级目录准备好 dsh 源码并执行 pnpm install。", file=sys.stderr)
    sys.exit(1)

SUFFIX_MAP = [
    r"-linux-x64-gnu$", r"-linux-arm64-gnu$", r"-linux-arm-gnueabihf$",
    r"-linux-x64-musl$", r"-linux-arm64-musl$", r"-linux-arm-musleabihf$",
]
SUFFIX_RE = re.compile("(" + "|".join(SUFFIX_MAP) + ")")

installed = 0
skipped = 0
missing = []

# 收集需要补齐的 (loong_name, version, parent_node_modules_dir)
todo = []
for root, dirs, files in os.walk(PNPM):
    if "package.json" not in files:
        continue
    # 只处理形如 .pnpm/<pkg>@<ver>/node_modules/<name>/package.json 的真实包
    pj = os.path.join(root, "package.json")
    rel = os.path.relpath(pj, PNPM)
    parts = rel.split(os.sep)
    # 期望结构: <pkg>@<ver>/node_modules/<name>/package.json
    #   或      <pkg>@<ver>/node_modules/@scope/<name>/package.json
    if len(parts) < 4 or parts[1] != "node_modules":
        continue
    try:
        with open(pj) as f:
            data = json.load(f)
    except Exception:
        continue
    opt = data.get("optionalDependencies") or {}
    for key, ver in opt.items():
        if not SUFFIX_RE.search(key):
            continue
        loong = SUFFIX_RE.sub("-linux-loong64-gnu", key)
        if loong == key:
            continue
        parent_nm = os.path.dirname(os.path.dirname(pj))  # .../<pkg>@<ver>/node_modules
        # 宿主包本身带 scope 时 (如 @reflink/reflink、@napi-rs/canvas), 上式得到的
        # 是 .../node_modules/@scope, 需要再上提一级才是真正的 node_modules。
        # 否则会装成 @scope/@scope/<binding> 这种双层目录: 运行时 require 找不到,
        # 且 pnpm 的 prunePnpmForeignNativePackages 遍历到该目录时读不到
        # package.json 会直接抛 ENOENT, 导致 prepare:runtime 失败。
        if os.path.basename(parent_nm).startswith("@"):
            parent_nm = os.path.dirname(parent_nm)
        target = os.path.join(parent_nm, loong)
        if os.path.exists(target):
            skipped += 1
            continue
        todo.append((loong, ver, parent_nm))

# 去重
seen = set()
uniq = []
for loong, ver, pnm in todo:
    k = (loong, ver, pnm)
    if k in seen:
        continue
    seen.add(k)
    uniq.append((loong, ver, pnm))

print(f"需补齐的 loong64 绑定: {len(uniq)} 个")
for loong, ver, pnm in uniq:
    print(f"  - {loong}@{ver}  ->  {pnm}")

for loong, ver, pnm in uniq:
    # npm registry 的标准 scope 编码: @scope/name -> %40scope%2fname
    # 只把 @ 换成 %40 而留下 '/' 时, 部分镜像会 404。
    enc = loong.replace("@", "%40").replace("/", "%2f")
    try:
        meta = subprocess.run(["curl", "-fsSL", "--retry", "2", "--retry-delay", "1",
                               "--retry-all-errors", "--max-time", "40",
                               f"{REGISTRY}/{enc}/"], capture_output=True, text=True)
        if meta.returncode != 0:
            print(f"跳过 {loong}@{ver}: 镜像无该包或不可达 (HTTP/网络错误)"); missing.append((loong,ver)); continue
        d = json.loads(meta.stdout)
        v = d.get("versions", {}).get(ver)
        if not v:
            have = list(d.get("versions", {}).keys())
            print(f"跳过 {loong}@{ver}: 镜像无该版本 (可用 {len(have)} 个, 末尾: {have[-3:] if have else []})")
            missing.append((loong,ver)); continue
        tarball = v["dist"]["tarball"]
        shasum = v["dist"].get("shasum", "")
    except Exception as e:
        print(f"跳过 {loong}@{ver}: 元数据错误 {e}"); missing.append((loong,ver)); continue
    # 包名含 '@scope/name', 直接拼进路径会引入不存在的子目录,
    # 导致 curl -o 对所有 scoped 包都失败。文件名必须扁平化。
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", loong)
    tgz = os.path.join(TMP, safe + ".tgz")
    try:
        dl = subprocess.run(["curl", "-fsSL", "--retry", "4", "--retry-delay", "2",
                               "--retry-all-errors", "--max-time", "180", tarball, "-o", tgz],
                            capture_output=True, text=True)
        if dl.returncode != 0:
            print(f"跳过 {loong}@{ver}: 下载失败 {dl.stderr.strip()[:160]}"); missing.append((loong,ver)); continue
        if shasum:
            out = subprocess.run(["sha1sum", tgz], capture_output=True, text=True).stdout.split()[0]
            if out != shasum:
                print(f"跳过 {loong}@{ver}: shasum 不匹配"); missing.append((loong,ver)); continue
    except Exception as e:
        print(f"跳过 {loong}@{ver}: 下载错误 {e}"); missing.append((loong,ver)); continue
    dest = os.path.join(pnm, loong)
    os.makedirs(dest, exist_ok=True)
    subprocess.run(["tar", "-xzf", tgz, "-C", dest, "--strip-components=1"], check=True)
    installed += 1
    print(f"已安装 {loong}@{ver}")

shutil.rmtree(TMP, ignore_errors=True)
print(f"\n完成: 新安装 {installed} 个, 跳过已存在 {skipped} 个, 缺失(loongnix 无) {len(missing)} 个")
if missing:
    print("缺失清单(需另想办法, 例如源码编译或寻找其他镜像):")
    for m in missing:
        print("  -", m)
