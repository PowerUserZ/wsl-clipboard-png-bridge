#!/usr/bin/env bash
# uninstall.sh — reverse of install.sh.
#
# Stops the daemon, removes the installed binary, strips the managed block
# from ~/.bashrc, and removes the lock file. Leaves apt packages installed.

set -euo pipefail

SCRIPT_NAME="wsl-clipboard-png-bridge"
INSTALL_PATH="$HOME/.local/bin/$SCRIPT_NAME"
LOCK_PATH="$HOME/.cache/${SCRIPT_NAME}.lock"
BASHRC="$HOME/.bashrc"
SENTINEL_START="# >>> ${SCRIPT_NAME} (managed block; do not edit) >>>"
SENTINEL_END="# <<< ${SCRIPT_NAME} <<<"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Stop the daemon.
#
# The daemon's cmdline is exactly "bash <INSTALL_PATH>" because the script
# starts with `#!/usr/bin/env bash`. We match that exact full cmdline with
# `pgrep -fx` so that unrelated processes whose cmdline merely *contains*
# "$INSTALL_PATH" — most notably the very shell running this script, which
# at this moment has the path embedded in its own command line — are not
# killed. A previous version used `pkill -f "$INSTALL_PATH"` and ended up
# killing its own parent shell.
daemon_cmdline="bash $INSTALL_PATH"
if pgrep -fx "$daemon_cmdline" >/dev/null 2>&1; then
    log "stopping daemon"
    pkill -fx "$daemon_cmdline" || true
    sleep 0.3
fi

if [ -f "$INSTALL_PATH" ]; then
    log "removing $INSTALL_PATH"
    rm -f "$INSTALL_PATH"
fi

if [ -f "$LOCK_PATH" ]; then
    log "removing $LOCK_PATH"
    rm -f "$LOCK_PATH"
fi

warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }

# Strip the sentinel-marked block from bashrc (if present) — but ONLY when
# both sentinels are present. If just the start sentinel remains (for
# example because the user edited the file manually and removed the end
# sentinel), a naive `sed "/START/,/END/d"` deletes from the start sentinel
# all the way to EOF and silently destroys unrelated user content below
# the block. Refuse to auto-remove in that case.
if [ -f "$BASHRC" ] && grep -Fq "$SENTINEL_START" "$BASHRC"; then
    if ! grep -Fq "$SENTINEL_END" "$BASHRC"; then
        warn "found the start sentinel in $BASHRC but no matching end sentinel."
        warn "refusing to auto-remove the block to avoid deleting unrelated"
        warn "content between the start sentinel and EOF."
        warn "please edit $BASHRC by hand and remove the lines from:"
        warn "    $SENTINEL_START"
        warn "down to (and including) a line containing:"
        warn "    $SENTINEL_END"
    else
        log "removing managed block from $BASHRC"
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        # Delete from SENTINEL_START through SENTINEL_END inclusive.
        # Using a portable sed range with literal anchors.
        sed "/$(printf '%s' "$SENTINEL_START" | sed 's/[][\/.^$*]/\\&/g')/,/$(printf '%s' "$SENTINEL_END" | sed 's/[][\/.^$*]/\\&/g')/d" "$BASHRC" >"$tmp"
        install -m 0644 "$tmp" "$BASHRC"
    fi
fi

log "uninstall complete. apt packages (wl-clipboard, xclip, imagemagick) left installed."
