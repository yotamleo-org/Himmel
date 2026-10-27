#!/usr/bin/env bash
# test-himmelctl-path-shim.sh — hermetic coverage for the
# himmelctl launcher written by both `install` and `update`.
#
# Covers: checkout-targeted creation, idempotent rewrite, moved-checkout
# re-point, PATH-missing guidance without profile/PATH mutation, honest dry-run,
# and install self-application.

set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || fail "$wizard not found"
command -v node >/dev/null 2>&1 || fail "node required"
node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d -t himmelctl-path-shim.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bash_bin=$(winpath "$(command -v bash)")

build_update_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/himmelctl"
  cat > "$_d/scripts/himmel-update.sh" <<STUB
#!/usr/bin/env bash
printf 'update\n' >> "$_d/update-calls.log"
STUB
  chmod +x "$_d/scripts/himmel-update.sh"
  cat > "$_d/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
const fs = require('fs');
fs.appendFileSync(process.env.SHIM_CALL_LOG, `${process.env.SHIM_LABEL}:${process.argv.slice(2).join('|')}\n`);
STUB
}

run_update() {
  local _fixture="$1" _bin="$2" _path="$3"
  PATH="$_path" HIMMELCTL_BASH="$bash_bin" \
    HIMMELCTL_CACHE_DIR="$(winpath "$_fixture.himmelctl-cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_fixture.himmelctl-cache/luna-config.json")" \
    HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
    HIMMELCTL_BIN_DIR="$(winpath "$_bin")" \
    "$node_bin" "$wizard" update </dev/null 2>&1
}

# ── A: update creates a checkout-targeted POSIX launcher ────────────────────
fixtureA="$work/caseA-checkout"
binA="$work/shared-bin"
build_update_fixture "$fixtureA"
out=$(run_update "$fixtureA" "$binA" "$(winpath "$binA"):$PATH")
[ -f "$fixtureA/update-calls.log" ] || fail "caseA: update engine was not invoked"
[ -x "$binA/himmelctl" ] || fail "caseA: executable POSIX launcher missing"
[ -f "$binA/himmelctl.js" ] || fail "caseA: target loader missing"
grepq "$out" 'launcher ->' || fail "caseA: launcher write was not reported: $out"
SHIM_CALL_LOG="$(winpath "$work/shim-calls.log")" SHIM_LABEL=A \
  PATH="$(winpath "$binA"):$PATH" "$binA/himmelctl" alpha "two words"
[ "$(cat "$work/shim-calls.log")" = 'A:alpha|two words' ] \
  || fail "caseA: generated launcher did not dispatch to this checkout's bin.js"
echo "ok: caseA update creates a working checkout-targeted POSIX launcher"

# a `himmel` alias launcher sits beside himmelctl, so `himmel update`
# works in any shell (fish included) with no shell config.
[ -x "$binA/himmel" ] || fail "caseA2: executable himmel alias launcher missing"
SHIM_CALL_LOG="$(winpath "$work/shim-calls.log")" SHIM_LABEL=A2 \
  PATH="$(winpath "$binA"):$PATH" "$binA/himmel" update
[ "$(tail -n 1 "$work/shim-calls.log")" = 'A2:update' ] \
  || fail "caseA2: himmel alias did not dispatch to this checkout's bin.js"
echo "ok: caseA2 himmel alias launcher dispatches like himmelctl"

# ── B: re-run is byte-idempotent; moved checkout re-points the loader ───────
cp "$binA/himmelctl" "$work/himmelctl.before"
cp "$binA/himmelctl.js" "$work/himmelctl-js.before"
run_update "$fixtureA" "$binA" "$(winpath "$binA"):$PATH" >/dev/null
cmp -s "$work/himmelctl.before" "$binA/himmelctl" \
  || fail "caseB: idempotent re-run changed the POSIX wrapper"
cmp -s "$work/himmelctl-js.before" "$binA/himmelctl.js" \
  || fail "caseB: idempotent re-run changed the target loader"

fixtureB="$work/caseB-moved-checkout"
build_update_fixture "$fixtureB"
run_update "$fixtureB" "$binA" "$(winpath "$binA"):$PATH" >/dev/null
: > "$work/shim-calls.log"
SHIM_CALL_LOG="$(winpath "$work/shim-calls.log")" SHIM_LABEL=B \
  PATH="$(winpath "$binA"):$PATH" "$binA/himmelctl" moved
[ "$(cat "$work/shim-calls.log")" = 'B:moved' ] \
  || fail "caseB: moved checkout did not re-point the existing launcher"
grepq "$(cat "$binA/himmelctl.js")" 'caseB-moved-checkout' \
  || fail "caseB: loader does not name the moved checkout"
echo "ok: caseB re-run is idempotent and a moved checkout re-points in place"

# ── C: missing PATH prints a copy-paste instruction and mutates no profile ──
fixtureC="$work/caseC-checkout"
binC="$work/caseC-bin"
homeC="$work/caseC-home"
mkdir -p "$homeC"
build_update_fixture "$fixtureC"
printf 'profile-sentinel\n' > "$homeC/.profile"
printf 'bashrc-sentinel\n' > "$homeC/.bashrc"
before_path="$PATH"
out=$(HOME="$(winpath "$homeC")" USERPROFILE="$(winpath "$homeC")" run_update "$fixtureC" "$binC" "$PATH")
[ "$PATH" = "$before_path" ] || fail "caseC: parent PATH changed"
[ "$(cat "$homeC/.profile")" = 'profile-sentinel' ] || fail "caseC: .profile was mutated"
[ "$(cat "$homeC/.bashrc")" = 'bashrc-sentinel' ] || fail "caseC: .bashrc was mutated"
grepq "$out" 'is not on PATH' || fail "caseC: missing-PATH diagnostic absent: $out"
grepq "$out" 'export PATH=' || fail "caseC: exact POSIX PATH instruction absent: $out"
[ -f "$binC/himmelctl" ] || fail "caseC: launcher should still be written when PATH is missing"
echo "ok: caseC PATH-missing prints manual guidance and mutates neither PATH nor shell profiles"

# ── D: dry-run plans the launcher but writes and executes nothing ───────────
fixtureD="$work/caseD-checkout"
binD="$work/caseD-bin"
build_update_fixture "$fixtureD"
set +e
out=$(PATH="$PATH" HIMMELCTL_BASH="$bash_bin" \
  HIMMELCTL_CACHE_DIR="$(winpath "$fixtureD.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$fixtureD.himmelctl-cache/luna-config.json")" \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
  HIMMELCTL_BIN_DIR="$(winpath "$binD")" \
  "$node_bin" "$wizard" update --dry-run </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseD: dry-run exited $rc: $out"
grepq "$out" 'DRY: himmelctl launcher ->' || fail "caseD: launcher plan absent: $out"
grepq "$out" '(written to' && fail "caseD: dry-run claimed the launcher was written: $out"
[ ! -e "$binD" ] || fail "caseD: dry-run created the bin directory"
[ ! -f "$fixtureD/update-calls.log" ] || fail "caseD: dry-run executed the update engine"
echo "ok: caseD dry-run plans only — no update execution and no launcher files"

# ── F: install applies the same launcher after its executor succeeds ────────
fixtureF="$work/caseF-checkout"
binF="$work/caseF-bin"
homeF="$work/caseF-home"
stubF="$work/caseF-tools"
mkdir -p "$fixtureF/scripts/himmelctl" "$homeF" "$stubF"
cat > "$fixtureF/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
const fs = require('fs');
fs.appendFileSync(process.env.SHIM_CALL_LOG, `install:${process.argv.slice(2).join('|')}\n`);
STUB
# ONE execution engine now — deriveCommand always targets
# adopt.sh, with the dev overlay's setup.sh as an ADDITIONAL step
# on top. A silent no-op (never touching INSTALL_CALL_LOG) so the assertion
# below still sees exactly the overlay's own 'setup' line.
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureF/scripts/adopt.sh"
chmod +x "$fixtureF/scripts/adopt.sh"
cat > "$fixtureF/scripts/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'setup\n' >> "$INSTALL_CALL_LOG"
STUB
chmod +x "$fixtureF/scripts/setup.sh"
cat > "$work/contributor-profile.json" <<'JSON'
{
  "role": "contributor",
  "tier": "standard",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
for tool in bash git jq python3 npm; do link_hermetic_tool "$tool" "$stubF"; done
install_path="$(winpath "$binF"):$(winpath "$stubF"):$PATH"
set +e
out=$(PATH="$install_path" HOME="$(winpath "$homeF")" USERPROFILE="$(winpath "$homeF")" \
  XDG_STATE_HOME="$(winpath "$work/caseF-state")" \
  HIMMELCTL_BASH="$bash_bin" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/caseF-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseF-cache")-luna-config.json" \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
  HIMMELCTL_BIN_DIR="$(winpath "$binF")" \
  INSTALL_CALL_LOG="$(winpath "$work/install-calls.log")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$work/contributor-profile.json")" \
  </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: install exited $rc: $out"
[ "$(cat "$work/install-calls.log")" = 'setup' ] || fail "caseF: install executor did not run"
[ -x "$binF/himmelctl" ] || fail "caseF: install did not apply the launcher"
SHIM_CALL_LOG="$(winpath "$work/install-shim-calls.log")" \
  PATH="$(winpath "$binF"):$PATH" "$binF/himmelctl" status
[ "$(cat "$work/install-shim-calls.log")" = 'install:status' ] \
  || fail "caseF: install-applied launcher does not target this checkout"
echo "ok: caseF successful install self-applies the same launcher"

# ── F2: install creates the himmel XDG state home + bus at 0700 ─
# Its own XDG_STATE_HOME (caseF-state), never the real one; the fake HOME must
# stay free of .local/state.
mode_f2() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
[ "$(mode_f2 "$work/caseF-state/himmel")" = 700 ] || fail "caseF2: himmel state dir is not 0700"
[ "$(mode_f2 "$work/caseF-state/himmel/bus")" = 700 ] || fail "caseF2: himmel/bus is not 0700"
[ ! -e "$homeF/.local/state" ] || fail "caseF2: install wrote the fake HOME's .local/state"
echo "ok: caseF2 install creates the himmel XDG state home and bus at 0700"

# ── G: ownership marker — refuse unmarked/symlink collisions, replace marked, ─
# ── atomic tmp+rename. ───────────────────────────────────────────────────────
# These cases deliberately exercise FAILURE paths (refusals) and assert the rc
# explicitly with `[ ] || fail`, so run them under errexit OFF — caseF above
# leaves `set -e` on, under which an expected non-zero `out=$(run_update …)`
# would abort silently before the assertion.
set +e

# G1: an unmarked third-party himmelctl.js is refused and left byte-untouched;
# no wrapper is written (the shim aborts on the first refusal). The update
# engine itself succeeded, so cmdUpdate keeps rc 0 and WARNS that the launcher
# is missing — the launcher is a best-effort rider.
fixG1="$work/caseG1-checkout"; binG1="$work/caseG1-bin"; mkdir -p "$binG1"
build_update_fixture "$fixG1"
printf 'third-party\n' > "$binG1/himmelctl.js"
out=$(run_update "$fixG1" "$binG1" "$(winpath "$binG1"):$PATH"); rc=$?
[ "$rc" -eq 0 ] || fail "caseG1: a refused launcher must not fail a successful update (rc=$rc): $out"
[ "$(cat "$binG1/himmelctl.js")" = 'third-party' ] \
  || fail "caseG1: unmarked collision must be left untouched"
[ ! -e "$binG1/himmelctl" ] || fail "caseG1: refusing the loader must abort before writing the wrapper"
grepq "$out" 'refusing to overwrite' || fail "caseG1: refusal message absent: $out"
grepq "$out" 'WARN: update succeeded' || fail "caseG1: launcher-failure WARN absent (best-effort rider): $out"
echo "ok: caseG1 unmarked third-party file refused (untouched); shim aborts; update rc stays 0 + WARN"

# G2: a symlink to an EXISTING target (a valid symlink) is refused — lstat,
# never followed/clobbered. This path already worked; it stays covered so a
# regression to an existsSync-follows-links guard is caught. The update engine
# succeeded, so rc stays 0 + WARN.
fixG2="$work/caseG2-checkout"; binG2="$work/caseG2-bin"; mkdir -p "$binG2"
build_update_fixture "$fixG2"
printf 'valid-target\n' > "$work/caseG2-target"
if ln -s "$work/caseG2-target" "$binG2/himmelctl.js" 2>/dev/null && [ -L "$binG2/himmelctl.js" ]; then
  out=$(run_update "$fixG2" "$binG2" "$(winpath "$binG2"):$PATH"); rc=$?
  [ "$rc" -eq 0 ] || fail "caseG2: a refused launcher must not fail a successful update (rc=$rc): $out"
  [ -L "$binG2/himmelctl.js" ] || fail "caseG2: valid symlink must be left intact (not followed/clobbered)"
  grepq "$out" 'refusing to overwrite symlink' || fail "caseG2: symlink refusal message absent: $out"
  grepq "$out" 'WARN: update succeeded' || fail "caseG2: launcher-failure WARN absent: $out"
  echo "ok: caseG2 valid symlink destination refused (intact); update rc stays 0 + WARN"
else
  echo "ok: caseG2 symlink refusal SKIPPED (host 'ln -s' produced no real symlink — e.g. MSYS without winsymlinks:nativestrict)"
fi

# G2b: a BROKEN (dangling) symlink — target absent — is refused too. fs.existsSync
# FOLLOWS symlinks and returns false for a dangling link, so the pre-fix guard
# skipped the symlink check and renameSync clobbered the link — violating the
# never-clobber-a-symlink contract. The lstat-based guard
# refuses ANY symlink, broken included. rc stays 0 + WARN (the update engine
# succeeded; glm-5). Hosts that cannot create a real symlink (MSYS without
# winsymlinks:nativestrict) skip — this runs on Linux CI.
fixG2b="$work/caseG2b-checkout"; binG2b="$work/caseG2b-bin"; mkdir -p "$binG2b"
build_update_fixture "$fixG2b"
if ln -s "$work/caseG2b-does-not-exist" "$binG2b/himmelctl.js" 2>/dev/null && [ -L "$binG2b/himmelctl.js" ]; then
  out=$(run_update "$fixG2b" "$binG2b" "$(winpath "$binG2b"):$PATH"); rc=$?
  [ "$rc" -eq 0 ] || fail "caseG2b: a refused launcher must not fail a successful update (rc=$rc): $out"
  [ -L "$binG2b/himmelctl.js" ] || fail "caseG2b: broken symlink must be left intact (not clobbered)"
  grepq "$out" 'refusing to overwrite symlink' || fail "caseG2b: broken-symlink refusal message absent: $out"
  grepq "$out" 'WARN: update succeeded' || fail "caseG2b: launcher-failure WARN absent: $out"
  echo "ok: caseG2b broken (dangling) symlink destination refused (intact); update rc stays 0 + WARN"
else
  echo "ok: caseG2b broken-symlink refusal SKIPPED (host 'ln -s' produced no real symlink — e.g. MSYS without winsymlinks:nativestrict)"
fi

# G3: a MARKED file is replaced in place (re-pointed); marker preserved.
fixG3="$work/caseG3-checkout"; binG3="$work/caseG3-bin"; mkdir -p "$binG3"
build_update_fixture "$fixG3"
cat > "$binG3/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/old/target/himmelctl.js');
STUB
out=$(run_update "$fixG3" "$binG3" "$(winpath "$binG3"):$PATH"); rc=$?
[ "$rc" -eq 0 ] || fail "caseG3: marked file should be replaced (rc=$rc): $out"
grepq "$(cat "$binG3/himmelctl.js")" 'caseG3-checkout' \
  || fail "caseG3: marked loader was not re-pointed to this checkout"
grepq "$(cat "$binG3/himmelctl.js")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseG3: replacement loader lost the ownership marker"
grepq "$(cat "$binG3/himmelctl")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseG3: replacement wrapper lost the ownership marker"
echo "ok: caseG3 marked file replaced in place (re-pointed), marker preserved"

# G4a: a successful write leaves no orphaned tmp (rename always completes).
fixG4="$work/caseG4-checkout"; binG4="$work/caseG4-bin"
build_update_fixture "$fixG4"
run_update "$fixG4" "$binG4" "$(winpath "$binG4"):$PATH" >/dev/null
tmpcount=$(find "$binG4" -name '.*.tmp' 2>/dev/null | wc -l | tr -d ' ')
[ "$tmpcount" -eq 0 ] || fail "caseG4a: successful write left an orphaned tmp file"
echo "ok: caseG4a successful write leaves no orphaned tmp"

# G4b: a failed write leaves the existing marked dest untouched (no partial).
# POSIX-native only: 'chmod a-w' reliably denies node's file creation on
# Linux/macOS; on MSYS/Cygwin chmod is a no-op against NTFS ACLs, so the failure
# can't be injected there — skip with a note. The update engine succeeded, so a
# failed launcher write keeps rc 0 + WARN; the dest-
# untouched guarantee is the part this case actually locks.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "ok: caseG4b partial-on-failure SKIPPED (chmod is a no-op on MSYS/NTFS — can't inject a write failure)"
    ;;
  *)
    fixG4b="$work/caseG4b-checkout"; binG4b="$work/caseG4b-bin"; mkdir -p "$binG4b"
    build_update_fixture "$fixG4b"
    cat > "$binG4b/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/old/target');
STUB
    marked_before=$(cat "$binG4b/himmelctl.js")
    chmod a-w "$binG4b"
    out=$(run_update "$fixG4b" "$binG4b" "$(winpath "$binG4b"):$PATH"); rc=$?
    chmod u+w "$binG4b"   # restore so the EXIT trap's rm -rf can clean up
    [ "$rc" -eq 0 ] || fail "caseG4b: a failed launcher write must not fail a successful update (rc=$rc): $out"
    [ "$(cat "$binG4b/himmelctl.js")" = "$marked_before" ] \
      || fail "caseG4b: a failed write must leave the existing marked dest untouched (no partial)"
    grepq "$out" 'WARN: update succeeded' || fail "caseG4b: launcher-failure WARN absent: $out"
    echo "ok: caseG4b failed write leaves the marked dest untouched (no partial); update rc stays 0 + WARN"
    ;;
esac

# ── H: launcher binds to the PRIMARY checkout, not the running worktree (Fix 2)
# A real git fixture: install from a linked worktree must target the PRIMARY
# root; install from a non-worktree primary targets itself (unchanged).

# H1: linked worktree — loader targets the primary, never the worktree.
primaryH="$work/caseH-primary"
mkdir -p "$primaryH"
build_update_fixture "$primaryH"
( cd "$primaryH" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
wtH="$work/caseH-worktree"
if git -C "$primaryH" worktree add -q "$wtH" 2>/dev/null; then
  binH1="$work/caseH1-bin"
  # repoRoot = the WORKTREE; the loader must target the PRIMARY checkout.
  run_update "$wtH" "$binH1" "$(winpath "$binH1"):$PATH" >/dev/null
  loader=$(cat "$binH1/himmelctl.js")
  grepq "$loader" 'caseH-primary' || fail "caseH1: worktree-installed loader must target the PRIMARY checkout"
  case "$loader" in *caseH-worktree*) fail "caseH1: loader must not target the disposable worktree ($loader)" ;; esac
  echo "ok: caseH1 linked-worktree install targets the PRIMARY checkout"
else
  echo "ok: caseH1 linked-worktree SKIPPED (git worktree add unavailable on this host)"
fi

# H2: non-worktree primary — loader targets repoRoot itself (unchanged).
primaryH2="$work/caseH2-repo"
mkdir -p "$primaryH2"
build_update_fixture "$primaryH2"
( cd "$primaryH2" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
binH2="$work/caseH2-bin"
run_update "$primaryH2" "$binH2" "$(winpath "$binH2"):$PATH" >/dev/null
grepq "$(cat "$binH2/himmelctl.js")" 'caseH2-repo' \
  || fail "caseH2: non-worktree install must target repoRoot (primary == self)"
echo "ok: caseH2 non-worktree primary install targets repoRoot unchanged"

# ── I: a failed adopt.sh must not skip the PATH shim ──────────
# RED control (pre-fix order): applyHimmelctlPathShim ran AFTER the
# `if (rc !== 0) return rc` early return, so a failing adopt.sh (e.g. the
# plugin SSH-clone class) left no himmelctl launcher on PATH and
# the adopter had no way to run `himmelctl ensure` to resume.
fixtureI="$work/caseI-checkout"
binI="$work/caseI-bin"
homeI="$work/caseI-home"
stubI="$work/caseI-tools"
mkdir -p "$fixtureI/scripts/himmelctl" "$homeI" "$stubI"
cat > "$fixtureI/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
const fs = require('fs');
fs.appendFileSync(process.env.SHIM_CALL_LOG, `install:${process.argv.slice(2).join('|')}\n`);
STUB
printf '#!/usr/bin/env bash\necho "adopt.sh: simulated failure" >&2\nexit 1\n' > "$fixtureI/scripts/adopt.sh"
chmod +x "$fixtureI/scripts/adopt.sh"
cat > "$work/adopter-profile.json" <<'JSON'
{
  "role": "adopter",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
for tool in bash git jq python3 npm; do link_hermetic_tool "$tool" "$stubI"; done
install_path="$(winpath "$binI"):$(winpath "$stubI"):$PATH"
set +e
out=$(PATH="$install_path" HOME="$(winpath "$homeI")" USERPROFILE="$(winpath "$homeI")" \
  HIMMELCTL_BASH="$bash_bin" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/caseI-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseI-cache")-luna-config.json" \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
  HIMMELCTL_BIN_DIR="$(winpath "$binI")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$work/adopter-profile.json")" \
  </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "caseI: install must propagate adopt.sh's non-zero rc unchanged (got rc=$rc): $out"
[ -x "$binI/himmelctl" ] || fail "caseI: PATH shim must be applied even though adopt.sh failed: $out"
[ -f "$binI/himmelctl.js" ] || fail "caseI: launcher loader must be written even though adopt.sh failed"
grepq "$out" 'himmelctl ensure' || fail "caseI: failure message must tell the adopter himmelctl ensure is on PATH to resume: $out"
SHIM_CALL_LOG="$(winpath "$work/caseI-shim-calls.log")" \
  PATH="$(winpath "$binI"):$PATH" "$binI/himmelctl" status
[ "$(cat "$work/caseI-shim-calls.log")" = 'install:status' ] \
  || fail "caseI: shim written after a failed adopt.sh must still target this checkout"
echo "ok: caseI failed adopt.sh still applies the PATH shim and points the adopter at himmelctl ensure"

# ── J: the generated launcher RE-EXECS bin.js, so bin.js's own
# `require.main === module` guard still fires. Pre-fix the
# generated himmelctl.js did `require(target)`, which runs with
# require.main === himmelctl.js (the launcher), not the target — so a
# guarded main() never ran: silent no-op, empty stdout, rc 0. The other
# fixtures in this file stub bin.js with UNGUARDED top-level code (it runs
# the instant it's require()'d), which would mask exactly this bug class —
# this fixture mirrors the real guard shape instead.
fixtureJ="$work/caseJ-checkout"; binJ="$work/caseJ-bin"; mkdir -p "$binJ"
build_update_fixture "$fixtureJ"
cat > "$fixtureJ/scripts/himmelctl/bin.js" <<'STUB'
'use strict';
function main() {
  process.stdout.write('himmelctl: guarded main ran\n');
}
if (require.main === module) {
  main();
}
STUB
run_update "$fixtureJ" "$binJ" "$(winpath "$binJ"):$PATH" >/dev/null
outJ=$("$binJ/himmelctl" --help 2>&1); rcJ=$?
[ -n "$outJ" ] || fail "caseJ: generated launcher produced no output — the require.main===module guard (HIMMEL-2438) swallowed main() (rc=$rcJ)"
[ "$rcJ" -eq 0 ] || fail "caseJ: generated launcher should exit 0 (got rc=$rcJ): $outJ"
grepq "$outJ" 'guarded main ran' || fail "caseJ: generated launcher did not run the guarded main() (got: $outJ)"
echo "ok: caseJ generated launcher re-execs bin.js so the require.main===module guard (HIMMEL-2438) still fires"

# ── K: update opens a provenance session and the launcher
# writer records its shim rows into it (class code): create on a fresh bin dir,
# replace (with a backup of the prior marked launcher) on the re-run. A private
# ledger dir per case, so nothing here can reach the operator's real ledger.
if command -v jq >/dev/null 2>&1; then
  fixtureK="$work/caseK-checkout"; binK="$work/caseK-bin"; provK="$work/caseK-prov"; mkdir -p "$binK"
  build_update_fixture "$fixtureK"
  HIMMEL_PROVENANCE_DIR="$(winpath "$provK")" run_update "$fixtureK" "$binK" "$(winpath "$binK"):$PATH" >/dev/null
  ledK="$provK/provenance.jsonl"
  [ -f "$ledK" ] || fail "caseK: no ledger written at $ledK"
  [ "$(jq -rs '.[0].op' "$ledK")" = "install-begin" ] || fail "caseK: first row is not install-begin"
  [ "$(jq -rs '.[-1] | .op + " " + .status' "$ledK")" = "install-end ok" ] || fail "caseK: session did not end ok"
  [ "$(jq -rs '[.[] | select(.kind=="shim" and .op=="create" and .class=="code")] | length' "$ledK")" = "3" ] \
    || fail "caseK: expected three shim create rows (himmelctl.js + himmelctl + himmel alias)"
  HIMMEL_PROVENANCE_DIR="$(winpath "$provK")" run_update "$fixtureK" "$binK" "$(winpath "$binK"):$PATH" >/dev/null
  [ "$(jq -rs '[.[] | select(.kind=="shim" and .op=="replace" and .class=="code")] | length' "$ledK")" = "3" ] \
    || fail "caseK: the re-run should record three shim replace rows"
  [ "$(jq -rs '[.[] | select(.op=="install-begin")] | length' "$ledK")" = "2" ] || fail "caseK: each run should be its own session"
  [ -n "$(find "$provK/provenance-backups" -type f -name '*himmelctl*' 2>/dev/null | head -1)" ] \
    || fail "caseK: a replaced launcher should have a backup in the ledger dir"
  echo "ok: caseK update opens a session and records its launcher shim rows (create, then replace with backup)"
else
  echo "skip: caseK needs jq"
fi

echo "PASS"
