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
import time
from typing import Optional

try:
    import evdev
    from evdev import ecodes, InputDevice, UInput, list_devices
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
all_devices: list        = []
held_keys: set           = set()
recording                = False   # True while any PTT recording is in progress
ui: Optional[UInput]     = None    # UInput passthrough device (forwards non-PTT keys)

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

    Python's evdev.UInput sets phys to 'py-evdev-uinput', which is non-empty
    but still a virtual device.  We must also exclude it to prevent the daemon
    from grabbing and monitoring its own passthrough device (infinite loop).
    """
    caps = dev.capabilities()
    if not (ecodes.EV_KEY in caps and ecodes.KEY_A in caps[ecodes.EV_KEY]):
        return False
    # Exclude virtual/uinput devices: empty phys (ydotool) or py-evdev marker
    return bool(dev.phys) and not dev.phys.startswith("py-evdev-uinput")

def _grab_all() -> None:
    for dev in all_devices:
        try:
            dev.grab()
        except OSError as exc:
            log(f"grab: WARNING: could not grab {dev.path}: {exc}")

def _ungrab_all() -> None:
    for dev in all_devices:
        try:
            dev.ungrab()
        except OSError:
            pass

def _setup_uinput() -> None:
    """Create a UInput passthrough device that mirrors all physical keyboards.

    Because we grab physical keyboards at daemon startup (preventing PTT keys
    from ever reaching the Wayland compositor), all non-PTT key events must be
    re-injected via this virtual device so normal typing continues to work.

    Why this fixes the first-press beep / tilde-spam bug
    ────────────────────────────────────────────────────
    Kernel-level auto-repeat is disabled on these keyboards (hardware default).
    The Wayland compositor (GNOME/Mutter) handles repeat via its own internal
    timer: once it receives a key-press event it starts firing synthetic repeat
    events to the focused application until it sees the matching key-release.

    With the old reactive-grab approach the compositor always received the
    initial PTT key-press (before the daemon could grab the device).  It then
    began generating compositor-level repeats — completely outside evdev —
    causing beeps or "~~~~" characters to appear for the entire duration of
    the key-hold.  Grabbing the device afterwards could not stop those repeats
    because they were generated internally by the compositor, not by evdev.

    With grab-at-startup + passthrough the compositor never sees the PTT key
    press at all, so it never starts its repeat timer.  Problem eliminated.
    """
    global ui
    if not all_devices:
        log("uinput: no keyboards available yet — passthrough skipped")
        return
    try:
        ui = UInput.from_device(*all_devices, name="vox-ptt-passthrough")
        log(f"uinput: passthrough device created ({ui.device.path})")
        # Give udev / libinput time to discover and open the new virtual device
        # before we grab the physical keyboards away from the compositor.
        time.sleep(0.5)
    except Exception as exc:
        log(f"uinput: WARNING: could not create passthrough: {exc!r}")
        log("uinput: falling back to reactive grab — first PTT press may beep")
        ui = None

# ── PTT callbacks ──────────────────────────────────────────────────────────────
def on_ptt_press(mode: str) -> None:
    global recording
    if recording:
        return
    recording = True
    # Keyboards are already grabbed at startup; no reactive grab needed here.
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
    # Keyboards stay grabbed; passthrough resumes forwarding non-PTT events.
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
            # ── EV_SYN: flush the current event group on the passthrough ──────
            if event.type == ecodes.EV_SYN:
                if ui and not recording:
                    try:
                        ui.write(event.type, event.code, event.value)
                    except OSError:
                        pass
                continue

            # ── Non-key events (LEDs, misc, relative axes …) ─────────────────
            if event.type != ecodes.EV_KEY:
                if ui and not recording:
                    try:
                        ui.write(event.type, event.code, event.value)
                    except OSError:
                        pass
                continue

            code, value = event.code, event.value

            if value == 1:
                held_keys.add(code)
            elif value == 0:
                held_keys.discard(code)

            # ── Check each PTT binding ────────────────────────────────────────
            is_ptt = False
            for binding in bindings:
                if code == binding.trigger_code:
                    modifiers_ok = all(c in held_keys for c in binding.modifier_codes)
                    if value == 1 and modifiers_ok:
                        on_ptt_press(binding.mode)
                        is_ptt = True
                    elif value == 0:
                        on_ptt_release()
                        is_ptt = True

            # ── Forward non-PTT key events through the passthrough ────────────
            # Skip forwarding while recording: the keyboard is intentionally
            # "silent" during speech capture (the user is speaking, not typing).
            if not is_ptt and not recording and ui:
                try:
                    ui.write(ecodes.EV_KEY, code, value)
                except OSError:
                    pass

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
            # If the passthrough device was not created at startup (daemon started
            # before any keyboard was present), try to create it now that we have
            # at least one keyboard to mirror capabilities from.
            if ui is None:
                _setup_uinput()
            # Grab only when the passthrough is active.  Without a passthrough,
            # grabbing would make the keyboard completely dead (events captured
            # but nowhere to forward them), so fall back to reactive grab instead.
            if ui is not None:
                try:
                    dev.grab()
                except OSError as exc:
                    log(f"hotplug: WARNING: could not grab {dev.path}: {exc}")
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
        log("PTT was active on exit — firing ptt-stop")
        subprocess.run(
            [VOX_SH, "ptt-stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    _ungrab_all()
    if ui:
        try:
            ui.close()
        except Exception:
            pass
    sys.exit(0)

signal.signal(signal.SIGTERM, _handle_sigterm)

# ── Main ───────────────────────────────────────────────────────────────────────
async def main() -> None:
    global all_devices
    binding_summary = "  ".join(f"{b.key_spec}→{b.mode}" for b in bindings)

    # Ensure the state/log directory exists (it lives in /tmp, wiped on reboot)
    os.makedirs(os.path.dirname(VOX_LOG), exist_ok=True)

    log(f"starting  bindings=[{binding_summary}]  vox={VOX_SH}")

    all_devices = get_keyboard_devices()
    if not all_devices:
        log("WARNING: no keyboards found at startup — hotplug watcher will detect them")
    else:
        log(f"found {len(all_devices)} keyboard device(s)")

    # Create the UInput passthrough device first so the Wayland compositor
    # (libinput) has time to discover it before we grab the physical keyboards.
    # Then grab all physical keyboards so PTT keys can never reach the compositor.
    if all_devices:
        _setup_uinput()
        if ui is not None:
            _grab_all()
        else:
            log("startup: uinput unavailable — using reactive grab (first press may beep)")

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
            subprocess.run(
                [VOX_SH, "ptt-stop"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        _ungrab_all()
        if ui:
            try:
                ui.close()
            except Exception:
                pass
