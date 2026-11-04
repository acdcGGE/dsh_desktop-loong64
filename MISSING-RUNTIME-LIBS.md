# dsh loong64 运行时缺失的系统库依赖

dsh 桌面端的 Python 运行时（打包进最终 `.deb`/`.tar.gz`）依赖若干 **loong64 系统原生库**，
这些库由 pip 上的 loong64 wheel（`numpy` / `Pillow` / `lxml` / `python-docx` / `python-pptx` 等）
在链接时写死了 `NEEDED`，但**不会随 wheel 一起分发**。构建机与目标机都必须提供它们。

> 重要：这些 wheel 是在**比 Deepin 25 更新的基础环境**里编译的，部分库版本较新。
> 下表中的「版本约束」一栏标明了最低版本要求，老发行版（如 Deepin 25 自带的 libxml2 2.12）
> 并不满足，需要更新源或 backports。

## 缺失依赖清单（按 `.so` 列出）

| 运行时需要的 `.so` | 应在新机器 `apt install` 的包 | 版本约束 / 说明 | 被谁需要 |
|---|---|---|---|
| `libcblas.so.3` | `libcblas3` | 同时需要 `libblas3` | numpy `_multiarray_umath` |
| `libblas.so.3` | `libblas3` | — | numpy（经 cblas） |
| `liblapack.so.3` | `liblapack3` | — | numpy.linalg |
| `libgfortran.so.5` | `libgfortran5` | — | blas/lapack 依赖 |
| `libjpeg.so.8` | `libjpeg-turbo8` | libjpeg-turbo **≥ 3.0**（提供 `libjpeg.so.8`）；旧发行版仅 `libjpeg.so.62` | Pillow `_imaging` |
| `libimagequant.so.0.4` | `libimagequant0` | — | Pillow 量化 |
| `libraqm.so.0` | `libraqm0` | — | Pillow `_imagingft`（文本排版） |
| `libxml2.so.16` | `libxml2 (>= 2.14)` | 提供 `libxml2.so.16`；Deepin 25 自带 2.12 仅 `libxml2.so.2` | lxml / docx / pptx |
| `libicuuc.so.78` | `libicu78` | ICU 78 | libxml2 依赖 |
| `libicudata.so.78` | `libicu78` | 同上包 | libxml2 依赖 |

## 在新构建机上准备依赖

```bash
# 1) 在 /etc/apt/sources.list 确保有提供上述版本的源（Debian trixie+ / Ubuntu 24.04+
#    或对应 backports）。Deepin 25 自带源版本偏旧，可能需额外源才能拿到 libxml2 2.14+。
sudo apt-get update
sudo apt-get install -y \
  libcblas3 libblas3 liblapack3 libgfortran5 \
  libjpeg-turbo8 libimagequant0 libraqm0 \
  libxml2 libicu78

# 2) 让脚本从系统目录取出并打包进最终产物
python3 resolve-runtime-libs.py
# 脚本会扫描打包用 python、把上述库复制到 blas-libs/，并报告是否仍有缺失。
```

## 对最终产物的影响

`finalize-rc5.sh` 会在 `package-desktop.sh` 产出 `linux-loong64-unpacked` 之后，
把 `blas-libs/` 全部拷进里面的 python runtime `lib/` 目录。该 python 二进制带
`RPATH [$ORIGIN/../lib]`，因此**最终 `.deb`/`.tar.gz` 自带这些库、到目标机开箱即用**，
不要求目标机再装 `libcblas3` / `libxml2` 等。

唯一例外：若某库在构建机上始终无法取得（脚本最后报告「未满足的前置依赖」），
则该库不会进入最终包，目标机运行时会报 `ImportError: libxxx.so.N: cannot open
shared object file`。务必在构建机上先 `apt install` 满足全部依赖。

## 排查命令

```bash
# 查看某个 wheel 的 .so 到底需要哪些系统库
readelf -d /path/to/_multiarray_umath.cpython-312-loongarch64-linux-gnu.so | grep NEEDED

# 系统是否已具备
ldconfig -p | grep -E 'libxml2|libcblas|libjpeg'
```
