#!/usr/bin/env bash
# scripts/ci/test-home-canary.sh -- hermetic suite for scripts/ci/home-canary.sh.
#
# Each fixture is a tiny stand-in "runner" the canary is pointed at with
# --runner, so no real suite runs. The PR 2883 shape (a test that reads
# $HOME/.env) must FAIL the canary; a clean run must pass.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, GNU/BSD coreutils.
# shellcheck disable=SC2015,SC2016 # fixtures are literal shell text; ok/bad never fail
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CANARY="$ROOT/scripts/ci/home-canary.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

SCRATCH="$(mktemp -d)" || { echo "FAIL - cannot allocate scratch dir" >&2; exit 1; }
: "${SCRATCH:?}"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/tmp" "$SCRATCH/fx" || exit 1

# A fixture runner: $1 = name, remaining args = body (written verbatim).
mkfx() {
  local name="$1"; shift
  printf '#!/usr/bin/env bash\n%s\n' "$*" > "$SCRATCH/fx/$name.sh"
}

# Run the canary against a fixture; sets RC and OUT. TMPDIR is pinned so the
# cleanup row can look for leftovers.
run_canary() {
  OUT="$(TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/$1.sh" "${@:2}" 2>&1)"
  RC=$?
}

if [ ! -f "$CANARY" ]; then
  bad "scripts/ci/home-canary.sh does not exist"
  echo "$fails failed" >&2
  exit 1
fi

# --- 1. clean fixture passes -------------------------------------------------
mkfx clean 'echo "suite ok"; exit 0'
run_canary clean
[ "$RC" -eq 0 ] && ok "clean runner passes" || bad "clean runner failed rc=$RC: $OUT"

# --- 2. the PR 2883 shape: a test that cats $HOME/.env -------------------------
mkfx cat-env 'cat "$HOME/.env"; exit 0'
run_canary cat-env
[ "$RC" -ne 0 ] && ok "runner that cats \$HOME/.env fails the canary" || bad "cat \$HOME/.env passed the canary"
case "$OUT" in *"honeytoken"*) ok "failure names the honeytoken leak" ;; *) bad "failure message lacks 'honeytoken': $OUT" ;; esac
# The token itself must not be echoed back by the canary's own diagnostics.
tok="$(printf '%s\n' "$OUT" | grep -o 'hc-[0-9a-f]\{16,\}' | head -1)"
[ -z "$tok" ] && ok "canary diagnostics redact the token" || bad "canary diagnostics echo the token ($tok)"

# --- 3. USERPROFILE points at the sandbox too ----------------------------------
mkfx cat-userprofile 'cat "$USERPROFILE/.env"; exit 0'
run_canary cat-userprofile
[ "$RC" -ne 0 ] && ok "USERPROFILE/.env read fails the canary" || bad "USERPROFILE/.env read passed"

# --- 4. an access that does not print is caught by the atime check -------------
mkfx touch-env 'touch -a "$HOME/.env"; exit 0'
run_canary touch-env
[ "$RC" -ne 0 ] && ok "access-time bump on .env fails the canary" || bad "atime bump on .env passed"

# A real silent read only registers where the filesystem tracks atime.
mkfx silent-read 'cat "$HOME/.env" >/dev/null; exit 0'
probe="$SCRATCH/probe"; : > "$probe"; touch -a -d @0 "$probe"; touch -m -d @1000 "$probe"
cat "$probe" >/dev/null
if [ "$(stat -c %X "$probe" 2>/dev/null || stat -f %a "$probe")" != 0 ]; then
  run_canary silent-read
  [ "$RC" -ne 0 ] && ok "silent read of .env fails the canary (atime tracked here)" || bad "silent read passed"
else
  echo "ok - SKIP silent read: this filesystem does not track atime (the touch -a row above covers the check)"
fi

# --- 5. a runner failure is a canary failure -----------------------------------
mkfx red 'echo boom; exit 3'
run_canary red
[ "$RC" -ne 0 ] && ok "runner failure propagates" || bad "runner failure swallowed"
OUT="$(HOME_CANARY_RUNNER_FAIL_OK=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/red.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "RUNNER_FAIL_OK=1 downgrades a runner failure to a note" || bad "RUNNER_FAIL_OK=1 still failed rc=$RC: $OUT"
mkfx red-leak 'cat "$HOME/.env"; exit 3'
OUT="$(HOME_CANARY_RUNNER_FAIL_OK=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/red-leak.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "RUNNER_FAIL_OK=1 still fails a leak" || bad "RUNNER_FAIL_OK=1 hid a leak"

# --- 6. bounded runtime ----------------------------------------------------------
mkfx slow 'sleep 30; exit 0'
OUT="$(HOME_CANARY_TIMEOUT=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/slow.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a hung runner is cut off and fails" || bad "hung runner passed"
case "$OUT" in *"timed out"*) ok "timeout is named in the failure" ;; *) bad "timeout not named: $OUT" ;; esac

# --- 7. HOME inside the runner is the sandbox, not the caller's ------------------
mkfx home-is-temp 'case "$HOME" in "'"$HOME"'") echo "HOME not redirected" >&2; exit 9 ;; esac; [ -f "$HOME/.env" ] || exit 8; exit 0'
run_canary home-is-temp
[ "$RC" -eq 0 ] && ok "runner sees a redirected HOME holding a .env" || bad "HOME not redirected (rc=$RC): $OUT"

# --- 8. runner args are forwarded -------------------------------------------------
mkfx args 'printf "%s\n" "$@" > "'"$SCRATCH"'/args.out"; exit 0'
run_canary args --impacted a..b
if [ "$RC" -eq 0 ] && [ "$(cat "$SCRATCH/args.out")" = "--impacted
a..b" ]; then ok "runner args forwarded verbatim"; else bad "args not forwarded (rc=$RC): $(cat "$SCRATCH/args.out" 2>/dev/null)"; fi

# --- 9. the temp sandbox is removed, pass or fail ----------------------------------
left="$(find "$SCRATCH/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
[ "$left" -eq 0 ] && ok "no sandbox left behind in TMPDIR" || bad "$left leftover entr(ies) in TMPDIR"

# --- 10. known ceiling: a hard-coded real-home path is not seen --------------------
# ponytail: the canary redirects $HOME only, so a suite that reads a literal
# /home/<user>/.env (or ~root) bypasses it; the static read-sink check and the
# judge cover that route, upgrade path is an fanotify/strace watch on the real home.
mkfx hardcoded 'cat /nonexistent-home-canary-path/.env 2>/dev/null; exit 0'
run_canary hardcoded
[ "$RC" -eq 0 ] && ok "known ceiling documented: hard-coded real-home path passes" || bad "hard-coded path row changed behaviour (rc=$RC)"

# --- 11. REQUIRE_ATIME fails closed where atime is not tracked ----------------------
if [ "$(stat -c %X "$probe" 2>/dev/null || stat -f %a "$probe")" = 0 ]; then
  OUT="$(HOME_CANARY_REQUIRE_ATIME=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/clean.sh" 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] && ok "REQUIRE_ATIME=1 fails when atime is untracked" || bad "REQUIRE_ATIME=1 passed on a noatime fs"
else
  OUT="$(HOME_CANARY_REQUIRE_ATIME=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/clean.sh" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok "REQUIRE_ATIME=1 passes where atime is tracked" || bad "REQUIRE_ATIME=1 failed on an atime fs: $OUT"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
