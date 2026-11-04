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
| `package-desktop.sh` | ✅ `linux-loong64-unpacked` |
| `make-deb.sh` / `make-dist.sh` / `make-pkg.sh` | 见下方产物 |

## 产物（SHA256）

> 构建于 2026-11-04 08:32，产物见 `dist/`，各文件 SHA256 见 `dist/SHA256SUMS`。

| 文件 | 大小 | SHA256 |
| --- | --- | --- |
| `deepseek-harness_0.2.1~rc.5-1_loong64.deb` | 364821482 B (≈348 MiB) | `0b64060f496c76b602a6e7e0eeba9186efd0786ed8b3d0e062ee09f9d61f1b0f` |
| `deepseek-harness-0.2.1-rc.5-linux-loong64.tar.gz` | 403924032 B (≈385 MiB) | `52ed184113fd8e3aae3e6df7090a3b6aaa35e37c9352a5fcaf8ce4dbe8422e4c` |
| `deepseek-harness.desktop` | 288 B | `37557123e839fe7099495f4738dcac66478a2fcc5c555ca698f32632f56c43eb` |
| `install.sh` | 2035 B | `e0d73b2b9e3d140e64a83af9ee9c93a8b063f4b4f3890721a7cfe65cb3c7a2f7` |

> 说明：Python 运行时所需的 libcblas / libxml2 等系统库已在打包时注入
> `linux-loong64-unpacked/resources/runtime/primary-runtime/dependencies/python/lib`，
> 故 `.deb` / `.tar.gz` 为完整自包含包，目标机无需额外安装 BLAS/XML 等依赖（见 MISSING-RUNTIME-LIBS.md）。

## 复现命令

```bash
cd dsh_desktop-loong64
DSH_SRC_TREE=../dsh DSH_DESKTOP_ELECTRON_DIST=../electron-loong64/electron-43.7.7 \
  ./build.sh
sha256sum dist/* > dist/SHA256SUMS
```
