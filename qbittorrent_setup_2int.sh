#!/bin/bash

# 增强版qBittorrent双容器部署脚本 - 重构版
# 新增功能：版本选择、简体中文WebUI、随机UPnP端口、取消连接数限制、种子不排队
# GitHub快速执行：curl -sSL https://raw.githubusercontent.com/heshuiiii/commad-use/main/qbittorrent_setup_enhanced.sh | bash

set -e

echo "=== 增强版qBittorrent双容器部署脚本 - 重构版 ==="
echo "开始执行部署..."

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "警告：正在以root用户运行"
    fi
}

# 版本选择菜单
select_qb_version() {
    echo "=========================================="
    echo "请选择qBittorrent版本："
    echo "=========================================="
    echo "1) qBittorrent 4.6.7 (LTS 长期支持版)"
    echo "2) qBittorrent 5.0.3 (最新版)"
    echo "3) qBittorrent 5.0.2 (稳定版)"
    echo "4) qBittorrent 4.6.6 (经典版)"
    echo "5) qBittorrent latest (最新开发版)"
    echo "6) 自定义版本"
    echo "=========================================="
    
    while true; do
        read -p "请输入选项 [1-6]: " choice
        case $choice in
            1)
                QB_VERSION="4.6.7"
                QB_IMAGE="linuxserver/qbittorrent:4.6.7"
                echo "已选择: qBittorrent $QB_VERSION (LTS版)"
                break
                ;;
            2)
                QB_VERSION="5.0.3"
                QB_IMAGE="linuxserver/qbittorrent:5.0.3"
                echo "已选择: qBittorrent $QB_VERSION (最新版)"
                break
                ;;
            3)
                QB_VERSION="5.0.2"
                QB_IMAGE="linuxserver/qbittorrent:5.0.2"
                echo "已选择: qBittorrent $QB_VERSION (稳定版)"
                break
                ;;
            4)
                QB_VERSION="4.6.6"
                QB_IMAGE="linuxserver/qbittorrent:4.6.6"
                echo "已选择: qBittorrent $QB_VERSION (经典版)"
                break
                ;;
            5)
                QB_VERSION="latest"
                QB_IMAGE="linuxserver/qbittorrent:latest"
                echo "已选择: qBittorrent $QB_VERSION (最新开发版)"
                break
                ;;
            6)
                read -p "请输入自定义版本号 (例如: 4.6.5): " custom_version
                if [[ -n "$custom_version" ]]; then
                    QB_VERSION="$custom_version"
                    QB_IMAGE="linuxserver/qbittorrent:$custom_version"
                    echo "已选择: qBittorrent $QB_VERSION (自定义版)"
                    break
                else
                    echo "版本号不能为空，请重新输入"
                fi
                ;;
            *)
                echo "无效选项，请重新选择"
                ;;
        esac
    done
    echo ""
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
    
    echo "生成的端口配置："
    echo "qBittorrent NO1 UPnP端口: $QB1_PORT"
    echo "qBittorrent NO2 UPnP端口: $QB2_PORT"
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
    image: $QB_IMAGE
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
    image: $QB_IMAGE
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

    echo "Docker Compose配置文件创建完成 (版本: $QB_VERSION)"
}

# 设置目录权限
set_permissions() {
    echo "步骤6: 设置目录权限..."
    
    # 设置目录所有者和权限
    sudo chown -R 1000:1000 NO1_QB NO2_QB
    chmod -R 755 NO1_QB NO2_QB
    
    echo "目录权限设置完成"
}

# 初次启动获取默认密码
first_startup() {
    echo "步骤7: 初次启动qBittorrent容器获取默认密码..."
    
    # 拉取镜像
    $COMPOSE_CMD pull
    
    # 启动容器
    $COMPOSE_CMD up -d
    
    echo "容器启动中，等待初始化完成..."
    sleep 30
    
    # 获取默认密码
    echo ""
    echo "=== 获取默认登录密码 ==="
    echo ""
    echo "qBittorrent NO1 默认密码："
    QB1_PASSWORD=$(docker logs qbittorrent-no1 2>&1 | grep -i "temporary password" | tail -1 | sed -n 's/.*temporary password is: \([A-Za-z0-9]*\).*/\1/p')
    if [[ -n "$QB1_PASSWORD" ]]; then
        echo "用户名: admin"
        echo "密码: $QB1_PASSWORD"
    else
        echo "未找到临时密码，检查容器日志："
        docker logs qbittorrent-no1 | tail -20
    fi
    
    echo ""
    echo "qBittorrent NO2 默认密码："
    QB2_PASSWORD=$(docker logs qbittorrent-no2 2>&1 | grep -i "temporary password" | tail -1 | sed -n 's/.*temporary password is: \([A-Za-z0-9]*\).*/\1/p')
    if [[ -n "$QB2_PASSWORD" ]]; then
        echo "用户名: admin"
        echo "密码: $QB2_PASSWORD"
    else
        echo "未找到临时密码，检查容器日志："
        docker logs qbittorrent-no2 | tail -20
    fi
    
    # 保存密码到文件
    echo "NO1_PASSWORD=$QB1_PASSWORD" > .qb_passwords
    echo "NO2_PASSWORD=$QB2_PASSWORD" >> .qb_passwords
    chmod 600 .qb_passwords
    
    echo ""
    echo "默认密码已保存到 .qb_passwords 文件"
}

# 创建增强配置文件
create_enhanced_config() {
    local config_dir=$1
    local upnp_port=$2
    local webui_port=$3
    
    # 等待容器停止
    sleep 5
    
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

# 应用增强配置
apply_enhanced_config() {
    echo "步骤8: 应用增强配置..."
    
    # 停止容器
    $COMPOSE_CMD stop
    echo "容器已停止，开始配置..."
    
    # 确保配置目录存在
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
    
    # 重启容器
    echo "重新启动容器..."
    $COMPOSE_CMD up -d
    sleep 15
    
    echo "增强配置已应用！"
}

# 创建密码查询脚本
create_password_script() {
    echo "步骤9: 创建密码查询脚本..."
    
    cat > check_passwords.sh << 'EOF'
#!/bin/bash
# qBittorrent密码查询脚本

echo "=== qBittorrent密码查询 ==="
echo ""

# 方法1：从保存的密码文件读取
if [[ -f ".qb_passwords" ]]; then
    echo "从保存的密码文件读取："
    cat .qb_passwords
    echo ""
fi

# 方法2：从容器日志获取
echo "从容器日志获取最新密码："
echo ""

echo "qBittorrent NO1:"
QB1_TEMP_PASS=$(docker logs qbittorrent-no1 2>&1 | grep -i "temporary password" | tail -1)
if [[ -n "$QB1_TEMP_PASS" ]]; then
    echo "$QB1_TEMP_PASS"
else
    echo "未找到临时密码日志"
    # 尝试查找其他相关日志
    docker logs qbittorrent-no1 2>&1 | grep -i "password\|login\|web.*ui" | tail -5
fi

echo ""
echo "qBittorrent NO2:"
QB2_TEMP_PASS=$(docker logs qbittorrent-no2 2>&1 | grep -i "temporary password" | tail -1)
if [[ -n "$QB2_TEMP_PASS" ]]; then
    echo "$QB2_TEMP_PASS"
else
    echo "未找到临时密码日志"
    # 尝试查找其他相关日志
    docker logs qbittorrent-no2 2>&1 | grep -i "password\|login\|web.*ui" | tail -5
fi

echo ""
echo "增强配置密码（如果已应用）："
echo "用户名: heshui"
echo "密码: 1wuhongli"
echo ""
echo "如果无法使用增强配置密码，请使用上面显示的临时密码"
EOF

    chmod +x check_passwords.sh
    echo "密码查询脚本创建完成: ./check_passwords.sh"
}

# 创建管理脚本
create_management_script() {
    echo "步骤10: 创建管理脚本..."
    
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
        if [[ "$2" == "1" || "$2" == "no1" ]]; then
            echo "查看NO1日志..."
            docker logs -f qbittorrent-no1
        elif [[ "$2" == "2" || "$2" == "no2" ]]; then
            echo "查看NO2日志..."
            docker logs -f qbittorrent-no2
        else
            echo "查看所有日志..."
            $COMPOSE_CMD logs -f
        fi
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
    password)
        ./check_passwords.sh
        ;;
    reset)
        echo "重置到默认配置..."
        $COMPOSE_CMD stop
        rm -rf NO1_QB/config/qBittorrent/qBittorrent.conf
        rm -rf NO2_QB/config/qBittorrent/qBittorrent.conf
        $COMPOSE_CMD start
        echo "已重置，请等待30秒后运行 './qb_manage.sh password' 查看新密码"
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs [1|2]|status|update|down|password|reset}"
        echo ""
        echo "命令说明:"
        echo "  start     - 启动容器"
        echo "  stop      - 停止容器"
        echo "  restart   - 重启容器"
        echo "  logs      - 查看实时日志 (可指定1或2查看单个容器)"
        echo "  status    - 查看容器状态"
        echo "  update    - 更新镜像并重启容器"
        echo "  down      - 删除容器（保留数据）"
        echo "  password  - 查看登录密码"
        echo "  reset     - 重置为默认配置"
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
    echo "=== 部署完成！=== "
    echo ""
    echo "qBittorrent容器信息："
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│ qBittorrent NO1 - $QB_VERSION                        │"
    echo "│ 访问地址: http://$(hostname -I | awk '{print $1}'):8081             │"
    echo "│ 本地访问: http://localhost:8081                     │"
    echo "│ UPnP端口: $QB1_PORT                                  │"
    echo "│ 配置目录: ./NO1_QB/config                           │"
    echo "│ 下载目录: ./NO1_QB/downloads                        │"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│ qBittorrent NO2 - $QB_VERSION                        │"
    echo "│ 访问地址: http://$(hostname -I | awk '{print $1}'):8082             │"
    echo "│ 本地访问: http://localhost:8082                     │"
    echo "│ UPnP端口: $QB2_PORT                                  │"
    echo "│ 配置目录: ./NO2_QB/config                           │"
    echo "│ 下载目录: ./NO2_QB/downloads                        │"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
    echo "🔑 登录信息："
    echo "方式1 - 增强配置密码（推荐）："
    echo "用户名: heshui"
    echo "密码: 1wuhongli"
    echo ""
    echo "方式2 - 默认临时密码："
    if [[ -n "$QB1_PASSWORD" ]]; then
        echo "NO1 - 用户名: admin, 密码: $QB1_PASSWORD"
    fi
    if [[ -n "$QB2_PASSWORD" ]]; then
        echo "NO2 - 用户名: admin, 密码: $QB2_PASSWORD"
    fi
    echo ""
    echo "🔧 常用管理命令："
    echo "./qb_manage.sh password  # 查看所有密码"
    echo "./qb_manage.sh start     # 启动容器"
    echo "./qb_manage.sh stop      # 停止容器"
    echo "./qb_manage.sh restart   # 重启容器"
    echo "./qb_manage.sh logs 1    # 查看NO1日志"
    echo "./qb_manage.sh logs 2    # 查看NO2日志"
    echo "./qb_manage.sh reset     # 重置为默认配置"
    echo ""
    echo "✨ 增强功能："
    echo "✓ 版本: qBittorrent $QB_VERSION"
    echo "✓ WebUI语言: 简体中文"
    echo "✓ UPnP端口: 随机生成 (NO1: $QB1_PORT, NO2: $QB2_PORT)"
    echo "✓ 种子排队: 已禁用"
    echo "✓ 连接数限制: 已取消"
    echo "✓ 上传/下载数限制: 已取消"
    echo "✓ 活动种子数限制: 已取消"
    echo ""
}

# 交互式配置选项
interactive_setup() {
    echo ""
    read -p "是否应用增强配置？(y/n) [默认: y]: " apply_config
    apply_config=${apply_config:-y}
    
    if [[ "$apply_config" =~ ^[Yy]$ ]]; then
        apply_enhanced_config
        echo "✓ 增强配置已应用"
    else
        echo "⚠ 跳过增强配置，使用默认设置"
    fi
}

# 主执行流程
main() {
    check_root
    select_qb_version
    install_docker
    install_docker_compose
    generate_random_ports
    create_directories
    create_compose_file
    set_permissions
    first_startup
    create_password_script
    interactive_setup
    create_management_script
    show_results
    
    echo ""
    echo "🎉 部署完成！现在可以通过浏览器访问qBittorrent了"
    echo ""
    echo "如需查看密码，请运行: ./check_passwords.sh"
    echo "如需管理容器，请运行: ./qb_manage.sh"
}

# 执行脚本
main "$@"
