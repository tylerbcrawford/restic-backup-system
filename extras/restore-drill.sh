#!/bin/bash
# restore-drill.sh — Prove backups can be read back, from local and offsite.
# Restores a small sample to a temp dir, checks the files, then removes them.
# Read-only against both repos (restic --no-lock).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/discord-notify.sh"

WORK_DIR=$(mktemp -d "${RESTORE_DRILL_TMP:-/tmp}/restore-drill.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
FAILS=0

fail() { err "Drill: $1"; FAILS=$((FAILS + 1)); }

check_file() {
    local file="$1"
    [[ -s "$file" ]] || { fail "empty file: $file"; return; }
    case "$file" in
        *.gz) gzip -t "$file" || fail "gzip check failed: $file" ;;
        *.db)
            [[ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA integrity_check").fetchone()[0])' "$file" 2>&1)" == "ok" ]] \
                || fail "SQLite integrity failed: $file"
            ;;
    esac
}

drill_repo() {
    local name="$1" repo="$2" target="$WORK_DIR/$1"
    log "Drill: $name ($repo)"
    export RESTIC_REPOSITORY="$repo"

    if ((${#RESTORE_DRILL_PATHS[@]})); then
        local includes=()
        for path in "${RESTORE_DRILL_PATHS[@]}"; do includes+=(--include "$path"); done
        restic --no-lock restore latest --tag "$TAG_HOME" --target "$target/home" "${includes[@]}" --quiet \
            || fail "$name: home restore failed"
        for path in "${RESTORE_DRILL_PATHS[@]}"; do
            [[ -e "$target/home$path" ]] || fail "$name: missing $path"
        done
    fi

    restic --no-lock restore latest --tag "$TAG_SYSTEM_CONFIGS" --target "$target/configs" --quiet \
        || fail "$name: system-configs restore failed"
    find "$target/configs" -type f -name 'dpkg-selections.txt' | grep -q . \
        || fail "$name: system-configs sample missing"

    local count=0
    while IFS= read -r -d '' file; do
        check_file "$file"
        count=$((count + 1))
    done < <(find "$target/home" -type f -print0 2>/dev/null)
    log "Drill: $name checked $count home files"
}

drill_repo local "$RESTIC_REPOSITORY"
drill_repo offsite "rclone:$OFFSITE_DEST"

if [[ $FAILS -gt 0 ]]; then
    send_discord_error "Restore drill failed" "$FAILS check(s) failed. See $LOG_FILE"
    exit 1
fi
log "Drill passed: local and offsite"
if [[ -n "$NOTIFY_COMMAND" ]]; then
    _notify_hook ok "Restore drill passed" "Local and offsite restores checked out."
fi
