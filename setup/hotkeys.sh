#!/usr/bin/env bash
# setup/hotkeys.sh — Register keyboard shortcuts for vox-linux
#
# Usage: hotkeys.sh INSTALL_DIR [HOTKEY_TYPE=Super+V] [HOTKEY_CHAT=Super+C]
#
# Supports GNOME and KDE Plasma.  Falls back to printing manual instructions.

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "${BLUE}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }

INSTALL_DIR="${1:?Usage: hotkeys.sh INSTALL_DIR}"
HOTKEY_TYPE="${2:-<Super>v}"
HOTKEY_CHAT="${3:-<Super>c}"
VOX_CMD="$INSTALL_DIR/vox.sh"

# ── GNOME ─────────────────────────────────────────────────────────────────────
_setup_gnome() {
    step "Configuring GNOME keyboard shortcuts…"

    local media_keys="org.gnome.settings-daemon.plugins.media-keys"
    local custom_base="${media_keys}.custom-keybinding"
    local path_type="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vox-type/"
    local path_chat="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vox-chat/"

    # Merge with existing custom shortcuts using Python to avoid fragile bash string manip
    local merged
    merged=$(python3 - "$media_keys" "$path_type" "$path_chat" <<'PYEOF'
import sys, subprocess, ast

media_keys, path_type, path_chat = sys.argv[1], sys.argv[2], sys.argv[3]
raw = subprocess.check_output(['gsettings', 'get', media_keys, 'custom-keybindings'], text=True).strip()
try:
    current = ast.literal_eval(raw.replace('@as ', ''))
    if not isinstance(current, list): current = []
except Exception:
    current = []
new_paths = [p for p in [path_type, path_chat] if p not in current]
merged = new_paths + current
print(str(merged).replace('"', "'"))
PYEOF
    )

    gsettings set "$media_keys" custom-keybindings "$merged"

    # vox-type
    gsettings set "${custom_base}:${path_type}" name    "Vox: Type Anywhere"
    gsettings set "${custom_base}:${path_type}" command "$VOX_CMD type"
    gsettings set "${custom_base}:${path_type}" binding "$HOTKEY_TYPE"

    # vox-chat
    gsettings set "${custom_base}:${path_chat}" name    "Vox: Voice to Copilot"
    gsettings set "${custom_base}:${path_chat}" command "$VOX_CMD chat"
    gsettings set "${custom_base}:${path_chat}" binding "$HOTKEY_CHAT"

    ok "GNOME shortcuts set: $HOTKEY_TYPE (type)  $HOTKEY_CHAT (chat)"
}

# ── KDE Plasma ────────────────────────────────────────────────────────────────
_setup_kde() {
    step "Configuring KDE keyboard shortcuts…"

    if ! command -v kwriteconfig5 >/dev/null 2>&1 && \
       ! command -v kwriteconfig6 >/dev/null 2>&1; then
        warn "kwriteconfig not found — printing manual instructions below."
        return 1
    fi

    local kw
    kw=$(command -v kwriteconfig6 2>/dev/null || command -v kwriteconfig5)

    "$kw" --file kglobalshortcutsrc --group "vox-linux" \
        --key "vox-type" "$HOTKEY_TYPE,none,Vox: Type Anywhere"
    "$kw" --file kglobalshortcutsrc --group "vox-linux" \
        --key "vox-chat" "$HOTKEY_CHAT,none,Vox: Voice to Copilot"

    ok "KDE shortcuts written (restart KDE or run: qdbus org.kde.kglobalaccel /component/vox-linux invokeAction)"
}

# ── Manual fallback instructions ──────────────────────────────────────────────
_print_manual() {
    echo ""
    warn "Automatic hotkey setup not available for your desktop environment."
    echo "  Set up two custom keyboard shortcuts manually:"
    echo ""
    echo "  Shortcut 1 — Voice Type Anywhere"
    echo "    Command : $VOX_CMD type"
    echo "    Hotkey  : $HOTKEY_TYPE"
    echo ""
    echo "  Shortcut 2 — Voice to Copilot"
    echo "    Command : $VOX_CMD chat"
    echo "    Hotkey  : $HOTKEY_CHAT"
    echo ""
    echo "  GNOME: Settings → Keyboard → Custom Shortcuts"
    echo "  KDE  : System Settings → Shortcuts → Custom Shortcuts"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
if command -v gsettings >/dev/null 2>&1 && \
   gsettings list-schemas 2>/dev/null | grep -q "org.gnome.settings-daemon"; then
    _setup_gnome
elif [[ -d "$HOME/.config/kglobalshortcutsrc" ]] || \
     command -v kwriteconfig5 >/dev/null 2>&1 || \
     command -v kwriteconfig6 >/dev/null 2>&1; then
    _setup_kde || _print_manual
else
    _print_manual
fi
