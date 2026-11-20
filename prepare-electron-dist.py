#!/usr/bin/env python3
"""从带应用残留的 Electron dist 生成纯净运行时目录。

背景: 若 Electron dist 直接从已安装应用(如 /opt/deepseek-harness)整目录复制,
会混入 app.asar / app.asar.unpacked / resources/runtime / icon.png / 启动脚本。
electron-builder 配置 electronDist=<该目录>, 其旧 resources/runtime 会与本次
extraResources 写入的新 runtime 冲突, 报 EEXIST: symlink python3.12 -> python3。

本脚本生成只含 Electron 运行时本身(二进制/.pak/.so/locales/default_app.asar)
的副本, 供 DSH_DESKTOP_ELECTRON_DIST 使用。用硬链接副本省空间, 只 unlink 副本
条目, 不动源目录。

用法:
  python3 prepare-electron-dist.py                       # 默认 ../electron-loong64/electron-43.7.7 -> 同目录 -clean
  python3 prepare-electron-dist.py SRC DST               # 显式指定
  python3 prepare-electron-dist.py SRC DST --force       # 目标已存在时先删除
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_SRC = HERE.parent / "electron-loong64/electron-43.7.7"

TOP_EXCLUDE = {"deepseek-harness"}
RES_EXCLUDE = {"app.asar", "app.asar.unpacked", "runtime", "icon.png"}


def remove(path: Path) -> None:
    if not path.lexists():
        return
    if path.is_dir() and not path.is_link():
        shutil.rmtree(path)
    else:
        path.unlink()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?", type=Path, default=DEFAULT_SRC, help="源 Electron dist 目录")
    ap.add_argument("dst", nargs="?", type=Path, default=None, help="目标纯净目录 (默认 <src>-clean)")
    ap.add_argument("--force", action="store_true", help="目标已存在时先删除")
    args = ap.parse_args()

    src: Path = args.src.resolve()
    dst: Path = (args.dst or Path(str(args.src) + "-clean")).resolve()

    if not src.is_dir():
        print(f"错误: 源目录不存在: {src}", file=sys.stderr)
        return 1
    if not (src / "electron").exists():
        print(f"错误: 源目录无 electron 二进制: {src}", file=sys.stderr)
        return 1
    if dst.exists():
        if not args.force:
            print(f"错误: 目标已存在 (加 --force 覆盖): {dst}", file=sys.stderr)
            return 1
        remove(dst)

    shutil.copytree(src, dst, copy_function=os_link, symlinks=True)

    removed = []
    for name in sorted(TOP_EXCLUDE):
        if (dst / name).lexists():
            remove(dst / name)
            removed.append(name)
    res = dst / "resources"
    for name in sorted(RES_EXCLUDE):
        if (res / name).lexists():
            remove(res / name)
            removed.append("resources/" + name)

    print(f"纯净 Electron dist: {dst}")
    print("已排除:", ", ".join(removed) if removed else "(无)")
    print("resources/ 保留:", ", ".join(sorted(p.name for p in res.iterdir())))
    return 0


def os_link(src: str, dst: str) -> None:
    """copytree 的硬链接复制函数; 跨文件系统时回退为普通复制。"""
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


if __name__ == "__main__":
    raise SystemExit(main())
