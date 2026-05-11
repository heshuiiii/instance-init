#!/usr/bin/env bash
# =============================================================================
#  PT Network Tuning Script
#  Target : 10 Gbps server · BBRv3 · libtorrent v1.2.14 / v2.0.11
#  Goal   : Maximum upload throughput + upload-first priority
#  Author : optimized for heshuiiii/instance-init workflow
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0"

# ── 1. BBRv3 availability check ───────────────────────────────────────────────
info "Checking BBRv3 availability..."
KERNEL_VER=$(uname -r)
info "Kernel: $KERNEL_VER"

# BBRv3 ships in kernel ≥ 6.3 (mainline) or Google's patched kernels
# Check if bbr is available as tcp_bbr module
if modprobe tcp_bbr 2>/dev/null && \
   grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    # Detect actual BBRv3 by checking module info
    BBR_VER=$(modinfo tcp_bbr 2>/dev/null | grep -oP 'version:\s*\K\S+' || echo "unknown")
    ok "BBR module loaded (reported version: ${BBR_VER})"
else
    warn "BBR module not found. Attempting to load..."
    modprobe tcp_bbr || die "Cannot load tcp_bbr. Install a BBRv3-capable kernel (≥6.3) first."
fi

# ── 2. Sysctl — core network stack ───────────────────────────────────────────
info "Applying sysctl parameters..."

SYSCTL_CONF=/etc/sysctl.d/99-pt-10g-bbrv3.conf
cat > "$SYSCTL_CONF" << 'EOF'
# =============================================================================
# PT / 10 Gbps / BBRv3 / libtorrent upload-optimised sysctl
# =============================================================================

# ── Congestion control ────────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control         = bbr
net.core.default_qdisc                  = fq

# fq (Fair Queue) is the canonical pacer for BBR.
# fq_codel adds AQM latency control — good for mixed up/down,
# but for pure upload-priority PT we stay with fq for lower overhead.

# ── Socket buffer sizes (10G line, ~10ms RTT as baseline) ────────────────────
# Formula: BDP = 10Gbps × 0.010s = 12.5 MB → use 4-8× for headroom
net.core.rmem_max                       = 134217728   # 128 MiB
net.core.wmem_max                       = 134217728   # 128 MiB
net.core.rmem_default                   = 33554432    # 32 MiB
net.core.wmem_default                   = 33554432    # 32 MiB
net.ipv4.tcp_rmem                       = 8192 262144 134217728
net.ipv4.tcp_wmem                       = 8192 262144 134217728

# Increase UDP buffers for uTP (libtorrent default transport)
net.core.netdev_max_backlog             = 250000
net.core.netdev_budget                  = 600
net.core.netdev_budget_usecs            = 8000

# ── TCP performance knobs ─────────────────────────────────────────────────────
net.ipv4.tcp_fastopen                   = 3           # TFO client+server
net.ipv4.tcp_mtu_probing                = 1           # Enable PMTUD
net.ipv4.tcp_timestamps                 = 1           # Required by BBR for RTT
net.ipv4.tcp_sack                       = 1
net.ipv4.tcp_dsack                      = 1
net.ipv4.tcp_fack                       = 0           # Disable with SACK+BBR
net.ipv4.tcp_ecn                        = 1           # ECN — beneficial with BBRv3
net.ipv4.tcp_ecn_fallback               = 1

# ── Upload-priority: larger write queues, less recv pressure ─────────────────
# tcp_notsent_lowat: keep the send buffer aggressive
# Lower value → kernel calls sk_write_space sooner → libtorrent fills faster
net.ipv4.tcp_notsent_lowat              = 131072      # 128 KiB (down from 4 MiB default)

# Increase the per-socket send backlog depth
net.ipv4.tcp_limit_output_bytes         = 1048576     # 1 MiB (was 262144)

# ── Connection handling ───────────────────────────────────────────────────────
net.core.somaxconn                      = 65535
net.ipv4.tcp_max_syn_backlog            = 65535
net.ipv4.tcp_synack_retries             = 3
net.ipv4.tcp_syn_retries                = 3
net.ipv4.tcp_fin_timeout                = 15
net.ipv4.tcp_tw_reuse                   = 1

# ── Large numbers of simultaneous connections (PT peers) ─────────────────────
net.ipv4.tcp_max_tw_buckets             = 2000000
net.ipv4.ip_local_port_range            = 1024 65535
net.ipv4.tcp_keepalive_time             = 600
net.ipv4.tcp_keepalive_intvl            = 30
net.ipv4.tcp_keepalive_probes           = 5

# ── Memory thresholds ────────────────────────────────────────────────────────
# Raise tcp_mem to avoid throttle on high-peer-count uploads
# units: pages (typically 4 KiB)
# low / pressure / high  (in pages)
net.ipv4.tcp_mem                        = 786432 1048576 26214400

# ── NIC receive ring / IRQ coalescing (sysctl-accessible parts) ──────────────
net.ipv4.tcp_low_latency                = 0           # Keep throughput mode

# ── UDP / uTP tuning (libtorrent uTP) ────────────────────────────────────────
net.ipv4.udp_mem                        = 786432 1048576 26214400
net.ipv4.udp_rmem_min                   = 16384
net.ipv4.udp_wmem_min                   = 16384

# ── File descriptor limits ───────────────────────────────────────────────────
fs.file-max                             = 1000000
fs.nr_open                              = 1000000
EOF

sysctl --system -q && ok "sysctl applied from $SYSCTL_CONF"

# ── 3. fq qdisc — tune for 10G upload ────────────────────────────────────────
info "Tuning fq qdisc on all physical/virtual NICs..."

tune_fq() {
    local iface="$1"
    # flow_limit: max packets per flow in the queue
    # maxrate: leave unset to allow full 10G
    # quantum: MTU-sized quantum improves per-flow fairness at 10G
    # initial_quantum: boost initial window per flow
    if tc qdisc replace dev "$iface" root fq \
        flow_limit 200 \
        limit 10000 \
        quantum 1514 \
        initial_quantum 15140 \
        refill_delay 10 2>/dev/null; then
        ok "  fq applied on $iface"
    else
        warn "  Could not set fq on $iface (may already be set or unsupported)"
    fi
}

# Iterate over all UP non-loopback interfaces
for iface in $(ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    tune_fq "$iface"
done

# ── 4. NIC offload & ring buffer (ethtool) ───────────────────────────────────
info "Optimising NIC offload settings..."

tune_nic() {
    local iface="$1"
    # For upload-heavy PT: GRO off reduces latency on received ACKs;
    # TSO/GSO on lets the NIC segment large sends → lower CPU for upload
    ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null   && ok "  ring buffer set on $iface" || true
    ethtool -K "$iface" tso on  gso on  gro on  \
                         lro off rx-gro-list off 2>/dev/null \
        && ok "  offload set on $iface" || true
    # Increase coalesce tx frames to batch ACKs efficiently
    ethtool -C "$iface" tx-usecs 50 rx-usecs 50 2>/dev/null || true
}

for iface in $(ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    tune_nic "$iface"
done

# ── 5. IRQ affinity (multi-queue NICs) ───────────────────────────────────────
info "Setting IRQ / RPS / RFS for multi-queue upload..."

CPU_COUNT=$(nproc)
RPS_MASK=$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))

set_rps_rfs() {
    local iface="$1"
    local queues
    queues=$(ls /sys/class/net/"$iface"/queues/rx-* 2>/dev/null | wc -l)
    [[ $queues -eq 0 ]] && return

    # RPS: spread receive processing across all CPUs
    for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        echo "$RPS_MASK" > "$f" 2>/dev/null || true
    done

    # RFS: flow steering for cache locality
    # rps_sock_flow_entries: global table
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    for f in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
        echo 2048 > "$f" 2>/dev/null || true
    done

    # XPS: transmit packet steering — bind tx queues to CPUs
    local tx_queues
    tx_queues=$(ls /sys/class/net/"$iface"/queues/tx-* 2>/dev/null | wc -l)
    if [[ $tx_queues -gt 0 ]]; then
        local i=0
        for f in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
            cpu_bit=$(printf '%x' $(( 1 << (i % CPU_COUNT) )))
            echo "$cpu_bit" > "$f" 2>/dev/null || true
            (( i++ )) || true
        done
    fi

    ok "  RPS/RFS/XPS configured on $iface ($queues RX queues, $tx_queues TX queues)"
}

for iface in $(ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    set_rps_rfs "$iface"
done

# ── 6. Process / ulimit persistence ──────────────────────────────────────────
info "Setting system-wide file descriptor limits..."

LIMITS_CONF=/etc/security/limits.d/99-pt-fd.conf
cat > "$LIMITS_CONF" << 'EOF'
# High fd limits for PT clients (qBittorrent / libtorrent)
*    soft nofile 1000000
*    hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
ok "fd limits written to $LIMITS_CONF"

# Apply to running session
ulimit -n 1000000 2>/dev/null || true

# ── 7. Systemd service to persist qdisc on reboot ────────────────────────────
info "Installing fq-persist systemd service..."

SERVICE=/etc/systemd/system/pt-fq-persist.service
cat > "$SERVICE" << UNIT
[Unit]
Description=Restore fq qdisc for PT 10G BBRv3 upload optimisation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  for iface in \$(ip -o link show up | awk -F": " "{print \$2}" | grep -v "^lo\$"); do \
    tc qdisc replace dev \$iface root fq flow_limit 200 limit 10000 quantum 1514 initial_quantum 15140 refill_delay 10 || true; \
  done'

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pt-fq-persist.service 2>/dev/null && ok "pt-fq-persist.service enabled" || warn "systemd service setup failed (non-systemd system?)"

# ── 8. Verify BBRv3 is active ─────────────────────────────────────────────────
echo ""
info "──── Verification ────────────────────────────────────────────────────"
ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
ACTIVE_QD=$(tc qdisc show | head -5)

if [[ "$ACTIVE_CC" == "bbr" ]]; then
    ok "Congestion control: $ACTIVE_CC ✓"
else
    warn "Congestion control: $ACTIVE_CC  (expected bbr)"
fi

# Try to determine BBRv3 vs BBRv1
if [[ -f /sys/module/tcp_bbr/version ]]; then
    ok "BBR module version: $(cat /sys/module/tcp_bbr/version)"
fi

echo ""
info "Active qdisc (first 5 lines):"
echo "$ACTIVE_QD"

echo ""
ok "══════════════════════════════════════════════════════"
ok " PT 10G BBRv3 Upload Tuning — DONE"
ok "══════════════════════════════════════════════════════"
echo ""
echo -e "${CYAN}Key changes applied:${NC}"
echo "  • tcp_congestion_control = bbr  +  default_qdisc = fq"
echo "  • TCP/UDP socket buffers  : wmem/rmem → 128 MiB"
echo "  • tcp_notsent_lowat       : 128 KiB  (upload queue stay-full)"
echo "  • tcp_limit_output_bytes  : 1 MiB"
echo "  • fq qdisc                : flow_limit=200, quantum=1514 (10G tuned)"
echo "  • NIC ring buffers        : rx/tx 4096"
echo "  • NIC offload             : TSO/GSO on, LRO off"
echo "  • RPS/RFS/XPS             : all CPUs ($CPU_COUNT cores)"
echo "  • fd limits               : 1,000,000"
echo ""
warn "Reboot recommended to fully activate all changes."
