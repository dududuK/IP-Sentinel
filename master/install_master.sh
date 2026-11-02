#!/bin/bash
# ==========================================================
# 脚本名称: install_master.sh (动态模块化终极引导入口)
# 核心功能: 极简引导入口。包含 Ctrl+C 优雅中断，动态版本嗅探
# ==========================================================

cleanup_and_exit() {
    echo -e "\n\n\033[33m⚠️ 检测到中断信号 (Ctrl+C)，安装操作已被手动中止。\033[0m"
    echo -e "🧹 正在清理临时沙盒文件..."
    rm -rf "$SECURE_TMP" 2>/dev/null
    exit 1
}
trap cleanup_and_exit INT QUIT TERM
trap 'rm -rf "$SECURE_TMP" 2>/dev/null' EXIT HUP

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

SECURE_TMP=$(mktemp -d /tmp/ips_master_install.XXXXXX)
REPO_RAW_URL="https://raw.githubusercontent.com/dududuK/IP-Sentinel/main"

# ----------------------------------------------------------
# [核心架构升级] 动态嗅探云端真理之源 (SSOT)
# ----------------------------------------------------------
TARGET_VERSION=$( (curl -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)" || curl -4 -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)") 2>/dev/null | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
TARGET_VERSION=${TARGET_VERSION:-"4.3.1"}

echo -e "\n⏳ 正在拉取 IP-Sentinel Master v${TARGET_VERSION} 安装引擎..."

curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/build_master.sh?t=$(date +%s)" -o "${SECURE_TMP}/build_master.sh"

if [ ! -s "${SECURE_TMP}/build_master.sh" ]; then
    echo -e "\033[31m❌ 致命错误：中枢安装引擎拉取失败！\033[0m"
    exit 1
fi

export SECURE_TMP
export REPO_RAW_URL
export TARGET_VERSION

chmod +x "${SECURE_TMP}/build_master.sh"
bash "${SECURE_TMP}/build_master.sh"

exit $?
