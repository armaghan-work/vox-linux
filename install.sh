#!/usr/bin/env bash
# install.sh — vox-linux one-command installer
#
# Usage:
#   ./install.sh              (installs with base.en model)
#   ./install.sh small.en     (installs with a larger, more accurate model)
#   ./install.sh --help
#
# Supported: Ubuntu 22.04+ / Debian 12+  (X11 and Wayland)
# Run as your NORMAL user, NOT as root.

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

# ── 0. Must NOT run as root ───────────────────────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
    err "Do not run this installer as root or with sudo!"
    err "Run it as your normal user:  ./install.sh"
    err "The installer will call sudo automatically when needed."
    exit 1
fi

# ── 1. Detect environment ─────────────────────────────────────────────────────
step "Detecting environment…"

# Detect session type robustly — env vars may be missing in some terminals
_detect_session() {
    # Direct environment check
    [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && { echo "wayland"; return; }
    [[ -n "${WAYLAND_DISPLAY:-}" ]]             && { echo "wayland"; return; }

    # loginctl fallback: works even when env vars are not exported to subshells
    local session_id
    session_id=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk -v u="$USER" '$3==u {print $1; exit}')
    if [[ -n "$session_id" ]]; then
        local stype
        stype=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)
        [[ "$stype" == "wayland" ]] && { echo "wayland"; return; }
    fi

    echo "x11"
}

SESSION=$(_detect_session)
DISTRO="unknown"
command -v apt    >/dev/null 2>&1 && DISTRO="debian"
command -v pacman >/dev/null 2>&1 && DISTRO="arch"

ok "Session type : $SESSION"
ok "Distribution : $DISTRO"
ok "User         : $USER  (home: $HOME)"

if [[ "$DISTRO" == "unknown" ]]; then
    warn "Distribution not detected. Only Debian/Ubuntu and Arch are officially supported."
    warn "You may need to install dependencies manually — continuing anyway."
fi

# ── 2. System packages ────────────────────────────────────────────────────────
step "Installing system packages…"

if [[ "$DISTRO" == "debian" ]]; then
    sudo apt-get update -qq

    PKGS=(git build-essential libnotify-bin)
    command -v pw-record >/dev/null 2>&1 || PKGS+=(pulseaudio-utils alsa-utils)
    command -v cmake     >/dev/null 2>&1 || PKGS+=(cmake)

    # Install both wayland AND x11 tools so it works regardless of session
    PKGS+=(ydotool wl-clipboard xdotool xclip)

    sudo apt-get install -y "${PKGS[@]}"
    ok "Packages installed"

elif [[ "$DISTRO" == "arch" ]]; then
    PKGS=(git base-devel libnotify cmake)
    command -v pw-record >/dev/null 2>&1 || PKGS+=(pulseaudio)
    PKGS+=(ydotool wl-clipboard xdotool xclip)
    sudo pacman -S --noconfirm --needed "${PKGS[@]}"
    ok "Packages installed"
fi

# ── 3. input group + ydotoold service (needed for ydotool on Wayland) ─────────
step "Setting up ydotool…"

if ! groups "$USER" | grep -qw input; then
    warn "Adding $USER to 'input' group — a log out/in will be required."
    sudo usermod -aG input "$USER"
    _NEED_RELOGIN=true
else
    ok "User already in 'input' group"
fi

svc_dir="$HOME/.config/systemd/user"
mkdir -p "$svc_dir"

cat > "$svc_dir/ydotoold.service" <<EOF
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
systemctl --user start ydotoold 2>/dev/null \
    && ok "ydotoold service started" \
    || warn "ydotoold will start automatically after next login"

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

# Auto-add ~/.local/bin to PATH in ~/.bashrc if missing
if ! echo ":${PATH}:" | grep -q ":$BIN_DIR:"; then
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]]; then
            echo "" >> "$rc"
            echo '# vox-linux: add ~/.local/bin to PATH' >> "$rc"
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            ok "Added $BIN_DIR to PATH in $rc"
        fi
    done
    warn "PATH updated — run:  source ~/.bashrc   (or open a new terminal)"
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
echo "  Hotkeys:"
echo "    Ctrl+Alt+V  →  🎤 Voice type anywhere"
echo "    Ctrl+Alt+S  →  🤖 Voice AI suggest (gh copilot suggest)"
echo ""
echo "  Test from terminal:"
echo "    vox type      (speak, press hotkey again to stop)"
echo "    vox suggest   (speak, runs gh copilot suggest)"
echo ""
echo "  Config  : $CONFIG_DIR/config.cfg"
echo "  Models  : $DATA_DIR/models/"
echo ""

if [[ "${_NEED_RELOGIN:-false}" == "true" ]]; then
    echo -e "${YELLOW}  ⚠  IMPORTANT: Log out and back in before using vox!${NC}"
    echo ""
fi

