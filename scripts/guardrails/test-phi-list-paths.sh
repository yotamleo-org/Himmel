#!/usr/bin/env bash
# The bash, CommonJS and Python PHI list resolvers against one table,
# phi-dir-cases.tsv. Every row runs under a fixture HOME built by
# testlib-phi-dirs.sh, so the station's real lists are never read.
# PHI_LIST_PATHS_CJS / PHI_LIST_PATHS_PY only choose the module file, so a
# mutated scratch copy can be proven to fail.
#
# Usage: bash scripts/guardrails/test-phi-list-paths.sh
# By design: single-quoted child bodies, subshell-local HOME, the trap and the seam variable.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2329
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/guardrails/phi-egress-lib.sh"
CJS="${PHI_LIST_PATHS_CJS:-$REPO_ROOT/scripts/guardrails/phi-list-paths.cjs}"
PYMOD="${PHI_LIST_PATHS_PY:-$REPO_ROOT/scripts/guardrails/phi_list_paths.py}"
# shellcheck source=testlib-phi-dirs.sh
. "$REPO_ROOT/scripts/guardrails/testlib-phi-dirs.sh"

NODE="$(node -e 'process.stdout.write(process.execPath)')" || exit 1
PYTHON="$(python3 -c 'import sys; sys.stdout.write(sys.executable)')" || exit 1
DEADLINE="$(command -v timeout || command -v gtimeout || true)"

WS="$(mktemp -d "${TMPDIR:-/tmp}/phi-list-paths-test.XXXXXX")" || exit 1
BUILT=()
cleanup() {
    local h
    for h in ${BUILT[@]+"${BUILT[@]}"}; do phi_dirs_restore "$h" || true; done
    rm -rf "$WS"
}
trap cleanup EXIT

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

with_deadline() {
    if [ -n "$DEADLINE" ]; then "$DEADLINE" 10 "$@"; else "$@"; fi
}

run_one() {
    local rc=0
    (
        phi_dirs_enter "$2" "$3" || exit 99
        case "$1" in
            bash) with_deadline bash -c '. "$1" && _guard_phi_list_paths "$2"' _ "$LIB" "$4" ;;
            cjs) with_deadline "$NODE" "$CJS" "$4" ;;
            py) with_deadline "$PYTHON" -I -B "$PYMOD" "$4" ;;
        esac
    ) >"$WS/out" 2>"$WS/err" || rc=$?
    [ "$2" != C22 ] || chmod 755 "$3/work"
    return "$rc"
}

dirs_of() {
    (
        phi_dirs_enter "$2" "$3" || exit 99
        case "$1" in
            bash) with_deadline bash -c '. "$1" && _guard_phi_dirs' _ "$LIB" ;;
            cjs) with_deadline "$NODE" -e 'console.log(require(process.argv[1]).phiDirs(process.env).join("\n"))' "$CJS" ;;
            py) with_deadline "$PYTHON" -I -B -c 'import importlib.util, os, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print("\n".join(m.phi_dirs(os.environ)))' "$PYMOD" ;;
        esac
    )
}

unprovable_dir() {
    case "$1" in
        C8 | C9 | C14 | C15) printf '%s' "$2/.config/himmel/phi" ;;
        C13 | C16) printf '%s' "$2/.config/claude-glm" ;;
        C17) printf '%s' "$2/glm-override" ;;
        C22) printf '%s' cfg ;;
        *) printf '%s' "unmapped-$1" ;;
    esac
}

is_mode000_row() {
    case "$1" in C8 | C9 | C12 | C13 | C14 | C17 | C22 | C23) return 0 ;; esac
    return 1
}

check_row() {
    local impl="$1" id="$2" home="$3" name="$4" want_rc rel want="" got rc=0 line bad=""
    want_rc="$(phi_dirs_expect "$id" "$5")"
    rel="$(phi_dirs_expect "$id" "$6")"
    if [ "$rel" != - ]; then
        local IFS=,
        for line in $rel; do want="$want${want:+$'\n'}$home/$line"; done
        unset IFS
    fi
    run_one "$impl" "$id" "$home" "$name" || rc=$?
    got="$(cat "$WS/out")"
    [ "$rc" = "$want_rc" ] || bad="rc want $want_rc got $rc"
    [ "$got" = "$want" ] || bad="$bad; paths want [$want] got [$got]"
    if [ "$want_rc" = 2 ]; then
        line="unprovable: $(unprovable_dir "$id" "$home")"
        grep -q -x -F -- "$line" "$WS/err" || bad="$bad; stderr lacks [$line]"
    elif grep -q '^unprovable:' "$WS/err"; then
        bad="$bad; stderr names an unprovable dir"
    fi
    if [ -z "$bad" ]; then pass "$impl $id $name"; else fail "$impl $id $name -> $bad"; fi
}

echo "== table rows =="
for id in $(phi_dirs_cases); do
    if [ "$(id -u)" -eq 0 ] && is_mode000_row "$id"; then
        echo "  SKIP  $id: running as root, chmod 000 cannot take access away"
        continue
    fi
    home="$WS/$id"
    BUILT+=("$home")
    phi_dirs_build "$id" "$home" || { fail "$id fixture build"; continue; }
    for impl in bash cjs py; do
        check_row "$impl" "$id" "$home" phi-roots rc_roots paths_roots
        check_row "$impl" "$id" "$home" egress-denylist rc_deny paths_deny
    done
done

echo "== dir set =="
for id in C1 C4 C21; do
    home="$WS/dirs-$id"
    BUILT+=("$home")
    phi_dirs_build "$id" "$home" || { fail "$id fixture build"; continue; }
    want="$home/.config/himmel/phi"
    case "$id" in
        C4) want="$want"$'\n'"$home/glm-override" ;;
        C21) want="$want"$'\n'"relative-cfg-absent/x" ;;
    esac
    want="$want"$'\n'"$home/.config/claude-glm"
    for impl in bash cjs py; do
        got="$(dirs_of "$impl" "$id" "$home" 2>"$WS/err")"
        if [ "$got" = "$want" ]; then pass "$impl dirs $id"; else fail "$impl dirs $id -> want [$want] got [$got]"; fi
    done
done

home="$WS/dirs-dup"; mkdir -p "$home"
want="$home/.config/himmel/phi"$'\n'"$home/.config/claude-glm"
for impl in bash cjs py; do
    got="$(
        export HOME="$home" CLAUDE_GLM_CONFIG_DIR="$home/.config/claude-glm"
        case "$impl" in
            bash) with_deadline bash -c '. "$1" && _guard_phi_dirs' _ "$LIB" ;;
            cjs) with_deadline "$NODE" -e 'console.log(require(process.argv[1]).phiDirs(process.env).join("\n"))' "$CJS" ;;
            py) with_deadline "$PYTHON" -I -B -c 'import importlib.util, os, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print("\n".join(m.phi_dirs(os.environ)))' "$PYMOD" ;;
        esac 2>"$WS/err"
    )"
    if [ "$got" = "$want" ]; then pass "$impl override equal to the default dir"; else fail "$impl override equal to the default dir -> got [$got]"; fi
done

echo "== no HOME =="
for impl in bash cjs py; do
    rc=0
    (
        unset CLAUDE_GLM_CONFIG_DIR
        export HOME=""
        case "$impl" in
            bash) with_deadline bash -c '. "$1" && _guard_phi_list_paths phi-roots' _ "$LIB" ;;
            cjs) with_deadline "$NODE" "$CJS" phi-roots ;;
            py) with_deadline "$PYTHON" -I -B "$PYMOD" phi-roots ;;
        esac
    ) >"$WS/out" 2>"$WS/err" || rc=$?
    if [ "$rc" -eq 2 ] && [ ! -s "$WS/out" ]; then pass "$impl empty HOME -> rc 2"; else fail "$impl empty HOME -> rc $rc"; fi
done

echo "== newline in a dir =="
home="$WS/newline"; nl_dir="$WS/glm"$'\n'"split"
mkdir -p "$home" "$nl_dir" && printf '%s\n' "$home/phi-root-fixture" > "$nl_dir/phi-roots"
for impl in bash cjs py; do
    rc=0
    (
        export HOME="$home" CLAUDE_GLM_CONFIG_DIR="$nl_dir"
        case "$impl" in
            bash) with_deadline bash -c '. "$1" && _guard_phi_list_paths phi-roots' _ "$LIB" ;;
            cjs) with_deadline "$NODE" "$CJS" phi-roots ;;
            py) with_deadline "$PYTHON" -I -B "$PYMOD" phi-roots ;;
        esac
    ) >"$WS/out" 2>"$WS/err" || rc=$?
    if [ "$rc" -eq 2 ]; then pass "$impl a newline in the override -> rc 2"; else fail "$impl a newline in the override -> rc $rc, expected 2"; fi
done

echo "== python dir proof =="
if [ "$(id -u)" -ne 0 ]; then
    for spec in "C8 .config/himmel/phi" "C15 .config/himmel/phi" "C16 .config/claude-glm" "C7 ."; do
        id="${spec%% *}"; rel="${spec#* }"; home="$WS/proof-$id"; want=False
        [ "$id" != C7 ] || want=True
        BUILT+=("$home")
        phi_dirs_build "$id" "$home" || { fail "$id fixture build"; continue; }
        got="$(with_deadline "$PYTHON" -I -B -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.phi_dir_provable(sys.argv[2]))' "$PYMOD" "$home/$rel" 2>"$WS/err")"
        if [ "$got" = "$want" ]; then pass "py phi_dir_provable $id -> $want"; else fail "py phi_dir_provable $id -> want $want got [$got]"; fi
    done
fi

echo "== fixture refusals =="
standin="$WS/standin-home"; mkdir -p "$standin"
for target in "$standin" "$standin/sub"; do
    rc=0
    ( PHI_DIRS_REAL_HOME="$standin"; phi_dirs_build C1 "$target" ) 2>"$WS/err" || rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$standin/.config" ] && [ ! -e "$standin/sub" ] && [ ! -e "$standin/phi-root-fixture" ]; then
        pass "build at or under the recorded HOME is refused, nothing created"
    else
        fail "build at $target -> rc $rc, expected a refusal that creates nothing"
    fi
done
linked="$WS/linked-home"; elsewhere="$WS/link-target"; mkdir -p "$linked" "$elsewhere"
ln -s "$elsewhere" "$linked/.config"
rc=0
phi_dirs_build C1 "$linked" 2>"$WS/err" || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$(ls -A "$elsewhere")" ]; then
    pass "a fixture HOME that already holds a .config link is refused, nothing written through it"
else
    fail "pre-existing .config link -> rc $rc, expected a refusal that writes nothing through it"
fi
mkdir -p "$WS/shim"
printf '#!/bin/sh\nexit 0\n' > "$WS/shim/getent"
chmod +x "$WS/shim/getent"
rc=0
PATH="$WS/shim:$PATH" bash -c '. "$1" && phi_dirs_build C1 "$2"' _ "$REPO_ROOT/scripts/guardrails/testlib-phi-dirs.sh" "$WS/shimbuild" 2>"$WS/err" || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$WS/shimbuild" ]; then
    pass "a real-HOME lookup that prints nothing refuses every build"
else
    fail "empty real-HOME lookup -> rc $rc, expected a refusal that creates nothing"
fi

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
