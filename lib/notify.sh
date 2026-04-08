#!/usr/bin/env bash
# lib/notify.sh — Desktop notification wrappers
#
# Uses notify-send with a stable stack-tag so successive notifications
# replace each other instead of piling up.

readonly _VOX_APP_NAME="vox-linux"
readonly _VOX_STACK_TAG="vox-linux"

# vox_notify TITLE [BODY] [URGENCY=normal] [TIMEOUT_MS=3000]
vox_notify() {
    local title="${1:-vox}"
    local body="${2:-}"
    local urgency="${3:-normal}"
    local timeout="${4:-3000}"

    notify-send \
        --app-name="$_VOX_APP_NAME" \
        --urgency="$urgency" \
        --expire-time="$timeout" \
        --hint="string:x-canonical-private-synchronous:$_VOX_STACK_TAG" \
        "$title" "$body" 2>/dev/null || true
}

notify_recording() {
    vox_notify "🎤 Recording…" "Press hotkey again to stop." "critical" 0
}

notify_processing() {
    vox_notify "⏳ Transcribing…" "" "low" 5000
}

# notify_done TEXT
notify_done() {
    local text="${1:-}"
    local preview="${text:0:80}"
    [[ ${#text} -gt 80 ]] && preview+="…"
    vox_notify "✅ Done" "$preview" "low" 3000
}

# notify_error MESSAGE
notify_error() {
    vox_notify "❌ vox-linux error" "$1" "critical" 5000
}
