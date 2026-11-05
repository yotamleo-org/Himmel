#!/usr/bin/env bash
# test-adopt-features.sh — the native git-gate placement scenarios of the adopt.sh smoke tests.
# The adopt.sh smoke tests live in several suites so
# each stays well under the runner's per-suite time cap. Same fixture
# (scripts/lib/adopt-test-fixture.sh): stubs `claude` on PATH, throwaway temp
# dirs, a fake HOME.
#
# Covers the native git-gate placement scenarios: foreign, backed-up and symlinked
# hooks, the hooksPath refusals and the worktree default. The chained-hook,
# plugin-failure, provenance and wizard scenarios moved out so
# no shard is bounded by this one suite.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# install_native_hooks() must
# not clobber a pre-existing hand-written hook, must stay idempotent about
# its OWN generated hooks, and must refuse an absolute/shared core.hooksPath
# rather than write dispatcher hooks into it (they resolve $(git rev-parse
# --show-toplevel) at FIRE time, so a hooksPath shared by other repos would
# break commits there the instant this repo adopts).

# 1. An existing hand-written hook is preserved, not truncated.
crtarget1="$work/cr2771-foreign"; crbin1="$work/cr2771-foreign-bin"
mkdir -p "$crtarget1" "$crbin1"
HOME="$pchome" git -C "$crtarget1" init -q
mkdir -p "$crtarget1/.git/hooks"
foreign_hook_content='#!/usr/bin/env bash
echo "ADOPTER OWN HOOK -- do not clobber me"
'
printf '%s' "$foreign_hook_content" > "$crtarget1/.git/hooks/commit-msg"
chmod +x "$crtarget1/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin1:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR foreign-hook: adopt exited $rc: $out"
[ -x "$crtarget1/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR foreign-hook: native commit-msg hook absent"
grepq "$(cat "$crtarget1/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR foreign-hook: native hook was not written in place of the foreign one"
[ -f "$crtarget1/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR foreign-hook: no backup of the adopter's original hook"
diff <(printf '%s' "$foreign_hook_content") "$crtarget1/.git/hooks/commit-msg.himmel-backup" >/dev/null \
  || fail "HIMMEL-2771 CR foreign-hook: backup content does not match the original byte-for-byte"
grepq "$out" 'backed up to commit-msg.himmel-backup' \
  || fail "HIMMEL-2771 CR foreign-hook: missing the backup progress message"
echo "ok: HIMMEL-2771 CR foreign-hook is preserved as commit-msg.himmel-backup"

# 2. Idempotent re-adopt: running adopt TWICE on a clean target must not
# back up our own generated hook on the second run.
crtarget2="$work/cr2771-idempotent"; crbin2="$work/cr2771-idempotent-bin"
mkdir -p "$crtarget2" "$crbin2"
HOME="$pchome" git -C "$crtarget2" init -q
set +e
out=$(PATH="$crbin2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget2" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR idempotent (run 1): adopt exited $rc: $out"
[ -x "$crtarget2/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR idempotent (run 1): native hook absent"
[ ! -e "$crtarget2/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR idempotent (run 1): unexpected backup on a clean target"
set +e
out2=$(PATH="$crbin2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget2" 2>&1); rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "HIMMEL-2771 CR idempotent (run 2): adopt exited $rc2: $out2"
[ -x "$crtarget2/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR idempotent (run 2): native hook absent"
[ ! -e "$crtarget2/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR idempotent (run 2): re-adopt backed up its OWN previously-placed hook"
echo "ok: HIMMEL-2771 CR idempotent re-adopt creates no spurious backup"

# 3. An absolute/shared core.hooksPath OUTSIDE the target is refused, not
# written into -- this is the control that matters: asserting only the rc
# would not catch a write that happened before the refusal.
crtarget3="$work/cr2771-hookspath"; crbin3="$work/cr2771-hookspath-bin"
croutside3="$work/cr2771-hookspath-outside"
mkdir -p "$crtarget3" "$crbin3" "$croutside3"
HOME="$pchome" git -C "$crtarget3" init -q
HOME="$pchome" git -C "$crtarget3" config core.hooksPath "$croutside3"
set +e
out=$(PATH="$crbin3:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget3" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR hookspath-outside: adopt exited 0 with a shared/outside hooksPath"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR hookspath-outside: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR hookspath-outside: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside3" \
  || fail "HIMMEL-2771 CR hookspath-outside: a hook was written into the outside hooksPath dir"
echo "ok: HIMMEL-2771 CR hookspath-outside refuses to write into a shared/absolute hooksPath"

# 4. A pre-existing <hook>.himmel-backup is REFUSED, not overwritten. Silently
# clobbering it would destroy the adopter's real original -- the exact harm
# the backup exists to prevent -- so the only assertion that matters is that
# the prior backup survives byte-for-byte, not merely that adopt exited != 0.
crtarget4="$work/cr2771-backup-exists"; crbin4="$work/cr2771-backup-exists-bin"
mkdir -p "$crtarget4" "$crbin4"
HOME="$pchome" git -C "$crtarget4" init -q
mkdir -p "$crtarget4/.git/hooks"
prior_backup_content='#!/usr/bin/env bash
echo "THE ADOPTERS REAL ORIGINAL -- never destroy me"
'
printf '%s' "$foreign_hook_content" > "$crtarget4/.git/hooks/commit-msg"
chmod +x "$crtarget4/.git/hooks/commit-msg"
printf '%s' "$prior_backup_content" > "$crtarget4/.git/hooks/commit-msg.himmel-backup"
set +e
out=$(PATH="$crbin4:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget4" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR backup-exists: adopt exited 0 over an existing backup"
grepq "$out" 'already exists' \
  || fail "HIMMEL-2771 CR backup-exists: FAILED line does not name the existing backup"
diff <(printf '%s' "$prior_backup_content") "$crtarget4/.git/hooks/commit-msg.himmel-backup" >/dev/null \
  || fail "HIMMEL-2771 CR backup-exists: the adopter's prior backup was overwritten"
echo "ok: HIMMEL-2771 CR backup-exists refuses rather than destroying the prior backup"

# 5. A RELATIVE --target still gates. install_native_hooks() compares the
# resolved hooks dir against $TARGET, and --target is taken verbatim (never
# canonicalised at parse time), so a relative one reaches that comparison
# unanchored -- this is the end-to-end control over that path.
crrelbase="$work/cr2771-relbase"; crbin5="$work/cr2771-relbase-bin"
mkdir -p "$crrelbase/reltarget" "$crbin5"
HOME="$pchome" git -C "$crrelbase/reltarget" init -q
set +e
out=$( cd "$crrelbase" && PATH="$crbin5:$work/bin:$native_free_path" HOME="$pchome" \
  bash "$adopt" --profile core --scope project --target reltarget 2>&1 ); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR relative-target: adopt exited $rc: $out"
[ -x "$crrelbase/reltarget/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR relative-target: native commit-msg hook absent"
grepq "$(cat "$crrelbase/reltarget/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR relative-target: hook is not the native gate"
echo "ok: HIMMEL-2771 CR relative-target still places the native gate"

# _native_hooks_canon() used LOGICAL
# cd+pwd, so a core.hooksPath pointing at a path INSIDE the target that is
# itself a symlink to a directory OUTSIDE it was accepted as "inside" and the
# adopter wrote hooks THROUGH the symlink into the outside directory -- the
# exact shared-hooks-directory escape the round-1 containment check exists to
# prevent. Asserting only the rc would not catch a write that happened before
# the refusal, so assert the outside directory stays empty.
crtarget6="$work/cr2771r2-symlink"; crbin6="$work/cr2771r2-symlink-bin"
croutside6="$work/cr2771r2-symlink-outside"
mkdir -p "$crtarget6" "$crbin6" "$croutside6"
HOME="$pchome" git -C "$crtarget6" init -q
ln -s "$croutside6" "$crtarget6/hookslink"
HOME="$pchome" git -C "$crtarget6" config core.hooksPath hookslink
set +e
out=$(PATH="$crbin6:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget6" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR2 symlink-escape: adopt exited 0 with a hooksPath symlinked outside the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR2 symlink-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR2 symlink-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside6" \
  || fail "HIMMEL-2771 CR2 symlink-escape: a hook was written through the symlink into the outside dir"
echo "ok: HIMMEL-2771 CR2 symlink-escape refuses a hooksPath symlinked outside the target"

# _native_hooks_canon()'s walk-up reattaches
# the not-yet-existing tail of a hooksPath UNCHANGED, so a tail containing ".."
# was never folded -- the containment check then compared a string that still
# held "..", which `mkdir -p` resolves past $TARGET. A hooksPath shaped like
# "new/../../<outside>" reaches this: "new" does not exist, so the walk-up
# strips the whole tail back to the target and reattaches it verbatim. As with
# the round-2 symlink-escape control above, asserting only the rc would not
# catch a write that happened before the refusal, so assert the outside
# directory stays empty.
crtarget10="$work/cr2771r3-dotdot"; crbin10="$work/cr2771r3-dotdot-bin"
croutside10="$work/cr2771r3-dotdot-outside"
mkdir -p "$crtarget10" "$crbin10" "$croutside10"
HOME="$pchome" git -C "$crtarget10" init -q
HOME="$pchome" git -C "$crtarget10" config core.hooksPath 'new/../../cr2771r3-dotdot-outside'
set +e
out=$(PATH="$crbin10:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget10" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR3 dotdot-escape: adopt exited 0 with an unfolded ../.. hooksPath escaping the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR3 dotdot-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR3 dotdot-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside10" \
  || fail "HIMMEL-2771 CR3 dotdot-escape: a hook was written through the unfolded ../.. into the outside dir"
echo "ok: HIMMEL-2771 CR3 dotdot-escape refuses a hooksPath whose unfolded ../.. tail escapes the target"

# folding "." and ".." out of the
# not-yet-existing tail (the round-3 fix above) can RE-EXPOSE a symlink the
# walk-up never looked at. A hooksPath shaped "new/../hookslink" -- "new"
# absent, "hookslink" a symlink INSIDE the target pointing OUTSIDE it --
# reaches this: the walk-up strips the whole tail back to the target without
# ever seeing "hookslink" (it does not exist as a path component until the
# ".." fold puts it directly under the target), then the fold reattaches
# "hookslink" as a plain string that nothing ever resolves, so the
# containment check compares a string that never followed the symlink. As
# with the round-2 and round-3 controls above, asserting only the rc would
# not catch a write that happened before the refusal, so assert the outside
# directory stays empty.
crtarget11="$work/cr2771r4-dotdot-symlink"; crbin11="$work/cr2771r4-dotdot-symlink-bin"
croutside11="$work/cr2771r4-dotdot-symlink-outside"
mkdir -p "$crtarget11" "$crbin11" "$croutside11"
HOME="$pchome" git -C "$crtarget11" init -q
ln -s "$croutside11" "$crtarget11/hookslink"
HOME="$pchome" git -C "$crtarget11" config core.hooksPath 'new/../hookslink'
set +e
out=$(PATH="$crbin11:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget11" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: adopt exited 0 with a folded ../<symlink> hooksPath escaping the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside11" \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: a hook was written through the re-exposed symlink into the outside dir"
echo "ok: HIMMEL-2771 CR4 dotdot-symlink-escape refuses a hooksPath whose ../ fold re-exposes a symlink out of the target"

# The containment check above
# refused an ORDINARY linked worktree outright -- its default hooks dir lives
# in the PRIMARY checkout's common git dir, outside $TARGET, with
# core.hooksPath UNSET (not misconfigured -- this is Git's own default
# layout, and himmel's own workflow mandates worktrees). Prove this on a real
# linked worktree: `git worktree add` needs a real HEAD, so commit
# --allow-empty first (same user.name/user.email/-c commit.gpgsign=false
# idiom as the push-block control above). RED against the pre-fix code =
# adopt exits 1 with the core.hooksPath FAILED line, naming a setting that
# was never set.
crprimary12="$work/cr2771r5-worktree-primary"; crwt12="$work/cr2771r5-worktree-wt"
crbin12="$work/cr2771r5-worktree-bin"
mkdir -p "$crprimary12" "$crbin12"
HOME="$pchome" git -C "$crprimary12" init -q
HOME="$pchome" git -C "$crprimary12" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimary12" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimary12" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] worktree-default primary commit'
HOME="$pchome" git -C "$crprimary12" worktree add -q "$crwt12" -b cr2771r5-worktree-branch
effective_hooks_dir12=$(HOME="$pchome" git -C "$crwt12" rev-parse --git-path hooks)
case "$effective_hooks_dir12" in
  /*) : ;;
  *) effective_hooks_dir12="$crwt12/$effective_hooks_dir12" ;;
esac
set +e
out=$(PATH="$crbin12:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crwt12" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 worktree-default: adopt exited $rc on an ordinary linked worktree with core.hooksPath unset: $out"
grepq "$out" 'git gate hooks — placed (native' \
  || fail "HIMMEL-2771 CR5 worktree-default: missing the native placed summary line: $out"
for hook in commit-msg pre-commit pre-push; do
  [ -x "$effective_hooks_dir12/$hook" ] \
    || fail "HIMMEL-2771 CR5 worktree-default: $hook absent/non-executable in the worktree's effective hooks dir ($effective_hooks_dir12)"
done
echo "ok: HIMMEL-2771 CR5 worktree-default: adopt gates an ordinary linked worktree with core.hooksPath unset"

# The directory-level containment
# check cannot see a per-file SYMLINK escape -- $hooks_dir itself is
# legitimately inside the target; it is this one directory ENTRY that
# escapes. Shape (a): a DANGLING symlink at $hooks_dir/commit-msg bypasses the
# `-e` backup-need test entirely (a dangling symlink is not `-e`), so the
# subsequent `cat >` follows the link and creates a file OUTSIDE $TARGET. As
# with the containment controls above, asserting only rc would not catch a
# write that happened before/during the escape, so assert the outside
# directory stays empty AND that the hooks-dir entry is now a genuine regular
# file (not still a symlink) carrying the marker.
crtarget13="$work/cr2771r5-symlink-dangling"; crbin13="$work/cr2771r5-symlink-dangling-bin"
croutside13="$work/cr2771r5-symlink-dangling-outside"
mkdir -p "$crtarget13" "$crbin13" "$croutside13"
HOME="$pchome" git -C "$crtarget13" init -q
mkdir -p "$crtarget13/.git/hooks"
ln -s "$croutside13/pwned" "$crtarget13/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin13:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget13" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: adopt exited $rc: $out"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside13" \
  || fail "HIMMEL-2771 CR5 symlink-dangling: a file was created outside the target through the dangling symlink"
[ -f "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is not a regular file after adopt"
[ ! -L "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is still a symlink after adopt"
grepq "$(cat "$crtarget13/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR5 symlink-dangling: replacement entry is not the native gate"
echo "ok: HIMMEL-2771 CR5 symlink-dangling: a dangling hook symlink is backed up (not followed) and replaced with a real file"

# shape (b) -- a symlink at
# $hooks_dir/commit-msg pointing at an OUTSIDE file that already carries our
# marker made the marker check (`grep -qF`, which follows the link) look like
# "already ours" and skip the backup, so the subsequent `cat >` truncated a
# file OUTSIDE $TARGET. Assert the outside file survives byte-for-byte (its
# distinctive sentinel line, not just its existence) and that the hooks-dir
# entry is now a genuine regular file.
crtarget14="$work/cr2771r5-symlink-marker"; crbin14="$work/cr2771r5-symlink-marker-bin"
croutside14="$work/cr2771r5-symlink-marker-outside.sh"
mkdir -p "$crtarget14" "$crbin14"
HOME="$pchome" git -C "$crtarget14" init -q
mkdir -p "$crtarget14/.git/hooks"
sentinel14='echo "SENTINEL cr2771r5-symlink-marker: outside file must not be truncated"'
markerline14='# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.'
cat > "$croutside14" <<OUTSIDEHOOK
#!/usr/bin/env bash
$markerline14
$sentinel14
OUTSIDEHOOK
chmod +x "$croutside14"
ln -s "$croutside14" "$crtarget14/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin14:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget14" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: adopt exited $rc: $out"
grepq "$(cat "$croutside14")" -F "$sentinel14" \
  || fail "HIMMEL-2771 CR5 symlink-marker: outside file was truncated (sentinel line missing)"
[ -f "$crtarget14/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: hooks-dir entry is not a regular file after adopt"
[ ! -L "$crtarget14/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: hooks-dir entry is still a symlink after adopt"
echo "ok: HIMMEL-2771 CR5 symlink-marker: a symlink to a marker-bearing outside file is backed up (not followed) and replaced with a real file"

# The earlier fix above teaches
# adopt to ACCEPT the shared Git common-directory hooks layout, but the
# payload (scripts/hooks/*.sh + guardrails/lib.sh) was copied only into
# $TARGET (the linked worktree). Git's hooks are per-REPOSITORY, not
# per-worktree, so that one hooks dir also serves the PRIMARY checkout (and
# any sibling worktree) -- neither of which received a payload. Their shared
# dispatcher resolves `$root/scripts/hooks/<script>` against ITS OWN
# toplevel (the primary, not the adopted worktree), finds nothing, and every
# commit/push there starts failing with a bash "No such file or directory"
# error -- an earlier version traded a false refusal for a real breakage of a checkout
# the adopter never named. Drive the PRIMARY's own commit-msg dispatcher
# directly rather than `git commit`: the pre-commit dispatcher fires too on
# a real commit, and check-worktree-isolation.sh legitimately refuses
# commits on the primary's default branch, which would make RED and GREEN
# indistinguishable (both would fail).
#
# The cwd trap: the dispatcher does `root=$(git rev-parse --show-toplevel)`.
# Git sets cwd to the repo toplevel when IT fires a hook, but here the hook
# is invoked by hand, so an un-pinned cwd would still be THIS himmel
# worktree -- which DOES carry scripts/hooks/check-commit-msg.sh -- and the
# control would pass against the broken code for the wrong reason. Pin cwd
# to the primary with a subshell.
crprimary15="$work/cr2771r6-worktree-primary"; crwt15="$work/cr2771r6-worktree-wt"
crbin15="$work/cr2771r6-worktree-bin"
mkdir -p "$crprimary15" "$crbin15"
HOME="$pchome" git -C "$crprimary15" init -q
HOME="$pchome" git -C "$crprimary15" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimary15" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimary15" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] worktree-primary-gate primary commit'
HOME="$pchome" git -C "$crprimary15" worktree add -q "$crwt15" -b cr2771r6-worktree-branch
set +e
out=$(PATH="$crbin15:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crwt15" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: adopt exited $rc against the linked worktree: $out"

msgfile15="$work/cr2771r6-valid.msg"
printf 'test: HIMMEL-2771 [#2771] worktree-primary-gate valid message\n' > "$msgfile15"
set +e
pout15=$( cd "$crprimary15" && HOME="$pchome" bash .git/hooks/commit-msg "$msgfile15" 2>&1 ); prc15=$?
set -e
[ "$prc15" -eq 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: PRIMARY's commit-msg dispatcher rejected a valid ticketed message (rc=$prc15): $pout15"
grepq "$pout15" 'No such file or directory' \
  && fail "HIMMEL-2771 CR6 worktree-primary-gate: PRIMARY's dispatcher hit the missing-script error: $pout15"

msgfile15b="$work/cr2771r6-noticket.msg"
printf 'no ticket here at all\n' > "$msgfile15b"
set +e
pout15b=$( cd "$crprimary15" && HOME="$pchome" bash .git/hooks/commit-msg "$msgfile15b" 2>&1 ); prc15b=$?
set -e
[ "$prc15b" -ne 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: an unticketed message exited 0 in the PRIMARY -- the gate did not actually run: $pout15b"
echo "ok: HIMMEL-2771 CR6 worktree-primary-gate: the PRIMARY checkout's shared dispatcher finds its payload copy and genuinely gates"

# direct self-test of
# dir_is_empty itself, because every containment control above -- including
# the round-5 cr2771r5-symlink-dangling control, whose whole SUBJECT is a
# dangling symlink -- trusts this helper's verdict. `[ -e "$f" ]` alone
# follows a symlink to test its TARGET, so a dangling symlink is `-e` false
# and was silently skipped: if the escape those controls guard against ever
# landed as a dangling link, this helper would report the directory empty
# while the escape happened. RED against the pre-fix helper = it reports the
# dangling-symlink directory empty.
cr2771r6dirempty="$work/cr2771r6-dir-is-empty-dangling"
# Two SEPARATE directories, not one shared parent: a dangling symlink sitting
# alongside a genuinely-existing entry (e.g. the plain-empty dir itself) would
# still make the parent report non-empty via that OTHER entry, masking the
# very bug this control exists to catch. The dangling-holder directory must
# contain the dangling symlink and NOTHING else.
mkdir -p "$cr2771r6dirempty/dangling-holder" "$cr2771r6dirempty/plain-empty"
ln -s "$cr2771r6dirempty/plain-empty/nonexistent-target" "$cr2771r6dirempty/dangling-holder/dangling"
if dir_is_empty "$cr2771r6dirempty/dangling-holder"; then
  fail "HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty reported a directory containing only a dangling symlink as empty"
fi
dir_is_empty "$cr2771r6dirempty/plain-empty" \
  || fail "HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty reported a genuinely empty directory as non-empty"
echo "ok: HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty sees a dangling symlink as an occupied entry and a genuinely empty dir as empty"

# An adopter with no OpenRouter key searches on qmd's local models, so wire_qmd_core
# checks the local reranker model is really in the cache after `qmd pull`, and says so when it is not
# (or when QMD_RERANK turns the reranker off). The stub qmd's `pull` fabricates the model file under the
# fake HOME only when RR_STUB_MODEL=1; the file name is the one the real station keeps in ~/.cache/qmd/models.
rrbin="$work/rr9265-bin"; mkdir -p "$rrbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$rrbin/bun"
cat > "$rrbin/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "pull" ] && [ "${RR_STUB_MODEL:-0}" = "1" ]; then
  mkdir -p "$HOME/.cache/qmd/models"
  : > "$HOME/.cache/qmd/models/hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf"
fi
exit 0
STUB
cat > "$rrbin/git" <<STUB
#!/usr/bin/env bash
[ "\$1" = "clone" ] && exit 1
exec "$(command -v git)" "\$@"
STUB
chmod +x "$rrbin/bun" "$rrbin/qmd" "$rrbin/git"
rr_run() {
  # rr_run <tag> <1 when the stub pull fabricates the model, else 0> [QMD_RERANK value]
  local tag="$1" stub_model="$2" rerank_val="${3:-}"
  local h="$work/rr9265-home-$tag" t="$work/rr9265-target-$tag"
  rm -rf "${h:?}" "${t:?}"; mkdir -p "$h" "$t"
  HOME="$h" git -C "$t" init -q
  set +e
  rr_out=$( unset QMD_RERANK QMD_RERANK_MODEL XDG_CACHE_HOME XDG_CONFIG_HOME QMD_CONFIG_DIR; export RR_STUB_MODEL="$stub_model"
    [ -z "$rerank_val" ] || export QMD_RERANK="$rerank_val"
    PATH="$rrbin:$work/bin:$native_free_path" HOME="$h" bash "$adopt" \
    --profile core --scope project --target "$t" 2>&1 ); rr_rc=$?
  set -e
}
rr_run nomodel 0
[ "$rr_rc" -eq 0 ] || fail "HIMMEL-9265 no-model: adopt exited $rr_rc: $rr_out"
grepq "$rr_out" -E 'WARNING.*no local reranker model' \
  || fail "HIMMEL-9265 no-model: no WARNING that the local reranker model is missing: $rr_out"
grepq "$rr_out" -F 'Pull it: qmd pull' \
  || fail "HIMMEL-9265 no-model: the WARNING carries no remedy line: $rr_out"
echo "ok: HIMMEL-9265 a pull that leaves no reranker model WARNs and adopt still exits 0"
rr_run model 1
[ "$rr_rc" -eq 0 ] || fail "HIMMEL-9265 model: adopt exited $rr_rc: $rr_out"
grepq "$rr_out" -F 'qmd rerank: local reranker model present' \
  || fail "HIMMEL-9265 model: missing the local reranker present line: $rr_out"
grepq "$rr_out" -E 'no local reranker model|QMD_RERANK' \
  && fail "HIMMEL-9265 model: control warned although the reranker model is present: $rr_out"
echo "ok: HIMMEL-9265 control: a reranker model in the cache gives no WARNING"
rr_run off 1 off
[ "$rr_rc" -eq 0 ] || fail "HIMMEL-9265 off: adopt exited $rr_rc: $rr_out"
grepq "$rr_out" -E 'WARNING.*QMD_RERANK=off' \
  || fail "HIMMEL-9265 off: no WARNING that QMD_RERANK=off disables the reranker: $rr_out"
echo "ok: HIMMEL-9265 QMD_RERANK=off in the adopter's environment WARNs"
rr_dry_t="$work/rr9265-dry"; mkdir -p "$rr_dry_t"; HOME="$work/rr9265-home-dry" git -C "$rr_dry_t" init -q 2>/dev/null || git -C "$rr_dry_t" init -q
set +e
rr_out=$(PATH="$rrbin:$work/bin:$native_free_path" HOME="$work/rr9265-home-dry" bash "$adopt" \
  --profile core --scope project --target "$rr_dry_t" --dry-run 2>&1); rr_rc=$?
set -e
[ "$rr_rc" -eq 0 ] || fail "HIMMEL-9265 dry-run: adopt exited $rr_rc: $rr_out"
grepq "$rr_out" -F 'DRY: verify the qmd reranker' || fail "HIMMEL-9265 dry-run: missing the reranker DRY line: $rr_out"
echo "ok: HIMMEL-9265 dry-run names the reranker check"

echo "PASS"
