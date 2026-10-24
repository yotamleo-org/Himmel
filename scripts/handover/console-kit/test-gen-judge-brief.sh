#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-gen-judge-brief.sh — Exercises gen-judge-brief.py on a fixture spec: the
# brief it writes is the docs/handover/judge-brief-template.md fenced block with every
# placeholder filled, passes brief-lint.sh and the launcher's Tier gate, is blind (a spec that
# carries a conclusion is refused), and never overwrites. Every path is a fixture: no launch.
# GEN_JUDGE_BRIEF overrides the script under test (the RED control: a missing script fails
# every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-gen-judge-brief.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GEN_JUDGE_BRIEF:-$HERE/gen-judge-brief.py}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-judge-brief-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
BUCKET="$WORK/bucket"
HEAD40="0123456789abcdef0123456789abcdef01234567"
CONSOLE="HIMMEL-nextleg-2026-10-13Z-roadmap-console"

cat > "$WORK/spec.json" <<EOF
{"qid": "j2599a", "ticket": "HIMMEL-3746", "pr": 2599, "head": "$HEAD40",
 "tickets": ["HIMMEL-3746", "HIMMEL-3254"],
 "author_doc": "$WORK/author-doc.md",
 "question": "Does PR 2599 parse the SUCCESSION bullet strictly enough that an ambiguous line reads missing?",
 "reason": "Disputed review finding: the leg and the reviewer disagree on a trailing-text bullet.",
 "prior": "HIMMEL-3254 (tick nonces=RELAYED). Source: qmd jira-himmel succession tracker.",
 "description": "Rule on whether the succession tracker's bullet parse is strict",
 "tier": {"category": "unverified-finding", "reason": "a finding the console could not verify at Sonnet"},
 "attack": ["a bullet with trailing prose after the replaces clause", "two bullets, the older one naming the successor"],
 "evidence": [{"item": "$WORK/extra.txt", "for": "the reviewer's finding text"}],
 "do_not": "everything except reading and the verdict file"}
EOF

run() { python3 "$SUT" "$WORK/spec.json" --console "$CONSOLE" --bucket "$BUCKET" --date 2026-10-13 \
    --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" 2>&1; }

out="$(run)"; rc=$?
[ "$rc" = 0 ] && pass "a valid spec generates (rc 0)" || fail "rc=$rc: $out"
DOC="$BUCKET/HIMMEL-3746-judge-j2599a-2026-10-13-RESUME.md"
[ -f "$DOC" ] && pass "the brief is named <TICKET>-judge-<qid>-<date>-RESUME.md" || fail "no $DOC; ls: $(ls "$BUCKET" 2>&1)"
b="$(cat "$DOC" 2>/dev/null)"
has "the printed output names the doc" "$out" "$DOC"

bash "$HERE/brief-lint.sh" "$DOC" 2>"$WORK/lint.err"; rc=$?
[ "$rc" = 0 ] && pass "the brief passes brief-lint.sh" || fail "brief-lint rc=$rc: $(cat "$WORK/lint.err")"

has "the question is carried verbatim" "$b" "Does PR 2599 parse the SUCCESSION bullet strictly enough that an ambiguous line reads missing?"
has "the nonce is in the console letter's shape" "$b" "Z-j2599a-"
has "the console is named" "$b" "$CONSOLE"
has "the handover root is named" "$b" "$WORK/handovers"
has "the Tier line is exact" "$b" "> **Tier:** opus — unverified-finding: a finding the console could not verify at Sonnet"
has "the PR head is evidence" "$b" "$HEAD40"
has "the ticket is evidence" "$b" "HIMMEL-3254"
has "the author doc is evidence" "$b" "$WORK/author-doc.md"
has "an attack-list item is carried" "$b" "a bullet with trailing prose after the replaces clause"
has "a console-supplied evidence item is carried" "$b" "the reviewer's finding text"
has "the Lifecycle rule from the template survives" "$b" "**Lifecycle — the one rule.**"
has "the front matter has the description" "$b" "description: \"Rule on whether the succession tracker's bullet parse is strict\""
has "resume_cwd is the scratch dir outside the handover root" "$b" "resume_cwd: $WORK/verdicts/j2599a/scratch"
lacks "no <qid> placeholder is left" "$b" "<qid>"
lacks "no <console session name> placeholder is left" "$b" "<console session name>"
lacks "no <hex> placeholder is left" "$b" "<console letter>"
lacks "no <TICKET> placeholder is left" "$b" "# <TICKET>"
lacks "no unfilled <free text> tier is left" "$b" "<category>: <free text>"
lacks "the console's own conclusion field never appears" "$b" "conclusion"

# the launcher's own Tier gate: a copy arms through headed-arm-leg.sh --dry-run
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$WORK/preflight.sh"
mkdir -p "$WORK/arm" "$WORK/handovers" "$WORK/verdicts/j2599a/scratch"
rc=0; arm_out="$(HEADED_ARM_LEG_PREFLIGHT="$WORK/preflight.sh" LEG_REPO="$WORK" HANDOVER_DIR="$WORK/handovers" bash "$HERE/headed-arm-leg.sh" --dry-run --judge --console "$CONSOLE" HIMMEL-3746-judge-j2599a "$DOC" "$WORK/sig" 9999999999 "$WORK/arm.log" claude-opus-5-5 2>&1)" || rc=$?
if [ "$rc" = 0 ] && case "$arm_out" in *"headed-arm-leg: would exec:"*) true ;; *) false ;; esac; then
    pass "headed-arm-leg --judge's Tier and prior-art gates accept the generated brief (dry-run completed, rc 0)"
else
    fail "headed-arm-leg --judge did not complete a dry run on the generated brief (rc=$rc): $arm_out"
fi

# refusals: nothing written
rm -rf "$BUCKET"
run >/dev/null; rc=$?
run >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "re-running over an existing brief refuses (rc 1)" || fail "overwrite rc=$rc"

mutate() { # <name> <python expr over d> -> $WORK/<name>.json
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d,open(sys.argv[3],"w"))' "$WORK/spec.json" "$2" "$WORK/$1.json"
}
refuse() { # <label> <name> <stderr fragment>
    rm -rf "$BUCKET"
    python3 "$SUT" "$WORK/$2.json" --console "$CONSOLE" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>"$WORK/$2.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$3" "$WORK/$2.err" && ! ls "$BUCKET"/*.md >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$rc, err: $(cat "$WORK/$2.err"))"; fi
}
mutate bare 'd["prior"]="none"';                          refuse "a bare none prior art is refused" bare "prior"
mutate nohead 'd["head"]="abc123"';                       refuse "a short head is refused" nohead "head"
mutate noq 'del d["question"]';                           refuse "a missing question is refused" noq "question"
mutate notier 'del d["tier"]';                            refuse "a missing tier is refused" notier "tier"
mutate badcat 'd["tier"]["category"]="cheap"';            refuse "a tier category outside the four tags is refused" badcat "tier.category"
mutate blank 'd["tier"]["reason"]="  "';                  refuse "a blank tier reason is refused" blank "tier.reason"
mutate badqid 'd["qid"]="J 1"';                           refuse "a qid with a space is refused" badqid "qid"
mutate concl 'd["conclusion"]="the finding is real"';     refuse "a spec carrying a conclusion is refused (blind, not thin)" concl "blind"
mutate recom 'd["recommendation"]="NO-GO"';               refuse "a spec carrying a recommendation is refused" recom "blind"
mutate badev 'd["evidence"]=[{"item":"x","for":5}]';       refuse "a non-string evidence field is refused with a diagnostic" badev "evidence"
mutate badmodel 'd["model"]=7';                           refuse "a non-string model is refused with a diagnostic" badmodel "model"
mutate badtl 'd["tickets"]=123';                          refuse "a non-list tickets value is refused with a diagnostic" badtl "tickets must be a list"
mutate crq 'd["question"]="one line\rsecond"';            refuse "a question with a CR is refused" crq "question"
mutate falsyev 'd["evidence"]={}';                        refuse "a falsy non-list evidence value is refused" falsyev "evidence"
mutate falsyat 'd["attack"]=0';                           refuse "a falsy non-list attack value is refused" falsyat "attack"
mutate longqid 'd["qid"]="j2599a_"+"a"*42';                refuse "a 49-char qid is refused" longqid "qid"
mutate badtk 'd["tickets"]=["not-a-key"]';                refuse "a malformed ticket key is refused" badtk "ticket"

# The nonce <letter>-<qid>-<hex> must stay inside the vault token grammar (1-3 upper-case letters).
jletter() { # <label> <stderr fragment> <args...>: refused, rc 1, nothing written
    local n="$1" frag="$2"; shift 2
    rm -rf "$BUCKET"
    python3 "$SUT" "$WORK/spec.json" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" "$@" >/dev/null 2>"$WORK/jl.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/jl.err" && ! ls "$BUCKET"/*.md >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/jl.err"))"; fi
}
jletter "a 4-letter --letter is refused" "letter" --console "$CONSOLE" --letter ABCD
jletter "a lower-case --letter is refused" "letter" --console "$CONSOLE" --letter z
jletter "an explicitly empty --letter is refused" "letter" --console "$CONSOLE" --letter ""
jletter "a letter derived from the console name that is 4 letters long is refused" "letter" --console HIMMEL-nextleg-2026-10-13ABCD-roadmap-console
rm -rf "$BUCKET"
python3 "$SUT" "$WORK/spec.json" --console "$CONSOLE" --letter ABC --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'ABC-j2599a-' "$BUCKET"/HIMMEL-3746-judge-j2599a-*.md && pass "a 3-letter --letter is accepted and minted" || fail "3-letter letter rc=$rc"

# the judge reads pin to the PR head sha directly, never FETCH_HEAD
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
gb="$(cat "$BUCKET"/HIMMEL-3746-judge-j2599a-*.md 2>/dev/null)"
has "generated brief names the sha-pinned read" "$gb" "git cat-file -t $HEAD40"
has "generated brief names the sha-pinned diff" "$gb" "git diff origin/main...$HEAD40"
has "generated brief names the sha-pinned tree read" "$gb" "git show $HEAD40:<path>"
has "generated brief forbids FETCH_HEAD" "$gb" "never FETCH_HEAD"
lacks "generated brief has no FETCH_HEAD tree read" "$gb" "git show FETCH_HEAD"
lacks "generated brief gives no refspec fetch" "$gb" "refs/judge/pr-"
for f in .claude/agents/judge.md .claude/agents/judge-ro.md docs/handover/console-sections/judge.md docs/handover/judge-brief-template.md; do
    c="$(cat "$REPO_ROOT/$f")"
    has "$f names the sha-pinned read" "$c" "git cat-file -t <sha>"
    lacks "$f gives no refspec fetch" "$c" "refs/judge/pr-"
    has "$f forbids FETCH_HEAD" "$c" "never FETCH_HEAD"
done

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
