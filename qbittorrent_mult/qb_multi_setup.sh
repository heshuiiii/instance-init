#!/bin/bash

# qBittorrent多开配置脚本
# 使用方法: ./setup_multi_qb.sh [数量]

# 检查参数
if [ $# -ne 1 ]; then
    echo "使用方法: $0 <需要的qBittorrent实例数量>"
    echo "例如: $0 3  # 创建3个实例(heshui1, heshui2, heshui3)"
    exit 1
fi

NUM_INSTANCES=$1

# 检查输入是否为正整数
if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] || [ "$NUM_INSTANCES" -lt 1 ]; then
    echo "错误: 请输入一个正整数"
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

echo "开始创建 $NUM_INSTANCES 个qBittorrent实例..."
echo "基础配置路径: $BASE_CONFIG"
echo ""

# 创建多个实例
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_USER="heshui$i"
    NEW_HOME="/home/$NEW_USER"
    NEW_CONFIG="$NEW_HOME/.config/qBittorrent"
    
    echo "创建实例 $i: $NEW_USER"
    
    # 创建新的用户目录结构
    echo "  - 创建目录: $NEW_HOME"
    sudo mkdir -p "$NEW_HOME"
    
    echo "  - 复制整个home目录"
    sudo cp -r "$BASE_HOME/." "$NEW_HOME/"
    
    # 计算新的端口
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    
    echo "  - 修改配置文件"
    echo "    WebUI端口: $NEW_WEBUI_PORT"
    echo "    连接端口: $NEW_PORT_MIN"
    
    # 修改配置文件中的端口
    CONFIG_FILE="$NEW_CONFIG/qBittorrent.conf"
    
    if [ -f "$CONFIG_FILE" ]; then
        # 使用sed修改端口配置
        sudo sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=$NEW_WEBUI_PORT/" "$CONFIG_FILE"
        sudo sed -i "s/^Connection\\\\PortRangeMin=.*/Connection\\\\PortRangeMin=$NEW_PORT_MIN/" "$CONFIG_FILE"
        
        # 修改下载路径
        sudo sed -i "s|/home/$BASE_USER/|/home/$NEW_USER/|g" "$CONFIG_FILE"
        
        echo "  - 配置文件已更新"
    else
        echo "  - 警告: 配置文件不存在: $CONFIG_FILE"
    fi
    
    # 设置正确的权限
    echo "  - 设置目录权限"
    sudo chown -R "$NEW_USER:$NEW_USER" "$NEW_HOME" 2>/dev/null || {
        echo "    警告: 无法设置用户权限，可能需要先创建用户 $NEW_USER"
        sudo chown -R $(whoami):$(whoami) "$NEW_HOME"
    }
    
    echo "  ✓ 实例 $NEW_USER 创建完成"
    echo ""
done

echo "所有实例创建完成！"
echo ""
echo "端口分配情况:"
echo "原始实例 (heshui): WebUI=8080, 连接=45000"
for i in $(seq 1 $NUM_INSTANCES); do
    NEW_WEBUI_PORT=$((8080 + i))
    NEW_PORT_MIN=$((45000 + i))
    echo "实例 heshui$i: WebUI=$NEW_WEBUI_PORT, 连接=$NEW_PORT_MIN"
done

echo ""
echo "启动方式示例:"
echo "原始实例: systemctl start qbittorrent@heshui"
for i in $(seq 1 $NUM_INSTANCES); do
    echo "实例 $i: systemctl start qbittorrent@heshui$i"
done

echo ""
echo "注意事项:"
echo "1. 确保防火墙允许新的端口"
echo "2. 如果需要系统服务，请为每个用户配置systemd服务"
echo "3. 建议为每个新用户创建系统用户账户"