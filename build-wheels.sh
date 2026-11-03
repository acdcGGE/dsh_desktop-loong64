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
# 下载源: 龙芯 devpi PyPI 镜像 (pypi.loongnix.cn, 国内 ~1MB/s, PyPI 直连仅 ~16kB/s);
# 镜像按需代理 PyPI, 含全部构建依赖。可用 PIP_INDEX_URL 覆盖。
# 幂等: 已存在的轮子自动跳过, 可中断后重跑。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$HERE/artifacts/python/bin/python3.12"
WHEEL_DIR="$HERE/artifacts/wheels"

export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.loongnix.cn/loongson/pypi/+simple/}"
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
  "$PYTHON" -m pip wheel --no-deps --wheel-dir "$WHEEL_DIR" "$@" "$spec"
}

echo "==> pip 源: $PIP_INDEX_URL"
echo "==> 升级 pip/setuptools/wheel"
"$PYTHON" -m pip install --quiet --upgrade pip setuptools wheel

build_wheel "numpy 2.3.5" "numpy==2.3.5"
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
