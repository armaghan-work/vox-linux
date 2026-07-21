#!/usr/bin/env bash
# lib/detect.sh — System capability detection for vox-linux
# All functions set global VOX_* variables and respect config file overrides.

detect_display_server() {
    # Honour explicit config override
    if [[ "${VOX_DISPLAY_SERVER:-auto}" != "auto" ]]; then
        return 0
    fi
    # Normal case: session env vars are present (GNOME shortcut / user terminal).
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        VOX_DISPLAY_SERVER="wayland"
        return 0
    fi
    # Systemd user services (e.g. the PTT daemon) inherit XDG_RUNTIME_DIR but
    # NOT WAYLAND_DISPLAY / XDG_SESSION_TYPE because those are imported by the
    # desktop session AFTER the service has already started.
    # Probe XDG_RUNTIME_DIR for a live Wayland socket as a reliable fallback.
    local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local sock
    for sock in "$runtime_dir"/wayland-?; do
        if [[ -S "$sock" ]]; then
            export WAYLAND_DISPLAY="${sock##*/}"
            VOX_DISPLAY_SERVER="wayland"
            return 0
        fi
    done
    VOX_DISPLAY_SERVER="x11"
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
        # Resolve the ydotoold socket path. ydotoold's own default (when no
        # --socket-path is given) is $XDG_RUNTIME_DIR/.ydotool_socket, e.g.
        # /run/user/1000/.ydotool_socket — this is what the distro-provided
        # "ydotool.service" unit uses on newer packages (>=1.0.4, e.g. Ubuntu
        # 24.10+/26.04). Some manual setups/older docs instead use
        # /tmp/.ydotool_socket. Respect an explicit YDOTOOL_SOCKET override;
        # otherwise probe both known locations, preferring the runtime dir.
        if [[ -z "${YDOTOOL_SOCKET:-}" ]]; then
            local runtime_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket"
            if [[ -S "$runtime_sock" ]]; then
                export YDOTOOL_SOCKET="$runtime_sock"
            elif [[ -S "/tmp/.ydotool_socket" ]]; then
                export YDOTOOL_SOCKET="/tmp/.ydotool_socket"
            fi
        fi
        local sock="${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket}"

        # ydotool >=1.0.4 (e.g. Ubuntu 24.10+/26.04) dropped the old
        # "direct /dev/uinput, no daemon" mode — it now always requires
        # ydotoold running behind that socket. install.sh enables the
        # package-provided ydotool.service for this, but if it isn't active
        # yet (e.g. just installed, or failed to start at login), try a
        # one-off lazy start here so typing doesn't silently fall back to
        # clipboard-only.
        if command -v ydotool >/dev/null 2>&1 && [[ ! -S "$sock" ]] && command -v ydotoold >/dev/null 2>&1; then
            systemctl --user start ydotool.service ydotoold.service >/dev/null 2>&1 || true
            local _i=0
            while [[ ! -S "$sock" ]] && [[ $_i -lt 10 ]]; do
                sleep 0.1
                _i=$(( _i + 1 ))
            done
            [[ -z "${YDOTOOL_SOCKET:-}" ]] && [[ -S "$sock" ]] && export YDOTOOL_SOCKET="$sock"
        fi

        if command -v ydotool >/dev/null 2>&1 && [[ -S "$sock" ]]; then
            # Daemon socket present — full ydotool support
            VOX_TYPING_TOOL="ydotool"
        elif command -v ydotool >/dev/null 2>&1 && [[ -w "/dev/uinput" ]] && ! command -v ydotoold >/dev/null 2>&1; then
            # No daemon binary shipped at all (older ydotool, e.g. Ubuntu 22.04/24.04):
            # direct /dev/uinput access works (user is in input group).
            # Use ydotool type only — character injection works in direct mode.
            # Do NOT use ydotool key (modifier key sequences produce raw digits).
            VOX_TYPING_TOOL="ydotool"
        elif command -v xdotool >/dev/null 2>&1; then
            # XWayland fallback — works for apps running under XWayland
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

    # ydotool >=1.0.4 (daemon-only, e.g. Ubuntu 24.10+/26.04) removed the
    # "type --delay <ms>" option that older direct-uinput ydotool versions
    # required (a startup delay while the temporary uinput device registered
    # with the compositor). Passing --delay to the new binary makes the whole
    # command fail ("unrecognized option"), silently falling back to
    # clipboard. Detect support once here so lib/type.sh can omit the flag on
    # newer installs while keeping it for older ones.
    if [[ "$VOX_TYPING_TOOL" == "ydotool" ]]; then
        if ydotool type --help 2>&1 | grep -qE -- '(^|[^-])--delay([^-]|$)'; then
            export VOX_YDOTOOL_SUPPORTS_DELAY="true"
        else
            export VOX_YDOTOOL_SUPPORTS_DELAY="false"
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
