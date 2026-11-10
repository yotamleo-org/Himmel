#!/usr/bin/env bash
# test-adopt-hooks-chain.sh — the chained-hook and pre-commit fallback scenarios.
# The adopt.sh smoke tests live in several suites so
# each stays well under the runner's per-suite time cap. Same fixture
# (scripts/lib/adopt-test-fixture.sh): stubs `claude` on PATH, throwaway temp
# dirs, a fake HOME.
#
# Covers the chained backup hooks (fail, pass, push-block) and the pre-commit
# fallbacks (--skip-hooks, non-git target, --dry-run, failing install, uv
# bootstrap), split from scripts/test-adopt-features.sh.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# A pre-existing foreign hook is backed up
# to <hook>.himmel-backup but the generated dispatcher never ran it again, so
# the adopter's own gate was silently disabled. This is the control that
# matters -- it proves enforcement was preserved, not merely that a file was
# kept: a presence-only assertion on .himmel-backup would pass today while
# the check is dead.
crtarget7="$work/cr2771r2-chain-fails"; crbin7="$work/cr2771r2-chain-fails-bin"
mkdir -p "$crtarget7" "$crbin7"
HOME="$pchome" git -C "$crtarget7" init -q
mkdir -p "$crtarget7/.git/hooks"
HOME="$pchome" git -C "$crtarget7" checkout -q -b feat/native-test
cat > "$crtarget7/.git/hooks/commit-msg" <<'FOREIGNHOOK'
#!/usr/bin/env bash
echo "ADOPTER HOOK REFUSES EVERYTHING" >&2
exit 1
FOREIGNHOOK
chmod +x "$crtarget7/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin7:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget7" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-fails: adopt exited $rc: $out"
[ -f "$crtarget7/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR2 chain-fails: backup absent"
HOME="$pchome" git -C "$crtarget7" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget7" config user.email 'native@example.invalid'
set +e
cout=$(HOME="$pchome" git -C "$crtarget7" -c commit.gpgsign=false commit --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] chained backup fails' 2>&1); crc=$?
set -e
[ "$crc" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 chain-fails: an otherwise-valid ticketed commit LANDED even though the adopter's backed-up hook refuses everything"
! git -C "$crtarget7" rev-parse --verify HEAD >/dev/null 2>&1 \
  || fail "HIMMEL-2771 CR2 chain-fails: refused commit created HEAD"
echo "ok: HIMMEL-2771 CR2 chain-fails: a chained backup hook can still fail the operation"

# The flip side of chain-fails -- a chained backup
# hook that PASSES must not break the himmel gate itself (no double-negative,
# no rc-mangling that turns a real himmel-gate refusal into a pass).
crtarget8="$work/cr2771r2-chain-passes"; crbin8="$work/cr2771r2-chain-passes-bin"
mkdir -p "$crtarget8" "$crbin8"
HOME="$pchome" git -C "$crtarget8" init -q
mkdir -p "$crtarget8/.git/hooks"
HOME="$pchome" git -C "$crtarget8" checkout -q -b feat/native-test
cat > "$crtarget8/.git/hooks/commit-msg" <<FOREIGNHOOK2
#!/usr/bin/env bash
echo ran >> "$crtarget8/adopter-hook-ran"
exit 0
FOREIGNHOOK2
chmod +x "$crtarget8/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin8:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget8" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-passes: adopt exited $rc: $out"
[ -f "$crtarget8/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR2 chain-passes: backup absent"
HOME="$pchome" git -C "$crtarget8" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget8" config user.email 'native@example.invalid'
set +e
cout=$(HOME="$pchome" git -C "$crtarget8" -c commit.gpgsign=false commit --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] chained backup passes' 2>&1); crc=$?
set -e
[ "$crc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-passes: ticketed commit refused even though both gates pass: $cout"
git -C "$crtarget8" rev-parse --verify HEAD >/dev/null \
  || fail "HIMMEL-2771 CR2 chain-passes: ticketed commit did not create HEAD"
[ -f "$crtarget8/adopter-hook-ran" ] \
  || fail "HIMMEL-2771 CR2 chain-passes: adopter's backed-up hook never ran"
set +e
cout2=$(HOME="$pchome" git -C "$crtarget8" -c commit.gpgsign=false commit --allow-empty \
  -m 'no ticket here at all' 2>&1); crc2=$?
set -e
[ "$crc2" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 chain-passes: unticketed commit landed -- himmel gate was masked by the passing backup hook: $cout2"
echo "ok: HIMMEL-2771 CR2 chain-passes: a passing chained backup hook does not break the himmel gate"

# git feeds pre-push its ref list on
# STDIN, and running the himmel gate (which drains stdin -- see
# check-push-target.sh's own header) before the backup left the backup
# reading an already-drained, EOF stdin. A backed-up hook whose refusal
# depends on the ref stream (the realistic shape -- check-push-target.sh
# itself decides this way) would then see zero ref lines and fall through to
# exit 0 regardless of what it should have refused. presence/rc-only checks
# on the hook file do not catch this (a probe against the pre-fix payload
# showed exactly that fallthrough); only a REAL `git push` supplies git's own
# ref-stream protocol, so this control drives one against a real remote.
crtarget9="$work/cr2771r2-push-block"; crbin9="$work/cr2771r2-push-block-bin"
crremote9="$work/cr2771r2-push-block-remote.git"
mkdir -p "$crtarget9" "$crbin9"
HOME="$pchome" git init -q --bare "$crremote9"
HOME="$pchome" git -C "$crtarget9" init -q
mkdir -p "$crtarget9/.git/hooks"
HOME="$pchome" git -C "$crtarget9" checkout -q -b feat/native-test
out=$(PATH="$crbin9:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget9" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 push-block: adopt exited $rc: $out"
[ -x "$crtarget9/.git/hooks/pre-push" ] \
  || fail "HIMMEL-2771 CR2 push-block: no native pre-push hook was installed"
# No pre-existing pre-push hook here for adopt to back up (that mechanic is
# already covered by chain-fails/chain-passes above) -- plant the "adopter's
# own hook" directly as .himmel-backup, the exact file the dispatcher chains
# to. It refuses a push whose DESTINATION ref is refs/heads/protected, a
# decision that requires actually reading the ref stream, so a drained stdin
# is indistinguishable from "nothing pushed" and the hook would wrongly allow
# it -- unlike a stub that always/never refuses regardless of stdin content.
cat > "$crtarget9/.git/hooks/pre-push.himmel-backup" <<'FOREIGNPUSHHOOK'
#!/usr/bin/env bash
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/protected)
      echo "ADOPTER PRE-PUSH HOOK REFUSES protected" >&2
      exit 1
      ;;
  esac
done
exit 0
FOREIGNPUSHHOOK
chmod +x "$crtarget9/.git/hooks/pre-push.himmel-backup"
HOME="$pchome" git -C "$crtarget9" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget9" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crtarget9" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] push-block probe commit'
HOME="$pchome" git -C "$crtarget9" remote add origin "$crremote9"
set +e
pout=$(HOME="$pchome" git -C "$crtarget9" push origin feat/native-test:refs/heads/protected 2>&1); prc=$?
set -e
[ "$prc" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 push-block: a REAL git push landed even though the chained backup hook refuses this ref (drained-stdin regression): $pout"
grepq "$pout" 'ADOPTER PRE-PUSH HOOK REFUSES protected' \
  || fail "HIMMEL-2771 CR2 push-block: push was refused but not by the adopter's chained backup hook: $pout"
! HOME="$pchome" git -C "$crremote9" rev-parse --verify refs/heads/protected >/dev/null 2>&1 \
  || fail "HIMMEL-2771 CR2 push-block: remote has refs/heads/protected even though the push was refused"
echo "ok: HIMMEL-2771 CR2 push-block: a chained pre-push backup hook blocks a real git push"

# --skip-hooks: pre-commit is never invoked.
: > "$work/pre-commit.argv"
pctarget19b2="$work/pctarget19b2"; mkdir -p "$pctarget19b2"
( cd "$pctarget19b2" && HOME="$pchome" git init -q )
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b2" --skip-hooks 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 --skip-hooks: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 --skip-hooks: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks: skipped (--skip-hooks)' \
  || fail "HIMMEL-2441 --skip-hooks: missing the skip message (got: $out)"
echo "ok: HIMMEL-2441 --skip-hooks opts out, pre-commit never invoked"

# non-git target: no .git in $TARGET -> skip, pre-commit never invoked.
: > "$work/pre-commit.argv"
pctarget19b3="$work/pctarget19b3"; mkdir -p "$pctarget19b3"
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b3" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 non-git target: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 non-git target: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks: skipping (' \
  || fail "HIMMEL-2441 non-git target: missing the non-git skip message (got: $out)"
echo "ok: HIMMEL-2441 non-git \$TARGET skips git-hooks install, pre-commit never invoked"

# --dry-run: prints the DRY line, pre-commit never invoked.
: > "$work/pre-commit.argv"
pctarget19b4="$work/pctarget19b4"; mkdir -p "$pctarget19b4"
( cd "$pctarget19b4" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b4/.pre-commit-config.yaml"
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b4" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 --dry-run: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 --dry-run: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" "DRY: (cd $pctarget19b4 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441 --dry-run: missing the DRY git-hooks line (got: $out)"
echo "ok: HIMMEL-2441 --dry-run prints the git-hooks DRY line, pre-commit never invoked"

# framework hook installation failure falls back to native gates.
cat > "$pcbin/pre-commit" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$work/pre-commit.argv"
exit 1
STUB
chmod +x "$pcbin/pre-commit"
: > "$work/pre-commit.argv"
pctarget19b5="$work/pctarget19b5"; mkdir -p "$pctarget19b5"
( cd "$pctarget19b5" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b5/.pre-commit-config.yaml"
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b5" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 install-fails: adopt must exit 0 (WARN-not-fail), got rc=$rc: $out"
grepq "$out" 'WARNING: git hook install failed' \
  || fail "HIMMEL-2441 install-fails: missing the WARNING message (got: $out)"
grepq "$out" "git gate hooks — placed (native, no pre-commit framework: lint hooks absent)" \
  || fail "HIMMEL-2771 install-fails: native fallback absent"
echo "ok: HIMMEL-2771 failing pre-commit install falls back to native gates (rc=0)"

# A real `uv tool install pre-commit`
# can succeed while its bin dir isn't on PATH yet -- prove adopt.sh resolves
# the bootstrapped binary to an absolute path instead of trusting a bare
# `pre-commit` call that would silently miss it. No real pre-commit anywhere
# on PATH (pc_free_path additionally scrubs any dir carrying one, on top of
# the suite-wide qmd/bun/npm/node/uv/pipx scrub); a stubbed `uv` on PATH
# answers `tool install pre-commit --quiet` by writing an argv-logging
# `pre-commit` into $HOME/.local/bin — the UV_TOOL_BIN_DIR default — which is
# deliberately NOT added to PATH, so `command -v pre-commit` still fails
# after the "install" and adopt.sh must fall back to the candidate bin dir.
pc_free_path=$(scrub_path "$qmd_free_path" pre-commit)
uvbin="$work/uvbin"; mkdir -p "$uvbin"
cat > "$uvbin/uv" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "tool" ] && [ "$2" = "install" ] && [ "$3" = "pre-commit" ]; then
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/pre-commit" <<'INNER'
#!/usr/bin/env bash
echo "$*" >> "$HOME/pre-commit-2483.argv"
exit 0
INNER
  chmod +x "$HOME/.local/bin/pre-commit"
  exit 0
fi
exit 1
STUB
chmod +x "$uvbin/uv"
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
pctarget19b6="$work/pctarget19b6"; mkdir -p "$pctarget19b6"
( cd "$pctarget19b6" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b6/.pre-commit-config.yaml"
set +e
out=$(PATH="$uvbin:$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b6" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 PATH-less bootstrap: adopt should exit 0 (got $rc): $out"
[ -f "$pchome/pre-commit-2483.argv" ] \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: bootstrapped pre-commit in \$HOME/.local/bin was never invoked (got: $out)"
grepq "$(cat "$pchome/pre-commit-2483.argv")" \
  'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: pre-commit install was not invoked with all 3 hook types (argv: $(cat "$pchome/pre-commit-2483.argv"))"
grepq "$out" 'git hooks installed (pre-commit, commit-msg, pre-push).' \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: missing the git-hooks-installed message (got: $out)"
echo "ok: HIMMEL-2441/2483 a PATH-less uv bootstrap still resolves pre-commit to an absolute path"

# Clean up the PATH-less-bootstrap fixture so it cannot affect any later
# scenario — none of this is on the ambient exported PATH.
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
rmdir "$pchome/.local/bin" "$pchome/.local" 2>/dev/null || true

# --dry-run must describe the
# planned pre-commit install regardless of host state. No real pre-commit
# anywhere (reuses $uvbin/$pc_free_path from the row above) and a uv stub
# present -- in --dry-run the bootstrap's own `run uv tool install ...` never
# actually executes the stub (it just prints its DRY: line), so resolution
# afterward necessarily finds nothing real either. adopt.sh must still print
# the planned `pre-commit install` DRY: line (literal name) instead of
# WARNing and going silent -- the plan is what matters in dry-run, not
# whether the plan's binary actually exists yet.
pctarget19b7="$work/pctarget19b7"; mkdir -p "$pctarget19b7"
( cd "$pctarget19b7" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b7/.pre-commit-config.yaml"
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
set +e
out=$(PATH="$uvbin:$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b7" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 --dry-run PATH-less: adopt should exit 0 (got $rc): $out"
[ ! -f "$pchome/pre-commit-2483.argv" ] \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: pre-commit stub was invoked during --dry-run (argv: $(cat "$pchome/pre-commit-2483.argv"))"
grepq "$out" 'DRY: uv tool install pre-commit' \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: missing the uv bootstrap DRY line (got: $out)"
grepq "$out" "DRY: (cd $pctarget19b7 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: missing the planned pre-commit install DRY line (got: $out)"
echo "ok: HIMMEL-2441/2483 --dry-run describes the planned pre-commit install even when resolution finds nothing"

rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
rmdir "$pchome/.local/bin" "$pchome/.local" 2>/dev/null || true

# no installer can run in dry-run; describe both framework
# bootstrap and the native fallback without writing any hooks.
pctarget19b8="$work/pctarget19b8"; mkdir -p "$pctarget19b8"
( cd "$pctarget19b8" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b8/.pre-commit-config.yaml"
set +e
out=$(PATH="$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b8" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: adopt should exit 0 (got $rc): $out"
grepq "$out" "DRY: place executable native commit-msg, pre-commit, pre-push hooks" \
  || fail "HIMMEL-2771 --dry-run: missing native placement plan (got: $out)"
[ ! -e "$pctarget19b8/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 --dry-run: wrote native hook"
grepq "$out" "DRY: (cd $pctarget19b8 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: missing the planned pre-commit install DRY line (got: $out)"
echo "ok: HIMMEL-2771 --dry-run prints framework and native plans without placing hooks"

# Remove the stub so it cannot affect any later scenario in this file — $pcbin
# was only ever added to PATH via a per-invocation prefix above (never
# exported), so this is belt-and-braces, not load-bearing.
rm -f "$pcbin/pre-commit"

echo "PASS"
