#!/usr/bin/env bash
# lib/notify.sh — Desktop notification wrappers
#
# Status notifications (Recording, Transcribing, Typed) are marked transient:
# they pop up as banners but do NOT accumulate in the notification center.
# Errors are non-transient so they stay in the tray if the user misses them.
# Clipboard notifications are non-transient because they require user action.
#
# To show a fresh banner on every event, we close the previous notification via
# D-Bus before sending the new one.  --replace-id only silently updates the tray
# entry; the x-canonical-private-synchronous hint suppresses banners entirely
# (it is designed for volume/brightness OSD overlays, not for us).

readonly _VOX_APP_NAME="vox-linux"
_VOX_NOTIF_ID_FILE="/tmp/vox-linux/notif_id"

# vox_notify TITLE [BODY] [URGENCY=normal] [TIMEOUT_MS=3000] [TRANSIENT=true]
vox_notify() {
    local title="${1:-vox}"
    local body="${2:-}"
    local urgency="${3:-normal}"
    local timeout="${4:-3000}"
    local transient="${5:-true}"

    # Close the previous notification so GNOME shows the next one as a fresh
    # banner.  --replace-id only silently updates the tray entry; closing first
    # forces GNOME to treat the next send as a new event worthy of a popup.
    if [[ -f "$_VOX_NOTIF_ID_FILE" ]]; then
        local prev_id
        prev_id=$(cat "$_VOX_NOTIF_ID_FILE" 2>/dev/null || true)
        if [[ -n "$prev_id" ]]; then
            gdbus call --session \
                --dest org.freedesktop.Notifications \
                --object-path /org/freedesktop/Notifications \
                --method org.freedesktop.Notifications.CloseNotification \
                "$prev_id" >/dev/null 2>&1 || true
        fi
        rm -f "$_VOX_NOTIF_ID_FILE"
    fi

    local args=(
        --app-name="$_VOX_APP_NAME"
        --urgency="$urgency"
        --expire-time="$timeout"
    )

    # Transient notifications show as a banner but are not kept in the
    # notification center, so they don't pile up with normal app messages.
    [[ "$transient" == "true" ]] && args+=(--hint=boolean:transient:true)

    # Save the new ID so the next call can close this notification first.
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
    vox_notify "🔴 Recording…" "" "critical" 0 "true"
}

notify_processing() {
    vox_notify "⏳ Transcribing…" "" "normal" 0 "true"
}

# notify_done TEXT
notify_done() {
    local text="${1:-}"
    local preview="${text:0:80}"
    [[ ${#text} -gt 80 ]] && preview+="…"
    vox_notify "✅ Typed" "$preview" "normal" 4000 "true"
}

# notify_clipboard TEXT — text is in clipboard, user must paste manually
notify_clipboard() {
    local text="${1:-}"
    local preview="${text:0:120}"
    [[ ${#text} -gt 120 ]] && preview+="…"
    # Non-transient: user must see this to know they need to paste manually
    vox_notify "📋 Paste now  (Ctrl+V / Ctrl+Shift+V)" "$preview" "normal" 12000 "false"
}

# notify_error MESSAGE
notify_error() {
    # Non-transient: stays in the tray so the user can check it later
    vox_notify "❌ vox-linux error" "$1" "critical" 5000 "false"
}
