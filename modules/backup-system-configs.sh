#!/bin/bash
# backup-system-configs.sh — Back up system configuration files
# Stages configs to a temp dir then runs restic backup.
# Some paths (e.g., /etc/nginx) require sudo — the sudoers entry
# grants NOPASSWD for this specific script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

STAGING_DIR=$(mktemp -d /tmp/backup-system-configs.XXXXXX)

cleanup_staging() {
    rm -rf "$STAGING_DIR" 2>/dev/null || true
}
trap cleanup_staging EXIT

main() {
    log "Backing up system configurations"

    mkdir -p "$STAGING_DIR"/{etc,home-config,cron,packages}

    # /etc/nginx needs sudo to read but we want user-owned copies.
    # Use sudo tar piped to regular tar — extracts as current user, no root-owned files.
    if [[ -d /etc/nginx ]]; then
        mkdir -p "$STAGING_DIR/etc/nginx"
        sudo tar cf - -C /etc nginx 2>/dev/null | tar xf - -C "$STAGING_DIR/etc/" 2>/dev/null || \
        warn "Could not copy /etc/nginx (sudo required)"
    fi
    cp /etc/fstab "$STAGING_DIR/etc/fstab" 2>/dev/null || warn "Could not copy fstab"
    cp /etc/hosts "$STAGING_DIR/etc/hosts" 2>/dev/null || warn "Could not copy hosts"

    # Crontab and installed packages
    crontab -l > "$STAGING_DIR/cron/crontab-$(whoami).txt" 2>/dev/null || warn "No crontab for $(whoami)"
    sudo crontab -l > "$STAGING_DIR/cron/crontab-root.txt" 2>/dev/null || true
    dpkg --get-selections > "$STAGING_DIR/packages/dpkg-selections.txt" 2>/dev/null || true

    # Docker/application configs
    if [[ -d "${DOCKER_DIR}/.config" ]]; then
        cp -a "${DOCKER_DIR}/.config" "$STAGING_DIR/home-config/docker-config"
    fi
    if [[ -f "${DOCKER_DIR}/.env" ]]; then
        cp "${DOCKER_DIR}/.env" "$STAGING_DIR/home-config/docker-env"
    fi
    if [[ -f "${DOCKER_DIR}/docker-compose.yml" ]]; then
        cp "${DOCKER_DIR}/docker-compose.yml" "$STAGING_DIR/home-config/docker-compose.yml"
    fi

    # Restic backup from staging directory
    restic backup "$STAGING_DIR" \
        --tag "$TAG_SYSTEM_CONFIGS" \
        --verbose

    local exit_code=$?
    log "System configs backup complete (exit $exit_code)"
    return $exit_code
}

main "$@"
