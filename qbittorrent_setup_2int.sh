#!/bin/bash

# qBittorrent双容器一键部署脚本 - 优化版
# 功能：Docker安装、最大资源分配、双容器部署、自定义用户名密码、简体中文UI
# 使用：curl -sSL <脚本URL> | bash

set -e

echo "=== qBittorrent双容器一键部署 ==="

# 版本选择
select_version() {
    echo "选择qBittorrent版本："
    echo "1) 14.3.9 (LTS推荐)"
    echo "2) 5.0.3 (最新)"
    echo "3) latest"
    read -p "选择 [1-3, 默认1]: " choice
    case ${choice:-1} in
        1) QB_VERSION="14.3.9" ;;
        2) QB_VERSION="5.0.3" ;;
        3) QB_VERSION="latest" ;;
        *) QB_VERSION="4.6.7" ;;
    esac
    echo "选择版本: $QB_VERSION"
}

# 安装Docker
install_docker() {
    echo "检查Docker..."
    if ! command -v docker &> /dev/null; then
        echo "安装Docker..."
        # 修复包依赖
        apt update || true
        apt install -y --fix-broken curl ca-certificates gnupg || true
        # 一键安装Docker
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        usermod -aG docker $USER 2>/dev/null || true
    fi
    
    # 安装Docker Compose
    if ! docker compose version &> /dev/null; then
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    echo "Docker准备完成"
}

# 生成随机密码和端口
generate_config() {
    QB1_PORT=$((20000 + RANDOM % 45000))
    QB2_PORT=$((20000 + RANDOM % 45000))
    while [ $QB2_PORT -eq $QB1_PORT ]; do
        QB2_PORT=$((20000 + RANDOM % 45000))
    done
    
    # 生成随机密码
    RANDOM_PASS=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-10)
    
    # 生成PBKDF2哈希（qBittorrent格式）
    # 使用Python生成正确的哈希值
    HASHED_PASS=$(python3 -c "
import hashlib
import base64
import secrets
password = '$RANDOM_PASS'
salt = secrets.token_bytes(32)
iterations = 100000
key = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations)
result = base64.b64encode(salt + key).decode()
print(f'@ByteArray({result})')
" 2>/dev/null || echo "@ByteArray($(echo -n "${RANDOM_PASS}" | base64))")
    
    echo "配置生成完成"
    echo "端口: QB1=$QB1_PORT, QB2=$QB2_PORT"
    echo "用户: heshui, 密码: $RANDOM_PASS"
}

# 创建项目结构
setup_project() {
    mkdir -p qbittorrent-cluster/{NO1_QB,NO2_QB}/{config,downloads}
    cd qbittorrent-cluster
    
    # 创建Docker Compose
    cat > docker-compose.yml << EOF
version: '3.8'
services:
  qbittorrent-1:
    image: linuxserver/qbittorrent:$QB_VERSION
    container_name: qb-no1
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8081
    volumes:
      - ./NO1_QB/config:/config
      - ./NO1_QB/downloads:/downloads
    network_mode: host
    # ports:
    #   - "8081:8081"
    #   - "$QB1_PORT:$QB1_PORT"
    restart: unless-stopped

  qbittorrent-2:
    image: linuxserver/qbittorrent:$QB_VERSION
    container_name: qb-no2
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8082
    volumes:
      - ./NO2_QB/config:/config
      - ./NO2_QB/downloads:/downloads
    network_mode: host
    # ports:
    #   - "8082:8082"
    #   - "$QB2_PORT:$QB2_PORT"
    restart: unless-stopped
EOF
    
    chown -R 1000:1000 NO1_QB NO2_QB
}

# 创建优化配置
create_config() {
    local config_dir=$1
    local upnp_port=$2
    local webui_port=$3
    
    mkdir -p "$config_dir/qBittorrent"
    
    # 根据版本选择配置模板
    if [[ "$QB_VERSION" =~ ^5\. ]]; then
        # qBittorrent 5.x 配置
        cat > "$config_dir/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\\Port=$upnp_port
Session\\UPnPEnabled=true
Session\\MaxActiveDownloads=-1
Session\\MaxActiveTorrents=-1
Session\\MaxActiveUploads=-1
Session\\MaxConnections=-1
Session\\MaxConnectionsPerTorrent=-1
Session\\MaxUploads=-1
Session\\MaxUploadsPerTorrent=-1
Session\\QueueingSystemEnabled=false
Session\\GlobalMaxRatio=0

[Preferences]
WebUI\\Port=$webui_port
WebUI\\Username=heshui
WebUI\\Password_PBKDF2="$HASHED_PASS"
WebUI\\LocalHostAuth=false
General\\Locale=zh_CN
Connection\\PortRangeMin=$upnp_port
Connection\\UPnP=true
Downloads\\SavePath=/downloads
EOF
    else
        # qBittorrent 4.x 配置
        cat > "$config_dir/qBittorrent/qBittorrent.conf" << EOF
[BitTorrent]
Session\\Port=$upnp_port
Session\\UPnPEnabled=true
Session\\MaxActiveDownloads=-1
Session\\MaxActiveTorrents=-1
Session\\MaxActiveUploads=-1
Session\\MaxConnections=-1
Session\\MaxConnectionsPerTorrent=-1
Session\\MaxUploads=-1
Session\\MaxUploadsPerTorrent=-1
Session\\QueueingSystemEnabled=false
Session\\GlobalMaxRatio=0

[Preferences]
Bittorrent\\MaxConnecs=-1
Bittorrent\\MaxConnecsPerTorrent=-1
Bittorrent\\MaxUploads=-1
Bittorrent\\MaxUploadsPerTorrent=-1
Bittorrent\\MaxActiveDownloads=-1
Bittorrent\\MaxActiveTorrents=-1
Bittorrent\\MaxActiveUploads=-1
Bittorrent\\QueueingEnabled=false
WebUI\\Port=$webui_port
WebUI\\Username=heshui
WebUI\\Password_PBKDF2="$HASHED_PASS"
WebUI\\LocalHostAuth=false
General\\Locale=zh_CN
Connection\\PortRangeMin=$upnp_port
Connection\\UPnP=true
Downloads\\SavePath=/downloads
EOF
    fi
    
    chown -R 1000:1000 "$config_dir"
}

# 部署和启动
deploy() {
    echo "拉取镜像并启动..."
    docker compose pull
    docker compose up -d
    
    sleep 10
    
    # 停止容器应用配置
    docker compose stop
    
    echo "应用优化配置..."
    create_config "NO1_QB/config" "$QB1_PORT" "8081"
    create_config "NO2_QB/config" "$QB2_PORT" "8082"
    
    # 重启应用配置
    docker compose up -d
    
    sleep 5
}

# 创建管理脚本
create_manager() {
    cat > manage.sh << 'EOF'
#!/bin/bash
case "$1" in
    start) docker compose start ;;
    stop) docker compose stop ;;
    restart) docker compose restart ;;
    logs) docker compose logs -f ${2:-} ;;
    status) docker compose ps ;;
    update) docker compose pull && docker compose up -d ;;
    *) echo "用法: $0 {start|stop|restart|logs [qb-no1|qb-no2]|status|update}" ;;
esac
EOF
    chmod +x manage.sh
}

# 显示结果
show_results() {
    local server_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo "=== 部署完成！ ==="
    echo ""
    echo "🔗 访问地址:"
    echo "  NO1: http://$server_ip:8081"
    echo "  NO2: http://$server_ip:8082"
    echo ""
    echo "🔑 登录信息:"
    echo "  用户名: heshui"
    echo "  密码: $RANDOM_PASS"
    echo ""
    echo "⚙️ 配置信息:"
    echo "  版本: qBittorrent $QB_VERSION"
    echo "  语言: 简体中文"
    echo "  UPnP端口: NO1=$QB1_PORT, NO2=$QB2_PORT"
    echo "  限制: 全部取消"
    echo ""
    echo "📁 目录结构:"
    echo "  配置: ./NO1_QB/config, ./NO2_QB/config"
    echo "  下载: ./NO1_QB/downloads, ./NO2_QB/downloads"
    echo ""
    echo "🛠️ 管理命令:"
    echo "  ./manage.sh start|stop|restart|logs|status|update"
    echo ""
    
    # 保存密码到文件
    echo "用户名: heshui" > login_info.txt
    echo "密码: $RANDOM_PASS" >> login_info.txt
    echo "NO1端口: $QB1_PORT" >> login_info.txt
    echo "NO2端口: $QB2_PORT" >> login_info.txt
    echo "✅ 登录信息已保存到 login_info.txt"
}

# 主流程
main() {
    select_version
    install_docker
    generate_config
    setup_project
    deploy
    create_manager
    show_results
}

main "$@"
