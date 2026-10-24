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
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/portable-timeout.sh"
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

# --- 1b. BSD touch has no -d @N (macos-cadence log: "touch: out of range or illegal time specification") ---
mkdir -p "$SCRATCH/bsdbin"
REAL_TOUCH="$(command -v touch)"
cat > "$SCRATCH/bsdbin/touch" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -d) echo "touch: out of range or illegal time specification: YYYY-MM-DDThh:mm:SS[.frac][tz]" >&2; exit 1 ;; esac
done
exec "$REAL_TOUCH" "\$@"
EOF
chmod +x "$SCRATCH/bsdbin/touch"
OUT="$(PATH="$SCRATCH/bsdbin:$PATH" TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/clean.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "clean runner passes under a touch without -d" || bad "clean runner failed under BSD-style touch rc=$RC: $OUT"

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
probe="$SCRATCH/probe"; : > "$probe"; TZ=UTC touch -a -t 197001010000.00 "$probe"; TZ=UTC touch -m -t 197001010016.40 "$probe"
cat "$probe" >/dev/null
if [ "$(stat -c %X "$probe" 2>/dev/null || stat -f %a "$probe")" != 0 ]; then
  run_canary silent-read
  [ "$RC" -ne 0 ] && ok "silent read of .env fails the canary (atime tracked here)" || bad "silent read passed"
else
  echo "ok - SKIP silent read: this filesystem does not track atime (the touch -a row above covers the check)"
fi

# --- 5. a runner failure is a canary failure -----------------------------------
mkfx red 'echo boom; exit 1'
run_canary red
[ "$RC" -ne 0 ] && ok "runner failure propagates" || bad "runner failure swallowed"
OUT="$(HOME_CANARY_RUNNER_FAIL_OK=1 TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/red.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "RUNNER_FAIL_OK=1 downgrades a runner failure to a note" || bad "RUNNER_FAIL_OK=1 still failed rc=$RC: $OUT"
mkfx red-leak 'cat "$HOME/.env"; exit 1'
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

# --- 12. RUNNER_FAIL_OK=1 downgrades only a suite-failure exit (rc 1) ---------------
fail_ok() { OUT="$(HOME_CANARY_RUNNER_FAIL_OK=1 TMPDIR="$SCRATCH/tmp" timeout 60 bash "$CANARY" --runner "$SCRATCH/fx/$1.sh" 2>&1)"; RC=$?; }

mkfx rc1 'echo "suite red"; exit 1'
fail_ok rc1
[ "$RC" -eq 0 ] && ok "FAIL_OK=1 downgrades rc 1 to a note" || bad "FAIL_OK=1 rc 1 failed rc=$RC: $OUT"
case "$OUT" in *"NOTE runner exited rc=1"*) ok "rc 1 note names the exit code" ;; *) bad "rc 1 note missing: $OUT" ;; esac

for code in 2 3 4 5 6 96; do
  mkfx "rc$code" "echo aborted; exit $code"
  fail_ok "rc$code"
  [ "$RC" -ne 0 ] && ok "FAIL_OK=1 still fails runner rc $code" || bad "FAIL_OK=1 hid runner rc $code: $OUT"
done

mkfx rc137 'echo killed; exit 137'
fail_ok rc137
[ "$RC" -ne 0 ] && ok "FAIL_OK=1 still fails runner rc 137" || bad "FAIL_OK=1 hid runner rc 137: $OUT"
case "$OUT" in *"timed out"*) ok "rc 137 is named a timeout" ;; *) bad "rc 137 not named a timeout: $OUT" ;; esac

# Plain (no FAIL_OK) rc 1 still fails.
mkfx rc1-plain 'exit 1'
run_canary rc1-plain
[ "$RC" -ne 0 ] && ok "rc 1 without FAIL_OK fails" || bad "rc 1 without FAIL_OK passed"

# A real timeout under FAIL_OK=1: the runner ignores TERM, so timeout -k sends KILL (rc 137).
mkfx stubborn 'trap "" TERM; while :; do sleep 1; done'
OUT="$(HOME_CANARY_RUNNER_FAIL_OK=1 HOME_CANARY_TIMEOUT=1 TMPDIR="$SCRATCH/tmp" timeout 60 bash "$CANARY" --runner "$SCRATCH/fx/stubborn.sh" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "FAIL_OK=1 plus a TERM-ignoring hang fails (exit 1)" || bad "FAIL_OK=1 plus a hang gave rc=$RC: $OUT"
case "$OUT" in *"timed out"*) ok "TERM-ignoring hang is named a timeout" ;; *) bad "TERM-ignoring hang not named a timeout: $OUT" ;; esac

# --- 13. runner output goes to a file, not a pipe -------------------------------------
# A backgrounded child keeps the runner's stdout open; a pipe would hold the canary
# until the child exits, a file does not.
mkfx orphan 'sleep 20 & exit 0'
start=$SECONDS
OUT="$(TMPDIR="$SCRATCH/tmp" timeout 15 bash "$CANARY" --runner "$SCRATCH/fx/orphan.sh" 2>&1)"; RC=$?
elapsed=$((SECONDS - start))
[ "$RC" -eq 0 ] && [ "$elapsed" -lt 15 ] && ok "an orphan holding stdout does not hold the canary (${elapsed}s)" || bad "orphan stdout held the canary (rc=$RC, ${elapsed}s): $OUT"

# --- 14. a `pip install --user` tool still runs under the swapped HOME ----------------
# Fork-PR CI has no CI image, so pre-commit is a --user package whose Python user
# site follows $HOME; with HOME swapped the launcher dies with ModuleNotFoundError.
# The launcher below has the shape pip writes (shebang + `from <pkg>.main import
# main`); the stub package stands in for pre_commit so the row reproduces on a host
# that has the real one system-wide.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import site, sys; sys.exit(0 if site.ENABLE_USER_SITE else 1)' >/dev/null 2>&1; then
  INSTALL_HOME="$SCRATCH/install-home"
  OTHER_HOME="$SCRATCH/other-home"
  mkdir -p "$INSTALL_HOME/.local/bin" "$OTHER_HOME"
  USER_SITE="$(HOME="$INSTALL_HOME" PYTHONUSERBASE='' python3 -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$USER_SITE/himmel_stub_pc"
  : > "$USER_SITE/himmel_stub_pc/__init__.py"
  printf 'def main():\n    return 0\n' > "$USER_SITE/himmel_stub_pc/main.py"
  printf '#!/usr/bin/env python3\nimport sys\nfrom himmel_stub_pc.main import main\nif __name__ == "__main__":\n    sys.exit(main())\n' > "$INSTALL_HOME/.local/bin/stub-tool"
  chmod +x "$INSTALL_HOME/.local/bin/stub-tool"
  mkfx usersite '"'"$INSTALL_HOME"'/.local/bin/stub-tool" || exit 7; exit 0'
  OUT="$(HOME="$OTHER_HOME" PYTHONUSERBASE='' bash "$SCRATCH/fx/usersite.sh" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && grep -q 'ModuleNotFoundError' <<< "$OUT"; then
    ok "the --user launcher fixture dies under a different HOME (the fork-runner condition)"
  else
    bad "the --user launcher fixture does not reproduce the HOME-bound failure (rc=$RC): $OUT"
  fi
  OUT="$(HOME="$INSTALL_HOME" PYTHONUSERBASE='' TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/usersite.sh" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok "a --user installed tool still runs under the canary's swapped HOME" || bad "a --user installed tool broke under the canary (rc=$RC): $OUT"
  OUT="$(HOME="$INSTALL_HOME" PYTHONUSERBASE="$SCRATCH/elsewhere" TMPDIR="$SCRATCH/tmp" bash "$CANARY" --runner "$SCRATCH/fx/usersite.sh" 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] && ok "a caller-set PYTHONUSERBASE is kept, not overridden" || bad "the canary overrode the caller's PYTHONUSERBASE"
else
  echo "skip - python3 absent or its user site disabled, the --user launcher rows need it"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
