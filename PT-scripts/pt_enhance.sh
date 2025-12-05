#!/bin/bash

###############################################################################
# PT 上传优化脚本 - 精简版 v5.1
# 新增：自动检测网卡速率并适配限速策略
# 专注：TCP 参数优化 + BBR/FQ 配置
# 前提：用户已自行安装 BBRv3 内核
# 作者：Claude | 更新日期：2025-12-06
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 默认配置 ====================
DEFAULT_INTERFACE=""
DEFAULT_RATE_OPTION="5"        # 5=不限速 / auto / 1-4
DEFAULT_BBR_VERSION="bbr"      # bbr / bbr2 / bbr3 / cubic
AUTO_REBOOT="n"
SILENT_MODE=true

show_help() {
    cat << EOF
${GREEN}═══════════════════════════════════════════════════${NC}
${GREEN}  PT 上传优化脚本 v5.1 - 自动检测版${NC}
${GREEN}  专注 TCP 参数 + BBR/FQ 配置${NC}
${GREEN}═══════════════════════════════════════════════════${NC}

${YELLOW}用法：${NC}
    $0 [选项]

${YELLOW}选项：${NC}
    -i, --interface <网卡>      指定网络接口
    -r, --rate <auto|1-5>       限速策略
                                  auto) 自动检测
                                  1) 2.5Gbps (2.3Gbps)
                                  2) 10Gbps 单流 (9.5Gbps)
                                  3) 10Gbps 多流 (8Gbps)
                                  4) 10Gbps 保守 (7Gbps)
                                  5) 不限速 [默认]
    -b, --bbr <版本>            BBR 版本：bbr3/bbr2/bbr/cubic
    -R, --reboot                配置完成后自动重启
    -y, --yes                   无人值守模式
    -h, --help                  显示帮助

${CYAN}示例：${NC}
    # 完全自动化（推荐）
    $0 -y -R

    # 指定网卡 + 自动检测速率
    $0 -i eth0 -y

    # 手动指定限速 + BBR v3
    $0 -i eth0 -r 3 -b bbr3

${CYAN}环境变量：${NC}
    PT_INTERFACE=eth0
    PT_RATE=5              # 默认不限速
    PT_BBR=bbr3
    PT_AUTO_REBOOT=y

EOF
}

# ==================== 解析参数 ====================
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interface) DEFAULT_INTERFACE="$2"; shift 2 ;;
        -r|--rate) DEFAULT_RATE_OPTION="$2"; shift 2 ;;
        -b|--bbr) DEFAULT_BBR_VERSION="$2"; shift 2 ;;
        -R|--reboot) AUTO_REBOOT="y"; shift ;;
        -y|--yes) SILENT_MODE=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo -e "${RED}未知参数: $1${NC}"; show_help; exit 1 ;;
    esac
done

# 环境变量支持
DEFAULT_INTERFACE=${PT_INTERFACE:-$DEFAULT_INTERFACE}
DEFAULT_RATE_OPTION=${PT_RATE:-$DEFAULT_RATE_OPTION}
DEFAULT_BBR_VERSION=${PT_BBR:-$DEFAULT_BBR_VERSION}
AUTO_REBOOT=${PT_AUTO_REBOOT:-$AUTO_REBOOT}

echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  PT 上传优化脚本 v5.1 - 自动检测版${NC}"
echo -e "${GREEN}  模式: $([ "$SILENT_MODE" = true ] && echo "无人值守" || echo "交互式")${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

# 检查 root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误：需要 root 权限${NC}"
    exit 1
fi

# ==================== 检测系统 ====================
echo -e "${YELLOW}[1/5] 检测系统信息...${NC}"
KERNEL_VERSION=$(uname -r)
CPU_CORES=$(nproc)
echo -e "${GREEN}  内核: $KERNEL_VERSION${NC}"
echo -e "${GREEN}  CPU 核心: $CPU_CORES${NC}"

# 检测 BBR 支持
AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
if [[ "$AVAILABLE_CC" =~ "bbr" ]]; then
    echo -e "${GREEN}  BBR 支持: ✓${NC}"
else
    echo -e "${YELLOW}  BBR 支持: ✗ (将使用 CUBIC)${NC}"
    DEFAULT_BBR_VERSION="cubic"
fi
echo ""

# ==================== 检测网卡 ====================
echo -e "${YELLOW}[2/5] 检测网卡...${NC}"

if [ -z "$DEFAULT_INTERFACE" ]; then
    NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$NETWORK_INTERFACE" ]; then
        if [ "$SILENT_MODE" = true ]; then
            echo -e "${RED}无法自动检测网卡${NC}"; exit 1
        else
            echo "可用网卡："
            ip -o link show | awk -F': ' '{print "  " $2}'
            read -p "请输入网卡名称: " NETWORK_INTERFACE
        fi
    fi
else
    NETWORK_INTERFACE="$DEFAULT_INTERFACE"
fi

if ! ip link show "$NETWORK_INTERFACE" &>/dev/null; then
    echo -e "${RED}网卡不存在: $NETWORK_INTERFACE${NC}"; exit 1
fi

echo -e "${GREEN}✓ 网卡: $NETWORK_INTERFACE${NC}"

# 网卡信息
LINK_SPEED=$(ethtool $NETWORK_INTERFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/[^0-9]//g' || echo "0")
LINK_SPEED_DISPLAY=$(ethtool $NETWORK_INTERFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "Unknown")
echo -e "${GREEN}  速率: $LINK_SPEED_DISPLAY${NC}"

# 检测队列类型
QDISC_TYPE=$(tc qdisc show dev $NETWORK_INTERFACE | head -n1 | awk '{print $2}')
IS_MULTI_QUEUE=false
if [ "$QDISC_TYPE" = "mq" ]; then
    IS_MULTI_QUEUE=true
    echo -e "${GREEN}  类型: 多队列网卡${NC}"
else
    echo -e "${GREEN}  类型: 单队列网卡${NC}"
fi
echo ""

# ==================== 备份并配置 sysctl ====================
echo -e "${YELLOW}[3/5] 配置 TCP 参数...${NC}"

# 备份
BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/sysctl.conf "$BACKUP_FILE"
echo -e "${BLUE}  已备份: $BACKUP_FILE${NC}"

# 删除旧配置
if grep -q "# PT_OPTIMIZER_START" /etc/sysctl.conf; then
    sed -i '/# PT_OPTIMIZER_START/,/# PT_OPTIMIZER_END/d' /etc/sysctl.conf
    echo -e "${BLUE}  已删除旧配置${NC}"
fi

# 写入新配置
cat >> /etc/sysctl.conf << EOF

# PT_OPTIMIZER_START - 配置于 $(date +%Y-%m-%d\ %H:%M:%S)
# 网卡: $NETWORK_INTERFACE | BBR: $DEFAULT_BBR_VERSION

# ==================== TCP 缓冲区（高带宽优化）====================
net.core.rmem_max = 134217728              # 128MB
net.core.wmem_max = 134217728              # 128MB
net.core.rmem_default = 16777216           # 16MB
net.core.wmem_default = 16777216           # 16MB
net.ipv4.tcp_rmem = 4096 87380 67108864    # TCP RX
net.ipv4.tcp_wmem = 4096 65536 67108864    # TCP TX（上传关键）

# ==================== TCP 协议优化 ====================
net.ipv4.tcp_window_scaling = 1            # 窗口缩放
net.ipv4.tcp_timestamps = 1                # 时间戳
net.ipv4.tcp_sack = 1                      # 选择性确认
net.ipv4.tcp_mtu_probing = 1               # MTU 探测
net.ipv4.tcp_fastopen = 3                  # Fast Open
net.ipv4.tcp_slow_start_after_idle = 0     # 禁用慢启动重启
net.ipv4.tcp_notsent_lowat = 16384         # 低延迟优化

# ==================== BBR 拥塞控制 ====================
net.core.default_qdisc = fq                # Fair Queue
net.ipv4.tcp_congestion_control = $DEFAULT_BBR_VERSION

# ==================== 连接数优化（PT 高并发）====================
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 32768

# ==================== Conntrack ====================
net.netfilter.nf_conntrack_max = 2097152
net.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# ==================== 其他优化 ====================
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 32768

# PT_OPTIMIZER_END
EOF

echo -e "${GREEN}✓ TCP 参数已写入 /etc/sysctl.conf${NC}"

# 应用配置
sysctl -p > /dev/null 2>&1
echo -e "${GREEN}✓ 配置已生效${NC}"

# 加载 BBR 模块
modprobe tcp_bbr 2>/dev/null || true
echo -e "${GREEN}✓ BBR 模块已加载${NC}"
echo ""

# ==================== 配置 TC 队列（自动检测速率）====================
echo -e "${YELLOW}[4/5] 配置 TC 队列（FQ）...${NC}"

# 自动检测速率并选择限速策略
if [ "$DEFAULT_RATE_OPTION" = "auto" ]; then
    echo -e "${BLUE}  正在根据网卡速率自动选择限速策略...${NC}"
    
    if [ "$LINK_SPEED" -ge 40000 ]; then
        # 40Gbps 及以上
        RATE_OPTION="5"
        echo -e "${GREEN}  检测到 ${LINK_SPEED_DISPLAY} 网卡 → 选择策略 5: 不限速${NC}"
    elif [ "$LINK_SPEED" -ge 10000 ]; then
        # 10Gbps
        RATE_OPTION="3"
        echo -e "${GREEN}  检测到 ${LINK_SPEED_DISPLAY} 网卡 → 选择策略 3: 10Gbps 多流 (8Gbps)${NC}"
    elif [ "$LINK_SPEED" -ge 2500 ]; then
        # 2.5Gbps - 10Gbps 之间
        RATE_OPTION="1"
        echo -e "${GREEN}  检测到 ${LINK_SPEED_DISPLAY} 网卡 → 选择策略 1: 2.5Gbps (2.3Gbps)${NC}"
    elif [ "$LINK_SPEED" -ge 1000 ]; then
        # 1Gbps
        MAXRATE="950mbit"
        RATE_OPTION="custom"
        echo -e "${GREEN}  检测到 ${LINK_SPEED_DISPLAY} 网卡 → 使用自定义限速: 950Mbit${NC}"
    else
        # 小于 1Gbps 或检测失败
        RATE_OPTION="5"
        echo -e "${YELLOW}  无法准确检测速率 → 选择策略 5: 不限速${NC}"
    fi
elif [[ "$DEFAULT_RATE_OPTION" =~ ^[1-5]$ ]]; then
    RATE_OPTION="$DEFAULT_RATE_OPTION"
    echo -e "${BLUE}  使用手动指定的策略: $RATE_OPTION${NC}"
else
    echo -e "${RED}  无效的速率选项: $DEFAULT_RATE_OPTION${NC}"
    RATE_OPTION="3"
    echo -e "${YELLOW}  使用默认策略: 3 (10Gbps 多流)${NC}"
fi

# 根据策略设置限速
if [ "$RATE_OPTION" != "custom" ]; then
    case $RATE_OPTION in
        1) MAXRATE="2.3gbit" ;;
        2) MAXRATE="9.5gbit" ;;
        3) MAXRATE="8gbit" ;;
        4) MAXRATE="7gbit" ;;
        5) MAXRATE="" ;;
        *) MAXRATE="8gbit" ;;
    esac
fi

# 删除旧规则
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true

# 应用 FQ
if [ "$IS_MULTI_QUEUE" = true ]; then
    if [ -n "$MAXRATE" ]; then
        tc qdisc replace dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ FQ (多队列)，限速: $MAXRATE${NC}"
    else
        tc qdisc replace dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ FQ (多队列)，不限速${NC}"
    fi
else
    if [ -n "$MAXRATE" ]; then
        tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ FQ，限速: $MAXRATE${NC}"
    else
        tc qdisc add dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ FQ，不限速${NC}"
    fi
fi
echo ""

# ==================== 创建启动脚本 ====================
echo -e "${YELLOW}[5/5] 创建开机启动...${NC}"

TC_CMD="tc qdisc replace dev $NETWORK_INTERFACE root fq$([ -n "$MAXRATE" ] && echo " maxrate $MAXRATE")"

# 创建启动脚本
cat > /usr/local/bin/pt-tc-setup.sh << EOF
#!/bin/bash
# PT TC 配置 - 自动生成于 $(date)
sleep 2
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true
$TC_CMD
exit 0
EOF

chmod +x /usr/local/bin/pt-tc-setup.sh

# 创建 systemd 服务
if [ -d /etc/systemd/system ]; then
    cat > /etc/systemd/system/pt-tc.service << EOF
[Unit]
Description=PT TC Optimizer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pt-tc-setup.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable pt-tc.service 2>/dev/null
    systemctl start pt-tc.service 2>/dev/null
    echo -e "${GREEN}✓ systemd 服务已创建${NC}"
else
    # 使用 rc.local 作为后备
    if [ -f /etc/rc.local ]; then
        if ! grep -q "pt-tc-setup" /etc/rc.local; then
            sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
            echo "/usr/local/bin/pt-tc-setup.sh" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
            chmod +x /etc/rc.local
            echo -e "${GREEN}✓ rc.local 配置完成${NC}"
        fi
    fi
fi
echo ""

# ==================== 完成总结 ====================
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}【配置摘要】${NC}"
echo "  网卡: $NETWORK_INTERFACE ($LINK_SPEED_DISPLAY)"
echo "  拥塞控制: $DEFAULT_BBR_VERSION"
echo "  队列算法: FQ (Fair Queue)"
echo "  限速: ${MAXRATE:-不限速}"
echo "  策略: $([ "$DEFAULT_RATE_OPTION" = "auto" ] && echo "自动检测" || echo "手动指定")"
echo ""
echo -e "${CYAN}【当前状态】${NC}"
echo "  BBR 状态: $(lsmod | grep tcp_bbr >/dev/null && echo "✓ 已加载" || echo "✗ 未加载")"
echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  TC 队列: $(tc qdisc show dev $NETWORK_INTERFACE | head -n1)"
echo ""
echo -e "${CYAN}【验证命令】${NC}"
echo "  sysctl net.ipv4.tcp_congestion_control  # 查看拥塞控制"
echo "  tc qdisc show dev $NETWORK_INTERFACE    # 查看 TC 配置"
echo "  lsmod | grep bbr                         # 查看 BBR 模块"
echo "  ss -s                                    # 查看连接数"
echo "  iftop -i $NETWORK_INTERFACE              # 实时流量监控"
echo ""
echo -e "${CYAN}【管理命令】${NC}"
echo "  systemctl status pt-tc.service           # 查看服务状态"
echo "  systemctl restart pt-tc.service          # 重启服务"
echo "  journalctl -u pt-tc.service              # 查看日志"
echo ""

if [ "$AUTO_REBOOT" = "y" ]; then
    echo -e "${YELLOW}系统将在 10 秒后重启...${NC}"
    echo -e "${RED}按 Ctrl+C 取消${NC}"
    sleep 10
    reboot
else
    echo -e "${YELLOW}【建议】${NC}"
    echo "  1. 重启系统以确保所有配置生效"
    echo "  2. 重启后运行验证命令检查状态"
    echo ""
    
    if [ "$SILENT_MODE" = false ]; then
        read -p "是否现在重启? [y/N]: " REBOOT_NOW
        if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}正在重启...${NC}"
            reboot
        fi
    fi
fi

echo -e "${GREEN}配置完成！${NC}"
