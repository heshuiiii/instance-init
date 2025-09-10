#!/bin/bash

set -e
set -x

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 用户确认函数
ask_user() {
    local prompt="$1"
    local response
    while true; do
        echo -e "${BLUE}$prompt (y/n): ${NC}"
        read -r response
        case $response in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo -e "${RED}请输入 y 或 n${NC}" ;;
        esac
    done
}

echo -e "${GREEN}🔧 Debian 系统完整初始化脚本 (含 Rclone)${NC}"
echo -e "${BLUE}请选择需要执行的功能：${NC}"

# 预先询问所有功能选项
SET_HOSTNAME=false
CREATE_DIRS=false
INSTALL_SOFTWARE=false
SET_LOCALE=false
CREATE_SWAP=false
MOUNT_CIFS=false
ENABLE_BBR=false
INSTALL_RCLONE=false
CREATE_RCLONE_SERVICE=false
REBOOT_SYSTEM=false
SET_TIMEZONE=false

# 主机名设置
if ask_user "1️⃣ 是否需要设置主机名？"; then
    SET_HOSTNAME=true
    echo -e "${BLUE}请输入新的主机名:${NC}"
    read -r NEW_HOSTNAME
    if [ -z "$NEW_HOSTNAME" ]; then
        echo -e "${YELLOW}⚠️ 主机名为空，将跳过此功能${NC}"
        SET_HOSTNAME=false
    fi
fi

# 创建目录
if ask_user "2️⃣ 是否需要创建目录结构？"; then
    CREATE_DIRS=true
fi

# 安装软件
if ask_user "3️⃣ 是否需要安装常用软件包？"; then
    INSTALL_SOFTWARE=true
    echo -e "${BLUE}将安装以下软件包:${NC}"
    echo -e "${YELLOW}基础工具: screen rsync wget curl unzip${NC}"
    echo -e "${YELLOW}系统工具: cifs-utils locales fuse3${NC}"
    echo -e "${YELLOW}开发工具: git vim nano htop tree${NC}"
    echo -e "${YELLOW}网络工具: net-tools dnsutils${NC}"
fi

# 设置语言环境
if ask_user "4️⃣ 是否需要设置中文语言环境 (zh_CN.UTF-8)？"; then
    SET_LOCALE=true
fi

# 设置swap
if ask_user "5️⃣ 是否需要设置 6G swap 文件？"; then
    CREATE_SWAP=true
fi

# CIFS挂载
if ask_user "6️⃣ 是否需要挂载 CIFS 网络共享盘？"; then
    MOUNT_CIFS=true
    echo -e "${YELLOW}📝 CIFS 挂载配置说明：${NC}"
    echo -e "${YELLOW}请准备你的 fstab 挂载条目，格式如下：${NC}"
    echo -e "${BLUE}//服务器IP/共享名 /挂载点 cifs username=用户名,password=密码,vers=3.0,其他选项 0 0${NC}"
    echo
    
    CIFS_ENTRIES=()
    ENTRY_COUNT=0
    
    while true; do
        ENTRY_COUNT=$((ENTRY_COUNT + 1))
        echo -e "${BLUE}请输入第 $ENTRY_COUNT 个 CIFS 挂载条目（完整的 fstab 行）:${NC}"
        echo -e "${YELLOW}提示：直接粘贴完整的挂载行，或输入 'done' 完成输入${NC}"
        read -r CIFS_ENTRY
        
        if [ "$CIFS_ENTRY" = "done" ]; then
            break
        fi
        
        if [ -n "$CIFS_ENTRY" ]; then
            CIFS_ENTRIES+=("$CIFS_ENTRY")
            echo -e "${GREEN}✅ 已添加挂载条目 $ENTRY_COUNT: $CIFS_ENTRY${NC}"
            
            if ! ask_user "是否继续添加更多挂载条目？"; then
                break
            fi
        else
            echo -e "${RED}❌ 输入为空，请重新输入${NC}"
            ENTRY_COUNT=$((ENTRY_COUNT - 1))
        fi
    done
    
    if [ ${#CIFS_ENTRIES[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️ 未输入任何挂载条目，将跳过 CIFS 挂载${NC}"
        MOUNT_CIFS=false
    fi
fi

# BBR加速 - 暂时移除，不询问
# if ask_user "7️⃣ 是否需要启用 TCP BBR 加速？"; then
#     ENABLE_BBR=true
# fi

# 安装 Rclone
if ask_user "7️⃣ 是否需要安装最新版 Rclone？"; then
    INSTALL_RCLONE=true
fi

# 创建 Rclone 服务
if ask_user "8️⃣ 是否需要创建 Rclone 挂载服务？"; then
    CREATE_RCLONE_SERVICE=true
fi

# 设置时区
if ask_user "9️⃣ 是否需要将系统时区设置为 Asia/Shanghai？"; then
    SET_TIMEZONE=true
fi

# 重启系统
if ask_user "🔟 完成后是否需要立即重启系统？"; then
    REBOOT_SYSTEM=true
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}开始执行选定的功能...${NC}"
echo -e "${GREEN}========================================${NC}"

# 0️⃣ 设置主机名
if [ "$SET_HOSTNAME" = true ]; then
    echo -e "${BLUE}🔧 设置主机名为: $NEW_HOSTNAME${NC}"
    # 设置主机名
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # 更新 /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    # 如果没有找到 127.0.1.1 行，则添加
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    fi
    echo -e "${GREEN}✅ 主机名已设置为: $NEW_HOSTNAME${NC}"
fi

# 1️⃣ 创建目录
if [ "$CREATE_DIRS" = true ]; then
    echo -e "${BLUE}🔧 创建目录结构...${NC}"
    mkdir -p /home/mnt/LOS-1 \
             /home/mnt/Rclone \
             /root/.config/rclone \
             /var/log
    echo -e "${GREEN}✅ 目录结构创建完成${NC}"
fi

# 2️⃣ 安装常用软件
if [ "$INSTALL_SOFTWARE" = true ]; then
    echo -e "${BLUE}🔧 安装常用软件...${NC}"
    apt update && apt install -y screen rsync wget curl cifs-utils locales unzip fuse3
    echo -e "${GREEN}✅ 常用软件安装完成${NC}"
fi

# 3️⃣ 设置中文语言环境
if [ "$SET_LOCALE" = true ]; then
    echo -e "${BLUE}🔧 设置中文语言环境...${NC}"
    sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=zh_CN.UTF-8
    export LANG=zh_CN.UTF-8
    echo -e "${GREEN}✅ 中文语言环境设置完成（zh_CN.UTF-8）${NC}"
fi

# 4️⃣ 设置 6G swap
if [ "$CREATE_SWAP" = true ]; then
    echo -e "${BLUE}🔧 设置 6G swap...${NC}"
    if [ ! -f /swapfile ]; then
        fallocate -l 6G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap defaults 0 0" >> /etc/fstab
        echo -e "${GREEN}✅ 6G swap 已创建并启用${NC}"
    else
        echo -e "${YELLOW}⚠️ swapfile 已存在，跳过${NC}"
    fi
fi

# 5️⃣ 挂载 CIFS 网络盘
if [ "$MOUNT_CIFS" = true ]; then
    echo -e "${BLUE}🔧 挂载 CIFS 网络共享盘...${NC}"
    
    # 备份 fstab
    cp /etc/fstab /etc/fstab.bak.$(date +%F-%H-%M-%S)

    # 添加用户输入的挂载项
    for entry in "${CIFS_ENTRIES[@]}"; do
        echo -e "${BLUE}添加挂载条目: $entry${NC}"
        # 检查是否已存在相同的挂载条目
        if ! grep -qF -- "$entry" /etc/fstab; then
            echo "$entry" >> /etc/fstab
            echo -e "${GREEN}✅ 已添加到 fstab${NC}"
        else
            echo -e "${YELLOW}⚠️ 该挂载条目已存在，跳过${NC}"
        fi
    done

    # 创建挂载点目录（从 fstab 条目中提取挂载点）
    for entry in "${CIFS_ENTRIES[@]}"; do
        MOUNT_POINT=$(echo "$entry" | awk '{print $2}')
        if [ -n "$MOUNT_POINT" ]; then
            mkdir -p "$MOUNT_POINT"
            echo -e "${BLUE}已创建挂载点目录: $MOUNT_POINT${NC}"
        fi
    done

    # 执行挂载
    echo -e "${BLUE}正在执行挂载...${NC}"
    if mount -a; then
        echo -e "${GREEN}✅ CIFS 共享盘挂载完成${NC}"
    else
        echo -e "${RED}⚠️ 某些挂载失败，请检查配置和网络连接${NC}"
        echo -e "${YELLOW}你可以使用以下命令查看详细信息：${NC}"
        echo -e "${BLUE}   mount -v -t cifs${NC}"
        echo -e "${BLUE}   dmesg | tail -20${NC}"
    fi
fi

# 6️⃣ 启用 TCP BBR
if [ "$ENABLE_BBR" = true ]; then
    echo -e "${BLUE}🔧 启用 TCP BBR...${NC}"
    cat <<EOF >> /etc/sysctl.conf

# TCP BBR 加速
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p

    # 验证是否启用成功
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}✅ BBR 已启用成功${NC}"
    else
        echo -e "${RED}❌ BBR 启用失败，请检查内核支持情况${NC}"
    fi
fi

# 7️⃣ 安装最新版 Rclone
if [ "$INSTALL_RCLONE" = true ]; then
    echo -e "${BLUE}🔧 安装最新版 Rclone...${NC}"
    
    # 进入临时目录
    cd /tmp
    
    # 下载最新版 rclone
    echo -e "${BLUE}正在下载 Rclone...${NC}"
    wget -q https://downloads.rclone.org/rclone-current-linux-amd64.zip -O rclone-current-linux-amd64.zip
    
    # 解压
    echo -e "${BLUE}正在解压 Rclone...${NC}"
    unzip -q rclone-current-linux-amd64.zip
    
    # 进入解压目录
    cd rclone-*-linux-amd64
    
    # 替换二进制文件
    echo -e "${BLUE}正在安装 Rclone...${NC}"
    cp rclone /usr/bin/
    chown root:root /usr/bin/rclone
    chmod 755 /usr/bin/rclone
    
    # 清理临时文件
    cd /
    rm -rf /tmp/rclone-*
    
    # 验证安装
    if command -v rclone &> /dev/null; then
        RCLONE_VERSION=$(rclone version | head -n 1)
        echo -e "${GREEN}✅ Rclone 安装成功: $RCLONE_VERSION${NC}"
    else
        echo -e "${RED}❌ Rclone 安装失败${NC}"
    fi
fi

# 8️⃣ 创建 Rclone 挂载服务
if [ "$CREATE_RCLONE_SERVICE" = true ]; then
    echo -e "${BLUE}🔧 创建 Rclone 挂载服务...${NC}"
    
    # 创建 systemd 服务文件
    cat > /etc/systemd/system/rclone-mount.service << 'EOF'
[Unit]
Description=Rclone Mount
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
ExecStartPre=/bin/mkdir -p /home/mnt/Rclone
ExecStartPre=-/bin/umount /home/mnt/Rclone
ExecStart=/usr/bin/rclone mount openlist:/ /home/mnt/Rclone \
  --config=/root/.config/rclone/rclone.conf \
  --allow-other \
  --allow-non-empty \
  --dir-cache-time 5m \
  --vfs-cache-mode full \
  --vfs-cache-max-size 10G \
  --vfs-cache-max-age 24h \
  --vfs-read-chunk-size 256M \
  --vfs-read-chunk-size-limit 2G \
  --buffer-size 128M \
  --transfers 4 \
  --checkers 8 \
  --attr-timeout 5m \
  --poll-interval 30s \
  --vfs-refresh \
  --no-modtime \
  --umask 022 \
  --uid 1000 \
  --gid 1000 \
  --log-level INFO \
  --log-file /var/log/rclone-mount.log \
  --rc \
  --rc-addr 127.0.0.1:5572 \
  --rc-no-auth
ExecStop=/bin/umount /home/mnt/Rclone
Restart=on-failure
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd
    systemctl daemon-reload
    
    # 启用服务（但不立即启动，因为需要先配置 rclone）
    systemctl enable rclone-mount.service
    
    echo -e "${GREEN}✅ Rclone 挂载服务已创建并启用${NC}"
    echo -e "${YELLOW}⚠️ 请先配置 /root/.config/rclone/rclone.conf 文件，然后使用以下命令启动服务：${NC}"
    echo -e "${BLUE}   systemctl start rclone-mount${NC}"
    echo -e "${BLUE}   systemctl status rclone-mount${NC}"
fi

# 9️⃣ 设置时区为 Asia/Shanghai
if [ "$SET_TIMEZONE" = true ]; then
    echo -e "${BLUE}🔧 设置时区为 Asia/Shanghai...${NC}"
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
    echo -e "${GREEN}✅ 系统时区已设置为 Asia/Shanghai${NC}"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 所有选定功能执行完成！${NC}"
echo -e "${GREEN}========================================${NC}"

# 输出重要提醒
if [ "$CREATE_RCLONE_SERVICE" = true ]; then
    echo -e "${YELLOW}📝 重要提醒：${NC}"
    echo -e "${YELLOW}1. 请配置 Rclone 配置文件: /root/.config/rclone/rclone.conf${NC}"
    echo -e "${YELLOW}2. 配置完成后启动服务: systemctl start rclone-mount${NC}"
    echo -e "${YELLOW}3. 查看服务状态: systemctl status rclone-mount${NC}"
    echo -e "${YELLOW}4. 查看挂载日志: tail -f /var/log/rclone-mount.log${NC}"
fi

if [ "$MOUNT_CIFS" = true ]; then
    echo -e "${YELLOW}📝 CIFS 挂载提醒：${NC}"
    echo -e "${YELLOW}1. fstab 已备份，可用以下命令恢复: cp /etc/fstab.bak.* /etc/fstab${NC}"
    echo -e "${YELLOW}2. 查看当前挂载状态: df -h | grep cifs${NC}"
    echo -e "${YELLOW}3. 如果挂载失败，请检查网络连接和认证信息${NC}"
fi

# 🔟 重启系统
if [ "$REBOOT_SYSTEM" = true ]; then
    echo -e "${GREEN}系统将在 10 秒后重启...${NC}"
    sleep 10
    reboot
else
    echo -e "${YELLOW}请记得稍后手动重启系统以使所有设置生效。${NC}"
fi
