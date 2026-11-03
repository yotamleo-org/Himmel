#!/usr/bin/env bash
# test-adopt-hooks-gates.sh — the plugin-failure and shared-payload gate scenarios.
# The adopt.sh smoke tests live in several suites so
# each stays well under the runner's per-suite time cap. Same fixture
# (scripts/lib/adopt-test-fixture.sh): stubs `claude` on PATH, throwaway temp
# dirs, a fake HOME.
#
# Covers the plugin-failure gates and the worktree and shared-payload gates of
# adopt.sh, split from scripts/test-adopt-features.sh.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# ── 19c. plugin failure must not leave an adopter ungated ───────
# A second claude stub shadows the suite's successful one only for these runs.
# Empty plugin-list output models a failed install, not an already-installed
# plugin (whose nonzero install status is legitimately tolerated).
failurebin="$work/plugin-failure-bin"; mkdir -p "$failurebin"
cat > "$failurebin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = plugin ] && [ "$2" = install ]; then
  echo 'PLUGIN_INSTALL_FAILURE_STUB' >&2
  exit 1
fi
exit 0
STUB
cat > "$failurebin/pre-commit" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$PWD" "\$*" >> "$work/plugin-failure-hooks.argv"
exit 0
STUB
chmod +x "$failurebin/claude" "$failurebin/pre-commit"
for hook_mode in default skip; do
  failuretarget="$work/plugin-failure-$hook_mode"
  failurehome="$work/plugin-failure-home-$hook_mode"
  mkdir -p "$failuretarget" "$failurehome"
  ( cd "$failuretarget" && HOME="$failurehome" git init -q )
  # This block is about ordering (hooks before plugins), so it takes the
  # framework path -- that needs the adopter's own config (no-config = 19d).
  [ "$hook_mode" = skip ] || : > "$failuretarget/.pre-commit-config.yaml"
  : > "$work/plugin-failure-hooks.argv"
  hook_args=()
  [ "$hook_mode" != skip ] || hook_args+=(--skip-hooks)
  set +e
  out=$(PATH="$failurebin:$work/bin:$qmd_free_path" HOME="$failurehome" bash "$adopt" \
        --profile core --scope project --target "$failuretarget" ${hook_args[@]+"${hook_args[@]}"} 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "HIMMEL-2818 $hook_mode: plugin failure must abort adopt"
  grepq "$out" 'PLUGIN_INSTALL_FAILURE_STUB' \
    || fail "HIMMEL-2818 $hook_mode: failing plugin install was not reached: $out"
  grepq "$out" 'plugin(s) not present after install:' \
    || fail "HIMMEL-2818 $hook_mode: missing fatal plugin verification diagnostic: $out"
  if [ "$hook_mode" = default ]; then
    grep -qxF "$failuretarget" "$work/plugin-failure-hooks.argv" \
      || fail "HIMMEL-2818 default: hooks were not installed in the target before plugin failure"
    grep -qxF 'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
      "$work/plugin-failure-hooks.argv" \
      || fail "HIMMEL-2818 default: hook install must include all three gate types"
    plugin_header='──── Installing plugins (--scope project) ────'
    grepq "$out" -F "$plugin_header" \
      || fail "HIMMEL-2818 default: missing plugin install section"
    before_plugins=${out%%"$plugin_header"*}
    grepq "$before_plugins" -F 'git hooks installed (pre-commit, commit-msg, pre-push).' \
      || fail "HIMMEL-2818 default: hooks must be installed BEFORE the plugin section"
  else
    [ ! -s "$work/plugin-failure-hooks.argv" ] \
      || fail "HIMMEL-2818 skip: --skip-hooks must not invoke pre-commit"
    for hook in pre-commit commit-msg pre-push; do
      [ ! -e "$failuretarget/.git/hooks/$hook" ] \
        || fail "HIMMEL-2818 skip: --skip-hooks placed $hook despite the opt-out"
    done
  fi
  echo "ok: HIMMEL-2818 $hook_mode: plugin failure stays fatal and hook placement respects the opt-out"
done

# gap 1 (mirror of cr2771r6-worktree-primary-gate, reversed): adopt
# the PRIMARY checkout itself -- its resolved hooks dir is `$TARGET/.git/hooks`,
# INSIDE $TARGET -- and only THEN add a SIBLING worktree, with no re-run of
# adopt.sh against it. Pre-fix, install_native_hooks() keyed the fallback
# payload decision on containment ("hooks dir inside $TARGET => no payload
# needed"), true here even though this is Git's ONE per-repository hooks dir
# that the sibling worktree shares. RED against the pre-fix code = the
# sibling's dispatcher (same physical script file; only $root at fire-time
# differs) finds neither $root/scripts/hooks (the branch it was created from
# carries no tree copy) nor a payload, and refuses every commit with the
# "not found ... re-run adopt.sh" message instead of genuinely gating.
crprimaryG1="$work/cr2814g1-primary"; crwtG1="$work/cr2814g1-wt"
crbinG1="$work/cr2814g1-bin"
mkdir -p "$crprimaryG1" "$crbinG1"
HOME="$pchome" git -C "$crprimaryG1" init -q
HOME="$pchome" git -C "$crprimaryG1" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimaryG1" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimaryG1" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap1 primary commit'
set +e
out=$(PATH="$crbinG1:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crprimaryG1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: adopt exited $rc against the PRIMARY checkout: $out"
[ -x "$crprimaryG1/.git/hooks/himmel-payload/scripts/hooks/check-commit-msg.sh" ] \
  || fail "HIMMEL-2814 gap1 shared-payload: no fallback payload was left beside the PRIMARY's own (shared) hooks dir"
[ -f "$crprimaryG1/.git/hooks/himmel-payload/scripts/lib/project-mode.sh" ] \
  || fail "HIMMEL-4758 shared-payload: the payload carries check-commit-msg.sh without the scripts/lib/project-mode.sh it sources"
[ -f "$crprimaryG1/.git/hooks/himmel-payload/scripts/lib/git-clean.sh" ] \
  || fail "HIMMEL-5308 shared-payload: the payload carries check-push-target.sh without the scripts/lib/git-clean.sh it sources"
HOME="$pchome" git -C "$crprimaryG1" worktree add -q "$crwtG1" -b cr2814g1-worktree-branch

# Resolve the hooks dir from the SIBLING's own view (it is the same physical
# path as the primary's, since hooks are per-repository, not per-worktree --
# but resolve it this way rather than assuming so, mirroring cr2771r5-worktree-default above).
effective_hooks_dir_g1=$(HOME="$pchome" git -C "$crwtG1" rev-parse --git-path hooks)
case "$effective_hooks_dir_g1" in
  /*) : ;;
  *) effective_hooks_dir_g1="$crwtG1/$effective_hooks_dir_g1" ;;
esac

msgfileG1="$work/cr2814g1-valid.msg"
printf 'test: HIMMEL-2814 [#2814] gap1 worktree valid message\n' > "$msgfileG1"
set +e
woutG1=$( cd "$crwtG1" && HOME="$pchome" bash "$effective_hooks_dir_g1/commit-msg" "$msgfileG1" 2>&1 ); wrcG1=$?
set -e
[ "$wrcG1" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: SIBLING worktree's commit-msg dispatcher rejected a valid ticketed message added AFTER the primary adopt (rc=$wrcG1): $woutG1"
grepq "$woutG1" 'not found in' \
  && fail "HIMMEL-2814 gap1 shared-payload: sibling worktree hit the missing-script 'not found ... re-run adopt.sh' error: $woutG1"

msgfileG1b="$work/cr2814g1-noticket.msg"
printf 'no ticket here at all\n' > "$msgfileG1b"
set +e
woutG1b=$( cd "$crwtG1" && HOME="$pchome" bash "$effective_hooks_dir_g1/commit-msg" "$msgfileG1b" 2>&1 ); wrcG1b=$?
set -e
[ "$wrcG1b" -ne 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: an unticketed message exited 0 in the sibling worktree -- the gate did not actually run: $woutG1b"
echo "ok: HIMMEL-2814 gap1 shared-payload: adopting the PRIMARY checkout leaves a fallback payload that gates a SIBLING worktree added afterward, with no re-run of adopt.sh"

# gap 1, push variant (contract item 3): the same sibling
# worktree's pre-push dispatcher genuinely gates a REAL `git push` (not just a
# hand-invoked commit-msg dispatcher) via its fallback payload -- proving the
# fix covers the pre-push hook too, not only commit-msg.
crremoteG1="$work/cr2814g1-remote.git"
HOME="$pchome" git init -q --bare "$crremoteG1"
HOME="$pchome" git -C "$crwtG1" config user.name 'Native Test'
HOME="$pchome" git -C "$crwtG1" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crwtG1" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap1 worktree push probe commit'
HOME="$pchome" git -C "$crwtG1" remote add origin "$crremoteG1"

set +e
poutG1=$(HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/main 2>&1); prcG1=$?
set -e
[ "$prcG1" -ne 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload push: a direct push to main from the SIBLING worktree landed"
grepq "$poutG1" 'not found in' \
  && fail "HIMMEL-2814 gap1 shared-payload push: sibling worktree's pre-push dispatcher hit the missing-script error instead of genuinely gating: $poutG1"
grepq "$poutG1" "Direct push to 'main' is not allowed" \
  || fail "HIMMEL-2814 gap1 shared-payload push: push was refused but not by the real check-push-target.sh gate: $poutG1"
! HOME="$pchome" git -C "$crremoteG1" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
  || fail "HIMMEL-2814 gap1 shared-payload push: remote has refs/heads/main even though the push was refused"

set +e
poutG1b=$(HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/fix/cr2814g1-ok 2>&1); prcG1b=$?
set -e
[ "$prcG1b" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload push: a push to a non-main ref from the SIBLING worktree was refused: $poutG1b"
# the gate sources scripts/lib/git-clean.sh; a payload without it
# prints source errors on every push and git_env_scrub never runs.
grepq "$poutG1b" 'No such file|cannot open|not found' \
  && fail "HIMMEL-5308 shared-payload push: the pre-push gate printed source errors (payload is missing a file it sources): $poutG1b"
# BRANCH_NAME_OK bypasses the branch-NAME check only, never the main refusal.
set +e
poutG1c=$(BRANCH_NAME_OK=1 HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/main 2>&1); prcG1c=$?
set -e
[ "$prcG1c" -ne 0 ] \
  || fail "HIMMEL-5308 BRANCH_NAME_OK=1 let a push to main land"
grepq "$poutG1c" "Direct push to 'main' is not allowed" \
  || fail "HIMMEL-5308 BRANCH_NAME_OK=1 push to main was refused but not by the main gate: $poutG1c"
echo "ok: HIMMEL-2814 gap1 shared-payload push: the SIBLING worktree's pre-push dispatcher (added after the primary adopt) genuinely gates a real git push via its fallback payload"

# gap 2: the generated pre-push dispatcher's `cat > "$reffile"`
# stdin-capture return status was unchecked -- a read error or a full
# $TMPDIR would leave a TRUNCATED ref list that check-push-target.sh then
# validates instead of the refs actually being pushed, letting a push that
# should have been refused pass. Force the capture to fail by wrapping
# `mktemp` so the reffile it returns is immediately made read-only: a real
# `git push` then drives the dispatcher's real stdin-piping shape (the same
# reason CR2 push-block above uses a real push rather than a hand-invocation),
# and the truncated-write `cat >` genuinely fails. RED against the pre-fix
# dispatcher = the push proceeds (validating an empty/truncated ref list)
# instead of aborting with the named capture-failure message.
crtargetG2="$work/cr2814g2-captured-fail"; crbinG2="$work/cr2814g2-bin"
crremoteG2="$work/cr2814g2-remote.git"
mkdir -p "$crtargetG2" "$crbinG2"
HOME="$pchome" git init -q --bare "$crremoteG2"
HOME="$pchome" git -C "$crtargetG2" init -q
HOME="$pchome" git -C "$crtargetG2" checkout -q -b feat/native-test
set +e
out=$(PATH="$crbinG2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtargetG2" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2814 gap2 capture-checked: adopt exited $rc: $out"

real_mktemp_g2=$(command -v mktemp) || fail "HIMMEL-2814 gap2 capture-checked: no system mktemp on PATH to wrap"
cat > "$crbinG2/mktemp" <<MKTEMPSHIM
#!/usr/bin/env bash
f=\$("$real_mktemp_g2" "\$@") || exit 1
chmod 0444 "\$f"
printf '%s\n' "\$f"
MKTEMPSHIM
chmod +x "$crbinG2/mktemp"

# confirm chmod 0444 actually blocks writes for the current user
# before relying on it below to force the capture failure -- as root (or on a
# filesystem where mode bits don't gate writes) this is a silent no-op and the
# suite would then fail because the push simply succeeded, not because the
# gate misbehaved. Same "fixture requires an unprivileged user" convention as
# The unwritable-hooks-dir case above.
probe_g2=$("$crbinG2/mktemp")
if : > "$probe_g2" 2>/dev/null; then
  fail "HIMMEL-2814 gap2 capture-checked: fixture requires an unprivileged user (chmod 0444 did not block a write to $probe_g2)"
fi

HOME="$pchome" git -C "$crtargetG2" config user.name 'Native Test'
HOME="$pchome" git -C "$crtargetG2" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crtargetG2" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap2 capture-checked probe commit'
HOME="$pchome" git -C "$crtargetG2" remote add origin "$crremoteG2"
set +e
poutG2=$(PATH="$crbinG2:$PATH" HOME="$pchome" git -C "$crtargetG2" push origin feat/native-test:refs/heads/cr2814g2-ok 2>&1); prcG2=$?
set -e
[ "$prcG2" -ne 0 ] \
  || fail "HIMMEL-2814 gap2 capture-checked: push landed even though the ref-list capture into a read-only reffile should have failed: $poutG2"
grepq "$poutG2" 'failed to capture the pushed ref list' \
  || fail "HIMMEL-2814 gap2 capture-checked: push was refused but not with the named stdin-capture-failure message: $poutG2"
! HOME="$pchome" git -C "$crremoteG2" rev-parse --verify refs/heads/cr2814g2-ok >/dev/null 2>&1 \
  || fail "HIMMEL-2814 gap2 capture-checked: remote received the ref even though capture failed"
echo "ok: HIMMEL-2814 gap2 capture-checked: a failed stdin-ref-list capture aborts the pre-push dispatcher instead of validating a truncated ref list"

echo "PASS"
