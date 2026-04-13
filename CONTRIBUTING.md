# Contributing to vox-linux

Thanks for your interest! Contributions of all kinds are welcome.

## Ways to contribute

- **Bug reports** — open an issue with your distro, desktop, and the debug log (`cat /tmp/vox-linux/debug.log`)
- **Feature requests** — open an issue describing what you want and why
- **Code** — fork, branch, PR
- **Testing** — try it on KDE, Arch, non-GNOME Wayland (Sway, Hyprland) and report results

## Before opening a PR

1. Test on your machine: `./vox.sh type` and `./vox.sh suggest` should work end-to-end
2. Keep changes focused — one thing per PR
3. Update `README.md` if you change behaviour or add config options
4. Shell scripts: follow the existing style (`set -euo pipefail`, local variables, `ok`/`warn`/`err` for output)

## Dev setup

```bash
git clone https://github.com/armaghan-work/vox-linux.git
cd vox-linux
./install.sh        # sets up everything on your machine
```

Debug log is at `/tmp/vox-linux/debug.log` — run `tail -f /tmp/vox-linux/debug.log` while testing.

## Questions?

Open an issue — happy to help.
