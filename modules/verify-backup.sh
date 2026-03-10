#!/bin/bash
# verify-backup.sh — Weekly health check for the backup system
# Runs integrity checks, validates snapshot freshness, and checks disk space.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/discord-notify.sh"

WARNINGS=0

main() {
    log "Running backup verification"

    # 1. Restic integrity check (sample 5% of pack data)
    log "Checking repository integrity (5% data sample)..."
    if ! restic check --read-data-subset=5% 2>&1; then
        err "Repository integrity check FAILED"
        send_discord_error "Backup integrity failure" "restic check --read-data-subset=5% failed. Manual inspection required."
        return 1
    fi
    log "Integrity check passed"

    # 2. Snapshot freshness — warn if newest is older than threshold
    log "Checking snapshot freshness..."
    local tags=("$TAG_VOLUMES" "$TAG_PLEX_DB" "$TAG_SYSTEM_CONFIGS" "$TAG_HOME")
    for tag in "${tags[@]}"; do
        local latest_time
        latest_time=$(restic snapshots --tag "$tag" --json 2>/dev/null \
            | grep -o '"time":"[^"]*"' | tail -1 | cut -d'"' -f4)

        if [[ -z "$latest_time" ]]; then
            warn "No snapshots found for tag: $tag"
            WARNINGS=$((WARNINGS + 1))
            continue
        fi

        local latest_epoch now_epoch age_hours
        latest_epoch=$(date -d "$latest_time" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age_hours=$(( (now_epoch - latest_epoch) / 3600 ))

        if [[ $age_hours -gt $SNAPSHOT_MAX_AGE_HOURS ]]; then
            warn "Snapshot '$tag' is ${age_hours}h old (threshold: ${SNAPSHOT_MAX_AGE_HOURS}h)"
            WARNINGS=$((WARNINGS + 1))
        else
            log "Snapshot '$tag': ${age_hours}h old — OK"
        fi
    done

    # 3. Local disk space
    log "Checking local disk space..."
    local free_gb
    free_gb=$(df -BG /home | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ $free_gb -lt $LOCAL_FREE_MIN_GB ]]; then
        warn "Low local disk: ${free_gb}GB free (threshold: ${LOCAL_FREE_MIN_GB}GB)"
        WARNINGS=$((WARNINGS + 1))
    else
        log "Local disk: ${free_gb}GB free — OK"
    fi

    # 4. Repo size check
    log "Checking repo size..."
    local repo_gb
    repo_gb=$(repo_size_gb)
    local repo_gb_int=${repo_gb%.*}
    if [[ $repo_gb_int -gt $RESTIC_REPO_MAX_GB ]]; then
        warn "Repo size ${repo_gb}GB exceeds threshold ${RESTIC_REPO_MAX_GB}GB"
        WARNINGS=$((WARNINGS + 1))
    else
        log "Repo size: ${repo_gb}GB — OK"
    fi

    # 5. GDrive freshness (compare local and remote sizes)
    log "Checking GDrive sync status..."
    local remote_bytes
    remote_bytes=$(rclone size "$GDRIVE_DEST" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | cut -d: -f2)
    if [[ -n "$remote_bytes" && "$remote_bytes" -gt 0 ]]; then
        local local_bytes
        local_bytes=$(du -sb "$RESTIC_REPOSITORY" | awk '{print $1}')
        local diff=$(( local_bytes - remote_bytes ))
        if [[ ${diff#-} -gt 1048576 ]]; then
            warn "GDrive out of sync: local=${local_bytes}b, remote=${remote_bytes}b"
            WARNINGS=$((WARNINGS + 1))
        else
            log "GDrive sync: sizes match — OK"
        fi
    else
        warn "GDrive sync: could not read remote size"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Summary
    if [[ $WARNINGS -gt 0 ]]; then
        warn "Verification completed with $WARNINGS warning(s)"
        send_discord_warning "Backup verification warnings" "$WARNINGS issue(s) found during weekly verification. Check logs: $LOG_FILE"
    else
        log "All verification checks passed"
    fi

    return 0
}

main "$@"
