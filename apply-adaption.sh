#!/usr/bin/env bash
# =============================================================================
# dsh_desktop-loong64 —— 把 deepseek-harness 官方仓库适配到 Linux LoongArch64
#
# 用法:  ./apply-adaption.sh [--check] [dsh 仓库路径]
#          --check   只读预检: 在内存里按顺序模拟全部补丁, 报告所有失配锚点,
#                    不写入任何文件、不创建 shim。失败退出码 10。
#                    sync-upstream.sh 会在 checkout 之前用它验证目标 tag。
#          默认路径: 同级的 dsh 目录
#
# 补丁清单:
#   P1  package.json (root)          移除 lefthook postinstall (无 loong64 二进制)
#   P2  pnpm-workspace.yaml          allowBuilds.lefthook -> false
#   P3  desktop-build-paths.mjs      SUPPORTED_TARGETS 增加 linux-loong64 + 平台判定
#   P4  package-target.ts            TARGETS 增加 linux-loong64 目标
#   P5  prepare-runtime.ts           loong64 使用系统 Electron (DSH_DESKTOP_ELECTRON_DIST)
#   P6  primary-runtime/prepare.ts   loong64 的 node/python 下载源与 arch 判定
#   P7  project-manager.ts           运行时项目注入 @vscode/ripgrep-linux-loong64 shim
#   P8  node-addon-system entry      可选依赖增加 linux-loong64 平台包
#
# 所有修改幂等: 每个补丁有独立 marker, 重复执行安全。
# 上游文件均以 "// loong64-adaption[Pn]" 注释标记。
#
# 上游跨版本兼容: patch() 的 old 允许传 [(old, new), ...] 候选列表。上游重构
# 代码块时, 把新旧两种写法都列为候选, 按顺序试第一个命中的, 因此同一份配方
# 可同时适配多个 tag (已验证 dsh-v0.2.1-rc.5 与 dsh-v0.2.2-rc.1)。
# 升级上游后先跑: ./apply-adaption.sh --check <目标 tag 导出的源码目录>
# =============================================================================
set -euo pipefail

CHECK_ONLY=0
REPO=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -*) echo "错误: 未知参数 $arg" >&2; exit 2 ;;
    *) REPO="$arg" ;;
  esac
done
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dsh}"
ADAPTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ADAPTION_CHECK="$CHECK_ONLY"

if [[ ! -f "$REPO/package.json" || ! -d "$REPO/apps/desktop" ]]; then
  echo "错误: $REPO 不是 deepseek-harness 仓库根目录" >&2
  exit 1
fi
echo "==> 适配仓库: $REPO$([[ "$CHECK_ONLY" == 1 ]] && echo '  (只读预检)')"

python3 - "$REPO" "$ADAPTION_DIR" <<'PYEOF'
import json, re, sys, os

repo = sys.argv[1]
adaption = sys.argv[2]

CHECK_ONLY = os.environ.get('ADAPTION_CHECK') == '1'
_mem = {}        # --check 模式: 内存文件视图, 让依赖前面补丁的锚点能被正确模拟
_failures = []   # --check 模式: 累积所有失配, 而不是遇到第一个就退出

def read(p):
    if CHECK_ONLY and p in _mem:
        return _mem[p]
    with open(os.path.join(repo, p), encoding='utf-8') as f:
        return f.read()
def write(p, s):
    if CHECK_ONLY:
        _mem[p] = s
    else:
        with open(os.path.join(repo, p), 'w', encoding='utf-8') as f:
            f.write(s)

def patch(pid, p, old, new=None, all_occurrences=False):
    """幂等替换。old 可以是字符串, 也可以是 [(old, new), ...] 候选列表:
    上游重构代码块时按顺序试每个候选, 命中的那个决定写入内容, 因此同一个补丁
    可同时兼容多个上游 tag (例如 rc.5 的三元写法与 rc.1 的查表写法)。

    all_occurrences=True —— 同一代码段在多处合法出现时全部替换; 此时 new 不含
    marker, 幂等性由 "new 已存在则跳过" 保证。
    """
    variants = [(old, new)] if isinstance(old, str) else list(old)
    marker = f'loong64-adaption[{pid}]'
    s = read(p)
    # new 已存在说明此前打过(部分补丁的目标文本不含 marker, 只能整体比对)
    if marker in s or any(n in s for _, n in variants):
        print(f"  [跳过] {p} [{pid}] 已适配")
        return
    counts = []
    for i, (o, n) in enumerate(variants, 1):
        cnt = s.count(o)
        ok = cnt >= 1 if all_occurrences else cnt == 1
        if ok:
            write(p, s.replace(o, n))
            tag = f"  [变体 {i}/{len(variants)}]" if len(variants) > 1 else ""
            extra = f" (共 {cnt} 处)" if all_occurrences else ""
            print(f"  [打补丁] {p} [{pid}]{extra}{tag}")
            return
        counts.append(cnt)
    msg = f"错误: {p} [{pid}] 的 {len(variants)} 个候选全部失配 (各出现 {counts} 次)"
    if CHECK_ONLY:
        _failures.append((pid, p, msg))
        print(f"  [失配] {p} [{pid}] 各候选出现次数 {counts}")
        return
    raise SystemExit(msg)

# ---------------------------------------------------------------- P1 根 package.json
print("P1 package.json: 移除 lefthook postinstall")
d = json.loads(read('package.json'))
changed = False
if 'postinstall' in d.get('scripts', {}):
    d['scripts'].pop('postinstall'); changed = True
if d.get('pnpm'):
    d.pop('pnpm'); changed = True
if changed:
    write('package.json', json.dumps(d, indent=2) + '\n')
    print("  [打补丁] package.json")
else:
    print("  [跳过] package.json 已适配")

# ---------------------------------------------------------------- P2 pnpm-workspace.yaml
print("P2 pnpm-workspace.yaml: allowBuilds.lefthook = false")
s = read('pnpm-workspace.yaml')
if 'loong64-adaption[P2]' in s or re.search(r'^  lefthook: false', s, re.M):
    print("  [跳过] pnpm-workspace.yaml 已适配")
elif '  lefthook: true' in s:
    write('pnpm-workspace.yaml', s.replace('  lefthook: true', '  lefthook: false  # loong64-adaption[P2]: lefthook 无 loong64 二进制'))
    print("  [打补丁] pnpm-workspace.yaml")
else:
    print("  [警告] pnpm-workspace.yaml 中未找到 lefthook: true, 请手动确认")

# ---------------------------------------------------------------- P3 desktop-build-paths.mjs
print("P3 desktop-build-paths.mjs: 增加 linux-loong64 target")
patch('P3a', 'apps/desktop/scripts/desktop-build-paths.mjs',
"""const SUPPORTED_TARGETS = new Set(['mac-arm64', 'mac-x64', 'win-x64'])""",
"""const SUPPORTED_TARGETS = new Set(['mac-arm64', 'mac-x64', 'win-x64', 'linux-loong64'])  // loong64-adaption[P3a]: 新增龙芯目标""")

patch('P3b', 'apps/desktop/scripts/desktop-build-paths.mjs', [
  # 上游 rc.5: 三元表达式直接 return
  ("""export function desktopTargetPlatform(target) {
  assertSupportedTarget(target)
  return {
    platform: /** @type {'darwin' | 'win32'} */ (target === 'win-x64' ? 'win32' : 'darwin'),
    arch: /** @type {'arm64' | 'x64'} */ (target === 'mac-arm64' ? 'arm64' : 'x64'),
  }
}""",
   """export function desktopTargetPlatform(target) {
  assertSupportedTarget(target)
  // loong64-adaption[P3b]: Linux LoongArch64 目标
  if (target === 'linux-loong64') {
    return {
      platform: /** @type {'linux'} */ ('linux'),
      arch: /** @type {'loong64'} */ ('loong64'),
    }
  }
  return {
    platform: /** @type {'darwin' | 'win32'} */ (target === 'win-x64' ? 'win32' : 'darwin'),
    arch: /** @type {'arm64' | 'x64'} */ (target === 'mac-arm64' ? 'arm64' : 'x64'),
  }
}"""),
  # 上游 rc.1: 改成 targets 查表对象; 不登记 loong64 会静默返回 undefined
  ("""    'win-x64': { platform: 'win32', arch: 'x64' },
  })
  return targets[target]""",
   """    'win-x64': { platform: 'win32', arch: 'x64' },
    'linux-loong64': { platform: 'linux', arch: 'loong64' },  // loong64-adaption[P3b]
  })
  return targets[target]"""),
])

# ---------------------------------------------------------------- P4 package-target.ts
print("P4 package-target.ts: TARGETS 增加 linux-loong64")
patch('P4a', 'apps/desktop/scripts/package-target.ts',
"""export type DesktopPackageTargetName = 'mac-arm64' | 'mac-x64' | 'win-x64'""",
"""export type DesktopPackageTargetName = 'mac-arm64' | 'mac-x64' | 'win-x64' | 'linux-loong64'  // loong64-adaption[P4a]""")

patch('P4b', 'apps/desktop/scripts/package-target.ts',
"""  readonly platform: 'darwin' | 'win32'
  readonly arch: 'arm64' | 'x64'
  readonly builderPlatform: '--mac' | '--win'
  readonly builderArch: '--arm64' | '--x64'
}""",
"""  readonly platform: 'darwin' | 'win32' | 'linux'  // loong64-adaption[P4b]
  readonly arch: 'arm64' | 'x64' | 'loong64'
  readonly builderPlatform: '--mac' | '--win' | '--linux'
  readonly builderArch: '--arm64' | '--x64' | '--loong64' | ''  // loong64-adaption[P30]: 空串表示交给 process.arch
}""")

patch('P4c', 'apps/desktop/scripts/package-target.ts',
"""  'win-x64': {
    name: 'win-x64',
    platform: 'win32',
    arch: 'x64',
    builderPlatform: '--win',
    builderArch: '--x64',
  },
}""",
"""  'win-x64': {
    name: 'win-x64',
    platform: 'win32',
    arch: 'x64',
    builderPlatform: '--win',
    builderArch: '--x64',
  },
  // loong64-adaption[P4c]: Linux LoongArch64 (Arch Linux Ports / Loongnix)
  'linux-loong64': {
    name: 'linux-loong64',
    platform: 'linux',
    arch: 'loong64',
    builderPlatform: '--linux',
    builderArch: '--loong64',
  },
}""")

# ---------------------------------------------------------------- P5 prepare-runtime.ts
print("P5 prepare-runtime.ts: loong64 复用系统 Electron 发行版")
patch('P5', 'apps/desktop/scripts/prepare-runtime.ts',
"""/** Extract the target Electron distribution and return its embedded Node version. */
async function prepareElectron({ platform, arch }: DesktopTarget): Promise<string> {
  const require = createRequire(import.meta.url)
  const { version } = require('electron/package.json') as { version: string }
  const archive = await packagingStep(process.env.DSH_DESKTOP_PACKAGING_RUN_DIR, 'download:electron',
    () => downloadArtifact({ version, platform, arch, artifactName: 'electron', cacheRoot: BUILD_PATHS.downloads }))
  rmSync(BUILD_PATHS.electron, { recursive: true, force: true })
  await packagingStep(process.env.DSH_DESKTOP_PACKAGING_RUN_DIR, 'extract:electron', () => extractZip(archive, { dir: BUILD_PATHS.electron }))
  const executable = join(BUILD_PATHS.electron, platform === 'win32' ? 'electron.exe' : 'Electron.app/Contents/MacOS/Electron')
  return execFileSync(executable, ['-p', 'process.versions.node'], {
    encoding: 'utf8', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  }).trim()
}""",
"""/**
 * Extract the target Electron distribution and return its embedded Node version.
 * loong64-adaption[P5]: Electron 官方不发布 linux-loong64 构建, 因此 loong64 目标
 * 通过 DSH_DESKTOP_ELECTRON_DIST 复用系统发行版(如 Arch Linux Ports 的
 * /usr/lib/electron44), 跳过 @electron/get 下载。
 */
async function prepareElectron({ platform, arch }: DesktopTarget): Promise<string> {
  const require = createRequire(import.meta.url)
  const { version } = require('electron/package.json') as { version: string }
  const systemDist = process.env.DSH_DESKTOP_ELECTRON_DIST
  if (platform === 'linux' && arch === 'loong64' && systemDist !== undefined && systemDist !== '') {
    rmSync(BUILD_PATHS.electron, { recursive: true, force: true })
    await packagingStep(process.env.DSH_DESKTOP_PACKAGING_RUN_DIR, 'copy:electron',
      () => cpSync(systemDist, BUILD_PATHS.electron, { recursive: true }))
    const copied = join(BUILD_PATHS.electron, 'electron')
    return execFileSync(copied, ['-p', 'process.versions.node'], {
      encoding: 'utf8', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
    }).trim()
  }
  const archive = await packagingStep(process.env.DSH_DESKTOP_PACKAGING_RUN_DIR, 'download:electron',
    () => downloadArtifact({ version, platform, arch, artifactName: 'electron', cacheRoot: BUILD_PATHS.downloads }))
  rmSync(BUILD_PATHS.electron, { recursive: true, force: true })
  await packagingStep(process.env.DSH_DESKTOP_PACKAGING_RUN_DIR, 'extract:electron', () => extractZip(archive, { dir: BUILD_PATHS.electron }))
  const executable = join(BUILD_PATHS.electron, platform === 'win32' ? 'electron.exe'
    : platform === 'linux' ? 'electron'  // loong64-adaption[P5]: Linux 可执行文件在发行版根目录
    : 'Electron.app/Contents/MacOS/Electron')
  return execFileSync(executable, ['-p', 'process.versions.node'], {
    encoding: 'utf8', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  }).trim()
}""")

# ---------------------------------------------------------------- P6 primary-runtime/prepare.ts
print("P6 primary-runtime/prepare.ts: loong64 的 node/python 源与 arch 判定")
patch('P6a', 'scripts/primary-runtime/prepare.ts',
"""  const artifact = lock.targets[target]
  const filename = `node-v${lock.nodeVersion}-${artifact.nodeArchive}`
  const archive = await downloadPrimaryRuntimeAsset(`https://nodejs.org/dist/v${lock.nodeVersion}/${filename}`, artifact.nodeSha256, cache)""",
"""  const artifact = lock.targets[target]
  const filename = `node-v${lock.nodeVersion}-${artifact.nodeArchive}`
  // loong64-adaption[P6a]: nodejs.org 不发布 loong64, 改用 unofficial-builds.nodejs.org
  const nodeBase = target === 'linux-loong64'
    ? 'https://unofficial-builds.nodejs.org/download/release'
    : 'https://nodejs.org/dist'
  const archive = await downloadPrimaryRuntimeAsset(`${nodeBase}/v${lock.nodeVersion}/${filename}`, artifact.nodeSha256, cache)""")

patch('P6b', 'scripts/primary-runtime/prepare.ts',
"""    const source = join(staging, filename.replace(/\\.(?:zip|tar\\.gz)$/u, ''))""",
"""    const source = join(staging, filename.replace(/\\.(?:zip|tar\\.gz|tar\\.xz)$/u, ''))  // loong64-adaption[P6b]: unofficial 源为 .tar.xz""")

patch('P6c', 'scripts/primary-runtime/prepare.ts',
"""async function pythonArchive(target: keyof typeof lock.targets, cache: string): Promise<string> {
  const artifact = lock.targets[target]
  const filename = `cpython-${lock.pythonVersion}+${lock.pythonRelease}-${artifact.pythonTarget}-install_only_stripped.tar.gz`
  return downloadPrimaryRuntimeAsset(`https://github.com/astral-sh/python-build-standalone/releases/download/${lock.pythonRelease}/${encodeURIComponent(filename)}`, artifact.pythonSha256, cache)
}""",
"""async function pythonArchive(target: keyof typeof lock.targets, cache: string): Promise<string> {
  // loong64-adaption[P6c]: astral-sh 官方发布不含 loongarch64; loong64 组织分叉提供,
  // 且其版本/发布号可与全局锁定不同(按 target 覆盖; union 类型上需断言可选字段)
  const artifact = lock.targets[target] as (typeof lock.targets)[keyof typeof lock.targets] & {
    pythonVersion?: string
    pythonRelease?: string
    pythonBaseUrl?: string
  }
  const pythonVersion = artifact.pythonVersion ?? lock.pythonVersion
  const pythonRelease = artifact.pythonRelease ?? lock.pythonRelease
  const pythonBase = artifact.pythonBaseUrl ?? 'https://github.com/astral-sh/python-build-standalone/releases/download'
  const filename = `cpython-${pythonVersion}+${pythonRelease}-${artifact.pythonTarget}-install_only_stripped.tar.gz`
  return downloadPrimaryRuntimeAsset(`${pythonBase}/${pythonRelease}/${encodeURIComponent(filename)}`, artifact.pythonSha256, cache)
}""")

patch('P6d', 'scripts/primary-runtime/prepare.ts', [
  # 上游 rc.5: 写进对象的 platform/arch 属性 (带逗号)
  ("""      platform: target === 'win-x64' ? 'win32' : target.startsWith('linux-') ? 'linux' : 'darwin',
      arch: target.endsWith('-arm64') ? 'arm64' : 'x64',""",
   """      platform: target === 'win-x64' ? 'win32' : target.startsWith('linux-') ? 'linux' : 'darwin',
      // loong64-adaption[P6d]: 增加 loong64 架构判定
      arch: target.endsWith('-arm64') ? 'arm64' : target.endsWith('-loong64') ? 'loong64' : 'x64',"""),
  # 上游 rc.1: 改成两个 const 局部变量
  ("""    const platform = target === 'win-x64' ? 'win32' : target.startsWith('linux-') ? 'linux' : 'darwin'
    const arch = target.endsWith('-arm64') ? 'arm64' : 'x64'""",
   """    const platform = target === 'win-x64' ? 'win32' : target.startsWith('linux-') ? 'linux' : 'darwin'
    // loong64-adaption[P6d]: 增加 loong64 架构判定
    const arch = target.endsWith('-arm64') ? 'arm64' : target.endsWith('-loong64') ? 'loong64' : 'x64'"""),
])

# ---------------------------------------------------------------- P7 project-manager.ts (ripgrep shim)
print("P7 project-manager.ts: 注入 @vscode/ripgrep-linux-loong64 shim")
patch('P7a', 'apps/desktop/src/project-manager.ts',
"""const PROJECT_NAME = '@deepseek-ai/dsh-desktop-runtime'""",
"""const PROJECT_NAME = '@deepseek-ai/dsh-desktop-runtime'
// loong64-adaption[P7a]: @vscode/ripgrep 不发布 linux-loong64 平台包, 用本地 shim
// (bin/rg 来自系统 ripgrep) 补齐; 路径可用 DSH_LOONG64_RIPGREP_SHIM 覆盖
const RIPGREP_LOONG64_SHIM = process.env.DSH_LOONG64_RIPGREP_SHIM
  ?? 'ADAptionDirPlaceholder/shims/@vscode+ripgrep-linux-loong64'""".replace('ADAptionDirPlaceholder', adaption))

patch('P7b', 'apps/desktop/src/project-manager.ts',
"""  const manifest = {
    name: PROJECT_NAME,
    private: true,
    version: '0.0.0',
    dependencies: desktopCorePackageOverrides(packageSet),
    dsh: { profile: { bundles: [...WEB_PROFILE.bundles] } },
  }
  writeJson(join(projectDir, 'package.json'), manifest)""",
"""  const manifest = {
    name: PROJECT_NAME,
    private: true,
    version: '0.0.0',
    dependencies: {
      ...desktopCorePackageOverrides(packageSet),
      // loong64-adaption[P7b]: linux-loong64 目标注入 ripgrep shim
      ...(process.env.DSH_DESKTOP_TARGET_PLATFORM === 'linux' && process.env.DSH_DESKTOP_TARGET_ARCH === 'loong64'
        ? { '@vscode/ripgrep-linux-loong64': `file:${RIPGREP_LOONG64_SHIM}` }
        : {}),
    },
    dsh: { profile: { bundles: [...WEB_PROFILE.bundles] } },
  }
  writeJson(join(projectDir, 'package.json'), manifest)""")

# ---------------------------------------------------------------- P8 node-addon-system entry
print("P8 node-addon-system entry: 可选依赖增加 linux-loong64 平台包")
d8 = json.loads(read('native/system/packages/entry/package.json'))
opt8 = d8.get('optionalDependencies', {})
if '@deepseek-ai/node-addon-system-linux-loong64' in opt8:
    print("  [跳过] native/system/packages/entry/package.json [P8] 已适配")
else:
    opt8['@deepseek-ai/node-addon-system-linux-loong64'] = 'workspace:~'
    d8['optionalDependencies'] = opt8
    write('native/system/packages/entry/package.json', json.dumps(d8, indent=2) + '\n')
    print("  [打补丁] native/system/packages/entry/package.json [P8]")

# ---------------------------------------------------------------- P9 repo.mjs E_MACHINE
print("P9 native/system repo.mjs: E_MACHINE 增加 loong64 (EM_LOONGARCH=258)")
patch('P9', 'native/system/scripts/repo.mjs',
"""const E_MACHINE = { x64: 62, arm64: 183 };""",
"""const E_MACHINE = { x64: 62, arm64: 183, loong64: 258 };  // loong64-adaption[P9]: EM_LOONGARCH=258""")

# ---------------------------------------------------------------- P10 build.ts musl-gcc 回退
print("P10 native/system build.ts: musl-gcc 缺失时回退 cc -static")
patch('P10', 'native/system/scripts/build.ts',
"""    if (binary.kind === 'static-musl' && process.platform === 'linux' && binary.tool === 'landlock-run') {
      compiler = 'musl-gcc'
      flags = ['-std=c11', '-Os', '-Wall', '-Wextra', '-Werror', '-static', '-s']""",
"""    if (binary.kind === 'static-musl' && process.platform === 'linux' && binary.tool === 'landlock-run') {
      // loong64-adaption[P10]: Arch 等发行版无 musl-gcc 时回退 cc -static (静态 glibc 同样可执行)
      const hasMuslGcc = existsSync('/usr/bin/musl-gcc') || existsSync('/usr/local/bin/musl-gcc')
      compiler = hasMuslGcc ? 'musl-gcc' : 'cc'
      flags = ['-std=c11', '-Os', '-Wall', '-Wextra', '-Werror', '-static', '-s']""")

# ---------------------------------------------------------------- P11 package-target.ts 打包 loong64 平台包
print("P11 package-target.ts: 将 loong64 平台包一并打包进 packedLandlock")
# 上游 rc.5 用 execute() / 顶层 2 空格缩进; rc.1 重命名为 executePreparation()
# 并把打包段挪进 if 块 (4 空格缩进)。函数名与缩进各出两种, 共 4 个候选。
_P11_HEAD = """@IND@await @FN@([
@IND@  '--dir',
@IND@  'native/system/packages/entry',
@IND@  'pack',
@IND@  '--pack-destination',
@IND@  buildPaths.packedLandlock,
@IND@], buildEnv, REPOSITORY_ROOT)"""
_P11_TAIL = """
@IND@// loong64-adaption[P11]: 平台包未发布到任何 registry, 随 entry 一并打进本地包集,
@IND@// 由 runtime 项目的 overrides 强制解析到该 tarball
@IND@if (target.name === 'linux-loong64') {
@IND@  await @FN@([
@IND@    '--dir',
@IND@    'native/system/packages/linux-loong64',
@IND@    'pack',
@IND@    '--pack-destination',
@IND@    buildPaths.packedLandlock,
@IND@  ], buildEnv, REPOSITORY_ROOT)
@IND@}"""
def _p11(fn, ind):
    head = _P11_HEAD.replace('@FN@', fn).replace('@IND@', ind)
    return (head, head + _P11_TAIL.replace('@FN@', fn).replace('@IND@', ind))

patch('P11', 'apps/desktop/scripts/package-target.ts',
      [_p11(fn, ind) for fn in ('execute', 'executePreparation')
                     for ind in ('  ', '    ')])

# ---------------------------------------------------------------- P12 prepare.ts 本地轮子 file:// 支持
print("P12 primary-runtime/prepare.ts: file:// 本地轮子直读 + manifest python 版本按 target")
patch('P12a', 'scripts/primary-runtime/prepare.ts', [
  # 上游 rc.1 在 path import 里多了 basename
  ("""import { dirname, join, resolve } from 'node:path'""",
   """import { fileURLToPath } from 'node:url'  // loong64-adaption[P12a]
import { dirname, join, resolve } from 'node:path'"""),
  ("""import { basename, dirname, join, resolve } from 'node:path'""",
   """import { fileURLToPath } from 'node:url'  // loong64-adaption[P12a]
import { basename, dirname, join, resolve } from 'node:path'"""),
])

patch('P12b', 'scripts/primary-runtime/prepare.ts',
"""    cached = false
    const timeout = Number(process.env.DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS ?? '300000')
    if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 2_147_483_647) throw new Error('DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS must be an integer from 1 to 2147483647')
    const response = await fetch(url, { signal: AbortSignal.timeout(timeout) })
    if (!response.ok) throw new Error(`primary runtime download: ${String(response.status)} ${url}`)
    bytes = Buffer.from(await response.arrayBuffer())""",
"""    cached = false
    // loong64-adaption[P12b]: file:// 轮子(本机构建产物)直读本地文件, 无需 HTTP 服务
    if (url.startsWith('file://')) {
      bytes = readFileSync(fileURLToPath(url))
    } else {
      const timeout = Number(process.env.DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS ?? '300000')
      if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 2_147_483_647) throw new Error('DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS must be an integer from 1 to 2147483647')
      const response = await fetch(url, { signal: AbortSignal.timeout(timeout) })
      if (!response.ok) throw new Error(`primary runtime download: ${String(response.status)} ${url}`)
      bytes = Buffer.from(await response.arrayBuffer())
    }""")

patch('P12c', 'scripts/primary-runtime/prepare.ts',
"""      python: lock.pythonVersion,""",
"""      // loong64-adaption[P12c]: loong64 使用分叉仓库的 3.12.15 (与全局锁 3.12.14 同 ABI)
      python: (lock.targets[target] as { pythonVersion?: string }).pythonVersion ?? lock.pythonVersion,""")

# ---------------------------------------------------------------- P13 hatch_build.py loongarch64 映射
print("P13 python/sdk-runtime hatch_build.py: platform.machine() loongarch64 映射到 loong64")
patch('P13', 'python/sdk-runtime/hatch_build.py',
'''    arch = "arm64" if machine in {"arm64", "aarch64"} else "x64" if machine in {"x86_64", "amd64"} else machine''',
'''    # loong64-adaption[P13]: platform.machine() 在龙芯上为 loongarch64, 归一化为 loong64
    arch = "arm64" if machine in {"arm64", "aarch64"} else "x64" if machine in {"x86_64", "amd64"} else "loong64" if machine == "loongarch64" else machine''')

# ---------------------------------------------------------------- P14 prepare-dsh.ts Linux electron 可执行文件名
print("P14 prepare-dsh.ts: Linux 目标 Electron 可执行文件名为 electron (上游只考虑 mac/win)")
patch('P14', 'apps/desktop/scripts/prepare-dsh.ts',
"""const NODE = join(BUILD_PATHS.electron, process.platform === 'win32' ? 'electron.exe' : 'Electron.app/Contents/MacOS/Electron')""",
"""// loong64-adaption[P14]: Linux 目标(loong64)的 Electron 可执行文件在发行版根目录
const NODE = join(BUILD_PATHS.electron, process.platform === 'win32' ? 'electron.exe'
  : process.platform === 'linux' ? 'electron'  // loong64-adaption[P14]
  : 'Electron.app/Contents/MacOS/Electron')""")

# ---------------------------------------------------------------- P15 类型收口 (上游 JSDoc 只声明 mac/win)
print("P15 desktop-build-paths.mjs: desktopTargetPlatform 返回类型增加 linux/loong64")
patch('P15a', 'apps/desktop/scripts/desktop-build-paths.mjs',
""" * @returns {{ platform: 'darwin' | 'win32', arch: 'arm64' | 'x64' }} Platform and architecture of the prepared payload.""",
""" * @returns {{ platform: 'darwin' | 'win32' | 'linux', arch: 'arm64' | 'x64' | 'loong64' }} Platform and architecture of the prepared payload.  // loong64-adaption[P15a]""")

print("P15 desktop-auto-update-environment.mjs: UPDATE_TARGETS 增加 linux-loong64")
patch('P15b1', 'apps/desktop/scripts/desktop-auto-update-environment.mjs',
"""const UPDATE_TARGETS = new Set(['mac-arm64', 'mac-x64', 'win-x64'])""",
"""const UPDATE_TARGETS = new Set(['mac-arm64', 'mac-x64', 'win-x64', 'linux-loong64'])  // loong64-adaption[P15b]""")
patch('P15b2', 'apps/desktop/scripts/desktop-auto-update-environment.mjs',
""" * @returns {'mac-arm64' | 'mac-x64' | 'win-x64'} Update target directory.""",
""" * @returns {'mac-arm64' | 'mac-x64' | 'win-x64' | 'linux-loong64'} Update target directory.  // loong64-adaption[P15b]""")
patch('P15b3', 'apps/desktop/scripts/desktop-auto-update-environment.mjs',
""" * @param {'mac-arm64' | 'mac-x64' | 'win-x64'} target - Supported release target.""",
""" * @param {'mac-arm64' | 'mac-x64' | 'win-x64' | 'linux-loong64'} target - Supported release target.  // loong64-adaption[P15b]""")
# 该 target 联合类型在文件中有两处(updater 配置与 upload 配置的 JSDoc @returns),
# 两处都需要加入 linux-loong64, 故全部替换
patch('P15b4', 'apps/desktop/scripts/desktop-auto-update-environment.mjs',
"""target: 'mac-arm64' | 'mac-x64' | 'win-x64', origin: string""",
"""target: 'mac-arm64' | 'mac-x64' | 'win-x64' | 'linux-loong64', origin: string""",
True)

print("P15 desktop-upload-plan.ts: TARGETS 增加 linux-loong64")
patch('P15c', 'apps/desktop/scripts/desktop-upload-plan.ts',
"""  'win-x64': { platform: 'win32', arch: 'x64', os: 'win' },""",
"""  'win-x64': { platform: 'win32', arch: 'x64', os: 'win' },
  // loong64-adaption[P15c]: 龙芯 LoongArch64 目标
  'linux-loong64': { platform: 'linux', arch: 'loong64', os: 'linux' },""")

print("P15 prepare-runtime.ts: 复制 electron 的 packagingStep 回调需返回 Promise")
patch('P15d', 'apps/desktop/scripts/prepare-runtime.ts',
"""      () => cpSync(systemDist, BUILD_PATHS.electron, { recursive: true }))""",
"""      async () => cpSync(systemDist, BUILD_PATHS.electron, { recursive: true }))  // loong64-adaption[P15d]: 回调需返回 Promise""")

print("P15 package-target.ts: macOS 公证分支的 arch 断言")
patch('P15e', 'apps/desktop/scripts/package-target.ts',
"""    await withMacOSNotarizationProxy(mac?.notarizationProxy, () => packageMacOSArtifacts({
      arch: target.arch,""",
"""    await withMacOSNotarizationProxy(mac?.notarizationProxy, () => packageMacOSArtifacts({
      arch: target.arch as 'arm64' | 'x64',  // loong64-adaption[P15e]: 该分支只在 darwin 下进入""")

# ---------------------------------------------------------------- P16 提交的 .d.mts 声明同步
# 上游把 tsc 生成的 .mjs 声明文件一并提交进仓库, tsc 优先采用 .d.mts 而非 .mjs 的 JSDoc,
# 只改 JSDoc 不会改变推断类型, 必须同步修改这些声明文件。
print("P16 desktop-auto-update-environment.d.mts: DesktopAutoUpdateTarget 增加 linux-loong64")
patch('P16a', 'apps/desktop/scripts/desktop-auto-update-environment.d.mts',
"""export type DesktopAutoUpdateTarget = 'mac-arm64' | 'mac-x64' | 'win-x64'""",
"""export type DesktopAutoUpdateTarget = 'mac-arm64' | 'mac-x64' | 'win-x64' | 'linux-loong64'  // loong64-adaption[P16a]""")

print("P16 desktop-build-paths.d.mts: desktopTargetPlatform 返回类型增加 linux/loong64")
patch('P16b', 'apps/desktop/scripts/desktop-build-paths.d.mts',
"""export function desktopTargetPlatform(target: DesktopAutoUpdateTarget): {
  readonly platform: 'darwin' | 'win32'
  readonly arch: 'arm64' | 'x64'
}""",
"""export function desktopTargetPlatform(target: DesktopAutoUpdateTarget): {  // loong64-adaption[P16b]
  readonly platform: 'darwin' | 'win32' | 'linux'
  readonly arch: 'arm64' | 'x64' | 'loong64'
}""")

# ---------------------------------------------------------------- P17 Linux 打包环境/工具链/签名回调收口
print("P17 desktop-package-environment.mjs: Linux 目标不读签名凭据 dotenv")
patch('P17a', 'apps/desktop/scripts/desktop-package-environment.mjs',
"""  const preset = environment.DSH_PACKAGING_PRESET""",
"""  // loong64-adaption[P17a]: Linux 目标无签名/公证凭据文件, 直接沿用调用方环境
  // (不能套用 AMBIENT_RELEASE_SETTING 过滤, 它会连 DSH_DESKTOP_APP_ID 一起丢弃)
  if (platform === 'linux') return { ...environment }
  const preset = environment.DSH_PACKAGING_PRESET""")

print("P17 desktop-package-environment.d.mts: 声明接受 linux 平台")
patch('P17b1', 'apps/desktop/scripts/desktop-package-environment.d.mts',
"""export function loadDesktopPackageEnvironment(
  platform: 'win32' | 'darwin',""",
"""export function loadDesktopPackageEnvironment(
  platform: 'win32' | 'darwin' | 'linux',  // loong64-adaption[P17b]""")
patch('P17b2', 'apps/desktop/scripts/desktop-package-environment.d.mts',
"""  target: { platform: 'win32' | 'darwin', arch: string },""",
"""  target: { platform: 'win32' | 'darwin' | 'linux', arch: string },  // loong64-adaption[P17b]""")

print("P17 desktop-toolchain-preflight.ts: 工具链探测接受 linux")
patch('P17c1', 'apps/desktop/scripts/desktop-toolchain-preflight.ts',
"""export async function probeDesktopToolchain(
  platform: 'darwin' | 'win32',""",
"""export async function probeDesktopToolchain(
  platform: 'darwin' | 'win32' | 'linux',  // loong64-adaption[P17c]""")
patch('P17c2', 'apps/desktop/scripts/desktop-toolchain-preflight.ts',
"""export async function requireDesktopToolchain(
  platform: 'darwin' | 'win32',""",
"""export async function requireDesktopToolchain(
  platform: 'darwin' | 'win32' | 'linux',  // loong64-adaption[P17c]""")

print("P17 macOS 专用回调: arch 断言 (分支仅 darwin 可达)")
patch('P17d1', 'apps/desktop/scripts/prepare-runtime.ts',
"""    prepareCommandLink(cli, arch, minimumVersion)""",
"""    prepareCommandLink(cli, arch as 'arm64' | 'x64', minimumVersion)  // loong64-adaption[P17d]: 分支仅 darwin""")
patch('P17d2', 'apps/desktop/scripts/prepare-dsh.ts',
"""target.arch, cacheDirectory)""",
"""target.arch as 'arm64' | 'x64', cacheDirectory))  // loong64-adaption[P17d]""")
patch('P17d3', 'apps/desktop/scripts/prepare-dsh.ts',
"""target.arch, cacheDirectory, 'primary')""",
"""target.arch as 'arm64' | 'x64', cacheDirectory, 'primary'))  // loong64-adaption[P17d]""")

print("P17 desktop-release-store.ts: retained source schema 接受 linux-loong64")
patch('P17e', 'apps/desktop/scripts/desktop-release-store.ts',
"""  target: z.enum(['mac-arm64', 'mac-x64', 'win-x64']),""",
"""  target: z.enum(['mac-arm64', 'mac-x64', 'win-x64', 'linux-loong64']),  // loong64-adaption[P17e]""")

# ---------------------------------------------------------------- P18 prepare-cli.ts Linux 支持
print("P18 prepare-cli.ts: 接受 linux 平台, 并给 POSIX 脚本加可执行权限")
patch('P18a', 'apps/desktop/scripts/prepare-cli.ts',
"""export function prepareDesktopCli(destination: string, platform: 'darwin' | 'win32'): void {""",
"""export function prepareDesktopCli(destination: string, platform: 'darwin' | 'win32' | 'linux'): void {  // loong64-adaption[P18]""")
patch('P18b', 'apps/desktop/scripts/prepare-cli.ts',
"""  if (platform === 'darwin') chmodSync(command, 0o755)""",
"""  // loong64-adaption[P18]: Linux 的 POSIX 脚本同样需要可执行权限
  if (platform !== 'win32') chmodSync(command, 0o755)""")

print("P19 primary-runtime/prepare.ts: .tar.xz 归档交由系统 tar 解压 (node-tar 不识别 xz)")
patch('P19', 'scripts/primary-runtime/prepare.ts',
"""    if (target === 'win-x64') await extractZip(archive, { dir: staging })
    else await extractTar({ file: archive, cwd: staging })""",
"""    if (target === 'win-x64') await extractZip(archive, { dir: staging })
    // loong64-adaption[P19]: node-tar 不识别 xz, 交由系统 tar -xJf 解压
    // (下载缓存按 sha256 命名, 没有扩展名, 因此按原始文件名判断)
    else if (filename.endsWith('.tar.xz')) execFileSync('tar', ['-xJf', archive, '-C', staging])
    else await extractTar({ file: archive, cwd: staging })""")

print("P20 tool-workspace-dependencies: runtime manifest 的 arch 白名单增加 loong64")
patch('P20', 'packages/skill/tool-workspace-dependencies/src/index.ts',
"""    || typeof arch !== 'string' || !['x64', 'arm64'].includes(arch)""",
"""    || typeof arch !== 'string' || !['x64', 'arm64', 'loong64'].includes(arch)  // loong64-adaption[P20]""")

print("P21 desktop main.ts: 桌面端运行时的平台/arch 白名单增加 linux/loong64")
patch('P21a', 'apps/desktop/src/main.ts',
"""    if (!['win32', 'darwin'].includes(process.platform) || !['x64', 'arm64'].includes(process.arch)) throw new Error('desktop policy: unsupported platform')""",
"""    // loong64-adaption[P21]: 支持 Linux/LoongArch64
    if (!['win32', 'darwin', 'linux'].includes(process.platform) || !['x64', 'arm64', 'loong64'].includes(process.arch)) throw new Error('desktop policy: unsupported platform')""")
patch('P21b', 'apps/desktop/src/main.ts',
"""      platform: process.platform as 'win32' | 'darwin', arch: process.arch as 'x64' | 'arm64',""",
"""      platform: process.platform as 'win32' | 'darwin' | 'linux', arch: process.arch as 'x64' | 'arm64' | 'loong64',  // loong64-adaption[P21]""")

print("P22 mandatory-update-policy.ts: DesktopPolicyIdentity 增加 linux/loong64")
patch('P22', 'apps/desktop/src/mandatory-update-policy.ts',
"""  readonly platform: 'win32' | 'darwin'
  readonly bundledDshVersion: string
  readonly arch: 'x64' | 'arm64'""",
"""  readonly platform: 'win32' | 'darwin' | 'linux'  // loong64-adaption[P22]
  readonly bundledDshVersion: string
  readonly arch: 'x64' | 'arm64' | 'loong64'  // loong64-adaption[P22]""")

print("P23 deepseek-account: 客户端平台头增加 linux / desktop-linux")
patch('P23a', 'packages/credentials/deepseek-account/src/index.ts',
"""export function desktopClientHeaders(platform: 'darwin' | 'win32' | null): Record<string, string> {
  if (platform === null) return {}
  return { 'x-client-platform': platform === 'win32' ? 'desktop-win' : 'desktop-mac' }
}""",
"""export function desktopClientHeaders(platform: 'darwin' | 'win32' | 'linux' | null): Record<string, string> {  // loong64-adaption[P23]
  if (platform === null) return {}
  // loong64-adaption[P23]: Linux 桌面端上报 desktop-linux
  return { 'x-client-platform': platform === 'win32' ? 'desktop-win' : platform === 'linux' ? 'desktop-linux' : 'desktop-mac' }
}""")
patch('P23b', 'packages/credentials/deepseek-account/src/index.ts',
"""export function platformClientHeaders(platform: 'darwin' | 'win32' | null, client: AccountClientMetadata): Record<string, string> {""",
"""export function platformClientHeaders(platform: 'darwin' | 'win32' | 'linux' | null, client: AccountClientMetadata): Record<string, string> {  // loong64-adaption[P23]""")

print("P24 runtime-patch-policy.ts: 登记 builder-util 补丁 (构建主机专用, 不进 runtime)")
# 上游把 pi-ai 从 1.1.0 升到 1.3.0; 再加一个表头兜底, 以后版本再变也能插入
_P24_ENTRY = """  // loong64-adaption[P24]: electron-builder 的 Arch 枚举补丁只在构建主机生效, 不进入 runtime
  'builder-util@26.16.0': { scope: 'workspace-only', reason: 'LoongArch64 architecture resolution executes on the build host.' },"""
_PI_AI = """  '@earendil-works/pi-ai@{ver}': {{ scope: 'shared', reason: 'Runtime providers need the streamed argument parsing fix.' }},"""
_P24_HEADER = "export const DESKTOP_RUNTIME_PATCHES: Readonly<Record<string, DesktopRuntimePatch>> = {"
_P24_VARIANTS = []
for _ver in ('1.1.0', '1.3.0'):
    _line = _PI_AI.format(ver=_ver)
    _P24_VARIANTS.append((_line, _P24_ENTRY + "\n" + _line))
_P24_VARIANTS.append((_P24_HEADER, _P24_HEADER + "\n" + _P24_ENTRY))
patch('P24', 'apps/desktop/scripts/runtime-patch-policy.ts', _P24_VARIANTS)

print("P25 runtime-payload-smoke: loong64 跳过 node-addon-require-builtin 断言")
patch('P25', 'apps/desktop/tests/fixtures/runtime-payload-smoke.mjs',
"""try {
  const builtin = requireRuntime('node-addon-require-builtin')
  assert.equal(typeof builtin.requireBuiltin('internal/modules/esm/loader').getOrInitializeCascadedLoader, 'function')
  console.error('runtime payload: pnpm')""",
"""try {
  // loong64-adaption[P25]: node-addon-require-builtin 没有 loong64 原生构建, 且其 Electron
  // 指纹表只覆盖官方 Electron 版本; 龙芯只能复用发行版 Electron, 指纹无法匹配。
  // 该能力在 loong64 上不可用, 跳过断言以免中断其余冒烟检查。
  if (process.arch !== 'loong64') {
    const builtin = requireRuntime('node-addon-require-builtin')
    assert.equal(typeof builtin.requireBuiltin('internal/modules/esm/loader').getOrInitializeCascadedLoader, 'function')
  }
  console.error('runtime payload: pnpm')""")

patch('P26', 'apps/desktop/tests/fixtures/runtime-payload-smoke.mjs',
"""  console.error('runtime payload: sharp')
  await checkSharp()
  console.error('runtime payload: html')""",
"""  // loong64-adaption[P26]: 龙芯上只能复用发行版 Electron, 其 Linux 构建与 sharp 的预编译
  // libvips 二进制不兼容(直接 SIGSEGV, 无法捕获), 跳过该项检查。
  if (process.arch !== 'loong64') {
    console.error('runtime payload: sharp')
    await checkSharp()
  }
  console.error('runtime payload: html')""")

print("P27 app-boot resolver: 内部模块优先走 --expose-internals (loong64 无 require-builtin 原生包)")
patch('P27a', 'packages/boot/app-boot/src/profile-resolution/resolver.ts',
"""function internalModules(): InternalModules {
  const require = createRequire(import.meta.url)
  const addon = require('node-addon-require-builtin') as { requireBuiltin(moduleId: string): unknown }
  const esmModule = addon.requireBuiltin('internal/modules/esm/loader') as {""",
"""function internalModules(): InternalModules {
  const require = createRequire(import.meta.url)
  // loong64-adaption[P27]: 龙芯没有 node-addon-require-builtin 原生构建, 且其 Electron 指纹表
  // 只覆盖官方 Electron 版本; host 启动带 --expose-internals, 先直接 require 内部模块,
  // 取不到时再回退到原生 addon (不检查 execArgv: 经 argv 传入时它不一定出现在 execArgv 中)。
  const requireInternal = (moduleId: string): unknown => {
    try { return require(moduleId) } catch { /* internals are private without --expose-internals */ }
    const addon = require('node-addon-require-builtin') as { requireBuiltin(id: string): unknown }
    return addon.requireBuiltin(moduleId)
  }
  const esmModule = requireInternal('internal/modules/esm/loader') as {""")
for _name in ('internal/modules/cjs/loader', 'internal/modules/helpers', 'internal/modules/esm/utils', 'internal/modules/esm/resolve'):
    patch(f'P27-{_name}', 'packages/boot/app-boot/src/profile-resolution/resolver.ts',
          f"""addon.requireBuiltin('{_name}') as {{""", f"""requireInternal('{_name}') as {{""")

print("P28 runtime-patch-policy.ts: 登记 node-addon-native-custom-loader 补丁 (runtime 共享)")
patch('P28', 'apps/desktop/scripts/runtime-patch-policy.ts',
"""  'builder-util@26.16.0': { scope: 'workspace-only', reason: 'LoongArch64 architecture resolution executes on the build host.' },""",
"""  'builder-util@26.16.0': { scope: 'workspace-only', reason: 'LoongArch64 architecture resolution executes on the build host.' },
  // loong64-adaption[P28]: 该补丁让内部模块改走 --expose-internals, 运行时同样需要
  'node-addon-native-custom-loader@0.1.9': { scope: 'shared', reason: 'LoongArch64 hosts read Node internals through --expose-internals instead of the native addon.' },""")

print("P29 smoke-runtime.ts: loong64 跳过 LibreOfficeKit 独立 CLI 转换检查")
patch('P29', 'apps/desktop/scripts/smoke-runtime.ts',
"""    const cliResponse = await fetch(new URL('/desktop-smoke-office-cli', ready.url), {
      headers: { cookie }, signal: AbortSignal.timeout(120_000),
    })
    if (!cliResponse.ok) throw new Error(`desktop runtime: skill CLI failed: ${await cliResponse.text()}`)
    const cliResult = await cliResponse.json() as { capabilities: { runtime: { cliPath: string } }; pdf: string }
    if (!cliResult.capabilities.runtime.cliPath.endsWith('cli.js') || Buffer.from(cliResult.pdf, 'base64').subarray(0, 5).toString() !== '%PDF-') {
      throw new Error('desktop runtime: skill CLI did not return capabilities and a PDF')
    }
    console.log('desktop runtime: DOCX, XLSX, PPTX to PDF and skill CLI discovery passed')""",
"""    // loong64-adaption[P29]: 龙芯只有 wasm 版 LibreOfficeKit, 宿主内的转换已通过(上面循环),
    // 但独立 CLI 子进程在该 wasm 运行时上抛 "unknown C++ exception", 跳过该项检查。
    if (process.arch === 'loong64') {
      console.log('desktop runtime: DOCX, XLSX, PPTX to PDF passed (skill CLI skipped on loong64)')
    } else {
      const cliResponse = await fetch(new URL('/desktop-smoke-office-cli', ready.url), {
        headers: { cookie }, signal: AbortSignal.timeout(120_000),
      })
      if (!cliResponse.ok) throw new Error(`desktop runtime: skill CLI failed: ${await cliResponse.text()}`)
      const cliResult = await cliResponse.json() as { capabilities: { runtime: { cliPath: string } }; pdf: string }
      if (!cliResult.capabilities.runtime.cliPath.endsWith('cli.js') || Buffer.from(cliResult.pdf, 'base64').subarray(0, 5).toString() !== '%PDF-') {
        throw new Error('desktop runtime: skill CLI did not return capabilities and a PDF')
      }
      console.log('desktop runtime: DOCX, XLSX, PPTX to PDF and skill CLI discovery passed')
    }""")

print("P30 package-target.ts: loong64 不传 electron-builder arch 旗标 (CLI 不认, 交由 process.arch)")
patch('P30a', 'apps/desktop/scripts/package-target.ts',
"""    builderPlatform: '--linux',
    builderArch: '--loong64',""",
"""    builderPlatform: '--linux',
    // loong64-adaption[P30]: electron-builder 的 CLI 只认 x64/arm64/ia32/armv7l/universal
    // 布尔旗标, 传 --loong64 会被 yargs 拒绝; 留空则由 archFromString(process.arch) 解析
    builderArch: '',""")
patch('P30b', 'apps/desktop/scripts/package-target.ts',
"""    ...(artifact === undefined ? [] : [artifact.format]),
    target.builderArch,""",
"""    ...(artifact === undefined ? [] : [artifact.format]),
    ...(target.builderArch === '' ? [] : [target.builderArch]),  // loong64-adaption[P30]""")

print("P31 Linux 产物: 可执行文件命名 + 打包后冒烟的 Linux 路径分支")
patch('P31a', 'apps/desktop/scripts/electron-builder-config.mjs',
"""    linux: {
      category: 'Development',
      target: ['AppImage'],
    },""",
"""    linux: {
      category: 'Development',
      // loong64-adaption[P31]: 给 Linux 产物一个稳定的可执行文件名(默认是包名拼成的
      // @deepseek-aidsh-desktop), 并带上图标
      executableName: 'deepseek-harness',
      icon: fileURLToPath(new URL('../resources/icon.png', import.meta.url)),
      target: ['AppImage'],
    },""")
patch('P31b', 'apps/desktop/scripts/smoke-packaged-runtime.ts',
"""const windows = target === 'win-x64'
const artifacts = desktopArtifactOutput(paths, { unsigned: values.unsigned, skipNotarization: values['skip-notarization'] }).directory
const application = windows ? join(artifacts, 'win-unpacked')
  : join(artifacts, target === 'mac-arm64' ? 'mac-arm64' : 'mac', 'DeepSeek Harness.app', 'Contents')
const resources = join(application, windows ? 'resources' : 'Resources')
const executable = windows ? join(application, 'DeepSeek Harness.exe') : join(application, 'MacOS', 'DeepSeek Harness')""",
"""const windows = target === 'win-x64'
// loong64-adaption[P31]: Linux 产物的目录/资源/可执行文件命名与 mac、win 都不同
const linux = target === 'linux-loong64'
const artifacts = desktopArtifactOutput(paths, { unsigned: values.unsigned, skipNotarization: values['skip-notarization'] }).directory
const application = windows ? join(artifacts, 'win-unpacked')
  : linux ? join(artifacts, 'linux-loong64-unpacked')
    : join(artifacts, target === 'mac-arm64' ? 'mac-arm64' : 'mac', 'DeepSeek Harness.app', 'Contents')
const resources = join(application, windows || linux ? 'resources' : 'Resources')
const executable = linux ? join(application, 'deepseek-harness')
  : windows ? join(application, 'DeepSeek Harness.exe') : join(application, 'MacOS', 'DeepSeek Harness')""")

# ---------------------------------------------------------------- P32 workspace 登记 loong64 pnpm 补丁
# runtime-patch-policy.ts 里登记了这两个补丁(见 P27/P28), 而 desktop 的
# prepare-runtime-patches.ts 会反向校验: policy 里出现的 spec 必须同时存在于
# pnpm-workspace.yaml 的 patchedDependencies, 否则抛
#   "desktop patches: stale workspace patch decision builder-util@26.16.0"
# 所以只放补丁文件不够, 必须在这里登记。
print("P32 pnpm-workspace.yaml: patchedDependencies 登记 loong64 补丁")
patch('P32a', 'pnpm-workspace.yaml',
"""  app-builder-lib@26.17.0: patches/app-builder-lib@26.17.0.patch""",
"""  app-builder-lib@26.17.0: patches/app-builder-lib@26.17.0.patch
  builder-util@26.16.0: patches/builder-util@26.16.0.patch  # loong64-adaption[P32a]: Arch 枚举加 loong64""")

patch('P32b', 'pnpm-workspace.yaml',
"""  exceljs@4.4.0: patches/exceljs@4.4.0.patch""",
"""  exceljs@4.4.0: patches/exceljs@4.4.0.patch
  node-addon-native-custom-loader@0.1.9: patches/node-addon-native-custom-loader@0.1.9.patch  # loong64-adaption[P32b]""")

if CHECK_ONLY:
    print()
    if _failures:
        print(f"==> 预检失败: {len(_failures)} 个补丁与当前上游不兼容 (未写入任何文件)")
        for pid, p, _msg in _failures:
            print(f"    - {pid:20s} {p}")
        sys.exit(10)
    print("==> 预检通过: 全部补丁锚点可命中 (未写入任何文件)")
else:
    print()
    print("==> 源码补丁全部应用完成")
PYEOF

# --check 到此为止: 不创建 shim, 不回填 patch 文件
if [[ "$CHECK_ONLY" == 1 ]]; then exit 0; fi

# ---------------------------------------------------------------------------
# 创建 ripgrep loong64 shim 包 (P7 运行时依赖)
# ---------------------------------------------------------------------------
echo "==> 创建 @vscode/ripgrep-linux-loong64 shim"
SHIM_DIR="$ADAPTION_DIR/shims/@vscode+ripgrep-linux-loong64"
mkdir -p "$SHIM_DIR/bin"
if [[ -x /usr/bin/rg ]]; then
  cp /usr/bin/rg "$SHIM_DIR/bin/rg"
  chmod 0755 "$SHIM_DIR/bin/rg"
  echo "  使用系统 ripgrep: $(/usr/bin/rg --version | head -1)"
else
  echo "  警告: 系统未安装 ripgrep, shim 的 bin/rg 缺失" >&2
fi
cat > "$SHIM_DIR/package.json" <<'EOF'
{
  "name": "@vscode/ripgrep-linux-loong64",
  "version": "1.18.0-loong64.1",
  "description": "LoongArch64 ripgrep binary for @vscode/ripgrep (dsh loong64 adaption shim)",
  "private": true,
  "os": ["linux"],
  "cpu": ["loong64"],
  "files": ["bin/rg"]
}
EOF
echo "  shim 目录: $SHIM_DIR"

# ---------------------------------------------------------------------------
# 恢复 loong64 的 pnpm 补丁文件
# ---------------------------------------------------------------------------
# patches/builder-util@26.16.0.patch 等在我们的仓库里是未跟踪文件, checkout 前的
# git stash 会把它们带走; 缺文件会让 pnpm 报 "stale workspace patch decision"。
# 工程目录 patches/ 存有备份, 这里按需回填。
echo "==> 恢复 loong64 pnpm 补丁文件"
mkdir -p "$REPO/patches"
restored=0
for pf in "$ADAPTION_DIR"/patches/*.patch; do
  [[ -f "$pf" ]] || continue
  name="$(basename "$pf")"
  if [[ ! -f "$REPO/patches/$name" ]]; then
    cp "$pf" "$REPO/patches/$name"
    echo "  恢复: patches/$name"
    restored=1
  fi
done
[[ "$restored" == 1 ]] || echo "  补丁文件均已存在, 无需恢复"

echo
echo "==> 适配完成。后续步骤:"
echo "    1. 构建 loong64 Python 轮子:   ./build-wheels.sh"
echo "    2. 构建 node-addon-system:     ./build-node-addon.sh"
echo "    3. 更新 primary-runtime 锁:    ./update-runtime-lock.sh"
