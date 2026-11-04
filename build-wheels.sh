#!/usr/bin/env bash
# =============================================================================
# build-wheels.sh —— 为 dsh primary-runtime 构建 loong64 原生 Python 轮子
#
# 使用 loong64 独立 CPython (artifacts/python) 从源码构建:
#   numpy 2.3.5 / pandas 3.0.1 / pillow 12.3.0 / lxml 6.1.3
# 产物: artifacts/wheels/*.whl  (cp312, loongarch64)
#
# 这些包在 npmjs/PyPI 均无 loongarch64 预编译轮子, 必须本机编译;
# 版本与 scripts/primary-runtime/lock.json 中的 pythonPackages 锁定一致。
#
# 下载源: 默认阿里云 PyPI 镜像 (mirrors.aliyun.com, 本机可达, PyPI 完整代理);
#   该镜像无 loong64 预编译轮子, 故仍走源码编译。备选可达镜像:
#   PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/simple/ 或华为云等。
#   官方 pypi.org 亦可用 (直连偶发超时)。龙芯 pypi.loongnix.cn 当前常不可达。
#
# 重要(loong64 专属): 这些包及构建依赖(patchelf/ninja/Cython)在 PyPI 无 loong64
#   预编译 wheel, 故脚本关闭了 pip 构建隔离(--no-build-isolation), 需本机先备好:
#   - apt: sudo apt-get install -y gfortran libxslt1-dev libfreetype6-dev libjpeg-dev \
#          zlib1g-dev libtiff-dev libwebp-dev libimagequant-dev libraqm-dev patchelf ninja-build
#          (gfortran 编 numpy/pandas 的 OpenBLAS; jpeg/zlib/tiff/webp/imagequant/raqm 为 pillow 编解码;
#           后两者为构建工具)
#   - pip(用独立 python): 预装 meson meson-python pyproject-metadata packaging tomli versioneer pybind11 Cython
#   否则构建隔离会尝试编译 patchelf/Cython 而失败。
#   (注: aliyun/ustc 等镜像已提供 Cython 的 loong64 wheel, 可直接装; 若所用镜像无,
#    则回退 `pip install --no-binary :all: Cython` 从源码编一次。)
# 幂等: 已存在的轮子自动跳过, 可中断后重跑。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$HERE/artifacts/python/bin/python3.12"
WHEEL_DIR="$HERE/artifacts/wheels"

# 把独立 python 的 bin 加进 PATH: Cython 入口(cython/cythonize)与可能的 pip 脚本
# 需可被构建子进程(numpy/pandas 的 meson)发现; ninja/patchelf 走系统 /usr/bin。
export PATH="$HERE/artifacts/python/bin:$PATH"

export PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
export PIP_DISABLE_PIP_VERSION_CHECK=1

[[ -x "$PYTHON" ]] || { echo "错误: 找不到 $PYTHON, 请先下载 loong64 CPython" >&2; exit 1; }
mkdir -p "$WHEEL_DIR"

# build_wheel <版本名> <包名==版本> [额外 pip 参数...]
build_wheel() {
  local label="$1" spec="$2"; shift 2
  local base
  base="$(echo "${spec%%==*}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]//g')"
  if ls "$WHEEL_DIR/${base}"-*.whl >/dev/null 2>&1; then
    echo "==> 跳过 $label (轮子已存在: $(ls "$WHEEL_DIR/${base}"-*.whl | xargs -n1 basename | tr '\n' ' '))"
    return 0
  fi
  echo "==> 构建 $label"
  # --no-build-isolation: loong64 缺 patchelf/ninja/Cython 等构建依赖的预编译 wheel,
  # 需本机预装 (meson/meson-python/pyproject-metadata/packaging/tomli 走 pip 纯 py wheel,
  # patchelf/ninja 走 apt, Cython 从源码编一次), 故关闭构建隔离、复用已装环境。
  "$PYTHON" -m pip wheel --no-deps --no-build-isolation --wheel-dir "$WHEEL_DIR" "$@" "$spec"
}

echo "==> pip 源: $PIP_INDEX_URL"
echo "==> 升级 pip/setuptools/wheel"
"$PYTHON" -m pip install --quiet --upgrade pip setuptools wheel
# 预装构建依赖(--no-build-isolation 下不会自动装):
#   meson/meson-python/pyproject-metadata/packaging/tomli(纯 py);
#   versioneer(pandas 版本探测); pybind11(pillow 构建); Cython 见下方(无 loong64 wheel)。
"$PYTHON" -m pip install --quiet --no-build-isolation \
  meson meson-python pyproject-metadata packaging tomli versioneer pybind11 Cython

build_wheel "numpy 2.3.5" "numpy==2.3.5"
# pandas 构建时需 import numpy 取头文件; --no-build-isolation 下不会自动装,
# 故先把刚编好的 numpy 轮子装入本机独立 python (仅构建期使用, 不影响产物)。
"$PYTHON" -m pip install --no-deps --no-build-isolation "$WHEEL_DIR"/numpy-*.whl
build_wheel "pillow 12.3.0" "pillow==12.3.0"
build_wheel "lxml 6.1.3" "lxml==6.1.3"
# pandas 构建需要 numpy 头文件, 通过 find-links 复用本机 numpy 轮子
PIP_FIND_LINKS="$WHEEL_DIR" build_wheel "pandas 3.0.1" "pandas==3.0.1"

echo
echo "==> 构建完成, 轮子清单:"
ls -la "$WHEEL_DIR"/*.whl
echo
echo "==> sha256 (用于 update-runtime-lock.sh):"
sha256sum "$WHEEL_DIR"/*.whl
