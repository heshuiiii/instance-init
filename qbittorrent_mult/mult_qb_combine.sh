#!/bin/bash

# qBittorrent多开简化配置脚本
# 使用方法: ./qb_multi_setup.sh [数量]

# 显示帮助信息
show_help() {
    cat << EOF
qBittorrent多开配置脚本

使用方法:
    $0 <实例数量>

参数:
    实例数量        需要创建的qBittorrent实例数量

示例:
    $0 2            # 创建2个实例配置 (heshui1, heshui2)
    $0 3            # 创建3个实例配置 (heshui1, heshui2, heshui3)

EOF
}

# 检查参数
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

NUM_INSTANCES=$1

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

# 检查是否有root权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 需要root权限，请使用sudo运行"
    exit 1
fi

# 检测qbittorrent-nox路径
QB_NOX_PATH=$(which qbittorrent-nox 2>/dev/null)
if [ -z "$QB_NOX_PATH" ]; then
    echo "错误: 未找到qbittorrent-nox可执行文件"
    echo "请确保qBittorrent已正确安装"
    exit 1
fi

echo "========================================="
echo "qBittorrent多开配置"
echo "========================================="
echo "实例数量: $NUM_INSTANCES"
echo "基础配置: $BASE_CONFIG"
echo "qBittorrent路径: $QB_NOX_PATH"
echo ""

# 创建多个实例
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="heshui$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "━━━ 创建实例 $i: $NEW_USER ━━━"
    
    # 创建目录结构
    echo "  📁 创建目录: $NEW_HOME"
    mkdir -p "$NEW_HOME"
    
    echo "  📋 复制配置目录 (排除下载文件)"
    
    # 使用rsync复制，排除Downloads目录
    if command -v rsync >/dev/null 2>&1; then
        echo "     📦 使用rsync复制 (高效模式)"
        rsync -av --exclude='qbittorrent/Downloads/' --exclude='qbittorrent/Downloads' "$BASE_HOME/" "$NEW_HOME/"
        echo "     ✅ rsync复制完成，已排除Downloads目录"
    else
        # 备用方案：先复制所有，然后删除Downloads
        echo "     📦 使用cp复制 (兼容模式)"
        cp -r "$BASE_HOME/." "$NEW_HOME/"
        [ -d "$NEW_HOME/qbittorrent/Downloads" ] && rm -rf "$NEW_HOME/qbittorrent/Downloads"
        echo "     ✅ cp复制完成，已删除Downloads目录"
    fi
    
    # 确保为每个实例创建独立的Downloads目录
    DOWNLOADS_DIR="$NEW_HOME/qbittorrent/Downloads"
    echo "     📁 创建独立下载目录: $DOWNLOADS_DIR"
    mkdir -p "$DOWNLOADS_DIR"
    
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
        sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
        sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_PORT_MIN/" "$CONFIG_FILE"
        sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        echo "     ✅ 配置文件已更新"
    else
        echo "     ⚠️  警告: 配置文件不存在: $CONFIG_FILE"
    fi
    
    # 创建systemd服务文件
    SERVICE_FILE="/etc/systemd/system/qbittorrent-$NEW_USER.service"
    
    echo "  ⚙️  创建服务文件: $SERVICE_FILE"
    echo "     WebUI端口: $NEW_WEBUI_PORT"
    echo "     配置目录: /home/$NEW_USER"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent Daemon for $NEW_USER
After=network.target

[Service]
Type=forking
User=root
Group=root
UMask=0002
ExecStart=$QB_NOX_PATH -d --webui-port=$NEW_WEBUI_PORT --profile=/home/$NEW_USER
TimeoutStopSec=1800

[Install]
WantedBy=multi-user.target
EOF

    echo "  🔄 启用服务"
    systemctl daemon-reload
    systemctl enable "qbittorrent-$NEW_USER"
    
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
echo "🚀 服务管理命令:"
echo "   原始实例: systemctl start qbittorrent@heshui"
for i in $(seq 1 $NUM_INSTANCES); do
    echo "   实例 $i: systemctl start qbittorrent-heshui$i"
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
    echo "   启动 $USER: systemctl start qbittorrent-$USER"
    echo "   停止 $USER: systemctl stop qbittorrent-$USER"
    echo "   状态 $USER: systemctl status qbittorrent-$USER"
    echo ""
done

echo ""
echo "⚠️  注意事项:"
echo "   1. 确保防火墙允许新的端口"
echo "   2. 各实例配置独立，互不干扰"
echo "   3. 每个实例都有独立的下载目录"
echo "   4. 服务以root身份运行，但使用独立的配置目录"
echo "   5. 原始Downloads目录已被排除，节省复制时间"
