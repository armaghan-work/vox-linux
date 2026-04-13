#!/usr/bin/env bash
# vox.sh — vox-linux main entry point
#
# Usage:
#   vox.sh type     — voice-to-text: transcribe + paste at cursor (no Enter)
#   vox.sh suggest  — voice-to-shell-command: transcribe + run
#                     'gh copilot suggest "..."' + Enter in the focused terminal
#
# Toggle behaviour:
#   First call  → start recording (runs in background, script exits)
#   Second call → stop recording, transcribe, inject text
#
# Designed to be bound to two GNOME / KDE hotkeys.

set -euo pipefail

# ── Locate script directory (works via symlink) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ── Load configuration ─────────────────────────────────────────────────────────
DEFAULTS="$SCRIPT_DIR/config/defaults.cfg"
USER_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/vox-linux/config.cfg"

[[ -f "$DEFAULTS" ]] && source "$DEFAULTS"
[[ -f "$USER_CFG" ]] && source "$USER_CFG"

# ── Load libraries ─────────────────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/notify.sh"    # needed early for error messages
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/audio.sh"
source "$SCRIPT_DIR/lib/transcribe.sh"
source "$SCRIPT_DIR/lib/type.sh"

# ── State directory ────────────────────────────────────────────────────────────
VOX_STATE_DIR="/tmp/vox-linux"
mkdir -p "$VOX_STATE_DIR"

LOCKFILE="$VOX_STATE_DIR/recording.lock"
PIDFILE="$VOX_STATE_DIR/recorder.pid"
AUDIO_FILE="$VOX_STATE_DIR/recording.wav"
MODE_FILE="$VOX_STATE_DIR/mode"

MODE="${1:-type}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
# _VOX_KEEP_LOCK is set to true only when _cmd_start completes successfully,
# so the lockfile survives between the start and stop invocations.
_VOX_KEEP_LOCK=false

# ERR fires on any unhandled command failure (set -e).
# Shows an error notification so a stuck "Transcribing…" banner never hangs.
_on_error() {
    notify_error "vox-linux crashed unexpectedly. Hotkey is reset." || true
}

# EXIT always fires — removes transient state files unless _cmd_start succeeded.
_cleanup() {
    if [[ "$_VOX_KEEP_LOCK" != "true" ]]; then
        rm -f "$LOCKFILE" "$MODE_FILE" "$_VOX_NOTIF_ID_FILE" 2>/dev/null || true
    fi
}

trap _on_error ERR
trap _cleanup EXIT

# ── Detect system capabilities ────────────────────────────────────────────────
detect_display_server
detect_audio_backend
detect_typing_tool
detect_clipboard_tool

# ── Commands ──────────────────────────────────────────────────────────────────

_cmd_start() {
    local mode="$1"
    echo "$mode" > "$MODE_FILE"
    touch "$LOCKFILE"
    rm -f "$AUDIO_FILE"   # ensure no stale file
    notify_recording
    audio_start "$AUDIO_FILE" "$PIDFILE"
    # Mark the lockfile as intentionally persistent so _cleanup leaves it.
    # Script exits here; recorder keeps running via disown.
    _VOX_KEEP_LOCK=true
}

_cmd_stop() {
    # Capture the active window NOW, before transcription takes focus away.
    # type_text uses this (via VOX_FOCUSED_WINDOW) to re-focus before pasting.
    VOX_FOCUSED_WINDOW=""
    if command -v xdotool >/dev/null 2>&1; then
        VOX_FOCUSED_WINDOW=$(xdotool getactivewindow 2>/dev/null || true)
    fi

    notify_processing
    audio_stop "$PIDFILE"
    rm -f "$LOCKFILE"

    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "type")
    rm -f "$MODE_FILE"

    local text
    if ! text=$(transcribe "$AUDIO_FILE"); then
        notify_error "Transcription failed — check install.sh output."
        exit 1
    fi

    # Trim surrounding whitespace
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"

    if [[ -z "$text" ]]; then
        notify_error "No speech detected. Try speaking closer to the microphone."
        exit 0
    fi

    # type_text handles notify_done / notify_error internally
    type_text "$text" "$mode"
}

# ── Toggle: start or stop ─────────────────────────────────────────────────────
if [[ -f "$LOCKFILE" ]]; then
    _cmd_stop
else
    _cmd_start "$MODE"
fi
