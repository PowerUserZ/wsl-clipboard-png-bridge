#!/usr/bin/env bash
# install.sh — install wsl-clipboard-png-bridge into the current user's home.
#
# Idempotent: re-running will overwrite the script, keep the single managed
# bashrc block, and start (or keep alive) exactly one daemon.

set -euo pipefail

SCRIPT_NAME="wsl-clipboard-png-bridge"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/$SCRIPT_NAME"
LOCK_PATH="$HOME/.cache/${SCRIPT_NAME}.lock"
BASHRC="$HOME/.bashrc"
SENTINEL_START="# >>> ${SCRIPT_NAME} (managed block; do not edit) >>>"
SENTINEL_END="# <<< ${SCRIPT_NAME} <<<"

RAW_BASE="${WCPB_RAW_BASE:-https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main}"
SOURCE_SCRIPT="$(dirname "$(readlink -f "$0")")/$SCRIPT_NAME"
tmp=""
tmp_bashrc=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [ -n "$tmp" ]; then
        rm -f "$tmp"
    fi
    if [ -n "$tmp_bashrc" ]; then
        rm -f "$tmp_bashrc"
    fi
}
trap cleanup EXIT

# --- environment checks ---------------------------------------------------

if ! { [ -r /proc/sys/kernel/osrelease ] && grep -qi "microsoft" /proc/sys/kernel/osrelease; }; then
    die "this installer only runs under WSL2 (detected non-WSL kernel)"
fi
if ! grep -qi "wsl2" /proc/sys/kernel/osrelease; then
    die "this installer requires WSL2 (detected WSL1-compatible kernel string)"
fi

missing=()
required_cmds=(wl-paste wl-copy xclip convert timeout flock mktemp sha256sum)
if [ ! -f "$SOURCE_SCRIPT" ]; then
    required_cmds+=(curl)
fi
for cmd in "${required_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    warn "missing required commands: ${missing[*]}"
    echo "install them with:"
    echo "  sudo apt update && sudo apt install -y wl-clipboard xclip imagemagick coreutils util-linux curl"
    die "re-run this installer after installing the dependencies"
fi

# --- fetch or copy the script --------------------------------------------

mkdir -p "$INSTALL_DIR" "$(dirname "$LOCK_PATH")"

if [ -f "$SOURCE_SCRIPT" ]; then
    log "installing from local checkout"
    install -m 0755 "$SOURCE_SCRIPT" "$INSTALL_PATH"
else
    log "downloading $SCRIPT_NAME from $RAW_BASE"
    tmp="$(mktemp)"
    curl -fsSL "$RAW_BASE/$SCRIPT_NAME" -o "$tmp"
    install -m 0755 "$tmp" "$INSTALL_PATH"
fi

# --- idempotent bashrc block ---------------------------------------------

emit_bashrc_block() {
    printf '\n%s\n' "$SENTINEL_START"
    cat <<EOF
# Installed by wsl-clipboard-png-bridge/install.sh. Remove the entire block
# between the sentinel comments (or run uninstall.sh) to opt out.
# Fire-and-forget spawn. The daemon itself holds an exclusive flock on
# ~/.cache/${SCRIPT_NAME}.lock for its lifetime, so duplicate invocations
# exit silently with no effect on this shell. We intentionally avoid
# \`flock -n 9 || exit 0\` here because a \`{ ... }\` command group runs in
# the parent shell, and the \`exit\` would terminate the login shell
# whenever another daemon already held the lock (observed to crash Warp
# for Windows as "Shell process exited prematurely").
if command -v wl-paste >/dev/null 2>&1 && [ -x "\$HOME/.local/bin/$SCRIPT_NAME" ]; then
    "\$HOME/.local/bin/$SCRIPT_NAME" >/dev/null 2>&1 &
    disown
fi
EOF
    printf '%s\n' "$SENTINEL_END"
}

escape_sed_literal() {
    printf '%s' "$1" | sed 's/[][\/.^$*]/\\&/g'
}

bashrc_start_count=0
bashrc_end_count=0
if [ -f "$BASHRC" ]; then
    bashrc_start_count="$(grep -Fc "$SENTINEL_START" "$BASHRC" || true)"
    bashrc_end_count="$(grep -Fc "$SENTINEL_END" "$BASHRC" || true)"
fi

if [ "$bashrc_start_count" -eq 1 ] && [ "$bashrc_end_count" -eq 0 ]; then
    die "$BASHRC has a start sentinel but no matching end sentinel; refusing to rewrite it automatically"
elif [ "$bashrc_start_count" -eq 0 ] && [ "$bashrc_end_count" -eq 1 ]; then
    die "$BASHRC has an end sentinel but no matching start sentinel; refusing to rewrite it automatically"
elif [ "$bashrc_start_count" -ne "$bashrc_end_count" ]; then
    die "$BASHRC has mismatched managed block sentinels; refusing to rewrite it automatically"
elif [ "$bashrc_start_count" -gt 1 ]; then
    die "$BASHRC has multiple managed blocks; refusing to rewrite it automatically"
elif [ "$bashrc_start_count" -eq 1 ]; then
    log "replacing managed block in $BASHRC"
    tmp_bashrc="$(mktemp)"
    start_re="$(escape_sed_literal "$SENTINEL_START")"
    end_re="$(escape_sed_literal "$SENTINEL_END")"
    sed "/$start_re/,/$end_re/d" "$BASHRC" >"$tmp_bashrc"
    emit_bashrc_block >>"$tmp_bashrc"
    install -m 0644 "$tmp_bashrc" "$BASHRC"
    rm -f "$tmp_bashrc"
    tmp_bashrc=""
else
    log "appending managed block to $BASHRC"
    emit_bashrc_block >>"$BASHRC"
fi

# --- start the daemon now ------------------------------------------------

log "starting daemon (duplicate spawns exit silently via the daemon's self-lock)"
nohup "$INSTALL_PATH" >/dev/null 2>&1 &
disown

# Match the daemon's exact full cmdline ("bash <INSTALL_PATH>") with -fx, the
# same pattern uninstall.sh uses. Plain `pgrep -f "$INSTALL_PATH"` matches any
# process whose cmdline merely *contains* the install path — including this
# very script, an editor with the path open, or a verifying shell — and would
# falsely report "daemon running" when the actual daemon failed to start.
sleep 0.5
if pgrep -fx "bash $INSTALL_PATH" >/dev/null 2>&1; then
    log "daemon running"
else
    warn "daemon did not start; inspect \`$INSTALL_PATH\` manually"
fi

cat <<'EOF'

installation complete.

verify:
  pgrep -af wsl-clipboard-png-bridge

test end-to-end:
  1. take a screenshot on Windows (Win+Shift+S or Snipping Tool)
  2. in your WSL Claude Code session, press Alt+V (or Ctrl+V if remapped)
  3. the image should attach as [Image #N]

uninstall:
  bash <(curl -fsSL https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main/uninstall.sh)
EOF
