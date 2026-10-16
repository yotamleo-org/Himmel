#!/usr/bin/env bash
# Hermetic tests for dispatch-codex-exec.sh.
# No real codex install: CODEX_BIN + CODEX_ACL_NORMALIZE inject stubs that
# record their argv/cwd/order. Asserts the lane invariants: ACL preflight
# before codex + fail-closed, critic-model default (unless caller-named), the
# --background refusal, the workspace-redirect/sandbox-widening deny-list,
# and the --reasoning-effort passthrough.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-codex-exec.sh"
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"
CRITIC_MODEL="$(node -e 'process.stdout.write(require(process.argv[1]).panel.find(x => x.slug === "codex").model)' "$SCRIPT_DIR/../cr/critics.json")"
unset CODEX_CRITICS_FILE

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_rc() {  # assert_rc <expected> <ok-name> <fail-detail>
  if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$3"; fi
}

# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/canon-path.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# dispatch-codex-exec.sh resolves the worktree with `pwd -P`, so the
# fixture root must be the physical spelling too (macOS TMPDIR sits behind the
# /var -> /private/var link).
# Assign through a scratch var: a failed substitution would otherwise blank TMP
# and the EXIT trap above would clean nothing.
CANON_TMP="$(canon_path "$TMP")" || { echo "setup: canon_path failed for the fixture root" >&2; exit 1; }
TMP="$CANON_TMP"

WT="$TMP/.claude/worktrees/wt"
mkdir -p "$WT"
LOG="$TMP/calls.log"
JOBS_DIR="$TMP/jobs-dir"
mkdir -p "$JOBS_DIR"

# codex stub: records invocation order, argv, and cwd; exits 0.
CODEX_STUB="$TMP/codex-stub"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
printf '%s\n' "\${CODEX_CONTEXT_WINDOW-unset}" > "$TMP/codex.ctx"
exit 0
EOF
chmod +x "$CODEX_STUB"

# preflight stub: records invocation order + its worktree arg; exit code via file.
NORM_STUB="$TMP/norm-stub.sh"
cat > "$NORM_STUB" <<EOF
#!/usr/bin/env bash
echo "normalize" >> "$LOG"
printf '%s\n' "\$1" > "$TMP/norm.arg"
exit \$(cat "$TMP/norm.rc")
EOF
chmod +x "$NORM_STUB"
echo 0 > "$TMP/norm.rc"

# reap-mcp-fleet stub: records invocation + argv, exits 0 - no
# real process table or pwsh is touched. Injected into every run_dispatch
# call below so a codex stub that actually runs (rc-0 or nonzero-rc paths)
# never shells out to the real reap-mcp-fleet.sh/.ps1.
REAP_STUB="$TMP/reap-stub.sh"
cat > "$REAP_STUB" <<EOF
#!/usr/bin/env bash
echo "reap" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/reap.args"
exit 0
EOF
chmod +x "$REAP_STUB"

# every dispatch now writes flow-run-ledger rows. Point the lib
# at a temp ledger so the suite never appends to the operator's real
# ~/.himmel/flow-runs.jsonl.
LEDGER="$TMP/flow-runs.jsonl"

run_dispatch() {  # run_dispatch <args...> ; sets $RC and $OUT
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
      bash "$DISPATCH" "$@" 2>&1)"
  RC=$?
  set -e
}

# the hook-trust preflight reads $CODEX_HOME/config.toml, which no
# hermetic row below fixtures. Default every dispatch to a pass stub (the
# CODEX_ACL_NORMALIZE idiom); section 16 unsets it to run the REAL check.
TRUST_PASS_STUB="$TMP/trust-pass.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TRUST_PASS_STUB"
chmod +x "$TRUST_PASS_STUB"
export CODEX_HOOK_TRUST_CHECK="$TRUST_PASS_STUB"

# --- 1: missing --worktree -> usage (exit 2) ---------------------------------
run_dispatch
assert_rc 2 "missing --worktree exits 2" "no-worktree rc=$RC out=$OUT"

# --- 2: nonexistent worktree -> exit 2 ---------------------------------------
run_dispatch --worktree "$TMP/does-not-exist"
assert_rc 2 "nonexistent worktree exits 2" "bad-worktree rc=$RC out=$OUT"

# --- 2.5: directory OUTSIDE .claude/worktrees refused (codex-adv r5) ----------
OUTSIDE="$TMP/not-a-worktree"
mkdir -p "$OUTSIDE"
run_dispatch --worktree "$OUTSIDE" do-it
assert_rc 2 "non-worktree directory refused" "outside rc=$RC out=$OUT"
case "$OUT" in *"outside .claude/worktrees"*) pass "outside refusal names the containment rule";; *) fail "outside out: $OUT";; esac

# --- 2.6: resume / review subcommands refused, ANY position (codex-adv r5/r6) -
for subargs in "resume --all" "review x" "--json resume --all" "--sandbox workspace-write review"; do
  : > "$LOG"
  # shellcheck disable=SC2086  # word-splitting the fixture is the point
  run_dispatch --worktree "$WT" $subargs
  assert_rc 2 "subcommand refused: $subargs" "sub [$subargs] rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite: $subargs"; else pass "codex not invoked on: $subargs"; fi
done

# --- 2.7: --json passes the allow-list; symlinked worktree refused (final rd) -
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --json do-it
assert_rc 0 "--json allowed through the allow-list" "json rc=$RC out=$OUT"
LINKED="$TMP/.claude/worktrees/linked-wt"
if ln -s "$TMP/not-a-worktree" "$LINKED" 2>/dev/null && [ -L "$LINKED" ]; then
  run_dispatch --worktree "$LINKED" do-it
  assert_rc 2 "symlinked worktree (physical target outside) refused" "symlink rc=$RC out=$OUT"
  rm -f "$LINKED"
else
  rm -rf "$LINKED"
  pass "symlink escape case skipped (no real symlinks on this platform)"
fi

# --- 3: --background refused (exit 2), codex never invoked -------------------
: > "$LOG"
run_dispatch --worktree "$WT" some-prompt --background
assert_rc 2 "--background refused with exit 2" "background rc=$RC out=$OUT"
case "$OUT" in *"--background refused"*) pass "--background refusal names the rule";; *) fail "background out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite --background"; else pass "codex not invoked on --background"; fi

# --- 4: default dispatch follows the critic and runs preflight first ---------
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" do-the-task
assert_rc 0 "default dispatch exits 0" "default rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_context_window=272000 do-the-task") pass "$CRITIC_MODEL pin + sandbox pin injected" ;;
  *) fail "codex args: $(cat "$TMP/codex.args")" ;;
esac
case "$(tr '\n' ' ' < "$LOG")" in
  "normalize codex "*) pass "preflight runs before codex" ;;
  *) fail "call order: $(tr '\n' ' ' < "$LOG")" ;;
esac
case "$(cat "$TMP/norm.arg")" in
  "$WT") pass "preflight got the worktree path" ;;
  *) fail "norm arg: $(cat "$TMP/norm.arg")" ;;
esac

# --- 5: codex runs with cwd = the worktree -----------------------------------
# (compare basenames: mktemp paths differ across /tmp vs C:/... spellings on MSYS)
case "$(basename "$(cat "$TMP/codex.cwd")")" in
  "$(basename "$WT")") pass "codex cwd is the worktree" ;;
  *) fail "codex cwd: $(cat "$TMP/codex.cwd")" ;;
esac

# --- 6: caller-named --model overrides without a warning for plain IDs -------
: > "$LOG"
run_dispatch --worktree "$WT" --model qwen-plus do-it
assert_rc 0 "caller model dispatch exits 0" "caller-model rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -c model_context_window=272000 --model qwen-plus do-it") pass "caller model preserved, sandbox still pinned" ;;
  *) fail "caller-model codex args: $(cat "$TMP/codex.args")" ;;
esac
case "$OUT" in *WARN*) fail "plain caller model unexpectedly warns: $OUT";; *) pass "plain caller model does not warn";; esac

# Each model flag spelling preserves the override and warns only on variants.
for model_args in '--model fixture-codex' '--model=fixture-codex' '-m fixture-codex' '-mfixture-codex'; do
  # shellcheck disable=SC2086 # deliberately exercise both one- and two-token forms
  run_dispatch --worktree "$WT" $model_args do-it
  assert_rc 0 "variant override accepted: $model_args" "variant rc=$RC out=$OUT"
  case "$OUT" in *"WARN"*"codex-variant"*) pass "variant warning: $model_args";; *) fail "missing variant warning: $OUT";; esac
done
run_dispatch --worktree "$WT" --model gpt-6-astra do-it
case "$OUT" in *WARN*) fail "explicit plain model warned: $OUT";; *) pass "explicit gpt-6-astra remains warning-free";; esac

# A different registry model must actually change the rendered codex argv.
printf '%s\n' '{"panel":[{"slug":"codex","model":"fixture-next","provider":"openai-codex","route_provider":"openai-codex","tier":"paid"}]}' > "$TMP/critics.json"
export CODEX_CRITICS_FILE="$TMP/critics.json"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "alternate critic registry accepted" "critic drift rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model fixture-next --sandbox workspace-write -c model_context_window=272000 do-it') pass "dispatch default follows changed critic model" ;;
  *) fail "critic drift argv: $(cat "$TMP/codex.args")" ;;
esac
run_dispatch --worktree "$WT" --model explicit-model do-it
case "$(cat "$TMP/codex.args")" in
  'exec --sandbox workspace-write -c model_context_window=272000 --model explicit-model do-it') pass "explicit model wins over critic registry" ;;
  *) fail "override argv: $(cat "$TMP/codex.args")" ;;
esac
for invalid_registry in 'not json' '{"panel":[]}' '{"panel":[{"slug":"codex","model":""}]}' \
    '{"panel":[{"slug":"codex","model":"fixture --sandbox danger-full-access"}]}' \
    '{"panel":[{"slug":"codex","model":"*"}]}'; do
  printf '%s\n' "$invalid_registry" > "$TMP/critics.json"
  : > "$LOG"
  run_dispatch --worktree "$WT" do-it
  assert_rc 2 "invalid registry refuses rather than silently drifting" "invalid registry=$invalid_registry rc=$RC out=$OUT"
  if grep -q codex "$LOG"; then fail "codex invoked despite invalid model registry"; else pass "invalid registry never reaches codex"; fi
done
run_dispatch --worktree "$WT" --model explicit-model do-it
assert_rc 0 "explicit override does not depend on registry parsing" "override with malformed registry rc=$RC out=$OUT"
export CODEX_CRITICS_FILE="$TMP/missing-critics.json"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "unreadable registry uses fallback" "missing registry rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model gpt-6.1-sol --sandbox workspace-write -c model_context_window=272000 do-it') pass "unreadable registry uses named fallback model" ;;
  *) fail "fallback argv: $(cat "$TMP/codex.args")" ;;
esac
unset CODEX_CRITICS_FILE

# --- 6.5: workspace-redirect + sandbox-widening flags refused (codex-adv r2) --
for bad in "-C" "--cd" "--cd=/tmp/elsewhere" "--add-dir" "--add-dir=/tmp/x" \
           "--dangerously-bypass-approvals-and-sandbox" "--yolo" \
           "--sandbox=danger-full-access" "-s=danger-full-access" \
           "-c" "--config" "-c=sandbox_permissions=full" "--config=x=y" \
           "-p" "--profile" "--profile=wide" "-o" "--output-last-message" "--output-last-message=/tmp/x" \
           "--dangerously-bypass-hook-trust" "--ignore-rules" \
           "-C/tmp/outside" "-csandbox_permissions=x" "-pwide" "-o/tmp/out" "-sdanger-full-access" \
           "--disable" "--disable=hooks" "--enable" "--enable=x" "--full-auto" "--no-such-flag"; do
  : > "$LOG"
  run_dispatch --worktree "$WT" "$bad" /tmp/elsewhere do-it
  assert_rc 2 "refused: $bad" "flag $bad rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite $bad"; else pass "codex not invoked on $bad"; fi
done
# two-arg forms: --sandbox danger-full-access and -s danger-full-access
for sflag in "--sandbox" "-s"; do
  : > "$LOG"
  run_dispatch --worktree "$WT" "$sflag" danger-full-access do-it
  assert_rc 2 "refused: $sflag danger-full-access (two-arg)" "sandbox-pair $sflag rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite $sflag pair"; else pass "codex not invoked on $sflag pair"; fi
done
# non-widening sandbox value passes through
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --sandbox workspace-write do-it
assert_rc 0 "--sandbox workspace-write allowed" "sandbox-ok rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL -c model_context_window=272000 --sandbox workspace-write do-it") pass "workspace-write passed through with pin" ;;
  *) fail "sandbox-ok codex args: $(cat "$TMP/codex.args")" ;;
esac
# attached short forms of the ALLOWED values still register (no double pin)
: > "$LOG"
run_dispatch --worktree "$WT" -sworkspace-write do-it
assert_rc 0 "-sworkspace-write (attached) allowed" "s-attach rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL -c model_context_window=272000 -sworkspace-write do-it") pass "-s attached registers have_sandbox (no injected --sandbox)" ;;
  *) fail "s-attach codex args: $(cat "$TMP/codex.args")" ;;
esac
: > "$LOG"
run_dispatch --worktree "$WT" -mqwen-plus do-it
assert_rc 0 "-mqwen-plus (attached) allowed" "m-attach rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -c model_context_window=272000 -mqwen-plus do-it") pass "-m attached registers have_model (no injected pin)" ;;
  *) fail "m-attach codex args: $(cat "$TMP/codex.args")" ;;
esac

# --- 7: preflight failure aborts the dispatch (fail-closed, exit 1) ----------
: > "$LOG"; echo 1 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" do-the-task
assert_rc 1 "preflight failure exits 1" "preflight-fail rc=$RC out=$OUT"
case "$OUT" in *"ACL preflight failed"*) pass "preflight failure is named";; *) fail "preflight-fail out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite preflight failure"; else pass "codex not invoked on preflight failure"; fi

# --- 8: --model=<value> equals form and -m short form detected --------------
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --model=qwen-plus do-it
assert_rc 0 "--model= equals form exits 0" "model-eq rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -c model_context_window=272000 --model=qwen-plus do-it") pass "--model= form preserved, sandbox still pinned" ;;
  *) fail "model-eq codex args: $(cat "$TMP/codex.args")" ;;
esac
: > "$LOG"
run_dispatch --worktree "$WT" -m qwen-plus do-it
assert_rc 0 "-m short form exits 0" "m-short rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -c model_context_window=272000 -m qwen-plus do-it") pass "-m form preserved, sandbox still pinned" ;;
  *) fail "m-short codex args: $(cat "$TMP/codex.args")" ;;
esac

# --- 9: --background=value form refused ---------------------------------------
: > "$LOG"
run_dispatch --worktree "$WT" --background=true do-it
assert_rc 2 "--background= equals form refused" "background-eq rc=$RC out=$OUT"

# --- 10: --worktree present but not first -> usage (exit 2) -------------------
run_dispatch do-the-task --worktree "$WT"
assert_rc 2 "--worktree not-first exits 2 (positional contract)" "positional rc=$RC out=$OUT"

# --- 11: codex exit code propagates through the exec tail --------------------
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 3
EOF
run_dispatch --worktree "$WT" do-it
assert_rc 3 "codex nonzero exit propagates (rc=3)" "propagate rc=$RC out=$OUT"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
exit 0
EOF

# --- 12: codex CLI missing -> exit 127 with the CODEX_BIN hint ----------------
set +e
OUT="$(CODEX_BIN="$TMP/definitely-not-a-binary" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 127 "missing codex CLI exits 127" "no-codex rc=$RC out=$OUT"
case "$OUT" in *"set CODEX_BIN"*) pass "missing-codex message names CODEX_BIN";; *) fail "no-codex out: $OUT";; esac

# --- 13: worktree vanishing after the preflight is named distinctly ----------
VANISH_WT="$TMP/.claude/worktrees/vanish-wt"
mkdir -p "$VANISH_WT"
VANISH_NORM="$TMP/vanish-norm.sh"
cat > "$VANISH_NORM" <<EOF
#!/usr/bin/env bash
rmdir "\$1"
exit 0
EOF
chmod +x "$VANISH_NORM"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$VANISH_NORM" \
    bash "$DISPATCH" --worktree "$VANISH_WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 1 "vanished worktree exits 1" "vanish rc=$RC out=$OUT"
case "$OUT" in *"worktree vanished before dispatch"*) pass "vanish failure is named";; *) fail "vanish out: $OUT";; esac

# --- 14: --shared-branch mode ------------------------------------
# Real git repo + real worktree under .claude/worktrees (so the containment
# check passes) and the REAL shared-branch-lock.sh (not a stub) - this
# section tests the integration between dispatch-codex-exec.sh and the
# frozen lock primitive, not the primitive's own internals (that is
# scripts/lib/test-shared-branch-lock.sh's job).
SB_REPO="$TMP/sb-repo"
mkdir -p "$SB_REPO"
git -C "$SB_REPO" init -q
git -C "$SB_REPO" config user.email "test@example.com"
git -C "$SB_REPO" config user.name "Test User"
: > "$SB_REPO/README.md"
git -C "$SB_REPO" add README.md
git -C "$SB_REPO" commit -q -m init
SB_WT="$TMP/.claude/worktrees/sb-wt"
git -C "$SB_REPO" worktree add -q "$SB_WT" -b "feat/shared" >/dev/null 2>&1

# 14a: happy path - matching branch, clean tree -> codex runs, lock released after.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 0 "shared-branch happy path exits 0" "sb-happy rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then pass "codex invoked in shared-branch happy path"; else fail "codex not invoked in shared-branch happy path: $OUT"; fi
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  free) pass "shared-branch lock released after happy path" ;;
  *) fail "shared-branch lock not released after happy path: $sb_status" ;;
esac

# 14b: branch mismatch -> exit 2, codex not invoked.
: > "$LOG"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/other" do-it
assert_rc 2 "shared-branch mismatch refused" "sb-mismatch rc=$RC out=$OUT"
case "$OUT" in *"does not match"*) pass "mismatch refusal names both branches";; *) fail "sb-mismatch out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite branch mismatch"; else pass "codex not invoked on branch mismatch"; fi

# 14c: main refused -> exit 2, codex not invoked (checked before branch match).
: > "$LOG"
run_dispatch --worktree "$SB_WT" --shared-branch main do-it
assert_rc 2 "shared-branch main refused" "sb-main rc=$RC out=$OUT"
case "$OUT" in *"refuses trunk branch"*) pass "main refusal names the trunk rule";; *) fail "sb-main out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite main refusal"; else pass "codex not invoked on main refusal"; fi

# 14d: dirty tree -> exit 2, codex not invoked.
: > "$LOG"
echo "dirty" > "$SB_WT/dirty-file.txt"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 2 "shared-branch dirty tree refused" "sb-dirty rc=$RC out=$OUT"
case "$OUT" in *"uncommitted changes"*) pass "dirty-tree refusal names the rule";; *) fail "sb-dirty out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite dirty tree"; else pass "codex not invoked on dirty tree"; fi
rm -f "$SB_WT/dirty-file.txt"

# 14e: lock already held -> exit 4, codex not invoked, pre-existing lock intact.
: > "$LOG"
bash "$LOCK_LIB" acquire "$SB_WT" "feat/shared" "external-holder" >/dev/null 2>&1
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 4 "shared-branch lock-held refused with exit 4" "sb-lock-held rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite lock held"; else pass "codex not invoked when lock held"; fi
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  *"external-holder"*) pass "pre-existing lock not clobbered by dispatch's own trap" ;;
  *) fail "pre-existing lock was clobbered: $sb_status" ;;
esac
bash "$LOCK_LIB" release "$SB_WT" "feat/shared" >/dev/null 2>&1

# 14f: codex nonzero exit propagates AND the lock is released (trap fires).
: > "$LOG"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 7
EOF
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 7 "shared-branch codex nonzero exit propagates" "sb-codex-rc7 rc=$RC out=$OUT"
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  free) pass "shared-branch lock released after codex nonzero exit" ;;
  *) fail "shared-branch lock not released after nonzero exit: $sb_status" ;;
esac
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
printf '%s\n' "\${CODEX_CONTEXT_WINDOW-unset}" > "$TMP/codex.ctx"
exit 0
EOF

# --- 15: job registry - created during the run, removed after; --
# the composed EXIT trap invokes the reap primitive with the codex CHILD's
# own pid (never the dispatcher's own $$); rc propagation unchanged with the
# new always-a-child flow. A dedicated slow stub records its own pid and
# snapshots $CODEX_JOBS_DIR mid-run (the parent's registry write is racing
# the child's start, so the child sleeps briefly first).
: > "$LOG"; echo 0 > "$TMP/norm.rc"
rm -f "$TMP/jobs-during.txt" "$TMP/codex.pid" "$TMP/reap.args"
SLOW_CODEX_STUB="$TMP/codex-slow-stub"
cat > "$SLOW_CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
echo \$\$ > "$TMP/codex.pid"
sleep 0.3
ls "\$CODEX_JOBS_DIR" 2>/dev/null > "$TMP/jobs-during.txt"
exit 0
EOF
chmod +x "$SLOW_CODEX_STUB"
set +e
OUT="$(CODEX_BIN="$SLOW_CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 0 "registry-test dispatch exits 0" "registry rc=$RC out=$OUT"
# Line-wise, not a whole-string glob: the watchdog adds a sibling failed/ dir
# that earlier nonzero-exit cases leave behind, and `ls` sorts it AFTER the
# digit-prefixed job file.
if grep -q '\.json$' "$TMP/jobs-during.txt" 2>/dev/null; then
  pass "job registry file present during the run"
else
  fail "job registry file missing during run: $(cat "$TMP/jobs-during.txt" 2>/dev/null)"
fi
# The SUCCESS path still removes its own entry; only failed/ survives, and it
# holds no live-job *.json.
if [ -z "$(ls "$JOBS_DIR"/*.json 2>/dev/null)" ]; then
  pass "job registry file removed after the run (EXIT trap cleanup)"
else
  fail "job registry file(s) left behind: $(ls "$JOBS_DIR")"
fi
CODEX_CHILD_PID_SEEN="$(cat "$TMP/codex.pid" 2>/dev/null)"
case "$(cat "$TMP/reap.args" 2>/dev/null)" in
  "--root-pid $CODEX_CHILD_PID_SEEN --started-at "*" --kill")
    pass "reap primitive invoked with the codex child's own pid" ;;
  *)
    fail "reap.args: $(cat "$TMP/reap.args" 2>/dev/null) (expected root-pid=$CODEX_CHILD_PID_SEEN)" ;;
esac

# --- 16: --reasoning-effort passthrough --------------------------
# 16a: two-word form, valid value -> translated to -c model_reasoning_effort="<v>"
#      and stripped from the codex passthrough.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --reasoning-effort high do-it
assert_rc 0 "--reasoning-effort two-word form exits 0" "reff-two rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"high\" -c model_context_window=272000 do-it") pass "--reasoning-effort translated to -c override, stripped from passthrough" ;;
  *) fail "reff-two codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16b: --reasoning-effort=<value> equals form, valid value.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort=xhigh do-it
assert_rc 0 "--reasoning-effort= equals form exits 0" "reff-eq rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"xhigh\" -c model_context_window=272000 do-it") pass "--reasoning-effort= translated to -c override" ;;
  *) fail "reff-eq codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16c: every valid enum value accepted (none/low/medium/high/xhigh/max).
for v in none low medium high xhigh max; do
  : > "$LOG"
  run_dispatch --worktree "$WT" --reasoning-effort "$v" do-it
  assert_rc 0 "--reasoning-effort $v accepted" "reff-enum $v rc=$RC out=$OUT"
done

# 16d: invalid value refused (exit 2), codex never invoked.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort bogus do-it
assert_rc 2 "--reasoning-effort invalid value refused" "reff-bad rc=$RC out=$OUT"
case "$OUT" in *"not in none|low|medium|high|xhigh|max"*) pass "invalid --reasoning-effort names the allowed enum";; *) fail "reff-bad out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite invalid --reasoning-effort"; else pass "codex not invoked on invalid --reasoning-effort"; fi

# 16e: invalid value via equals form also refused.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort=bogus do-it
assert_rc 2 "--reasoning-effort=bogus refused" "reff-eq-bad rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite --reasoning-effort=bogus"; else pass "codex not invoked on --reasoning-effort=bogus"; fi

# 16f: no --reasoning-effort passed -> no -c override injected (default unchanged).
: > "$LOG"
run_dispatch --worktree "$WT" do-it
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_context_window=272000 do-it") pass "no --reasoning-effort -> no -c override injected" ;;
  *) fail "no-reff codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16g: raw -c/--config still refused for callers even alongside a valid
# --reasoning-effort (the wrapper's own -c injection is internal, not a
# caller-facing allow).
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort high -c foo=bar do-it
assert_rc 2 "raw -c still refused even alongside --reasoning-effort" "reff-plus-c rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite raw -c alongside --reasoning-effort"; else pass "codex not invoked on raw -c alongside --reasoning-effort"; fi

# 16h: --reasoning-effort as the ONLY arg (no prompt word) - exercises the
# zero-element NEW_ARGS guard (set -u safe empty-array rebuild on pre-4.4 bash).
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --reasoning-effort medium
assert_rc 0 "--reasoning-effort as sole arg exits 0 (empty positional rebuild)" "reff-only rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"medium\" -c model_context_window=272000") pass "empty-args rebuild after stripping the only two tokens" ;;
  *) fail "reff-only codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16i: --reasoning-effort as the very LAST token with NO value - must be
# refused (rc=2), not silently stripped into a default-effort run (the
# value-validation branch only fires on the NEXT loop iteration, which never
# comes for a trailing flag - post-loop guard covers it).
: > "$LOG"
run_dispatch --worktree "$WT" do-it --reasoning-effort
assert_rc 2 "trailing --reasoning-effort with no value refused" "trailing-reff rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite trailing bare --reasoning-effort"; else pass "codex not invoked on trailing bare --reasoning-effort"; fi

# --- 16j: --context-tier ----------------------------------------------------
# An ambient CODEX_CONTEXT_WINDOW must never buy a pricier tier: unstated pins 272000.
: > "$LOG"
CODEX_CONTEXT_WINDOW=900000 run_dispatch --worktree "$WT" do-it
assert_rc 0 "ambient CODEX_CONTEXT_WINDOW run exits 0" "ctx-ambient rc=$RC out=$OUT"
if [ "$(cat "$TMP/codex.ctx")" = "272000" ]; then pass "unstated tier pins 272000 over an ambient 900000"; else fail "ctx-ambient env: $(cat "$TMP/codex.ctx")"; fi
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_context_window=272000 do-it") pass "unstated tier still pins the 272000 -c override" ;;
  *) fail "ctx-ambient codex args: $(cat "$TMP/codex.args")" ;;
esac
for pair in 272k:272000 353k:353000 900k:900000; do
  : > "$LOG"
  run_dispatch --worktree "$WT" --context-tier "${pair%%:*}" do-it
  assert_rc 0 "--context-tier ${pair%%:*} exits 0" "ctx-${pair%%:*} rc=$RC out=$OUT"
  if [ "$(cat "$TMP/codex.ctx")" = "${pair##*:}" ]; then pass "--context-tier ${pair%%:*} exports ${pair##*:}"; else fail "ctx env ${pair%%:*}: $(cat "$TMP/codex.ctx")"; fi
  case "$(cat "$TMP/codex.args")" in
    "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_context_window=${pair##*:} do-it") pass "--context-tier ${pair%%:*} becomes the trusted -c override, stripped from passthrough" ;;
    *) fail "ctx codex args ${pair%%:*}: $(cat "$TMP/codex.args")" ;;
  esac
done
: > "$LOG"
run_dispatch --worktree "$WT" --context-tier=353k do-it
if [ "$(cat "$TMP/codex.ctx")" = "353000" ]; then pass "--context-tier=353k equals form"; else fail "ctx-eq env: $(cat "$TMP/codex.ctx")"; fi
: > "$LOG"
run_dispatch --worktree "$WT" --context-tier 1m do-it
assert_rc 2 "--context-tier 1m refused" "ctx-bad rc=$RC out=$OUT"
case "$OUT" in *'--context-tier must be one of 272k|353k|900k (got "1m")'*) pass "bad tier names the closed enum" ;; *) fail "ctx-bad out: $OUT" ;; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite bad --context-tier"; else pass "codex not invoked on bad --context-tier"; fi
: > "$LOG"
run_dispatch --worktree "$WT" do-it --context-tier
assert_rc 2 "trailing bare --context-tier refused" "ctx-trailing rc=$RC out=$OUT"

# --- 17: watchdog + ledger + evidence ----
# 17a: the default budget must equal the codex-exec lane's own timeoutSeconds.
# The dispatcher keeps the number as a literal (no JSON reader on its hot
# path), so THIS assertion is what stops the two drifting apart.
LANE_TIMEOUT="$(node -e '
const l = require(process.argv[1]).lanes.find(x => x.id === "codex-exec");
process.stdout.write(String(l.dispatch.timeoutSeconds));
' "$SCRIPT_DIR/../lanes/lanes.json" 2>/dev/null)"
# shellcheck disable=SC2016 # the sed script is a literal match against the dispatcher's source text, not an expansion
SCRIPT_DEFAULT="$(sed -n 's/^EXEC_TIMEOUT="${CODEX_EXEC_TIMEOUT:-\([0-9]*\)}"$/\1/p' "$DISPATCH")"
if [ -n "$LANE_TIMEOUT" ] && [ "$LANE_TIMEOUT" = "$SCRIPT_DEFAULT" ]; then
  pass "default watchdog budget matches the codex-exec lane timeoutSeconds ($LANE_TIMEOUT)"
else
  fail "watchdog budget drift: lanes.json=$LANE_TIMEOUT dispatcher=$SCRIPT_DEFAULT"
fi

# 17b: a malformed budget REFUSES rather than degrading to an unbounded wait.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=nope \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 2 "non-numeric CODEX_EXEC_TIMEOUT refused" "bad-timeout rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite a malformed budget"; else pass "codex not invoked on a malformed budget"; fi

# 17b1: an OVER-CEILING budget is refused too. A digit string `sleep` cannot
# parse exits immediately, which the watchdog would read as its budget having
# elapsed and kill a run that had just started (panel r3, dropped citation).
# The 20-digit case also pins the length guard: bash's own `[ -gt ]` errors on
# it, and reading that error as "not too large" would let it straight through.
for bad_to in 86401 99999999999999999999; do
  : > "$LOG"
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT="$bad_to" \
      bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
  RC=$?
  set -e
  assert_rc 2 "over-ceiling CODEX_EXEC_TIMEOUT=$bad_to refused" "big-timeout $bad_to rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite CODEX_EXEC_TIMEOUT=$bad_to"; else pass "codex not invoked on CODEX_EXEC_TIMEOUT=$bad_to"; fi
done
# ...and the ceiling itself is still accepted.
: > "$LOG"
run_dispatch_to() {
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT="$1" \
      bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
  RC=$?
  set -e
}
run_dispatch_to 86400
assert_rc 0 "CODEX_EXEC_TIMEOUT at the 86400 ceiling accepted" "ceiling rc=$RC out=$OUT"

# 17b2: an unusable watchdog REFUSES before codex starts (panel r2 codex-1).
# Without its flag file the watchdog would still kill the tree but this shell
# could not tell that it had — the run would report the child's bare 143, keep
# no evidence, and cancel the watchdog mid-escalation. TMPDIR pointed at a
# non-directory makes mktemp fail without touching the real temp root.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
printf 'not-a-dir\n' > "$TMP/notdir"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" TMPDIR="$TMP/notdir" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 2 "unusable watchdog flag file refuses the dispatch" "no-flagfile rc=$RC out=$OUT"
case "$OUT" in
  *"refusing to run codex with an unreadable watchdog verdict"*) pass "watchdog-flag refusal names the cause" ;;
  *) fail "no-flagfile message missing: $OUT" ;;
esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite an unusable watchdog flag file"; else pass "codex not invoked when the watchdog cannot report"; fi

# 17c: a wedged run is TIMEBOXED, killed as a TREE, reported 124 + loudly, and
# leaves evidence. The stub backgrounds a grandchild the way the real codex
# CLI leaks its MCP fleet: signalling the child alone would leave it alive.
: > "$LOG"; : > "$LEDGER"; rm -f "$TMP/grandchild.pid"
HANG_STUB="$TMP/codex-hang-stub"
cat > "$HANG_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
sleep 120 &
echo \$! > "$TMP/grandchild.pid"
sleep 120
EOF
chmod +x "$HANG_STUB"
set +e
OUT="$(CODEX_BIN="$HANG_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 124 "watchdog timeout exits 124" "timeout rc=$RC out=$OUT"
case "$OUT" in
  *"codex-exec: TIMEOUT after 2s - killed tree"*) pass "timeout is reported LOUDLY on stderr" ;;
  *) fail "timeout message missing: $OUT" ;;
esac
GCHILD="$(cat "$TMP/grandchild.pid" 2>/dev/null)"
if [ -z "$GCHILD" ]; then
  fail "hang stub never recorded a grandchild pid"
elif kill -0 "$GCHILD" 2>/dev/null; then
  fail "grandchild $GCHILD survived the timeout kill (tree not killed)"
  kill -9 "$GCHILD" 2>/dev/null
else
  pass "grandchild reaped by the timeout tree kill"
fi
if grep -q '"ev":"start".*"flow":"codex-exec"' "$LEDGER" 2>/dev/null \
   || grep -q '"flow":"codex-exec".*"ev":"start"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger carries a codex-exec start row"
else
  fail "no codex-exec start row in the ledger: $(cat "$LEDGER" 2>/dev/null)"
fi
if grep -q '"outcome":"timeout"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=timeout"
else
  fail "no outcome=timeout end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -n "$(ls "$JOBS_DIR"/failed/*.json 2>/dev/null)" ]; then
  pass "job registry entry preserved under failed/ on timeout"
else
  fail "timeout deleted the job registry evidence: $(ls -R "$JOBS_DIR" 2>/dev/null)"
fi

# 17d: a clean run writes outcome=complete and removes its own entry.
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"; : > "$LEDGER"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "clean run after the timeout case exits 0" "post-timeout rc=$RC out=$OUT"
if grep -q '"outcome":"complete"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=complete on success"
else
  fail "no outcome=complete end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -z "$(ls -A "$JOBS_DIR" 2>/dev/null)" ]; then
  pass "clean run leaves no registry evidence behind"
else
  fail "clean run left registry entries: $(ls -R "$JOBS_DIR")"
fi

# 17e: a nonzero codex exit is outcome=error and ALSO preserves the evidence.
: > "$LEDGER"
cat > "$TMP/codex-fail-stub" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 9
EOF
chmod +x "$TMP/codex-fail-stub"
set +e
OUT="$(CODEX_BIN="$TMP/codex-fail-stub" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 9 "codex nonzero exit still propagates verbatim" "fail-stub rc=$RC out=$OUT"
if grep -q '"outcome":"error"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=error"
else
  fail "no outcome=error end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -n "$(ls "$JOBS_DIR"/failed/*.json 2>/dev/null)" ]; then
  pass "job registry entry preserved under failed/ on a nonzero exit"
else
  fail "nonzero exit deleted the job registry evidence"
fi

# --- 18: explicit stdin + timeout diagnosis ---------------------
# A stub that reads to EOF catches the non-tty empty-pipe hang. Keep a FIFO
# open for reading AND writing: no data and no EOF until the fixture closes
# fd 9. The dispatch's short watchdog bounds the regression, not the producer.
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
STDIN_STUB="$TMP/codex-stdin-stub"
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
cat > "$TMP/codex.stdin"
exit 0
EOF
chmod +x "$STDIN_STUB"
run_stdin_dispatch() {  # run_stdin_dispatch <redirect-source> [wrapper/codex args...]
  local source="$1"
  shift
  set +e
  OUT="$(CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
      bash "$DISPATCH" --worktree "$WT" "$@" do-it < "$source" 2>&1)"
  RC=$?
  set -e
}
assert_timeout_reason() {
  if node - "$JOBS_DIR/failed" "$1" <<'NODE'
const fs = require('fs');
const [dir, reason] = process.argv.slice(2);
if (!fs.existsSync(dir)) process.exit(1);
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
if (files.length !== 1) process.exit(1);
const job = JSON.parse(fs.readFileSync(`${dir}/${files[0]}`, 'utf8'));
if (job.reason !== reason || !job.codex_pid || !job.dispatch_pid ||
    !job.worktree || !job.started_at) process.exit(1);
NODE
  then pass "timeout evidence: $1"; else fail "missing/incorrect timeout reason: $1"; fi
}
mkfifo "$TMP/empty-pipe"
exec 9<> "$TMP/empty-pipe"
run_stdin_dispatch "$TMP/empty-pipe"
assert_rc 0 "non-tty empty pipe defaults to EOF without timing out" "stdin-open-pipe rc=$RC out=$OUT"
exec 9>&-

printf 'the brief\nsecond line\n' > "$TMP/brief.txt"
: > "$TMP/codex.stdin"; : > "$TMP/codex.args"
run_stdin_dispatch "$TMP/brief.txt" --stdin-brief
assert_rc 0 "explicit stdin-brief dispatch exits 0" "stdin-brief rc=$RC out=$OUT"
if cmp -s "$TMP/brief.txt" "$TMP/codex.stdin"; then
  pass "--stdin-brief delivers the complete brief"
else
  fail "explicit stdin brief lost or changed"
fi
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_context_window=272000 do-it") pass "wrapper strips --stdin-brief from codex argv" ;;
  *) fail "stdin-brief codex args: $(cat "$TMP/codex.args")" ;;
esac
run_stdin_dispatch "$TMP/brief.txt"
assert_rc 0 "redirected file without opt-in exits 0" "stdin-file-default rc=$RC out=$OUT"
if [ ! -s "$TMP/codex.stdin" ]; then pass "redirected file is ignored without --stdin-brief"; else fail "implicit stdin brief passed through"; fi
run_stdin_dispatch /dev/null
assert_rc 0 "closed-stdin dispatch exits 0 without blocking" "stdin-null rc=$RC out=$OUT"
if [ ! -s "$TMP/codex.stdin" ]; then pass "closed stdin reaches codex as immediate EOF"; else fail "closed stdin delivered content"; fi

# Opting into a never-closing pipe still times out, with a useful diagnosis.
# A stderr startup message is NOT an event; the stdout event stream is empty.
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
printf 'Reading additional input from stdin...\n' >&2
cat > "$TMP/codex.stdin"
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
exec 9<> "$TMP/empty-pipe"
run_stdin_dispatch "$TMP/empty-pipe" --stdin-brief --json
exec 9>&-
assert_rc 124 "explicit open pipe is still bounded by the watchdog" "stdin-optin-timeout rc=$RC out=$OUT"
assert_timeout_reason 'no events before timeout — stdin pass-through?'

# The same diagnosis applies without opt-in if codex emits no stdout at all.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'starting up\n' >&2
sleep 120
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null --json
assert_rc 124 "stderr-only timeout exits 124" "stderr-timeout rc=$RC out=$OUT"
assert_timeout_reason 'no events before timeout — stdin pass-through?'

# Once stdout events arrive, preserve the ordinary timeout reason instead.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"thread.started","thread_id":"fixture"}\n'
sleep 120
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null --json
assert_rc 124 "timeout after events still exits 124" "events-timeout rc=$RC out=$OUT"
assert_timeout_reason 'timeout after 2s'
case "$OUT" in
  *'{"type":"thread.started","thread_id":"fixture"}'*) pass "stdout events still reach the caller" ;;
  *) fail "stdout event was swallowed: $OUT" ;;
esac

# 18f: dispatch completion must include the stdout relay, not just codex.
# Delay the forwarding cat after draining stdin to make the race deterministic;
# invoke directly (command substitution would wait on its pipe). Only the
# relay's two-argument invocation is intercepted, not library uses of cat.
REAL_CAT="$(command -v cat)"
mkdir -p "$TMP/slow-relay-bin"
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
payload=\$("$REAL_CAT" "\$@")
sleep 1
printf '%s\n' "\$payload"
printf done > "$TMP/relay.done"
EOF
chmod +x "$TMP/slow-relay-bin/cat"
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'final output\n'
EOF
set +e
PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=5 \
    bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
RC=$?
set -e
assert_rc 0 "slow stdout relay preserves codex exit status" "relay rc=$RC"
if [ -f "$TMP/relay.done" ] && [ "$(cat "$TMP/relay.stdout")" = 'final output' ]; then
  pass "dispatch waits for stdout forwarding to finish"
else
  fail "dispatch exited before stdout forwarding finished"
fi
# Let the deliberately delayed fixture finish even on RED before temp cleanup.
sleep 2

# 18g: a failed relay must not turn a successful codex into false success.
# Drain stdin first so codex can exit normally, then fail without forwarding.
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
"$REAL_CAT" "\$@" > /dev/null
exit 23
EOF
for child_rc in 0 7; do
  cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
printf 'final output\n'
exit $child_rc
EOF
  set +e
  PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=5 \
      bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
  RC=$?
  set -e
  if [ "$child_rc" -eq 0 ]; then
    assert_rc 23 "relay failure makes successful codex dispatch fail" "failed relay rc=$RC (expected 23)"
  else
    assert_rc 7 "codex failure takes precedence over relay failure" "failed codex and relay rc=$RC (expected 7)"
  fi
done

# A finished codex does not disarm the watchdog while the relay is stalled.
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
"$REAL_CAT" "\$@" > /dev/null
sleep 120
EOF
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'final output\n'
exit 0
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
set +e
PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
    bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
RC=$?
set -e
assert_rc 124 "watchdog bounds stalled relay after codex exits" "stalled relay rc=$RC"
assert_timeout_reason 'timeout after 2s'

# --- 19: large binary stdout stays byte-exact with bounded presence storage ---
# A full-retention tee fails the size assertion; dropped/reordered/NUL-stripped
# output fails the SHA-256 comparison. Snapshot before the dispatch EXIT cleanup.
mkdir -p "$TMP/presence-tmp"
node -e 'const fs = require("fs"); const b = Buffer.alloc(6 * 1024 * 1024); for (let i = 0; i < b.length; i++) b[i] = i % 256; fs.writeFileSync(process.argv[1], b)' "$TMP/payload.bin"
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
cat "$TMP/payload.bin"
for ((i=0; i<100; i++)); do
  [ "\$(wc -c < "$TMP/large.stdout")" -eq 6291456 ] && break
  sleep 0.05
done
wc -c "\$TMPDIR"/* > "$TMP/presence-sizes"
exit \${LARGE_CHILD_RC:-0}
EOF
for child_rc in 0 7; do
  set +e
  TMPDIR="$TMP/presence-tmp" LARGE_CHILD_RC="$child_rc" \
      CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=15 \
      bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/large.stdout" 2> "$TMP/large.stderr"
  RC=$?
  set -e
  assert_rc "$child_rc" "large stdout preserves child rc=$child_rc" "large output rc=$RC"
  if node - "$TMP/payload.bin" "$TMP/large.stdout" "$TMP/presence-sizes" <<'NODE'
const fs = require('fs'), crypto = require('crypto');
const [input, output, sizes] = process.argv.slice(2);
const hash = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
if (hash(input) !== hash(output)) { console.error('stdout SHA-256 mismatch'); process.exit(1); }
const rows = fs.readFileSync(sizes, 'utf8').trim().split('\n');
const total = Number(rows[rows.length - 1].trim().split(/\s+/)[0]);
if (total !== 1) { console.error(`presence storage=${total} bytes, expected 1`); process.exit(1); }
NODE
  then pass "6 MiB binary stdout hash matches; presence storage is one byte (rc=$child_rc)"
  else fail "large stdout forwarding or bounded presence tracking (rc=$child_rc)"; fi
done

# Timeout must win over a late nonzero child exit after stdout was observed.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
trap 'exit 7' TERM
printf 'event\n'
while :; do sleep 0.1; done
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null
assert_rc 124 "timeout wins over late child rc=7" "late child rc=$RC out=$OUT"
assert_timeout_reason 'timeout after 2s'

# --- 16: hook-trust preflight ----------------------------------
# codex keys hook trust to the absolute hooks.json path, so a fresh worktree
# runs with NO himmel hooks (an in-workspace force push
# succeeded). The lane must refuse to launch unless every PreToolUse hook of
# the worktree's .codex/hooks.json is trusted in $CODEX_HOME/config.toml.
# Fixtures: hooks.json is the REAL repo file; the config table shape
# ([hooks.state.'<abs hooks.json>:<event>:<group>:<hook>'] + trusted_hash) is
# copied from a real ~/.codex/config.toml.
REAL_HOOKS="$SCRIPT_DIR/../../.codex/hooks.json"
TRUST_WT="$TMP/.claude/worktrees/trust-wt"
mkdir -p "$TRUST_WT/.codex"
cp "$REAL_HOOKS" "$TRUST_WT/.codex/hooks.json"
# the primary checkout must RESOLVE; a fixture that is its own git
# repo is its own primary (git-common-dir = <it>/.git).
git -C "$TRUST_WT" init -q -b main
TRUST_HOME="$TMP/codex-home"
mkdir -p "$TRUST_HOME"

# codex trusts a hook only when trusted_hash equals the hash it
# recomputes from the hook definition. The helper below is a second, independent
# port of that computation, written from openai/codex rust-v0.161.0:
# hooks/src/engine/discovery.rs hook_hash() (a NormalizedHookIdentity of
# event_name + the matcher group holding the one normalized handler, as a TOML
# value) and config/src/fingerprint.rs version_for_toml() (sha256 of the compact
# JSON with every object key sorted). It prints one `<key>\t<hash>` row per hook
# of a hooks.json, <key> = <event>:<group>:<hook> in codex's snake_case labels.
HOOK_HASH_JS="$TMP/hook-hash.js"
cat > "$HOOK_HASH_JS" <<'EOF'
const fs = require("fs");
const crypto = require("crypto");
const label = { PreToolUse: "pre_tool_use", PostToolUse: "post_tool_use", SessionStart: "session_start", SessionEnd: "session_end", UserPromptSubmit: "user_prompt_submit", Stop: "stop" };
const sorted = (v) => Array.isArray(v) ? v.map(sorted)
  : (v && typeof v === "object") ? Object.keys(v).sort().reduce((o, k) => { o[k] = sorted(v[k]); return o; }, {})
  : v;
const version = (v) => "sha256:" + crypto.createHash("sha256").update(JSON.stringify(sorted(v))).digest("hex");
if (process.argv[2] === "--vector") {
  // upstream codex-rs/config/src/fingerprint_tests.rs, the config as TOML parsed to a value
  console.log(version({ rows: [{ z: 2, a: 1 }, { z: 4, a: 3 }], nested: { z: "text", a: true } }));
  process.exit(0);
}
const doc = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).hooks;
for (const [event, groups] of Object.entries(doc)) {
  groups.forEach((g, gi) => g.hooks.forEach((h, hi) => {
    const sessionEnd = event === "SessionEnd";
    const cmd = process.platform === "win32" && typeof h.commandWindows === "string" ? h.commandWindows : h.command;
    const handler = { type: "command", command: cmd, async: h.async === true,
      timeout: sessionEnd ? Math.min(Math.max(h.timeout === undefined ? 1 : h.timeout, 1), 3) : Math.max(h.timeout === undefined ? 600 : h.timeout, 1) };
    if (typeof h.statusMessage === "string") handler.statusMessage = h.statusMessage;
    const identity = { event_name: label[event], hooks: [handler] };
    // codex drops the matcher for these events before hashing (matcher_pattern_for_event)
    if (typeof g.matcher === "string" && !["stop", "user_prompt_submit", "interrupt"].includes(label[event])) identity.matcher = g.matcher;
    console.log(label[event] + ":" + gi + ":" + hi + "\t" + version(identity));
  }));
}
EOF

# trust_config <worktree> [skip-PreToolUse-ordinal|-] [enabled=false-ordinal|-]
# [skip-key|-] [stale-key|-]: write a config.toml trusting every hook (all
# events) of the real hooks.json under <worktree>, each with the hash codex
# computes. skip-key drops that <event>:<group>:<hook>; stale-key keeps its
# entry but with a wrong (well-formed) hash, the shape of an edited hooks.json.
trust_config() {
  node -e '
const fs = require("fs");
const { execFileSync } = require("child_process");
const [helper, hooks, wt, skip, off, skipKey, staleKey, out] = process.argv.slice(1);
let text = "[hooks.state]\n\n", n = 0;
for (const row of execFileSync("node", [helper, hooks], { encoding: "utf8" }).trim().split("\n")) {
  const [key, hash] = row.split("\t");
  const idx = key.startsWith("pre_tool_use:") ? n++ : -1;
  if (String(idx) === skip || key === skipKey) continue;
  text += "[hooks.state.\x27" + wt + "/.codex/hooks.json:" + key + "\x27]\n";
  if (String(idx) === off) text += "enabled = false\n";
  text += "trusted_hash = \"" + (key === staleKey ? "sha256:" + "ab".repeat(32) : hash) + "\"\n\n";
}
fs.writeFileSync(out, text);
' "$HOOK_HASH_JS" "$TRUST_WT/.codex/hooks.json" "$1" "${2:--}" "${3:--}" "${4:--}" "${5:--}" "$TRUST_HOME/config.toml"
}

run_trust() {  # run_trust <worktree> ; REAL trust check, own CODEX_HOME
  set +e
  OUT="$(env -u CODEX_HOOK_TRUST_CHECK CODEX_HOME="$TRUST_HOME" \
      CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
      bash "$DISPATCH" --worktree "$1" do-it 2>&1)"
  RC=$?
  set -e
}

# 16a: the defect - fresh worktree, no trust state at all -> refused.
: > "$LOG"; echo 0 > "$TMP/norm.rc"; : > "$TRUST_HOME/config.toml"
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_trust "$TRUST_WT"
assert_rc 2 "untrusted worktree hooks refused" "16a rc=$RC out=$OUT"
case "$OUT" in *"$TRUST_WT"*"not trusted"*) pass "refusal names the worktree and the trust state";; *) fail "16a out: $OUT";; esac
case "$OUT" in *"trust"*"interactive"*|*"interactive"*"trust"*) pass "refusal names a remedy";; *) fail "16a remedy missing: $OUT";; esac
case "$OUT" in *--dangerously-bypass-hook-trust*) fail "refusal suggests the bypass flag";; *) pass "refusal never suggests the bypass flag";; esac
if grep -q '^codex$' "$LOG" 2>/dev/null; then fail "codex invoked with untrusted hooks"; else pass "codex not invoked with untrusted hooks"; fi
if [ -z "$(ls "$JOBS_DIR" 2>/dev/null)" ]; then pass "refusal leaves no job registry entry"; else fail "16a left registry: $(ls "$JOBS_DIR")"; fi

# 16b: every PreToolUse hook trusted for THIS worktree path -> runs.
: > "$LOG"
trust_config "$TRUST_WT"
run_trust "$TRUST_WT"
assert_rc 0 "fully trusted worktree dispatches" "16b rc=$RC out=$OUT"
if grep -q '^codex$' "$LOG" 2>/dev/null; then pass "codex invoked when hooks are trusted"; else fail "16b codex not invoked"; fi

# 16c: one PreToolUse hook (index 3) missing from the trust state -> refused.
: > "$LOG"
trust_config "$TRUST_WT" 3
run_trust "$TRUST_WT"
assert_rc 2 "a single untrusted PreToolUse hook refuses" "16c rc=$RC out=$OUT"
case "$OUT" in *"pre_tool_use:3:0"*) pass "refusal names the missing hook key";; *) fail "16c out: $OUT";; esac

# 16d: trusted_hash present but enabled = false -> refused.
: > "$LOG"
trust_config "$TRUST_WT" - 2
run_trust "$TRUST_WT"
assert_rc 2 "a disabled hook refuses" "16d rc=$RC out=$OUT"

# 16e: trust recorded for ANOTHER worktree path only (the per-path keying) -> refused.
: > "$LOG"
trust_config "$TMP/.claude/worktrees/some-other-wt"
run_trust "$TRUST_WT"
assert_rc 2 "trust for another worktree path does not count" "16e rc=$RC out=$OUT"

# 16f: worktree without .codex/hooks.json has no guard chain -> refused.
: > "$LOG"
run_trust "$WT"
assert_rc 2 "worktree with no .codex/hooks.json refused" "16f rc=$RC out=$OUT"

# 16g: codex resolves a git worktree to its PRIMARY checkout and keys trust to
# that checkout's hooks.json, in the basic-quoted ("...") key shape observed in
# a real ~/.codex/config.toml (codex-cli 0.161.0, Linux) -> accepted.
PRIM="$TMP/primary"
mkdir -p "$PRIM"
git -C "$PRIM" init -q -b main
git -C "$PRIM" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
PRIM_WT="$PRIM/.claude/worktrees/prim-wt"
git -C "$PRIM" worktree add -q -b prim-wt "$PRIM_WT"
mkdir -p "$PRIM_WT/.codex"
cp "$REAL_HOOKS" "$PRIM_WT/.codex/hooks.json"
# codex loads a linked worktree's hooks from the PRIMARY checkout.
mkdir -p "$PRIM/.codex"
cp "$REAL_HOOKS" "$PRIM/.codex/hooks.json"
node -e '
const fs = require("fs");
const { execFileSync } = require("child_process");
const [helper, hooks, root, out] = process.argv.slice(1);
let text = "[hooks.state]\n\n";
for (const row of execFileSync("node", [helper, hooks], { encoding: "utf8" }).trim().split("\n")) {
  const [key, hash] = row.split("\t");
  text += "[hooks.state.\"" + root + "/.codex/hooks.json:" + key + "\"]\n";
  text += "trusted_hash = \"" + hash + "\"\n\n";
}
fs.writeFileSync(out, text);
' "$HOOK_HASH_JS" "$PRIM_WT/.codex/hooks.json" "$PRIM" "$TRUST_HOME/config.toml"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 0 "trust keyed to the primary checkout counts for its worktree" "16g rc=$RC out=$OUT"

# 16h: trust keyed to the linked worktree's OWN path while codex resolves to the
# primary checkout is an entry codex never reads -> refused.
trust_config "$PRIM_WT"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 2 "worktree-path trust does not count when codex keys to the primary" "16h rc=$RC out=$OUT"

# 16i: a PreToolUse array holding only empty groups declares no hook -> refused.
EMPTY_WT="$TMP/empty-wt"
mkdir -p "$EMPTY_WT/.codex"
git -C "$EMPTY_WT" init -q -b main
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}' > "$EMPTY_WT/.codex/hooks.json"
: > "$TRUST_HOME/config.toml"
: > "$LOG"
run_trust "$EMPTY_WT"
assert_rc 2 "PreToolUse with only empty groups refused" "16i rc=$RC out=$OUT"

# --- 17: trust-hash validity, primary resolution, CODEX_BIN --
# 17a: the hash helper reproduces codex's own published fingerprint vector
# (upstream codex-rs/config/src/fingerprint_tests.rs) - the one fixture here
# copied from the real upstream, so the helper's serialization is not my guess.
VEC="$(node "$HOOK_HASH_JS" --vector)"
if [ "$VEC" = "sha256:a5e4c8fbdbc75d185b0f2b5291bfb2de10e8c523d6c89248876fd78a97c83176" ]; then pass "17a hash helper reproduces codex's upstream fingerprint vector"; else fail "17a vector: $VEC"; fi

# 17b: a hash codex would NOT accept (stale: hooks.json edited since trust) on a
# PreToolUse hook is refused though a trusted_hash is present.
: > "$LOG"
trust_config "$TRUST_WT" - - - "pre_tool_use:3:0"
run_trust "$TRUST_WT"
assert_rc 2 "a stale trusted_hash refuses" "17b rc=$RC out=$OUT"
case "$OUT" in *"pre_tool_use:3:0"*) pass "17b refusal names the stale hook";; *) fail "17b out: $OUT";; esac
if grep -q '^codex$' "$LOG" 2>/dev/null; then fail "17b codex invoked on a stale hash"; else pass "17b codex not invoked on a stale hash"; fi

# 17c: hooks.json edited AFTER trust (the real defect path) -> refused.
: > "$LOG"
trust_config "$TRUST_WT"
cp "$TRUST_WT/.codex/hooks.json" "$TMP/hooks.json.good"
sed 's/auto-approve-safe-bash.sh/auto-approve-safe-bash-v2.sh/' "$TMP/hooks.json.good" > "$TRUST_WT/.codex/hooks.json"
run_trust "$TRUST_WT"
assert_rc 2 "hooks.json edited after trust refuses" "17c rc=$RC out=$OUT"
cp "$TMP/hooks.json.good" "$TRUST_WT/.codex/hooks.json"

# 17d: every PreToolUse hook trusted, one POST-tool hook not -> refused.
: > "$LOG"
trust_config "$TRUST_WT" - - "post_tool_use:0:0"
run_trust "$TRUST_WT"
assert_rc 2 "an untrusted non-PreToolUse hook refuses" "17d rc=$RC out=$OUT"
case "$OUT" in *"post_tool_use:0:0"*) pass "17d refusal names the post_tool_use hook";; *) fail "17d out: $OUT";; esac

# 17e: a worktree whose primary checkout cannot be resolved (not a git repo)
# must refuse, not fall back to trusting the worktree's own path.
NOGIT_WT="$TMP/.claude/worktrees/nogit-wt"
mkdir -p "$NOGIT_WT/.codex"
cp "$REAL_HOOKS" "$NOGIT_WT/.codex/hooks.json"
node -e '
const fs = require("fs");
const { execFileSync } = require("child_process");
const [helper, hooks, root, out] = process.argv.slice(1);
let text = "[hooks.state]\n\n";
for (const row of execFileSync("node", [helper, hooks], { encoding: "utf8" }).trim().split("\n")) {
  const [key, hash] = row.split("\t");
  text += "[hooks.state.\x27" + root + "/.codex/hooks.json:" + key + "\x27]\ntrusted_hash = \"" + hash + "\"\n\n";
}
fs.writeFileSync(out, text);
' "$HOOK_HASH_JS" "$NOGIT_WT/.codex/hooks.json" "$NOGIT_WT" "$TRUST_HOME/config.toml"
: > "$LOG"
run_trust "$NOGIT_WT"
assert_rc 2 "an unresolvable primary checkout refuses (no fallback to the worktree path)" "17e rc=$RC out=$OUT"
case "$OUT" in *"primary"*) pass "17e refusal names the primary checkout";; *) fail "17e out: $OUT";; esac

# 17f: the fully-trusted, correctly-hashed real hooks.json still launches.
: > "$LOG"
trust_config "$TRUST_WT"
run_trust "$TRUST_WT"
assert_rc 0 "correct hashes on every event dispatch" "17f rc=$RC out=$OUT"

# 17g: CODEX_BIN naming a wrapper that adds the trust bypass is refused before
# any launch (the wrapper sits OUTSIDE the argv filter).
BYPASS_BIN="$TMP/codex-bypass-wrapper"
cat > "$BYPASS_BIN" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exec "$CODEX_STUB" --dangerously-bypass-hook-trust "\$@"
EOF
chmod +x "$BYPASS_BIN"
: > "$LOG"
set +e
OUT="$(CODEX_BIN="$BYPASS_BIN" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 2 "a CODEX_BIN wrapper carrying the hook-trust bypass is refused" "17g rc=$RC out=$OUT"
if grep -q '^codex$' "$LOG" 2>/dev/null; then fail "17g wrapper was launched"; else pass "17g wrapper not launched"; fi

# 17h: CODEX_BIN and the trust-check override are registered chokepoint seams,
# so an env-prefixed call of the dispatch is denied by block-chokepoint-env-prefix.
if node -e '
const r = require(process.argv[1])["scripts/codex/dispatch-codex-exec.sh"];
const v = (r && r.seam_env_vars) || [];
process.exit(v.includes("CODEX_BIN") && v.includes("CODEX_HOOK_TRUST_CHECK") ? 0 : 1);
' "$SCRIPT_DIR/../chokepoints.json"; then pass "17h CODEX_BIN + CODEX_HOOK_TRUST_CHECK registered as chokepoint seams"; else fail "17h chokepoints.json lacks the codex dispatch seams"; fi

# --- 18: primary-keyed hooks, strict parse, real-codex hashes --
# trust_keyed <hooks-file-to-hash> <root> <out>: a config.toml trusting every hook
# of <hooks-file> under <root>/.codex/hooks.json (single-quoted key style).
trust_keyed() {
  node -e '
const fs = require("fs");
const { execFileSync } = require("child_process");
const [helper, hooks, root, out] = process.argv.slice(1);
let text = "[hooks.state]\n\n";
for (const row of execFileSync("node", [helper, hooks], { encoding: "utf8" }).trim().split("\n")) {
  const [key, hash] = row.split("\t");
  text += "[hooks.state.\x27" + root + "/.codex/hooks.json:" + key + "\x27]\ntrusted_hash = \"" + hash + "\"\n\n";
}
fs.writeFileSync(out, text);
' "$HOOK_HASH_JS" "$1" "$2" "$3"
}

# 18a: hashes WRITTEN BY REAL codex-cli 0.161.0 (app-server hooks/list currentHash,
# captured in a VM from these exact hook groups) accepted under the primary's key.
# Hand-written hashes could share my port's mistake; these cannot.
REAL_WT="$TMP/.claude/worktrees/real-codex-wt"
mkdir -p "$REAL_WT/.codex"
git -C "$REAL_WT" init -q -b main
cat > "$REAL_WT/.codex/hooks.json" <<'EOF'
{"hooks":{
"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":".codex/run-hook.sh --sandbox guard-leg-context-handoff.sh","commandWindows":".codex/run-hook.cmd --sandbox guard-leg-context-handoff.sh","timeout":15}]}],
"PostToolUse":[{"matcher":"Bash","hooks":[
{"type":"command","command":".codex/run-hook.sh --sandbox detect-dirty-primary.sh","commandWindows":".codex/run-hook.cmd --sandbox detect-dirty-primary.sh","timeout":15},
{"type":"command","command":".codex/run-hook.sh --sandbox memory-bash-line-check.sh","commandWindows":".codex/run-hook.cmd --sandbox memory-bash-line-check.sh","timeout":15}]}],
"SessionStart":[{"hooks":[{"type":"command","command":".codex/run-hook.sh --sandbox --lifecycle check-update-available.sh+inject-initiative.sh+inject-where-are-we.sh+inject-doc-freshness.sh+record-primary-baseline.sh","commandWindows":".codex/run-hook.cmd --sandbox --lifecycle check-update-available.sh+inject-initiative.sh+inject-where-are-we.sh+inject-doc-freshness.sh+record-primary-baseline.sh","timeout":60}]}],
"Stop":[{"hooks":[
{"type":"command","command":".codex/run-hook.sh --sandbox --lifecycle refresh-where-are-we-on-end.sh","commandWindows":".codex/run-hook.cmd --sandbox --lifecycle refresh-where-are-we-on-end.sh","timeout":15},
{"type":"command","command":".codex/run-hook.sh --sandbox --lifecycle jira-nudge-on-end.sh","commandWindows":".codex/run-hook.cmd --sandbox --lifecycle jira-nudge-on-end.sh","timeout":15},
{"type":"command","command":".codex/run-hook.sh --sandbox --lifecycle end-session-wiki.sh","commandWindows":".codex/run-hook.cmd --sandbox --lifecycle end-session-wiki.sh","timeout":30}]}],
"SessionEnd":[{"hooks":[{"type":"command","command":".codex/run-hook.sh --sandbox --lifecycle telegram-session-end.sh","commandWindows":".codex/run-hook.cmd --sandbox --lifecycle telegram-session-end.sh","timeout":3}]}]}}
EOF
{
  echo "[hooks.state]"; echo
  while IFS=' ' read -r key hash; do
    printf "[hooks.state.'%s/.codex/hooks.json:%s']\ntrusted_hash = \"%s\"\n\n" "$REAL_WT" "$key" "$hash"
  done <<'EOF'
pre_tool_use:0:0 sha256:b2958fcf295ae1c660aacb3a3bc4952c7b6096c464c87bef05f8812586476d7b
post_tool_use:0:0 sha256:74a2f199cd3d1fe8dfc021279c3856b8af90c9a1cbe8e2bd656c287174aac95e
post_tool_use:0:1 sha256:b9ec4431e6733f81b2da62571b683dc6ccd3a533033b6243aae303c7be2a0d93
session_start:0:0 sha256:a967b1e73acf6256090689cb3587f874ea0bc8a7f1d30d387a10cd496c012bdf
session_end:0:0 sha256:24cb0594d1890fa8f5eb120c48d92c8066899c42fcd0d104e3d19b2c7d3f78ac
stop:0:0 sha256:cda00ca3025ef438d2300c961c766219037571325297405e432b002593ba4994
stop:0:1 sha256:0b41497a42af0085dccfd642b5e9b0f33e92cd2301aabbbf187192a38e52cee2
stop:0:2 sha256:8391457cacc37a8e7242b1193c63750e5898cf59adda607950af912f6954b337
EOF
} > "$TRUST_HOME/config.toml"
: > "$LOG"
run_trust "$REAL_WT"
assert_rc 0 "hashes written by real codex 0.161.0 are accepted" "18a rc=$RC out=$OUT"
# 18b: the same real hashes, one hook edited afterwards -> refused (stale).
cp "$REAL_WT/.codex/hooks.json" "$TMP/real-hooks.good"
sed 's/jira-nudge-on-end.sh/jira-nudge-on-end-v2.sh/g' "$TMP/real-hooks.good" > "$REAL_WT/.codex/hooks.json"
: > "$LOG"
run_trust "$REAL_WT"
assert_rc 2 "a real-codex hash goes stale when its hook is edited" "18b rc=$RC out=$OUT"
case "$OUT" in *"stop:0:1"*) pass "18b refusal names stop:0:1";; *) fail "18b out: $OUT";; esac
cp "$TMP/real-hooks.good" "$REAL_WT/.codex/hooks.json"

# 18c-f: a LINKED worktree runs the PRIMARY's hooks (verified live on
# codex 0.161.0). Trust is keyed to the primary; PRIM and PRIM_WT both carry the
# real hooks.json from 16g.
trust_keyed "$PRIM/.codex/hooks.json" "$PRIM" "$TRUST_HOME/config.toml"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 0 "18c linked worktree equal to the trusted primary dispatches" "rc=$RC out=$OUT"
# worktree edited, primary untouched and still trusted -> codex would run the
# primary's hooks, not what this worktree carries: refused.
sed 's/guard-leg-context-handoff.sh/guard-leg-context-handoff-v2.sh/' "$PRIM/.codex/hooks.json" > "$PRIM_WT/.codex/hooks.json"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 2 "18d a worktree hooks.json edited away from the primary refuses" "rc=$RC out=$OUT"
case "$OUT" in *"differs"*"primary"*) pass "18d refusal says the primary's hooks are the ones in effect";; *) fail "18d out: $OUT";; esac
# primary edited after trust, worktree still the old copy -> refused (differs).
cp "$REAL_HOOKS" "$PRIM_WT/.codex/hooks.json"
sed 's/guard-leg-context-handoff.sh/guard-leg-context-handoff-v2.sh/' "$REAL_HOOKS" > "$PRIM/.codex/hooks.json"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 2 "18e a primary edited under a stale worktree copy refuses" "rc=$RC out=$OUT"
# both synced to the edit but trust is stale -> refused on the hash.
cp "$PRIM/.codex/hooks.json" "$PRIM_WT/.codex/hooks.json"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 2 "18f an edited primary with a stale trusted_hash refuses" "rc=$RC out=$OUT"
case "$OUT" in *"stale trusted_hash"*) pass "18f refusal names the stale hash";; *) fail "18f out: $OUT";; esac
# worktree without a hooks.json beside a primary that has one -> refused.
cp "$REAL_HOOKS" "$PRIM/.codex/hooks.json"
trust_keyed "$PRIM/.codex/hooks.json" "$PRIM" "$TRUST_HOME/config.toml"
mv "$PRIM_WT/.codex/hooks.json" "$TMP/prim-wt-hooks.json.away"
: > "$LOG"
run_trust "$PRIM_WT"
assert_rc 2 "18g a worktree missing hooks.json beside a primary refuses" "rc=$RC out=$OUT"
mv "$TMP/prim-wt-hooks.json.away" "$PRIM_WT/.codex/hooks.json"

# 18h-m: parse strictness. codex rejects the whole file (zero hooks) on an
# unknown top-level field, a wrong type or a duplicate key, and silently ignores
# the `hooks.hooks || hooks` shape; each is refused here although every hash is
# valid for the real hooks.json (so a lenient parse would have accepted them).
SHAPE_WT="$TMP/.claude/worktrees/shape-wt"
mkdir -p "$SHAPE_WT/.codex"
git -C "$SHAPE_WT" init -q -b main
trust_keyed "$REAL_HOOKS" "$SHAPE_WT" "$TRUST_HOME/config.toml"
# shape_case <label> <rc> <needle> <mutator-js(d,text)>: hooks.json = mutated real file.
shape_case() {
  node -e '
const fs = require("fs");
const text = fs.readFileSync(process.argv[1], "utf8");
const r = new Function("d", "text", process.argv[2])(JSON.parse(text), text);
fs.writeFileSync(process.argv[3], (typeof r === "string" || Buffer.isBuffer(r)) ? r : JSON.stringify(r, null, 2));
' "$REAL_HOOKS" "$4" "$SHAPE_WT/.codex/hooks.json"
  : > "$LOG"
  run_trust "$SHAPE_WT"
  assert_rc "$2" "$1" "rc=$RC out=$OUT"
  case "$OUT" in *"$3"*) pass "$1 message names its cause";; *) fail "$1 out: $OUT";; esac
}
shape_case "18h unknown top-level field" 2 "unknown top-level field" 'd.extra = 1; return d;'
shape_case "18i wrong type (timeout string)" 2 "timeout is not a non-negative integer" 'd.hooks.PreToolUse[0].hooks[0].timeout = "60"; return d;'
shape_case "18j duplicate key" 2 "duplicate key" 'return text.replace("\"timeout\": 60", "\"timeout\": 60, \"timeout\": 60");'
shape_case "18k hooks.hooks fallback shape (no hooks wrapper)" 2 "codex would load no hooks" 'return d.hooks;'
shape_case "18l group hooks not an array" 2 "is not an array" 'd.hooks.Stop[0].hooks = {}; return d;'
shape_case "18m invalid matcher regex" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "("; return d;'
shape_case "18o u64 overflow (additionalContextLimit 1e20)" 2 "outside the accepted grammar" 'd.hooks.Stop[0].hooks[0].additionalContextLimit = 1e20; return d;'
shape_case "18p matcher with lookahead (JS-only regex syntax)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "Bash(?=x)"; return d;'
shape_case "18q matcher with backreference (JS-only regex syntax)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "(a)\\1"; return d;'
shape_case "18r float-syntax timeout (60.0)" 2 "outside the accepted grammar" 'return text.replace("\"timeout\": 60", "\"timeout\": 60.0");'
shape_case "18t JSON booleans stay booleans (async true parses, only the hash is stale)" 2 "stale trusted_hash" 'd.hooks.PreToolUse[0].hooks[0].async = true; return d;'
shape_case "18u -0 timeout (serde reads F64 -0.0)" 2 "outside the accepted grammar" 'return text.replace("\"timeout\": 60", "\"timeout\": -0");'
shape_case "18v lone surrogate escape in description" 2 "lone surrogate" 'd.description = "PLACE"; return JSON.stringify(d).replace("PLACE", "\\ud800");'
shape_case "18w invalid UTF-8 byte in description" 2 "not valid" 'd.description = "aPLACEb"; const [a, b] = JSON.stringify(d).split("PLACE"); return Buffer.concat([Buffer.from(a), Buffer.from([0xff]), Buffer.from(b)]);'
shape_case "18s matcher with unknown letter escape" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\qb"; return d;'
# 18x-18ab: JS accepts these escapes, Rust rejects or mis-reads them; the closed
# matcher grammar has no backslash at all.
shape_case "18x matcher with malformed hex escape (\\xZZ)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\xZZ"; return d;'
shape_case "18y matcher with hex escape (\\x41)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\x41"; return d;'
shape_case "18z matcher with start-anchor escape (\\A)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "\\Aa"; return d;'
shape_case "18aa matcher with unicode class (\\p{L})" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "\\p{L}"; return d;'
shape_case "18ab matcher with octal escape (\\0)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\0"; return d;'
shape_case "18af matcher with stray brace (a{)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a{"; return d;'
shape_case "18ag matcher with lone bracket (a])" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a]"; return d;'
# Even escapes the old allow-list accepted now refuse (no backslash in the grammar).
shape_case "18ac escaped dot refused" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\.b"; return d;'
shape_case "18ad class and boundary escapes refused" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "\\bfoo\\d\\s\\W"; return d;'
shape_case "18ae escaped pipe and paren refused" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a\\|b\\(c\\)"; return d;'
# 18ah-18an: JS accepts these, Rust regex-syntax rejects them.
shape_case "18ah matcher [\\b] (backspace in a class)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "[\\b]"; return d;'
shape_case "18ai matcher [] (empty class)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "[]"; return d;'
shape_case "18aj matcher [^] (negated empty class)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "[^]"; return d;'
shape_case "18ak matcher a{4294967296} (repetition past the Rust limit)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a{4294967296}"; return d;'
shape_case "18al matcher nested 300 groups" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "(".repeat(300) + "a" + ")".repeat(300); return d;'
shape_case "18am matcher with empty alternative (a||b)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a||b"; return d;'
shape_case "18an matcher with repeated quantifier (a**)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a**"; return d;'
# 18ao-18as: a value in an UNKNOWN field never reaches a typed check, yet serde
# fails the whole file on it (out of range number, deep nesting), and the closed
# schema refuses any unknown key.
shape_case "18ao unknown handler field with 1e400" 2 "outside the accepted grammar" 'return text.replace("\"timeout\": 60", "\"timeout\": 60, \"extra\": 1e400");'
shape_case "18ap unknown handler field with a 400-digit integer" 2 "outside the accepted grammar" 'return text.replace("\"timeout\": 60", "\"timeout\": 60, \"extra\": " + "9".repeat(400));'
shape_case "18aq nesting deeper than serde limit (200)" 2 "nesting deeper than 32" 'd.description = "PLACE"; return JSON.stringify(d).replace("\"PLACE\"", "[".repeat(200) + "]".repeat(200));'
shape_case "18ar nesting deeper than 32 but inside serde limit (50)" 2 "nesting deeper than 32" 'd.description = "PLACE"; return JSON.stringify(d).replace("\"PLACE\"", "[".repeat(50) + "]".repeat(50));'
shape_case "18as unknown handler field (extra:1)" 2 "unknown field" 'd.hooks.PreToolUse[0].hooks[0].extra = 1; return d;'
shape_case "18at unknown group field" 2 "unknown field" 'd.hooks.PreToolUse[0].extra = "x"; return d;'
shape_case "18au unknown event key" 2 "unknown hook event" 'd.hooks.NotAnEvent = []; return d;'
# A matcher inside the closed grammar parses; only the hash is stale.
shape_case "18av grammar-conformant matcher allowed" 2 "stale trusted_hash" 'd.hooks.PreToolUse[0].matcher = "Bash|Read.*(a|b)+?$"; return d;'
# 18n: codex drops the matcher of a Stop group before hashing, so a matcher there
# must not change the identity: dispatch still accepts the unchanged hashes.
shape_case "18n matcher on a Stop group is ignored" 0 "" 'd.hooks.Stop[0].matcher = "Bash"; return d;'

# 18aw-18bc: residual differences from codex. A matcher inside the
# closed grammar can still blow the Rust regex compile-size limit (no counted
# repetition, so the cost is linear in its length: refuse past a conservative
# length cap), and codex skips a command hook whose command is empty or only
# Unicode White_Space (Rust str::trim; U+FEFF is not White_Space).
shape_case "18aw matcher far past the compile-size limit (100000 dots)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = ".".repeat(100000); return d;'
shape_case "18ax matcher at the length cap (1024) still parses" 2 "stale trusted_hash" 'd.hooks.PreToolUse[0].matcher = "a".repeat(1024); return d;'
shape_case "18ay matcher one past the length cap (1025)" 2 "regular expression" 'd.hooks.PreToolUse[0].matcher = "a".repeat(1025); return d;'
shape_case "18az empty command" 2 "command is empty" 'd.hooks.PreToolUse[0].hooks[0].command = ""; return d;'
shape_case "18ba whitespace-only command" 2 "command is empty" 'd.hooks.PreToolUse[0].hooks[0].command = " \t\n "; return d;'
shape_case "18bb NBSP-only command (Unicode White_Space)" 2 "command is empty" 'd.hooks.PreToolUse[0].hooks[0].command = String.fromCharCode(0xa0); return d;'
shape_case "18bc BOM-only command is not White_Space to Rust" 2 "stale trusted_hash" 'd.hooks.PreToolUse[0].hooks[0].command = String.fromCharCode(0xfeff); return d;'

# 19a-i: the config.toml reader counts only what codex keeps. An
# entry whose `enabled` is not a TOML boolean is discarded by codex; a header
# inside a multi-line string is string content, not a table.
: > "$LOG"
trust_config "$TRUST_WT"
run_trust "$TRUST_WT"
assert_rc 0 "19a baseline: fully trusted config dispatches" "rc=$RC out=$OUT"
# toml_edit <label> <rc> <needle> <mutator-js(text,key,hash)>: mutate the fully
# trusted config.toml; key/hash are pre_tool_use:3:0's trust key and hash.
toml_edit() {
  trust_config "$TRUST_WT"
  node -e '
const fs = require("fs");
const { execFileSync } = require("child_process");
const [helper, hooks, wt, cfg, mut] = process.argv.slice(1);
const rows = execFileSync("node", [helper, hooks], { encoding: "utf8" }).trim().split("\n").map((r) => r.split("\t"));
const hash = rows.find((r) => r[0] === "pre_tool_use:3:0")[1];
const header = "[hooks.state.\x27" + wt + "/.codex/hooks.json:pre_tool_use:3:0\x27]";
const r = new Function("text", "header", "hash", mut)(fs.readFileSync(cfg, "utf8"), header, hash);
fs.writeFileSync(cfg, r);
' "$HOOK_HASH_JS" "$TRUST_WT/.codex/hooks.json" "$TRUST_WT" "$TRUST_HOME/config.toml" "$4"
  : > "$LOG"
  run_trust "$TRUST_WT"
  assert_rc "$2" "$1" "rc=$RC out=$OUT"
  if [ -n "$3" ]; then case "$OUT" in *"$3"*) pass "$1 names its cause";; *) fail "$1 out: $OUT";; esac; fi
}
toml_edit "19b enabled = \"yes\" (non-boolean) is a discarded entry" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\nenabled = \"yes\"\n");'
toml_edit "19c enabled = true stays trusted" 0 "" 'return text.replace(header + "\n", header + "\nenabled = true\n");'
toml_edit "19d header inside a multi-line basic string is not a table" 2 "pre_tool_use:3:0" 'const at = text.indexOf(header); const end = text.indexOf("\n\n", at) + 2; return "note = \"\"\"\n" + text.slice(at, end) + "\"\"\"\n" + text.slice(0, at) + text.slice(end);'
toml_edit "19e header inside a multi-line literal string is not a table" 2 "pre_tool_use:3:0" 'const at = text.indexOf(header); const end = text.indexOf("\n\n", at) + 2; return "note = \x27\x27\x27\n" + text.slice(at, end) + "\x27\x27\x27\n" + text.slice(0, at) + text.slice(end);'
# a multi-line string that CLOSES before a real entry does not hide that entry.
toml_edit "19f entry after a closed multi-line string still counts" 0 "" 'return "note = \"\"\"\nx\n\"\"\"\n" + text;'
# a trailing comment holding U+2028/U+2029 (which JS `.` does not match) must not
# make a `enabled = false` line unreadable and so leave the entry trusted.
toml_edit "19g enabled = false with a U+2028 comment is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\nenabled = false # x" + String.fromCharCode(0x2028) + "\n");'
toml_edit "19h enabled = false with a U+2029 comment is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\nenabled = false # x" + String.fromCharCode(0x2029) + "\n");'
toml_edit "19i enabled = true with a U+2028 comment stays trusted" 0 "" 'return text.replace(header + "\n", header + "\nenabled = true # x" + String.fromCharCode(0x2028) + "\n");'

# 19j-19q: a quoted `enabled` key is the same key to codex, and a
# line starting with [ inside a multi-line array is an element, not a table header.
toml_edit "19j basic-quoted \"enabled\" = false is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\n\"enabled\" = false\n");'
toml_edit "19k literal-quoted single-quoted enabled = false is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\n\x27enabled\x27 = false\n");'
toml_edit "19l quoted key with inner whitespace is discarded (fail closed)" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\n\" enabled \" = false\n");'
toml_edit "19m basic-quoted \"enabled\" = true stays trusted" 0 "" 'return text.replace(header + "\n", header + "\n\"enabled\" = true\n");'
toml_edit "19n nested array line before enabled = false is discarded" 2 "pre_tool_use:3:0" 'const at = text.indexOf(header); const nl = text.indexOf("\n", text.indexOf("trusted_hash", at)) + 1; return text.slice(0, nl) + "note = [\n[\"a\"],\n]\nenabled = false\n" + text.slice(nl);'
toml_edit "19o nested array line before enabled = true stays trusted" 0 "" 'const at = text.indexOf(header); const nl = text.indexOf("\n", text.indexOf("trusted_hash", at)) + 1; return text.slice(0, nl) + "note = [\n[\"a\"],\n]\nenabled = true\n" + text.slice(nl);'
toml_edit "19p bracket inside an array string does not close it" 2 "pre_tool_use:3:0" 'const at = text.indexOf(header); const nl = text.indexOf("\n", text.indexOf("trusted_hash", at)) + 1; return text.slice(0, nl) + "note = [\n\"]\",\n[\"a\"],\n]\nenabled = false\n" + text.slice(nl);'
toml_edit "19q enabled = false inside an array is not the key" 0 "" 'const at = text.indexOf(header); const nl = text.indexOf("\n", text.indexOf("trusted_hash", at)) + 1; return text.slice(0, nl) + "note = [\n[\"a\"],\n\"enabled = false\",\n]\n" + text.slice(nl);'
toml_edit "19r escaped quoted key (enab\\u006ced) = false is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\n\"enab\\u006ced\" = false\n");'

# 19s-19x: escapes in a header key decode like TOML (\n LF, \t TAB,
# not n / t), a header key with \x or \e is refused (toml 1.0 fails the whole file,
# 1.1 decodes it: unknown which codex links), \x in a quoted setting name decodes,
# and an unterminated array / multi-line string at EOF trusts nothing.
toml_edit "19s header key with \\n escape is not the real key (fail closed)" 2 "pre_tool_use:3:0" 'return text.replace(header, "[hooks.state.\"" + header.slice(14, -2).replace("hooks.json", "hooks.jso\\n") + "\"]");'
toml_edit "19t header key with \\t escape is not the real key (fail closed)" 2 "pre_tool_use:3:0" 'return text.replace(header, "[hooks.state.\"" + header.slice(14, -2).replace("pre_tool", "pre_\\tool") + "\"]");'
toml_edit "19u header key with \\x escape is refused" 2 "pre_tool_use:3:0" 'return text.replace(header, "[hooks.state.\"" + header.slice(14, -2).replace("hooks.json", "hooks.jso\\x6E") + "\"]");'
toml_edit "19v escaped quoted key (enab\\x6Ced) = false is discarded" 2 "pre_tool_use:3:0" 'return text.replace(header + "\n", header + "\n\"enab\\x6Ced\" = false\n");'
toml_edit "19w unterminated array at EOF trusts nothing" 2 "pre_tool_use:3:0" 'return text + "note = [\n\"a\",\n";'
toml_edit "19x unterminated multi-line string at EOF trusts nothing" 2 "pre_tool_use:3:0" 'return text + "note = \"\"\"\nopen\n";'

# 19y-19ae: a REAL key may hold a backslash (a Windows path, a POSIX
# directory named a\x41). A raw, unescaped backslash in a basic-quoted header is an
# escape to TOML (1.1 decodes \x41 to A, \e is ESC; 1.0 refuses the file), so the
# raw text must not be trusted even when it equals the real key; the escaped form
# (\\ doubled) and the literal-quoted form are the same key as the real one.
# bs_case <label> <rc> <worktree dir name> <raw|escaped|literal>
bs_case() {
  local wt="$TMP/.claude/worktrees/$3"
  mkdir -p "$wt/.codex"
  cp "$REAL_HOOKS" "$wt/.codex/hooks.json"
  git -C "$wt" init -q -b main
  trust_config "$wt"
  node -e '
const fs = require("fs");
const [cfg, mode] = process.argv.slice(1);
const out = fs.readFileSync(cfg, "utf8").split("\n").map((line) => {
  if (!line.startsWith("[hooks.state.\x27") || !line.endsWith("\x27]")) return line;
  const inner = line.slice(14, -2);
  if (mode === "raw") return "[hooks.state.\"" + inner + "\"]";
  if (mode === "escaped") return "[hooks.state.\"" + inner.replace(/\\/g, "\\\\") + "\"]";
  return line;
}).join("\n");
fs.writeFileSync(cfg, out);
' "$TRUST_HOME/config.toml" "$4"
  : > "$LOG"
  run_trust "$wt"
  assert_rc "$2" "$1" "rc=$RC out=$OUT"
}
bs_case "19y real key a\\x41 as literal-quoted header stays trusted" 0 'a\x41' literal
bs_case "19z real key a\\x41 as escaped basic header (a\\\\x41) stays trusted" 0 'a\x41' escaped
bs_case "19aa real key a\\x41 written raw in a basic header is refused" 2 'a\x41' raw
bs_case "19ab real key a\\eb written raw in a basic header is refused (\\e)" 2 'a\eb' raw
bs_case "19ac real key a\\wb written raw in a basic header is refused (unknown escape)" 2 'a\wb' raw
bs_case "19ad real key a\\U0011FFFF written raw is refused (out of range)" 2 'a\U0011FFFF' raw
bs_case "19ae real key a\\n written raw is refused (decodes to LF, not the key)" 2 'a\nb' raw

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
