#!/usr/bin/env bash
set -euo pipefail

# 无 systemd 环境下的简单前台/后台启动脚本。
BASE="/opt/apps/yunshu/files/bin"
LOG_DIR="/opt/apps/yunshu/files/logs"

mkdir -p "$LOG_DIR"

start_daemon() {
  "$BASE/yunshu-daemon" -d >>"$LOG_DIR/daemon.log" 2>&1 &
  echo $! > /run/yunshu-daemon.pid
}

start_updater() {
  "$BASE/yunshu-updater" -d >>"$LOG_DIR/updater.log" 2>&1 &
  echo $! > /run/yunshu-updater.pid
}

start_daemon
start_updater

echo "yunshu-daemon pid: $(cat /run/yunshu-daemon.pid)"
echo "yunshu-updater pid: $(cat /run/yunshu-updater.pid)"

wait
