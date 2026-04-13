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
    local _log="${VOX_LOG:-/tmp/vox-linux/debug.log}"
    _alog() { printf '[%s] audio_stop: %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >> "$_log"; }

    _alog "start (pid_file=$pid_file)"

    [[ -f "$pid_file" ]] || { _alog "no pidfile — skipping"; return 0; }

    local pid
    pid=$(cat "$pid_file")
    rm -f "$pid_file"
    _alog "recorder pid=$pid"

    if kill -0 "$pid" 2>/dev/null; then
        _alog "sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true

        # Wait up to 2 s for graceful shutdown.
        # Use i=$(( i + 1 )) — never (( i++ )) — to avoid set -e exit when i=0.
        local i=0
        while kill -0 "$pid" 2>/dev/null && [[ $i -lt 20 ]]; do
            sleep 0.1
            i=$(( i + 1 ))
        done
        _alog "after TERM wait: i=$i still_alive=$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"

        # Force-kill if still alive (handles pw-record stuck in PipeWire I/O)
        if kill -0 "$pid" 2>/dev/null; then
            _alog "sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    else
        _alog "process already gone"
    fi

    # Do NOT call sync — it flushes ALL filesystem buffers and can block for
    # minutes on systems with dirty pages or network mounts.
    sleep 0.3   # let the file handle close fully
    _alog "done"
}
