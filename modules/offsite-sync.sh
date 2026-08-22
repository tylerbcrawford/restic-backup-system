#!/bin/bash
# offsite-sync.sh — Sync local restic repo to Google Drive
# Uses rclone sync to mirror the encrypted repo to any configured rclone remote
# The GDrive copy is opaque encrypted data — restore requires restic + password.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/discord-notify.sh"

main() {
    log "Starting offsite sync to $OFFSITE_DEST"

    # Check rclone is available
    if ! command -v rclone &>/dev/null; then
        err "rclone not found in PATH"
        return 1
    fi

    # Check repo exists and has data
    if [[ ! -d "$RESTIC_REPOSITORY/data" ]]; then
        err "Restic repository not found or empty at $RESTIC_REPOSITORY"
        return 1
    fi

    local repo_size
    repo_size=$(du -sh "$RESTIC_REPOSITORY" | cut -f1)
    log "Local repo size: $repo_size"

    # Sync local repo → GDrive
    rclone sync "$RESTIC_REPOSITORY" "$OFFSITE_DEST" \
        --transfers 4 \
        --checkers 8 \
        --stats 1m \
        --stats-one-line \
        --log-level INFO

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        err "rclone sync failed (exit $exit_code)"
        return $exit_code
    fi

    # Verify remote size
    local remote_size
    remote_size=$(rclone size "$OFFSITE_DEST" --json 2>/dev/null | sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1 || true)
    local local_size
    local_size=$(du -sb "$RESTIC_REPOSITORY" | awk '{print $1}')

    if [[ -n "$remote_size" && -n "$local_size" ]]; then
        local diff=$(( local_size - remote_size ))
        # Allow 1MB tolerance for metadata differences
        if [[ ${diff#-} -gt 1048576 ]]; then
            warn "Size mismatch: local=${local_size} bytes, remote=${remote_size} bytes"
        else
            log "Size verified: local and remote match"
        fi
    fi

    # Optional free-space check (quota-based remotes only; 0 = disabled)
    if [[ "${OFFSITE_FREE_MIN_GB:-0}" -gt 0 ]]; then
        local remote_name free_gb
        remote_name="${OFFSITE_DEST%%:*}:"
        free_gb=$(rclone about "$remote_name" --json 2>/dev/null | sed -n 's/.*"free"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1 || true)
        if [[ -n "$free_gb" ]]; then
            free_gb=$((free_gb / 1073741824))
            log "Offsite remote free space: ${free_gb}GB"
            if [[ $free_gb -lt $OFFSITE_FREE_MIN_GB ]]; then
                warn "Offsite free space below threshold: ${free_gb}GB < ${OFFSITE_FREE_MIN_GB}GB"
                send_discord_warning "Low offsite space" "Only ${free_gb}GB free (threshold: ${OFFSITE_FREE_MIN_GB}GB)"
            fi
        else
            log "Offsite remote does not report free space; skipping check"
        fi
    fi

    log "Offsite sync complete"
    return 0
}

main "$@"
