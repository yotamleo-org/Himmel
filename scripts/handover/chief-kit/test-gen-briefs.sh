#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-gen-briefs.sh — Exercises gen-briefs.py on a fixture workers
# JSON: the briefs it writes pass brief-lint.sh (the arming-time check
# headed-arm-worker runs), the launcher carries the hook-integrity bypass export
# only for hook=true, bad input is refused, nothing is overwritten. The worktree
# step is stubbed (GEN_BRIEFS_WORKTREE_CMD) and every path is a fixture: no real
# bucket, worktree or launch. GEN_BRIEFS overrides the script under test (the
# RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-gen-briefs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GEN_BRIEFS:-$HERE/gen-briefs.py}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-briefs-test.XXXXXX")" || exit 1
# Physical path: gen-briefs.py resolves a relative --repo through getcwd, which names /private/var/... on macOS, not the logical TMPDIR.
WORK="$(cd "$WORK" && pwd -P)" || exit 1
trap 'rm -rf "$WORK"' EXIT
BUCKET="$WORK/bucket"; REPO="$WORK/repo"; mkdir -p "$REPO"
# No bus identity, so relay-batch never reaches the real himmel-bus store.
unset HIMMEL_BUS_NAME

cat > "$WORK/wt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WT_LOG"
[ "$1" = "fix/fail-me" ] && exit 1
echo "created worktree $1"
EOF
chmod +x "$WORK/wt.sh"
export WT_LOG="$WORK/wt.log" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh"
export GEN_BRIEFS_MIRROR="$WORK/mirror"; mkdir -p "$GEN_BRIEFS_MIRROR"  # the proof check reads this fixture mirror, never the real one
export TICKET_STATUS_STATE_DIR="$WORK/state-empty"  # the partial-merge block reads status-events.jsonl here, never the real one
export GEN_BRIEFS_NO_WT_CHECK=1 # the older rows use a fixture --repo with no real worktrees; the bucket and worktree-guard rows unset it
# The core gate: gen-briefs asks the REAL built jira CLI (release core-check, spec-check) about every worker, never a stub.
# This suite FAILS, never skips, when dist/ is absent (locally: npm --prefix scripts/jira run build; CI builds it first).
JIRA_CLI="${GEN_BRIEFS_JIRA_CLI:-$HERE/../../jira/dist/index.js}"
if [ -f "$JIRA_CLI" ]; then
    pass "the jira CLI is built ($JIRA_CLI)"
else
    fail "the jira CLI is not built at $JIRA_CLI: run npm --prefix scripts/jira run build; every row below that generates a brief fails without it"
fi
export GEN_BRIEFS_JIRA_CLI="$JIRA_CLI"

cat > "$WORK/workers.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"},
 {"label":"N902","keys":["HIMMEL-9002","HIMMEL-9003"],"slug":"hook-fix","branch":"fix/himmel-9002-hook-fix","title":"a hook fix","desc":"fix the hook thing","why":"the hook is broken","prior":"none found (qmd jira-himmel hook thing)","writes":"scripts/hooks/h.sh","scope":"`scripts/hooks/h.sh`","scope_short":"h.sh","hook":true,"judge":true,"env":true,"commit":"fix(hooks): [HIMMEL-9002] fix the hook","extra":"GREEN controls stay."}
]
EOF

run() { python3 "$SUT" "$WORK/workers.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$BUCKET" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/w" --deadline 1791475000 "$@"; }

out="$(run --manifest "$WORK/fleet.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "a valid workers file generates (rc 0)" || fail "rc=$rc: $out"
D1="$BUCKET/HIMMEL-9001-N901-plain-fix-2026-10-08.md"
D2="$BUCKET/HIMMEL-9002-N902-hook-fix-2026-10-08.md"
[ -f "$D1" ] && [ -f "$D2" ] && pass "one brief per worker, named <KEY>-<label>-<slug>-<date>.md" || fail "briefs missing in $BUCKET"
bash "$HERE/brief-lint.sh" "$D1" 2>"$WORK/lint1.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 1 passes brief-lint.sh" || fail "brief 1 brief-lint rc=$rc: $(cat "$WORK/lint1.err")"
bash "$HERE/brief-lint.sh" "$D2" 2>"$WORK/lint2.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 2 (none found (<query>) prior art) passes brief-lint.sh" || fail "brief 2 brief-lint rc=$rc: $(cat "$WORK/lint2.err")"

# every brief pre-authorizes a new suite's own tier + duration row
has "brief 1 pre-authorizes the new suite's own tier and duration rows" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" "A new test suite may add exactly one row for itself to scripts/ci/suite-tiers.tsv and scripts/ci/suite-durations.tsv"
has "brief 2 pre-authorizes the new suite's own tier and duration rows" "$(tr '\n' ' ' < "$D2" | tr -s ' ')" "name the rows in READY"

# contract item 3: a worker runs locally only the RED rows it builds; every other impacted suite is CI-gated
B1="$(tr '\n' ' ' < "$D1" | tr -s ' ')"
lacks "brief 1 no longer tells the worker to run the full suite of every touched file" "$B1" "the full suite of every file you touched"
has "brief 1 lists non-RED impacted suites as SKIP CI-gated per decision 101" "$B1" "SKIP CI-gated per decision 101 (GitHub CI is the gate)"
has "brief 1 routes VM-only checks through the VM queue" "$B1" "VM queue"
has "brief 1 forbids run-shell-tests.sh full or sharded locally" "$B1" "never run run-shell-tests.sh full or sharded locally"
has "brief 1 limits local runs to the RED rows of the item built" "$B1" "Locally run only the RED rows of the item you build"

# the three most-refused shapes are taught where the worker first meets them (7370, 7371, 7372)
has "brief 1 teaches the exact quiet-run RED command, nothing inside the backticks after the suite" "$B1" "run it as \`bash scripts/quiet-run.sh suite -- bash <test-*.sh>\` with nothing appended"
has "brief 1 names the quiet-run log path to Read" "$B1" "Read the log path its ERR line prints"
has "brief 1 teaches the Edit tool / python3 -I <file> shape" "$B1" "run as \`python3 -I <file>\`"
has "brief 1 teaches the SWEEP record grammar and its write command" "$B1" "write its \`SWEEP [<id>@<head>] class=… :: sites=…\` line (a one-site finding: \`:: single-site search=git grep …\`) with \`bash scripts/cr/write-verdicts.sh sweep --branch <b> --from-file <f>\`"
has "brief 1 teaches the single-site search form for a one-site finding" "$B1" ":: single-site search=git grep"

# the wrap step checks the queue lock: the brief's wrap command carries --queue-doc with THIS worker's doc
has "brief 1 wrap command passes --queue-doc with its own doc" "$(cat "$D1")" "wrap-subtree-check.sh --queue-doc $D1"
has "brief 2 wrap command passes --queue-doc with its own doc" "$(cat "$D2")" "wrap-subtree-check.sh --queue-doc $D2"
has "the worker preface's HALT/WRAP step passes --queue-doc" "$(tr '\n' ' ' < "$HERE/../../../docs/handover/worker-preface.md" | tr -s ' ')" "wrap-subtree-check.sh --queue-doc <doc>"

# the arming gate lints every brief, so a generated brief must also
# arm through the launcher itself (dry-run reaches the gate before it exits).
# (a copy without resume_cwd: the worktree check is a later gate and the copy leaves D1 alone)
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$WORK/preflight.sh"
mkdir -p "$WORK/arm"; grep -v '^resume_cwd:' "$D1" > "$WORK/arm/HIMMEL-9001-N901-copy.md"
rc=0; arm_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile worker-impl HIMMEL-9001-N901 "$WORK/arm/HIMMEL-9001-N901-copy.md" "$WORK/arm/signal" 9999999999 "$WORK/arm/log" claude-sonnet-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "a generated brief arms through headed-arm-worker.sh (brief-lint gate)" || fail "generated brief refused by headed-arm-worker.sh rc=$rc: $arm_out"

b1="$(cat "$D1" 2>/dev/null)"; b2="$(cat "$D2" 2>/dev/null)"
has "the brief names the chief" "$b1" "HIMMEL-nextleg-2026-10-08BZ-roadmap-chief"
has "the brief carries a nonce in the chief letter's shape" "$b1" "BZ-N901-"
has "the brief names the base sha" "$b1" "4ccb59dd6de2eba962c75f136096cd7b721ae312"
has "the brief names the worktree under the repo" "$b1" "$REPO/.claude/worktrees/fix+himmel-9001-plain-fix"
has "the brief carries the handover root" "$b1" "$WORK/handovers"
has "a two-key worker's Why lists both tickets' get commands" "$b2" "get HIMMEL-9003"
has "a hook worker's brief says it is launched with the bypass" "$b2" "hook-integrity bypass flag"
lacks "a plain worker's brief does not" "$b1" "hook-integrity bypass flag"
has "a judge worker's brief announces the opus judge" "$b2" "chief runs an opus judge"
has "the other worker's scope is listed under 'other live workers'" "$b1" "N902 (h.sh)"
has "the brief puts the write list on its own '> **Writes:**' line (HIMMEL-7469)" "$(grep -c '^> \*\*Writes:\*\* ' "$D1")" "1"
[ "$(grep '^> \*\*Writes:\*\* ' "$D1")" = "> **Writes:** scripts/x/" ] && pass "the Writes line is the scope's paths only (HIMMEL-7469)" || fail "the Writes line is not exactly the scope's paths: $(grep '^> \*\*Writes:\*\* ' "$D1")"
lacks "the Writes line carries no backtick prose (HIMMEL-7469)" "$(grep '^> \*\*Writes:\*\* ' "$D1")" '`'
# a worker flagged for CI, infra or the environment gets a RED-first line requiring a real-environment fixture.
has "a flagged worker's brief requires a fixture copied from the real environment" "$b2" "copied from the real environment"
lacks "an unflagged worker's brief does not" "$b1" "copied from the real environment"

l1="$(cat "$BUCKET/launch-N901.sh" 2>/dev/null)"; l2="$(cat "$BUCKET/launch-N902.sh" 2>/dev/null)"
lacks "a plain worker's launcher has NO bypass export" "$l1" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK"
has "a hook worker's launcher exports the bypass" "$l2" "export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1"
has "the launcher calls headed-arm-worker.sh under the repo" "$l1" "$REPO/scripts/handover/chief-kit/headed-arm-worker.sh --profile worker-impl --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief"
has "the launcher passes the deadline and model" "$l1" "1791475000"
has "the launcher is syntactically valid bash" "$(bash -n "$BUCKET/launch-N901.sh" 2>&1 && echo ok)" "ok"
[ -x "$BUCKET/launch-N901.sh" ] && pass "launchers are executable" || fail "launcher not executable"
has "it prints one manifest add per worker" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2"
# the printed add line carries --lane, so the manifest never stores lane unknown.
has "the add line for a default worker carries --lane native" "$out" "fleet-manifest.sh add $WORK/fleet.json $D1 --lane native"
has "and so does the second worker's" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2 --lane native"
# The printed lines, run as printed from the repo root, build a manifest relay-batch resolves.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# fleet-manifest.sh takes a util-linux flock (its PLATFORM GUARD): without one no manifest row is written, so the relay rows have nothing to read.
if command -v flock >/dev/null 2>&1; then
printf '%s\n' "$out" | grep '^bash scripts/handover/chief-kit/fleet-manifest.sh add ' > "$WORK/adds.txt"
while IFS= read -r addline; do (cd "$REPO_ROOT" && eval "$addline" >/dev/null 2>&1); done < "$WORK/adds.txt"
cp "$WORK/fleet.json" "$WORK/chief.fleet.json" 2>/dev/null
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
printf '## Live state\nlegs: `N901:tok1:lock:1` `N902:tok2:lock:2`\n' > "$WORK/chief.md"
cat > "$WORK/census.sh" <<'EOC'
#!/usr/bin/env bash
printf '1\tHIMMEL-9001-N901-plain-fix-2026-10-08\tm\t0\n2\tHIMMEL-9002-N902-hook-fix-2026-10-08\tm\t0\n'
EOC
rb="$(RELAY_BATCH_CENSUS="$WORK/census.sh" bash "$HERE/relay-batch.sh" "$WORK/chief.md" --successor X-chief 2>&1)"
lacks "relay-batch on a gen-briefs-built manifest prints no UNRESOLVED-LANE" "$rb" "UNRESOLVED-LANE"
has "relays the first worker" "$rb" "SENDMESSAGE to=HIMMEL-9001-N901-plain-fix-2026-10-08"
has "and relays the second worker" "$rb" "SENDMESSAGE to=HIMMEL-9002-N902-hook-fix-2026-10-08"
else
  echo "SKIP relay-batch rows (no flock on this host, so fleet-manifest.sh writes no row)"
fi
# the sidecar Telegram /launch-worker checks is written with the launcher.
side="$(cat "$WORK/fleet.launchers.sha256" 2>/dev/null)"
# hashlib, not sha256sum: macOS ships shasum only.
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
has "the sha256 sidecar records launcher 1 at write time" "$side" "$(sha_of "$BUCKET/launch-N901.sh")  $BUCKET/launch-N901.sh"
has "and launcher 2" "$side" "$(sha_of "$BUCKET/launch-N902.sh")  $BUCKET/launch-N902.sh"
has "it created both worktrees via the seam" "$(paste -sd, "$WORK/wt.log")" "fix/himmel-9001-plain-fix,fix/himmel-9002-hook-fix"
[ -f "$WORK/workers.json.out" ] && pass "the .out file records the nonces" || fail "no .out file"
has "nothing was launched (no signal files)" "$(ls "$WORK/w" 2>&1)" "No such file"

# A chief that runs only the launcher must still leave the worker in the manifest,
# added BEFORE the arm. The launcher runs against a fixture repo (real fleet-manifest.sh and libs,
# stub headed-arm-worker.sh) with `sleep` stubbed off the PATH.
if command -v flock >/dev/null 2>&1; then
R7811="$WORK/repo7811"; mkdir -p "$R7811/scripts/handover/chief-kit" "$WORK/bin7811"
cp -R "$REPO_ROOT/scripts/lib" "$R7811/scripts/lib"
cp "$HERE/fleet-manifest.sh" "$R7811/scripts/handover/chief-kit/fleet-manifest.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/arm7811.log" > "$R7811/scripts/handover/chief-kit/headed-arm-worker.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin7811/sleep"; chmod +x "$WORK/bin7811/sleep"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811" --repo "$R7811" --handover-root /h --no-worktree --manifest "$WORK/f7811.fleet.json" >/dev/null 2>&1
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811/launch-N901.sh" >/dev/null 2>&1; rc7811=$?
[ "$rc7811" -eq 0 ] && pass "the generated launcher exits 0 (HIMMEL-7811)" || fail "the generated launcher exited $rc7811"
d7811="$(find "$WORK/b7811" -maxdepth 1 -name 'HIMMEL-9001-N901-plain-fix-*.md' 2>/dev/null | head -n1)"
[ -n "$d7811" ] && bash "$HERE/fleet-manifest.sh" list "$WORK/f7811.fleet.json" 2>&1 | grep -Fxq -- "$d7811" && pass "the generated launcher leaves its exact worker doc in the fleet manifest (HIMMEL-7811)" || fail "the fleet manifest does not list the exact worker doc [$d7811]"
l7811="$(cat "$WORK/b7811/launch-N901.sh" 2>/dev/null)"
add_pos="${l7811%%fleet-manifest.sh add*}"; arm_pos="${l7811%%headed-arm-worker.sh*}"
[ "${#add_pos}" -lt "${#arm_pos}" ] && pass "the launcher adds the worker to the manifest before it arms (HIMMEL-7811)" || fail "manifest add does not precede the arm in the launcher"
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811/launch-N901.sh" >/dev/null 2>&1; rc7811=$?
[ "$rc7811" -eq 0 ] && pass "the re-run launcher exits 0 (HIMMEL-7811)" || fail "the re-run launcher exited $rc7811"
[ "$(bash "$HERE/fleet-manifest.sh" list "$WORK/f7811.fleet.json" 2>&1 | grep -c N901)" = 1 ] && pass "running the launcher twice adds the worker once (HIMMEL-7811)" || fail "launcher re-run duplicated the manifest row"
# A failed manifest add stops the launch: the arm never runs.
R7811f="$WORK/repo7811f"; mkdir -p "$R7811f/scripts/handover/chief-kit"
cp -R "$REPO_ROOT/scripts/lib" "$R7811f/scripts/lib"
printf '#!/usr/bin/env bash\nexit 1\n' > "$R7811f/scripts/handover/chief-kit/fleet-manifest.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/arm7811f.log" > "$R7811f/scripts/handover/chief-kit/headed-arm-worker.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811f" --repo "$R7811f" --handover-root /h --no-worktree --manifest "$WORK/f7811f.fleet.json" >/dev/null 2>&1
has "the launcher for the failed-add check carries the manifest add (HIMMEL-7811)" "$(cat "$WORK/b7811f/launch-N901.sh" 2>/dev/null)" "fleet-manifest.sh"
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811f/launch-N901.sh" >/dev/null 2>&1; rc7811f=$?
[ "$rc7811f" -ne 0 ] && pass "a failed manifest add makes the launcher exit non-zero (HIMMEL-7811)" || fail "launcher exited 0 after a failed manifest add"
[ ! -s "$WORK/arm7811f.log" ] && pass "a failed manifest add stops the launch before the arm (HIMMEL-7811)" || fail "the arm ran after a failed manifest add"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811n" --repo "$R7811" --handover-root /h --no-worktree >/dev/null 2>&1; rc7811n=$?
[ "$rc7811n" -eq 0 ] && pass "generation without --manifest succeeds (HIMMEL-7811)" || fail "generation without --manifest exited $rc7811n"
has "the launcher generated without --manifest still arms (HIMMEL-7811)" "$(cat "$WORK/b7811n/launch-N901.sh" 2>/dev/null)" "headed-arm-worker.sh"
lacks "a launcher generated without --manifest adds nothing (HIMMEL-7811)" "$(cat "$WORK/b7811n/launch-N901.sh" 2>/dev/null)" "fleet-manifest.sh"
else
  echo "SKIP launcher manifest rows (no flock on this host)"
fi

# --- refusals ---------------------------------------------------------------
run >/dev/null 2>"$WORK/again.err"; rc=$?
[ "$rc" = 1 ] && pass "re-running over existing briefs refuses (rc 1)" || fail "overwrite rc=$rc"

rm -rf "$BUCKET"
sed 's/"prior":"HIMMEL-9000[^"]*"/"prior":"none"/' "$WORK/workers.json" > "$WORK/bare.json"
python3 "$SUT" "$WORK/bare.json" --base 4ccb59d --chief BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/bare.err"; rc=$?
[ "$rc" = 1 ] && pass "a bare 'none' prior art is refused (rc 1)" || fail "bare none rc=$rc"
[ ! -e "$BUCKET/launch-N901.sh" ] && pass "and nothing is written for it" || fail "wrote files for an invalid worker"

printf '[{"label":"N903","keys":["HIMMEL-1"]}]\n' > "$WORK/short.json"
python3 "$SUT" "$WORK/short.json" --base 4ccb59d --chief BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/short.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'missing' "$WORK/short.err" && pass "a worker missing required keys is refused" || fail "missing keys rc=$rc"

python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --console BZ --bucket "$WORK/b-oldflag" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/oldflag.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'unrecognized arguments: --console' "$WORK/oldflag.err" && [ ! -e "$WORK/b-oldflag/launch-N901.sh" ] && pass "the retired --console flag is refused (rc 2, nothing written)" || fail "--console rc=$rc"

sed 's#fix/himmel-9001-plain-fix#fix/fail-me#' "$WORK/workers.json" > "$WORK/wtfail.json"
python3 "$SUT" "$WORK/wtfail.json" --base 4ccb59d --chief BZ --bucket "$WORK/b2" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/wtfail.err"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/b2/launch-N901.sh" ] && pass "a failed worktree writes no brief for that worker" || fail "worktree failure rc=$rc"

mkdir -p "$WORK/b3"; : > "$WORK/b3/launch-N901.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/coll.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'launch-N901.sh already exists' "$WORK/coll.err" && [ ! -s "$WORK/b3/launch-N901.sh" ] && ! ls "$WORK/b3"/*.md >/dev/null 2>&1 && pass "an existing launcher is refused before anything is written" || fail "launcher collision rc=$rc"

python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); d=dict(l[0]); d["label"]="N999"; d["keys"]=["HIMMEL-9999"]; l.append(d); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/dupbr.json"
python3 "$SUT" "$WORK/dupbr.json" --base 4ccb59d --chief BZ --bucket "$WORK/b4" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/dupbr.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'duplicate worker branches' "$WORK/dupbr.err" && pass "two workers sharing a branch are refused" || fail "dup branch rc=$rc"

# The nonce <letter>-<label>-<hex> must stay inside the vault token grammar (1-3 upper-case letters, label N + 1-5 digits).
tok() { # <name> <stderr fragment> <gen-briefs args...>: refused, rc 1, nothing written
    local n="$1" frag="$2"; shift 2
    rm -rf "$WORK/bt-tok"
    python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --bucket "$WORK/bt-tok" --repo "$REPO" --handover-root /h --no-worktree "$@" >/dev/null 2>"$WORK/tok.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/tok.err" && ! ls "$WORK/bt-tok"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/tok.err"))"; fi
}
tok "a 4-letter --letter is refused" "letter" --chief BZ --letter ABCD
tok "a lower-case --letter is refused" "letter" --chief BZ --letter bz
tok "an explicitly empty --letter is refused" "letter" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --letter ""
tok "a letter derived from the chief name that is 4 letters long is refused" "letter" --chief HIMMEL-nextleg-2026-10-08ABCD-roadmap-chief
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --letter ABC --bucket "$WORK/bt-ok" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'ABC-N901-' "$WORK/bt-ok"/HIMMEL-9001-N901-*.md && pass "a 3-letter --letter is accepted and minted" || fail "3-letter letter rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["label"]="N123456"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lbl6.json"
python3 "$SUT" "$WORK/lbl6.json" --base 4ccb59d --chief BZ --bucket "$WORK/bt-lbl" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lbl6.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'label' "$WORK/lbl6.err" && pass "a 6-digit worker label is refused" || fail "6-digit label rc=$rc"

# A per-worker lane key is carried through and validated.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-ok.json"
lout="$(python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b5" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5.json" 2>&1)"
has "a worker's lane key is printed as --lane" "$lout" "--lane claudex"
# The launcher itself carries the lane, so a claudex worker needs no hand edit that breaks the sidecar sha.
has "a claudex worker's launcher passes --lane claudex" "$(cat "$WORK/b5/launch-N901.sh")" "--lane claudex "
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5/launch-N901.sh")  $WORK/b5/launch-N901.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b5n" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5n.json" >/dev/null 2>&1; rc5n=$?
[ "$rc5n" -eq 0 ] && pass "a native worker's generation succeeds (HIMMEL-7811)" || fail "native worker generation exited $rc5n"
has "a native worker's launcher has an arm line to check" "$(grep 'headed-arm-worker.sh' "$WORK/b5n/launch-N901.sh" 2>/dev/null)" "headed-arm-worker.sh"
lacks "a native worker's arm line has no --lane (its manifest add line carries --lane native, HIMMEL-7811)" "$(grep 'headed-arm-worker.sh' "$WORK/b5n/launch-N901.sh")" "--lane"
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5n.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5n/launch-N901.sh")  $WORK/b5n/launch-N901.sh"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="Bad Lane"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-bad.json"
python3 "$SUT" "$WORK/lane-bad.json" --base 4ccb59d --chief BZ --bucket "$WORK/b6" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-bad.err" && [ ! -e "$WORK/b6/launch-N901.sh" ] && pass "an invalid lane is refused before anything is written" || fail "bad lane rc=$rc"
# A non-string lane (a JSON number) is refused too, not a TypeError after the artifacts are written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]=123; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-num.json"
python3 "$SUT" "$WORK/lane-num.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-num.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-num.err" && [ ! -e "$WORK/b7/launch-N901.sh" ] && pass "a numeric lane is refused before anything is written" || fail "numeric lane rc=$rc"
# A trailing newline is not a lowercase word: the whole value must match.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="native\n"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-nl.json"
python3 "$SUT" "$WORK/lane-nl.json" --base 4ccb59d --chief BZ --bucket "$WORK/b8" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-nl.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-nl.err" && [ ! -e "$WORK/b8/launch-N901.sh" ] && pass "a lane with a trailing newline is refused" || fail "newline lane rc=$rc"

# an ab_arm key writes the brief ruling line, exports WORKER_SESSION_AUTOCOMPACT_AB in the launcher
# and passes --arm on the printed manifest add line; a bad value is refused; no key changes nothing.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="400k"; l[0]["profile"]="worker-docs"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-ok.json"
about="$(python3 "$SUT" "$WORK/ab-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b9" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f9.json" 2>&1)"
abdoc="$(cat "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>/dev/null)"
has "ab_arm 400k: the brief carries the ruling line" "$abdoc" "> **Context:** ab-400k — operator-ruling: HIMMEL-5193"
has "ab_arm 400k: the launcher exports WORKER_SESSION_AUTOCOMPACT_AB=400000" "$(cat "$WORK/b9/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_AUTOCOMPACT_AB=400000"
has "ab_arm 400k: the manifest add line passes --arm 400k" "$about" "--arm 400k"
bash "$HERE/brief-lint.sh" "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>"$WORK/lint-ab.err"; rc=$?
[ "$rc" = 0 ] && pass "ab_arm brief passes brief-lint.sh" || fail "ab_arm brief-lint rc=$rc: $(cat "$WORK/lint-ab.err")"
lacks "no ab_arm: the plain brief has no Context line" "$b1" "operator-ruling: HIMMEL-5193"
lacks "no ab_arm: the plain launcher exports no arm" "$l1" "WORKER_SESSION_AUTOCOMPACT_AB"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="500k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-bad.json"
python3 "$SUT" "$WORK/ab-bad.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'ab_arm' "$WORK/ab-bad.err" && [ ! -e "$WORK/b10/launch-N901.sh" ] && pass "an invalid ab_arm is refused before anything is written" || fail "bad ab_arm rc=$rc"
# an A/B arm on a profile that gives a Sonnet launch its own ceiling is refused here, not printed as a launcher
# the wrapper would refuse; the same arm on a non-native lane (no Sonnet ceiling there) or on worker-docs is fine.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="200k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-impl.json"
python3 "$SUT" "$WORK/ab-impl.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10b" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-impl.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'Sonnet ceiling' "$WORK/ab-impl.err" && [ ! -e "$WORK/b10b/launch-N901.sh" ] && pass "an ab_arm on worker-impl with a Sonnet model is refused naming the Sonnet ceiling" || fail "ab_arm on worker-impl rc=$rc: $(cat "$WORK/ab-impl.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="200k"; l[0]["profile"]="worker-eval"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-eval.json"
python3 "$SUT" "$WORK/ab-eval.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10c" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-eval.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'Sonnet ceiling' "$WORK/ab-eval.err" && pass "an ab_arm on worker-eval with a Sonnet model is refused" || fail "ab_arm on worker-eval rc=$rc"

# an opus (or fable) worker needs a tier {category, reason}; without it nothing is
# written (exit 1), with it the brief carries the Tier line headed-arm-worker.sh's own gate accepts.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/opus-no.json"
python3 "$SUT" "$WORK/opus-no.json" --base 4ccb59d --chief BZ --bucket "$WORK/b11" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-no.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier' "$WORK/opus-no.err" && [ ! -e "$WORK/b11/launch-N901.sh" ] && ! ls "$WORK/b11"/*.md >/dev/null 2>&1 && pass "an opus worker without a tier is refused and nothing is written" || fail "opus without tier rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design: the gate shape is open"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/opus-ok.json"
python3 "$SUT" "$WORK/opus-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b12" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "an opus worker with a tier generates (rc 0)" || fail "opus with tier rc=$rc: $(cat "$WORK/opus-ok.err")"
TD="$(find "$WORK/b12" -name 'HIMMEL-9001-N901-plain-fix-*.md' 2>/dev/null | head -n 1)"
has "the opus brief carries the Tier line" "$(cat "$TD" 2>/dev/null)" "> **Tier:** opus — design: multi-step design: the gate shape is open"
# the launcher's own gate is the check: a copy without resume_cwd (as in the arming row above) arms, not refused.
mkdir -p "$WORK/tier-arm"; grep -v '^resume_cwd:' "$TD" > "$WORK/tier-arm/HIMMEL-9001-N901-copy.md"
rc=0; tier_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile worker-impl HIMMEL-9001-N901 "$WORK/tier-arm/HIMMEL-9001-N901-copy.md" "$WORK/tier-arm/signal" 9999999999 "$WORK/tier-arm/log" claude-opus-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "headed-arm-worker.sh's Tier gate accepts the generated opus brief" || fail "opus brief refused by headed-arm-worker.sh rc=$rc: $tier_out"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"cheap","reason":"x"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/tier-badcat.json"
python3 "$SUT" "$WORK/tier-badcat.json" --base 4ccb59d --chief BZ --bucket "$WORK/b13" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-badcat.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.category' "$WORK/tier-badcat.err" && pass "a tier category outside the four tags is refused" || fail "bad tier category rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"  "}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/tier-blank.json"
python3 "$SUT" "$WORK/tier-blank.json" --base 4ccb59d --chief BZ --bucket "$WORK/b14" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-blank.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/tier-blank.err" && pass "a blank tier reason is refused" || fail "blank tier reason rc=$rc"
lacks "a sonnet worker's brief has no Tier line" "$b1" "**Tier:**"

# A lane worker (lane other than native or claudex) cannot read the state repo, so a worker whose
# text points at a path under the handover root is refused and nothing is written; a native or claudex worker may.
SPEC="$WORK/handovers/yotamleo/himmel/specs/plan/2026-08-10-plan.md"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-spec.json" "$SPEC"
python3 "$SUT" "$WORK/lane-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b15" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-spec.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'handover root' "$WORK/lane-spec.err" && [ ! -e "$WORK/b15/launch-N901.sh" ] && ! ls "$WORK/b15"/*.md >/dev/null 2>&1 && pass "a lane worker pointing at a handover-root path is refused and nothing is written" || fail "lane worker spec path rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["tier"]={"category":"design","reason":"spec at "+sys.argv[3]}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-tier.json" "$SPEC"
python3 "$SUT" "$WORK/lane-tier.json" --base 4ccb59d --chief BZ --bucket "$WORK/b18" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-tier.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/lane-tier.err" && pass "a lane-worker tier.reason naming a handover-root path is refused" || fail "lane worker tier reason rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/native-spec.json" "$SPEC"
python3 "$SUT" "$WORK/native-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b16" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/native-spec.err"; rc=$?
[ "$rc" = 0 ] && pass "a native worker may point at a handover-root path (rc 0)" || fail "native spec path rc=$rc: $(cat "$WORK/native-spec.err")"
# A claudex worker runs with the native worker-impl settings, the project's additionalDirectories and the qmd MCP config, so it reads the handover root too.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/claudex-spec.json" "$SPEC"
python3 "$SUT" "$WORK/claudex-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b19" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/claudex-spec.err"; rc=$?
[ "$rc" = 0 ] && grep -q -- "$SPEC" "$WORK/b19"/*.md 2>/dev/null && pass "a claudex worker may point at a handover-root path (rc 0, path kept in the brief)" || fail "claudex spec path rc=$rc: $(cat "$WORK/claudex-spec.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-ok.json"
python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b17" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "a lane worker with no handover-root path generates (rc 0)" || fail "lane worker clean rc=$rc: $(cat "$WORK/lane-ok.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["writes"]=sys.argv[3]; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-writes.json" "$SPEC"
python3 "$SUT" "$WORK/lane-writes.json" --base 4ccb59d --chief BZ --bucket "$WORK/lane-writes" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-writes.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'handover root' "$WORK/lane-writes.err" && [ ! -e "$WORK/lane-writes/launch-N901.sh" ] && pass "the new writes field preserves the lane handover-root restriction" || fail "lane writes restriction rc=$rc"
# A non-native worker with no model key takes the lane's model: no native model argument in the launcher, the lane model in the brief header.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-nomodel.json"
python3 "$SUT" "$WORK/lane-nomodel.json" --base 4ccb59d --chief BZ --bucket "$WORK/b20" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-nomodel.err"; rc=$?
[ "$rc" = 0 ] && [ -s "$WORK/b20/launch-N901.sh" ] && [ -n "$(find "$WORK/b20" -name 'HIMMEL-9001-N901-*.md')" ] && pass "a claudex worker with no model key generates its brief and launcher (rc 0)" || fail "claudex no-model rc=$rc: $(cat "$WORK/lane-nomodel.err")"
# claudex is a live lane: nothing the generator writes or prints calls it dormant.
lacks "a claudex worker's brief carries no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$(find "$WORK/b20" -name 'HIMMEL-9001-N901-*.md' | head -n 1)")" "dormant"
lacks "a claudex worker's launcher carries no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$WORK/b20/launch-N901.sh")" "dormant"
lacks "a claudex worker's generation prints no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$WORK/lane-nomodel.err")" "dormant"
lacks "a claudex worker with no model key passes no native model argument" "$(cat "$WORK/b20/launch-N901.sh")" "claude-sonnet-5-5"
lacks "a claudex worker with no model key leaves the lane default to headed-arm-worker" "$(cat "$WORK/b20/launch-N901.sh")" "gpt-6.1-sol"
has "its brief header names the lane model and the lane" "$(cat "$WORK/b20"/HIMMEL-9001-N901-*.md)" "gpt-6.1-sol, claudex"
# A claudex worker's named model is the launcher's trailing model argument, and headed-arm-worker.sh hands it to
# scripts/claude-codex as CODEX_MODEL: the launcher's own arguments, run as a dry run.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="gpt-6-astra"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-astra.json"
python3 "$SUT" "$WORK/lane-astra.json" --base 4ccb59d --chief BZ --bucket "$WORK/b20a" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "a claudex worker with a model key passes it as the launcher's model argument" "$(grep -F headed-arm-worker.sh "$WORK/b20a/launch-N901.sh")" '.log" gpt-6-astra >'
mkdir -p "$WORK/astra-arm"; grep -v '^resume_cwd:' "$(find "$WORK/b20a" -name 'HIMMEL-9001-N901-*.md' | head -n 1)" > "$WORK/astra-arm/HIMMEL-9001-N901-copy.md"
rc=0; astra_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --lane claudex --profile worker-impl HIMMEL-9001-N901 "$WORK/astra-arm/HIMMEL-9001-N901-copy.md" "$WORK/astra-arm/signal" 9999999999 "$WORK/astra-arm/log" gpt-6-astra 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "the generated claudex brief arms with the named model" || fail "claudex brief refused by headed-arm-worker.sh rc=$rc: $astra_out"
has "and the named model reaches the worker as CODEX_MODEL" "$astra_out" "CODEX_MODEL=gpt-6-astra"
lacks "and the claudex launch prints no dormant warning" "$(printf '%s' "$astra_out" | tr '[:upper:]' '[:lower:]')" "dormant"
# An effort key exports WORKER_SESSION_EFFORT in the launcher.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["effort"]="high"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-effort.json"
python3 "$SUT" "$WORK/lane-effort.json" --base 4ccb59d --chief BZ --bucket "$WORK/b21" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "an effort key exports WORKER_SESSION_EFFORT in the launcher" "$(cat "$WORK/b21/launch-N901.sh")" "export WORKER_SESSION_EFFORT=high"
# An opus model on a non-native lane is refused before anything is written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-opus.json"
python3 "$SUT" "$WORK/lane-opus.json" --base 4ccb59d --chief BZ --bucket "$WORK/b22" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-opus.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-opus.err" && [ ! -e "$WORK/b22/launch-N901.sh" ] && pass "an opus model on a non-native lane is refused before anything is written" || fail "opus on claudex rc=$rc"

# The scope's LAST completes-ticket value becomes one dedicated machine-readable
# line (merge-on-green.sh reads it from the worker doc); a scope stating neither writes no line.
ct_brief() { # <scope text> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]=sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ct.json" "$1" || { fail "completes-ticket fixture setup failed"; return 1; }
    python3 "$SUT" "$WORK/ct.json" --base 4ccb59d --chief BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ct.err" || fail "completes-ticket scope generation rc=$?: $(cat "$WORK/ct.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["writes"]="scripts/wr/a.sh docs/writes-only.md"; l[0]["scope"]="scripts/wr-context/read.sh. Stay off scripts/lib/. completes-ticket: no"; l[0]["prior"]="HIMMEL-9000: docs/prior.md"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/wr.json"
python3 "$SUT" "$WORK/wr.json" --base 4ccb59d --chief BZ --bucket "$WORK/wr1" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/wr.err"; wr_rc=$?
[ "$wr_rc" = 0 ] && pass "explicit ticket Writes text generates" || fail "explicit Writes generation rc=$wr_rc: $(cat "$WORK/wr.err")"
wr_brief="$(cat "$WORK/wr1"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
wr_line="$(printf '%s\n' "$wr_brief" | grep '^> \*\*Writes:\*\* ')"
[ "$wr_line" = "> **Writes:** scripts/wr/a.sh docs/writes-only.md" ] && pass "Writes derives only from the ticket Writes text, never scope or prior (HIMMEL-7949)" || fail "Writes must use the explicit writes key only: $wr_line"
wr_note="$(printf '%s\n' "$wr_brief" | grep '^> \*\*Writes note:\*\* ')"
has "Writes note retains scope context" "$wr_note" "scripts/wr-context/read.sh"
has "Writes note retains stay-off paths" "$wr_note" "Stay off scripts/lib/"
has "Writes note retains prior art paths" "$wr_note" "docs/prior.md"
has "the original prior art field stays" "$wr_brief" "> **Prior art:** HIMMEL-9000: docs/prior.md"
has "the original scope field stays" "$wr_brief" "> **Scope / do not:** writes confined to scripts/wr-context/read.sh. Stay off scripts/lib/. completes-ticket: no"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0].pop("writes",None); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/wr-empty.json"
python3 "$SUT" "$WORK/wr-empty.json" --base 4ccb59d --chief BZ --bucket "$WORK/wr-empty" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/wr-empty.err"; wr_rc=$?
[ "$wr_rc" = 0 ] && pass "missing optional writes still generates a draft" || fail "missing writes generation rc=$wr_rc"
wr_empty_doc="$(find "$WORK/wr-empty" -name '*.md' 2>/dev/null)"
[ "$(grep '^> \*\*Writes:\*\*' "$wr_empty_doc")" = "> **Writes:** " ] && pass "missing writes renders an empty Writes line, never inferred holds" || fail "missing writes must render an empty Writes line"
bash "$HERE/brief-lint.sh" "$wr_empty_doc" 2>"$WORK/wr-empty-lint.err"; wr_rc=$?
[ "$wr_rc" = 1 ] && grep -q 'chief' "$WORK/wr-empty-lint.err" && pass "empty generated Writes is refused until the chief fills it" || fail "empty generated Writes did not fail lint with the chief hint (rc=$wr_rc)"
ct_count() { printf '%s\n' "$1" | grep -c '^> \*\*Completes ticket:\*\* '; }
ct_no="$(ct_brief 'one PR. completes-ticket: no' "$WORK/ct1")"
has "scope ending completes-ticket: no writes the no line" "$ct_no" "> **Completes ticket:** no"
[ "$(ct_count "$ct_no")" = 1 ] && pass "exactly one Completes ticket line (no)" || fail "Completes ticket line count (no) = $(ct_count "$ct_no")"
ct_yes="$(ct_brief 'one PR. completes-ticket: yes' "$WORK/ct2")"
has "scope ending completes-ticket: yes writes the yes line" "$ct_yes" "> **Completes ticket:** yes"
[ "$(ct_count "$ct_yes")" = 1 ] && pass "exactly one Completes ticket line (yes)" || fail "Completes ticket line count (yes) = $(ct_count "$ct_yes")"
ct_last="$(ct_brief 'completes-ticket: yes in the middle, but later completes-ticket: no' "$WORK/ct3")"
has "the LAST completes-ticket value wins" "$ct_last" "> **Completes ticket:** no"
lacks "an earlier, overridden value writes no yes line" "$ct_last" "> **Completes ticket:** yes"
ct_none="$(ct_brief 'one PR, nothing stated' "$WORK/ct4")"
[ "$(ct_count "$ct_none")" = 0 ] && pass "a scope stating neither writes no Completes ticket line" || fail "Completes ticket line written without a stated value"
# The Ship step states the same value and the matching merge command (one value per brief).
lacks "a completes-ticket: no brief states no 'completes-ticket: yes' anywhere" "$ct_no" "completes-ticket: yes"
ship_no="$(printf '%s\n' "$ct_no" | grep '^> 4\. Ship:')"
lacks "a completes-ticket: no Ship step has no --jira-transition" "$ship_no" "--jira-transition"
has "a completes-ticket: no Ship step merges bare" "$ship_no" 'merge-on-green.sh`'
has "a completes-ticket: no Ship step leaves the ticket In Progress" "$ship_no" "In Progress"
ship_yes="$(printf '%s\n' "$ct_yes" | grep '^> 4\. Ship:')"
has "a completes-ticket: yes Ship step keeps --jira-transition" "$ship_yes" "merge-on-green.sh --jira-transition"
has "a completes-ticket: yes Ship step states yes" "$ship_yes" "completes-ticket: yes"
ship_last="$(printf '%s\n' "$ct_last" | grep '^> 4\. Ship:')"
lacks "the LAST value (no) also drives the Ship step" "$ship_last" "--jira-transition"
has "the LAST value (no) writes the bare-merge Ship wording" "$ship_last" "completes-ticket: no (leave the ticket In Progress after MERGED)"
ship_none="$(printf '%s\n' "$ct_none" | grep '^> 4\. Ship:')"
has "a scope stating neither keeps the yes Ship step" "$ship_none" "merge-on-green.sh --jira-transition"
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step names the relative merge spelling" "$ship_yes" '`bash scripts/handover/merge-on-green.sh --jira-transition`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step names the relative merge spelling" "$ship_no" '`bash scripts/handover/merge-on-green.sh`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step ends the merge with the --go GO file" "$ship_yes" 'then `--go <the GO file'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step ends the merge with the --go GO file" "$ship_no" 'then `--go <the GO file'
# A claudex worker's classifier refuses merge-path actions, so its Ship step ends at READY: no
# merge command anywhere in the brief, the chief is named as the merger, and the worker waits
# for MERGED. A native worker of the same scope keeps the merge step (asserted above).
cx_brief() { # <completes value> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/cx.json" "$1" || { fail "claudex ship fixture setup failed"; return 1; }
    python3 "$SUT" "$WORK/cx.json" --base 4ccb59d --chief BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/cx.err" || fail "claudex ship generation rc=$?: $(cat "$WORK/cx.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
cx_no="$(cx_brief no "$WORK/cx1")"
ship_cx="$(printf '%s\n' "$cx_no" | grep '^> 4\. Ship:')"
lacks "a claudex Ship step has no merge-on-green.sh" "$ship_cx" "merge-on-green.sh"
lacks "a claudex Ship step has no merge-on-GO clause" "$ship_cx" "Merge only on GO"
has "a claudex Ship step names the chief as the merger" "$ship_cx" "the chief merges"
has "a claudex Ship step waits for MERGED" "$ship_cx" "MERGED #<pr>"
has "a claudex Ship step still ends at READY" "$ship_cx" 'READY <pr> <full-40-hex-head> GREEN'
has "a claudex completes-ticket: no Ship step keeps the clause" "$ship_cx" "completes-ticket: no"
lacks "the claudex brief carries no merge-on-green.sh anywhere" "$cx_no" "merge-on-green.sh"
cx_yes="$(cx_brief yes "$WORK/cx2")"
ship_cxy="$(printf '%s\n' "$cx_yes" | grep '^> 4\. Ship:')"
lacks "a claudex completes-ticket: yes Ship step has no merge-on-green.sh" "$ship_cxy" "merge-on-green.sh"
has "a claudex completes-ticket: yes Ship step keeps the clause" "$ship_cxy" "completes-ticket: yes"
bash "$HERE/brief-lint.sh" "$WORK"/cx1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-cx.err"; rc=$?
[ "$rc" = 0 ] && pass "a claudex brief with the chief-merges Ship step passes brief-lint.sh" || fail "claudex brief-lint rc=$rc: $(cat "$WORK/lint-cx.err")"
bash "$HERE/brief-lint.sh" "$WORK"/ct1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-ct.err"; rc=$?
[ "$rc" = 0 ] && pass "a brief with the Completes ticket line passes brief-lint.sh" || fail "Completes ticket brief-lint rc=$rc: $(cat "$WORK/lint-ct.err")"

# A completes-ticket value other than yes or no is refused (it used to fall through to the closing
# merge): nothing is written, and the message names the worker label and the value. Case is ignored.
# shellcheck disable=SC2016  # the backticks are literal characters in the value under test
for bad in partial maybe yess '"no"' '`yes`'; do
    rm -rf "$WORK/ctb-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ctb.json" "$bad"
    python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --chief BZ --bucket "$WORK/ctb-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
    [ "$rc" = 1 ] && grep -q "N901" "$WORK/ctb.err" && grep -qF -- "$bad" "$WORK/ctb.err" && pass "completes-ticket: $bad is refused naming the worker and the value" || fail "completes-ticket: $bad rc=$rc: $(cat "$WORK/ctb.err")"
    [ ! -e "$WORK/ctb-out/launch-N901.sh" ] && ! ls "$WORK/ctb-out"/*.md >/dev/null 2>&1 && pass "and nothing is written for $bad" || fail "files written for completes-ticket: $bad"
done
ct_mixed="$(ct_brief 'one PR. completes-ticket: YES' "$WORK/ct5")"
has "an upper-case YES still writes the yes line" "$ct_mixed" "> **Completes ticket:** yes"
ct_mixed="$(ct_brief 'one PR. completes-ticket: No' "$WORK/ct6")"
has "a mixed-case No still writes the no line" "$ct_mixed" "> **Completes ticket:** no"
ct_nl="$(ct_brief "one PR. completes-ticket:
no" "$WORK/ct7")"
has "a value on the next line is read, not refused as empty" "$ct_nl" "> **Completes ticket:** no"
# A bad value earlier in the scope is refused even when a good one comes last.
rm -rf "$WORK/ctb-early"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="completes-ticket: partial, later completes-ticket: no"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ctb.json"
python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --chief BZ --bucket "$WORK/ctb-early" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
[ "$rc" = 1 ] && pass "an earlier bad value is refused even when the last value is no" || fail "early bad value rc=$rc"

# Windows and WSL are dropped: a worker whose title, desc, why or scope names them is refused (rc 1,
# nothing written) unless it sets platform_removal AND its title says it removes something.
# pl_gen <title> <field> <value> [platform_removal]: one worker with <field> set to <value>.
pl_gen() {
    rm -rf "$WORK/pl-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0][sys.argv[3]]=sys.argv[4]
if len(sys.argv)>5: l[0]["platform_removal"]=True if sys.argv[5]=="yes" else sys.argv[5]
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/pl.json" "$@"
    python3 "$SUT" "$WORK/pl.json" --base 4ccb59d --chief BZ --bucket "$WORK/pl-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pl.err"
}
pl_written() { [ -n "$(find "$WORK/pl-out" -type f -print -quit 2>/dev/null)" ]; }
pl_complete() { ls "$WORK/pl-out"/*.md >/dev/null 2>&1 && ls "$WORK/pl-out"/launch-*.sh >/dev/null 2>&1; }
pl_gen title 'AG-UI session name handles Windows cwd separators'; rc=$?
[ "$rc" = 1 ] && grep -q "N901" "$WORK/pl.err" && grep -qi "windows" "$WORK/pl.err" && ! pl_written && pass "a worker titled with Windows is refused, naming the worker, nothing written" || fail "windows title rc=$rc: $(cat "$WORK/pl.err")"
pl_gen desc 'run the WSL codex lane'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a desc naming WSL is refused" || fail "wsl desc rc=$rc"
pl_gen scope 'the .ps1 twin'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a scope naming a .ps1 file is refused" || fail "ps1 scope rc=$rc"
pl_gen writes 'scripts/old.ps1'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "the new writes field preserves the dropped-platform restriction" || fail "ps1 writes rc=$rc"
pl_gen why 'it breaks under Git Bash'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a why naming Git Bash is refused" || fail "git bash why rc=$rc"
pl_gen title 'Remove Windows leftovers' yes; rc=$?
[ "$rc" = 0 ] && pl_complete && pass "a Windows removal worker with platform_removal true is accepted" || fail "removal worker rc=$rc: $(cat "$WORK/pl.err")"
pl_gen title 'Fix Windows leftovers' yes; rc=$?
[ "$rc" = 1 ] && grep -q "platform_removal" "$WORK/pl.err" && ! pl_written && pass "platform_removal true on a non-removal title is refused" || fail "non-removal platform_removal rc=$rc: $(cat "$WORK/pl.err")"
for bad in false yes 1; do
    pl_gen title 'Remove Windows leftovers' "$bad"; rc=$?
    case "$bad" in yes) want=0 ;; *) want=1 ;; esac
    [ "$rc" = "$want" ] && pass "platform_removal $bad on a removal title exits $want (only boolean true is the exemption)" || fail "platform_removal $bad rc=$rc"
done
for bad in 'Fix Windows dropdown rendering' 'Fix the Windows cleanroom'; do
    pl_gen title "$bad" yes; rc=$?
    [ "$rc" = 1 ] && ! pl_written && pass "platform_removal true on '$bad' is refused (no removal verb)" || fail "'$bad' with platform_removal rc=$rc"
done
for good in 'Drop Windows support' 'Sweep Windows leftovers' 'Retire the WSL lane' 'Delete the .ps1 twins' 'Clean up Windows paths' 'Removing Windows code'; do
    pl_gen title "$good" yes; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "platform_removal true on '$good' is accepted" || fail "'$good' with platform_removal rc=$rc: $(cat "$WORK/pl.err")"
done
for ok in 'Close WRAPPED chief windows' 'Stop worker windows piling up' 'Spread work over 5-hour windows' 'Trim the context-windows report'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is chief wording, not the OS" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done
# Fail closed: with the pattern file gone the script exits 2 rather than briefing unfiltered.
NF="$WORK/nopat"; mkdir -p "$NF"; cp "$SUT" "$NF/gen-briefs.py"
python3 "$NF/gen-briefs.py" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$NF/out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$rc"
pl_gen title 'Remove runtime Windows compatibility'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "'runtime Windows' is not excused by the time-window qualifier" || fail "runtime Windows rc=$rc"
for ok in 'cap the context window' 'widen the time window' 'Windowed rate limit' 'the context windows budget'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is not a platform mention" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done

# Every worker and chief pays these two files on every turn: keep the always-on core small
# (rarely-read rules live in docs/handover/worker-sections/ and chief-sections/).
HANDOVER_DOCS="${HANDOVER_DOCS:-$HERE/../../../docs/handover}"
# worker-preface.md carries the adapter-repo stop-at-READY rule, so its budget is 12800.
for budget in "worker-preface.md:12800" "chief-template.md:16637"; do
    f="${budget%%:*}"; max="${budget##*:}"
    size="$(wc -c < "$HANDOVER_DOCS/$f" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$size" ] && [ "$size" -le "$max" ] && pass "$f is within its byte budget ($size <= $max)" || fail "$f is over its byte budget (${size:-missing} > $max)"
done

tr '\n' ' ' < "$HANDOVER_DOCS/worker-preface.md" | grep -Eq 'ONE +turn.*text-only turn' \
    && pass "worker-preface.md tells a worker to batch tool calls into ONE turn and skip text-only turns" \
    || fail "worker-preface.md lacks the batch-tool-calls / no text-only turn rule"

# The renamed templates are regular files and the old paths are gone.
for pair in leg-preface.md:worker-preface.md console-template.md:chief-template.md leg-brief-template.md:worker-brief-template.md; do
    old="${pair%%:*}"; new="${pair##*:}"
    [ -f "$HANDOVER_DOCS/$new" ] && [ ! -L "$HANDOVER_DOCS/$new" ] && pass "$new is a regular file" || fail "$new is missing or not a regular file"
    [ ! -e "$HANDOVER_DOCS/$old" ] && [ ! -L "$HANDOVER_DOCS/$old" ] && pass "$old is gone" || fail "$old still exists"
done
# A worker launched through the launcher's default preface path (the plain
# worker branch, last of the role defaults) gets the worker preface.
# shellcheck disable=SC2016  # $HERE is the launcher's literal text, matched not expanded
launch_preface="$(sed -n 's#.*PREFACE:-\$HERE/../../../\(docs/handover/[a-z-]*\.md\)}.*#\1#p' "$HERE/headed-arm-worker.sh" | tail -n 1)"
[ -n "$launch_preface" ] && cmp -s "$HERE/../../../$launch_preface" "$HANDOVER_DOCS/worker-preface.md" \
    && pass "the launcher's default preface ($launch_preface) is the worker preface, byte for byte" \
    || fail "the launcher's default preface (${launch_preface:-unparsed}) is not the worker preface"

# --- bare --bucket resolves under the handover root; --no-worktree needs a real worktree ---
# (the rows above stub the worktree step, so they skip the existing-worktree check)
mkdir -p "$WORK/hr/tester" "$WORK/gitcwd"
git -C "$WORK/gitcwd" init -q 2>/dev/null
rc=0; (cd "$WORK/gitcwd" && USER_SLUG=tester python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket himmel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree --manifest "$WORK/fb.json" >"$WORK/bb.out" 2>"$WORK/bb.err") || rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/hr/tester/himmel/launch-N901.sh" ] && pass "a bare --bucket resolves to <handover-root>/<user>/<bucket>" || fail "bare bucket rc=$rc: $(cat "$WORK/bb.err")"
[ ! -e "$WORK/gitcwd/himmel" ] && pass "and writes no stray dir under the cwd" || fail "stray himmel/ dir under the cwd"
grep -q -- "$WORK/hr/tester/himmel/HIMMEL-9001-N901" "$WORK/hr/tester/himmel/launch-N901.sh" 2>/dev/null && pass "the launcher passes an absolute doc path" || fail "launcher doc path not absolute"
rc=0; (cd "$WORK" && python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket ./gitcwd/rel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/rel.out" 2>"$WORK/rel.err") || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/rel.err" && [ ! -e "$WORK/gitcwd/rel" ] && pass "a path --bucket inside a git checkout (outside the handover root) is refused" || fail "git-checkout bucket rc=$rc: $(cat "$WORK/rel.err")"
ln -s "$WORK/gitcwd" "$WORK/hr/tester/link"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/link/sub" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/lnk.err" || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/lnk.err" && [ ! -e "$WORK/gitcwd/sub" ] && pass "a bucket under a handover-root symlink into a git checkout is refused" || fail "symlink bucket rc=$rc: $(cat "$WORK/lnk.err")"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/abs" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "RED control: an absolute --bucket works unchanged" || fail "absolute bucket rc=$rc"
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/nw" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/nw.out" 2>"$WORK/nw.err") || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/nw/launch-N901.sh" ] && pass "--no-worktree with a missing worktree exits 1 and writes nothing" || fail "no-worktree rc=$rc"
has "and prints the exact worktree.sh line" "$(cat "$WORK/nw.err")" "bash scripts/worktree.sh new fix/himmel-9001-plain-fix --no-prune"
NWREPO="$WORK/nwrepo"; git init -q "$NWREPO" && git -C "$NWREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9001-plain-fix" -b fix/himmel-9001-plain-fix 2>/dev/null
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9002-hook-fix" -b fix/himmel-9002-hook-fix 2>/dev/null
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/nw2" --repo "$NWREPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/nw2.err") || rc=$?
[ "$rc" = 0 ] && pass "RED control: --no-worktree with existing worktrees works unchanged" || fail "existing worktrees rc=$rc: $(cat "$WORK/nw2.err")"

# --- an adopted repo (a git checkout with no chief-kit of its own): the worktree is made by
# himmel's _new-worktree.sh run inside the adopter, and the launcher names himmel's kit and exports the
# adopter worktree as WORKER_SESSION_REPO (headed-arm.sh starts the session in that dir) ---
KIT="$WORK/kit"; mkdir -p "$KIT/scripts/handover/chief-kit"
mkdir -p "$KIT/scripts/ci"
cp "$SUT" "$HERE/platform-dropped.re" "$KIT/scripts/handover/chief-kit/"
cp "$HERE/../../ci/ci-trust-paths.txt" "$HERE/../../ci/pr-size-bands.tsv" "$KIT/scripts/ci/"
mkdir -p "$KIT/scripts/lib"; cp "$HERE/../../lib/flags.py" "$HERE/../../lib/flags.tsv" "$KIT/scripts/lib/"
export ADP_WT_LOG="$WORK/adp-wt.log"
cat > "$KIT/scripts/_new-worktree.sh" <<'EOF'
#!/usr/bin/env bash
[ "$2" = --no-install ] || { echo "_new-worktree.sh stub: unexpected 2nd argument [$2]" >&2; exit 64; }
printf '%s|%s|%s\n' "$PWD" "$1" "$2" >> "$ADP_WT_LOG"
git worktree add -q "$PWD/.claude/worktrees/${1//\//+}" -b "$1"
EOF
ADP="$WORK/adapter"; git init -q "$ADP" && git -C "$ADP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ADPBASE="$(git -C "$ADP" rev-parse HEAD)"
rc=0; env -u GEN_BRIEFS_WORKTREE_CMD python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp" --repo "$ADP" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 --manifest "$WORK/adp.fleet.json" >"$WORK/adp.out" 2>"$WORK/adp.err" || rc=$?
[ "$rc" = 0 ] && pass "an adopted repo generates (rc 0)" || fail "adopted repo rc=$rc: $(cat "$WORK/adp.err") $(cat "$WORK/adp.out")"
has "the adopter worktree is made by himmel's _new-worktree.sh run inside the adopter, without the install step" "$(cat "$WORK/adp-wt.log" 2>/dev/null)" "$ADP|fix/himmel-9001-plain-fix|--no-install"
has "and so is the second worker's" "$(cat "$WORK/adp-wt.log" 2>/dev/null)" "$ADP|fix/himmel-9002-hook-fix|--no-install"
al="$(cat "$WORK/hr/tester/adp/launch-N901.sh" 2>/dev/null)"
has "the adopter launcher names himmel's headed-arm-worker.sh" "$al" "$KIT/scripts/handover/chief-kit/headed-arm-worker.sh --profile worker-impl"
lacks "and not a copy under the adopter" "$al" "$ADP/scripts/handover/chief-kit/"
has "the adopter launcher exports the adopter worktree as WORKER_SESSION_REPO" "$al" "export WORKER_SESSION_REPO=$ADP/.claude/worktrees/fix+himmel-9001-plain-fix"
has "the adopter launcher's manifest add uses himmel's fleet-manifest.sh" "$al" "$KIT/scripts/handover/chief-kit/fleet-manifest.sh add"
has "the adopter brief's ticket-read line uses himmel's jira CLI" "$(cat "$WORK"/hr/tester/adp/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)" "node $KIT/scripts/jira/dist/index.js get HIMMEL-9001"
lacks "RED control: a himmel-repo launcher exports no WORKER_SESSION_REPO" "$l1" "WORKER_SESSION_REPO"
ADP2="$WORK/adapter2"; git init -q "$ADP2"
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp2" --repo "$ADP2" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/adp2.err") || rc=$?
has "an adopter --no-worktree refusal prints himmel's _new-worktree.sh line, not a worktree.sh the adopter lacks" "$(cat "$WORK/adp2.err")" "$KIT/scripts/_new-worktree.sh fix/himmel-9001-plain-fix --no-install"
[ "$rc" = 1 ] && [ ! -e "$WORK/hr/tester/adp2/launch-N901.sh" ] && pass "and exits 1 writing no launcher" || fail "adopter no-worktree refusal rc=$rc"
rc=0; (cd "$WORK" && unset GEN_BRIEFS_NO_WT_CHECK; python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp3" --repo adapter --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/adp3.err") || rc=$?
has "a relative --repo still exports an absolute worktree path" "$(cat "$WORK/hr/tester/adp3/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_REPO=$ADP/.claude/worktrees/fix+himmel-9001-plain-fix"

# --- the rm kind: a release-manager brief filled from docs/handover/rm-brief-template.md ---
cat > "$WORK/rm.json" <<EOF
[
 {"kind":"rm","label":"N910","keys":["HIMMEL-9010"],"slug":"rm","release":"R1","versions":"v1 + v2, current v1","epoch":3,"state_dir":"$WORK/hr/tester/himmel/release/R1","mode":"observe"}
]
EOF
: > "$WT_LOG"
# an rm worker with an ab_arm is refused: its launcher applies no A/B arm
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="400k"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/rm.json" "$WORK/rm-ab.json"
rc=0; python3 "$SUT" "$WORK/rm-ab.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmb-ab" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >/dev/null 2>"$WORK/rm-ab.err" || rc=$?
[ "$rc" = 1 ] && grep -q 'ab_arm' "$WORK/rm-ab.err" && [ ! -e "$WORK/rmb-ab/launch-N910.sh" ] && pass "an rm worker with an ab_arm is refused before anything is written (HIMMEL-7811)" || fail "rm ab_arm rc=$rc"
rmout="$(python3 "$SUT" "$WORK/rm.json" --base 4ccb59d --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/rmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 --manifest "$WORK/rmf.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "an rm worker generates (rc 0)" || fail "rm rc=$rc: $rmout"
RMD="$WORK/rmb/HIMMEL-9010-N910-rm-R1-2026-10-08.md"
[ -f "$RMD" ] && [ -f "$WORK/rmb/launch-N910.sh" ] && pass "an rm worker writes <KEY>-<label>-rm-<R>-<date>.md and its launcher" || fail "rm files missing in $WORK/rmb"
[ ! -s "$WT_LOG" ] && pass "an rm worker creates no worktree" || fail "worktree stub called: $(cat "$WT_LOG")"
RMB="$(sed 's/^> *//' "$RMD" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
has "the rm brief carries the release and its versions" "$RMB" 'Release manager for R1 (v1 + v2, current v1)'
has "the rm brief names the lease epoch to acquire" "$RMB" '--expect-epoch 3'
has "the rm brief names the state directory" "$RMB" "State directory \`$WORK/hr/tester/himmel/release/R1\`"
has "the rm brief carries a minted token in the RM shape" "$RMB" 'BZ-RM-R1-'
has "the rm brief carries the opus tier line" "$RMB" '**Tier:** opus'
has "the rm brief resumes in the release scratch dir" "$(head -3 "$RMD" 2>/dev/null)" "/.cache/himmel/rm/R1/scratch"
if sed 's/REQ <id>/REQ/' "$RMD" 2>/dev/null | grep -Eq '<[A-Za-z$]'; then fail "the rm brief keeps an unfilled placeholder: $(sed 's/REQ <id>/REQ/' "$RMD" | grep -E '<[A-Za-z$]' | head -2)"; else pass "the rm brief keeps no unfilled placeholder"; fi
RML="$(cat "$WORK/rmb/launch-N910.sh" 2>/dev/null)"
has "the rm launcher arms the release-manager profile for its release" "$RML" '--profile release-manager --rm-release R1'
has "the rm launcher skips the prior-art lint an rm brief has no field for" "$RML" '--no-prior-art-check'
has "the printed manifest line is native" "$rmout" "--lane native"
rmbad() { # <name> <python edit> <stderr fragment>: refused, rc 1, nothing written
    local n="$1" edit="$2" frag="$3"
    rm -rf "$WORK/rmbad" "$WORK/rmbad.json"
    python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); d=l[0]; $edit; json.dump(l,open(sys.argv[2],'w'))" "$WORK/rm.json" "$WORK/rmbad.json" || { fail "$n (fixture setup failed)"; return; }
    python3 "$SUT" "$WORK/rmbad.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmbad" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/rmbad.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/rmbad.err" && ! ls "$WORK/rmbad"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/rmbad.err"))"; fi
}
rmbad "an rm worker with a release holding a slash is refused" 'd["release"]="a/b"' "release"
rmbad "an rm worker with a non-integer epoch is refused" 'd["epoch"]="three"' "epoch"
rmbad "an rm worker with a negative epoch is refused" 'd["epoch"]=-1' "epoch"
rmbad "an rm worker with a mode other than observe or live is refused" 'd["mode"]="dry"' "mode"
rmbad "an rm worker missing its state_dir is refused" 'del d["state_dir"]' "state_dir"
rmbad "an rm worker on a non-native lane is refused" 'd["lane"]="claudex"' "lane"
rmbad "an rm worker whose state_dir names another release is refused" 'd["state_dir"]="/h/tester/himmel/release/R2"' "must end in release/R1"
rmbad "an rm worker whose state_dir is not under a release directory is refused" 'd["state_dir"]="/h/tester/himmel/R1"' "must end in release/R1"
rmbad "an rm worker on a non-opus model is refused" 'd["model"]="claude-sonnet-5-5"' "opus"

# --- a brief naming VM work carries the guest-exec line; one that does not stays without it ---
python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); l[0]['why']='the install must be proven on a test VM first'; json.dump(l,open(sys.argv[2],'w'))" "$WORK/workers.json" "$WORK/vmlegs.json"
rc=0; python3 "$SUT" "$WORK/vmlegs.json" --base 4ccb59d --chief BZ --bucket "$WORK/vmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/vm.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "a workers file naming VM work generates (rc 0)" || fail "vm workers rc=$rc: $(cat "$WORK/vm.out")"
VMB1="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
VMB2="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9002-N902-hook-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
has "a brief naming VM work says to drive the guest only through guest-exec.sh" "$VMB1" "drive the guest only through guest-exec.sh"
lacks "a brief that names no VM work does not carry the guest-exec line" "$VMB2" "guest-exec.sh"
bash "$HERE/brief-lint.sh" "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>"$WORK/vmlint.err"; rc=$?
[ "$rc" = 0 ] && pass "the VM brief passes brief-lint.sh" || fail "vm brief brief-lint rc=$rc: $(cat "$WORK/vmlint.err")"

# --- a grants list renders a Pre-granted follow-ups block; a grant reaching a forbidden path or a bypass is refused ---
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["grants"]=[{"text":"add the RED row to the harness suite","paths":["scripts/handover/chief-kit/test-gen-briefs.sh"]},{"text":"mirror the change in the twin","paths":["scripts/a.sh","scripts/b.sh"]}]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/gr.json" || fail "grants fixture setup failed"
python3 "$SUT" "$WORK/gr.json" --base 4ccb59d --chief BZ --bucket "$WORK/gr" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/gr.err"; rc=$?
[ "$rc" = 0 ] && pass "a worker with grants generates (rc 0)" || fail "grants rc=$rc: $(cat "$WORK/gr.err")"
GR="$(cat "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
has "a brief with grants carries the Pre-granted follow-ups block" "$GR" "> **Pre-granted follow-ups** (HIMMEL-7091)"
# shellcheck disable=SC2016 # literal backticks in the sed pattern
GR_NONCE="$(sed -n 's/^> \*\*RETASK:\*\* your nonce is `\([^`]*\)`.*/\1/p' "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md)"
if [ -n "$GR_NONCE" ]; then has "the grants block binds the ruling to the worker's own nonce" "$GR" "\`RULING $GR_NONCE grant=<Gn> :: <action>\`"; else fail "no RETASK nonce in the grants brief"; fi
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "G1 names its text and backticked path" "$GR" '> - G1 add the RED row to the harness suite: `scripts/handover/chief-kit/test-gen-briefs.sh`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "G2 lists every path it names" "$GR" '> - G2 mirror the change in the twin: `scripts/a.sh`, `scripts/b.sh`'
has "an off-grant ruling gets a needs-rebrief FINDING" "$GR" "FINDING needs-rebrief <Gn>"
bash "$HERE/brief-lint.sh" "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/grlint.err"; rc=$?
[ "$rc" = 0 ] && pass "the grants brief passes brief-lint.sh" || fail "grants brief brief-lint rc=$rc: $(cat "$WORK/grlint.err")"
lacks "a worker without grants carries no grants block" "$ct_no" "Pre-granted follow-ups"
grbad() { # <name> <python edit of the grant g> <stderr fragment>
    rm -rf "$WORK/grbad" "$WORK/grbad.json"
    python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); g={'text':'fix the twin','paths':['scripts/a.sh']}; $2; l[0]['grants']=[g]; json.dump(l[:1],open(sys.argv[2],'w'))" "$WORK/workers.json" "$WORK/grbad.json" || { fail "$1 (fixture setup failed)"; return; }
    python3 "$SUT" "$WORK/grbad.json" --base 4ccb59d --chief BZ --bucket "$WORK/grbad" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/grbad.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q -- "$3" "$WORK/grbad.err" && ! ls "$WORK/grbad"/* >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$rc, err: $(cat "$WORK/grbad.err"))"; fi
}
grbad "a grant with no paths is refused" 'g["paths"]=[]' "must name its paths"
grbad "a grant naming a settings file is refused" 'g["paths"]=[".claude/settings.json"]' "settings, CI-workflow or trust path"
grbad "a grant naming a CI workflow is refused" 'g["paths"]=[".github/workflows/ci.yml"]' "settings, CI-workflow or trust path"
grbad "a grant naming a ci-trust-paths file is refused" 'g["paths"]=["scripts/handover/chief-kit/brief-lint.sh"]' "settings, CI-workflow or trust path"
grbad "a grant whose text names a bypass is refused" 'g["text"]="skip review with SKIP_CR"' "never carries a bypass"
grbad "a grant whose text names an amend is refused" 'g["text"]="amend the first commit"' "never carries a bypass"
grbad "a grant with a glob path is refused" 'g["paths"]=["scripts/*.sh"]' "literal repo-relative file path"
grbad "a grant with a parent-relative path is refused" 'g["paths"]=["../x.sh"]' "literal repo-relative file path"
grbad "a dot-prefixed spelling of a workflow path is refused" 'g["paths"]=["./.github/workflows/ci.yml"]' "literal repo-relative file path"
grbad "a doubled-slash spelling of a trust path is refused" 'g["paths"]=["scripts/handover//chief-kit/brief-lint.sh"]' "literal repo-relative file path"
grbad "a grant path with a trailing slash is refused" 'g["paths"]=["scripts/"]' "literal repo-relative file path"
grbad "a grant path naming the repo root is refused" 'g["paths"]=["."]' "literal repo-relative file path"
mkdir -p "$REPO/grantdir" || fail "grantdir fixture setup failed"
grbad "a grant path naming an existing directory is refused" 'g["paths"]=["grantdir"]' "literal repo-relative file path"
grbad "a grant path holding a backtick is refused" 'g["paths"]=["scripts/a`.sh"]' "literal repo-relative file path"
grbad "a grant whose text names a short-flag force push is refused" 'g["text"]="git push -f origin main"' "never carries a bypass"
grbad "a grant whose text names a spaced force push is refused" 'g["text"]="force push the branch"' "never carries a bypass"
grbad "a grant whose text holds a backtick is refused" 'g["text"]="fix "+chr(96)+"x"' "<placeholder>"
grbad "a grant whose text holds a control character is refused" 'g["text"]="fix\tthe twin"' "<placeholder>"
grbad "a grant with a placeholder in its text is refused" 'g["text"]="edit <file>"' "<placeholder>"
grbad "a grant with an extra key is refused" 'g["why"]="x"' "exactly {text, paths}"

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

# --- a ticket whose body lacks a DoD or a Proof is refused, the ticket printed for the chief to fix ---
pm() { # <KEY> <body>: a mirror ticket with that Description
    printf -- '---\nkey: %s\n---\n# %s: t\n\n## Description\n\n%s\n\n## Comments\n\nnone\n' "$1" "$1" "$2" > "$GEN_BRIEFS_MIRROR/$1.md"
}
PROOF_TAIL=$'\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n'
pm HIMMEL-9001 $'Edit scripts/x.\n\nDoD\n- the row is green\n'
pm HIMMEL-9002 "Edit scripts/hooks/h.sh.$PROOF_TAIL"
pm HIMMEL-9003 "Edit the hook.$PROOF_TAIL"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb.err" || rc=$?
[ "$rc" = 1 ] && pass "proof: a ticket with a DoD but no Proof is refused (rc 1)" || fail "proof: no-Proof rc=$rc"
has "proof: the refusal names the ticket and the missing section" "$(cat "$WORK/pb.err")" "HIMMEL-9001 lacks Proof"
has "proof: the refusal prints the ticket body for the chief to fix" "$(cat "$WORK/pb.err")" "Edit scripts/x."
lacks "proof: a ticket that has both is not named" "$(cat "$WORK/pb.err")" "HIMMEL-9002 lacks"
[ ! -e "$WORK/pb/launch-N901.sh" ] && pass "proof: nothing is written for a refused ticket" || fail "proof: wrote files for a refused ticket"
pm HIMMEL-9001 "Edit scripts/x.$PROOF_TAIL"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb.err" || rc=$?
[ "$rc" = 0 ] && pass "proof: tickets that all have DoD and Proof generate" || fail "proof: complete tickets rc=$rc: $(cat "$WORK/pb.err")"
pm HIMMEL-9003 $'Edit the hook.\n\nDoD\n- the row is green\n\nProof\nTBD\n'
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb2.err" || rc=$?
[ "$rc" = 1 ] && has "proof: a placeholder Proof on the second key of a worker is refused" "$(cat "$WORK/pb2.err")" "HIMMEL-9003 lacks Proof" || fail "proof: placeholder rc=$rc"
rm -f "$GEN_BRIEFS_MIRROR/HIMMEL-9003.md"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb3.err" || rc=$?
[ "$rc" = 0 ] && has "proof: a ticket missing from the mirror warns and does not refuse (mirror lag)" "$(cat "$WORK/pb3.err")" "HIMMEL-9003" || fail "proof: absent mirror rc=$rc"

# --- an optional inherited key renders the Inherited PR block; a bad value is refused ---
inh_gen() { # <python expr for the inherited value, or -: writes N901 alone into $WORK/inh; sets inh_rc
    rm -rf "$WORK/inh" "$WORK/inh.json" "$WORK/inh.err"
    inh_rc=1
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]
if sys.argv[3] != "-": l[0]["inherited"]=eval(sys.argv[3])
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/inh.json" "$1" || return 1
    python3 "$SUT" "$WORK/inh.json" --base 4ccb59d --chief BZ --bucket "$WORK/inh" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/inh.err"; inh_rc=$?
}
inh_gen "{'pr': 4033, 'authors': ['Ada Lovelace', 'Alan Turing'], 'mode': 'takeover'}"
inh_brief="$(cat "$WORK/inh"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
[ "$inh_rc" = 0 ] && pass "a worker with a valid inherited key generates (rc 0)" || fail "inherited worker rc=$inh_rc: $(cat "$WORK/inh.err")"
has "a worker with inherited renders the Inherited PR block" "$inh_brief" "> **Inherited PR (the resume of an \`ORPHAN PR\`"
has "the Inherited PR block names the PR number" "$inh_brief" "PR \`4033\`"
has "the Inherited PR block names every original author" "$inh_brief" "by \`Ada Lovelace, Alan Turing\`"
has "the Inherited PR block carries the mode" "$inh_brief" "Mode: \`takeover\`"
has "the Inherited PR block keeps the disposition rule" "$inh_brief" "**Before the first push, decide a disposition**"
inh_gen -
plain_brief="$(cat "$WORK/inh"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
[ "$inh_rc" = 0 ] && [ -n "$plain_brief" ] && lacks "a worker without inherited renders no Inherited PR block" "$plain_brief" "Inherited PR" || fail "plain worker rc=$inh_rc or no brief written"
inhbad() { # <name> <python expr for the inherited value>: refused, rc 1, nothing written
    inh_gen "$2"
    if [ "$inh_rc" = 1 ] && grep -q "inherited" "$WORK/inh.err" && ! ls "$WORK/inh"/*.md >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$inh_rc, err: $(cat "$WORK/inh.err"))"; fi
}
inhbad "an inherited key that is not an object is refused" "'4033'"
inhbad "an inherited key with an empty authors list is refused" "{'pr': 4033, 'authors': [], 'mode': 'resume'}"
inhbad "an inherited key with authors as a bare string is refused" "{'pr': 4033, 'authors': 'Ada', 'mode': 'resume'}"
inhbad "an inherited key with a pr that is not an integer is refused" "{'pr': '4033', 'authors': ['Ada'], 'mode': 'resume'}"
inhbad "an inherited key with a mode other than resume or takeover is refused" "{'pr': 4033, 'authors': ['Ada'], 'mode': 'fork'}"
inhbad "an inherited key with no mode is refused" "{'pr': 4033, 'authors': ['Ada']}"

# A worker whose scope Writes name scripts/config-ui/ launches with worker-e2e (worker-impl plus the
# Playwright MCP server) and its brief says how to look at the page; any other worker stays on worker-impl.
ui_gen() { # <scope prefix or -> <profile key or ->: one worker generated into $WORK/ui
    rm -rf "$WORK/ui"; ui_rc=1
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]
if sys.argv[3] != "-": l[0]["writes"]=sys.argv[3]
if sys.argv[4] != "-": l[0]["profile"]=sys.argv[4]
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ui.json" "$1" "$2" || return 1
    python3 "$SUT" "$WORK/ui.json" --base 4ccb59d --chief BZ --bucket "$WORK/ui" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ui.err"; ui_rc=$?
    ui_launch="$(cat "$WORK/ui"/launch-N901.sh 2>/dev/null)"; ui_brief="$(cat "$WORK/ui"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
}
ui_mcp() { # the mcp= field a dry-run launch with <profile> reports for the generated brief
    mkdir -p "$WORK/uiarm"; grep -v '^resume_cwd:' "$WORK/ui"/HIMMEL-9001-N901-plain-fix-*.md > "$WORK/uiarm/HIMMEL-9001-N901-copy.md"
    HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile "$1" HIMMEL-9001-N901 "$WORK/uiarm/HIMMEL-9001-N901-copy.md" "$WORK/uiarm/signal" 9999999999 "$WORK/uiarm/log" claude-sonnet-5-5 2>&1 | grep -o ' mcp=[^ ]*'
}
ui_gen "Writes scripts/config-ui/page.ts." -
[ "$ui_rc" = 0 ] && pass "a config-ui worker generates (rc 0)" || fail "config-ui worker rc=$ui_rc: $(cat "$WORK/ui.err")"
has "a config-ui worker's launcher arms worker-e2e" "$ui_launch" "--profile worker-e2e --chief BZ"
has "a config-ui worker's brief says the chief starts himmelctl ui from the worker's own worktree" "$ui_brief" "from YOUR worktree"
has "a config-ui worker's brief tells the worker to ask for the URL and never start the UI itself" "$ui_brief" "ask for it, never start it yourself"
lacks "a config-ui worker's brief hands out no standing agent-session bypass" "$ui_brief" "allow-agent-session"
has "a config-ui worker's brief says to open the URL with the browser MCP headless" "$ui_brief" "browser MCP headless"
has "a config-ui worker's brief says to save screenshots to the scratch dir" "$ui_brief" "save screenshots to your scratch dir"
ui_launch_profile="$(printf '%s' "$ui_launch" | grep -o -e '--profile [a-z0-9-]*')"
has "the dry-run launch of a config-ui worker lists playwright among its MCP servers" "$(ui_mcp "${ui_launch_profile#--profile }")" "playwright"
ui_gen "Writes scripts/config-ui/page.ts." worker-bus
has "an explicit worker profile key wins over the config-ui choice" "$ui_launch" "--profile worker-bus --chief BZ"
has "the explicit-profile worker's brief was written" "$ui_brief" "> **Writes:**"
lacks "and a worker off the browser profile gets no browser line" "$ui_brief" "UI work:"
ui_gen - -
[ "$ui_rc" = 0 ] && pass "a non-UI worker generates (rc 0)" || fail "non-UI worker rc=$ui_rc: $(cat "$WORK/ui.err")"
has "a non-UI worker's launcher stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
has "the non-UI worker's brief was written" "$ui_brief" "> **Writes:**"
lacks "a non-UI worker's brief has no browser line" "$ui_brief" "UI work:"

# A worker whose Writes are all under docs/ or are *.md defaults to worker-docs; one code path,
# a missing Writes line, or a config-ui path keeps its profile; worker-eval is only an explicit key.
ui_gen "Writes docs/internals/a.md and README.md." -
has "a docs-only worker's launcher arms worker-docs" "$ui_launch" "--profile worker-docs --chief BZ"
ui_gen "Writes docs/internals/ (a.md)." -
has "a docs/ dir worker arms worker-docs" "$ui_launch" "--profile worker-docs --chief BZ"
ui_gen "Writes docs/internals/a.md and scripts/lib/x.sh." -
has "a worker writing docs and one script stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
for unk in "src/main.py" "Makefile" "LICENSE"; do
  ui_gen "Writes docs/internals/a.md and $unk." -
  has "a docs path plus an unrecognised path ($unk) stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
done
ui_gen "Writes docs/internals/a.md and scripts/config-ui/page.ts." -
has "a docs plus config-ui worker keeps worker-e2e" "$ui_launch" "--profile worker-e2e --chief BZ"
ui_gen "Writes docs/internals/a.md." worker-eval
has "an explicit worker-eval key wins over the docs default" "$ui_launch" "--profile worker-eval --chief BZ"
ui_gen "Writes docs/internals/a.md." worker-impl
has "an explicit worker-impl key wins over the docs default" "$ui_launch" "--profile worker-impl --chief BZ"
ui_launch_profile="$(printf '%s' "$ui_launch" | grep -o -e '--profile [a-z0-9-]*')"
ui_mcp_impl="$(ui_mcp "${ui_launch_profile#--profile }")"
has "the dry-run launch of a non-UI worker reports its MCP servers" "$ui_mcp_impl" 'mcp=["qmd","himmel-bus"]'
lacks "the dry-run launch of a non-UI worker lists no playwright" "$ui_mcp_impl" "playwright"
ui_gen - 'Bad;x'
[ "$ui_rc" = 1 ] && grep -q 'profile' "$WORK/ui.err" && [ ! -e "$WORK/ui/launch-N901.sh" ] && pass "an invalid worker profile is refused before anything is written" || fail "bad profile rc=$ui_rc"

# The brief names every merged contract=no PR of its ticket and the PR body's Remaining: text, so merged work is never redone.
mkdir -p "$WORK/pm-state"
cat > "$WORK/pm-state/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4313","head":"aaa","contract":"no","result":"noop"}
{"ts":"t","event":"derive","key":"HIMMEL-9101","pr":"4313","result":"moved","rule":"D3"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4313","result":"moved","rule":"D3"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4320","head":"bbb","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4340","head":"eee","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4350","head":"fff","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4330","head":"ccc","contract":"yes","result":"moved"}
{"ts":"t","event":"merge","key":"HIMMEL-9102","pr":"4399","head":"ddd","contract":"no","result":"noop"}
EOF
cat > "$WORK/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$3" in
    4313) printf 'Slice C1a of the thing.\n\nRemaining: slices C1b and C4 (the {brace} readers)\n' ;;
    4320) printf 'No remaining line here.\n' ;;
    4340) printf 'Remaining:\n\nAn unrelated section follows.\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$WORK/gh-stub.sh"
cat > "$WORK/pm.json" <<'EOF'
[{"label":"N911","keys":["HIMMEL-9101"],"slug":"pm-fix","branch":"fix/himmel-9101-pm-fix","title":"a partial ticket","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9101] f"},
 {"label":"N912","keys":["HIMMEL-9103"],"slug":"pm-none","branch":"fix/himmel-9103-pm-none","title":"a clean ticket","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9103] f"}]
EOF
pm_out="$(TICKET_STATUS_STATE_DIR="$WORK/pm-state" GEN_BRIEFS_GH_CMD="$WORK/gh-stub.sh" python3 "$SUT" "$WORK/pm.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/pm-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/pmw" --deadline 1791475000 2>&1)"; pm_rc=$?
[ "$pm_rc" = 0 ] && pass "a ticket with partial merges generates (rc 0)" || fail "partial-merge gen rc=$pm_rc: $pm_out"
PM1="$(tr '\n' ' ' < "$WORK/pm-bucket/HIMMEL-9101-N911-pm-fix-2026-10-08.md" | tr -s ' ')"
has "the brief names the merged contract=no PR and its Remaining: text" "$PM1" "PR \`#4313\`: Remaining: slices C1b and C4 (the {brace} readers)"
has "a partial PR whose body has no Remaining: line is marked as needing a chief note" "$PM1" "PR \`#4320\`: needs a chief note"
has "an empty Remaining: line does not borrow the text of the next line" "$PM1" "PR \`#4340\`: needs a chief note"
has "a PR whose body gh cannot read says so, not that it has no Remaining: line" "$PM1" "PR \`#4350\`: needs a chief note (its body could not be read)"
lacks "a contract=yes merge row is not listed as a partial" "$PM1" '#4330'
lacks "another ticket's partial merge is not listed" "$PM1" '#4399'
bash "$HERE/brief-lint.sh" "$WORK/pm-bucket/HIMMEL-9101-N911-pm-fix-2026-10-08.md" 2>"$WORK/lintpm.err"; rc=$?
[ "$rc" = 0 ] && pass "the partial-merge brief passes brief-lint.sh" || fail "partial-merge brief-lint rc=$rc: $(cat "$WORK/lintpm.err")"
lacks "a ticket with no partial merge gets no Already merged block" "$(cat "$WORK/pm-bucket/HIMMEL-9103-N912-pm-none-2026-10-08.md")" "Already merged"
# a status log that exists but cannot be read is reported, not read as "no partial merges"
mkdir -p "$WORK/pm-state-bad/status-events.jsonl"
pm_bad="$(TICKET_STATUS_STATE_DIR="$WORK/pm-state-bad" GEN_BRIEFS_GH_CMD="$WORK/gh-stub.sh" python3 "$SUT" "$WORK/pm.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/pm-bucket2" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/pmw2" --deadline 1791475000 2>&1)"
has "an unreadable status log is warned about, not silently read as empty" "$pm_bad" "status-events.jsonl is unreadable"

# ---- the PR size projection (own block) ----
# A Writes list that expands to more than the hard max of scripts/ci/pr-size-bands.tsv (40 files) is refused with
# pr_size_gate on, unless the worker carries bulk: mechanical; flag off, or past only the soft max (20), is a warning.
PS="$WORK/ps"; mkdir -p "$PS/scripts/big" "$PS/scripts/mid" "$PS/scripts/few"
for n in $(seq 1 41); do echo "$n" > "$PS/scripts/big/f$n.txt"; done
for n in $(seq 1 25); do echo "$n" > "$PS/scripts/mid/f$n.txt"; done
for n in 1 2 3; do echo "$n" > "$PS/scripts/few/f$n.txt"; done
if git init -q "$PS" && git -C "$PS" add -A && git -C "$PS" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base && PSBASE="$(git -C "$PS" rev-parse HEAD)"; then
    pass "the size-projection fixture repo holds a base commit"
else
    fail "the size-projection fixture repo could not be committed; the rows below cannot be trusted"
    PSBASE=0000000000000000000000000000000000000000
fi
export HIMMEL_CONFIG_DIR="$WORK/no-conf"; unset HIMMEL_FLAG_PR_SIZE_GATE
ps_workers() { # <name> <dir/> [extra json members]
    cat > "$WORK/ps-$1.json" <<PSEOF
[{"label":"N921","keys":["HIMMEL-9201"],"slug":"size","branch":"fix/himmel-9201-size","title":"a sized fix","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/x\`.","writes":"$2","scope":"\`$2\`","scope_short":"$2","commit":"fix(x): [HIMMEL-9201] f"$3}]
PSEOF
}
psrun() { python3 "$SUT" "$WORK/ps-$1.json" --base "$PSBASE" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/ps-bucket-$1${2:-}" --date 2026-10-08 --repo "$PS" --handover-root "$WORK/handovers" --work-dir "$WORK/psw-$1${2:-}" --deadline 1791475000 2>&1; }
ps_brief() { ls "$WORK/ps-bucket-$1${2:-}"/HIMMEL-9201-*.md 2>/dev/null; }
ps_workers big scripts/big/ ''; ps_workers bulk scripts/big/ ',"bulk":"mechanical"'; ps_workers mid scripts/mid/ ''; ps_workers few scripts/few/ ''; ps_workers badbulk scripts/few/ ',"bulk":"yes"'

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a Writes dir of 41 tracked files is refused (rc 1)" || fail "41 files with the gate on: rc=$rc: $pso"
has "the refusal names the 40-file hard max" "$pso" "40-file hard max"
has "the refusal names the pr-size-bands.tsv hard row" "$pso" "pr-size-bands.tsv row hard"
has "the refusal says how many files the Writes expand to" "$pso" "41 files"
[ -z "$(ps_brief big)" ] && pass "a refused brief writes no doc" || fail "a refused brief wrote a doc"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun bulk)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on, bulk: mechanical: 41 files pass (rc 0)" || fail "bulk mechanical: rc=$rc: $pso"
[ -n "$(ps_brief bulk)" ] && pass "the bulk mechanical worker gets its brief" || fail "bulk mechanical: no brief"

pso="$(psrun big off)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate at its default (off): 41 files still write the brief (rc 0)" || fail "flag off: rc=$rc: $pso"
has "flag off: a warning names the 40-file hard max" "$pso" "warning: worker N921 Writes project to 41 files, over the 40-file hard max"
[ -n "$(ps_brief big off)" ] && pass "flag off: the brief is written" || fail "flag off: no brief"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun mid)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: 25 files (soft max only) pass (rc 0)" || fail "25 files: rc=$rc: $pso"
has "25 files: a warning names the 20-file soft max" "$pso" "over the 20-file soft max"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun few)"; rc=$?
[ "$rc" = 0 ] && pass "3 files pass (rc 0)" || fail "3 files: rc=$rc: $pso"
lacks "3 files: no size warning" "$pso" "warning:"

PSBASE_GOOD="$PSBASE"; PSBASE="4ccb59dd6de2eba962c75f136096cd7b721ae312"  # a sha this fixture repo does not hold
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun few nobase)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a base git cannot read refuses instead of counting one file (rc 1)" || fail "unreadable base, gate on: rc=$rc: $pso"
has "the unreadable-base refusal says the Writes cannot be projected" "$pso" "cannot be projected"
pso="$(psrun few nobase-off)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate off: an unreadable base warns and writes the brief (rc 0)" || fail "unreadable base, gate off: rc=$rc: $pso"
has "gate off: the unreadable base is a warning" "$pso" "warning: worker N921 Writes cannot be projected"
PSBASE="$PSBASE_GOOD"

pso="$(psrun badbulk)"; rc=$?
[ "$rc" = 1 ] && has "bulk other than mechanical is refused" "$pso" "bulk" || fail "bulk yes: rc=$rc: $pso"
unset HIMMEL_CONFIG_DIR

# --- S2a: with stacked_series on, a writer's `series: [<label>, ...]` writes ONE brief (Series line, grant line, the union of
# the items' Writes) and creates the ledger through series-ledger.py; the named workers get no brief or launcher. Flag off: the key is ignored. ---
export HIMMEL_CONFIG_DIR="$WORK/no-conf"; unset HIMMEL_FLAG_STACKED_SERIES
SRP="HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/sa\`."
cat > "$WORK/sr-base.json" <<SREOF
[
 {"label":"N931","keys":["HIMMEL-9301"],"slug":"sr-a","branch":"feat/himmel-9301-sr-a","title":"series writer","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/a.sh","scope":"\`scripts/sa/a.sh\` completes-ticket: no","scope_short":"a.sh","commit":"feat(sa): [HIMMEL-9301] a","series":["N932","N933"],"series_grant":{"family":"scripts/sa/","decision":388}},
 {"label":"N932","keys":["HIMMEL-9302"],"slug":"sr-b","branch":"feat/himmel-9302-sr-b","title":"series item b","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/b.sh","scope":"\`scripts/sa/b.sh\` completes-ticket: no","scope_short":"b.sh","commit":"feat(sa): [HIMMEL-9302] b"},
 {"label":"N933","keys":["HIMMEL-9303"],"slug":"sr-c","branch":"feat/himmel-9303-sr-c","title":"series item c","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/c.sh","scope":"\`scripts/sa/c.sh\` completes-ticket: no","scope_short":"c.sh","commit":"feat(sa): [HIMMEL-9303] c"}
]
SREOF
srmut() { # <name> <python statements editing the worker list w>: sr-<name>.json from the base
    python3 -I -c 'import json, sys; w = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(w, open(sys.argv[2], "w"))' "$WORK/sr-base.json" "$WORK/sr-$1.json" "$2"
}
srrun() { # <name> [flag value, default 1]
    HIMMEL_FLAG_STACKED_SERIES="${2:-1}" python3 "$SUT" "$WORK/sr-$1.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-$1" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-$1" --deadline 1791475000 2>&1
}
srledger() { python3 -I "$HERE/series-ledger.py" read --ledger "$1" 2>&1; }
srsummary() { printf '%s' "$1" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(",".join(i["key"] for i in d["items"]), ",".join(i["state"] for i in d["items"]), ",".join(",".join(i["writes"]) for i in d["items"]), d["writer"], d["completes_ticket"], d["grant"], sep="|")'; }
srbad() { # <name> <python edit> <stderr fragment>: refused, rc 1, no brief, no launcher, no ledger
    srmut "$1" "$2"
    local o rc=0; o="$(srrun "$1")" || rc=$?
    [ "$rc" = 1 ] && has "S2a: $1 refusal names its cause" "$o" "$3" || fail "S2a: $1 rc=$rc: $o"
    lacks "S2a: $1 refusal is no traceback" "$o" "Traceback"
    [ -z "$(find "$WORK/sr-b-$1" -type f -print -quit 2>/dev/null)" ] && pass "S2a: $1 refusal writes no brief, launcher or ledger" || fail "S2a: $1 wrote $(find "$WORK/sr-b-$1" -type f)"
}

srmut ok 'pass'
sro="$(srrun ok)"; rc=$?
[ "$rc" = 0 ] && pass "S2a: a series writer with stacked_series on generates (rc 0)" || fail "S2a ok rc=$rc: $sro"
SRB="$WORK/sr-b-ok"; SRD="$SRB/HIMMEL-9301-N931-sr-a-2026-10-08.md"; SRL="$SRB/series/HIMMEL-9301-N931.json"
[ -f "$SRD" ] && pass "S2a: the writer's brief is written" || fail "S2a: no brief $SRD"
[ ! -e "$SRB/launch-N932.sh" ] && [ ! -e "$SRB/launch-N933.sh" ] && [ -z "$(find "$SRB" -name 'HIMMEL-9302-*' -o -name 'HIMMEL-9303-*')" ] && pass "S2a: the named workers get no brief and no launcher" || fail "S2a: a named worker got a file: $(ls "$SRB")"
[ -f "$SRB/launch-N931.sh" ] && pass "S2a: the writer gets its launcher" || fail "S2a: no writer launcher"
srbrief="$(cat "$SRD" 2>/dev/null)"  # read-sink-ok: SRD is a fixture path under this test's own mktemp dir
has "S2a: the Series line carries the sid, the ledger path and the series.md path" "$srbrief" "> **Series:** HIMMEL-9301-N931 $SRL — read docs/handover/worker-sections/series.md"
has "S2a: the grant line names the family and the operator decision" "$srbrief" "> **Series grant:** scripts/sa/ (operator decision 388)"
has "S2a: the Writes line is the union of the items' Writes" "$srbrief" "> **Writes:** scripts/sa/a.sh scripts/sa/b.sh scripts/sa/c.sh"
has "S2a: the ledger holds the three items planned, their writes, the brief doc as writer, one completes value and the grant" "$(srsummary "$(srledger "$SRL")")" "HIMMEL-9301,HIMMEL-9302,HIMMEL-9303|planned,planned,planned|scripts/sa/a.sh,scripts/sa/b.sh,scripts/sa/c.sh|$SRD|no|scripts/sa/ (operator decision 388)"
bash "$HERE/brief-lint.sh" "$SRD" 2>"$WORK/srlint.err"; rc=$?
[ "$rc" = 0 ] && pass "S2a: the series brief passes brief-lint.sh" || fail "S2a: series brief brief-lint rc=$rc: $(cat "$WORK/srlint.err")"
lacks "S2a: the .out file lists no named worker" "$(cat "$WORK/sr-ok.json.out" 2>/dev/null)" "\"label\": \"N932\""

# the brief gen-briefs wrote is read by the real next-dispatchable.sh: the Series line parses and the series worker holds the files
mkdir -p "$WORK/sr-nd/HIMMEL"
printf 'v1.0.1\tfalse\t\n' > "$WORK/sr-nd/HIMMEL.versions.tsv"
printf -- '---\nkey: "HIMMEL-9390"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9390: wants a series file\n\n## Description\n\nEdit scripts/sa/a.sh please.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' > "$WORK/sr-nd/HIMMEL/HIMMEL-9390.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/sr-gh"; chmod +x "$WORK/sr-gh"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N931"}]}\n' "$SRD" > "$SRB/fleet.json"
srnd="$(HIMMEL_FLAG_STACKED_SERIES=1 NEXT_DISPATCH_MIRROR="$WORK/sr-nd/HIMMEL" NEXT_DISPATCH_GH_CMD="$WORK/sr-gh" bash "$HERE/next-dispatchable.sh" --workers-from "$SRB/fleet.json" --no-classify --why 2>"$WORK/srnd.err")"; rc=$?
[ "$rc" = 0 ] && pass "S2a: next-dispatchable exits 0 on the written series (rc 0)" || fail "S2a: next-dispatchable rc=$rc: $srnd"
has "S2a: next-dispatchable lists the series writer as the holder a colliding candidate stacks on" "$srnd" "STACKABLE HIMMEL-9390 $SRD"
lacks "S2a: next-dispatchable reports no unreadable ledger or doc for the written series" "$(cat "$WORK/srnd.err")" "unreadable"

srbad mixed 'w[2]["scope"] = "scripts/sa/c.sh completes-ticket: yes"' "completes-ticket"
srbad nogrant 'w[0]["series_grant"] = {"family": "scripts/sa/"}' "decision"
srbad nograntkey 'del w[0]["series_grant"]' "decision"
srbad compact 'w[0]["context_guard"] = "compact"' "compact mode"
srbad fifth 'w += [dict(w[2], label="N93%d" % i, keys=["HIMMEL-930%d" % i], slug="sr-x%d" % i, branch="feat/himmel-930%d-sr-x%d" % (i, i)) for i in (4, 5)]; w[0]["series"] = ["N932", "N933", "N934", "N935"]' "at most 4"
srbad unknown 'w[0]["series"] = ["N932", "N999"]' "N999"
srbad dupkey 'w[2]["keys"] = ["HIMMEL-9302"]' "more than once"

# a manifest outside the bucket would hide the ledger from next-dispatchable.sh, which reads series/ beside the manifest
srmut mfout 'pass'
mfo="$(HIMMEL_FLAG_STACKED_SERIES=1 python3 "$SUT" "$WORK/sr-mfout.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-mfout" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-mfout" --deadline 1791475000 --manifest "$WORK/elsewhere.fleet.json" 2>&1)"; rc=$?
[ "$rc" = 1 ] && has "S2a: a manifest outside the bucket is refused" "$mfo" "not in the bucket" || fail "S2a: manifest outside the bucket rc=$rc: $mfo"
[ -z "$(find "$WORK/sr-b-mfout" -type f -print -quit 2>/dev/null)" ] && pass "S2a: the manifest refusal writes no brief, launcher or ledger" || fail "S2a: the manifest refusal wrote $(find "$WORK/sr-b-mfout" -type f)"
srmut mfin 'pass'
mfi="$(HIMMEL_FLAG_STACKED_SERIES=1 python3 "$SUT" "$WORK/sr-mfin.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-mfin" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-mfin" --deadline 1791475000 --manifest "$WORK/sr-b-mfin/x.fleet.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/sr-b-mfin/series/HIMMEL-9301-N931.json" ] && pass "S2a: a manifest in the bucket writes the ledger beside it (rc 0)" || fail "S2a: manifest in the bucket rc=$rc: $mfi"

# a ledger that already exists is exit 4 from the verb: a refusal, not a traceback, and no brief
srmut exists 'pass'
mkdir -p "$WORK/sr-b-exists/series"
python3 -I "$HERE/series-ledger.py" create --ledger "$WORK/sr-b-exists/series/HIMMEL-9301-N931.json" --sid HIMMEL-9301-N931 --completes-ticket no --writer /elsewhere.md
o="$(srrun exists)"; rc=$?
[ "$rc" = 1 ] && has "S2a: an existing ledger is a refusal that names it" "$o" "already exists" || fail "S2a: existing ledger rc=$rc: $o"
lacks "S2a: an existing ledger is no traceback" "$o" "Traceback"
[ -z "$(find "$WORK/sr-b-exists" -name '*.md' -print -quit)" ] && pass "S2a: an existing ledger leaves no brief" || fail "S2a: a brief was written beside an existing ledger"

# flag off: the series keys are ignored: one brief per worker, no ledger, and the writer's brief is the one a workers file without the keys gets
srmut off 'pass'
sroff="$(srrun off 0)"; rc=$?
[ "$rc" = 0 ] && pass "S2a: stacked_series off generates (rc 0)" || fail "S2a off rc=$rc: $sroff"
[ -f "$WORK/sr-b-off/HIMMEL-9302-N932-sr-b-2026-10-08.md" ] && [ ! -e "$WORK/sr-b-off/series" ] && pass "S2a: flag off writes a brief per worker and no ledger" || fail "S2a: flag off wrote: $(find "$WORK/sr-b-off")"
srmut plain 'for x in w: x.pop("series", None); x.pop("series_grant", None)'
srrun plain 0 >/dev/null
norm() { sed -E 's#BZ-N[0-9]+-[0-9a-f]{8}#NONCE#g; s#sr-b-[a-z]+#BUCKET#g' "$1"; }
[ "$(norm "$WORK/sr-b-off/HIMMEL-9301-N931-sr-a-2026-10-08.md")" = "$(norm "$WORK/sr-b-plain/HIMMEL-9301-N931-sr-a-2026-10-08.md")" ] && pass "S2a: flag off, the writer's brief is byte-identical to the one without the series keys (I8)" || fail "S2a: flag off changed the writer's brief"
lacks "S2a: flag off, the brief carries no Series line" "$(cat "$WORK/sr-b-off/HIMMEL-9301-N931-sr-a-2026-10-08.md")" "**Series"
unset HIMMEL_CONFIG_DIR

# ---- the core gate (spec section 3 and 4) ----
# gen-briefs asks the real jira CLI per key: a core build leg with no signed minerva spec is refused with core_gate on;
# a bypass (design leg, Bug, emergency) passes with one core-gate.jsonl row; a core-check that cannot run always refuses.
CG="$WORK/cg"; mkdir -p "$CG/mirror" "$CG/specs"
export HIMMEL_CONFIG_DIR="$WORK/no-conf"; unset HIMMEL_FLAG_CORE_GATE
export HIMMEL_RELEASE_STATE_DIR="$CG/release" HIMMEL_RELEASE_KEY_DIR="$CG/keys" JIRA_PROJECT_KEY=HIMMEL
unset HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$CG/mirror/.cursor.json"
cg_mirror() { # <KEY> <type> <priority> <labels json array>: a mirror ticket the proof check and core-check both read
    printf -- '---\nkey: "%s"\nstatus: "To Do"\ntype: "%s"\npriority: "%s"\nlabels: %s\n---\n# %s: t\n\n## Description\n\nEdit the thing.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n\n## Comments\n\nnone\n' "$1" "$2" "$3" "$4" "$1" > "$CG/mirror/$1.md"
}
cg_workers() { # <name> <key> <writes> [extra json members]
    cat > "$CG/$1.json" <<CGEOF
[{"label":"N941","keys":["$2"],"slug":"cg","branch":"feat/himmel-9400-cg","title":"a core fix","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/x\`.","writes":"$3","scope":"\`$3\`","scope_short":"x","commit":"feat(x): [$2] f"$4}]
CGEOF
}
cgrun() { # <name> [flag value, default 1]: the same bucket per name, so a re-run is a re-run
    GEN_BRIEFS_MIRROR="$CG/mirror" HIMMEL_FLAG_CORE_GATE="${2:-1}" python3 "$SUT" "$CG/$1.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$CG/b-$1" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$CG/w-$1" --deadline 1791475000 2>&1
}
cg_brief() { ls "$CG/b-$1"/*-N941-cg-2026-10-08.md 2>/dev/null; }
cg_log() { printf '%s' "$CG/b-$1/core-gate.jsonl"; }
cg_rows() { [ -f "$(cg_log "$1")" ] && grep -c "\"key\": \"$2\"" "$(cg_log "$1")" || echo 0; }
cg_field() { python3 -I -c 'import json, sys; [print(r.get(sys.argv[3])) for r in map(json.loads, open(sys.argv[1])) if r["key"] == sys.argv[2]]' "$(cg_log "$1")" "$2" "$3" 2>/dev/null; }
cg_sign() { # <name> <keys csv>: sign a fixture spec for those keys through the real fenced verb
    mkdir -p "$CG/specs/$1"
    printf '{"median_seq": 1, "sigma": 0.1, "dod": {"passed": true}}\n' > "$CG/specs/$1/est.json"
    printf '# K-1: a fixture design\n\nEstimate record: est.json\n\n## Alternatives considered\n\n- none better.\n\n## Definition of done\n\n- the fixture signs.\n\n## Invariants\n\nnone\n' > "$CG/specs/$1/spec-$1-2026-11-01.md"
    printf "the critic's return\n\nSPEC CLEAN\n" > "$CG/specs/$1/spec-$1-2026-11-01.md.critic-spec-r1.md"
    printf "the critic's return\n\nPLAN CLEAN\n" > "$CG/specs/$1/spec-$1-2026-11-01.md.critic-plan-r1.md"
    node "$JIRA_CLI" release operator spec R1 --keys "$2" --spec "$CG/specs/$1/spec-$1-2026-11-01.md" \
        --verdict "$CG/specs/$1/spec-$1-2026-11-01.md.critic-spec-r1.md" --verdict "$CG/specs/$1/spec-$1-2026-11-01.md.critic-plan-r1.md" \
        --decision 387 --verbatim-file "$CG/verbatim.txt" 2>&1
}
printf 'approve\n' > "$CG/verbatim.txt"
cgo="$(node "$JIRA_CLI" release operator declare R1 --versions v1 --decision 1 --verbatim-file "$CG/verbatim.txt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "the core-gate fixture release R1 is declared" || fail "declare R1 rc=$rc: $cgo"

CORE_WRITES="scripts/handover/chief-kit/next-dispatchable.sh"
cg_mirror HIMMEL-9411 Task Medium '[]'
cg_workers nospec HIMMEL-9411 "$CORE_WRITES" ''
cgo="$(cgrun nospec)"; rc=$?
[ "$rc" = 1 ] && has "a build leg with core Writes and no spec, core_gate on, exits 1 naming the missing spec" "$cgo" "HIMMEL-9411 is core" || fail "a build leg with core Writes and no spec, core_gate on, exits 1 naming the missing spec (rc=$rc): $cgo"
has "the refusal names the spec-check line (NO-SPEC <KEY>)" "$cgo" "NO-SPEC HIMMEL-9411"
has "the refusal names the matched path" "$cgo" "$CORE_WRITES"
has "the refusal says how to sign: minerva, then jira release operator spec" "$cgo" "run minerva, then jira release operator spec"
[ -z "$(cg_brief nospec)" ] && [ ! -e "$CG/b-nospec/launch-N941.sh" ] && pass "a refused core worker gets no brief and no launcher" || fail "a refused core worker was written"
[ "$(cg_rows nospec HIMMEL-9411)" = 1 ] && [ "$(cg_field nospec HIMMEL-9411 outcome)" = refused ] && pass "the refusal appends one refused row" || fail "refused row: $(cat "$(cg_log nospec)" 2>/dev/null)"
cgo="$(cgrun nospec)"; rc=$?
[ "$rc" = 1 ] && [ "$(cg_rows nospec HIMMEL-9411)" = 1 ] && pass "a re-run reaching the same outcome for the same key and brief appends no second row" || fail "re-run rows=$(cg_rows nospec HIMMEL-9411) rc=$rc"

cgs="$(cg_sign one HIMMEL-9412)"; rc=$?
[ "$rc" = 0 ] && pass "a fixture spec is signed for HIMMEL-9412 through the real fenced verb" || fail "cg_sign rc=$rc: $cgs"
cg_mirror HIMMEL-9412 Task Medium '[]'
cg_workers signed HIMMEL-9412 "$CORE_WRITES" ''
cgo="$(cgrun signed)"; rc=$?
[ "$rc" = 0 ] && pass "a core build leg with a signed spec generates (rc 0)" || fail "signed rc=$rc: $cgo"
has "the signed brief carries a Spec: line with the spec path and record id" "$(cat "$(cg_brief signed)" 2>/dev/null)" "> **Spec:** HIMMEL-9412 $CG/specs/one/spec-one-2026-11-01.md (O-R1-"
[ "$(cg_rows signed HIMMEL-9412)" = 1 ] && [ "$(cg_field signed HIMMEL-9412 outcome)" = spec ] && pass "the signed spec appends one spec row" || fail "spec row: $(cat "$(cg_log signed)" 2>/dev/null)"
bash "$HERE/brief-lint.sh" "$(cg_brief signed)" 2>"$CG/lint.err"; rc=$?
[ "$rc" = 0 ] && pass "the signed brief passes brief-lint.sh" || fail "signed brief-lint rc=$rc: $(cat "$CG/lint.err")"

cg_mirror HIMMEL-9413 Task Medium '["core"]'
cg_workers design HIMMEL-9413 "docs/internals/core-gate-fixture.md" ''
cgo="$(cgrun design)"; rc=$?
[ "$rc" = 0 ] && pass "a label-only design leg (docs-only Writes) passes (rc 0)" || fail "design rc=$rc: $cgo"
has "the design leg's brief carries a Core gate bypass=design line" "$(cat "$(cg_brief design)" 2>/dev/null)" "> **Core gate:** HIMMEL-9413 bypass=design"
[ "$(cg_rows design HIMMEL-9413)" = 1 ] && [ "$(cg_field design HIMMEL-9413 outcome)" = bypass ] && [ "$(cg_field design HIMMEL-9413 bypass)" = design ] && pass "the design leg appends one bypass row of kind design" || fail "design row: $(cat "$(cg_log design)" 2>/dev/null)"

cg_mirror HIMMEL-9414 Bug Medium '[]'
cg_workers bug HIMMEL-9414 "$CORE_WRITES" ''
cgo="$(cgrun bug)"; rc=$?
[ "$rc" = 0 ] && pass "a Bug on core Writes passes (rc 0)" || fail "bug rc=$rc: $cgo"
has "the Bug's brief carries a Core gate bypass=bug line" "$(cat "$(cg_brief bug)" 2>/dev/null)" "> **Core gate:** HIMMEL-9414 bypass=bug"
[ "$(cg_rows bug HIMMEL-9414)" = 1 ] && [ "$(cg_field bug HIMMEL-9414 bypass)" = bug ] && pass "the Bug appends one bypass row of kind bug" || fail "bug row: $(cat "$(cg_log bug)" 2>/dev/null)"

cg_mirror HIMMEL-9415 Bug Highest '[]'
cg_workers emergency HIMMEL-9415 "$CORE_WRITES" ''
cgo="$(cgrun emergency)"; rc=$?
[ "$rc" = 0 ] && pass "an emergency (a Bug at Highest) on core Writes passes (rc 0)" || fail "emergency rc=$rc: $cgo"
has "the emergency's brief carries a Core gate bypass=emergency line" "$(cat "$(cg_brief emergency)" 2>/dev/null)" "> **Core gate:** HIMMEL-9415 bypass=emergency"
[ "$(cg_rows emergency HIMMEL-9415)" = 1 ] && [ "$(cg_field emergency HIMMEL-9415 bypass)" = emergency ] && pass "the emergency appends one bypass row of kind emergency" || fail "emergency row: $(cat "$(cg_log emergency)" 2>/dev/null)"

# a design leg whose Writes match core-paths is refused, never bypassed (a SKILL.md under the bus plugin is a docs file in a core directory)
cg_mirror HIMMEL-9416 Task Medium '["core"]'
cg_workers designcore HIMMEL-9416 "marketplace/plugins/himmel-bus/SKILL.md" ''
cgo="$(cgrun designcore)"; rc=$?
[ "$rc" = 1 ] && has "a design leg writing core code is refused, not bypassed" "$cgo" "HIMMEL-9416 is core" || fail "design-core rc=$rc: $cgo"
[ -z "$(cg_brief designcore)" ] && [ "$(cg_field designcore HIMMEL-9416 outcome)" = refused ] && pass "the refused design-core leg writes no brief and one refused row" || fail "design-core: $(cat "$(cg_log designcore)" 2>/dev/null)"

# a free-text bypass is refused naming the key
cg_workers cb HIMMEL-9417 "$CORE_WRITES" ',"core_bypass":"operator said so"'
cgo="$(cgrun cb)"; rc=$?
[ "$rc" = 1 ] && has "a worker carrying core_bypass is refused naming it" "$cgo" "core_bypass" || fail "core_bypass rc=$rc: $cgo"
cg_workers bp HIMMEL-9417 "$CORE_WRITES" ',"bypass":"emergency"'
cgo="$(cgrun bp)"; rc=$?
[ "$rc" = 1 ] && has "a worker carrying bypass is refused naming it" "$cgo" "bypass" || fail "bypass rc=$rc: $cgo"
[ -z "$(cg_brief cb)$(cg_brief bp)" ] && pass "a worker carrying a bypass key gets no brief" || fail "a bypass-key worker was written"

# a mirror miss: with the flag on the worker is refused (neither core nor a bypass can be proven), one unknown row either way
cg_workers miss HIMMEL-9418 "$CORE_WRITES" ''
cgo="$(cgrun miss)"; rc=$?
[ "$rc" = 1 ] && has "a mirror miss with core_gate on is refused" "$cgo" "HIMMEL-9418" || fail "mirror miss rc=$rc: $cgo"
[ "$(cg_rows miss HIMMEL-9418)" = 1 ] && [ "$(cg_field miss HIMMEL-9418 outcome)" = unknown ] && pass "the mirror miss appends one unknown row" || fail "unknown row: $(cat "$(cg_log miss)" 2>/dev/null)"
cg_workers missoff HIMMEL-9418 "$CORE_WRITES" ''
cgo="$(cgrun missoff 0)"; rc=$?
[ "$rc" = 0 ] && has "a mirror miss with core_gate off warns and writes the brief" "$cgo" "WARN" || fail "mirror miss off rc=$rc: $cgo"
has "the flag-off mirror miss leaves a Core gate WARN UNKNOWN line in the brief" "$(cat "$(cg_brief missoff)" 2>/dev/null)" "> **Core gate:** WARN UNKNOWN HIMMEL-9418"
[ "$(cg_field missoff HIMMEL-9418 outcome)" = unknown ] && pass "the flag-off mirror miss appends an unknown row too" || fail "unknown row off: $(cat "$(cg_log missoff)" 2>/dev/null)"

# a core-check that cannot run is always a refusal, flag on or off
cg_mirror HIMMEL-9419 Task Medium '[]'
cg_workers nodist HIMMEL-9419 "$CORE_WRITES" ''
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/no-dist/index.js" cgrun nodist)"; rc=$?
[ "$rc" = 1 ] && has "no dist/, core_gate on: CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED" || fail "no dist on rc=$rc: $cgo"
[ "$(cg_field nodist HIMMEL-9419 outcome)" = failed ] && pass "no dist/ appends a failed row" || fail "failed row: $(cat "$(cg_log nodist)" 2>/dev/null)"
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/no-dist/index.js" cgrun nodist 0)"; rc=$?
[ "$rc" = 1 ] && has "no dist/, core_gate off: still CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED" || fail "no dist off rc=$rc: $cgo"
[ -z "$(cg_brief nodist)" ] && pass "a core-check that cannot run writes no brief" || fail "a brief was written with no dist"
printf '// valid JavaScript that exits 0 and prints no verdict line\n' > "$CG/junk.js"
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/junk.js" cgrun nodist 0)"; rc=$?
[ "$rc" = 1 ] && has "a core-check that prints nothing parseable is CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED" || fail "unparseable rc=$rc: $cgo"

# flag off: a core key with no spec writes a WARN line and a warn row, and nothing else changes (I6): the brief equals the flag-on signed brief bar the gate's own line
cg_mirror HIMMEL-9421 Task Medium '[]'
cg_workers off HIMMEL-9421 "$CORE_WRITES" ''
cgo="$(cgrun off 0)"; rc=$?
[ "$rc" = 0 ] && pass "core_gate off: a core build leg with no spec still generates (rc 0)" || fail "flag off rc=$rc: $cgo"
has "core_gate off: the brief carries a Core gate WARN line naming the spec-check line" "$(cat "$(cg_brief off)" 2>/dev/null)" "> **Core gate:** WARN NO-SPEC HIMMEL-9421"
[ "$(cg_rows off HIMMEL-9421)" = 1 ] && [ "$(cg_field off HIMMEL-9421 outcome)" = warn ] && pass "core_gate off appends one warn row" || fail "warn row: $(cat "$(cg_log off)" 2>/dev/null)"
cgs="$(cg_sign two HIMMEL-9421)"; rc=$?
[ "$rc" = 0 ] && pass "a fixture spec is signed for HIMMEL-9421" || fail "cg_sign two rc=$rc: $cgs"
cg_workers on9421 HIMMEL-9421 "$CORE_WRITES" ''
cgo="$(cgrun on9421 1)"; rc=$?
[ "$rc" = 0 ] && pass "the same worker with core_gate on and a signed spec generates (rc 0)" || fail "on9421 rc=$rc: $cgo"
cgnorm() { sed -E '/^> \*\*(Core gate|Spec):\*\*/d; s#BZ-N[0-9]+-[0-9a-f]{8}#NONCE#g; s#b-(off|on9421)#BUCKET#g' "$1"; }
[ -n "$(cg_brief off)" ] && [ "$(cgnorm "$(cg_brief off)")" = "$(cgnorm "$(cg_brief on9421)")" ] && pass "the flag-off brief differs from the signed brief only by the gate's own line (I6)" || fail "flag-off brief differs beyond the gate line"

unset HIMMEL_CONFIG_DIR HIMMEL_RELEASE_STATE_DIR HIMMEL_RELEASE_KEY_DIR JIRA_PROJECT_KEY

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
