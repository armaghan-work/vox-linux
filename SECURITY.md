# Security Policy

## Supported versions

Only the latest commit on `main` is supported.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Report privately by emailing the maintainer or using
[GitHub's private vulnerability reporting](https://github.com/armaghan-work/vox-linux/security/advisories/new).

Include:
- Description of the issue
- Steps to reproduce
- Potential impact

You'll receive a response within 7 days.

## Scope

vox-linux runs entirely locally — no network connections, no cloud API calls for
transcription. The main attack surfaces are:

- The `input` group membership (needed for `/dev/uinput` and `/dev/input/event*`)
- The PTT daemon reading raw keyboard events
- The AI CLI you configure for suggest mode (that tool's own security applies)
