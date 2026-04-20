# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [Semantic Versioning](https://semver.org/).

## [0.1.3] — 2026-04-20

### Fixed
- **Transient `wl-copy` / `xclip` write failures no longer mark a screenshot
  as successfully published.** The previous code set `did_work=true` as soon
  as the PNG temp file existed, then swallowed the publish-step exit codes
  with `|| true`. If both Wayland and X11 writes failed (clipboard-manager
  crash, transient DBus / X errors, ...) the daemon still cached the new
  signature and never retried — the screenshot was silently dropped.
  Now `did_work` becomes true only when **at least one** of `wl-copy` /
  `xclip` actually succeeded (or Wayland already held the PNG). If both
  fail, the cache is not advanced, so the next poll converts and publishes
  again.
- **Post-conversion signature refresh now reads the new MIME.** After a
  BMP → PNG conversion, the daemon correctly re-read the Wayland type list
  into `last_types`, but then still called `clipboard_signature "image/bmp"`
  based on the pre-conversion `has_bmp` flag. Since the clipboard now
  advertises `image/png`, that BMP read returned empty, `last_signature`
  stayed on the pre-write value, and the same PNG was re-published roughly
  `CLIPBOARD_SIGNATURE_EVERY` polls later. The refresh now picks the MIME
  from the **just-refreshed** `last_types` and hashes the current content.

## [0.1.2] — 2026-04-20

### Fixed
- **Stale X11 PNG no longer suppresses new Wayland BMP conversion.** The main
  loop previously skipped conversion when X11 already held `image/png`, and
  cached `last_types`/`last_signature` *before* the skipped work, so a fresh
  BMP arriving on Wayland was lost on the next poll. Conversion now runs
  whenever Wayland carries `image/bmp` or `image/png`, and the state cache
  advances only after the work succeeds (or when the clipboard contains no
  image to process).
- **Clipboard signatures no longer confuse read failure with empty content.**
  `clipboard_signature()` now runs its inner pipeline with `set -o pipefail`;
  a failed `wl-paste` returns the empty string instead of the deterministic
  `e3b0c442…` SHA-256-of-nothing hash. Callers refuse to cache empty
  signatures, so a transient Wayland blip no longer poisons change-detection.
- **Blocking clipboard IPC can no longer freeze the daemon.** Every
  `wl-paste`, `wl-copy`, and `xclip` call site — including the reads inside
  `clipboard_signature()` — is now wrapped in `timeout "$CLIPBOARD_IO_TIMEOUT"`
  (default `2` seconds). A hung selection owner drops the current poll
  instead of wedging the loop.
- **ImageMagick conversion is bounded by memory, map, and disk limits** in
  addition to the existing wall-clock timeout, via `convert -limit
  memory/map/disk`. A pathological BMP can no longer OOM the daemon before
  the wall-clock timer fires.
- **Prefix-collision on large screenshots.** The content signature now mixes
  the total clipboard byte length with the prefix SHA-256, so two 4K+ images
  that share their first 8 MiB (e.g. identical taskbar region) no longer
  collide and the second image is always detected.
  `CLIPBOARD_HASH_MAX_BYTES` default stays at `8388608` (8 MiB); size mixing
  closes the collision window without quadrupling per-poll I/O.

### Added
- `CLIPBOARD_IO_TIMEOUT` (default `2`) — wraps every blocking clipboard IPC.
- `CLIPBOARD_CONVERT_MEMORY_MB` (default `256`) — `convert -limit memory/map`.
- `CLIPBOARD_CONVERT_DISK_MB` (default `512`) — `convert -limit disk`.
- `wc` added to the startup dependency check (used by the size-mixed
  signature); already present on every Ubuntu/Debian base image via
  `coreutils`.

## [0.1.1] — 2026-04-20

### Fixed
- **Back-to-back screenshot reliability.** The daemon previously processed
  clipboard updates only when MIME types changed. Two consecutive screenshots
  both exposed as `image/bmp` kept the same type list, so the second image
  could be skipped. The loop now also tracks a content signature
  (SHA-256 of clipboard image bytes), so new screenshots are detected even
  when MIME types are unchanged.
- **Critical — shell crash under Warp for Windows.** The bashrc auto-start
  block used a `{ ... } 9>lock` command group (not a subshell), so
  `flock -n 9 || exit 0` terminated the **parent** login shell whenever
  another daemon already held the lock. This surfaced as
  *"Shell process exited prematurely"* in Warp every time a second terminal
  opened or the shell restarted with the daemon still running. The new block
  is a plain fire-and-forget spawn (`"$DAEMON" & disown`); single-instance
  behaviour is handled entirely by the daemon's own `exec 9>lock; flock -n 9`
  self-lock, so duplicate invocations exit silently with no effect on the
  parent shell. The "start daemon now" step in `install.sh` was also
  simplified to the same fire-and-forget pattern (previously used a correctly
  scoped `( ... )` subshell so it did not contribute to the crash, but is
  cleaner without it).
- **`CLIPBOARD_CONVERT_TIMEOUT=0` was silently accepted**, which made
  `timeout 0 convert …` return immediately and broke every conversion. The
  regex now requires a positive integer (`^[1-9][0-9]*$`) and logs a message
  on the fallback to `5`.
- **Local installer path no longer requires `curl`.** `install.sh` now checks
  for `curl` only when it needs to download from GitHub. Running `./install.sh`
  from a cloned checkout works without `curl`, matching the README guidance.
- **`CLIPBOARD_WATCH_INTERVAL=0` now correctly falls back** to the default
  `0.3` instead of being accepted as valid. This prevents accidental tight
  loops / busy polling caused by zero-second sleeps.

- **`uninstall.sh` killed the shell running it.** The daemon-stop step used
  `pkill -f "$INSTALL_PATH"`, which matched every process whose cmdline
  merely *contained* the install path — including the very shell invoking
  `uninstall.sh`, because that path is embedded in the shell's own command
  line. Tightened to `pgrep -fx "bash $INSTALL_PATH"` / `pkill -fx ...` so
  only the exact daemon cmdline matches.
- **Critical — `uninstall.sh` could silently destroy unrelated bashrc
  content.** If the `~/.bashrc` managed block was partially corrupted so
  that the start sentinel was still present but the end sentinel had been
  removed (manual edit, merge conflict resolution, another tool rewriting
  the file, etc.), the `sed "/START/,/END/d"` range semantically meant
  *"from start sentinel to end of file"* — deleting every line between the
  start sentinel and EOF, including exports, aliases, secrets, and
  `source` directives the user had written after the block. `uninstall.sh`
  now requires BOTH sentinels to be present before running the delete and
  emits a clear warning with manual-removal instructions otherwise.

### Changed
- README: `Requirements` section now mentions `curl` (needed by the one-shot
  installer; not needed when running `./install.sh` from a local checkout).
- README: minor wording / US-English consistency pass ("defense", threat-model
  sentence).
- Performance tuning: clipboard content signatures are now sampled every
  `CLIPBOARD_SIGNATURE_EVERY` polls (default `3`) when MIME types are
  unchanged, reducing steady-state CPU overhead while still detecting
  back-to-back screenshots.
- Added explicit `sha256sum` dependency checks in installer/runtime checks
  because signature-based detection now relies on it.
- Installer WSL guard now rejects WSL1 explicitly, aligning runtime checks
  with the documented "WSL2 required" support boundary.

## [0.1.0] — 2026-04-20

Initial public release.

### Added
- `wsl-clipboard-png-bridge` main daemon: polls the WSLg Wayland clipboard at
  300 ms intervals, converts `image/bmp` to `image/png` with ImageMagick,
  publishes the PNG to both Wayland (`wl-copy`) and X11 (`xclip`) clipboards.
- `install.sh` — idempotent installer with sentinel-marked `~/.bashrc` block
  and `flock`-based single-instance auto-start.
- `uninstall.sh` — reverse of install; leaves apt packages in place.
- `.github/workflows/shellcheck.yml` — lint-only CI on push / pull request.
- Hardening: `set -euo pipefail`, signal trap for temp-file cleanup,
  `timeout 5` around the ImageMagick conversion, regex validation of
  `CLIPBOARD_WATCH_INTERVAL` and `CLIPBOARD_CONVERT_TIMEOUT`, startup
  dependency check.

[0.1.0]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.0
[0.1.1]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.1
[0.1.2]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.2
[0.1.3]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.3
