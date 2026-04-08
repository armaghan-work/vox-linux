# vox-linux 🎤

> Voice input for Linux — type anywhere with your voice, or ask any AI CLI a question hands-free.

**Fully local transcription · No cloud needed · X11 & Wayland · GNOME & KDE**

---

## Two hotkey modes

| Hotkey | Mode | What it does |
|--------|------|-------------|
| `Super + V` | **Type anywhere** | Speak → transcribed text appears at your cursor in any app |
| `Super + S` | **AI suggest** | Speak → runs your configured AI CLI command in the terminal |

### How suggest mode works

```
Press Super+S  →  say "list all docker containers"  →  press Super+S again

terminal runs:  gh copilot suggest "list all docker containers"
             (or gemini / claude / llm — whatever you configure)
```

Speech-to-text runs **fully locally** via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). No cloud, no API key needed for transcription. The AI CLI you configure may require its own key.

---

## Requirements

- **Ubuntu 22.04+ / Debian 12+** (or Arch Linux)
- **X11** or **Wayland** (auto-detected)
- **Microphone**
- ~500 MB disk for whisper binary + base.en model

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
5. Register `Super+V` and `Super+S` shortcuts in GNOME or KDE

> ⚠️ **Wayland users:** Log out and back in once after install (required to activate the `input` group for `ydotool`).

### Install with a more accurate model

```bash
./install.sh small.en    # better accuracy, ~488 MB
./install.sh large-v3    # best accuracy, ~3 GB
```

---

## Usage

### `Super + V` — Type anywhere
1. Click where you want to type (browser, email, code editor, terminal…)
2. Press `Super + V` → notification: *🎤 Recording…*
3. Speak
4. Press `Super + V` again → text appears at your cursor

> Works in every app. For Copilot CLI chat: use `Super+V`, then press Enter yourself.

### `Super + S` — AI suggest
1. Open a terminal with your preferred AI CLI ready
2. Press `Super + S` → notification: *🎤 Recording…*
3. Say what you want, e.g. **"show me disk usage by folder"**
4. Press `Super + S` again → your terminal automatically runs:
   ```
   gh copilot suggest "show me disk usage by folder"
   ```
   The AI responds with the exact command, with options to run, copy, or explain it.

---

## Configuration

Edit `~/.config/vox-linux/config.cfg` (created automatically on first install):

```bash
# ── Whisper model ─────────────────────────────────────────────────────────────
# tiny.en (~77 MB, fastest) | base.en (~148 MB) | small.en (~488 MB) | large-v3 (~3 GB)
VOX_WHISPER_MODEL="base.en"

# ── Language ──────────────────────────────────────────────────────────────────
# BCP-47 code: en, de, fr, nl, es, ar, … — or "auto" for auto-detection
VOX_LANGUAGE="en"

# ── AI suggest command ────────────────────────────────────────────────────────
# The CLI used by Super+S. Your speech is appended as a quoted argument.
VOX_SUGGEST_CMD="gh copilot suggest"

# ── Display server (usually leave as auto) ────────────────────────────────────
VOX_DISPLAY_SERVER="auto"   # auto | wayland | x11

# ── Typing tool (usually leave as auto) ──────────────────────────────────────
VOX_TYPING_TOOL="auto"      # auto | ydotool | wtype | xdotool | clipboard_only
```

### Switching your AI CLI

Change `VOX_SUGGEST_CMD` in your config — that's all. Examples:

| AI | Command to set |
|----|---------------|
| GitHub Copilot *(default)* | `VOX_SUGGEST_CMD="gh copilot suggest"` |
| Google Gemini | `VOX_SUGGEST_CMD="gemini"` |
| Anthropic Claude | `VOX_SUGGEST_CMD="claude"` |
| Groq (via aichat) | `VOX_SUGGEST_CMD="aichat -m groq"` |
| Any model (llm CLI) | `VOX_SUGGEST_CMD="llm"` |

The speech becomes the argument: `VOX_SUGGEST_CMD "your words"` — so it works with any CLI that accepts a prompt as an argument.

---

## Changing hotkeys

```bash
./setup/hotkeys.sh "$(pwd)" "<Super>v" "<Super>s"
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
1. Check ydotoold: `systemctl --user status ydotoold`
2. Start if needed: `systemctl --user start ydotoold`
3. Still failing? → Log out and back in (the `input` group change needs a fresh session)

### "No speech detected"
- Speak louder or closer to the microphone
- Try a larger model: set `VOX_WHISPER_MODEL="small.en"` in your config

### Suggest mode not working
- Make sure your terminal is focused when you press `Super+S`
- Test your AI CLI works manually first: run `gh copilot suggest "test"` (or your configured CLI)
- For GitHub Copilot: `gh extension install github/gh-copilot`

### Clipboard is temporarily replaced
By design — your previous clipboard is restored automatically after 3 seconds.

### Test transcription directly
```bash
pw-record --rate=16000 --channels=1 --format=s16 /tmp/test.wav &
sleep 5 && kill %1
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
Hotkey press #1  →  vox.sh [type|suggest]
   ├─ auto-detect: display server, audio backend, typing tool
   ├─ start recorder → /tmp/vox-linux/recording.wav (background)
   └─ script exits (recorder keeps running)

Hotkey press #2  →  vox.sh [type|suggest]
   ├─ stop recorder
   ├─ whisper-cli → transcribed text (local, offline)
   ├─ type mode:    paste text at cursor
   └─ suggest mode: run  VOX_SUGGEST_CMD "text"  in terminal + Enter
```

---

## Roadmap

- [ ] GUI tray indicator (recording status)
- [ ] Push-to-talk mode (hold hotkey instead of toggle)
- [ ] Multiple language profiles

---

## License

MIT

