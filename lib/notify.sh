#!/usr/bin/env bash
# lib/notify.sh — Desktop notification wrappers
#
# Tracks the last notification ID and uses --replace-id so successive
# notifications replace each other instead of piling up.

readonly _VOX_APP_NAME="vox-linux"
readonly _VOX_STACK_TAG="vox-linux"
_VOX_NOTIF_ID_FILE="/tmp/vox-linux/notif_id"

# vox_notify TITLE [BODY] [URGENCY=normal] [TIMEOUT_MS=3000]
vox_notify() {
    local title="${1:-vox}"
    local body="${2:-}"
    local urgency="${3:-normal}"
    local timeout="${4:-3000}"

    local args=(
        --app-name="$_VOX_APP_NAME"
        --urgency="$urgency"
        --expire-time="$timeout"
        --hint="string:x-canonical-private-synchronous:$_VOX_STACK_TAG"
    )

    # Replace the previous notification if we have its ID
    if [[ -f "$_VOX_NOTIF_ID_FILE" ]]; then
        local prev_id
        prev_id=$(cat "$_VOX_NOTIF_ID_FILE" 2>/dev/null || true)
        [[ -n "$prev_id" ]] && args+=(--replace-id="$prev_id")
    fi

    # Use --print-id (libnotify >= 0.7.9) to track the ID for next replacement
    local new_id
    if new_id=$(notify-send --print-id "${args[@]}" "$title" "$body" 2>/dev/null) \
            && [[ "$new_id" =~ ^[0-9]+$ ]]; then
        mkdir -p /tmp/vox-linux
        printf '%s' "$new_id" > "$_VOX_NOTIF_ID_FILE"
    else
        # Fallback: send without --print-id (older libnotify)
        notify-send "${args[@]}" "$title" "$body" 2>/dev/null || true
    fi
}

notify_recording() {
    vox_notify "🎤 Recording…" "Press hotkey again to stop." "critical" 0
}

notify_processing() {
    # Keep visible (timeout=0) until explicitly replaced by notify_done/notify_error
    vox_notify "⏳ Transcribing…" "" "low" 0
}

# notify_done TEXT
notify_done() {
    local text="${1:-}"
    local preview="${text:0:80}"
    [[ ${#text} -gt 80 ]] && preview+="…"
    vox_notify "✅ Done" "$preview" "low" 3000
    rm -f "$_VOX_NOTIF_ID_FILE"
}

# notify_error MESSAGE
notify_error() {
    vox_notify "❌ vox-linux error" "$1" "critical" 5000
    rm -f "$_VOX_NOTIF_ID_FILE"
}
