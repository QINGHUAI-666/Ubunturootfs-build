#!/usr/bin/env bash
# =============================================================================
#  宿主机构建脚本（跑在 GitHub Actions 的 amd64 runner 上）
#  用 debootstrap 交叉构建 Ubuntu 26.04.1 arm64 rootfs，chroot 配置后打包为 tar.gz
# =============================================================================
set -euo pipefail

RELEASE="${RELEASE:-resolute}"
VERSION="${VERSION:-26.04.1}"
ARCH="${ARCH:-arm64}"
# 构建期镜像：EC2 us-east-2（与 GitHub runner 同区域，下载快）；
# 最终 rootfs 会在 chroot-setup.sh 结尾改回中科大源。
MIRROR="${MIRROR:-http://us-east-2.ec2.archive.ubuntu.com/ubuntu}"
ROOTFS_DIR="${ROOTFS_DIR:-rootfs}"
OUT="${OUT:-ubuntu-${VERSION}-${ARCH}-rootfs.tar.gz}"
QEMU_BIN="/usr/bin/qemu-aarch64-static"

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
# 2. 第一阶段：下载并解包基础系统（宿主侧执行，无需 QEMU）
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
# 3. 准备 QEMU 静态二进制（binfmt 未用 F 标志时，chroot 内需要它）
# ---------------------------------------------------------------------------
if [ ! -f "${QEMU_BIN}" ]; then
  log "安装 qemu-user-static"
  sudo apt-get install -y qemu-user-static
fi
log "复制 qemu-aarch64-static 到 rootfs"
sudo mkdir -p "${ROOTFS_DIR}/usr/bin"
sudo cp "${QEMU_BIN}" "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# ---------------------------------------------------------------------------
# 4. 挂载虚拟文件系统
# ---------------------------------------------------------------------------
sudo mkdir -p "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev/pts"
log "挂载 /proc /sys /dev /dev/pts"
sudo mount -t proc  /proc  "${ROOTFS_DIR}/proc"
sudo mount -t sysfs /sys   "${ROOTFS_DIR}/sys"
sudo mount -o bind  /dev   "${ROOTFS_DIR}/dev"
sudo mount -t devpts devpts "${ROOTFS_DIR}/dev/pts"
sudo cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

cleanup() {
  sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/dev"      2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/sys"      2>/dev/null || true
  sudo umount -l "${ROOTFS_DIR}/proc"     2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 5. 第二阶段：在 chroot 内完成基础系统安装（arm64 二进制经 QEMU 执行）
# ---------------------------------------------------------------------------
log "debootstrap --second-stage"
sudo chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage

# ---------------------------------------------------------------------------
# 6. 复制配置脚本并执行（安装软件 / 用户 / SSH / systemd / zsh / nvm / dsh）
# ---------------------------------------------------------------------------
log "复制 chroot 配置脚本"
sudo cp "${SCRIPT_DIR}/chroot-setup.sh" "${ROOTFS_DIR}/root/setup.sh"
sudo chmod 0755 "${ROOTFS_DIR}/root/setup.sh"

log "运行 chroot 配置（这一步较久，包含 npm 安装 dsh）"
sudo chroot "${ROOTFS_DIR}" /bin/bash /root/setup.sh

# ---------------------------------------------------------------------------
# 7. 清理 + 打包
# ---------------------------------------------------------------------------
log "清理临时文件"
sudo rm -f "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"
sudo rm -rf "${ROOTFS_DIR}/debootstrap"

cleanup
trap - EXIT

log "打包 ${OUT}"
sudo tar -C "${ROOTFS_DIR}" --numeric-owner --xattrs -cpzf "${OUT}" .
ls -lh "${OUT}"
log "完成：$(pwd)/${OUT}"
