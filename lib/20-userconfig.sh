#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
source "${CONFIG_FILE}"

SYSTEMROOT="${BUILD_DIR}/systemroot"
require_dir "${SYSTEMROOT}"

log "Configuring primary user: ${PRIMARY_USER}"

export DEBIAN_FRONTEND=noninteractive

# Ensure sudo exists (inside chroot)
chroot "${SYSTEMROOT}" apt-get update
chroot "${SYSTEMROOT}" apt-get install -y sudo

# Create user with home directory inside chroot if missing
if ! chroot "${SYSTEMROOT}" id "${PRIMARY_USER}" >/dev/null 2>&1; then
    chroot "${SYSTEMROOT}" useradd -m -s /bin/bash -G sudo "${PRIMARY_USER}"
fi

# Set password hash inside chroot
echo "${PRIMARY_USER}:${PRIMARY_USER_PASSWORD_HASH}" | chroot "${SYSTEMROOT}" chpasswd -e

# Determine UID/GID from chroot's /etc/passwd
PASSWD_LINE=$(chroot "${SYSTEMROOT}" getent passwd "${PRIMARY_USER}")
if [ -z "${PASSWD_LINE}" ]; then
    fail "Failed to find ${PRIMARY_USER} in chroot passwd database"
fi

# passwd format: name:passwd:uid:gid:gecos:home:shell
USER_UID=$(echo "${PASSWD_LINE}" | cut -d: -f3)
USER_GID=$(echo "${PASSWD_LINE}" | cut -d: -f4)

HOMEDIR="${SYSTEMROOT}/home/${PRIMARY_USER}"
SSH_DIR="${HOMEDIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Ensure home exists (should be created by useradd, but be defensive)
mkdir -p "${HOMEDIR}"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

printf '%s\n' "${PRIMARY_USER_SSH_PUBKEY}" > "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"

# Use numeric uid:gid so host chown works
chown -R "${USER_UID}:${USER_GID}" "${HOMEDIR}"

log "User configuration complete"
