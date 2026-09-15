#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   ./build-headless.sh [解包目录] [输出目录]
# 默认从 app/ 读取，输出到 dist/yunshu-headless/

SRC="${1:-app}"
OUT="${2:-dist/yunshu-headless}"
APP_FILES="$OUT/opt/apps/yunshu/files"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d "$SRC/opt/apps/yunshu/files" ] || {
  echo "未找到 $SRC/opt/apps/yunshu/files" >&2
  exit 1
}

mkdir -p \
  "$APP_FILES/bin/exec" \
  "$APP_FILES/config" \
  "$APP_FILES/socket" \
  "$APP_FILES/tmp" \
  "$APP_FILES/bak" \
  "$APP_FILES/logs" \
  "$APP_FILES/script" \
  "$APP_FILES/system"

# 仅保留无 GUI 运行所需的核心二进制。
cp -a "$SRC/opt/apps/yunshu/files/bin/yunshu"          "$APP_FILES/bin/yunshu"
cp -a "$SRC/opt/apps/yunshu/files/bin/yunshu-daemon"   "$APP_FILES/bin/yunshu-daemon"
cp -a "$SRC/opt/apps/yunshu/files/bin/yunshu-updater"  "$APP_FILES/bin/yunshu-updater"
cp -a "$SRC/opt/apps/yunshu/files/bin/libtunnel.so"    "$APP_FILES/bin/libtunnel.so"
cp -a "$SRC/opt/apps/yunshu/files/bin/exec/executor"   "$APP_FILES/bin/exec/executor"

cp -a "$SRC/opt/apps/yunshu/files/config/version.ini"  "$APP_FILES/config/version.ini"

# systemd 单元仅作参考，安装脚本会生成绝对路径版本。
cp -a "$SRC/opt/apps/yunshu/files/system/yunshu-daemon.service"  "$APP_FILES/system/yunshu-daemon.service"
cp -a "$SRC/opt/apps/yunshu/files/system/yunshu-updater.service" "$APP_FILES/system/yunshu-updater.service"

# 原 data.tar 中部分文件是 0644，必须修正为可执行。
chmod 0755 \
  "$APP_FILES/bin/yunshu" \
  "$APP_FILES/bin/yunshu-daemon" \
  "$APP_FILES/bin/yunshu-updater" \
  "$APP_FILES/bin/exec/executor"
chmod 0644 "$APP_FILES/bin/libtunnel.so"

# 附带运行/安装脚本。
cp -a "$SCRIPT_DIR/yunshu-headless-install.sh" "$OUT/install.sh"
cp -a "$SCRIPT_DIR/yunshu-login.sh"            "$OUT/yunshu-login.sh"
cp -a "$SCRIPT_DIR/supervise/run.sh"           "$OUT/supervise-run.sh"
cp -a "$SCRIPT_DIR/README.md"                  "$OUT/README.md"
chmod 0755 "$OUT/install.sh" "$OUT/yunshu-login.sh" "$OUT/supervise-run.sh"

echo "无 GUI payload 已生成: $OUT"
du -sh "$OUT"
