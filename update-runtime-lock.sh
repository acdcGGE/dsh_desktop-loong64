#!/usr/bin/env bash
# =============================================================================
# update-runtime-lock.sh —— 把 linux-loong64 目标写入 primary-runtime 锁
#
# 1. scripts/primary-runtime/lock.json  targets 增加 linux-loong64:
#      node:     unofficial-builds.nodejs.org 的 v24.21.0 linux-loong64 (.tar.xz);
#                若 artifacts/node-loong64.tar.xz 存在则改用本地归档 (上游该站带宽
#                在本机实测约 10 KB/s, 会导致 prepare:runtime 300s 超时)
#      python:   loong64 分叉的 python-build-standalone 3.12.15+20261021
#      wheels:   本机构建的 4 个原生轮子 (file:// 直读, 见 prepare.ts P12b)
# 2. python/sdk-runtime/platforms.json 增加 linux-loong64 (与锁目标集合保持一致)
#
# 依赖: build-wheels.sh 已产出 artifacts/wheels/{numpy,pandas,pillow,lxml}-*.whl
# 幂等: 重复执行覆盖同一目标, 不改动其他 target。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH="${1:-$(cd "$HERE/.." && pwd)/dsh}"
WHEEL_DIR="$HERE/artifacts/wheels"
LOCK="$DSH/scripts/primary-runtime/lock.json"
PLATFORMS="$DSH/python/sdk-runtime/platforms.json"

[[ -f "$LOCK" ]] || { echo "错误: 找不到 $LOCK" >&2; exit 1; }

# loong64 Python 分叉 (astral-sh 官方发布不含 loongarch64)
PY_VERSION="3.12.15"
PY_RELEASE="20261021"
PY_BASE_URL="https://github.com/loong64/python-build-standalone/releases/download"
PY_TARGET="loongarch64-unknown-linux-gnu"
PY_TARBALL="$HERE/artifacts/cpython-loong64.tar.gz"
NODE_VERSION="24.21.0"
NODE_ARCHIVE="linux-loong64.tar.xz"
NODE_SHA256="84b10844119d8734b5edbd42c01bd2d83fda50212361a63e91c1371a8bfc91ff"
NODE_TARBALL="$HERE/artifacts/node-loong64.tar.xz"
# 本机归档优先: 上游 unofficial-builds 在本机实测约 10 KB/s, 会让 prepare:runtime 300s 超时。
# nodeVersion 必须从归档内顶层目录反推, 否则 prepare.ts 解压后找不到 source,
# 且 smoke 检查会把 manifest.node 与 runtime 实际 Node 版本逐一比对。
if [[ -f "$NODE_TARBALL" ]]; then
  NODE_SHA256="$(sha256sum "$NODE_TARBALL" | cut -d' ' -f1)"
  # 用 sed -n '1p' 而非 head: 后者提前关管道会让 tar 收到 SIGPIPE, pipefail 下脚本直接退出。
  NODE_VERSION="$(tar -tJf "$NODE_TARBALL" | sed -n '1p' | cut -d/ -f1 | sed -E 's/^node-v//; s/-linux-loong64$//')"
  echo "==> node tarball: v$NODE_VERSION sha256=$NODE_SHA256 (本地)"
fi

echo "==> 校验本机构建轮子"
for pat in "numpy-2.3.5-cp312-cp312-linux_loongarch64.whl" \
           "pandas-3.0.1-cp312-cp312-linux_loongarch64.whl" \
           "pillow-12.3.0-cp312-cp312-linux_loongarch64.whl" \
           "lxml-6.1.3-cp312-cp312-linux_loongarch64.whl"; do
  [[ -f "$WHEEL_DIR/$pat" ]] || { echo "错误: 缺少轮子 $WHEEL_DIR/$pat (先运行 build-wheels.sh)" >&2; exit 1; }
done

if [[ -f "$PY_TARBALL" ]]; then
  PY_SHA256="$(sha256sum "$PY_TARBALL" | cut -d' ' -f1)"
  echo "    python tarball sha256: $PY_SHA256"
else
  echo "错误: 找不到 $PY_TARBALL (先下载 loong64 CPython)" >&2
  exit 1
fi

echo "==> 写入 $LOCK"
python3 - "$LOCK" "$PLATFORMS" "$WHEEL_DIR" "$PY_VERSION" "$PY_RELEASE" "$PY_BASE_URL" "$PY_TARGET" "$PY_SHA256" "$NODE_VERSION" "$NODE_ARCHIVE" "$NODE_SHA256" <<'PYEOF'
import hashlib, json, sys

lock_path, platforms_path, wheel_dir = sys.argv[1], sys.argv[2], sys.argv[3]
py_version, py_release, py_base_url, py_target, py_sha256 = sys.argv[4:9]
node_version, node_archive, node_sha256 = sys.argv[9:12]

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

wheel_names = [
    'numpy-2.3.5-cp312-cp312-linux_loongarch64.whl',
    'pandas-3.0.1-cp312-cp312-linux_loongarch64.whl',
    'pillow-12.3.0-cp312-cp312-linux_loongarch64.whl',
    'lxml-6.1.3-cp312-cp312-linux_loongarch64.whl',
]
wheels = []
for name in wheel_names:
    path = f"{wheel_dir}/{name}"
    wheels.append({
        'url': f'file://{path}',
        'sha256': sha256(path),
    })
    print(f"    {name}  sha256={wheels[-1]['sha256']}")

target = {
    'nodeArchive': node_archive,
    'nodeSha256': node_sha256,
    'pythonTarget': py_target,
    'pythonSha256': py_sha256,
    'pythonVersion': py_version,
    'pythonRelease': py_release,
    'pythonBaseUrl': py_base_url,
    'wheels': wheels,
}

with open(lock_path, encoding='utf-8') as f:
    lock = json.load(f)
lock['targets']['linux-loong64'] = target
# prepare.ts 用顶层 nodeVersion 拼解压后的目录名, smoke 也用它校验 runtime 内 Node 版本;
# 本地归档版本与上游锁不同步时, 必须同步顶层值, 否则两处都会失败。
lock['nodeVersion'] = node_version
with open(lock_path, 'w', encoding='utf-8') as f:
    f.write(json.dumps(lock, indent=2) + '\n')
print(f"    lock targets: {', '.join(lock['targets'])}")

with open(platforms_path, encoding='utf-8') as f:
    platforms = json.load(f)
platforms['linux-loong64'] = {
    'tag': 'manylinux_2_28_loongarch64',
    'executable': 'deepseek-harness-sdk-runtime-linux-loong64',
}
with open(platforms_path, 'w', encoding='utf-8') as f:
    f.write(json.dumps(platforms, indent=2) + '\n')
print(f"    platforms: {', '.join(platforms)}")
PYEOF

echo
echo "==> 校验锁一致性 (spec: targets 键集合必须与 platforms.json 一致)"
python3 - "$LOCK" "$PLATFORMS" <<'PYEOF'
import json, sys
lock = json.load(open(sys.argv[1], encoding='utf-8'))
platforms = json.load(open(sys.argv[2], encoding='utf-8'))
expected = sorted(k.replace('macos-', 'mac-') for k in platforms)
actual = sorted(lock['targets'])
assert actual == expected, f"targets {actual} != platforms {expected}"
# spec: 每个 target 的 wheels + 共享 wheels 必须恰好覆盖 pythonPackages
def normalize(name):
    return name.lower().replace('-', '').replace('_', '').replace('.', '')
from urllib.parse import urlparse
import os
for name, artifact in lock['targets'].items():
    dists = []
    for w in [*artifact['wheels'], *lock['wheels']]:
        base = os.path.basename(urlparse(w['url']).path)
        dists.append((normalize(base.split('-')[0]), base.split('-')[1]))
    declared = [(normalize(k), v) for k, v in lock['pythonPackages'].items()]
    assert dict(dists) == dict(declared), f"{name}: wheels 与 pythonPackages 不一致"
print("    OK: 所有 target 的轮子集合与 pythonPackages 精确匹配")
PYEOF

echo
echo "==> 完成。现在可以运行桌面端打包:"
echo "    cd $DSH"
echo "    export PATH=\"$HERE/../toolchain/node/bin:\$PATH\"   # node24 + pnpm11, 缺则先跑 ./setup-toolchain.sh"
echo "    DSH_DESKTOP_TARGET_PLATFORM=linux DSH_DESKTOP_TARGET_ARCH=loong64 \\"
echo "    DSH_DESKTOP_ELECTRON_DIST=${DSH_DESKTOP_ELECTRON_DIST:-$HERE/../electron-loong64/electron-43.7.7} \\"
echo "    DSH_LOONG64_RIPGREP_SHIM=$HERE/shims/@vscode+ripgrep-linux-loong64 \\"
echo "    pnpm --dir apps/desktop run package:dir"
