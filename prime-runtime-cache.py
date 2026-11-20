#!/usr/bin/env python3
"""预填 primary-runtime 下载缓存, 避免 prepare-runtime.ts 逐个联网下载卡满超时。

prepare.ts 的 downloadPrimaryRuntimeAsset 按 SHA-256 文件名在缓存里找资产,
命中即跳过联网; 缓存为空时每个资产走 fetch(默认 300s 超时)。本脚本在构建前
把两类资产填进缓存:

  1. 本机已编译并验证的 node/python 归档 + loong64 wheel (--artifacts 目录),
     校验 SHA-256 与 lock.json 一致后按 sha256 文件名放入缓存;
  2. lock.json 中的通用 wheel (files.pythonhosted.org), 联网下载并校验后填入。

用法:
  python3 prime-runtime-cache.py                      # 全部默认
  python3 prime-runtime-cache.py --offline            # 跳过联网通用 wheel
  python3 prime-runtime-cache.py --dsh /path/to/dsh --artifacts /path/to/artifacts
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_BUILD = HERE.parent
DEFAULT_DSH = DEFAULT_BUILD / "dsh"
# 缓存目录: 与 desktop-build-paths.mjs 的 downloads (BUILD_ROOT/downloads) 对齐
DEFAULT_CACHE = DEFAULT_DSH / "apps/desktop/.desktop-build/downloads"
DEFAULT_ARTIFACTS = HERE / "artifacts"
LOCK_REL = "scripts/primary-runtime/lock.json"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def place(dest: Path, data: bytes, sha: str, label: str) -> bool:
    if hashlib.sha256(data).hexdigest() != sha:
        print(f"  [MISMATCH] {label}: 期望 {sha[:16]}", file=sys.stderr)
        return False
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / sha
    if not target.exists():
        tmp = dest / (".tmp-" + sha)
        tmp.write_bytes(data)
        tmp.replace(target)
        print(f"  [OK] {label} -> {sha[:16]}")
    else:
        print(f"  [SKIP] {label} 已在缓存")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsh", type=Path, default=DEFAULT_DSH, help="上游 dsh 源码树路径")
    ap.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS, help="本机已编译产物目录")
    ap.add_argument("--cache", type=Path, default=None, help="下载缓存目录 (默认 <dsh>/apps/desktop/.desktop-build/downloads)")
    ap.add_argument("--offline", action="store_true", help="跳过联网通用 wheel, 仅填本地产物")
    args = ap.parse_args()

    dsh: Path = args.dsh.resolve()
    artifacts: Path = args.artifacts.resolve()
    cache: Path = (args.cache or DEFAULT_DSH and (dsh / "apps/desktop/.desktop-build/downloads")).resolve()

    lock_path = dsh / LOCK_REL
    if not lock_path.is_file():
        print(f"错误: 找不到 lock.json: {lock_path}", file=sys.stderr)
        return 1
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    target = lock["targets"].get("linux-loong64")
    if target is None:
        print("错误: lock.json 无 linux-loong64 目标 (先运行 update-runtime-lock.sh)", file=sys.stderr)
        return 1

    cache.mkdir(parents=True, exist_ok=True)
    ok = True
    print(f"缓存目录: {cache}")

    # 1) 本地产物: node 归档 / python 归档 / 4 个 loong64 wheel
    local_assets: list[tuple[Path, str, str]] = []
    local_assets.append((artifacts / "node-loong64.tar.xz", target["nodeSha256"], "node 归档"))
    local_assets.append((artifacts / "cpython-loong64.tar.gz", target["pythonSha256"], "python 归档"))
    for wheel in target.get("wheels", []):
        url = wheel["url"]
        fname = url.rsplit("/", 1)[-1]
        local_assets.append((artifacts / "wheels" / fname, wheel["sha256"], fname))

    print("\n[1/2] 本地产物")
    for path, sha, label in local_assets:
        if (cache / sha).exists():
            print(f"  [SKIP] {label} 已在缓存")
            continue
        if not path.is_file():
            print(f"  [MISS] {label}: 找不到 {path}", file=sys.stderr)
            ok = False
            continue
        actual = sha256_of(path)
        if actual != sha:
            print(f"  [MISMATCH] {label}: 本地 {actual[:16]} != lock {sha[:16]}", file=sys.stderr)
            ok = False
            continue
        shutil.copyfile(path, cache / sha)
        print(f"  [OK] {label} -> {sha[:16]}")

    # 2) 通用 wheel: 联网下载并校验
    print("\n[2/2] 通用 wheel")
    if args.offline:
        print("  [--offline] 跳过")
    else:
        ctx = ssl.create_default_context()
        for wheel in lock.get("wheels", []):
            sha = wheel["sha256"]
            url = wheel["url"]
            label = url.rsplit("/", 1)[-1]
            if (cache / sha).exists():
                print(f"  [SKIP] {label} 已在缓存")
                continue
            try:
                with urllib.request.urlopen(url, timeout=90, context=ctx) as resp:
                    data = resp.read()
                ok &= place(cache, data, sha, label)
            except Exception as exc:  # noqa: BLE001 - 单个下载失败不阻断其它资产
                print(f"  [FAIL] {label}: {exc}", file=sys.stderr)
                ok = False

    print("\n完成" if ok else "\n存在缺失/不匹配项, 请按上面的提示处理")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
