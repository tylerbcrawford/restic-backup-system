#!/bin/bash
# config.sh — Central configuration for the backup system
# All paths, thresholds, and environment variables
#
# Source your .env before running, or export these variables

# Restic
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/path/to/restic/repo}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/password}"
RESTIC_BIN="/usr/bin/restic"

# Offsite destination (any rclone remote: Google Drive, Backblaze B2, S3, ...)
# GDRIVE_DEST is kept as a backward-compatible alias.
GDRIVE_DEST="${GDRIVE_DEST:-gdrive:Backups/restic}"
OFFSITE_DEST="${OFFSITE_DEST:-$GDRIVE_DEST}"
# Warn if the offsite remote reports less than this much free space.
# 0 disables the check (correct for pay-per-GB remotes like B2/S3 with no quota).
OFFSITE_FREE_MIN_GB="${OFFSITE_FREE_MIN_GB:-0}"

# Space-separated module keys to skip on this machine,
# e.g. SKIP_MODULES="plex-db volumes" on a host with no Plex and no named volumes.
SKIP_MODULES="${SKIP_MODULES:-}"

# Docker
DOCKER_DIR="${DOCKER_DIR:-/path/to/docker-compose-directory}"
DOCKER_COMPOSE="docker compose"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-myproject}"

# Paths
BACKUP_SCRIPTS_DIR="${BACKUP_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${LOG_DIR:-/var/log/backup-system}"
LOG_FILE="$LOG_DIR/backup-orchestrator.log"
LOCK_FILE="/tmp/backup-orchestrator.lock"

# Restic tags (one per backup module)
TAG_VOLUMES="volumes"
TAG_PLEX_DB="plex-db"
TAG_SYSTEM_CONFIGS="system-configs"
TAG_HOME="home"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# Alert thresholds
RESTIC_REPO_MAX_GB=45      # Warn if local repo exceeds this
LOCAL_FREE_MIN_GB=20        # Warn if local disk free space drops below this
SNAPSHOT_MAX_AGE_HOURS=26   # Warn if newest snapshot older than this

# Discord notifications
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

# Backup exclusions for home directory
HOME_EXCLUDES=(
    ".cache"
    "snap"
    ".local/share/Trash"
    ".mozilla"
    ".config/google-chrome"
    "backups"
    ".steam"
    ".nvm/.cache"
    ".npm/_cacache"
    "**/__pycache__"
)

# Plex volume — backed up separately by backup-plex-db.sh
PLEX_VOLUME="${PLEX_VOLUME:-${COMPOSE_PROJECT_NAME}_plex_config}"

# Plex DB path inside the volume
PLEX_DB_PATH="Library/Application Support/Plex Media Server/Plug-in Support/Databases"

# ── Machine-local overrides ──────────────────────────────
# Optional, gitignored. Override any variable above or append to arrays
# (e.g. HOME_EXCLUDES+=("**/node_modules")) for this deployment.
_LOCAL_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.local.sh"
# shellcheck disable=SC1090
[[ -f "$_LOCAL_CONF" ]] && source "$_LOCAL_CONF"
