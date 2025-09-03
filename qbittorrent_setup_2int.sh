#!/bin/bash

# qBittorrent双容器PT优化部署脚本
# 专为PT下载优化：高连接数、大缓存、多线程、简体中文
# 使用：curl -sSL <脚本URL> | bash

set -e

echo "=== qBittorrent双容器PT优化部署 ==="

# 版本选择
select_version() {
    echo "选择qBittorrent版本："
    echo "1) 14.3.9 (PT站推荐)"
    echo "2) 5.0.3 (最新版)"
    echo "3) latest"
    read -p "选择 [1-3, 默认1]: " choice
    case ${choice:-1} in
        1) QB_VERSION="14.3.9" ;;
        2) QB_VERSION="5.0.3" ;;
        3) QB_VERSION="latest" ;;
        *) QB_VERSION="4.6.7" ;;
    esac
    echo "选择版本: $QB_VERSION (PT优化版)"
}

# 安装Docker
install_docker() {
    echo "检查Docker..."
    if ! command -v docker &> /dev/null; then
        echo "安装Docker..."
        apt update || true
        apt install -y curl ca-certificates || true
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker && systemctl start docker
        usermod -aG docker $USER 2>/dev/null || true
    fi
    
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo "安装Docker Compose..."
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    echo "Docker准备完成"
}

# 生成配置
generate_config() {
    # 随机端口
    QB1_PORT=$((20000 + RANDOM % 45000))
    QB2_PORT=$((20000 + RANDOM % 45000))
    while [ $QB2_PORT -eq $QB1_PORT ]; do
        QB2_PORT=$((20000 + RANDOM % 45000))
    done
    
    echo "端口分配: QB1=$QB1_PORT, QB2=$QB2_PORT"
}

# 创建项目
setup_project() {
    mkdir -p qbittorrent-pt/{NO1_QB,NO2_QB}/{config,downloads}
    cd qbittorrent-pt
    
    # Docker Compose配置
    cat > docker-compose.yml << EOF
version: '3.8'
services:
  qbittorrent-1:
    image: linuxserver/qbittorrent:$QB_VERSION
    container_name: qb-pt1
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
      - "$QB1_PORT:$QB1_PORT"
    restart: unless-stopped
    sysctls:
      - net.core.rmem_max=134217728
      - net.core.wmem_max=134217728

  qbittorrent-2:
    image: linuxserver/qbittorrent:$QB_VERSION
    container_name: qb-pt2
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
      - "$QB2_PORT:$QB2_PORT"
    restart: unless-stopped
    sysctls:
      - net.core.rmem_max=134217728
      - net.core.wmem_max=134217728
EOF
    
    chown -R 1000:1000 NO1_QB NO2_QB
}

# 创建PT优化配置
create_pt_config() {
    local config_dir=$1
    local upnp_port=$2
    local webui_port=$3
    
    mkdir -p "$config_dir/qBittorrent"
    
    # PT专用优化配置
    cat > "$config_dir/qBittorrent/qBittorrent.conf" << EOF
[Application]
FileLogger\\Enabled=true
FileLogger\\Path=/config/qBittorrent
FileLogger\\Backup=true
FileLogger\\MaxSize=10

[BitTorrent]
Session\\AnnounceToAllTrackers=true
Session\\AnnounceToAllTiers=true
Session\\AsyncIOThreadsCount=16
Session\\CheckingMemUsageSize=1024
Session\\FilePoolSize=500
Session\\GuidedReadCache=true
Session\\MultiConnectionsPerIp=true
Session\\SendBufferWatermark=5120
Session\\SendBufferLowWatermark=1024
Session\\SendBufferWatermarkFactor=150
Session\\SocketBacklogSize=200
Session\\UseOSCache=false
Session\\CoalesceReads=true
Session\\CoalesceWrites=true
Session\\SuggestMode=true
Session\\SendRedundantRequests=true
Session\\Port=$upnp_port
Session\\UPnPEnabled=true
Session\\GlobalMaxRatio=0
Session\\GlobalMaxSeedingMinutes=-1
Session\\MaxActiveDownloads=50
Session\\MaxActiveTorrents=200
Session\\MaxActiveUploads=50
Session\\MaxConnections=5000
Session\\MaxConnectionsPerTorrent=500
Session\\MaxUploads=100
Session\\MaxUploadsPerTorrent=20
Session\\QueueingSystemEnabled=false
Session\\DefaultSavePath=/downloads
Session\\TempPath=/downloads/incomplete

[Preferences]
Advanced\\AnnounceToAllTrackers=true
Advanced\\AnnounceToAllTiers=true
Advanced\\AsyncIOThreadsCount=16
Advanced\\CheckingMemUsageSize=1024
Advanced\\FilePoolSize=500
Advanced\\GuidedReadCache=true
Advanced\\MultiConnectionsPerIp=true
Advanced\\SendBufferWatermark=5120
Advanced\\SendBufferLowWatermark=1024
Advanced\\SendBufferWatermarkFactor=150
Advanced\\SocketBacklogSize=200
Advanced\\UseOSCache=false
Advanced\\CoalesceReads=true
Advanced\\CoalesceWrites=true
Advanced\\SuggestMode=true
Advanced\\SendRedundantRequests=true
Bittorrent\\MaxConnecs=5000
Bittorrent\\MaxConnecsPerTorrent=500
Bittorrent\\MaxUploads=100
Bittorrent\\MaxUploadsPerTorrent=20
Bittorrent\\MaxActiveDownloads=50
Bittorrent\\MaxActiveTorrents=200
Bittorrent\\MaxActiveUploads=50
Bittorrent\\QueueingEnabled=false
Connection\\PortRangeMin=$upnp_port
Connection\\UPnP=true
Downloads\\SavePath=/downloads
Downloads\\TempPath=/downloads/incomplete
Downloads\\PreAllocation=true
DynDNS\\Enabled=false
General\\Locale=zh_CN
WebUI\\Port=$webui_port
WebUI\\LocalHostAuth=false
WebUI\\CSRFProtection=false
WebUI\\SessionTimeout=86400
EOF
    
    chown -R 1000:1000 "$config_dir"
}

# 启动和配置
deploy() {
    echo "启动qBittorrent容器..."
    docker compose pull
    docker compose up -d
    
    echo "等待容器初始化..."
    sleep 20
    
    # 获取随机密码
    PASS1=$(docker logs qb-pt1 2>&1 | grep -oP 'temporary password is: \K\w+' | tail -1)
    PASS2=$(docker logs qb-pt2 2>&1 | grep -oP 'temporary password is: \K\w+' | tail -1)
    
    # 应用PT优化配置
    docker compose stop
    echo "应用PT优化配置..."
    
    create_pt_config "NO1_QB/config" "$QB1_PORT" "8081"
    create_pt_config "NO2_QB/config" "$QB2_PORT" "8082"
    
    # 重启
    docker compose up -d
    sleep 10
}

# 创建管理工具
create_tools() {
    # 管理脚本
    cat > manage.sh << 'EOF'
#!/bin/bash
case "$1" in
    start) docker compose start ;;
    stop) docker compose stop ;;
    restart) docker compose restart ;;
    logs) docker compose logs -f ${2:-} ;;
    status) docker compose ps ;;
    update) docker compose pull && docker compose up -d ;;
    password)
        echo "=== qBittorrent登录密码 ==="
        echo "NO1: $(docker logs qb-pt1 2>&1 | grep 'temporary password' | tail -1)"
        echo "NO2: $(docker logs qb-pt2 2>&1 | grep 'temporary password' | tail -1)"
        ;;
    stats)
        echo "=== 容器资源使用 ==="
        docker stats qb-pt1 qb-pt2 --no-stream
        ;;
    *) echo "用法: $0 {start|stop|restart|logs|status|update|password|stats}" ;;
esac
EOF
    chmod +x manage.sh
    
    # 密码查询脚本
    cat > get_password.sh << 'EOF'
#!/bin/bash
echo "=== qBittorrent登录信息 ==="
echo ""
echo "NO1 (端口8081):"
P1=$(docker logs qb-pt1 2>&1 | grep "temporary password is:" | tail -1 | grep -oP 'temporary password is: \K\w+')
echo "用户名: admin"
echo "密码: $P1"
echo "访问: http://$(hostname -I | awk '{print $1}'):8081"
echo ""
echo "NO2 (端口8082):"
P2=$(docker logs qb-pt2 2>&1 | grep "temporary password is:" | tail -1 | grep -oP 'temporary password is: \K\w+')
echo "用户名: admin"
echo "密码: $P2"
echo "访问: http://$(hostname -I | awk '{print $1}'):8082"
EOF
    chmod +x get_password.sh
}

# 显示结果
show_results() {
    local server_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo "=== PT优化部署完成！ ==="
    echo ""
    echo "🎯 访问地址:"
    echo "  NO1: http://$server_ip:8081"
    echo "  NO2: http://$server_ip:8082"
    echo ""
    echo "🔑 登录信息:"
    echo "  用户名: admin"
    echo "  NO1密码: ${PASS1:-正在生成中...}"
    echo "  NO2密码: ${PASS2:-正在生成中...}"
    echo ""
    echo "⚡ PT优化参数:"
    echo "  最大连接数: 5000 (全局) / 500 (单种子)"
    echo "  最大上传数: 100 (全局) / 20 (单种子)"
    echo "  活动种子数: 200 (下载50+上传50)"
    echo "  异步IO线程: 16"
    echo "  文件池大小: 500"
    echo "  内存缓存: 1GB"
    echo "  预分配磁盘: 启用"
    echo "  种子排队: 禁用"
    echo "  WebUI语言: 简体中文"
    echo "  UPnP端口: NO1=$QB1_PORT, NO2=$QB2_PORT"
    echo ""
    echo "🛠️ 管理命令:"
    echo "  ./get_password.sh  # 查看登录密码"
    echo "  ./manage.sh start  # 启动容器"
    echo "  ./manage.sh stop   # 停止容器"
    echo "  ./manage.sh stats  # 查看资源使用"
    echo ""
    echo "📊 性能建议:"
    echo "  - 建议服务器内存 ≥ 4GB"
    echo "  - SSD硬盘可获得更好性能"
    echo "  - 上传带宽建议 ≥ 100Mbps"
    echo ""
    
    # 保存信息
    cat > login_info.txt << EOF
=== qBittorrent PT优化版登录信息 ===

NO1 访问地址: http://$server_ip:8081
用户名: admin
密码: $PASS1
UPnP端口: $QB1_PORT

NO2 访问地址: http://$server_ip:8082
用户名: admin  
密码: $PASS2
UPnP端口: $QB2_PORT

管理命令:
./get_password.sh - 获取最新密码
./manage.sh password - 查看密码
./manage.sh stats - 查看资源使用
EOF
    
    echo "✅ 登录信息已保存到 login_info.txt"
    echo "🔥 现在可以开始你的PT下载之旅了！"
}

# 主流程
main() {
    select_version
    install_docker
    generate_config
    setup_project
    deploy
    create_tools
    show_results
}

main "$@"
