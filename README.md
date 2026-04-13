# vox-linux 🎤

> Voice input for Linux — type anywhere with your voice, or ask any AI CLI a question hands-free.

**Fully local transcription · No cloud needed · X11 & Wayland · GNOME & KDE**

---

## Three input modes

| Mode | Trigger | What it does |
|------|---------|-------------|
| **Toggle type** | `Ctrl + Alt + V` | Press to start recording, press again to stop → text at cursor |
| **Toggle suggest** | `Ctrl + Alt + S` | Press to start recording, press again to stop → AI CLI in terminal |
| **Push-to-talk** | Hold configured key (default `F9`) | Hold to record, release to transcribe → text at cursor |

### How suggest mode works

```
Press Ctrl+Alt+S  →  say "list all docker containers"  →  press Ctrl+Alt+S again

terminal runs:  copilot -i "list all docker containers"
             (or gemini / claude / llm — whatever you configure)
```

### How push-to-talk works

```
Hold F9  →  🎤 Recording…  →  release F9  →  text appears at cursor
```

Hold the PTT key while speaking. Release when done — transcription runs immediately. No second keypress needed.

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

That's it. The installer sets everything up automatically:

1. Installs system packages (`ydotool`, `wl-clipboard`, `xdotool`, `xclip`, `python3-evdev`)
2. Adds your user to the `input` group (needed for typing and push-to-talk)
3. Clones and builds **whisper.cpp** (~2–5 min, one time only)
4. Downloads the **base.en** model (~148 MB)
5. Creates your config at `~/.config/vox-linux/config.cfg`
6. Registers `Ctrl+Alt+V` and `Ctrl+Alt+S` shortcuts in GNOME or KDE
7. Installs the **push-to-talk daemon** as a systemd user service (auto-starts at login)

> ⚠️ **After install:** Log out and back in once. This activates the `input` group membership needed for typing and push-to-talk.

### Install with a more accurate model

```bash
./install.sh small.en    # better accuracy, ~488 MB
./install.sh large-v3    # best accuracy, ~3 GB
```

---

## Usage

### `Ctrl + Alt + V` — Type anywhere
1. Click where you want text (browser, email, editor, terminal…)
2. Press `Ctrl + Alt + V` → *🎤 Recording…*
3. Speak
4. Press `Ctrl + Alt + V` again → text appears at your cursor

### `Ctrl + Alt + S` — AI suggest
1. Press `Ctrl + Alt + S` → *🎤 Recording…*
2. Say what you want, e.g. **"show me disk usage by folder"**
3. Press `Ctrl + Alt + S` again → terminal runs your AI CLI with those words

### `F9` — Push-to-talk
Hold `F9` while speaking. Release when done — text appears immediately. No second keypress needed.

---

## Configuration

Edit `~/.config/vox-linux/config.cfg` — every option is commented with an explanation. Uncomment only what you want to change; everything else uses sensible defaults.

Common changes:

| What | Setting |
|------|---------|
| Whisper model | `VOX_WHISPER_MODEL="small.en"` |
| AI CLI for suggest | `VOX_SUGGEST_CMD="gemini"` |
| PTT type key | `VOX_PTT_TYPE_KEY="KEY_F10"` |
| Add PTT suggest key | `VOX_PTT_SUGGEST_KEY="KEY_F8"` |
| Toggle hotkeys | `VOX_HOTKEY_TYPE="<Primary><Alt>v"` |

**After changing PTT keys** → `vox-ptt restart`

**After changing toggle hotkeys** → `./setup/hotkeys.sh` (from the vox-linux directory)

### Switching your AI CLI

Change `VOX_SUGGEST_CMD`. Your speech is appended as a quoted argument.

| AI | Config value |
|----|-------------|
| GitHub Copilot *(default)* | `VOX_SUGGEST_CMD="copilot -i"` |
| Google Gemini | `VOX_SUGGEST_CMD="gemini"` |
| Anthropic Claude | `VOX_SUGGEST_CMD="claude"` |
| Any model (llm CLI) | `VOX_SUGGEST_CMD="llm"` |

> ⚠️ PTT keys must **not** also be registered as GNOME/KDE toggle hotkeys — they would fire twice.

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

### PTT daemon not working

1. Check it's running: `vox-ptt status`
2. Check python3-evdev: `python3 -c "import evdev; print('ok')"`
3. Check input group: `groups | grep input` (log out/in after adding)
4. Check the debug log: `tail -f /tmp/vox-linux/debug.log`
5. Make sure the PTT key is **not** registered as a GNOME/KDE hotkey

### PTT fires twice on key press

The PTT key is also registered as a GNOME or KDE keyboard shortcut. Remove the conflicting shortcut:
- **GNOME**: Settings → Keyboard → Keyboard Shortcuts → Custom Shortcuts
- **KDE**: System Settings → Shortcuts → Custom Shortcuts

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

PTT (push-to-talk):
   Key held    →  vox-ptt daemon → vox.sh ptt-start  →  recording starts
   Key released →  vox-ptt daemon → vox.sh ptt-stop   →  transcribe + inject
```

**Typing method by session:**

| Session | Tool | How |
|---------|------|-----|
| Wayland | `ydotool type` | Writes key events directly to `/dev/uinput` — works for all apps regardless of compositor |
| X11 | `xdotool type` | Sends key events via X11 — works for all X11 apps |

---

## Roadmap

- [ ] GUI tray indicator (recording status)
- [ ] Multiple language profiles
- [ ] Auto-stop watchdog (recording > 60s)

---

## License

MIT

