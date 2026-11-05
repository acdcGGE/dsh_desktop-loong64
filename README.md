# dsh_desktop-loong64

**DeepSeek Harness（dsh）桌面端的龙芯 LoongArch64（loong64）移植与构建工具包**

本项目把官方的 [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness) 桌面客户端适配到 **Linux / LoongArch64（龙芯）** 平台，提供完整、可复现的本地编译、打包与分发流程。

> ⚠️ 本仓库**只包含构建/适配脚本、补丁与文档**，不包含上游应用源码。
> 应用源码由构建脚本在运行时从上游拉取（见下文），其许可证以[上游仓库](https://github.com/deepseek-ai/deepseek-harness)为准（上游声明 `BSD-3-Clause`）。本仓库脚本与文档以 MIT 许可发布（见 `LICENSE`）。

---

## 1. 这个仓库是什么 / 不是什么

| 是 | 不是 |
| --- | --- |
| loong64 构建脚本、补丁集、文档 | 上游应用源码的镜像 |
| 一套可复现的本地构建流程 | 官方签名/发布产物 |
| 对上游最小化的适配（可重复施加） | 对 dsh 业务逻辑的修改 |

构建产物（`.deb` / `.pkg.tar.zst` / `.tar.gz`）应作为 **GitHub Release 资产** 发布，**不要**提交进 git（已被 `.gitignore` 排除）。

**下载最新构建**：[Releases · v0.2.2-rc.1](https://github.com/acdcGGE/dsh_desktop-loong64/releases/tag/v0.2.2-rc.1)

```bash
# Debian / Deepin / UOS
sudo apt install ./deepseek-harness_0.2.2.rc.1-2_loong64.deb
# Arch Linux
sudo pacman -U deepseek-harness-0.2.2_rc.1-2-loongarch64.pkg.tar.zst
```

> GitHub 会把资产名中的 `~` 规范成 `.`，故下载到的 deb 名为 `0.2.2.rc.1-2`，与 `SHA256SUMS` 中的 `0.2.2~rc.1-2` 仅差这一个字符；包内容与版本号不受影响。

> **从旧版升级**：`-1`（及更早）的 deb 存在「升级后打不开、必须先卸载再安装」的缺陷，
> 根因是 `postrm` 在升级时误删安装目录。`-2` 已修复，且新增 `preinst` 会自动中和已安装的
> 旧脚本，**直接 `apt install` 新版即可，不要先卸载**。详见 `BUILD-RECORD.md`。

---

## 2. 为什么需要这个工具包（背景）

官方只发布 **x64 / arm64** 的预编译产物，完全没有 loong64 目标。要让它在龙芯上构建并真正跑起 GUI，需要处理一连串平台差异：

1. **Electron 版本与 glibc 兼容性**：官方 Electron 44.7.x 需要 **glibc ≥ 2.42**，而多数龙芯发行版（Loongnix / 统信 / 麒麟）目前是 glibc **2.38**。直接跑官方 Electron 会 `version 'GLIBC_2.42' not found`。
   → 改用 [`darkyzhou/electron-loong64`](https://github.com/darkyzhou/electron-loong64) 的 **v43.7.7**（loong64 移植，仅需 glibc ≥ 2.38）。
2. **npm 依赖里的 loong64 原生绑定缺失**：`rolldown`、`lightningcss`、`oxc` 等 Rust / NAPI 原生包，上游 `optionalDependencies` 只声明了 x64/arm64，**从未声明 loong64**，于是 `pnpm install` 不拉取、运行时 `require('@xxx/binding-linux-loong64-gnu')` 直接崩溃。
   → 龙芯官方镜像 `registry.loongnix.cn:5873` 已为这些包装好了 loong64 绑定，但上游没把它们写进 `optionalDependencies`。本仓库的 `install-loong64-bindings.sh` 会扫描 pnpm store、自动从 loongnix 补齐对应版本并校验 shasum。
3. **`file` 命令缺失导致假失败**：最小化系统往往没装 `file`，而 `build-node-addon.sh` 原本用 `set -euo pipefail` + `file ... | cut` 做信息展示，缺 `file` 会让管道非零退出、脚本在真正校验前误退。已修复为 `command -v file && ... || true`。
4. **npm electron 版本 vs 实际 dist 版本不一致**：lockfile 锁的是 `electron@44.7.0`，而你作为二进制 dist 用的是 `43.7.7`。这是有意为之——保留 npm 的 44.7.0（满足发布年龄豁免与某些原生插件指纹），仅用 43.7.7 作为实际打包二进制，并通过 `ELECTRON_SKIP_BINARY_DOWNLOAD=1` 阻止 postinstall 去下载并不存在的 44.x loong64 二进制。

---

## 3. 环境要求

- **架构 / 系统**：龙芯 LoongArch64（loong64）机器，Linux（glibc ≥ 2.38，建议 Loongnix / 统信 / 麒麟）。
- **Node 工具链（loong64）**：Node 24 + pnpm，置于构建根目录的 `toolchain/node/bin`（构建脚本会加入 `PATH`）。可从 <https://unofficial-builds.nodejs.org> 取 loong64 构建。
- **Electron 二进制**：[`darkyzhou/electron-loong64`](https://github.com/darkyzhou/electron-loong64) 的 **v43.7.7**，解压到 `electron-loong64/electron-43.7.7/`。通过 `DSH_DESKTOP_ELECTRON_DIST` 指定。
- **龙芯 npm 镜像**：`https://registry.loongnix.cn:5873`——loong64 平台原生包（含 rolldown/lightningcss 的 loong64 绑定）仅此源提供。脚本默认已设置，可用 `DSH_DESKTOP_NPM_REGISTRY` 覆盖。
- **编译依赖**：`gcc` / `make` / `python3` / `cargo`（部分原生模块用 node-gyp 编译）。
- **运行时系统库（关键！）**：4 个 Python 原生 wheel（`numpy` / `pandas` / `Pillow` / `lxml`）在**构建机本机从源码编译**（`build-wheels.sh`），链接的是构建机自己的系统库（`libblas3` / `liblapack3` / `libxml2` / `libxslt1.1` / `libfreetype6` / `libjpeg62-turbo` / `libimagequant0` / `libraqm0` / `liblcms2-2` / `libtiff6` / `libwebp7` / `libwebpdemux2` / `libwebpmux3` / `libxcb1` / `zlib1g`），这些**不会随 wheel 分发**。本仓库**不再搬运任何系统库**：`.deb` 由 `make-deb.sh` 把这些包写进 `Depends`，目标机 `dpkg -i` 后 `apt` 自动补齐；`.pkg.tar.zst` 由 `make-pkg.sh` 写入对应的 **Arch 包名**（`blas` / `lapack` / `libxml2` / `libxslt` / `freetype2` / `libjpeg-turbo` / `libimagequant` / `libraqm` / `lcms2` / `libtiff` / `libwebp` / `libxcb` / `zlib`），`pacman -U` 时会一并安装；`.tar.gz` 则需目标机手动 `apt install`（命令见 **[`MISSING-RUNTIME-LIBS.md`](./MISSING-RUNTIME-LIBS.md)**）。构建机需先装好这些包，`build.sh` 会调用 `check-runtime-libs.py` 校验。
- **打包依赖**：
  - `.deb`：`dpkg-deb` + `fakeroot`
  - `.pkg.tar.zst`：`bsdtar`（libarchive）+ `zstd`
  - `tar.gz`：无额外依赖
- **GitHub CLI `gh`**（仅 `check-upstream.sh` / `sync-upstream.sh` 需要，缺失时退化为 `curl`）。
- **建议安装 `file` 命令**：虽然脚本已容忍其缺失，但装上能让构建日志更完整。

---

## 4. 目录布局（构建根目录）

```
<build-root>/                 # 例如 /home/youruser/dsh-build
├── dsh_desktop-loong64/      # ★ 本仓库 (git clone 到这里)
├── dsh/                     # 上游源码工作树 (由 sync-upstream.sh / 手动 clone 得到, 不入本仓库)
├── toolchain/node/          # loong64 Node 24 + pnpm (自备, 不入本仓库)
└── electron-loong64/
    └── electron-43.7.7/     # darkyzhou/electron-loong64 解压目录 (自备, 不入本仓库)
```

> 适配脚本默认作用于**同级**的 `../dsh`。可用环境变量 `DSH_SRC_TREE` 覆盖。

---

## 5. 编译步骤（从零开始）

### 5.1 准备构建根与上游源码

```bash
BUILD=$HOME/dsh-build
mkdir -p "$BUILD" && cd "$BUILD"

# 1) 取本仓库
git clone <本仓库地址> dsh_desktop-loong64

# 2) 准备上游源码 (取目标 tag, 例: dsh-v0.2.2-rc.1)
git clone https://github.com/deepseek-ai/deepseek-harness.git dsh
cd dsh && git checkout dsh-v0.2.2-rc.1 && cd ..

# 3) 准备 loong64 Node 工具链 -> toolchain/node
#    (从 https://unofficial-builds.nodejs.org 取 loong64 构建, 解压到 toolchain/node)

# 4) 准备 Electron 43.7.7 -> electron-loong64/electron-43.7.7
#    (从 https://github.com/darkyzhou/electron-loong64/releases 下载 linux-loong64 包解压)
```

### 5.2 一键构建（推荐）

```bash
cd dsh_desktop-loong64
./build.sh            # 构建当前 ../dsh 工作树 (本次验证: dsh-v0.2.2-rc.1)
```

`build.sh` 会自动依次执行：应用适配补丁 → 构建原生系统包 → 更新运行时锁 → `pnpm install` → **补齐 loong64 原生绑定**（必须在 install 之后）→ `build:lib` → `build:desktop` → `check-runtime-libs.py` → `package-desktop.sh` → `make-deb.sh` + `make-pkg.sh` + `make-dist.sh`。

### 5.3 分步构建（便于排错）

```bash
cd dsh_desktop-loong64
./apply-adaption.sh --check     # 先只读预检补丁锚点 (不写文件, 失配退出 10)
./apply-adaption.sh             # 打 loong64 适配补丁 (幂等)
./build-node-addon.sh          # 构建 @deepseek-ai/node-addon-system-linux-loong64 + 静态 landlock
./update-runtime-lock.sh       # 写入 linux-loong64 运行时下载源与锁

cd ../dsh
pnpm install --no-frozen-lockfile
python3 ../dsh_desktop-loong64/install-loong64-bindings.sh   # ★ 关键: 必须在 install 之后
pnpm run build:lib
pnpm run build:desktop

cd ../dsh_desktop-loong64
./package-desktop.sh           # 产出 linux-loong64-unpacked
./make-deb.sh                  # dist/*.deb
./make-pkg.sh                  # dist/*.pkg.tar.zst (Arch 系, 需 bsdtar + zstd)
./make-dist.sh                 # dist/*.tar.gz (+ install.sh / .desktop / SHA256SUMS)
```

> **顺序陷阱**：`pnpm install` 会依据 lockfile 重建 `node_modules`，把我手动放入的 loong64 绑定剪除。务必在每次 `pnpm install` **之后**再跑 `install-loong64-bindings.sh`。

---

## 6. 产物

构建完成后，`dist/` 下出现（命名随版本变化）：

| 文件 | 说明 |
| --- | --- |
| `deepseek-harness_<ver>-1_loong64.deb` | Debian/Ubuntu/统信/麒麟 安装包（`dpkg -i`） |
| `deepseek-harness-<pkgver>-<pkgrel>-<carch>.pkg.tar.zst` | Arch 系安装包（`pacman -U`）。`pkgver` 中的 `-` 会转 `_`（如 `0.2.2_rc.1-1`）；`carch` 取自宿主的 `makepkg.conf` 或 `uname -m`，可用 `CARCH=... ./make-pkg.sh` 覆盖 |
| `deepseek-harness-<ver>-linux-loong64.tar.gz` | 通用分发包，含 `install.sh` / `.desktop` / `SHA256SUMS` |

包内容（三者同源，来自同一个 `linux-loong64-unpacked`）：

- `/opt/deepseek-harness/` — 应用本体（`deepseek-harness` 为启动器，`deepseek-harness.bin` 为真实 Electron 二进制）
- `/usr/bin/deepseek-harness` — 命令链接
- `/usr/share/applications/deepseek-harness.desktop` — 桌面入口
- `/usr/share/icons/hicolor/256x256/apps/deepseek-harness.png` — 图标

安装方式见各 `make-*.sh` 头部注释与上游文档；本地也可直接解压 `tar.gz` 后运行其中的 `deepseek-harness`（已内置龙芯环境自愈逻辑）。

---

## 7. 已知问题与排错

- **glibc 版本不符**：若误用官方 Electron 44.x，启动报 `version 'GLIBC_2.42' not found`。务必用 darkyzhou 的 43.7.7。
- **`require('@.../binding-linux-loong64-gnu')` 失败 / 构建中途崩溃**：几乎总是 loong64 原生绑定缺失。确认 `install-loong64-bindings.sh` 是在 `pnpm install` 之后运行的；重跑它即可。`install-loong64-bindings.sh` 会打印已装/缺失清单。
- **`prepare:runtime` 冒烟测试报 `ImportError: libxxx.so.N: cannot open shared object file`**：Python 运行时缺系统原生库。这是 numpy/Pillow/lxml 的 loong64 wheel 链接了构建机缺失的库。`build.sh` 会先跑 `check-runtime-libs.py` 扫描并列出缺的 apt 包，按 [`MISSING-RUNTIME-LIBS.md`](./MISSING-RUNTIME-LIBS.md) 在构建机 `apt install` 对应包即可（无需任何外部媒体盘）。
- **`file` 命令缺失的"假失败"**：历史版本会在原生二进制其实编译成功时误报失败。已修复；若仍见，属信息展示行，可用 `verify-launcher-binary.mjs` 真校验。
- **`ELECTRON_RUN_AS_NODE` 陷阱**：若外部环境（部分 agent / IDE 沙箱）把它置为 `1`，Electron 会退化成纯 Node.js 弹 REPL 而非桌面应用。启动器会 `unset` 该变量规避。
- **显示后端**：部分 loong64 Chromium 默认选 Wayland 却连不上，报 `Failed to initialize Wayland platform`。启动器用 `--ozone-platform=x11` 显式指定 X11；可用 `DSH_DESKTOP_OZONE_PLATFORM=wayland|x11` 切换。
- **无官方签名**：本地构建走 unsigned 路径（`DSH_DESKTOP_UNSIGNED=1`），仅用于本地/内部分发。

---

## 8. 跟踪上游更新（含 rc 预发布）

配置集中在 `upstream.conf`（记录官方仓库、本地已验证版本/commit，由 `sync-upstream.sh --apply` 自动回写）。

上游当前以**预发布**节奏迭代（`rc.N`、`alpha.N`），`releases/latest` 对这类版本返回空，按时间取 `tags[0]` 也会错序（`rc.10` 会比 `rc.6` 旧）。因此 `check-upstream.sh` 会：

- 同时拉 `releases`（含 pre-release）与 `tags`，按**语义化版本号**取最大值，`rc`/`alpha`/`beta`/`pre` 分别标注；
- 分别给出「上游最新（含预发布）」「上游最新 rc」「上游最新正式版」，并列出最近几个预发布；
- 与 `upstream.conf` 的 `LOCAL_VERSION` 比较，判定是否有更新；
- 回写 `LAST_CHECKED` / `LAST_UPSTREAM_VERSION` / `LAST_SEEN_RC`。

```bash
./check-upstream.sh                    # 完整报告（含本地 git 比对、参考仓库）
./check-upstream.sh --quiet            # 仅在有更新时输出一行 (适合 cron)
./check-upstream.sh --json             # 机器可读 JSON (含 latest/latest_kind/latest_rc/update)
./check-upstream.sh --sync             # 发现更新直接调 sync-upstream.sh --apply
./check-upstream.sh --fixtures DIR     # 离线调试: 从 DIR 读 releases.json / tags.json
```

**退出码**：`0` 已是最新 / 无法判定；`10` 上游有更新可用。便于在脚本里分支：

```bash
if ./check-upstream.sh --quiet; then echo "无更新"; else echo "有更新，准备同步"; fi
# 或每日定时：
# 0 9 * * * cd /path/to/dsh_desktop-loong64 && ./check-upstream.sh --quiet
```

```bash
./audit-patches.sh dsh-v0.2.2-rc.1 ../dsh   # 单独预检某个 tag 的补丁兼容性 (只读, 失配退出 1)
./sync-upstream.sh --apply --yes --with-tarball   # fetch → 预检 → checkout → 打补丁 → 构建 → 打包 → 回写
./sync-upstream.sh --apply --tag dsh-v0.2.2-rc.1 # 指定目标 tag
DSH_SYNC_PRECHECK_ONLY=1 ./sync-upstream.sh --apply --yes   # 只跑预检, 不碰工作树/不构建
```

> **上游升级必读**：`sync-upstream.sh` 在 `git fetch` 之后、`checkout`/`stash` 之前，
> 会把目标 tag 用 `git archive` 导出到临时目录并跑 `apply-adaption.sh --check`。
> 一旦上游重构了被打补丁的代码块（例如 rc.1 把 `desktopTargetPlatform` 改成查表、
> 把 `execute()` 改名为 `executePreparation()`），同步会**在动工作树之前**带着完整失配清单中止。
> 按清单给 `apply-adaption.sh` 对应补丁补一个候选锚点即可；`patch()` 支持
> `[(old, new), ...]`，同一补丁可同时兼容多个 tag。
> 手动验证：`./apply-adaption.sh --check <某个 tag 导出的源码目录>`（只读，退出码 10 表示失配）。
>
> `sync-upstream.sh` 改动的是上游源码工作树与构建产物，**不会删除 `dist/` 下的历史包**。

---



## 10. 参考

- 上游仓库：<https://github.com/deepseek-ai/deepseek-harness>
- loong64 Electron 移植：<https://github.com/darkyzhou/electron-loong64>
- 龙芯 npm 镜像：<https://registry.loongnix.cn:5873>
- loong64 Node 构建：<https://unofficial-builds.nodejs.org>
- 第三方移植参考（仅参考）：<https://github.com/Chen-Yuanmeng/dsh-loongarch-adaption>

---

## 11. 已验证构建记录（provenance）

| 项 | 值 |
| --- | --- |
| 上游版本 | `dsh-v0.2.2-rc.1`（commit `66491b0`） |
| Electron dist | `darkyzhou/electron-loong64` **v43.7.7**（进程内 `process.versions.electron = 43.7.7`） |
| npm `electron` | 锁文件 `44.7.0`（仅用于版本推断；实际二进制为 43.7.7） |
| Node 工具链 | loong64 Node 24 + pnpm 11 |
| 宿主机 | LoongArch64，glibc 2.38 |
| 补齐的 loong64 绑定 | `rolldown@1.1.1`、`rolldown@1.2.7`、`lightningcss@1.33.0`、`oxlint@1.81.0`、`reflink@0.1.19`、`canvas@1.0.8` 等（源自 loongnix 镜像） |
| 验证 | `build:lib` ✅、`build:desktop` ✅、三种分发包 ✅；产物内 Python 导入 numpy/pandas/Pillow/lxml ✅；主程序为合法 LoongArch ELF |

> 详见随仓库的 `BUILD-RECORD.md`（构建时间、环境、产物 SHA256 等）。
