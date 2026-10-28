#!/usr/bin/env bash
# Tests for scripts/lib/load-dotenv.sh.
# Each case runs load_dotenv in its own $(...) subshell to isolate the
# exported env between cases — the subshell-scoped export is intentional.
# shellcheck disable=SC2030,SC2031
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/load-dotenv.sh"
# shellcheck source=load-dotenv.sh
# shellcheck disable=SC1091
. "$LIB"
# shellcheck source=canon-path.sh
# shellcheck disable=SC1091
. "$(dirname "$LIB")/canon-path.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}
# assert_eq_fp: for a row that requests a real key name. A failure prints
# only a length and a hash prefix, never the value.
assert_eq_fp() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — got a value of length ${#actual}, sha256 $(printf '%s' "$actual" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
        FAILED=$((FAILED + 1))
    fi
}

# The runners export HIMMEL_SECRETS_KEYRING=off; the K rows need the stub keyring.
unset HIMMEL_SECRETS_KEYRING

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# himmel.conf (behaviour keys, HANDOVER_DIR included) is read from the config
# dir; an empty one keeps every row off the operator's real ~/.himmel.
mkdir -p "$TMP/himmel-config"
export HIMMEL_CONFIG_DIR="$TMP/himmel-config"
# The policy dir comes from the account entry; this seam points it back at HOME.
export HIMMEL_POLICY_FOLLOWS_HOME=1

# Stub keyring. load_dotenv asks scripts/lib/himmel-secrets for secret-class
# keys, so every row runs with a stub secret-tool and busctl first on PATH and
# never reaches a real keyring. The stub store is one `attrs<TAB>value` line per
# item; a lookup matches an item holding every queried attribute, as libsecret
# does. The two error lines are copied from the station (CachyOS, libsecret
# 0.21.8, systemd 262) under `env -i HOME=… PATH=/usr/bin:/bin`, 2026-10-25.
KBIN="$TMP/kbin"
mkdir -p "$KBIN"
export KSTUB_STORE="$TMP/keyring.tsv" KSTUB_LOG="$TMP/keyring.log" KSTUB_LOCKED=false
: >"$KSTUB_STORE"
cat >"$KBIN/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool[%s] %s\n' "${DBUS_SESSION_BUS_ADDRESS:-}" "$*" >>"$KSTUB_LOG"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo 'secret-tool: Cannot autolaunch D-Bus without X11 $DISPLAY' >&2
    exit 1
fi
verb="$1"; shift
[ "${1:-}" = --all ] && shift
if [ "$verb" = store ]; then shift 2; fi
q=""
while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
case "$verb" in
    store) IFS= read -r val || true; printf '%s\t%s\n' "${q# }" "$val" >>"$KSTUB_STORE"; exit 0 ;;
esac
rc=1
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    [ "$m" = 1 ] || continue
    case "$verb" in
        lookup) printf '%s' "$val"; exit 0 ;;
        # As libsecret's secret-tool.c: the item lines and the secret go to
        # stdout (g_print), the attribute lines to stderr (g_printerr).
        search)
            printf '[/stub]\nlabel = stub\nsecret = %s\n' "$val"
            for p in $attrs; do printf 'attribute.%s = %s\n' "${p%%=*}" "${p#*=}" >&2; done
            rc=0 ;;
    esac
done <"$KSTUB_STORE"
# A search that matches nothing exits 0, as libsecret's does.
[ "$verb" = search ] && exit 0
exit "$rc"
STUB
cat >"$KBIN/busctl" <<'STUB'
#!/usr/bin/env bash
printf 'busctl[%s] %s\n' "${DBUS_SESSION_BUS_ADDRESS:-}" "$*" >>"$KSTUB_LOG"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    echo 'Failed to set bus address: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined (consider using --machine=<user>@.host --user to connect to bus of other user)' >&2
    exit 1
fi
[ -n "${KSTUB_HANG:-}" ] && exec sleep 10
case "$*" in
    *Unlock*) echo unlock-called >>"$KSTUB_LOG" ;;
    *" Locked") echo "b ${KSTUB_LOCKED:-false}" ;;
esac
STUB
chmod +x "$KBIN/secret-tool" "$KBIN/busctl"
export PATH="$KBIN:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/stub-bus"
kreset() { : >"$KSTUB_STORE"; : >"$KSTUB_LOG"; }

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet

# T1: sets a key that is currently unset.
printf 'HANDOVER_DIR=/c/some/path/handovers\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "T1 sets unset key" "/c/some/path/handovers" "$got"

# T2: a value already in the live env wins (??= semantics).
got=$( cd "$REPO" && export HANDOVER_DIR=/live/value && load_dotenv HANDOVER_DIR && printf '%s' "$HANDOVER_DIR" )
assert_eq "T2 live env wins" "/live/value" "$got"

# T3: missing .env → no-op, key stays unset, rc=0.
rm -f "$REPO/.env"
out=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR; rc=$?; printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "$rc" )
assert_eq "T3 missing .env no-op" "<unset>|0" "$out"

# T4: CRLF-safe (trailing CR stripped from value).
printf 'HANDOVER_DIR=/c/crlf/path\r\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '[%s]' "$HANDOVER_DIR" )
assert_eq "T4 CRLF stripped" "[/c/crlf/path]" "$got"

# T5: comments / blanks / non-KV lines skipped; surrounding whitespace trimmed.
printf '# comment\n\nnot-a-kv-line\n  HANDOVER_DIR =  /c/spaced/path  \n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '[%s]' "$HANDOVER_DIR" )
assert_eq "T5 trims + skips noise" "[/c/spaced/path]" "$got"

# T6: first match wins on a duplicated key.
printf 'HANDOVER_DIR=/first\nHANDOVER_DIR=/second\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "$HANDOVER_DIR" )
assert_eq "T6 first match wins" "/first" "$got"

# T7: without an explicit allowlist, even the old defaults stay unset.
printf 'HANDOVER_DIR=/c/h\nUSER_SLUG=tester\nTEST_ANTHROPIC_API_KEY=dummy\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR USER_SLUG TEST_ANTHROPIC_API_KEY && load_dotenv && printf '%s|%s|%s' "${HANDOVER_DIR:-<unset>}" "${USER_SLUG:-<unset>}" "${TEST_ANTHROPIC_API_KEY:-<unset>}" )
assert_eq "shared-loader-without-list-exports-nothing" "<unset>|<unset>|<unset>" "$got"
got=$( unset HANDOVER_DIR USER_SLUG && load_dotenv --root "$REPO" && printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "${USER_SLUG:-<unset>}" )
assert_eq "shared-loader-root-without-list-exports-nothing" "<unset>|<unset>" "$got"

# T8: only requested keys are loaded (others stay unset).
printf 'HANDOVER_DIR=/c/h\nOTHER_KEY=should-not-load\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR OTHER_KEY && load_dotenv HANDOVER_DIR && printf '%s|%s' "$HANDOVER_DIR" "${OTHER_KEY:-<unset>}" )
assert_eq "T8 only requested keys" "/c/h|<unset>" "$got"

# T9: from inside a git WORKTREE, the loader resolves the PRIMARY checkout's
# .env (the headline guarantee — a gitignored .env is never copied into a
# worktree, so git-common-dir resolution must reach back to the main repo).
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit --allow-empty -q -m init
printf 'HANDOVER_DIR=/c/primary/handovers\n' > "$REPO/.env"
WT="$TMP/wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch
got=$( cd "$WT" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "T9 worktree reads primary .env" "/c/primary/handovers" "$got"
git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true

# T10: outside any git repo, _load_dotenv_root falls back to the script-
# relative root and no-ops cleanly when no .env is found there (rc=0, no crash).
# The fallback is SCRIPT-relative ("two levels up from this script"), so
# sourcing the real $LIB (as every other case does) makes this case resolve to
# the real repo root and read the operator's real .env — not the clean no-op
# it claims to test. Give this one case its own scratch tree with a COPY of
# load-dotenv.sh two levels down, so its script-relative fallback resolves to
# the scratch root instead of the real repo.
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT/scripts/lib"
cp "$LIB" "$NONGIT/scripts/lib/load-dotenv.sh"
if [ -e "$NONGIT/.env" ]; then
    echo "FAIL T10 setup — scratch root unexpectedly has a .env"
    FAILED=$((FAILED + 1))
fi
# shellcheck disable=SC1091
out=$( cd "$NONGIT" && unset HANDOVER_DIR && . "$NONGIT/scripts/lib/load-dotenv.sh" && load_dotenv HANDOVER_DIR; rc=$?; printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "$rc" )
assert_eq "T10 git-absent fallback clean no-op" "<unset>|0" "$out"

# ── --root mode: explicit root, CWD git resolution bypassed ─────
ROOTDIR="$TMP/explicit-root"
mkdir -p "$ROOTDIR"
printf 'HIMMEL_INITIATIVE=prcheck,pr\n' > "$ROOTDIR/.env"

# T11: --root loads <dir>/.env regardless of CWD.
got=$( cd "$NONGIT" && unset HIMMEL_INITIATIVE && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "${HIMMEL_INITIATIVE:-<unset>}" )
assert_eq "T11 --root loads its .env" "prcheck,pr" "$got"

# T12: --root NEVER reads the CWD repo's .env (the CWD-safety guarantee). Launch
# from inside a DECOY git repo whose .env sets a different value; --root must win.
DECOY="$TMP/decoy"; mkdir -p "$DECOY"; git -C "$DECOY" init --quiet
printf 'HIMMEL_INITIATIVE=DECOY_VALUE\n' > "$DECOY/.env"
got=$( cd "$DECOY" && unset HIMMEL_INITIATIVE && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "$HIMMEL_INITIATIVE" )
assert_eq "T12 --root ignores CWD repo .env" "prcheck,pr" "$got"

# T13: --root is still non-clobbering (process env wins).
got=$( cd "$NONGIT" && export HIMMEL_INITIATIVE=live && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "$HIMMEL_INITIATIVE" )
assert_eq "T13 --root non-clobbering" "live" "$got"

# T14: --root pointing at a dir with no .env → clean no-op, rc=0.
out=$( cd "$NONGIT" && unset HIMMEL_INITIATIVE && load_dotenv --root "$NONGIT" HIMMEL_INITIATIVE; rc=$?; printf '%s|%s' "${HIMMEL_INITIATIVE:-<unset>}" "$rc" )
assert_eq "T14 --root no .env no-op" "<unset>|0" "$out"

# ── _load_dotenv_primary_for: primary-checkout fallback for a ───
# pinned --root — the claude-codex path. A launcher invoked from a worktree copy
# of itself has <parent> = worktree root (no .env); the helper resolves the
# primary and reads .env there. canonicalize() compares paths by their resolved
# form (avoids macOS /var → /private/var and MSYS /tmp vs C:/… mismatches; a bare
# `cd && pwd` is the LOGICAL path and canonicalises neither).
canon() { canon_path_native "$1" 2>/dev/null; }
PFREPO="$TMP/pf-repo"; mkdir -p "$PFREPO"; git -C "$PFREPO" init --quiet
git -C "$PFREPO" config user.email t@example.com
git -C "$PFREPO" config user.name tester
git -C "$PFREPO" commit --allow-empty -q -m init
printf 'CLIPROXY_API_KEY=pk-from-primary\n' > "$PFREPO/.env"   # gitleaks:allow
PFWT="$TMP/pf-wt"
git -C "$PFREPO" worktree add -q "$PFWT" -b pf-branch

# T15: candidate is a linked worktree with NO .env → resolves the PRIMARY (which
# has .env), and emits exactly ONE advisory line to stderr.
root=$( _load_dotenv_primary_for "$PFWT" 2>/dev/null )
assert_eq "T15 worktree → primary root" "$(canon "$PFREPO")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWT" 2>&1 1>/dev/null )
case "$adv" in *"reading the primary checkout's .env"*) echo "PASS T15 advisory emitted" ;; *) echo "FAIL T15 advisory — got: $adv"; FAILED=$((FAILED + 1)) ;; esac

# T16: candidate is the primary (has .env) → returned unchanged, NO advisory.
assert_eq "T16 primary unchanged" "$(canon "$PFREPO")" "$(canon "$(_load_dotenv_primary_for "$PFREPO" 2>/dev/null)")"
adv=$( _load_dotenv_primary_for "$PFREPO" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T16 no advisory on primary"; else echo "FAIL T16 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T17: both missing (worktree AND primary have no .env) → returns the candidate
# unchanged, NO advisory (the caller's missing-.env path applies — load_dotenv
# no-ops, the key stays unset, the launcher's own error message surfaces).
rm -f "$PFREPO/.env"
root=$( _load_dotenv_primary_for "$PFWT" 2>/dev/null )
assert_eq "T17 both-missing returns candidate" "$(canon "$PFWT")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWT" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T17 no advisory on both-missing"; else echo "FAIL T17 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi
printf 'CLIPROXY_API_KEY=pk-from-primary\n' > "$PFREPO/.env"   # gitleaks:allow  (restore for T18)

# T18: integration — load_dotenv --root <helper-resolved worktree> finds the key
# in the PRIMARY .env (exactly what claude-codex does). Run from the worktree's
# own cwd to prove --root + helper reaches the primary regardless of CWD.
got=$( cd "$PFWT" && unset CLIPROXY_API_KEY && load_dotenv --root "$(_load_dotenv_primary_for "$PFWT")" CLIPROXY_API_KEY && printf '%s' "${CLIPROXY_API_KEY:-<unset>}" )
assert_eq_fp "T18 load_dotenv via helper finds primary key" "pk-from-primary" "$got"

# T19: a non-git candidate dir → returned unchanged (git fails, no fallback, no
# advisory) — hermetic tests that pin the root to a temp dir are unaffected.
PFNONGIT="$TMP/pf-nongit"; mkdir -p "$PFNONGIT"
assert_eq "T19 non-git returns candidate" "$(canon "$PFNONGIT")" "$(canon "$(_load_dotenv_primary_for "$PFNONGIT" 2>/dev/null)")"
adv=$( _load_dotenv_primary_for "$PFNONGIT" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T19 no advisory on non-git"; else echo "FAIL T19 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T20: a NESTED dir INSIDE a worktree (NOT the worktree root)
# must NOT read the primary .env. A hermetically pinned root like
# <worktree>/scripts resolves common-dir to the real .git and (under r1) differed
# from the candidate → silently loaded the operator's .env. The candidate is not
# the checkout root, so the fallback must NOT fire (primary .env still present).
PFWTNEST="$PFWT/nested"; mkdir -p "$PFWTNEST"
root=$( _load_dotenv_primary_for "$PFWTNEST" 2>/dev/null )
assert_eq "T20 nested-in-worktree returns candidate" "$(canon "$PFWTNEST")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWTNEST" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T20 no advisory on nested-in-worktree"; else echo "FAIL T20 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T21: a NESTED dir INSIDE the primary checkout must NOT fall
# back either — git-dir == git-common-dir here (primary checkout), so there is no
# linked worktree to fall back from, and the candidate is not the toplevel.
PFPRIMNEST="$PFREPO/nested"; mkdir -p "$PFPRIMNEST"
root=$( _load_dotenv_primary_for "$PFPRIMNEST" 2>/dev/null )
assert_eq "T21 nested-in-primary returns candidate" "$(canon "$PFPRIMNEST")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFPRIMNEST" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T21 no advisory on nested-in-primary"; else echo "FAIL T21 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

git -C "$PFREPO" worktree remove --force "$PFWT" 2>/dev/null || true

# ── one-pass loader invariants ─────────────────────────────────

# T22: an already-set EMPTY environment value counts as ABSENT,
# so the .env value loads over it. Every caller guards with `[ -z "${KEY-}" ]`,
# so a loader that treated set-empty as "already provided" loaded nothing and
# still returned 0 — the silent-failure class this family of tickets removes.
printf 'DOTENV_KEEP=from-file\n' > "$REPO/.env"
got=$( cd "$REPO" && export DOTENV_KEEP= && load_dotenv DOTENV_KEEP && printf '<%s>' "$DOTENV_KEEP" )
assert_eq "T22 set-empty env is filled from .env" "<from-file>" "$got"

# T22b: the other half of the same rule — a live NON-EMPTY value
# still wins over .env. Without this, T22 alone would also pass a loader that
# clobbered unconditionally.
printf 'DOTENV_KEEP=from-file\n' > "$REPO/.env"
got=$( cd "$REPO" && export DOTENV_KEEP=live && load_dotenv DOTENV_KEEP && printf '<%s>' "$DOTENV_KEEP" )
assert_eq "T22b live non-empty env is not clobbered" "<live>" "$got"

# T23: matching is anchored to the complete key; XKEY must not satisfy KEY.
printf 'XDOTENV_ANCHOR=decoy\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ANCHOR && load_dotenv DOTENV_ANCHOR && printf '%s' "${DOTENV_ANCHOR:-<unset>}" )
assert_eq "T23 key match is anchored" "<unset>" "$got"

# T24: first match wins even when its value is empty.
printf 'DOTENV_DUP=\nDOTENV_DUP=second\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_DUP && load_dotenv DOTENV_DUP && printf '<%s>' "$DOTENV_DUP" )
assert_eq "T24 empty first duplicate wins" "<>" "$got"

# T25: reject constructs unavailable in macOS's Bash 3.2.
incompatible=$(grep -En '(^|[[:space:]])(declare|local)[[:space:]]+-A|(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)|\$\{[^}]*(\^\^|,,)|\[\[[^]]*[[:space:]]-v[[:space:]]' "$LIB" || true)
assert_eq "T25 Bash 3.2-compatible constructs" "" "$incompatible"

# T26: an explicitly selected root with no .env fails open, silently, with rc 0.
MISSING_ROOT="$TMP/missing-explicit-root"
mkdir -p "$MISSING_ROOT"
out=$( cd "$NONGIT" && unset DOTENV_MISSING && load_dotenv --root "$MISSING_ROOT" DOTENV_MISSING; rc=$?; printf '%s|%s' "${DOTENV_MISSING:-<unset>}" "$rc" )
assert_eq "T26 missing .env fails open" "<unset>|0" "$out"

# T27: requested keys that match load_dotenv's own local names still load.
printf 'root=ROOTVAL\nkeys=KEYSVAL\nenvfile=ENVFILEVAL\nkey=KEYVAL\nline=LINEVAL\nval=VALVAL\npending=PENDINGVAL\nDOTENV_LOCAL_CONTROL=CONTROLVAL\n' > "$REPO/.env"
got=$( cd "$REPO" && unset root keys envfile key line val pending DOTENV_LOCAL_CONTROL && load_dotenv root keys envfile key line val pending DOTENV_LOCAL_CONTROL && printf '%s|%s|%s|%s|%s|%s|%s|%s' "${root:-<unset>}" "${keys:-<unset>}" "${envfile:-<unset>}" "${key:-<unset>}" "${line:-<unset>}" "${val:-<unset>}" "${pending:-<unset>}" "${DOTENV_LOCAL_CONTROL:-<unset>}" )
assert_eq "T27 local-name keys load" "ROOTVAL|KEYSVAL|ENVFILEVAL|KEYVAL|LINEVAL|VALVAL|PENDINGVAL|CONTROLVAL" "$got"

# T28: an unquoted trailing ` #…` comment is stripped. The fixture
# line is `.env.example`'s JIRA_PROJECT_KEY verbatim — the one the commit-msg
# gate builds its ticket pattern from. Before this, every machine installed from
# .env.example ran the gate with the pattern
# `HIMMEL   # default project for jira ops-[0-9]+`, which nothing can match.
printf 'JIRA_PROJECT_KEY=HIMMEL                            # default project for jira ops\n' > "$REPO/.env"
got=$( cd "$REPO" && unset JIRA_PROJECT_KEY && load_dotenv JIRA_PROJECT_KEY && printf '<%s>' "$JIRA_PROJECT_KEY" )
assert_eq "T28 inline comment is stripped (.env.example:64 verbatim)" "<HIMMEL>" "$got"

# T28b: a single space before the `#` is enough — the comment marker is
# whitespace-then-hash, not a wide gutter.
printf 'DOTENV_C1=value #comment\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_C1 && load_dotenv DOTENV_C1 && printf '<%s>' "$DOTENV_C1" )
assert_eq "T28b one space before # is a comment" "<value>" "$got"

# T29 NEGATIVE CONTROL: an UNSPACED `#` is part of the value, not a comment —
# the dotenv convention, and the reason a URL fragment survives. Without this
# case a loader that stripped from the first `#` anywhere would pass T28.
printf 'DOTENV_URL=http://x/#frag\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_URL && load_dotenv DOTENV_URL && printf '<%s>' "$DOTENV_URL" )
assert_eq "T29 unspaced # stays in the value" "<http://x/#frag>" "$got"

# T29b NEGATIVE CONTROL: a `#` inside quotes is data even with a space before it.
# The surrounding quotes are NOT stripped — that is pre-existing behaviour this
# change deliberately leaves alone (quote handling is separate).
printf 'DOTENV_TOKEN="abc #def"\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_TOKEN && load_dotenv DOTENV_TOKEN && printf '<%s>' "$DOTENV_TOKEN" )
assert_eq "T29b quoted # is data" '<"abc #def">' "$got"

# T29c: a comment AFTER a quoted value is still a comment.
printf "DOTENV_QC='a b' # trailing note\n" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_QC && load_dotenv DOTENV_QC && printf '<%s>' "$DOTENV_QC" )
assert_eq "T29c comment after a quoted value is stripped" "<'a b'>" "$got"

# T29d: an unterminated quote keeps the whole remainder — never guess where a
# broken value ends.
printf 'DOTENV_UQ="abc # def\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_UQ && load_dotenv DOTENV_UQ && printf '<%s>' "$DOTENV_UQ" )
assert_eq "T29d unterminated quote keeps the remainder" '<"abc # def>' "$got"

# T30: a comment-free value is byte-identical to before — the change must be
# invisible to every key that carries no `#`.
printf 'DOTENV_PLAIN=a b  c\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_PLAIN && load_dotenv DOTENV_PLAIN && printf '<%s>' "$DOTENV_PLAIN" )
assert_eq "T30 comment-free value is unchanged" "<a b  c>" "$got"

# T30b: a value that is ENTIRELY a comment resolves to empty rather than to the
# comment text.
printf 'DOTENV_ONLYC=  # nothing here\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ONLYC && load_dotenv DOTENV_ONLYC && printf '<%s>' "$DOTENV_ONLYC" )
assert_eq "T30b comment-only value is empty" "<>" "$got"

# T31 (codex-2): an apostrophe in an UNQUOTED value is DATA, not a quote open —
# a value is quoted only when it BEGINS with a quote. Without this rule the
# apostrophe opened quote-mode and never closed, so the trailing comment was
# never stripped.
printf "DOTENV_APOS=don't # note\n" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_APOS && load_dotenv DOTENV_APOS && printf '<%s>' "$DOTENV_APOS" )
assert_eq "T31 apostrophe in unquoted value is data, comment still stripped" "<don't>" "$got"

# T32 (codex-2): a backslash-escaped quote inside a quoted value does NOT close
# it, so the `#` after it stays inside the (still-open) quote and the value is
# kept WHOLE. Before this fix the escaped quote was read as the close and the
# value was truncated — data loss on a secret-bearing path.
printf 'DOTENV_ESCQ="abc \\" # data"\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ESCQ && load_dotenv DOTENV_ESCQ && printf '<%s>' "$DOTENV_ESCQ" )
assert_eq 'T32 escaped quote does not close, value kept whole' '<"abc \" # data">' "$got"

# T33: a comment after a properly CLOSED quoted value is still stripped — the
# positive control paired with T32 (an escape must not disable stripping
# generally, only for a genuinely escaped quote).
printf 'DOTENV_QCOM="abc" # note\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_QCOM && load_dotenv DOTENV_QCOM && printf '<%s>' "$DOTENV_QCOM" )
assert_eq 'T33 comment after a closed quoted value is stripped' '<"abc">' "$got"

# T34: leading whitespace before the opening quote is skipped before the
# quote-start check runs — an inner `#` stays data (still inside the quote)
# and the trailing comment after the quote closes is still stripped.
printf 'DOTENV_LWSQ=   "abc # def" # trail\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_LWSQ && load_dotenv DOTENV_LWSQ && printf '<%s>' "$DOTENV_LWSQ" )
assert_eq "T34 leading whitespace before opening quote is skipped" '<"abc # def">' "$got"

# T35: inside a SINGLE-quoted value a backslash is a LITERAL
# character, not an escape — shell/dotenv convention. A trailing-backslash
# Windows path like 'C:\' must still close on the real closing quote; escaping
# applies only inside DOUBLE quotes (T32). Built via an intermediate variable
# so bash's own quote parsing (not printf's format-string escapes) produces
# the literal backslash.
bsq_line="DOTENV_BSQ='C:\\' # note"
printf '%s\n' "$bsq_line" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_BSQ && load_dotenv DOTENV_BSQ && printf '<%s>' "$DOTENV_BSQ" )
assert_eq "T35 single-quoted trailing backslash is literal, comment stripped" "<'C:\\'>" "$got"

# T36: a backslash NOT at the end of a single-quoted value is data too.
bsq_line="DOTENV_BSQ2='a\\b' # note"
printf '%s\n' "$bsq_line" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_BSQ2 && load_dotenv DOTENV_BSQ2 && printf '<%s>' "$DOTENV_BSQ2" )
assert_eq "T36 single-quoted mid-value backslash is literal" "<'a\\b'>" "$got"

# ── himmelctl-cache-dir-first fallback ──────────────────────
# When the install prefix is read-only (e.g. a packaged /usr/share tree), the
# adopter path can't write an in-tree .env, so it lands under the himmelctl
# cache dir instead. Readers must check there FIRST, then fall back to the
# git-resolved root — so a writable clone's in-tree .env still wins when no
# cache-dir .env exists.

# T37: a cache-dir .env is found even when the in-tree root has none (the
# read-only-prefix case). CACHE-side value: DOTENV_CACHE.
CACHEDIR="$TMP/cache-himmel"
mkdir -p "$CACHEDIR"
printf 'DOTENV_CACHE=from-cache-dir\n' > "$CACHEDIR/.env"
rm -f "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_CACHE && HIMMELCTL_CACHE_DIR="$CACHEDIR" load_dotenv DOTENV_CACHE && printf '%s' "${DOTENV_CACHE:-<unset>}" )
assert_eq "T37 cache-dir .env found when in-tree root has none" "from-cache-dir" "$got"

# T38: a cache-dir .env WINS over an in-tree .env (new place first).
printf 'DOTENV_CACHE=from-in-tree\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_CACHE && HIMMELCTL_CACHE_DIR="$CACHEDIR" load_dotenv DOTENV_CACHE && printf '%s' "${DOTENV_CACHE:-<unset>}" )
assert_eq "T38 cache-dir .env wins over in-tree" "from-cache-dir" "$got"

# T39: no cache-dir .env → falls back to the in-tree root, byte-for-byte
# (existing writable clones are unaffected).
EMPTYCACHE="$TMP/cache-empty"
mkdir -p "$EMPTYCACHE"
printf 'DOTENV_CACHE=from-in-tree\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_CACHE && HIMMELCTL_CACHE_DIR="$EMPTYCACHE" load_dotenv DOTENV_CACHE && printf '%s' "${DOTENV_CACHE:-<unset>}" )
assert_eq "T39 no cache-dir .env falls back to in-tree" "from-in-tree" "$got"

# T40: an explicit --root is HERMETIC — never consults the cache dir at all.
printf 'DOTENV_CACHE=from-root-flag\n' > "$ROOTDIR/.env"
got=$( cd "$NONGIT" && unset DOTENV_CACHE && HIMMELCTL_CACHE_DIR="$CACHEDIR" load_dotenv --root "$ROOTDIR" DOTENV_CACHE && printf '%s' "${DOTENV_CACHE:-<unset>}" )
assert_eq "T40 --root bypasses the cache dir entirely" "from-root-flag" "$got"
rm -f "$ROOTDIR/.env"

# ── secret keys through the resolver (scripts/lib/himmel-secrets) ──────────
# TEST_KR_TOKEN is secret-class and fake. Default items carry scope=user; a
# project override carries project=<primary checkout path>.
if [ "$(uname -s)" = Darwin ]; then
    echo "SKIP K1-K8:the macOS Keychain backend is a follow-up; the resolver skips the keyring on Darwin"
else
PROJ=$(cd "$REPO" && pwd -P)

# K1: a key served by the stub keyring reaches load_dotenv with no .env present.
kreset
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tfake-keyring-value\n' >"$KSTUB_STORE"
rm -f "$REPO/.env"
got=$( cd "$REPO" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K1 keyring serves a secret key with no .env" "fake-keyring-value" "$got"

# K2: a locked keyring returns within 3 s with one 'keyring locked' line, makes
# no lookup (a lookup on a locked collection raises the unlock prompt) and no
# Unlock call.
kreset
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tfake-keyring-value\n' >"$KSTUB_STORE"
SECONDS=0
got=$( cd "$REPO" && export KSTUB_LOCKED=true && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>"$TMP/k2.err"; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
k2_secs=$SECONDS
assert_eq "K2 locked keyring serves nothing" "<unset>" "$got"
assert_eq "K2 one 'keyring locked' line" "1" "$(grep -c 'keyring locked' "$TMP/k2.err")"
assert_eq "K2 no lookup and no unlock on a locked keyring" "0" "$(grep -c 'secret-tool\|unlock-called' "$KSTUB_LOG")"
assert_eq "K2 returns within 3 s" "yes" "$([ "$k2_secs" -le 3 ] && echo yes || echo "no (${k2_secs}s)")"

# K2b: a bus that never answers is cut off by the timeout and falls through.
kreset
SECONDS=0
got=$( cd "$REPO" && export KSTUB_HANG=1 && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
k2_secs=$SECONDS
assert_eq "K2b hung bus serves nothing" "<unset>" "$got"
assert_eq "K2b hung bus returns within 3 s" "yes" "$([ "$k2_secs" -le 3 ] && echo yes || echo "no (${k2_secs}s)")"

# K3: a cron-shaped env (env -i, no DBUS_SESSION_BUS_ADDRESS) finds the bus at
# <runtime dir>/bus. The runtime dir is the test seam; the socket is a scratch one.
RT="$TMP/rt"
mkdir -p "$RT"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$RT/bus"
kreset
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tfake-keyring-value\n' >"$KSTUB_STORE"
# shellcheck disable=SC2016 # the body expands in the child shell
got=$( cd "$REPO" && env -i HOME="$HOME" PATH="$KBIN:/usr/bin:/bin" KSTUB_STORE="$KSTUB_STORE" KSTUB_LOG="$KSTUB_LOG" HIMMEL_SECRETS_RUNTIME_DIR="$RT" \
    bash -c '. "$1"; load_dotenv TEST_KR_TOKEN 2>/dev/null; printf "%s" "${TEST_KR_TOKEN:-<unset>}"' _ "$LIB" )
assert_eq "K3 cron-shaped env resolves through the runtime-dir bus" "fake-keyring-value" "$got"
assert_eq "K3 the lookup used the runtime-dir bus" "yes" "$(grep -q "secret-tool\[unix:path=$RT/bus\]" "$KSTUB_LOG" && echo yes || echo no)"

# K4: backend order — process env, then $CREDENTIALS_DIRECTORY, then the
# keyring, then .env. A key served from .env prints one DEPRECATED line.
CRED="$TMP/creds"
mkdir -p "$CRED"
printf 'from-credentials\n' >"$CRED/TEST_KR_TOKEN"
kreset
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tfrom-keyring\n' >"$KSTUB_STORE"
printf 'TEST_KR_TOKEN=from-dotenv\n' >"$REPO/.env"
got=$( cd "$REPO" && export TEST_KR_TOKEN=from-env CREDENTIALS_DIRECTORY="$CRED" && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "$TEST_KR_TOKEN" )
assert_eq "K4 process env beats every backend" "from-env" "$got"
got=$( cd "$REPO" && export CREDENTIALS_DIRECTORY="$CRED" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K4 CREDENTIALS_DIRECTORY beats the keyring" "from-credentials" "$got"
got=$( cd "$REPO" && unset TEST_KR_TOKEN CREDENTIALS_DIRECTORY && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K4 keyring beats .env" "from-keyring" "$got"
kreset
got=$( cd "$REPO" && unset TEST_KR_TOKEN CREDENTIALS_DIRECTORY && load_dotenv TEST_KR_TOKEN 2>"$TMP/k4.err"; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K4 .env serves a key the keyring lacks" "from-dotenv" "$got"
assert_eq "K4 one DEPRECATED line for a secret from .env" "1" "$(grep -c 'DEPRECATED' "$TMP/k4.err")"
assert_eq "K4 the DEPRECATED line names the key, never the value" "1|0" "$(grep -c 'TEST_KR_TOKEN' "$TMP/k4.err")|$(grep -c 'from-dotenv' "$TMP/k4.err")"
rm -f "$REPO/.env"

# K5: a project-scoped item for this repo (keyed by the primary checkout, so a
# worktree matches its primary) beats the user default; with no override for
# this repo the default serves, even when another project's override exists.
kreset
printf 'service=himmel key=TEST_KR_TOKEN project=/elsewhere/other-repo\tother-project\n' >"$KSTUB_STORE"
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tuser-default\n' >>"$KSTUB_STORE"
got=$( cd "$REPO" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K5 no override for this repo: the user default serves" "user-default" "$got"
printf 'service=himmel key=TEST_KR_TOKEN project=%s\tproject-value\n' "$PROJ" >>"$KSTUB_STORE"
got=$( cd "$REPO" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K5 this repo's override beats the user default" "project-value" "$got"
KWT="$TMP/k5-wt"
git -C "$REPO" worktree add -q "$KWT" -b k5-branch
got=$( cd "$KWT" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>/dev/null && printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K5 a worktree matches its primary's override" "project-value" "$got"
git -C "$REPO" worktree remove --force "$KWT" 2>/dev/null || true

# K6: a git-tracked .env is refused with one line and serves no secret.
TREPO="$TMP/tracked"
mkdir -p "$TREPO"
git -C "$TREPO" init --quiet
git -C "$TREPO" config user.email t@example.com
git -C "$TREPO" config user.name tester
printf 'TEST_KR_TOKEN=tracked-value\n' >"$TREPO/.env"
git -C "$TREPO" add .env
git -C "$TREPO" commit -q -m tracked
kreset
got=$( cd "$TREPO" && unset TEST_KR_TOKEN && load_dotenv TEST_KR_TOKEN 2>"$TMP/k6.err"; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K6 a tracked .env serves no secret" "<unset>" "$got"
assert_eq "K6 one refusal line" "1" "$(grep -c 'tracked by git' "$TMP/k6.err")"

# K7: config-class and policy-class keys never touch the resolver.
kreset
printf 'HANDOVER_DIR=/c/h\nCR_REQUIRE_CROSS_MODEL=1\n' >"$REPO/.env"
( cd "$REPO" && unset HANDOVER_DIR CR_REQUIRE_CROSS_MODEL && load_dotenv HANDOVER_DIR CR_REQUIRE_CROSS_MODEL 2>/dev/null )
assert_eq "K7 config and policy keys make no keyring call" "" "$(cat "$KSTUB_LOG")"
rm -f "$REPO/.env"

# K8: sourced by a slash-less name from its own directory, the loader still
# finds the resolver beside it.
K8LIB="$TMP/k8/scripts/lib"
mkdir -p "$K8LIB"
cp "$LIB" "$(dirname "$LIB")/himmel-secrets" "$K8LIB/"
kreset
printf 'service=himmel key=TEST_KR_TOKEN scope=user\tfake-keyring-value\n' >"$KSTUB_STORE"
got=$( cd "$K8LIB" && unset TEST_KR_TOKEN && . load-dotenv.sh && load_dotenv --root "$REPO" TEST_KR_TOKEN 2>/dev/null; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K8 a slash-less source still reaches the resolver" "fake-keyring-value" "$got"

# K9: an unlocked keyring holding none of the requested secrets must fall
# through to .env, even under a caller's set -e.
kreset
printf 'TEST_KR_TOKEN=env-value\n' >"$REPO/.env"
got=$( unset TEST_KR_TOKEN; set -euo pipefail; cd "$REPO" && load_dotenv --root "$REPO" TEST_KR_TOKEN 2>/dev/null; printf '%s' "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "K9 set -e caller survives a keyring miss and reads .env" "env-value" "$got"
rm -f "$REPO/.env"
fi

# C1: HIMMEL_CONFIG_DIR redirects the himmel.conf read; with it unset the
# default is $HOME/.himmel.
mkdir -p "$TMP/c1-config"
printf 'HANDOVER_DIR=/c1/from-conf\n' >"$TMP/c1-config/himmel.conf"
rm -f "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && HIMMEL_CONFIG_DIR="$TMP/c1-config" load_dotenv HANDOVER_DIR 2>/dev/null; printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "C1 HIMMEL_CONFIG_DIR redirects the himmel.conf read" "/c1/from-conf" "$got"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR 2>/dev/null; printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "C1 an empty config dir leaves HANDOVER_DIR unset" "<unset>" "$got"
got=$( unset HIMMEL_CONFIG_DIR; _himmel_config_dir )
assert_eq "C1 the default config dir is \$HOME/.himmel" "$HOME/.himmel" "$got"

# C2: HIMMEL_CONFIG_DIR never redirects the gate-policy file; load_policy and
# the policy layer of load_dotenv read $HOME/.himmel/config.json only.
mkdir -p "$TMP/c2-home/.himmel" "$TMP/c2-config"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1"}}\n' >"$TMP/c2-home/.himmel/config.json"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"0"}}\n' >"$TMP/c2-config/config.json"
got=$( cd "$REPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/c2-home" HIMMEL_CONFIG_DIR="$TMP/c2-config" load_policy --root "$REPO" CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" )
assert_eq "C2 load_policy ignores HIMMEL_CONFIG_DIR" "1" "$got"
got=$( cd "$REPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/c2-home" HIMMEL_CONFIG_DIR="$TMP/c2-config" load_dotenv CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" )
assert_eq "C2 load_dotenv policy layer ignores HIMMEL_CONFIG_DIR" "1" "$got"

# C3: a suite that blanks HANDOVER_DIR sources testlib-config-isolation.sh; a
# station-like $HOME/.himmel/himmel.conf naming a live root is then not read.
mkdir -p "$TMP/c3-home/.himmel" "$TMP/c3-live"
printf 'HANDOVER_DIR=%s\n' "$TMP/c3-live" >"$TMP/c3-home/.himmel/himmel.conf"
rm -f "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR HIMMEL_CONFIG_DIR && HOME="$TMP/c3-home" load_dotenv HANDOVER_DIR 2>/dev/null; printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "C3 control: the station conf supplies HANDOVER_DIR" "$TMP/c3-live" "$got"
got=$( cd "$REPO" && unset HANDOVER_DIR HIMMEL_CONFIG_DIR && HOME="$TMP/c3-home" && . "$(dirname "$LIB")/testlib-config-isolation.sh" && isolate_himmel_config "$TMP/c3-suite" && printf 'isolated ' && load_dotenv HANDOVER_DIR 2>/dev/null && printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "C3 isolate_himmel_config keeps the station conf out" "isolated <unset>" "$got"

# P1-P8: the per-project override, <primary checkout>/.himmel/project.conf.
PREPO="$TMP/p-repo"
mkdir -p "$PREPO/.himmel" "$TMP/p-config" "$TMP/p-home/.himmel"
git -C "$PREPO" init --quiet
git -C "$PREPO" config user.email t@example.com
git -C "$PREPO" config user.name tester
git -C "$PREPO" commit --allow-empty -q -m init
PCONF="$PREPO/.himmel/project.conf"
printf 'CR_PROFILE=p1-from-user\nHANDOVER_DIR=/p7/from-user\n' >"$TMP/p-config/himmel.conf"

# P1: a project-scope key in the project file beats himmel.conf; the process
# env still beats the project file.
printf 'CR_PROFILE=p1-from-project\n' >"$PCONF"
got=$( cd "$PREPO" && unset CR_PROFILE && HIMMEL_CONFIG_DIR="$TMP/p-config" load_dotenv CR_PROFILE 2>/dev/null; printf '%s' "${CR_PROFILE:-<unset>}" )
assert_eq "P1 the project file beats himmel.conf for a project-scope key" "p1-from-project" "$got"
got=$( cd "$PREPO" && export CR_PROFILE=p1-live && HIMMEL_CONFIG_DIR="$TMP/p-config" load_dotenv CR_PROFILE 2>/dev/null; printf '%s' "${CR_PROFILE:-<unset>}" )
assert_eq "P1 the process env beats the project file" "p1-live" "$got"

# P2: a project value looser than the user's is ignored, with one notice.
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1","ARMAUTOMERGE":"0"}}\n' >"$TMP/p-home/.himmel/config.json"
printf 'CR_REQUIRE_CROSS_MODEL=0\nCR_FLOOR_FALLBACK=claude-only\nARMAUTOMERGE=1\n' >"$PCONF"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE && HOME="$TMP/p-home" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE 2>"$TMP/p2.err"; printf '%s|%s|%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" "${CR_FLOOR_FALLBACK:-<unset>}" "${ARMAUTOMERGE:-<unset>}" )
assert_eq "P2 the project file cannot loosen a policy key" "1|<unset>|0|3" "$got|$(grep -c 'may only tighten' "$TMP/p2.err")"

# P3: a project value stricter than the user's wins, in the gate reader and in
# load_dotenv (pr-check-env.sh reads the policy keys through it).
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"0","CR_FLOOR_FALLBACK":"claude-only","ARMAUTOMERGE":"1"}}\n' >"$TMP/p-home/.himmel/config.json"
printf 'CR_REQUIRE_CROSS_MODEL=1\nCR_FLOOR_FALLBACK=off\nARMAUTOMERGE=0\n' >"$PCONF"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE && HOME="$TMP/p-home" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK ARMAUTOMERGE 2>/dev/null; printf '%s|%s|%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" "${CR_FLOOR_FALLBACK:-<unset>}" "${ARMAUTOMERGE:-<unset>}" )
assert_eq "P3 the project file tightens a policy key (load_policy)" "1|off|0" "$got"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/p-home" load_dotenv --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" )
assert_eq "P3 the project file tightens a policy key (load_dotenv)" "1" "$got"
got=$( cd "$PREPO" && export CR_REQUIRE_CROSS_MODEL=0 && HOME="$TMP/p-home" load_dotenv --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "${CR_REQUIRE_CROSS_MODEL:-<unset>}" )
assert_eq "P3 the project file tightens a policy key the process env set loose (load_dotenv)" "1" "$got"

# P4: a secret key in the project file is never loaded, while a project-scope
# key beside it is.
kreset
printf 'CR_PROFILE=p4-from-project\nTEST_KR_TOKEN=planted-in-project\n' >"$PCONF"
got=$( cd "$PREPO" && unset CR_PROFILE TEST_KR_TOKEN && load_dotenv CR_PROFILE TEST_KR_TOKEN 2>/dev/null; printf '%s|%s' "${CR_PROFILE:-<unset>}" "${TEST_KR_TOKEN:-<unset>}" )
assert_eq "P4 a secret in the project file is not loaded" "p4-from-project|<unset>" "$got"

# P5: a worktree reads its primary checkout's project file, not its own copy.
printf 'CR_PROFILE=p5-from-primary\n' >"$PCONF"
PWT="$TMP/p-wt"
git -C "$PREPO" worktree add -q "$PWT" -b p5-branch
mkdir -p "$PWT/.himmel"
printf 'CR_PROFILE=p5-from-worktree\n' >"$PWT/.himmel/project.conf"
got=$( cd "$PWT" && unset CR_PROFILE && load_dotenv CR_PROFILE 2>/dev/null; printf '%s' "${CR_PROFILE:-<unset>}" )
assert_eq "P5 a worktree reads the primary checkout's project file" "p5-from-primary" "$got"
git -C "$PREPO" worktree remove --force "$PWT" 2>/dev/null || true

# P6: a project file that is a dangling symlink fails closed in the gate reader.
rm -f "$PCONF"
ln -s "$TMP/p6-gone" "$PCONF"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/p-home" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>"$TMP/p6.err"; printf '%s' "$?" )
assert_eq "P6 a dangling project-file symlink fails closed" "1|1" "$got|$(grep -c 'unreadable' "$TMP/p6.err")"
rm -f "$PCONF"

# P7: a station-scope key is never read from the project file, so a committed
# file cannot redirect HANDOVER_DIR, whether or not himmel.conf sets it.
printf 'HANDOVER_DIR=/p7/decoy\nLUNA_VAULT_PATH=/p7/decoy-vault\n' >"$PCONF"
got=$( cd "$PREPO" && unset HANDOVER_DIR && HIMMEL_CONFIG_DIR="$TMP/p-config" load_dotenv HANDOVER_DIR 2>/dev/null; printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "P7 a project HANDOVER_DIR cannot beat himmel.conf" "/p7/from-user" "$got"
got=$( cd "$PREPO" && unset LUNA_VAULT_PATH && HIMMEL_CONFIG_DIR="$TMP/p-config" load_dotenv LUNA_VAULT_PATH 2>/dev/null; printf '%s' "${LUNA_VAULT_PATH:-<unset>}" )
assert_eq "P7 a station key absent from himmel.conf is not served from the project file" "<unset>" "$got"

# P8: when the project file cannot be parsed (a directory, or awk failing),
# the gate reader fails closed instead of dropping the tightening.
rm -f "$PCONF"
mkdir -p "$PCONF"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/p-home" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "$?" )
assert_eq "P8 a project file that is a directory fails closed" "1" "$got"
rmdir "$PCONF"
printf 'CR_REQUIRE_CROSS_MODEL=1\n' >"$PCONF"
mkdir -p "$TMP/p8-bin"
printf '#!/bin/sh\nexit 2\n' >"$TMP/p8-bin/awk"
chmod +x "$TMP/p8-bin/awk"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/p-home" PATH="$TMP/p8-bin:$PATH" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>/dev/null; printf '%s' "$?" )
assert_eq "P8 a failing project-file extractor fails closed" "1" "$got"
rm -f "$PCONF"

# P9: a policy key written without "=" is not served, and says so once.
printf 'CR_REQUIRE_CROSS_MODEL 1\n' >"$PCONF"
got=$( cd "$PREPO" && unset CR_REQUIRE_CROSS_MODEL && HOME="$TMP/p-home" load_policy --root "$PREPO" CR_REQUIRE_CROSS_MODEL 2>"$TMP/p9.err"; printf '%s|%s' "$?" "${CR_REQUIRE_CROSS_MODEL:-<unset>}" )
assert_eq "P9 a policy key without = is reported, not silently dropped" "0|0|1" "$got|$(grep -c 'CR_REQUIRE_CROSS_MODEL.*no =' "$TMP/p9.err")"
rm -f "$PCONF"

# K: the plain-config keys resolve from himmel.conf when .env is empty and the
# process env is unset.
mkdir -p "$TMP/k-config"
for k in HIMMEL_REPO CLAUDE_HUD_ALLOW_EXTRA_CMD HIMMEL_WHERE_ARE_WE_ROLLUP_TTL \
    HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT HIMMEL_JIRA_NUDGE CR_APP CR_PUBLIC_REPO \
    CLAUDE_END_SESSION_WIKI SKILL_INDEX_DIR ALIBABA_ANTHROPIC_BASE_URL \
    ALIBABA_CODING_PLAN_BASE_URL ALIBABA_DASHSCOPE_BASE_URL ALIBABA_OPENAI_BASE_URL \
    JIRA_PROJECTS; do
    printf '%s=k-from-conf\n' "$k" >"$TMP/k-config/himmel.conf"
    got=$( cd "$REPO" && unset "$k" && HIMMEL_CONFIG_DIR="$TMP/k-config" load_dotenv "$k" 2>/dev/null; printf '%s' "${!k:-<unset>}" )
    assert_eq "K $k resolves from himmel.conf" "k-from-conf" "$got"
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All load-dotenv tests passed."
else
    echo "$FAILED load-dotenv test(s) failed."
    exit 1
fi
