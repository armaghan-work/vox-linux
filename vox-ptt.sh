#!/usr/bin/env bash
# vox-ptt.sh — Push-to-talk daemon for vox-linux
#
# Usage:
#   vox-ptt.sh start     — start the PTT daemon in the background
#   vox-ptt.sh stop      — stop the PTT daemon
#   vox-ptt.sh restart   — restart the daemon
#   vox-ptt.sh status    — show whether the daemon is running
#   vox-ptt.sh install   — install as a systemd user service (auto-start at login)
#   vox-ptt.sh uninstall — remove the systemd user service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEFAULTS="$SCRIPT_DIR/config/defaults.cfg"
USER_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/vox-linux/config.cfg"

[[ -f "$DEFAULTS" ]] && source "$DEFAULTS"
[[ -f "$USER_CFG" ]]  && source "$USER_CFG"

VOX_STATE_DIR="/tmp/vox-linux"
mkdir -p "$VOX_STATE_DIR"

PTT_PIDFILE="$VOX_STATE_DIR/ptt-daemon.pid"
PTT_DAEMON="$SCRIPT_DIR/lib/ptt_daemon.py"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${BLUE}▶ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✗ $*${NC}" >&2; }

# ── Dependency check ──────────────────────────────────────────────────────────
_check_deps() {
    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 not found. Install it first."
        exit 1
    fi
    if ! python3 -c "import evdev" 2>/dev/null; then
        err "python3-evdev not installed."
        err "  Debian/Ubuntu: sudo apt install python3-evdev"
        err "  Arch:          sudo pacman -S python-evdev"
        exit 1
    fi
    if ! groups "$USER" | grep -qw input; then
        err "User '$USER' is not in the 'input' group."
        err "Run: sudo usermod -aG input \$USER  — then log out and back in."
        exit 1
    fi
}

# ── PID file helpers ──────────────────────────────────────────────────────────
_daemon_running() {
    [[ -f "$PTT_PIDFILE" ]] && kill -0 "$(cat "$PTT_PIDFILE")" 2>/dev/null
}

_service_active() {
    systemctl --user is-active --quiet vox-ptt 2>/dev/null
}

# ── start / stop / restart / status ──────────────────────────────────────────
_ptt_start() {
    _check_deps

    if _daemon_running; then
        local pid; pid=$(cat "$PTT_PIDFILE")
        warn "PTT daemon already running (PID $pid)"
        return 0
    fi
    [[ -f "$PTT_PIDFILE" ]] && rm -f "$PTT_PIDFILE"

    export VOX_SH="${VOX_SH:-$SCRIPT_DIR/vox.sh}"
    export VOX_PTT_KEY="${VOX_PTT_KEY:-KEY_F9}"
    export VOX_PTT_MODE="${VOX_PTT_MODE:-type}"
    export VOX_LOG="${VOX_LOG:-$VOX_STATE_DIR/debug.log}"

    python3 "$PTT_DAEMON" &
    local pid=$!
    disown "$pid"
    echo "$pid" > "$PTT_PIDFILE"
    ok "PTT daemon started (PID $pid)"
    echo "   Hold ${VOX_PTT_KEY} to record — release to transcribe (mode: ${VOX_PTT_MODE})"
    echo ""
    warn "Reminder: '${VOX_PTT_KEY}' must NOT be registered as a GNOME/KDE hotkey."
    warn "If it is, both the GNOME shortcut and the PTT daemon will fire on press."
}

_ptt_stop() {
    if _service_active; then
        systemctl --user stop vox-ptt
        ok "vox-ptt.service stopped"
        return 0
    fi
    if ! _daemon_running; then
        [[ -f "$PTT_PIDFILE" ]] && rm -f "$PTT_PIDFILE"
        warn "PTT daemon not running"
        return 0
    fi
    local pid; pid=$(cat "$PTT_PIDFILE")
    kill "$pid"
    rm -f "$PTT_PIDFILE"
    ok "PTT daemon stopped (PID $pid)"
}

_ptt_status() {
    if _service_active; then
        ok "vox-ptt.service is active (systemd)"
        systemctl --user status vox-ptt --no-pager -l 2>/dev/null | tail -5 || true
        return 0
    fi
    if _daemon_running; then
        local pid; pid=$(cat "$PTT_PIDFILE")
        ok "PTT daemon running (PID $pid)"
        echo "   Key : ${VOX_PTT_KEY:-KEY_F9}"
        echo "   Mode: ${VOX_PTT_MODE:-type}"
    else
        warn "PTT daemon not running"
        echo "   Start manually : vox-ptt start"
        echo "   Auto-start     : vox-ptt install"
    fi
}

# ── systemd user service install / uninstall ──────────────────────────────────
_SERVICE_FILE="$HOME/.config/systemd/user/vox-ptt.service"

_ptt_install_service() {
    _check_deps
    mkdir -p "$(dirname "$_SERVICE_FILE")"

    # Stop any manually-started instance first
    if _daemon_running; then
        local pid; pid=$(cat "$PTT_PIDFILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$PTT_PIDFILE"
    fi

    local vox_sh="${VOX_SH:-$SCRIPT_DIR/vox.sh}"
    local ptt_key="${VOX_PTT_KEY:-KEY_F9}"
    local ptt_mode="${VOX_PTT_MODE:-type}"
    local ptt_log="$VOX_STATE_DIR/debug.log"

    cat > "$_SERVICE_FILE" <<EOF
[Unit]
Description=vox-linux push-to-talk daemon
Documentation=https://github.com/armaghan-work/vox-linux
# Wait until the graphical session is ready so /dev/input devices are available.
After=graphical-session.target

[Service]
Type=simple
ExecStart=python3 $PTT_DAEMON
Environment=VOX_SH=$vox_sh
Environment=VOX_PTT_KEY=$ptt_key
Environment=VOX_PTT_MODE=$ptt_mode
Environment=VOX_LOG=$ptt_log
# Restart if the daemon crashes or if a USB keyboard is re-plugged and the
# device node disappears (the daemon exits; systemd restarts it automatically).
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable vox-ptt
    systemctl --user start  vox-ptt
    ok "vox-ptt.service installed and started"
    ok "PTT daemon will auto-start at next login."
    echo ""
    echo "   Key : $ptt_key"
    echo "   Mode: $ptt_mode"
    echo ""
    warn "Reminder: '$ptt_key' must NOT be registered as a GNOME/KDE hotkey."
    warn "Change VOX_PTT_KEY in ~/.config/vox-linux/config.cfg, then run: vox-ptt install"
}

_ptt_uninstall_service() {
    if systemctl --user is-active --quiet vox-ptt 2>/dev/null; then
        systemctl --user stop vox-ptt
    fi
    systemctl --user disable vox-ptt 2>/dev/null || true
    rm -f "$_SERVICE_FILE"
    systemctl --user daemon-reload
    ok "vox-ptt.service removed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    start)     _ptt_start ;;
    stop)      _ptt_stop ;;
    restart)   _ptt_stop; sleep 0.3; _ptt_start ;;
    status)    _ptt_status ;;
    install)   _ptt_install_service ;;
    uninstall) _ptt_uninstall_service ;;
    *)
        echo "Usage: vox-ptt {start|stop|restart|status|install|uninstall}"
        echo ""
        echo "  start     Start PTT daemon (this session only)"
        echo "  stop      Stop PTT daemon"
        echo "  restart   Restart PTT daemon"
        echo "  status    Show daemon status"
        echo "  install   Install as systemd user service (auto-start at login)"
        echo "  uninstall Remove systemd user service"
        exit 1
        ;;
esac
