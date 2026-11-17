# dsh_desktop-loong64

**DeepSeek Harness（dsh）桌面端的龙芯 LoongArch64（loong64）移植与构建工具包**

把官方 [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness) 桌面客户端适配到 **Linux / LoongArch64**，提供可复现的编译、打包与分发流程。

> 本仓库**只含构建脚本、补丁与文档**，不含上游源码（构建时从上游拉取，许可依上游 BSD-3-Clause）；本仓库脚本与文档为 MIT。构建产物（`.deb` / `.pkg.tar.zst` / `.tar.gz`）走 GitHub Release，不进 git。

## 为什么需要它

官方只发 x64 / arm64 产物，龙芯上要跑起来得处理三类差异：

1. **Electron 与 glibc**：官方 Electron 44.7.x 要求 glibc ≥ 2.42，龙芯发行版多为 2.38 → 改用 [`darkyzhou/electron-loong64`](https://github.com/darkyzhou/electron-loong64) 的 **v43.7.7**（仅需 ≥ 2.38）。
2. **原生绑定缺失**：`rolldown` / `lightningcss` / `oxc` 等包的 `optionalDependencies` 从未声明 loong64，`pnpm install` 不拉取，运行时 `require('...binding-linux-loong64-gnu')` 崩溃 → `install-loong64-bindings.sh` 从龙芯镜像 `registry.loongnix.cn:5873` 补齐。
3. **`file` 命令缺失导致假失败**（已修复）。

## 安装（下载 Release）

```bash
# Debian / Deepin / UOS
sudo apt install ./deepseek-harness_0.2.2.rc.3-1_loong64.deb
# Arch Linux（架构字段是 loong64，不是 loongarch64）
sudo pacman -U deepseek-harness-0.2.2_rc.3-1-loong64.pkg.tar.zst
```

GitHub 会把资产名里的 `~` 规范成 `.`，`SHA256SUMS` 按实际资产名生成，可直接 `sha256sum -c`。

**从旧版升级**：rc.1 `-2` 起已修复「升级后打不开」的 `postrm` 缺陷，**直接 `apt install` 新版即可，不要先卸载**。

## 环境要求

- 龙芯 LoongArch64，Linux，glibc ≥ 2.38（Loongnix / 统信 / 麒麟）
- Node **24**（≥ 24.9.0）+ **pnpm 11.28.5**，两者须在同一 PATH 前缀（`./setup-toolchain.sh` 负责组装）
- Electron 解压到 `electron-loong64/electron-43.7.7/`（用 `DSH_DESKTOP_ELECTRON_DIST` 指定）
- 龙芯 npm 镜像 `https://registry.loongnix.cn:5873`（脚本默认已设，`DSH_DESKTOP_NPM_REGISTRY` 可覆盖）
- 编译依赖：`gcc` / `make` / `python3` / `cargo`
- 运行时系统库：numpy/pandas/Pillow/lxml 四个 wheel 在构建机本机编译并链接系统库（不随 wheel 分发）。`.deb` 由 `Depends` 自动补齐，`.pkg.tar.zst` 写入对应 Arch 包名，`.tar.gz` 需手动安装（见 `MISSING-RUNTIME-LIBS.md`）
- 打包依赖：`.deb` 需 `dpkg-deb` + `fakeroot`；`.pkg.tar.zst` 需 `bsdtar` + `zstd`
- 可选：`gh`（`check/sync-upstream.sh` 用，缺失退化为 `curl`）、`file`

## 构建

目录约定（`<build-root>` 下同级放置）：

```
<build-root>/
├── dsh_desktop-loong64/   # 本仓库
├── dsh/                   # 上游源码工作树（默认 ../dsh，可用 DSH_SRC_TREE 覆盖）
├── toolchain/             # node(符号链接) / pnpm / node-v24 归档
└── electron-loong64/electron-43.7.7/
```

```bash
BUILD=$HOME/dsh-build && mkdir -p "$BUILD" && cd "$BUILD"

# 1) 本仓库
git clone <本仓库地址> dsh_desktop-loong64

# 2) 上游源码（取目标 tag）
git clone https://github.com/deepseek-ai/deepseek-harness.git dsh
cd dsh && git checkout dsh-v0.2.2-rc.3 && cd ..

# 3) 工具链
npm install --global pnpm@11.28.5 --prefix ./toolchain/pnpm \
  --registry https://registry.loongnix.cn:5873 --no-audit --no-fund
cd dsh_desktop-loong64 && ./setup-toolchain.sh && cd ..   # 幂等、不联网

# 4) 解压 Electron 43.7.7 到 electron-loong64/electron-43.7.7

# 5) 一键构建
cd dsh_desktop-loong64 && ./build.sh
```

`build.sh` 依次执行：打补丁 → 构建原生包 → 更新运行时锁 → `pnpm install` → 补齐 loong64 绑定 → `build:lib` → `build:desktop` → 校验运行时库 → 打包三件套。

分步排错时按同样顺序手工执行 `apply-adaption.sh --check`（只读预检）→ `apply-adaption.sh` → `build-node-addon.sh` → `update-runtime-lock.sh` → `pnpm install` → `install-loong64-bindings.sh` → `build:lib` → `build:desktop` → `package-desktop.sh` → `make-deb.sh` / `make-pkg.sh` / `make-dist.sh`。

> **顺序陷阱**：`pnpm install` 会按 lockfile 重建 `node_modules` 并剪除手动放入的绑定，因此 `install-loong64-bindings.sh` 必须在**每次 install 之后**运行。

## 产物

| 文件 | 说明 |
|---|---|
| `deepseek-harness_<ver>-1_loong64.deb` | Debian/统信/麒麟（`dpkg -i`） |
| `deepseek-harness-<ver>-1-loong64.pkg.tar.zst` | Arch 系（`pacman -U`） |
| `deepseek-harness-<ver>-linux-loong64.tar.gz` | 通用包，含 `install.sh` / `.desktop` / `SHA256SUMS` |

包内容同源：`/opt/deepseek-harness/`（`deepseek-harness` 启动器 + `deepseek-harness.bin`）、`/usr/bin/deepseek-harness`、`/usr/share/applications/*.desktop`、图标 PNG。

## 常见问题

- **`GLIBC_2.42 not found`**：误用官方 Electron 44.x，改用 43.7.7。
- **`binding-linux-loong64-gnu` 失败 / 构建中途崩溃**：绑定缺失，确认脚本在 `pnpm install` 之后跑，重跑即可。
- **`ImportError: libxxx.so.N`**：缺系统原生库，按 `MISSING-RUNTIME-LIBS.md` 装对应包。
- **`Failed to initialize Wayland platform`**：启动器默认 `--ozone-platform=x11`，可用 `DSH_DESKTOP_OZONE_PLATFORM=wayland|x11` 切换。
- **`ELECTRON_RUN_AS_NODE=1`**（部分 agent/IDE 沙箱会置位）会让 Electron 退化成 Node REPL，启动器已 `unset`。
- **无官方签名**：走 unsigned 路径（`DSH_DESKTOP_UNSIGNED=1`），仅限本地/内部分发。

## 跟踪上游

配置在 `upstream.conf`。上游以 `rc.N` / `alpha.N` 预发布节奏迭代，`releases/latest` 会返回空、按 tag 时间排序又会错序，故 `check-upstream.sh` 按**语义化版本号**取最大值：

```bash
./check-upstream.sh                 # 完整报告
./check-upstream.sh --quiet         # 仅在有更新时输出一行（适合 cron）
./check-upstream.sh --json          # 机器可读
./check-upstream.sh --sync          # 发现更新直接同步
```

退出码：`0` 已最新 / 无法判定，`10` 有更新。匿名 API 限流（60 次/小时，403）时可用 `gh api` 导出 fixtures 后离线跑 `--fixtures DIR`。

同步与预检：

```bash
./audit-patches.sh dsh-v0.2.2-rc.3 ../dsh          # 只读预检某 tag 的补丁兼容性
./sync-upstream.sh --apply --yes --with-tarball     # fetch → 预检 → checkout → 打补丁 → 构建 → 打包
./sync-upstream.sh --apply --from 5 --tag <tag> --yes   # 断点续跑（跳过 1–4 步）
```

`sync-upstream.sh` 在改动工作树之前，会对目标 tag 跑 `apply-adaption.sh --check`，上游重构导致锚点失配时带完整清单中止——按清单补候选锚点（`patch()` 支持多个 `(old, new)`）。它不会删除 `dist/` 下的历史包。

## 已验证构建

上游 `dsh-v0.2.2-rc.3`（`38a6a5c9`）· Electron `43.7.7`（npm 锁文件仍为 44.7.0，仅用于版本推断）· Node 24.14.0 + pnpm 11.28.5 · 宿主 glibc 2.38 · 产物 `build:lib`/`build:desktop`/deb/pkg 均通过，Python wheel 导入正常，主程序为合法 LoongArch ELF。详见 `BUILD-RECORD.md`。

## 参考

- 上游：https://github.com/deepseek-ai/deepseek-harness
- loong64 Electron：https://github.com/darkyzhou/electron-loong64
- 龙芯 npm 镜像：https://registry.loongnix.cn:5873
- loong64 Node：https://unofficial-builds.nodejs.org
