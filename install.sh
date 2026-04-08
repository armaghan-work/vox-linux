#!/usr/bin/env bash
# install.sh — vox-linux one-command installer
#
# Usage:
#   ./install.sh              (installs with base.en model)
#   ./install.sh small.en     (installs with a larger, more accurate model)
#   ./install.sh --help
#
# Supported: Ubuntu 22.04+ / Debian 12+  (X11 and Wayland)

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()   { echo -e "${RED}  ✗ $*${NC}" >&2; }
banner(){ echo -e "${BLUE}$*${NC}"; }

INSTALL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vox-linux"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vox-linux"
BIN_DIR="$HOME/.local/bin"
MODEL="${1:-base.en}"

[[ "$MODEL" == "--help" ]] && {
    echo "Usage: ./install.sh [MODEL]"
    echo "Models: tiny.en  base.en(default)  small.en  medium.en  large-v3"
    exit 0
}

# ── 1. Detect environment ─────────────────────────────────────────────────────
step "Detecting environment…"

SESSION="${XDG_SESSION_TYPE:-x11}"
DISTRO="unknown"
command -v apt >/dev/null 2>&1 && DISTRO="debian"
command -v pacman >/dev/null 2>&1 && DISTRO="arch"

ok "Session type : $SESSION"
ok "Distribution : $DISTRO"

if [[ "$DISTRO" == "unknown" ]]; then
    warn "Distribution not detected. Only Debian/Ubuntu and Arch are officially supported."
    warn "You may need to install dependencies manually — continuing anyway."
fi

# ── 2. System packages ────────────────────────────────────────────────────────
step "Installing system packages…"

if [[ "$DISTRO" == "debian" ]]; then
    sudo apt-get update -qq

    PKGS=(git build-essential libnotify-bin)

    # Audio: pw-record is already available on Ubuntu 22.04+; add fallbacks
    command -v pw-record  >/dev/null 2>&1 || PKGS+=(pulseaudio-utils alsa-utils)
    command -v cmake      >/dev/null 2>&1 || PKGS+=(cmake)

    if [[ "$SESSION" == "wayland" ]]; then
        PKGS+=(ydotool wl-clipboard)
    else
        PKGS+=(xdotool xclip)
    fi

    sudo apt-get install -y "${PKGS[@]}"
    ok "Packages installed"

elif [[ "$DISTRO" == "arch" ]]; then
    PKGS=(git base-devel libnotify cmake)
    command -v pw-record >/dev/null 2>&1 || PKGS+=(pulseaudio)
    [[ "$SESSION" == "wayland" ]] && PKGS+=(ydotool wl-clipboard) || PKGS+=(xdotool xclip)
    sudo pacman -S --noconfirm --needed "${PKGS[@]}"
    ok "Packages installed"
fi

# ── 3. Wayland: ydotoold service and input group ─────────────────────────────
if [[ "$SESSION" == "wayland" ]]; then
    step "Setting up ydotool (Wayland text injection)…"

    # Add user to input group (required for ydotool uinput access)
    if ! groups "$USER" | grep -qw input; then
        warn "Adding $USER to 'input' group — a log out/in will be required."
        sudo usermod -aG input "$USER"
        _NEED_RELOGIN=true
    else
        ok "User already in 'input' group"
    fi

    # Create a systemd user service so ydotoold starts automatically
    local_svc_dir="$HOME/.config/systemd/user"
    mkdir -p "$local_svc_dir"

    cat > "$local_svc_dir/ydotoold.service" <<EOF
[Unit]
Description=ydotool daemon (vox-linux)
After=default.target

[Service]
ExecStart=/usr/bin/ydotoold --socket-path /tmp/.ydotool_socket --socket-perm 0660
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable ydotoold

    # Try to start; may fail until user re-logins (input group not active yet)
    systemctl --user start ydotoold 2>/dev/null && ok "ydotoold service started" \
        || warn "ydotoold will start automatically after next login"
fi

# ── 4. Build whisper.cpp and download model ───────────────────────────────────
step "Setting up whisper.cpp…"
bash "$INSTALL_DIR/setup/whisper.sh" "$MODEL"

# ── 5. Create user config (first-time only) ───────────────────────────────────
step "Creating user config…"
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.cfg" ]]; then
    cp "$INSTALL_DIR/config/defaults.cfg" "$CONFIG_DIR/config.cfg"
    ok "Created: $CONFIG_DIR/config.cfg"
else
    ok "Config already exists (preserved): $CONFIG_DIR/config.cfg"
fi

# ── 6. Install launcher to PATH ───────────────────────────────────────────────
step "Installing launcher…"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/vox" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/vox.sh" "\$@"
EOF
chmod +x "$BIN_DIR/vox"
ok "Installed: $BIN_DIR/vox"

# Ensure ~/.local/bin is in PATH
if ! echo ":${PATH}:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR is not in your PATH."
    warn "Add to ~/.bashrc or ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Make all scripts executable
chmod +x "$INSTALL_DIR/vox.sh" \
         "$INSTALL_DIR/setup/whisper.sh" \
         "$INSTALL_DIR/setup/hotkeys.sh" \
         "$INSTALL_DIR/uninstall.sh"

# ── 7. Keyboard shortcuts ─────────────────────────────────────────────────────
step "Setting up keyboard shortcuts…"
bash "$INSTALL_DIR/setup/hotkeys.sh" "$INSTALL_DIR"

# ── 8. Summary ────────────────────────────────────────────────────────────────
echo ""
banner "═══════════════════════════════════════════════"
banner "   vox-linux installed successfully!           "
banner "═══════════════════════════════════════════════"
echo ""
echo "  Hotkeys (change in $CONFIG_DIR/config.cfg):"
echo "    Super + V  →  🎤 Voice type anywhere"
echo "    Super + C  →  🤖 Voice to Copilot CLI"
echo ""
echo "  Test from terminal:"
echo "    vox type    (speak, press hotkey again to stop)"
echo "    vox chat    (same, but submits with Enter)"
echo ""
echo "  Config  : $CONFIG_DIR/config.cfg"
echo "  Models  : $DATA_DIR/models/"
echo "  Whisper : $DATA_DIR/whisper.cpp/"
echo ""

if [[ "${_NEED_RELOGIN:-false}" == "true" ]]; then
    echo -e "${YELLOW}  ⚠  IMPORTANT: Log out and back in for Wayland typing to work!${NC}"
    echo ""
fi
