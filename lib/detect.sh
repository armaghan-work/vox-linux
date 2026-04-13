#!/usr/bin/env bash
# lib/detect.sh — System capability detection for vox-linux
# All functions set global VOX_* variables and respect config file overrides.

detect_display_server() {
    # Honour explicit config override
    if [[ "${VOX_DISPLAY_SERVER:-auto}" != "auto" ]]; then
        return 0
    fi
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        VOX_DISPLAY_SERVER="wayland"
    else
        VOX_DISPLAY_SERVER="x11"
    fi
}

detect_audio_backend() {
    if [[ "${VOX_AUDIO_BACKEND:-auto}" != "auto" ]]; then
        return 0
    fi
    if command -v pw-record >/dev/null 2>&1; then
        VOX_AUDIO_BACKEND="pipewire"
    elif command -v parecord >/dev/null 2>&1; then
        VOX_AUDIO_BACKEND="pulseaudio"
    elif command -v arecord >/dev/null 2>&1; then
        VOX_AUDIO_BACKEND="alsa"
    else
        vox_notify "vox-linux error" "No audio recorder found. Install pipewire or pulseaudio-utils." "critical"
        exit 1
    fi
}

detect_typing_tool() {
    if [[ "${VOX_TYPING_TOOL:-auto}" != "auto" ]]; then
        return 0
    fi
    if [[ "$VOX_DISPLAY_SERVER" == "wayland" ]]; then
        local sock="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
        if command -v ydotool >/dev/null 2>&1 && [[ -S "$sock" ]]; then
            # Only use ydotool when the ydotoold daemon socket is present.
            # Without the daemon, direct /dev/uinput mode has known latency
            # and key-injection bugs (modifier keys misfiring as raw digits).
            VOX_TYPING_TOOL="ydotool"
        elif command -v wtype >/dev/null 2>&1; then
            VOX_TYPING_TOOL="wtype"
        elif command -v xdotool >/dev/null 2>&1; then
            # XWayland fallback — works for any app running under XWayland
            VOX_TYPING_TOOL="xdotool"
        else
            VOX_TYPING_TOOL="clipboard_only"
        fi
    else
        if command -v xdotool >/dev/null 2>&1; then
            VOX_TYPING_TOOL="xdotool"
        else
            VOX_TYPING_TOOL="clipboard_only"
        fi
    fi
}

detect_clipboard_tool() {
    if [[ "${VOX_CLIPBOARD_TOOL:-auto}" != "auto" ]]; then
        return 0
    fi
    if [[ "$VOX_DISPLAY_SERVER" == "wayland" ]]; then
        if command -v wl-copy >/dev/null 2>&1; then
            VOX_CLIPBOARD_TOOL="wl-copy"
        else
            VOX_CLIPBOARD_TOOL="none"
        fi
    else
        if command -v xclip >/dev/null 2>&1; then
            VOX_CLIPBOARD_TOOL="xclip"
        elif command -v xsel >/dev/null 2>&1; then
            VOX_CLIPBOARD_TOOL="xsel"
        else
            VOX_CLIPBOARD_TOOL="none"
        fi
    fi
}

# Locate the whisper.cpp binary; echoes the path or returns 1.
find_whisper_binary() {
    local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/vox-linux"
    local build_dir="$data_dir/whisper.cpp/build/bin"

    for candidate in \
        "$build_dir/whisper-cli" \
        "$build_dir/main" \
        "$data_dir/whisper.cpp/build/whisper-cli" \
        "$data_dir/whisper.cpp/build/main" \
        "$data_dir/whisper.cpp/whisper-cli" \
        "$data_dir/whisper.cpp/main"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Fall back to PATH
    for name in whisper-cli whisper main; do
        if command -v "$name" >/dev/null 2>&1; then
            command -v "$name"
            return 0
        fi
    done

    return 1
}
