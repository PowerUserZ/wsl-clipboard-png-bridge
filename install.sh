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
PROC_ROOT="${WCPB_PROC_ROOT:-/proc}"
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

find_daemon_pids() {
    local proc pid cmdline
    for proc in "$PROC_ROOT"/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        pid="${proc##*/}"
        # The daemon's literal argv is "bash <INSTALL_PATH>". Compare argv
        # after NUL-to-space normalization instead of using pgrep's regex
        # matcher; home paths may legally contain regex metacharacters.
        cmdline="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
        cmdline="${cmdline% }"
        if [ "$cmdline" = "bash $INSTALL_PATH" ]; then
            printf '%s\n' "$pid"
        fi
    done
}

# --- environment checks ---------------------------------------------------

if ! { [ -r /proc/sys/kernel/osrelease ] && grep -qi "microsoft" /proc/sys/kernel/osrelease; }; then
    die "this installer only runs under WSL2 (detected non-WSL kernel)"
fi
if ! grep -qi "wsl2" /proc/sys/kernel/osrelease; then
    die "this installer requires WSL2 (detected WSL1-compatible kernel string)"
fi

missing=()
required_cmds=(wl-paste wl-copy xclip convert timeout flock mktemp sha256sum tr setsid)
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
    if command -v setsid >/dev/null 2>&1; then
        setsid -f "\$HOME/.local/bin/$SCRIPT_NAME" >/dev/null 2>&1
    else
        nohup "\$HOME/.local/bin/$SCRIPT_NAME" >/dev/null 2>&1 &
        disown
    fi
fi
EOF
    printf '%s\n' "$SENTINEL_END"
}

escape_sed_literal() {
    printf '%s' "$1" | sed 's/[][\/.^$*]/\\&/g'
}

replace_bashrc_from_tmp() {
    # Preserve an existing .bashrc mode, ownership, and symlink target. `install
    # -m 0644` would silently relax a user's more restrictive permissions.
    cp "$tmp_bashrc" "$BASHRC"
}

bashrc_start_count=0
bashrc_end_count=0
if [ -f "$BASHRC" ]; then
    bashrc_start_count="$(grep -Fxc "$SENTINEL_START" "$BASHRC" || true)"
    bashrc_end_count="$(grep -Fxc "$SENTINEL_END" "$BASHRC" || true)"
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
    sed "/^$start_re\$/,/^$end_re\$/d" "$BASHRC" >"$tmp_bashrc"
    emit_bashrc_block >>"$tmp_bashrc"
    replace_bashrc_from_tmp
    rm -f "$tmp_bashrc"
    tmp_bashrc=""
else
    log "appending managed block to $BASHRC"
    emit_bashrc_block >>"$BASHRC"
fi

# --- start the daemon now ------------------------------------------------

log "starting daemon (duplicate spawns exit silently via the daemon's self-lock)"
setsid -f "$INSTALL_PATH" >/dev/null 2>&1

# Match the daemon's exact full cmdline ("bash <INSTALL_PATH>") literally via
# /proc, the same approach uninstall.sh uses. Avoid pgrep regex matching here:
# paths under $HOME may contain regex metacharacters even though that is rare.
sleep 0.5
if [ -n "$(find_daemon_pids | sed -n '1p')" ]; then
    log "daemon running"
else
    warn "daemon did not start; inspect \`$INSTALL_PATH\` manually"
fi

cat <<'EOF'

installation complete.

verify daemon:
  pgrep -af wsl-clipboard-png-bridge

EOF

# --- Claude Code keybinding check ----------------------------------------
#
# The daemon populates the Linux clipboard with image/png, but Claude Code
# also needs a working *paste keystroke* to reach its TUI. On Warp for
# Windows the default Ctrl+V is intercepted by Warp's text-paste path and
# silently fails on image-only clipboards, so a one-time custom keybinding
# is required. Print a clear, copy-pasteable warning when the user has not
# set it up yet, and a green confirmation when they have. Re-running the
# installer just re-checks; nothing is written to ~/.claude.
KB_FILE="$HOME/.claude/keybindings.json"
if [ -f "$KB_FILE" ] && grep -Eq '"alt\+v"[[:space:]]*:[[:space:]]*"chat:imagePaste"' "$KB_FILE"; then
    printf '\033[1;32m==>\033[0m Claude Code keybinding: \033[1;32m✓\033[0m alt+v → chat:imagePaste (configured)\n'
else
    printf '\n\033[1;33m==> action required for image paste in Claude Code:\033[0m\n\n'
    cat <<'EOF'
On Warp for Windows the default Ctrl+V does NOT trigger image paste —
Warp intercepts it for text-paste and silently fails on image-only
clipboards. One-time fix: bind Alt+V to chat:imagePaste in Claude Code.

Create ~/.claude/keybindings.json with:

  {
    "$schema": "https://claude.ai/schemas/keybindings.json",
    "bindings": [
      {
        "context": "Chat",
        "bindings": { "alt+v": "chat:imagePaste" }
      }
    ]
  }

Then use Alt+V (instead of Ctrl+V) to paste images.
Windows Terminal / vanilla wsl.exe users: Ctrl+V already works — skip.

Full explanation: README → "Claude Code paste keybinding".
EOF
fi

cat <<'EOF'

test end-to-end:
  1. take a screenshot on Windows (Win+Shift+S, ShareX with "Copy image
     to clipboard" enabled, or Snipping Tool)
  2. in your WSL Claude Code session, press Alt+V
  3. the image attaches as [Image #N]

uninstall:
  bash <(curl -fsSL https://raw.githubusercontent.com/PowerUserZ/wsl-clipboard-png-bridge/main/uninstall.sh)

For immutable installs, run uninstall.sh from the same reviewed checkout or
replace "main" in the raw URL with the same reviewed tag/commit SHA.
EOF
