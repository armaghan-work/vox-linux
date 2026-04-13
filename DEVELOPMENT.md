# vox-linux — Development Reference

## Architecture Overview

```
vox.sh (entry point, toggle logic, trap/cleanup)
├── lib/notify.sh     — desktop notification wrappers (replace-ID stacking)
├── lib/detect.sh     — auto-detect display server, audio backend, typing tool
├── lib/audio.sh      — start/stop background recorder (PipeWire/PulseAudio/ALSA)
├── lib/transcribe.sh — run whisper.cpp, clean output
└── lib/type.sh       — clipboard copy + key simulation (paste injection)

config/defaults.cfg   — default VOX_* config variables
setup/whisper.sh      — build whisper.cpp from source, download model
setup/hotkeys.sh      — register GNOME/KDE keyboard shortcuts
install.sh            — one-command installer (calls setup/*)
uninstall.sh          — remove installed files
```

### Toggle flow

```
Hotkey press 1  →  vox.sh type
                    └─ no lockfile → _cmd_start
                        ├─ write MODE_FILE, touch LOCKFILE
                        ├─ notify_recording  (🔴 "Recording…")
                        ├─ audio_start  (background recorder, disown)
                        └─ _VOX_KEEP_LOCK=true  → EXIT trap preserves lockfile

Hotkey press 2  →  vox.sh type
                    └─ lockfile exists → _cmd_stop
                        ├─ capture VOX_FOCUSED_WINDOW  (before focus stolen)
                        ├─ notify_processing  (⏳ "Transcribing…")
                        ├─ audio_stop  (SIGTERM recorder, wait flush)
                        ├─ transcribe  (whisper.cpp → text)
                        └─ type_text   (clipboard copy → restore focus → Ctrl+V)
                            ├─ success → notify_done  (✅ "Typed")
                            └─ failure → notify_clipboard  (📋 "Paste manually")
```

### Cleanup / crash safety (`trap`)

| Trap | Condition | Action |
|------|-----------|--------|
| `ERR` | Any unhandled command fails (`set -e`) | `notify_error` "crashed" |
| `EXIT` | Always on script exit | Remove `LOCKFILE`, `MODE_FILE`, `_VOX_NOTIF_ID_FILE` (unless `_cmd_start` succeeded) |

---

## System Requirements (Target: Ubuntu 22.04+ / Debian 12+)

| Component | Package | Notes |
|-----------|---------|-------|
| Audio (PipeWire) | `pipewire` | Preferred |
| Audio (PulseAudio) | `pulseaudio-utils` (`parecord`) | Fallback |
| Audio (ALSA) | `alsa-utils` (`arecord`) | Last resort |
| Transcription | whisper.cpp | Built from source by `setup/whisper.sh` |
| Model | `ggml-base.en.bin` | ~142 MB, ~2s on CPU |
| Notifications | `libnotify-bin` (`notify-send`) | Requires `--print-id` (libnotify ≥ 0.7.9) |
| Typing (Wayland+daemon) | `ydotool` + `ydotoold` daemon | Reliable only with daemon socket |
| Typing (Wayland, preferred) | `xdotool` via XWayland | Used when ydotoold not running |
| Typing (Wayland native) | `wtype` | Pure-Wayland, no XWayland needed |
| Clipboard (Wayland) | `wl-clipboard` (`wl-copy`/`wl-paste`) | Required |
| Clipboard (X11) | `xclip` or `xsel` | Required on X11 |

---

## Known Issues & Status

### ✅ Fixed

| # | Issue | Fix | Commit |
|---|-------|-----|--------|
| 1 | Stale lockfile / toggle stuck after crash | `trap _cleanup EXIT` + `_VOX_KEEP_LOCK` flag | `d62d40c` |
| 2 | "Transcribing" notification stuck forever on crash | `trap _on_error ERR` → `notify_error` | `d62d40c` |
| 3 | ydotool types `2442` instead of Ctrl+V | ydotool 0.1.8 direct-uinput mode buggy; now requires daemon socket | `11cb70f` |
| 4 | `xdotool windowfocus --sync` hangs on GNOME 46 Wayland | Removed `--sync`; GNOME Wayland never delivers X11 FocusIn | `pending` |

### 🔍 Under Investigation

| # | Issue | Suspected cause |
|---|-------|-----------------|
| 5 | Text not typed after transcription | Hang in `_restore_focus` (now fixed above); needs re-test |
| 6 | Clipboard paste lands in wrong window | Focus restoration timing on GNOME Wayland |

### 📋 Backlog

| # | Issue | Priority |
|---|-------|----------|
| 7 | No WAV size validation before transcription | Low |
| 8 | Add `PULSE_LATENCY_MSEC=100` to audio setup | Low |
| 9 | Watchdog: auto-stop recording after N minutes | Medium |
| 10 | `wtype` not tested on pure Wayland (no XWayland) | Low |

---

## Typing Tool Selection (Wayland)

```
Is ydotoold socket present?  (/tmp/.ydotool_socket)
  YES → ydotool          (reliable, daemon-backed)
  NO  → wtype installed?
          YES → wtype    (pure Wayland, no daemon needed)
          NO  → xdotool  (XWayland fallback, works for most GNOME apps)
               → clipboard_only  (no tool found; user pastes manually)
```

**Why not ydotool without daemon?**  
ydotool 0.1.8 in direct `/dev/uinput` mode has a known bug where modifier
keys misfire as raw digit strings (e.g. Ctrl+V keycode sequence `29:1 47:1 47:0 29:0`
gets output as the string `"2442"`). Only use ydotool when `ydotoold` is running.

**Why xdotool on GNOME Wayland?**  
GNOME runs every app under XWayland unless the app opts into native Wayland.
`xdotool` operates over the X11 protocol and works for all XWayland-hosted windows.
`DISPLAY=:0` is always set in a GNOME session.

---

## GNOME Wayland Quirks

### Shell.Eval is disabled (GNOME 40+)
`org.gnome.Shell.Eval` returns `(false, '')` — it exists but is sandboxed.
Used in `_is_terminal_focused()` to detect the focused window class.
On GNOME 46 this always returns empty, so the function falls back to
`xdotool getactivewindow getwindowname`.

### `windowfocus --sync` hangs
`xdotool windowfocus --sync <id>` blocks waiting for an X11 `FocusIn` event.
On GNOME Wayland, the Wayland compositor delivers focus to the Wayland surface
but does NOT send a corresponding X11 `FocusIn` to XWayland apps.
Result: `--sync` blocks indefinitely.  
**Fix:** use `xdotool windowfocus <id>` (no `--sync`), then `sleep 0.1`.

### Focus window IDs
`xdotool getactivewindow` returns the XWayland window ID.
This ID can be passed to `xdotool windowfocus` and `key` for the same window.
IDs are valid for the lifetime of the window.

---

## Debugging

```bash
# Run manually from terminal — output visible immediately
~/vox-linux/vox.sh type
# speak
~/vox-linux/vox.sh type

# Read debug log (written every hotkey press)
cat /tmp/vox-linux/debug.log

# Tail log in real time
tail -f /tmp/vox-linux/debug.log

# Test transcription on last recording
~/.local/share/vox-linux/whisper.cpp/build/bin/whisper-cli \
    -m ~/.local/share/vox-linux/models/ggml-base.en.bin \
    -f /tmp/vox-linux/recording.wav \
    --no-timestamps -l en --output-txt \
    --output-file /tmp/vox-test 2>&1 | tail -5
cat /tmp/vox-test.txt

# Test paste mechanism directly
echo "Hello world" | wl-copy
DISPLAY=:0 xdotool key ctrl+v

# Check typing tool detection
source ~/vox-linux/lib/detect.sh
detect_display_server; detect_typing_tool
echo "Display: $VOX_DISPLAY_SERVER  Typing: $VOX_TYPING_TOOL"
```

---

## Research: Comparable Projects

| Project | Language | STT Engine | Text Injection | Wayland |
|---------|----------|------------|----------------|---------|
| [nerd-dictation](https://github.com/ideasman42/nerd-dictation) | Python | Vosk | xdotool/ydotool/wtype | ydotool+daemon |
| [linux-stt-hotkey](https://github.com/josh-stone/linux-stt-hotkey) | Bash | whisper.cpp | ydotool/xdotool | ydotool |
| [ptt-dictate](https://github.com/arturo-jc/ptt-dictate) | Bash | whisper.cpp HTTP | ydotool | ydotool |
| [ten-four](https://github.com/christiangantuangco/ten-four) | Rust | whisper.cpp | ydotool/xdotool | ydotool+daemon |
| **vox-linux** | **Bash** | **whisper.cpp** | **clipboard+paste** | **xdotool (XWayland)** |

**Key differentiator:** vox-linux uses clipboard+paste instead of direct key
injection. This avoids `/dev/uinput` permission issues, handles unicode/special
characters correctly, and always has a graceful fallback (text stays in clipboard).

---

## Configuration Reference

File: `~/.config/vox-linux/config.cfg` (created from `config/defaults.cfg`)

| Variable | Default | Options |
|----------|---------|---------|
| `VOX_WHISPER_MODEL` | `base.en` | `tiny.en`, `base.en`, `small.en`, `medium.en`, `large-v3` |
| `VOX_LANGUAGE` | `en` | BCP-47 code or `auto` |
| `VOX_DISPLAY_SERVER` | `auto` | `wayland`, `x11` |
| `VOX_AUDIO_BACKEND` | `auto` | `pipewire`, `pulseaudio`, `alsa` |
| `VOX_TYPING_TOOL` | `auto` | `ydotool`, `wtype`, `xdotool`, `clipboard_only` |
| `VOX_CLIPBOARD_TOOL` | `auto` | `wl-copy`, `xclip`, `xsel`, `none` |
| `VOX_SUGGEST_CMD` | `gh copilot suggest` | Any CLI that accepts a quoted string |

---

## Hotkeys

| Hotkey | Command | Mode |
|--------|---------|------|
| `Ctrl+Alt+V` | `vox type` | Voice → paste text at cursor |
| `Ctrl+Alt+S` | `vox suggest` | Voice → `gh copilot suggest "..."` in terminal |

Registered via `setup/hotkeys.sh` → GNOME `gsettings` custom keybindings.
