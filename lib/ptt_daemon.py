#!/usr/bin/env python3
"""vox-linux PTT daemon — monitors keyboard for hold-to-record keys.

Hold a PTT key to start recording; release it to stop and transcribe.

Key spec format:
  KEY_F9                    — single key
  KEY_RIGHTCTRL+KEY_F9      — modifier + trigger combo

Environment variables:
  VOX_SH              — path to vox.sh launcher   (default: ~/.local/bin/vox)
  VOX_PTT_TYPE_KEY    — hold to type at cursor     (default: KEY_F9)
  VOX_PTT_SUGGEST_KEY — hold to run AI suggest     (default: empty = disabled)
  VOX_LOG             — log file path              (default: /tmp/vox-linux/debug.log)

  Legacy (still supported):
  VOX_PTT_KEY         — mapped to VOX_PTT_TYPE_KEY if TYPE_KEY is not set
"""

import asyncio
import ctypes
import datetime
import os
import re
import signal
import subprocess
import sys
from typing import Optional

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

# ── Config file loading ────────────────────────────────────────────────────────
def _source_config() -> None:
    """Override VOX_PTT_* env vars by reading the vox-linux config files directly.

    The systemd service file bakes in environment variables at install time.
    Sourcing the config files here means users can edit config.cfg and simply
    restart the daemon (vox-ptt restart) — no need to re-run 'vox-ptt install'.
    Defaults are loaded first, then the user config overrides them.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    xdg_cfg    = os.environ.get("XDG_CONFIG_HOME",
                                os.path.join(os.path.expanduser("~"), ".config"))
    files = [
        os.path.join(script_dir, "..", "config", "defaults.cfg"),
        os.path.join(xdg_cfg, "vox-linux", "config.cfg"),
    ]
    # Matches bash assignments like:  VOX_PTT_SUGGEST_KEY="KEY_F8"
    #                               or VOX_PTT_SUGGEST_KEY=KEY_F8
    _re = re.compile(r'^(VOX_PTT_\w+)\s*=\s*"?(.*?)"?\s*(?:#.*)?$')
    for path in files:
        try:
            with open(path) as fh:
                for line in fh:
                    m = _re.match(line.strip())
                    if m:
                        os.environ[m.group(1)] = m.group(2)
        except OSError:
            pass

_source_config()

# ── Configuration ──────────────────────────────────────────────────────────────
VOX_SH  = os.environ.get("VOX_SH", os.path.expanduser("~/.local/bin/vox"))
VOX_LOG = os.environ.get("VOX_LOG", "/tmp/vox-linux/debug.log")

# Backward compat: VOX_PTT_KEY maps to type key if new var not set
_legacy_key = os.environ.get("VOX_PTT_KEY", "")
PTT_TYPE_KEY    = os.environ.get("VOX_PTT_TYPE_KEY",    _legacy_key or "KEY_F9")
PTT_SUGGEST_KEY = os.environ.get("VOX_PTT_SUGGEST_KEY", "")

# ── Key binding ────────────────────────────────────────────────────────────────
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

class PTTBinding:
    """One hold-to-record binding: a key spec and the mode it triggers."""
    def __init__(self, key_spec: str, mode: str):
        parts = [k.strip() for k in key_spec.split("+")]
        self.modifier_codes = [_resolve_key(m) for m in parts[:-1]]
        self.trigger_code   = _resolve_key(parts[-1])
        self.mode           = mode
        self.key_spec       = key_spec

# Build active bindings (skip empty / disabled entries)
bindings: list = []
if PTT_TYPE_KEY:
    bindings.append(PTTBinding(PTT_TYPE_KEY,    "type"))
if PTT_SUGGEST_KEY:
    bindings.append(PTTBinding(PTT_SUGGEST_KEY, "suggest"))

if not bindings:
    print("Error: no PTT keys configured. Set VOX_PTT_TYPE_KEY in config.cfg", file=sys.stderr)
    sys.exit(1)

# ── State ──────────────────────────────────────────────────────────────────────
all_devices: list = []
held_keys: set    = set()
recording         = False   # True while any PTT recording is in progress

# ── Logging ────────────────────────────────────────────────────────────────────
def log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:12]
    try:
        with open(VOX_LOG, "a") as f:
            f.write(f"[{ts}] ptt_daemon: {msg}\n")
    except OSError:
        pass

# ── Device grab / ungrab ───────────────────────────────────────────────────────
def _is_real_keyboard(dev: InputDevice) -> bool:
    """Return True only for physical/KVM keyboards; False for virtual uinput devices.

    ydotool creates a transient uinput device at /dev/input/eventN while
    injecting text.  That device has EV_KEY + KEY_A just like a real keyboard,
    but its physical path (dev.phys) is empty.  Real keyboards — USB, PS/2,
    Bluetooth, KVM adapters — always have a non-empty physical path such as
    'usb-0000:00:14.0-2/input0' or 'XX:XX:XX:XX:XX:XX'.  Grabbing a ydotool
    virtual device would swallow the injected keystrokes before they reach the
    focused window.
    """
    caps = dev.capabilities()
    if not (ecodes.EV_KEY in caps and ecodes.KEY_A in caps[ecodes.EV_KEY]):
        return False
    return bool(dev.phys)   # empty phys → virtual/uinput → skip

def _grab_all() -> None:
    for dev in all_devices:
        try:
            dev.grab()
        except OSError:
            pass

def _ungrab_all() -> None:
    for dev in all_devices:
        try:
            dev.ungrab()
        except OSError:
            pass

# ── PTT callbacks ──────────────────────────────────────────────────────────────
def on_ptt_press(mode: str) -> None:
    global recording
    if recording:
        return
    recording = True
    _grab_all()
    log(f"PTT press  → ptt-start {mode}")
    subprocess.Popen(
        [VOX_SH, "ptt-start", mode],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def on_ptt_release() -> None:
    global recording
    if not recording:
        return
    recording = False
    _ungrab_all()
    log("PTT release → ptt-stop")
    subprocess.Popen(
        [VOX_SH, "ptt-stop"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

# ── Device monitoring ──────────────────────────────────────────────────────────
async def monitor_device(device: InputDevice) -> None:
    log(f"monitoring {device.path} ({device.name})")
    try:
        async for event in device.async_read_loop():
            if event.type != ecodes.EV_KEY:
                continue

            code, value = event.code, event.value

            if value == 1:
                held_keys.add(code)
            elif value == 0:
                held_keys.discard(code)

            # Check each binding for this event
            for binding in bindings:
                if code == binding.trigger_code:
                    modifiers_ok = all(c in held_keys for c in binding.modifier_codes)
                    if value == 1 and modifiers_ok:
                        on_ptt_press(binding.mode)
                    elif value == 0:
                        on_ptt_release()

    except (OSError, asyncio.CancelledError):
        log(f"device disconnected or task cancelled: {device.path}")
    finally:
        # Remove from the live list so hotplug_watcher can re-add it if it
        # reconnects (e.g. KVM switch returning to this machine).
        try:
            all_devices.remove(device)
        except ValueError:
            pass

async def hotplug_watcher() -> None:
    """Detect keyboards that appear after startup (KVM switch, USB hot-plug).

    Uses inotify to watch /dev/input/ — the kernel wakes us instantly when a
    new device node is created; there is zero overhead between events.
    Falls back to a 5-second poll if inotify_init1 is unavailable.
    """
    _IN_CREATE = 0x00000100   # inotify: file created in watched directory
    _libc      = ctypes.CDLL(None, use_errno=True)

    ifd = _libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if ifd < 0:
        log("inotify unavailable — falling back to 5 s poll")
        await _hotplug_poll()
        return

    _libc.inotify_add_watch(ifd, b"/dev/input", _IN_CREATE)

    loop  = asyncio.get_running_loop()
    ready = asyncio.Event()
    loop.add_reader(ifd, ready.set)
    try:
        while True:
            await ready.wait()
            ready.clear()
            try:
                os.read(ifd, 4096)   # drain buffered inotify records
            except OSError:
                pass
            await asyncio.sleep(0.5)  # let udev finish initialising the node
            _check_new_keyboards()
    finally:
        loop.remove_reader(ifd)
        os.close(ifd)

async def _hotplug_poll() -> None:
    """Fallback hotplug detection: poll every 5 s (used only if inotify fails)."""
    while True:
        await asyncio.sleep(5)
        _check_new_keyboards()

def _check_new_keyboards() -> None:
    """Add any keyboard devices not yet in all_devices."""
    known = {dev.path for dev in all_devices}
    for path in list_devices():
        if path in known:
            continue
        try:
            dev = InputDevice(path)
            if not _is_real_keyboard(dev):
                dev.close()
                continue
            log(f"hotplug: new keyboard {dev.path} ({dev.name})")
            all_devices.append(dev)
            if recording:
                try:
                    dev.grab()
                except OSError:
                    pass
            asyncio.create_task(monitor_device(dev))
        except (PermissionError, OSError):
            pass

def get_keyboard_devices() -> list:
    devices = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            if _is_real_keyboard(dev):
                devices.append(dev)
            else:
                dev.close()
        except (PermissionError, OSError):
            pass
    return devices

# ── Signal handling ────────────────────────────────────────────────────────────
def _handle_sigterm(signum, frame):
    log("stopped (SIGTERM)")
    if recording:
        log("PTT was active on exit — ungrabbing and firing ptt-stop")
        _ungrab_all()
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
    global all_devices
    binding_summary = "  ".join(f"{b.key_spec}→{b.mode}" for b in bindings)
    log(f"starting  bindings=[{binding_summary}]  vox={VOX_SH}")

    all_devices = get_keyboard_devices()
    if not all_devices:
        log("WARNING: no keyboards found at startup — hotplug watcher will detect them")
    else:
        log(f"found {len(all_devices)} keyboard device(s)")

    await asyncio.gather(
        *(monitor_device(d) for d in all_devices),
        hotplug_watcher(),
    )

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log("stopped (SIGINT)")
        if recording:
            _ungrab_all()
            subprocess.run(
                [VOX_SH, "ptt-stop"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
