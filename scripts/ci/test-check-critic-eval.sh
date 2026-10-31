#!/usr/bin/env bash
# test-check-critic-eval.sh — check-critic-eval.sh, the reviewer-eval merge gate.
# Each row builds a fixture repo from the REAL cbs.txt, fixture set, key, critics.json and CBS
# file bytes of this checkout, commits a base and a head, and runs the gate from inside it.
# Rows in results.jsonl are written with the real score.py cbs-hash / confighash of the commits.
# CHECK_CRITIC_EVAL overrides the script under test. No model call, no network.
#
# Run: bash scripts/ci/test-check-critic-eval.sh
# shellcheck disable=SC2015  # A && pass || fail reporting idiom (pass never fails)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SUT="${CHECK_CRITIC_EVAL:-$HERE/check-critic-eval.sh}"
SCORE="$ROOT/scripts/eval/review-panel/score.py"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check-critic-eval.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP test-check-critic-eval: python3 not on PATH"; exit 0; }

# The real inputs of the gate: everything the CBS can expand to, the eval's own tree and the roster.
SRC_PATHS="scripts/cr scripts/lib/critics-config.sh scripts/hermes/invoke.sh scripts/eval/review-panel/cbs.txt scripts/eval/review-panel/fixtures scripts/eval/review-panel/key"

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
# rows <file> <run_id:cbs:conf:recall:fp>...: append gate rows (class recall = recall, one outputs bundle
# per run_id) to a results file.
rows() {
    local f="$1"; shift
    python3 -c 'import hashlib,json,sys
f = sys.argv[1]
with open(f, "a") as fh:
    for spec in sys.argv[2:]:
        rid, cbs, conf, rec, fp = spec.split(":")
        fh.write(json.dumps({"run_id": rid, "cbs_hash": cbs, "confighash": conf, "status": "ok",
                             "metrics": {"panel.recall_gating": float(rec), "panel.fp_rate": float(fp)},
                             "class_recall": {"logic": float(rec)},
                             "outputs_sha256": hashlib.sha256(rid.encode()).hexdigest()},
                            sort_keys=True) + "\n")' "$f" "$@"
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

# --- I3: every critic behaviour path and the eval itself are trust paths ------------------------
fixture trust
trust_re="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/ci/ci-trust-paths.txt")"
cbs="$(python3 "$SCORE" cbs-paths HEAD --repo "$R")"
own="$( (cd "$ROOT" && git ls-files --cached --others --exclude-standard -- scripts/eval/review-panel scripts/eval/lib/eval_feedback.py) )"
untrusted="$(printf '%s\n%s\n' "$cbs" "$own" | grep -v '^$' | grep -vE -e "$trust_re")"
[ "$(printf '%s\n' "$cbs" | grep -c .)" -ge 7 ] && pass "the real cbs.txt expands to the critic files" \
    || fail "the real cbs.txt expands to the critic files (got: $(printf '%s' "$cbs" | tr '\n' ' '))"
[ -z "$untrusted" ] && pass "every cbs path, review-panel file and eval_feedback.py is a trust path" \
    || fail "paths outside ci-trust-paths.txt: $(printf '%s' "$untrusted" | tr '\n' ' ')"

echo
[ "$fails" -eq 0 ] && echo "test-check-critic-eval: all passed" || echo "test-check-critic-eval: $fails failed"
[ "$fails" -eq 0 ]
