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

log "Configuring system settings"

# Ensure SSH config path exists
mkdir -p "${SYSTEMROOT}/etc/ssh"
if [ ! -f "${SYSTEMROOT}/etc/ssh/sshd_config" ]; then
    touch "${SYSTEMROOT}/etc/ssh/sshd_config"
fi

log "Configuring SSH hardening"
cat >> "${SYSTEMROOT}/etc/ssh/sshd_config" <<'EOSSH'
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOSSH

log "Configuring network interface naming"
mkdir -p "${SYSTEMROOT}/etc/systemd/network"
cat > "${SYSTEMROOT}/etc/systemd/network/10-eth0.link" <<'EOLINK'
[Match]
Type=ether

[Link]
NamePolicy=
Name=eth0
EOLINK

log "Configuring systemd-networkd"
addr="${NETWORK_ADDRESS%/*}"
prefix="${NETWORK_ADDRESS#*/}"

cat > "${SYSTEMROOT}/etc/systemd/network/10-${NETWORK_IFACE}.network" <<EOF
[Match]
Name=${NETWORK_IFACE}

[Network]
EOF

if [[ "${NETWORK_USE_DHCP}" == "true" ]]; then
    echo "DHCP=yes" >> "${SYSTEMROOT}/etc/systemd/network/10-${NETWORK_IFACE}.network"
else
    cat >> "${SYSTEMROOT}/etc/systemd/network/10-${NETWORK_IFACE}.network" <<EOF
Address=${addr}/${prefix}
Gateway=${NETWORK_GATEWAY}
EOF
    for dns in ${NETWORK_DNS}; do
        echo "DNS=${dns}" >> "${SYSTEMROOT}/etc/systemd/network/10-${NETWORK_IFACE}.network"
    done
fi

chroot "${SYSTEMROOT}" systemctl enable systemd-networkd.service || true
chroot "${SYSTEMROOT}" systemctl enable systemd-resolved.service systemd-timesyncd.service || true

log "Enabling tmpfs for /tmp (required for read-only root)"
chroot "${SYSTEMROOT}" cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
chroot "${SYSTEMROOT}" systemctl enable tmp.mount || true

log "Installing first-boot /var sync script"
mkdir -p "${SYSTEMROOT}/usr/local/sbin"
mkdir -p "${SYSTEMROOT}/usr/local/share"

cat > "${SYSTEMROOT}/usr/local/sbin/sync-var-home.sh" <<'EOSYNC'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/sync-var-home.log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

log "Syncing /var structure from image"

PRISTINE_VAR_TGZ="/usr/local/share/pristine-var.tgz"

if [ ! -f /var/.image_version ] || [ ! -f "${PRISTINE_VAR_TGZ}" ]; then
    exit 0
fi

tar xzf "${PRISTINE_VAR_TGZ}" -C / --keep-newer-files \
    --exclude='./lib/postgresql' \
    --exclude='./lib/postgresql/*' \
    --exclude='./lib/postgresql/16/main' \
    >> "${LOG_FILE}" 2>&1 || true

EOSYNC

chmod +x "${SYSTEMROOT}/usr/local/sbin/sync-var-home.sh"

log "Creating systemd unit for var sync"
cat > "${SYSTEMROOT}/etc/systemd/system/sync-var-home.service" <<'EOUNIT'
[Unit]
Description=Sync /var and /home from image updates
After=local-fs.target
Before=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-var-home.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOUNIT

chroot "${SYSTEMROOT}" systemctl enable sync-var-home.service

log "Writing /etc/hosts"
cat > "${SYSTEMROOT}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

log "System configuration complete"
