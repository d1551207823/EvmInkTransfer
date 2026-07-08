#!/bin/bash
#=============================================================================
# Xray Socks5 多IP一键部署脚本
# 自动检测服务器所有内网IP，为每个IP生成独立的 Socks5 入站+路由+出站
#
# 一条命令部署:
#   bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/setup-xray-socks5.sh)
#=============================================================================
set -e

#=== 颜色 ===
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_ask()   { echo -e "${CYAN}[INPUT]${NC} $*"; }

#=== 默认值 ===
SOCKS_PORT=1081
SOCKS_USER="admin"
SOCKS_PASS="admin123"
CUSTOM_DIRECT_DOMAINS=("domain:599.com" "ip138.com")

usage() {
    cat <<EOF
用法: bash setup-xray-socks5.sh [选项]

选项:
  -p, --port PORT          SOCKS5 端口 (默认: 1081)
  -u, --user USER          认证用户名 (默认: admin)
  -P, --pass PASS          认证密码   (默认: admin123)
  -d, --direct DOMAINS     直连域名, 逗号分隔 (默认: domain:599.com,ip138.com)
  -i, --ips IP1,IP2,IP3    手动指定IP, 逗号分隔 (默认: 自动检测)
  -y                       跳过确认, 直接部署
  -h, --help               显示帮助

示例:
  bash setup-xray-socks5.sh                           # 全自动
  bash setup-xray-socks5.sh -p 2080 -P mypass -y     # 自定义参数, 跳过确认
  bash setup-xray-socks5.sh -i 10.0.0.1,10.0.0.2,10.0.0.3
EOF
    exit 0
}

#=== 解析参数 ===
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)   SOCKS_PORT="$2"; shift 2 ;;
        -u|--user)   SOCKS_USER="$2"; shift 2 ;;
        -P|--pass)   SOCKS_PASS="$2"; shift 2 ;;
        -d|--direct) IFS=',' read -ra CUSTOM_DIRECT_DOMAINS <<< "$2"; shift 2 ;;
        -i|--ips)    IFS=',' read -ra MANUAL_IPS <<< "$2"; shift 2 ;;
        -y)          SKIP_CONFIRM=true; shift ;;
        -h|--help)   usage ;;
        *) log_error "未知参数: $1"; usage ;;
    esac
done

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Xray Socks5 多IP 一键部署脚本               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

[[ $EUID -ne 0 ]] && { log_error "请用 root 用户运行"; exit 1; }

#=============================================================================
# 第1步：自动检测服务器IP
#=============================================================================
log_info "正在检测服务器内网IP..."

# 方法: hostname -I 一行拿所有非lo的IPv4
detected_raw=$(hostname -I 2>/dev/null || true)

# fallback: 用 ip 命令逐个接口取
if [[ -z "$detected_raw" ]]; then
    detected_raw=$(ip -4 addr show 2>/dev/null | \
        grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
        grep -v '^127\.' | sort -u | tr '\n' ' ')
fi

# 转数组, 同时排除 127.x.x.x
DETECTED_IPS=()
for ip in $detected_raw; do
    [[ "$ip" =~ ^127\. ]] && continue
    DETECTED_IPS+=("$ip")
done

# 如果有 docker0 网桥, 只排除这一个IP (不按网段过滤, 避免误伤云服务器内网IP)
DOCKER_IP=""
if ip link show docker0 &>/dev/null 2>&1; then
    DOCKER_IP=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    [[ -n "$DOCKER_IP" ]] && log_info "检测到 docker0 (${DOCKER_IP}), 已自动排除"
fi

FILTERED_IPS=()
for ip in "${DETECTED_IPS[@]}"; do
    [[ "$ip" == "$DOCKER_IP" ]] && continue
    FILTERED_IPS+=("$ip")
done

# 决定最终使用的IP
if [[ -n "${MANUAL_IPS[*]}" ]]; then
    SELECTED_IPS=("${MANUAL_IPS[@]}")
    log_info "使用手动指定的 ${#SELECTED_IPS[@]} 个IP"
else
    log_info "检测到 ${#FILTERED_IPS[@]} 个内网IP: ${FILTERED_IPS[*]}"

    if [[ ${#FILTERED_IPS[@]} -eq 0 ]]; then
        log_error "未检测到有效IP, 请用 --ips 手动指定"
        exit 1
    elif [[ ${#FILTERED_IPS[@]} -eq 1 ]]; then
        log_warn "只检测到1个IP, 将搭建单IP代理"
        SELECTED_IPS=("${FILTERED_IPS[@]}")
    else
        # 多个IP: 列出让用户选
        echo ""
        for i in "${!FILTERED_IPS[@]}"; do
            echo "  [$((i+1))] ${FILTERED_IPS[$i]}"
        done
        echo ""
        log_ask "输入要使用的IP序号, 逗号分隔 (直接回车=全部使用):"
        read -r ip_selection

        if [[ -z "$ip_selection" ]]; then
            SELECTED_IPS=("${FILTERED_IPS[@]}")
        else
            IFS=',' read -ra idxs <<< "$ip_selection"
            SELECTED_IPS=()
            for idx in "${idxs[@]}"; do
                SELECTED_IPS+=("${FILTERED_IPS[$((idx-1))]}")
            done
        fi
    fi
fi

# 确认界面
echo ""
log_info "======== 配置确认 ========"
echo "  代理IP数量 : ${#SELECTED_IPS[@]}"
for i in "${!SELECTED_IPS[@]}"; do
    echo "  IP-$((i+1))    : ${SELECTED_IPS[$i]}"
done
echo "  SOCKS端口  : ${SOCKS_PORT}"
echo "  用户名     : ${SOCKS_USER}"
echo "  密码       : ${SOCKS_PASS}"
echo "  直连域名   : ${CUSTOM_DIRECT_DOMAINS[*]}"
echo "=========================="
echo ""

if [[ "$SKIP_CONFIRM" != true ]]; then
    read -r -p "确认部署? (Y/n): " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && { log_info "已取消"; exit 0; }
fi

#=============================================================================
# 第2步：安装 Xray
#=============================================================================
log_info "正在安装/检查 Xray..."

if command -v xray &>/dev/null; then
    log_info "Xray 已安装 ($(xray version 2>&1 | head -1 || true))"
else
    log_info "下载安装 Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    log_info "Xray 安装完成"
fi

#=============================================================================
# 第3步：生成配置文件
#=============================================================================
log_info "正在生成 Xray 配置..."

XRAY_CONFIG="/usr/local/etc/xray/config.json"

# --- 生成 inbounds ---
gen_inbounds() {
    local count=0 total=${#SELECTED_IPS[@]}
    for i in "${!SELECTED_IPS[@]}"; do
        local ip="${SELECTED_IPS[$i]}"
        local tag="socks-${SOCKS_PORT}-${i}"
        local comma=$((count < total - 1 ? 1 : 0))
        cat <<INBOUND
    {
      "tag": "${tag}",
      "listen": "${ip}",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          { "user": "${SOCKS_USER}", "pass": "${SOCKS_PASS}" }
        ],
        "udp": true,
        "udpAddress": "${ip}"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }$( [[ $comma -eq 1 ]] && echo "," )
INBOUND
        ((count++))
    done
}

# --- 生成 routing rules ---
gen_routing_rules() {
    # 计算规则总数，用于判断最后一条不加逗号
    local total=0
    [[ ${#CUSTOM_DIRECT_DOMAINS[@]} -gt 0 ]] && ((total++))   # 自定义域名
    ((total++))                                                # geoip:private
    total=$((total + ${#SELECTED_IPS[@]}))                     # 每个IP的入站路由
    local idx=0

    # 自定义直连域名
    if [[ ${#CUSTOM_DIRECT_DOMAINS[@]} -gt 0 ]]; then
        local domains
        domains=$(printf '"%s",' "${CUSTOM_DIRECT_DOMAINS[@]}")
        domains="${domains%,}"
        local comma=","
        [[ $idx -eq $((total - 1)) ]] && comma=""
        cat <<RULE
      {
        "type": "field",
        "domain": [${domains}],
        "outboundTag": "direct"
      }${comma}

RULE
        ((idx++))
    fi

    # 私有IP直连
    local comma=","
    [[ $idx -eq $((total - 1)) ]] && comma=""
    cat <<RULE
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }${comma}

RULE
    ((idx++))

    # 每个IP的入站→出站路由
    for i in "${!SELECTED_IPS[@]}"; do
        local ip="${SELECTED_IPS[$i]}"
        local tag="socks-${SOCKS_PORT}-${i}"
        local comma=","
        [[ $idx -eq $((total - 1)) ]] && comma=""
        echo "      { \"type\": \"field\", \"inboundTag\": [\"${tag}\"], \"outboundTag\": \"out-${i}\" }${comma}"
        ((idx++))
    done
}

# --- 生成 outbounds ---
gen_outbounds() {
    for i in "${!SELECTED_IPS[@]}"; do
        local ip="${SELECTED_IPS[$i]}"
        cat <<OUTBOUND
    { "tag": "out-${i}", "protocol": "freedom", "sendThrough": "${ip}" },
OUTBOUND
    done
    cat <<OUTBOUND
    { "tag": "direct", "protocol": "freedom" },
    { "protocol": "blackhole", "tag": "block" }
OUTBOUND
}

# 组装并写入
cat > "${XRAY_CONFIG}" <<JSONEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
$(gen_inbounds)
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
$(gen_routing_rules)
    ]
  },
  "outbounds": [
$(gen_outbounds)
  ]
}
JSONEOF

log_info "配置已写入: ${XRAY_CONFIG}"

#=============================================================================
# 第4步：重启 Xray
#=============================================================================
log_info "重启 Xray 服务..."
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    log_info "Xray 运行正常 ✓"
else
    log_error "Xray 启动失败!"
    echo "--- 最近日志 ---"
    journalctl -u xray --no-pager -n 20 2>/dev/null || true
    exit 1
fi

#=============================================================================
# 第5步：输出连接信息
#=============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              部署成功!                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
for i in "${!SELECTED_IPS[@]}"; do
    echo -e "  ${YELLOW}代理${i}${NC}  socks5://${SOCKS_USER}:${SOCKS_PASS}@${SELECTED_IPS[$i]}:${SOCKS_PORT}"
done
echo ""
echo -e "  ${CYAN}状态:${NC} systemctl status xray"
echo -e "  ${CYAN}日志:${NC} journalctl -u xray -f"
echo -e "  ${CYAN}配置:${NC} ${XRAY_CONFIG}"
echo ""
echo -e "${GREEN}完成!${NC}"
