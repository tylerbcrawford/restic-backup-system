#!/bin/bash
# backup-orchestrator.sh — Main entry point for the restic backup system
#
# Usage:
#   ./backup-orchestrator.sh --daily      # Run all backup modules + offsite sync
#   ./backup-orchestrator.sh --weekly     # Daily + prune + verify
#   ./backup-orchestrator.sh --dry-run    # Show status without running anything
#
# Cron:
#   Mon-Sat 4AM: --daily
#   Sunday  6AM: --weekly (after full system image finishes)

set -uo pipefail  # no -e: we handle module failures ourselves

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/discord-notify.sh"

# Associative array for module results
declare -A MODULE_RESULTS

TOTAL_START=$(date +%s)
FAIL_COUNT=0
MODE=""

# ── Argument Parsing ─────────────────────────────────────

usage() {
    echo "Usage: $0 [--daily|--weekly|--dry-run]"
    exit 1
}

case "${1:-}" in
    --daily)  MODE="daily" ;;
    --weekly) MODE="weekly" ;;
    --dry-run) MODE="dry-run" ;;
    *) usage ;;
esac

# ── Cleanup Trap ─────────────────────────────────────────

cleanup() {
    release_lock
    if [[ $FAIL_COUNT -gt 0 && "$MODE" != "dry-run" ]]; then
        send_discord_error "Backup $MODE failed" "$FAIL_COUNT module(s) failed. Check logs: $LOG_FILE"
    fi
}
trap cleanup EXIT

# ── Dry Run ──────────────────────────────────────────────

if [[ "$MODE" == "dry-run" ]]; then
    echo "=== Backup System Dry Run ==="
    echo ""

    echo "Restic repository: $RESTIC_REPOSITORY"
    if restic snapshots --quiet &>/dev/null; then
        echo "  Status: accessible"
        echo "  Size: $(repo_size_gb)GB"
        echo "  Snapshots:"
        restic snapshots --compact
    else
        echo "  Status: NOT accessible"
    fi
    echo ""

    local_free=$(df -BG /home | tail -1 | awk '{print $4}' | tr -d 'G')
    echo "Local disk: ${local_free}GB free"
    echo ""

    echo "Google Drive:"
    if rclone about gdrive: 2>/dev/null | head -3; then
        echo "  Restic folder:"
        rclone size "$GDRIVE_DEST" 2>/dev/null || echo "  (empty or not synced yet)"
    else
        echo "  (rclone not configured)"
    fi
    echo ""

    echo "Modules that would run (--daily):"
    echo "  1. backup-volumes.sh       (Docker volumes)"
    echo "  2. backup-plex-db.sh       (Plex database)"
    echo "  3. backup-system-configs.sh (system configs)"
    echo "  4. backup-home.sh          (\$HOME)"
    echo "  5. offsite-sync.sh         (rclone → GDrive)"

    if [[ "$MODE" == "dry-run" ]]; then
        echo ""
        echo "Additional modules for --weekly:"
        echo "  6. prune-snapshots.sh     (retention: ${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)"
        echo "  7. verify-backup.sh       (integrity + freshness)"
    fi

    exit 0
fi

# ── Main Execution ───────────────────────────────────────

log "=========================================="
log "Backup $MODE started"
log "=========================================="

acquire_lock

if ! preflight; then
    err "Preflight checks failed, aborting"
    FAIL_COUNT=1
    exit 1
fi

# Daily modules — run all, don't stop on failure
MODULES_DIR="$SCRIPT_DIR/modules"

run_module "volumes" "$MODULES_DIR/backup-volumes.sh" || ((FAIL_COUNT++))
run_module "plex-db" "$MODULES_DIR/backup-plex-db.sh" || ((FAIL_COUNT++))
run_module "system-configs" "$MODULES_DIR/backup-system-configs.sh" || ((FAIL_COUNT++))
run_module "home" "$MODULES_DIR/backup-home.sh" || ((FAIL_COUNT++))
run_module "offsite-sync" "$MODULES_DIR/offsite-sync.sh" || ((FAIL_COUNT++))

# Weekly-only modules
if [[ "$MODE" == "weekly" ]]; then
    run_module "prune" "$MODULES_DIR/prune-snapshots.sh" || ((FAIL_COUNT++))
    run_module "verify" "$MODULES_DIR/verify-backup.sh" || ((FAIL_COUNT++))
fi

# ── Summary ──────────────────────────────────────────────

TOTAL_DURATION=$(( $(date +%s) - TOTAL_START ))

# Build results string for Discord: "volumes:OK (30s)|plex-db:FAIL (exit 1, 5s)|..."
RESULTS_STR=""
for key in "${!MODULE_RESULTS[@]}"; do
    [[ -n "$RESULTS_STR" ]] && RESULTS_STR+="|"
    RESULTS_STR+="${key}:${MODULE_RESULTS[$key]}"
done

log "=========================================="
log "Backup $MODE finished in $((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s"
log "Failures: $FAIL_COUNT"
for key in "${!MODULE_RESULTS[@]}"; do
    log "  $key: ${MODULE_RESULTS[$key]}"
done
log "=========================================="

# Send Discord summary (success or mixed results)
send_discord_summary "$MODE" "$RESULTS_STR" "$TOTAL_DURATION" "$FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
