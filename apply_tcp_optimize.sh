# #!/bin/bash

# # TCP 优化配置应用脚本
# # 适用于 PT 上传等需要稳定长连接的场景

# set -e

# # 颜色定义
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# NC='\033[0m' # No Color

# # 配置文件路径
# CONFIG_FILE="/etc/sysctl.d/99-tcp-optimize.conf"

# # 检查是否以 root 权限运行
# if [[ $EUID -ne 0 ]]; then
#    echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
#    echo "请使用: sudo $0"
#    exit 1
# fi

# echo -e "${GREEN}=== TCP 优化配置应用脚本 ===${NC}\n"

# # 备份现有配置(如果存在)
# if [ -f "$CONFIG_FILE" ]; then
#     BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
#     echo -e "${YELLOW}发现现有配置,备份到: ${BACKUP_FILE}${NC}"
#     cp "$CONFIG_FILE" "$BACKUP_FILE"
# fi

# # 写入配置
# echo -e "${GREEN}正在写入配置到 ${CONFIG_FILE}...${NC}"
# cat > "$CONFIG_FILE" << 'EOF'
# # TCP 优化配置 - PT 上传专用
# # 生成时间: $(date)

# # TCP Keepalive 参数 - 保持连接活跃
# net.ipv4.tcp_keepalive_time = 120
# net.ipv4.tcp_keepalive_intvl = 30
# net.ipv4.tcp_keepalive_probes = 5

# # 增加 TCP 重传次数,避免因暂时网络波动断连
# net.ipv4.tcp_retries2 = 15

# # 启用 TCP 窗口缩放,提升长连接性能
# net.ipv4.tcp_window_scaling = 1

# # 增加 TCP 缓冲区,适合大量上传连接
# net.core.rmem_max = 16777216
# net.core.wmem_max = 16777216
# net.ipv4.tcp_rmem = 4096 87380 16777216
# net.ipv4.tcp_wmem = 4096 65536 16777216

# # 增加最大连接数
# net.core.somaxconn = 4096
# net.ipv4.tcp_max_syn_backlog = 8192

# # 减少 TIME_WAIT 状态连接数量
# net.ipv4.tcp_fin_timeout = 30
# net.ipv4.tcp_tw_reuse = 1

# # 禁用慢启动,适合持续上传
# net.ipv4.tcp_slow_start_after_idle = 0
# EOF

# echo -e "${GREEN}配置文件写入完成!${NC}\n"

# # 应用配置
# echo -e "${GREEN}正在应用配置...${NC}"
# if sysctl -p "$CONFIG_FILE"; then
#     echo -e "${GREEN}✓ 配置应用成功!${NC}\n"
# else
#     echo -e "${RED}✗ 配置应用失败,请检查错误信息${NC}"
#     exit 1
# fi

# # 显示当前生效的配置
# echo -e "${GREEN}=== 当前生效的 TCP 配置 ===${NC}"
# echo -e "${YELLOW}Keepalive 设置:${NC}"
# sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes

# echo -e "\n${YELLOW}重传设置:${NC}"
# sysctl net.ipv4.tcp_retries2

# echo -e "\n${YELLOW}缓冲区设置:${NC}"
# sysctl net.core.rmem_max net.core.wmem_max

# echo -e "\n${YELLOW}连接队列设置:${NC}"
# sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog

# echo -e "\n${YELLOW}TIME_WAIT 设置:${NC}"
# sysctl net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse

# echo -e "\n${YELLOW}慢启动设置:${NC}"
# sysctl net.ipv4.tcp_slow_start_after_idle

# echo -e "\n${GREEN}=== 配置完成 ===${NC}"
# echo -e "配置文件位置: ${CONFIG_FILE}"
# echo -e "这些配置将在系统重启后自动生效"
# echo -e "\n${YELLOW}提示: 如需撤销配置,可删除配置文件:${NC}"
# echo -e "sudo rm ${CONFIG_FILE}"
# echo -e "sudo sysctl -p"


###############################

#!/bin/bash
# TCP 优化配置应用脚本 - PT 上传增强版
# 专注于：大量并发连接 + 连接稳定性 + 上传性能
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/sysctl.d/99-tcp-optimize.conf"
LIMITS_FILE="/etc/security/limits.conf"

# 检查是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
   echo "请使用: sudo $0"
   exit 1
fi

echo -e "${GREEN}=== TCP 优化配置应用脚本 - PT 上传增强版 ===${NC}\n"

# 备份现有配置(如果存在)
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}发现现有配置,备份到: ${BACKUP_FILE}${NC}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

# 写入配置
echo -e "${GREEN}正在写入配置到 ${CONFIG_FILE}...${NC}"
cat > "$CONFIG_FILE" << EOF
# TCP 优化配置 - PT 上传增强版
# 生成时间: $(date)
# 优化目标: 最大化并发连接数 + 连接稳定性

# ==========================================
# 1. TCP Keepalive - 保持长连接存活
# ==========================================
# 空闲 60 秒后开始发送 keepalive 探测包（更积极）
net.ipv4.tcp_keepalive_time = 60
# 探测包间隔 20 秒（更频繁）
net.ipv4.tcp_keepalive_intvl = 20
# 探测次数 6 次才判定连接死亡（更宽容）
net.ipv4.tcp_keepalive_probes = 6

# ==========================================
# 2. 连接稳定性 - 防止断连
# ==========================================
# 增加重传次数到 20 次（原 15），极大提高稳定性
net.ipv4.tcp_retries2 = 20
# SYN 重传次数（建立连接时）
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_synack_retries = 6
# 禁用慢启动（持续上传场景）
net.ipv4.tcp_slow_start_after_idle = 0

# ==========================================
# 3. 大量并发连接支持
# ==========================================
# 增加本地端口范围（支持更多出站连接）
net.ipv4.ip_local_port_range = 10000 65535
# 最大连接跟踪数（适合大量 P2P 连接）
net.netfilter.nf_conntrack_max = 1048576
# 连接跟踪超时时间（秒）
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
# 最大文件句柄数
fs.file-max = 2097152
# SYN 队列长度（接受更多新连接）
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384

# ==========================================
# 4. TCP 缓冲区 - 提升吞吐量
# ==========================================
# 启用窗口缩放
net.ipv4.tcp_window_scaling = 1
# 增加接收/发送缓冲区（32MB 最大）
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
# TCP 读缓冲区：最小 8KB，默认 256KB，最大 32MB
net.ipv4.tcp_rmem = 8192 262144 33554432
# TCP 写缓冲区：最小 8KB，默认 256KB，最大 32MB
net.ipv4.tcp_wmem = 8192 262144 33554432
# TCP 内存管理（单位：页，4KB/页）
# 最小 192MB，压力 256MB，最大 512MB
net.ipv4.tcp_mem = 49152 65536 131072

# ==========================================
# 5. TIME_WAIT 状态优化 - 快速回收端口
# ==========================================
# 缩短 FIN_WAIT 超时（20 秒，更激进）
net.ipv4.tcp_fin_timeout = 20
# 启用 TIME_WAIT 重用（安全）
net.ipv4.tcp_tw_reuse = 1
# 允许更多 TIME_WAIT 套接字
net.ipv4.tcp_max_tw_buckets = 262144

# ==========================================
# 6. 拥塞控制 - 优化上传性能
# ==========================================
# 使用 BBR 拥塞控制（如果内核支持）
# 如果报错可注释掉这两行

# net.core.default_qdisc = fq
# net.ipv4.tcp_congestion_control = bbr

# ==========================================
# 7. 其他优化
# ==========================================
# 启用 TCP Fast Open（减少握手延迟）
net.ipv4.tcp_fastopen = 3
# 启用 TCP 时间戳（提高性能）
net.ipv4.tcp_timestamps = 1
# 启用选择性确认（SACK）
net.ipv4.tcp_sack = 1
# 禁用 MTU 探测（避免某些网络问题）
net.ipv4.tcp_mtu_probing = 0
# 减少 orphan 套接字数量限制
net.ipv4.tcp_max_orphans = 262144
EOF

echo -e "${GREEN}配置文件写入完成!${NC}\n"

# 优化系统文件描述符限制
echo -e "${BLUE}正在优化系统文件描述符限制...${NC}"
if ! grep -q "# PT TCP Optimization" "$LIMITS_FILE"; then
    cat >> "$LIMITS_FILE" << EOF

# PT TCP Optimization - $(date +%Y-%m-%d)
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
EOF
    echo -e "${GREEN}✓ 文件描述符限制已优化${NC}"
else
    echo -e "${YELLOW}文件描述符限制已存在，跳过${NC}"
fi

# 检查并加载 nf_conntrack 模块
echo -e "\n${BLUE}检查连接跟踪模块...${NC}"
if lsmod | grep -q nf_conntrack; then
    echo -e "${GREEN}✓ nf_conntrack 模块已加载${NC}"
else
    echo -e "${YELLOW}正在加载 nf_conntrack 模块...${NC}"
    modprobe nf_conntrack || echo -e "${YELLOW}⚠ 无法加载 nf_conntrack，连接跟踪相关配置可能无效${NC}"
fi

# 应用配置
echo -e "\n${GREEN}正在应用配置...${NC}"
if sysctl -p "$CONFIG_FILE" 2>&1 | grep -v "No such file or directory"; then
    echo -e "${GREEN}✓ 配置应用成功!${NC}\n"
else
    echo -e "${RED}✗ 配置应用失败,请检查错误信息${NC}"
    exit 1
fi

# 显示当前生效的配置
echo -e "${GREEN}=== 当前生效的 TCP 配置（关键项）===${NC}\n"

echo -e "${YELLOW}【连接稳定性】${NC}"
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
sysctl net.ipv4.tcp_retries2 net.ipv4.tcp_slow_start_after_idle

echo -e "\n${YELLOW}【并发连接能力】${NC}"
sysctl net.ipv4.ip_local_port_range
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
sysctl fs.file-max
if sysctl net.netfilter.nf_conntrack_max 2>/dev/null; then
    sysctl net.netfilter.nf_conntrack_tcp_timeout_established
fi

echo -e "\n${YELLOW}【缓冲区设置】${NC}"
sysctl net.core.rmem_max net.core.wmem_max

echo -e "\n${YELLOW}【TIME_WAIT 优化】${NC}"
sysctl net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse net.ipv4.tcp_max_tw_buckets

echo -e "\n${YELLOW}【拥塞控制】${NC}"
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "BBR 不可用（需要内核 4.9+）"

echo -e "\n${GREEN}=== 配置完成 ===${NC}"
echo -e "配置文件位置: ${CONFIG_FILE}"
echo -e "这些配置将在系统重启后自动生效"
echo -e "\n${BLUE}建议操作:${NC}"
echo -e "1. 重启 PT 客户端以应用新配置"
echo -e "2. 监控连接数: ${YELLOW}ss -s${NC} 或 ${YELLOW}netstat -an | grep ESTABLISHED | wc -l${NC}"
echo -e "3. 查看 TIME_WAIT 数: ${YELLOW}ss -ant | grep TIME-WAIT | wc -l${NC}"
echo -e "4. 查看文件描述符: ${YELLOW}ulimit -n${NC} (需重新登录生效)"

echo -e "\n${YELLOW}撤销配置方法:${NC}"
echo -e "sudo rm ${CONFIG_FILE}"
echo -e "sudo sysctl -p"
echo -e "sudo sed -i '/# PT TCP Optimization/,+4d' ${LIMITS_FILE}"

echo -e "\n${GREEN}✓ 优化完成！建议重启系统以确保所有配置生效。${NC}"




