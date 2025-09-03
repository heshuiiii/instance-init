#!/bin/bash

# qBittorrent Docker 安装和配置脚本
# 适用于 Debian 系统

set -e

echo "=== 开始安装 Docker 和配置 qBittorrent 容器 ==="

# 显示可用版本
echo "检查 nevinee/qbittorrent 镜像的前5个版本..."
echo "1. latest"
echo "2. 5.1.2"
echo "3. 5.1.1"
echo "4. 5.1.0"
echo "5. 5.0.3"
echo ""
read -p "请选择版本号 (1-5) 或直接输入版本标签 [默认: latest]: " VERSION_CHOICE

case $VERSION_CHOICE in
    1|"")
        IMAGE_TAG="latest"
        ;;
    2)
        IMAGE_TAG="5.1.2"
        ;;
    3)
        IMAGE_TAG="5.1.1"
        ;;
    4)
        IMAGE_TAG="5.1.0"
        ;;
    5)
        IMAGE_TAG="5.0.3"
        ;;
    *)
        IMAGE_TAG="$VERSION_CHOICE"
        ;;
esac

echo "选择的版本: nevinee/qbittorrent:$IMAGE_TAG"

# 更新系统包
echo "更新系统包..."
apt-get update

# 安装必要的包
echo "安装必要的依赖包..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# 添加 Docker 官方 GPG 密钥
echo "添加 Docker GPG 密钥..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# 设置稳定版仓库
echo "添加 Docker 仓库..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 更新包索引
apt-get update

# 安装 Docker Engine
echo "安装 Docker Engine..."
apt-get install -y docker-ce docker-ce-cli containerd.io

# 安装 Docker Compose
echo "安装 Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 启动 Docker 服务
echo "启动 Docker 服务..."
systemctl start docker
systemctl enable docker

# 检查 Docker 版本
echo "Docker 版本信息："
docker --version
docker-compose --version

# 创建项目目录结构
echo "创建项目目录结构..."
mkdir -p ./qbittorrent_pt/NO1/config
mkdir -p ./qbittorrent_pt/NO1/downloads
mkdir -p ./qbittorrent_pt/NO2/config
mkdir -p ./qbittorrent_pt/NO2/downloads

# 清空现有的 docker-compose 文件
echo "清空现有的 docker-compose.yml 文件..."
> docker-compose.yml

# 创建带有版本变量的 docker-compose.yml 文件
echo "创建 docker-compose.yml 文件（版本: $IMAGE_TAG）..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  qbittorrent-no1:
    image: nevinee/qbittorrent:${IMAGE_TAG}
    container_name: qbittorrent-no1
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8081
      - QB_USERNAME=heshui
      - QB_PASSWORD=1wuhongli
    volumes:
      - ./qbittorrent_pt/NO1/config:/config
      - ./qbittorrent_pt/NO1/downloads:/downloads

  qbittorrent-no2:
    image: nevinee/qbittorrent:${IMAGE_TAG}
    container_name: qbittorrent-no2
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8082
      - QB_USERNAME=heshui
      - QB_PASSWORD=1wuhongli
    volumes:
      - ./qbittorrent_pt/NO2/config:/config
      - ./qbittorrent_pt/NO2/downloads:/downloads

EOF

echo "docker-compose.yml 文件创建完成！"

# 设置目录权限
echo "设置目录权限..."
chown -R 1000:1000 ./qbittorrent_pt/

# 启动容器
echo "启动 qBittorrent 容器（版本: $IMAGE_TAG）..."
IMAGE_TAG=$IMAGE_TAG docker-compose up -d

# 等待容器启动
echo "等待容器启动..."
sleep 10

# 显示容器状态
echo "容器状态："
docker-compose ps

echo ""
echo "=== 安装完成 ==="
echo "使用镜像版本: nevinee/qbittorrent:$IMAGE_TAG"
echo "qBittorrent NO1 WebUI: http://localhost:8081"
echo "qBittorrent NO2 WebUI: http://localhost:8082"
echo "用户名: heshui"
echo "密码: 1wuhongli"
echo ""
echo "目录映射："
echo "NO1 配置目录: ./qbittorrent_pt/NO1/config"
echo "NO1 下载目录: ./qbittorrent_pt/NO1/downloads"
echo "NO2 配置目录: ./qbittorrent_pt/NO2/config"
echo "NO2 下载目录: ./qbittorrent_pt/NO2/downloads"
echo ""
echo "网络模式: host (直接使用主机网络)"
echo "WebUI 端口: 8081 (NO1), 8082 (NO2)"
echo ""
echo "管理命令："
echo "启动容器: IMAGE_TAG=$IMAGE_TAG docker-compose up -d"
echo "停止容器: docker-compose down"
echo "查看日志: docker-compose logs -f [qbittorrent-no1|qbittorrent-no2]"
echo "重启容器: docker-compose restart"

# 显示防火墙提示（如果需要）
echo ""
echo "注意：使用 host 网络模式，容器直接使用主机网络"
echo "如果无法访问 WebUI，请检查防火墙设置："
echo "ufw allow 8081"
echo "ufw allow 8082"
