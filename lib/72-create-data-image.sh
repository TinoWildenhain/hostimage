#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
source "${CONFIG_FILE}"

SYSTEMROOT="${BUILD_DIR}/systemroot"
IMAGES_DIR="${BUILD_DIR}/images"
DATA_RAW="${IMAGES_DIR}/data.raw"

require_dir "${SYSTEMROOT}"
mkdir -p "${IMAGES_DIR}"

FS_VAR_TYPE="${FS_VAR_TYPE:-ext4}"
FS_HOME_TYPE="${FS_HOME_TYPE:-ext4}"

log "Creating data.raw (${DATA_DISK_SIZE_GB}GB)"

qemu-img create -f raw "${DATA_RAW}" "${DATA_DISK_SIZE_GB}G"

LOOPDEV=$(losetup --show -f "${DATA_RAW}")
log "Attached to ${LOOPDEV}"

cleanup() {
    sync
    umount "${BUILD_DIR}/mnt_data/var" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt_data/home" 2>/dev/null || true
    vgchange -an "${DATA_VG_NAME}" 2>/dev/null || true
    losetup -d "${LOOPDEV}" 2>/dev/null || true
}
trap cleanup EXIT

# Partition and LVM
parted -s "${LOOPDEV}" mklabel gpt
parted -s "${LOOPDEV}" mkpart primary 1MiB 100%
partprobe "${LOOPDEV}"
sleep 1

DATA_PV="${LOOPDEV}p1"

pvcreate "${DATA_PV}"
vgcreate "${DATA_VG_NAME}" "${DATA_PV}"
lvcreate -n "${LV_VAR_NAME}"  -L "${LV_VAR_SIZE_GB}G"  "${DATA_VG_NAME}"
lvcreate -n "${LV_HOME_NAME}" -L "${LV_HOME_SIZE_GB}G" "${DATA_VG_NAME}"

# Format /var LV
log "Creating /var filesystem (${FS_VAR_TYPE}) on /dev/${DATA_VG_NAME}/${LV_VAR_NAME}"
case "${FS_VAR_TYPE}" in
  ext4)
    mkfs.ext4 -F "/dev/${DATA_VG_NAME}/${LV_VAR_NAME}"
    ;;
  xfs)
    mkfs.xfs -f "/dev/${DATA_VG_NAME}/${LV_VAR_NAME}"
    ;;
  btrfs)
    mkfs.btrfs -f "/dev/${DATA_VG_NAME}/${LV_VAR_NAME}"
    ;;
  *)
    fail "Unsupported FS_VAR_TYPE='${FS_VAR_TYPE}'. Use ext4, xfs, or btrfs."
    ;;
esac

# Format /home LV
log "Creating /home filesystem (${FS_HOME_TYPE}) on /dev/${DATA_VG_NAME}/${LV_HOME_NAME}"
case "${FS_HOME_TYPE}" in
  ext4)
    mkfs.ext4 -F "/dev/${DATA_VG_NAME}/${LV_HOME_NAME}"
    ;;
  xfs)
    mkfs.xfs -f "/dev/${DATA_VG_NAME}/${LV_HOME_NAME}"
    ;;
  btrfs)
    mkfs.btrfs -f "/dev/${DATA_VG_NAME}/${LV_HOME_NAME}"
    ;;
  *)
    fail "Unsupported FS_HOME_TYPE='${FS_HOME_TYPE}'. Use ext4, xfs, or btrfs."
    ;;
esac

# Mount and copy /var and /home from systemroot
MNT="${BUILD_DIR}/mnt_data"
mkdir -p "${MNT}/var" "${MNT}/home"

mount "/dev/${DATA_VG_NAME}/${LV_VAR_NAME}"  "${MNT}/var"
mount "/dev/${DATA_VG_NAME}/${LV_HOME_NAME}" "${MNT}/home"

log "Copying /var from systemroot to data disk"
rsync -aHAX "${SYSTEMROOT}/var/"  "${MNT}/var/"

log "Copying /home from systemroot to data disk"
rsync -aHAX "${SYSTEMROOT}/home/" "${MNT}/home/"

# Create marker for first-boot sync script
cat > "${MNT}/var/.image_version" <<EOF
IMAGE_HOSTNAME=${HOSTNAME}
IMAGE_OS_RELEASE=${OS_RELEASE}
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Create marker to indicate data disk was created/updated in this run
if [ -f "${MNT}/var/.image_version" ]; then
    cp "${MNT}/var/.image_version" "${BUILD_DIR}/.image_version"
fi

log "data.raw created and populated successfully"