# vox-linux 🎤

> Voice input for Linux — type anywhere with your voice, or ask any AI CLI a question hands-free.

**Fully local transcription · No cloud needed · X11 & Wayland · GNOME & KDE**

---

## Two hotkey modes

| Hotkey | Mode | What it does |
|--------|------|-------------|
| `Ctrl + Alt + V` | **Type anywhere** | Speak → transcribed text appears at your cursor in any app |
| `Ctrl + Alt + S` | **AI suggest** | Speak → runs your configured AI CLI command in the terminal |

### How suggest mode works

```
Press Ctrl+Alt+S  →  say "list all docker containers"  →  press Ctrl+Alt+S again

terminal runs:  copilot -i "list all docker containers"
             (or gemini / claude / llm — whatever you configure)
```

Speech-to-text runs **fully locally** via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). No cloud, no API key needed for transcription. The AI CLI you configure may require its own key.

---

## Requirements

- **Ubuntu 22.04+ / Debian 12+** or **Arch Linux**
- **X11** or **Wayland** (auto-detected)
- **Microphone**
- ~500 MB disk for whisper binary + base.en model

---

## Installation

```bash
git clone https://github.com/armaghan-work/vox-linux.git
cd vox-linux
./install.sh          # run as your normal user, NOT with sudo
```

The installer will:

1. Install system packages (`ydotool`, `wl-clipboard`, `xdotool`, `xclip`)
2. Add your user to the `input` group (needed for `ydotool` to type on Wayland)
3. Clone and build **whisper.cpp** (~2–5 min, one time only)
4. Download the **base.en** model (~148 MB)
5. Create your config at `~/.config/vox-linux/config.cfg`
6. Register `Ctrl+Alt+V` and `Ctrl+Alt+S` shortcuts in GNOME or KDE

> ⚠️ **After install:** Log out and back in once. This activates the `input` group membership that `ydotool` needs to type on Wayland.

### Install with a more accurate model

```bash
./install.sh small.en    # better accuracy, ~488 MB
./install.sh large-v3    # best accuracy, ~3 GB
```

---

## Usage

### `Ctrl + Alt + V` — Type anywhere
1. Click where you want to type (browser, email, code editor, terminal…)
2. Press `Ctrl + Alt + V` → notification: *🎤 Recording…*
3. Speak
4. Press `Ctrl + Alt + V` again → text appears at your cursor

Works in every app: native Wayland apps, X11 apps, terminals, browsers.

### `Ctrl + Alt + S` — AI suggest
1. Press `Ctrl + Alt + S` → notification: *🎤 Recording…*
2. Say what you want, e.g. **"show me disk usage by folder"**
3. Press `Ctrl + Alt + S` again → a terminal opens (if none is focused) and runs:
   ```
   copilot -i "show me disk usage by folder"
   ```
   The AI responds with the exact command, with options to run, copy, or explain it.

---

## Configuration

Edit `~/.config/vox-linux/config.cfg` — uncomment and change only the values you want to override. All other settings come from built-in defaults automatically.

```bash
# Uncomment to change — only set what you want to override

# VOX_WHISPER_MODEL="base.en"   # tiny.en | base.en | small.en | medium.en | large-v3
# VOX_LANGUAGE="en"             # en, de, fr, nl, es, ar, … — or "auto"
# VOX_SUGGEST_CMD="copilot -i"  # AI CLI for Ctrl+Alt+S (see below)
# VOX_DISPLAY_SERVER="auto"     # auto | wayland | x11
# VOX_TYPING_TOOL="auto"        # auto | ydotool | xdotool | clipboard_only
```

### Switching your AI CLI

Change `VOX_SUGGEST_CMD` in your config. Your speech is appended as a quoted argument: `VOX_SUGGEST_CMD "your words"`.

| AI | Config value |
|----|-------------|
| GitHub Copilot *(default)* | `VOX_SUGGEST_CMD="copilot -i"` |
| Google Gemini | `VOX_SUGGEST_CMD="gemini"` |
| Anthropic Claude | `VOX_SUGGEST_CMD="claude"` |
| Any model (llm CLI) | `VOX_SUGGEST_CMD="llm"` |
| aichat | `VOX_SUGGEST_CMD="aichat"` |

Works with any CLI that accepts a prompt as its first argument.

---

## Changing hotkeys

```bash
./setup/hotkeys.sh "$(pwd)" "<Primary><Alt>v" "<Primary><Alt>s"
```

Or manually in:
- **GNOME**: Settings → Keyboard → Custom Shortcuts
- **KDE**: System Settings → Shortcuts → Custom Shortcuts

| Command | Assign to |
|---------|-----------|
| `vox type` | Voice type anywhere |
| `vox suggest` | Voice AI suggest |

---

## Troubleshooting

### Text is not being typed (Wayland)

vox-linux uses `ydotool` in direct `/dev/uinput` mode — no daemon required. It needs your user to be in the `input` group.

1. Check: `groups | grep input`
2. If missing: `sudo usermod -aG input $USER` then **log out and back in**
3. Check udev rule: `cat /etc/udev/rules.d/60-uinput.rules`
   Should contain: `KERNEL=="uinput", GROUP="input", MODE="0660"`

### Text is not being typed (X11)

`xdotool type` is used on X11. Test it directly:
```bash
xdotool type "hello world"
```

### "No speech detected"
- Speak louder or closer to the microphone
- Try a larger model: uncomment `VOX_WHISPER_MODEL="small.en"` in your config

### Suggest mode: command not found or wrong format
- Test your AI CLI manually first: `copilot -i "test query"`
- For GitHub Copilot: `gh extension install github/gh-copilot`
- Set the correct command: uncomment `VOX_SUGGEST_CMD="your-command"` in your config

### Test transcription directly
```bash
pw-record --rate=16000 --channels=1 --format=s16 /tmp/test.wav &
sleep 5 && kill %1
~/.local/share/vox-linux/whisper.cpp/build/bin/whisper-cli \
  -m ~/.local/share/vox-linux/models/ggml-base.en.bin \
  -f /tmp/test.wav --no-timestamps
```

### Debug log
```bash
cat /tmp/vox-linux/debug.log
```

---

## Uninstall

```bash
./uninstall.sh
```

---

## How it works

```
Hotkey press #1  →  vox.sh [type|suggest]
   ├─ auto-detect: display server, audio backend, typing tool
   ├─ start audio recorder → /tmp/vox-linux/recording.wav (background)
   └─ script exits (recorder keeps running)

Hotkey press #2  →  vox.sh [type|suggest]
   ├─ stop recorder
   ├─ whisper-cli → transcribed text (local, fully offline)
   ├─ type mode:    inject text directly at cursor via ydotool/xdotool
   └─ suggest mode: run  VOX_SUGGEST_CMD "text"  in terminal + Enter
```

**Typing method by session:**

| Session | Tool | How |
|---------|------|-----|
| Wayland | `ydotool type` | Writes key events directly to `/dev/uinput` — works for all apps regardless of compositor |
| X11 | `xdotool type` | Sends key events via X11 — works for all X11 apps |

---

## Roadmap

- [ ] GUI tray indicator (recording status)
- [ ] Push-to-talk mode (hold hotkey instead of toggle)
- [ ] Multiple language profiles

---

## License

MIT


