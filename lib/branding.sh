#!/bin/bash
# branding.sh — Shared bot identity for Discord webhook messages
# Source this from any script that sends Discord webhooks.
#
# Usage:
#   source /path/to/branding.sh
#   curl ... -d '{"username":"'"$BOT_USERNAME"'","avatar_url":"'"$BOT_AVATAR_URL"'", ...}'

BOT_USERNAME="${BOT_USERNAME:-Backup Bot}"
BOT_AVATAR_URL="${BOT_AVATAR_URL:-}"
