#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
source "${CONFIG_FILE}"

# Convert to absolute path to guarantee the unmount trap always works
SYSTEMROOT="$(realpath "${BUILD_DIR}/systemroot")"
require_dir "${SYSTEMROOT}"

log "Configuring chroot in ${SYSTEMROOT} to be bootable"

# Ensure /boot/efi exists in chroot (mounted later when creating the image)
mkdir -p "${SYSTEMROOT}/boot/efi"

# Generate initramfs and grub.cfg inside the chroot
mount --bind /dev  "${SYSTEMROOT}/dev"
mount --bind /proc "${SYSTEMROOT}/proc"
mount --bind /sys  "${SYSTEMROOT}/sys"

chroot_cleanup() {
    umount "${SYSTEMROOT}/sys"  2>/dev/null || true
    umount "${SYSTEMROOT}/proc" 2>/dev/null || true
    umount "${SYSTEMROOT}/dev"  2>/dev/null || true
}
trap chroot_cleanup EXIT

# Force visible serial + VGA console and verbose boot for test images
mkdir -p "${SYSTEMROOT}/etc/default/grub.d"
cat > "${SYSTEMROOT}/etc/default/grub.d/99-custom.cfg" <<'EOF'
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_RECORDFAIL_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200 console=tty1 systemd.log_level=debug systemd.log_target=console"
GRUB_TERMINAL_OUTPUT=console
EOF

# Disable unwanted grub extensions without changing directory
for f in 20_linux_xen 25_bli 30_os-prober 30_uefi-firmware 10_linux_zfs; do
    if [ -f "${SYSTEMROOT}/etc/grub.d/$f" ]; then
        chmod -x "${SYSTEMROOT}/etc/grub.d/$f" || true
    fi
done

# Optional: minimal theme (plain colors)
cat > "${SYSTEMROOT}/etc/grub.d/05_debian_theme" <<'EOF'
#!/bin/sh
set_menu_color_normal=white/black
set_menu_color_highlight=black/light-gray
EOF
chmod +x "${SYSTEMROOT}/etc/grub.d/05_debian_theme"

log "Running update-initramfs and update-grub in chroot"
chroot "${SYSTEMROOT}" update-initramfs -u || true
chroot "${SYSTEMROOT}" update-grub || fail "update-grub inside chroot failed"

log "Chroot boot configuration completed"
