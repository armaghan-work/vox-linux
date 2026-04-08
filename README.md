# vox-linux 🎤

> Voice input for Linux — type anywhere with your voice or talk directly to Copilot CLI.

**Fully local · No API key needed · X11 & Wayland · GNOME & KDE**

---

## What it does

| Hotkey | Mode | Behaviour |
|--------|------|-----------|
| `Super + V` | **Type anywhere** | Speak → transcribe → paste at cursor |
| `Super + C` | **Voice to Copilot** | Speak → transcribe → paste + Enter (submits to Copilot CLI or any terminal) |

Both modes use [whisper.cpp](https://github.com/ggerganov/whisper.cpp) locally — no cloud, no subscription.

---

## Requirements

- **Ubuntu 22.04+ / Debian 12+** (or Arch Linux)
- **X11** or **Wayland** (auto-detected)
- **Microphone**
- ~500 MB disk for binary + model (base.en)

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/vox-linux.git
cd vox-linux
./install.sh
```

That's it. The script will:

1. Install system packages (`ydotool`, `wl-clipboard` on Wayland; `xdotool`, `xclip` on X11)
2. Clone and build **whisper.cpp**
3. Download the **base.en** model (~148 MB)
4. Create your config at `~/.config/vox-linux/config.cfg`
5. Register keyboard shortcuts in GNOME or KDE

> ⚠️ **Wayland users:** You will be asked to log out and back in once (required to activate the `input` group for `ydotool`).

### Install with a different model

```bash
./install.sh small.en    # better accuracy, ~488 MB
./install.sh large-v3    # best accuracy, ~3 GB
```

---

## Usage

Press **`Super + V`** to start recording → speak → press **`Super + V`** again to stop.  
Transcribed text appears at your cursor.

Press **`Super + C`** while your Copilot CLI terminal is focused → speak → press **`Super + C`** again.  
Text is typed and submitted automatically.

You can also run from the terminal:

```bash
vox type   # voice → type at cursor
vox chat   # voice → type + Enter
```

---

## Configuration

Edit `~/.config/vox-linux/config.cfg`:

```bash
# Whisper model (tiny.en | base.en | small.en | medium.en | large-v3)
VOX_WHISPER_MODEL="base.en"

# Language code (en | de | fr | nl | es | …) or "auto"
VOX_LANGUAGE="en"

# Override display server detection: auto | wayland | x11
VOX_DISPLAY_SERVER="auto"

# Override typing tool: auto | ydotool | wtype | xdotool | clipboard_only
VOX_TYPING_TOOL="auto"
```

---

## Changing hotkeys

Run the hotkey setup script with your preferred bindings (GNOME format):

```bash
./setup/hotkeys.sh "$(pwd)" "<Super>v" "<Super>c"
```

Or set them manually in:
- **GNOME**: Settings → Keyboard → Custom Shortcuts
- **KDE**: System Settings → Shortcuts → Custom Shortcuts

Commands to assign:
- `vox type` for voice-to-cursor
- `vox chat` for voice-to-Copilot

---

## Troubleshooting

### Text is not being typed (Wayland)
1. Confirm `ydotoold` is running: `systemctl --user status ydotoold`
2. If not, start it: `systemctl --user start ydotoold`
3. If the service fails, you may not have logged out/in since install. Log out and back in.

### "No speech detected"
- Speak closer to the microphone or increase your microphone input level
- Try a larger model: change `VOX_WHISPER_MODEL="small.en"` in your config

### Clipboard is replaced after use
By design — the previous clipboard is restored automatically after 3 seconds.

### Check what was detected
```bash
source vox.sh && detect_display_server && echo "Display: $VOX_DISPLAY_SERVER"
```

### Test transcription directly
```bash
# Record 5 seconds
pw-record --rate=16000 --channels=1 --format=s16 /tmp/test.wav &
sleep 5 && kill %1
# Transcribe
~/.local/share/vox-linux/whisper.cpp/whisper-cli \
  -m ~/.local/share/vox-linux/models/ggml-base.en.bin \
  -f /tmp/test.wav --no-timestamps
```

---

## Uninstall

```bash
./uninstall.sh
```

---

## Roadmap

- [ ] GUI tray indicator (recording status)
- [ ] Groq / Gemini API as optional faster backend
- [ ] Push-to-talk mode (hold hotkey)
- [ ] Multiple language profiles
- [ ] Smart rewrite: select text → speak to rephrase

---

## How it works

```
Hotkey press #1
  └─ vox.sh type
       ├─ detect display server, audio backend, typing tool
       ├─ start pw-record → /tmp/vox-linux/recording.wav (background)
       └─ create /tmp/vox-linux/recording.lock

Hotkey press #2
  └─ vox.sh type
       ├─ lock found → stop recorder
       ├─ whisper-cli → transcribed text
       ├─ copy to clipboard (wl-copy / xclip)
       ├─ simulate Ctrl+V (ydotool / xdotool)
       └─ restore original clipboard after 3 s
```

---

## License

MIT
