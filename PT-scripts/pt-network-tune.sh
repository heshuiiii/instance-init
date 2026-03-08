#!/usr/bin/env bash
# =============================================================================
#  PT Seedbox 系统网络调优脚本 v2.0
#  目标：更快建立连接 / 更多并发连接 / 更优的连接质量 / 最大化上传吞吐
#  范围：内核参数 + 拥塞控制 + qdisc + NIC 硬件卸载 + 中断亲和性
#  不涉及：qBittorrent 配置
#
#  用法：
#    sudo bash pt-network-tune.sh              # 正式执行
#    sudo bash pt-network-tune.sh --dry-run    # 仅预览，不修改
#    sudo bash pt-network-tune.sh --revert     # 回滚
# =============================================================================

set -euo pipefail

# ─── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
info()   { echo -e "${BLUE}[→]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; echo -e "${CYAN}$(printf '─%.0s' {1..60})${NC}"; }
result() { printf "  ${BOLD}%-38s${NC} ${GREEN}%s${NC}\n" "$1" "$2"; }

DRY_RUN=false
REVERT=false
SYSCTL_FILE="/etc/sysctl.d/99-pt-network.conf"
BACKUP_FILE="/etc/sysctl.d/99-pt-network.bak"
LIMITS_FILE="/etc/security/limits.d/99-pt-network.conf"

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --revert)  REVERT=true  ;;
    esac
done

[[ $EUID -ne 0 ]] && [[ "$DRY_RUN" == false ]] && { error "需要 root 权限，请用 sudo"; exit 1; }

# ─── 回滚 ─────────────────────────────────────────────────────────────────────
if [[ "$REVERT" == true ]]; then
    header "回滚"
    [[ -f "$BACKUP_FILE" ]] && cp "$BACKUP_FILE" "$SYSCTL_FILE" && sysctl -p "$SYSCTL_FILE" && log "sysctl 已回滚"
    rm -f "$LIMITS_FILE"
    NIC=$(ip route show default | awk '/default/{print $5}' | head -1)
    [[ -n "$NIC" ]] && tc qdisc del dev "$NIC" root 2>/dev/null && log "qdisc 已恢复默认"
    rm -f /etc/modules-load.d/pt-bbr.conf
    log "完成，建议重启服务器"
    exit 0
fi

[[ "$DRY_RUN" == true ]] && warn "DRY-RUN 模式：只预览，不写入任何文件"

# =============================================================================
#  探测环境
# =============================================================================
header "探测系统环境"

NIC=$(ip route show default | awk '/default/{print $5}' | head -1)
[[ -z "$NIC" ]] && { error "无法检测主网卡"; exit 1; }
info "主网卡：${BOLD}$NIC${NC}"

# 网卡速度
NIC_SPEED=0
NIC_SPEED=$(cat /sys/class/net/"$NIC"/speed 2>/dev/null || echo 0)
NIC_SPEED=${NIC_SPEED//[^0-9]/}
[[ "$NIC_SPEED" -le 0 ]] && \
    NIC_SPEED=$(ethtool "$NIC" 2>/dev/null | awk '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}' || echo 0)
info "网卡速度：${BOLD}${NIC_SPEED} Mbps${NC}"

# 内存
MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
info "内存：${BOLD}${MEM_MB} MB${NC}"

# CPU
CPU_CORES=$(nproc --all)
CPU_THREADS=$(nproc)
info "CPU：${BOLD}${CPU_CORES} 核 / ${CPU_THREADS} 线程${NC}"

# 内核版本（用于判断特性支持）
KERN_MAJOR=$(uname -r | cut -d. -f1)
KERN_MINOR=$(uname -r | cut -d. -f2)
KERN_NUM=$(( KERN_MAJOR * 100 + KERN_MINOR ))
info "内核版本：${BOLD}$(uname -r)${NC}"

# 检测网卡驱动（用于 NIC 优化）
NIC_DRIVER=$(ethtool -i "$NIC" 2>/dev/null | awk '/driver:/{print $2}' || echo "unknown")
info "网卡驱动：${BOLD}${NIC_DRIVER}${NC}"

# =============================================================================
#  档位选择
# =============================================================================
header "带宽档位"

if   [[ "$NIC_SPEED" -ge 10000 ]]; then
    PROFILE="10g"; LABEL="10Gbps · Hetzner"
elif [[ "$NIC_SPEED" -ge 2000 ]];  then
    PROFILE="2g5"; LABEL="2.5Gbps · netcup"
elif [[ "$NIC_SPEED" -ge 1000 ]];  then
    PROFILE="1g";  LABEL="1Gbps · 通用"
else
    warn "无法自动识别网卡速度，请选择："
    echo -e "  ${BOLD}1${NC}) 2.5Gbps - netcup"
    echo -e "  ${BOLD}2${NC}) 10Gbps  - Hetzner"
    echo -e "  ${BOLD}3${NC}) 1Gbps   - 通用"
    read -rp "选项 [1/2/3]: " C
    case $C in 1) PROFILE="2g5"; LABEL="2.5Gbps · netcup" ;;
               2) PROFILE="10g"; LABEL="10Gbps · Hetzner" ;;
               *) PROFILE="1g";  LABEL="1Gbps · 通用" ;; esac
fi
log "档位：${BOLD}${LABEL}${NC}"

# =============================================================================
#  参数计算
# =============================================================================

# ── TCP 缓冲区（BDP × 4）──────────────────────────────────────────────────────
# BDP = 带宽(bps) × RTT / 8
# RTT 保守估计：国际节点 50ms，同大洲 20ms，本国 10ms
# 取最大场景（50ms）× 4 做为 max 缓冲区
case $PROFILE in
    10g)
        # 10Gbps × 0.050s / 8 × 4 = 250MB → 取 256MB
        BUFMAX=$((256*1024*1024))
        BUFDEF=$((4*1024*1024))
        BACKLOG=65536
        SOMAXCONN=32768
        SYNBACKLOG=32768
        TW=$((1024*1024))
        TCP_MEM_MAX=$(( MEM_MB * 1024 / 4 / 4 ))   # 总内存 25% 给 TCP（以页为单位）
        ;;
    2g5)
        # 2.5Gbps × 0.050s / 8 × 4 = 62.5MB → 取 64MB
        BUFMAX=$((64*1024*1024))
        BUFDEF=$((2*1024*1024))
        BACKLOG=32768
        SOMAXCONN=16384
        SYNBACKLOG=16384
        TW=$((512*1024))
        TCP_MEM_MAX=$(( MEM_MB * 1024 / 4 / 4 ))
        ;;
    *)
        BUFMAX=$((32*1024*1024))
        BUFDEF=$((1024*1024))
        BACKLOG=16384
        SOMAXCONN=8192
        SYNBACKLOG=8192
        TW=$((180*1024))
        TCP_MEM_MAX=$(( MEM_MB * 1024 / 4 / 4 ))
        ;;
esac

TCP_MEM_LOW=$(( TCP_MEM_MAX / 8 ))
TCP_MEM_PRESS=$(( TCP_MEM_MAX / 4 ))
FS_MAX=2097152
NOFILE=1048576

# ── 拥塞控制 & qdisc ──────────────────────────────────────────────────────────
# BBR 优先，v3（内核 6.3+）> v2（内核 5.16+）> v1（内核 4.9+）> htcp
CC="cubic"   # 默认回退
QDISC="pfifo_fast"

if [[ $KERN_NUM -ge 603 ]] && grep -q "bbr3" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC="bbr3"; QDISC="fq"
elif modprobe tcp_bbr 2>/dev/null; then
    CC="bbr"; QDISC="fq"
elif modprobe htcp 2>/dev/null; then
    CC="htcp"; QDISC="fq_codel"
fi

# 尝试加载更优的 qdisc 模块
modprobe sch_fq 2>/dev/null     || true
modprobe sch_fq_codel 2>/dev/null || true

info "拥塞控制：${BOLD}${CC}${NC} / qdisc：${BOLD}${QDISC}${NC}"

# =============================================================================
#  写入配置
# =============================================================================
header "写入 sysctl 参数"

CONF=$(cat << EOF
# =============================================================================
#  PT Seedbox 系统网络调优
#  生成：$(date '+%Y-%m-%d %H:%M:%S')
#  档位：${LABEL} | 内核：$(uname -r) | 内存：${MEM_MB}MB
# =============================================================================

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  一、拥塞控制与队列调度
#  原理：BBR 基于带宽和 RTT 探测，不依赖丢包信号
#        高并发做种（数百条连接）遇到轻微丢包时 CUBIC 大幅降速，BBR 不会
#        fq（Fair Queue）为每条流独立排队，防止少数 torrent 占满发送队列
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  二、TCP 发送/接收缓冲区
#  原理：max = BDP × 4（带宽×RTT/8×4），保证高延迟链路满速
#        default 不能设太大（会触发缓冲膨胀导致延迟飙升）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.core.rmem_max = ${BUFMAX}
net.core.wmem_max = ${BUFMAX}
net.core.rmem_default = ${BUFDEF}
net.core.wmem_default = ${BUFDEF}
# 格式：min  default  max（字节）
net.ipv4.tcp_rmem = 4096 ${BUFDEF} ${BUFMAX}
net.ipv4.tcp_wmem = 4096 ${BUFDEF} ${BUFMAX}

# UDP 缓冲区（libtorrent uTP 协议走 UDP，同样需要足够大）
net.core.udp_rmem_min = 16384
net.core.udp_wmem_min = 16384

# TCP 内存总量（单位：页=4KB）低水位/压力/硬上限
net.ipv4.tcp_mem = ${TCP_MEM_LOW} ${TCP_MEM_PRESS} ${TCP_MEM_MAX}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  三、"更多连接"：队列与并发上限
#  原理：PT 做种需要同时维持数千条 peer 连接
#        somaxconn/syn_backlog 决定握手时的排队容量
#        tw_buckets 决定能容纳多少 TIME_WAIT 连接（不够会直接 RST）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${SYNBACKLOG}
net.ipv4.tcp_max_tw_buckets = ${TW}
# 本地端口范围（做种有大量出站连接，需要足够多的可用端口）
net.ipv4.ip_local_port_range = 1024 65535

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  四、"更快连接"：握手与回收加速
#  原理：tw_reuse 允许复用 TIME_WAIT socket 发起新连接（不等 2MSL）
#        fin_timeout 缩短半关闭连接占用时间
#        syn_retries 减少，快速判定对端不可达（不浪费时间等僵尸 peer）
#        no_metrics_save 不保存旧路由指标，避免对新 peer 错误估计初始窗口
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_no_metrics_save = 1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  五、"更优连接"：保持质量 & 及时清理死连接
#  原理：keepalive 定期探测，及时发现死 peer 并断开，释放上传 slot
#        slow_start_after_idle=0 防止空闲后重进慢启动（做种连接常有暂时空闲）
#        tcp_abort_on_overflow=0 内核满时拒绝而非 RST，保护正常连接
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  六、TCP 功能开关（全部开启，保证最大性能）
#  SACK：选择性确认，减少不必要重传
#  window_scaling：突破 64KB 窗口上限（千兆以上链路必须）
#  timestamps：配合 PAWS 防止旧包污染，保持精准 RTT 估算
#  mtu_probing：自动探测 PMTU，避免因 DF 位被拦截造成黑洞
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_mtu_probing = 1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  七、文件描述符（每个 peer 连接消耗 1 个 fd，数千连接必须放开限制）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fs.file-max = ${FS_MAX}
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  八、内存回收策略（防止内核把网络缓冲区内存提前回收）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 不主动将匿名内存换到 swap（网络缓冲区是匿名内存）
vm.swappiness = 10
# 脏页写回阈值（避免大量 dirty page 积累后的 I/O 风暴影响网络）
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
EOF
)

LIMITS_CONF=$(cat << EOF
# PT Seedbox 文件描述符限制 - $(date '+%Y-%m-%d %H:%M:%S')
*    soft nofile ${NOFILE}
*    hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
*    soft nproc  unlimited
*    hard nproc  unlimited
EOF
)

if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}[DRY-RUN] sysctl 将写入 ${SYSCTL_FILE}：${NC}"
    echo "$CONF"
    echo -e "\n${YELLOW}[DRY-RUN] limits 将写入 ${LIMITS_FILE}：${NC}"
    echo "$LIMITS_CONF"
else
    [[ -f "$SYSCTL_FILE" ]] && cp "$SYSCTL_FILE" "$BACKUP_FILE" && info "已备份旧配置 → $BACKUP_FILE"
    echo "$CONF"   > "$SYSCTL_FILE"
    echo "$LIMITS_CONF" > "$LIMITS_FILE"
    log "sysctl 配置已写入：$SYSCTL_FILE"
    log "limits 配置已写入：$LIMITS_FILE"
fi

# =============================================================================
#  加载内核模块 & 应用 sysctl
# =============================================================================
if [[ "$DRY_RUN" == false ]]; then
    header "加载内核模块"

    # BBR
    if [[ "$CC" == "bbr" || "$CC" == "bbr3" ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        echo "tcp_bbr" > /etc/modules-load.d/pt-bbr.conf
        log "tcp_bbr 模块已加载并设为开机自动加载"
    fi

    # 加载 fq 相关模块
    modprobe sch_fq     2>/dev/null && log "sch_fq 模块已加载"     || true
    modprobe sch_fq_codel 2>/dev/null && log "sch_fq_codel 模块已加载" || true

    header "应用 sysctl"
    sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "^#" | grep -v "^$" | \
        sed "s/^/  ${BLUE}→${NC} /"
    log "sysctl 参数已全部应用"
fi

# =============================================================================
#  配置 qdisc（立即生效 + 持久化）
# =============================================================================
header "配置网卡队列调度 (qdisc)"

apply_qdisc() {
    local nic=$1
    tc qdisc del dev "$nic" root 2>/dev/null || true

    if [[ "$QDISC" == "fq" ]]; then
        # flow_limit 200：每条流队列最多 200 个包，防单流霸占
        # quantum 9000：适配 9000 字节 Jumbo Frame（如网卡支持）
        #               普通 MTU 1500 的网卡会自动回退，填 9000 无害
        # initial_quantum：流建立初期允许突发的字节数
        # low_rate_threshold：低于此速率的流绕过 pacing，减少小流延迟
        tc qdisc add dev "$nic" root fq \
            flow_limit 200 \
            quantum 9000 \
            initial_quantum 15140 \
            low_rate_threshold 550000 \
            2>/dev/null || \
        tc qdisc add dev "$nic" root fq flow_limit 200
        log "已为 $nic 设置 fq qdisc"
    else
        tc qdisc add dev "$nic" root fq_codel
        log "已为 $nic 设置 fq_codel qdisc（回退）"
    fi

    # 打印当前 qdisc 状态
    info "当前 qdisc：$(tc qdisc show dev "$nic" | head -1)"
}

if [[ "$DRY_RUN" == false ]]; then
    apply_qdisc "$NIC"

    # 持久化（networkd-dispatcher 优先，没有则用 systemd service）
    PERSIST_DIR="/etc/networkd-dispatcher/routable.d"
    if [[ -d "$PERSIST_DIR" ]]; then
        cat > "${PERSIST_DIR}/99-pt-qdisc" << SCRIPT
#!/bin/sh
# PT Seedbox qdisc 持久化 - $(date '+%Y-%m-%d')
[ "\$IFACE" = "${NIC}" ] || exit 0
tc qdisc del dev ${NIC} root 2>/dev/null || true
tc qdisc add dev ${NIC} root ${QDISC} flow_limit 200 quantum 9000 initial_quantum 15140 2>/dev/null || \
tc qdisc add dev ${NIC} root ${QDISC}
SCRIPT
        chmod +x "${PERSIST_DIR}/99-pt-qdisc"
        log "qdisc 持久化：$PERSIST_DIR/99-pt-qdisc"
    else
        # 创建 systemd oneshot service 持久化
        cat > /etc/systemd/system/pt-qdisc.service << UNIT
[Unit]
Description=PT Seedbox qdisc setup
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "tc qdisc del dev ${NIC} root 2>/dev/null; tc qdisc add dev ${NIC} root ${QDISC} flow_limit 200 quantum 9000 initial_quantum 15140 2>/dev/null || tc qdisc add dev ${NIC} root ${QDISC}"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable pt-qdisc.service 2>/dev/null
        log "qdisc 持久化：systemd service pt-qdisc.service"
    fi
fi

# =============================================================================
#  NIC 硬件卸载优化（减少 CPU 处理网络的开销，让更多 CPU 给磁盘 I/O）
# =============================================================================
header "NIC 硬件卸载优化"

if [[ "$DRY_RUN" == false ]] && command -v ethtool &>/dev/null; then
    # GRO/GSO/TSO：合并小包/分段大包由网卡硬件完成，降低 CPU 中断频率
    for feature in gro gso tso; do
        ethtool -K "$NIC" $feature on 2>/dev/null && log "已开启 $NIC $feature" || warn "$NIC 不支持 $feature（跳过）"
    done

    # RX/TX ring buffer 调大（防止高速上传时网卡队列溢出丢包）
    MAX_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set maximums/,/Current/{if(/RX:/ && !/Jumbo/ && !/Mini/){print $2;exit}}')
    MAX_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set maximums/,/Current/{if(/TX:/{print $2;exit}}')
    if [[ -n "$MAX_RX" && "$MAX_RX" -gt 0 ]]; then
        ethtool -G "$NIC" rx "$MAX_RX" tx "${MAX_TX:-$MAX_RX}" 2>/dev/null && \
            log "已将 $NIC RX/TX ring buffer 设为最大值 $MAX_RX" || true
    fi

    # 持久化 NIC 设置
    NIC_PERSIST="/etc/networkd-dispatcher/routable.d/98-pt-nic"
    if [[ -d "/etc/networkd-dispatcher/routable.d" ]]; then
        cat > "$NIC_PERSIST" << SCRIPT
#!/bin/sh
# PT Seedbox NIC 优化持久化
[ "\$IFACE" = "${NIC}" ] || exit 0
ethtool -K ${NIC} gro on gso on tso on 2>/dev/null || true
ethtool -G ${NIC} rx ${MAX_RX:-4096} tx ${MAX_TX:-4096} 2>/dev/null || true
SCRIPT
        chmod +x "$NIC_PERSIST"
        log "NIC 优化已持久化：$NIC_PERSIST"
    fi
else
    [[ "$DRY_RUN" == true ]] && info "[DRY-RUN] 将优化 NIC 硬件卸载（GRO/GSO/TSO + ring buffer）"
fi

# =============================================================================
#  多队列 & CPU 中断亲和性（多核 CPU 高速网卡场景）
# =============================================================================
header "多队列 & 中断亲和性"

if [[ "$DRY_RUN" == false ]]; then
    # 检测网卡队列数量
    QUEUES=$(ls /sys/class/net/"$NIC"/queues/rx-* 2>/dev/null | wc -l || echo 1)
    info "网卡 RX 队列数：${BOLD}${QUEUES}${NC}"

    if [[ "$QUEUES" -gt 1 ]] && [[ "$CPU_CORES" -gt 1 ]]; then
        # 启用 RPS（Receive Packet Steering）：将 RX 处理分散到多核
        # 掩码：CPU 数量 → 例如 8 核 = 0xff
        RPS_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
        for f in /sys/class/net/"$NIC"/queues/rx-*/rps_cpus; do
            echo "$RPS_MASK" > "$f" 2>/dev/null && true
        done
        log "已启用 RPS，CPU 掩码：0x${RPS_MASK}"

        # XPS（Transmit Packet Steering）：TX 绑定到 CPU
        TX_QUEUES=$(ls /sys/class/net/"$NIC"/queues/tx-* 2>/dev/null | wc -l || echo 1)
        if [[ "$TX_QUEUES" -gt 1 ]]; then
            i=0
            for f in /sys/class/net/"$NIC"/queues/tx-*/xps_cpus; do
                MASK=$(printf '%x' $(( 1 << (i % CPU_CORES) )))
                echo "$MASK" > "$f" 2>/dev/null || true
                (( i++ )) || true
            done
            log "已配置 XPS：TX 队列绑定到各 CPU 核"
        fi
    else
        info "单队列网卡或单核 CPU，跳过中断亲和性配置"
    fi
else
    info "[DRY-RUN] 将配置 RPS/XPS 多队列中断亲和性"
fi

# =============================================================================
#  验证结果
# =============================================================================
header "验证当前配置"

echo ""
echo -e "${BOLD}  拥塞控制 & qdisc${NC}"
result "tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
result "default_qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
result "${NIC} qdisc" "$(tc qdisc show dev "$NIC" 2>/dev/null | awk '{print $2" "$3" "$4}' | head -1 || echo N/A)"

echo ""
echo -e "${BOLD}  TCP 缓冲区${NC}"
result "wmem_max" "$(( $(sysctl -n net.core.wmem_max 2>/dev/null || echo 0) / 1024 / 1024 )) MB"
result "rmem_max" "$(( $(sysctl -n net.core.rmem_max 2>/dev/null || echo 0) / 1024 / 1024 )) MB"
result "tcp_wmem (min/def/max)" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo N/A)"

echo ""
echo -e "${BOLD}  连接管理${NC}"
result "somaxconn" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo N/A)"
result "max_tw_buckets" "$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo N/A)"
result "tcp_tw_reuse" "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo N/A)"
result "tcp_fin_timeout" "$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo N/A) 秒"
result "slow_start_after_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo N/A)"

echo ""
echo -e "${BOLD}  文件描述符${NC}"
result "fs.file-max" "$(sysctl -n fs.file-max 2>/dev/null || echo N/A)"
result "当前进程 nofile (soft)" "$(ulimit -Sn 2>/dev/null || echo "重新登录后生效")"

echo ""
echo -e "${BOLD}  NIC 硬件卸载${NC}"
if command -v ethtool &>/dev/null; then
    for f in gro gso tso; do
        VAL=$(ethtool -k "$NIC" 2>/dev/null | awk -F': ' "/^${f}:/{print \$2}" || echo "unknown")
        result "$f" "$VAL"
    done
fi

# =============================================================================
#  完成
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│  网络调优完成  ·  ${LABEL}  │${NC}"
echo -e "${GREEN}${BOLD}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${YELLOW}注意事项：${NC}"
echo -e "  • ${BOLD}nofile 文件描述符限制${NC}需重新登录后对新进程生效"
echo -e "  • 回滚命令：${BOLD}sudo bash $0 --revert${NC}"
echo -e "  • 建议重启服务器使全部参数完整生效"
echo ""
echo -e "  ${CYAN}快速验证上传效果：${NC}"
echo -e "  ${BOLD}watch -n1 'ss -s; cat /proc/net/dev | grep ${NIC}'${NC}"
echo ""
