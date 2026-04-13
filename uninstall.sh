#!/usr/bin/env bash
# uninstall.sh — Remove vox-linux components

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
step() { echo -e "${BLUE}▶ $*${NC}"; }

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vox-linux"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vox-linux"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "This will remove:"
echo "  • $BIN_DIR/vox  and  $BIN_DIR/vox-ptt"
echo "  • $DATA_DIR   (whisper binary + models)"
echo "  • GNOME/KDE hotkeys"
echo "  • vox-ptt systemd user service"
echo "  • /etc/udev/rules.d/60-uinput.rules  (ydotool input access)"
echo ""
echo "Your config at $CONFIG_DIR/config.cfg will be KEPT."
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── Launchers ─────────────────────────────────────────────────────────────────
step "Removing launchers…"
rm -f "$BIN_DIR/vox" "$BIN_DIR/vox-ptt"
ok "Removed $BIN_DIR/vox  and  $BIN_DIR/vox-ptt"

# ── Data (whisper + models) ───────────────────────────────────────────────────
step "Removing data directory…"
if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
    ok "Removed $DATA_DIR"
else
    warn "$DATA_DIR not found — skipping"
fi

# ── GNOME hotkeys ─────────────────────────────────────────────────────────────
step "Removing GNOME shortcuts…"
if command -v gsettings >/dev/null 2>&1; then
    python3 - <<'PYEOF'
import subprocess, ast

media_keys = "org.gnome.settings-daemon.plugins.media-keys"
custom_base = f"{media_keys}.custom-keybinding"
vox_paths = [
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vox-type/",
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vox-suggest/",
]

raw = subprocess.check_output(['gsettings', 'get', media_keys, 'custom-keybindings'], text=True).strip()
try:
    current = ast.literal_eval(raw.replace('@as ', ''))
    if not isinstance(current, list): current = []
except Exception:
    current = []

remaining = [p for p in current if p not in vox_paths]
subprocess.run(['gsettings', 'set', media_keys, 'custom-keybindings', str(remaining).replace('"', "'")])
print(f"  Removed {len(current) - len(remaining)} vox-linux GNOME shortcuts")
PYEOF
fi

# ── vox-ptt systemd service ───────────────────────────────────────────────────
step "Removing vox-ptt service…"
PTT_SVC="$HOME/.config/systemd/user/vox-ptt.service"
if systemctl --user is-active --quiet vox-ptt 2>/dev/null; then
    systemctl --user stop vox-ptt
fi
systemctl --user disable vox-ptt 2>/dev/null || true
if [[ -f "$PTT_SVC" ]]; then
    rm -f "$PTT_SVC"
    systemctl --user daemon-reload
    ok "vox-ptt service removed"
else
    warn "vox-ptt service not found — skipping"
fi

# ── udev rule for /dev/uinput ─────────────────────────────────────────────────
step "Removing udev rule…"
UDEV_FILE="/etc/udev/rules.d/60-uinput.rules"
if [[ -f "$UDEV_FILE" ]]; then
    sudo rm -f "$UDEV_FILE"
    sudo udevadm control --reload-rules && sudo udevadm trigger
    ok "Removed $UDEV_FILE"
else
    warn "$UDEV_FILE not found — skipping"
fi

# ── ydotoold service (legacy — may exist from older installs) ─────────────────
step "Removing ydotoold service (if present)…"
SVC="$HOME/.config/systemd/user/ydotoold.service"
if [[ -f "$SVC" ]]; then
    systemctl --user stop ydotoold 2>/dev/null || true
    systemctl --user disable ydotoold 2>/dev/null || true
    rm -f "$SVC"
    systemctl --user daemon-reload
    ok "ydotoold service removed"
else
    warn "ydotoold service not found — skipping"
fi

echo ""
echo "vox-linux uninstalled.  Config kept at $CONFIG_DIR"
echo "Remove it manually if desired: rm -rf $CONFIG_DIR"
echo ""
