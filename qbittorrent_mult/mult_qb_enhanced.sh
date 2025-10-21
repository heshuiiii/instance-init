#!/bin/bash
# qBittorrent多开简化配置脚本 - 支持版本判断
# 动态读取端口配置并递增
# 4.3+版本使用 Connection\PortRangeMin
# 4.3以下版本使用 Session\Port

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 输出函数
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
need_input() { echo -e "${YELLOW}[INPUT]${NC} $1"; }

# 显示帮助信息
show_help() {
    cat << EOF
qBittorrent多开配置脚本 - 支持版本判断

使用方法:
    $0 <实例数量> [起始端口] [用户名前缀]

参数:
    实例数量        需要创建的qBittorrent实例数量 (必需)
    起始端口        WebUI起始端口，默认8081 (可选)
    用户名前缀      用户名前缀，默认heshui (可选)

示例:
    $0 3                          # 创建3个实例
    $0 2 8033                     # 创建2个实例，端口8033-8034
    $0 3 9000 qbuser             # 创建3个实例

交互模式:
    $0                            # 进入交互模式

功能:
    - 支持qBittorrent 4.3+和4.3以下版本
    - 4.3+使用Connection\PortRangeMin，4.3以下使用Session\Port
    - 创建真正的系统用户
    - 独立的配置目录和下载目录
    - 自动端口分配（WebUI、Connection、Session三组端口）
    - systemd服务配置

EOF
}

# 版本比较函数
version_ge() {
    # 比较版本号是否 >= 4.3
    local version=$1
    local major minor
    
    # 提取主版本号和次版本号
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    
    if [ "$major" -gt 4 ]; then
        return 0
    elif [ "$major" -eq 4 ] && [ "$minor" -ge 3 ]; then
        return 0
    else
        return 1
    fi
}

# 验证端口是否可用
check_port() {
    local port=$1
    local is_base_port=$2
    
    if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        if [ "$is_base_port" = "1" ]; then
            return 0
        fi
        return 1
    fi
    return 0
}

# 根据版本读取基础配置中的端口
read_base_port() {
    local config_file=$1
    local qb_version=$2
    local port
    local port_key
    
    if version_ge "$qb_version"; then
        # 4.3+ 版本使用 Connection\PortRangeMin
        port_key="Connection\\\\PortRangeMin"
        port=$(grep "^Connection\\\\PortRangeMin=" "$config_file" | sed 's/Connection\\PortRangeMin=//')
        if [ -z "$port" ]; then
            warn "未找到 Connection\\PortRangeMin 配置，使用默认值 23335"
            echo "23335"
        else
            echo "$port"
        fi
    else
        # 4.3以下版本使用 Session\Port
        port_key="Session\\\\Port"
        port=$(grep "^Session\\\\Port=" "$config_file" | sed 's/Session\\Port=//')
        if [ -z "$port" ]; then
            warn "未找到 Session\\Port 配置，使用默认值 60244"
            echo "60244"
        else
            echo "$port"
        fi
    fi
}

# 创建系统用户函数
create_system_user() {
    local username=$1
    local password=${2:-"1wuhongli"}
    
    info "创建系统用户: $username"
    
    if id -u "$username" > /dev/null 2>&1; then
        warn "用户 $username 已存在，跳过创建"
        return 0
    fi
    
    useradd -m -s /bin/bash "$username"
    if [ $? -ne 0 ]; then
        error "创建用户 $username 失败"
        return 1
    fi
    
    echo "$username:$password" | chpasswd
    if [ $? -ne 0 ]; then
        error "设置用户 $username 密码失败"
        return 1
    fi
    
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
    
    # 询问版本号
    while true; do
        need_input "请输入qBittorrent版本号 (如: 4.3.9, 4.2.5): "
        read -r QB_VERSION
        if [[ "$QB_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            if version_ge "$QB_VERSION"; then
                info "检测到版本 $QB_VERSION >= 4.3，将使用 Connection\\PortRangeMin"
            else
                info "检测到版本 $QB_VERSION < 4.3，将使用 Session\\Port"
            fi
            break
        else
            error "请输入有效的版本号格式 (如: 4.3.9)"
        fi
    done
    
    while true; do
        need_input "请输入要创建的实例数量 (1-20): "
        read -r NUM_INSTANCES
        if [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && [ "$NUM_INSTANCES" -ge 1 ] && [ "$NUM_INSTANCES" -le 20 ]; then
            break
        else
            error "请输入1-20之间的数字"
        fi
    done
    
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
    info "qBittorrent版本: $QB_VERSION"
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

if [ "$EUID" -ne 0 ]; then
    error "需要root权限，请使用sudo运行"
    exit 1
fi

QB_NOX_PATH=$(which qbittorrent-nox 2>/dev/null)
if [ -z "$QB_NOX_PATH" ]; then
    error "未找到qbittorrent-nox可执行文件"
    exit 1
fi

if [ $# -eq 0 ]; then
    interactive_input
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
else
    # 命令行模式也需要询问版本
    echo "========================================="
    echo "qBittorrent多开配置"
    echo "========================================="
    while true; do
        need_input "请输入qBittorrent版本号 (如: 4.3.9, 4.2.5): "
        read -r QB_VERSION
        if [[ "$QB_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            if version_ge "$QB_VERSION"; then
                info "检测到版本 $QB_VERSION >= 4.3，将使用 Connection\\PortRangeMin"
            else
                info "检测到版本 $QB_VERSION < 4.3，将使用 Session\\Port"
            fi
            break
        else
            error "请输入有效的版本号格式 (如: 4.3.9)"
        fi
    done
    echo ""
    
    NUM_INSTANCES=$1
    START_PORT=${2:-8081}
    USER_PREFIX=${3:-"heshui"}
    BASE_USER=${4:-"heshui"}
    
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

BASE_HOME="/home/$BASE_USER"
BASE_CONFIG="$BASE_HOME/.config/qBittorrent"
DEFAULT_PASSWORD="1wuhongli"

if ! id -u "$BASE_USER" > /dev/null 2>&1; then
    error "基础用户不存在: $BASE_USER"
    exit 1
fi

if [ ! -d "$BASE_CONFIG" ]; then
    error "基础配置目录不存在: $BASE_CONFIG"
    exit 1
fi

BASE_CONFIG_FILE="$BASE_CONFIG/qBittorrent.conf"
if [ ! -f "$BASE_CONFIG_FILE" ]; then
    error "配置文件不存在: $BASE_CONFIG_FILE"
    exit 1
fi

BASE_PORT=$(read_base_port "$BASE_CONFIG_FILE" "$QB_VERSION")
if version_ge "$QB_VERSION"; then
    PORT_KEY_NAME="Connection\\PortRangeMin"
    info "读取到基础 Connection\\PortRangeMin: $BASE_PORT"
else
    PORT_KEY_NAME="Session\\Port"
    info "读取到基础 Session\\Port: $BASE_PORT"
fi

# 检查端口冲突
info "检查端口占用情况..."
CONFLICT_PORTS=()
for i in $(seq 1 $NUM_INSTANCES); do
    WEBUI_PORT=$((START_PORT + i - 1))
    CONNECTION_PORT=$((45000 + START_PORT + i - 1))
    SESSION_PORT=$((BASE_PORT + i * 2))
    
    if ! check_port $WEBUI_PORT "0"; then
        CONFLICT_PORTS+=("WebUI端口 $WEBUI_PORT")
    fi
    
    if ! check_port $CONNECTION_PORT "0"; then
        CONFLICT_PORTS+=("连接端口 $CONNECTION_PORT")
    fi
    
    if ! check_port $SESSION_PORT "0"; then
        CONFLICT_PORTS+=("${PORT_KEY_NAME}端口 $SESSION_PORT")
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
echo "qBittorrent多开配置"
echo "========================================="
info "qBittorrent版本: $QB_VERSION"
info "端口配置键: $PORT_KEY_NAME"
info "实例数量: $NUM_INSTANCES"
info "起始端口: $START_PORT"
info "用户前缀: $USER_PREFIX"
info "基础用户: $BASE_USER"
info "基础配置: $BASE_CONFIG"
info "基础端口: $BASE_PORT"
info "qBittorrent路径: $QB_NOX_PATH"
info "默认密码: $DEFAULT_PASSWORD"
echo ""

CREATED_USERS=()
CREATED_SERVICES=()
PORT_ASSIGNMENTS=()

for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="$USER_PREFIX$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "━━━ 创建实例 $i: $NEW_USER ━━━"
    
    if ! create_system_user "$NEW_USER" "$DEFAULT_PASSWORD"; then
        error "创建用户 $NEW_USER 失败，跳过此实例"
        continue
    fi
    CREATED_USERS+=("$NEW_USER")
    
    info "创建.config目录: $NEW_HOME/.config"
    sudo -u "$NEW_USER" mkdir -p "$NEW_HOME/.config"
    
    info "复制qBittorrent配置目录"
    if command -v rsync >/dev/null 2>&1; then
        info "使用rsync复制"
        rsync -av "$BASE_CONFIG/" "$NEW_CONFIG/"
        chown -R "$NEW_USER:$NEW_USER" "$NEW_CONFIG"
        success "rsync复制完成"
    else
        info "使用cp复制"
        cp -r "$BASE_CONFIG" "$NEW_HOME/.config/"
        chown -R "$NEW_USER:$NEW_USER" "$NEW_CONFIG"
        success "cp复制完成"
    fi
    
    QB_WORK_DIR="$NEW_HOME/qbittorrent"
    DOWNLOADS_DIR="$QB_WORK_DIR/Downloads"
    info "创建工作目录: $QB_WORK_DIR"
    sudo -u "$NEW_USER" mkdir -p "$QB_WORK_DIR"
    info "创建下载目录: $DOWNLOADS_DIR"
    sudo -u "$NEW_USER" mkdir -p "$DOWNLOADS_DIR"
    
    NEW_WEBUI_PORT=$((START_PORT + i - 1))
    NEW_CONNECTION_PORT=$((45000 + START_PORT + i - 1))
    NEW_SESSION_PORT=$((BASE_PORT + i * 2))
    
    info "端口配置:"
    info "  WebUI端口: $NEW_WEBUI_PORT"
    info "  连接端口: $NEW_CONNECTION_PORT"
    info "  ${PORT_KEY_NAME}: $NEW_SESSION_PORT (基础$BASE_PORT + $i*2)"
    
    PORT_ASSIGNMENTS+=("$NEW_USER|$NEW_WEBUI_PORT|$NEW_CONNECTION_PORT|$NEW_SESSION_PORT")
    
    CONFIG_FILE="$NEW_CONFIG/qBittorrent.conf"
    
    if [ -f "$CONFIG_FILE" ]; then
        info "修改配置文件"
        
        sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
        
        # 根据版本修改不同的配置项
        if version_ge "$QB_VERSION"; then
            # 4.3+ 版本修改 Connection\PortRangeMin
            sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_SESSION_PORT/" "$CONFIG_FILE"
        else
            # 4.3以下版本修改 Session\Port
            sed -i "s/^Session\\\\Port=.*/Session\\\\Port=$NEW_SESSION_PORT/" "$CONFIG_FILE"
        fi
        
        sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        
        success "配置文件已更新"
        
        # 验证配置
        if version_ge "$QB_VERSION"; then
            VERIFY_PORT=$(grep "^Connection\\\\PortRangeMin=" "$CONFIG_FILE" | sed 's/Connection\\PortRangeMin=//')
        else
            VERIFY_PORT=$(grep "^Session\\\\Port=" "$CONFIG_FILE" | sed 's/Session\\Port=//')
        fi
        VERIFY_WEBUI=$(grep "^WebUI\\\\Port=" "$CONFIG_FILE" | sed 's/WebUI\\Port=//')
        
        if [ "$VERIFY_PORT" = "$NEW_SESSION_PORT" ] && [ "$VERIFY_WEBUI" = "$NEW_WEBUI_PORT" ]; then
            success "端口配置验证通过"
        else
            warn "端口配置可能存在问题"
        fi
    fi
    
    SERVICE_FILE="/etc/systemd/system/qbittorrent-$NEW_USER.service"
    SERVICE_NAME="qbittorrent-$NEW_USER"
    
    info "创建服务文件: $SERVICE_FILE"
    
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

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    CREATED_SERVICES+=("$SERVICE_NAME")
    
    success "实例 $NEW_USER 配置完成"
    echo ""
done

get_host_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ]; then
        ip=$(ifconfig 2>/dev/null | grep -E 'inet.*broadcast' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    fi
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
    info "📊 完整端口分配情况:"
    echo ""
    printf "   %-15s %-10s %-10s %-10s\n" "用户名" "WebUI" "连接端口" "$PORT_KEY_NAME"
    echo "   ───────────────────────────────────────────────────"
    for assignment in "${PORT_ASSIGNMENTS[@]}"; do
        IFS='|' read -r username webui conn session <<< "$assignment"
        printf "   %-15s %-10s %-10s %-10s\n" "$username" "$webui" "$conn" "$session"
    done
    
    echo ""
    info "📋 端口递增规则 ($PORT_KEY_NAME):"
    echo "   基础用户 ($BASE_USER): $BASE_PORT"
    for i in $(seq 1 $NUM_INSTANCES); do
        NEW_SESSION_PORT=$((BASE_PORT + i * 2))
        echo "   实例 $i: $NEW_SESSION_PORT (基础$BASE_PORT + $i*2)"
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
        echo ""
    done
    
    echo ""
    info "🌐 Web界面访问:"
    for assignment in "${PORT_ASSIGNMENTS[@]}"; do
        IFS='|' read -r username webui conn session <<< "$assignment"
        echo "   $username: http://$HOST_IP:$webui"
    done
    
    echo ""
    info "🎯 一键管理命令:"
    echo ""
    echo "   启动所有实例:"
    if [ ${#CREATED_SERVICES[@]} -gt 0 ]; then
        START_CMD="systemctl start"
        for service in "${CREATED_SERVICES[@]}"; do
            START_CMD="$START_CMD $service"
        done
        echo "   $START_CMD"
    fi
    
    echo ""
    echo "   停止所有实例:"
    if [ ${#CREATED_SERVICES[@]} -gt 0 ]; then
        STOP_CMD="systemctl stop"
        for service in "${CREATED_SERVICES[@]}"; do
            STOP_CMD="$STOP_CMD $service"
        done
        echo "   $STOP_CMD"
    fi
    
    echo ""
    echo "   重启所有实例:"
    if [ ${#CREATED_SERVICES[@]} -gt 0 ]; then
        RESTART_CMD="systemctl restart"
        for service in "${CREATED_SERVICES[@]}"; do
            RESTART_CMD="$RESTART_CMD $service"
        done
        echo "   $RESTART_CMD"
    fi
    
    echo ""
    echo "   查看所有实例状态:"
    if [ ${#CREATED_SERVICES[@]} -gt 0 ]; then
        STATUS_CMD="systemctl status"
        for service in "${CREATED_SERVICES[@]}"; do
            STATUS_CMD="$STATUS_CMD $service"
        done
        echo "   $STATUS_CMD"
    fi
fi
