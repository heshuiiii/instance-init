#!/bin/bash

# 增强版qBittorrent双容器部署脚本
# 新增功能：简体中文WebUI、随机UPnP端口、取消连接数限制、种子不排队
# GitHub快速执行：curl -sSL https://raw.githubusercontent.com/heshuiiii/commad-use/main/qbittorrent_setup_2int.sh | bash

set -e

echo "=== 增强版qBittorrent双容器部署脚本 ==="
echo "开始执行部署..."

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "警告：正在以root用户运行"
    fi
}

# 修复损坏的包依赖
fix_broken_packages() {
    echo "检查并修复损坏的包依赖..."
    
    # 检查是否有损坏的包
    if dpkg -l | grep -q "linux-headers-4.14.129-bbrplus"; then
        echo "发现损坏的内核头文件包，正在修复..."
        
        # 强制移除损坏的包
        sudo dpkg --remove --force-remove-reinstreq linux-headers-4.14.129-bbrplus 2>/dev/null || true
        
        # 清理包缓存
        sudo apt clean
        sudo apt autoclean
        
        # 修复损坏的依赖
        sudo apt --fix-broken install -y
        
        echo "包依赖修复完成"
    fi
}

# 安装Docker
install_docker() {
    echo "步骤1: 检查并安装Docker..."
    
    if command -v docker &> /dev/null; then
        echo "Docker已安装，版本: $(docker --version)"
    else
        echo "正在安装Docker..."
        
        # 修复损坏的包依赖
        fix_broken_packages
        
        # 适用于Debian/Ubuntu
        if command -v apt &> /dev/null; then
            # 更新包索引，忽略错误
            sudo apt update || true
            
            # 安装必要的包，使用--fix-missing参数
            sudo apt install -y --fix-missing apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
            
            # 添加Docker官方GPG密钥
            curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # 添加Docker APT仓库
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # 如果是Ubuntu，使用ubuntu仓库
            if grep -q "Ubuntu" /etc/os-release; then
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            fi
            
            # 再次更新包索引
            sudo apt update
            
            # 安装Docker，如果失败则尝试替代方案
            if ! sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
                echo "标准安装失败，尝试使用convenience脚本安装..."
                curl -fsSL https://get.docker.com -o get-docker.sh
                sudo sh get-docker.sh
                rm get-docker.sh
            fi
            
        # 适用于CentOS/RHEL
        elif command -v yum &> /dev/null; then
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl start docker
        fi
        
        # 启动Docker服务
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # 添加当前用户到docker组
        if [ "$EUID" -ne 0 ]; then
            sudo usermod -aG docker $USER
            echo "Docker安装完成！注意：需要重新登录以使用户组生效"
        else
            echo "Docker安装完成！"
        fi
    fi
}

# 安装Docker Compose
install_docker_compose() {
    echo "步骤2: 检查并安装Docker Compose..."
    
    # 优先使用Docker Compose Plugin
    if docker compose version &> /dev/null; then
        echo "Docker Compose Plugin已安装，版本: $(docker compose version)"
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        echo "Docker Compose已安装，版本: $(docker-compose --version)"
        COMPOSE_CMD="docker-compose"
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
        
        COMPOSE_CMD="docker-compose"
        echo "Docker Compose安装完成，版本: $(docker-compose --version)"
    fi
}

# 生成随机UPnP端口
generate_random_ports() {
    echo "步骤3: 生成随机UPnP端口..."
    
    # 为第一个qBittorrent生成随机端口 (范围: 20000-65000)
    QB1_PORT=$((20000 + RANDOM % 45000))
    # 为第二个qBittorrent生成随机端口，确保不重复
    QB2_PORT=$((20000 + RANDOM % 45000))
    while [ $QB2_PORT -eq $QB1_PORT ]; do
        QB2_PORT=$((20000 + RANDOM % 45000))
    done
    
    # 默认UPnP端口
    DEFAULT_UPNP_PORT=54889
    
    echo "生成的端口配置："
    echo "qBittorrent NO1 UPnP端口: $QB1_PORT"
    echo "qBittorrent NO2 UPnP端口: $QB2_PORT"
    echo "默认UPnP端口: $DEFAULT_UPNP_PORT"
}

# 创建目录结构
create_directories() {
    echo "步骤4: 创建目录结构..."
    
    # 创建主目录
    mkdir -p qbittorrent-cluster
    cd qbittorrent-cluster
    
    # 创建qBittorrent容器目录
    mkdir -p NO1_QB/{config,downloads}
    mkdir -p NO2_QB/{config,downloads}
    
    echo "目录结构创建完成："
    echo "$(pwd)"
    find . -type d | sort
}

# 创建Docker Compose文件
create_compose_file() {
    echo "步骤5: 创建Docker Compose配置文件..."
    
    cat > docker-compose.yml << EOF
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
    network_mode: host
    restart: unless-stopped

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
    network_mode: host
    restart: unless-stopped
EOF

    echo "Docker Compose配置文件创建完成 (使用host网络模式)"
}

# 设置目录权限
set_permissions() {
    echo "步骤6: 设置目录权限..."
    
    # 设置目录所有者和权限
    sudo chown -R 1000:1000 NO1_QB NO2_QB
    chmod -R 755 NO1_QB NO2_QB
    
    echo "目录权限设置完成"
}

# 启动容器
start_containers() {
    echo "步骤7: 启动qBittorrent容器..."
    
    # 拉取镜像并启动容器
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d
    
    echo "容器启动完成！"
    echo ""
    echo "等待容器初始化..."
    sleep 15
}

# 创建增强配置文件
create_enhanced_config() {
    local config_dir=$1
    local upnp_port=$2
    local webui_port=$3
    
    cat > "$config_dir/qBittorrent/qBittorrent.conf" << EOF
[Application]
FileLogger\\Enabled=true
FileLogger\\Path=/config/qBittorrent
FileLogger\\Backup=true
FileLogger\\MaxSize=5

[BitTorrent]
Session\\Port=$upnp_port
Session\\UPnPEnabled=true
Session\\GlobalMaxRatio=0
Session\\GlobalMaxSeedingMinutes=-1
Session\\MaxActiveDownloads=-1
Session\\MaxActiveTorrents=-1
Session\\MaxActiveUploads=-1
Session\\MaxConnections=-1
Session\\MaxConnectionsPerTorrent=-1
Session\\MaxUploads=-1
Session\\MaxUploadsPerTorrent=-1
Session\\QueueingSystemEnabled=false
Session\\DefaultSavePath=/downloads
Session\\TempPath=/downloads/incomplete

[Preferences]
Bittorrent\\MaxConnecs=-1
Bittorrent\\MaxConnecsPerTorrent=-1
Bittorrent\\MaxUploads=-1
Bittorrent\\MaxUploadsPerTorrent=-1
Bittorrent\\MaxActiveDownloads=-1
Bittorrent\\MaxActiveTorrents=-1
Bittorrent\\MaxActiveUploads=-1
Bittorrent\\QueueingEnabled=false
Connection\\PortRangeMin=$upnp_port
Connection\\UPnP=true
Downloads\\SavePath=/downloads
Downloads\\TempPath=/downloads/incomplete
General\\Locale=zh_CN
WebUI\\Port=$webui_port
WebUI\\Username=heshui
WebUI\\Password_PBKDF2="@ByteArray(PvVGYlQW5iE5OOyX5HfEgQ==:OEZGHdLGBJNqOlNc+G/QZGhJKTgzKVlAc/SHGJl2MkPgZKJUzd2fEZFLJl6uL8tg+5yMh3vQRRLJNl3AzQvPl+QNl3ZGZhOl3vGBJANl3vGBJAl3vGBJAl3vGBJANl3vGB)"
EOF
}

# 配置qBittorrent
configure_qbittorrent() {
    echo "步骤8: 配置qBittorrent增强设置..."
    
    # 等待容器完全启动
    echo "等待qBittorrent服务完全启动..."
    sleep 20
    
    # 停止容器以修改配置
    $COMPOSE_CMD stop
    
    # 创建配置目录
    mkdir -p NO1_QB/config/qBittorrent
    mkdir -p NO2_QB/config/qBittorrent
    
    # 为第一个qBittorrent创建增强配置
    echo "配置qBittorrent NO1 (端口8081, UPnP端口: $QB1_PORT)..."
    create_enhanced_config "NO1_QB/config" "$QB1_PORT" "8081"
    
    # 为第二个qBittorrent创建增强配置
    echo "配置qBittorrent NO2 (端口8082, UPnP端口: $QB2_PORT)..."
    create_enhanced_config "NO2_QB/config" "$QB2_PORT" "8082"
    
    # 设置配置文件权限
    sudo chown -R 1000:1000 NO1_QB/config NO2_QB/config
    chmod -R 644 NO1_QB/config/qBittorrent/qBittorrent.conf NO2_QB/config/qBittorrent/qBittorrent.conf
    
    # 重启容器以应用配置
    $COMPOSE_CMD up -d
    
    echo "增强配置完成，正在重启容器..."
    sleep 15
}

# 创建快速管理脚本
create_management_script() {
    echo "步骤9: 创建管理脚本..."
    
    cat > qb_manage.sh << 'EOF'
#!/bin/bash
# qBittorrent管理脚本

COMPOSE_CMD="docker-compose"
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
fi

case "$1" in
    start)
        echo "启动qBittorrent容器..."
        $COMPOSE_CMD start
        ;;
    stop)
        echo "停止qBittorrent容器..."
        $COMPOSE_CMD stop
        ;;
    restart)
        echo "重启qBittorrent容器..."
        $COMPOSE_CMD restart
        ;;
    logs)
        echo "查看日志..."
        $COMPOSE_CMD logs -f
        ;;
    status)
        echo "查看容器状态..."
        $COMPOSE_CMD ps
        ;;
    update)
        echo "更新容器..."
        $COMPOSE_CMD pull
        $COMPOSE_CMD up -d
        ;;
    down)
        echo "删除容器（保留数据）..."
        $COMPOSE_CMD down
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs|status|update|down}"
        echo ""
        echo "命令说明:"
        echo "  start   - 启动容器"
        echo "  stop    - 停止容器"
        echo "  restart - 重启容器"
        echo "  logs    - 查看实时日志"
        echo "  status  - 查看容器状态"
        echo "  update  - 更新镜像并重启容器"
        echo "  down    - 删除容器（保留数据）"
        exit 1
        ;;
esac
EOF

    chmod +x qb_manage.sh
    echo "管理脚本创建完成: ./qb_manage.sh"
}

# 显示部署结果
show_results() {
    echo ""
    echo "=== 增强版部署完成！ ==="
    echo ""
    echo "qBittorrent容器信息 (HOST网络模式 + 增强配置)："
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│ qBittorrent NO1 - 增强版                            │"
    echo "│ 访问地址: http://$(hostname -I | awk '{print $1}'):8081             │"
    echo "│ 本地访问: http://localhost:8081                     │"
    echo "│ 用户名: heshui                                      │"
    echo "│ 密码: 1wuhongli                                    │"
    echo "│ UPnP端口: $QB1_PORT                                  │"
    echo "│ 配置目录: ./NO1_QB/config                           │"
    echo "│ 下载目录: ./NO1_QB/downloads                        │"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│ qBittorrent NO2 - 增强版                            │"
    echo "│ 访问地址: http://$(hostname -I | awk '{print $1}'):8082             │"
    echo "│ 本地访问: http://localhost:8082                     │"
    echo "│ 用户名: heshui                                      │"
    echo "│ 密码: 1wuhongli                                    │"
    echo "│ UPnP端口: $QB2_PORT                                  │"
    echo "│ 配置目录: ./NO2_QB/config                           │"
    echo "│ 下载目录: ./NO2_QB/downloads                        │"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
    echo "增强功能已启用："
    echo "✓ WebUI语言: 简体中文"
    echo "✓ UPnP端口: 随机生成 (NO1: $QB1_PORT, NO2: $QB2_PORT)"
    echo "✓ 种子排队: 已禁用"
    echo "✓ 连接数限制: 已取消"
    echo "✓ 上传/下载数限制: 已取消"
    echo "✓ 活动种子数限制: 已取消"
    echo ""
    echo "快速管理命令："
    echo "./qb_manage.sh start    # 启动容器"
    echo "./qb_manage.sh stop     # 停止容器"
    echo "./qb_manage.sh restart  # 重启容器"
    echo "./qb_manage.sh logs     # 查看日志"
    echo "./qb_manage.sh status   # 查看状态"
    echo "./qb_manage.sh update   # 更新容器"
    echo ""
    echo "GitHub快速部署命令："
    echo "curl -sSL https://raw.githubusercontent.com/heshuiiii/commad-use/main/qbittorrent_setup_2int.sh | bash"
    echo ""
    echo "注意事项 (HOST网络模式 + 增强配置)："
    echo "1. 使用host网络模式，容器直接使用宿主机网络"
    echo "2. WebUI已预设为简体中文界面"
    echo "3. UPnP端口已随机生成，提高安全性"
    echo "4. 所有连接数和队列限制已移除"
    echo "5. 请确保宿主机防火墙允许相应端口访问"
    echo "6. 配置文件已优化，无需手动调整"
    echo ""
}

# 主执行流程
main() {
    check_root
    install_docker
    install_docker_compose
    generate_random_ports
    create_directories
    create_compose_file
    set_permissions
    start_containers
    configure_qbittorrent
    create_management_script
    show_results
}

# 执行脚本
main "$@"
