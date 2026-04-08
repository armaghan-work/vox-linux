#!/usr/bin/env bash
# lib/type.sh — Text injection (clipboard paste method)
#
# Strategy:
#  1. Save current clipboard
#  2. Copy transcribed text to clipboard
#  3. Simulate Ctrl+V (regular apps) or Ctrl+Shift+V (terminals)
#  4. Press Enter if mode=chat
#  5. Restore clipboard in background after 3 s
#
# Terminal detection: terminals require Ctrl+Shift+V to paste.
# If mode=chat we always treat target as terminal (user is in Copilot CLI).

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

    # X11 fallback (also works for XWayland apps)
    if [[ -z "$name" ]] && command -v xdotool >/dev/null 2>&1; then
        name=$(xdotool getactivewindow getwindowname 2>/dev/null || true)
    fi

    local lower="${name,,}"
    for t in "${_KNOWN_TERMINALS[@]}"; do
        [[ "$lower" == *"$t"* ]] && return 0
    done
    return 1
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
#   MODE = type  → paste at cursor, no Enter
#   MODE = chat  → paste at cursor + Enter (for Copilot CLI / any terminal)
type_text() {
    local text="$1"
    local mode="${2:-type}"

    if [[ "$VOX_TYPING_TOOL" == "clipboard_only" ]]; then
        # Fallback: copy to clipboard and let user paste manually
        _clipboard_copy "$text"
        notify_done "Copied to clipboard — press Ctrl+Shift+V (terminal) or Ctrl+V to paste."
        return 0
    fi

    # Detect target window type
    local is_terminal="false"
    [[ "$mode" == "chat" ]] && is_terminal="true"
    if [[ "$is_terminal" == "false" ]]; then
        _is_terminal_focused && is_terminal="true" || true
    fi

    # Save current clipboard content
    local old_clipboard
    old_clipboard=$(_clipboard_get)

    # Copy transcribed text
    _clipboard_copy "$text"

    # Paste into focused window
    _send_paste_key "$is_terminal"

    # In chat mode, submit with Enter
    if [[ "$mode" == "chat" ]]; then
        _send_enter_key
    fi

    # Restore original clipboard after 3 s (background, non-blocking)
    {
        sleep 3
        _clipboard_copy "$old_clipboard"
    } &
    disown $!
}
