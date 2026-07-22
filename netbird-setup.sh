#!/bin/sh
# shellcheck shell=dash
# NetBird 首次开机接入脚本
# 由 reinstall.sh 的 --setup-key 触发，在目标系统首次开机、网络就绪后执行：
#   安装 netbird -> 启动 netbird 守护进程 -> netbird up 加入虚拟局域网
# systemd 目标经 netbird-setup.service 调用，Alpine 经 /etc/init.d/netbird-setup 调用
#
# 设计要点：
# - 幂等、可重试：联网成功前不删除 key、不禁用服务，下次开机会再次尝试
# - 不中断开机：任何失败都以 exit 0 结束，交由「下次开机重跑」兜底
# - 不泄露 key：key 仅存于 0600 文件，用 --setup-key-file 传入，日志不回显

# 路径与次数默认值，允许用环境变量覆盖（主要用于测试，生产使用默认值）
KEY_FILE="${NETBIRD_SETUP_KEY_FILE:-/etc/netbird-setup/setup-key}"
LOG_FILE="${NETBIRD_SETUP_LOG_FILE:-/var/log/netbird-setup.log}"
# 最多尝试 netbird up 的次数（单次开机内），间隔递增
MAX_TRIES="${NETBIRD_SETUP_MAX_TRIES:-6}"

log() {
    echo "[netbird-setup] $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) $*"
}

# 主守卫：没有 key 文件说明未配置或已完成，直接退出
[ -f "$KEY_FILE" ] || exit 0

# 全程记录日志，但不回显 key 本身
{
    log "start"

    is_connected() {
        netbird status 2>/dev/null | grep -q 'Management: Connected'
    }

    # 检测包管理器（仅用于在缺少 curl/tar 时补齐依赖）
    detect_pm() {
        for pm in apt-get dnf yum apk pacman zypper; do
            if command -v "$pm" >/dev/null 2>&1; then
                echo "$pm"
                return 0
            fi
        done
        return 1
    }

    # 确保 curl 与 tar 存在（netbird 官方安装脚本的 bin 回退需要）
    ensure_deps() {
        if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
            return 0
        fi
        pm=$(detect_pm) || { log "no known package manager, skip dep install"; return 0; }
        log "installing deps via $pm"
        case "$pm" in
        apt-get) apt-get update && apt-get install -y curl ca-certificates tar ;;
        dnf) dnf install -y curl ca-certificates tar ;;
        yum) yum install -y curl ca-certificates tar ;;
        apk) apk add --no-cache curl ca-certificates tar ;;
        pacman) pacman -Sy --noconfirm curl ca-certificates tar ;;
        zypper) zypper -n install curl ca-certificates tar ;;
        esac
    }

    # 下载并执行 netbird 官方安装脚本（headless，只装 CLI）
    install_netbird() {
        if command -v netbird >/dev/null 2>&1; then
            log "netbird already installed"
            return 0
        fi
        log "installing netbird via official install.sh"
        # SKIP_UI_APP=true 只装 CLI，适合无桌面服务器
        if command -v curl >/dev/null 2>&1; then
            SKIP_UI_APP=true sh -c "$(curl -fsSL https://pkgs.netbird.io/install.sh)"
        elif command -v wget >/dev/null 2>&1; then
            SKIP_UI_APP=true sh -c "$(wget -qO- https://pkgs.netbird.io/install.sh)"
        else
            log "neither curl nor wget available, cannot fetch installer"
            return 1
        fi
    }

    # 成功后的清理：删除 key，systemd 下自禁用（OpenRC 由 initd 的 start_post 处理）
    cleanup_and_disable() {
        log "connected, cleaning up"
        rm -f "$KEY_FILE"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable netbird-setup.service >/dev/null 2>&1 || true
        fi
    }

    # 已经连上（例如上次开机已成功但未清理），直接清理退出
    if is_connected; then
        cleanup_and_disable
        log "done (was already connected)"
        exit 0
    fi

    ensure_deps || true

    if ! install_netbird; then
        log "install failed, will retry on next boot"
        exit 0
    fi

    # 确保守护进程就绪（bin 安装方式下 install.sh 已尝试，这里再兜底一次）
    netbird service install >/dev/null 2>&1 || true
    netbird service start >/dev/null 2>&1 || true

    # 重试 netbird up，直到连上或用尽次数
    i=1
    while [ "$i" -le "$MAX_TRIES" ]; do
        log "netbird up attempt $i/$MAX_TRIES"
        # 用 --setup-key-file 避免 key 出现在进程列表；不回显 key
        netbird up --setup-key-file "$KEY_FILE" >/dev/null 2>&1 || true
        if is_connected; then
            cleanup_and_disable
            log "done (connected)"
            exit 0
        fi
        sleep $((i * 5))
        i=$((i + 1))
    done

    log "not connected after $MAX_TRIES tries, will retry on next boot"
    exit 0
} >>"$LOG_FILE" 2>&1
