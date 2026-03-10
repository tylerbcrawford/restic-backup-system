#!/bin/bash
# backup-volumes.sh — Back up Docker volumes to restic via container
# Mounts all configured volumes read-only into a container,
# then runs restic backup from inside the container.
#
# Why a container? Docker volumes aren't directly accessible from the host
# filesystem without knowing the internal storage path. Mounting them into a
# lightweight container gives us clean, portable access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Docker volumes to back up.
# Volume names follow the pattern: ${COMPOSE_PROJECT_NAME}_<service>_config
#
# Excluded from this list:
#   - plex (backed up separately by backup-plex-db.sh — only the DB, not media cache)
#   - database volumes with non-standard ownership (mongo, postgres) — use dumps instead
#   - portainer_data (root-owned internal state, not restorable config)
#
# Customize this list to match your Docker Compose project's volumes.
# Run `docker volume ls` to see available volumes.
VOLUMES=(
    "${COMPOSE_PROJECT_NAME}_audiobookshelf_config"
    "${COMPOSE_PROJECT_NAME}_bazarr_config"
    "${COMPOSE_PROJECT_NAME}_calibre_config"
    "${COMPOSE_PROJECT_NAME}_filebrowser_config"
    "${COMPOSE_PROJECT_NAME}_lidarr_config"
    "${COMPOSE_PROJECT_NAME}_nzbget_config"
    "${COMPOSE_PROJECT_NAME}_prowlarr_config"
    "${COMPOSE_PROJECT_NAME}_qbittorrent_config"
    "${COMPOSE_PROJECT_NAME}_radarr_config"
    "${COMPOSE_PROJECT_NAME}_readarr_config"
    "${COMPOSE_PROJECT_NAME}_sonarr_config"
    "${COMPOSE_PROJECT_NAME}_tautulli_config"
    "${COMPOSE_PROJECT_NAME}_unpackerr_config"
)

# Build docker volume mount args: -v volume:/data/volume_name:ro
build_volume_mounts() {
    local mounts=""
    for vol in "${VOLUMES[@]}"; do
        mounts+=" -v ${vol}:/data/${vol}:ro"
    done
    echo "$mounts"
}

main() {
    log "Backing up ${#VOLUMES[@]} Docker volumes"

    # Verify all volumes exist
    local missing=0
    for vol in "${VOLUMES[@]}"; do
        if ! docker volume inspect "$vol" &>/dev/null; then
            warn "Volume not found: $vol"
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        warn "$missing volumes not found — continuing with available volumes"
    fi

    local mounts
    mounts=$(build_volume_mounts)

    # Run restic backup inside the official restic container
    # Using restic/restic image because the host binary is glibc-linked
    # and won't execute inside Alpine (musl). The official image ships
    # a statically-linked restic binary.
    # shellcheck disable=SC2086
    docker run --rm \
        --name backup-volumes \
        --user "$(id -u):$(id -g)" \
        -v "$RESTIC_REPOSITORY":/repo \
        -v "$RESTIC_PASSWORD_FILE":/password:ro \
        -e RESTIC_REPOSITORY=/repo \
        -e RESTIC_PASSWORD_FILE=/password \
        $mounts \
        restic/restic:0.18.1 \
        backup /data/ \
            --tag "$TAG_VOLUMES" \
            --exclude="*.log" \
            --exclude="*/logs/*" \
            --exclude="*/cache/*" \
            --exclude="*/Cache/*" \
            --exclude="*/.cache/*" \
            --exclude="*/transcodes/*" \
            --exclude="*-journal" \
            --exclude="*-wal" \
            --exclude="*.tmp" \
            --exclude="*/.config/procps" \
            --verbose

    local exit_code=$?
    log "Volume backup complete (exit $exit_code)"
    return $exit_code
}

main "$@"
