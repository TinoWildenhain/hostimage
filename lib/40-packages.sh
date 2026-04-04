#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

SYSTEMROOT="$(realpath "${BUILD_DIR}/systemroot")"
require_dir "${SYSTEMROOT}"

log "Installing kernel and packages into chroot ${SYSTEMROOT}"

# Guest tools selection
EXTRA_GUEST_PKGS="open-vm-tools"
if [[ "${INSTALL_KVM_TOOLS:-false}" == "true" ]]; then
    EXTRA_GUEST_PKGS="${EXTRA_GUEST_PKGS} qemu-guest-agent"
fi

mount_chroot() {
    mount --bind /proc "${SYSTEMROOT}/proc"
    mount --bind /sys  "${SYSTEMROOT}/sys"
    mount --bind /dev  "${SYSTEMROOT}/dev"
}

unmount_chroot() {
    umount "${SYSTEMROOT}/proc" 2>/dev/null || true
    umount "${SYSTEMROOT}/sys"  2>/dev/null || true
    umount "${SYSTEMROOT}/dev"  2>/dev/null || true
}

trap unmount_chroot EXIT
mount_chroot

chroot "${SYSTEMROOT}" /bin/bash <<'EOSH'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

# Make sure APT is up to date
apt-get update -y

echo "[40-packages] Installing base packages"

apt-get install --no-install-recommends -y \
  linux-image-virtual \
  grub-efi-amd64 \
  efibootmgr \
  sudo \
  curl \
  wget \
  openssh-server \
  systemd-resolved \
  systemd-timesyncd \
  zstd
EOSH

# Install guest tools and extras in a second chroot with config-expanded vars
chroot "${SYSTEMROOT}" /bin/bash <<EOSH2
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

if [ -n "${EXTRA_GUEST_PKGS}" ]; then
    echo "[40-packages] Installing guest packages: ${EXTRA_GUEST_PKGS}"
    apt-get install -y ${EXTRA_GUEST_PKGS}
fi

if [ -n "${EXTRA_PACKAGES:-}" ]; then
    echo "[40-packages] Installing EXTRA_PACKAGES: ${EXTRA_PACKAGES}"
    apt-get install -y ${EXTRA_PACKAGES}
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
EOSH2

log "Package installation complete"
