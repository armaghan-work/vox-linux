#!/usr/bin/env bash
# vox.sh — vox-linux main entry point
#
# Usage:
#   vox.sh type        — voice-to-text: toggle record/stop, paste at cursor
#   vox.sh suggest     — voice-to-shell: toggle record/stop, run AI CLI
#   vox.sh ptt-start [MODE]  — PTT: start recording (no-op if already recording)
#   vox.sh ptt-stop          — PTT: stop recording + transcribe (no-op if idle)
#
# Toggle behaviour (type / suggest):
#   First call  → start recording (runs in background, script exits)
#   Second call → stop recording, transcribe, inject text
#
# PTT behaviour (called by vox-ptt.sh daemon on key hold/release):
#   ptt-start  → start recording only if not already recording
#   ptt-stop   → stop recording + transcribe only if currently recording
#
# Designed to be bound to two GNOME / KDE hotkeys (toggle), or driven by the
# vox-ptt.sh daemon for push-to-talk (hold key = record, release = transcribe).

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

# ── Debug logging ─────────────────────────────────────────────────────────────
VOX_LOG="$VOX_STATE_DIR/debug.log"
vox_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >> "$VOX_LOG"; }
# Rotate log if it grows large
[[ -f "$VOX_LOG" ]] && (( $(wc -c < "$VOX_LOG") > 102400 )) && mv "$VOX_LOG" "${VOX_LOG}.old"
vox_log "=== vox.sh invoked: mode=${1:-type} PID=$$ DISPLAY=${DISPLAY:-unset} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset} ==="

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
        rm -f "$LOCKFILE" "$MODE_FILE" 2>/dev/null || true
    fi
}

trap _on_error ERR
trap _cleanup EXIT

# ── Detect system capabilities ────────────────────────────────────────────────
detect_display_server
detect_audio_backend
detect_typing_tool
detect_clipboard_tool
vox_log "detected: display=$VOX_DISPLAY_SERVER audio=$VOX_AUDIO_BACKEND typing=$VOX_TYPING_TOOL clipboard=$VOX_CLIPBOARD_TOOL"

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
    vox_log "cmd_stop: start"
    notify_processing
    vox_log "cmd_stop: stopping audio recorder"
    audio_stop "$PIDFILE"
    rm -f "$LOCKFILE"
    vox_log "cmd_stop: audio stopped, lockfile removed"

    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo "type")
    rm -f "$MODE_FILE"

    # Validate the WAV file before passing to whisper
    local wav_size=0
    [[ -f "$AUDIO_FILE" ]] && wav_size=$(wc -c < "$AUDIO_FILE" 2>/dev/null || echo 0)
    vox_log "cmd_stop: wav size=${wav_size} bytes"
    if [[ $wav_size -lt 4096 ]]; then
        if [[ $wav_size -gt 0 ]]; then
            vox_log "cmd_stop: WAV too small (${wav_size}B) — recording was too short"
            notify_error "Recording too short — hold the key a bit longer and speak."
        else
            vox_log "cmd_stop: WAV missing or empty — recording probably failed"
            notify_error "Recording failed — no audio captured. Check microphone."
        fi
        exit 1
    fi

    vox_log "cmd_stop: starting transcription (mode=$mode)"
    local text
    if ! text=$(transcribe "$AUDIO_FILE"); then
        vox_log "cmd_stop: transcription FAILED"
        notify_error "Transcription failed — check install.sh output."
        exit 1
    fi
    vox_log "cmd_stop: transcription done, text='${text:0:80}'"

    # Trim surrounding whitespace
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"

    if [[ -z "$text" ]]; then
        vox_log "cmd_stop: no speech detected"
        notify_error "No speech detected. Try speaking closer to the microphone."
        exit 0
    fi

    vox_log "cmd_stop: calling type_text"
    # type_text handles notify_done / notify_error internally
    type_text "$text" "$mode"
    vox_log "cmd_stop: type_text returned"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
#
# ptt-start / ptt-stop are called by the vox-ptt.sh daemon (hold-to-talk).
# They guard against race conditions: ptt-start is a no-op if already
# recording; ptt-stop is a no-op if not currently recording.
#
# type / suggest use the original toggle logic (hotkey = start OR stop).
case "$MODE" in
    ptt-start)
        PTT_MODE="${2:-type}"
        vox_log "ptt-start: lockfile=$([ -f "$LOCKFILE" ] && echo exists || echo absent)"
        if [[ ! -f "$LOCKFILE" ]]; then
            _cmd_start "$PTT_MODE"
        fi
        ;;
    ptt-stop)
        vox_log "ptt-stop: lockfile=$([ -f "$LOCKFILE" ] && echo exists || echo absent)"
        if [[ -f "$LOCKFILE" ]]; then
            _cmd_stop
        fi
        ;;
    *)
        # Toggle: first call starts, second call stops.
        if [[ -f "$LOCKFILE" ]]; then
            _cmd_stop
        else
            _cmd_start "$MODE"
        fi
        ;;
esac
