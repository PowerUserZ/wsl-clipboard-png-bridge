# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Bash daemon that polls the WSLg Wayland clipboard for `image/bmp`
(produced by Windows screenshot tools — Snipping Tool / `Win+Shift+S` — and
proxied through WSLg), converts it to PNG via ImageMagick, and republishes the
PNG to the Wayland clipboard (`wl-copy`) with a best-effort X11 mirror
(`xclip`).

The point is to make WSL-side tools that only accept `image/png` (notably
Claude Code — see `anthropics/claude-code#25935`) able to receive Windows
screenshots without manual file-saving.

There is **no build step and no package manager**. Runtime code is Bash, and
the regression suite is a dependency-free Bash harness with fake clipboard
commands.

## Layout

- `wsl-clipboard-png-bridge` — the daemon (bash script, no extension; the
  script's literal cmdline is `bash <INSTALL_PATH>` — relevant for literal
  `/proc/*/cmdline` matching during install/uninstall).
- `install.sh` — copies the daemon to `~/.local/bin/`, appends a
  sentinel-marked block to `~/.bashrc` for auto-start, and spawns the daemon.
  Idempotent.
- `uninstall.sh` — reverse of `install.sh`.
- `tests/run.sh` — regression tests for installer/uninstaller block handling,
  daemon retry/cache behavior, env fallback, and single-instance locking.
- `.github/workflows/shellcheck.yml` — ShellCheck plus the Bash regression
  suite.
- `.github/workflows/claude-review.yml` — calls a reusable workflow from
  `PowerUserZ/.github`, pinned by commit SHA (do not switch back to a tag).
- `TASKS.md` — Turkish-language list of suggested code-review improvements;
  treat as backlog notes, not authoritative spec.

## Commands

```bash
# Lint (matches CI exactly — both .sh files and the extensionless daemon)
shellcheck -x install.sh uninstall.sh wsl-clipboard-png-bridge

# Regression tests (no WSLg required; fake clipboard commands are generated)
tests/run.sh

# Run the daemon in the foreground for manual testing
./wsl-clipboard-png-bridge

# End-to-end smoke test on a WSL2 host:
#   1. Take a screenshot with Win+Shift+S
#   2. Run: wl-paste --list-types          # should now include image/png
#   3. Optional: xclip -selection clipboard -t TARGETS -o may include image/png
```

There is no `--help` and no single-test invocation. Clipboard edge cases should
get a fake-command regression in `tests/run.sh`; host-specific WSLg issues are
still reproduced by running the daemon in the foreground and triggering the
failing clipboard transition by hand.

## Architecture (the only thing worth reading more than once)

The daemon is one `while true; do ... sleep "$current_interval"; done` loop
with a small state machine. Every iteration:

0. **Pick poll interval** — adaptive since 0.1.5. If `now < active_until`,
   use `CLIPBOARD_WATCH_INTERVAL` (active, default 0.3s). Otherwise use
   `CLIPBOARD_IDLE_INTERVAL` (idle, default 1.5s). Each successful publish
   bumps `active_until = now + CLIPBOARD_ACTIVE_WINDOW_SEC` so a burst of
   screenshots stays in fast-poll mode.
1. **List MIME types** on the Wayland clipboard (`wl-paste --list-types`).
2. **Decide whether to hash** clipboard bytes. Hashing happens when types
   *change* OR every `CLIPBOARD_SIGNATURE_EVERY` polls when types are
   unchanged but contain an image (back-to-back screenshots produce identical
   type lists but different bytes).
3. **Compute a content signature** if needed. Signature =
   `<sha256 of full clipboard bytes>`. Empty result means "read failed" —
   callers treat empty as *unknown* and refuse to overwrite the prior
   signature. The stream is hashed directly, while the `wl-paste`/`timeout`
   status is written to a private temp file so partial timed-out reads are not
   cached.
4. **Convert + publish** if `(types, signature)` changed and clipboard holds
   a PNG or BMP. Convert via `convert` with wall-clock `timeout` AND
   `-limit memory/map/disk`. Publish a best-effort X11 mirror (`xclip`) first,
   then publish Wayland (`wl-copy`) last so WSLg leaves `image/png` available to
   Wayland-native consumers. Both calls use `9>&-` to drop the daemon's lock fd
   in the daemonizing child.
5. **Advance the state cache** (`last_types`, `last_signature`) **only after
   the primary Wayland publish reports ready**. X11 mirroring is attempted
   first and is best-effort; a failed `xclip` write must not churn the same
   Wayland-ready PNG every signature tick. A failed conversion or failed
   Wayland publish keeps the old signature state so the periodic hash retry
   re-attempts the missing primary publish.

Every decision point above is instrumented with `debug "..."` calls that
are no-ops unless `CLIPBOARD_DEBUG=1` is set. Use that for any bug
reproduction: `CLIPBOARD_DEBUG=1 ./wsl-clipboard-png-bridge 2>~/wcpb.log`.

### Invariants the code depends on

- **`wl-copy` must run after `xclip`.** Real WSLg testing showed `xclip` writes
  can clear the Wayland clipboard owner. The daemon may attempt X11 mirroring,
  but the final operation must be `wl-copy` so the primary `image/png` target
  remains available.
- **Wayland success is the publish success criterion.** X11 mirroring is a
  compatibility bonus; if `wl-copy` succeeds and `xclip` fails, advance the cache
  instead of repeatedly converting and publishing the same content. If `wl-copy`
  fails, keep the old state so the next signature retry tries again.
- **Post-conversion signature refresh must re-read the MIME list.** After
  BMP → PNG, the clipboard advertises `image/png`, not `image/bmp`. Hashing
  with the stale `has_bmp` flag returns empty (the BMP slot is gone),
  `last_signature` stays on the pre-write value, and the same PNG is
  re-published `CLIPBOARD_SIGNATURE_EVERY` polls later. Fixed in 0.1.3.
- **Every blocking clipboard IPC call is wrapped in `timeout
  "$io_timeout"`** (default 2s). A hung selection owner on either the
  Wayland or X11 side would otherwise wedge the loop. This includes the
  `wl-paste` reads inside `clipboard_signature()`.
- **Why polling, not `wl-paste --watch`:** WSLg uses the Weston compositor,
  which does not implement the `wlroots` `data-control` protocol that
  `wl-paste --watch` requires. Do not "fix" this with `--watch`.
- **All numeric env vars are regex-validated** against `^[1-9][0-9]*$` (or a
  positive-decimal pattern for `CLIPBOARD_WATCH_INTERVAL`). Don't relax
  this — the values are expanded into `sleep` and `timeout` and would
  otherwise be a shell-injection vector.

### Configuration env vars (all optional)

| Variable | Default | Purpose |
|---|---|---|
| `CLIPBOARD_WATCH_INTERVAL` | `0.3` | **Active** poll interval (seconds, decimal allowed). |
| `CLIPBOARD_IDLE_INTERVAL` | `1.5` | **Idle** poll interval (since 0.1.5). Used when no successful publish in the last `CLIPBOARD_ACTIVE_WINDOW_SEC` seconds. To restore pre-0.1.5 behaviour, set this equal to `CLIPBOARD_WATCH_INTERVAL`. |
| `CLIPBOARD_ACTIVE_WINDOW_SEC` | `5` | Seconds to stay in fast-poll mode after a successful publish (since 0.1.5). |
| `CLIPBOARD_CONVERT_TIMEOUT` | `5` | Wall-clock cap on one ImageMagick run (positive int; `0` is rejected — it would fire immediately and break every conversion silently). |
| `CLIPBOARD_SIGNATURE_EVERY` | `3` | Hash bytes every N polls when types are unchanged. |
| `CLIPBOARD_HASH_TIMEOUT` | `2` | Cap on the signature hashing stage; the `wl-paste` read is separately capped by `CLIPBOARD_IO_TIMEOUT`. |
| `CLIPBOARD_IO_TIMEOUT` | `2` | Cap on any single `wl-paste`/`wl-copy`/`xclip` call. |
| `CLIPBOARD_CONVERT_MEMORY_MB` / `CLIPBOARD_CONVERT_DISK_MB` | tuned for 4K BMP | ImageMagick `-limit` ceilings. The memory value is also used for `-limit map`. |
| `CLIPBOARD_DEBUG` | `0` | Set to `1` for ms-stamped diagnostics on stderr (since 0.1.5). |
| `WCPB_LOCK_FILE` | `~/.cache/wsl-clipboard-png-bridge.lock` | Single-instance flock path. |

## Landmines (read before editing the named files)

These are real bugs we already paid for. The code looks plausible without
them; the comments at each site explain why.

- **`install.sh` / `uninstall.sh` daemon lookup uses literal
  `/proc/*/cmdline` comparison, not `pgrep` / `pkill -f`.** The daemon's
  cmdline is exactly `bash <INSTALL_PATH>`. `pkill -f "$INSTALL_PATH"`
  matched the shell *running uninstall.sh* (which has the path embedded in its
  own cmdline) and killed its own parent. Later `pgrep -fx` avoided substring
  matches but still interpreted regex metacharacters in unusual home paths.
  Keep the literal `/proc` comparison.
- **`uninstall.sh` — refuses to strip the bashrc block when only the START
  sentinel is present.** A naive `sed "/START/,/END/d"` deletes from the
  start sentinel to EOF if the user removed the END sentinel manually,
  silently destroying everything below the block. Both sentinels must be
  present, or we bail. Commit `0febf05`.
- **`install.sh` bashrc snippet — fire-and-forget spawn, no
  `flock -n 9 || exit 0` in the command group.** A `{ ... } &` runs in the
  parent shell, and `exit 0` inside it terminates the *login shell* whenever
  another daemon already holds the lock (observed to crash Warp for Windows
  with "Shell process exited prematurely"). The daemon does its own
  single-instance flock; the bashrc side just spawns. Commit `e45f477`.
- **Auto-start currently writes only `~/.bashrc`.** Do not claim zsh/fish
  auto-start works unless install.sh grows explicit support or systemd user
  service support. README should keep this limitation visible.
- **CI workflows must stay pinned to commit SHAs**, not tags. Both
  `shellcheck.yml` (`ludeeus/action-shellcheck@00cae5...`) and
  `claude-review.yml` (the `PowerUserZ/.github` reusable workflow) are
  pinned for supply-chain reasons. Commits `7991fe3`, `b109d15`.
- **`shellcheck` is invoked with `-x`** so the source-following is enabled,
  and the daemon's filename has no extension — CI lists it explicitly under
  `additional_files`. If you rename the daemon, update the workflow.
- **`clipboard_signature` is `() (...)` — a subshell-function — by design.**
  The body has a local trap for its temp file and keeps any shell-option
  changes scoped away from the parent where `set -euo pipefail` is mandatory.
  Don't convert this back to a `() { ... }` regular function.
- **`clipboard_signature` hashes the full stream.** Do not reintroduce a
  bounded-prefix signature. Prefix+size signatures miss same-sized screenshots
  when only later pixels change. Regression covered by
  `tests/run.sh::test_same_size_same_prefix_bmp_change_republishes`.
- **`clipboard_signature` always exits 0 (prints empty on failure).**
  Callers use `var=$(clipboard_signature ...)` and the parent shell has
  `set -e`. A nonzero return from a command substitution propagates and
  kills the daemon; the function therefore explicitly `exit 0`s after
  printing nothing on the failure path. Don't rewrite to `return 1` —
  that brings back the daemon-killing behaviour.
- **`wl-copy` and `xclip` invocations close fd 9 with `9>&-`.** Both
  utilities self-daemonize as the Wayland / X11 selection owner; without
  the redirection they inherit the daemon's flock fd and keep the lock
  held even after the daemon exits, deadlocking every future restart with
  "another instance is already running". The block comment above the
  `LOCK_FILE` section explains the failure mode in detail. Don't drop
  the `9>&-`. Commit for v0.1.4.
- **`install.sh` daemon-running check uses the same literal `/proc` helper
  as `uninstall.sh`.** Plain `pgrep -f` matches every process whose cmdline
  contains the install path, including the verifying shell, falsely reporting
  "daemon running" when the daemon failed to start. `pgrep -fx` is better but
  still regex-based. Regression covered by
  `tests/run.sh::test_installer_detects_daemon_with_literal_proc_cmdline`.
- **`debug "...$(...)..."` arguments are evaluated EVEN WHEN `debug()` is
  the no-op stub.** Bash expands `$(...)` in command arguments before the
  function body runs; a `debug() { :; }` body never executes the
  substitution, but bash still forks any subshells inside the argument
  list. v0.1.6 found that an innocuous-looking `debug "convert tmp_size=$(stat
  -c%s "$tmp")"` was spawning one `stat` per poll in production
  (~5 ms/iter overhead). The fix is **always** to pre-compute debug
  arguments into local variables (`_dbg_size=$(...)`, etc.) and gate any
  expensive ones behind an explicit
  `if [ "${CLIPBOARD_DEBUG:-0}" = "1" ]; then ...; fi` block. Do not
  inline `$(...)` into `debug` call sites. Commit for v0.1.6.
- **`grep -qx PATTERN <<<"$types"` is replaced with bash `case`
  whole-line matching** (`case $'\n'"$types"$'\n' in *$'\nimage/png\n'*)`).
  This is not just style — `grep` was forking on the polling hot path.
  If you reach for `grep` here, use `case` instead. The literal
  newline wrappers are mandatory: without them, a hypothetical
  `image/pngextra` MIME line would falsely match `image/png`. Commit
  for v0.1.6. Regression covered by
  `tests/run.sh::test_mime_prefix_does_not_false_match`.
- **`tmp=$(mktemp --suffix=.png)` is guarded with `if ! ...; then tmp=""`,
  not bare.** The daemon runs under `set -euo pipefail`; any standalone
  command-substitution assignment that exits nonzero terminates the
  daemon. `mktemp` can fail transiently on a host (TMPDIR full, EMFILE,
  denied perms), and "kill the long-running daemon and wait for the user's
  next login shell to respawn it" is the wrong failure mode. The
  conversion site now skips the iteration on mktemp failure (gated by
  `if $ok` around the wl-paste/convert pipeline) and the existing
  `did_work=false → retry_armed` path arms the next periodic-hash retry.
  Regression covered by
  `tests/run.sh::test_mktemp_failure_does_not_crash`.

## Trust model (don't bolt on extra validation)

Anything on the Windows clipboard is treated as trusted local input — the
user just authored it. The hardening that *is* there bounds resource use on
malformed input (timeout, `convert -limit`, `mktemp` 0600 perms), not
authenticates content. Do not add antivirus-style checks.

## Versioning

`CHANGELOG.md` follows Keep-a-Changelog. Keep entries factual about *the
state-machine bug fixed*, not just the symptom — that's how the existing
entries are written and why they remain useful as a reading list of invariants.
Before publishing a release, verify that any changelog reference links point to
tags or commits that actually exist.
