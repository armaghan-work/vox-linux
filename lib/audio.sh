#!/usr/bin/env bash
# lib/audio.sh — Audio recording (PipeWire / PulseAudio / ALSA)

# Start recording to AUDIO_FILE in the background; save PID to PIDFILE.
audio_start() {
    local audio_file="$1"
    local pid_file="$2"

    case "$VOX_AUDIO_BACKEND" in
        pipewire)
            pw-record --rate=16000 --channels=1 --format=s16 "$audio_file" \
                >/dev/null 2>&1 &
            ;;
        pulseaudio)
            parecord --rate=16000 --channels=1 --format=s16le \
                --file-format=wav "$audio_file" >/dev/null 2>&1 &
            ;;
        alsa)
            arecord -q -r 16000 -c 1 -f S16_LE -t wav "$audio_file" \
                >/dev/null 2>&1 &
            ;;
    esac

    local pid=$!
    disown "$pid"        # detach so it survives after this script exits
    echo "$pid" > "$pid_file"
}

# Stop the background recorder gracefully, then wait for file flush.
audio_stop() {
    local pid_file="$1"

    [[ -f "$pid_file" ]] || return 0

    local pid
    pid=$(cat "$pid_file")
    rm -f "$pid_file"

    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true

        # Wait up to 3 s for graceful shutdown
        local i=0
        while kill -0 "$pid" 2>/dev/null && (( i < 30 )); do
            sleep 0.1
            (( i++ ))
        done

        # Force-kill if still alive
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi

    sync        # flush OS buffers
    sleep 0.2   # let the file handle close fully
}
