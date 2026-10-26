#!/usr/bin/env bash
# vpn-run.sh — root 属主的启动包装脚本（sudoers 只放行这一个脚本）
#
# 为什么需要它：过去 sudoers 直接放行 openvpn 二进制，而 openvpn 接受任意参数与任意配置文件 ——
# 任何以该用户身份运行的进程都能免密以 root 启动一份自己写的配置，配置文件里的 up/down/plugin/
# script-security 等指令足以在 root 下执行代码。这里把权限面收窄成：
#   只接受 validate / start / stop / status 四个动作、只接受"数据参数"（不接受 openvpn 参数）、
#   对配置做指令白名单校验、引擎路径写死。
#
# 由 app 的「授权 VPN…」安装到 /usr/local/vpnstatusbar/vpn-run.sh（root:wheel 755），
# sudoers 规则：<user> ALL=(root) NOPASSWD: /usr/local/vpnstatusbar/vpn-run.sh
#
# 注意：本脚本被 root 属主固定安装，**改它需要重新授权**。可变的逻辑（参数拼装以外的部分、
# 会话分隔、日志轮转）都在用户侧的 vpn-runner.sh 里，那个随 app 更新即可。
#
# 用法：
#   vpn-run.sh validate <ovpn>                        # 不需要 root：供 app 预检与 CI 使用
#   vpn-run.sh start --ovpn <f> --auth <f> --log <f> [--session-note <一行>] [--mgmt-password-file <f>]
#   vpn-run.sh stop                                   # 兜底停隧道（主路径是 management 接口）
#   vpn-run.sh status                                 # 打印引擎版本（app 用它做"是否已授权"探测）
set -euo pipefail

ENGINE="/usr/local/vpnstatusbar/openvpn"
PID_FILE="/usr/local/vpnstatusbar/openvpn.pid"
MGMT_PORT="7505"
MAX_CONFIG_BYTES=$((1024 * 1024))

# 危险指令：能让 openvpn 以 root 执行外部程序、或改进程行为/日志/接口归属。
# 公司配置不含这些；确需脚本类指令的配置请走管理员定制的白名单（文档里有说明）。
FORBIDDEN_RE='^[[:space:]]*(up|down|route-up|route-pre-down|tls-verify|iproute|learn-address|client-connect|client-disconnect|plugin|script-security|auth-user-pass-verify|daemon|writepid|user|group|chroot|cd|tmp-dir|log|log-append|management|config|setenv|setenv-safe|status|ifconfig|dev-node)[[:space:]]'

die() { echo "❌ $*" >&2; exit 1; }

caller_name() { echo "${SUDO_USER:-$(id -un)}"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "该动作需要以管理员权限运行（app 会通过 sudoers 免密调用）"; }

# 配置文件校验：必须存在、是普通文件、属主=调用者、非组/其他可写、不含危险指令
validate_config() {
    local cfg="${1:-}" owner mode group_w other_w size hit
    [ -n "${cfg}" ] || die "缺少配置文件参数"
    [ -f "${cfg}" ] || die "配置文件不存在：${cfg}"
    [ -L "${cfg}" ] && die "配置文件不能是符号链接：${cfg}"

    owner="$(stat -f '%Su' "${cfg}")"
    [ "${owner}" = "$(caller_name)" ] || die "配置文件属主必须是当前用户：${cfg}（属主为 ${owner}）"

    mode="$(stat -f '%Lp' "${cfg}")"
    group_w=$(( (mode / 10) % 10 & 2 ))
    other_w=$(( mode % 10 & 2 ))
    [ "${group_w}" -eq 0 ] && [ "${other_w}" -eq 0 ] || die "配置文件不能对组/其他用户可写：${cfg}（当前权限 ${mode}）"

    size="$(stat -f '%z' "${cfg}")"
    [ "${size}" -le "${MAX_CONFIG_BYTES}" ] || die "配置文件过大（${size} 字节），拒绝启动"

    hit="$(grep -nE "${FORBIDDEN_RE}" "${cfg}" 2>/dev/null | head -3 || true)"
    [ -z "${hit}" ] || die "配置包含不支持的指令（安全策略）：$(echo "${hit}" | tr '\n' ' ')"
    echo "✅ 配置校验通过：${cfg}"
}

validate_auth_file() {
    local auth="${1:-}" owner mode
    [ -n "${auth}" ] || die "缺少认证文件参数"
    [ -f "${auth}" ] || die "认证文件不存在：${auth}"
    [ -L "${auth}" ] && die "认证文件不能是符号链接：${auth}"
    owner="$(stat -f '%Su' "${auth}")"
    [ "${owner}" = "$(caller_name)" ] || die "认证文件属主必须是当前用户：${auth}"
    mode="$(stat -f '%Lp' "${auth}")"
    [ "$(( mode % 100 ))" -eq 0 ] || die "认证文件权限必须是 600（当前 ${mode}）"
}

# ---------- 分派 ----------
ACTION="${1:-}"
shift || true

case "${ACTION}" in
    validate)
        validate_config "${1:-}"
        ;;

    status)
        # 打印引擎版本：app 通过 `sudo -n vpn-run.sh status` 的退出码判断"是否已免密授权"，
        # 并从输出里解析版本/架构（与 EngineAuthorizer.parseVersion 的格式约定保持一致）
        [ -x "${ENGINE}" ] || die "引擎不存在或不可执行：${ENGINE}"
        exec "${ENGINE}" --version
        ;;

    stop)
        require_root
        if [ -f "${PID_FILE}" ]; then
            pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
            if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
                kill -TERM "${pid}" 2>/dev/null || true
                sleep 1
                kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
                echo "已停止 openvpn（pid ${pid}）"
            else
                echo "pid 文件存在但进程已不在（${pid}）"
            fi
            rm -f "${PID_FILE}"
        else
            echo "没有记录在案的 openvpn 进程"
        fi
        ;;

    start)
        require_root
        OVPN=""; AUTH=""; LOG=""; SESSION_NOTE=""; MGMT_PASSWORD_FILE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --ovpn)                OVPN="${2:-}"; shift 2 ;;
                --auth)                AUTH="${2:-}"; shift 2 ;;
                --log)                 LOG="${2:-}"; shift 2 ;;
                --session-note)        SESSION_NOTE="${2:-}"; shift 2 ;;
                --mgmt-password-file)  MGMT_PASSWORD_FILE="${2:-}"; shift 2 ;;
                *) die "不支持的参数：$1" ;;
            esac
        done

        [ -x "${ENGINE}" ] || die "引擎不存在或不可执行：${ENGINE}"
        validate_config "${OVPN}"
        validate_auth_file "${AUTH}"
        [ -n "${LOG}" ] || die "缺少日志文件参数"

        # 日志为追加模式（app 按会话分隔行切片判断凭据错误）
        [ -e "${LOG}" ] || : > "${LOG}"
        [ -n "${SESSION_NOTE}" ] && printf '%s\n' "${SESSION_NOTE}" >> "${LOG}"
        # 日志必须让调用者（普通用户）能读、能追加，否则 app 面板读不到日志
        chown "$(caller_name)" "${LOG}" 2>/dev/null || true

        MGMT_ARGS=(--management 127.0.0.1 "${MGMT_PORT}")
        if [ -n "${MGMT_PASSWORD_FILE}" ]; then
            [ -r "${MGMT_PASSWORD_FILE}" ] || die "management 密码文件不可读：${MGMT_PASSWORD_FILE}"
            MGMT_ARGS=(--management 127.0.0.1 "${MGMT_PORT}" "${MGMT_PASSWORD_FILE}")
        fi

        # 记录 pid 供 stop 兜底（exec 后 pid 不变）
        echo $$ > "${PID_FILE}"
        chmod 644 "${PID_FILE}" 2>/dev/null || true

        exec "${ENGINE}" \
            --config "${OVPN}" \
            --auth-user-pass "${AUTH}" \
            --connect-retry 5 \
            --connect-retry-max 0 \
            --ping 15 \
            --ping-restart 60 \
            --auth-nocache \
            --log-append "${LOG}" \
            "${MGMT_ARGS[@]}"
        ;;

    ""|-h|--help|help)
        sed -n '2,30p' "$0"
        ;;

    *)
        die "未知动作：${ACTION}（支持 validate / start / stop / status）"
        ;;
esac
