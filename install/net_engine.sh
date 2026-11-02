#!/bin/bash
# ==========================================================
# 模块名称: net_engine.sh
# 核心功能: 冗余网络栈探测、多出口容灾弹匣装填、老节点平滑迁移网络配置
# ==========================================================

do_network_probe() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n\033[36m[4.5/7] 正在探测本机网络栈与可用出口 (多节点雷达扫描中)...\033[0m"

        RAW_DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
        RAW_DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

        # [v4.2.2 源头防线] 引入工业级网卡追踪，双重过滤 WARP/TUN/NAT 等假公网环境
        DETECT_V4=""
        if [[ -n "$RAW_DETECT_V4" ]]; then
            V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || \
               [[ "$RAW_DETECT_V4" =~ ^104\.28\. ]] || \
               [[ "$RAW_DETECT_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
                echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv4 出口 ($RAW_DETECT_V4) 经由虚拟网卡 ($V4_DEV)，已从通讯候选池中隔离。\033[0m"
            else
                DETECT_V4="$RAW_DETECT_V4"
            fi
        fi

        DETECT_V6=""
        if [[ -n "$RAW_DETECT_V6" ]]; then
            V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
            if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_DETECT_V6" =~ ^fe80:|^::1 ]]; then
                echo -e " \033[33m⚠️ 雷达警告: 发现异常 IPv6 出口 ($RAW_DETECT_V6) 经由虚拟网卡 ($V6_DEV)，已从通讯候选池中隔离。\033[0m"
            else
                DETECT_V6="$RAW_DETECT_V6"
            fi
        fi

        IP_OPTIONS=()
        IP_PROTO=()

        [[ -n "$DETECT_V4" ]] && { IP_OPTIONS+=("$DETECT_V4"); IP_PROTO+=("4"); }
        [[ -n "$DETECT_V6" ]] && { IP_OPTIONS+=("$DETECT_V6"); IP_PROTO+=("6"); }

        if [ ${#IP_OPTIONS[@]} -eq 0 ]; then
            echo -e "\033[33m⚠️ 雷达受阻：未能自动探测到公网 IP，请手动指定。\033[0m"
            read -p "请输入您要绑定的公网 IP (v4 或 v6): " RAW_PUBLIC_IP
            PUBLIC_IP=$(echo "$RAW_PUBLIC_IP" | tr -cd 'a-fA-F0-9.:[]')
            [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
        else
            echo "📍 发现可用出口 IP，请选择要注册与养护的锚点:"
            for i in "${!IP_OPTIONS[@]}"; do
                num=$((i+1))
                if [ "${IP_PROTO[$i]}" == "4" ]; then
                    echo "  $num) 🌐 IPv4: ${IP_OPTIONS[$i]} (默认选项)"
                else
                    echo "  $num) 🌌 IPv6: ${IP_OPTIONS[$i]}"
                fi
            done
            CUSTOM_OPT=$(( ${#IP_OPTIONS[@]} + 1 ))
            echo "  $CUSTOM_OPT) ✍️ 手动指定其他 IP (适合多 IP 站群机)"
            
            read -p "请输入选择 (默认1): " IP_CHOICE
            IP_CHOICE=${IP_CHOICE:-1}
            
            if [ "$IP_CHOICE" -le "${#IP_OPTIONS[@]}" ] && [ "$IP_CHOICE" -gt 0 ]; then
                idx=$((IP_CHOICE-1))
                PUBLIC_IP="${IP_OPTIONS[$idx]}"
                IP_PREF="${IP_PROTO[$idx]}"
            elif [ "$IP_CHOICE" -eq "$CUSTOM_OPT" ]; then
                read -p "请输入您要绑定的公网 IP (v4 或 v6): " PUBLIC_IP
                [[ "$PUBLIC_IP" == *":"* ]] && IP_PREF="6" || IP_PREF="4"
            else
                PUBLIC_IP="${IP_OPTIONS[0]}"
                IP_PREF="${IP_PROTO[0]}"
            fi
        fi

        # [容灾防线] 为含冒号的 IPv6 数据自动装卸方括号护盾，保障下游组件识别不崩溃
        if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
            SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
        else
            SAFE_PUBLIC_IP="$PUBLIC_IP"
        fi
    fi
}

do_assemble_fallback() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n\033[36m[4.6/7] 正在装填通讯容灾防线 (Multi-IP Fallback)...\033[0m"
        COMM_IP="$SAFE_PUBLIC_IP"
        
        # 注入次发弹药 (可用 IPv4)
        if [[ -n "$DETECT_V4" ]] && [[ "$DETECT_V4" != "$PUBLIC_IP" ]]; then
            COMM_IP="${COMM_IP}_${DETECT_V4}"
        fi
        
        # 注入保底弹药 (可用 IPv6，带括号保护)
        if [[ -n "$DETECT_V6" ]] && [[ "$DETECT_V6" != "$PUBLIC_IP" ]]; then
            [[ "$DETECT_V6" != *"["* ]] && SAFE_V6="[${DETECT_V6}]" || SAFE_V6="$DETECT_V6"
            COMM_IP="${COMM_IP}_${SAFE_V6}"
        fi
        
        SAFE_COMM_IP="$COMM_IP"
        
        if [[ "$COMM_IP" == *"_"* ]]; then
            echo -e " \033[32m✅ 成功组装多宿主容灾通讯专线: $SAFE_COMM_IP\033[0m"
        else
            echo -e " \033[33m⚠️ 本机仅有单一出口，建立单轨通讯模式: $SAFE_COMM_IP\033[0m"
        fi

        echo -n "🕵️ 正在进行出站链路试射 (NAT环境与双栈嗅探)..."
        
        RAW_TEST_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
        
        if [[ "$RAW_TEST_IP" == *":"* ]]; then
            TEST_TARGET="https://[2606:4700:4700::1111]"
        else
            TEST_TARGET="https://1.1.1.1"
        fi
        
        if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
            echo -e " \033[32m✅ 原生直连，物理网卡死锁已激活。\033[0m"
            BIND_IP="$SAFE_PUBLIC_IP"
        else
            echo -e " \033[33m⚠️ 发现 NAT/虚拟路由架构，自动卸除网卡枷锁，交由内核路由。\033[0m"
            BIND_IP=""
        fi
        echo -e "\033[32m✅ 哨兵对外联络点已永久锁定至: $SAFE_PUBLIC_IP\033[0m"

        # [身份分离] 分离底层系统锚定的不可变主键，与暴露给上层展示的可变别名
        IP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
        NODE_ALIAS="$NODE_NAME"

        if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
            echo -e "\n\033[36m[4.8/7] 节点展示别名设定 (用于面板友好显示)...\033[0m"
            echo -e "💡 系统底层的不可变主键为: \033[33m${NODE_NAME}\033[0m"
            read -p "请输入节点展示别名 (如'纽约机房', 回车使用默认): " CUSTOM_ALIAS

            if [ -n "$CUSTOM_ALIAS" ]; then
                # 挂载 UTF-8 环境，防止原生 Bash 在 C Locale 下对多字节汉字进行错误截断
                export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true
                CLEAN_ALIAS=$(echo "$CUSTOM_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r')
                NODE_ALIAS="${CLEAN_ALIAS:0:20}"
                [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
            fi
            echo -e "✅ 已锁定节点展示别名: \033[32m$NODE_ALIAS\033[0m"
        fi
    fi
}

do_timezone_align() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n\033[36m[4.7/7] 服务器时区环境侦测与人性化作息对齐...\033[0m"

        # 1. 嗅探当前服务器时区
        CURRENT_TZ=""
        if command -v timedatectl >/dev/null 2>&1; then
            CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
        fi
        [ -z "$CURRENT_TZ" ] && [ -f /etc/timezone ] && CURRENT_TZ=$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]')
        [ -z "$CURRENT_TZ" ] && [ -L /etc/localtime ] && CURRENT_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
        [ -z "$CURRENT_TZ" ] && CURRENT_TZ="UTC"

        # 获取时区中文友好名称映射
        get_tz_name() {
            case "$1" in
                "Asia/Shanghai") echo "中国标准时间" ;;
                "Asia/Hong_Kong") echo "香港时间" ;;
                "Asia/Taipei") echo "台北时间" ;;
                "Asia/Tokyo") echo "日本标准时间" ;;
                "Asia/Seoul") echo "韩国标准时间" ;;
                "Asia/Singapore") echo "新加坡时间" ;;
                "Asia/Bangkok") echo "泰国时间" ;;
                "Asia/Kuala_Lumpur") echo "马来西亚时间" ;;
                "Asia/Ho_Chi_Minh") echo "越南时间" ;;
                "Asia/Manila") echo "菲律宾时间" ;;
                "Asia/Jakarta") echo "印尼西部时间" ;;
                "Asia/Kolkata") echo "印度标准时间" ;;
                "Asia/Dubai") echo "阿联酋海湾时间" ;;
                "America/New_York") echo "美国东部时间" ;;
                "America/Chicago") echo "美国中部时间" ;;
                "America/Denver") echo "美国山地时间" ;;
                "America/Los_Angeles") echo "美国太平洋时间" ;;
                "America/Toronto") echo "加拿大东部时间" ;;
                "Europe/London") echo "英国伦敦时间" ;;
                "Europe/Berlin") echo "德国柏林时间" ;;
                "Europe/Paris") echo "法国巴黎时间" ;;
                "Europe/Amsterdam") echo "荷兰阿姆斯特丹时间" ;;
                "Australia/Sydney") echo "澳大利亚东部时间" ;;
                "UTC") echo "协调世界时" ;;
                *) date "+%Z" 2>/dev/null || echo "当地时间" ;;
            esac
        }
        CURRENT_TZ_NAME=$(get_tz_name "$CURRENT_TZ")

        # 2. 智能探测目标战区与 IP 对应时区
        TARGET_TZ=""
        RAW_IP_FOR_GEO=$(echo "${SAFE_PUBLIC_IP:-${PUBLIC_IP:-127.0.0.1}}" | tr -d '[]')
        if [[ "$RAW_IP_FOR_GEO" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            DETECTED_IP_TZ=$(curl -s -m 3 "http://ip-api.com/json/${RAW_IP_FOR_GEO}?fields=timezone" 2>/dev/null | jq -r '.timezone // empty' 2>/dev/null)
            if [ -n "$DETECTED_IP_TZ" ] && [ "$DETECTED_IP_TZ" != "null" ]; then
                TARGET_TZ="$DETECTED_IP_TZ"
            fi
        fi

        if [ -z "$TARGET_TZ" ]; then
            CC="${COUNTRY_ID:-$REGION_CODE}"
            CC="${CC%%-*}"
            CC=$(echo "$CC" | tr 'a-z' 'A-Z')
            case "$CC" in
                "JP") TARGET_TZ="Asia/Tokyo" ;;
                "HK") TARGET_TZ="Asia/Hong_Kong" ;;
                "TW") TARGET_TZ="Asia/Taipei" ;;
                "SG") TARGET_TZ="Asia/Singapore" ;;
                "KR") TARGET_TZ="Asia/Seoul" ;;
                "DE") TARGET_TZ="Europe/Berlin" ;;
                "UK"|"GB") TARGET_TZ="Europe/London" ;;
                "FR") TARGET_TZ="Europe/Paris" ;;
                "NL") TARGET_TZ="Europe/Amsterdam" ;;
                "TH") TARGET_TZ="Asia/Bangkok" ;;
                "MY") TARGET_TZ="Asia/Kuala_Lumpur" ;;
                "VN") TARGET_TZ="Asia/Ho_Chi_Minh" ;;
                "PH") TARGET_TZ="Asia/Manila" ;;
                "ID") TARGET_TZ="Asia/Jakarta" ;;
                "IN") TARGET_TZ="Asia/Kolkata" ;;
                "AU") TARGET_TZ="Australia/Sydney" ;;
                "CA") TARGET_TZ="America/Toronto" ;;
                "US")
                    case "$STATE_ID" in
                        "CA"|"WA"|"OR"|"NV") TARGET_TZ="America/Los_Angeles" ;;
                        "IL"|"TX"|"MO")       TARGET_TZ="America/Chicago" ;;
                        *)                    TARGET_TZ="America/New_York" ;;
                    esac
                    ;;
                *) TARGET_TZ="UTC" ;;
            esac
        fi

        TARGET_TZ_NAME=$(get_tz_name "$TARGET_TZ")
        NODE_TIMEZONE="$TARGET_TZ"

        # 3. 比较时区并交互确认
        if [ "$CURRENT_TZ" == "$TARGET_TZ" ]; then
            echo -e " \033[32m✅ 检测到当前服务器时区 (${CURRENT_TZ}) 与目标 IP 归属地一致，无需调整。\033[0m"
        else
            echo -e "当前服务器的时区设置是： \033[33m${CURRENT_TZ}（${CURRENT_TZ_NAME}）\033[0m，是否修改为ip对应的时区设置： \033[32m${TARGET_TZ}\033[0m？"
            echo -e "（提示：后续养护动作会根据时区人员的作息规律更加人性化）【默认y】"
            read -p "请输入选择 [y/n] (默认y): " TZ_CHANGE_CHOICE
            TZ_CHANGE_CHOICE=${TZ_CHANGE_CHOICE:-y}

            if [[ "$TZ_CHANGE_CHOICE" =~ ^[Yy]$ ]]; then
                echo -n "⏳ 正在同步系统底层时区至 ${TARGET_TZ}..."
                if command -v timedatectl >/dev/null 2>&1; then
                    timedatectl set-timezone "$TARGET_TZ" >/dev/null 2>&1
                fi
                if [ -f "/usr/share/zoneinfo/$TARGET_TZ" ]; then
                    ln -sf "/usr/share/zoneinfo/$TARGET_TZ" /etc/localtime 2>/dev/null
                    echo "$TARGET_TZ" > /etc/timezone 2>/dev/null
                fi
                echo -e " \033[32m完成！\033[0m"
                echo -e "✅ 服务器时区已成功修改为: \033[32m$TARGET_TZ\033[0m"
                NODE_TIMEZONE="$TARGET_TZ"
            else
                echo -e "ℹ️ 已保留当前服务器时区设置 ($CURRENT_TZ)。"
                NODE_TIMEZONE="$CURRENT_TZ"
            fi
        fi
    fi
}

do_write_config() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n[5/7] 正在从云端数据仓库拉取 [${CITY_NAME}] 节点的底层规则..."
        REGION_JSON_FILE="${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json" -o "$REGION_JSON_FILE"

        if [ ! -s "$REGION_JSON_FILE" ]; then
            echo "❌ 拉取或解析规则失败！请检查 Forgejo 仓库是否公开或网络是否畅通。"
            exit 1
        fi

        REGION_NAME=$(jq -r '.region_name' "$REGION_JSON_FILE")
        BASE_LAT=$(jq -r '.google_module.base_lat' "$REGION_JSON_FILE")
        BASE_LON=$(jq -r '.google_module.base_lon' "$REGION_JSON_FILE")
        LANG_PARAMS=$(jq -r '.google_module.lang_params' "$REGION_JSON_FILE")
        VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$REGION_JSON_FILE")

        cat > "$CONFIG_FILE" << EOF
# IP-Sentinel 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
AGENT_VERSION="$TARGET_VERSION"
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

# 模块开关状态
ENABLE_GOOGLE="$ENABLE_GOOGLE"
ENABLE_TRUST="$ENABLE_TRUST"

TG_TOKEN="$TG_TOKEN"
TG_API_URL="$TG_API_URL"
CHAT_ID="$CHAT_ID"
AGENT_PORT="$AGENT_PORT"
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"
COMM_IP="$SAFE_COMM_IP"

NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_ALIAS"

ENABLE_OTA="$ENABLE_OTA"
TIMEZONE="${NODE_TIMEZONE:-$TARGET_TZ}"
EOF

        chmod 600 "$CONFIG_FILE"
    fi
}

do_smooth_migrate() {
    if [ "$UPGRADE_MODE" == "true" ]; then
        if ! grep -q "PUBLIC_IP=" "$CONFIG_FILE"; then
            echo -e "\n🔄 [平滑迁移] 正在对老节点进行无损双核身份架构升级..."
            
            MIGRATE_IP=$(curl -${IP_PREF:-4} -s -m 5 api.ip.sb/ip | tr -d '[:space:]')
            [[ "$MIGRATE_IP" == *":"* ]] && [[ "$MIGRATE_IP" != *"["* ]] && MIGRATE_IP="[${MIGRATE_IP}]"
            
            echo -n "🕵️ 正在进行补发链路试射 (NAT与双栈嗅探)..."
            RAW_TEST_IP=$(echo "$MIGRATE_IP" | tr -d '[]')
            if [[ "$RAW_TEST_IP" == *":"* ]]; then
                TEST_TARGET="https://[2606:4700:4700::1111]"
            else
                TEST_TARGET="https://1.1.1.1"
            fi
            
            if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
                echo -e " \033[32m✅ 原生直连，网卡死锁已继承。\033[0m"
                NEW_BIND_IP="$MIGRATE_IP"
            else
                echo -e " \033[33m⚠️ 发现 NAT 架构，已自动卸除老版本的物理枷锁。\033[0m"
                NEW_BIND_IP=""
            fi
            
            sed -i "s/^BIND_IP=.*/BIND_IP=\"$NEW_BIND_IP\"/" "$CONFIG_FILE"
            echo "PUBLIC_IP=\"$MIGRATE_IP\"" >> "$CONFIG_FILE"
            
            SAFE_PUBLIC_IP="$MIGRATE_IP"
            BIND_IP="$NEW_BIND_IP"
        else
            SAFE_PUBLIC_IP="${PUBLIC_IP}"
        fi

        # [v4.2.2 热修复] 为所有老节点 (无论是否已有残缺的 COMM_IP) 强行重铸多宿主容灾弹匣
        echo -e "\n🔄 [平滑迁移] 正在对老节点执行 v4.2.2 全域容灾弹匣重构..."
        
        RAW_V4=$(curl -4 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
        RAW_V6=$(curl -6 -s -m 3 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
        
        V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V4" =~ ^104\.28\. ]] || [[ "$RAW_V4" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            RAW_V4=""
        fi
        
        V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_V6" =~ ^fe80:|^::1 ]]; then
            RAW_V6=""
        fi
        
        # 绝对基座：始终确保养护 IP (SAFE_PUBLIC_IP) 处于弹匣的首发位置
        NEW_COMM_IP="$SAFE_PUBLIC_IP"
        RAW_BASE_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
        
        # 追加 V4 容灾备弹
        if [[ -n "$RAW_V4" ]] && [[ "$NEW_COMM_IP" != *"$RAW_V4"* ]]; then
            NEW_COMM_IP="${NEW_COMM_IP}_${RAW_V4}"
        fi
        
        # 追加 V6 容灾备弹
        if [[ -n "$RAW_V6" ]]; then
            [[ "$RAW_V6" != *"["* ]] && SAFE_V6="[${RAW_V6}]" || SAFE_V6="$RAW_V6"
            if [[ "$NEW_COMM_IP" != *"$SAFE_V6"* ]]; then
                NEW_COMM_IP="${NEW_COMM_IP}_${SAFE_V6}"
            fi
        fi
        
        # 强制覆盖 config.conf 中的旧 COMM_IP 记录
        sed -i '/^COMM_IP=/d' "$CONFIG_FILE"
        echo "COMM_IP=\"$NEW_COMM_IP\"" >> "$CONFIG_FILE"
        SAFE_COMM_IP="$NEW_COMM_IP"
        
        echo -e " \033[32m✅ 重铸容灾通讯专线完成: $SAFE_COMM_IP\033[0m"

        if ! grep -q "^NODE_NAME=" "$CONFIG_FILE"; then
            TMP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
            NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${TMP_HASH}"
            NODE_ALIAS="$NODE_NAME"
            echo "NODE_NAME=\"$NODE_NAME\"" >> "$CONFIG_FILE"
            echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
        else
            NODE_NAME=$(grep "^NODE_NAME=" "$CONFIG_FILE" | cut -d'"' -f2)
            NODE_ALIAS=$(grep "^NODE_ALIAS=" "$CONFIG_FILE" | cut -d'"' -f2)
            if [ -z "$NODE_ALIAS" ]; then
                NODE_ALIAS="$NODE_NAME"
                echo "NODE_ALIAS=\"$NODE_ALIAS\"" >> "$CONFIG_FILE"
            fi
        fi

        if ! grep -q "^ENABLE_OTA=" "$CONFIG_FILE"; then
            echo "ENABLE_OTA=\"false\"" >> "$CONFIG_FILE"
            ENABLE_OTA="false"
        else
            ENABLE_OTA=$(grep "^ENABLE_OTA=" "$CONFIG_FILE" | cut -d'"' -f2)
        fi
    fi
}
