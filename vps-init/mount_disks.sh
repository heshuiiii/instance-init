#!/bin/bash
# =============================================================
# 批量格式化并挂载硬盘到 /home/disk{N}，写入 /etc/fstab 永久生效
# 适用环境：4块裸盘 sda/sdb/sdc/sdd，文件系统 ext4
# 使用方法：chmod +x mount_disks.sh && bash mount_disks.sh
# 警告：此脚本会格式化硬盘，所有数据将被清除！
# =============================================================

set -euo pipefail

# -------- 配置区（按需修改） --------
DISKS=(sda sdb sdc sdd)
MOUNT_BASE="/home"
FS_TYPE="ext4"
MKFS_OPTS="-F -L"          # -F 强制格式化，-L 设置卷标
MOUNT_OPTS="defaults,noatime"
# ------------------------------------

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# -------- 安全确认 --------
echo -e "${RED}"
echo "  ██████╗  █████╗ ███╗   ██╗ ██████╗ ███████╗██████╗ "
echo "  ██╔══██╗██╔══██╗████╗  ██║██╔════╝ ██╔════╝██╔══██╗"
echo "  ██║  ██║███████║██╔██╗ ██║██║  ███╗█████╗  ██████╔╝"
echo "  ██║  ██║██╔══██║██║╚██╗██║██║   ██║██╔══╝  ██╔══██╗"
echo "  ██████╔╝██║  ██║██║ ╚████║╚██████╔╝███████╗██║  ██║"
echo "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝"
echo -e "${NC}"
warn "此操作将格式化以下硬盘，数据无法恢复："
for i in "${!DISKS[@]}"; do
    echo "    /dev/${DISKS[$i]}  -->  ${MOUNT_BASE}/disk$((i+1))"
done
echo ""
read -rp "确认继续？输入大写 YES 继续，其他任意键退出: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    err "操作已取消。"
    exit 1
fi

# -------- 检查 root 权限 --------
if [[ $EUID -ne 0 ]]; then
    err "请以 root 身份运行此脚本。"
    exit 1
fi

# -------- 备份 fstab --------
FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/fstab "$FSTAB_BAK"
log "已备份 /etc/fstab -> $FSTAB_BAK"

# -------- 主循环 --------
for i in "${!DISKS[@]}"; do
    DISK="/dev/${DISKS[$i]}"
    LABEL="disk$((i+1))"
    MOUNTPOINT="${MOUNT_BASE}/${LABEL}"

    echo ""
    log "========== 处理 ${DISK} -> ${MOUNTPOINT} =========="

    # 检查硬盘是否存在
    if [[ ! -b "$DISK" ]]; then
        err "${DISK} 不存在，跳过。"
        continue
    fi

    # 检查硬盘是否已挂载
    if mount | grep -q "^${DISK}"; then
        warn "${DISK} 当前已挂载，先卸载..."
        umount "${DISK}" || { err "卸载 ${DISK} 失败，跳过。"; continue; }
    fi

    # 清除分区表（可选，确保干净）
    log "清除 ${DISK} 分区表..."
    wipefs -a "${DISK}"

    # 格式化
    log "格式化 ${DISK} 为 ${FS_TYPE}，卷标: ${LABEL}..."
    mkfs.${FS_TYPE} ${MKFS_OPTS} "${LABEL}" "${DISK}"

    # 获取 UUID
    UUID=$(blkid -s UUID -o value "${DISK}")
    if [[ -z "$UUID" ]]; then
        err "无法获取 ${DISK} 的 UUID，跳过。"
        continue
    fi
    log "UUID: ${UUID}"

    # 创建挂载点
    if [[ ! -d "$MOUNTPOINT" ]]; then
        mkdir -p "$MOUNTPOINT"
        log "创建挂载点: ${MOUNTPOINT}"
    fi

    # 写入 fstab（去重，避免重复写入）
    FSTAB_ENTRY="UUID=${UUID}  ${MOUNTPOINT}  ${FS_TYPE}  ${MOUNT_OPTS}  0  2"
    if grep -q "UUID=${UUID}" /etc/fstab; then
        warn "UUID=${UUID} 已存在于 fstab，跳过写入。"
    else
        echo "${FSTAB_ENTRY}" >> /etc/fstab
        log "已写入 fstab: ${FSTAB_ENTRY}"
    fi

    # 挂载
    mount "${MOUNTPOINT}"
    log "${DISK} 挂载成功 -> ${MOUNTPOINT}"
done

# -------- 验证结果 --------
echo ""
log "========== 挂载结果 =========="
for i in "${!DISKS[@]}"; do
    LABEL="disk$((i+1))"
    MOUNTPOINT="${MOUNT_BASE}/${LABEL}"
    if mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        df -h "${MOUNTPOINT}" | tail -1 | awk -v mp="${MOUNTPOINT}" \
            '{printf "  ✓ %-20s  大小:%-8s  已用:%-8s  可用:%s\n", mp, $2, $3, $4}'
    else
        echo -e "  ${RED}✗ ${MOUNTPOINT} 未挂载${NC}"
    fi
done

echo ""
log "全部完成！fstab 备份位于: ${FSTAB_BAK}"
log "可用 'mount -a' 验证 fstab 配置，或重启后确认自动挂载。"
