#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
source "${CONFIG_FILE}"

SYSTEMROOT="$(realpath "${BUILD_DIR}/systemroot")"
require_dir "${SYSTEMROOT}"

log "Configure stage (customizing final image)"

if [ -n "${APT_PROXY:-}" ]; then
    log "Configuring APT proxy (to be used after installation): ${APT_PROXY}"
    cat > "${SYSTEMROOT}/etc/apt/apt.conf.d/01proxy" <<EOF
Acquire::http::Proxy "${APT_PROXY}";
Acquire::https::Proxy "${APT_HTTPS_PROXY:-$APT_PROXY}";
EOF
fi

log "Linking resolv.conf to systemd-resolved for final image boot"
ln -sf ../run/systemd/resolve/stub-resolv.conf "${SYSTEMROOT}/etc/resolv.conf"

log "Configure stage complete"
