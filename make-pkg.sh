#!/usr/bin/env bash
# =============================================================================
# make-pkg.sh —— 把 electron-builder --dir 的 unpacked 产物打成 Arch (pacman)
#                .pkg.tar.zst 包, 供 Arch Linux loong64 用 pacman -U 安装
#
# 产出: dist/deepseek-harness-<pkgver>-<pkgrel>-loong64.pkg.tar.zst
#
# 用法:
#   ./make-pkg.sh [unpacked目录]      省略则自动探测
#   PKG_REL=2 ./make-pkg.sh           自定义 pkgrel (默认 1)
#   PKG_STRIP=0 ./make-pkg.sh         不做精简(保留全部 locale)
#   PKG_STRIP=aggressive ./make-pkg.sh  再删 SwiftShader 软渲染库
#   ZSTD_LEVEL=3 ./make-pkg.sh        压缩级别 (默认 10; 越大越慢越小)
#   DSH_SRC_TREE=/path/to/dsh ./make-pkg.sh   指定上游源码树
#
# 说明:
#   - 安装前缀固定 /opt/deepseek-harness, /usr/bin 建命令链接
#   - pkgver 中的 '-' 会转 '_' (Arch 用 '-' 分隔 pkgver/pkgrel, 版本字段禁止 '-')
#     例: 0.2.1-rc.4 -> 0.2.1_rc.4
#   - 包内 .PKGINFO 必须是归档第一个成员, .INSTALL 次之, 之后才是文件
#   - 依赖声明按宿主自适应: Arch 系写入 Electron 运行时依赖;
#     非 Arch 系留空, 避免 pacman 依赖解析失败
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 源码树探测
# 优先环境变量; 否则按本目录名推断: dsh_desktop-loong64-0.2.2 -> ../dsh-0.2.2
# 无后缀的 dsh_desktop-loong64 -> ../dsh 。这样脚本复制到别的版本目录也能直接用
detect_src_tree() {
  if [[ -n "${DSH_SRC_TREE:-}" ]]; then echo "$DSH_SRC_TREE"; return; fi
  local base suffix
  base="$(basename "$HERE")"
  suffix="${base#dsh_desktop-loong64}"
  suffix="${suffix#-}"
  if [[ -n "$suffix" && -d "$HERE/../dsh-$suffix" ]]; then echo "$HERE/../dsh-$suffix"; return; fi
  if [[ -d "$HERE/../dsh" ]]; then echo "$HERE/../dsh"; return; fi
  echo "$HERE/../dsh"
}

SRC_TREE="$(detect_src_tree)"
CARCH="${CARCH:-$(grep -m1 '^CARCH=' /etc/makepkg.conf 2>/dev/null | cut -d'"' -f2)}"
CARCH="${CARCH:-$(uname -m)}"
OUT="$HERE/dist"
TARGETS="$SRC_TREE/apps/desktop/.desktop-build/targets/linux-loong64"
DSH="${1:-}"
PKG_REL="${PKG_REL:-1}"
PKG_STRIP="${PKG_STRIP:-1}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"
PREFIX=/opt/deepseek-harness

if [[ -z "$DSH" ]]; then
  # 依次尝试 unsigned-artifacts / artifacts (不同版本的上游脚本产出目录名不同)
  for base in "$TARGETS/unsigned-artifacts" "$TARGETS/artifacts"; do
    [[ -d "$base" ]] || continue
    for candidate in "$base"/linux-*unpacked "$base"/linux-*; do
      if [[ -d "$candidate" && -f "$candidate/resources/app.asar" ]]; then DSH="$candidate"; break 2; fi
    done
  done
fi
[[ -n "$DSH" && -d "$DSH" ]] || { echo "错误: 找不到 unpacked 产物目录 (先运行 package-desktop.sh)" >&2; exit 1; }

VERSION="$(python3 -c "import json;print(json.load(open('$SRC_TREE/apps/desktop/package.json'))['version'])")"
# Arch 的 pkgver 禁止 '-' (该字符用于分隔 pkgver 与 pkgrel)
PKGVER="${VERSION//-/_}"
ICON_SRC="$SRC_TREE/apps/desktop/resources/icon.png"
LAUNCHER="$HERE/deepseek-harness-launcher.sh"
PKG="deepseek-harness-${PKGVER}-${PKG_REL}-${CARCH}.pkg.tar.zst"

echo "==> 产物目录: $DSH"
echo "==> 源码树:   $SRC_TREE"
echo "==> 上游版本: $VERSION"
echo "==> 包版本:   ${PKGVER}-${PKG_REL} (arch=$CARCH)"

# ---------------------------------------------------------------- 依赖声明
DEPENDS=()
if command -v pacman >/dev/null 2>&1 && grep -qiE '^ID=(arch|archlinux)' /etc/os-release 2>/dev/null; then
  DEPENDS=(gtk3 nss alsa-lib libxss libxtst libnotify at-spi2-core libdrm
           mesa libcups libxkbcommon pango cairo libsecret xdg-utils)
  echo "==> 宿主为 Arch 系, 写入 Electron 运行时依赖 (${#DEPENDS[@]} 项)"
else
  echo "==> 宿主非 Arch 系, depend 留空 (避免依赖名不匹配导致安装失败)"
fi

rm -f "$OUT/$PKG"
mkdir -p "$OUT"

# ---------------------------------------------------------------- 组装 payload
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APPDIR="$STAGE$PREFIX"
mkdir -p "$APPDIR"
cp -a "$DSH"/. "$APPDIR/"
[[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "$APPDIR/resources/icon.png"

# 龙芯启动器注入 (清 ELECTRON_RUN_AS_NODE + 强制 X11 Ozone + 省资源参数)
if [[ -f "$APPDIR/deepseek-harness" && -f "$LAUNCHER" ]]; then
  mv "$APPDIR/deepseek-harness" "$APPDIR/deepseek-harness.bin"
  cp "$LAUNCHER" "$APPDIR/deepseek-harness"
  chmod 0755 "$APPDIR/deepseek-harness" "$APPDIR/deepseek-harness.bin"
  echo "==> 已注入龙芯启动器"
fi

# ---------------------------------------------------------------- 精简 (可选)
if [[ "$PKG_STRIP" != "0" ]]; then
  before="$(du -sm "$APPDIR" | cut -f1)"
  rm -f "$APPDIR/LICENSES.chromium.html" 2>/dev/null || true
  if [[ -d "$APPDIR/locales" ]]; then
    find "$APPDIR/locales" -name '*.pak' ! -name 'zh-CN.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
  fi
  if [[ "$PKG_STRIP" == "aggressive" ]]; then
    rm -f "$APPDIR/libvk_swiftshader.so" "$APPDIR/libEGL.so" "$APPDIR/libGLESv2.so" \
          "$APPDIR/vk_swiftshader_icd.json" "$APPDIR/chrome_crashpad_handler" 2>/dev/null || true
  fi
  after="$(du -sm "$APPDIR" | cut -f1)"
  echo "==> 精简($PKG_STRIP): ${before}MB -> ${after}MB"
fi

# ---------------------------------------------------------------- 桌面入口 / 图标 / 命令链接
mkdir -p "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps" "$STAGE/usr/bin"
cat > "$STAGE/usr/share/applications/deepseek-harness.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=DeepSeek Harness desktop client (LoongArch64)
Exec=$PREFIX/deepseek-harness %U
Icon=deepseek-harness
Terminal=false
Categories=Development;Utility;
StartupWMClass=deepseek-harness
MimeType=x-scheme-handler/dsh;
EOF
[[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/256x256/apps/deepseek-harness.png"
ln -s "$PREFIX/deepseek-harness" "$STAGE/usr/bin/deepseek-harness"

# chrome-sandbox 需 setuid root 才能启用 Chromium 沙箱; 直接写进包权限,
# .INSTALL 里再兜一次(覆盖升级/权限被重置的情形)
[[ -f "$APPDIR/chrome-sandbox" ]] && chmod 4755 "$APPDIR/chrome-sandbox" 2>/dev/null || true

# ---------------------------------------------------------------- .PKGINFO
SIZE_KB="$(du -sk "$STAGE" | cut -f1)"
{
  echo "# Generated by make-pkg.sh (dsh_desktop-loong64)"
  echo "# $(date -u '+%a %b %d %H:%M:%S UTC %Y')"
  echo "pkgname = deepseek-harness"
  echo "pkgbase = deepseek-harness"
  echo "pkgver = ${PKGVER}-${PKG_REL}"
  echo "pkgdesc = DeepSeek Harness desktop client (LoongArch64)"
  echo "url = https://github.com/deepseek-ai/deepseek-harness"
  echo "builddate = $(date +%s)"
  echo "packager = dsh_desktop-loong64 <noreply@localhost>"
  echo "size = $((SIZE_KB * 1024))"
  echo "arch = ${CARCH}"
  echo "license = custom"
  for d in "${DEPENDS[@]}"; do echo "depend = $d"; done
} > "$STAGE/.PKGINFO"

# ---------------------------------------------------------------- .INSTALL
cat > "$STAGE/.INSTALL" <<'EOF'
# Arch 安装脚本 (pacman 以 root 执行)
post_install() {
  PREFIX=/opt/deepseek-harness
  if [ -f "$PREFIX/chrome-sandbox" ]; then
    chown root:root "$PREFIX/chrome-sandbox" 2>/dev/null || true
    chmod 4755 "$PREFIX/chrome-sandbox" 2>/dev/null || true
  fi
  chmod +x "$PREFIX/deepseek-harness" "$PREFIX/deepseek-harness.bin" 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  echo "DeepSeek Harness (LoongArch64) 已安装到 $PREFIX"
  echo "命令行: deepseek-harness   (本构建未签名, 自动更新通道为占位地址)"
}

post_upgrade() {
  post_install "$@"
}

post_remove() {
  rm -f /usr/bin/deepseek-harness 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
}
EOF

# ---------------------------------------------------------------- 打包
# .PKGINFO 必须是第一个成员, .INSTALL 次之
ENTRIES=(.PKGINFO .INSTALL)
mapfile -t rest < <(cd "$STAGE" && ls -A | grep -vx -e '.PKGINFO' -e '.INSTALL')
ENTRIES+=("${rest[@]}")

echo "==> 打包 (zstd -$ZSTD_LEVEL, 多线程)"
TMPTAR="$(mktemp)"
trap 'rm -rf "$STAGE" "$TMPTAR"' EXIT
# --owner/--group 强制归 root; setuid 位由文件系统 mode 保留
bsdtar -cf "$TMPTAR" --owner=0 --group=0 --numeric-owner -C "$STAGE" "${ENTRIES[@]}"
zstd -q -T0 "-$ZSTD_LEVEL" -f -o "$OUT/$PKG" "$TMPTAR"
rm -f "$TMPTAR"
# zstd 按 umask 建文件常得 600; 分发前放宽为 644
chmod 0644 "$OUT/$PKG"

echo
ls -lh "$OUT/$PKG"
echo "==> 完成: $OUT/$PKG"
echo
echo "安装:"
echo "  sudo pacman -U $OUT/$PKG"
echo "卸载:"
echo "  sudo pacman -R deepseek-harness"
echo "查询:"
echo "  pacman -Qip $OUT/$PKG       # 包信息"
echo "  pacman -Qlp $OUT/$PKG       # 文件清单"
