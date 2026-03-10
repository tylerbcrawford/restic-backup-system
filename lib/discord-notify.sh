#!/bin/bash
# discord-notify.sh — Discord webhook notifications for the backup system
# Posts rich embeds to a Discord channel via webhook

# Source config and branding if not already loaded
_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${DISCORD_WEBHOOK:-}" ]] && source "$_NOTIFY_DIR/config.sh"
[[ -z "${BOT_USERNAME:-}" ]] && source "$_NOTIFY_DIR/branding.sh"

# ── Discord Embed Sender ─────────────────────────────────

# Low-level: send a Discord embed via webhook
# Usage: _send_embed "title" "description" color_decimal "footer_text"
_send_embed() {
    local title="$1" description="$2" color="$3" footer="${4:-}"
    local payload footer_json=""

    if [[ -n "$footer" ]]; then
        footer_json=",\"footer\":{\"text\":\"$footer\"}"
    fi

    payload=$(cat <<ENDJSON
{
  "username": "$BOT_USERNAME",
  "avatar_url": "$BOT_AVATAR_URL",
  "embeds": [{
    "title": "$title",
    "description": "$description",
    "color": $color,
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    $footer_json
  }]
}
ENDJSON
)

    curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK"
}

# ── Public Functions ─────────────────────────────────────

# Daily/weekly summary embed with module statuses
# Usage: send_discord_summary "daily|weekly" "module1:OK|module2:FAIL" total_duration_seconds fail_count
send_discord_summary() {
    local mode="$1" results="$2" duration="$3" failures="${4:-0}"
    local color title desc

    # Green=65280, Red=16711680, Yellow=16776960
    if [[ "$failures" -eq 0 ]]; then
        color=65280
        title="Backup $mode completed"
    else
        color=16711680
        title="Backup $mode completed with $failures failure(s)"
    fi

    # Format results as description lines
    desc=""
    IFS='|' read -ra entries <<< "$results"
    for entry in "${entries[@]}"; do
        local name status icon
        name="${entry%%:*}"
        status="${entry#*:}"
        if [[ "$status" == OK* ]]; then
            icon="\\u2705"
        else
            icon="\\u274c"
        fi
        desc+="$icon **$name**: $status\\n"
    done

    local duration_min=$(( duration / 60 ))
    local repo_gb
    repo_gb=$(du -sb "$RESTIC_REPOSITORY" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')

    desc+="\\n**Duration:** ${duration_min}m | **Repo:** ${repo_gb}GB"

    _send_embed "$title" "$desc" "$color" "$BOT_USERNAME | $(hostname)"
}

# Warning notification (non-fatal alert)
# Usage: send_discord_warning "Low disk space" "Only 15GB free on /home"
send_discord_warning() {
    local title="$1" message="$2"
    _send_embed "\\u26a0\\ufe0f $title" "$message" 16776960 "$BOT_USERNAME | $(hostname)"
}

# Critical failure notification
# Usage: send_discord_error "Backup failed" "restic returned exit code 1"
send_discord_error() {
    local title="$1" message="$2"
    _send_embed "\\u274c $title" "$message" 16711680 "$BOT_USERNAME | $(hostname)"
}
