# wsl-clipboard-png-bridge

[![shellcheck](https://github.com/PowerUserZ/wsl-clipboard-png-bridge/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/PowerUserZ/wsl-clipboard-png-bridge/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![WSL2](https://img.shields.io/badge/WSL2-required-blue)

A tiny WSL2 background daemon that converts Windows screenshots (BMP) on the
Linux-side clipboard to PNG in real time, so tools like **Claude Code** that
only accept `image/png` can receive pasted screenshots.

## The problem

Windows screenshot tools (Snipping Tool, `Win+Shift+S`) place images on the
Windows clipboard as `image/bmp`. WSLg bridges this to the WSL Wayland
clipboard **as BMP** — it does not convert to PNG. The Claude Code CLI (Linux
build) reads the Linux clipboard and only accepts `image/png`, so pressing
`Alt+V` / `Ctrl+V` yields **"no image"** even though a screenshot is visibly
on the clipboard.

See [`anthropics/claude-code#25935`](https://github.com/anthropics/claude-code/issues/25935).

## How this differs from [`Nailuu/wsl-screenshot-cli`](https://github.com/Nailuu/wsl-screenshot-cli)

Both tools solve the same user-visible problem, but with different trade-offs.
Pick whichever matches your workflow — they are not typically used together.

|                             | **wsl-clipboard-png-bridge** (this tool) | **Nailuu/wsl-screenshot-cli** |
| --------------------------- | ---------------------------------------- | ----------------------------- |
| Approach                    | Linux-side PNG injection into clipboard  | Windows-side enriched DataObject (`image + text(path) + fileDrop`) |
| Claude Code UX              | Inline paste: input shows `[Image #N]`   | Path paste: input shows `/mnt/c/.../a1b2.png` |
| Paste in Paint / image apps | Works (PNG on Windows clipboard)         | Works (image kept in DataObject)  |
| Paste in Explorer           | —                                        | Works (file drop list) |
| Excel / spreadsheet filter  | No                                       | Yes |
| De-duplication              | No                                       | Yes (SHA-256) |
| Implementation              | Single Bash daemon + installer scripts   | Go binary + persistent PowerShell STA subprocess |
| Dependencies                | `wl-clipboard`, `xclip`, `imagemagick`, `coreutils`, `util-linux` | Single Go binary |

In short: this tool stays out of the Windows clipboard entirely and gives you
a clean inline-paste experience in Claude Code. If you want cross-app paste
(Paint, Explorer, multiple terminals) handled by a single tool, prefer
`wsl-screenshot-cli`.

## Requirements

* WSL2 with WSLg (ships in Windows 11 and current Windows 10 builds)
* Ubuntu / Debian-family distribution

## Install

### 1. System packages (required, one-time)

The daemon shells out to `wl-paste`, `wl-copy`, `xclip`, and ImageMagick's
`convert`. None of these are typically pre-installed on a fresh WSL2 Ubuntu —
install them up front:

```bash
sudo apt update && sudo apt install -y wl-clipboard xclip imagemagick coreutils util-linux curl
```

What each package supplies:

| Package        | Provides                              | Why it is needed |
| -------------- | ------------------------------------- | ---------------- |
| `wl-clipboard` | `wl-paste`, `wl-copy`                 | Read / write the WSLg Wayland clipboard |
| `xclip`        | `xclip`                               | Mirror the converted PNG onto the X11 clipboard |
| `imagemagick`  | `convert`                             | BMP → PNG conversion |
| `coreutils`    | `mktemp`, `sha256sum`, `wc`           | Temp files, content hashing for change detection |
| `util-linux`   | `flock`, `timeout`                    | Single-instance lock; per-call IPC timeouts |
| `curl`         | `curl`                                | Used **only** by the one-shot installer below — skip if you cloned the repo |

The installer fails fast with the same `sudo apt` line above if any binary is
missing; it never invokes `sudo` itself.

### 2. Run the installer

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main/install.sh)
```

Or, from a local clone (no `curl` needed):

```bash
git clone https://github.com/PowerUserZ/wsl-clipboard-png-bridge.git
cd wsl-clipboard-png-bridge
bash install.sh
```

The installer:

1. Verifies you are on WSL2 and that required commands are present.
2. Copies the script to `~/.local/bin/wsl-clipboard-png-bridge`.
3. Adds (or replaces) a sentinel-marked block in `~/.bashrc` that
   fire-and-forget-spawns the daemon on shell startup. Single-instance
   behaviour comes from the daemon's own `flock`, so duplicate spawns exit
   silently.
4. Starts the daemon immediately.

## Verify

```bash
pgrep -af wsl-clipboard-png-bridge
```

End-to-end test:

1. Take a screenshot on Windows (`Win+Shift+S` or Snipping Tool).
2. Switch to your WSL Claude Code session.
3. Press `Alt+V` (after the one-time keybinding setup below — see
   *"Claude Code paste keybinding"*).
4. The image attaches as `[Image #N]`.

## Claude Code paste keybinding (one-time, required on Warp for Windows)

> **TL;DR** — create `~/.claude/keybindings.json` with the snippet below and
> use `Alt+V` instead of `Ctrl+V` to paste images. This is independent of
> the daemon — it lives entirely on the Claude Code side.

This daemon's job is to put `image/png` on the WSL Wayland *and* X11
clipboards. After it runs, your Linux clipboard is image-ready and Claude
Code (which reads X11 first via `xclip`, falling back to `wl-paste`) can
attach the screenshot. **However**, getting the *paste keystroke* to reach
Claude Code's TUI is a separate problem and depends on which Windows
terminal you use.

### Why default `Ctrl+V` does not work on Warp for Windows

Claude Code's default chat-image-paste keybinding on Linux/WSL is `Ctrl+V`
(action: `chat:imagePaste`). Warp on Windows intercepts `Ctrl+V` for its
own *text-only* paste path: it reads the Windows clipboard, and if there
is no text format on it (an image-only clipboard right after a screenshot
falls into this case), Warp silently does nothing. The keystroke never
reaches Claude Code's TUI, so the image never attaches — even though our
daemon has populated the Linux clipboards correctly.

This is consistent with [`warpdotdev/Warp#7069`](https://github.com/warpdotdev/Warp/issues/7069).
It is a Warp-side default-binding conflict, not a daemon bug. Codex CLI
happens to default to `Alt+V`, which Warp passes through to the TUI — that
is why image paste "just works" in Codex on the same setup.

### Fix — bind `Alt+V` to image paste in Claude Code

Claude Code supports user keybindings via `~/.claude/keybindings.json`.
Add this file (it is loaded by Claude Code's keybinding watcher; new
sessions pick it up immediately):

```json
{
  "$schema": "https://claude.ai/schemas/keybindings.json",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "alt+v": "chat:imagePaste"
      }
    }
  ]
}
```

Then take a screenshot and press `Alt+V` in Claude Code. The image
attaches as `[Image #N]`.

If you use Windows Terminal, vanilla WSL `wsl.exe` shell, or another
terminal that does not intercept `Ctrl+V`, the default `Ctrl+V` keeps
working and you can skip this step.

## How it works

```
Win+Shift+S
   │
   ▼
Windows clipboard (image/bmp)
   │     WSLg bridge
   ▼
WSL Wayland clipboard (image/bmp)
   │     wsl-clipboard-png-bridge polls every 300 ms
   ▼
ImageMagick: BMP → PNG (5 s timeout)
   │
   ├─► wl-copy  (Wayland clipboard, image/png)
   └─► xclip    (X11 clipboard,    image/png)
        │
        ▼
Claude Code Alt+V → chat:imagePaste → [Image #N]
```

`wl-paste --watch` cannot be used: WSLg ships the Weston compositor, which
does not implement the `wlroots` data-control protocol. Short-interval polling
is the only practical option today.

## Configuration

All environment variables are optional; invalid values fall back to defaults
with a warning on stderr.

### Polling

| Variable                       | Default | Meaning |
| ------------------------------ | ------- | ------- |
| `CLIPBOARD_WATCH_INTERVAL`     | `0.3`   | **Active** poll interval in seconds (positive number). Used right after a successful conversion and for `CLIPBOARD_ACTIVE_WINDOW_SEC` seconds afterwards. Pre-0.1.5 this was the only interval; setting `CLIPBOARD_IDLE_INTERVAL=0.3` restores the old steady-state behaviour. |
| `CLIPBOARD_IDLE_INTERVAL`      | `1.5`   | **Idle** poll interval in seconds (positive number). Used when no successful publish has happened within `CLIPBOARD_ACTIVE_WINDOW_SEC`. Drops idle CPU ~5x at the cost of one extra poll of latency for the first screenshot after a long quiet period. |
| `CLIPBOARD_ACTIVE_WINDOW_SEC`  | `5`     | Seconds the daemon stays in fast-poll mode after a successful publish (positive integer). Each new conversion extends the window. |
| `CLIPBOARD_SIGNATURE_EVERY`    | `3`     | When clipboard MIME types are unchanged, compute a content signature every N polls (positive integer). Lower = faster back-to-back screenshot detection, higher = lower CPU usage. |

### Resource limits

| Variable                       | Default     | Meaning |
| ------------------------------ | ----------- | ------- |
| `CLIPBOARD_CONVERT_TIMEOUT`    | `5`         | Maximum seconds each ImageMagick conversion may run before being killed (positive integer). |
| `CLIPBOARD_CONVERT_MEMORY_MB`  | `256`       | `convert -limit memory/map` ceiling (MiB, positive integer). |
| `CLIPBOARD_CONVERT_DISK_MB`    | `512`       | `convert -limit disk` ceiling (MiB, positive integer). |
| `CLIPBOARD_IO_TIMEOUT`         | `2`         | Per-call timeout (seconds) on every blocking `wl-paste`, `wl-copy`, and `xclip` invocation. Prevents a hung selection owner from wedging the loop. |
| `CLIPBOARD_HASH_TIMEOUT`       | `2`         | Total timeout (seconds) for one signature computation. |
| `CLIPBOARD_HASH_MAX_BYTES`     | `8388608`   | Bytes of clipboard content hashed per signature (positive integer). The full byte count is mixed into the signature alongside the prefix hash to defeat prefix-only collisions. |

### Diagnostics

| Variable                       | Default | Meaning |
| ------------------------------ | ------- | ------- |
| `CLIPBOARD_DEBUG`              | `0`     | Set to `1` to emit millisecond-stamped diagnostics on stderr at every decision point in the poll loop. Use as `CLIPBOARD_DEBUG=1 ./wsl-clipboard-png-bridge 2>~/wcpb.log` for bug reports. Off by default; the no-op debug helper costs ~5 µs per poll. |
| `WCPB_LOCK_FILE`               | `~/.cache/wsl-clipboard-png-bridge.lock` | Override the single-instance lock file path. |

## Security notes

* **Trust model.** Anything a local user can place on their own Windows
  clipboard is treated as trusted input. The daemon runs as the current user
  only and opens no network sockets.
* **Temp files.** Each conversion uses `mktemp` (0600 permissions) in `$TMPDIR`,
  and a `trap` removes the file on normal exit, `INT`, `TERM`, or `HUP`.
* **ImageMagick attack surface.** BMP parsing has had notable CVEs historically
  (e.g. ImageTragick — CVE-2016-3714). This bridge converts BMP bytes with a
  wall-clock timeout plus ImageMagick memory/map/disk limits to bound resource
  use on malformed input, and relies on Ubuntu's default `policy.xml` limits.
  If your threat model does not include "a local user pastes a hostile BMP to
  their own clipboard", you can skip this tool. The daemon is a single Bash
  script with focused shell tests — audit it before installing.
* **No privilege escalation.** Install writes only under `$HOME`, and the
  installer never invokes `sudo` silently.

## Limitations

* Helps only the **WSL-side** Claude Code build. The Windows-native build
  already handles BMP through `powershell Get-Clipboard -Format Image`.
* Polling-based (300 ms default). WSLg does not expose event-driven clipboard
  watching today.
* Tested on WSL2 Ubuntu 24.04 only; other Debian-family distributions should
  work but are not CI-tested.
* Getting the paste *keystroke* to Claude Code's TUI is terminal-dependent.
  On **Warp for Windows** the default `Ctrl+V` does not work and a one-time
  Claude Code keybinding override is required (see
  [Claude Code paste keybinding](#claude-code-paste-keybinding-one-time-required-on-warp-for-windows) above).
  Windows Terminal and vanilla `wsl.exe` shells pass `Ctrl+V` through to
  the TUI and need no extra setup.

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main/uninstall.sh)
```

Or manually: kill the daemon, delete `~/.local/bin/wsl-clipboard-png-bridge`,
and remove the sentinel-marked block from `~/.bashrc`.

## Related

* Claude Code MIME handling: [anthropics/claude-code#25935](https://github.com/anthropics/claude-code/issues/25935)
* Claude Code keybinding parity under WSL: [anthropics/claude-code#50985](https://github.com/anthropics/claude-code/issues/50985)
* Warp for Windows paste interception: [warpdotdev/Warp#7069](https://github.com/warpdotdev/Warp/issues/7069)
* Complementary tool — path-paste approach: [Nailuu/wsl-screenshot-cli](https://github.com/Nailuu/wsl-screenshot-cli)

## License

[MIT](LICENSE)
