# vox-linux 🎤

> Voice input for Linux — type anywhere, talk to Copilot CLI, or get instant shell command suggestions.

**Fully local · No API key needed · X11 & Wayland · GNOME & KDE**

---

## Three hotkey modes

| Hotkey | Mode | What it does |
|--------|------|-------------|
| `Super + V` | **Type anywhere** | Speak → transcribed text appears at your cursor in any app |
| `Super + C` | **Copilot chat** | Speak → text typed + submitted to the Copilot CLI chat session already open in your terminal |
| `Super + S` | **Shell suggest** | Speak → runs `gh copilot suggest "your words"` in your terminal → Copilot suggests the right command |

### Which mode to use?

```
Want to dictate text into any app (browser, editor, chat)?
  → Super + V

Have the Copilot CLI chat open (this session) and want to ask it something?
  → Super + C

Want to say "list all docker containers" and get the exact shell command?
  → Super + S  (runs: gh copilot suggest "list all docker containers")
```

All three modes use [whisper.cpp](https://github.com/ggerganov/whisper.cpp) locally — no cloud, no subscription.

---

## Requirements

- **Ubuntu 22.04+ / Debian 12+** (or Arch Linux)
- **X11** or **Wayland** (auto-detected)
- **Microphone**
- ~500 MB disk for whisper binary + base.en model
- `gh` CLI with Copilot extension (for `suggest` mode only)

---

## Installation

```bash
git clone https://github.com/armaghan-work/vox-linux.git
cd vox-linux
./install.sh
```

The installer will:

1. Install system packages (`ydotool` + `wl-clipboard` on Wayland; `xdotool` + `xclip` on X11)
2. Clone and build **whisper.cpp** (~2–5 min, one time only)
3. Download the **base.en** model (~148 MB)
4. Create your config at `~/.config/vox-linux/config.cfg`
5. Register keyboard shortcuts in GNOME or KDE automatically

> ⚠️ **Wayland users:** You will need to log out and back in once after install (required to activate the `input` group for `ydotool`).

### Install with a better model

```bash
./install.sh small.en    # better accuracy, ~488 MB
./install.sh large-v3    # best accuracy, ~3 GB
```

---

## Usage

### Type anywhere (`Super + V`)
1. Click where you want to type (browser URL bar, email, chat, code editor…)
2. Press `Super + V` → notification: *Recording…*
3. Speak
4. Press `Super + V` again → text appears at cursor

### Copilot CLI chat (`Super + C`)
1. Open a terminal and start Copilot CLI (`gh copilot` or however you launch it)
2. Press `Super + C` → notification: *Recording…*
3. Ask your question ("explain what this code does", "help me debug this error"…)
4. Press `Super + C` again → your question is typed and submitted automatically

### Shell command suggest (`Super + S`)
1. Open a terminal
2. Press `Super + S` → notification: *Recording…*
3. Say what you want to do: **"list all docker containers"**
4. Press `Super + S` again → the terminal runs:
   ```
   gh copilot suggest "list all docker containers"
   ```
   Copilot responds with the exact command and options to copy/run/explain it.

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

```bash
./setup/hotkeys.sh "$(pwd)" "<Super>v" "<Super>c" "<Super>s"
```

Or set them manually:
- **GNOME**: Settings → Keyboard → Custom Shortcuts
- **KDE**: System Settings → Shortcuts → Custom Shortcuts

| Command | Description |
|---------|-------------|
| `vox type` | Voice → type at cursor |
| `vox chat` | Voice → type + Enter (Copilot CLI chat) |
| `vox suggest` | Voice → `gh copilot suggest "…"` + Enter |

---

## Troubleshooting

### Text is not being typed (Wayland)
1. Check ydotoold is running: `systemctl --user status ydotoold`
2. Start if needed: `systemctl --user start ydotoold`
3. If it fails → log out and back in (input group needs to activate)

### "No speech detected"
- Speak louder or closer to the microphone
- Try a larger model: set `VOX_WHISPER_MODEL="small.en"` in your config

### `gh copilot suggest` mode not working
- Ensure `gh` CLI is installed: `gh --version`
- Ensure Copilot extension: `gh extension install github/gh-copilot`
- Your terminal must be focused when you press the hotkey

### Clipboard is temporarily replaced
By design — your previous clipboard is restored automatically after 3 seconds.

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

## How it works

```
Hotkey press #1  →  vox.sh [type|chat|suggest]
   ├─ detect: display server, audio backend, typing tool
   ├─ start pw-record → /tmp/vox-linux/recording.wav (background)
   └─ create /tmp/vox-linux/recording.lock  →  script exits

Hotkey press #2  →  vox.sh [type|chat|suggest]
   ├─ lock found → stop recorder
   ├─ whisper-cli → transcribed text
   ├─ type mode:    copy to clipboard → Ctrl+V at cursor
   ├─ chat mode:    copy to clipboard → Ctrl+Shift+V + Enter
   └─ suggest mode: wrap as 'gh copilot suggest "text"' → Ctrl+Shift+V + Enter
```

---

## Roadmap

- [ ] GUI tray indicator (recording status)
- [ ] Groq / Gemini API as optional faster backend
- [ ] Push-to-talk mode (hold hotkey)
- [ ] Multiple language profiles

---

## License

MIT

