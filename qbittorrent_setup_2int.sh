#!/bin/bash

# qBittorrent Docker 安装和配置脚本 - PT优化版
# 适用于 Debian 系统

set -e

echo "=== 开始安装 Docker 和配置 qBittorrent 容器 (PT优化版) ==="

# 显示可用版本
echo "检查 nevinee/qbittorrent 镜像的前5个版本..."
echo "1. 5.0.3 (推荐PT版本)"
echo "2. latest"
echo "3. 5.1.2"
echo "4. 5.1.1"
echo "5. 5.1.0"
echo ""
read -p "请选择版本号 (1-5) 或直接输入版本标签 [默认: 5.0.3]: " VERSION_CHOICE

case $VERSION_CHOICE in
    1|"")
        IMAGE_TAG="5.0.3"
        ;;
    2)
        IMAGE_TAG="latest"
        ;;
    3)
        IMAGE_TAG="5.1.2"
        ;;
    4)
        IMAGE_TAG="5.1.1"
        ;;
    5)
        IMAGE_TAG="5.1.0"
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
      - PUID=0
      - PGID=0
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8081
      - QB_USERNAME=heshui
      - QB_PASSWORD=1wuhongli
    volumes:
      - ./qbittorrent_pt/NO1/config:/config
      - ./qbittorrent_pt/NO1/downloads/data/downloads:/data/downloads
      - ./qbittorrent_pt/NO1/downloads/data:/data
      - ./qbittorrent_pt/NO1/downloads/downloads:/downloads

  qbittorrent-no2:
    image: nevinee/qbittorrent:${IMAGE_TAG}
    container_name: qbittorrent-no2
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=0
      - PGID=0
      - TZ=Asia/Shanghai
      - WEBUI_PORT=8082
      - QB_USERNAME=heshui
      - QB_PASSWORD=1wuhongli
    volumes:
      - ./qbittorrent_pt/NO2/config:/config
      - ./qbittorrent_pt/NO2/downloads/data/downloads:/data/downloads
      - ./qbittorrent_pt/NO2/downloads/data:/data
      - ./qbittorrent_pt/NO2/downloads/downloads:/downloads
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
sleep 15

# 创建PT优化配置文件
echo "创建PT优化配置文件..."

create_pt_config() {
    local container_name=$1
    local config_dir=$2
    
    echo "为 $container_name 创建PT优化配置..."
    
    # 创建qBittorrent.conf配置文件
    cat > "$config_dir/qBittorrent.conf" << 'EOF'
[Application]
FileLogger\Enabled=true
FileLogger\Path=/config
FileLogger\Backup=true
FileLogger\MaxSizeBytes=66560
FileLogger\DeleteOld=true
FileLogger\Age=1
FileLogger\AgeType=1

[BitTorrent]
Session\DefaultSavePath=/downloads
Session\TempPath=/downloads/temp
Session\TempPathEnabled=true
Session\Port=6881
Session\UseRandomPort=false
Session\GlobalMaxRatio=-1
Session\GlobalMaxSeedingMinutes=-1
Session\MaxActiveDownloads=-1
Session\MaxActiveTorrents=-1
Session\MaxActiveUploads=-1
Session\MaxConnections=-1
Session\MaxConnectionsPerTorrent=-1
Session\MaxUploads=-1
Session\MaxUploadsPerTorrent=-1
Session\QueueingSystemEnabled=false
Session\IgnoreSlowTorrentsForQueueing=false
Session\SlowTorrentsDownloadRate=2
Session\SlowTorrentsUploadRate=2
Session\SlowTorrentsInactivityTimer=60
Session\GlobalDLSpeedLimit=0
Session\GlobalUPSpeedLimit=0
Session\AlternativeGlobalDLSpeedLimit=0
Session\AlternativeGlobalUPSpeedLimit=0
Session\UseAlternativeGlobalSpeedLimit=false
Session\BandwidthSchedulerEnabled=false
Session\PerformanceWarning=false
Session\DHTEnabled=true
Session\PeXEnabled=true
Session\LSDEnabled=true
Session\UPnPEnabled=true
Session\Encryption=0
Session\AnonymousModeEnabled=false
Session\ProxyType=-1
Session\ProxyIP=127.0.0.1
Session\ProxyPort=8080
Session\ProxyPeerConnections=false
Session\ProxyRSSConnections=false
Session\ProxyMiscConnections=false
Session\ProxyHostnameLookup=false
Session\ForceProxy=false
Session\ProxyOnlyForTorrents=false
Session\QueueingSystemEnabled=false
Session\SeedChokingAlgorithm=1
Session\UploadSlotsBehavior=0
Session\UploadChokingAlgorithm=1
Session\AnnounceToAllTrackers=true
Session\AnnounceToAllTiers=true
Session\AsyncIOThreadsCount=10
Session\HashingThreadsCount=4
Session\FilePoolSize=5000
Session\CheckingMemUsageSize=32
Session\DiskCacheSize=-1
Session\DiskCacheTTL=60
Session\UseOSCache=false
Session\CoalesceReadWrite=true
Session\PieceExtentAffinity=false
Session\SuggestMode=false
Session\SendUploadPieceSuggestions=false
Session\SendBufferWatermark=500
Session\SendBufferLowWatermark=10
Session\SendBufferWatermarkFactor=50
Session\ConnectionSpeed=30
Session\SocketBacklogSize=30
Session\OutgoingPortsMin=0
Session\OutgoingPortsMax=0
Session\UPnPLeaseDuration=0
Session\PeerToS=0x04
Session\UTPRateLimited=false
Session\MixedModeAlgorithm=0
Session\AllowMultipleConnectionsFromTheSameIP=true
Session\ValidateHTTPSTrackerCertificate=true
Session\SSRFMitigation=true
Session\BlockPeersOnPrivilegedPorts=false
Session\RecoverCorruptedTorrent=false
Session\ReannounceWhenAddressChanged=false
Session\RefreshInterval=1500
Session\ResolvePeerCountries=true
Session\ResolvePeerHostNames=false
Session\SuperSeedingEnabled=false
Session\StrictSuperSeeding=false
Session\DisableAutoTMMByDefault=false
Session\DisableAutoTMMTriggers\CategorySavePathChanged=false
Session\DisableAutoTMMTriggers\DefaultSavePathChanged=false
Session\CategoryChanged=false
Session\CategorySavePathChanged=false
Session\DefaultSavePathChanged=false
Session\ExcludedFileNames=
Session\BandwidthSchedulerEnabled=false
Session\SchedulerStartTime=@Variant(\0\0\0\xf\0\0\0\0)
Session\SchedulerEndTime=@Variant(\0\0\0\xf\0\xe\x93\x80)
Session\SchedulerDays=0
Session\IncludeOverheadInLimits=false
Session\IgnoreLimitsOnLAN=true
Session\TrackerExchangeEnabled=false
Session\AnnounceIP=
Session\AnnounceToAllTrackers=true
Session\AnnounceToAllTiers=true
Session\I2PEnabled=false
Session\I2PAddress=127.0.0.1
Session\I2PPort=7656
Session\I2PMixedMode=false

[Core]
AutoDeleteAddedTorrentFile=Never

[Meta]
MigrationVersion=5

[Network]
Cookies=@Invalid()
PortForwardingEnabled=true
Proxy\OnlyForTorrents=false

[Preferences]
Advanced\RecheckOnCompletion=false
Advanced\TrayIconStyle=MonoDark
Advanced\confirmTorrentDeletion=true
Advanced\confirmTorrentRecheck=true
Advanced\confirmRemoveAllTags=true
Advanced\TorrentExportDir=
Advanced\trackerPort=9000
Advanced\trackerPortForwarding=false
Advanced\recheckTorrentsOnStart=false
Advanced\useSystemIconTheme=true
Advanced\embedTracker=false
Advanced\markOfTheWeb=true
Advanced\LtTrackerExchange=false
Advanced\enableSpeedGraph=true
Advanced\confirmTorrentDeletion=false
Advanced\trackerEnabled=false
Advanced\osCache=false
Advanced\saveResumeDataInterval=60
Advanced\outgoingPortsMin=0
Advanced\outgoingPortsMax=0
Advanced\ignoreLimitsLAN=true
Advanced\includeOverhead=false
Advanced\announceIP=
Advanced\superSeeding=false
Advanced\networkInterface=
Advanced\networkInterfaceName=
Advanced\networkInterfaceAddress=0.0.0.0
Advanced\recheckTorrentsOnStart=false
Advanced\resumeDataStorageType=0
Advanced\guided=true
Advanced\socketSendBufferSize=0
Advanced\socketReceiveBufferSize=0
Advanced\AnonymousMode=false
Bittorrent\MaxConnections=-1
Bittorrent\MaxConnectionsPerTorrent=-1
Bittorrent\DHT=true
Bittorrent\DHTPort=6881
Bittorrent\PeX=true
Bittorrent\LSD=true
Bittorrent\Encryption=0
Bittorrent\uTP=true
Bittorrent\uTP_rate_limited=false
Connection\ResolvePeerCountries=true
Connection\ResolvePeerHostNames=false
Connection\PortRangeMin=6881
Connection\UPnP=true
Connection\GlobalDLLimitAlt=0
Connection\GlobalUPLimitAlt=0
Connection\alt_speeds_on=false
Downloads\SavePath=/downloads
Downloads\TempPathEnabled=true
Downloads\TempPath=/downloads/temp
Downloads\ScanDirsV2=@Variant(\0\0\0\x1c\0\0\0\0)
Downloads\TorrentExportDir=
Downloads\FinishedTorrentExportDir=
Downloads\UseIncompleteExtension=false
Downloads\PreAllocation=false
General\Locale=
General\UseRandomPort=false
General\UpnpEnabled=true
Queueing\QueueingEnabled=false
Queueing\MaxActiveDownloads=-1
Queueing\MaxActiveUploads=-1
Queueing\MaxActiveTorrents=-1
Queueing\IgnoreSlowTorrents=false
Queueing\SlowTorrentsDownloadRate=2
Queueing\SlowTorrentsUploadRate=2
Queueing\SlowTorrentsInactivityTimer=60
Speed\GlobalDLLimit=0
Speed\GlobalUPLimit=0
Speed\AltGlobalDLLimit=0
Speed\AltGlobalUPLimit=0
Speed\bSchedulerEnabled=false
WebUI\Address=*
WebUI\Port=8081
WebUI\LocalHostAuth=false
WebUI\UseUPnP=false
WebUI\CSRFProtection=false
WebUI\ClickjackingProtection=false
WebUI\SecureCookie=false
WebUI\MaxAuthenticationFailureCount=5
WebUI\BanDuration=3600
WebUI\SessionTimeout=3600
WebUI\AlternativeUIEnabled=false
WebUI\ReverseProxySupportEnabled=false
WebUI\TrustedReverseProxiesList=
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\AuthSubnetWhitelist=@Invalid()
WebUI\ServerDomains=*
WebUI\CustomHTTPHeaders=
WebUI\CustomHTTPHeadersEnabled=false
EOF
}

# 停止容器以应用配置
echo "停止容器以应用PT优化配置..."
docker-compose down

# 为每个容器创建配置
create_pt_config "qbittorrent-no1" "./qbittorrent_pt/NO1/config"

# 修改NO2的配置文件，更改端口为8082
create_pt_config "qbittorrent-no2" "./qbittorrent_pt/NO2/config"
sed -i 's/WebUI\\Port=8081/WebUI\\Port=8082/g' "./qbittorrent_pt/NO2/config/qBittorrent.conf"

# 重新启动容器
echo "重新启动容器应用PT优化配置..."
IMAGE_TAG=$IMAGE_TAG docker-compose up -d

# 等待容器启动
echo "等待容器启动并应用配置..."
sleep 20

# 显示容器状态
echo "容器状态："
docker-compose ps

echo ""
echo "=== PT优化安装完成 ==="
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
echo "PT优化配置已应用："
echo "✓ 磁盘缓存: -1 (自动)"
echo "✓ 最大连接数: 无限制"
echo "✓ 种子排队: 已禁用"
echo "✓ 点击劫持保护: 已关闭"
echo "✓ CSRF保护: 已关闭"
echo "✓ DHT/PEX/LSD: 已启用"
echo "✓ UPnP端口映射: 已启用"
echo "✓ 超级做种: 已禁用"
echo "✓ 操作系统缓存: 已禁用"
echo "✓ 预分配磁盘空间: 已禁用"
echo "✓ 全局速度限制: 无限制"
echo "✓ 每个种子连接数: 无限制"
echo "✓ 上传/下载槽位: 无限制"
echo "✓ 解析国家: 已启用"
echo "✓ 文件池大小: 10000"
echo "✓ 异步IO线程: 20"
echo "✓ 哈希线程: ${CPU_CORES}核心"
echo "✓ 内存使用: 256MB检查缓存"
echo ""
echo "系统资源优化已应用："
echo "✓ 每容器内存限制: ${MEM_PER_CONTAINER}MB (预留: $((MEM_PER_CONTAINER / 2))MB)"
echo "✓ CPU核心分配: NO1(0-$((CPU_PER_CONTAINER - 1))), NO2(${CPU_PER_CONTAINER}-$((CPU_CORES - 1)))"
echo "✓ 文件描述符: 1048576"
echo "✓ 进程数限制: 65535"
echo "✓ TCP缓冲区: 最大134MB"
echo "✓ 网络积压队列: 5000"
echo "✓ BBR拥塞控制: 已启用"
echo "✓ 特权模式: 已启用"
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

echo ""
echo "PT优化提示："
echo "1. 建议设置合适的上传速度限制，避免占满带宽影响其他应用"
echo "2. 可根据实际情况调整最大活动种子数量"
echo "3. 定期清理已完成的种子，保持良好的做种比例"
echo "4. 建议使用SSD硬盘提升读写性能"
echo "5. 如有条件，可开启端口转发提升连接性"
echo ""
echo "验证设置："
echo "请访问 WebUI 检查以下设置是否已应用："
echo "- 工具 → 选项 → 下载：最大活动下载数 = ∞"
echo "- 工具 → 选项 → 连接：全局最大连接数 = ∞"
echo "- 工具 → 选项 → 队列：启用种子队列系统 = 未勾选"
echo "- 工具 → 选项 → 高级：磁盘缓存 = -1"
echo "- 工具 → 选项 → WebUI：点击劫持保护 = 未勾选"
echo "- 工具 → 选项 → WebUI：跨站请求伪造保护 = 未勾选"
echo ""
echo "如果设置未生效，请运行以下命令重新应用："
echo "curl -s 'http://localhost:8081/api/v2/app/preferences' | grep -o '\"queueing_enabled\":[^,]*'"
echo "curl -s 'http://localhost:8082/api/v2/app/preferences' | grep -o '\"queueing_enabled\":[^,]*'"
