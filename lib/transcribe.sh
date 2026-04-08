#!/usr/bin/env bash
# lib/transcribe.sh — Whisper.cpp speech-to-text

# transcribe AUDIO_FILE
# Prints clean transcribed text to stdout; returns 1 on failure.
transcribe() {
    local audio_file="$1"
    local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/vox-linux"
    local model_file="$data_dir/models/ggml-${VOX_WHISPER_MODEL:-base.en}.bin"
    local output_base="/tmp/vox-linux/transcript"

    local whisper_bin
    whisper_bin=$(find_whisper_binary) || {
        notify_error "whisper-cli not found. Run install.sh first."
        return 1
    }

    if [[ ! -f "$model_file" ]]; then
        notify_error "Model not found: ggml-${VOX_WHISPER_MODEL:-base.en}.bin — run install.sh"
        return 1
    fi

    if [[ ! -s "$audio_file" ]]; then
        return 1
    fi

    local lang_args=()
    local lang="${VOX_LANGUAGE:-en}"
    [[ "$lang" != "auto" ]] && lang_args=(-l "$lang")

    # Run transcription; write to file for consistent output across versions
    "$whisper_bin" \
        -m "$model_file" \
        -f "$audio_file" \
        --no-timestamps \
        "${lang_args[@]}" \
        --output-txt \
        --output-file "$output_base" \
        >/dev/null 2>&1

    local txt_file="${output_base}.txt"
    [[ -f "$txt_file" ]] || return 1

    # Clean output:
    #  - drop [BLANK_AUDIO] / [MUSIC] / similar whisper artefacts
    #  - strip leading/trailing whitespace
    #  - join lines into a single line
    local result
    result=$(
        grep -v '^\[' "$txt_file" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//'
    )

    rm -f "$txt_file"

    [[ -z "$result" ]] && return 1
    echo "$result"
}
