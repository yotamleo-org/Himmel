#!/usr/bin/env bash
# test-adopt.sh — smoke tests for scripts/adopt.sh (the one-click harness
# installer). Self-contained: stubs `claude` on PATH so the plugin-install
# step doesn't hit the network, and uses throwaway temp dirs + a fake HOME so
# nothing touches the real ~/.claude.
#
# adopt.ps1 carries the same profile/scope logic for PowerShell — that twin is
# NOT covered here; keep both in lockstep when changing either.
#
# Covers:
#   1. core/project — copies the portable files, wires 4 PreToolUse hooks
#      ($CLAUDE_PROJECT_DIR prefix), idempotent on re-run.
#   2. merge — pre-existing settings.json keys + hooks are preserved.
#   3. core/user — wires ~/.claude/settings.json to the himmel abs path,
#      copies NO scripts into a repo.
#   4. luna — copies the vault scaffold to the target.
#   5. invalid --profile / --scope exit 2.
#
# The native git-gate placement scenarios, the provenance ledger and the wizard
# suites live in scripts/test-adopt-features.sh (split off for the per-suite
# time cap); both source scripts/lib/adopt-test-fixture.sh.

# shellcheck disable=SC2154,SC2034 # the fixture, sourced below, assigns and reads the shared state
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# ── self-test: co-located essential + scrubbed tool ──────────────
# Reproduce the stock-Ubuntu regression shape synthetically: a single dir
# carrying BOTH a scrubbed tool (npm) and an essential one (sed) must be
# dropped wholesale by scrub_path, and sed must still resolve afterward — via
# the hermetic stub dir ($work/bin), not via the dropped co-located dir.
coloc="$work/coloc"; mkdir -p "$coloc"
printf '#!/usr/bin/env bash\nexit 0\n' > "$coloc/npm"; chmod +x "$coloc/npm"
printf '#!/usr/bin/env bash\nexit 0\n' > "$coloc/sed"; chmod +x "$coloc/sed"
synthetic_scrubbed=$(scrub_path "$coloc:$work/bin" qmd bun npm node uv pipx)
case ":$synthetic_scrubbed:" in
  *":$coloc:"*) fail "self-test: co-located dir with npm+sed was not scrubbed" ;;
esac
[ "$(PATH="$work/bin:$synthetic_scrubbed" command -v sed)" = "$work/bin/sed" ] \
  || fail "self-test: sed did not resolve via the hermetic stub dir after scrub"
echo "ok: self-test reproduces HIMMEL-874 (co-located npm+sed dir scrubbed, sed still resolves via stub dir)"

# ── 5. invalid args (run first — validated before any tool preflight) ────────
set +e
out=$(bash "$adopt" --profile bogus --scope project 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --profile should exit 2 (got $rc)"
grepq "$out" "invalid --profile" || fail "missing invalid-profile diagnostic"
set +e
out=$(bash "$adopt" --profile core --scope bogus 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --scope should exit 2 (got $rc)"
echo "ok: invalid --profile / --scope rejected (exit 2)"

# ── 1. core/project ──────────────────────────────────────────────────────────
# Fake HOME on every non-user-scope run too (belt-and-braces with the PATH
# scrub): nothing in the suite may read or write the real ~/.claude.
proj="$work/proj"; mkdir -p "$proj"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
for f in scripts/hooks/block-edit-on-main.sh scripts/guardrails/lib.sh scripts/worktree.sh; do
  [ -f "$proj/$f" ] || fail "core/project did not copy $f"
done
# check-commit-msg.sh sources the resolver; a target without it fails closed.
[ -f "$proj/scripts/lib/project-mode.sh" ] || fail "core/project did not copy scripts/lib/project-mode.sh"
s="$proj/.claude/settings.json"
[ -f "$s" ] || fail "core/project did not write $s"
[ "$(jq '.hooks.PreToolUse | length' "$s")" = "4" ] || fail "expected 4 PreToolUse hooks"
jq -e '.hooks.PreToolUse[].hooks[].command | select(contains("$CLAUDE_PROJECT_DIR"))' "$s" >/dev/null \
  || fail "project-scope hooks must use \$CLAUDE_PROJECT_DIR"
echo "ok: core/project copies portable files + wires 4 \$CLAUDE_PROJECT_DIR hooks"

# idempotency
cp "$s" "$work/before.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
diff -q "$work/before.json" "$s" >/dev/null || fail "core/project not idempotent"
echo "ok: core/project idempotent on re-run"

# ── 1b2. project scope wires the initiative SessionStart hook ───
# `himmelctl config set initiative.<step> on` writes the himmel clone's .env,
# which only the inject-initiative hook reads -- a project-scope install that
# never wired the hook silently ignored the setting.
ss_cmd=$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(contains("inject-initiative"))] | .[0] // empty' "$s")
[ -n "$ss_cmd" ] || fail "HIMMEL-6956: core/project did not wire the inject-initiative SessionStart hook"
mkdir -p "$work/ss-clone"
printf 'HIMMEL_INITIATIVE=pr\n' > "$work/ss-clone/.env"
ss_out=$(cd "$proj" && unset HIMMEL_INITIATIVE HIMMEL_AFK HIMMEL_INITIATIVE_AFK HIMMEL_OVERNIGHT HIMMEL_INITIATIVE_OVERNIGHT && HIMMEL_REPO="$work/ss-clone" bash -c "$ss_cmd" </dev/null)
grepq "$ss_out" 'Active steps: pr' \
  || fail "HIMMEL-6956: the project-scope SessionStart hook did not name the active step (got: $ss_out)"
ss_idle=$(cd "$proj" && unset HIMMEL_INITIATIVE HIMMEL_AFK HIMMEL_INITIATIVE_AFK HIMMEL_OVERNIGHT HIMMEL_INITIATIVE_OVERNIGHT && HIMMEL_REPO="$work/no-such-clone" bash -c "$ss_cmd" </dev/null)
[ -z "$ss_idle" ] || fail "HIMMEL-6956: the project-scope SessionStart hook injected with no step set: $ss_idle"
[ "$(jq '[.hooks.SessionStart[]?.hooks[]?.command | select(contains("inject-initiative"))] | length' "$s")" = "1" ] \
  || fail "HIMMEL-6956: idempotent re-run left more than one inject-initiative hook"
echo "ok: HIMMEL-6956 core/project wires inject-initiative; a set step reaches the session, an unset one injects nothing"

# ── 1c. --scope project must not write home rule files ─────────
# wire_user_claude_md's two do_core() calls (~/.claude/CLAUDE.md, ~/.codex/
# AGENTS.md) were unconditional in BOTH scopes -- the flag's name promises
# project-only writes. $base_home already ran two project-scope installs
# above with no --scope user in between, so any presence here is the bug.
if [ -e "$base_home/.claude/CLAUDE.md" ]; then
  fail "HIMMEL-3309: --scope project wrote $base_home/.claude/CLAUDE.md"
fi
if [ -e "$base_home/.codex/AGENTS.md" ]; then
  fail "HIMMEL-3309: --scope project wrote $base_home/.codex/AGENTS.md"
fi
echo "ok: core/project does not write ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md (HIMMEL-3309)"

# ── 1c2. the adopted commit gate honours the project's .env ─────────────────
# check-commit-msg.sh sources scripts/lib/load-dotenv.sh to read
# TICKET_ID_REQUIRED from the project .env; a target without that lib silently
# ignores the documented opt-out and refuses every commit.
printf 'chore: add himmel\n' > "$work/msg-noticket.txt"
gate_noticket() {  # run the adopted gate on a ticket-less message, rule vars scrubbed from the env
  (cd "$proj" && export HOME="$base_home" \
    && unset TICKET_ID_REQUIRED TICKET_ID_PATTERN TICKET_ID_EXEMPT_AUTHORS JIRA_PROJECT_KEY TRACKER \
    && bash scripts/hooks/check-commit-msg.sh "$work/msg-noticket.txt" >/dev/null 2>&1)
}
set +e
gate_noticket; rc_no_env=$?
printf 'TICKET_ID_REQUIRED=0\n' > "$proj/.env"
gate_noticket; rc_env=$?
rm -f "$proj/.env"
set -e
[ "$rc_no_env" -ne 0 ] || fail "HIMMEL-6327: control: a ticket-less message passed with no opt-out"
[ "$rc_env" -eq 0 ] || fail "HIMMEL-6327: TICKET_ID_REQUIRED=0 in the adopter project's .env did not reach the commit gate (rc=$rc_env)"
echo "ok: adopted commit gate reads TICKET_ID_REQUIRED=0 from the project .env (HIMMEL-6327)"

# ── 1d. trial path: no-origin repo on main ──────────────────────────────────
# Install, commit the install on main (the one allowed commit), then cut a
# worktree with no origin: it must carry scripts/ and .claude/worktrees/ must
# be ignored.
tp="$work/trial-path"; mkdir -p "$tp"
git -C "$tp" init -q -b main
git -C "$tp" config user.email t@t; git -C "$tp" config user.name t
git -C "$tp" config commit.gpgsign false
git -C "$tp" commit -q --allow-empty -m "chore: initial commit"
out_tp=$(HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tp" 2>&1)
[ "$(git -C "$tp" status --porcelain -- scripts | wc -l)" -gt 0 ] || fail "HIMMEL-6326: install without --commit-install must stay uncommitted"
grep -qx '.claude/worktrees/' "$tp/.gitignore" || fail "HIMMEL-6326: adopt did not add .claude/worktrees/ to .gitignore"
printed_tp=$(sed -n 's/^.*Commit it once with: //p' <<< "$out_tp")
[ -n "$printed_tp" ] || fail "HIMMEL-6852: install on main printed no 'Commit it once with:' line: $out_tp"
eval "printed_argv=($printed_tp)"
case "${printed_argv[1]:-}" in /*) ;; *) fail "HIMMEL-6852: the printed adopt.sh path must be absolute (got: $printed_tp)" ;; esac
head_before=$(git -C "$tp" rev-parse HEAD)
( cd "$tp" && HOME="$base_home" "${printed_argv[@]}" >/dev/null 2>&1 ) || fail "HIMMEL-6852: the printed line failed from the project cwd: $printed_tp"
[ "$(git -C "$tp" rev-parse HEAD)" != "$head_before" ] || fail "HIMMEL-6852: the printed line created no commit"
git -C "$tp" show --name-only --format= HEAD | grep -q '^scripts/' || fail "HIMMEL-6852: the printed line's commit does not hold the installed scripts/"
[ "$(git -C "$tp" status --porcelain -- scripts .gitignore .claude/settings.json | wc -l)" -eq 0 ] || fail "HIMMEL-6852: the printed line left the install uncommitted"
echo "ok: the printed --commit-install line runs from the project cwd (HIMMEL-6852)"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tp" --commit-install >/dev/null
[ "$(git -C "$tp" status --porcelain -- scripts .gitignore .claude/settings.json | wc -l)" -eq 0 ] || fail "HIMMEL-6326: --commit-install left the install uncommitted"
[ "$(grep -c -x '.claude/worktrees/' "$tp/.gitignore")" = "1" ] || fail "HIMMEL-6326: .gitignore rule duplicated on re-run"
[ "$(git -C "$tp" remote | wc -l)" -eq 0 ] || fail "HIMMEL-6326: fixture must have no remote"
(cd "$tp" && HOME="$base_home" bash scripts/worktree.sh feat/try-himmel >/dev/null 2>&1) || fail "HIMMEL-6326: worktree.sh failed in a project with no origin"
[ -f "$tp/.claude/worktrees/feat+try-himmel/scripts/worktree.sh" ] || fail "HIMMEL-6326: worktree cut after install lacks scripts/"
[ "$(git -C "$tp" status --porcelain | wc -l)" -eq 0 ] || fail "HIMMEL-6326: worktree dir shows up as untracked"
echo "ok: HIMMEL-6326 no-origin worktree, committable install, .claude/worktrees/ ignored"

# A user's own uncommitted .gitignore edit must not ride into the install commit.
te="$work/trial-edited"; mkdir -p "$te"
git -C "$te" init -q -b main
git -C "$te" config user.email t@t; git -C "$te" config user.name t
git -C "$te" config commit.gpgsign false
printf 'node_modules/\n' > "$te/.gitignore"
git -C "$te" add .gitignore
git -C "$te" commit -q -m "chore: initial commit"
printf 'my-private-notes/\n' >> "$te/.gitignore"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$te" --commit-install >/dev/null
[ "$(git -C "$te" log --oneline | wc -l)" -eq 1 ] || fail "HIMMEL-6326: install commit swept in a user's uncommitted .gitignore edit"
echo "ok: HIMMEL-6326 pre-edited .gitignore blocks the auto-commit"

# Same with an install already pending: an edit made after the declined run
# must still stop --commit-install.
tq="$work/trial-pending"; mkdir -p "$tq"
git -C "$tq" init -q -b main
git -C "$tq" config user.email t@t; git -C "$tq" config user.name t
git -C "$tq" config commit.gpgsign false
git -C "$tq" commit -q --allow-empty -m "chore: initial commit"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tq" >/dev/null
printf 'my-private-notes/\n' >> "$tq/.gitignore"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tq" --commit-install >/dev/null
[ "$(git -C "$tq" log --oneline | wc -l)" -eq 1 ] || fail "HIMMEL-6326: install commit swept in an edit made after a declined install"
echo "ok: HIMMEL-6326 edit after a declined install blocks the auto-commit"

# A change staged after the declined run still counts when the working tree
# was put back to the recorded content.
tr="$work/trial-staged"; mkdir -p "$tr"
git -C "$tr" init -q -b main
git -C "$tr" config user.email t@t; git -C "$tr" config user.name t
git -C "$tr" config commit.gpgsign false
git -C "$tr" commit -q --allow-empty -m "chore: initial commit"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tr" >/dev/null
cp "$tr/.gitignore" "$work/trial-staged.gitignore"
printf 'my-private-notes/\n' >> "$tr/.gitignore"
git -C "$tr" add .gitignore
cp "$work/trial-staged.gitignore" "$tr/.gitignore"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$tr" --commit-install >/dev/null
[ "$(git -C "$tr" log --oneline | wc -l)" -eq 1 ] || fail "HIMMEL-6326: install commit swept in a staged .gitignore change"
echo "ok: HIMMEL-6326 staged edit after a declined install blocks the auto-commit"

# ── 1b. self-copy guard ─────────────────────────────────────────
# A brand-new adopter clones himmel and runs the installer FROM INSIDE that
# clone (TARGET == HIMMEL_ROOT). do_core() mutates its TARGET, so this can't
# be reproduced by pointing --target at the live checkout ($repo_root) --
# that would mutate this worktree's real .claude/settings.json etc. Instead
# build a standalone, disposable clone (a full copy of this worktree's
# CURRENT tracked-file content, not the committed HEAD blob -- so it carries
# whatever adopt.sh is on disk right now: the original for this red-first
# run, the guarded version once the fix lands) and run its OWN adopt.sh
# against itself.
fakeClone="$work/fake-himmel-clone"; mkdir -p "$fakeClone"
# -P: copy tracked symlinks as symlinks. Without it GNU cp follows a symlink to
# a directory, refuses it without
# -r and exits 1 -- xargs reports that as rc=123.
( cd "$repo_root" && git ls-files -z ) | xargs -0 cp -P --parents -t "$fakeClone"
[ -f "$fakeClone/scripts/adopt.sh" ] || fail "HIMMEL-2435 fixture: scripts/adopt.sh did not land in the fake clone"
[ -L "$fakeClone/scripts/lanes/tests/fixtures/tier-return-configdir/projects" ] \
  || fail "HIMMEL-3201 fixture: the tracked dir-symlink tier-return-configdir/projects must land in the fake clone AS a symlink"

# case A (the important one, red-first): the documented flow -- cd into the
# clone and run `adopt.sh --scope project`, TARGET defaulting to $PWD (the
# clone itself). Before the fix this dies on the self-copy `cp` error on the
# very first portable file.
homeA2435="$work/home-2435a"; mkdir -p "$homeA2435"
set +e
outA2435=$( cd "$fakeClone" && HOME="$homeA2435" bash scripts/adopt.sh --scope project 2>&1 ); rcA2435=$?
set -e
[ "$rcA2435" -eq 0 ] || fail "HIMMEL-2435 case A: the documented adopter flow (adopt.sh --scope project run from inside the clone) should exit 0 (got rc=$rcA2435): $outA2435"
grepq "$outA2435" -i "already in place" \
  || fail "HIMMEL-2435 case A: expected a skip note, not silence or the self-copy cp abort (got: $outA2435)"
grepq "$outA2435" "are the same file" \
  && fail "HIMMEL-2435 case A: must NOT hit the self-copy cp error (got: $outA2435)"
echo "ok: HIMMEL-2435 case A the documented adopter flow (adopt.sh --scope project from inside the clone) completes rc=0 with a skip note, not the self-copy cp abort"

# case B: the by-hand route -- `adopt.sh --scope project --target <the
# clone>`, invoked from elsewhere. Same single guard (inside copy_portable())
# must cover this call shape too, not just the documented one above.
homeB2435="$work/home-2435b"; mkdir -p "$homeB2435"
set +e
outB2435=$(HOME="$homeB2435" bash "$fakeClone/scripts/adopt.sh" --scope project --target "$fakeClone" 2>&1); rcB2435=$?
set -e
[ "$rcB2435" -eq 0 ] || fail "HIMMEL-2435 case B: --target <the clone> (by-hand route) should exit 0 (got rc=$rcB2435): $outB2435"
grepq "$outB2435" -i "already in place" \
  || fail "HIMMEL-2435 case B: expected the skip note on the by-hand --target route too (got: $outB2435)"
echo "ok: HIMMEL-2435 case B the by-hand route (adopt.sh --scope project --target <clone>) hits the same guard"

# negative control (load-bearing): a genuinely DIFFERENT target must still
# get its portable core copied -- a guard that skipped unconditionally (or
# compared paths by content instead of identity) would also pass A and B.
diffTarget2435="$work/diff-target-2435"; mkdir -p "$diffTarget2435"
homeC2435="$work/home-2435c"; mkdir -p "$homeC2435"
set +e
outC2435=$(HOME="$homeC2435" bash "$fakeClone/scripts/adopt.sh" --scope project --target "$diffTarget2435" 2>&1); rcC2435=$?
set -e
[ "$rcC2435" -eq 0 ] || fail "HIMMEL-2435 negative control: a genuinely different --target should still succeed (got rc=$rcC2435): $outC2435"
[ -f "$diffTarget2435/scripts/worktree.sh" ] \
  || fail "HIMMEL-2435 negative control: the guard must not over-skip -- a genuinely different target should still get its portable core copied (missing $diffTarget2435/scripts/worktree.sh)"
grepq "$outC2435" -i "already in place" \
  && fail "HIMMEL-2435 negative control: a genuinely different target should NOT print the self-copy skip note (got: $outC2435)"
echo "ok: HIMMEL-2435 negative control a genuinely different --target still gets its portable core copied (the guard does not over-skip)"

# ── 1e. the adoption page's worktree step must resolve in a
# --scope project install ────────────────────────────────────────────────────
# A starter (--scope project) install ships scripts/worktree.sh + its
# sourced lib/ closure but NO .claude/commands/worktree.md -- there is no
# installed plugin that ships one either -- so the page's step must tell the
# reader to run the SCRIPT, not the `/worktree` slash command (which cannot
# resolve there). Prove it two ways: (a) the page's own text names the
# working command, not the absent slash command, for the starter trail; (b)
# that command, run inside a real starter install, actually creates a
# worktree.
page="$repo_root/docs/adoption-trail.html"
[ -f "$page" ] || fail "HIMMEL-3326: $page not found"
grepq "$(cat "$page")" 'bash scripts/worktree.sh feat/try-himmel' \
  || fail "HIMMEL-3326: adoption-trail.html's starter walkthrough must tell the reader to run bash scripts/worktree.sh (the /worktree slash command does not exist in a --scope project install)"

wtpage_bare="$work/wtpage-origin.git"
git init -q --bare "$wtpage_bare" 2>/dev/null || git init -q --bare "$wtpage_bare"
wtpage="$work/wtpage-repo"; mkdir -p "$wtpage"
git init -q --initial-branch=main "$wtpage" 2>/dev/null || { git init -q "$wtpage"; git -C "$wtpage" symbolic-ref HEAD refs/heads/main || true; }
git -C "$wtpage" config user.email t@test.com
git -C "$wtpage" config user.name t
git -C "$wtpage" config commit.gpgsign false
printf 'base\n' > "$wtpage/README"
git -C "$wtpage" add README
git -C "$wtpage" commit -q -m base
git -C "$wtpage" branch -m main 2>/dev/null || true
git -C "$wtpage" remote add origin "$wtpage_bare"
git -C "$wtpage" push -q origin main
home1e="$work/home-1e"; mkdir -p "$home1e"
HOME="$home1e" bash "$adopt" --profile core --scope project --target "$wtpage" >/dev/null
[ -f "$wtpage/scripts/worktree.sh" ] || fail "HIMMEL-3326: starter install did not land scripts/worktree.sh"
[ -f "$wtpage/.claude/commands/worktree.md" ] && fail "HIMMEL-3326 precondition: a starter install must NOT ship the /worktree slash command (test assumption broken)"
set +e
out1e=$(cd "$wtpage" && bash scripts/worktree.sh feat/try-himmel 2>&1); rc1e=$?
set -e
[ "$rc1e" -eq 0 ] || fail "HIMMEL-3326: the page's documented command (bash scripts/worktree.sh feat/try-himmel) failed in a real starter install (rc=$rc1e): $out1e"
[ -d "$wtpage/.claude/worktrees/feat+try-himmel" ] \
  || fail "HIMMEL-3326: bash scripts/worktree.sh feat/try-himmel did not create .claude/worktrees/feat+try-himmel: $out1e"
echo "ok: HIMMEL-3326 the adoption page's starter-trail worktree step (bash scripts/worktree.sh) resolves and works in a real --scope project install"

# ── 1f. machine-level footprint block ─────────────────
# Printed BEFORE any install step, naming the paths that stay shared/machine-
# level regardless of --scope (qmd models, bun, claude-hud config,
# workspace-trust entry, plugin content cache + ledger).
home1f="$work/home-1f"; mkdir -p "$home1f"
proj1f="$work/proj1f"; mkdir -p "$proj1f"
out1f=$(HOME="$home1f" bash "$adopt" --profile core --scope project --target "$proj1f")
grepq "$out1f" "Machine-level footprint" \
  || fail "HIMMEL-3303 (b): adopt.sh did not print a machine-level footprint block"
grepq "$out1f" "qmd models + search index" \
  || fail "HIMMEL-3303 (b): footprint block missing the qmd models line"
grepq "$out1f" "$home1f/.bun" \
  || fail "HIMMEL-3303 (b): footprint block missing the bun line"
grepq "$out1f" "claude-hud/config.json" \
  || fail "HIMMEL-3303 (b): footprint block missing the claude-hud config line"
grepq "$out1f" "$home1f/.claude.json" \
  || fail "HIMMEL-3303 (b): footprint block missing the workspace-trust entry line"
grepq "$out1f" "plugins/cache" \
  || fail "HIMMEL-3303 (b): footprint block missing the plugin content cache line"
grepq "$out1f" "installed_plugins.json" \
  || fail "HIMMEL-3303 (b): footprint block missing the plugin install ledger"
echo "ok: HIMMEL-3303 (b) --scope project prints the machine-level footprint block before installing"

# F1: himmel's own state dir (ledger, backups of overwritten user files,
# the uninstall bundle) is machine-level too; qmd-fork lives there when bun is present.
grepq "$out1f" "$HIMMEL_PROVENANCE_DIR" \
  || fail "HIMMEL-3303 F1: footprint block does not name the himmel state dir ($HIMMEL_PROVENANCE_DIR)"
grepq "$out1f" "backups" \
  || fail "HIMMEL-3303 F1: footprint block does not say the state dir holds the backups of overwritten files"
grepq "$out1f" "qmd-fork" \
  && fail "HIMMEL-3303 F1: footprint block names qmd-fork although bun is absent"
# F3: a bare adopt.sh never writes ~/.claude.json (applyWorkspaceTrust is himmelctl-only)
grepq "$out1f" "workspace-trust.*himmelctl" \
  || fail "HIMMEL-3303 F3: the workspace-trust line does not say it is himmelctl-only (a bare adopt.sh never writes it)"
bun1f="$work/bun1f"; mkdir -p "$bun1f"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bun1f/bun"; chmod +x "$bun1f/bun"
out1fb=$(PATH="$bun1f:$work/bin:$qmd_free_path" HOME="$home1f" bash "$adopt" --profile core --scope project --target "$proj1f" --dry-run 2>&1)
grepq "$out1fb" "qmd-fork" \
  || fail "HIMMEL-3303 F1: with bun present the footprint block does not name qmd-fork"
echo "ok: HIMMEL-3303 F1/F3 footprint names the himmel state dir (+ qmd-fork with bun) and words the trust line accurately"

# R1: a --scope project marketplace add still clones into the machine-
# wide marketplaces dir and registers in the global known_marketplaces.json.
grepq "$out1f" "plugins/marketplaces" \
  || fail "HIMMEL-3303 R1: footprint block does not name the marketplace clones dir"
grepq "$out1f" "known_marketplaces.json" \
  || fail "HIMMEL-3303 R1: footprint block does not name the global marketplace registry"
echo "ok: HIMMEL-3303 R1 footprint names the marketplace clones dir and the global registry"

# S1: with bun present, a bare adopt registers the clone as a qmd
# collection in the machine-wide qmd config, not just the fork clone dir.
grepq "$out1fb" "qmd/index.yml" \
  || fail "HIMMEL-3303 S1: with bun present the footprint block does not name the qmd collection registry (qmd/index.yml)"
echo "ok: HIMMEL-3303 S1 footprint names the qmd collection registry when bun is present"

# ── 1g. bare adopt.sh leaves a standalone uninstaller ──
# scripts/himmelctl/bin.js's PATH-shim step already writes this bundle
# (bin.js:4847) so `uninstall` survives deleting the clone -- but only inside
# the himmelctl wizard flow. A bare (non-himmelctl) `adopt.sh` run must
# produce the SAME bundle via the SAME writer (standalone-bundle.js), never a
# forked copy.
# node is scrubbed from the suite-wide PATH (line ~248) so the NODE_AVAILABLE=0
# soft-degrade path (no node on the box) is the default everywhere else; this
# one case needs a REAL node to exercise write_standalone_bundle_core's happy
# path, so it gets its own dir prepended to PATH (resolved against the
# pre-scrub $saved_path, same shape as the wizard suites at the bottom of this
# file), rather than the qmd/bun/npm/node-scrubbed base every other case runs on.
nodebin1g="$work/nodebin1g"; mkdir -p "$nodebin1g"
ln -sf "$(PATH="$saved_path" command -v node)" "$nodebin1g/node"
# require_tools' pre-existing npm-less-node hard fail (adopt.sh's node/npm/bun
# preflight, unrelated to this ticket) fires when node is present but neither
# npm nor bun is -- this dev box's real node has no npm. Stub npm here (a
# no-op, same shape as build_jira_cli's npm stub elsewhere in this file) to
# clear that unrelated gate; leave bun genuinely absent so BUN_AVAILABLE stays
# 0 and wire_qmd_core takes its documented clean-skip branch (a bun stub here
# would instead look "real" to it and trigger an actual network qmd install).
printf '#!/usr/bin/env bash\nexit 0\n' > "$nodebin1g/npm"; chmod +x "$nodebin1g/npm"
home1g="$work/home-1g"; mkdir -p "$home1g"
proj1g="$work/proj1g"; mkdir -p "$proj1g"
# HIMMEL_PROVENANCE_DIR is pinned suite-wide to $work/prov (see the top of this
# file) so every adopt.sh call's ledger lands off the real machine -- give this
# one its own subdir so the bundle path below is unambiguous, same as the P4
# provenance tests further down do with $p4led.
prov1g="$work/prov1g"
out1g=$(PATH="$nodebin1g:$work/bin:$qmd_free_path" HOME="$home1g" HIMMEL_PROVENANCE_DIR="$prov1g" bash "$adopt" --profile core --scope project --target "$proj1g")
bundle1g="$prov1g/uninstall/bundle.json"
[ -f "$bundle1g" ] \
  || fail "HIMMEL-3303 (4): a bare adopt.sh run did not write a standalone uninstall bundle ($bundle1g absent)"
[ "$(jq -r '.marker' "$bundle1g")" = "himmel-standalone-uninstaller/1" ] \
  || fail "HIMMEL-3303 (4): $bundle1g has the wrong marker"
[ -f "$prov1g/uninstall/standalone.js" ] \
  || fail "HIMMEL-3303 (4): the bundle is missing standalone.js (the delete-the-clone fallback entry point)"
[ -f "$prov1g/uninstall/scripts/uninstall.sh" ] \
  || fail "HIMMEL-3303 (4): the bundle is missing scripts/uninstall.sh"
grepq "$out1g" "the fallback still works" \
  || fail "HIMMEL-3303 (4): adopt.sh did not print the delete-the-clone fallback line"
grepq "$out1g" "$prov1g/uninstall/standalone.js uninstall" \
  || fail "HIMMEL-3303 (4): the printed fallback command does not point at the standalone bundle"
# F2: the uninstaller is cwd-scoped -- the printed line must say where to run it
grepq "$out1g" "run from the adopted project directory.*$proj1g" \
  || fail "HIMMEL-3303 F2: the printed uninstall line does not say to run it from the adopted project directory ($proj1g)"
echo "ok: HIMMEL-3303 (4) a bare adopt.sh run writes the same standalone uninstall bundle himmelctl's PATH-shim step builds"

# ── 2. merge preserves existing settings ─────────────────────────────────────
proj2="$work/proj2"; mkdir -p "$proj2/.claude"
printf '%s' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /pre/existing.sh"}]}]}}' > "$proj2/.claude/settings.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj2" >/dev/null
[ "$(jq -r '.permissions.allow[0]' "$proj2/.claude/settings.json")" = "Bash(ls)" ] || fail "merge dropped existing permissions"
[ "$(jq '.hooks.PreToolUse | length' "$proj2/.claude/settings.json")" = "5" ] || fail "merge expected 5 PreToolUse hooks (1 existing + 4)"
echo "ok: merge preserves existing keys + hooks"

# ── 3. core/user (fake HOME) ─────────────────────────────────────────────────
home="$work/home"; mkdir -p "$home"
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
us="$home/.claude/settings.json"
[ -f "$us" ] || fail "core/user did not write ~/.claude/settings.json"
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user expected 3 PreToolUse hooks"
us_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$us")
# shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR globs below, not expansions
case "$us_cmd" in
  *'$CLAUDE_PROJECT_DIR'*) fail "user-scope must not use \$CLAUDE_PROJECT_DIR ($us_cmd)" ;;
  */scripts/hooks/*) : ;;  # absolute himmel path
  *) fail "user-scope hook command unexpected: $us_cmd" ;;
esac
[ ! -d "$work/ignored/scripts" ] || fail "core/user must NOT copy scripts into a repo"
echo "ok: core/user wires ~/.claude to himmel abs path, copies no scripts"

# ── 3b. control: --scope user still writes the home rule files ──
# Negative control for 1c: the same wire_user_claude_md calls must still fire
# under --scope user, or a guard that over-skips (e.g. unconditionally
# disabled) would also pass 1c.
MARKER="HIMMEL:working-principles"
[ -f "$home/.claude/CLAUDE.md" ] || fail "HIMMEL-3309 control: --scope user did not write ~/.claude/CLAUDE.md"
grep -q -- "<!-- BEGIN $MARKER -->" "$home/.claude/CLAUDE.md" \
  || fail "HIMMEL-3309 control: ~/.claude/CLAUDE.md missing the working-principles marker"
[ -f "$home/.codex/AGENTS.md" ] || fail "HIMMEL-3309 control: --scope user did not write ~/.codex/AGENTS.md"
grep -q -- "<!-- BEGIN $MARKER -->" "$home/.codex/AGENTS.md" \
  || fail "HIMMEL-3309 control: ~/.codex/AGENTS.md missing the working-principles marker"
echo "ok: core/user still writes ~/.claude/CLAUDE.md + ~/.codex/AGENTS.md (HIMMEL-3309 control)"

# ── 4. luna scaffold ─────────────────────────────────────────────────────────
vault="$work/vault"
HOME="$base_home" bash "$adopt" --profile luna --target "$vault" >/dev/null
[ -f "$vault/README.md" ] || fail "luna profile did not scaffold the vault (README.md missing)"
# F1: project scope wires LUNA_VAULT_PATH into $TARGET/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$vault/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$vault")" ] || fail "luna/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$vault")])"
echo "ok: luna scaffolds the vault + persists LUNA_VAULT_PATH (project scope)"

# luna profile also seeds HANDOVER_DIR at <vault>/handovers so a
# fresh adopter's handover state doesn't silently default to the inline
# <repo-root>/handovers stub.
hd=$(jq -r '.env.HANDOVER_DIR' "$vault/.claude/settings.json" 2>/dev/null)
[ "$hd" = "$(norm "$vault/handovers")" ] || fail "luna/project did not persist HANDOVER_DIR ([$hd] != [$(norm "$vault/handovers")])"
[ -d "$vault/handovers" ] || fail "luna/project did not create <vault>/handovers"
echo "ok: luna scaffolds the vault + persists HANDOVER_DIR (project scope)"

# ── 4b. PRESERVE an existing settings.json HANDOVER_DIR ──
# A routine re-adopt must reproduce state, never silently reset an
# operator-selected root (own settings.json env.HANDOVER_DIR from a prior
# /handover-setup or adopt run).
preserve_vault="$work/preserve-vault"
preserve_target="$work/preserve-target"; mkdir -p "$preserve_target/.claude"
printf '%s' '{"env":{"HANDOVER_DIR":"/some/operator/chosen/handovers"}}' > "$preserve_target/.claude/settings.json"
out=$(HOME="$base_home" bash "$adopt" --profile luna --target "$preserve_target" --luna-target "$preserve_vault" 2>&1)
hd=$(jq -r '.env.HANDOVER_DIR' "$preserve_target/.claude/settings.json" 2>/dev/null)
[ "$hd" = "/some/operator/chosen/handovers" ] || fail "HIMMEL-839 preserve: existing settings.json HANDOVER_DIR was overwritten ([$hd])"
grepq "$out" 'leaving it' || fail "HIMMEL-839 preserve: missing the leaving-it message (got: $out)"
echo "ok: HIMMEL-839 preserves an existing settings.json env.HANDOVER_DIR (re-adopt reproduces, not resets)"

# ── 4c. PRESERVE an existing repo .env HANDOVER_DIR ──
# The other place HANDOVER_DIR can already live: the primary checkout's own
# .env (set-handover-dir.sh / Mode B — what /handover-setup actually writes).
# settings.json env takes PROCESS-ENV precedence over .env, so writing it here
# would silently shadow that choice even with the .env file itself untouched.
if [ -f "$real_env" ]; then
  env_backup="$work/env-backup"
  mv "$real_env" "$env_backup"
fi
printf 'HANDOVER_DIR=/some/dotenv/handovers\n' > "$real_env"
env_mutated=1
preserve_vault2="$work/preserve-vault2"
preserve_target2="$work/preserve-target2"; mkdir -p "$preserve_target2"
out=$(HOME="$base_home" bash "$adopt" --profile luna --target "$preserve_target2" --luna-target "$preserve_vault2" 2>&1)
if [ -n "$env_backup" ]; then mv "$env_backup" "$real_env"; env_backup=""; else rm -f "$real_env"; fi
env_mutated=0
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$preserve_target2/.claude/settings.json" 2>/dev/null)
[ "$hd" = "ABSENT" ] || fail "HIMMEL-839 preserve: .env-configured HANDOVER_DIR was shadowed by a settings.json write ([$hd])"
grepq "$out" 'via /handover-setup' || fail "HIMMEL-839 preserve: missing the .env-preserve message (got: $out)"
echo "ok: HIMMEL-839 preserves an existing repo .env HANDOVER_DIR (does not shadow it via settings.json)"

# ── 4c2. PRESERVE a HANDOVER_DIR in the tracked config file ──
# The behaviour-config layer (~/.himmel/himmel.conf) is where HANDOVER_DIR now
# lives; adopt must not shadow it with a settings.json write either.
confhome="$work/confhome"; mkdir -p "$confhome/.himmel"
printf 'HANDOVER_DIR=/some/conf/handovers\n' > "$confhome/.himmel/himmel.conf"
preserve_vault3="$work/preserve-vault3"
preserve_target3="$work/preserve-target3"; mkdir -p "$preserve_target3"
out=$(HOME="$confhome" bash "$adopt" --profile luna --target "$preserve_target3" --luna-target "$preserve_vault3" 2>&1)
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$preserve_target3/.claude/settings.json" 2>/dev/null)
[ "$hd" = "ABSENT" ] || fail "HIMMEL-7021 preserve: himmel.conf-configured HANDOVER_DIR was shadowed by a settings.json write ([$hd])"
grepq "$out" 'himmel.conf' || fail "HIMMEL-7021 preserve: missing the himmel.conf-preserve message (got: $out)"
echo "ok: HIMMEL-7021 preserves a himmel.conf HANDOVER_DIR (does not shadow it via settings.json)"

# An empty HANDOVER_DIR= reads as unset, so it must not suppress the wiring.
emptyhome="$work/emptyhome"; mkdir -p "$emptyhome/.himmel"
printf 'HANDOVER_DIR=\n' > "$emptyhome/.himmel/himmel.conf"
empty_vault="$work/empty-vault"
empty_target="$work/empty-target"; mkdir -p "$empty_target"
HOME="$emptyhome" bash "$adopt" --profile luna --target "$empty_target" --luna-target "$empty_vault" >/dev/null 2>&1
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$empty_target/.claude/settings.json" 2>/dev/null)
[ -n "$hd" ] && [ "$hd" != "ABSENT" ] || fail "HIMMEL-7021 empty: an empty HANDOVER_DIR= in himmel.conf suppressed the settings.json wiring"
echo "ok: HIMMEL-7021 an empty himmel.conf HANDOVER_DIR= does not count as configured"

# A quoted-empty value parses empty too.
qhome="$work/qhome"; mkdir -p "$qhome/.himmel"
printf 'HANDOVER_DIR=""\n' > "$qhome/.himmel/himmel.conf"
q_vault="$work/q-vault"
q_target="$work/q-target"; mkdir -p "$q_target"
HOME="$qhome" bash "$adopt" --profile luna --target "$q_target" --luna-target "$q_vault" >/dev/null 2>&1
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$q_target/.claude/settings.json" 2>/dev/null)
[ -n "$hd" ] && [ "$hd" != "ABSENT" ] || fail "HIMMEL-7021 quoted-empty: HANDOVER_DIR=\"\" in himmel.conf suppressed the settings.json wiring"
echo "ok: HIMMEL-7021 a quoted-empty himmel.conf HANDOVER_DIR does not count as configured"

# ── 4d. canonicalize a relative --luna-target ────────
# A relative --luna-target must not persist a CWD-dependent relative path.
relhome="$work/relhome"; mkdir -p "$relhome"
relbase="$work/relbase"; mkdir -p "$relbase"
( cd "$relbase" && HOME="$relhome" bash "$adopt" --profile luna --luna-target "rel-vault" >/dev/null )
relsettings="$relbase/.claude/settings.json"
hd=$(jq -r '.env.HANDOVER_DIR' "$relsettings" 2>/dev/null)
expected_rel="$(norm "$relbase/rel-vault/handovers")"
[ "$hd" = "$expected_rel" ] || fail "HIMMEL-839 canonicalize: relative --luna-target persisted a wrong/non-canonical HANDOVER_DIR ([$hd] != [$expected_rel])"
case "$hd" in /*|[A-Za-z]:/*) : ;; *) fail "HIMMEL-839 canonicalize: HANDOVER_DIR is not absolute: $hd" ;; esac
echo "ok: HIMMEL-839 canonicalizes a relative --luna-target to an absolute HANDOVER_DIR"

# ── 4e. handover.mode=inline must NOT wire HANDOVER_DIR ────────
# Default (no --handover-mode) preserves today's behaviour (cases
# 4/4b/4c/4d above); --handover-mode inline is the new no-op path.
inline_vault="$work/inline-vault"
inline_target="$work/inline-target"; mkdir -p "$inline_target"
HOME="$base_home" bash "$adopt" --profile luna --target "$inline_target" --luna-target "$inline_vault" --handover-mode inline >/dev/null
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$inline_target/.claude/settings.json" 2>/dev/null)
[ "$hd" = "ABSENT" ] || fail "HIMMEL-2466: handover.mode=inline still wired env.HANDOVER_DIR ([$hd])"
[ -d "$inline_vault/handovers" ] && fail "HIMMEL-2466: handover.mode=inline must not create <vault>/handovers"
echo "ok: HIMMEL-2466 handover.mode=inline leaves settings.json without env.HANDOVER_DIR"

# ── 4f. control: --handover-mode external is still today's behaviour ──
external_vault="$work/external-vault"
external_target="$work/external-target"; mkdir -p "$external_target"
HOME="$base_home" bash "$adopt" --profile luna --target "$external_target" --luna-target "$external_vault" --handover-mode external >/dev/null
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$external_target/.claude/settings.json" 2>/dev/null)
[ "$hd" = "$(norm "$external_vault/handovers")" ] || fail "HIMMEL-2466 control: --handover-mode external did not persist HANDOVER_DIR ([$hd])"
echo "ok: HIMMEL-2466 control: --handover-mode external still wires HANDOVER_DIR"

# ── 6. all — core→--target, vault→--luna-target (no leak) ────────────────────
allrepo="$work/allrepo"; allvault="$work/allvault"; mkdir -p "$allrepo"
HOME="$base_home" bash "$adopt" --profile all --scope project --target "$allrepo" --luna-target "$allvault" >/dev/null
[ -f "$allrepo/scripts/worktree.sh" ] || fail "all: core did not land in --target"
[ -f "$allvault/README.md" ] || fail "all: vault did not land in --luna-target"
[ ! -f "$allrepo/README.md" ] || fail "all: vault scaffold leaked into the core --target"
# F1: project scope wires LUNA_VAULT_PATH=$allvault into $allrepo/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$allrepo/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$allvault")" ] || fail "all/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$allvault")])"
# same for HANDOVER_DIR=$allvault/handovers — this is the exact
# --profile all repro shape from the ticket (VM adopter needed HANDOVER_DIR
# set manually; adopt.sh should seed it).
hd=$(jq -r '.env.HANDOVER_DIR' "$allrepo/.claude/settings.json" 2>/dev/null)
[ "$hd" = "$(norm "$allvault/handovers")" ] || fail "all/project did not persist HANDOVER_DIR ([$hd] != [$(norm "$allvault/handovers")])"
echo "ok: all routes core→--target, vault→--luna-target (no leak) + persists LUNA_VAULT_PATH + HANDOVER_DIR"

# ── 7. core/user idempotency (re-run into populated ~/.claude keeps 3) ────────
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user not idempotent on re-run"
echo "ok: core/user idempotent on re-run"

# ── 8. F1: user-scope persists LUNA_VAULT_PATH to ~/.claude ──────
# 8a. F1-SC1(a): all/user --luna-target -> env.LUNA_VAULT_PATH in ~/.claude.
fh="$work/f1a-home"; mkdir -p "$fh"; fv="$work/f1a-vault"
HOME="$fh" bash "$adopt" --profile all --scope user --target "$work/ign-a" --luna-target "$fv" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh/.claude/settings.json")
[ "$got" = "$(norm "$fv")" ] || fail "F1-SC1(a) all/user: LUNA_VAULT_PATH=[$got] != [$(norm "$fv")]"
echo "ok: F1-SC1(a) all/user --luna-target persists LUNA_VAULT_PATH"
# this is the literal ticket repro shape (`adopt.sh --profile all
# --scope user --luna-target ...`) — HANDOVER_DIR must land in ~/.claude too.
got=$(jq -r '.env.HANDOVER_DIR' "$fh/.claude/settings.json")
[ "$got" = "$(norm "$fv/handovers")" ] || fail "HIMMEL-839 all/user: HANDOVER_DIR=[$got] != [$(norm "$fv/handovers")]"
echo "ok: HIMMEL-839 all/user --luna-target persists HANDOVER_DIR"

# 8b. F1-SC1(b): luna/user --target -> env.LUNA_VAULT_PATH in ~/.claude.
fh2="$work/f1b-home"; mkdir -p "$fh2"; fv2="$work/f1b-vault"
HOME="$fh2" bash "$adopt" --profile luna --scope user --target "$fv2" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh2/.claude/settings.json")
[ "$got" = "$(norm "$fv2")" ] || fail "F1-SC1(b) luna/user --target: LUNA_VAULT_PATH=[$got] != [$(norm "$fv2")]"
echo "ok: F1-SC1(b) luna/user --target persists LUNA_VAULT_PATH"

# 8c. arg fix: --profile luna honors --luna-target when --target is left default.
fh3="$work/f1c-home"; mkdir -p "$fh3"; fv3="$work/f1c-vault"
HOME="$fh3" bash "$adopt" --profile luna --scope user --luna-target "$fv3" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh3/.claude/settings.json")
[ "$got" = "$(norm "$fv3")" ] || fail "luna --luna-target honored: LUNA_VAULT_PATH=[$got] != [$(norm "$fv3")]"
[ -f "$fv3/README.md" ] || fail "luna --luna-target did not scaffold to --luna-target"
echo "ok: --profile luna honors --luna-target (no longer a silent no-op)"

# 8d. unconditional wiring: a re-run over an EXISTING scaffold (copy skipped)
#     must STILL write the env key — fixes a previously-unwired install.
fh4="$work/f1d-home"; mkdir -p "$fh4"; fv4="$work/f1d-vault"; mkdir -p "$fv4"
HOME="$fh4" bash "$adopt" --profile luna --scope user --luna-target "$fv4" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh4/.claude/settings.json")
[ "$got" = "$(norm "$fv4")" ] || fail "dest-preexists: LUNA_VAULT_PATH not written ([$got] != [$(norm "$fv4")])"
echo "ok: re-run over existing scaffold still wires LUNA_VAULT_PATH (unconditional)"

# ── 9. hook paths forward-slashed + quoted; re-wire REPLACES a
#       pre-existing broken backslash entry (basename dedup), keeps non-himmel ──
h9="$work/h9"; mkdir -p "$h9/.claude"
# seed a BROKEN backslash auto-approve entry (the adopt.ps1 bug) + a non-himmel hook
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash C:\\Users\\me\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}]}
]}}' > "$h9/.claude/settings.json"
HOME="$h9" bash "$adopt" --profile core --scope user --target "$work/ign9" >/dev/null
s9="$h9/.claude/settings.json"
aa=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))' "$s9")
[ -n "$aa" ] || fail "hookpath: auto-approve hook missing after re-wire"
[ "$(printf '%s\n' "$aa" | wc -l)" -eq 1 ] || fail "hookpath: expected exactly ONE auto-approve entry (got: $aa)"
# shellcheck disable=SC1003  # '\' is a literal-backslash glob pattern, not a quote escape
case "$aa" in *'\'*) fail "hookpath: auto-approve command still contains a backslash: $aa" ;; esac
# the wired command now guards a missing script (if [ -f ]; then
# bash "..."; else warn+exit 0; fi) instead of a bare bash "...", so the
# forward-slash+quoted check matches that shape.
case "$aa" in 'if [ -f "'*'/scripts/hooks/auto-approve-safe-bash.sh" ]; then bash "'*'/scripts/hooks/auto-approve-safe-bash.sh"; else echo "himmel: hook script missing ('*'/scripts/hooks/auto-approve-safe-bash.sh) -- re-run the install (himmelctl install) or unwire it (himmelctl uninstall)" >&2; exit 0; fi') : ;; *) fail "hookpath: auto-approve not forward-slash+quoted: $aa" ;; esac
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9" >/dev/null || fail "hookpath: rtk-hook-guard not preserved"
echo "ok: hooks forward-slash+quoted; broken entry replaced; rtk kept"

# 9b. hook-object granularity: a non-himmel hook co-located in the SAME hooks[]
#     array as a himmel hook must SURVIVE re-wire (not dropped with the stanza).
h9b="$work/h9b"; mkdir -p "$h9b/.claude"
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[
    {"type":"command","command":"bash C:\\old\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"},
    {"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}
  ]}
]}}' > "$h9b/.claude/settings.json"
HOME="$h9b" bash "$adopt" --profile core --scope user --target "$work/ign9b" >/dev/null
s9b="$h9b/.claude/settings.json"
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9b" >/dev/null \
  || fail "hookpath(nested): co-located rtk-hook-guard dropped with the himmel stanza"
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s9b")" = "1" ] \
  || fail "hookpath(nested): expected exactly one auto-approve after re-wire"
echo "ok: co-located non-himmel hook survives re-wire (hook-object granularity)"

# ── 10. qmd wiring: --dry-run emits the qmd step DRY lines ───────
# Force has_qmd=false deterministically: fake HOME (no ~/.bun/.../qmd.js) on the
# suite-wide qmd/bun-scrubbed PATH (computed at the top), so wire_qmd_core
# reaches its install/register steps even on a dev box that has a real qmd
# installed. bun is stubbed (exit 0) so require_tools leaves BUN_AVAILABLE at
# its default (1). --dry-run is side-effect-free (the wire helpers honor the
# dry flag).
qbin="$work/qbin"; mkdir -p "$qbin"
cat > "$qbin/bun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$qbin/bun"
qhome="$work/qhome"; mkdir -p "$qhome"
# --with-graphify rides this dry-run: opted-in + --dry-run
# must emit the graphify DRY line (and nothing real — dry-run never installs).
set +e
out=$(PATH="$qbin:$work/bin:$qmd_free_path" HOME="$qhome" bash "$adopt" \
      --profile all --scope user --target "$work/ign-q" --luna-target "$work/qvault" --with-graphify --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "dry-run adopt exited rc=$rc (expected 0)"
grepq "$out" 'DRY:.*fix-qmd-stub'    || fail "dry-run missing fix-qmd-stub DRY line"
grepq "$out" 'DRY: qmd_install'      || fail "dry-run missing qmd_install DRY line"
grepq "$out" 'DRY: qmd pull'         || fail "dry-run missing qmd pull DRY line"
grepq "$out" 'DRY: qmd_register_collection .* himmel$' || fail "dry-run missing himmel register DRY line"
grepq "$out" 'DRY: qmd_register_collection .* luna$'   || fail "dry-run missing luna register DRY line"
# dry-run must also report the HANDOVER_DIR seed step (no mkdir,
# no settings.json write — mirrors the mkdir-then-wire pair as DRY lines).
grepq "$out" 'DRY: mkdir -p .*/qvault/handovers$' || fail "dry-run missing HANDOVER_DIR mkdir DRY line"
grepq "$out" 'DRY: wire env.HANDOVER_DIR' || fail "dry-run missing HANDOVER_DIR wire DRY line"
grepq "$out" 'Wiring graphify (opt-in' || fail "dry-run --with-graphify missing the graphify wiring banner"
grepq "$out" 'DRY: graphify_install'   || fail "dry-run --with-graphify missing graphify_install DRY line"
# --with-graphify also registers the MCP server at the adopt scope
# (here --scope user: on demand, never in ~/.claude.json), so the dry-run must
# emit the on-demand registration DRY line.
grepq "$out" 'DRY: register graphify MCP on demand' || fail "dry-run --with-graphify missing the graphify MCP registration DRY line"
# gap 3: build_jira_cli runs after install_plugins; with npm scrubbed
# suite-wide and bun stubbed present, it picks bun and emits its DRY build line.
grepq "$out" 'DRY:.*(cd scripts/jira && bun install && bun run build)' || fail "dry-run missing build_jira_cli DRY line"
echo "ok: dry-run emits all qmd step DRY lines (core G1/G3/G4 + luna G5) + build_jira_cli + graphify opt-in DRY"

# ── 11. qmd WARN-not-fail: a failing qmd install never aborts adopt
# bun present (stubbed) + a `git` stub that fails on `clone` + has_qmd=false
# (scrubbed PATH, fake HOME) -> qmd_install is invoked, the fork clone fails,
# and wire_qmd_core WARNs, but adopt still exits 0 (qmd is best-effort). The
# git stub keeps this hermetic — no real network clone of the fork repo. Fake
# HOME keeps settings writes isolated.
fbin="$work/fbin"; mkdir -p "$fbin"
cat > "$fbin/bun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fbin/bun"
cat > "$fbin/git" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "clone" ] && exit 1
exit 0
STUB
chmod +x "$fbin/git"
# Argv-logging uv stub: this run passes NO --with-graphify,
# so graphify must stay completely un-wired — the stub's log proves no
# `uv tool install` ever fires on a default core adopt (the
# open-verdict contract: opt-in only, never default).
cat > "$fbin/uv" <<STUB
#!/usr/bin/env bash
echo "UV \$*" >> "$work/uv-calls-11"
exit 0
STUB
chmod +x "$fbin/uv"
: > "$work/uv-calls-11"
fhome="$work/fhome"; mkdir -p "$fhome"
set +e
out=$(PATH="$fbin:$work/bin:$qmd_free_path" HOME="$fhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-f" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "adopt must exit 0 when qmd install fails (WARN-not-fail), got rc=$rc"
grepq "$out" 'Installing qmd fork' || fail "qmd_install not invoked (call order)"
grepq "$out" -E 'WARNING.*qmd install failed' || fail "missing qmd install WARNING (WARN-not-fail)"
echo "ok: qmd install failure WARNs and adopt continues (WARN-not-fail, rc=0)"
# graphify default-OFF, behaviorally asserted on the run above.
if grepq "$out" 'Wiring graphify'; then
  fail "default core adopt (no --with-graphify) ran the graphify wiring (opt-in regression)"
fi
if grep -q 'tool install' "$work/uv-calls-11"; then
  fail "default core adopt (no --with-graphify) invoked uv tool install (opt-in regression)"
fi
echo "ok: graphify stays un-wired on a default core adopt (opt-in only, zero uv installs)"

# ── 11b. an existing UPSTREAM install MIGRATES ────
# A real @tobilu/qmd directory at the bun-global path + a working stubbed bun
# make has_qmd TRUE -- the exact population the fork change repairs. The
# install gate is qmd_fork_served (not presence), so adopt must still run
# qmd_install: back the upstream dir up and link the fork over the global
# path -- never skip and report success on the EPERM-prone upstream install.
# Stubs keep it hermetic: git clone fabricates the fork clone locally, bun
# fabricates the build output; no network, fake HOME.
mbin="$work/mbin"; mkdir -p "$mbin"
cat > "$mbin/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  install) exit 0 ;;
  run) [ "$2" = "build" ] && { mkdir -p dist/cli; : > dist/cli/qmd.js; }; exit 0 ;;
  *) echo "qmd 2.6.10"; exit 0 ;;
esac
STUB
chmod +x "$mbin/bun"
# The stub answers the pin check with the pin adopt.sh will actually check:
# the ambient QMD_FORK_REF override when one is set (the same precedence
# _qmd_fork_ref uses, and the shape an earlier change's own positive control ran),
# otherwise the compiled-in default read out of qmd-bin.sh. A hardcoded copy
# drifts on the next pin bump and silently fails this case before it reaches
# the migration branch it asserts on.
QMD_STUB_HEAD_SHA="${QMD_FORK_REF:-$(sed -n 's/.*QMD_FORK_REF:-\([0-9a-f]\{40\}\).*/\1/p' \
  "$repo_root/scripts/lib/qmd-bin.sh" | head -1)}"
[ -n "$QMD_STUB_HEAD_SHA" ] \
  || fail "could not read QMD_FORK_REF out of scripts/lib/qmd-bin.sh"
export QMD_STUB_HEAD_SHA
cat > "$mbin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-C" ]; then shift 2; fi
case "$1" in
  # replaced `git clone` with init+fetch-by-sha+checkout, so the
  # stub must materialize the dir on `init` (clone kept for back-compat) and
  # answer the belt-and-braces `rev-parse HEAD` with the pinned fork SHA --
  # otherwise install refuses before the migration ("moving aside") branch
  # this case exercises ever runs.
  clone|init) target="${!#}"; mkdir -p "$target/.git"; exit 0 ;;
  # Only the exact `rev-parse HEAD` query the pin check performs gets the
  # SHA; other rev-parse forms keep the silent-success default (coderabbit
  # finding).
  rev-parse) [ "${2:-}" = "HEAD" ] && echo "${QMD_STUB_HEAD_SHA:-}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$mbin/git"
mhome="$work/mhome"
mkdir -p "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
: > "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"  # upstream: has_qmd=TRUE
set +e
out=$(PATH="$mbin:$work/bin:$qmd_free_path" HOME="$mhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-m" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "migration adopt exited rc=$rc (expected 0)"
grepq "$out" 'Installing qmd fork' \
  || fail "upstream-present install did not trigger the fork install (presence-gate regression)"
grepq "$out" 'moving aside' || fail "upstream dir was not moved aside"
[ -d "$mhome/.bun/install/global/node_modules/@tobilu/qmd.pre-fork-backup" ] \
  || fail "upstream backup dir missing after migration"
[ -e "$mhome/.himmel/qmd-fork/dist/cli/qmd.js" ] || fail "fork clone was not built"
[ -e "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js" ] \
  || fail "global path does not serve the fork after migration"
echo "ok: existing upstream install migrates to the fork (backup + link, not skipped)"

# ── 12. node-without-npm + no JS package manager -> HARD fail ──
# Stub node on PATH but provide NO npm; bun is already absent suite-wide, so the
# node-without-npm check finds no JS package manager and adopt must exit non-zero
# with the bun.sh + NodeSource install hints. npm dirs are scrubbed from the
# suite-wide bun/qmd-scrubbed PATH (node + npm usually share a bin dir, so dropping
# the npm dir also drops real node — the stub node re-adds node deterministically).
nbin="$work/nbin"; mkdir -p "$nbin"
cat > "$nbin/node" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$nbin/node"
npm_free_path=""
_save_ifs="$IFS"; IFS=':'
for _d in $qmd_free_path; do
  [ -x "$_d/npm" ] && continue
  npm_free_path="${npm_free_path:+$npm_free_path:}$_d"
done
IFS="$_save_ifs"
ntarget="$work/ntarget"; nhome="$work/nhome"; mkdir -p "$ntarget" "$nhome"
set +e
out=$(PATH="$nbin:$work/bin:$npm_free_path" HOME="$nhome" bash "$adopt" \
      --profile core --scope project --target "$ntarget" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "node-without-npm + no bun should exit non-zero (got $rc)"
grepq "$out" 'npm' || fail "node-without-npm msg missing 'npm'"
grepq "$out" 'bun.sh' || fail "node-without-npm msg missing bun.sh hint"
grepq "$out" -i 'nodesource' || fail "node-without-npm msg missing nodesource hint"
echo "ok: node-without-npm + no JS package manager -> hard fail (rc=$rc) + install hints"

# ── 13. node-without-npm WITH bun -> soft warn, adopt proceeds ─
# bun covers every himmel JS build, so node-without-npm is only a SOFT warn when
# bun is present (no hard fail). --dry-run keeps the run side-effect-free.
nbin2="$work/nbin2"; mkdir -p "$nbin2"
printf '#!/usr/bin/env bash\nexit 0\n' > "$nbin2/node"; chmod +x "$nbin2/node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$nbin2/bun";  chmod +x "$nbin2/bun"
ntarget2="$work/ntarget2"; nhome2="$work/nhome2"; mkdir -p "$ntarget2" "$nhome2"
set +e
out=$(PATH="$nbin2:$work/bin:$npm_free_path" HOME="$nhome2" bash "$adopt" \
      --profile core --scope project --target "$ntarget2" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "node-without-npm + bun should proceed (got $rc)"
grepq "$out" 'npm' || fail "node-without-npm+bun missing soft warn"
if grepq "$out" 'no JS package manager'; then
  fail "node-without-npm+bun must NOT hard-fail (saw hard-fail message)"
fi
echo "ok: node-without-npm + bun present -> soft warn, adopt proceeds (rc=0)"

# ── 14. build_jira_cli success path (stub npm exit 0) ───────
# npm scrubbed suite-wide; re-add a stub npm (exit 0) so build_jira_cli picks npm,
# the (cd scripts/jira && npm install && npm run build) subshell "succeeds", and
# adopt reports the build + continues. dist/index.js is not actually created by
# the stub — the assertion is on the reported outcome, not the artifact.
bjbin="$work/bjbin"; mkdir -p "$bjbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bjbin/npm"; chmod +x "$bjbin/npm"
bjhome="$work/bjhome"; mkdir -p "$bjhome"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli success path: adopt should exit 0 (got $rc)"
grepq "$out" 'Building jira CLI' || fail "build_jira_cli: missing 'Building jira CLI' header"
grepq "$out" 'jira CLI built'    || fail "build_jira_cli: missing success message"
if grepq "$out" 'jira CLI build failed'; then
  fail "build_jira_cli: success path must not print a build-failed warning"
fi
echo "ok: build_jira_cli success path (stub npm) reports built, adopt exits 0"

# ── 15. build_jira_cli WARN-not-fail (stub npm exit 1) ──────
# A failing build must WARN with the manual command and return 0 — matches
# wire_qmd_core's contract; a broken jira build never aborts adopt.
bfbin="$work/bfbin"; mkdir -p "$bfbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bfbin/npm"; chmod +x "$bfbin/npm"
bfhome="$work/bfhome"; mkdir -p "$bfhome"
set +e
out=$(PATH="$bfbin:$work/bin:$qmd_free_path" HOME="$bfhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bf" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli WARN-not-fail: adopt must exit 0 on a build failure (got $rc)"
grepq "$out" -E 'WARNING.*jira CLI build failed' || fail "build_jira_cli: missing build-failed WARNING"
grepq "$out" 'npm install && npm run build'     || fail "build_jira_cli: missing manual command in WARNING"
echo "ok: build_jira_cli failure WARNs with manual command, adopt continues (rc=0)"

# ── 16. build_jira_cli skip when no JS package manager ──────
# npm AND bun both absent (the scrubbed suite base) -> build_jira_cli skips with
# the manual command and never attempts a build. A real run, not --dry-run, so
# the skip branch (not the DRY branch) is exercised.
skhome="$work/skhome"; mkdir -p "$skhome"
set +e
out=$(PATH="$work/bin:$qmd_free_path" HOME="$skhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-sk" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli skip path: adopt should exit 0 (got $rc)"
grepq "$out" 'jira CLI: skipping build (no npm or bun' || fail "build_jira_cli: missing no-pm skip note"
if grepq "$out" 'Building jira CLI'; then
  fail "build_jira_cli: no-pm path must NOT attempt a build (saw build header)"
fi
echo "ok: build_jira_cli skips (no npm/bun) with manual command, no build attempted"

# ── 17. build_jira_cli idempotent when dist AND node_modules
# already built (F3: the skip now requires BOTH halves present) ─────────────
# The suite-wide move-aside at the top guarantees scripts/jira/dist and
# scripts/jira/node_modules are both absent entering this scenario; create
# both so build_jira_cli's "already built" branch fires. Removed right after
# (dist/ and node_modules/ are gitignored, so this never pollutes git); the
# suite-wide trap restores the real ones unconditionally regardless.
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
bjhome2="$work/bjhome2"; mkdir -p "$bjhome2"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome2" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj2" 2>&1); rc=$?
set -e
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "build_jira_cli idempotent path: adopt should exit 0 (got $rc)"
grepq "$out" 'jira CLI dist already built' || fail "build_jira_cli: missing 'already built' skip"
if grepq "$out" 'Building jira CLI'; then
  fail "build_jira_cli: already-built path must NOT attempt a build"
fi
echo "ok: build_jira_cli idempotent when dist/index.js + node_modules already present (skips build)"

# ── 18. dist present but node_modules ABSENT -> build
# must NOT skip ────────────────────────────────────────────────────────────
# A stale dist/ without node_modules/ previously passed as "already built"
# then failed at runtime — F3's fix requires BOTH halves present to skip.
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
# node_modules stays absent (suite-wide baseline).
bjhome3="$work/bjhome3"; mkdir -p "$bjhome3"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome3" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj3" 2>&1); rc=$?
set -e
rm -rf "$real_jira_dist"
[ "$rc" -eq 0 ] || fail "dist-present/node_modules-absent: adopt should exit 0 (got $rc)"
grepq "$out" 'Building jira CLI' || fail "dist-present/node_modules-absent: build_jira_cli should NOT skip (missing build header)"
if grepq "$out" 'jira CLI dist already built'; then
  fail "dist-present/node_modules-absent: must NOT take the already-built skip branch"
fi
echo "ok: build_jira_cli builds when dist present but node_modules absent (F3 invariant)"

# ── 19. build_jira_cli bun branch, REAL invocation ────
# npm absent (suite-wide scrub), bun stubbed; assert the bun install/build
# lines actually ran (success path is enough per F5) — the bun branch was
# previously only exercised via --dry-run (scenario 10).
bubin="$work/bubin"; mkdir -p "$bubin"
cat > "$bubin/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  install) echo "BUN_INSTALL_STUB_RAN" ;;
  run) [ "$2" = "build" ] && echo "BUN_BUILD_STUB_RAN" ;;
esac
exit 0
STUB
chmod +x "$bubin/bun"
buhome="$work/buhome"; mkdir -p "$buhome"
set +e
out=$(PATH="$bubin:$work/bin:$qmd_free_path" HOME="$buhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bu" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli bun real-invocation: adopt should exit 0 (got $rc)"
grepq "$out" 'BUN_INSTALL_STUB_RAN' || fail "build_jira_cli bun real-invocation: bun install did not run"
grepq "$out" 'BUN_BUILD_STUB_RAN'   || fail "build_jira_cli bun real-invocation: bun run build did not run"
grepq "$out" 'jira CLI built' || fail "build_jira_cli bun real-invocation: missing success message"
echo "ok: build_jira_cli bun branch real-invocation runs install + build (F5)"

# ── 19b. install_precommit_hooks places the git gate hooks ──────
# The stub `pre-commit` in $pcbin (scripts/lib/adopt-test-fixture.sh) logs its
# argv, which proves adopt.sh actually shells out to `pre-commit install ...`
# against $TARGET, not just that it prints a message.

# default: no --skip-hooks, and the target carries its OWN
# .pre-commit-config.yaml (without one adopt places the native
# gates instead -- see 19d) -> pre-commit install runs against $TARGET with
# all 3 hook types, adopt reports success, rc=0, the config is left untouched.
: > "$work/pre-commit.argv"
pctarget19b1="$work/pctarget19b1"; mkdir -p "$pctarget19b1"
( cd "$pctarget19b1" && HOME="$pchome" git init -q )
printf 'repos: []\n# adopter-owned\n' > "$pctarget19b1/.pre-commit-config.yaml"
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 default: adopt should exit 0 (got $rc): $out"
[ "$(cat "$pctarget19b1/.pre-commit-config.yaml")" = "$(printf 'repos: []\n# adopter-owned')" ] \
  || fail "HIMMEL-3306 own-config: the adopter's .pre-commit-config.yaml was modified"
grepq "$(cat "$work/pre-commit.argv")" \
  'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
  || fail "HIMMEL-2441 default: pre-commit install was not invoked with all 3 hook types (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks installed (pre-commit, commit-msg, pre-push).' \
  || fail "HIMMEL-2441 default: missing the git-hooks-installed message (got: $out)"
echo "ok: HIMMEL-2441 default adopt wires pre-commit/commit-msg/pre-push hooks into \$TARGET"

# collect all five controls so the first missing fallback does
# not hide the behavioural failure. Each subshell retains the fail idiom.
native_failures=0
for native_case in missing framework pep668 unwritable behaviour; do
  set +e
  (
    set -e
    ntarget="$work/native-$native_case"
    nbin="$work/native-bin-$native_case"
    mkdir -p "$ntarget" "$nbin"
    HOME="$pchome" git -C "$ntarget" init -q
    HOME="$pchome" git -C "$ntarget" checkout -q -b feat/native-test
    npath="$nbin:$work/bin:$native_free_path"
    if [ "$native_case" = framework ]; then
      npath="$pcbin:$npath"
      : > "$work/pre-commit.argv"
    fi
    # pre-commit is only attempted for an adopter with a config of
    # their own, so the framework case and both bootstrap-failure fallbacks
    # need one to reach it at all (the no-config path is 19d).
    case "$native_case" in
      missing|framework|pep668) printf 'repos: []\n' > "$ntarget/.pre-commit-config.yaml" ;;
    esac
    if [ "$native_case" = pep668 ]; then
      cat > "$nbin/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
  echo 'error: externally-managed-environment' >&2
  exit 1
fi
exec "$real_python3" "\$@"
STUB
      chmod +x "$nbin/python3"
    fi
    if [ "$native_case" = unwritable ]; then
      mkdir -p "$ntarget/.git/hooks"
      chmod a-w "$ntarget/.git/hooks"
      [ ! -w "$ntarget/.git/hooks" ] || fail "HIMMEL-2771 unwritable: fixture requires an unprivileged user"
    fi
    set +e
    nout=$(PATH="$npath" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$ntarget" 2>&1); nrc=$?
    set -e
    case "$native_case" in
      missing|pep668)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 $native_case: adopt exited $nrc"
        if [ "$native_case" = pep668 ]; then
          grepq "$nout" 'externally-managed-environment' \
            || fail "HIMMEL-2771 pep668: refusal was not reported by name"
        fi
        for hook in commit-msg pre-commit pre-push; do
          [ -x "$ntarget/.git/hooks/$hook" ] \
            || fail "HIMMEL-2771 $native_case: executable $hook hook absent"
        done
        grepq "$nout" 'git gate hooks — placed (native, no pre-commit framework: lint hooks absent)' \
          || fail "HIMMEL-2771 $native_case: native summary absent"
        ;;
      framework)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 framework: adopt exited $nrc"
        grepq "$(cat "$work/pre-commit.argv")" 'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
          || fail "HIMMEL-2771 framework: install not called"
        ! grepq "$nout" 'placed (native' || fail "HIMMEL-2771 framework: native fallback taken"
        ;;
      unwritable)
        chmod u+w "$ntarget/.git/hooks"
        [ "$nrc" -ne 0 ] || fail "HIMMEL-2771 unwritable: adopt exited 0 with no gates"
        grepq "$nout" 'git gate hooks — FAILED (native:' \
          || fail "HIMMEL-2771 unwritable: failure summary absent"
        # $ntarget is the PRIMARY checkout with core.hooksPath
        # unset, so the fallback payload copy (now always attempted for
        # Git's own shared per-repository hooks dir, per the gap-1 fix) is
        # the FIRST write into the unwritable hooks dir and fails before the
        # dispatcher-writing loop below it ever runs -- the failure reason
        # moved from "cannot write .../commit-msg" to the payload mkdir/cp.
        grepq "$nout" "cannot copy scripts/hooks/check-commit-msg.sh into $ntarget/.git/hooks/himmel-payload" \
          || fail "HIMMEL-2771 unwritable: failure reason absent"
        ;;
      behaviour)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 behaviour: adopt exited $nrc"
        HOME="$pchome" git -C "$ntarget" config user.name 'Native Test'
        HOME="$pchome" git -C "$ntarget" config user.email 'native@example.invalid'
        set +e
        nout=$(HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'no ticket here at all' 2>&1); nrc=$?
        set -e
        [ "$nrc" -ne 0 ] || fail "HIMMEL-2771 behaviour: unticketed commit landed"
        ! git -C "$ntarget" rev-parse --verify HEAD >/dev/null 2>&1 \
          || fail "HIMMEL-2771 behaviour: rejected commit created HEAD"
        # Also isolate the ticket check from the conventional-format check.
        if HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'test: missing ticket' >/dev/null 2>&1; then
          fail "HIMMEL-2771 behaviour: conventional unticketed commit landed"
        fi
        HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'test: HIMMEL-2771 [#2771] native gates' >/dev/null 2>&1 \
          || fail "HIMMEL-2771 behaviour: ticketed commit refused"
        git -C "$ntarget" rev-parse --verify HEAD >/dev/null \
          || fail "HIMMEL-2771 behaviour: ticketed commit did not create HEAD"
        ;;
    esac
    echo "ok: HIMMEL-2771 $native_case"
  )
  native_rc=$?
  set -e
  if [ "$native_rc" -ne 0 ]; then native_failures=$((native_failures + 1)); fi
done
[ "$native_failures" -eq 0 ] || fail "HIMMEL-2771 controls: $native_failures failed, $((5 - native_failures)) passed"

# ── 19d. no config of the adopter's own => the gates must GATE ──
# The framework stubs skip ("config file not found") on every commit and push
# when the target has no .pre-commit-config.yaml, so adopt must place the native
# gates even though a working `pre-commit` is on PATH -- the recommended path
# used to be the WEAKER one. Each refusal below is checked for the gate's own
# text, so a blanket failure (missing binary, read-only dir) cannot pass for it.
gtarget="$work/gates-3306"; gremote="$work/gates-3306-remote.git"
mkdir -p "$gtarget"
HOME="$pchome" git init -q -b main "$gtarget"
HOME="$pchome" git init -q --bare "$gremote"
HOME="$pchome" git -C "$gtarget" remote add origin "$gremote"
HOME="$pchome" git -C "$gtarget" config user.name 'Gate Test'
HOME="$pchome" git -C "$gtarget" config user.email 'gate@example.invalid'
: > "$work/pre-commit.argv"
# The state a pre-fix install left behind: framework stubs, no config.
mkdir -p "$gtarget/.git/hooks"
for hook in commit-msg pre-commit pre-push; do
  printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\necho "config file not found. Skipping" >&2\nexit 0\n' > "$gtarget/.git/hooks/$hook"
  chmod +x "$gtarget/.git/hooks/$hook"
done
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$gtarget" 2>&1) \
  || fail "HIMMEL-3306 no-config: adopt failed: $out"
[ ! -s "$work/pre-commit.argv" ] \
  || fail "HIMMEL-3306 no-config: pre-commit install ran with no config to wire (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git gate hooks — placed (native' || fail "HIMMEL-3306 no-config: native gates not placed: $out"
[ ! -e "$gtarget/.pre-commit-config.yaml" ] || fail "HIMMEL-3306 no-config: adopt wrote a .pre-commit-config.yaml"
for hook in commit-msg pre-commit pre-push; do
  grepq "$(cat "$gtarget/.git/hooks/$hook")" 'HIMMEL-2771: native invariant gate' \
    || fail "HIMMEL-3306 no-config: $hook is not the native dispatcher"
  [ -x "$gtarget/.git/hooks/$hook.himmel-backup" ] \
    || fail "HIMMEL-3306 no-config: the earlier framework stub $hook was not preserved as a backup"
done
# (1) commit on main: refused by check-worktree-isolation.
set +e
out=$(HOME="$pchome" git -C "$gtarget" commit --allow-empty -m 'test: HIMMEL-3306 [#3306] on main' 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-3306 no-config: a commit on main succeeded (rc=$rc): $out"
grepq "$out" "Committing directly on 'main' is not allowed" \
  || fail "HIMMEL-3306 no-config: a commit on main was not refused by the isolation gate (rc=$rc): $out"
# (2) non-conventional, unticketed message on a feature branch: refused by check-commit-msg.
HOME="$pchome" git -C "$gtarget" checkout -q -b feat/gates-3306
set +e
out=$(HOME="$pchome" git -C "$gtarget" commit --allow-empty -m 'zzzz not conventional and no ticket' 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-3306 no-config: a non-conventional commit succeeded (rc=$rc): $out"
grepq "$out" 'COMMIT REJECTED' \
  || fail "HIMMEL-3306 no-config: a non-conventional commit was not refused by the message gate (rc=$rc): $out"
! git -C "$gtarget" rev-parse --verify HEAD >/dev/null 2>&1 \
  || fail "HIMMEL-3306 no-config: the rejected commit created HEAD"
# Control: the gates are not a blanket refusal -- a conventional, ticketed commit lands.
HOME="$pchome" git -C "$gtarget" commit -q --allow-empty -m 'test: HIMMEL-3306 [#3306] gates gate' >/dev/null 2>&1 \
  || fail "HIMMEL-3306 no-config: a conventional ticketed commit was refused"
# (3) direct push to main: refused by check-push-target; a feature-branch push is not.
set +e
out=$(HOME="$pchome" git -C "$gtarget" push origin HEAD:refs/heads/main 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-3306 no-config: a direct push to main succeeded (rc=$rc): $out"
grepq "$out" "Direct push to 'main' is not allowed" \
  || fail "HIMMEL-3306 no-config: a direct push to main was not refused by the push gate (rc=$rc): $out"
HOME="$pchome" git -C "$gtarget" push -q origin HEAD:refs/heads/feat/gates-3306 >/dev/null 2>&1 \
  || fail "HIMMEL-3306 no-config: a feature-branch push was refused"
# Re-running adopt must not back up its own dispatchers over the adopter's backups.
before=$(cat "$gtarget/.git/hooks/commit-msg.himmel-backup")
HOME="$pchome" PATH="$pcbin:$work/bin:$native_free_path" bash "$adopt" --profile core --scope project --target "$gtarget" >/dev/null 2>&1 \
  || fail "HIMMEL-3306 no-config: re-adopt failed"
[ "$(cat "$gtarget/.git/hooks/commit-msg.himmel-backup")" = "$before" ] \
  || fail "HIMMEL-3306 no-config: re-adopt rewrote the backup"
echo "ok: HIMMEL-3306 no-config adopt places the native gates: commit on main, non-conventional commit and push to main are all refused; controls land"

# --dry-run with no config plans the native gates and names no pre-commit install.
gdry="$work/gates-3306-dry"; mkdir -p "$gdry"
HOME="$pchome" git init -q -b main "$gdry"
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" --profile core --scope project --target "$gdry" --dry-run 2>&1) \
  || fail "HIMMEL-3306 dry-run: adopt failed: $out"
grepq "$out" 'DRY: place executable native commit-msg, pre-commit, pre-push hooks' \
  || fail "HIMMEL-3306 dry-run: no native placement plan: $out"
! grepq "$out" 'install --allow-missing-config' || fail "HIMMEL-3306 dry-run: planned a pre-commit install with no config: $out"
[ ! -e "$gdry/.git/hooks/commit-msg" ] || fail "HIMMEL-3306 dry-run: wrote a hook"
echo "ok: HIMMEL-3306 --dry-run with no config plans the native gates only"

# --skip-hooks stays an opt-out when there is no config either.
gskip="$work/gates-3306-skip"; mkdir -p "$gskip"
HOME="$pchome" git init -q -b main "$gskip"
PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" --profile core --scope project --target "$gskip" --skip-hooks >/dev/null 2>&1 \
  || fail "HIMMEL-3306 skip-hooks: adopt failed"
[ ! -e "$gskip/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-3306 skip-hooks: --skip-hooks still placed a hook"
[ ! -s "$work/pre-commit.argv" ] \
  || fail "HIMMEL-3306 skip-hooks: --skip-hooks still ran pre-commit"
echo "ok: HIMMEL-3306 --skip-hooks still places nothing"

# The native pre-push gate also runs check-no-force-push.sh -- a
# force push to main is refused with THAT gate's own text (not just
# check-push-target's), a fast-forward feature push is not, and a re-adopt
# leaves one force-push invocation in the hook, not two.
fptarget="$work/gates-6976"; fpremote="$work/gates-6976-remote.git"; fpseed="$work/gates-6976-seed"
mkdir -p "$fptarget" "$fpseed"
HOME="$pchome" git init -q -b main "$fptarget"
HOME="$pchome" git init -q --bare "$fpremote"
HOME="$pchome" git init -q -b main "$fpseed"
for fpr in "$fptarget" "$fpseed"; do
  HOME="$pchome" git -C "$fpr" config user.name 'Gate Test'
  HOME="$pchome" git -C "$fpr" config user.email 'gate@example.invalid'
done
HOME="$pchome" git -C "$fptarget" remote add origin "$fpremote"
HOME="$pchome" git -C "$fpseed" remote add origin "$fpremote"
HOME="$pchome" git -C "$fpseed" commit -q --allow-empty -m 'seed remote main'
HOME="$pchome" git -C "$fpseed" push -q origin main >/dev/null 2>&1 \
  || fail "HIMMEL-6976: could not seed the remote's main"
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$fptarget" 2>&1) \
  || fail "HIMMEL-6976: adopt failed: $out"
[ -f "$fptarget/scripts/hooks/check-no-force-push.sh" ] \
  || fail "HIMMEL-6976: check-no-force-push.sh was not copied into the project"
HOME="$pchome" git -C "$fptarget" checkout -q -b feat/force-6976
HOME="$pchome" git -C "$fptarget" commit -q --allow-empty --no-verify -m 'unrelated history' >/dev/null 2>&1
set +e
out=$(HOME="$pchome" git -C "$fptarget" push --force origin HEAD:refs/heads/main 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-6976: a force push to main succeeded (rc=$rc): $out"
grepq "$out" "Force-push to 'main' is not allowed" \
  || fail "HIMMEL-6976: the force push to main was not refused by the no-force-push gate (rc=$rc): $out"
[ "$(git -C "$fpremote" rev-parse main)" = "$(git -C "$fpseed" rev-parse main)" ] \
  || fail "HIMMEL-6976: the remote's main moved despite the refusal"
HOME="$pchome" git -C "$fptarget" push -q origin HEAD:refs/heads/feat/force-6976 >/dev/null 2>&1 \
  || fail "HIMMEL-6976: a fast-forward feature push was refused"
HOME="$pchome" PATH="$pcbin:$work/bin:$native_free_path" bash "$adopt" --profile core --scope project --target "$fptarget" >/dev/null 2>&1 \
  || fail "HIMMEL-6976: re-adopt failed"
# shellcheck disable=SC2016
[ "$(grep -c 'bash "\$fp_gate"' "$fptarget/.git/hooks/pre-push" | tr -d ' ')" = "1" ] \
  || fail "HIMMEL-6976: re-adopt did not leave exactly one force-push gate invocation in pre-push"
[ ! -e "$fptarget/.git/hooks/pre-push.himmel-backup" ] || [ "$(grep -c 'check-no-force-push.sh' "$fptarget/.git/hooks/pre-push.himmel-backup")" = "0" ] \
  || fail "HIMMEL-6976: re-adopt backed up its own pre-push over the adopter's"
echo "ok: HIMMEL-6976 the native pre-push gate refuses a force push to main with the no-force-push gate; fast-forward lands; re-adopt keeps one invocation"

# The adopted project's own copy of check-ci.sh runs against a stubbed gh and
# resolves the project's repo from its PR URL, never himmel's; a second adopt
# leaves it byte-identical.
cittarget="$work/checkci-6977"; citbin="$work/checkci-6977-bin"; cithome="$work/checkci-6977-home"
mkdir -p "$cittarget" "$citbin" "$cithome"
HOME="$pchome" git init -q -b main "$cittarget"
cat > "$citbin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CIT_GH_LOG"
jq_arg=""
a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do
  [ "${a[$i]}" = "--jq" ] && jq_arg="${a[$((i + 1))]}"
done
emit() { if [ -n "$jq_arg" ]; then printf '%s' "$1" | jq -r "$jq_arg"; else printf '%s\n' "$1"; fi; }
case "$1 ${2:-}" in
  "pr view"|"pr checks") [ "${3:-}" = "7" ] || { echo "unexpected PR selector: $*" >&2; exit 1; } ;;
esac
case "$1 ${2:-}" in
  "pr view")
    emit '{"url":"https://github.com/acme/widgets/pull/7","reviewDecision":"","headRefOid":"abc123","baseRefName":"main","title":"feat: x","mergeStateStatus":"CLEAN"}' ;;
  "pr checks") echo '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
  "api graphql")
    emit '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  "api repos/acme/widgets/rules/branches/main") : ;;
  "api repos/acme/widgets/branches/main/protection/required_status_checks") echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
  "api repos/acme/widgets/commits/abc123/statuses?per_page=100"|"api repos/acme/widgets/pulls/7/reviews") echo '[]' ;;
  "api -i") printf 'X-Ratelimit-Remaining: 4000\nX-Ratelimit-Reset: 9999999999\n' ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$citbin/gh"
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$cittarget" 2>&1) \
  || fail "HIMMEL-6977: adopt failed: $out"
[ -f "$cittarget/scripts/check-ci.sh" ] \
  || fail "HIMMEL-6977: check-ci.sh was not copied into the project"
for cit_lib in non-gating-contexts.sh non-gating-contexts.txt; do
  [ -f "$cittarget/scripts/lib/$cit_lib" ] \
    || fail "HIMMEL-7239: check-ci.sh sources lib/$cit_lib but it was not copied into the project"
done
set +e
out=$(cd "$cittarget" && PATH="$citbin:$PATH" HOME="$cithome" CIT_GH_LOG="$work/checkci-6977.log" \
      CHECK_CI_POLL_INTERVAL=0 CHECK_CI_SETTLE=0 CHECK_CI_CACHE=0 WORKER_SESSION_JIRA_STATUS=0 \
      bash scripts/check-ci.sh 7 --max-wait 30 --grace 0 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-6977: the project's check-ci.sh did not reach a green verdict (rc=$rc): $out"
grepq "$out" "all checks green + all review threads resolved (PR #7 @ abc123)" \
  || fail "HIMMEL-6977: the project's check-ci.sh printed no green verdict: $out"
grep -q 'repos/acme/widgets/' "$work/checkci-6977.log" \
  || fail "HIMMEL-6977: check-ci.sh did not query the project's own repo"
if grep -q -i 'yotamleo' "$work/checkci-6977.log" "$cittarget/scripts/check-ci.sh"; then
  fail "HIMMEL-6977: the copied check-ci.sh or its gh calls name the himmel repo"
fi
IFS= read -r -d '' cit_before < "$cittarget/scripts/check-ci.sh" || true
HOME="$pchome" PATH="$pcbin:$work/bin:$native_free_path" bash "$adopt" --profile core --scope project --target "$cittarget" >/dev/null 2>&1 \
  || fail "HIMMEL-6977: re-adopt failed"
IFS= read -r -d '' cit_after < "$cittarget/scripts/check-ci.sh" || true
[ "$cit_after" = "$cit_before" ] \
  || fail "HIMMEL-6977: re-adopt changed the project's check-ci.sh"
echo "ok: HIMMEL-6977 the adopted check-ci.sh reaches a green verdict for the project's own repo; re-adopt is idempotent"

# An adopted project carries the merge-on-green gate and the anchor files it
# needs, and the copied script loads in the project.
for f in scripts/handover/merge-on-green.sh scripts/lib/check-pr-title.sh scripts/lib/ticket-id-internal.sh scripts/ci/ticket-id-internal-authors.txt scripts/chokepoints.json; do
  [ -f "$cittarget/$f" ] || fail "HIMMEL-7001: $f was not copied into the project"
  cmp -s "$repo_root/$f" "$cittarget/$f" || fail "HIMMEL-7001: the project's $f differs from himmel's"
done
set +e
out=$(cd "$cittarget" && HOME="$cithome" HIMMEL_REPO="$cittarget" bash "$cittarget/scripts/handover/merge-on-green.sh" --help 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-7001: the project's merge-on-green.sh --help failed (rc=$rc): $out"
grepq "$out" "Usage: merge-on-green.sh" \
  || fail "HIMMEL-7001: the project's merge-on-green.sh printed no usage: $out"
echo "ok: HIMMEL-7001 an adopted project carries merge-on-green.sh and its anchor files"

# The adopted project's own copy of the usage preflight (and its old-name
# forwarder) reads the usage cache and account identity the project's session
# sees and prints a verdict, never a himmel-checkout path. The cache shape is the
# status line producer's real output (five_hour / seven_day / extra_usage /
# primaries_refreshed_at / account).
uptarget="$work/usagepf-6965"; uphome="$work/usagepf-6965-home"
mkdir -p "$uptarget" "$uphome"
HOME="$pchome" git init -q -b main "$uptarget"
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$uptarget" 2>&1) \
  || fail "HIMMEL-6965: adopt failed: $out"
for f in usage-preflight.sh bank-preflight.sh; do
  [ -f "$uptarget/scripts/lib/$f" ] || fail "HIMMEL-6965: $f was not copied into the project"
done
printf '{"oauthAccount":{"accountUuid":"11111111-2222-3333-4444-555555555555"}}\n' > "$uphome/.claude.json"
if command -v sha256sum >/dev/null 2>&1; then
  up_acct=$(printf '%s' "11111111-2222-3333-4444-555555555555" | sha256sum | cut -c1-16)
else
  up_acct=$(printf '%s' "11111111-2222-3333-4444-555555555555" | shasum -a 256 | cut -c1-16)
fi
up_cache() {
  jq -n --argjson five "$1" --argjson seven "$2" --arg acct "$up_acct" --argjson now "$(date +%s)" '{
    five_hour: {utilization: $five, resets_at: "2026-10-22T05:39:59.541164+00:00"},
    seven_day: {utilization: $seven, resets_at: "2026-10-24T08:59:59.541212+00:00"},
    extra_usage: {is_enabled: false, utilization: null},
    oauth_checked_at: $now, derived_at: $now, primaries_refreshed_at: $now, account: $acct}' \
    > "$work/usagepf-6965-cache.json"
}
up_run() {
  (cd "$uptarget" && HOME="$uphome" CADENCE_USAGE_CACHE="$work/usagepf-6965-cache.json" \
     CADENCE_USAGE_LEDGER="$uphome/.himmel/cadence-ledger.jsonl" CADENCE_USAGE_SKIP_REFRESH=1 \
     HIMMEL_FLEET_CAP=50 HIMMEL_FLEET_SLOTS="$work/usagepf-6965-slots" \
     bash scripts/lib/"$1" 2>"$work/usagepf-6965.err")
}
up_cache 10 20
out=$(up_run usage-preflight.sh) || fail "HIMMEL-6965: the project's usage-preflight.sh failed: $(cat "$work/usagepf-6965.err")"
[ "$out" = "PROCEED" ] \
  || fail "HIMMEL-6965: the project's usage-preflight.sh did not PROCEED on a low-usage cache: $out $(cat "$work/usagepf-6965.err")"
up_cache 10 99
out=$(up_run usage-preflight.sh) || fail "HIMMEL-6965: usage-preflight.sh failed on a high-usage cache"
[ "$out" = "SKIPPED-BANK" ] \
  || fail "HIMMEL-6965: the project's usage-preflight.sh did not hold on a 99% seven_day cache: $out"
up_cache 10 20
out=$(up_run bank-preflight.sh) || fail "HIMMEL-6965: the old-name forwarder failed: $(cat "$work/usagepf-6965.err")"
[ "$out" = "PROCEED" ] \
  || fail "HIMMEL-6965: the project's bank-preflight.sh forwarder did not PROCEED: $out $(cat "$work/usagepf-6965.err")"
grep -q '"verdict":"PROCEED"' "$uphome/.himmel/cadence-ledger.jsonl" \
  || fail "HIMMEL-6965: the preflight did not write its ledger row under the project's HOME"
if grep -q -i 'yotamleo' "$uptarget/scripts/lib/usage-preflight.sh"; then
  fail "HIMMEL-6965: the copied usage-preflight.sh names the himmel repo"
fi
echo "ok: HIMMEL-6965 the adopted usage-preflight.sh and its forwarder read the project's cache and print PROCEED / SKIPPED-BANK"

# The adopted project's own copies of the review-loop commands and the scripts
# they call read the PROJECT's review ledger (<project>/.git/cr-critic-scores.jsonl)
# through the relative anchor hand-off, never a himmel checkout's. The anchor is a
# scratch clone carrying only the files the hand-off byte-compares.
crtarget="$work/crloop-6999"; crclone="$work/crloop-6999-clone"
mkdir -p "$crtarget" "$crclone"
HOME="$pchome" git init -q -b main "$crtarget"
HOME="$pchome" git init -q -b main "$crclone"
out=$(PATH="$pcbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$crtarget" 2>&1) \
  || fail "HIMMEL-6999: adopt failed: $out"
for f in .claude/commands/cr-scores.md .claude/commands/cr-tune.md .claude/commands/cr-learnings-refresh.md \
         scripts/cr/cr-scores.sh scripts/cr/cr-tune.sh scripts/cr/known-findings.sh scripts/cr/known-findings.json \
         scripts/cr/standards-cadence.sh scripts/cr/anchor-handoff.sh scripts/lib/handover-path.sh; do
  [ -f "$crtarget/$f" ] || fail "HIMMEL-6999: $f was not copied into the project"
  cmp -s "$repo_root/$f" "$crtarget/$f" || fail "HIMMEL-6999: the project's $f differs from himmel's"
  case "$f" in
    *.sh) [ -x "$crtarget/$f" ] || fail "HIMMEL-6999: the project's $f is not executable" ;;
    *)    [ ! -x "$crtarget/$f" ] || fail "HIMMEL-6999: the project's $f (not a script) was made executable" ;;
  esac
done
for f in scripts/cr/anchor-handoff.sh scripts/cr/cr-scores.sh scripts/cr/known-findings.sh scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh; do
  mkdir -p "$crclone/$(dirname "$f")"; cp "$repo_root/$f" "$crclone/$f"
done
HOME="$pchome" git -C "$crclone" add scripts
{
  echo '{"kind":"finding","ts":"2026-07-01T10:00:00Z","branch":"b1","head":"aaaa111","model":"crloop-modelA","finding_id":"crloop-modelA-1","severity":"imp","file":"scripts/foo.sh","line":10,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-07-01T10:01:00Z","branch":"b1","head":"aaaa111","model":"crloop-modelA","finding_id":"crloop-modelA-2","severity":"crit","file":"scripts/bar.sh","line":5,"verdict":"disproved"}'
} > "$crtarget/.git/cr-critic-scores.jsonl"
crloop_node="$work/crloop-6999-node"; mkdir -p "$crloop_node"
ln -sf "$(PATH="$saved_path" command -v node)" "$crloop_node/node"
cr_run() {
  (cd "$crtarget" && PATH="$crloop_node:$PATH" HOME="$pchome" HIMMEL_REPO="$crclone" bash scripts/cr/"$1" "${@:2}" 2>"$work/crloop-6999.err")
}
out=$(cr_run cr-scores.sh) || fail "HIMMEL-6999: the project's cr-scores.sh failed: $(cat "$work/crloop-6999.err")"
grepq "$out" 'crloop-modelA' || fail "HIMMEL-6999: cr-scores.sh did not print the project ledger's rows: $out"
out=$(cr_run cr-tune.sh) || fail "HIMMEL-6999: the project's cr-tune.sh failed: $(cat "$work/crloop-6999.err")"
grepq "$out" 'crloop-modelA' || fail "HIMMEL-6999: cr-tune.sh did not mine the project ledger: $out"
echo "ok: HIMMEL-6999 the adopted review-loop commands and scripts read the project's own ledger"

# exercise the remaining bootstrap exits and Git's configured
# hooks directory. User scope must also carry its own native gate payloads.
for fallback_case in uv-fails pipx-fails unresolved user-hooks-path skip; do
  ntarget="$work/fallback-$fallback_case"; nbin="$work/fallback-bin-$fallback_case"
  mkdir -p "$ntarget" "$nbin"
  HOME="$pchome" git -C "$ntarget" init -q
  nscope=project; hook_dir="$ntarget/.git/hooks"; extra_flag=""
  # the installer-failure fallbacks only run for a target with its own config.
  printf 'repos: []\n' > "$ntarget/.pre-commit-config.yaml"
  case "$fallback_case" in
    uv-fails|pipx-fails|unresolved)
      installer="${fallback_case%-fails}"; installer_rc=1
      if [ "$fallback_case" = unresolved ]; then installer=uv; installer_rc=0; fi
      printf '#!/usr/bin/env bash\nexit %s\n' "$installer_rc" > "$nbin/$installer"
      chmod +x "$nbin/$installer"
      ;;
    user-hooks-path)
      nscope=user; hook_dir="$ntarget/native hooks"
      HOME="$pchome" git -C "$ntarget" config core.hooksPath 'native hooks'
      ;;
    skip) extra_flag=--skip-hooks ;;
  esac
  out=$(PATH="$nbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
    --profile core --scope "$nscope" --target "$ntarget" ${extra_flag:+"$extra_flag"} 2>&1) \
    || fail "HIMMEL-2771 $fallback_case: adoption failed: $out"
  if [ "$fallback_case" = skip ]; then
    [ ! -e "$hook_dir/commit-msg" ] || fail "HIMMEL-2771 skip: native hook placed"
  else
    for hook in commit-msg pre-commit pre-push; do
      [ -x "$hook_dir/$hook" ] || fail "HIMMEL-2771 $fallback_case: $hook absent"
    done
    printf 'test: HIMMEL-2771 [#2771] native gates\n' > "$ntarget/message"
    ( cd "$ntarget" && HOME="$pchome" bash "$hook_dir/commit-msg" "$ntarget/message" ) \
      || fail "HIMMEL-2771 $fallback_case: native message gate failed"
  fi
  echo "ok: HIMMEL-2771 $fallback_case"
done
echo "PASS"
