#!/bin/bash

###############################################################################
# Private Tracker 上传优化脚本 - BBR 优化版 v3.0
# 适用场景：2.5Gbps / 10Gbps 网络，欧洲低延迟环境 (德国/荷兰/英国)
# 作者：Claude | 更新日期：2025-01-10
# 特性：BBR 专项优化 + 多队列网卡自动检测
###############################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}  PT 上传优化配置脚本 v3.0 - BBR 优化版${NC}"
echo -e "${GREEN}  支持：2.5Gbps / 10Gbps 网络 + 欧洲低延迟${NC}"
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
# PT 上传优化配置 - BBR 专项优化版
# 配置时间：2025-01-10
# 支持场景：2.5Gbps / 10Gbps 网络 + 欧洲低延迟环境
# 优化目标：最大化 PT 上传分享率，保持大量并发连接
###############################################################################

# ==================== TCP 缓冲区优化 - PT 上传优化版 ====================
# 针对欧洲低延迟网络 (德国/荷兰/英国: RTT 5-20ms)
# 10Gbps × 20ms = 25MB BDP，设置为 256MB 支持多并发上传
# PT 场景特点：数百个并发连接同时上传

net.core.rmem_max = 268435456          # 256MB 接收缓冲区最大值
net.core.wmem_max = 268435456          # 256MB 发送缓冲区最大值 (上传关键!)
net.core.rmem_default = 33554432       # 32MB 默认接收缓冲区
net.core.wmem_default = 33554432       # 32MB 默认发送缓冲区

# TCP 自动调优 - 激进策略以最大化上传吞吐量
# 欧洲内部网络质量好，可以设置更大的缓冲区
net.ipv4.tcp_rmem = 8192 262144 134217728   # min default max (128MB)
net.ipv4.tcp_wmem = 8192 262144 134217728   # min default max (128MB，上传关键!)

# 调整窗口缩放系数 (-2 = 更激进的窗口增长)
net.ipv4.tcp_adv_win_scale = -2

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

# ==================== BBR 拥塞控制 + PT 专项优化 ====================
# BBR 在低延迟欧洲网络中表现优异，非常适合 PT 上传
net.ipv4.tcp_congestion_control = bbr

# **关键优化**: tcp_notsent_lowat - 减少发送缓冲区积压
# 对于 PT 多连接场景，设置为 128KB 可以：
# 1. 减少每个连接的缓冲区占用
# 2. 让 BBR 更精确地控制发送速率
# 3. 避免过度缓冲导致的延迟增加
# 建议值：16KB-131072 (131072 = 128KB 适合高速网络)
net.ipv4.tcp_notsent_lowat = 131072

# 启用 ECN (显式拥塞通知) - 帮助 BBR 更快检测拥塞
# 欧洲骨干网普遍支持 ECN，强烈建议启用
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# ==================== 连接数优化 (PT 必备) ====================
# 扩大本地端口范围 (支持更多并发上传连接)
net.ipv4.ip_local_port_range = 1024 65535

# 允许 TIME_WAIT 套接字快速回收 (推荐设置为 1，而非 2)
net.ipv4.tcp_tw_reuse = 1

# 减少 FIN_WAIT2 超时时间
net.ipv4.tcp_fin_timeout = 10

# 增加 SYN backlog 队列
net.ipv4.tcp_max_syn_backlog = 16384

# 增加 TCP 连接队列大小
net.core.somaxconn = 8192

# 增加网络设备接收队列
net.core.netdev_max_backlog = 32768

# TCP 孤儿连接数限制（PT 大量连接场景需提高）
net.ipv4.tcp_max_orphans = 262144

# 减少 keepalive 探测时间，快速清理死连接
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# ==================== Conntrack 优化 ====================
# 增加连接跟踪表大小（支持大量并发连接）
# PT 场景建议设置为 2097152 (200万连接)
net.netfilter.nf_conntrack_max = 2097152
net.nf_conntrack_max = 2097152

# 减少连接跟踪超时时间
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30

# ==================== 其他优化 ====================
# 启用 TCP Fast Open（减少握手延迟，对 PT 很有帮助）
net.ipv4.tcp_fastopen = 3

# 禁用 TCP 慢启动重启（保持高速传输，PT 上传关键！）
net.ipv4.tcp_slow_start_after_idle = 0

# 禁用 TCP 指标保存（减少内存占用，提高性能）
net.ipv4.tcp_no_metrics_save = 1

# 启用 TCP 早期重传
net.ipv4.tcp_early_retrans = 3

# TCP 重排序阈值（降低假重传）
net.ipv4.tcp_reordering = 3

# 增加 ARP 缓存大小
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 16384
net.ipv4.neigh.default.gc_thresh3 = 32768

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
echo "1) 2.5Gbps PT 专用 (限速 2.4Gbps，推荐留 100Mbps 余量)"
echo "2) 10Gbps PT 激进模式 (限速 9.5Gbps，适合专用服务器)"
echo "3) 10Gbps PT 稳定模式 (限速 8.5Gbps，推荐，更好的多流公平性)"
echo "4) 10Gbps PT 保守模式 (限速 7.5Gbps，多用户共享服务器)"
echo "5) 不限速 (让 BBR 自动控制，适合测试)"
read -p "请输入选项 [1-5] (默认: 3): " RATE_OPTION
RATE_OPTION=${RATE_OPTION:-3}

case $RATE_OPTION in
    1)
        MAXRATE="2.4gbit"
        ;;
    2)
        MAXRATE="9.5gbit"
        ;;
    3)
        MAXRATE="8.5gbit"
        ;;
    4)
        MAXRATE="7.5gbit"
        ;;
    5)
        MAXRATE=""
        ;;
    *)
        MAXRATE="8.5gbit"
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

echo -e "\n${YELLOW}BBR 关键参数:${NC}"
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "tcp_notsent_lowat: 未设置或内核不支持"
sysctl net.ipv4.tcp_ecn

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
echo "3. 验证 BBR 已启用: ${RED}sysctl net.ipv4.tcp_congestion_control${NC}"
echo "4. 启动 PT 客户端测试上传速度"
echo "5. 使用 ${RED}iftop -i $NETWORK_INTERFACE${NC} 监控实时流量"
echo "6. 如需恢复配置，使用备份文件: ${RED}$BACKUP_FILE${NC}"
echo ""
echo -e "${YELLOW}PT 客户端优化建议：${NC}"
echo "- qBittorrent: 设置全局最大连接数 1000-2000，每个种子 100-200"
echo "- Deluge: 启用 libtorrent 1.2+ 以支持更好的上传调度"
echo "- Transmission: 调整 peer-limit-global 到 2000+"
echo "- 建议开启 uTP 协议以获得更好的拥塞控制"
echo "- 上传槽位设置: 建议 50-100 (根据带宽和连接数调整)"
echo ""
echo -e "${YELLOW}欧洲 PT 站点特别提示：${NC}"
echo "- 德国/荷兰服务器: RTT 通常 5-15ms，BBR 效果最佳"
echo "- 英国服务器: RTT 通常 10-25ms，仍能保持优秀性能"
echo "- 跨大西洋连接: RTT 80-120ms，BBR 相比 CUBIC 优势更明显"
echo "- 建议监控指标: 上传速度、活跃连接数、分享率"
echo ""
echo -e "${YELLOW}故障排查命令：${NC}"
echo "- 检查 systemd 服务: ${RED}systemctl status pt-tc-optimizer.service${NC}"
echo "- 手动应用 TC 配置: ${RED}$TC_COMMAND${NC}"
echo "- 查看系统日志: ${RED}journalctl -u pt-tc-optimizer.service${NC}"
echo "- 检查活跃连接数: ${RED}ss -s${NC}"
echo "- 检查 conntrack 使用率: ${RED}cat /proc/sys/net/netfilter/nf_conntrack_count${NC}"
echo "- 实时监控 TCP 统计: ${RED}watch -n 1 'ss -tin | head -20'${NC}"
echo ""
echo -e "${BLUE}配置摘要：${NC}"
echo "  网卡: $NETWORK_INTERFACE ($([ "$IS_MULTI_QUEUE" = true ] && echo "多队列" || echo "单队列"))"
echo "  限速: ${MAXRATE:-不限速}"
echo "  BBR: $([ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && echo "已启用" || echo "未启用")"
echo "  tcp_notsent_lowat: 131072 (128KB)"
echo "  ECN: 已启用"
echo "  开机启动: $([ -f /etc/systemd/system/pt-tc-optimizer.service ] && echo "systemd" || echo "rc.local")"
echo ""
echo -e "${GREEN}脚本执行完成！建议立即重启系统。${NC}"
echo -e "${BLUE}重启后可运行以下命令验证 BBR 效果：${NC}"
echo -e "${RED}ss -ti | grep bbr | head -5${NC}"
echo ""
