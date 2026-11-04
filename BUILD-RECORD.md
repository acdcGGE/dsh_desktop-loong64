# 构建溯源记录（Build Record）

> 本文件记录本仓库某次实际构建的环境与产物，便于复现与发布核对。
> 由构建主机在构建完成后填写产物 SHA256；本仓库不提交 `dist/` 本身（见 `.gitignore`），
> 产物请作为 GitHub Release 资产分发。

## 构建环境

| 项 | 值 |
| --- | --- |
| 构建日期 | 2026-11-04 |
| 架构 / 系统 | LoongArch64（loong64）/ Linux，glibc 2.38 |
| 上游版本 | `dsh-v0.2.1-rc.5` |
| 上游 commit | `b830ec950f`（tag: `dsh-v0.2.1-rc.5`） |
| Electron dist | `darkyzhou/electron-loong64` **v43.7.7**（`process.versions.electron = 43.7.7`） |
| npm `electron` | 锁文件 `44.7.0`（仅版本推断；实际二进制 43.7.7） |
| Node 工具链 | loong64 Node 24 + pnpm 11（`toolchain/node`） |
| npm 镜像 | `https://registry.loongnix.cn:5873` |
| Node 头文件镜像 | `https://npmmirror.com/mirrors/node`（`NODEJS_ORG_MIRROR`，供 node-gyp 编 node-pty） |

## 适配与补丁

- 适配补丁：`dsh_desktop-loong64/patches/`（builder-util、node-addon-native-custom-loader 等），
  由 `apply-adaption.sh` 幂等施加。
- 原生系统包：`build-node-addon.sh` 产出
  `@deepseek-ai/node-addon-system-linux-loong64`（含静态 `landlock-run` + `system.node`），
  经 `verify-launcher-binary.mjs` 校验为合法 **EM_LOONGARCH (0x102)** ELF。

## 补齐的 loong64 原生绑定（来自 loongnix 镜像）

| 包 | 版本 | 说明 |
| --- | --- | --- |
| `@rolldown/binding-linux-loong64-gnu` | 1.1.1 | rolldown@1.1.1 原生绑定（构建必需） |
| `@rolldown/binding-linux-loong64-gnu` | 1.2.7 | rolldown@1.2.7 原生绑定（构建必需） |
| `lightningcss-linux-loong64-gnu` | 1.33.0 | lightningcss 原生绑定（构建必需） |

> 由 `install-loong64-bindings.sh` 在 `pnpm install` 之后自动补齐并校验 shasum。
> 上游 `optionalDependencies` 未声明 loong64，故普通 install 不会拉取，必须手动补齐。

## 构建阶段结果

| 阶段 | 结果 |
| --- | --- |
| `apply-adaption.sh` | ✅ |
| `build-node-addon.sh` | ✅（含 `file` 命令缺失容错） |
| `update-runtime-lock.sh` | ✅ 写入 `linux-loong64` |
| `pnpm install` | ✅ |
| `install-loong64-bindings.sh` | ✅ |
| `pnpm run build:lib` | ✅ |
| `pnpm run build:desktop` | ✅ |
| `check-runtime-libs.py` | ✅ 16 个 Python 系统库 apt 包均已安装 |
| `package-desktop.sh` | ✅ `linux-loong64-unpacked`（node-pty 经镜像下载头文件后编译通过） |
| `make-deb.sh` / `make-dist.sh` / `make-pkg.sh` | 见下方产物 |

## 原生 Python wheel（本机从源码重编）

4 个 loong64 wheel 由 `build-wheels.sh` 在构建机用独立 CPython 从源码编译（不再使用外来预编译
wheel），链接构建机自己的系统库。`lock.json` 的 `targets.linux-loong64.wheels` 已更新为
`file://` 本地路径 + 下列 sha256：

| wheel | sha256 |
| --- | --- |
| `numpy-2.3.5-cp312-cp312-linux_loongarch64.whl` | `58c6990dc25cf9e21a0ddffbaaecfbfcd8ed1bd3abe5d2fc0b7437816839f2ed` |
| `pandas-3.0.1-cp312-cp312-linux_loongarch64.whl` | `3c6dd60bee14cd426838ddb1f4e5ca34b11d21180955349ae6247416b6941ba0` |
| `Pillow-12.3.0-cp312-cp312-linux_loongarch64.whl` | `db11c7b6c162c9260a65a6e2d37e042608809d97f650a98131de6cc80dab4980` |
| `lxml-6.1.3-cp312-cp312-linux_loongarch64.whl` | `29e9df97ebd4fdb5ef51976ebc59044738ff6265b200880d70891dffc3681c7a` |

> 编译依赖：本机需 `gfortran` / `libxslt1-dev` / `libfreetype6-dev` / `libjpeg-dev` / `zlib1g-dev`
> / `libtiff-dev` / `libwebp-dev` / `libimagequant-dev` / `libraqm-dev` / `patchelf` / `ninja-build`；
> 构建隔离关闭，预装 `meson` `meson-python` `Cython` `versioneer` `pybind11`（见 `build-wheels.sh` 头部）。

## 产物（SHA256）

> 产物见 `dist/`，各文件 SHA256 见 `dist/SHA256SUMS`。

| 文件 | 大小 | SHA256 |
| --- | --- | --- |
| `deepseek-harness_0.2.1~rc.5-1_loong64.deb` | 329709022 B (≈314 MiB) | `222090083b952cb8a87f807fb02fc161e67c161c654f0adb1f1f68cfdc7d04f8` |
| `deepseek-harness-0.2.1-rc.5-linux-loong64.tar.gz` | 367853724 B (≈351 MiB) | `0a27a64c56f5e577d7d00dce2b0a89914d15929c316e06a9c6ed36191c159d83` |
| `deepseek-harness.desktop` | 288 B | `37557123e839fe7099495f4738dcac66478a2fcc5c555ca698f32632f56c43eb` |
| `install.sh` | 2035 B | `e0d73b2b9e3d140e64a83af9ee9c93a8b063f4b4f3890721a7cfe65cb3c7a2f7` |

> 本次 `.deb` 已反映**原生 wheel + 声明依赖**方案：`Installed-Size` 1080760 KB，
> `Depends` 写入 **31 个包**（15 个 Electron 运行时库 + 16 个 Python 系统库），
> 产物内 `python/lib/` 根部只有 `libpython3.12` / `libtcl*`，**无任何注入的 BLAS/XML 库**。
> 校验：包内 `numpy/_core/_multiarray_umath*.so` 的 NEEDED 为 `libblas.so.3`（对应 `Depends: libblas3`），
> `pandas/_libs/*.so` 不直链 BLAS。目标机 `dpkg -i` 后由 `apt` 自动补齐依赖；
> `.tar.gz` 安装路径需目标机手动 `apt install` 同名包（见 MISSING-RUNTIME-LIBS.md）。

## 避坑记录

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 打包阶段 `node-pty` 编译失败：`gyp ERR! ConnectTimeoutError` 下载 `node-v24.x-headers.tar.gz` | `prepare-dsh.ts` 把 `XDG_CACHE_HOME` 指向每次清空的构建临时目录，`node-gyp` 看不到 `~/.cache/node-gyp` 缓存；且 `npm_*` 环境变量被过滤；nodejs.org 不可达 | `build.sh` 导出 `NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node`（node-gyp 原生识别，未被过滤） |
| `make-deb.sh` 在构建机自身 `Depends` 为空 | Deepin 25 `/etc/os-release` 仅 `ID=deepin`，无 `ID_LIKE=debian`，原 grep 漏判 | 改 `is_deb_family` 按 dpkg 家族判定（debian/ubuntu/deepin/raspbian/devuan/kali） |
| pandas 构建 `generate_version.py --print` 失败 | `--no-build-isolation` 下 `versioneer` 未自动安装 | `build-wheels.sh` 预装 `versioneer`（及 meson/meson-python/Cython/pybind11） |


## 复现命令

```bash
cd dsh_desktop-loong64
# 1) 本机重编 4 个原生 wheel (若尚未)
./build-wheels.sh
# 2) 完整构建 + 打包 (会自动 check-runtime-libs 并声明 Depends)
DSH_SRC_TREE=../dsh DSH_DESKTOP_ELECTRON_DIST=../electron-loong64/electron-43.7.7 \
  ./build.sh
sha256sum dist/* > dist/SHA256SUMS
```
