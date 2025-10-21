#!/bin/bash

# TCP 优化配置应用脚本
# 适用于 PT 上传等需要稳定长连接的场景

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/etc/sysctl.d/99-tcp-optimize.conf"

# 检查是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
   echo "请使用: sudo $0"
   exit 1
fi

echo -e "${GREEN}=== TCP 优化配置应用脚本 ===${NC}\n"

# 备份现有配置(如果存在)
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}发现现有配置,备份到: ${BACKUP_FILE}${NC}"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

# 写入配置
echo -e "${GREEN}正在写入配置到 ${CONFIG_FILE}...${NC}"
cat > "$CONFIG_FILE" << 'EOF'
# TCP 优化配置 - PT 上传专用
# 生成时间: $(date)

# TCP Keepalive 参数 - 保持连接活跃
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 增加 TCP 重传次数,避免因暂时网络波动断连
net.ipv4.tcp_retries2 = 15

# 启用 TCP 窗口缩放,提升长连接性能
net.ipv4.tcp_window_scaling = 1

# 增加 TCP 缓冲区,适合大量上传连接
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 增加最大连接数
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

# 减少 TIME_WAIT 状态连接数量
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1

# 禁用慢启动,适合持续上传
net.ipv4.tcp_slow_start_after_idle = 0
EOF

echo -e "${GREEN}配置文件写入完成!${NC}\n"

# 应用配置
echo -e "${GREEN}正在应用配置...${NC}"
if sysctl -p "$CONFIG_FILE"; then
    echo -e "${GREEN}✓ 配置应用成功!${NC}\n"
else
    echo -e "${RED}✗ 配置应用失败,请检查错误信息${NC}"
    exit 1
fi

# 显示当前生效的配置
echo -e "${GREEN}=== 当前生效的 TCP 配置 ===${NC}"
echo -e "${YELLOW}Keepalive 设置:${NC}"
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes

echo -e "\n${YELLOW}重传设置:${NC}"
sysctl net.ipv4.tcp_retries2

echo -e "\n${YELLOW}缓冲区设置:${NC}"
sysctl net.core.rmem_max net.core.wmem_max

echo -e "\n${YELLOW}连接队列设置:${NC}"
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog

echo -e "\n${YELLOW}TIME_WAIT 设置:${NC}"
sysctl net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse

echo -e "\n${YELLOW}慢启动设置:${NC}"
sysctl net.ipv4.tcp_slow_start_after_idle

echo -e "\n${GREEN}=== 配置完成 ===${NC}"
echo -e "配置文件位置: ${CONFIG_FILE}"
echo -e "这些配置将在系统重启后自动生效"
echo -e "\n${YELLOW}提示: 如需撤销配置,可删除配置文件:${NC}"
echo -e "sudo rm ${CONFIG_FILE}"
echo -e "sudo sysctl -p"
