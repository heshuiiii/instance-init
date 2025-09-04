#!/bin/bash

# qBittorrent多开简化配置脚本 - 优化版
# 使用方法: ./qb_multi_setup.sh [数量]

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 输出函数
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
need_input() { echo -e "${YELLOW}[INPUT]${NC} $1"; }

# 显示帮助信息
show_help() {
    cat << EOF
qBittorrent多开配置脚本 - 优化版

使用方法:
    $0 <实例数量>

参数:
    实例数量        需要创建的qBittorrent实例数量

示例:
    $0 2            # 创建2个实例配置 (heshui1, heshui2)
    $0 3            # 创建3个实例配置 (heshui1, heshui2, heshui3)

功能:
    - 创建真正的系统用户
    - 独立的配置目录和下载目录
    - 自动端口分配
    - systemd服务配置

EOF
}

# 创建系统用户函数
create_system_user() {
    local username=$1
    local password=${2:-"1wuhongli"}  # 默认密码
    
    info "创建系统用户: $username"
    
    # 检查用户是否已存在
    if id -u "$username" > /dev/null 2>&1; then
        warn "用户 $username 已存在，跳过创建"
        return 0
    fi
    
    # 创建用户
    useradd -m -s /bin/bash "$username"
    if [ $? -ne 0 ]; then
        error "创建用户 $username 失败"
        return 1
    fi
    
    # 设置密码
    echo "$username:$password" | chpasswd
    if [ $? -ne 0 ]; then
        error "设置用户 $username 密码失败"
        return 1
    fi
    
    # 设置目录权限
    chown -R "$username:$username" "/home/$username"
    
    success "用户 $username 创建成功，密码: $password"
    return 0
}

# 检查参数
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

NUM_INSTANCES=$1

# 检查输入是否为正整数
if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -lt 1 ]; then
    error "请输入一个正整数作为实例数量"
    exit 1
fi

# 基础配置路径
BASE_USER="heshui"
BASE_HOME="/home/$BASE_USER"
BASE_CONFIG="$BASE_HOME/.config/qBittorrent"
DEFAULT_PASSWORD="1wuhongli"

# 检查基础配置是否存在
if [ ! -d "$BASE_CONFIG" ]; then
    error "基础配置目录不存在: $BASE_CONFIG"
    error "请先运行原始安装脚本创建基础配置"
    exit 1
fi

# 检查qBittorrent.conf文件是否存在
if [ ! -f "$BASE_CONFIG/qBittorrent.conf" ]; then
    error "配置文件不存在: $BASE_CONFIG/qBittorrent.conf"
    exit 1
fi

# 检查是否有root权限
if [ "$EUID" -ne 0 ]; then
    error "需要root权限，请使用sudo运行"
    exit 1
fi

# 检测qbittorrent-nox路径
QB_NOX_PATH=$(which qbittorrent-nox 2>/dev/null)
if [ -z "$QB_NOX_PATH" ]; then
    error "未找到qbittorrent-nox可执行文件"
    error "请确保qBittorrent已正确安装"
    exit 1
fi

echo "========================================="
echo "qBittorrent多开配置 - 优化版"
echo "========================================="
info "实例数量: $NUM_INSTANCES"
info "基础配置: $BASE_CONFIG"
info "qBittorrent路径: $QB_NOX_PATH"
info "默认密码: $DEFAULT_PASSWORD"
echo ""

# 创建多个实例
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="heshui$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "━━━ 创建实例 $i: $NEW_USER ━━━"
    
    # 创建系统用户
    if ! create_system_user "$NEW_USER" "$DEFAULT_PASSWORD"; then
        error "创建用户 $NEW_USER 失败，跳过此实例"
        continue
    fi
    
    # 创建.config目录结构
    info "创建.config目录: $NEW_HOME/.config"
    sudo -u "$NEW_USER" mkdir -p "$NEW_HOME/.config"
    
    # 复制qBittorrent配置目录
    info "复制qBittorrent配置目录"
    
    if command -v rsync >/dev/null 2>&1; then
        info "使用rsync复制qBittorrent配置"
        rsync -av "$BASE_CONFIG/" "$NEW_CONFIG/"
        chown -R "$NEW_USER:$NEW_USER" "$NEW_CONFIG"
        success "rsync复制完成"
    else
        info "使用cp复制qBittorrent配置"
        cp -r "$BASE_CONFIG" "$NEW_HOME/.config/"
        chown -R "$NEW_USER:$NEW_USER" "$NEW_CONFIG"
        success "cp复制完成"
    fi
    
    # 创建qbittorrent工作目录和Downloads目录
    QB_WORK_DIR="$NEW_HOME/qbittorrent"
    DOWNLOADS_DIR="$QB_WORK_DIR/Downloads"
    info "创建工作目录: $QB_WORK_DIR"
    sudo -u "$NEW_USER" mkdir -p "$QB_WORK_DIR"
    info "创建下载目录: $DOWNLOADS_DIR"
    sudo -u "$NEW_USER" mkdir -p "$DOWNLOADS_DIR"
    
    # 计算新的端口
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    
    info "修改配置文件"
    info "WebUI端口: $NEW_WEBUI_PORT"
    info "连接端口: $NEW_PORT_MIN"
    
    # 修改配置文件中的端口
    CONFIG_FILE="$NEW_CONFIG/qBittorrent.conf"
    
    if [ -f "$CONFIG_FILE" ]; then
        # 使用sed修改端口配置
        sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
        sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_PORT_MIN/" "$CONFIG_FILE"
        sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        success "配置文件已更新"
    else
        warn "配置文件不存在: $CONFIG_FILE"
    fi
    
    # 创建systemd服务文件 - 优化版本
    SERVICE_FILE="/etc/systemd/system/qbittorrent-$NEW_USER.service"
    
    info "创建服务文件: $SERVICE_FILE"
    info "服务用户: $NEW_USER"
    info "WebUI端口: $NEW_WEBUI_PORT"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent Daemon for $NEW_USER
After=network.target

[Service]
Type=forking
User=$NEW_USER
Group=$NEW_USER
UMask=0002
LimitNOFILE=infinity
ExecStart=$QB_NOX_PATH -d --webui-port=$NEW_WEBUI_PORT
ExecStop=/usr/bin/killall -w -s 9 $QB_NOX_PATH
Restart=on-failure
TimeoutStopSec=20
RestartSec=10
WorkingDirectory=$NEW_HOME

[Install]
WantedBy=multi-user.target
EOF

    info "重新加载systemd并启用服务"
    systemctl daemon-reload
    systemctl enable "qbittorrent-$NEW_USER"
    
    success "实例 $NEW_USER 配置完成"
    echo ""
done

echo "========================================="
success "🎉 所有实例创建完成！"
echo "========================================="
echo ""
info "📊 端口分配情况:"
echo "   原始实例 (heshui): WebUI=8080, 连接=45000"
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    echo "   实例 heshui$i: WebUI=$NEW_WEBUI_PORT, 连接=$NEW_PORT_MIN"
done

echo ""
info "👤 用户信息:"
for i in $(seq 1 $NUM_INSTANCES); do
    echo "   用户: heshui$i, 密码: $DEFAULT_PASSWORD"
done

echo ""
info "🚀 服务管理命令:"
echo "   原始实例: systemctl start qbittorrent@heshui"
for i in $(seq 1 $NUM_INSTANCES); do
    echo "   实例 $i:"
    echo "     启动: systemctl start qbittorrent-heshui$i"
    echo "     停止: systemctl stop qbittorrent-heshui$i"
    echo "     状态: systemctl status qbittorrent-heshui$i"
    echo "     日志: journalctl -u qbittorrent-heshui$i -f"
done

# 获取当前主机IP地址
get_host_ip() {
    # 方法1: 优先使用ip命令获取默认路由的IP
    local ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    
    # 方法2: 如果方法1失败，尝试hostname -I
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # 方法3: 如果还是失败，使用ifconfig解析
    if [ -z "$ip" ]; then
        ip=$(ifconfig 2>/dev/null | grep -E 'inet.*broadcast' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    fi
    
    # 如果所有方法都失败，返回localhost
    if [ -z "$ip" ]; then
        ip="localhost"
    fi
    
    echo "$ip"
}

HOST_IP=$(get_host_ip)

echo ""
info "🌐 Web界面访问:"
echo "   原始实例: http://$HOST_IP:8080"
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_WEBUI_PORT=$((8080 + i))
    echo "   实例 $i: http://$HOST_IP:$NEW_WEBUI_PORT"
done

echo ""
info "📋 一键启动所有新实例:"
START_COMMAND="systemctl start"
for i in $(seq 1 $NUM_INSTANCES); do
    START_COMMAND="$START_COMMAND qbittorrent-heshui$i"
done
echo "   $START_COMMAND"

echo ""
warn "⚠️  注意事项:"
echo "   1. 每个实例都创建了真正的系统用户"
echo "   2. 用户默认密码为: $DEFAULT_PASSWORD"
echo "   3. 服务以对应用户身份运行，更加安全"
echo "   4. 确保防火墙允许新的端口"
echo "   5. 各实例配置独立，互不干扰"
echo "   6. 配置目录: /home/heshui[1-$NUM_INSTANCES]/.config/qBittorrent/"
echo "   7. 下载目录: /home/heshui[1-$NUM_INSTANCES]/qbittorrent/Downloads/"
echo "   8. 可以使用SSH登录对应用户进行管理"

echo ""
info "🔧 故障排查:"
echo "   - 查看服务状态: systemctl status qbittorrent-heshui[N]"
echo "   - 查看服务日志: journalctl -u qbittorrent-heshui[N] -f"
echo "   - 重启服务: systemctl restart qbittorrent-heshui[N]"
echo "   - 检查端口占用: netstat -tulpn | grep [端口]"
