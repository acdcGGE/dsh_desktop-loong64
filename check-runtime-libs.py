#!/usr/bin/env python3
# =============================================================================
# check-runtime-libs.py —— 校验构建机已安装原生 Python 轮子所需的系统库
#
# 4 个原生轮子 (numpy/pandas/lxml/pillow) 在构建机从源码编译, 链接的是本机
# /usr/lib 下的系统库。本脚本扫描 artifacts/wheels/*.whl 内全部 .so 的 NEEDED,
# 映射每个外部 SONAME 到其所属的 apt 包, 并校验该包在构建机已安装。
#
# 这些 apt 包同时会被 make-deb.sh 写进 .deb 的 Depends, 目标机 dpkg -i 时由 apt
# 解析安装 —— 因此本机不再把任何系统库打包进产物 (不再有 blas-libs/)。
#
# 退出码: 全部满足 -> 0; 任一缺失 -> 1 (让 build.sh 立即失败)。
# 用法: python3 check-runtime-libs.py
# =============================================================================
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WHEEL_DIR = os.path.join(HERE, "artifacts", "wheels")

# 核心系统库: 任何程序都有, 不在依赖声明范围内
CORE = {
    "libc.so.6", "libm.so.6", "libgcc_s.so.1", "libstdc++.so.6",
    "libdl.so.2", "libpthread.so.0", "librt.so.1", "libutil.so.1",
    "libatomic.so.1", "libgomp.so.1",
}


def collect_so_files():
    """解压所有 wheel, 返回其中全部 .so 路径。"""
    if not os.path.isdir(WHEEL_DIR):
        print(f"警告: 未找到 wheel 目录 {WHEEL_DIR}, 跳过校验", file=sys.stderr)
        return []
    tmp = tempfile.mkdtemp(prefix="ckrtl-")
    so_files = []
    for whl in sorted(os.listdir(WHEEL_DIR)):
        if not whl.endswith(".whl"):
            continue
        dest = os.path.join(tmp, whl[:-4])
        subprocess.run(["unzip", "-q", "-o", os.path.join(WHEEL_DIR, whl), "-d", dest],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for root, _dirs, files in os.walk(dest):
            for f in files:
                if f.endswith(".so") or ".so." in f:
                    so_files.append(os.path.join(root, f))
    return so_files


def needed_sonames(so):
    try:
        out = subprocess.run(["objdump", "-p", so], capture_output=True, text=True).stdout
    except Exception:
        return []
    return re.findall(r"NEEDED\s+(\S+)", out)


def locate_soname(soname):
    """用 ldconfig -p 把 SONAME 解析为磁盘路径。"""
    out = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if soname in line and "=>" in line:
            return line.split("=>")[-1].strip()
    return None


def package_of(path):
    """dpkg -S 反查提供该 .so 的 apt 包名。"""
    rp = os.path.realpath(path)
    r = subprocess.run(["dpkg", "-S", rp], capture_output=True, text=True).stdout.strip()
    return r.split(":")[0] if r else None


def main():
    so_files = collect_so_files()
    if not so_files:
        print("无 .so 可扫描, 跳过。")
        return 0

    # 外部 SONAME -> 集合 (去重)
    external = {}
    for so in so_files:
        for s in needed_sonames(so):
            if s.startswith("ld-linux"):
                continue
            if any(s.startswith(c) or c in s for c in CORE):
                continue
            external.setdefault(s, 0)
            external[s] += 1

    # 映射 SONAME -> apt 包 -> 是否已安装
    missing = []
    print(f"扫描到 {len(so_files)} 个 .so, 外部依赖 SONAME {len(external)} 个:\n")
    for soname in sorted(external):
        path = locate_soname(soname)
        pkg = package_of(path) if path else None
        if pkg is None:
            status = "?? 未在构建机找到/无法确定包"
            missing.append((soname, "(未知)"))
        else:
            installed = subprocess.run(
                ["dpkg", "-s", pkg], capture_output=True, text=True
            ).stdout
            ok = "Status: install ok installed" in installed
            status = ("已安装 " if ok else "!! 缺失 ") + pkg
            if not ok:
                missing.append((soname, pkg))
        print(f"  {soname:24s} {status}")

    print()
    if missing:
        print("以下系统库在构建机缺失, 请先安装 (否则冒烟测试/运行时会失败):")
        pkgs = sorted({p for _s, p in missing})
        print("  sudo apt-get install -y " + " ".join(pkgs))
        return 1
    print("✓ 全部系统库依赖已在构建机安装; 这些包将由 make-deb.sh 写进 .deb 的 Depends。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
