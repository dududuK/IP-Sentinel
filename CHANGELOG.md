# Changelog

## [v4.4.0] - 2026-11-23

### ✨ Features
- **人格档案系统 (Persona Archive)** — 新增 `core/agent_common.sh` 共享库：每节点按 IP+月份哈希固化一套 UA 画像并落盘（`data/persona/`），30 天轮换，根治"同一 Cookie 每轮换设备指纹"的机器人特征；mod_google / mod_trust 跨模块共享同一画像
- **分浏览器指纹头引擎** — 按 UA 自动识别 Chrome/Edge/Firefox/Safari 家族：Chromium 系按 UA 实时解析版本生成 Sec-Ch-Ua（杜绝 UA 与 Client Hints 版本脱节），Firefox/Safari 不再发送 Chrome 专属头；Accept/Accept-Encoding 按引擎真实行为分化
- **Accept-Language 区域化** — 从 `lang_params` 的 hl/gl 参数派生本地化语言头（如 ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7），根治全区域 en-US 硬编码穿帮
- **curl-impersonate 可选接入** — 检测到 `curl_chrome*`/`curl_ff*`/`curl_safari*` 等二进制时自动启用真实浏览器 TLS 指纹（JA3/JA4），未安装回退系统 curl；支持 `SENTINEL_CURL_BIN` 强制指定
- **安装器自动部署 curl-impersonate** — `install/env_setup.sh`（新装）与 `core/install.sh`（OTA/旧版）在依赖安装阶段自动拉取 GitHub Release 预编译产物至 `/usr/local/bin`；支持 x86_64/aarch64/armv7l，Alpine 自动补 gcompat，试运行失败自动回滚，best-effort 绝不阻断安装
- **行为多样化** — mod_google 动作深度扩至 2-4 且停留时间改泊松长尾分布；8% 概率切入区域白名单中的本地生态站点漫游，脱离 Google 同域流量聚类；Sec-Fetch-Site 按 same-site/cross-site 如实上报
- **UA 指纹库换代 (V6.0.0)** — ua_generator 全面更新至当代版本（Chrome 140-143 / Firefox 144-147 / Safari 26.x / Android 14-16），按真实市场份额配比 4000 条，剔除三年前的古董指纹

### 🐛 Bug Fixes
- **修复 mod_trust 白名单区域错配** — 旧版 `find|head -n1` 随机抓取任意城市 json，多城市国家拿错白名单；现按 BASE_LAT/BASE_LON 坐标在 regions/ 全库做最近邻匹配，锁定本节点专属规则文件
- **修复 mod_trust log_msg 先调用后定义** — jq 缺失告警分支会触发 command not found，函数定义前移至首个调用点之前
- **修复探针双画像穿帮** — YouTube 送中探针复用人格档案 UA 与传输引擎，不再"浏览器 UA 漫游 + 裸 Chrome/124 探针"混用

## [v4.3.4] - 2026-08-26

### ✨ Features
- **全舰队切换 Bot 凭证** (#102) — 更换 TG Bot 不再需要逐台卸载重装。Master 主菜单新增「🔁 全舰队切换 Bot 凭证」按钮：填写新 Token + Chat ID 后，司令部先 getMe 验证，再向所有开启 OTA 权限的节点批量下发切换指令；各节点自动完成凭证验证、向新 Bot 推送注册回执、原子重写本地配置，Chat ID 变更时自动重启守护进程完成 HMAC 密钥轮换
- **Agent 端新增 /trigger_reconfig 路由** — 复用 b64 安全 Base64 载荷与 HMAC 签名鉴权；ENABLE_OTA=false 的节点自动熔断（与 Master 下发范围对齐）；先推注册后改配置，任一步失败旧凭证保持完好

### 🐛 Bug Fixes
- **修复 TG API 无效凭证返回 HTTP 401 时 Agent 误报 500** — urllib 对非 2xx 抛异常，现捕获 HTTPError 并解析响应体，正确回传 403 + 失败原因

## [v4.3.2] - 2026-07-24

### ✨ Features
- **新增重新发送注册指令** — Master 重新部署导致 Agent 节点信息丢失时，无需重新安装 Agent，直接运行 `bash /opt/ip_sentinel/core/install.sh` 选择选项 3，一键向 Telegram 推送注册命令即可恢复节点连接
- **添加布法罗地区信息** (#100)
- **注入尔湾 (Irvine) 节点** (#98)
- **扩编芝加哥 (Chicago) 节点** (#90)

### 🐛 Bug Fixes
- **修复模块化入口缺少选项3** — `install/ui_menu.sh` 同步新增重新注册功能（实际运行走此入口）
- **Telegram MarkdownV2 消息换行乱码** — `\n` 字面量改为实际换行，特殊字符正确转义

### 🎨 Improvements
- **暗黑模式星标图表修复** — 采用 GitHub 原生深色主题渲染，坐标轴不再隐形
- **升级星标趋势图引擎** — 自研渲染引擎，彻底摆脱第三方服务 502 问题

### 🔒 Security
- **添加 .gitignore** — 防止密钥泄露

## [v4.3.1] - 2026-07-24

### ✨ Features
- 分布式 VPS IP 养护系统 v4.3.1
- Master-Agent 架构，Telegram Bot 控制
- Agent 每20分钟执行养护循环（mod_google 区域模拟搜索、mod_quality IP质量探测、mod_trust 白名单访问）
- HMAC-SHA256 动态签名 60 秒有效期
- WARP 过滤、防火墙自动管理
- Python3 标准库零第三方依赖
