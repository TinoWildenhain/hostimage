#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="$1"
BUILD_DIR="$2"
CACHE_FILE="${BUILD_DIR}/.config.cache"

if [ ! -f "${CACHE_FILE}" ]; then
    exit 0
fi

# Helper to read a var from a file
get_var() {
    grep "^$1=" "$2" | cut -d= -f2-
}

OLD_PKGS=$(get_var "EXTRA_PACKAGES" "${CACHE_FILE}")
NEW_PKGS=$(get_var "EXTRA_PACKAGES" "${CONFIG_FILE}")

OLD_REL=$(get_var "OS_RELEASE" "${CACHE_FILE}")
NEW_REL=$(get_var "OS_RELEASE" "${CONFIG_FILE}")

if [ "$OLD_REL" != "$NEW_REL" ]; then
    echo "OS_RELEASE changed ($OLD_REL -> $NEW_REL). Forcing full rebuild."
    rm -rf "${BUILD_DIR}/systemroot"
    exit 0
fi

# Package logic:
# If packages added: We can technically continue, but cleaner to just invalidate package stage.
# If packages removed: We MUST invalidate package stage, and ideally debootstrap to be clean.
#   (apt-get autoremove might work, but debootstrap is safer for "clean image").

if [ "$OLD_PKGS" != "$NEW_PKGS" ]; then
    # Check if NEW contains everything in OLD (additions only)
    MISSING_PKGS=0
    for pkg in $OLD_PKGS; do
        if [[ "$NEW_PKGS" != *"$pkg"* ]]; then
            MISSING_PKGS=1
            break
        fi
    done

    if [ "$MISSING_PKGS" -eq 1 ]; then
        echo "Packages removed. Forcing full systemroot rebuild."
        rm -rf "${BUILD_DIR}/systemroot"
    else
        echo "Packages added only. Invalidating packages stage."
        # Remove the target for packages stage so Make reruns it
        rm -f "${BUILD_DIR}/systemroot/.stage_packages"
        # Also remove downstream stages
        rm -f "${BUILD_DIR}/systemroot/.stage_configure"
        rm -f "${BUILD_DIR}/systemroot/boot/efi/EFI/ubuntu/grubx64.efi"
    fi
fi
