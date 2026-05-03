#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME="wsl-clipboard-png-bridge"
SENTINEL_START="# >>> ${SCRIPT_NAME} (managed block; do not edit) >>>"
SENTINEL_END="# <<< ${SCRIPT_NAME} <<<"

tmp_dirs=()
failures=0

new_tmp() {
    local dir
    dir="$(mktemp -d)"
    tmp_dirs+=("$dir")
    printf '%s\n' "$dir"
}

cleanup() {
    local dir
    for dir in "${tmp_dirs[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

assert_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -Fq "$needle" "$file"; then
        printf 'expected %s to contain: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_not_contains() {
    local file="$1"
    local needle="$2"
    if grep -Fq "$needle" "$file"; then
        printf 'expected %s not to contain: %s\n' "$file" "$needle" >&2
        return 1
    fi
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'expected %s to be %s, got %s\n' "$label" "$expected" "$actual" >&2
        return 1
    fi
}

write_executable() {
    local path="$1"
    shift
    printf '%s\n' "$@" >"$path"
    chmod +x "$path"
}

make_installer_fakebin() {
    local fakebin="$1"
    local cmd
    mkdir -p "$fakebin"

    for cmd in wl-paste wl-copy xclip convert; do
        write_executable "$fakebin/$cmd" \
            '#!/usr/bin/env bash' \
            'exit 0'
    done

    cat >"$fakebin/grep" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do
    last="$arg"
done
if [ "$last" = "/proc/sys/kernel/osrelease" ]; then
    exit 0
fi
exec /usr/bin/grep "$@"
SH
    chmod +x "$fakebin/grep"

    write_executable "$fakebin/nohup" \
        '#!/usr/bin/env bash' \
        'exit 0'
    # shellcheck disable=SC2016
    write_executable "$fakebin/setsid" \
        '#!/usr/bin/env bash' \
        'if [ "${1:-}" = "-f" ]; then shift; fi' \
        'exit 0'
    write_executable "$fakebin/pgrep" \
        '#!/usr/bin/env bash' \
        'exit 1'
}

make_daemon_fakebin() {
    local fakebin="$1"
    mkdir -p "$fakebin"

    cat >"$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
    chmod +x "$fakebin/timeout"

    cat >"$fakebin/wl-paste" <<'SH'
#!/usr/bin/env bash
state="${FAKE_STATE:?}"
case "${1:-}" in
    --list-types)
        if [ -f "$state/wayland_png" ]; then
            printf 'image/png\n'
        elif [ -f "$state/types" ]; then
            cat "$state/types"
        fi
        ;;
    -t)
        if [ "${FAKE_WL_PASTE_READ_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        case "${2:-}" in
            image/bmp) cat "$state/bmp" ;;
            image/png)
                if [ "${FAKE_WL_PASTE_FAIL_PNG_AFTER_WL_COPY:-0}" = "1" ] && [ -f "$state/wayland_png" ]; then
                    exit 1
                fi
                cat "$state/png"
                ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
SH
    chmod +x "$fakebin/wl-paste"

    cat >"$fakebin/convert" <<'SH'
#!/usr/bin/env bash
cat
SH
    chmod +x "$fakebin/convert"

    cat >"$fakebin/wl-copy" <<'SH'
#!/usr/bin/env bash
state="${FAKE_STATE:?}"
count=0
if [ -f "$state/wl_copy_count" ]; then
    read -r count <"$state/wl_copy_count"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state/wl_copy_count"
if [ "${FAKE_WL_COPY_ALWAYS_FAIL:-0}" = "1" ]; then
    cat >/dev/null
    exit 1
fi
cat >"$state/png"
touch "$state/wayland_png"
SH
    chmod +x "$fakebin/wl-copy"

    cat >"$fakebin/xclip" <<'SH'
#!/usr/bin/env bash
state="${FAKE_STATE:?}"
count=0
if [ -f "$state/xclip_count" ]; then
    read -r count <"$state/xclip_count"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state/xclip_count"
if [ "${FAKE_XCLIP_ALWAYS_FAIL:-0}" = "1" ]; then
    exit 1
fi
if [ "${FAKE_XCLIP_FAIL_FIRST:-0}" = "1" ] && [ "$count" -eq 1 ]; then
    exit 1
fi
input=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-i" ]; then
        shift
        input="${1:-}"
    fi
    shift || true
done
if [ -n "$input" ]; then
    cp "$input" "$state/x11_png"
fi
if [ "${FAKE_XCLIP_CLEARS_WAYLAND:-0}" = "1" ]; then
    rm -f "$state/wayland_png"
fi
SH
    chmod +x "$fakebin/xclip"

    cat >"$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
state="${FAKE_STATE:?}"
count=0
if [ -f "$state/sleep_count" ]; then
    read -r count <"$state/sleep_count"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state/sleep_count"
printf '%s\n' "${1:-}" >>"$state/sleeps"
if [ -n "${FAKE_SLEEP_REAL_DELAY:-}" ]; then
    /usr/bin/sleep "$FAKE_SLEEP_REAL_DELAY"
fi
if [ "${FAKE_MUTATE_AFTER_SLEEP:-0}" = "$count" ] && [ -f "$state/bmp_next" ]; then
    cp "$state/bmp_next" "$state/bmp"
    rm -f "$state/png" "$state/wayland_png"
    printf 'image/bmp\n' >"$state/types"
fi
limit="${FAKE_SLEEP_LIMIT:-1}"
if [ "$count" -ge "$limit" ]; then
    exit "${FAKE_SLEEP_EXIT:-77}"
fi
exit 0
SH
    chmod +x "$fakebin/sleep"
}

test_installer_replaces_existing_block() {
    local tmp fakebin home out err start_count end_count expected_spawn mode
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    mkdir -p "$home"
    make_installer_fakebin "$fakebin"

    {
        printf 'before\n'
        printf '%s\n' "$SENTINEL_START"
        cat <<'EOF'
if command -v wl-paste >/dev/null 2>&1 && [ -x "$HOME/.local/bin/wsl-clipboard-png-bridge" ]; then
    {
        flock -n 9 || exit 0
        nohup "$HOME/.local/bin/wsl-clipboard-png-bridge" >/dev/null 2>&1 &
        disown
    } 9>"$HOME/.cache/wsl-clipboard-png-bridge.lock"
fi
EOF
        printf '%s\n' "$SENTINEL_END"
        printf 'after\n'
    } >"$home/.bashrc"
    chmod 0600 "$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    PATH="$fakebin:$PATH" HOME="$home" bash "$ROOT/install.sh" >"$out" 2>"$err" || return 1

    assert_contains "$out" "replacing managed block" || return 1
    assert_not_contains "$home/.bashrc" "        flock -n 9 || exit 0" || return 1
    expected_spawn="setsid -f \"\$HOME/.local/bin/wsl-clipboard-png-bridge\" >/dev/null 2>&1"
    assert_contains "$home/.bashrc" "$expected_spawn" || return 1
    assert_contains "$home/.bashrc" "before" || return 1
    assert_contains "$home/.bashrc" "after" || return 1
    mode="$(stat -c %a "$home/.bashrc")"
    assert_eq "600" "$mode" "bashrc mode after installer replacement" || return 1
    start_count="$(grep -Fxc "$SENTINEL_START" "$home/.bashrc")"
    end_count="$(grep -Fxc "$SENTINEL_END" "$home/.bashrc")"
    assert_eq "1" "$start_count" "start sentinel count" || return 1
    assert_eq "1" "$end_count" "end sentinel count" || return 1
}

test_installer_refuses_partial_block() {
    local tmp fakebin home out err status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    mkdir -p "$home"
    make_installer_fakebin "$fakebin"
    printf '%s\n' "$SENTINEL_START" >"$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    status=0
    PATH="$fakebin:$PATH" HOME="$home" bash "$ROOT/install.sh" >"$out" 2>"$err" || status=$?

    if [ "$status" -eq 0 ]; then
        printf 'installer unexpectedly accepted a partial managed block\n' >&2
        return 1
    fi
    assert_contains "$err" "no matching end sentinel" || return 1
}

test_installer_refuses_mismatched_blocks() {
    local tmp fakebin home out err status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    mkdir -p "$home"
    make_installer_fakebin "$fakebin"
    {
        printf '%s\n' "$SENTINEL_START"
        printf '%s\n' "$SENTINEL_END"
        printf '%s\n' "$SENTINEL_START"
    } >"$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    status=0
    PATH="$fakebin:$PATH" HOME="$home" bash "$ROOT/install.sh" >"$out" 2>"$err" || status=$?

    if [ "$status" -eq 0 ]; then
        printf 'installer unexpectedly accepted mismatched managed blocks\n' >&2
        return 1
    fi
    assert_contains "$err" "mismatched managed block sentinels" || return 1
}

test_installer_ignores_embedded_sentinel_text() {
    local tmp fakebin home out err start_count end_count
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    mkdir -p "$home"
    make_installer_fakebin "$fakebin"
    {
        printf 'before\n'
        printf 'echo "%s"\n' "$SENTINEL_START"
        printf 'echo "%s"\n' "$SENTINEL_END"
        printf 'after\n'
    } >"$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    PATH="$fakebin:$PATH" HOME="$home" bash "$ROOT/install.sh" >"$out" 2>"$err" || return 1

    assert_contains "$out" "appending managed block" || return 1
    assert_contains "$home/.bashrc" "echo \"$SENTINEL_START\"" || return 1
    assert_contains "$home/.bashrc" "echo \"$SENTINEL_END\"" || return 1
    start_count="$(grep -Fxc "$SENTINEL_START" "$home/.bashrc")"
    end_count="$(grep -Fxc "$SENTINEL_END" "$home/.bashrc")"
    assert_eq "1" "$start_count" "exact start sentinel count" || return 1
    assert_eq "1" "$end_count" "exact end sentinel count" || return 1
}

test_success_switches_sleep_to_active_interval() {
    local tmp fakebin home state status first_sleep
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/bmp\n' >"$state/types"
    printf 'bmp-bytes' >"$state/bmp"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=1 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.05 \
        CLIPBOARD_IDLE_INTERVAL=0.2 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    first_sleep="$(sed -n '1p' "$state/sleeps")"
    assert_eq "0.05" "$first_sleep" "post-publish sleep interval" || return 1
    assert_eq "1" "$(cat "$state/wl_copy_count")" "wl-copy call count" || return 1
    assert_eq "1" "$(cat "$state/xclip_count")" "xclip call count" || return 1
}

test_xclip_failure_does_not_republish_when_wayland_succeeds() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/png\n' >"$state/types"
    printf 'png-bytes' >"$state/png"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_XCLIP_ALWAYS_FAIL=1 \
        FAKE_SLEEP_LIMIT=3 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "1" "$(cat "$state/wl_copy_count")" "wl-copy called once after Wayland success" || return 1
    assert_eq "1" "$(cat "$state/xclip_count")" "xclip not retried after Wayland success" || return 1
}

test_publish_failures_retry_when_wayland_fails() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/png\n' >"$state/types"
    printf 'png-bytes' >"$state/png"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_XCLIP_ALWAYS_FAIL=1 \
        FAKE_WL_COPY_ALWAYS_FAIL=1 \
        FAKE_SLEEP_LIMIT=2 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "2" "$(cat "$state/wl_copy_count")" "wl-copy retried after Wayland failure" || return 1
    assert_eq "2" "$(cat "$state/xclip_count")" "xclip retried while primary publish failed" || return 1
}

test_wayland_publish_runs_after_xclip_mirror() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/bmp\n' >"$state/types"
    printf 'bmp-bytes' >"$state/bmp"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_XCLIP_CLEARS_WAYLAND=1 \
        FAKE_SLEEP_LIMIT=1 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "1" "$(cat "$state/xclip_count")" "xclip mirror call count" || return 1
    assert_eq "1" "$(cat "$state/wl_copy_count")" "wl-copy final call count" || return 1
    if [ ! -f "$state/wayland_png" ]; then
        printf 'expected final wl-copy publish to restore Wayland PNG after xclip mirror\n' >&2
        return 1
    fi
}

test_invalid_env_values_fall_back() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    : >"$state/types"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=1 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0 \
        CLIPBOARD_CONVERT_TIMEOUT=0 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_contains "$tmp/err" "invalid CLIPBOARD_WATCH_INTERVAL='0'; using 0.3" || return 1
    assert_contains "$tmp/err" "invalid CLIPBOARD_CONVERT_TIMEOUT='0'; using 5" || return 1
}

test_home_unset_fails_clearly() {
    local tmp script out err status
    tmp="$(new_tmp)"

    for script in "$SCRIPT_NAME" install.sh uninstall.sh; do
        out="$tmp/${script}.out"
        err="$tmp/${script}.err"
        status=0
        env -u HOME bash "$ROOT/$script" >"$out" 2>"$err" || status=$?
        if [ "$status" -eq 0 ]; then
            printf 'expected %s to fail when HOME is unset\n' "$script" >&2
            return 1
        fi
        assert_contains "$err" "HOME must be set" || return 1
    done
}

# This intentionally runs the daemon against the same file locked by fd 9 in
# the parent subshell to verify the second-instance path.
# shellcheck disable=SC2094
test_second_instance_exits_cleanly_on_lock() {
    local tmp home lock status
    tmp="$(new_tmp)"
    home="$tmp/home"
    lock="$tmp/bridge.lock"
    mkdir -p "$home"

    (
        flock -n 9 || exit 1
        status=0
        HOME="$home" WCPB_LOCK_FILE="$lock" bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?
        printf '%s\n' "$status" >"$tmp/status"
    ) 9>"$lock"

    assert_eq "0" "$(cat "$tmp/status")" "second instance exit status" || return 1
    assert_contains "$tmp/err" "another instance is already running; exiting" || return 1
}

test_daemon_ignores_sighup() {
    local tmp fakebin home state daemon_pid
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    : >"$state/types"

    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=100 \
        FAKE_SLEEP_REAL_DELAY=0.05 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" &
    daemon_pid="$!"

    /usr/bin/sleep 0.15
    kill -HUP "$daemon_pid" 2>/dev/null || {
        wait "$daemon_pid" 2>/dev/null || true
        printf 'daemon exited before SIGHUP could be sent\n' >&2
        return 1
    }
    /usr/bin/sleep 0.15
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
        wait "$daemon_pid" 2>/dev/null || true
        printf 'daemon exited after SIGHUP\n' >&2
        return 1
    fi
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
}

run_test() {
    local name="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
    else
        printf 'not ok - %s\n' "$name" >&2
        failures=$((failures + 1))
    fi
}

test_mktemp_failure_does_not_crash() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    # Force mktemp to always fail. Without the guard at the conversion site,
    # `set -e` would propagate the substitution failure and kill the daemon.
    # With the guard, the daemon must skip the iteration and survive.
    write_executable "$fakebin/mktemp" \
        '#!/usr/bin/env bash' \
        'exit 1'
    printf 'image/bmp\n' >"$state/types"
    printf 'bmp-bytes' >"$state/bmp"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=2 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon survived mktemp failure" || return 1
    if [ -f "$state/wl_copy_count" ]; then
        assert_eq "0" "$(cat "$state/wl_copy_count")" "wl-copy not called after mktemp failure" || return 1
    fi
    if [ -f "$state/xclip_count" ]; then
        assert_eq "0" "$(cat "$state/xclip_count")" "xclip not called after mktemp failure" || return 1
    fi
}

test_mime_prefix_does_not_false_match() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    # Hostile MIME list that would false-match a substring `grep`. The daemon's
    # case statement wraps `$types` in literal newlines and matches whole lines
    # only — these entries must NOT trigger conversion.
    printf 'X-image/png-foo\nimage/pngextra\nimage/bmpx\n' >"$state/types"
    printf 'should-not-be-read' >"$state/png"
    printf 'should-not-be-read' >"$state/bmp"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=2 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    if [ -f "$state/wl_copy_count" ]; then
        assert_eq "0" "$(cat "$state/wl_copy_count")" "wl-copy not called for prefix non-match" || return 1
    fi
    if [ -f "$state/xclip_count" ]; then
        assert_eq "0" "$(cat "$state/xclip_count")" "xclip not called for prefix non-match" || return 1
    fi
}

test_post_publish_refresh_prevents_republish() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/bmp\n' >"$state/types"
    printf 'bmp-bytes' >"$state/bmp"

    # Run for 3 sleep cycles. Iter 1 converts BMP→PNG. The fake wl-copy writes
    # state/png and touches state/wayland_png so subsequent iterations see
    # image/png on the Wayland clipboard. If the post-publish refresh works,
    # last_signature is updated to the published-PNG hash; iters 2 and 3 hash
    # the same bytes, see the cache match, and skip republish. Without the
    # refresh (the v0.1.3 regression class), the same image gets republished
    # every signature_every polls.
    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_SLEEP_LIMIT=3 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "1" "$(cat "$state/wl_copy_count")" "wl-copy called exactly once across 3 iterations" || return 1
    assert_eq "1" "$(cat "$state/xclip_count")" "xclip called exactly once across 3 iterations" || return 1
}

test_same_size_same_prefix_bmp_change_republishes() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/bmp\n' >"$state/types"
    # These two payloads have the same first 8 bytes and the same total size,
    # but differ afterwards. The old prefix+size signature missed this class
    # when CLIPBOARD_HASH_MAX_BYTES was small; the full-content signature must
    # publish the second screenshot.
    printf '12345678A-tail' >"$state/bmp"
    printf '12345678B-tail' >"$state/bmp_next"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_MUTATE_AFTER_SLEEP=1 \
        FAKE_SLEEP_LIMIT=2 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "2" "$(cat "$state/wl_copy_count")" "wl-copy called for changed same-prefix image" || return 1
    assert_eq "2" "$(cat "$state/xclip_count")" "xclip called for changed same-prefix image" || return 1
    assert_eq "$(cat "$state/bmp_next")" "$(cat "$state/x11_png")" "latest PNG mirror contents" || return 1
}

test_signature_read_failure_does_not_crash() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/png\n' >"$state/types"
    printf 'png-bytes' >"$state/png"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_WL_PASTE_READ_FAIL=1 \
        FAKE_SLEEP_LIMIT=1 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon survived signature read failure" || return 1
    if [ -f "$state/xclip_count" ]; then
        assert_eq "0" "$(cat "$state/xclip_count")" "xclip not called after signature read failure" || return 1
    fi
}

test_empty_post_publish_refresh_does_not_crash() {
    local tmp fakebin home state status
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home"
    state="$tmp/state"
    mkdir -p "$home" "$state"
    make_daemon_fakebin "$fakebin"
    printf 'image/bmp\n' >"$state/types"
    printf 'bmp-bytes' >"$state/bmp"

    status=0
    PATH="$fakebin:$PATH" \
        HOME="$home" \
        FAKE_STATE="$state" \
        FAKE_WL_PASTE_FAIL_PNG_AFTER_WL_COPY=1 \
        FAKE_SLEEP_LIMIT=1 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon survived empty post-publish refresh" || return 1
    assert_eq "1" "$(cat "$state/wl_copy_count")" "wl-copy called before empty refresh" || return 1
    assert_eq "1" "$(cat "$state/xclip_count")" "xclip called before empty refresh" || return 1
}

test_installer_detects_daemon_with_literal_proc_cmdline() {
    local tmp fakebin home procroot install_path out err
    tmp="$(new_tmp)"
    fakebin="$tmp/bin"
    home="$tmp/home[regex]"
    procroot="$tmp/proc"
    install_path="$home/.local/bin/$SCRIPT_NAME"
    mkdir -p "$home" "$procroot/1234" "$procroot/5678"
    make_installer_fakebin "$fakebin"
    printf 'bash\0%s\0' "$install_path" >"$procroot/1234/cmdline"
    printf 'bash\0%s-extra\0' "$install_path" >"$procroot/5678/cmdline"

    out="$tmp/out"
    err="$tmp/err"
    PATH="$fakebin:$PATH" HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/install.sh" >"$out" 2>"$err" || return 1

    assert_contains "$out" "daemon running" || return 1
    assert_not_contains "$err" "daemon did not start" || return 1
}

test_uninstaller_removes_managed_block_and_files() {
    local tmp home procroot out err install_path lock_path mode
    tmp="$(new_tmp)"
    home="$tmp/home"
    procroot="$tmp/proc"
    install_path="$home/.local/bin/$SCRIPT_NAME"
    lock_path="$home/.cache/${SCRIPT_NAME}.lock"
    mkdir -p "$home/.local/bin" "$home/.cache" "$procroot"
    write_executable "$install_path" \
        '#!/usr/bin/env bash' \
        'exit 0'
    printf 'lock\n' >"$lock_path"
    {
        printf 'before\n'
        printf '%s\n' "$SENTINEL_START"
        printf 'managed line\n'
        printf '%s\n' "$SENTINEL_END"
        printf 'after\n'
    } >"$home/.bashrc"
    chmod 0600 "$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>"$err" || return 1

    assert_contains "$out" "removing $install_path" || return 1
    assert_contains "$out" "removing $lock_path" || return 1
    assert_contains "$out" "removing managed block" || return 1
    assert_contains "$home/.bashrc" "before" || return 1
    assert_contains "$home/.bashrc" "after" || return 1
    mode="$(stat -c %a "$home/.bashrc")"
    assert_eq "600" "$mode" "bashrc mode after uninstall rewrite" || return 1
    assert_not_contains "$home/.bashrc" "$SENTINEL_START" || return 1
    assert_not_contains "$home/.bashrc" "managed line" || return 1
    if [ -e "$install_path" ]; then
        printf 'expected installed daemon to be removed\n' >&2
        return 1
    fi
    if [ -e "$lock_path" ]; then
        printf 'expected lock file to be removed\n' >&2
        return 1
    fi
    assert_eq "" "$(cat "$err")" "uninstall stderr" || return 1
}

test_uninstaller_refuses_partial_block_preserves_bashrc() {
    local tmp home procroot out err
    tmp="$(new_tmp)"
    home="$tmp/home"
    procroot="$tmp/proc"
    mkdir -p "$home" "$procroot"
    {
        printf 'before\n'
        printf '%s\n' "$SENTINEL_START"
        printf 'after without end sentinel\n'
    } >"$home/.bashrc"

    out="$tmp/out"
    err="$tmp/err"
    HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>"$err" || return 1

    assert_contains "$err" "no matching end sentinel" || return 1
    assert_contains "$home/.bashrc" "before" || return 1
    assert_contains "$home/.bashrc" "$SENTINEL_START" || return 1
    assert_contains "$home/.bashrc" "after without end sentinel" || return 1
}

test_uninstaller_refuses_mismatched_blocks_preserves_bashrc() {
    local tmp home procroot out err before after
    tmp="$(new_tmp)"
    home="$tmp/home"
    procroot="$tmp/proc"
    mkdir -p "$home" "$procroot"
    {
        printf 'before\n'
        printf '%s\n' "$SENTINEL_START"
        printf 'managed line\n'
        printf '%s\n' "$SENTINEL_END"
        printf '%s\n' "$SENTINEL_START"
        printf 'after mismatched start\n'
    } >"$home/.bashrc"
    before="$(cat "$home/.bashrc")"

    out="$tmp/out"
    err="$tmp/err"
    HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>"$err" || return 1
    after="$(cat "$home/.bashrc")"

    assert_contains "$err" "mismatched managed block sentinels" || return 1
    assert_eq "$before" "$after" "bashrc after mismatched uninstall refusal" || return 1
    assert_not_contains "$out" "removing managed block" || return 1
}

test_uninstaller_ignores_embedded_sentinel_text() {
    local tmp home procroot out err before after
    tmp="$(new_tmp)"
    home="$tmp/home"
    procroot="$tmp/proc"
    mkdir -p "$home" "$procroot"
    {
        printf 'before\n'
        printf 'echo "%s"\n' "$SENTINEL_START"
        printf 'echo "%s"\n' "$SENTINEL_END"
        printf 'after\n'
    } >"$home/.bashrc"
    before="$(cat "$home/.bashrc")"

    out="$tmp/out"
    err="$tmp/err"
    HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>"$err" || return 1
    after="$(cat "$home/.bashrc")"

    assert_eq "$before" "$after" "bashrc with embedded sentinels after uninstall" || return 1
    assert_not_contains "$out" "removing managed block" || return 1
    assert_eq "" "$(cat "$err")" "uninstall stderr" || return 1
}

test_uninstaller_stops_only_literal_proc_cmdline() {
    local tmp home procroot out install_path daemon_pid
    tmp="$(new_tmp)"
    home="$tmp/home[regex]"
    procroot="$tmp/proc"
    install_path="$home/.local/bin/$SCRIPT_NAME"
    sleep 30 &
    daemon_pid="$!"
    mkdir -p "$home" "$procroot/$daemon_pid"
    printf 'bash\0%s\0' "$install_path" >"$procroot/$daemon_pid/cmdline"

    out="$tmp/out"
    if ! HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>/dev/null; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
        return 1
    fi
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true

    assert_contains "$out" "stopping daemon" || return 1
    assert_not_contains "$out" "daemon did not start" || return 1
}

test_uninstaller_ignores_nonliteral_proc_cmdline() {
    local tmp home procroot out install_path daemon_pid
    tmp="$(new_tmp)"
    home="$tmp/home[regex]"
    procroot="$tmp/proc"
    install_path="$home/.local/bin/$SCRIPT_NAME"
    sleep 30 &
    daemon_pid="$!"
    mkdir -p "$home" "$procroot/$daemon_pid"
    printf 'bash\0%s-extra\0' "$install_path" >"$procroot/$daemon_pid/cmdline"

    out="$tmp/out"
    if ! HOME="$home" WCPB_PROC_ROOT="$procroot" bash "$ROOT/uninstall.sh" >"$out" 2>/dev/null; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
        return 1
    fi
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true

    assert_not_contains "$out" "stopping daemon" || return 1
}

run_test "installer replaces existing managed block" test_installer_replaces_existing_block
run_test "installer refuses partial managed block" test_installer_refuses_partial_block
run_test "installer refuses mismatched managed blocks" test_installer_refuses_mismatched_blocks
run_test "installer ignores embedded sentinel text" test_installer_ignores_embedded_sentinel_text
run_test "successful publish switches sleep to active interval" test_success_switches_sleep_to_active_interval
run_test "xclip failure does not republish after Wayland success" test_xclip_failure_does_not_republish_when_wayland_succeeds
run_test "publish failures retry when Wayland fails" test_publish_failures_retry_when_wayland_fails
run_test "Wayland publish runs after xclip mirror" test_wayland_publish_runs_after_xclip_mirror
run_test "invalid env values fall back" test_invalid_env_values_fall_back
run_test "HOME unset fails clearly" test_home_unset_fails_clearly
run_test "second instance exits cleanly on lock" test_second_instance_exits_cleanly_on_lock
run_test "daemon ignores SIGHUP from spawning shell" test_daemon_ignores_sighup
run_test "daemon survives mktemp failure" test_mktemp_failure_does_not_crash
run_test "MIME prefix does not false-match exact line" test_mime_prefix_does_not_false_match
run_test "post-publish refresh prevents republish" test_post_publish_refresh_prevents_republish
run_test "same-size same-prefix BMP change republishes" test_same_size_same_prefix_bmp_change_republishes
run_test "signature read failure does not crash daemon" test_signature_read_failure_does_not_crash
run_test "empty post-publish refresh does not crash daemon" test_empty_post_publish_refresh_does_not_crash
run_test "installer daemon check uses literal proc cmdline" test_installer_detects_daemon_with_literal_proc_cmdline
run_test "uninstaller removes managed block and files" test_uninstaller_removes_managed_block_and_files
run_test "uninstaller refuses partial block and preserves bashrc" test_uninstaller_refuses_partial_block_preserves_bashrc
run_test "uninstaller refuses mismatched blocks and preserves bashrc" test_uninstaller_refuses_mismatched_blocks_preserves_bashrc
run_test "uninstaller ignores embedded sentinel text" test_uninstaller_ignores_embedded_sentinel_text
run_test "uninstaller stops only literal proc cmdline" test_uninstaller_stops_only_literal_proc_cmdline
run_test "uninstaller ignores nonliteral proc cmdline" test_uninstaller_ignores_nonliteral_proc_cmdline

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
