#!/bin/bash

###############################################################################
# Private Tracker 上传优化脚本 - 通用高速网络版
# 适用场景：2.5Gbps / 10Gbps 网络，低延迟环境
# 作者：Claude | 日期：2025-11-13
###############################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  PT 上传优化配置脚本 - 通用高速网络版${NC}"
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
echo -e "${YELLOW}[1/6] 检测网络接口...${NC}"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$NETWORK_INTERFACE" ]; then
    echo -e "${RED}无法自动检测网卡，请手动指定：${NC}"
    read -p "请输入网卡名称 (如 eth0, ens33): " NETWORK_INTERFACE
fi

echo -e "${GREEN}✓ 使用网卡: $NETWORK_INTERFACE${NC}"

# 检测当前带宽（可选）
LINK_SPEED=$(ethtool $NETWORK_INTERFACE 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "Unknown")
echo -e "${GREEN}  当前速率: $LINK_SPEED${NC}"
echo ""

# 备份现有配置
echo -e "${YELLOW}[2/6] 备份现有配置...${NC}"
BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/sysctl.conf "$BACKUP_FILE"
echo -e "${GREEN}✓ 已备份到: $BACKUP_FILE${NC}"
echo ""

# 写入优化配置
echo -e "${YELLOW}[3/6] 应用 TCP 优化参数...${NC}"

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
echo ""

# 应用 sysctl 配置
echo -e "${YELLOW}[4/6] 应用 sysctl 配置...${NC}"
sysctl -p > /dev/null 2>&1
echo -e "${GREEN}✓ sysctl 配置已生效${NC}"
echo ""

# 配置 tc 队列调度器和限速
echo -e "${YELLOW}[5/6] 配置队列调度器和带宽限制...${NC}"

# 删除旧的 qdisc 规则（如果存在）
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true

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

if [ -n "$MAXRATE" ]; then
    tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE
    echo -e "${GREEN}✓ 已设置 FQ 调度器，限速: $MAXRATE${NC}"
else
    tc qdisc add dev $NETWORK_INTERFACE root fq
    echo -e "${GREEN}✓ 已设置 FQ 调度器，不限速${NC}"
fi
echo ""

# 创建启动脚本（持久化 tc 配置）
echo -e "${YELLOW}[6/6] 创建开机启动脚本...${NC}"

# 检测系统类型
if [ -d /etc/systemd/system ]; then
    # Systemd 系统
    cat > /etc/systemd/system/pt-tc-optimizer.service << EOF
[Unit]
Description=PT Upload Traffic Control Optimizer
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pt-tc-setup.sh

[Install]
WantedBy=multi-user.target
EOF

    # 创建执行脚本
    cat > /usr/local/bin/pt-tc-setup.sh << EOF
#!/bin/bash
tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true
EOF
    
    if [ -n "$MAXRATE" ]; then
        echo "tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE" >> /usr/local/bin/pt-tc-setup.sh
    else
        echo "tc qdisc add dev $NETWORK_INTERFACE root fq" >> /usr/local/bin/pt-tc-setup.sh
    fi
    
    chmod +x /usr/local/bin/pt-tc-setup.sh
    systemctl daemon-reload
    systemctl enable pt-tc-optimizer.service
    echo -e "${GREEN}✓ 已创建 systemd 服务: pt-tc-optimizer.service${NC}"

elif [ -f /etc/rc.local ]; then
    # 使用 rc.local
    if ! grep -q "pt-tc-setup" /etc/rc.local 2>/dev/null; then
        sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
        echo "" >> /etc/rc.local
        echo "# PT Upload Traffic Control Optimizer" >> /etc/rc.local
        echo "tc qdisc del dev $NETWORK_INTERFACE root 2>/dev/null || true" >> /etc/rc.local
        if [ -n "$MAXRATE" ]; then
            echo "tc qdisc add dev $NETWORK_INTERFACE root fq maxrate $MAXRATE" >> /etc/rc.local
        else
            echo "tc qdisc add dev $NETWORK_INTERFACE root fq" >> /etc/rc.local
        fi
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
        echo -e "${GREEN}✓ 已添加到 /etc/rc.local${NC}"
    fi
else
    echo -e "${YELLOW}! 未检测到 systemd 或 rc.local，请手动添加 tc 命令到启动脚本${NC}"
fi
echo ""

# 验证配置
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  配置验证${NC}"
echo -e "${GREEN}==================================================${NC}"

echo -e "\n${YELLOW}TCP 缓冲区设置:${NC}"
sysctl net.ipv4.tcp_wmem
sysctl net.ipv4.tcp_rmem

echo -e "\n${YELLOW}拥塞控制算法:${NC}"
sysctl net.ipv4.tcp_congestion_control
lsmod | grep bbr || echo -e "${RED}警告: BBR 模块未加载，可能需要内核 >= 4.9${NC}"

echo -e "\n${YELLOW}队列调度器:${NC}"
tc qdisc show dev $NETWORK_INTERFACE

echo -e "\n${YELLOW}连接跟踪表:${NC}"
sysctl net.netfilter.nf_conntrack_max 2>/dev/null || sysctl net.nf_conntrack_max

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  优化完成！${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${YELLOW}建议操作：${NC}"
echo "1. 重启系统以确保所有配置生效: ${RED}reboot${NC}"
echo "2. 重启后验证配置: ${RED}sudo tc qdisc show${NC}"
echo "3. 启动 PT 客户端测试上传速度"
echo "4. 使用 ${RED}iftop -i $NETWORK_INTERFACE${NC} 监控实时流量"
echo "5. 如需恢复配置，使用备份文件: $BACKUP_FILE"
echo ""
echo -e "${YELLOW}故障排查：${NC}"
echo "- 如果 BBR 未启用，请确认内核版本 >= 4.9"
echo "- 如果上传速度仍不理想，尝试调整 maxrate 值"
echo "- 检查防火墙规则: ${RED}iptables -L -n${NC}"
echo ""
echo -e "${GREEN}脚本执行完成！${NC}"
