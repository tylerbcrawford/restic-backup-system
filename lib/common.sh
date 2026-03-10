#!/bin/bash
# common.sh — Shared functions for the backup system
# Provides: logging, locking, preflight checks, module runner

# Source config if not already loaded
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${RESTIC_REPOSITORY:-}" ]] && source "$_COMMON_DIR/config.sh"

# ── Logging ──────────────────────────────────────────────

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [INFO] $*" | tee -a "$LOG_FILE"
}

warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [WARN] $*" | tee -a "$LOG_FILE"
}

err() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

# ── Locking ──────────────────────────────────────────────

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            err "Another backup is already running (PID $pid). Exiting."
            exit 1
        else
            warn "Stale lock file found (PID $pid), removing"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ── Preflight ────────────────────────────────────────────

preflight() {
    # Check restic is available
    if ! command -v restic &>/dev/null; then
        err "restic not found in PATH"
        return 1
    fi

    # Check password file exists
    if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
        err "Restic password file not found: $RESTIC_PASSWORD_FILE"
        return 1
    fi

    # Check repo exists
    if ! restic snapshots --quiet &>/dev/null; then
        err "Cannot access restic repository at $RESTIC_REPOSITORY"
        return 1
    fi

    # Check local disk space
    local free_gb
    free_gb=$(df -BG /home | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "$free_gb" -lt "$LOCAL_FREE_MIN_GB" ]]; then
        warn "Low disk space: ${free_gb}GB free (threshold: ${LOCAL_FREE_MIN_GB}GB)"
    fi

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    log "Preflight checks passed (${free_gb}GB free on /home)"
    return 0
}

# ── Module Runner ────────────────────────────────────────

# Runs a backup module script, captures pass/fail and duration.
# Usage: run_module "module_name" "/path/to/module.sh"
# Returns: 0 on success, 1 on failure
# Sets: MODULE_RESULTS associative array (declared by caller)
run_module() {
    local name="$1"
    local script="$2"
    local start_time duration exit_code

    log "── Starting module: $name ──"
    start_time=$(date +%s)

    if [[ ! -x "$script" ]]; then
        err "Module not found or not executable: $script"
        MODULE_RESULTS["$name"]="FAIL (not found)"
        return 1
    fi

    # Run module, capture output to log
    "$script" >> "$LOG_FILE" 2>&1
    exit_code=$?

    duration=$(( $(date +%s) - start_time ))
    if [[ $exit_code -eq 0 ]]; then
        log "── Module $name completed (${duration}s) ──"
        MODULE_RESULTS["$name"]="OK (${duration}s)"
        return 0
    else
        err "── Module $name FAILED (exit $exit_code, ${duration}s) ──"
        MODULE_RESULTS["$name"]="FAIL (exit $exit_code, ${duration}s)"
        return 1
    fi
}

# ── Utilities ────────────────────────────────────────────

# Human-readable byte sizes
human_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1048576}")MB"
    else
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1024}")KB"
    fi
}

# Get restic repo size in GB
repo_size_gb() {
    du -sb "$RESTIC_REPOSITORY" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}'
}
