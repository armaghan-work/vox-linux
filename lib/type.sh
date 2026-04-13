#!/usr/bin/env bash
# lib/type.sh — Text injection (direct typing method)
#
# Strategy:
#  1. For suggest mode: ensure a terminal is focused (open one if needed)
#  2. Inject text directly using wtype (Wayland), xdotool type (X11/XWayland),
#     or ydotool type (uinput). No clipboard, no focus-restore needed.
#  3. On failure: copy to clipboard and notify user to paste manually.
#
# Why direct typing beats clipboard+paste on GNOME Wayland:
#  - xdotool key ctrl+v targets the X11-focused window, which is NONE when a
#    native Wayland app (e.g. GNOME Text Editor) has focus — key goes to void.
#  - wtype / ydotool type inject directly into the Wayland-focused window.
#  - No focus-restore, no clipboard save/restore, no timing races.

readonly _KNOWN_TERMINALS=(
    "gnome-terminal" "terminal" "konsole" "kitty" "alacritty"
    "wezterm" "foot" "tilix" "terminator" "xterm" "urxvt"
    "bash" "zsh" "fish" "tmux" "rxvt"
)

# Returns 0 if the focused window appears to be a terminal emulator.
_is_terminal_focused() {
    local name=""

    if [[ "$VOX_DISPLAY_SERVER" == "wayland" ]]; then
        # GNOME Wayland: query focused window via D-Bus
        name=$(gdbus call --session \
            --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Eval \
            "global.display.get_focus_window()?.get_wm_class() || ''" \
            2>/dev/null | grep -oP "(?<=')[^']+(?=')" | head -1 || true)
    fi

    # X11 / XWayland fallback
    if [[ -z "$name" ]] && command -v xdotool >/dev/null 2>&1; then
        name=$(xdotool getactivewindow getwindowname 2>/dev/null || true)
    fi

    local lower="${name,,}"
    local t
    for t in "${_KNOWN_TERMINALS[@]}"; do
        [[ "$lower" == *"$t"* ]] && return 0
    done
    return 1
}

# _open_terminal — open a terminal emulator and wait for it to receive focus.
_open_terminal() {
    local term=""
    local t
    for t in gnome-terminal kitty alacritty konsole wezterm foot tilix xterm; do
        command -v "$t" >/dev/null 2>&1 && { term="$t"; break; }
    done

    [[ -z "$term" ]] && return 1

    case "$term" in
        gnome-terminal) gnome-terminal &;;
        konsole)        konsole &;;
        wezterm)        wezterm start &;;
        *)              "$term" &;;
    esac
    disown $!

    # Poll until the terminal grabs focus (up to 5 s), then allow it to settle
    local i=0
    while [[ $i -lt 25 ]]; do
        sleep 0.2
        if _is_terminal_focused; then
            sleep 0.4
            return 0
        fi
        i=$(( i + 1 ))
    done
    sleep 1  # detection timed out — give one final extra second
    return 0
}

# Copy TEXT to the system clipboard (used only for clipboard_only fallback).
_clipboard_copy() {
    local text="$1"
    case "$VOX_CLIPBOARD_TOOL" in
        wl-copy)  printf '%s' "$text" | wl-copy ;;
        xclip)    printf '%s' "$text" | xclip -selection clipboard ;;
        xsel)     printf '%s' "$text" | xsel --clipboard --input ;;
    esac
}

# _type_direct TEXT — inject TEXT into the currently focused window.
# wtype  → native Wayland; targets the Wayland-focused window directly.
# xdotool→ X11/XWayland; --clearmodifiers releases the hotkey modifiers first.
# ydotool→ kernel uinput; types regardless of Wayland/X11 focus state.
_type_direct() {
    local text="$1"
    # Allow the compositor time to release the hotkey modifier keys (Ctrl+Alt)
    # before we send new key events. Without this, some apps see stray modifiers.
    sleep 0.3

    case "$VOX_TYPING_TOOL" in
        wtype)
            wtype -- "$text"
            ;;
        xdotool)
            # --clearmodifiers: release any held modifiers (e.g. Ctrl+Alt from hotkey)
            # --delay 0: no inter-character delay
            DISPLAY=:0 xdotool type --clearmodifiers --delay 0 -- "$text"
            ;;
        ydotool)
            local sock="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
            YDOTOOL_SOCKET="$sock" ydotool type --delay 30 -- "$text"
            ;;
    esac
}

# Simulate pressing Enter.
_send_enter_key() {
    sleep 0.05
    case "$VOX_TYPING_TOOL" in
        wtype)   wtype -k Return ;;
        xdotool) DISPLAY=:0 xdotool key --clearmodifiers Return ;;
        ydotool)
            local sock="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
            YDOTOOL_SOCKET="$sock" ydotool key 28:1 28:0
            ;;
    esac
}

# type_text TEXT MODE
#   MODE = type    → inject text at cursor, no Enter
#   MODE = suggest → ensure terminal focused (open one if needed),
#                    wrap as 'gh copilot suggest "..."', inject + Enter
type_text() {
    local text="$1"
    local mode="${2:-type}"

    local _log="${VOX_LOG:-/tmp/vox-linux/debug.log}"
    _tlog() { printf '[%s] type_text: %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >> "$_log"; }

    _tlog "start mode=$mode tool=$VOX_TYPING_TOOL clipboard=$VOX_CLIPBOARD_TOOL"

    # No automation tool available — copy to clipboard for manual paste
    if [[ "$VOX_TYPING_TOOL" == "clipboard_only" ]]; then
        _clipboard_copy "$text"
        notify_clipboard "$text"
        return 0
    fi

    # suggest mode requires a terminal; open one if none is focused
    if [[ "$mode" == "suggest" ]]; then
        if ! _is_terminal_focused; then
            if ! _open_terminal; then
                notify_error "No terminal found. Install gnome-terminal, kitty, or another terminal emulator."
                return 0
            fi
        fi
    fi

    # Build the text to inject
    local inject_text="$text"
    if [[ "$mode" == "suggest" ]]; then
        local escaped="${text//\"/\\\"}"   # escape any double quotes in speech
        local cmd="${VOX_SUGGEST_CMD:-gh copilot suggest}"
        inject_text="${cmd} \"${escaped}\""
    fi

    _tlog "injecting: '${inject_text:0:80}'"

    if ! _type_direct "$inject_text"; then
        _tlog "direct type FAILED — falling back to clipboard"
        _clipboard_copy "$text"
        notify_clipboard "$text"
        return 0
    fi

    _tlog "injection OK"
    notify_done "$text"

    # In suggest mode, submit with Enter
    if [[ "$mode" == "suggest" ]]; then
        _send_enter_key || true
    fi
}


readonly _KNOWN_TERMINALS=(
    "gnome-terminal" "terminal" "konsole" "kitty" "alacritty"
    "wezterm" "foot" "tilix" "terminator" "xterm" "urxvt"
    "bash" "zsh" "fish" "tmux" "rxvt"
)

# Returns 0 if the focused window appears to be a terminal emulator.
_is_terminal_focused() {
    local name=""

    if [[ "$VOX_DISPLAY_SERVER" == "wayland" ]]; then
        # GNOME Wayland: query focused window via D-Bus
        name=$(gdbus call --session \
            --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Eval \
            "global.display.get_focus_window()?.get_wm_class() || ''" \
            2>/dev/null | grep -oP "(?<=')[^']+(?=')" | head -1 || true)
    fi

    # X11 / XWayland fallback
    if [[ -z "$name" ]] && command -v xdotool >/dev/null 2>&1; then
        name=$(xdotool getactivewindow getwindowname 2>/dev/null || true)
    fi

    local lower="${name,,}"
    local t
    for t in "${_KNOWN_TERMINALS[@]}"; do
        [[ "$lower" == *"$t"* ]] && return 0
    done
    return 1
}

# _restore_focus — re-focus the window that was active when recording stopped.
# Reads VOX_FOCUSED_WINDOW (set by _cmd_stop in vox.sh).
_restore_focus() {
    [[ -z "${VOX_FOCUSED_WINDOW:-}" ]] && return 0
    sleep 0.1  # let notification system settle before refocusing
    if command -v xdotool >/dev/null 2>&1; then
        # Do NOT use --sync: on GNOME Wayland the X11 FocusIn confirmation
        # never arrives from the compositor, causing an indefinite hang.
        xdotool windowfocus "$VOX_FOCUSED_WINDOW" 2>/dev/null || true
        sleep 0.1  # allow the compositor to settle focus before we paste
    elif command -v wmctrl >/dev/null 2>&1; then
        wmctrl -ia "$VOX_FOCUSED_WINDOW" 2>/dev/null || true
    fi
}

# _open_terminal — open a terminal emulator and wait for it to receive focus.
_open_terminal() {
    local term=""
    local t
    for t in gnome-terminal kitty alacritty konsole wezterm foot tilix xterm; do
        command -v "$t" >/dev/null 2>&1 && { term="$t"; break; }
    done

    [[ -z "$term" ]] && return 1

    case "$term" in
        gnome-terminal) gnome-terminal &;;
        konsole)        konsole &;;
        wezterm)        wezterm start &;;
        *)              "$term" &;;
    esac
    disown $!

    # Poll until the terminal grabs focus (up to 5 s), then allow it to settle
    local i=0
    while (( i < 25 )); do
        sleep 0.2
        if _is_terminal_focused; then
            sleep 0.4
            return 0
        fi
        i=$(( i + 1 ))
    done
    sleep 1  # detection timed out — give one final extra second
    return 0
}

# Copy TEXT to the system clipboard.
_clipboard_copy() {
    local text="$1"
    case "$VOX_CLIPBOARD_TOOL" in
        wl-copy)  printf '%s' "$text" | wl-copy ;;
        xclip)    printf '%s' "$text" | xclip -selection clipboard ;;
        xsel)     printf '%s' "$text" | xsel --clipboard --input ;;
    esac
}

# Read and print current clipboard contents (best-effort; empty string on fail).
_clipboard_get() {
    case "$VOX_CLIPBOARD_TOOL" in
        wl-copy)  wl-paste --no-newline 2>/dev/null || true ;;
        xclip)    xclip -selection clipboard -o 2>/dev/null || true ;;
        xsel)     xsel --clipboard --output 2>/dev/null || true ;;
        *)        true ;;
    esac
}

# Simulate a paste keystroke.  IS_TERMINAL=true → Ctrl+Shift+V
_send_paste_key() {
    local is_terminal="${1:-false}"
    sleep 0.15   # ensure clipboard write is flushed before paste

    case "$VOX_TYPING_TOOL" in
        ydotool)
            local sock="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
            if [[ "$is_terminal" == "true" ]]; then
                # Ctrl + Shift + V
                YDOTOOL_SOCKET="$sock" ydotool key 29:1 42:1 47:1 47:0 42:0 29:0
            else
                # Ctrl + V
                YDOTOOL_SOCKET="$sock" ydotool key 29:1 47:1 47:0 29:0
            fi
            ;;
        wtype)
            if [[ "$is_terminal" == "true" ]]; then
                wtype -M ctrl -M shift -k v -m shift -m ctrl
            else
                wtype -M ctrl -k v -m ctrl
            fi
            ;;
        xdotool)
            if [[ "$is_terminal" == "true" ]]; then
                xdotool key ctrl+shift+v
            else
                xdotool key ctrl+v
            fi
            ;;
    esac
}

# Simulate pressing Enter.
_send_enter_key() {
    sleep 0.05
    case "$VOX_TYPING_TOOL" in
        ydotool)
            local sock="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
            YDOTOOL_SOCKET="$sock" ydotool key 28:1 28:0
            ;;
        wtype)   wtype -k Return ;;
        xdotool) xdotool key Return ;;
    esac
}

# type_text TEXT MODE
#   MODE = type    → paste at cursor, no Enter
#   MODE = suggest → ensure terminal focused (open one if needed),
#                    wrap as 'gh copilot suggest "..."', paste + Enter
type_text() {
    local text="$1"
    local mode="${2:-type}"

    # vox_log may not be defined if called standalone; guard with a no-op
    local _log="${VOX_LOG:-/tmp/vox-linux/debug.log}"
    _tlog() { printf '[%s] type_text: %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >> "$_log"; }

    _tlog "start mode=$mode tool=$VOX_TYPING_TOOL clipboard=$VOX_CLIPBOARD_TOOL"

    if [[ "$VOX_TYPING_TOOL" == "clipboard_only" ]]; then
        _clipboard_copy "$text"
        notify_clipboard "$text"
        return 0
    fi

    # suggest mode requires a terminal; open one if none is focused
    if [[ "$mode" == "suggest" ]]; then
        if ! _is_terminal_focused; then
            if ! _open_terminal; then
                notify_error "No terminal found. Install gnome-terminal, kitty, or another terminal emulator."
                return 0
            fi
        fi
    fi

    # Detect target window type (suggest mode always targets a terminal)
    local is_terminal="false"
    if [[ "$mode" == "suggest" ]]; then
        is_terminal="true"
    elif _is_terminal_focused; then
        is_terminal="true"
    fi
    _tlog "is_terminal=$is_terminal"

    # For suggest mode: wrap text as a gh copilot suggest command
    local inject_text="$text"
    if [[ "$mode" == "suggest" ]]; then
        local escaped="${text//\"/\\\"}"   # escape any double quotes in speech
        local cmd="${VOX_SUGGEST_CMD:-gh copilot suggest}"
        inject_text="${cmd} \"${escaped}\""
    fi

    # Save current clipboard content
    _tlog "saving old clipboard"
    local old_clipboard
    old_clipboard=$(_clipboard_get)

    # Copy text to clipboard
    _tlog "copying text to clipboard"
    if ! _clipboard_copy "$inject_text"; then
        _tlog "clipboard copy FAILED"
        notify_error "Clipboard copy failed (tool: ${VOX_CLIPBOARD_TOOL}). Is it installed and working?"
        return 0
    fi
    _tlog "clipboard copy OK"

    # Re-focus the window that was active when recording stopped
    _tlog "restoring focus to window='${VOX_FOCUSED_WINDOW:-}'"
    _restore_focus
    _tlog "focus restored"

    # Paste into focused window
    _tlog "sending paste key (is_terminal=$is_terminal)"
    if ! _send_paste_key "$is_terminal"; then
        _tlog "send_paste_key FAILED — falling back to clipboard notify"
        notify_clipboard "$text"
        return 0
    fi
    _tlog "send_paste_key OK"

    notify_done "$text"
    _tlog "notify_done called"

    # In suggest mode, submit with Enter
    if [[ "$mode" == "suggest" ]]; then
        _send_enter_key || true
    fi

    # Restore original clipboard after 3 s (background, non-blocking)
    {
        sleep 3
        _clipboard_copy "$old_clipboard"
    } &
    disown $!
}
