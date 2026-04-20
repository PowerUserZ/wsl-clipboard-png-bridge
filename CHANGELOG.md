# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [Semantic Versioning](https://semver.org/).

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
