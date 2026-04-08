#!/usr/bin/env bash
# setup/whisper.sh — Build whisper.cpp and download a GGML model
#
# Usage: whisper.sh [MODEL]   (default: base.en)

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step()  { echo -e "${BLUE}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
err()   { echo -e "${RED}✗ $*${NC}" >&2; }

MODEL="${1:-base.en}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vox-linux"
WHISPER_DIR="$DATA_DIR/whisper.cpp"
MODEL_DIR="$DATA_DIR/models"

# ── Helper: find built binary ─────────────────────────────────────────────────
_find_built_binary() {
    for p in \
        "$WHISPER_DIR/build/bin/whisper-cli" \
        "$WHISPER_DIR/build/bin/main" \
        "$WHISPER_DIR/whisper-cli" \
        "$WHISPER_DIR/main"; do
        [[ -x "$p" ]] && echo "$p" && return 0
    done
    return 1
}

# ── Build whisper.cpp ─────────────────────────────────────────────────────────
build_whisper() {
    if _find_built_binary >/dev/null 2>&1; then
        ok "whisper.cpp already built — skipping"
        return 0
    fi

    # Ensure build tools are present
    for tool in git make gcc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            err "Missing build tool: $tool"
            err "Run: sudo apt install git build-essential"
            exit 1
        fi
    done

    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR"

    if [[ ! -d "whisper.cpp" ]]; then
        step "Cloning whisper.cpp (shallow clone)…"
        git clone --depth=1 https://github.com/ggerganov/whisper.cpp.git
    else
        step "Updating whisper.cpp…"
        git -C whisper.cpp pull --ff-only || warn "Could not update whisper.cpp (continuing with existing)"
    fi

    cd "$WHISPER_DIR"

    step "Building whisper.cpp (make -j$(nproc)) — this takes 2–5 minutes…"

    # Try cmake first (preferred for newer releases)
    if command -v cmake >/dev/null 2>&1; then
        mkdir -p build && cd build
        cmake .. -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
            2>&1 | tail -3
        make -j"$(nproc)" whisper-cli 2>&1 | tail -5 || make -j"$(nproc)" main 2>&1 | tail -5
        cd "$WHISPER_DIR"
    else
        # Plain make fallback
        make -j"$(nproc)" whisper-cli 2>&1 | tail -5 || make -j"$(nproc)" 2>&1 | tail -5
    fi

    if ! _find_built_binary >/dev/null 2>&1; then
        err "Build failed — binary not found after make"
        err "Check build output above; you may need: sudo apt install cmake"
        exit 1
    fi

    ok "whisper.cpp built: $(_find_built_binary)"
}

# ── Download GGML model ───────────────────────────────────────────────────────
download_model() {
    mkdir -p "$MODEL_DIR"
    local model_file="$MODEL_DIR/ggml-${MODEL}.bin"

    if [[ -f "$model_file" ]]; then
        ok "Model already present: $model_file"
        return 0
    fi

    step "Downloading model: $MODEL (~$(model_size "$MODEL"))…"

    # Prefer whisper.cpp's own download script (validates checksum)
    local dl_script="$WHISPER_DIR/models/download-ggml-model.sh"
    if [[ -f "$dl_script" ]]; then
        bash "$dl_script" "$MODEL"
        # Script puts the file in whisper.cpp/models/; move it to our location
        local src="$WHISPER_DIR/models/ggml-${MODEL}.bin"
        [[ -f "$src" ]] && mv "$src" "$model_file"
    fi

    # Direct download fallback (HuggingFace mirror)
    if [[ ! -f "$model_file" ]]; then
        local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"
        curl --location --progress-bar --retry 3 "$url" -o "$model_file"
    fi

    [[ -f "$model_file" ]] || { err "Download failed for model: $MODEL"; exit 1; }
    ok "Model saved: $model_file"
}

model_size() {
    case "$1" in
        tiny.en)   echo "77 MB" ;;
        base.en)   echo "148 MB" ;;
        small.en)  echo "488 MB" ;;
        medium.en) echo "1.5 GB" ;;
        large-v3)  echo "3.1 GB" ;;
        *)         echo "?" ;;
    esac
}

build_whisper
download_model
