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
        case "${2:-}" in
            image/bmp) cat "$state/bmp" ;;
            image/png) cat "$state/png" ;;
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
limit="${FAKE_SLEEP_LIMIT:-1}"
if [ "$count" -ge "$limit" ]; then
    exit "${FAKE_SLEEP_EXIT:-77}"
fi
exit 0
SH
    chmod +x "$fakebin/sleep"
}

test_installer_replaces_existing_block() {
    local tmp fakebin home out err start_count end_count expected_spawn
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

    out="$tmp/out"
    err="$tmp/err"
    PATH="$fakebin:$PATH" HOME="$home" bash "$ROOT/install.sh" >"$out" 2>"$err" || return 1

    assert_contains "$out" "replacing managed block" || return 1
    assert_not_contains "$home/.bashrc" "        flock -n 9 || exit 0" || return 1
    expected_spawn="\"\$HOME/.local/bin/wsl-clipboard-png-bridge\" >/dev/null 2>&1 &"
    assert_contains "$home/.bashrc" "$expected_spawn" || return 1
    assert_contains "$home/.bashrc" "before" || return 1
    assert_contains "$home/.bashrc" "after" || return 1
    start_count="$(grep -Fc "$SENTINEL_START" "$home/.bashrc")"
    end_count="$(grep -Fc "$SENTINEL_END" "$home/.bashrc")"
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

test_xclip_failure_retries_png_mirror() {
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
        FAKE_XCLIP_FAIL_FIRST=1 \
        FAKE_SLEEP_LIMIT=2 \
        WCPB_LOCK_FILE="$state/lock" \
        CLIPBOARD_WATCH_INTERVAL=0.01 \
        CLIPBOARD_IDLE_INTERVAL=0.01 \
        CLIPBOARD_SIGNATURE_EVERY=1 \
        bash "$ROOT/$SCRIPT_NAME" >"$tmp/out" 2>"$tmp/err" || status=$?

    assert_eq "77" "$status" "daemon controlled sleep exit" || return 1
    assert_eq "2" "$(cat "$state/xclip_count")" "xclip retry count" || return 1
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

run_test "installer replaces existing managed block" test_installer_replaces_existing_block
run_test "installer refuses partial managed block" test_installer_refuses_partial_block
run_test "installer refuses mismatched managed blocks" test_installer_refuses_mismatched_blocks
run_test "successful publish switches sleep to active interval" test_success_switches_sleep_to_active_interval
run_test "xclip failure retries PNG mirror" test_xclip_failure_retries_png_mirror
run_test "invalid env values fall back" test_invalid_env_values_fall_back
run_test "second instance exits cleanly on lock" test_second_instance_exits_cleanly_on_lock
run_test "daemon survives mktemp failure" test_mktemp_failure_does_not_crash
run_test "MIME prefix does not false-match exact line" test_mime_prefix_does_not_false_match
run_test "post-publish refresh prevents republish" test_post_publish_refresh_prevents_republish

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
