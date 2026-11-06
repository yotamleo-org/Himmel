#!/usr/bin/env bash
# test-adopt-provenance.sh — the settings merge and the provenance ledger scenarios.
# The adopt.sh smoke tests live in several suites so
# each stays well under the runner's per-suite time cap. Same fixture
# (scripts/lib/adopt-test-fixture.sh): stubs `claude` on PATH, throwaway temp
# dirs, a fake HOME.
#
# Covers the settings.json hook-block merge and the provenance ledger rows that
# adopt.sh records, split from scripts/test-adopt-features.sh.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# ── 21. the hook block MERGES into an existing settings.json ────
# Regression control for the 2026-09-09 dogfood incident: `himmelctl install
# --scope project` inside a repo whose .claude/settings.json already carried a
# hand-curated hook block REGENERATED that block from the manifest (98+/38-):
# foreign matchers dropped, a himmel matcher collapsed to the canonical string,
# adopter timeouts reset 60 -> 15, ordering shuffled. Ownership rule this
# asserts: himmel owns ONLY the `command` string of an entry it installed
# (so a moved clone / broken backslash path is still repaired in place —
# section 9 above). The adopter owns everything else — the stanza's `matcher`,
# its POSITION in the array, the entry's `timeout`, and every foreign matcher
# or co-located foreign entry, all of which must survive byte-for-byte.
p2892="$work/proj-2892"; mkdir -p "$p2892/.claude"
cat > "$p2892/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"WebFetch|WebSearch","hooks":[{"type":"command","command":"bash \"/opt/foreign/hooks/foreign-guard.sh\"","timeout":90}]},
      {"matcher":"Edit|Write|MultiEdit|NotebookEdit|PowerShell","hooks":[
        {"type":"command","command":"bash \"/old/clone/scripts/hooks/block-edit-on-main.sh\"","timeout":60},
        {"type":"command","command":"bash \"/opt/foreign/hooks/co-located.sh\"","timeout":45}
      ]}
    ]
  }
}
JSON
cp "$p2892/.claude/settings.json" "$work/2892-seed.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$p2892" >/dev/null
s2892="$p2892/.claude/settings.json"

# (a) the foreign matcher stanza survives byte-for-byte, at index 0.
before_a=$(jq -Sc '.hooks.PreToolUse[0]' "$work/2892-seed.json")
after_a=$(jq -Sc '.hooks.PreToolUse[0]' "$s2892")
[ "$before_a" = "$after_a" ] \
  || fail "HIMMEL-2892 (a): the foreign PreToolUse stanza was not preserved byte-for-byte at its original index — before=$before_a after=$after_a"

# (b) the foreign entry co-located under a himmel-owned matcher survives
#     byte-for-byte, still the SECOND entry of that stanza.
before_b=$(jq -Sc '.hooks.PreToolUse[1].hooks[1]' "$work/2892-seed.json")
after_b=$(jq -Sc '.hooks.PreToolUse[1].hooks[1]' "$s2892")
[ "$before_b" = "$after_b" ] \
  || fail "HIMMEL-2892 (b): the co-located foreign hook entry was not preserved byte-for-byte in place — before=$before_b after=$after_b"

# (c) the himmel-owned entry is UPDATED IN PLACE, not regenerated: adopter's
#     matcher kept (never collapsed to the canonical string), adopter's timeout
#     kept, only the command repointed at this install's prefix.
[ "$(jq -r '.hooks.PreToolUse[1].matcher' "$s2892")" = "Edit|Write|MultiEdit|NotebookEdit|PowerShell" ] \
  || fail "HIMMEL-2892 (c): the adopter's matcher was collapsed to the canonical one (got: $(jq -r '.hooks.PreToolUse[1].matcher' "$s2892"))"
[ "$(jq -r '.hooks.PreToolUse[1].hooks[0].timeout' "$s2892")" = "60" ] \
  || fail "HIMMEL-2892 (c): the adopter's timeout was reset (got: $(jq -r '.hooks.PreToolUse[1].hooks[0].timeout' "$s2892"))"
c2892=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$s2892")
# shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR (the project-scope prefix), not an expansion
# the wired command now guards a missing script (if [ -f ]; then
# bash "..."; else warn+exit 0; fi) instead of a bare bash "...".
case "$c2892" in
  'if [ -f "$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh" ]; then bash "$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh"; else echo "himmel: hook script missing ($CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh) -- re-run the install (himmelctl install) or unwire it (himmelctl uninstall)" >&2; exit 0; fi') : ;;
  *) fail "HIMMEL-2892 (c): the himmel-owned command was not repointed at this install's prefix (got: $c2892)" ;;
esac

# (d) exactly ONE block-edit-on-main entry (merged in place, not appended
#     alongside the existing one), and the two hooks that were genuinely ABSENT
#     and the merge gate are appended as fresh stanzas -> 2 seeded + 3 appended = 5.
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s2892")" = "1" ] \
  || fail "HIMMEL-2892 (d): expected exactly one block-edit-on-main entry after the merge"
[ "$(jq '.hooks.PreToolUse | length' "$s2892")" = "5" ] \
  || fail "HIMMEL-2892 (d): expected 5 PreToolUse stanzas (2 seeded + the 3 genuinely-absent himmel hooks appended), got $(jq '.hooks.PreToolUse | length' "$s2892")"
echo "ok: HIMMEL-2892 the hook block merges into an existing settings.json (foreign matcher + co-located entry + adopter matcher/timeout preserved; himmel command repointed in place)"

# ── 19x. copy_portable + the user-scope gate copies record what
# they overwrite. Every copy into the adopter's tree is one `file` row in the
# install-provenance ledger; an OVERWRITE keeps the user's bytes (and mode) in a
# backup, so uninstall can put them back (a same-named user file was
# silently gone at install time). Scratch HOME + scratch ledger throughout.
prov_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
prov_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# prov_row <ledger> <path-suffix> — the newest `file` row whose path ends in <suffix>
prov_row() { jq -c --arg s "$2" 'select(.kind=="file" and (.path|endswith($s)))' "$1" | tail -n 1; }

p4home="$work/p4-home"; mkdir -p "$p4home"
p4led="$work/p4-ledger"
p4proj="$work/p4-proj"; mkdir -p "$p4proj/scripts"
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p4proj/scripts/worktree.sh"
chmod 0755 "$p4proj/scripts/worktree.sh"
p4seed_sha="$(prov_sha "$p4proj/scripts/worktree.sh")"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4proj" >/dev/null
[ -s "$p4led/provenance.jsonl" ] || fail "HIMMEL-3332 S4: copy_portable wrote no ledger"
row="$(prov_row "$p4led/provenance.jsonl" /scripts/worktree.sh)"
[ -n "$row" ] || fail "HIMMEL-3332 S4: no file row for the overwritten scripts/worktree.sh"
[ "$(jq -r '[.op,.class,.scope,.manifest_row,.pre.state,.pre.sha,.pre.mode]|join(",")' <<< "$row")" = "replace,code,project,adopter-scripts,present,$p4seed_sha,0755" ] \
  || fail "HIMMEL-3332 S4: overwritten worktree.sh row wrong: $row"
p4bk="$(jq -r '.pre.backup' <<< "$row")"
[ "$([ -f "$p4bk" ] && prov_sha "$p4bk")" = "$p4seed_sha" ] \
  || fail "HIMMEL-3332 S4: the backup is missing or is not the user's original bytes ($p4bk)"
[ "$(prov_mode "$p4bk")" = "755" ] || fail "HIMMEL-3332 S4: the backup lost the user's mode"
[ "$(jq -r '.post.sha' <<< "$row")" = "$(prov_sha "$repo_root/scripts/worktree.sh")" ] \
  || fail "HIMMEL-3332 S4: post.sha is not the himmel copy's sha"
row="$(prov_row "$p4led/provenance.jsonl" /scripts/hooks/block-edit-on-main.sh)"
[ "$(jq -r '[.op,.pre.state,.class]|join(",")' <<< "$row")" = "create,absent,code" ] \
  || fail "HIMMEL-3332 S4: a copy into a clean target must be a create row: $row"
[ "$(jq -sr '[.[]|select(.kind=="file" and .manifest_row=="adopter-scripts")]|length' "$p4led/provenance.jsonl")" = "99" ] \
  || fail "S4: expected 99 file rows (98 portable entries plus the trust policy seed)"
echo "ok: HIMMEL-3332 S4 copy_portable records create + replace rows; the user's bytes and mode are backed up"

# a re-run finds our own bytes already there: noop rows, and NO new backups
p4bk_count="$(find "$p4led/provenance-backups" -type f | wc -l | tr -d ' ')"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4proj" >/dev/null
row="$(prov_row "$p4led/provenance.jsonl" /scripts/worktree.sh)"
[ "$(jq -r '[.op,.pre.sha,(.pre.backup|tostring)]|join(",")' <<< "$row")" = "noop,$(jq -r .post.sha <<< "$row"),null" ] \
  || fail "HIMMEL-3332 S4: a re-run over our own copy must record noop with no backup: $row"
[ "$(find "$p4led/provenance-backups" -type f | wc -l | tr -d ' ')" = "$p4bk_count" ] \
  || fail "HIMMEL-3332 S4: a noop re-run must not take another backup"
echo "ok: HIMMEL-3332 S4 re-run records noop, takes no backup"

# --dry-run writes nothing to the ledger and says what it would record
p4dry="$work/p4-dry"; mkdir -p "$p4dry"
p4lines="$(wc -l < "$p4led/provenance.jsonl" | tr -d ' ')"
out=$(HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4dry" --dry-run 2>&1)
[ "$(wc -l < "$p4led/provenance.jsonl" | tr -d ' ')" = "$p4lines" ] || fail "HIMMEL-3332 S4: --dry-run appended to the ledger"
grepq "$out" 'DRY: record create file' || fail "HIMMEL-3332 S4: --dry-run did not say what it would record: $out"
[ ! -e "$p4dry/scripts/worktree.sh" ] || fail "HIMMEL-3332 S4: --dry-run copied a file"
echo "ok: HIMMEL-3332 S4 --dry-run records nothing"

# ── adopt never overwrites a file it cannot back up, and reports every replace.
p6home="$work/p6-home"; mkdir -p "$p6home"
p6led="$work/p6-ledger"
p6proj="$work/p6-proj"; mkdir -p "$p6proj/scripts"
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p6proj/scripts/worktree.sh"
chmod 0755 "$p6proj/scripts/worktree.sh"
p6sha="$(prov_sha "$p6proj/scripts/worktree.sh")"
# a mktemp that fails only for the copy_recorded snapshot template
p6bin="$work/p6-bin"; mkdir -p "$p6bin"
# shellcheck disable=SC2016 # the stub's $1 and $@ must stay literal
printf '#!/bin/sh\ncase "${1:-}" in */adopt-copy.XXXXXX) exit 1;; esac\nPATH="${PATH#*:}" exec mktemp "$@"\n' > "$p6bin/mktemp"
chmod +x "$p6bin/mktemp"
set +e
out=$(PATH="$p6bin:$PATH" HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-6321: adopt exited 0 although it could not back up an existing file: $out"
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] \
  || fail "HIMMEL-6321: the user's worktree.sh was overwritten although the snapshot failed"
grepq "$out" 'not replaced.*scripts/worktree.sh' \
  || fail "HIMMEL-6321: the refused file is not listed: $out"
echo "ok: HIMMEL-6321 a failed snapshot leaves the user's file untouched, lists it, exits non-zero"

# a cp that truncates the destination and then fails (disk full, EIO): the user's file is restored from the snapshot
p6cp="$work/p6-cp-bin"; mkdir -p "$p6cp"
# shellcheck disable=SC2016 # the stub's $# and $@ must stay literal
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in */p6-proj/scripts/worktree.sh) [ "$#" -eq 2 ] && { : > "$last"; exit 1; };; esac\nPATH="${PATH#*:}" cp "$@"\n' > "$p6cp/cp"
chmod +x "$p6cp/cp"
set +e
out=$(PATH="$p6cp:$PATH" HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1); rc=$?
set -e
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] \
  || fail "HIMMEL-6356: a failed copy left the user's worktree.sh truncated: $out"
[ "$rc" -ne 0 ] || fail "HIMMEL-6356: adopt exited 0 although a copy failed: $out"
grepq "$out" 'not replaced.*scripts/worktree.sh' \
  || fail "HIMMEL-6356: the file whose copy failed is not listed: $out"
echo "ok: HIMMEL-6356 a failed copy restores the user's file from the snapshot, lists it, exits non-zero"

# a normal replace names the file and its backup; the backup holds the user's original bytes
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1)
p6bk="$(jq -r '.pre.backup' <<< "$(prov_row "$p6led/provenance.jsonl" /scripts/worktree.sh)")"
grepq "$out" "replaced scripts/worktree.sh (backed up to $p6bk)" \
  || fail "HIMMEL-6321: a replace must print the file and its backup path ($p6bk): $out"
[ "$(prov_sha "$p6bk")" = "$p6sha" ] || fail "HIMMEL-6321: the backup is not the user's original bytes"
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1)
! grepq "$out" 'replaced scripts/worktree.sh' || fail "HIMMEL-6321: a noop re-run must not report a replace: $out"
echo "ok: HIMMEL-6321 a replace prints the file and its backup path; a re-run is silent"

# --dry-run says what it would replace
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p6proj/scripts/worktree.sh"
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" --dry-run 2>&1)
grepq "$out" 'would replace scripts/worktree.sh (backed up to ' \
  || fail "HIMMEL-6321: --dry-run must say 'would replace X (backed up to ...)': $out"
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] || fail "HIMMEL-6321: --dry-run changed the file"
echo "ok: HIMMEL-6321 --dry-run reports would-replace"

# P6: the user-scope gate copies (install_native_hooks) go through the same path
p4gate="$work/p4-gate"; mkdir -p "$p4gate/scripts/hooks"
HOME="$p4home" git -C "$p4gate" init -q
printf '#!/bin/sh\necho user-owned gate\n' > "$p4gate/scripts/hooks/check-commit-msg.sh"
p4gate_sha="$(prov_sha "$p4gate/scripts/hooks/check-commit-msg.sh")"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" PATH="$work/bin:$native_free_path" \
  bash "$adopt" --profile core --scope user --target "$p4gate" >/dev/null
row="$(prov_row "$p4led/provenance.jsonl" "$p4gate/scripts/hooks/check-commit-msg.sh")"
[ "$(jq -r '[.op,.class,.manifest_row,.pre.sha]|join(",")' <<< "$row")" = "replace,code,adopter-scripts,$p4gate_sha" ] \
  || fail "HIMMEL-3332 S4: user-scope gate copy over a user file must record a replace row: $row"
[ "$(prov_sha "$(jq -r '.pre.backup' <<< "$row")")" = "$p4gate_sha" ] \
  || fail "HIMMEL-3332 S4: the user-scope gate copy's backup is not the user's original bytes"
row="$(prov_row "$p4led/provenance.jsonl" "$p4gate/scripts/guardrails/lib.sh")"
[ "$(jq -r '[.op,.pre.state]|join(",")' <<< "$row")" = "create,absent" ] \
  || fail "HIMMEL-3332 S4: a fresh user-scope gate copy must be a create row: $row"
echo "ok: HIMMEL-3332 S4 user-scope gate copies record create + replace rows with a backup"

# class 5: the native git hooks, the adopter's displaced hook and
# the shared-dir payload are all written into the repo, so each gets a ledger
# row (the VM round trip's no-unrecorded-write check reads these); uninstall
# [5/8] still removes/restores them from the manifest, not from these rows.
p4gh="$work/p4-gh"; mkdir -p "$p4gh"
HOME="$p4home" git -C "$p4gh" init -q
mkdir -p "$p4gh/.git/hooks"
printf '#!/bin/sh\necho adopter pre-commit\n' > "$p4gh/.git/hooks/pre-commit"; chmod +x "$p4gh/.git/hooks/pre-commit"
p4gh_sha="$(prov_sha "$p4gh/.git/hooks/pre-commit")"
p4ghled="$work/p4-gh-ledger"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4ghled" PATH="$work/bin:$native_free_path" \
  bash "$adopt" --profile core --scope project --target "$p4gh" >/dev/null
for h in commit-msg pre-push; do
  row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/$h")"
  [ "$(jq -r '[.op,.pre.state,.manifest_row,.scope,.class]|join(",")' <<< "$row")" = "create,absent,git-hooks,project,code" ] \
    || fail "HIMMEL-3541: a fresh native $h hook must be a create row on git-hooks: $row"
done
row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/pre-commit")"
[ "$(jq -r '[.op,.pre.sha,.manifest_row]|join(",")' <<< "$row")" = "replace,$p4gh_sha,git-hooks" ] \
  || fail "HIMMEL-3541: a native hook over the adopter's own must be a replace row naming its bytes: $row"
row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/pre-commit.himmel-backup")"
[ "$(jq -r '[.op,.pre.state,.post.sha,.manifest_row]|join(",")' <<< "$row")" = "create,absent,$p4gh_sha,git-hook-backups" ] \
  || fail "HIMMEL-3541: the displaced hook's backup must be a create row on git-hook-backups: $row"
row="$(jq -c 'select(.kind=="tree" and (.path|endswith("/.git/hooks/himmel-payload")))' "$p4ghled/provenance.jsonl" | tail -n 1)"
[ "$(jq -r '[.op,.pre.state,.manifest_row]|join(",")' <<< "$row")" = "create,absent,git-hooks" ] \
  || fail "HIMMEL-3541: the shared-dir hook payload must be a tree create row: $row"
echo "ok: HIMMEL-3541 native git hooks, the displaced hook and the payload are ledger rows"

# wire_handover_dir_luna skips a HANDOVER_DIR the operator already chose;
# the ledger must say the key was theirs, or uninstall removes it anyway.
p4hd="$work/p4-hd"; mkdir -p "$p4hd/.claude"
printf '%s' '{"env":{"HANDOVER_DIR":"/some/operator/chosen/handovers"}}' > "$p4hd/.claude/settings.json"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile luna --target "$p4hd" >/dev/null
row="$(jq -c 'select(.kind=="json-key" and .unit=="/env/HANDOVER_DIR")' "$p4led/provenance.jsonl" | tail -n 1)"
[ "$(jq -r '[.op,.preexisted,.pre.state,.scope,.manifest_row,.class]|join(",")' <<< "$row")" = "noop,true,present,project,project-settings,code" ] \
  || fail "HIMMEL-3332 S4: a skipped HANDOVER_DIR must be recorded as noop preexisted: $row"
[ "$(jq -r '.env.HANDOVER_DIR' "$p4hd/.claude/settings.json")" = "/some/operator/chosen/handovers" ] \
  || fail "HIMMEL-3332 S4: the recorded skip must not change the operator's HANDOVER_DIR"
echo "ok: HIMMEL-3332 S4 a preserved HANDOVER_DIR is recorded as noop preexisted"

echo "PASS"
