#!/usr/bin/env bash
# =============================================================================
#  宿主机构建脚本（跑在 GitHub Actions 的 arm64 原生 runner 上）
#  用 debootstrap 原生构建 Ubuntu 26.04.1 arm64 rootfs，chroot 配置后打包为 tar.gz
# =============================================================================
set -euo pipefail

RELEASE="${RELEASE:-resolute}"
VERSION="${VERSION:-26.04.1}"
ARCH="${ARCH:-arm64}"
# 构建期镜像：EC2 us-east-2；
# 最终 rootfs 会在 chroot-setup.sh 结尾改回中科大源。
MIRROR="${MIRROR:-http://us-east-2.ec2.archive.ubuntu.com/ubuntu}"
ROOTFS_DIR="${ROOTFS_DIR:-rootfs}"
OUT="${OUT:-ubuntu-${VERSION}-${ARCH}-rootfs.tar.gz}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. 确保 debootstrap 识别 resolute 套件（新版 Ubuntu 的脚本都是 gutsy 的符号链接）
# ---------------------------------------------------------------------------
if [ ! -e "/usr/share/debootstrap/scripts/${RELEASE}" ]; then
  log "为 debootstrap 添加 ${RELEASE} 套件脚本（-> gutsy）"
  sudo ln -sf gutsy "/usr/share/debootstrap/scripts/${RELEASE}"
fi

# ---------------------------------------------------------------------------
# 2. 第一阶段：下载并解包基础系统（宿主侧执行）
#    说明：--no-check-gpg 仅跳过“下载阶段”的签名校验（runner 自带的 keyring 通常不含
#    26.04 密钥）；chroot 内部随后会安装正确版本的 ubuntu-keyring，后续 apt 全程校验签名。
# ---------------------------------------------------------------------------
sudo rm -rf "${ROOTFS_DIR}"
log "debootstrap --foreign ${RELEASE} (${ARCH})  <==  ${MIRROR}"
sudo debootstrap \
  --arch="${ARCH}" \
  --foreign \
  --no-check-gpg \
  --include=ca-certificates \
  --components=main,universe,restricted,multiverse \
  "${RELEASE}" "${ROOTFS_DIR}" "${MIRROR}"

# ---------------------------------------------------------------------------
# 3. 第二阶段：在 chroot 内完成基础系统安装（arm64 原生执行）
#    关键：必须放在“挂载虚拟文件系统”之前——debootstrap 的 second-stage 会自行
#    挂载并卸载 /proc，若提前挂载会被它卸载，导致后续 systemd postinst 报
#    “/proc is not mounted / Cannot open /etc/machine-id ... Function not implemented”。
# ---------------------------------------------------------------------------
log "debootstrap --second-stage"
sudo chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage

# ---------------------------------------------------------------------------
# 4. 挂载虚拟文件系统（务必在 second-stage 之后）
#    受限 mount namespace 下 mount -t proc 可能静默失败，故加 bind 挂载回退。
# ---------------------------------------------------------------------------
sudo mkdir -p "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev/pts"
log "挂载 /proc /sys /dev /dev/pts"

mount_vfs() {
  local target="$1" fstype="$2" devsrc="$3" bindsrc="$4"
  if ! mountpoint -q "${ROOTFS_DIR}${target}" 2>/dev/null; then
    sudo mount -t "${fstype}" "${devsrc}" "${ROOTFS_DIR}${target}" 2>/dev/null \
      || sudo mount -o bind "${bindsrc}" "${ROOTFS_DIR}${target}" 2>/dev/null \
      || true
  fi
}
mount_vfs /proc     proc   proc   /proc
mount_vfs /sys      sysfs  sysfs  /sys
mount_vfs /dev/pts  devpts devpts /dev/pts
sudo mount -o bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true

sudo cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

# 校验 /proc 是否真的可访问，便于早发现问题
if [ ! -e "${ROOTFS_DIR}/proc/self" ]; then
  log "警告：/proc 挂载似乎未生效，chroot 内 systemd 可能报错"
fi

cleanup() {
  sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/dev"      2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/sys"      2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/proc"     2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 5. 复制配置脚本并执行（安装软件 / 用户 / SSH / systemd / zsh / nvm / dsh）
# ---------------------------------------------------------------------------
log "复制 chroot 配置脚本"
sudo cp "${SCRIPT_DIR}/chroot-setup.sh" "${ROOTFS_DIR}/root/setup.sh"
sudo chmod 0755 "${ROOTFS_DIR}/root/setup.sh"

log "运行 chroot 配置（这一步较久，包含 npm 安装 dsh）"
sudo chroot "${ROOTFS_DIR}" /bin/bash /root/setup.sh

# ---------------------------------------------------------------------------
# 6. 清理 + 打包
# ---------------------------------------------------------------------------
log "清理临时文件"
sudo rm -rf "${ROOTFS_DIR}/debootstrap"

cleanup
trap - EXIT

log "打包 ${OUT}"
sudo tar -C "${ROOTFS_DIR}" --numeric-owner --xattrs -cpzf "${OUT}" .
ls -lh "${OUT}"
log "完成：$(pwd)/${OUT}"
