#!/usr/bin/env bash
# lib/common.sh
# Shared utility functions for build scripts

# Log function with timestamp
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S%z)] $*" >&2
}

# Fail function to exit with error message
fail() {
    log "ERROR: $*"
    exit 1
}

# Verify a file exists
require_file() {
    [[ -f "$1" ]] || fail "Required file not found: $1"
}

# Verify a directory exists
require_dir() {
    [[ -d "$1" ]] || fail "Required directory not found: $1"
}

# Verify required commands exist
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
    done
}
