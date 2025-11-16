#!/bin/bash
# SMB服务端自动配置脚本
# 作用：快速生成SMB共享配置，并提供fstab挂载命令

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检查并安装Samba
install_samba() {
    print_info "检查Samba安装状态..."
    
    if command -v smbd >/dev/null 2>&1; then
        print_success "Samba已安装"
        return
    fi
    
    print_info "正在安装Samba..."
    
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y samba samba-common-bin
    elif command -v yum >/dev/null 2>&1; then
        yum install -y samba samba-client samba-common
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y samba samba-client samba-common
    else
        print_error "未找到支持的包管理器"
        exit 1
    fi
    
    print_success "Samba安装完成"
}

# 获取用户输入
get_user_input() {
    echo
    print_info "=== SMB配置向导 ==="
    echo
    
    # 获取共享名称
    read -p "请输入SMB共享名称 (默认: media): " SHARE_NAME
    SHARE_NAME=${SHARE_NAME:-media}
    
    # 获取共享目录路径
    read -p "请输入共享目录完整路径 (例如: /data/media): " SHARE_PATH
    if [[ -z "$SHARE_PATH" ]]; then
        print_error "共享目录路径不能为空"
        exit 1
    fi
    
    # 获取root密码
    echo -n "请输入root用户的SMB密码: "
    read -s ROOT_PASSWORD
    echo
    if [[ -z "$ROOT_PASSWORD" ]]; then
        print_error "密码不能为空"
        exit 1
    fi
    
    # 确认密码
    echo -n "请再次输入密码确认: "
    read -s ROOT_PASSWORD_CONFIRM
    echo
    if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
        print_error "两次输入的密码不一致"
        exit 1
    fi
    
    # 获取服务器IP（用于生成fstab命令）
    SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
    read -p "请输入服务器IP地址 (默认: $SERVER_IP): " INPUT_IP
    SERVER_IP=${INPUT_IP:-$SERVER_IP}
    
    echo
    print_info "配置信息确认："
    echo "  共享名称: $SHARE_NAME"
    echo "  共享路径: $SHARE_PATH"
    echo "  服务器IP: $SERVER_IP"
    echo "  用户名: root"
    echo
    read -p "确认以上信息是否正确？(y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "配置取消"
        exit 0
    fi
}

# 创建共享目录
create_share_directory() {
    print_info "创建共享目录: $SHARE_PATH"
    
    mkdir -p "$SHARE_PATH"
    chown root:root "$SHARE_PATH"
    chmod 755 "$SHARE_PATH"
    
    print_success "共享目录创建完成"
}

# 备份原配置文件
backup_smb_conf() {
    if [[ -f /etc/samba/smb.conf ]]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)
        print_info "已备份原配置文件"
    fi
}

# 生成SMB配置
generate_smb_config() {
    print_info "生成SMB配置文件..."
    
    cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = WORKGROUP
    server string = Media SMB Server
    security = user
    map to guest = never
    dns proxy = no
    
    # 性能优化配置
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    read raw = yes
    write raw = yes
    max xmit = 65535
    dead time = 15
    getwd cache = yes
    
    # 媒体文件优化
    strict allocate = No
    allocation roundup size = 1048576
    
    # 日志配置
    log file = /var/log/samba/log.%m
    max log size = 1000
    logging = file

[$SHARE_NAME]
    comment = $SHARE_NAME Storage
    path = $SHARE_PATH
    browseable = yes
    writable = yes
    guest ok = no
    valid users = root
    force user = root
    force group = root
    create mask = 0664
    directory mask = 0775
    
    # 媒体服务优化
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes
EOF
    
    print_success "SMB配置文件生成完成"
}

# 设置SMB密码
set_smb_password() {
    print_info "设置root用户SMB密码..."
    
    # 使用expect设置密码，如果没有expect则手动输入
    if command -v expect >/dev/null 2>&1; then
        expect << EOF
spawn smbpasswd -a root
expect "New SMB password:"
send "$ROOT_PASSWORD\r"
expect "Retype new SMB password:"
send "$ROOT_PASSWORD\r"
expect eof
EOF
    else
        echo "请手动输入root用户的SMB密码："
        smbpasswd -a root
    fi
    
    print_success "SMB密码设置完成"
}

# 启动SMB服务
start_smb_service() {
    print_info "启动SMB服务..."
    
    # 验证配置文件
    if ! testparm -s > /dev/null 2>&1; then
        print_error "SMB配置文件验证失败"
        exit 1
    fi
    
    # 启动服务
    systemctl enable smbd nmbd 2>/dev/null || true
    systemctl restart smbd nmbd
    
    if systemctl is-active --quiet smbd && systemctl is-active --quiet nmbd; then
        print_success "SMB服务启动成功"
    else
        print_error "SMB服务启动失败"
        exit 1
    fi
}

# 配置防火墙
configure_firewall() {
    print_info "配置防火墙..."
    
    if command -v ufw >/dev/null 2>&1; then
        ufw allow samba 2>/dev/null || true
        print_info "已通过ufw开放SMB端口"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=samba 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        print_info "已通过firewall-cmd开放SMB端口"
    else
        print_warning "请手动开放SMB端口 (139, 445)"
    fi
}

# 生成客户端挂载信息
generate_mount_info() {
    print_success "=== 配置完成 ==="
    echo
    print_info "SMB服务信息："
    echo "  服务器地址: $SERVER_IP"
    echo "  共享名称: $SHARE_NAME"
    echo "  共享路径: //$SERVER_IP/$SHARE_NAME"
    echo "  用户名: root"
    echo
    
    print_info "客户端挂载命令："
    echo
    echo -e "${GREEN}# 1. 创建凭据文件${NC}"
    echo "sudo cat > /etc/cifs-credentials << EOF"
    echo "username=root"
    echo "password=$ROOT_PASSWORD"
    echo "domain=WORKGROUP"
    echo "EOF"
    echo "sudo chmod 600 /etc/cifs-credentials"
    echo
    
    echo -e "${GREEN}# 2. 创建挂载点${NC}"
    echo "sudo mkdir -p /home/mnt/$SHARE_NAME"
    echo
    
    echo -e "${GREEN}# 3. 手动挂载测试${NC}"
    echo "sudo mount -t cifs //$SERVER_IP/$SHARE_NAME /home/mnt/$SHARE_NAME -o credentials=/etc/cifs-credentials,uid=1000,gid=1000,iocharset=utf8,file_mode=0664,dir_mode=0775,vers=3.0"
    echo
    
    echo -e "${GREEN}# 4. fstab自动挂载配置${NC}"
    echo "# 将以下行添加到 /etc/fstab 文件中："
    echo "//$SERVER_IP/$SHARE_NAME /home/mnt/$SHARE_NAME cifs credentials=/etc/cifs-credentials,uid=1000,gid=1000,iocharset=utf8,file_mode=0664,dir_mode=0775,vers=3.0,cache=strict,rsize=1048576,wsize=1048576,echo_interval=60,_netdev 0 0"
    echo
    
    echo -e "${GREEN}# 5. 直接在fstab中使用用户名密码（不推荐，安全性较低）${NC}"
    echo "//$SERVER_IP/$SHARE_NAME /home/mnt/$SHARE_NAME cifs username=root,password=$ROOT_PASSWORD,vers=3.0,rsize=130048,wsize=130048,actimeo=60,dir_mode=0777,file_mode=0777,iocharset=utf8 0 0"
    echo
    
    print_info "测试连接命令："
    echo "smbclient -L //$SERVER_IP -U root"
    echo
}

# 主函数
main() {
    echo -e "${BLUE}"
    echo "================================================"
    echo "           SMB服务端自动配置脚本"
    echo "================================================"
    echo -e "${NC}"
    
    check_root
    install_samba
    get_user_input
    create_share_directory
    backup_smb_conf
    generate_smb_config
    set_smb_password
    start_smb_service
    configure_firewall
    generate_mount_info
    
    print_success "SMB配置完成！请保存上面的挂载命令以备使用。"
}

# 运行主函数
main "$@"