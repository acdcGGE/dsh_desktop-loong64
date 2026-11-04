#!/usr/bin/env bash
# =============================================================================
# make-deb.sh —— 把 electron-builder --dir 的 unpacked 产物打成 loong64 .deb
#
# 产出: dist/deepseek-harness_<version>-<rev>_loong64.deb
#
# 用法:
#   ./make-deb.sh [unpacked目录]     省略则自动探测
#   DEB_REVISION=3 ./make-deb.sh     自定义 Debian revision (默认 1)
#   DEB_STRIP=0 ./make-deb.sh        不做精简(保留全部 locale / swiftshader)
#   DEB_STRIP=aggressive ./make-deb.sh  再删 SwiftShader 软渲染库
#   DSH_SRC_TREE=/path/to/dsh ./make-deb.sh   指定上游源码树
#
# 说明:
#   - 安装前缀固定 /opt/deepseek-harness, 并在 /usr/bin 建命令链接
#   - 依赖声明按宿主发行版自适应: Debian/Ubuntu 写 Electron 运行时依赖;
#     其他发行版(如 Arch/loong64)不写, 避免 dpkg -i 因依赖名不匹配而失败
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
ARCH=loong64
OUT="$HERE/dist"
TARGETS="$SRC_TREE/apps/desktop/.desktop-build/targets/linux-loong64"
DSH="${1:-}"
DEB_REVISION="${DEB_REVISION:-1}"
DEB_STRIP="${DEB_STRIP:-1}"

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
# Debian 版本规范: upstream 版本里不能出现 '-', 用 '~' 表示预发布(排序低于正式版)
# 注意 '~' 必须经变量引入, 直接写进 ${VAR//x/~} 会被 shell 做 tilde 展开
TILDE='~'
DEB_VER="${VERSION//-/$TILDE}-${DEB_REVISION}"
PKG="deepseek-harness_${DEB_VER}_${ARCH}.deb"
ICON_SRC="$SRC_TREE/apps/desktop/resources/icon.png"
LAUNCHER="$HERE/deepseek-harness-launcher.sh"
PREFIX=/opt/deepseek-harness

echo "==> 产物目录: $DSH"
echo "==> 源码树:   $SRC_TREE"
echo "==> 上游版本: $VERSION"
echo "==> deb 版本: $DEB_VER"

# ---------------------------------------------------------------- 依赖声明
# Electron/Chromium 在 Debian 系上的常见运行时依赖; 其他发行版(如 Arch/loong64)包名
# 不同, 故不写, 避免 dpkg -i 因依赖名不匹配而失败。
# 注意: 4 个原生 Python 轮子 (numpy/pandas/lxml/pillow) 链接的是本机构建机的系统库,
#   故必须把它们的运行时 .so 所属 apt 包全部声明为 Depends, 目标机 dpkg -i 时由 apt
#   解析安装。包名均为无版本号的标准包: libblas3 会带 libgfortran5, libxml2 会带 ICU。
DEPENDS=""
is_deb_family() {
  if [[ -f /etc/os-release ]]; then
    # 仅 source 需要的值, 不污染环境
    local id like
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    like="$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")"
    case " $like $id " in
      *debian*|*ubuntu*|*deepin*|*raspbian*|*devuan*|*kali*) return 0 ;;
    esac
  fi
  return 1
}
if is_deb_family; then
  DEPENDS="libc6, libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, \
libatspi2.0-0, libdrm2, libgbm1, libasound2, libcups2, libxkbcommon0, \
libpango-1.0-0, libcairo2, libsecret-1-0, \
libblas3, liblapack3, libxml2, libxslt1.1, libfreetype6, libjpeg62-turbo, \
libimagequant0, libraqm0, liblcms2-2, libtiff6, libwebp7, libwebpdemux2, \
libwebpmux3, libxcb1, zlib1g"
  echo "==> 宿主为 Debian 系 (dpkg/apt), 写入 Electron + Python 运行时依赖"
else
  echo "==> 宿主非 Debian 系, Depends 留空 (避免依赖名不匹配导致安装失败)"
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

# 龙芯启动器注入 (清 ELECTRON_RUN_AS_NODE + 强制 X11 Ozone)
if [[ -f "$APPDIR/deepseek-harness" && -f "$LAUNCHER" ]]; then
  mv "$APPDIR/deepseek-harness" "$APPDIR/deepseek-harness.bin"
  cp "$LAUNCHER" "$APPDIR/deepseek-harness"
  chmod 0755 "$APPDIR/deepseek-harness" "$APPDIR/deepseek-harness.bin"
  echo "==> 已注入龙芯启动器"
fi

# ---------------------------------------------------------------- 精简 (可选)
if [[ "$DEB_STRIP" != "0" ]]; then
  before="$(du -sm "$APPDIR" | cut -f1)"
  # Chromium 许可证/第三方声明: 纯文档, 运行时不读取
  rm -f "$APPDIR/LICENSES.chromium.html" 2>/dev/null || true
  # 只保留中英文语言包, 其余 .pak 不会被加载但占磁盘
  if [[ -d "$APPDIR/locales" ]]; then
    find "$APPDIR/locales" -name '*.pak' ! -name 'zh-CN.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
  fi
  # aggressive: 再删 SwiftShader 软渲染库 (与启动器默认 --disable-gpu 配套;
  # 若改用 DSH_DESKTOP_NO_GPU=0 启动则需用 DEB_STRIP=1 保留)
  if [[ "$DEB_STRIP" == "aggressive" ]]; then
    rm -f "$APPDIR/libvk_swiftshader.so" "$APPDIR/libEGL.so" "$APPDIR/libGLESv2.so" \
          "$APPDIR/vk_swiftshader_icd.json" "$APPDIR/chrome_crashpad_handler" 2>/dev/null || true
  fi
  after="$(du -sm "$APPDIR" | cut -f1)"
  echo "==> 精简($DEB_STRIP): ${before}MB -> ${after}MB"
fi

# ---------------------------------------------------------------- DEBIAN 控制文件
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: deepseek-harness
Version: $DEB_VER
Section: devel
Priority: optional
Architecture: $ARCH
Maintainer: dsh_desktop-loong64 <noreply@localhost>
Homepage: https://github.com/deepseek-ai/deepseek-harness
Installed-Size: $(du -sk "$APPDIR" | cut -f1)
EOF
if [[ -n "$DEPENDS" ]]; then echo "Depends: $DEPENDS" >> "$STAGE/DEBIAN/control"; fi
cat >> "$STAGE/DEBIAN/control" <<EOF
Description: DeepSeek Harness desktop client (LoongArch64)
 Community build of the DeepSeek Harness desktop client for
 LoongArch64 (loong64) hosts, based on Electron.
 This is an unsigned local build; the update channel points at a
 placeholder origin and no automatic updates are performed.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
PREFIX=/opt/deepseek-harness
# chrome-sandbox 需要 setuid root 才能启用 Chromium 沙箱
if [ -f "$PREFIX/chrome-sandbox" ]; then
  chown root:root "$PREFIX/chrome-sandbox" 2>/dev/null || true
  chmod 4755 "$PREFIX/chrome-sandbox" 2>/dev/null || true
fi
chmod +x "$PREFIX/deepseek-harness" "$PREFIX/deepseek-harness.bin" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
rm -f /usr/bin/deepseek-harness 2>/dev/null || true
exit 0
EOF

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
rm -rf /opt/deepseek-harness 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

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

# ---------------------------------------------------------------- 构建
echo "==> dpkg-deb --build (zstd)"
# mktemp 默认 700; 包内根目录应为 755, 否则 dpkg 会写入异常的根权限
chmod 0755 "$STAGE"
fakeroot dpkg-deb --build -Zzstd "$STAGE" "$OUT/$PKG"

echo
ls -lh "$OUT/$PKG"
echo "==> 完成: $OUT/$PKG"
echo
echo "安装:"
echo "  sudo dpkg -i $OUT/$PKG"
echo "  (非 Debian 系宿主若报依赖问题: sudo dpkg -i --force-depends $OUT/$PKG)"
echo "卸载:"
echo "  sudo dpkg -r deepseek-harness"
