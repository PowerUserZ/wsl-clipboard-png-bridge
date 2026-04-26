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
| Implementation              | ~70 lines of bash                        | Go binary + persistent PowerShell STA subprocess |
| Dependencies                | `wl-clipboard`, `xclip`, `imagemagick`   | Single Go binary |

In short: this tool stays out of the Windows clipboard entirely and gives you
a clean inline-paste experience in Claude Code. If you want cross-app paste
(Paint, Explorer, multiple terminals) handled by a single tool, prefer
`wsl-screenshot-cli`.

## Requirements

* WSL2 with WSLg (ships in Windows 11 and current Windows 10 builds)
* Ubuntu / Debian-family distribution
* Packages: `wl-clipboard xclip imagemagick coreutils util-linux curl`

`curl` is only required for the one-shot installer; if you clone the repo and
run `./install.sh` from inside it, you do not need `curl` because the installer
copies the script from the local checkout.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main/install.sh)
```

The installer:

1. Verifies you are on WSL2 and that required commands are present.
2. Copies the script to `~/.local/bin/wsl-clipboard-png-bridge`.
3. Appends a sentinel-marked block to `~/.bashrc` that starts exactly one
   daemon per user (via `flock`).
4. Starts the daemon immediately.

If any apt packages are missing, the installer prints a single `sudo apt`
command and exits — it never runs `sudo` silently.

## Verify

```bash
pgrep -af wsl-clipboard-png-bridge
```

End-to-end test:

1. Take a screenshot on Windows (`Win+Shift+S` or Snipping Tool).
2. Switch to your WSL Claude Code session.
3. Press `Alt+V` (or `Ctrl+V` if you have remapped; see below).
4. The image attaches as `[Image #N]`.

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
  `timeout 5` wrapper to bound memory / CPU on malformed input, and relies on
  Ubuntu's default `policy.xml` limits. If your threat model does not include
  "a local user pastes a hostile BMP to their own clipboard", you can skip
  this tool. The code is ~70 lines of bash — audit it before installing.
* **No privilege escalation.** Install writes only under `$HOME`, and the
  installer never invokes `sudo` silently.

## Limitations

* Helps only the **WSL-side** Claude Code build. The Windows-native build
  already handles BMP through `powershell Get-Clipboard -Format Image`.
* Polling-based (300 ms default). WSLg does not expose event-driven clipboard
  watching today.
* Tested on WSL2 Ubuntu 24.04 only; other Debian-family distributions should
  work but are not CI-tested.
* Claude Code's host terminal must deliver the paste keypress to the TUI. On
  Warp for Windows that typically requires remapping Warp's
  "Alternate terminal paste" off `Ctrl+V`; see
  [`warpdotdev/Warp#7069`](https://github.com/warpdotdev/Warp/issues/7069).

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
