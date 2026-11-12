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
| `deepseek-harness-0.2.1_rc.5-1-loongarch64.pkg.tar.zst` | 293270374 B (≈280 MiB) | `d45dd7c49cee41309a55c229bdc4d63ed430e7d6ab290c5799baa9235c9acc9a` |
| `deepseek-harness.desktop` | 288 B | `37557123e839fe7099495f4738dcac66478a2fcc5c555ca698f32632f56c43eb` |
| `install.sh` | 2035 B | `e0d73b2b9e3d140e64a83af9ee9c93a8b063f4b4f3890721a7cfe65cb3c7a2f7` |

> 本次 `.deb` 已反映**原生 wheel + 声明依赖**方案：`Installed-Size` 1080760 KB，
> `Depends` 写入 **31 个包**（15 个 Electron 运行时库 + 16 个 Python 系统库），
> 产物内 `python/lib/` 根部只有 `libpython3.12` / `libtcl*`，**无任何注入的 BLAS/XML 库**。
> 校验：包内 `numpy/_core/_multiarray_umath*.so` 的 NEEDED 为 `libblas.so.3`（对应 `Depends: libblas3`），
> `pandas/_libs/*.so` 不直链 BLAS。目标机 `dpkg -i` 后由 `apt` 自动补齐依赖；
> `.tar.gz` 安装路径需目标机手动 `apt install` 同名包（见 MISSING-RUNTIME-LIBS.md）。

### Arch 包（`pacman -U`）

同一份 `linux-loong64-unpacked` 由 `make-pkg.sh` 打成 `.pkg.tar.zst`，与 `.deb` 同源同版本，
仅依赖声明换成 **Arch 包名**（由同一份 SONAME 清单映射）：

| Debian/Deepin 包 | Arch 包 | 提供 |
| --- | --- | --- |
| `libblas3` | `blas` | `libblas.so.3`（并传递带入 `libgfortran`） |
| `liblapack3` | `lapack` | `liblapack.so.3` |
| `libxml2` | `libxml2` | `libxml2.so.2` |
| `libxslt1.1` | `libxslt` | `libxslt.so.1` + `libexslt.so.0` |
| `libfreetype6` | `freetype2` | `libfreetype.so.6` |
| `libjpeg62-turbo` | `libjpeg-turbo` | `libjpeg.so.62` |
| `libimagequant0` | `libimagequant` | `libimagequant.so.0` |
| `libraqm0` | `libraqm` | `libraqm.so.0` |
| `liblcms2-2` | `lcms2` | `liblcms2.so.2` |
| `libtiff6` | `libtiff` | `libtiff.so.6` |
| `libwebp7` / `libwebpdemux2` / `libwebpmux3` | `libwebp` | `libwebp.so.7` 等三个 |
| `libxcb1` | `libxcb` | `libxcb.so.1` |
| `zlib1g` | `zlib` | `libz.so.1` |

`.PKGINFO` 共 **28 个 `depend`**（15 个 Electron 运行时 + 13 个 Python 系统库）。
包结构校验：`zstd -t` 通过；`.PKGINFO` 为归档第一个成员、`.INSTALL` 第二；
`chrome-sandbox` 权限 `4755`；`/usr/bin/deepseek-harness` 符号链接、`.desktop`、图标齐全；
全包无组/其他可写条目；`python/lib/` 根部同样无注入库。
本机无 `pacman`，故未做安装实测（依赖名按 Arch 官方包名给出）。

## 避坑记录

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 打包阶段 `node-pty` 编译失败：`gyp ERR! ConnectTimeoutError` 下载 `node-v24.x-headers.tar.gz` | `prepare-dsh.ts` 把 `XDG_CACHE_HOME` 指向每次清空的构建临时目录，`node-gyp` 看不到 `~/.cache/node-gyp` 缓存；且 `npm_*` 环境变量被过滤；nodejs.org 不可达 | `build.sh` 导出 `NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node`（node-gyp 原生识别，未被过滤） |
| `make-deb.sh` 在构建机自身 `Depends` 为空 | Deepin 25 `/etc/os-release` 仅 `ID=deepin`，无 `ID_LIKE=debian`，原 grep 漏判 | 改 `is_deb_family` 按 dpkg 家族判定（debian/ubuntu/deepin/raspbian/devuan/kali） |
| pandas 构建 `generate_version.py --print` 失败 | `--no-build-isolation` 下 `versioneer` 未自动安装 | `build-wheels.sh` 预装 `versioneer`（及 meson/meson-python/Cython/pybind11） |
| `make-pkg.sh` 在非 Arch 宿主上秒退（无任何输出） | `CARCH=$(grep /etc/makepkg.conf … \| cut …)`：Deepin 上该文件不存在，`pipefail` 使 grep 的退出码 1 直接终止脚本 | 取值处加 `{ … \|\| true; }` 容错，缺失时回落 `uname -m` |
| Arch 包内目录 775 / 文件 664 | 构建宿主 umask 002，`cp -a` 保留了组可写位 | 在所有文件生成之后 `chmod -R a+rX,go-w`（位于 `.desktop`/图标/symlink 创建之后，`chrome-sandbox` 的 4755 不受影响） |


## 复现命令

```bash
cd dsh_desktop-loong64
# 1) 本机重编 4 个原生 wheel (若尚未)
./build-wheels.sh
# 2) 完整构建 + 打包 (会自动 check-runtime-libs, 产出 deb/pkg.tar.zst/tar.gz 三套)
DSH_SRC_TREE=../dsh DSH_DESKTOP_ELECTRON_DIST=../electron-loong64/electron-43.7.7 \
  ./build.sh
sha256sum dist/* > dist/SHA256SUMS
```

---

## 2026-11-05：全量重建 `dsh-v0.2.2-rc.1`

上游 tag `dsh-v0.2.2-rc.1`（commit `66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`，2026-11-04），
适配补丁已由 `apply-adaption.sh --check` 预检全部命中（P1–P32 全部「已适配」）。
执行 `./build.sh` 全量构建，最终 `BUILD_EXIT=0`，三种分发包全部产出。

### 产物

| 文件 | 字节 | SHA256 |
| --- | --- | --- |
| `deepseek-harness_0.2.2~rc.1-1_loong64.deb` | 334915828 | `a3f017a705fdb979e767628a4a4843027167a16f355d1437d98af3ed51ff1a55` |
| `deepseek-harness-0.2.2_rc.1-1-loongarch64.pkg.tar.zst` | 297624958 | `f64069e7606c2ee9e503fe637f8b128f1938016ad861a5c927d85777e06aee33` |
| `deepseek-harness-0.2.2-rc.1-linux-loong64.tar.gz` | 374187683 | `231223e8c82aec0f7888ca670ecda5bed26115def01731614d81400987fbe853` |

`dist/SHA256SUMS` 已由 `make-dist.sh` 重新生成（含 rc.5 与 rc.1 共 7 项），`sha256sum -c` 全部通过。
本次发布地址：<https://github.com/acdcGGE/dsh_desktop-loong64/releases/tag/v0.2.2-rc.1>
（Release 附带的 `SHA256SUMS` 只列本次上传的 6 个资产，与本地含历史版本的清单不同）。

### 校验结果

- `.deb`：`Version: 0.2.2~rc.1-1`、`Architecture: loong64`、`Installed-Size: 1110124 KB`，
  **Depends 31 项**（15 Electron + 16 Python 系统库）；`python/lib/` 根部仅
  `libpython3.12.so*` / `libpython3.so` / `libtcl9*.so`，**无注入的 BLAS/XML 库**；
  `postinst` 会把 `chrome-sandbox` 设为 `4755`。
- `.pkg.tar.zst`：`zstd -t` 通过；归档前两个成员为 `.PKGINFO`、`.INSTALL`；
  **28 个 `depend`**（Arch 包名）；`chrome-sandbox` 为 `4755`；无组/其他可写条目。
- `.tar.gz`：`gzip -t` 通过，顶层目录 `deepseek-harness-0.2.2-rc.1-linux-loong64/`。
- 主程序 ELF：`ELF64 / LoongArch / DOUBLE-FLOAT, OBJ-v1`；`version` 文件为 Electron `43.7.7`。
- 端到端（产物内 Python 3.12.15）：`numpy 2.3.5`（`a@a` 正常，NEEDED 为 `libblas.so.3`）、
  `pandas 3.0.1`、`pillow 12.3.0`、`lxml 6.1.3` 全部导入并计算通过。
- rc.1 新增的 `prunePnpmForeignNativePackages` 正常：运行时 pnpm 的
  `dist/node_modules/@reflink` 只保留 `reflink` + `reflink-linux-loong64-gnu`，外来平台绑定已裁剪。
- `check-runtime-libs.py`：`✓ 全部系统库依赖已在构建机安装`。

### 本次新增的避坑记录

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `./build.sh` 直接执行报「权限不够」(126) | 仓库中 `build.sh` 文件模式为 100644 | `chmod +x build.sh`（已提交 mode change 100644→100755） |
| `build:lib` 崩在 `rolldown@1.1.1`：`Cannot find native binding` | `install-loong64-bindings.sh` 用 `TMP/<包名>.tgz` 作下载目标，而 scoped 包名含 `/`（如 `@rolldown/binding-…`），子目录不存在使 `curl -o` 全部失败；只有无 scope 的两个包能装上 | 临时文件名扁平化 `re.sub(r"[^A-Za-z0-9._-]", "_", name)`；元数据 URL 改标准 `%40scope%2fname` 编码 |
| `prepare:runtime` 抛 `ENOENT: …/@reflink/@reflink/package.json` | 宿主包本身带 scope（`@reflink/reflink`、`@napi-rs/canvas`）时，脚本算出的 `node_modules` 少上提一级，绑定被装成 `@scope/@scope/<binding>` 双层目录；rc.1 新增的 prune 遍历该目录读不到 `package.json` 即抛错 | 当 `basename(parent_nm).startswith("@")` 时再 `dirname` 一级；清理错位目录后重装 |

rc.1 依赖中镜像确实没有的 5 个可选绑定（不影响本次构建与打包）：
`@trycua/cua-driver-linux-loong64-gnu@0.28.0`、`jscpd-linux-loong64-gnu@5.1.2`、
`@anthropic-ai/claude-agent-sdk-linux-loong64-gnu@0.3.263`、
`@oxc-resolver/binding-linux-loong64-gnu@11.20.0`（镜像仅 11.24.2）、
`@ubjs/node-linux-loong64-gnu@0.31.0-3`。

---

## 2026-11-05 修订 `-2`：修复「升级后必须卸载重装才能打开」

### 现象与现场证据

`/var/log/apt/history.log`：

```
2026-11-05 23:24:35  Upgrade: deepseek-harness:loong64 (0.2.1~rc.5-1, 0.2.2~rc.1-1)   # 升级后打不开
2026-11-05 23:30:15  Remove: deepseek-harness:loong64 (0.2.2~rc.1-1)
2026-11-05 23:30:34  Install: deepseek-harness:loong64 (0.2.2~rc.1-1)                # 卸载重装后恢复
```

### 根因

`-1` 的 `DEBIAN/postrm` 无条件执行 `rm -rf /opt/deepseek-harness`。
而 dpkg 升级时**在解包新文件之后**调用的是**旧包的 postrm `upgrade`**，
于是刚解包好的新版本被旧脚本整个删掉，只剩 `/usr/bin` 链接指向空目录。

用隔离 root（`dpkg --root=... --force-not-root --force-script-chrootless`）实测 dpkg 1.22.6 序列：

```
v1-postinst configure
v1-prerm   upgrade
v2-preinst upgrade
v1-postrm  upgrade      <- 旧包脚本, 在解包之后
v2-postinst configure
RESULT: TARGET-LOST     <- 新版文件被删
```

第二组实验在新 `preinst upgrade` 里就地中和旧 postrm：
`PATCHED-old-postrm arg=upgrade` / `RESULT: TARGET-SURVIVED`。
说明**只修新包的 postrm 不够**：存量用户升级时跑的是已落地的坏脚本，
必须同时由新 `preinst` 在解包前把它中和掉。

### 修复（`make-deb.sh`）

- `postrm` 严格按 `$1` 分派，只有 `remove|purge` 才删 `/opt/deepseek-harness`；
  `upgrade` / `failed-upgrade` / `abort-*` 一律不动。
- `prerm` 同样分派，只在 `remove|purge` 时删 `/usr/bin/deepseek-harness`，
  避免升级窗口期命令链接消失。
- 新增 `preinst`：在 `upgrade` 时若检测到已安装的 postrm 是
  「无条件 `rm -rf` 且无 `case "$1" in` 分派」版本，就地替换为安全版（幂等），
  使已装 `-1` 的用户**直接升级即可恢复，无需先卸载**。
- 版本号必须递增到 `-2`（Debian revision / Arch pkgrel），否则同版本安装不会
  替换 `/var/lib/dpkg/info` 里已落地的坏脚本。
- Arch 包 `.INSTALL` 的 `post_upgrade` 只做权限修复、不删目录，**不受此缺陷影响**；
  仅为与 deb 修订号对齐也重建为 `-2`。

### 修订版产物

| 文件 | 字节 | SHA256 |
| --- | --- | --- |
| `deepseek-harness_0.2.2~rc.1-2_loong64.deb` | 338098398 | `74d8dedfd9a04599ea2e34c69bfe07f137ffea57bed0c6b02ca870436041395d` |
| `deepseek-harness-0.2.2_rc.1-2-loongarch64.pkg.tar.zst` | 300145490 | `f811a3e9f6f79777028a8ecc4ac6654055fc0dd458b8991ec1c69c80a427534c` |
| `deepseek-harness-0.2.2-rc.1-linux-loong64.tar.gz` | 378229736 | `97cf6e6874584a221529baa946e0a82f8dcaf32cd846a7dc1b75661427a1eb67` |

### 验证

- deb：`Version 0.2.2~rc.1-2`，Depends 仍 31 项，控制文件含 `preinst/postinst/prerm/postrm`。
- Arch 包：`zstd -t` 通过，`pkgver 0.2.2_rc.1-2`，28 个 depend。
- tar.gz：`gzip -t` 通过；`dist/SHA256SUMS` 9 项 `sha256sum -c` 全部通过。
- 用**真实 deb 内提取的维护脚本**做路径重定向沙箱测试（不改真实 `/opt`）：
  - 从坏 `-1` 升级 → `SURVIVED`；
  - 正常卸载 → `CLEANED`；
  - 装好后再升级（幂等）→ `SURVIVED`。整体 `PASS`。
- 构建机无免密 sudo，未做本机真实 `dpkg -i` 升级实测；升级序列与修补效果由上述
  隔离 dpkg 实验 + 真实脚本沙箱测试覆盖。

### 存量用户升级方式

```bash
sudo apt install ./deepseek-harness_0.2.2~rc.1-2_loong64.deb
```

`preinst` 会自动中和旧的破坏性 `postrm`；**不要再先 `apt remove`**。
升级后可检查 `/opt/deepseek-harness/deepseek-harness.bin` 是否存在且可执行。

发布状态：`v0.2.2-rc.1` Release 的资产已由 `-1` **替换为 `-2`**（删除旧 deb/pkg，
覆盖同名 tar.gz 与 `SHA256SUMS`，并改写 Release 说明）；tag 与下载链接不变。
Release 附带的 `SHA256SUMS` 只列 `-2` 的 5 个资产，与本地 `dist/SHA256SUMS`（含历史版本）
不同。

---

## 2026-11-12：全量重建 `dsh-v0.2.2-rc.2`

上游 tag `dsh-v0.2.2-rc.2`（commit `ddac96760b6edf8fa0fe17cbdcf0b512f4c12b2c`，发布
2026-11-11），本地源码工作树重建于 `/home/yuri/文档/dsh`（浅克隆该 tag 后 `fetch --tags`）。
`sync-upstream.sh --apply --yes` 最终成功；deb/pkg 均产出，未产 tar.gz（默认包格式）。

### 本次配方修正（均已回写脚本）

| 脚本 | 改动 | 证据 |
| --- | --- | --- |
| `apply-adaption.sh` | P23 目标改为 `client-metadata.ts`（rc.2 把两个函数从 `index.ts` 拆出，函数体不变）；P29 在 rc.2 上游已删除独立 CLI 检查时跳过；新增 **P33** 把 `desktop-publish-targets.ts` 的 `targetSchema` 扩到 `linux-loong64` | rc.1/rc.2 干净 tarball 的 `--check` 均退出 0；P33 修复 `retain-desktop-ci.ts(39,40) TS2345` |
| `sync-upstream.sh` | `pnpm install` 后补 `install-loong64-bindings.sh`；`SHA256SUMS` 的 deb glob 由 `deepseek-harness-*.deb` 改为 `deepseek-harness_*.deb` | 首次生成的 `SHA256SUMS` 只有 pkg，漏掉 deb |
| `build-node-addon.sh` | `toolchain/node/bin` 不存在时不再让 `cd` 报错，沿用当前 PATH | 日志出现 `cd: .../toolchain/node/bin: 没有那个文件或目录` |
| `package-desktop.sh` | Node 路径支持 `DSH_NODE_BIN` 或回退到 `command -v node` | 原硬编码路径在本机不存在，步骤 9 直接失败 |
| `update-runtime-lock.sh` | 非空 `artifacts/node-loong64.tar.xz` 时以归档内顶层目录反推 `nodeVersion` 并计算 sha；同步写回锁顶层 `nodeVersion` | unofficial-builds 实测 300 s 仅收 3.2/30.7 MB；版本不同步导致 prepare 解压路径与 smoke 双重失败 |
| `make-pkg.sh` | `CARCH`/`PKG_ARCH` 为 `loongarch64` 时归一为 `loong64`，包名与 `.PKGINFO` 的 `arch` 同步修正 | 龙芯 `uname -m` 是 `loongarch64`，Arch loong64 端口用 `loong64`，旧包名 pacman 不识别 |

### 构建环境与运行时偏差

- 构建工具链：Node **24.14.0** loong64（复用本机已有二进制）+ pnpm **11.28.5**（npm 镜像
  `registry.loongnix.cn:5873`）；Electron `darkyzhou/electron-loong64` **v43.7.7**（其内嵌 Node 24.21.0）。
- primary-runtime 的 Node 归档改用本机 `node-v24.14.0-linux-loong64.tar.xz`，因此运行时
  `manifest.node = 24.14.0`（上游锁为 24.21.0，但该源在本机带宽不可用）。归档内容目录名与锁版本
  已对齐，smoke 检查通过。Python 仍为本机分叉 `3.12.15+20261021`，4 个 wheel 复用 pip 缓存，
  sha256 与上次记录一致。
- `check-runtime-libs.py` 未单独重跑（沿用上次已装齐的 31 个包）；打包阶段的
  `prepare:runtime` 完整 smoke 通过：Node/pnpm/Office 转换/插件安装/pty 全部 OK。

### 产物（`dist/SHA256SUMS` 2 项，`sha256sum -c` 全部通过）

| 文件 | 大小 | SHA256 |
| --- | --- | --- |
| `deepseek-harness_0.2.2~rc.2-1_loong64.deb` | 365 MiB | `46f42fbe529a49dd9463a8fdfa8e53a4640d22333a2fdbf8dab767ddfddb7afd` |
| `deepseek-harness-0.2.2_rc.2-1-loong64.pkg.tar.zst` | 324 MiB | `b7766bcfbd05708ffef854953ead17a51d78ca8f5c995748170c4948c8c565ec` |

校验：deb `Version: 0.2.2~rc.2-1`、`Architecture: loong64`、`Installed-Size: 1460096 KB`、
`Depends` 31 项，控制脚本含 `preinst/postinst/prerm/postrm`（升级修复版）；
pkg `zstd -t` 通过、`.PKGINFO` 28 个 `depend`、`arch = loong64`，归档首两项为
`.PKGINFO`/`.INSTALL`；unpacked 主程序为 LoongArch ELF。
本机免密 sudo 不可用，未做真实 `dpkg -i` 升级实测。

### 复现命令

```bash
export PATH=/path/to/node-v24.14.0-linux-loong64/bin:/path/to/pnpm/bin:$PATH
export DSH_DESKTOP_ELECTRON_DIST=/path/to/electron-43.7.7
export NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node
export npm_config_registry=https://registry.loongnix.cn:5873
cd dsh_desktop-loong64-main
./sync-upstream.sh --apply --tag dsh-v0.2.2-rc.2 --yes
```

> 若 upstream Node 归档仍不可达，先备好 `artifacts/node-loong64.tar.xz`（顶层目录须为
> `node-v<version>-linux-loong64`），`update-runtime-lock.sh` 会自动按归档内容写锁。
