#!/bin/bash

# ==========================================================
# 脚本名称: agent_common.sh
# 核心功能: 共享人格档案(Persona)固化、分浏览器指纹头构建、
#           区域规则定位、出口探测工具链
# 设计原则: 指纹必须"自洽"——UA、Client Hints、Accept 系、
#           Accept-Language 同属一个浏览器画像，严禁跨引擎拼接
# ==========================================================

# [依赖契约] 调用方必须先 source config.conf 并具备 INSTALL_DIR /
#            REGION_CODE / BASE_LAT / BASE_LON / LANG_PARAMS /

# ----------------------------------------------------------
# [节点哈希] 全节点唯一身份种子，与 Cookie 罐命名同源
# ----------------------------------------------------------
sentinel_node_hash() {
    local ip="${PUBLIC_IP:-${BIND_IP:-unknown}}"
    echo -n "$ip" | cksum | awk '{print $1}'
}

# ----------------------------------------------------------
# [区域规则定位] 按 config 中的 BASE_LAT/BASE_LON 坐标
# 在 regions/ 目录内做最近邻匹配，彻底根治"抓任意 json"的
# 跨区域错配 bug；旧配置无需新增字段即可自愈
# ----------------------------------------------------------
sentinel_region_json() {
    local root="${INSTALL_DIR}/data/regions"
    [ -d "$root" ] || return 1

    # 优先限定国家目录缩小搜索面，失配再退回全库
    local scope="$root"
    local cc="${REGION_CODE%%-*}"
    [ -d "$root/$cc" ] && scope="$root/$cc"

    local best="" best_d="999999"
    local f lat lon d
    while IFS= read -r f; do
        lat=$(jq -r '.google_module.base_lat // empty' "$f" 2>/dev/null)
        lon=$(jq -r '.google_module.base_lon // empty' "$f" 2>/dev/null)
        [ -z "$lat" ] || [ -z "$lon" ] && continue
        d=$(awk -v a="$lat" -v b="$BASE_LAT" -v c="$lon" -v e="$BASE_LON" \
            'BEGIN{d1=a-b; if(d1<0)d1=-d1; d2=c-e; if(d2<0)d2=-d2; print d1+d2}')
        # [epsilon=0.5°] 同城多 json 或坐标微调时仍能命中本命文件
        if awk -v d="$d" -v b="$best_d" 'BEGIN{exit !(d<b)}'; then
            best_d="$d"; best="$f"
        fi
    done < <(find "$scope" -name '*.json' 2>/dev/null | sort)

    # 国家目录内未命中时回退全库兜底
    if [ -z "$best" ] && [ "$scope" != "$root" ]; then
        while IFS= read -r f; do
            lat=$(jq -r '.google_module.base_lat // empty' "$f" 2>/dev/null)
            lon=$(jq -r '.google_module.base_lon // empty' "$f" 2>/dev/null)
            [ -z "$lat" ] || [ -z "$lon" ] && continue
            d=$(awk -v a="$lat" -v b="$BASE_LAT" -v c="$lon" -v e="$BASE_LON" \
                'BEGIN{d1=a-b; if(d1<0)d1=-d1; d2=c-e; if(d2<0)d2=-d2; print d1+d2}')
            if awk -v d="$d" -v b="$best_d" 'BEGIN{exit !(d<b)}'; then
                best_d="$d"; best="$f"
            fi
        done < <(find "$root" -name '*.json' 2>/dev/null | sort)
    fi

    [ -n "$best" ] && echo "$best"
    return 0
}

# ----------------------------------------------------------
# [Accept-Language 派生] 从 LANG_PARAMS (hl=/gl=) 生成
# 与目标战区匹配的真实浏览器语言头，根治全区域 en-US 硬编码
# ----------------------------------------------------------
sentinel_accept_language() {
    local hl gl primary base
    hl=$(printf '%s' "$LANG_PARAMS" | grep -o 'hl=[^&]*' | head -n1 | cut -d= -f2)
    gl=$(printf '%s' "$LANG_PARAMS" | grep -o 'gl=[^&]*' | head -n1 | cut -d= -f2)
    [ -z "$hl" ] && { echo "en-US,en;q=0.9"; return 0; }

    if [[ "$hl" == *-* ]]; then
        primary="$hl"; base="${hl%%-*}"
    else
        base="$hl"
        [ -n "$gl" ] && primary="$hl-$gl" || primary="$hl"
    fi

    # 英文系战区：真实浏览器只发两级语言
    if [ "$base" == "en" ]; then
        [ "$primary" == "$base" ] && primary="en-US"
        echo "$primary,en;q=0.9"
        return 0
    fi

    # 非英文战区：本地语言优先，英文兜底（真实浏览器惯例）
    if [ "$primary" == "$base" ]; then
        echo "$primary,en-US;q=0.8,en;q=0.7"
    else
        echo "$primary,$base;q=0.9,en-US;q=0.8,en;q=0.7"
    fi
}

# ----------------------------------------------------------
# [人格档案 Persona] 每节点固化一套 UA 画像，按月轮换。
# 同一 IP 的 Cookie 罐长期持久，UA 却每轮重抽是教科书级
# 机器人特征——人格必须落盘、低频轮换、跨会话稳定
# ----------------------------------------------------------
PERSONA_DIR="${INSTALL_DIR}/data/persona"
PERSONA_FILE=""
PERSONA_UA=""
PERSONA_FAMILY=""        # chrome | firefox | safari | edge | other（浏览器引擎）
PERSONA_OS=""            # windows | macos | linux | android | ios（操作系统平台）
PERSONA_LANG=""
PERSONA_CH_UA=""         # Sec-Ch-Ua 载荷（仅 chromium 系）
PERSONA_CH_PLATFORM=""   # Sec-Ch-Ua-Platform（仅 chromium 系）
PERSONA_CH_MOBILE=""     # Sec-Ch-Ua-Mobile（仅 chromium 系）
PERSONA_ACCEPT=""
PERSONA_ACCEPT_ENCODING=""
SENT_HEADER_ARGS=()      # sentinel_build_headers() 产物：curl -H 参数数组

sentinel_persona_path() {
    echo "${PERSONA_DIR}/$(sentinel_node_hash).conf"
}

# 从 UA 字符串推导浏览器家族与客户端 hints（纯 bash，无 jq 依赖）
sentinel_derive_persona() {
    local ua="$1"
    PERSONA_UA="$ua"

    if [[ "$ua" == *Firefox* ]]; then
        PERSONA_FAMILY="firefox"
    elif [[ "$ua" == *Edg/* ]]; then
        PERSONA_FAMILY="edge"
    elif [[ "$ua" == *Chrome/* ]] || [[ "$ua" == *Chromium/* ]]; then
        PERSONA_FAMILY="chrome"
    elif [[ "$ua" == *"Version/"* ]] && [[ "$ua" == *Safari* ]]; then
        PERSONA_FAMILY="safari"
    else
        PERSONA_FAMILY="other"
    fi

    # --- 平台推断（移动端判定优先，Android UA 内含 Linux 字样）---
    PERSONA_OS="windows"
    local plat="Windows" mobile="?0"
    if [[ "$ua" == *Android* ]]; then
        PERSONA_OS="android"; plat="Android"; mobile="?1"
    elif [[ "$ua" == *iPhone* ]] || [[ "$ua" == *iPad* ]]; then
        PERSONA_OS="ios"; plat="iOS"; mobile="?1"
    elif [[ "$ua" == *Macintosh* ]]; then
        PERSONA_OS="macos"; plat="macOS"
    elif [[ "$ua" == *Linux* ]]; then
        PERSONA_OS="linux"; plat="Linux"
    fi
    PERSONA_CH_PLATFORM="\"$plat\""
    PERSONA_CH_MOBILE="$mobile"

    # --- Chromium 系 Client Hints：版本必须从 UA 实时解析，
    #     绝不允许 UA 与 hint 版本脱节 ---
    PERSONA_CH_UA=""
    if [ "$PERSONA_FAMILY" = "chrome" ] || [ "$PERSONA_FAMILY" = "edge" ]; then
        local cmaj="" emaj=""
        [[ "$ua" =~ Chrome/([0-9]+) ]] && cmaj="${BASH_REMATCH[1]}"
        [ -z "$cmaj" ] && cmaj="120"
        if [ "$PERSONA_FAMILY" = "edge" ] && [[ "$ua" =~ Edg/([0-9]+) ]]; then
            emaj="${BASH_REMATCH[1]}"
            PERSONA_CH_UA="\"Microsoft Edge\";v=\"${emaj}\", \"Chromium\";v=\"${cmaj}\", \"Not_A Brand\";v=\"8\""
        else
            PERSONA_CH_UA="\"Chromium\";v=\"${cmaj}\", \"Google Chrome\";v=\"${cmaj}\", \"Not_A Brand\";v=\"8\""
        fi
    fi

    # --- Accept 系按引擎真实行为分化 ---
    case "$PERSONA_FAMILY" in
        chrome|edge)
            PERSONA_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
            PERSONA_ACCEPT_ENCODING='gzip, deflate, br, zstd'
            ;;
        firefox)
            PERSONA_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
            PERSONA_ACCEPT_ENCODING='gzip, deflate, br, zstd'
            ;;
        safari)
            PERSONA_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            PERSONA_ACCEPT_ENCODING='gzip, deflate, br'
            ;;
        *)
            PERSONA_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            PERSONA_ACCEPT_ENCODING='gzip, deflate, br'
            ;;
    esac

    PERSONA_LANG=$(sentinel_accept_language)
}

# 确保人格档案存在且未过期（30 天轮换），输出全局 PERSONA_* 变量
sentinel_ensure_persona() {
    PERSONA_DIR="${INSTALL_DIR}/data/persona"
    PERSONA_FILE=$(sentinel_persona_path)
    mkdir -p "$PERSONA_DIR" 2>/dev/null

    local ua="" born=0 now mtime
    if [ -f "$PERSONA_FILE" ]; then
        # shellcheck disable=SC1090
        source "$PERSONA_FILE" 2>/dev/null
        ua="${PERSONA_UA_STORED:-}"
        born="${PERSONA_BORN:-0}"
        now=$(date +%s)
        mtime=$(stat -c %Y "$PERSONA_FILE" 2>/dev/null || stat -f %m "$PERSONA_FILE" 2>/dev/null || echo 0)
        # 档案超过 30 天强制轮换，避免人格僵化
        if [ $((now - mtime)) -lt 2592000 ] && [ -n "$ua" ]; then
            sentinel_derive_persona "$ua"
            return 0
        fi
    fi

    # --- 轮换：按 IP + 月份桶哈希选 UA，舰队内确定性发散 ---
    local ua_file="${INSTALL_DIR}/data/user_agents.txt"
    local total=0 idx seed
    if [ -f "$ua_file" ]; then
        total=$(grep -cv '^[[:space:]]*$' "$ua_file" 2>/dev/null || echo 0)
    fi
    if [ "$total" -gt 0 ]; then
        seed=$(echo -n "${PUBLIC_IP:-${BIND_IP:-unknown}}:$(date -u +%Y%m)" | cksum | awk '{print $1}')
        idx=$((seed % total))
        ua=$(grep -v '^[[:space:]]*$' "$ua_file" | sed -n "$((idx+1))p")
    fi
    [ -z "$ua" ] && ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

    # 落盘人格档案（含生日戳，跨重启稳定）
    cat > "$PERSONA_FILE" << EOF
# IP-Sentinel Persona Archive (自动生成，请勿手改)
PERSONA_UA_STORED='$ua'
PERSONA_BORN=$(date +%s)
EOF
    chmod 600 "$PERSONA_FILE" 2>/dev/null

    sentinel_derive_persona "$ua"
}

# ----------------------------------------------------------
# [浏览器指纹头构建] 按人格家族产出 curl -H 参数数组。
# Chromium 系才发 Sec-Ch-Ua*；Firefox/Safari 绝不发送，
# 从根上消灭"UA 说 Firefox、头说 Chrome"的自爆穿帮
# ----------------------------------------------------------
sentinel_build_headers() {
    SENT_HEADER_ARGS=()

    # 通用三件套（所有现代浏览器导航请求共有）
    SENT_HEADER_ARGS+=(
        -H "Accept: ${PERSONA_ACCEPT}"
        -H "Accept-Language: ${PERSONA_LANG}"
        -H "Accept-Encoding: ${PERSONA_ACCEPT_ENCODING}"
    )

    case "$PERSONA_FAMILY" in
        chrome|edge|firefox)
            # Fetch Metadata：Chromium 与 Firefox 都发送，Safari 不发
            SENT_HEADER_ARGS+=(
                -H "Sec-Fetch-Dest: document"
                -H "Sec-Fetch-Mode: navigate"
                -H "Sec-Fetch-User: ?1"
                -H "Upgrade-Insecure-Requests: 1"
            )
            ;;
        *)
            SENT_HEADER_ARGS+=(
                -H "Upgrade-Insecure-Requests: 1"
            )
            ;;
    esac

    # Client Hints 仅 Chromium 内核系（Chrome/Edge）发送
    if [ -n "$PERSONA_CH_UA" ]; then
        SENT_HEADER_ARGS+=(
            -H "Sec-Ch-Ua: ${PERSONA_CH_UA}"
            -H "Sec-Ch-Ua-Mobile: ${PERSONA_CH_MOBILE}"
            -H "Sec-Ch-Ua-Platform: ${PERSONA_CH_PLATFORM}"
        )
    fi
}

# ----------------------------------------------------------
# [传输层探测] 优先启用 curl-impersonate 拿真实浏览器 TLS 指纹
# (JA3/JA4)，未安装则回退系统 curl。可用 SENTINEL_CURL_BIN 强制指定
# ----------------------------------------------------------
sentinel_curl_bin() {
    if [ -n "${SENTINEL_CURL_BIN:-}" ]; then
        command -v "$SENTINEL_CURL_BIN" >/dev/null 2>&1 && { echo "$SENTINEL_CURL_BIN"; return 0; }
    fi

    # 按人格家族优先匹配同内核 impersonate 二进制
    local patterns=()
    case "$1" in
        firefox)  patterns=("curl_ff*" "curl-impersonate*ff*" "curl_chrome*" "curl-impersonate*") ;;
        safari)   patterns=("curl_safari*" "curl-impersonate*" "curl_chrome*") ;;
        *)        patterns=("curl_chrome*" "curl-impersonate*" "curl_ff*" "curl_safari*") ;;
    esac

    local pat exe
    for pat in "${patterns[@]}"; do
        while IFS= read -r exe; do
            [ -n "$exe" ] && command -v "$exe" >/dev/null 2>&1 && { echo "$exe"; return 0; }
        done < <(compgen -c "$pat" 2>/dev/null | sort -u)
    done

    echo "curl"
}
