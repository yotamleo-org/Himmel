#!/usr/bin/env bash
# Smoke test for scripts/guardrails/phi-egress-lib.sh (fence
# parity by extraction). Exercises the two predicates shared by
# graphify-fence.sh and refresh-graph-map.sh in isolation; the consumer-level
# regression coverage lives in test-graphify-fence.sh and
# test-refresh-graph-map.sh.
#
# Usage: bash scripts/guardrails/test-phi-egress-lib.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/guardrails/phi-egress-lib.sh"

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/phi-egress-lib-test.XXXXXX")"
trap 'rm -rf "$WS"' EXIT

echo "== _guard_file_readable =="
if ! _guard_file_readable "$WS/absent"; then pass "absent file -> false"; else fail "absent file -> expected false"; fi

: > "$WS/readable.txt"
if _guard_file_readable "$WS/readable.txt"; then pass "readable file -> true"; else fail "readable file -> expected true"; fi

mkdir -p "$WS/adir"
if ! _guard_file_readable "$WS/adir"; then pass "directory (not a regular file) -> false"; else fail "directory -> expected false"; fi

: > "$WS/unreadable.txt"
if chmod 000 "$WS/unreadable.txt" 2>/dev/null && [ ! -r "$WS/unreadable.txt" ]; then
    if ! _guard_file_readable "$WS/unreadable.txt"; then
        pass "existing-but-unreadable file -> false (fail-closed, not treated as absent)"
    else
        fail "existing-but-unreadable file -> expected false"
    fi
    chmod 644 "$WS/unreadable.txt"
else
    echo "  SKIP  existing-but-unreadable case (chmod 000 did not deny read on this fs/user, e.g. root or Windows ACL passthrough)"
fi

echo "== _guard_endpoint_host =="
h="$(_guard_endpoint_host "https://api.anthropic.com/v1/messages")"
if [ "$h" = "api.anthropic.com" ]; then
    pass "https URL with path -> exact lowercased host"
else
    fail "https URL with path -> expected api.anthropic.com got [$h]"
fi

h="$(_guard_endpoint_host "HTTPS://API.ANTHROPIC.COM")"
if [ "$h" = "api.anthropic.com" ]; then
    pass "uppercase scheme+host -> lowercased"
else
    fail "uppercase scheme+host -> expected api.anthropic.com got [$h]"
fi

h="$(_guard_endpoint_host "https://user:pass@api.z.ai:443/x?y=1#z")"
if [ "$h" = "api.z.ai" ]; then
    pass "userinfo+port+query+fragment all stripped -> bare host"
else
    fail "userinfo+port+query+fragment -> expected api.z.ai got [$h]"
fi

if ! _guard_endpoint_host "" >/dev/null 2>&1; then pass "empty URL -> rc=1"; else fail "empty URL -> expected rc=1"; fi

if ! _guard_endpoint_host "http://api.anthropic.com" >/dev/null 2>&1; then
    pass "plaintext http:// -> rc=1 (fail-closed, not implicitly trusted)"
else
    fail "plaintext http:// -> expected rc=1"
fi

if ! _guard_endpoint_host "api.anthropic.com" >/dev/null 2>&1; then
    pass "scheme-less value -> rc=1"
else
    fail "scheme-less value -> expected rc=1"
fi

if ! _guard_endpoint_host 'https://evil.com\@api.anthropic.com' >/dev/null 2>&1; then
    pass "backslash-bearing URL -> rc=1 (userinfo-smuggling guard)"
else
    fail "backslash-bearing URL -> expected rc=1"
fi

out="$(_guard_endpoint_host "https://api.anthropic.com.evil.example")"
if [ "$out" = "api.anthropic.com.evil.example" ] && [ "$out" != "api.anthropic.com" ]; then
    pass "lookalike host is returned VERBATIM, not normalized to the real host (caller's exact-match allowlist must reject it)"
else
    fail "lookalike host -> expected verbatim api.anthropic.com.evil.example got [$out]"
fi

echo "== _guard_phi_list_paths =="
# rc 0 = paths printed, 2 = unreadable, 3 = none declared. Each row runs in a
# subshell with its own HOME, so the station's real lists are never read.
phi_home() { # <case> -> a fresh fixture HOME with both config parents
    local h="$WS/$1"
    mkdir -p "$h/.config/himmel/phi" "$h/.config/claude-glm"
    printf '%s' "$h"
}
paths_of() { # <home> <list name> -> "<rc>:<paths joined by a space>"
    local out rc
    out="$(unset CLAUDE_GLM_CONFIG_DIR; HOME="$1" _guard_phi_list_paths "$2")"
    rc=$?
    printf '%s:%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}
expect_paths() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -> expected [$2] got [$3]"; fi
}

H="$(phi_home only-neutral)"; : > "$H/.config/himmel/phi/phi-roots"
expect_paths "neutral only -> the neutral file" "0:$H/.config/himmel/phi/phi-roots" "$(paths_of "$H" phi-roots)"

H="$(phi_home only-old)"; : > "$H/.config/claude-glm/phi-roots"
expect_paths "old only -> the old file (fallback)" "0:$H/.config/claude-glm/phi-roots" "$(paths_of "$H" phi-roots)"

H="$(phi_home both)"; : > "$H/.config/himmel/phi/phi-roots"; : > "$H/.config/claude-glm/phi-roots"
expect_paths "both -> both files, neutral first (a list under either dir counts)" \
    "0:$H/.config/himmel/phi/phi-roots $H/.config/claude-glm/phi-roots" "$(paths_of "$H" phi-roots)"

H="$(phi_home neither)"
expect_paths "dirs but no list -> rc 3 (none declared), never rc 0 with no paths" "3:" "$(paths_of "$H" phi-roots)"

H="$WS/no-dirs"; mkdir -p "$H"
expect_paths "neither dir -> rc 3 (none declared)" "3:" "$(paths_of "$H" phi-roots)"

H="$(phi_home override)"; G="$WS/override-glm"; mkdir -p "$G"; : > "$G/phi-roots"; : > "$H/.config/claude-glm/phi-roots"
got="$(CLAUDE_GLM_CONFIG_DIR="$G" HOME="$H" _guard_phi_list_paths phi-roots)"
expect_paths "CLAUDE_GLM_CONFIG_DIR replaces only the old dir" "$G/phi-roots" "$got"

H="$(phi_home override-neutral)"; G="$WS/override-neutral-glm"; mkdir -p "$G"; : > "$H/.config/himmel/phi/phi-roots"
got="$(CLAUDE_GLM_CONFIG_DIR="$G" HOME="$H" _guard_phi_list_paths phi-roots)"
expect_paths "CLAUDE_GLM_CONFIG_DIR cannot steer the neutral list away" "$H/.config/himmel/phi/phi-roots" "$got"

H="$(phi_home dangling)"; ln -s "$WS/nowhere" "$H/.config/himmel/phi/phi-roots"
expect_paths "a dangling list symlink is present, not absent" "0:$H/.config/himmel/phi/phi-roots" "$(paths_of "$H" phi-roots)"

H="$(phi_home dir-is-file)"; rmdir "$H/.config/himmel/phi"; : > "$H/.config/himmel/phi"
expect_paths "a plain file where the neutral dir belongs -> rc 2" "2:" "$(paths_of "$H" phi-roots)"

H="$(phi_home dir-dangling)"; rmdir "$H/.config/claude-glm"; ln -s "$WS/nowhere" "$H/.config/claude-glm"
expect_paths "a dangling symlink where the old dir belongs -> rc 2" "2:" "$(paths_of "$H" phi-roots)"

H="$(phi_home dir-locked)"; : > "$H/.config/himmel/phi/phi-roots"
if chmod 000 "$H/.config/himmel/phi" 2>/dev/null && [ ! -x "$H/.config/himmel/phi" ]; then
    expect_paths "an unreadable neutral dir -> rc 2, never read as absent" "2:" "$(paths_of "$H" phi-roots)"
    chmod 755 "$H/.config/himmel/phi"
else
    echo "  SKIP  unreadable-dir case (chmod 000 did not deny access on this fs/user)"
fi

echo "== _guard_phi_list_entries =="
# Only the two list names are read, whichever dir the path comes from.
H="$(phi_home entries)"; printf '/synthetic/phi\n' > "$H/.config/claude-glm/phi-roots"; printf '/synthetic/phi\n' > "$H/.config/claude-glm/other-file"
got="$(_guard_phi_list_entries "$H/.config/claude-glm/phi-roots")"; rc=$?
expect_paths "a list name is read" "0:/synthetic/phi" "$rc:$got"
got="$(_guard_phi_list_entries "$H/.config/claude-glm/other-file")"; rc=$?
expect_paths "any other file name is refused, rc 2 and nothing printed" "2:" "$rc:$got"

echo "== _guard_phi_decision =="
# The egress decision, not the path: rc 0 clear, 1 listed (deny), 2 unreadable
# (deny), 3 none declared.
decision_of() { # <home> <path> -> rc
    ( unset CLAUDE_GLM_CONFIG_DIR; HOME="$1" _guard_phi_decision "$2" )
    printf '%s' "$?"
}
expect_rc() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -> expected rc $2 got rc $3"; fi
}
ROOT="$WS/phi-root"; OTHER="$WS/other-root"; mkdir -p "$ROOT/sub" "$OTHER"

H="$(phi_home d-neutral)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "root only under the neutral dir -> denied" 1 "$(decision_of "$H" "$ROOT/sub")"
expect_rc "a path outside it -> clear" 0 "$(decision_of "$H" "$OTHER")"

H="$(phi_home d-old)"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_rc "root only under the old dir -> denied" 1 "$(decision_of "$H" "$ROOT/sub")"

H="$(phi_home d-both)"; printf '%s\n' "$OTHER" > "$H/.config/himmel/phi/phi-roots"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_rc "both dirs, root only in the old list -> denied (neutral never hides old)" 1 "$(decision_of "$H" "$ROOT/sub")"
expect_rc "both dirs, root only in the neutral list -> denied" 1 "$(decision_of "$H" "$OTHER")"

H="$(phi_home d-deny)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/egress-denylist"
expect_rc "egress-denylist counts too" 1 "$(decision_of "$H" "$ROOT")"

H="$(phi_home d-crlf)"; printf '# managed\r\n\r\n  %s/  \r\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "CRLF, padding, a comment and a trailing slash still match" 1 "$(decision_of "$H" "$ROOT/sub")"

H="$(phi_home d-blank)"; printf '\r\n   \n# only a comment\n' > "$H/.config/himmel/phi/phi-roots"
expect_rc "a blank line never prefix-matches every path" 0 "$(decision_of "$H" "$ROOT")"

H="$(phi_home d-slash)"; printf '/\n' > "$H/.config/himmel/phi/phi-roots"
expect_rc "an entry of / covers every path" 1 "$(decision_of "$H" "$OTHER")"

H="$(phi_home d-prefix)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"; mkdir -p "$ROOT-sibling"
expect_rc "a name-prefix sibling of a root -> clear" 0 "$(decision_of "$H" "$ROOT-sibling")"

ln -s "$ROOT" "$WS/phi-link"
H="$(phi_home d-link)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "a symlink into a listed root -> denied" 1 "$(decision_of "$H" "$WS/phi-link/sub")"

H="$(phi_home d-link-root)"; printf '%s\n' "$WS/phi-link" > "$H/.config/himmel/phi/phi-roots"
expect_rc "a listed root that is a symlink -> denied" 1 "$(decision_of "$H" "$ROOT/sub")"

H="$(phi_home d-none)"
expect_rc "no list in either dir -> rc 3 (none declared), never clear" 3 "$(decision_of "$H" "$ROOT")"

H="$(phi_home d-dangling)"; ln -s "$WS/nowhere" "$H/.config/himmel/phi/phi-roots"
expect_rc "a dangling list symlink -> unreadable" 2 "$(decision_of "$H" "$ROOT")"

H="$(phi_home d-dirlist)"; mkdir -p "$H/.config/himmel/phi/phi-roots"
expect_rc "a directory where a list belongs -> unreadable" 2 "$(decision_of "$H" "$ROOT")"

H="$(phi_home d-listlock)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
if chmod 000 "$H/.config/himmel/phi/phi-roots" 2>/dev/null && [ ! -r "$H/.config/himmel/phi/phi-roots" ]; then
    printf '%s\n' "$OTHER" > "$H/.config/claude-glm/phi-roots"
    expect_rc "unreadable neutral list, readable old list without the path -> unreadable, not clear" 2 "$(decision_of "$H" "$ROOT")"
    expect_rc "unreadable neutral list, the path hits the readable old list -> still denied" 2 "$(decision_of "$H" "$OTHER")"
    chmod 644 "$H/.config/himmel/phi/phi-roots"
else
    echo "  SKIP  unreadable-list case (chmod 000 did not deny read on this fs/user)"
fi

H="$(phi_home d-dirlock)"; printf '%s\n' "$OTHER" > "$H/.config/claude-glm/phi-roots"
if chmod 000 "$H/.config/himmel/phi" 2>/dev/null && [ ! -x "$H/.config/himmel/phi" ]; then
    expect_rc "unreadable neutral dir -> unreadable, never clear" 2 "$(decision_of "$H" "$ROOT")"
    chmod 755 "$H/.config/himmel/phi"
else
    echo "  SKIP  unreadable-dir decision case (chmod 000 did not deny access on this fs/user)"
fi

H="$(phi_home d-parentlock)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
if chmod 000 "$H/.config/himmel" 2>/dev/null && [ ! -x "$H/.config/himmel" ]; then
    expect_rc "a locked parent of the neutral dir -> unreadable, never absent" 2 "$(decision_of "$H" "$ROOT")"
    chmod 755 "$H/.config/himmel"
else
    echo "  SKIP  locked-parent case (chmod 000 did not deny access on this fs/user)"
fi

expect_rc "no HOME -> unreadable, the lists cannot be located" 2 "$(decision_of "" "$ROOT")"

H="$(phi_home d-empty-path)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "an empty path -> unreadable, never clear" 2 "$(decision_of "$H" "")"

H="$(phi_home d-holds)"; printf '%s\n' "$ROOT/sub" > "$H/.config/himmel/phi/phi-roots"
expect_rc "a path holding a listed root -> denied" 1 "$(decision_of "$H" "$ROOT")"

: > "$ROOT/file.txt"; ln -s "$ROOT/file.txt" "$WS/phi-file-link"
H="$(phi_home d-filelink)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "a file symlink into a listed root -> denied" 1 "$(decision_of "$H" "$WS/phi-file-link")"
expect_rc "a not-yet-created path under a symlink into a root -> denied" 1 "$(decision_of "$H" "$WS/phi-link/new/deep/file")"

H="$(phi_home d-glob)"; printf '%s\n' "$WS/*" > "$H/.config/himmel/phi/phi-roots"
expect_rc "a list entry is a literal path, never a glob" 0 "$(decision_of "$H" "$OTHER")"

H="$(phi_home d-slashes)"; printf '%s///\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_rc "several trailing slashes still match" 1 "$(decision_of "$H" "$ROOT/sub")"

H="$(phi_home d-relative)"
got="$( cd "$WS" && HOME="$H" CLAUDE_GLM_CONFIG_DIR="relative-cfg-absent/x" _guard_phi_list_paths phi-roots; printf '%s' "$?" )"
expect_paths "a relative override with no such dir terminates -> rc 3" "3" "$got"

if ( set -euo pipefail; H="$(phi_home d-errexit)"; rc=0; HOME="$H" _guard_phi_decision "$ROOT" || rc=$?; [ "$rc" -eq 3 ] ); then
    pass "rc 3 survives a caller under set -euo pipefail"
else
    fail "rc 3 under set -euo pipefail -> the function aborted or returned another rc"
fi

echo "== _guard_phi_dir_provable =="
# A dir that cannot be traversed (or a path that cannot be followed to an existing
# ancestor) is unprovable: a list inside it must read as unreadable, never as a miss.
# Skipped where chmod cannot drop traversal (root); every dir is restored before the
# EXIT trap removes the tree.
PV_ROOT="$WS/pv"; mkdir -p "$PV_ROOT/open" "$PV_ROOT/locked-self/cfg" "$PV_ROOT/locked-parent/cfg" "$PV_ROOT/cwd"
printf '%s\n' "$ROOT" > "$PV_ROOT/locked-self/cfg/phi-roots"
mkdir -p "$PV_ROOT/cwd/cfg"; printf '%s\n' "$ROOT" > "$PV_ROOT/cwd/cfg/phi-roots"
chmod 000 "$PV_ROOT/locked-self/cfg" "$PV_ROOT/locked-parent"
ln -s "$PV_ROOT/locked-self/cfg" "$PV_ROOT/link-to-locked"
ln -s "$PV_ROOT/locked-parent/cfg" "$PV_ROOT/link-through-locked-parent"
ln -s "$PV_ROOT/nowhere" "$PV_ROOT/dangling-dir"
prov_rc() { # <dir> -> rc of _guard_phi_dir_provable, run in the working directory of the caller
    local rc=0; _guard_phi_dir_provable "$1" || rc=$?; printf '%s' "$rc"
}
expect_rc "an open dir -> provable" 0 "$(prov_rc "$PV_ROOT/open")"
expect_rc "a missing dir under an open parent -> provable (a miss is confirmed)" 0 "$(prov_rc "$PV_ROOT/open/none/deeper")"
if [ -x "$PV_ROOT/locked-self/cfg" ] || [ -x "$PV_ROOT/locked-parent" ]; then
    echo "  SKIP  unprovable-dir rows (chmod could not drop traversal here)"
else
    expect_rc "a dir at mode 000 -> unprovable" 1 "$(prov_rc "$PV_ROOT/locked-self/cfg")"
    expect_rc "a dir under a parent at mode 000 -> unprovable" 1 "$(prov_rc "$PV_ROOT/locked-parent/cfg")"
    expect_rc "a symlinked dir whose target is at mode 000 -> unprovable" 1 "$(prov_rc "$PV_ROOT/link-to-locked")"
    expect_rc "a symlinked dir whose target sits under a locked parent -> unprovable" 1 "$(prov_rc "$PV_ROOT/link-through-locked-parent")"
    expect_rc "a dangling symlinked dir -> unprovable" 1 "$(prov_rc "$PV_ROOT/dangling-dir")"
    # relative paths end at the working directory, which is locked after the cd
    rel_locked() { # <relative dir> -> rc, from a working directory made untraversable
        ( cd "$PV_ROOT/cwd" && chmod 000 "$PV_ROOT/cwd" && rc=0; _guard_phi_dir_provable "$1" || rc=$?; chmod 755 "$PV_ROOT/cwd"; printf '%s' "$rc" )
    }
    expect_rc "a relative dir in a locked working directory -> unprovable" 1 "$(rel_locked cfg)"
    expect_rc "a deeper relative dir in a locked working directory -> unprovable" 1 "$(rel_locked cfg/deeper)"
    # a list the locked relative override would hold: the decision must deny, not clear
    H="$(phi_home d-relative-locked)"
    got="$( cd "$PV_ROOT/cwd" && chmod 000 "$PV_ROOT/cwd" && rc=0; CLAUDE_GLM_CONFIG_DIR="cfg" HOME="$H" _guard_phi_decision "$ROOT/sub" || rc=$?; chmod 755 "$PV_ROOT/cwd"; printf '%s' "$rc" )"
    expect_rc "a relative override in a locked working directory -> unreadable, deny" 2 "$got"
fi
chmod 755 "$PV_ROOT/locked-self/cfg" "$PV_ROOT/locked-parent" "$PV_ROOT/cwd"
expect_rc "a relative dir in an open working directory -> provable" 0 "$( cd "$PV_ROOT/cwd" && prov_rc cfg )"
expect_rc "a dir whose parent is the root -> provable (the root is tested)" 0 "$(prov_rc /no-such-phi-dir-8923)"

echo "== _guard_phi_unenforced_roots =="
unenforced_of() { # <home> -> "<rc>:<roots joined by a space>"
    local out rc
    out="$(unset CLAUDE_GLM_CONFIG_DIR; HOME="$1" _guard_phi_unenforced_roots)"
    rc=$?
    printf '%s:%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

H="$(phi_home u-neutral)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
expect_paths "neutral only -> the root has no guard behind it" "0:$ROOT" "$(unenforced_of "$H")"

H="$(phi_home u-extra)"; printf '%s\n%s\n' "$ROOT" "$OTHER" > "$H/.config/himmel/phi/phi-roots"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_paths "both exist, an extra neutral root -> that root only" "0:$OTHER" "$(unenforced_of "$H")"

H="$(phi_home u-mirrored)"; printf '%s/\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_paths "mirrored, spelled differently -> nothing unenforced" "0:" "$(unenforced_of "$H")"

H="$(phi_home u-cross)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/egress-denylist"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_paths "held in the other old list -> nothing unenforced" "0:" "$(unenforced_of "$H")"

H="$(phi_home u-parent)"; printf '%s\n' "$ROOT/sub" > "$H/.config/himmel/phi/phi-roots"; printf '%s\n' "$ROOT" > "$H/.config/claude-glm/phi-roots"
expect_paths "covered by a parent root in the old list -> nothing unenforced" "0:" "$(unenforced_of "$H")"

H="$(phi_home u-child)"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"; printf '%s\n' "$ROOT/sub" > "$H/.config/claude-glm/phi-roots"
expect_paths "the old list covers only a child of the root -> unenforced" "0:$ROOT" "$(unenforced_of "$H")"

H="$(phi_home u-sched)"; G="$WS/u-sched-glm"; mkdir -p "$G"; printf '%s\n' "$ROOT" > "$G/phi-roots"; printf '%s\n' "$ROOT" > "$H/.config/himmel/phi/phi-roots"
got="$(CLAUDE_GLM_CONFIG_DIR="$G" HOME="$H" _guard_phi_unenforced_roots)"
expect_paths "the override covers it but the HOME old dir does not -> unenforced" "$ROOT" "$got"

H="$(phi_home u-dirlist)"; mkdir -p "$H/.config/himmel/phi/phi-roots"
expect_paths "an unreadable neutral list -> rc 2" "2:" "$(unenforced_of "$H")"

H="$(phi_home u-none)"
expect_paths "no neutral list -> nothing unenforced" "0:" "$(unenforced_of "$H")"

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
