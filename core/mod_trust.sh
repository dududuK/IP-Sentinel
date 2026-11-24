#!/bin/bash

# ==========================================================
# 脚本名称: mod_trust.sh
# 核心功能: 动态扫描本地 LBS 冷数据，提取权威白名单，执行流量净化
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
UA_FILE="${INSTALL_DIR}/data/user_agents.txt"
REPO_RAW_URL="https://raw.githubusercontent.com/dududuK/IP-Sentinel/main"

# --- [基础环境校验] ---
[ ! -f "$CONFIG_FILE" ] && exit 1
source "$CONFIG_FILE"

REGION=${REGION_CODE:-"US"}
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# --- [日志规范化组件] (必须先于一切 log_msg 调用点定义) ---
log_msg() {
    local TYPE=$1
    local MSG=$2
    local TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    local local_ver="${AGENT_VERSION:-未知}"

    printf "[%s] [v%-5s] [%-5s] [Trust  ] [%s] %s\n" \
        "$TIME" "$local_ver" "$TYPE" "$REGION" "$MSG" | tee -a "$LOG_FILE"
}

# ==========================================================
# 1. 动态获取配置 (拓扑自适应与兜底机制)
# ==========================================================
# [共享人格库] 指纹自洽 + 区域规则坐标定位的唯一权威来源
if [ ! -f "${INSTALL_DIR}/core/agent_common.sh" ]; then
    echo "共享人格库缺失 (agent_common.sh)，终止执行。" >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${INSTALL_DIR}/core/agent_common.sh"

# [v4.4.0 根因修复] 旧版 find|head -n1 会随机抓取任意城市的 json，
# 多城市国家直接拿错白名单。现按 config 中 BASE_LAT/BASE_LON
# 坐标在 regions/ 全库做最近邻匹配，锁定本节点专属规则文件
REGION_JSON_FILE=$(sentinel_region_json 2>/dev/null || true)

# [容灾兜底] 坐标匹配失败时回退拉取云端国家级通用配置
if [ -z "$REGION_JSON_FILE" ] || [ ! -f "$REGION_JSON_FILE" ]; then
    REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${REGION}.json"
    mkdir -p "${INSTALL_DIR}/data/regions"
    curl -${IP_PREF:-4} -sL "${REPO_RAW_URL}/data/regions/${REGION}.json" -o "$REGION_JSON_FILE"
fi

# 解析安全网址数组
if [ -f "$REGION_JSON_FILE" ]; then
    if command -v jq >/dev/null 2>&1; then
        mapfile -t TRUST_URLS < <(jq -r '.trust_module.white_urls[]' "$REGION_JSON_FILE" 2>/dev/null)
    else
        log_msg "WARN " "系统未安装 jq，白名单解析降级为兜底模式。"
        TRUST_URLS=()
    fi
fi

# [极限容灾] 提供国际通用无害白名单防全盘崩溃
if [ ${#TRUST_URLS[@]} -eq 0 ]; then
    TRUST_URLS=("https://en.wikipedia.org/wiki/Special:Random" "https://www.apple.com/" "https://www.microsoft.com/")
fi

# ==========================================================
# 2. 锁定人格档案 (Persona Archive)
# 与 mod_google 共享同一套 node 级 UA 画像，跨模块指纹一致；
# UA/Client Hints/Accept-Language 由人格库统一派生，全自洽
# ==========================================================
if [ ! -f "$UA_FILE" ]; then
    log_msg "ERROR" "UA 指纹库缺失，终止执行。"
    exit 1
fi

sentinel_ensure_persona
CURRENT_UA="$PERSONA_UA"
CURL_BIN=$(sentinel_curl_bin "$PERSONA_FAMILY")
sentinel_build_headers
# [指纹自洽] 白名单站点多为外站，Fetch Metadata 按 none 上下文发送
case "$PERSONA_FAMILY" in
    chrome|edge|firefox)
        SENT_HEADER_ARGS+=(-H "Sec-Fetch-Site: none")
        ;;
esac

# ==========================================================
# 3. 执行流量净化行动
# ==========================================================
log_msg "START" "========== 启动区域 IP 信用净化会话 =========="
log_msg "INFO " "已载入 [${REGION}] 区域白名单，配置库条目: ${#TRUST_URLS[@]} 个"
log_msg "INFO " "已锁定本地伪装指纹: $(echo $CURRENT_UA | cut -d' ' -f1-2)..."

# -----------------------------------------------------------
# [v4.1.6] Cookie 持久化身份库 (Trust 专属物理隔离)
# 消除无记忆爬虫特征，积累顶级 CDN 的访客信誉分
# -----------------------------------------------------------
COOKIE_DIR="${INSTALL_DIR}/data/cookies"
mkdir -p "$COOKIE_DIR"

NODE_HASH=$(sentinel_node_hash)
COOKIE_FILE="${COOKIE_DIR}/trust_${NODE_HASH}.txt"

# [互斥锁] 防止并发净化导致 Cookie 文件读写冲突
LOCK_FILE="${COOKIE_FILE}.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    log_msg "WARN " "检测到已有 Trust 会话运行，跳过本轮。"
    exit 0
}

# 定期清理废弃 Cookie，防爆栈
find "$COOKIE_DIR" -type f -name "trust_*.txt" -mtime +14 -delete 2>/dev/null || true

# ----------------------------------------------------------
# 网络锚定与协议自适应构建 
# 强制 curl 绑定网卡并自动匹配底层网络协议栈
# ----------------------------------------------------------
# [v4.1.6 修复] 改用 Bash 数组传参，彻底消除 Shell Word Splitting 注入隐患
CURL_BIND_ARGS=()
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    # [v4.1.6 修复] 使用 -Fq 替代 -qw，防止 IPv6 冒号被误认为单词边界导致误杀
    if ! ip addr show 2>/dev/null | grep -Fq "$RAW_BIND_IP"; then
        log_msg "WARN " "检测到配置的出口 IP ($RAW_BIND_IP) 已丢失，自动降级为系统默认路由出网！"
        CURL_BIND_ARGS=()
    else
        CURL_BIND_ARGS=(--interface "$BIND_IP")
        if [[ "$BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="-6"
            log_msg "INFO " "底层路由锁定: 绑定 IPv6 出口及协议 ($BIND_IP)"
        elif [[ "$BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="-4"
            log_msg "INFO " "底层路由锁定: 绑定 IPv4 出口及协议 ($BIND_IP)"
        fi
    fi
fi

STEP_COUNT=$((RANDOM % 4 + 3))
SUCCESS_INJECT=0

for ((i=1; i<=STEP_COUNT; i++)); do
    TARGET_URL=${TRUST_URLS[$((RANDOM % ${#TRUST_URLS[@]}))]}
    
    # [v4.4.0] 人格库统一指纹头（Accept/Accept-Language/Client Hints 全自洽），
    # 挂载持久化 Cookie (-b -c)，精准捕获底层死因
    HTTP_CODE=$("$CURL_BIN" "${CURL_BIND_ARGS[@]}" "$DYNAMIC_IP_PREF" \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" -A "$CURRENT_UA" \
        --compressed \
        "${SENT_HEADER_ARGS[@]}" \
        -s -L -o /dev/null -w "%{http_code}" -m 15 "$TARGET_URL")
    CURL_EXIT=$?

    # [v4.1.6 修复] 精准错误码映射，防空值塌陷
    if [ $CURL_EXIT -ne 0 ]; then
        case $CURL_EXIT in
            6)  HTTP_CODE="ERR_DNS" ;;
            7)  HTTP_CODE="ERR_CONN" ;;
            28) HTTP_CODE="ERR_TIMEOUT" ;;
            35) HTTP_CODE="ERR_TLS" ;;
            56) HTTP_CODE="ERR_RESET" ;;
            *)  HTTP_CODE="ERR_${CURL_EXIT}" ;;
        esac
        log_msg "WARN " "动作[$i/$STEP_COUNT]异常 | 底层错误: $HTTP_CODE | 阻拦: ${TARGET_URL:0:40}..."
    else
        # 扩大 HTTP 状态码容错区间：包含各大骨干 CDN 常见的 20x 及 30x 状态转移
        if [[ "$HTTP_CODE" =~ ^[23] ]]; then
            log_msg "EXEC " "动作[$i/$STEP_COUNT]完成 | 状态: $HTTP_CODE | 注入: ${TARGET_URL:0:40}..."
            ((SUCCESS_INJECT++))
        else
            log_msg "WARN " "动作[$i/$STEP_COUNT]异常 | 状态: $HTTP_CODE | 阻拦: ${TARGET_URL:0:40}..."
        fi
    fi

    # [v4.1.6] 泊松长尾生物钟拉伸，模拟人类真实阅读扫视习惯
    if [ $i -lt $STEP_COUNT ]; then
        SLEEP_DICE=$((RANDOM % 100))
        if [ $SLEEP_DICE -lt 45 ]; then
            SLEEP_TIME=$((8 + RANDOM % 13))    # 8 - 20s (45%)
        elif [ $SLEEP_DICE -lt 80 ]; then
            SLEEP_TIME=$((20 + RANDOM % 41))   # 20 - 60s (35%)
        elif [ $SLEEP_DICE -lt 95 ]; then
            SLEEP_TIME=$((60 + RANDOM % 121))  # 60 - 180s (15%)
        else
            SLEEP_TIME=$((180 + RANDOM % 300)) # 180 - 480s (5%)
        fi
        log_msg "WAIT " "正在浏览本地高权重页面，模拟停留 ${SLEEP_TIME}s..."
        sleep "$SLEEP_TIME"
    fi
done

# ==========================================================
# 4. 结论判定与输出
# ==========================================================
if [ "$SUCCESS_INJECT" -ge $((STEP_COUNT / 2)) ]; then
    log_msg "SCORE" "自检结论: ✅ 信用净化完成 (已成功注入 $SUCCESS_INJECT 条无害流量)"
else
    log_msg "SCORE" "自检结论: ❌ 净化受阻 (部分站点拦截或网络超时)"
fi

log_msg "END  " "========== 会话结束，释放进程 =========="
log_msg "INFO " "系统级调度完毕，信任因子持续积累中..."