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
PROC_ROOT="${WCPB_PROC_ROOT:-/proc}"
tmp=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }

escape_sed_literal() {
    printf '%s' "$1" | sed 's/[][\/.^$*]/\\&/g'
}

cleanup() {
    if [ -n "$tmp" ]; then
        rm -f "$tmp"
    fi
}
trap cleanup EXIT

find_daemon_pids() {
    local proc pid cmdline
    for proc in "$PROC_ROOT"/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        pid="${proc##*/}"
        # Compare the literal argv string. pgrep/pkill -f use regex matching,
        # so an unusual $HOME containing regex metacharacters can mis-match.
        cmdline="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
        cmdline="${cmdline% }"
        if [ "$cmdline" = "bash $INSTALL_PATH" ]; then
            printf '%s\n' "$pid"
        fi
    done
}

# Stop the daemon.
#
# The daemon's cmdline is exactly "bash <INSTALL_PATH>" because the script
# starts with `#!/usr/bin/env bash`. Use a literal /proc cmdline comparison so
# unrelated processes whose cmdline merely contains the install path are not
# killed, and so regex metacharacters in $HOME are not interpreted.
mapfile -t daemon_pids < <(find_daemon_pids)
if (( ${#daemon_pids[@]} > 0 )); then
    log "stopping daemon"
    kill "${daemon_pids[@]}" || true
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

# Strip the sentinel-marked block from bashrc (if present) — but ONLY when
# both sentinels are present. If just the start sentinel remains (for
# example because the user edited the file manually and removed the end
# sentinel), a naive `sed "/START/,/END/d"` deletes from the start sentinel
# all the way to EOF and silently destroys unrelated user content below
# the block. Refuse to auto-remove in that case.
if [ -f "$BASHRC" ]; then
    bashrc_start_count="$(grep -Fxc "$SENTINEL_START" "$BASHRC" || true)"
    bashrc_end_count="$(grep -Fxc "$SENTINEL_END" "$BASHRC" || true)"
else
    bashrc_start_count=0
    bashrc_end_count=0
fi

if [ "$bashrc_start_count" -gt 0 ]; then
    if [ "$bashrc_end_count" -eq 0 ]; then
        warn "found the start sentinel in $BASHRC but no matching end sentinel."
        warn "refusing to auto-remove the block to avoid deleting unrelated"
        warn "content between the start sentinel and EOF."
        warn "please edit $BASHRC by hand and remove the lines from:"
        warn "    $SENTINEL_START"
        warn "down to (and including) a line containing:"
        warn "    $SENTINEL_END"
    elif [ "$bashrc_start_count" -ne "$bashrc_end_count" ]; then
        warn "found mismatched managed block sentinels in $BASHRC."
        warn "refusing to auto-remove the block to avoid deleting unrelated"
        warn "shell configuration. Please inspect and edit the file by hand."
    elif [ "$bashrc_start_count" -gt 1 ]; then
        warn "found multiple managed blocks in $BASHRC."
        warn "refusing to auto-remove them automatically; please inspect and"
        warn "remove the managed blocks by hand."
    else
        log "removing managed block from $BASHRC"
        tmp="$(mktemp)"
        # Delete from SENTINEL_START through SENTINEL_END inclusive.
        # Match exact sentinel lines only; ordinary user text that merely
        # contains the sentinel string must not be treated as a managed block.
        start_re="$(escape_sed_literal "$SENTINEL_START")"
        end_re="$(escape_sed_literal "$SENTINEL_END")"
        sed "/^$start_re\$/,/^$end_re\$/d" "$BASHRC" >"$tmp"
        # Preserve an existing .bashrc mode, ownership, and symlink target.
        cp "$tmp" "$BASHRC"
        rm -f "$tmp"
        tmp=""
    fi
fi

log "uninstall complete. apt packages (wl-clipboard, xclip, imagemagick) left installed."
