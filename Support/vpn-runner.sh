#!/usr/bin/env bash
# vpn-runner.sh — app 侧的启动器（以普通用户身份运行，由 VPNStatusBar.app 调用）
#
# 职责边界（v4 起，配合 sudoers 收严）：
#   - 这里只做"用户侧"的事：参数解析、预检、把参数交给 root 属主的包装脚本；
#   - 真正的 openvpn 参数拼装、配置指令白名单校验、引擎路径，都在
#     /usr/local/vpnstatusbar/vpn-run.sh（root:wheel，sudoers 只放行它）里。
#   这样权限面收窄到那一个脚本，而本脚本随 app 更新即可（无需重新授权）。
#
# 用法：
#   vpn-runner.sh --ovpn <配置> --auth <认证文件> --log <日志> [--session-note <一行>] [--mgmt-password-file <文件>]
set -euo pipefail

WRAPPER="/usr/local/vpnstatusbar/vpn-run.sh"

CONFIG_FILE=""
AUTH_FILE=""
LOG_FILE=""
SESSION_NOTE=""
MGMT_PASSWORD_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ovpn)                CONFIG_FILE="${2:-}"; shift 2 ;;
    --auth)                AUTH_FILE="${2:-}"; shift 2 ;;
    --log)                 LOG_FILE="${2:-}"; shift 2 ;;
    --session-note)        SESSION_NOTE="${2:-}"; shift 2 ;;
    --mgmt-password-file)  MGMT_PASSWORD_FILE="${2:-}"; shift 2 ;;
    --openvpn)             shift 2 ;;   # 历史参数：引擎路径现在由包装脚本固定，这里忽略
    *) shift ;;
  esac
done

[ -x "$WRAPPER" ] || { echo "❌ 未安装启动包装脚本（$WRAPPER）。请在 app 设置里「授权 VPN…」。" >&2; exit 1; }
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || { echo "❌ 找不到配置文件（--ovpn）" >&2; exit 1; }
[ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] || { echo "❌ 找不到认证文件（--auth）" >&2; exit 1; }
[ -n "$LOG_FILE" ] || LOG_FILE="$HOME/Library/Application Support/VPNStatusBar/vpn.log"

# 先本地跑一次白名单校验（不需要 root）：危险配置在弹提权之前就给出明确原因
"$WRAPPER" validate "$CONFIG_FILE" >&2 || exit 1

ARGS=(start --ovpn "$CONFIG_FILE" --auth "$AUTH_FILE" --log "$LOG_FILE")
[ -n "$SESSION_NOTE" ] && ARGS+=(--session-note "$SESSION_NOTE")
[ -n "$MGMT_PASSWORD_FILE" ] && ARGS+=(--mgmt-password-file "$MGMT_PASSWORD_FILE")

exec sudo -n "$WRAPPER" "${ARGS[@]}"
