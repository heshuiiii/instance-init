#!/bin/bash

# qBittorrent多开一键配置脚本
# 使用方法: ./qb_multi_setup.sh [数量] [选项]

# 显示帮助信息
show_help() {
    cat << EOF
qBittorrent多开一键配置脚本

使用方法:
    $0 <实例数量> [选项]

参数:
    实例数量        需要创建的qBittorrent实例数量

选项:
    -s, --service   同时创建systemd服务
    -h, --help      显示此帮助信息

示例:
    $0 2            # 仅创建2个实例配置
    $0 3 -s         # 创建3个实例并配置systemd服务
    $0 2 --service  # 创建2个实例并配置systemd服务

EOF
}

# 检查参数
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

NUM_INSTANCES=$1
CREATE_SERVICE=false

# 解析选项
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--service)
            CREATE_SERVICE=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查输入是否为正整数
if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -lt 1 ]; then
    echo "错误: 请输入一个正整数作为实例数量"
    exit 1
fi

# 基础配置路径
BASE_USER="heshui"
BASE_HOME="/home/$BASE_USER"
BASE_CONFIG="$BASE_HOME/.config/qBittorrent"

# 检查基础配置是否存在
if [ ! -d "$BASE_CONFIG" ]; then
    echo "错误: 基础配置目录不存在: $BASE_CONFIG"
    echo "请先运行原始安装脚本创建基础配置"
    exit 1
fi

# 检查qBittorrent.conf文件是否存在
if [ ! -f "$BASE_CONFIG/qBittorrent.conf" ]; then
    echo "错误: 配置文件不存在: $BASE_CONFIG/qBittorrent.conf"
    exit 1
fi

# 检查是否有root权限（如果需要创建服务）
if [ "$CREATE_SERVICE" = true ] && [ "$EUID" -ne 0 ]; then
    echo "错误: 创建系统服务需要root权限，请使用sudo运行"
    exit 1
fi

echo "========================================="
echo "qBittorrent多开一键配置"
echo "========================================="
echo "实例数量: $NUM_INSTANCES"
echo "创建服务: $([ "$CREATE_SERVICE" = true ] && echo "是" || echo "否")"
echo "基础配置: $BASE_CONFIG"
echo ""

# 创建多个实例
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="heshui$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "━━━ 创建实例 $i: $NEW_USER ━━━"
    
    # 创建新的用户目录结构
    echo "  📁 创建目录: $NEW_HOME"
    if [ "$CREATE_SERVICE" = true ]; then
        mkdir -p "$NEW_HOME"
    else
        sudo mkdir -p "$NEW_HOME" 2>/dev/null || mkdir -p "$NEW_HOME"
    fi
    
    echo "  📋 复制配置目录"
    if [ "$CREATE_SERVICE" = true ]; then
        cp -r "$BASE_HOME/." "$NEW_HOME/"
    else
        sudo cp -r "$BASE_HOME/." "$NEW_HOME/" 2>/dev/null || cp -r "$BASE_HOME/." "$NEW_HOME/"
    fi
    
    # 计算新的端口
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    
    echo "  🔧 修改配置文件"
    echo "     WebUI端口: $NEW_WEBUI_PORT"
    echo "     连接端口: $NEW_PORT_MIN"
    
    # 修改配置文件中的端口
    CONFIG_FILE="$NEW_CONFIG/qBittorrent.conf"
    
    if [ -f "$CONFIG_FILE" ]; then
        # 使用sed修改端口配置
        if [ "$CREATE_SERVICE" = true ]; then
            sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
            sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_PORT_MIN/" "$CONFIG_FILE"
            sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        else
            sudo sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE" 2>/dev/null || {
                sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
                sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_PORT_MIN/" "$CONFIG_FILE"
                sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
            }
        fi
        echo "     ✅ 配置文件已更新"
    else
        echo "     ⚠️  警告: 配置文件不存在: $CONFIG_FILE"
    fi
    
    # 如果需要创建服务
    if [ "$CREATE_SERVICE" = true ]; then
        echo "  👤 创建系统用户: $NEW_USER"
        # 创建系统用户（如果不存在）
        if ! id "$NEW_USER" &>/dev/null; then
            useradd -r -s /bin/false -d "$NEW_HOME" "$NEW_USER"
            echo "     ✅ 系统用户创建成功"
        else
            echo "     ℹ️  用户已存在，跳过创建"
        fi
        
        # 设置目录权限
        echo "  🔐 设置目录权限"
        chown -R "$NEW_USER:$NEW_USER" "$NEW_HOME"
        
        # 创建systemd服务文件
        SERVICE_FILE="/etc/systemd/system/qbittorrent@$NEW_USER.service"
        
        echo "  ⚙️  创建服务文件: $SERVICE_FILE"
        
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent Daemon for %i
After=network.target

[Service]
Type=forking
User=%i
Group=%i
UMask=0002
ExecStart=/usr/local/bin/qbittorrent-nox -d --webui-port=$NEW_WEBUI_PORT
TimeoutStopSec=1800

[Install]
WantedBy=multi-user.target
EOF

        echo "  🔄 重新加载systemd配置"
        systemctl daemon-reload
        
        echo "  ✅ 启用服务"
        systemctl enable "qbittorrent@$NEW_USER"
        
    else
        # 设置正确的权限（非服务模式）
        echo "  🔐 设置目录权限"
        if command -v sudo >/dev/null 2>&1; then
            sudo chown -R "$NEW_USER:$NEW_USER" "$NEW_HOME" 2>/dev/null || {
                echo "     ⚠️  警告: 无法设置用户权限，可能需要先创建用户 $NEW_USER"
                sudo chown -R $(whoami):$(whoami) "$NEW_HOME" 2>/dev/null || chown -R $(whoami):$(whoami) "$NEW_HOME"
            }
        else
            echo "     ⚠️  警告: 无sudo权限，使用当前用户权限"
        fi
    fi
    
    echo "  ✅ 实例 $NEW_USER 配置完成"
    echo ""
done

echo "========================================="
echo "🎉 所有实例创建完成！"
echo "========================================="
echo ""
echo "📊 端口分配情况:"
echo "   原始实例 (heshui): WebUI=8080, 连接=45000"
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    echo "   实例 heshui$i: WebUI=$NEW_WEBUI_PORT, 连接=$NEW_PORT_MIN"
done

echo ""
if [ "$CREATE_SERVICE" = true ]; then
    echo "🚀 服务管理命令:"
    echo "   原始实例: systemctl start qbittorrent@heshui"
    for i in $(seq 1 $NUM_INSTANCES); do
        echo "   实例 $i: systemctl start qbittorrent@heshui$i"
    done
    
    echo ""
    echo "🌐 Web界面访问:"
    echo "   原始实例: http://your-server-ip:8080"
    for i in $(seq 1 $NUM_INSTANCES); do
        NEW_WEBUI_PORT=$((8080 + i))
        echo "   实例 $i: http://your-server-ip:$NEW_WEBUI_PORT"
    done
    
    echo ""
    echo "📋 管理命令示例:"
    for i in $(seq 1 $NUM_INSTANCES); do
        USER="heshui$i"
        echo "   启动 $USER: systemctl start qbittorrent@$USER"
        echo "   停止 $USER: systemctl stop qbittorrent@$USER"
        echo "   状态 $USER: systemctl status qbittorrent@$USER"
        echo ""
    done
else
    echo "🚀 手动启动命令:"
    echo "   原始实例: qbittorrent-nox -d --webui-port=8080"
    for i in $(seq 1 $NUM_INSTANCES); do
        NEW_WEBUI_PORT=$((8080 + i))
        echo "   实例 $i: sudo -u heshui$i qbittorrent-nox -d --webui-port=$NEW_WEBUI_PORT"
    done
    
    echo ""
    echo "💡 提示: 使用 -s 或 --service 选项可以自动创建systemd服务"
fi

echo ""
echo "⚠️  注意事项:"
echo "   1. 确保防火墙允许新的端口"
echo "   2. 各实例配置独立，互不干扰"
echo "   3. 每个实例都有独立的下载目录"
if [ "$CREATE_SERVICE" = false ]; then
    echo "   4. 建议创建对应的系统用户以提高安全性"
fi
