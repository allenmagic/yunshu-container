#!/usr/bin/env bash
set -euo pipefail

# 在目标 microVM 内以 root 运行。
# 安装路径被二进制硬编码为 /opt/apps/yunshu，不可改动。

INSTALL_PATH="/opt/apps/yunshu"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

SP_ADDR="${YUNSHU_SP_ADDR:-https://sp.eagleyun.cn/}"
CORP_CODE="${YUNSHU_CORP_CODE:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "必须以 root 运行" >&2
  exit 1
fi

mkdir -p "$INSTALL_PATH"
cp -a "$SRC_DIR/opt/apps/yunshu/files" "$INSTALL_PATH/files"

chmod 0755 \
  "$INSTALL_PATH/files/bin" \
  "$INSTALL_PATH/files/bin/yunshu" \
  "$INSTALL_PATH/files/bin/yunshu-daemon" \
  "$INSTALL_PATH/files/bin/yunshu-updater" \
  "$INSTALL_PATH/files/bin/exec/executor" \
  "$INSTALL_PATH/files/socket" \
  "$INSTALL_PATH/files/tmp" \
  "$INSTALL_PATH/files/bak" \
  "$INSTALL_PATH/files/logs" \
  "$INSTALL_PATH/files/config"
chmod 0644 "$INSTALL_PATH/files/bin/libtunnel.so"

# 生成运行配置（等价于原 postinst 的 check_private_conf / replace_private_conf 的最小实现）。
if [ ! -f "$INSTALL_PATH/files/config/private_ctl.conf" ]; then
  printf '%s\n' "$SP_ADDR" > "$INSTALL_PATH/files/config/private_ctl.conf"
fi

if [ ! -f "$INSTALL_PATH/files/config/app_config.json" ]; then
  printf '{\n  "corpcode": "%s",\n  "sp_addr": "%s"\n}\n' \
    "$CORP_CODE" "$SP_ADDR" > "$INSTALL_PATH/files/config/app_config.json"
fi

ln -sf "$INSTALL_PATH/files/bin/yunshu" /usr/local/bin/yunshu

if command -v systemctl >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/yunshu-daemon.service <<EOF
[Unit]
Description=yunshu headless daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH/files/bin/yunshu-daemon -d
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/yunshu-updater.service <<EOF
[Unit]
Description=yunshu headless updater
After=network-online.target yunshu-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH/files/bin/yunshu-updater -d
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable yunshu-daemon yunshu-updater
  systemctl start yunshu-daemon yunshu-updater
else
  echo "未检测到 systemd，使用 supervise-run.sh 手动拉起" >&2
fi

echo "安装完成: $INSTALL_PATH"
echo "登录: $SRC_DIR/yunshu-login.sh <企业码>"
