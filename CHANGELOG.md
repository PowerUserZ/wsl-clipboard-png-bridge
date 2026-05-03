# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.8] — 2026-05-03

### Fixed
- Clipboard content signatures now hash the full image stream instead of a
  bounded prefix. This closes the same-size/same-prefix back-to-back screenshot
  miss where later pixels changed but the first hashed bytes did not.
- Clipboard signature hashing no longer depends on `wc`; the daemon streams
  directly into `sha256sum` and separately checks the `wl-paste`/`timeout`
  status so partial timed-out reads are not cached.
- `clipboard_signature()` now explicitly disables `errexit` inside its
  subshell, preserving the intended "print empty and exit 0" contract when a
  clipboard owner disappears or `wl-paste` fails during signature reads.
- The daemon no longer exits after a successful publish when the post-publish
  signature refresh comes back empty; it now treats that as an unknown
  signature instead of letting `set -e` trip on a false `[ -n "$refreshed" ]`.
- Publishing now runs the best-effort X11 mirror before the final Wayland
  `wl-copy` write, because real WSLg testing showed `xclip` can otherwise clear
  the Wayland image/png selection owner.
- The daemon now ignores SIGHUP so `nohup ... &` startup from `install.sh` and
  the managed `.bashrc` block actually survives after the spawning shell exits.
- `install.sh` and the managed `.bashrc` block now prefer `setsid -f` for
  daemon startup so non-interactive parent-shell cleanup does not terminate the
  bridge immediately after installation.
- Daemon detection in `install.sh` and daemon stopping in `uninstall.sh` now
  compare `/proc/*/cmdline` literally instead of using `pgrep` / `pkill`
  regex matching. This keeps unusual home paths containing regex
  metacharacters from mis-matching.
- `install.sh` and `uninstall.sh` now preserve existing `~/.bashrc`
  permissions when rewriting the managed block, and sentinel detection matches
  exact lines only so ordinary user text containing sentinel strings is not
  treated as a managed block.
- `uninstall.sh` now refuses mismatched or duplicate managed-block sentinels
  instead of deleting a possibly ambiguous range from `~/.bashrc`.
- `install.sh` now checks for `tr`, which its literal `/proc` cmdline helper
  uses to normalize NUL-separated argv data.

### Added
- Regression coverage for same-size/same-prefix screenshot changes and for
  literal daemon cmdline detection.
- Regression coverage for signature-read failures so transient `wl-paste`
  errors do not kill the daemon.
- Regression coverage for empty post-publish signature refreshes.
- Regression coverage for keeping the final Wayland PNG publish after the X11
  mirror path.
- Regression coverage for SIGHUP survival after daemon startup.
- Regression coverage for `uninstall.sh` managed-block removal, partial-block
  refusal, installed-file cleanup, lock-file cleanup, and literal daemon
  cmdline matching.
- Regression coverage for preserving restrictive `.bashrc` permissions and
  ignoring sentinel text embedded inside ordinary shell lines.
- Regression coverage for `uninstall.sh` refusing mismatched sentinel blocks
  while preserving the original `.bashrc`.

### Documentation
- README now shows an immutable local-clone install path before the moving
  `main` one-shot installer.
- README now documents that auto-start is currently installed through
  `~/.bashrc` only, with zsh/fish users needing an equivalent startup hook or
  manual start until systemd user-service support exists.
- **README now documents the Claude Code paste keybinding override required
  on Warp for Windows.** This was the missing piece that made the project
  appear broken for users on the most common WSL2 + Warp setup: the daemon
  was correctly populating both Wayland and X11 clipboards with `image/png`,
  but Claude Code's default `Ctrl+V` chat-image-paste binding never reached
  the TUI because Warp on Windows intercepts `Ctrl+V` for its own text-paste
  path and silently does nothing when the clipboard has no text format
  (image-only clipboards immediately after a screenshot). The fix is a
  one-time `~/.claude/keybindings.json` snippet binding `alt+v` to
  `chat:imagePaste`; the daemon itself needs no change. The previous
  `Limitations` note pointed at remapping Warp's keybinding, which is
  the wrong side — the override belongs on Claude Code, not Warp. Section
  added: **Claude Code paste keybinding (one-time, required on Warp for
  Windows)**, with explanation, snippet, and a note that Codex CLI works
  out of the box because its default is already `Alt+V`.

## [0.1.7] — 2026-04-28

### Fixed
- `install.sh` now replaces an existing sentinel-managed `.bashrc` block
  instead of leaving old auto-start code in place. If only one sentinel is
  present, sentinel counts are mismatched, or multiple managed blocks exist,
  the installer refuses to rewrite the file automatically to avoid corrupting
  user shell configuration.
- Successful publishes switch the current loop's final sleep to the active
  polling interval immediately, so the first screenshot after idle mode does
  not leave the next screenshot waiting for one idle sleep.
- Partial publish failures no longer advance the image signature cache. Wayland
  must be ready and the X11 mirror must accept the PNG before the daemon treats
  an image as fully handled.
- **`mktemp` failure at the conversion site no longer kills the daemon.**
  `tmp=$(mktemp --suffix=.png)` was unguarded; under `set -e`, any transient
  host failure (TMPDIR full, EMFILE, denied perms) propagated as a daemon
  exit, leaving the user without a clipboard bridge until the next login
  shell respawned it. The substitution is now wrapped so `tmp=""` and the
  existing `[ -s "$tmp" ]` publish gate skip the iteration cleanly, with
  `did_work=false` arming the periodic-hash retry.
- Stale documentation was aligned with the current implementation: old
  implementation-size wording was removed, the internal guidance no longer
  claims there is no test runner, and the release guidance no longer claims
  every historical changelog entry has a pushed tag.

### Added
- `tests/run.sh`, a dependency-free Bash regression harness with fake clipboard
  commands covering installer block replacement, broken sentinel refusal,
  active polling, X11 mirror retries, env fallback, lock contention, mktemp
  failure survival, MIME prefix non-match, and post-publish refresh
  (republish-prevention).
- CI now runs the regression suite after ShellCheck.

## [0.1.6] — 2026-04-26

### Fixed
- **Hidden production CPU leak — `debug()` no-op still evaluated all of
  its argument substitutions.** Bash expands `$(...)` in function arguments
  *before* the function runs, so even with `CLIPBOARD_DEBUG=0` (debug() is
  a `:` no-op stub) every poll iteration was paying for a `stat` fork
  inside `$(stat -c%s "$tmp" ...)` and several internal `$([ ... ] && echo
  true || echo false)` expansions. Microbenchmarked: **~5.3 ms/iteration
  → ~0.02 ms/iteration (99% reduction)**. The fix pre-computes all debug
  arguments into local variables (`types_changed`, `sig_changed`,
  `trigger_reason`, `_dbg_size`, `_dbg_src`) and gates `stat` behind an
  explicit `if [ "${CLIPBOARD_DEBUG:-0}" = "1" ]; then` check.

### Changed
- **`grep -qx PATTERN <<<"$types"` → bash `case` pattern matching.** Four
  per-poll `grep` fork+exec calls (two in the main loop, two in the
  post-conversion refresh) replaced with bash internal `case` statements.
  Saves ~150 µs per poll on top of the debug-args fix. Whole-line match
  semantics preserved by wrapping the input in literal newlines:
  `case $'\n'"$types"$'\n' in *$'\nimage/png\n'*) ... ;;`. Verified
  against 8 edge cases including prefix-trap inputs like
  `image/pngextra` and `X-image/png` (must not match).
- **`types_changed` cached as a boolean variable.** The string comparison
  `[ "$types" != "$last_types" ]` was evaluated 5 times per loop iteration
  (twice in debug args, three times in control flow). Now computed once
  per iteration and reused. Same treatment applied to `sig_changed` and
  `trigger_reason`, scoped to the branches where they are actually used.
- **`uninstall.sh` — `warn()` helper moved to the top of the script,
  alongside `log()`**, matching `install.sh`'s style and avoiding the
  prior dangling definition-after-use ordering.

## 0.1.5 — 2026-04-26

### Added
- **Adaptive polling** — `CLIPBOARD_IDLE_INTERVAL` (default `1.5` seconds)
  and `CLIPBOARD_ACTIVE_WINDOW_SEC` (default `5` seconds). After a successful
  publish the daemon stays in fast-poll mode (`CLIPBOARD_WATCH_INTERVAL`,
  default `0.3` s) for `CLIPBOARD_ACTIVE_WINDOW_SEC` seconds, then drops to
  `CLIPBOARD_IDLE_INTERVAL`. Reduces steady-state idle CPU by ~5x without
  changing post-screenshot latency. The existing `CLIPBOARD_WATCH_INTERVAL`
  variable now represents the **active** interval (backwards compatible —
  pre-0.1.5 behaviour can be restored with
  `CLIPBOARD_IDLE_INTERVAL=0.3`).
- **Structured debug logging** — `CLIPBOARD_DEBUG=1` enables
  millisecond-stamped diagnostics on stderr at every decision point in the
  poll loop (mode/interval, type detection, hash computation, convert
  outcome, publish outcome per-channel, state cache branch). Off by default;
  the debug helper is defined as `:` (no-op) in production so the only cost
  is an empty function call per poll site. Activate with
  `CLIPBOARD_DEBUG=1 ./wsl-clipboard-png-bridge 2>~/wcpb.log`.

## 0.1.4 — 2026-04-26

### Fixed
- **Critical — `clipboard_signature` returned empty for any clipboard
  larger than `CLIPBOARD_HASH_MAX_BYTES` (8 MiB default).** The inner
  pipeline `wl-paste | head -c N | sha256sum` runs under `set -o pipefail`;
  when `head -c N` reaches its byte cap it closes its stdin, causing
  `wl-paste` to receive `SIGPIPE` and exit 141, which `pipefail` then
  promoted to the pipeline's exit code, tripping the `|| exit 1` guard.
  Result: signatures for a typical 4K BMP screenshot (~33 MiB) silently
  came back empty, so the periodic `signature_every` re-hash that exists
  to catch back-to-back screenshots **never produced a usable hash**.
  `clipboard_signature()` is now a `() (...)` subshell-function with
  `set +o pipefail` scoped to its body; large clipboards now hash and
  dedup correctly. Verified with mock 16 MiB / 33 MiB streams.
- **Critical — fd 9 leak via `wl-copy` and `xclip` could permanently
  freeze the daemon's single-instance lock.** `exec 9>FILE` does not
  set `O_CLOEXEC`, so when `wl-copy` and `xclip` self-daemonize as the
  Wayland / X11 selection owner, they inherit fd 9 and keep the
  `flock(2)` advisory lock held even after the bridge daemon exits. A
  fresh daemon's `flock -n` then reports *"another instance is already
  running"* until the user manually kills the selection daemon. Both
  sites now close fd 9 in the child via `9>&-` redirection.
- **Pano her signature için iki kez okunuyordu.** Old
  `clipboard_signature` called `wl-paste` once for `head -c | sha256sum`
  and a second time for `wc -c`, doubling clipboard IPC and racing on
  size-vs-hash drift. New implementation streams once: `tee -p` splits
  into a truncated copy (sha256 input) and the full stream (wc for true
  size). For a 4K BMP this halves clipboard bandwidth (~33 MiB saved per
  signature). `tee -p` is required — default `tee` exits on `EPIPE`
  before forwarding the rest to `wc`, leading to a ~50% short-count.
- **`install.sh` reported "daemon running" via the same `pgrep -f
  $INSTALL_PATH` pattern that previously ate uninstall.sh's parent
  shell.** Now uses `pgrep -fx "bash $INSTALL_PATH"` for an exact
  cmdline match, consistent with `uninstall.sh`.

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

## 0.1.0 — 2026-04-20

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

[Unreleased]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.8
[0.1.1]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.1
[0.1.2]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.2
[0.1.3]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.3
[0.1.6]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.6
[0.1.7]: https://github.com/PowerUserZ/wsl-clipboard-png-bridge/releases/tag/v0.1.7
