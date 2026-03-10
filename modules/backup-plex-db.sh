#!/bin/bash
# backup-plex-db.sh — Back up Plex database only (not media/cache)
# The desktop_plex_config volume is ~41GB total, but the actual database
# is only ~984MB. We exclude everything else (Media/, Metadata/, Cache/)
# since those are regenerable from the media files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

main() {
    log "Backing up Plex database from $PLEX_VOLUME"

    # Verify volume exists
    if ! docker volume inspect "$PLEX_VOLUME" &>/dev/null; then
        err "Plex volume not found: $PLEX_VOLUME"
        return 1
    fi

    # Mount only the plex config volume, backup just the Databases directory
    # Using restic/restic image (static binary) instead of alpine + host binary
    docker run --rm \
        --name backup-plex-db \
        --user "$(id -u):$(id -g)" \
        -v "$RESTIC_REPOSITORY":/repo \
        -v "$RESTIC_PASSWORD_FILE":/password:ro \
        -e RESTIC_REPOSITORY=/repo \
        -e RESTIC_PASSWORD_FILE=/password \
        -v "${PLEX_VOLUME}:/data/${PLEX_VOLUME}:ro" \
        restic/restic:0.18.1 \
        backup "/data/${PLEX_VOLUME}/${PLEX_DB_PATH}" \
            --tag "$TAG_PLEX_DB" \
            --verbose

    local exit_code=$?
    log "Plex DB backup complete (exit $exit_code)"
    return $exit_code
}

main "$@"
