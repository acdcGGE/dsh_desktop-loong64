#!/usr/bin/env bash
# =============================================================================
# DeepSeek Harness (LoongArch64) 启动器
#
# 龙芯 (loong64) 环境下 electron 桌面端的两个常见坑:
#   1) ELECTRON_RUN_AS_NODE 可能被外部环境(某些 agent/IDE 环境)误置为 1,
#      导致 electron 二进制退化为纯 Node.js, 直接弹出 Node REPL 而非桌面应用。
#   2) 部分 loong64 chromium 默认选择 Wayland 显示后端却无法连接, 报
#      "Failed to initialize Wayland platform ... Exiting"。
#      显式使用 X11 Ozone 后端即可正常出窗。
#
# 本启动器:
#   - 清除 ELECTRON_RUN_AS_NODE, 确保进入真正的 Electron 模式
#   - 通过 --ozone-platform 显式指定显示后端 (默认 x11, 可用环境变量覆盖)
#   - 其余参数原样转发给底层 electron 二进制
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 底层 electron 二进制 (由 electron-builder 产出, 此处已重命名为 .bin)
BIN="$HERE/deepseek-harness.bin"
if [[ ! -x "$BIN" ]]; then
  # 兜底: 若未重命名, 直接使用同名二进制
  BIN="$HERE/deepseek-harness"
fi

# 1) 清除可能让 electron 退化为 node 的环境变量
unset ELECTRON_RUN_AS_NODE

# 2) 显示后端: 默认 x11; 可通过 DSH_DESKTOP_OZONE_PLATFORM 覆盖
OZONE="${DSH_DESKTOP_OZONE_PLATFORM:-x11}"
export ELECTRON_OZONE_PLATFORM_HINT="$OZONE"

exec "$BIN" --ozone-platform="$OZONE" "$@"
