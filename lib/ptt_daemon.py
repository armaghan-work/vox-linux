#!/usr/bin/env python3
"""vox-linux PTT daemon — monitors keyboard for hold-to-record key.

Hold the PTT key to start recording; release it to stop and transcribe.

Key spec (VOX_PTT_KEY):
  KEY_F9                    — single key (default)
  KEY_RIGHTCTRL+KEY_F9      — modifier + trigger combo

Environment variables (all optional, have defaults):
  VOX_SH       — path to vox.sh launcher   (default: ~/.local/bin/vox)
  VOX_PTT_KEY  — evdev key spec             (default: KEY_F9)
  VOX_PTT_MODE — type | suggest             (default: type)
  VOX_LOG      — log file path              (default: /tmp/vox-linux/debug.log)

Known caveats (see DEVELOPMENT.md for details):
  • Requires user in 'input' group (same group needed by ydotool — already set up
    during install).
  • Bypasses GNOME hotkey system — the PTT key must NOT be registered as a GNOME
    shortcut or conflicts will occur (both handlers fire on press).
  • Events are read non-exclusively (device.grab() NOT called) so other apps still
    receive the key. Pick a key nothing else uses (F9, Right Ctrl, etc.).
  • On device hotplug (USB keyboard re-plugged), daemon must be restarted to pick
    up the new device. Systemd service handles this via Restart=on-failure.
"""

import asyncio
import datetime
import os
import signal
import subprocess
import sys

try:
    import evdev
    from evdev import ecodes, InputDevice, list_devices
except ImportError:
    print(
        "Error: python3-evdev not installed.\n"
        "  Debian/Ubuntu: sudo apt install python3-evdev\n"
        "  Arch:          sudo pacman -S python-evdev",
        file=sys.stderr,
    )
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────
VOX_SH   = os.environ.get("VOX_SH",      os.path.expanduser("~/.local/bin/vox"))
PTT_KEY  = os.environ.get("VOX_PTT_KEY", "KEY_F9")
PTT_MODE = os.environ.get("VOX_PTT_MODE","type")
VOX_LOG  = os.environ.get("VOX_LOG",     "/tmp/vox-linux/debug.log")

# ── Parse key spec ─────────────────────────────────────────────────────────────
_parts          = [k.strip() for k in PTT_KEY.split("+")]
_modifier_names = _parts[:-1]
_trigger_name   = _parts[-1]

def _resolve_key(name: str) -> int:
    code = getattr(ecodes, name, None)
    if code is None:
        print(
            f"Error: Unknown key '{name}'.\n"
            "  List all KEY_* names:\n"
            "    python3 -c \"from evdev import ecodes; "
            "print([k for k in dir(ecodes) if k.startswith('KEY_')])\"",
            file=sys.stderr,
        )
        sys.exit(1)
    return code

MODIFIER_CODES = [_resolve_key(m) for m in _modifier_names]
TRIGGER_CODE   = _resolve_key(_trigger_name)

# ── State ──────────────────────────────────────────────────────────────────────
# asyncio runs in a single thread, so no locks are needed for these globals.
held_keys: set = set()  # keycodes currently pressed (tracked across all devices)
recording = False       # True while a PTT recording is in progress

# ── Logging ────────────────────────────────────────────────────────────────────
def log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:12]
    try:
        with open(VOX_LOG, "a") as f:
            f.write(f"[{ts}] ptt_daemon: {msg}\n")
    except OSError:
        pass

# ── PTT callbacks ──────────────────────────────────────────────────────────────
def _modifiers_held() -> bool:
    return all(c in held_keys for c in MODIFIER_CODES)

def on_ptt_press() -> None:
    global recording
    if recording:
        return  # guard against key-repeat events (value == 2 is filtered, but be safe)
    recording = True
    log(f"PTT press  → ptt-start {PTT_MODE}")
    subprocess.Popen(
        [VOX_SH, "ptt-start", PTT_MODE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def on_ptt_release() -> None:
    global recording
    if not recording:
        return  # guard against spurious release with no matching press
    recording = False
    log("PTT release → ptt-stop")
    subprocess.Popen(
        [VOX_SH, "ptt-stop"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

# ── Device monitoring ──────────────────────────────────────────────────────────
async def monitor_device(device: InputDevice) -> None:
    """Read events from one keyboard device until it disconnects."""
    log(f"monitoring {device.path} ({device.name})")
    try:
        async for event in device.async_read_loop():
            if event.type != ecodes.EV_KEY:
                continue

            code, value = event.code, event.value

            # Track all held keys for modifier detection.
            # value 1 = press, 0 = release, 2 = repeat (ignored for held_keys).
            if value == 1:
                held_keys.add(code)
            elif value == 0:
                held_keys.discard(code)

            # Only act on the trigger key; ignore key-repeat (value == 2).
            if code == TRIGGER_CODE:
                if value == 1 and _modifiers_held():
                    on_ptt_press()
                elif value == 0:
                    # Fire release regardless of current modifier state —
                    # user may release trigger before modifiers.
                    on_ptt_release()

    except (OSError, asyncio.CancelledError):
        log(f"device disconnected or task cancelled: {device.path}")

def get_keyboard_devices() -> list:
    """Return all /dev/input/event* devices that look like keyboards.

    A device is considered a keyboard if it has EV_KEY capability and
    includes KEY_A (letter keys). This filters out mice, touchpads, etc.

    Requires user to be in the 'input' group (permissions on /dev/input/event*).
    The install.sh already adds the user to this group for ydotool support.
    """
    devices = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities()
            if ecodes.EV_KEY in caps and ecodes.KEY_A in caps[ecodes.EV_KEY]:
                devices.append(dev)
        except (PermissionError, OSError):
            pass
    return devices

# ── Signal handling ────────────────────────────────────────────────────────────
def _handle_sigterm(signum, frame):
    log("stopped (SIGTERM)")
    # If we were recording when killed, fire a stop so vox doesn't get stuck.
    if recording:
        log("PTT was active on exit — firing ptt-stop to clean up")
        subprocess.run(
            [VOX_SH, "ptt-stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    sys.exit(0)

signal.signal(signal.SIGTERM, _handle_sigterm)

# ── Main ───────────────────────────────────────────────────────────────────────
async def main() -> None:
    log(f"starting  key={PTT_KEY}  mode={PTT_MODE}  vox={VOX_SH}")

    devices = get_keyboard_devices()
    if not devices:
        log("ERROR: no accessible keyboard devices found")
        print(
            "Error: no keyboard input devices accessible.\n"
            "  Make sure your user is in the 'input' group:\n"
            "    sudo usermod -aG input $USER   (then log out and back in)",
            file=sys.stderr,
        )
        sys.exit(1)

    log(f"found {len(devices)} keyboard device(s)")
    await asyncio.gather(*(monitor_device(d) for d in devices))

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log("stopped (SIGINT)")
        if recording:
            subprocess.run(
                [VOX_SH, "ptt-stop"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
