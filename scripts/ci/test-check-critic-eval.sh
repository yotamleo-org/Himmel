#!/usr/bin/env bash
# test-check-critic-eval.sh — check-critic-eval.sh, the reviewer-eval merge gate.
# Each row builds a fixture repo from the REAL cbs.txt, fixture set, key, critics.json and CBS
# file bytes of this checkout, commits a base and a head, and runs the gate from inside it.
# Rows in results.jsonl are written with the real score.py cbs-hash / confighash of the commits.
# CHECK_CRITIC_EVAL overrides the script under test. No model call, no network.
#
# Run: bash scripts/ci/test-check-critic-eval.sh
# selector: tree-scan
# shellcheck disable=SC2015  # A && pass || fail reporting idiom (pass never fails)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCORE="$ROOT/scripts/eval/review-panel/score.py"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check-critic-eval.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP test-check-critic-eval: python3 not on PATH"; exit 0; }

SC="$WORK/scorer-copy"; mkdir -p "$SC/scripts/eval/review-panel" "$SC/scripts/eval/lib" "$SC/scripts/ci"
cp "$SCORE" "$SC/scripts/eval/review-panel/score.py"; cp "$ROOT/scripts/eval/lib/"*.py "$SC/scripts/eval/lib/"
cp "$ROOT/scripts/eval/review-panel/adjudication.py" "$SC/scripts/eval/review-panel/"
cp "$ROOT/scripts/eval/feedback-rules.json" "$SC/scripts/eval/"; cp "$HERE/check-critic-eval.sh" "$SC/scripts/ci/"
printf '__pycache__/\n' > "$SC/.gitignore"
git init -q "$SC" && git -C "$SC" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null \
    -c commit.gpgsign=false add -A && git -C "$SC" -c user.name=t -c user.email=t@example.invalid \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m scorer
SUT="${CHECK_CRITIC_EVAL:-$SC/scripts/ci/check-critic-eval.sh}"
sid() { python3 "$1" scorer-identity --json 2>/dev/null | python3 -c 'import json,sys; v=json.load(sys.stdin).get("scorer_sha256"); print("null" if v is None else v)' 2>/dev/null; }
SID="$(sid "$(dirname "$SUT")/../eval/review-panel/score.py")"
[[ "$SID" =~ ^[0-9a-f]{64}$ ]] && pass "the committed scorer copy has a clean identity" || fail "the committed scorer copy has a clean identity (got '$SID')"

# The real inputs of the gate: everything the CBS can expand to, the eval's own tree and the roster.
SRC_PATHS="scripts/cr scripts/lib/critics-config.sh scripts/hermes/invoke.sh scripts/eval/review-panel/cbs.txt scripts/eval/review-panel/gate-bypass.tsv scripts/eval/review-panel/fixtures scripts/eval/review-panel/key"
# The gate reads the PR number from these; a CI run of this suite must not leak its own into a row.
unset GITHUB_REF CHECK_CRITIC_EVAL_PR GITHUB_BASE_REF GITHUB_EVENT_PATH

gitc() { git -C "$R" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
# fixture <name>: a repo holding the real gate inputs, one base commit; sets R and BASE.
fixture() {
    R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R"
    # shellcheck disable=SC2086  # SRC_PATHS is a word list of pathspecs
    (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- $SRC_PATHS | tar --null -T - -cf -) | tar -xf - -C "$R"
    git init -q "$R" && gitc add -A && gitc commit -q -m base
    BASE="$(gitc rev-parse HEAD)"
}
# commit_edit <path> <line>: append a line to a tracked file and commit; prints the new sha.
commit_edit() { printf '%s\n' "$2" >> "$R/$1"; gitc add -A && gitc commit -q -m "edit $1" && gitc rev-parse HEAD; }
cbs_hash() { python3 "$SCORE" cbs-hash "$1" --repo "$R"; }
confighash() { python3 "$SCORE" confighash "$1" --repo "$R"; }
rows() {
    local f="$1"; shift
    python3 -c 'import hashlib,json,sys
f, sid = sys.argv[1:3]
with open(f, "a") as fh:
    for spec in sys.argv[3:]:
        p = spec.split(":")
        rid, cbs, conf, rec, fp = p[:5]
        sc, extra = (p[5] if len(p) > 5 else "cur"), (p[6] if len(p) > 6 else "")
        row = {"run_id": rid, "cbs_hash": cbs, "confighash": conf, "status": "ok",
               "metrics": {"panel.recall_gating": float(rec), "panel.fp_rate": float(fp)},
               "class_recall": {"logic": float(rec)},
               "outputs_sha256": hashlib.sha256(rid.encode()).hexdigest()}
        if sc != "none":
            row["scorer_sha256"] = {"cur": sid, "null": None}.get(sc, sc)
        for tok in [t for t in extra.split(",") if t]:
            if tok == "ineligible":
                row.update(decision_eligible=False, ineligibility_reasons=["provenance-reconstructed"])
            elif tok.startswith("sup="):
                row["supersedes_run_id"] = tok[4:]
            elif tok.startswith("exec="):
                row["execution_id"] = tok[5:]
        fh.write(json.dumps(row, sort_keys=True) + "\n")' "$f" "$SID" "$@"
}
# gate <label> <rc> [needle]: run the gate on BASE..HEAD of R.
gate() {
    local head rc; head="$(gitc rev-parse HEAD)"
    (cd "$R" && bash "$SUT" "$BASE" "$head") > "$WORK/out" 2>&1; rc=$?
    if [ "$rc" != "$2" ]; then fail "$1 (want rc $2, got $rc: $(head -3 "$WORK/out" | tr '\n' '|'))"; return; fi
    if [ -n "${3:-}" ] && ! grep -qF "$3" "$WORK/out"; then fail "$1 (output lacks '$3': $(head -3 "$WORK/out" | tr '\n' '|'))"; return; fi
    pass "$1"
}

# with_rows <spec>...: replace the head tree's results.jsonl with these rows and commit it.
RES=scripts/eval/review-panel/results.jsonl
with_rows() { rm -f "$R/$RES"; rows "$R/$RES" "$@"; gitc add -A && gitc commit -q -m rows; }

# --- RED: a critic change with no eval rows ------------------------------------------------
fixture no-rows
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
gate "a critic-file change with no eval rows fails" 1 "no eval rows"
gate "RED 9922: the failure names the paid eval as the default route, needing no operator ask" 1 \
    "the paid eval sweep is the default route for a critic change and needs no operator ask; only skipping it needs an operator decision"

# --- the verdicts over one critic change ----------------------------------------------------
fixture verdicts
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
B="$(cbs_hash "$BASE")"; H="$(cbs_hash HEAD)"; C="$(confighash HEAD)"
[ -n "$B" ] && [ -n "$C" ] && [ "$B" != "$H" ] && pass "the critic edit moves cbs_hash" || fail "the critic edit moves cbs_hash ($B / $H / $C)"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gate "two head rows within noise of two baseline rows pass" 0 "gate: no-loss"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.30:0.10" "h2:$H:$C:0.35:0.10"
gate "a recall drop beyond noise fails" 1 "gate: loss"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.50:0.10" "h1:$H:$C:0.50:0.40" "h2:$H:$C:0.50:0.30"
gate "an fp_rate rise beyond noise fails" 1 "gate: loss"
with_rows "b1:$B:$C:0.50:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gate "one baseline row is unmeasured" 1 "gate: unmeasured"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10"
gate "one head row is unmeasured" 1 "gate: unmeasured"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h1:$H:$C:0.55:0.10"
gate "two head rows with one run_id count once" 1 "gate: unmeasured"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:feedfeed:$C:0.55:0.10" "h2:feedfeed:$C:0.50:0.10"
gate "head rows at another cbs_hash fail" 1 "no eval rows"
with_rows "b1:$B:0000:0.50:0.10" "b2:$B:0000:0.60:0.10" "h1:$H:0000:0.55:0.10" "h2:$H:0000:0.50:0.10"
gate "rows at a confighash the head tree does not compute fail" 1 "no eval rows"
# An older critic version's row (another cbs_hash) must not widen the baseline noise.
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.50:0.10" "o3:old:$C:0.10:0.10" "h1:$H:$C:0.40:0.10" "h2:$H:$C:0.40:0.10"
gate "a third row of an older critic does not widen the noise" 1 "gate: loss"
# Main gained a critic change after the sweep: the merge ref's hash is not the swept head's.
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
commit_edit scripts/cr/critic-panel.sh '# a later critic change on main' >/dev/null
gate "a merge-ref cbs_hash that differs from the swept head fails" 1 "no eval rows"

fixture scorer-rows
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
B="$(cbs_hash "$BASE")"; H="$(cbs_hash HEAD)"; C="$(confighash HEAD)"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gate "rows stamped with the running scorer's identity pass" 0 "gate: no-loss"
with_rows "b1:$B:$C:0.50:0.10:none" "b2:$B:$C:0.60:0.10:none" "h1:$H:$C:0.55:0.10:none" "h2:$H:$C:0.50:0.10:none"
gate "legacy_rows_without_scorer_unmeasured: rows with no scorer_sha256 fail" 1 "4 without scorer_sha256"
with_rows "b1:$B:$C:0.50:0.10:$(printf 'a%.0s' $(seq 64))" "b2:$B:$C:0.60:0.10:$(printf 'a%.0s' $(seq 64))" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gate "mixed_scorer_rows_unmeasured: an older scorer's baseline beside the running scorer's head fails" 1 "gate: unmeasured"
SCD="$WORK/scorer-dirty"; cp -r "$SC" "$SCD"; printf '# dirty\n' >> "$SCD/scripts/eval/review-panel/score.py"
with_rows "b1:$B:$C:0.50:0.10:null" "b2:$B:$C:0.60:0.10:none" "h1:$H:$C:0.55:0.10:null" "h2:$H:$C:0.50:0.10:none"
SUT="$SCD/scripts/ci/check-critic-eval.sh" gate "null_running_identity_matches_no_rows: a dirty scorer over null and absent hashes fails" 1 "no clean identity"

fixture selector
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
B="$(cbs_hash "$BASE")"; H="$(cbs_hash HEAD)"; C="$(confighash HEAD)"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gate "selector: the plain two-and-two rows still pass" 0 "gate: no-loss"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h1r:$H:$C:0.55:0.10:cur:sup=h1"
gate "scorer_only_rescore_not_new_execution: a rescore of one head sweep is not a second distinct sweep" 1 "gate: unmeasured"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10" "h2r:$H:$C:0.50:0.10:cur:sup=h2"
gate "selector: a rescore beside its source is one execution, the pair still has two distinct sweeps" 0 "gate: no-loss"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10:cur:ineligible"
gate "old_unknown_provenance_diagnostic_only: an ineligible head row never counts" 1 "not-decision-eligible"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10:cur:sup=h2,exec=x" "h2:$H:$C:0.50:0.10:cur:sup=h1,exec=x"
gate "supersession_cycle: a cycle selects nothing, the head is unmeasured" 1 "supersession-cycle"
with_rows "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10:cur:exec=x" "h2:$H:$C:0.50:0.10:cur:exec=x" "h3:$H:$C:0.52:0.10:cur:sup=h1,exec=x" "h4:$H:$C:0.48:0.10:cur:sup=h1,exec=x"
gate "two_successors_ambiguous: two successors of one run select nothing" 1 "two-successors-ambiguous"

# --- which diffs are gated ------------------------------------------------------------------
fixture unlisted
python3 -c 'import sys
p = sys.argv[1]
keep = [l for l in open(p) if l.strip() not in ("scripts/cr/critic-first-pass.sh", "scripts/cr/critic-*.sh")]
open(p, "w").writelines(keep)' "$R/scripts/eval/review-panel/cbs.txt"
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
gate "dropping a file from cbs.txt while editing it is still gated" 1 "no eval rows"

fixture untouched
commit_edit scripts/cr/notes-not-a-critic.txt 'not a critic file' >/dev/null
gate "a diff that touches no critic path passes" 0 "no protected critic path changed"

# The gate's own files are not critic behaviour paths: a diff over them alone is not gated.
fixture own-diff
for p in scripts/eval/review-panel/score.py scripts/eval/review-panel/run.sh scripts/eval/review-panel/test-review-panel.sh \
         scripts/eval/review-panel/README.md scripts/eval/review-panel/harvest.py scripts/eval/review-panel/cbs.txt \
         scripts/eval/review-panel/results.jsonl scripts/eval/lib/eval_feedback.py scripts/ci/check-critic-eval.sh \
         scripts/ci/test-check-critic-eval.sh scripts/ci/ci-trust-paths.txt scripts/ci/suite-tiers.tsv \
         scripts/ci/suite-durations.tsv .github/workflows/ci.yml; do
    mkdir -p "$R/$(dirname "$p")"; printf '# x\n' >> "$R/$p"
done
gitc add -A && gitc commit -q -m own-diff
gate "a diff over HIMMEL-8426's own paths passes" 0 "no protected critic path changed"

# --- a critic path the eval sweep never executes ---------------------------------------
# cbs.txt tags those paths `# unexecuted: <path>`; the gate reads the tags at the diff base and the bypass file at
# the default branch's tip (falling back to the diff base), never from the head.
BYP=scripts/eval/review-panel/gate-bypass.tsv
fixture unexec
commit_edit scripts/cr/panel-first-pass.sh '# a pr-check flow change' >/dev/null
commit_edit scripts/cr/critic-pre-existing-tag.py '# a tagger change' >/dev/null
gate "a diff over only never-executed critic paths passes with the reason" 0 "only paths the sweep never executes changed: scripts/cr/critic-pre-existing-tag.py scripts/cr/panel-first-pass.sh; a judge GO covers them"

fixture unexec-mixed
commit_edit scripts/cr/panel-first-pass.sh '# a pr-check flow change' >/dev/null
commit_edit scripts/cr/critic-panel.sh '# a panel change' >/dev/null
gate "a never-executed path plus an executed critic path is still gated" 1 "no eval rows"

fixture unexec-head-tag
printf '# unexecuted: scripts/cr/critic-first-pass.sh\n' >> "$R/scripts/eval/review-panel/cbs.txt"
printf '# a critic change\n' >> "$R/scripts/cr/critic-first-pass.sh"
gitc add -A && gitc commit -q -m "retag own path"
gate "a head-tree cbs.txt tag cannot exempt the critic file the same PR edits" 1 "no eval rows"

fixture unexec-head-untag
python3 -c 'import sys
p = sys.argv[1]
keep = [l for l in open(p) if not l.startswith("# unexecuted:")]
open(p, "w").writelines(keep)' "$R/scripts/eval/review-panel/cbs.txt"
printf '# a pr-check flow change\n' >> "$R/scripts/cr/panel-first-pass.sh"
gitc add -A && gitc commit -q -m "drop the tags and edit"
gate "a head-tree cbs.txt that drops the tags does not change the base's verdict" 0 "a judge GO covers them"

# with_bypass <row>...: BASE becomes a sibling of HEAD (the old base plus these rows), as main would carry the
# row before the PR merges; HEAD itself is untouched.
brow() { printf '%s\t%s\t%s\t%s\n' "$@"; }
with_bypass() {
    local h; h="$(gitc rev-parse HEAD)"
    gitc checkout -q "$BASE0" && printf '%s\n' "# pr	head	decision	reason" "$@" > "$R/$BYP"
    gitc add -A && gitc commit -q -m bypass && BASE="$(gitc rev-parse HEAD)" && gitc checkout -q "$h"
}
fixture bypass
BASE0="$BASE"
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
H="$(gitc rev-parse HEAD)"
with_bypass "$(brow 4690 "${H:0:7}" 592 'noise on an unexecuted path')"
CHECK_CRITIC_EVAL_PR=4690 gate "a bypass row for this PR and this head passes, loudly" 0 "BYPASS honoured for PR 4690 at head ${H:0:7}"
CHECK_CRITIC_EVAL_PR=4690 gate "the bypass names the decision and the reason" 0 "decision 592: noise on an unexecuted path"
GITHUB_REF=refs/pull/4690/merge gate "the PR number is read from GITHUB_REF in CI" 0 "BYPASS honoured"
CHECK_CRITIC_EVAL_PR=4691 gate "a bypass row for another PR is ignored" 1 "no eval rows"
gate "no PR number means no bypass" 1 "no eval rows"
with_bypass "$(brow 4690 "deadbee" 592 'another head')"
CHECK_CRITIC_EVAL_PR=4690 gate "a bypass row for another head is ignored" 1 "no eval rows"
# CI hands the gate the merge ref: its second parent is the PR head the row names.
with_bypass "$(brow 4690 "${H:0:7}" 592 'noise on an unexecuted path')"
M="$(gitc commit-tree "$(gitc rev-parse "$H^{tree}")" -p "$BASE" -p "$H" -m merge-ref)"; gitc checkout -q "$M"
GITHUB_REF=refs/pull/4690/merge gate "a bypass row naming the PR head is honoured on the merge ref" 0 "BYPASS honoured"
CHECK_CRITIC_EVAL_PR=4690 gate "a second parent counts only on CI's merge ref, not on any merge commit" 1 "no eval rows"
# A PR cannot add its own bypass: the merge ref's tree carries a row for the PR head, the base does not.
gitc checkout -q "$H"; brow 4690 "${H:0:7}" 592 'self-granted' > "$R/$BYP"; gitc add -A && gitc commit -q -m "own bypass"
H2="$(gitc rev-parse HEAD)"
M2="$(gitc commit-tree "$(gitc rev-parse "$H2^{tree}")" -p "$BASE0" -p "$H" -m merge-ref)"; BASE="$BASE0"; gitc checkout -q "$M2"
GITHUB_REF=refs/pull/4690/merge gate "a bypass row added by the PR itself is ignored" 1 "no eval rows"

fixture bypass-bad
BASE0="$BASE"
commit_edit scripts/cr/critic-first-pass.sh '# a critic change' >/dev/null
H="$(gitc rev-parse HEAD)"
for bad in "$(brow 4690 "${H:0:6}" 592 'prefix too short')" "$(brow 4690 "zzzzzzz" 592 'not hex')" \
           "$(brow abc "${H:0:7}" 592 'pr not a number')" "$(printf '4690\t%s\t592' "${H:0:7}")" \
           "$(brow 4690 "${H:0:7}" '' 'no decision')" "$(brow 4690 "${H:0:7}" 592 '')"; do
    with_bypass "$bad"
    CHECK_CRITIC_EVAL_PR=4690 gate "a malformed bypass row fails closed ($(printf '%s' "$bad" | cut -c1-40 | tr '\t' '|'))" 1 "malformed"
done
with_bypass "$(brow 4690 "${H:0:6}" 592 'prefix too short')" "$(brow 4690 "${H:0:7}" 592 'a good row')"
CHECK_CRITIC_EVAL_PR=4690 gate "a malformed row next to a good one still fails closed" 1 "malformed"

# --- CI's merge ref: the diff base is its first parent, the bypass file is read at main's tip ----------
# P1 is a newer main than BASE0, which stays <base> as the event's base.sha does. on_merge_ref <edit> runs the
# PR's <edit> on BASE0 to make the PR head PRH, and again on HEAD (P1) to make the tree of M, the merge ref CI
# builds: parents P1 and PRH. It checks out M (detached).
on_merge_ref() {
    local p1; p1="$(gitc rev-parse HEAD)"
    gitc checkout -q "$BASE0" && "$1" && gitc add -A && gitc commit -q -m pr && PRH="$(gitc rev-parse HEAD)" || return 1
    gitc checkout -q "$p1" && "$1" && gitc add -A && gitc commit -q -m pr-on-main || return 1
    M="$(gitc commit-tree "$(gitc rev-parse 'HEAD^{tree}')" -p "$p1" -p "$PRH" -m merge-ref)" && gitc checkout -q "$M"
}
add_line() { printf '%s\n' "$2" >> "$R/$1"; }
untrack_first_pass() { python3 -c 'import sys
p = sys.argv[1]
keep = [l for l in open(p) if l.strip() not in ("scripts/cr/critic-first-pass.sh", "scripts/cr/critic-*.sh")]
open(p, "w").writelines(keep)' "$R/scripts/eval/review-panel/cbs.txt"; }
pr_note() { add_line scripts/cr/notes-not-a-critic.txt 'not a critic file'; }
pr_critic() { add_line scripts/cr/critic-first-pass.sh '# a critic change'; }
# event <default branch>: a pull_request event file in the shape the runner writes at GITHUB_EVENT_PATH (ci.yml
# reads github.event.repository.default_branch from it); prints its path.
event() {
    python3 -c 'import json,sys
json.dump({"action": "synchronize", "number": 4690,
           "pull_request": {"number": 4690, "base": {"ref": "main", "sha": sys.argv[2]}, "head": {"sha": sys.argv[3]}},
           "repository": {"full_name": "owner/repo", "default_branch": sys.argv[1]}}, open(sys.argv[4], "w"))' \
        "$1" "$BASE0" "$PRH" "$WORK/event-$1.json" && printf '%s\n' "$WORK/event-$1.json"
}
# ci <default branch> <gate args>: run the gate as CI does for PR 4690's merge ref, base branch main.
ci() { local ev; ev="$(event "$1")"; shift; GITHUB_REF=refs/pull/4690/merge GITHUB_BASE_REF=main GITHUB_EVENT_PATH="$ev" gate "$@"; }

fixture mr-diff
BASE0="$BASE"
commit_edit scripts/cr/critic-panel.sh '# a critic change on main' >/dev/null
on_merge_ref pr_note
GITHUB_REF=refs/pull/4690/merge gate "a critic change main gained after the PR opened is not the PR's (the diff runs from the first parent)" 0 "no protected critic path changed"

fixture mr-cbs
BASE0="$BASE"
untrack_first_pass; gitc add -A && gitc commit -q -m "main drops a file from cbs.txt"
on_merge_ref pr_critic
GITHUB_REF=refs/pull/4690/merge gate "a file main dropped from cbs.txt after the PR opened is not gated (the first parent's cbs.txt)" 0 "no protected critic path changed"

fixture mr-tag
BASE0="$BASE"
add_line scripts/eval/review-panel/cbs.txt '# unexecuted: scripts/cr/critic-first-pass.sh'; gitc add -A && gitc commit -q -m "main tags a path"
on_merge_ref pr_critic
GITHUB_REF=refs/pull/4690/merge gate "a tag main added after the PR opened counts (the first parent's tags)" 0 "only paths the sweep never executes changed: scripts/cr/critic-first-pass.sh"

fixture mr-rows
BASE0="$BASE"
commit_edit scripts/cr/critic-panel.sh '# a critic change on main' >/dev/null
on_merge_ref pr_critic
B="$(cbs_hash "$M^1")"; H="$(cbs_hash "$M")"; C="$(confighash "$M")"
[ -n "$B" ] && [ "$B" != "$(cbs_hash "$BASE0")" ] && pass "main's critic change moves the first parent's cbs_hash" || fail "main's critic change moves the first parent's cbs_hash ($B)"
rm -f "$R/$RES"; rows "$R/$RES" "b1:$B:$C:0.50:0.10" "b2:$B:$C:0.60:0.10" "h1:$H:$C:0.55:0.10" "h2:$H:$C:0.50:0.10"
gitc add -A && M="$(gitc commit-tree "$(gitc write-tree)" -p "$M^1" -p "$PRH" -m merge-ref)" && gitc checkout -q "$M"
GITHUB_REF=refs/pull/4690/merge gate "the base rows are read at the first parent's cbs_hash" 0 "gate: no-loss"

# A PR's own tag, cbs.txt drop or bypass row still counts for nothing on the merge ref.
fixture mr-guard
BASE0="$BASE"
commit_edit scripts/cr/notes-not-a-critic.txt 'a non-critic change on main' >/dev/null
P1="$(gitc rev-parse HEAD)"
pr_self_tag() { pr_critic; add_line scripts/eval/review-panel/cbs.txt '# unexecuted: scripts/cr/critic-first-pass.sh'; }
on_merge_ref pr_self_tag
GITHUB_REF=refs/pull/4690/merge gate "on the merge ref, a tag only in the PR's own cbs.txt does not exempt its edit" 1 "no eval rows"
gitc checkout -q "$P1"
pr_self_drop() { pr_critic; untrack_first_pass; }
on_merge_ref pr_self_drop
GITHUB_REF=refs/pull/4690/merge gate "on the merge ref, dropping its own edited file from cbs.txt does not ungate it" 1 "no eval rows"
gitc checkout -q "$P1"
on_merge_ref pr_critic
gitc checkout -q "$P1"; pr_critic; brow 4690 "$PRH" 592 'self-granted' >> "$R/$BYP"; gitc add -A && gitc commit -q -m "own bypass"
M="$(gitc commit-tree "$(gitc rev-parse 'HEAD^{tree}')" -p "$P1" -p "$PRH" -m merge-ref)"; gitc checkout -q "$M"
gitc update-ref refs/remotes/origin/main "$P1"
ci main "a bypass row only in the PR's own tree is ignored when main's tip is read" 1 "no eval rows"

fixture mr-bypass
BASE0="$BASE"
commit_edit scripts/cr/notes-not-a-critic.txt 'a non-critic change on main' >/dev/null
P1="$(gitc rev-parse HEAD)"
on_merge_ref pr_critic
gitc checkout -q "$P1"; brow 4690 "$PRH" 592 'recorded after the PR opened' >> "$R/$BYP"; gitc add -A && gitc commit -q -m "main records a bypass"
TIP="$(gitc rev-parse HEAD)"; gitc checkout -q "$M"
gitc update-ref refs/remotes/origin/main "$TIP"
ci main "a bypass row main gained after the merge ref was built is read at main's tip" 0 "BYPASS honoured for PR 4690 at head $PRH"
ci trunk "a base branch that is not the default branch reads the bypass file at the diff base, and says so" 1 "the base branch main is not the default branch trunk"
# HEAD is detached on M, so writing refs/heads/main moves no checkout, whatever init.defaultBranch named.
gitc update-ref -d refs/remotes/origin/main && gitc update-ref refs/heads/main "$TIP"
ci main "an absent refs/remotes/origin/main falls back to the diff base, and names the ref" 1 "refs/remotes/origin/main is absent"

# --- I3: every critic behaviour path and the eval itself are trust paths ------------------------
fixture trust
trust_re="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/ci/ci-trust-paths.txt")"
cbs="$(python3 "$SCORE" cbs-paths HEAD --repo "$R")"
# score.py puts scripts/eval/lib first on sys.path, so every module there (eval_runs.py, wilson.py, a new
# file that shadows a stdlib import) is gate code.
own="$( (cd "$ROOT" && git ls-files --cached --others --exclude-standard -- scripts/eval/review-panel scripts/eval/lib) )"
case "$own" in *scripts/eval/lib/eval_runs.py*) ;; *) fail "the I3 row lists scripts/eval/lib/eval_runs.py" ;; esac
untrusted="$(printf '%s\n%s\n' "$cbs" "$own" | grep -v '^$' | grep -vE -e "$trust_re")"; urc=$?
[ "$(printf '%s\n' "$cbs" | grep -c .)" -ge 7 ] && pass "the real cbs.txt expands to the critic files" \
    || fail "the real cbs.txt expands to the critic files (got: $(printf '%s' "$cbs" | tr '\n' ' '))"
# grep -v exits 1 when it prints nothing (every path trusted) and 2 on an unreadable file or a bad regex.
[ -n "$trust_re" ] && [ "$urc" -le 1 ] && [ -z "$untrusted" ] \
    && pass "every cbs path, review-panel file and scripts/eval/lib module is a trust path" \
    || fail "paths outside ci-trust-paths.txt (patterns read: $(printf '%s' "$trust_re" | grep -c .), grep rc $urc): $(printf '%s' "$untrusted" | tr '\n' ' ')"

echo
[ "$fails" -eq 0 ] && echo "test-check-critic-eval: all passed" || echo "test-check-critic-eval: $fails failed"
[ "$fails" -eq 0 ]
