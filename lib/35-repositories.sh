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

log "Adding extra repositories from templates..."

# Defaults
REPO_TEMPLATE_DIR="${REPO_TEMPLATE_DIR:-template/etc/apt}"

if [ -z "${EXTRA_REPOSITORIES:-}" ]; then
    log "EXTRA_REPOSITORIES not set. Skipping repository templates."
    exit 0
fi

if [ ! -d "${REPO_TEMPLATE_DIR}" ]; then
    log "Repository template dir ${REPO_TEMPLATE_DIR} does not exist. Skipping."
    exit 0
fi

SRC_SOURCES_DIR="${REPO_TEMPLATE_DIR}/sources.list.d"
SRC_KEYRINGS_DIR="${REPO_TEMPLATE_DIR}/keyrings"

DEST_SOURCES_DIR="${SYSTEMROOT}/etc/apt/sources.list.d"
DEST_KEYRINGS_DIR="${SYSTEMROOT}/etc/apt/keyrings"

mkdir -p "${DEST_SOURCES_DIR}" "${DEST_KEYRINGS_DIR}"

for REPO in ${EXTRA_REPOSITORIES}; do
    log "Processing repository template: ${REPO}"

    SRC_SOURCES_FILE="${SRC_SOURCES_DIR}/${REPO}.sources"
    SRC_KEY_FILE_GPG="${SRC_KEYRINGS_DIR}/${REPO}.gpg"
    SRC_KEY_FILE_ASC="${SRC_KEYRINGS_DIR}/${REPO}.asc"

    if [ -f "${SRC_SOURCES_FILE}" ]; then
        log "  Copying sources: ${SRC_SOURCES_FILE} -> ${DEST_SOURCES_DIR}/"
        cp "${SRC_SOURCES_FILE}" "${DEST_SOURCES_DIR}/"
    else
        log "  Warning: sources file not found: ${SRC_SOURCES_FILE}"
    fi

    if [ -f "${SRC_KEY_FILE_GPG}" ]; then
        DEST_KEY="${DEST_KEYRINGS_DIR}/$(basename "${SRC_KEY_FILE_GPG}")"
        log "  Copying keyring: ${SRC_KEY_FILE_GPG} -> ${DEST_KEY}"
        cp "${SRC_KEY_FILE_GPG}" "${DEST_KEY}"
    elif [ -f "${SRC_KEY_FILE_ASC}" ]; then
        DEST_KEY="${DEST_KEYRINGS_DIR}/$(basename "${SRC_KEY_FILE_ASC}")"
        log "  Copying keyring: ${SRC_KEY_FILE_ASC} -> ${DEST_KEY}"
        cp "${SRC_KEY_FILE_ASC}" "${DEST_KEY}"
    else
        log "  Warning: no keyring found for ${REPO} in ${SRC_KEYRINGS_DIR}"
    fi
done

# Ensure permissions are sane (non-executable, readable)
chmod -R u=rwX,go=rX "${DEST_SOURCES_DIR}" 2>/dev/null || true
chmod -R u=rwX,go=rX "${DEST_KEYRINGS_DIR}" 2>/dev/null || true

log "Ensuring ca-certificates and curl are available in chroot..."
chroot "${SYSTEMROOT}" apt-get update -y || true
chroot "${SYSTEMROOT}" apt-get install -y --no-install-recommends ca-certificates curl

log "Updating apt cache after adding repositories..."
chroot "${SYSTEMROOT}" apt-get update -y || log "Warning: apt-get update failed. Check repo configs."

log "Repository template configuration complete."