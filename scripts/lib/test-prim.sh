#!/usr/bin/env bash
# Tests for prim.sh: publication, lock exclusion, path resolution and temp roots.
# Usage: bash scripts/lib/test-prim.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$LIB_DIR/prim.sh"
source_contract() {
    local before='' after='' rc=0 variables_before='' variables_after=''
    variables_before=$(compgen -A variable | grep -v '^prim_')
    before=$(set +o)
    # shellcheck disable=SC1090
    . "$LIB"
    rc=$?
    after=$(set +o)
    variables_after=$(compgen -A variable | grep -v '^prim_')
    [ "$rc" -eq 0 ] && [ "$before" = "$after" ] &&
        [ "$variables_before" = "$variables_after" ]
}
if [ "${1-}" = --source-contract ]; then
    source_contract
    exit $?
fi

if [ -r "$LIB" ]; then
    # shellcheck source=prim.sh
    . "$LIB" || exit 1
else
    # Missing-function controls let every behavior report its own RED result.
    atomic_write() { return 97; }
    with_lock() { return 97; }
    canon_path() { return 97; }
    tmpdir() { return 97; }
fi

increment() {
    local n
    # read-sink-ok: workers supply the counter path inside this suite's private temporary fixture.
    IFS= read -r n < "$1" || return 1
    sleep 0.05 || return 1
    printf '%s\n' "$((n + 1))" > "$1"
}

atomic_workers() {
    local root="$1" i j pid pids='' rc=0 snapshot
    for i in 1 2 3 4; do
        awk -v n="$i" 'BEGIN { for (j=0;j<8192;j++) printf "%08d", n; print "" }' > "$root/payload-$i" || return 1
    done
    cp "$root/payload-1" "$root/shared" || return 1
    for i in 1 2 3 4; do
        (
            for j in 1 2 3 4 5 6 7 8; do
                atomic_write "$root/shared" < "$root/payload-$i" || exit 1
            done
        ) &
        pids="$pids $!"
    done
    j=0
    while [ "$j" -lt 16 ]; do
        j=$((j + 1))
        snapshot="$root/snapshot"
        cat "$root/shared" > "$snapshot" || { rc=1; break; }
        if ! cmp -s "$snapshot" "$root/payload-1" &&
           ! cmp -s "$snapshot" "$root/payload-2" &&
           ! cmp -s "$snapshot" "$root/payload-3" &&
           ! cmp -s "$snapshot" "$root/payload-4"; then
            rc=1
            break
        fi
    done
    for pid in $pids; do wait "$pid" || rc=1; done
    [ "$rc" -eq 0 ]
}

lock_workers() {
    local root="$1" i pid pids='' rc=0
    printf '0\n' > "$root/counter" || return 1
    for i in 1 2 3 4; do
        with_lock "$root/counter.lock" increment "$root/counter" &
        pids="$pids $!"
    done
    for pid in $pids; do wait "$pid" || rc=1; done
    [ "$rc" -eq 0 ] && [ "$(< "$root/counter")" = 4 ]
}

lock_churn() {
    local root="$1" i pid pids='' rc=0
    printf '0\n' > "$root/churn-counter" || return 1
    # shellcheck disable=SC2317,SC2329 # Invoked indirectly by with_lock.
    fast_increment() {
        local n
        IFS= read -r n < "$root/churn-counter" || return 1
        printf '%s\n' "$((n + 1))" > "$root/churn-counter"
    }
    for i in 1 2 3 4; do
        (
            i=0
            while [ "$i" -lt 100 ]; do
                with_lock "$root/churn.lock" fast_increment || exit 1
                i=$((i + 1))
            done
        ) &
        pids="$pids $!"
    done
    for pid in $pids; do wait "$pid" || rc=1; done
    [ "$rc" -eq 0 ] && [ "$(< "$root/churn-counter")" = 400 ]
}

case "${1-}" in
    --churn-workers) lock_churn "$2"; exit $? ;;
    --atomic-workers) atomic_workers "$2"; exit $? ;;
    --lock-workers) lock_workers "$2"; exit $? ;;
esac

T=$(mktemp -d "${TMPDIR:-/tmp}/test-prim.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/home" "$T/bin" "$T/with space" || exit 1
export HOME="$T/home"
TIMEOUT=$(command -v timeout || command -v gtimeout) || { printf 'FAIL timeout is required\n'; exit 1; }
BASH_BIN=$(command -v bash) || exit 1
for tool in bash cat mktemp mv rm sleep sh dirname; do
    tool_path=$(command -v "$tool") || exit 1
    ln -s "$tool_path" "$T/bin/$tool" || exit 1
done
FAILED=0
TOTAL=0
check() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if ( "$@" ); then
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        FAILED=$((FAILED + 1))
    fi
}

atomic_bytes() {
    local rc
    printf 'old\n' > "$T/with space/target" || return 1
    printf 'new\000bytes\n' > "$T/input" || return 1
    atomic_write "$T/with space/target" < "$T/input"
    rc=$?
    [ "$rc" -eq 0 ] && cmp -s "$T/input" "$T/with space/target"
}

atomic_same_directory() {
    local rc
    # A real rename must not depend on TMPDIR being usable.
    printf 'same directory\n' > "$T/input" || return 1
    TMPDIR="$T/missing" atomic_write "$T/with space/new" < "$T/input"
    rc=$?
    [ "$rc" -eq 0 ] && cmp -s "$T/input" "$T/with space/new"
}

atomic_failure() {
    local stage="$1" rc item
    mkdir "$T/fail-$stage" || return 1
    printf '#!/bin/sh\nexit 23\n' > "$T/fail-$stage/$stage" || return 1
    chmod +x "$T/fail-$stage/$stage" || return 1
    printf 'original\n' > "$T/with space/unchanged" || return 1
    PATH="$T/fail-$stage:$PATH" atomic_write "$T/with space/unchanged" < "$T/input"
    rc=$?
    [ "$rc" -eq 23 ] && [ "$(< "$T/with space/unchanged")" = original ] || return 1
    for item in "$T/with space"/.[!.]* "$T/with space"/..?*; do
        [ ! -e "$item" ] || return 1
    done
}

lock_result() {
    local rc out
    # shellcheck disable=SC2016 # The child shell expands its positional arguments.
    out=$(with_lock "$T/status.lock" "$BASH_BIN" -c 'printf "%s|%s" "$1" "$2"; exit 23' _ 'with space' '*')
    rc=$?
    [ "$rc" -eq 23 ] && [ "$out" = 'with space|*' ]
}

lock_release() {
    local rc
    with_lock "$T/release.lock" "$BASH_BIN" -c 'exit 23'
    rc=$?
    [ "$rc" -eq 23 ] || return 1
    with_lock "$T/release.lock" printf 'released\n' > "$T/released" || return 1
    [ "$(< "$T/released")" = released ]
}

fallback_status() {
    local rc
    PATH="$T/bin" with_lock "$T/fallback-status.lock" "$BASH_BIN" -c 'exit 23'
    rc=$?
    [ "$rc" -eq 23 ] && [ ! -e "$T/fallback-status.lock" ]
}

fallback_dead_owner() {
    local pid rc
    "$BASH_BIN" -c 'exit 0' &
    pid=$!
    wait "$pid" || return 1
    printf '%s\n' "$pid" > "$T/dead.lock" || return 1
    PATH="$T/bin" with_lock "$T/dead.lock" touch "$T/entered" 2> "$T/dead.err"
    rc=$?
    # Fail closed instead of racing another stale-lock reclaimer.
    [ "$rc" -eq 1 ] && [ ! -e "$T/entered" ] && [ "$(< "$T/dead.lock")" = "$pid" ]
}

fallback_owner_exited() {
    local pid
    "$BASH_BIN" -c 'exit 0' &
    pid=$!
    wait "$pid" || return 1
    printf '%s\n' "$pid" > "$T/exiting.lock" || return 1
    # Schedule release at the liveness-probe boundary; retain real kill status.
    # shellcheck disable=SC2317,SC2329 # The sourced helper calls this liveness probe.
    kill() {
        rm -f "$T/exiting.lock" || return 1
        builtin kill "$@"
    }
    PATH="$T/bin" with_lock "$T/exiting.lock" printf 'acquired\n' > "$T/acquired" 2>/dev/null || return 1
    [ "$(< "$T/acquired")" = acquired ] && [ ! -e "$T/exiting.lock" ]
}

fallback_changed_directory() {
    mkdir "$T/elsewhere" || return 1
    printf 'unrelated\n' > "$T/elsewhere/cwd.lock" || return 1
    # shellcheck disable=SC2317,SC2329 # Invoked indirectly by with_lock.
    change_directory() { cd "$T/elsewhere" || return 1; }
    cd "$T" || return 1
    PATH="$T/bin" with_lock cwd.lock change_directory || return 1
    [ ! -e "$T/cwd.lock" ] && [ "$(< "$T/elsewhere/cwd.lock")" = unrelated ]
}

fallback_missing_parent() {
    local rc
    # shellcheck disable=SC2016 # Expansion belongs to the child shell.
    "$TIMEOUT" 2 "$BASH_BIN" -c '. "$1"; PATH="$2" with_lock "$3" true' _ \
        "$LIB" "$T/bin" "$T/absent/lock" 2>/dev/null
    rc=$?
    [ "$rc" -eq 1 ]
}

fallback_owner_is_live_parent() {
    local rc
    # shellcheck disable=SC2016 # The child shell expands its positional arguments.
    PATH="$T/bin" with_lock "$T/live.lock" "$BASH_BIN" -c \
        'IFS= read -r o < "$1" && [ "$o" = "$PPID" ] && kill -0 "$o"' _ "$T/live.lock" # read-sink-ok: test-owned fixture lock under $T
    rc=$?
    [ "$rc" -eq 0 ] && [ ! -e "$T/live.lock" ]
}

atomic_symlink_replaced() {
    printf 'referent\n' > "$T/with space/referent" || return 1
    ln -s referent "$T/with space/live-link" || return 1
    printf 'new\n' | atomic_write "$T/with space/live-link" || return 1
    # The link itself is replaced; the file it pointed at is untouched.
    [ ! -L "$T/with space/live-link" ] && [ "$(< "$T/with space/live-link")" = new ] &&
        [ "$(< "$T/with space/referent")" = referent ]
}

atomic_symlink_dangling() {
    ln -s nowhere "$T/with space/dangling" || return 1
    printf 'new\n' | atomic_write "$T/with space/dangling" || return 1
    [ ! -L "$T/with space/dangling" ] && [ "$(< "$T/with space/dangling")" = new ] &&
        [ ! -e "$T/with space/nowhere" ]
}

atomic_symlink_to_directory() {
    local rc
    mkdir "$T/with space/linked-dir" || return 1
    ln -s linked-dir "$T/with space/dir-link" || return 1
    printf 'new\n' | atomic_write "$T/with space/dir-link" 2>/dev/null
    rc=$?
    [ "$rc" -eq 1 ] && [ -L "$T/with space/dir-link" ] && [ -z "$(ls -A "$T/with space/linked-dir")" ]
}

fallback_unreadable_record() {
    local rc
    printf '%s\n' "$$" > "$T/unreadable.lock" || return 1
    chmod 000 "$T/unreadable.lock" || return 1
    # A privileged user reads through mode 000, so the case cannot arise there.
    if [ -r "$T/unreadable.lock" ]; then chmod 600 "$T/unreadable.lock"; return 0; fi
    # shellcheck disable=SC2016 # Expansion belongs to the child shell.
    "$TIMEOUT" 3 "$BASH_BIN" -c '. "$1"; PATH="$2" with_lock "$3" touch "$4"' _ \
        "$LIB" "$T/bin" "$T/unreadable.lock" "$T/entered-unreadable" 2> "$T/unreadable.err"
    rc=$?
    chmod 600 "$T/unreadable.lock"
    [ "$rc" -eq 1 ] && [ ! -e "$T/entered-unreadable" ] && grep -q 'unreadable' "$T/unreadable.err"
}

lock_not_held_by_children() {
    local rc path_override="$1" tag=fl; [ -z "$1" ] || tag=fb
    # A background child must not keep the lock after with_lock returns.
    # shellcheck disable=SC2016 # Expansion belongs to the child shell.
    "$TIMEOUT" 8 "$BASH_BIN" -c '
        . "$1"; [ -z "$2" ] || PATH="$2" # read-sink-ok: test-owned library path from the harness
        with_lock "$3" "$4" -c "sleep 4 & exit 0" || exit 1
        "$5" 2 "$4" -c ". \"\$1\"; with_lock \"\$2\" true" _ "$1" "$3"
    ' _ "$LIB" "$path_override" "$T/child-held-$tag.lock" "$BASH_BIN" "$TIMEOUT"
    rc=$?
    [ "$rc" -eq 0 ]
}

lock_nested_distinct() {
    local rc path_override="$1" tag=fl; [ -z "$1" ] || tag=fb
    # shellcheck disable=SC2016 # Expansion belongs to the child shell.
    "$TIMEOUT" 5 "$BASH_BIN" -c '
        . "$1"; [ -z "$2" ] || PATH="$2" # read-sink-ok: test-owned library path from the harness
        with_lock "$3" with_lock "$4" true
    ' _ "$LIB" "$path_override" "$T/outer-$tag.lock" "$T/inner-$tag.lock"
    rc=$?
    [ "$rc" -eq 0 ]
}

lock_nested_same_blocks() {
    local rc path_override="$1" tag=fl; [ -z "$1" ] || tag=fb
    # Re-entering one lock is a documented deadlock; callers bound it with timeout.
    # shellcheck disable=SC2016 # Expansion belongs to the child shell.
    "$TIMEOUT" 2 "$BASH_BIN" -c '
        . "$1"; [ -z "$2" ] || PATH="$2" # read-sink-ok: test-owned library path from the harness
        with_lock "$3" with_lock "$3" true
    ' _ "$LIB" "$path_override" "$T/same-$tag.lock"
    rc=$?
    [ "$rc" -eq 124 ]
}

canonical_directory() {
    local got rc
    ln -s "$T/with space" "$T/link" || return 1
    got=$(canon_path "$T/link/.")
    rc=$?
    [ "$rc" -eq 0 ] && [ "$got" = "$(cd "$T/with space" && pwd -P)" ]
}

canonical_missing() {
    local got rc
    got=$(canon_path "$T/absent")
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ]
}

temp_directory() {
    local path rc
    path=$(TMPDIR="$T/with space///" tmpdir)
    rc=$?
    [ "$rc" -eq 0 ] && [ -d "$path" ] || return 1
    case "$path" in "$T/with space/"*) ;; *) return 1 ;; esac
    case "${path#"$T/with space/"}" in */*) return 1 ;; esac
    # Callers own the cleanup trap; the helper must leave the directory alive.
    [ -z "$(ls -A "$path")" ]
}

temp_failure() {
    local path rc
    path=$(TMPDIR="$T/absent" tmpdir 2>/dev/null)
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$path" ]
}

check 'source preserves shell options and prefixed state' "$BASH_BIN" "$0" --source-contract
check 'atomic_write replaces exact bytes in a spaced path' atomic_bytes
check 'atomic_write allocates beside target, not TMPDIR' atomic_same_directory
check 'atomic_write cleans up after input failure' atomic_failure cat
check 'atomic_write cleans up after rename failure' atomic_failure mv
check 'atomic_write never tears with four concurrent writers' "$TIMEOUT" 20 "$BASH_BIN" "$0" --atomic-workers "$T"
check 'with_lock preserves argv, stdout and command status' lock_result
check 'with_lock releases after command failure' lock_release
check 'with_lock serializes four counter increments' "$TIMEOUT" 15 "$BASH_BIN" "$0" --lock-workers "$T"
check 'fallback preserves status and releases exclusive file' fallback_status
mkdir "$T/fallback" || exit 1
check 'fallback serializes four counter increments without flock' env PATH="$T/bin" "$TIMEOUT" 15 "$BASH_BIN" "$0" --lock-workers "$T/fallback"
check 'fallback refuses dead PID without deleting its lock' fallback_dead_owner
check 'fallback retries if owner exited after releasing its record' fallback_owner_exited
check 'fallback fails promptly when lock parent is missing' fallback_missing_parent
check 'fallback releases correct lock when command changes directory' fallback_changed_directory
check 'fallback tolerates rapid lock release and reacquisition' env PATH="$T/bin" "$TIMEOUT" 20 "$BASH_BIN" "$0" --churn-workers "$T"
check 'fallback records its live parent as owner and releases' fallback_owner_is_live_parent
check 'atomic_write replaces a symlink, not its referent' atomic_symlink_replaced
check 'atomic_write replaces a dangling symlink' atomic_symlink_dangling
check 'atomic_write refuses a symlink to a directory' atomic_symlink_to_directory
check 'fallback fails on an unreadable lock record instead of waiting' fallback_unreadable_record
check 'flock lock is not held by background children' lock_not_held_by_children ''
check 'fallback lock is not held by background children' lock_not_held_by_children "$T/bin"
check 'flock nested distinct locks both acquire' lock_nested_distinct ''
check 'fallback nested distinct locks both acquire' lock_nested_distinct "$T/bin"
check 'flock re-entering one lock blocks until the caller timeout' lock_nested_same_blocks ''
check 'fallback re-entering one lock blocks until the caller timeout' lock_nested_same_blocks "$T/bin"
check 'canon_path resolves symlink and spaces' canonical_directory
check 'canon_path rejects nonexistent directory' canonical_missing
check 'tmpdir honors TMPDIR and strips trailing slashes' temp_directory
check 'tmpdir reports allocation failure without output' temp_failure
printf '%s tests, %s failed\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ]
