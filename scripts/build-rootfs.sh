#!/usr/bin/env bash
# =============================================================================
#  宿主机构建脚本（跑在 GitHub Actions 的 arm64 原生 runner 上）
#  用 Docker 构建 Arch Linux ARM (aarch64) rootfs：
#    下载官方 rootfs -> docker import -> docker run 配置 -> docker export 打包
# =============================================================================
set -euo pipefail

ARCH="${ARCH:-aarch64}"
ROOTFS_TARBALL="ArchLinuxARM-${ARCH}-latest.tar.gz"
ROOTFS_URL="${ROOTFS_URL:-http://os.archlinuxarm.org/os/${ROOTFS_TARBALL}}"
IMAGE="arch-arm-build"
CONTAINER="arch-build"
OUT="${OUT:-arch-${ARCH}-rootfs.tar.gz}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }

# docker 命令选择（runner 用户在 docker 组则直接可用，否则 sudo）
DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# ---------------------------------------------------------------------------
# 1. 下载 Arch Linux ARM 官方 rootfs
# ---------------------------------------------------------------------------
log "下载 ${ROOTFS_URL}"
curl -fL --retry 3 --retry-delay 5 -o "${ROOTFS_TARBALL}" "${ROOTFS_URL}"
ls -lh "${ROOTFS_TARBALL}"

# ---------------------------------------------------------------------------
# 2. docker import：把官方 rootfs 变成镜像
# ---------------------------------------------------------------------------
log "docker import → ${IMAGE}"
${DOCKER} import "${ROOTFS_TARBALL}" "${IMAGE}:latest"

# ---------------------------------------------------------------------------
# 3. docker run：在容器内执行配置（容器有完整 /proc /sys /dev，规避 chroot 挂载问题）
# ---------------------------------------------------------------------------
log "docker run 配置"
${DOCKER} rm -f "${CONTAINER}" 2>/dev/null || true
${DOCKER} run --name "${CONTAINER}" \
  --dns 223.5.5.5 --dns 119.29.29.29 \
  -v "${SCRIPT_DIR}:/scripts:ro" \
  "${IMAGE}:latest" \
  /bin/bash /scripts/setup.sh

# ---------------------------------------------------------------------------
# 4. docker export：导出干净的文件系统并打包为 tar.gz
# ---------------------------------------------------------------------------
log "docker export → ${OUT}"
${DOCKER} export "${CONTAINER}" | gzip > "${OUT}"

# ---------------------------------------------------------------------------
# 5. 清理
# ---------------------------------------------------------------------------
${DOCKER} rm -f "${CONTAINER}" 2>/dev/null || true
${DOCKER} rmi "${IMAGE}:latest" 2>/dev/null || true
rm -f "${ROOTFS_TARBALL}"

ls -lh "${OUT}"
log "完成：$(pwd)/${OUT}"
