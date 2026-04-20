# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [Semantic Versioning](https://semver.org/).

## [0.1.1] — 2026-04-20

### Fixed
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
