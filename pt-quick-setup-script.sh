#!/bin/bash

###############################################################################
# Private Tracker 上传优化脚本 - 通用高速网络版 v2.0
# 适用场景：2.5Gbps / 10Gbps 网络，低延迟环境
# 作者：Claude | 更新日期：2025-11-13
# 特性：支持多队列网卡自动检测和适配
###############################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  PT 上传优化配置脚本 v2.0${NC}"
echo -e "${GREEN}  支持：2.5Gbps / 10Gbps 网络${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
    echo "使用: sudo $0"
    exit 1
fi

# 自动检测网卡
echo -e "${YELLOW}[1/7] 检测网络接口...${NC}"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$NETWORK_INTERFACE" ]; then
    echo -e "${RED}无法自动检测网卡，请手动指定：${NC}"
    read -p "请输入网卡名称 (如 eth0, ens33, eno1np0): " NETWORK_INTERFACE
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

# 备份现有配置
echo -e "${YELLOW}[2/7] 备份现有配置...${NC}"
BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/sysctl.conf "$BACKUP_FILE"
echo -e "${GREEN}✓ 已备份到: $BACKUP_FILE${NC}"
echo ""

# 检查是否已有配置（避免重复添加）
echo -e "${YELLOW}[3/7] 检查现有配置...${NC}"
if grep -q "PT 上传优化配置" /etc/sysctl.conf; then
    echo -e "${YELLOW}! 检测到已有 PT 优化配置${NC}"
    read -p "是否覆盖现有配置? [y/N]: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}保留现有配置，跳过 sysctl 修改${NC}"
        SKIP_SYSCTL=true
    else
        # 删除旧配置
        sed -i '/# PT 上传优化配置/,/# 配置结束/d' /etc/sysctl.conf
        SKIP_SYSCTL=false
    fi
else
    SKIP_SYSCTL=false
fi
echo ""

# 写入优化配置
if [ "$SKIP_SYSCTL" = false ]; then
    echo -e "${YELLOW}[4/7] 应用 TCP 优化参数...${NC}"

    cat >> /etc/sysctl.conf << 'EOF'

###############################################################################
# PT 上传优化配置 - 通用高速网络优化
# 配置时间：2025-11-13
# 支持场景：2.5Gbps / 10Gbps 网络
###############################################################################

# ==================== TCP 缓冲区优化 ====================
# 支持 2.5Gbps - 10Gbps 网络 + 低延迟场景
# 2.5Gbps × 40ms = 12.5MB，10Gbps × 40ms = 50MB
# 设置为 128MB 以支持多种场景和多流并发

net.core.rmem_max = 134217728          # 128MB 接收缓冲区最大值
net.core.wmem_max = 134217728          # 128MB 发送缓冲区最大值（上传关键）
net.core.rmem_default = 16777216       # 16MB 默认接收缓冲区
net.core.wmem_default = 16777216       # 16MB 默认发送缓冲区

# TCP 自动调优（支持高并发上传）
net.ipv4.tcp_rmem = 4096 87380 67108864    # min default max (64MB)
net.ipv4.tcp_wmem = 4096 65536 67108864    # min default max (64MB)

# 启用 TCP 窗口缩放（支持大窗口）
net.ipv4.tcp_window_scaling = 1

# 启用时间戳（精确 RTT 测量）
net.ipv4.tcp_timestamps = 1

# 启用选择性确认（SACK）
net.ipv4.tcp_sack = 1

# MTU 探测（推荐启用，避免 MTU 黑洞）
net.ipv4.tcp_mtu_probing = 1

# ==================== 队列调度器 ====================
# 使用 FQ (Fair Queue) 调度器，配合 BBR 效果最佳
net.core.default_qdisc = fq

# ==================== BBR 拥塞控制 ====================
# BBR 在低延迟欧洲网络中表现优异
net.ipv4.tcp_congestion_control = bbr

# ==================== 连接数优化（PT 必备）====================
# 扩大本地端口范围（支持更多并发上传）
net.ipv4.ip_local_port_range = 10000 65535

# 允许 TIME_WAIT 套接字快速回收
net.ipv4.tcp_tw_reuse = 1

# 减少 FIN_WAIT2 超时时间
net.ipv4.tcp_fin_timeout = 15

# 增加 SYN backlog 队列
net.ipv4.tcp_max_syn_backlog = 8192

# 增加 TCP 连接队列大小
net.core.somaxconn = 4096

# 增加网络设备接收队列
net.core.netdev_max_backlog = 16384

# ==================== Conntrack 优化 ====================
# 增加连接跟踪表大小（支持大量并发连接）
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576

# 减少连接跟踪超时时间
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# ==================== 其他优化 ====================
# 启用 TCP Fast Open（减少握手延迟）
net.ipv4.tcp_fastopen = 3

# 禁用 TCP 慢启动重启（保持高速传输）
net.ipv4.tcp_slow_start_after_idle = 0

# 增加 ARP 缓存大小
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

###############################################################################
# 配置结束
###############################################################################
EOF

    echo -e "${GREEN}✓ TCP 参数配置完成${NC}"
else
    echo -e "${YELLOW}[4/7] 跳过 TCP 参数配置（使用现有配置）${NC}"
fi
echo ""

# 应用 sysctl 配置
echo -e "${YELLOW}[5/7] 应用 sysctl 配置...${NC}"
if timeout 10 sysctl -p 2>&1 | grep -v "net.netfilter.nf_conntrack" > /tmp/sysctl_output.log; then
    echo -e "${GREEN}✓ sysctl 配置已生效${NC}"
else
    echo -e "${YELLOW}! sysctl 部分配置可能失败，但核心参数应已生效${NC}"
    echo -e "${YELLOW}  详细日志: /tmp/sysctl_output.log${NC}"
fi
echo ""

# 配置 tc 队列调度器和限速
echo -e "${YELLOW}[6/7] 配置队列调度器和带宽限制...${NC}"

# 针对不同带宽网卡设置合适的 maxrate
echo -e "${YELLOW}请选择限速策略：${NC}"
echo "1) 2.5Gbps 多流优化 (限速 2.3Gbps)"
echo "2) 10Gbps 单客户端优化 (限速 9.5Gbps)"
echo "3) 10Gbps 多客户端/多流优化 (限速 8Gbps，推荐)"
echo "4) 10Gbps 保守策略 (限速 7Gbps)"
echo "5) 不限速 (不推荐)"
read -p "请输入选项 [1-5] (默认: 3): " RATE_OPTION
RATE_OPTION=${RATE_OPTION:-3}

case $RATE_OPTION in
    1)
        MAXRATE="2.3gbit"
        ;;
    2)
        MAXRATE="9.5gbit"
        ;;
    3)
        MAXRATE="8gbit"
        ;;
    4)
        MAXRATE="7gbit"
        ;;
    5)
        MAXRATE=""
        ;;
    *)
        MAXRATE="8gbit"
        ;;
esac

# 删除旧的 qdisc 规则（支持多队列网卡）
echo -e "${BLUE}  正在清理现有队列规则...${NC}"
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true

# 根据网卡类型配置
if [ "$IS_MULTI_QUEUE" = true ]; then
    echo -e "${BLUE}  检测到多队列网卡，使用特殊配置...${NC}"
    # 多队列网卡需要先删除 mq，然后直接添加 fq
    if [ -n "$MAXRATE" ]; then
        tc qdisc replace dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ 已设置 FQ 调度器（多队列网卡），限速: $MAXRATE${NC}"
    else
        tc qdisc replace dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ 已设置 FQ 调度器（多队列网卡），不限速${NC}"
    fi
else
    # 单队列网卡直接添加
    if [ -n "$MAXRATE" ]; then
        tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
        echo -e "${GREEN}✓ 已设置 FQ 调度器，限速: $MAXRATE${NC}"
    else
        tc qdisc add dev $NETWORK_INTERFACE root fq
        echo -e "${GREEN}✓ 已设置 FQ 调度器，不限速${NC}"
    fi
fi

# 验证 TC 配置
echo -e "${BLUE}  验证队列配置...${NC}"
if tc qdisc show dev $NETWORK_INTERFACE | grep -q "qdisc fq"; then
    echo -e "${GREEN}✓ FQ 调度器配置成功${NC}"
else
    echo -e "${RED}✗ FQ 调度器配置失败，请检查${NC}"
fi
echo ""

# 创建启动脚本（持久化 tc 配置）
echo -e "${YELLOW}[7/7] 创建开机启动脚本...${NC}"

# 生成 TC 配置命令
if [ -n "$MAXRATE" ]; then
    TC_COMMAND="tc qdisc replace dev $NETWORK_INTERFACE root fq maxrate $MAXRATE"
else
    TC_COMMAND="tc qdisc replace dev $NETWORK_INTERFACE root fq"
fi

# 检测系统类型
if [ -d /etc/systemd/system ]; then
    # Systemd 系统
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

    # 创建执行脚本
    cat > /usr/local/bin/pt-tc-setup.sh << EOF
#!/bin/bash
# PT TC Optimizer - Auto-generated script
# Network Interface: $NETWORK_INTERFACE
# Multi-Queue: $IS_MULTI_QUEUE
# Max Rate: ${MAXRATE:-unlimited}

# 等待网卡就绪
sleep 2

# 删除旧规则
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true

# 应用新规则
$TC_COMMAND

# 验证配置
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
    systemctl enable pt-tc-optimizer.service
    
    # 立即启动服务验证
    if systemctl start pt-tc-optimizer.service; then
        echo -e "${GREEN}✓ 已创建并启动 systemd 服务: pt-tc-optimizer.service${NC}"
    else
        echo -e "${YELLOW}! systemd 服务创建成功，但启动失败，请检查${NC}"
        echo -e "${YELLOW}  运行 'systemctl status pt-tc-optimizer.service' 查看详情${NC}"
    fi

elif [ -f /etc/rc.local ]; then
    # 使用 rc.local
    if ! grep -q "pt-tc-setup" /etc/rc.local 2>/dev/null; then
        sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
        echo "" >> /etc/rc.local
        echo "# PT Upload Traffic Control Optimizer" >> /etc/rc.local
        echo "sleep 2" >> /etc/rc.local
        echo "tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true" >> /etc/rc.local
        echo "$TC_COMMAND" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
        echo -e "${GREEN}✓ 已添加到 /etc/rc.local${NC}"
    else
        echo -e "${YELLOW}! /etc/rc.local 中已存在配置，请手动检查${NC}"
    fi
else
    echo -e "${YELLOW}! 未检测到 systemd 或 rc.local，请手动添加 tc 命令到启动脚本${NC}"
    echo -e "${YELLOW}  命令: $TC_COMMAND${NC}"
fi
echo ""

# 验证配置
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  配置验证${NC}"
echo -e "${GREEN}==================================================${NC}"

echo -e "\n${YELLOW}网卡信息:${NC}"
echo "  接口: $NETWORK_INTERFACE"
echo "  速率: $LINK_SPEED"
echo "  类型: $([ "$IS_MULTI_QUEUE" = true ] && echo "多队列网卡 (MQ)" || echo "单队列网卡")"

echo -e "\n${YELLOW}TCP 缓冲区设置:${NC}"
sysctl net.ipv4.tcp_wmem
sysctl net.ipv4.tcp_rmem

echo -e "\n${YELLOW}拥塞控制算法:${NC}"
sysctl net.ipv4.tcp_congestion_control
if lsmod | grep -q bbr; then
    BBR_CONNECTIONS=$(lsmod | grep bbr | awk '{print $3}')
    echo -e "${GREEN}✓ BBR 模块已加载 (${BBR_CONNECTIONS} 个连接使用中)${NC}"
else
    echo -e "${RED}✗ BBR 模块未加载，可能需要内核 >= 4.9${NC}"
fi

echo -e "\n${YELLOW}队列调度器:${NC}"
tc qdisc show dev $NETWORK_INTERFACE | head -n 3

if tc qdisc show dev $NETWORK_INTERFACE | grep -q "qdisc fq.*maxrate"; then
    CURRENT_RATE=$(tc qdisc show dev $NETWORK_INTERFACE | grep "qdisc fq" | grep -oP 'maxrate \K[^ ]+')
    echo -e "${GREEN}✓ FQ 调度器已启用，限速: $CURRENT_RATE${NC}"
elif tc qdisc show dev $NETWORK_INTERFACE | grep -q "qdisc fq"; then
    echo -e "${GREEN}✓ FQ 调度器已启用，不限速${NC}"
else
    echo -e "${YELLOW}! 警告: 未检测到 FQ 调度器${NC}"
fi

echo -e "\n${YELLOW}连接跟踪表:${NC}"
sysctl net.netfilter.nf_conntrack_max 2>/dev/null || sysctl net.nf_conntrack_max 2>/dev/null || echo "conntrack 未启用"

echo -e "\n${YELLOW}端口范围:${NC}"
sysctl net.ipv4.ip_local_port_range

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  优化完成！${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${YELLOW}建议操作：${NC}"
echo "1. ${RED}重启系统${NC}以确保所有配置生效: ${RED}reboot${NC}"
echo "2. 重启后验证 TC 配置: ${RED}tc qdisc show dev $NETWORK_INTERFACE${NC}"
echo "3. 启动 PT 客户端测试上传速度"
echo "4. 使用 ${RED}iftop -i $NETWORK_INTERFACE${NC} 监控实时流量"
echo "5. 如需恢复配置，使用备份文件: ${RED}$BACKUP_FILE${NC}"
echo ""
echo -e "${YELLOW}故障排查命令：${NC}"
echo "- 检查 systemd 服务: ${RED}systemctl status pt-tc-optimizer.service${NC}"
echo "- 手动应用 TC 配置: ${RED}$TC_COMMAND${NC}"
echo "- 查看系统日志: ${RED}journalctl -u pt-tc-optimizer.service${NC}"
echo "- 检查防火墙规则: ${RED}iptables -L -n${NC}"
echo ""
echo -e "${BLUE}配置摘要：${NC}"
echo "  网卡: $NETWORK_INTERFACE ($([ "$IS_MULTI_QUEUE" = true ] && echo "多队列" || echo "单队列"))"
echo "  限速: ${MAXRATE:-不限速}"
echo "  BBR: $([ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ] && echo "已启用" || echo "未启用")"
echo "  开机启动: $([ -f /etc/systemd/system/pt-tc-optimizer.service ] && echo "systemd" || echo "rc.local")"
echo ""
echo -e "${GREEN}脚本执行完成！建议立即重启系统。${NC}"
