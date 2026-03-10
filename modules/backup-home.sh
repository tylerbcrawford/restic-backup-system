#!/bin/bash
# backup-home.sh — Back up home directory with exclusions
# Excludes caches, browser data, the restic repo itself, and other
# large regenerable directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

BACKUP_HOME_DIR="${BACKUP_HOME_DIR:-$HOME}"

main() {
    log "Backing up $BACKUP_HOME_DIR"

    # Build exclude args from config
    local exclude_args=()
    for pattern in "${HOME_EXCLUDES[@]}"; do
        exclude_args+=("--exclude" "$BACKUP_HOME_DIR/$pattern")
    done

    restic backup "$BACKUP_HOME_DIR" \
        --tag "$TAG_HOME" \
        "${exclude_args[@]}" \
        --exclude-caches \
        --verbose

    local exit_code=$?
    log "Home backup complete (exit $exit_code)"
    return $exit_code
}

main "$@"
