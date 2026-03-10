#!/bin/bash
# prune-snapshots.sh — Apply retention policy and reclaim space
# Runs weekly to keep the repo from growing unbounded.
# Retention: 7 daily, 4 weekly, 6 monthly snapshots per tag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

main() {
    log "Pruning snapshots (keep: ${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)"

    local before_size
    before_size=$(repo_size_gb)

    restic forget \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --group-by "paths,tags" \
        --prune \
        --verbose

    local exit_code=$?

    local after_size
    after_size=$(repo_size_gb)
    log "Prune complete: ${before_size}GB → ${after_size}GB"

    return $exit_code
}

main "$@"
