# dsh loong64 运行时系统库依赖（声明式，非打包）

dsh 桌面端 Python 运行时（打包进最终 `.deb`/`.tar.gz`）依赖若干 **loong64 系统原生库**。
这些库由 4 个**本机从源码编译**的原生 wheel 在链接时写死 `NEEDED`，但**不会随 wheel 分发**。

## 关键变化：从「打包库」改为「声明依赖」

早期版本使用在更新环境里预编译的外来 wheel（链接 `libxml2.so.16` / `libicu78` /
`libcblas` 等 Deepin 25 没有的库），只能从媒体盘取出这些库再塞进 `.deb`。

现在 `build-wheels.sh` 在**构建机本机**用独立 CPython 从源码重编 4 个 wheel
（`numpy` / `pandas` / `Pillow` / `lxml`），它们链接的是**构建机自己的系统库**：
系统自带的 `libxml2.so.2`、`libblas.so.3`、`libjpeg.so.62` 等。只要构建机与目标机
是同一代 Debian/Deepin 基础（glibc 2.38，库 SONAME 一致），就**不再需要搬运任何库**，
改由 `.deb` 的 `Depends` 字段声明，目标机 `dpkg -i` 时由 apt 自动解析安装。

## 4 个原生 wheel 链接的系统库（按 `.so` → apt 包）

| 运行时需要的 `.so` | `Depends` 中声明的 apt 包 | 被谁需要 | 说明 |
|---|---|---|---|
| `libblas.so.3` | `libblas3` | numpy `_multiarray_umath` | 会自动带 `libgfortran5` |
| `liblapack.so.3` | `liblapack3` | numpy.linalg | |
| `libxml2.so.2` | `libxml2` | lxml / docx / pptx | 会自动带 ICU 传递依赖 |
| `libxslt.so.1` | `libxslt1.1` | lxml | |
| `libexslt.so.0` | `libxslt1.1` | lxml | 同上包 |
| `libfreetype.so.6` | `libfreetype6` | Pillow `_imagingft` | |
| `libjpeg.so.62` | `libjpeg62-turbo` | Pillow `_imaging` | |
| `libimagequant.so.0` | `libimagequant0` | Pillow 量化 | |
| `libraqm.so.0` | `libraqm0` | Pillow 文本排版 | |
| `liblcms2.so.2` | `liblcms2-2` | Pillow 色彩管理 | |
| `libtiff.so.6` | `libtiff6` | Pillow TIFF | |
| `libwebp.so.7` | `libwebp7` | Pillow WebP | |
| `libwebpdemux.so.2` | `libwebpdemux2` | Pillow WebP | |
| `libwebpmux.so.3` | `libwebpmux3` | Pillow WebP | |
| `libxcb.so.1` | `libxcb1` | Pillow X11 screen grab | |
| `libz.so.1` | `zlib1g` | Pillow（多数系统已带） | |

以上全部为**无版本号**的标准 Debian 包名，Deepin 25 / Debian trixie / Ubuntu 24.04
等均可直接 `apt install`。

> pandas 不直接链接 BLAS：它的 Cython 扩展只链 numpy 的 C API，所有线性代数经 numpy 完成；
> numpy 链接 `libblas.so.3`，因此 BLAS 依赖落在 numpy 上。

## 对最终产物的影响

- **`.deb`**：`make-deb.sh` 在构建机为 Debian/Ubuntu 系时，把上表 16 个包 + Electron 运行时
  库一起写进 `DEBIAN/control` 的 `Depends`。目标机 `sudo dpkg -i <deb>` 后 `apt-get install -f`
  即可补齐全部系统库，**无需再从媒体盘拷库**。
- **`.tar.gz`**（非 dpkg 分发）：无 `Depends` 机制，需目标机手动安装上表包后再解压运行：
  ```bash
  sudo apt-get install -y libblas3 liblapack3 libxml2 libxslt1.1 libfreetype6 \
    libjpeg62-turbo libimagequant0 libraqm0 liblcms2-2 libtiff6 libwebp7 \
    libwebpdemux2 libwebpmux3 libxcb1 zlib1g
  ```

## 构建机准备

构建机必须已安装上述包（否则 `prepare:runtime` 冒烟测试与运行时都会失败）。`build.sh` 会自动调用
`check-runtime-libs.py` 扫描 4 个 wheel 的 `.so` 依赖并校验这些包是否已装；缺任何一项会直接报错退出。

```bash
# 一次性装齐（含编译依赖，见 build-wheels.sh 头部说明）
sudo apt-get install -y gfortran libxslt1-dev libfreetype6-dev libjpeg-dev \
  zlib1g-dev libtiff-dev libwebp-dev libimagequant-dev libraqm-dev patchelf ninja-build
sudo apt-get install -y libblas3 liblapack3 libxml2 libxslt1.1 libfreetype6 \
  libjpeg62-turbo libimagequant0 libraqm0 liblcms2-2 libtiff6 libwebp7 \
  libwebpdemux2 libwebpmux3 libxcb1 zlib1g
```

## 排查命令

```bash
# 查看某 wheel 的 .so 到底需要哪些系统库
objdump -p /path/to/_multiarray_umath.cpython-312-loongarch64-linux-gnu.so | grep NEEDED

# 构建机是否已具备某库
ldconfig -p | grep -E 'libxml2|libblas|libjpeg'

# 重新校验依赖声明完整性
python3 check-runtime-libs.py
```
