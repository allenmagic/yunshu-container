#!/usr/bin/env bash
set -euo pipefail

# 交互式登录入口。飞书 SSO 由服务端 IdP 完成，客户端只需打开浏览器/扫码后等待 token。
#
# 用法:
#   ./yunshu-login.sh <企业码>
#   YUNSHU_CORP_CODE=<企业码> ./yunshu-login.sh

YUNSHU_BIN="${YUNSHU_BIN:-/opt/apps/yunshu/files/bin/yunshu}"
CORP_CODE="${1:-${YUNSHU_CORP_CODE:-}}"

if [ -z "$CORP_CODE" ]; then
  echo "用法: $0 <企业码>" >&2
  exit 2
fi

if [ ! -x "$YUNSHU_BIN" ]; then
  echo "未找到 $YUNSHU_BIN" >&2
  exit 1
fi

# 无图形环境可自行指定浏览器；否则由 yunshu 尝试打开系统浏览器或终端二维码。
export BROWSER="${BROWSER:-}"
exec "$YUNSHU_BIN" -c "$CORP_CODE" -l
