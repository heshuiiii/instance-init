#!/bin/bash

# qBittorrent多开服务配置脚本
# 创建系统用户和systemd服务

if [ $# -ne 1 ]; then
    echo "使用方法: $0 <实例数量>"
    exit 1
fi

NUM_INSTANCES=$1

echo "配置qBittorrent多开服务..."

# 创建系统用户和服务
for i in $(seq 1 $NUM_INSTANCES); do
    USER="heshui$i"
    
    echo "配置用户和服务: $USER"
    
    # 创建系统用户（如果不存在）
    if ! id "$USER" &>/dev/null; then
        echo "  - 创建系统用户: $USER"
        sudo useradd -r -s /bin/false -d "/home/$USER" "$USER"
    fi
    
    # 设置目录权限
    sudo chown -R "$USER:$USER" "/home/$USER"
    
    # 创建systemd服务文件
    SERVICE_FILE="/etc/systemd/system/qbittorrent@$USER.service"
    
    echo "  - 创建服务文件: $SERVICE_FILE"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=qBittorrent Daemon for %i
After=network.target

[Service]
Type=forking
User=%i
Group=%i
UMask=0002
ExecStart=/usr/local/bin/qbittorrent-nox -d --webui-port=$((8080 + i))
TimeoutStopSec=1800

[Install]
WantedBy=multi-user.target
EOF

    echo "  - 重新加载systemd配置"
    sudo systemctl daemon-reload
    
    echo "  - 启用服务"
    sudo systemctl enable "qbittorrent@$USER"
    
    echo "  ✓ $USER 服务配置完成"
    echo ""
done

echo "所有服务配置完成！"
echo ""
echo "管理命令:"
for i in $(seq 1 $NUM_INSTANCES); do
    USER="heshui$i"
    PORT=$((8080 + i))
    echo "启动 $USER: sudo systemctl start qbittorrent@$USER"
    echo "停止 $USER: sudo systemctl stop qbittorrent@$USER"
    echo "查看状态: sudo systemctl status qbittorrent@$USER"
    echo "Web界面: http://your-server-ip:$PORT"
    echo ""
done