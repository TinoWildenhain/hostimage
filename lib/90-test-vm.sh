#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

IMAGES_DIR="${BUILD_DIR}/images"
SYSTEMROOT_RAW="${IMAGES_DIR}/systemroot.raw"
SWAP_RAW="${IMAGES_DIR}/swap.raw"
DATA_RAW="${IMAGES_DIR}/data.raw"

require_file "${SYSTEMROOT_RAW}"
require_file "${SWAP_RAW}"
require_file "${DATA_RAW}"

VM_NAME="${HOSTNAME}-test"
LIBVIRT_IMG_DIR="/var/lib/libvirt/images/${VM_NAME}"

log "Creating libvirt image directory: ${LIBVIRT_IMG_DIR}"
mkdir -p "${LIBVIRT_IMG_DIR}"

require_cmd qemu-img virt-install virsh

log "Converting .raw images to qcow2 for libvirt"
qemu-img convert -f raw -O qcow2 \
  "${SYSTEMROOT_RAW}" "${LIBVIRT_IMG_DIR}/systemroot.qcow2"

qemu-img convert -f raw -O qcow2 \
  "${SWAP_RAW}" "${LIBVIRT_IMG_DIR}/swap.qcow2"

qemu-img convert -f raw -O qcow2 \
  "${DATA_RAW}" "${LIBVIRT_IMG_DIR}/data.qcow2"

# --- Network setup ---

# Derive CIDR and base address from config NETWORK_ADDRESS, e.g. 10.26.4.155/22
CIDR="${NETWORK_ADDRESS##*/}"
BASE_IP="${NETWORK_ADDRESS%/*}"

# Compute network address and gateway for the libvirt NAT network
ip_to_int() {
  local IFS=.
  read -r a b c d <<<"$1"
  printf '%u\n' "$(( (a<<24) + (b<<16) + (c<<8) + d ))"
}

int_to_ip() {
  local ip=$1
  printf '%u.%u.%u.%u\n' \
    $(( (ip>>24) & 255 )) \
    $(( (ip>>16) & 255 )) \
    $(( (ip>>8)  & 255 )) \
    $(( ip & 255 ))
}

calc_net_and_gw() {
  local ip_int mask_int net_int
  ip_int=$(ip_to_int "$1")
  mask_int=$(( 0xFFFFFFFF << (32-CIDR) & 0xFFFFFFFF ))
  net_int=$(( ip_int & mask_int ))
  NET_ADDR=$(int_to_ip "$net_int")
  GW_ADDR=$(int_to_ip "$((net_int + 1))")
}

calc_net_and_gw "${BASE_IP}"

NET_ADDR="${NET_ADDR}"
GATEWAY="${GW_ADDR}"

# Generate a short, deterministic network name, e.g. 10-26-4-0-22
NET_NAME_CIDR="${NET_ADDR}/${CIDR}"
NET_NAME_BASE="$(echo "${NET_NAME_CIDR}" | tr './' '-')"
# Libvirt bridge name must be <=15 chars, but net name can be longer; we'll truncate bridge name
NET_NAME="${NET_NAME:-${NET_NAME_BASE}}"
TMP_XML="/tmp/libvirt-${NET_NAME}.xml"

cidr_to_netmask() {
  local cidr=$1
  local mask=
  local full_octets=$(( cidr / 8 ))
  local remaining_bits=$(( cidr % 8 ))
  local i octet

  for (( i=0; i<4; i++ )); do
    if (( i < full_octets )); then
      octet=255
    elif (( i == full_octets && remaining_bits > 0 )); then
      octet=$(( 256 - 2**(8-remaining_bits) ))
    else
      octet=0
    fi
    mask+=$octet
    [[ $i -lt 3 ]] && mask+=.
  done
  printf '%s\n' "$mask"
}

NETMASK=$(cidr_to_netmask "${CIDR}")

# Derive bridge name (truncate to 15 chars)
BRIDGE_NAME="virbr-${NET_NAME_BASE}"
BRIDGE_NAME="${BRIDGE_NAME:0:15}"

if ! virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
  log "Defining libvirt NAT network ${NET_NAME} (${NET_ADDR}/${CIDR}, gw ${GATEWAY}, bridge ${BRIDGE_NAME})"

  cat > "${TMP_XML}" <<EOF
<network>
  <name>${NET_NAME}</name>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='${GATEWAY}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${GATEWAY}' end='${NET_ADDR%.*}.254'/>
    </dhcp>
  </ip>
</network>
EOF

  virsh net-define "${TMP_XML}"
  rm -f "${TMP_XML}"
  virsh net-autostart "${NET_NAME}"
  virsh net-start "${NET_NAME}"
else
  log "Libvirt network ${NET_NAME} already exists; reusing"
fi

log "Creating VM ${VM_NAME} on libvirt network ${NET_NAME}"

virt-install \
  --name "${VM_NAME}" \
  --memory ${MEM_MB} \
  --vcpus ${VCPUS} \
  --disk path="${LIBVIRT_IMG_DIR}/systemroot.qcow2",bus=virtio \
  --disk path="${LIBVIRT_IMG_DIR}/swap.qcow2",bus=virtio \
  --disk path="${LIBVIRT_IMG_DIR}/data.qcow2",bus=virtio \
  --network network="${NET_NAME}",model=virtio \
  --boot firmware=efi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
  --os-variant ubuntu24.04 \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole \
  --import

log "Starting VM ${VM_NAME}"
virsh start "${VM_NAME}" || true

log "Attaching to console (Ctrl+] to detach)"
sleep 2
virsh console "${VM_NAME}"