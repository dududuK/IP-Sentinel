#!/bin/bash

# ==========================================================
# 脚本名称: runner.sh
# 核心功能: 主控调度枢纽，管理防并发锁与 Feature Flag 概率轮盘
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# --- [基础环境构建] ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install.sh"
    exit 1
fi
source "$CONFIG_FILE"

# ==========================================================
# [防线 1] 进程排他锁管控
# 严格防止高频并发重入引发的底层内存雪崩与死锁
# ==========================================================
exec 200>"/tmp/ip_sentinel_runner.lock"
if ! flock -n 200; then
    echo "[$(date)] ⚠️ 上一轮巡逻任务尚未结束，本次触发自动取消。" >> "$LOG_FILE"
    exit 0
fi

# --- [系统级日志通道] ---
log() {
    local module=$1
    local level=$2
    local msg=$3
    local local_ver="${AGENT_VERSION:-未知}"
    
    mkdir -p "${INSTALL_DIR}/logs"
    
    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "$module" "$REGION_CODE" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        echo "$core_msg"
    fi
}
export -f log
export CONFIG_FILE INSTALL_DIR

# ==========================================================
# [防线 1.5] 目标时区生物钟门禁 (Circadian Rhythm Gate)
# 模拟目标区域人类生理作息，深夜时段静默休眠
# ==========================================================
TARGET_TZ="UTC"
CC="${REGION_CODE%%-*}"
CC=$(echo "$CC" | tr 'a-z' 'A-Z')
case "$CC" in
    "US")
        case "$REGION_CODE" in
            "US-CA"|"US-WA"|"US-OR"|"US-NV") TARGET_TZ="America/Los_Angeles" ;;
            "US-IL"|"US-TX"|"US-MO")         TARGET_TZ="America/Chicago" ;;
            *)                                TARGET_TZ="America/New_York" ;;
        esac
        ;;
    "JP") TARGET_TZ="Asia/Tokyo" ;;
    "HK") TARGET_TZ="Asia/Hong_Kong" ;;
    "TW") TARGET_TZ="Asia/Taipei" ;;
    "SG") TARGET_TZ="Asia/Singapore" ;;
    "DE") TARGET_TZ="Europe/Berlin" ;;
    "UK"|"GB") TARGET_TZ="Europe/London" ;;
    "FR") TARGET_TZ="Europe/Paris" ;;
    "NL") TARGET_TZ="Europe/Amsterdam" ;;
    "KR") TARGET_TZ="Asia/Seoul" ;;
    "AU") TARGET_TZ="Australia/Sydney" ;;
    "CA") TARGET_TZ="America/Toronto" ;;
    "IN") TARGET_TZ="Asia/Kolkata" ;;
    "MY") TARGET_TZ="Asia/Kuala_Lumpur" ;;
    "TH") TARGET_TZ="Asia/Bangkok" ;;
    "VN") TARGET_TZ="Asia/Ho_Chi_Minh" ;;
    "PH") TARGET_TZ="Asia/Manila" ;;
    "ID") TARGET_TZ="Asia/Jakarta" ;;
    "BR") TARGET_TZ="America/Sao_Paulo" ;;
    "MX") TARGET_TZ="America/Mexico_City" ;;
    *)    TARGET_TZ="UTC" ;;
esac

LOCAL_HOUR=$(TZ="$TARGET_TZ" date +%H 2>/dev/null || date -u +%H)
HOUR_VAL=$((10#$LOCAL_HOUR))
if [ "$HOUR_VAL" -ge 0 ] && [ "$HOUR_VAL" -le 6 ]; then
    log "SYSTEM" "INFO " "🌙 当前目标战区为深夜作息时段 (${LOCAL_HOUR}:00)，模拟人类睡眠，跳过本轮执行。"
    exit 0
fi

# ==========================================================
# [防线 2] 行为学隐蔽 (Cron Jitter)
# 彻底消除僵尸网络同频定时唤醒特征，自然打散全球并发请求
# ==========================================================
if [ -t 1 ]; then
    log "SYSTEM" "INFO " "💻 检测到人工终端干预，跳过静默休眠，立即执行任务！"
else
    JITTER_TIME=$((RANDOM % 180))
    log "SYSTEM" "INFO " "⏱️ 主控引擎由后台唤醒，进入防并发随机休眠状态: ${JITTER_TIME} 秒..."
    sleep $JITTER_TIME
fi

# ==========================================================
# 智能轮盘赌调度系统 (基于 Feature Flag)
# ==========================================================
log "SYSTEM" "INFO" "休眠结束，开始计算本轮任务轮盘..."

TARGET_MOD=""
MOD_NAME=""

# [稳定态判定: 达标即静默]
SETTLED_FILE="${INSTALL_DIR}/core/.geo_settled"
if [ -f "$SETTLED_FILE" ] || [ -f "/opt/ip_sentinel/core/.geo_settled" ]; then
    ROLL=$((RANDOM % 100 + 1))
    if [ $ROLL -le 95 ]; then
        log "SYSTEM" "INFO " "✅ IP 已成功拉回并处于稳定期 (.geo_settled)，跳过本轮 Google 纠偏以防触发人机风控。"
        exit 0
    else
        TARGET_MOD="mod_trust.sh"
        MOD_NAME="IP 信用净化"
    fi
else
    # 概率任务分配模型
    if [ "$ENABLE_GOOGLE" == "true" ] && [ "$ENABLE_TRUST" == "true" ]; then
        # 优先锚定地理画像，辅助洗刷风控分
        ROLL=$((RANDOM % 100 + 1))
        if [ $ROLL -le 70 ]; then
            TARGET_MOD="mod_google.sh"
            MOD_NAME="Google 区域纠偏"
        else
            TARGET_MOD="mod_trust.sh"
            MOD_NAME="IP 信用净化"
        fi
    elif [ "$ENABLE_GOOGLE" == "true" ]; then
        TARGET_MOD="mod_google.sh"
        MOD_NAME="Google 区域纠偏"
    elif [ "$ENABLE_TRUST" == "true" ]; then
        TARGET_MOD="mod_trust.sh"
        MOD_NAME="IP 信用净化"
    else
        log "SYSTEM" "WARN " "节点未开启任何养护模块，跳过本轮执行。"
        exit 0
    fi
fi

# ----------------------------------------------------------
# 安全执行与资源剥离
# ----------------------------------------------------------
if [ -n "$TARGET_MOD" ] && [ -x "${INSTALL_DIR}/core/${TARGET_MOD}" ]; then
    log "SYSTEM" "INFO" "命中触发条件，加载并执行子模块: ${MOD_NAME}"
    # [进程隔离与降耗] 赋予最低 CPU 优先级，并强制剥离排他锁的继承权，防止子进程假死拖垮全局
    nice -n 19 bash "${INSTALL_DIR}/core/${TARGET_MOD}" 200>&-
else
    log "SYSTEM" "ERROR" "配置了模块 ${MOD_NAME}，但未找到对应的可执行脚本: ${TARGET_MOD}"
fi

log "SYSTEM" "INFO" "本轮所有模块调度完毕，哨兵继续隐蔽待命。"