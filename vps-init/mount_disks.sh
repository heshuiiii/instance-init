#!/bin/bash
# =============================================================
# 批量挂载硬盘 — 自动发现裸盘，逐盘确认，集中预览后一次执行
# 用法：bash mount_disks.sh
# =============================================================

set -euo pipefail

MOUNT_BASE="/home"
FS_TYPE="ext4"
MOUNT_OPTS="defaults,noatime"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

# ── root 检查 ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "请以 root 身份运行。"; exit 1; }

# ── 自动扫描所有 disk 类型设备 ─────────────────────────────
echo ""
echo -e "${BOLD}════════════ 扫描可用硬盘 ════════════${NC}"
echo ""

mapfile -t ALL_DISKS < <(lsblk -dpno NAME,TYPE,SIZE,MOUNTPOINT \
    | awk '$2=="disk" {print $1, $3, $4}')

if [[ ${#ALL_DISKS[@]} -eq 0 ]]; then
    err "未发现任何磁盘设备，退出。"
    exit 1
fi

printf "  ${BOLD}%-12s %-8s %-12s %-20s${NC}\n" "设备" "大小" "状态" "说明"
printf "  %s\n" "──────────────────────────────────────────────────"
for entry in "${ALL_DISKS[@]}"; do
    DEV=$(echo "$entry" | awk '{print $1}')
    SZ=$(echo  "$entry" | awk '{print $2}')
    MP=$(echo  "$entry" | awk '{print $3}')
    CHILDREN=$(lsblk -no NAME "$DEV" | tail -n +2 | wc -l)
    if [[ -n "$MP" ]]; then
        printf "  %-12s %-8s " "$DEV" "$SZ"
        echo -e "${YELLOW}已挂载${NC}       跳过（系统盘）"
    elif [[ "$CHILDREN" -gt 0 ]]; then
        printf "  %-12s %-8s " "$DEV" "$SZ"
        echo -e "${YELLOW}有分区${NC}       可选"
    else
        printf "  %-12s %-8s " "$DEV" "$SZ"
        echo -e "${GREEN}裸盘${NC}         推荐挂载"
    fi
done
echo ""

# ── 逐盘确认，跳过系统盘 ───────────────────────────────────
echo -e "${BOLD}════════════ 逐盘确认挂载计划 ════════════${NC}"
echo ""

SELECTED_DEVS=()
DISK_COUNTER=1

for entry in "${ALL_DISKS[@]}"; do
    DEV=$(echo "$entry" | awk '{print $1}')
    SZ=$(echo  "$entry" | awk '{print $2}')
    MP=$(echo  "$entry" | awk '{print $3}')

    if [[ -n "$MP" ]]; then
        warn "${DEV} 已挂载于 ${MP}，自动跳过。"
        continue
    fi

    PROPOSED_MP="${MOUNT_BASE}/disk${DISK_COUNTER}"
    echo -e "  ${CYAN}${DEV}${NC}  (${SZ})  →  ${BOLD}${PROPOSED_MP}${NC}"
    read -rp "  加入挂载计划？[Y/n]: " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        SELECTED_DEVS+=("${DEV}:${PROPOSED_MP}")
        log "已加入 → ${PROPOSED_MP}"
        (( DISK_COUNTER++ ))
    else
        warn "跳过 ${DEV}。"
    fi
    echo ""
done

# ── 无选中则退出 ───────────────────────────────────────────
if [[ ${#SELECTED_DEVS[@]} -eq 0 ]]; then
    warn "未选择任何磁盘，退出。"
    exit 0
fi

# ── 集中展示执行计划，最终确认 ────────────────────────────
echo ""
echo -e "${BOLD}════════════ 执行计划预览 ════════════${NC}"
echo ""
printf "  ${BOLD}%-12s %-8s %-8s %-22s${NC}\n" "设备" "大小" "格式" "挂载点"
printf "  %s\n" "──────────────────────────────────────────────────"
for item in "${SELECTED_DEVS[@]}"; do
    DEV="${item%%:*}"
    MP="${item##*:}"
    SZ=$(lsblk -dno SIZE "$DEV")
    printf "  %-12s %-8s %-8s %-22s\n" "$DEV" "$SZ" "$FS_TYPE" "$MP"
done
echo ""
echo -e "  ${RED}${BOLD}⚠  以上磁盘将被格式化，原有数据不可恢复！${NC}"
echo ""
read -rp "  确认执行？输入大写 YES 开始，其他任意键退出: " FINAL
if [[ "$FINAL" != "YES" ]]; then
    err "已取消，未做任何修改。"
    exit 1
fi

# ── 备份 fstab ─────────────────────────────────────────────
FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/fstab "$FSTAB_BAK"
log "fstab 已备份 → ${FSTAB_BAK}"
echo ""

# ── 执行：格式化 → 挂载 → 写 fstab ───────────────────────
for item in "${SELECTED_DEVS[@]}"; do
    DEV="${item%%:*}"
    MP="${item##*:}"
    LABEL=$(basename "$MP")

    echo -e "${BOLD}── ${DEV} → ${MP} ──${NC}"

    # 若被占用先卸载
    if mount | grep -q "^${DEV} "; then
        warn "先卸载 ${DEV}..."
        umount "$DEV"
    fi

    info "清除旧签名 (wipefs)..."
    wipefs -a "$DEV" -f

    info "格式化为 ext4，卷标=${LABEL}..."
    mkfs.ext4 -F -L "$LABEL" "$DEV" -q

    UUID=$(blkid -s UUID -o value "$DEV")
    [[ -z "$UUID" ]] && { err "获取 UUID 失败，跳过 ${DEV}"; continue; }
    info "UUID: ${UUID}"

    mkdir -p "$MP"

    FSTAB_LINE="UUID=${UUID}  ${MP}  ${FS_TYPE}  ${MOUNT_OPTS}  0  2"
    if grep -q "UUID=${UUID}" /etc/fstab; then
        warn "UUID 已在 fstab，跳过写入。"
    else
        echo "$FSTAB_LINE" >> /etc/fstab
        info "写入 fstab: ${FSTAB_LINE}"
    fi

    mount "$MP"
    log "${DEV} 挂载成功 → ${MP}"
    echo ""
done

# ── 汇总结果 ───────────────────────────────────────────────
echo -e "${BOLD}════════════ 挂载结果汇总 ════════════${NC}"
echo ""
for item in "${SELECTED_DEVS[@]}"; do
    MP="${item##*:}"
    if mountpoint -q "$MP" 2>/dev/null; then
        df -h "$MP" | tail -1 | \
            awk -v mp="$MP" \
            '{printf "  \033[0;32m✔\033[0m  %-22s  大小:%-8s  已用:%-6s  可用:%s\n", mp, $2, $3, $4}'
    else
        echo -e "  ${RED}✘  ${MP} 未挂载${NC}"
    fi
done

echo ""
log "完成！已写入 fstab，重启后自动挂载。"
log "fstab 备份: ${FSTAB_BAK}"
