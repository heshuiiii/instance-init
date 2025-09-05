#!/bin/bash

# qBittorrent多开简化配置脚本 - 自定义版
# 使用方法: ./qb_multi_setup_custom.sh [数量] [起始端口] [用户名前缀]

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
qBittorrent多开配置脚本 - 自定义版

使用方法:
    $0 <实例数量> [起始端口] [用户名前缀]

参数:
    实例数量        需要创建的qBittorrent实例数量 (必需)
    起始端口        WebUI起始端口，默认8081 (可选)
    用户名前缀      用户名前缀，默认heshui (可选)

示例:
    $0 3                          # 创建3个实例，端口8081-8083，用户heshui1-3
    $0 2 8033                     # 创建2个实例，端口8033-8034，用户heshui1-2
    $0 3 9000 qbuser             # 创建3个实例，端口9000-9002，用户qbuser1-3
    $0 2 8033 heshui123          # 创建2个实例，端口8033-8034，用户heshui1231-1232

交互模式:
    $0                            # 进入交互模式，逐步输入参数

功能:
    - 支持自定义起始端口和用户名前缀
    - 创建真正的系统用户
    - 独立的配置目录和下载目录
    - 自动端口分配（WebUI和连接端口）
    - systemd服务配置

EOF
}

# 验证端口是否可用
check_port() {
    local port=$1
    if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        return 1  # 端口被占用
    fi
    return 0  # 端口可用
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

# 交互式获取参数
interactive_input() {
    echo "========================================="
    echo "qBittorrent多开配置 - 交互模式"
    echo "========================================="
    echo ""
    
    # 获取实例数量
    while true; do
        need_input "请输入要创建的实例数量 (1-20): "
        read -r NUM_INSTANCES
        if [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && [ "$NUM_INSTANCES" -ge 1 ] && [ "$NUM_INSTANCES" -le 20 ]; then
            break
        else
            error "请输入1-20之间的数字"
        fi
    done
    
    # 获取起始端口
    while true; do
        need_input "请输入WebUI起始端口 (1024-65535，默认8081): "
        read -r START_PORT
        if [ -z "$START_PORT" ]; then
            START_PORT=8081
            break
        elif [[ "$START_PORT" =~ ^[0-9]+$ ]] && [ "$START_PORT" -ge 1024 ] && [ "$START_PORT" -le 65535 ]; then
            break
        else
            error "请输入1024-65535之间的端口号"
        fi
    done
    
    # 获取用户名前缀
    while true; do
        need_input "请输入用户名前缀 (默认heshui): "
        read -r USER_PREFIX
        if [ -z "$USER_PREFIX" ]; then
            USER_PREFIX="heshui"
            break
        elif [[ "$USER_PREFIX" =~ ^[a-z][a-z0-9]*$ ]] && [ ${#USER_PREFIX} -le 20 ]; then
            break
        else
            error "用户名前缀只能包含小写字母和数字，以字母开头，长度不超过20字符"
        fi
    done
    
    # 获取基础用户
    while true; do
        need_input "请输入基础配置用户名 (默认heshui): "
        read -r BASE_USER
        if [ -z "$BASE_USER" ]; then
            BASE_USER="heshui"
            break
        elif id -u "$BASE_USER" > /dev/null 2>&1; then
            break
        else
            error "用户 $BASE_USER 不存在，请输入存在的用户名"
        fi
    done
    
    echo ""
    info "配置确认："
    info "实例数量: $NUM_INSTANCES"
    info "起始端口: $START_PORT"
    info "用户前缀: $USER_PREFIX"
    info "基础用户: $BASE_USER"
    echo ""
    
    while true; do
        need_input "确认配置? (y/n): "
        read -r confirm
        case $confirm in
            [Yy]* ) break;;
            [Nn]* ) exit 0;;
            * ) echo "请输入 y 或 n";;
        esac
    done
}

# 主程序开始

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

# 解析参数
if [ $# -eq 0 ]; then
    # 没有参数，进入交互模式
    interactive_input
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
else
    # 命令行参数模式
    NUM_INSTANCES=$1
    START_PORT=${2:-8081}
    USER_PREFIX=${3:-"heshui"}
    BASE_USER=${4:-"heshui"}
    
    # 验证参数
    if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -lt 1 ] || [ "$NUM_INSTANCES" -gt 20 ]; then
        error "实例数量必须是1-20之间的数字"
        exit 1
    fi
    
    if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ] || [ "$START_PORT" -gt 65535 ]; then
        error "端口号必须在1024-65535之间"
        exit 1
    fi
    
    if ! [[ "$USER_PREFIX" =~ ^[a-z][a-z0-9]*$ ]] || [ ${#USER_PREFIX} -gt 20 ]; then
        error "用户名前缀只能包含小写字母和数字，以字母开头，长度不超过20字符"
        exit 1
    fi
fi

# 基础配置路径
BASE_HOME="/home/$BASE_USER"
BASE_CONFIG="$BASE_HOME/.config/qBittorrent"
DEFAULT_PASSWORD="1wuhongli"

# 检查基础用户是否存在
if ! id -u "$BASE_USER" > /dev/null 2>&1; then
    error "基础用户不存在: $BASE_USER"
    error "请先创建基础用户或指定正确的用户名"
    exit 1
fi

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

# 检查端口冲突
info "检查端口占用情况..."
CONFLICT_PORTS=()
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    WEBUI_PORT=$((START_PORT + i))
    CONNECTION_PORT=$((45000 + START_PORT + i))
    
    if ! check_port $WEBUI_PORT; then
        CONFLICT_PORTS+=("WebUI端口 $WEBUI_PORT")
    fi
    
    if ! check_port $CONNECTION_PORT; then
        CONFLICT_PORTS+=("连接端口 $CONNECTION_PORT")
    fi
done

if [ ${#CONFLICT_PORTS[@]} -gt 0 ]; then
    error "发现端口冲突:"
    for port in "${CONFLICT_PORTS[@]}"; do
        echo "   - $port"
    done
    error "请更换起始端口或释放被占用的端口"
    exit 1
fi

echo "========================================="
echo "qBittorrent多开配置 - 自定义版"
echo "========================================="
info "实例数量: $NUM_INSTANCES"
info "起始端口: $START_PORT"
info "用户前缀: $USER_PREFIX"
info "基础用户: $BASE_USER"
info "基础配置: $BASE_CONFIG"
info "qBittorrent路径: $QB_NOX_PATH"
info "默认密码: $DEFAULT_PASSWORD"
echo ""

# 创建多个实例
CREATED_USERS=()
CREATED_SERVICES=()

for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="$USER_PREFIX$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "━━━ 创建实例 $i: $NEW_USER ━━━"
    
    # 创建系统用户
    if ! create_system_user "$NEW_USER" "$DEFAULT_PASSWORD"; then
        error "创建用户 $NEW_USER 失败，跳过此实例"
        continue
    fi
    CREATED_USERS+=("$NEW_USER")
    
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
    NEW_WEBUI_PORT=$((START_PORT + i - 1))
    NEW_CONNECTION_PORT=$((45000 + START_PORT + i - 1))
    
    info "修改配置文件"
    info "WebUI端口: $NEW_WEBUI_PORT"
    info "连接端口: $NEW_CONNECTION_PORT"
    
    # 修改配置文件中的端口
    CONFIG_FILE="$NEW_CONFIG/qBittorrent.conf"
    
    if [ -f "$CONFIG_FILE" ]; then
        # 使用sed修改端口配置
        sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
        sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_CONNECTION_PORT/" "$CONFIG_FILE"
        sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        success "配置文件已更新"
    else
        warn "配置文件不存在: $CONFIG_FILE"
    fi
    
    # 创建systemd服务文件
    SERVICE_FILE="/etc/systemd/system/qbittorrent-$NEW_USER.service"
    SERVICE_NAME="qbittorrent-$NEW_USER"
    
    info "创建服务文件: $SERVICE_FILE"
    info "服务名称: $SERVICE_NAME"
    
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
    systemctl enable "$SERVICE_NAME"
    CREATED_SERVICES+=("$SERVICE_NAME")
    
    success "实例 $NEW_USER 配置完成"
    echo ""
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

echo "========================================="
success "🎉 配置完成！共创建 ${#CREATED_USERS[@]} 个实例"
echo "========================================="
echo ""

if [ ${#CREATED_USERS[@]} -gt 0 ]; then
    info "📊 端口分配情况:"
    for i in $(seq 1 ${#CREATED_USERS[@]}); do
        username="${CREATED_USERS[$((i-1))]}"
        webui_port=$((START_PORT + i - 1))
        conn_port=$((45000 + START_PORT + i - 1))
        echo "   $username: WebUI=$webui_port, 连接=$conn_port"
    done
    
    echo ""
    info "👤 用户信息:"
    for username in "${CREATED_USERS[@]}"; do
        echo "   用户: $username, 密码: $DEFAULT_PASSWORD"
    done
    
    echo ""
    info "🚀 服务管理命令:"
    for service in "${CREATED_SERVICES[@]}"; do
        echo "   $service:"
        echo "     启动: systemctl start $service"
        echo "     停止: systemctl stop $service"
        echo "     状态: systemctl status $service"
        echo "     日志: journalctl -u $service -f"
        echo ""
    done
    
    echo ""
    info "🌐 Web界面访问:"
    for i in $(seq 1 ${#CREATED_USERS[@]}); do
        username="${CREATED_USERS[$((i-1))]}"
        webui_port=$((START_PORT + i - 1))
        echo "   $username: http://$HOST_IP:$webui_port"
    done
    
    echo ""
    info "📋 一键启动所有实例:"
    START_COMMAND="systemctl start $(IFS=' '; echo "${CREATED_SERVICES[*]}")"
    echo "   $START_COMMAND"
    
    echo ""
    info "📋 一键停止所有实例:"
    STOP_COMMAND="systemctl stop $(IFS=' '; echo "${CREATED_SERVICES[*]}")"
    echo "   $STOP_COMMAND"
    
    echo ""
    warn "⚠️  注意事项:"
    echo "   1. 每个实例都创建了真正的系统用户"
    echo "   2. 用户默认密码为: $DEFAULT_PASSWORD"
    echo "   3. 服务以对应用户身份运行，更加安全"
    echo "   4. 确保防火墙允许新的端口范围: $START_PORT-$((START_PORT + NUM_INSTANCES - 1))"
    echo "   5. 各实例配置独立，互不干扰"
    echo "   6. 配置目录: /home/${USER_PREFIX}[1-$NUM_INSTANCES]/.config/qBittorrent/"
    echo "   7. 下载目录: /home/${USER_PREFIX}[1-$NUM_INSTANCES]/qbittorrent/Downloads/"
    echo "   8. 可以使用SSH登录对应用户进行管理"
    
    echo ""
    info "🔧 故障排查:"
    echo "   - 查看所有实例状态: systemctl status qbittorrent-${USER_PREFIX}*"
    echo "   - 查看特定服务状态: systemctl status qbittorrent-${USER_PREFIX}[N]"
    echo "   - 查看特定服务日志: journalctl -u qbittorrent-${USER_PREFIX}[N] -f"
    echo "   - 重启特定服务: systemctl restart qbittorrent-${USER_PREFIX}[N]"
    echo "   - 检查端口占用: netstat -tulpn | grep [端口]"
else
    warn "没有成功创建任何实例"
fi
