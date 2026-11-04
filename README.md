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
- **运行时系统库（关键！）**：打包进最终包的 Python 运行时依赖若干 loong64 系统原生库（`libcblas` / `libblas` / `liblapack` / `libgfortran` / `libjpeg` / `libimagequant` / `libraqm` / `libxml2` / `libicu` 等），这些**不会随 wheel 分发**，必须先在构建机装好。这些 wheel 是在比 Deepin 25 更新的环境编译的，**部分库版本较新**（如 `libxml2.so.16` 需 libxml2 ≥ 2.14，Deepin 25 自带仅 2.12）。完整清单与 `apt install` 命令见 **[`MISSING-RUNTIME-LIBS.md`](./MISSING-RUNTIME-LIBS.md)**。装好后跑 `python3 resolve-runtime-libs.py` 会从 `/usr/lib` 取出并打包进最终产物（无需任何外部媒体盘）。
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

# 2) 准备上游源码 (取目标 tag, 例: dsh-v0.2.1-rc.5)
git clone https://github.com/deepseek-ai/deepseek-harness.git dsh
cd dsh && git checkout dsh-v0.2.1-rc.5 && cd ..

# 3) 准备 loong64 Node 工具链 -> toolchain/node
#    (从 https://unofficial-builds.nodejs.org 取 loong64 构建, 解压到 toolchain/node)

# 4) 准备 Electron 43.7.7 -> electron-loong64/electron-43.7.7
#    (从 https://github.com/darkyzhou/electron-loong64/releases 下载 linux-loong64 包解压)
```

### 5.2 一键构建（推荐）

```bash
cd dsh_desktop-loong64
./build.sh            # 默认构建 dsh-v0.2.1-rc.5 对应的源码状态
```

`build.sh` 会自动依次执行：应用适配补丁 → 构建原生系统包 → 更新运行时锁 → `pnpm install` → **补齐 loong64 原生绑定**（必须在 install 之后）→ `build:lib` → `build:desktop` → `package-desktop.sh` → `make-deb.sh` + `make-dist.sh`。

### 5.3 分步构建（便于排错）

```bash
cd dsh_desktop-loong64
./apply-adaption.sh            # 打 loong64 适配补丁 (幂等)
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
./make-dist.sh                 # dist/*.tar.gz (+ install.sh / .desktop / SHA256SUMS)
# ./make-pkg.sh                # 如需 Arch 包
```

> **顺序陷阱**：`pnpm install` 会依据 lockfile 重建 `node_modules`，把我手动放入的 loong64 绑定剪除。务必在每次 `pnpm install` **之后**再跑 `install-loong64-bindings.sh`。

---

## 6. 产物

构建完成后，`dist/` 下出现（命名随版本变化）：

| 文件 | 说明 |
| --- | --- |
| `deepseek-harness_<ver>-1_loong64.deb` | Debian/Ubuntu/统信/麒麟 安装包（`dpkg -i`） |
| `deepseek-harness-<ver>-1-loong64.pkg.tar.zst` | Arch 系安装包（`pacman -U`） |
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
- **`prepare:runtime` 冒烟测试报 `ImportError: libxxx.so.N: cannot open shared object file`**：Python 运行时缺系统原生库（典型如 `libcblas.so.3` / `libxml2.so.16`）。这是 numpy/Pillow/lxml 的 loong64 wheel 链接了构建机缺失的库。先按 [`MISSING-RUNTIME-LIBS.md`](./MISSING-RUNTIME-LIBS.md) 在构建机 `apt install` 对应包（注意版本约束），再跑 `python3 resolve-runtime-libs.py` 把库取出；脚本会把缺失项明确列出，未满足前不要继续打包。
- **`file` 命令缺失的"假失败"**：历史版本会在原生二进制其实编译成功时误报失败。已修复；若仍见，属信息展示行，可用 `verify-launcher-binary.mjs` 真校验。
- **`ELECTRON_RUN_AS_NODE` 陷阱**：若外部环境（部分 agent / IDE 沙箱）把它置为 `1`，Electron 会退化成纯 Node.js 弹 REPL 而非桌面应用。启动器会 `unset` 该变量规避。
- **显示后端**：部分 loong64 Chromium 默认选 Wayland 却连不上，报 `Failed to initialize Wayland platform`。启动器用 `--ozone-platform=x11` 显式指定 X11；可用 `DSH_DESKTOP_OZONE_PLATFORM=wayland|x11` 切换。
- **无官方签名**：本地构建走 unsigned 路径（`DSH_DESKTOP_UNSIGNED=1`），仅用于本地/内部分发。

---

## 8. 跟踪上游更新

配置集中在 `upstream.conf`（记录官方仓库、本地已验证版本/commit，由 `sync-upstream.sh --apply` 自动回写）。

```bash
./check-upstream.sh                 # 比对 GitHub 最新 tag 与本地版本
./sync-upstream.sh --apply --yes --with-tarball   # fetch → checkout → 打补丁 → 构建 → 打包 → 回写
./sync-upstream.sh --apply --tag dsh-v0.2.2      # 指定目标 tag
```

> `sync-upstream.sh` 改动的是上游源码工作树与构建产物，**不会删除 `dist/` 下的历史包**。

---

## 9. 发布到 GitHub（本仓库）

本仓库已配置 `.gitignore`，排除一切重产物：`dist/`、`artifacts/`、上游 `dsh/`、`toolchain/`、`electron-loong64/`、会话级临时脚本。因此仓库本身很轻，仅含构建"配方"。

```bash
# 在 dsh_desktop-loong64/ 内
git init
git add -A
git commit -m "feat: dsh desktop loong64 build kit (rc.5, electron 43.7.7)"

git remote add origin git@github.com:<你>/dsh_desktop-loong64.git
git push -u origin main
```

构建产物（`.deb` / `.pkg.tar.zst` / `.tar.gz`）请作为 **Release 资产** 上传，不要提交进 git：

```bash
gh release create v0.2.1-rc.5-loong64 --title "dsh 0.2.1-rc.5 (loong64)" dist/*
```

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
| 上游版本 | `dsh-v0.2.1-rc.5`（commit `b830ec9`） |
| Electron dist | `darkyzhou/electron-loong64` **v43.7.7**（进程内 `process.versions.electron = 43.7.7`） |
| npm `electron` | 锁文件 `44.7.0`（仅用于版本推断；实际二进制为 43.7.7） |
| Node 工具链 | loong64 Node 24 + pnpm 11 |
| 宿主机 | LoongArch64，glibc 2.38 |
| 补齐的 loong64 绑定 | `rolldown@1.1.1`、`rolldown@1.2.7`、`lightningcss@1.33.0`（源自 loongnix 镜像） |
| 验证 | `build:lib` ✅、`build:desktop` ✅；原生包经 `verify-launcher-binary.mjs` 校验为合法 EM_LOONGARCH ELF |

> 详见随仓库的 `BUILD-RECORD.md`（构建时间、环境、产物 SHA256 等）。
