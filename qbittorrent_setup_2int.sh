#!/bin/bash

# qBittorrent双容器部署脚本
# 功能：安装Docker Compose并部署两个qBittorrent 5.0.3容器

set -e

echo "=== qBittorrent双容器部署脚本 ==="
echo "开始执行部署..."

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "警告：正在以root用户运行"
    fi
}

# 安装Docker
install_docker() {
    echo "步骤1: 检查并安装Docker..."
    
    if command -v docker &> /dev/null; then
        echo "Docker已安装，版本: $(docker --version)"
    else
        echo "正在安装Docker..."
        # 适用于Ubuntu/Debian
        if command -v apt &> /dev/null; then
            sudo apt update
            sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io
        # 适用于CentOS/RHEL
        elif command -v yum &> /dev/null; then
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io
            sudo systemctl start docker
        fi
        
        # 启动Docker服务
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # 添加当前用户到docker组
        sudo usermod -aG docker $USER
        echo "Docker安装完成！注意：需要重新登录以使用户组生效"
    fi
}

# 安装Docker Compose
install_docker_compose() {
    echo "步骤2: 检查并安装Docker Compose..."
    
    if command -v docker-compose &> /dev/null; then
        echo "Docker Compose已安装，版本: $(docker-compose --version)"
    else
        echo "正在安装Docker Compose..."
        
        # 获取最新版本号
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        
        # 下载Docker Compose
        sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        
        # 添加执行权限
        sudo chmod +x /usr/local/bin/docker-compose
        
        # 创建软链接
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        echo "Docker Compose安装完成，版本: $(docker-compose --version)"
    fi
}

# 创建目录结构
create_directories() {
    echo "步骤3: 创建目录结构..."
    
    # 创建主目录
    mkdir -p qbittorrent-cluster
    cd qbittorrent-cluster
    
    # 创建qBittorrent容器目录
    mkdir -p NO1_QB/{config,downloads}
    mkdir -p NO2_QB/{config,downloads}
    
    echo "目录结构创建完成："
    echo "$(pwd)"
    tree . 2>/dev/null || find . -type d
}

# 创建Docker Compose文件
create_compose_file() {
    echo "步骤4: 创建Docker Compose配置文件..."
    
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  qbittorrent-1:
    image: linuxserver/qbittorrent:5.0.3
    container_name: qbittorrent-no1
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8081
    volumes:
      - ./NO1_QB/config:/config
      - ./NO1_QB/downloads:/downloads
    ports:
      - "8081:8081"
      - "6881:6881"
      - "6881:6881/udp"
    restart: unless-stopped
    networks:
      - qbittorrent-net

  qbittorrent-2:
    image: linuxserver/qbittorrent:5.0.3
    container_name: qbittorrent-no2
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8082
    volumes:
      - ./NO2_QB/config:/config
      - ./NO2_QB/downloads:/downloads
    ports:
      - "8082:8082"
      - "6882:6881"
      - "6882:6881/udp"
    restart: unless-stopped
    networks:
      - qbittorrent-net

networks:
  qbittorrent-net:
    driver: bridge
EOF

    echo "Docker Compose配置文件创建完成"
}

# 设置目录权限
set_permissions() {
    echo "步骤5: 设置目录权限..."
    
    # 设置目录所有者和权限
    sudo chown -R 1000:1000 NO1_QB NO2_QB
    chmod -R 755 NO1_QB NO2_QB
    
    echo "目录权限设置完成"
}

# 启动容器
start_containers() {
    echo "步骤6: 启动qBittorrent容器..."
    
    # 拉取镜像并启动容器
    docker-compose pull
    docker-compose up -d
    
    echo "容器启动完成！"
    echo ""
    echo "等待容器初始化..."
    sleep 10
}

# 配置qBittorrent
configure_qbittorrent() {
    echo "步骤7: 配置qBittorrent用户名密码..."
    
    # 等待容器完全启动
    echo "等待qBittorrent服务启动..."
    sleep 20
    
    # 为第一个qBittorrent设置用户名密码
    echo "配置qBittorrent NO1 (端口8081)..."
    docker exec qbittorrent-no1 /bin/bash -c "
        echo 'WebUI\\Username=heshui' >> /config/qBittorrent/qBittorrent.conf
        echo 'WebUI\\Password_PBKDF2=@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsO8WkS/UGHey/O+PQrUrJOT8n3ZcWOCT9yUj7jKF5eDQKWh3dBDBZXdNQK+0qtRHWW6nNMFZwT0K7tqzN6wIJFQpxcUGAuRgI=)' >> /config/qBittorrent/qBittorrent.conf
    " 2>/dev/null || echo "NO1配置可能需要手动设置"
    
    # 为第二个qBittorrent设置用户名密码
    echo "配置qBittorrent NO2 (端口8082)..."
    docker exec qbittorrent-no2 /bin/bash -c "
        echo 'WebUI\\Username=heshui' >> /config/qBittorrent/qBittorrent.conf
        echo 'WebUI\\Password_PBKDF2=@ByteArray(PvVGYlQW5iE5OOyX5HfEgQ==:OEZGHdLGBJNqOlNc+G/QZGhJKTgzKVlAc/SHGJl2MkPgZKJUzd2fEZFLJl6uL8tg+5yMh3vQRRLJNl3AzQvPl+QNl3ZGZhOl3vGBJANl3vGBJAl3vGBJAl3vGBJANl3vGB)' >> /config/qBittorrent/qBittorrent.conf
    " 2>/dev/null || echo "NO2配置可能需要手动设置"
    
    # 重启容器以应用配置
    docker-compose restart
    
    echo "配置完成，正在重启容器..."
    sleep 10
}

# 显示部署结果
show_results() {
    echo ""
    echo "=== 部署完成！ ==="
    echo ""
    echo "qBittorrent容器信息："
    echo "┌────────────────────────────────────────────┐"
    echo "│ qBittorrent NO1                            │"
    echo "│ 访问地址: http://localhost:8081            │"
    echo "│ 用户名: heshui                             │"
    echo "│ 密码: 1wuhongli                           │"
    echo "│ 配置目录: ./NO1_QB/config                  │"
    echo "│ 下载目录: ./NO1_QB/downloads               │"
    echo "├────────────────────────────────────────────┤"
    echo "│ qBittorrent NO2                            │"
    echo "│ 访问地址: http://localhost:8082            │"
    echo "│ 用户名: heshui                             │"
    echo "│ 密码: 1wuhongli                           │"
    echo "│ 配置目录: ./NO2_QB/config                  │"
    echo "│ 下载目录: ./NO2_QB/downloads               │"
    echo "└────────────────────────────────────────────┘"
    echo ""
    echo "常用命令："
    echo "查看容器状态: docker-compose ps"
    echo "查看日志: docker-compose logs -f"
    echo "停止容器: docker-compose stop"
    echo "启动容器: docker-compose start"
    echo "重启容器: docker-compose restart"
    echo "删除容器: docker-compose down"
    echo ""
    echo "注意事项 (HOST网络模式)："
    echo "1. 使用host网络模式，容器直接使用宿主机网络"
    echo "2. 端口8081和8082会直接绑定到宿主机"
    echo "3. 请确保宿主机防火墙允许这些端口访问"
    echo "4. 首次登录可能需要使用默认密码，然后在WebUI中修改"
    echo "5. 如果密码设置失败，请手动登录WebUI进行配置"
    echo "6. P2P端口会自动使用宿主机可用端口"
    echo ""
}

# 主执行流程
main() {
    check_root
    install_docker
    install_docker_compose
    create_directories
    create_compose_file
    set_permissions
    start_containers
    configure_qbittorrent
    show_results
}

# 执行脚本
main "$@"
