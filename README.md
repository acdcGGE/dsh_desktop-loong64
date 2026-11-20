# dsh_desktop-loong64

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 桌面端适配到 **Linux / LoongArch64（loong64）** 的构建配方：可复现地打补丁、编译、打包成 `.deb` / `.pkg.tar.zst`。

本仓库只含脚本、补丁和文档，不含上游源码（构建时拉取）与构建产物（走 Release）。脚本与文档采用 MIT，上游代码许可依上游。

## 安装

```bash
# Debian / Deepin / UOS（GitHub 会把包名里的 ~ 规范成 .）
sudo apt install ./deepseek-harness_0.2.2.rc.5-1_loong64.deb
# Arch Linux
sudo pacman -U deepseek-harness-0.2.2_rc.5-1-loong64.pkg.tar.zst
```

从旧版升级**直接装新版即可，不要先卸载**（rc.1 -2 起已修复升级后打不开的 `postrm` 缺陷）。用 `sha256sum -c SHA256SUMS` 校验。

## 环境

- 龙芯 LoongArch64，glibc ≥ 2.38；`gcc` / `make` / python3 / cargo
- Node 24（≥ 24.9.0）+ pnpm 11.28.5，须在同一 PATH 前缀：`setup-toolchain.sh` 组装，缺件时自动联网拉取并缓存到 `toolchain/`
- Electron 43.7.7（`darkyzhou/electron-loong64`，官方 44.x 要 glibc 2.42 不可用）
- 龙芯 npm 镜像 `https://registry.loongnix.cn:5873`（脚本默认）
- 打包：`.deb` 需 `dpkg-deb` + `fakeroot`；`.pkg` 需 `bsdtar` + `zstd`

## 构建

同级目录布局：

```
<build-root>/
├── dsh_desktop-loong64/   # 本仓库
├── dsh/                   # 上游源码（默认 ../dsh，DSH_SRC_TREE 可覆盖）
├── toolchain/             # setup-toolchain.sh 生成
└── electron-loong64/electron-43.7.7/
```

```bash
git clone https://github.com/acdcGGE/dsh_desktop-loong64.git
git clone https://github.com/deepseek-ai/deepseek-harness.git dsh
cd dsh && git checkout dsh-v0.2.2-rc.5 && cd ..

cd dsh_desktop-loong64
./setup-toolchain.sh                 # Node 24 + pnpm 11，幂等
python3 prime-runtime-cache.py       # 预填 runtime 下载缓存，避免构建时联网超时
./build.sh                           # 全流程
```

关键脚本：

| 脚本 | 作用 |
|---|---|
| `build.sh` | 一键全流程（补丁 → 原生包 → 运行时锁 → install → 绑定 → 编译 → 打包） |
| `setup-toolchain.sh` | 组装 Node 24 + pnpm 11，缺件自动联网拉取 |
| `prime-runtime-cache.py` | 预填 SHA-256 下载缓存（本地产物 + 通用 wheel）；`--offline` 仅本地 |
| `prepare-electron-dist.py` | 从带应用残留的 Electron 目录生成纯净 dist，供 `DSH_DESKTOP_ELECTRON_DIST` 使用 |
| `sync-upstream.sh` | 跟踪上游、预检补丁、构建打包；`--from N` 断点续跑（1–7） |
| `check-upstream.sh` | 按语义化版本检查上游更新（`--quiet` / `--json` / `--sync`） |

两个顺序陷阱：`pnpm install` 会剪除手动补入的 loong64 绑定，故 `install-loong64-bindings.sh` 必须在每次 install 之后；Electron dist 必须是纯净运行时，混入旧 `app.asar` / `resources/runtime` 会导致 `python3` 符号链接 `EEXIST`。

## 产物

`dist/` 下生成 `.deb`、`.pkg.tar.zst`（可选 `--with-tarball` 生成 `.tar.gz`），安装到 `/opt/deepseek-harness/`，附 `SHA256SUMS`。

## 常见问题

- `GLIBC_2.42 not found` — 误用官方 Electron 44.x，改用 43.7.7。
- `binding-linux-loong64-gnu` 找不到 — 绑定被 `pnpm install` 剪掉，重跑 `install-loong64-bindings.sh`。
- `prepare-runtime` 卡 300 秒超时 — 下载缓存为空，先跑 `prime-runtime-cache.py`。
- `symlink python3.12 -> python3` EEXIST — Electron dist 混入旧 runtime，用 `prepare-electron-dist.py` 生成纯净副本。
- `ImportError: libxxx.so.N` — 缺系统原生库，见 `MISSING-RUNTIME-LIBS.md`。
- `ELECTRON_RUN_AS_NODE=1`（部分沙箱会置位）— 启动器已 `unset`。

未签名构建（`DSH_DESKTOP_UNSIGNED=1`），适合本地/内部分发。

## 已验证

上游 `dsh-v0.2.2-rc.5`（`9c2670d3bce5`）· Electron 43.7.7 · Node 24.14.0 + pnpm 11.28.5 · Python 3.12.15（numpy / pandas / Pillow / lxml loong64 原生 wheel）· glibc ≥ 2.38。deb / pkg 全流程 EXIT=0。历史记录见 `BUILD-RECORD.md`。

参考：[上游](https://github.com/deepseek-ai/deepseek-harness) · [loong64 Electron](https://github.com/darkyzhou/electron-loong64) · [龙芯 npm 镜像](https://registry.loongnix.cn:5873) · [loong64 Node](https://unofficial-builds.nodejs.org)
