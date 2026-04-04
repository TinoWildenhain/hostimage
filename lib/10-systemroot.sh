#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
source "${CONFIG_FILE}"

SYSTEMROOT="${BUILD_DIR}/systemroot"

# If systemroot exists but we are running this, it might be a partial run or retry.
# Debootstrap refuses to run on non-empty dir usually.
if [ -d "${SYSTEMROOT}/bin" ]; then
    log "Systemroot appears populated. Skipping debootstrap (or run 'make clean' to force)."
    exit 0
fi

log "Creating systemroot directory: ${SYSTEMROOT}"
mkdir -p "${SYSTEMROOT}"

log "Running debootstrap for ${OS_RELEASE}"
debootstrap --arch=amd64 --variant=minbase "${OS_RELEASE}" "${SYSTEMROOT}" "${APT_MIRROR}"

log "Setting hostname"
echo "${HOSTNAME}" > "${SYSTEMROOT}/etc/hostname"

log "Configuring apt sources"
cat > "${SYSTEMROOT}/etc/apt/sources.list" <<EOF
deb ${APT_MIRROR} ${OS_RELEASE} main restricted universe multiverse
deb ${APT_MIRROR} ${OS_RELEASE}-updates main restricted universe multiverse
deb ${APT_MIRROR} ${OS_RELEASE}-security main restricted universe multiverse
EOF

log "Installing base system packages"
chroot "${SYSTEMROOT}" /bin/bash <<'EOBASE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    systemd-sysv \
    initramfs-tools \
    gnupg \
    wget \
    ca-certificates \
    apt-transport-https \
    locales

printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

locale-gen en_US.UTF-8 de_DE.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=
EOBASE

log "Systemroot stage complete"
