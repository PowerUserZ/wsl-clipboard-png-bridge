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

# Stop the daemon (exact full-path match to avoid killing unrelated processes).
if pgrep -f "$INSTALL_PATH" >/dev/null 2>&1; then
    log "stopping daemon"
    pkill -f "$INSTALL_PATH" || true
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

# Strip the sentinel-marked block from bashrc (if present).
if [ -f "$BASHRC" ] && grep -Fq "$SENTINEL_START" "$BASHRC"; then
    log "removing managed block from $BASHRC"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    # Delete from SENTINEL_START through SENTINEL_END inclusive.
    # Using a portable sed range with literal anchors.
    sed "/$(printf '%s' "$SENTINEL_START" | sed 's/[][\/.^$*]/\\&/g')/,/$(printf '%s' "$SENTINEL_END" | sed 's/[][\/.^$*]/\\&/g')/d" "$BASHRC" >"$tmp"
    # Also squeeze a leading blank line left over from install.
    install -m 0644 "$tmp" "$BASHRC"
fi

log "uninstall complete. apt packages (wl-clipboard, xclip, imagemagick) left installed."
