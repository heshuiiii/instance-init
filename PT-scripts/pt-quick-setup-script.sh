#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 默认配置参数 ====================
DEFAULT_INTERFACE=""        # 留空则自动检测
DEFAULT_RATE_OPTION="5"     # 默认不限速
DEFAULT_OVERWRITE="y"       # y/n: 是否覆盖现有配置
AUTO_REBOOT="n"            # y/n: 完成后自动重启

# ==================== 显示帮助信息 ====================
show_help() {
    cat << EOF
${GREEN}PT 上传优化脚本 v2.2 - 默认不限速版${NC}

用法: 
    $0 [选项]

选项:
    -i, --interface <网卡名>    指定网络接口 (如: eth0, ens33)
    -r, --rate <1-5>            选择限速策略:
                                  1) 2.5Gbps (限速 2.3Gbps)
                                  2) 10Gbps 单流 (限速 9.5Gbps)
                                  3) 10Gbps 多流 (限速 8Gbps)
                                  4) 10Gbps 保守 (限速 7Gbps)
                                  5) 不限速 [默认]
    -o, --overwrite             自动覆盖现有配置 (不询问)
    -R, --reboot                配置完成后自动重启
    -y, --yes                   完全无人值守模式
    -h, --help                  显示此帮助信息

示例:
    # 完全自动化: 默认不限速, 自动重启 (推荐)
    $0 -y -R

    # 指定网卡, 不限速
    $0 -i eth0 -y

    # 指定限速 8Gbps
    $0 -i eth0 -r 3 -y -R

环境变量 (可选):
    PT_INTERFACE=eth0          等同于 -i eth0
    PT_RATE=5                  等同于 -r 5 (默认)
    PT_AUTO_REBOOT=y           等同于 -R

EOF
}

# ==================== 解析命令行参数 ====================
SILENT_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interface)
            DEFAULT_INTERFACE="$2"
            shift 2
            ;;
        -r|--rate)
            DEFAULT_RATE_OPTION="$2"
            shift 2
            ;;
        -o|--overwrite)
            DEFAULT_OVERWRITE="y"
            shift
            ;;
        -R|--reboot)
            AUTO_REBOOT="y"
            shift
            ;;
        -y|--yes)
            SILENT_MODE=true
            DEFAULT_OVERWRITE="y"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# 支持环境变量配置
DEFAULT_INTERFACE=${PT_INTERFACE:-$DEFAULT_INTERFACE}
DEFAULT_RATE_OPTION=${PT_RATE:-$DEFAULT_RATE_OPTION}
AUTO_REBOOT=${PT_AUTO_REBOOT:-$AUTO_REBOOT}

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  PT 上传优化配置脚本 v2.2 (默认不限速)${NC}"
echo -e "${GREEN}  支持：2.5Gbps / 10Gbps 网络${NC}"
echo -e "${GREEN}  模式：$([ "$SILENT_MODE" = true ] && echo "无人值守" || echo "交互式")${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
    echo "使用: sudo $0 [选项]"
    exit 1
fi

# ==================== 自动检测或使用指定网卡 ====================
echo -e "${YELLOW}[1/7] 检测网络接口...${NC}"

if [ -z "$DEFAULT_INTERFACE" ]; then
    NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [ -z "$NETWORK_INTERFACE" ]; then
        if [ "$SILENT_MODE" = true ]; then
            echo -e "${RED}错误：无法自动检测网卡，请使用 -i 参数指定${NC}"
            exit 1
        else
            echo -e "${RED}无法自动检测网卡，请手动指定：${NC}"
            read -p "请输入网卡名称 (如 eth0, ens33, eno1np0): " NETWORK_INTERFACE
        fi
    fi
else
    NETWORK_INTERFACE="$DEFAULT_INTERFACE"
fi

# 验证网卡是否存在
if ! ip link show "$NETWORK_INTERFACE" &>/dev/null; then
    echo -e "${RED}错误：网卡 $NETWORK_INTERFACE 不存在${NC}"
    echo "可用网卡："
    ip -o link show | awk -F': ' '{print "  - " $2}'
    exit 1
fi

echo -e "${GREEN}✓ 使用网卡: $NETWORK_INTERFACE${NC}"

# 检测当前带宽和队列类型
LINK_SPEED=$(ethtool $NETWORK_INTERFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "Unknown")
echo -e "${GREEN}  当前速率: $LINK_SPEED${NC}"

# 检测是否为多队列网卡
QDISC_TYPE=$(tc qdisc show dev $NETWORK_INTERFACE | head -n1 | awk '{print $2}')
IS_MULTI_QUEUE=false
if [ "$QDISC_TYPE" = "mq" ]; then
    IS_MULTI_QUEUE=true
    echo -e "${BLUE}  网卡类型: 多队列网卡 (MQ)${NC}"
else
    echo -e "${BLUE}  网卡类型: 单队列网卡${NC}"
fi
echo ""

# ==================== 备份现有配置 ====================
echo -e "${YELLOW}[2/7] 备份现有配置...${NC}"
BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/sysctl.conf "$BACKUP_FILE"
echo -e "${GREEN}✓ 已备份到: $BACKUP_FILE${NC}"
echo ""

# ==================== 检查并覆盖现有配置 ====================
echo -e "${YELLOW}[3/7] 检查现有配置...${NC}"
SKIP_SYSCTL=false

if grep -q "PT 上传优化配置" /etc/sysctl.conf; then
    echo -e "${YELLOW}! 检测到已有 PT 优化配置${NC}"
    
    # 无人值守模式直接覆盖
    if [ "$SILENT_MODE" = true ]; then
        OVERWRITE="y"
        echo "  → 自动覆盖现有配置"
    else
        read -p "是否覆盖现有配置? [y/N]: " OVERWRITE
        OVERWRITE=${OVERWRITE:-$DEFAULT_OVERWRITE}
    fi
    
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        sed -i '/# PT 上传优化配置/,/# 配置结束/d' /etc/sysctl.conf
        echo -e "${GREEN}✓ 已删除旧配置${NC}"
    else
        echo -e "${BLUE}保留现有配置，跳过 sysctl 修改${NC}"
        SKIP_SYSCTL=true
    fi
else
    echo -e "${GREEN}✓ 未检测到旧配置${NC}"
fi
echo ""

# ==================== 写入优化配置 ====================
if [ "$SKIP_SYSCTL" = false ]; then
    echo -e "${YELLOW}[4/7] 应用 TCP 优化参数...${NC}"

    cat >> /etc/sysctl.conf << 'EOF'

###############################################################################
# PT 上传优化配置 - 通用高速网络优化
# 配置时间：AUTO_GENERATED
# 支持场景：2.5Gbps / 10Gbps 网络
###############################################################################

# ==================== TCP 缓冲区优化 ====================
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1

# ==================== 队列调度器 ====================
net.core.default_qdisc = fq

# ==================== BBR 拥塞控制 ====================
net.ipv4.tcp_congestion_control = bbr

# ==================== 连接数优化 ====================
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384

# ==================== Conntrack 优化 ====================
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# ==================== 其他优化 ====================
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

###############################################################################
# 配置结束
###############################################################################
EOF

    sed -i "s/AUTO_GENERATED/$(date +%Y-%m-%d\ %H:%M:%S)/g" /etc/sysctl.conf
    echo -e "${GREEN}✓ TCP 参数配置完成${NC}"
else
    echo -e "${YELLOW}[4/7] 跳过 TCP 参数配置（使用现有配置）${NC}"
fi
echo ""

# ==================== 应用 sysctl 配置 ====================
echo -e "${YELLOW}[5/7] 应用 sysctl 配置...${NC}"
if timeout 10 sysctl -p 2>&1 | grep -v "net.netfilter.nf_conntrack" > /tmp/sysctl_output.log; then
    echo -e "${GREEN}✓ sysctl 配置已生效${NC}"
else
    echo -e "${YELLOW}! sysctl 部分配置可能失败，但核心参数应已生效${NC}"
fi
echo ""

# ==================== 配置限速策略（无人值守模式）====================
echo -e "${YELLOW}[6/7] 配置队列调度器和带宽限制...${NC}"

# 无人值守模式：直接使用默认配置，不再询问
RATE_OPTION=$DEFAULT_RATE_OPTION

if [ "$SILENT_MODE" = true ]; then
    case $RATE_OPTION in
        1) echo "  → 使用限速策略: 2.5Gbps (2.3Gbps)" ;;
        2) echo "  → 使用限速策略: 10Gbps 单流 (9.5Gbps)" ;;
        3) echo "  → 使用限速策略: 10Gbps 多流 (8Gbps)" ;;
        4) echo "  → 使用限速策略: 10Gbps 保守 (7Gbps)" ;;
        5) echo "  → 使用限速策略: 不限速 (推荐)" ;;
    esac
else
    # 交互模式：显示选项
    echo -e "${YELLOW}请选择限速策略：${NC}"
    echo "1) 2.5Gbps 多流优化 (限速 2.3Gbps)"
    echo "2) 10Gbps 单客户端优化 (限速 9.5Gbps)"
    echo "3) 10Gbps 多客户端/多流优化 (限速 8Gbps)"
    echo "4) 10Gbps 保守策略 (限速 7Gbps)"
    echo "5) 不限速 (推荐)"
    read -p "请输入选项 [1-5] (默认: 5): " RATE_OPTION
    RATE_OPTION=${RATE_OPTION:-5}
fi

case $RATE_OPTION in
    1) MAXRATE="2.3gbit" ;;
    2) MAXRATE="9.5gbit" ;;
    3) MAXRATE="8gbit" ;;
    4) MAXRATE="7gbit" ;;
    5) MAXRATE="" ;;
    *) MAXRATE="" ;;
esac

# 清理旧规则
echo -e "${BLUE}  正在清理现有队列规则...${NC}"
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true

# 应用新规则
if [ "$IS_MULTI_QUEUE" = true ]; then
    if [ -n "$MAXRATE" ]; then
        tc qdisc replace dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ 已设置 FQ 调度器（多队列），限速: $MAXRATE${NC}"
    else
        tc qdisc replace dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ 已设置 FQ 调度器（多队列），不限速${NC}"
    fi
else
    if [ -n "$MAXRATE" ]; then
        tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ 已设置 FQ 调度器，限速: $MAXRATE${NC}"
    else
        tc qdisc add dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ 已设置 FQ 调度器，不限速${NC}"
    fi
fi

# 验证配置
if tc qdisc show dev $NETWORK_INTERFACE | grep -q "qdisc fq"; then
    echo -e "${GREEN}✓ FQ 调度器配置成功${NC}"
else
    echo -e "${RED}✗ FQ 调度器配置失败${NC}"
fi
echo ""

# ==================== 创建开机启动脚本 ====================
echo -e "${YELLOW}[7/7] 创建开机启动脚本...${NC}"

if [ -n "$MAXRATE" ]; then
    TC_COMMAND="tc qdisc replace dev $NETWORK_INTERFACE root fq maxrate $MAXRATE"
else
    TC_COMMAND="tc qdisc replace dev $NETWORK_INTERFACE root fq"
fi

if [ -d /etc/systemd/system ]; then
    cat > /etc/systemd/system/pt-tc-optimizer.service << EOF
[Unit]
Description=PT Upload Traffic Control Optimizer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pt-tc-setup.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/bin/pt-tc-setup.sh << EOF
#!/bin/bash
# PT TC Optimizer - Auto-generated: $(date)
sleep 2
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true
$TC_COMMAND
if tc qdisc show dev $NETWORK_INTERFACE | grep -q "qdisc fq"; then
    echo "TC configuration applied successfully"
    exit 0
else
    echo "TC configuration failed"
    exit 1
fi
EOF
    
    chmod +x /usr/local/bin/pt-tc-setup.sh
    systemctl daemon-reload
    systemctl enable pt-tc-optimizer.service 2>/dev/null
    systemctl start pt-tc-optimizer.service 2>/dev/null
    echo -e "${GREEN}✓ 已创建 systemd 服务${NC}"

elif [ -f /etc/rc.local ]; then
    if ! grep -q "pt-tc-setup" /etc/rc.local 2>/dev/null; then
        sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
        echo "" >> /etc/rc.local
        echo "# PT TC Optimizer" >> /etc/rc.local
        echo "sleep 2" >> /etc/rc.local
        echo "tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true" >> /etc/rc.local
        echo "$TC_COMMAND" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
        echo -e "${GREEN}✓ 已添加到 rc.local${NC}"
    fi
fi
echo ""

# ==================== 配置完成总结 ====================
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  优化完成！${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${BLUE}配置摘要：${NC}"
echo "  网卡: $NETWORK_INTERFACE ($([ "$IS_MULTI_QUEUE" = true ] && echo "多队列" || echo "单队列"))"
echo "  限速: ${MAXRATE:-不限速}"
echo "  BBR: $([ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && echo "已启用" || echo "未启用")"
echo "  开机启动: $([ -f /etc/systemd/system/pt-tc-optimizer.service ] && echo "systemd" || echo "rc.local")"
echo ""

if [ "$AUTO_REBOOT" = "y" ]; then
    echo -e "${YELLOW}系统将在 10 秒后自动重启...${NC}"
    echo -e "${RED}按 Ctrl+C 取消重启${NC}"
    sleep 10
    reboot
else
    echo -e "${YELLOW}建议操作：${NC}"
    echo "1. ${RED}重启系统${NC}以确保所有配置生效: ${RED}reboot${NC}"
    echo "2. 重启后验证: ${RED}tc qdisc show dev $NETWORK_INTERFACE${NC}"
    echo ""
    
    if [ "$SILENT_MODE" = false ]; then
        read -p "是否现在重启? [y/N]: " REBOOT_NOW
        if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}正在重启...${NC}"
            reboot
        fi
    fi
fi
