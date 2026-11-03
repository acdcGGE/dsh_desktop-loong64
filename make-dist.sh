#!/usr/bin/env bash
# =============================================================================
# make-dist.sh —— 把 electron-builder --dir 的 unpacked 产物打成龙芯可分发包
#
# 产出 (均在 dist/ 下):
#   deepseek-harness-<version>-linux-loong64.tar.gz   应用本体(可直接解压运行)
#   deepseek-harness.desktop                          XDG 桌面入口
#   install.sh                                        安装/卸载脚本
#   SHA256SUMS                                        校验值
#
# 用法: ./make-dist.sh [unpacked 目录]
#
# 说明: 本脚本只产出 tar.gz 一套; deb / pkg.tar.zst 分别由
#       make-deb.sh / make-pkg.sh 产出。三者都写在同一个 dist/ 下,
#       故这里清理时只删自己的产物, 不动同目录的 .deb / .pkg.tar.zst。
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH="${1:-}"
TARGETS="$HERE/../dsh/apps/desktop/.desktop-build/targets/linux-loong64"
OUT="$HERE/dist"
ARCH=loong64

if [[ -z "$DSH" ]]; then
  # 自动探测 electron-builder --dir 的产出目录
  # (unsigned 构建落在 unsigned-artifacts; 旧版本脚本可能落在 artifacts)
  for base in "$TARGETS/unsigned-artifacts" "$TARGETS/artifacts"; do
    [[ -d "$base" ]] || continue
    for candidate in "$base"/linux-*unpacked "$base"/linux-*; do
      if [[ -d "$candidate" && -f "$candidate/resources/app.asar" ]]; then DSH="$candidate"; break 2; fi
    done
  done
fi
[[ -n "$DSH" && -d "$DSH" ]] || { echo "错误: 找不到 unpacked 产物目录 (先运行 package:dir)" >&2; exit 1; }

VERSION="$(python3 -c "import json;print(json.load(open('$HERE/../dsh/apps/desktop/package.json'))['version'])")"
NAME="deepseek-harness-${VERSION}-linux-${ARCH}"
ICON_SRC="$HERE/../dsh/apps/desktop/resources/icon.png"

echo "==> 产物目录: $DSH"
echo "==> 版本:     $VERSION"

# 只清理本脚本自己产出的文件。
# 注意: 这里原本是 rm -rf "$OUT", 会把同目录下的 .deb / .pkg.tar.zst 一起删掉
# (sync-upstream.sh 一次流程会先后产出多种格式), 故改为按文件名精确清理。
mkdir -p "$OUT"
rm -f "$OUT"/deepseek-harness-*-linux-loong64.tar.gz \
      "$OUT"/deepseek-harness.desktop "$OUT"/install.sh 2>/dev/null || true

# ---------------------------------------------------------------- 桌面入口
cat > "$OUT/deepseek-harness.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=DeepSeek Harness desktop client (LoongArch64)
Exec=/opt/deepseek-harness/deepseek-harness %U
Icon=deepseek-harness
Terminal=false
Categories=Development;Utility;
StartupWMClass=deepseek-harness
MimeType=x-scheme-handler/dsh;
EOF

# ---------------------------------------------------------------- 安装脚本
cat > "$OUT/install.sh" <<'EOF'
#!/usr/bin/env bash
# DeepSeek Harness (LoongArch64) 安装脚本
#   ./install.sh            安装到 /opt/deepseek-harness
#   ./install.sh --user     安装到 ~/.local/share/deepseek-harness
#   ./install.sh --uninstall 卸载
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$(ls "$HERE"/deepseek-harness-*-linux-loong64.tar.gz | head -1)"

if [[ "${1:-}" == "--uninstall" ]]; then
  for prefix in /opt/deepseek-harness "$HOME/.local/share/deepseek-harness"; do
    [[ -d "$prefix" ]] && rm -rf "$prefix" && echo "已删除 $prefix"
  done
  rm -f "$HOME/.local/share/applications/deepseek-harness.desktop"
  rm -f "$HOME/.local/share/icons/deepseek-harness.png"
  echo "卸载完成"
  exit 0
fi

if [[ "${1:-}" == "--user" ]]; then
  PREFIX="$HOME/.local/share/deepseek-harness"
  BIN_DIR="$HOME/.local/bin"
  APP_DIR="$HOME/.local/share/applications"
  ICON_DIR="$HOME/.local/share/icons"
  SUDO=""
else
  PREFIX=/opt/deepseek-harness
  BIN_DIR=/usr/local/bin
  APP_DIR=/usr/local/share/applications
  ICON_DIR=/usr/share/icons/hicolor/256x256/apps
  SUDO="sudo"
  [[ "$(id -u)" -eq 0 ]] && SUDO=""
fi

echo "==> 解压到 $PREFIX"
$SUDO rm -rf "$PREFIX"
$SUDO mkdir -p "$PREFIX"
$SUDO tar -xzf "$TARBALL" -C "$PREFIX" --strip-components=1
$SUDO chmod +x "$PREFIX/deepseek-harness" "$PREFIX/deepseek-harness.bin" 2>/dev/null || \
  $SUDO chmod +x "$PREFIX/deepseek-harness"

echo "==> 创建命令链接"
$SUDO mkdir -p "$BIN_DIR"
$SUDO ln -sf "$PREFIX/deepseek-harness" "$BIN_DIR/deepseek-harness"

echo "==> 安装图标与桌面入口"
$SUDO mkdir -p "$ICON_DIR" "$APP_DIR"
if [[ -f "$PREFIX/resources/icon.png" ]]; then
  $SUDO cp "$PREFIX/resources/icon.png" "$ICON_DIR/deepseek-harness.png"
fi
$SUDO cp "$HERE/deepseek-harness.desktop" "$APP_DIR/deepseek-harness.desktop"
command -v update-desktop-database >/dev/null 2>&1 && $SUDO update-desktop-database "$APP_DIR" || true

echo
echo "安装完成。可从应用菜单启动，或执行: deepseek-harness"
echo "卸载: $0 --uninstall"
EOF
chmod 0755 "$OUT/install.sh"

# ---------------------------------------------------------------- 打包
echo "==> 打包 tar.gz"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/$NAME"
cp -a "$DSH"/. "$STAGE/$NAME/"
if [[ -f "$ICON_SRC" ]]; then cp "$ICON_SRC" "$STAGE/$NAME/resources/icon.png"; fi

# 龙芯启动器: 把 electron 二进制重命名为 .bin, 用 wrapper 包装
# (清除 ELECTRON_RUN_AS_NODE + 强制 X11 Ozone, 详见 deepseek-harness-launcher.sh)
LAUNCHER="$HERE/deepseek-harness-launcher.sh"
if [[ -f "$STAGE/$NAME/deepseek-harness" && -f "$LAUNCHER" ]]; then
  mv "$STAGE/$NAME/deepseek-harness" "$STAGE/$NAME/deepseek-harness.bin"
  cp "$LAUNCHER" "$STAGE/$NAME/deepseek-harness"
  chmod 0755 "$STAGE/$NAME/deepseek-harness" "$STAGE/$NAME/deepseek-harness.bin"
  echo "==> 已注入龙芯启动器 (deepseek-harness -> wrapper, 二进制为 .bin)"
fi

tar -czf "$OUT/$NAME.tar.gz" -C "$STAGE" "$NAME"
rm -rf "$STAGE"

echo "==> 生成校验值"
# 校验值覆盖 dist 下所有大件 (deb/pkg 可能由同一次同步流程产出), 而非只有本脚本的产物
( cd "$OUT" && find . -maxdepth 1 -type f \( -name '*.deb' -o -name '*.pkg.tar.zst' \
    -o -name "$NAME.tar.gz" -o -name 'deepseek-harness.desktop' -o -name 'install.sh' \) \
    -printf '%P\n' | sort | xargs -r sha256sum > SHA256SUMS )

echo
ls -la "$OUT"
echo
echo "==> 完成: $OUT/$NAME.tar.gz"
