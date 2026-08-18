#!/usr/bin/env bash
# VPN 启动脚本 v3 — 内置自包含 openvpn 引擎（由 VPNStatusBar.app 调用）
#
# 用法：
#   vpn-runner.sh --openvpn <引擎路径> --ovpn <配置路径> --auth <认证文件路径> [--log <日志路径>]
#
# v3 变化：openvpn 静态编译打进 app，首次授权时同步到稳定路径
#          /usr/local/vpnstatusbar/openvpn 并写入 sudoers 免密。
#          脚本用 --openvpn 直接指定该引擎，不再要求 brew 安装。
# 兼容：不传 --openvpn 时回退旧探测（brew 多路径 + 同目录 dev-ai.ovpn/.user）。
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 参数解析 ----------
OPENVPN_PATH=""
CONFIG_FILE=""
AUTH_FILE=""
LOG_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --openvpn) OPENVPN_PATH="$2"; shift 2 ;;
    --ovpn)    CONFIG_FILE="$2"; shift 2 ;;
    --auth)    AUTH_FILE="$2"; shift 2 ;;
    --log)     LOG_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ---------- 探测 openvpn（优先 --openvpn，回退探测）----------
OPENVPN=""
if [ -n "$OPENVPN_PATH" ] && [ -x "$OPENVPN_PATH" ]; then OPENVPN="$OPENVPN_PATH"; fi
if [ -z "$OPENVPN" ]; then
  list_openvpn_candidates() {
    local p
    for p in \
        /usr/local/vpnstatusbar/openvpn \
        /opt/homebrew/sbin/openvpn \
        /usr/local/sbin/openvpn \
        /opt/homebrew/opt/openvpn/sbin/openvpn \
        /usr/local/opt/openvpn/sbin/openvpn \
        /usr/local/bin/openvpn \
        /usr/sbin/openvpn; do
      [ -x "$p" ] && echo "$p"
    done
    command -v openvpn 2>/dev/null || true
  }
  for c in $(list_openvpn_candidates); do
    if sudo -n -l "$c" >/dev/null 2>&1; then OPENVPN="$c"; break; fi
  done
  [ -z "$OPENVPN" ] && OPENVPN="$(list_openvpn_candidates | head -1)"
fi

if [ -z "$OPENVPN" ]; then
  echo "❌ 未找到 openvpn 可执行文件。请在 app 设置中授权 VPN 引擎。" >&2
  exit 1
fi

if ! sudo -n -l "$OPENVPN" >/dev/null 2>&1; then
  echo "❌ openvpn（$OPENVPN）缺少 sudo 免密权限。请在 app 设置中「授权 VPN…」。" >&2
  exit 1
fi

# ---------- 兼容旧调用（无 --ovpn/--auth 时读同目录文件）----------
if [ -z "$CONFIG_FILE" ] && [ -f "$BASE_DIR/dev-ai.ovpn" ]; then CONFIG_FILE="$BASE_DIR/dev-ai.ovpn"; fi
if [ -z "$AUTH_FILE" ] && [ -f "$BASE_DIR/.user" ]; then
  # shellcheck disable=SC1090
  source "$BASE_DIR/.user"
  if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
    umask 077
    AUTH_FILE="$BASE_DIR/.auth.tmp"
    cat > "$AUTH_FILE" <<EOF
$USERNAME
$PASSWORD
EOF
    chmod 600 "$AUTH_FILE"
  fi
fi

[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || { echo "❌ 找不到配置文件（--ovpn）" >&2; exit 1; }
[ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] || { echo "❌ 找不到认证文件（--auth）" >&2; exit 1; }
[ -n "$LOG_FILE" ] || LOG_FILE="$BASE_DIR/vpn.log"

rm -f "$LOG_FILE"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

exec sudo -n "$OPENVPN" \
    --config "$CONFIG_FILE" \
    --auth-user-pass "$AUTH_FILE" \
    --connect-retry 5 \
    --connect-retry-max 0 \
    --ping 15 \
    --ping-restart 60 \
    --auth-nocache \
    --log "$LOG_FILE" \
    --management 127.0.0.1 7505
