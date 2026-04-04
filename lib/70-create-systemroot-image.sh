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
SYSTEMROOT_RAW="${IMAGES_DIR}/systemroot.raw"

require_dir "${SYSTEMROOT}"
mkdir -p "${IMAGES_DIR}"

log "Creating systemroot.raw (${DISK_SIZE_GB}GB)"
qemu-img create -f raw "${SYSTEMROOT_RAW}" "${DISK_SIZE_GB}G"

LOOPDEV=$(losetup --show -f "${SYSTEMROOT_RAW}")
log "Attached to ${LOOPDEV}"

MNT="${BUILD_DIR}/mnt"
SWAP_LOOPDEV=""

cleanup() {
    sync
    # Unmount chroot bindings first
    umount "${MNT}/proc" 2>/dev/null || true
    umount "${MNT}/sys" 2>/dev/null || true
    umount "${MNT}/dev" 2>/dev/null || true
    # Then ESP and root
    umount "${MNT}/boot/efi" 2>/dev/null || true
    umount "${MNT}" 2>/dev/null || true

    # Deactivate VGs
    vgchange -an "${VG_NAME}" 2>/dev/null || true

    # Detach loop devices
    if [ -n "${SWAP_LOOPDEV}" ]; then
        losetup -d "${SWAP_LOOPDEV}" 2>/dev/null || true
    fi
    losetup -d "${LOOPDEV}" 2>/dev/null || true
}
trap cleanup EXIT

# GPT: ESP + LVM PV
parted -s "${LOOPDEV}" mklabel gpt
parted -s "${LOOPDEV}" mkpart ESP fat32 1MiB 513MiB
parted -s "${LOOPDEV}" set 1 boot on
parted -s "${LOOPDEV}" set 1 esp on
parted -s "${LOOPDEV}" mkpart primary 513MiB 100%
partprobe "${LOOPDEV}"
sleep 1

ESP_PART="${LOOPDEV}p1"
ROOT_PV="${LOOPDEV}p2"

# LVM setup
if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
    log "Found existing VG ${VG_NAME}, deactivating and removing it"
    vgchange -an "${VG_NAME}" || true
    vgremove -ff "${VG_NAME}" || true
fi

wipefs -a "${ROOT_PV}" || true
pvcreate "${ROOT_PV}"
vgcreate "${VG_NAME}" "${ROOT_PV}"
lvcreate -n root -L "${LV_ROOT_SIZE_GB}G" "${VG_NAME}"

# Filesystems (root FS type currently fixed ext4)
mkfs.vfat -F32 "${ESP_PART}"
mkfs.ext4 -L root "/dev/${VG_NAME}/root"

# Mount root & ESP of the image
mkdir -p "${MNT}"
mount "/dev/${VG_NAME}/root" "${MNT}"
mkdir -p "${MNT}/boot/efi"
mount "${ESP_PART}" "${MNT}/boot/efi"

log "Copying systemroot into image root (excluding EFI contents)"
rsync -aHAX --exclude='/boot/efi/*' "${SYSTEMROOT}/" "${MNT}/"

# Ensure /var and /home are empty mount points only
log "Preparing /var and /home as mount points (data disk will back them)"
rm -rf "${MNT}/var"/* 2>/dev/null || true
rm -rf "${MNT}/home"/* 2>/dev/null || true
mkdir -p "${MNT}/var" "${MNT}/home"

log "Generating fstab with data disk mounts"
ROOT_UUID=$(blkid -s UUID -o value "/dev/${VG_NAME}/root")

cat > "${MNT}/etc/fstab" <<EOF
UUID=${ROOT_UUID}   /           ext4   defaults,errors=remount-ro  0 1
/dev/${DATA_VG_NAME}/${LV_VAR_NAME}   /var    ${FS_VAR_TYPE:-ext4}   defaults  0 2
/dev/${DATA_VG_NAME}/${LV_HOME_NAME}  /home   ${FS_HOME_TYPE:-ext4}  defaults  0 2
EOF

# Swap: create swap.raw and append to fstab
SWAP_RAW="${IMAGES_DIR}/swap.raw"
log "Creating swap.raw (${LV_SWAP_SIZE_GB}GB)"
qemu-img create -f raw "${SWAP_RAW}" "${LV_SWAP_SIZE_GB}G"
SWAP_LOOPDEV=$(losetup --show -f "${SWAP_RAW}")
log "Attached swap.raw to ${SWAP_LOOPDEV}"

parted -s "${SWAP_LOOPDEV}" mklabel gpt
parted -s "${SWAP_LOOPDEV}" mkpart primary linux-swap 1MiB 100%
partprobe "${SWAP_LOOPDEV}"
sleep 1

SWAP_PART="${SWAP_LOOPDEV}p1"
mkswap "${SWAP_PART}"

SWAP_UUID=$(blkid -s UUID -o value "${SWAP_PART}")
echo "UUID=${SWAP_UUID} none swap sw 0 0" >> "${MNT}/etc/fstab"

log "Installing GRUB into systemroot.raw image"

# Bind-mount for chroot operations against the image root
mount --bind /dev "${MNT}/dev"
mount --bind /proc "${MNT}/proc"
mount --bind /sys "${MNT}/sys"

mkdir -p "${MNT}/boot/grub"
echo "(hd0) ${LOOPDEV}" > "${MNT}/boot/grub/device.map"

chroot "${MNT}" grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=ubuntu \
  --no-nvram \
  --recheck

# Fallback BOOTX64.EFI if grubx64.efi exists
if [ -e "${MNT}/boot/efi/EFI/ubuntu/grubx64.efi" ]; then
    mkdir -p "${MNT}/boot/efi/EFI/BOOT"
    cp "${MNT}/boot/efi/EFI/ubuntu/grubx64.efi" \
       "${MNT}/boot/efi/EFI/BOOT/BOOTX64.EFI"
fi

chroot "${MNT}" update-grub || log "update-grub inside image failed (check manually)"

# Image version marker for first-boot sync + OVA logic
mkdir -p "${MNT}/var"
cat > "${MNT}/var/.image_version" <<EOF
IMAGE_HOSTNAME=${HOSTNAME}
IMAGE_OS_RELEASE=${OS_RELEASE}
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "systemroot.raw (and swap.raw) image creation complete"