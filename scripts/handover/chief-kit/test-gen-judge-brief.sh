#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-gen-judge-brief.sh — Exercises gen-judge-brief.py on a fixture spec: the
# brief it writes is the docs/handover/judge-brief-template.md fenced block with every
# placeholder filled, passes brief-lint.sh and the launcher's Tier gate, is blind (a spec that
# carries a conclusion is refused), and never overwrites. Every path is a fixture: no launch.
# GEN_JUDGE_BRIEF overrides the script under test (the RED control: a missing script fails
# every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-gen-judge-brief.sh
set -u
export UNGUARDED_LAUNCH_OK=1  # HIMMEL-9026: scratch fixtures; guard rows drop it
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GEN_JUDGE_BRIEF:-$HERE/gen-judge-brief.py}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-judge-brief-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HIMMEL_CEILINGS_LEDGER="$WORK/no-ceilings-ledger.tsv"
case "$HIMMEL_CEILINGS_LEDGER" in "$WORK"/*) ;; *) echo "FAIL: the ceilings ledger escapes the work dir"; exit 1 ;; esac
unset HIMMEL_BUCKET_DIR
BUCKET="$WORK/bucket"
HEAD40="0123456789abcdef0123456789abcdef01234567"
CHIEF="HIMMEL-nextleg-2026-10-13Z-roadmap-chief"

# brief-lint's core gate asks the jira CLI for every key in the title (scripts/jira/dist is untracked, absent in CI): a fixture stand-in calls every key NOT-CORE
mkdir -p "$WORK/stub-jira"
cat > "$WORK/stub-jira/index.js" <<'STUBEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else if (a[0] === 'release' && a[1] === 'bucket-check') for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUBEOF
export BRIEF_LINT_JIRA_CLI="$WORK/stub-jira/index.js"

cat > "$WORK/spec.json" <<EOF
{"qid": "j2599a", "ticket": "HIMMEL-3746", "pr": 2599, "head": "$HEAD40",
 "tickets": ["HIMMEL-3746", "HIMMEL-3254"],
 "author_doc": "$WORK/author-doc.md",
 "question": "Does PR 2599 parse the SUCCESSION bullet strictly enough that an ambiguous line reads missing?",
 "reason": "Disputed review finding: the worker and the reviewer disagree on a trailing-text bullet.",
 "prior": "HIMMEL-3254 (tick nonces=RELAYED). Source: qmd jira-himmel succession tracker.",
 "description": "Rule on whether the succession tracker's bullet parse is strict",
 "tier": {"category": "unverified-finding", "reason": "a finding the chief could not verify at Sonnet"},
 "attack": ["a bullet with trailing prose after the replaces clause", "two bullets, the older one naming the successor"],
 "evidence": [{"item": "$WORK/extra.txt", "for": "the reviewer's finding text"}],
 "do_not": "everything except reading and the verdict file"}
EOF

run() { python3 "$SUT" "$WORK/spec.json" --chief "$CHIEF" --bucket "$BUCKET" --date 2026-10-13 \
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
has "the nonce is in the chief letter's shape" "$b" "Z-j2599a-"
has "the chief is named" "$b" "$CHIEF"
has "the handover root is named" "$b" "$WORK/handovers"
has "the Tier line is exact" "$b" "> **Tier:** opus — unverified-finding: a finding the chief could not verify at Sonnet"
has "the PR head is evidence" "$b" "$HEAD40"
has "the ticket is evidence" "$b" "HIMMEL-3254"
has "the author doc is evidence" "$b" "$WORK/author-doc.md"
has "an attack-list item is carried" "$b" "a bullet with trailing prose after the replaces clause"
has "a chief-supplied evidence item is carried" "$b" "the reviewer's finding text"
has "the Lifecycle rule from the template survives" "$b" "**Lifecycle — the one rule.**"
has "the front matter has the description" "$b" "description: \"Rule on whether the succession tracker's bullet parse is strict\""
has "resume_cwd is the scratch dir outside the handover root" "$b" "resume_cwd: $WORK/verdicts/j2599a/scratch"
lacks "no <qid> placeholder is left" "$b" "<qid>"
lacks "no <chief session name> placeholder is left" "$b" "<chief session name>"
lacks "no <hex> placeholder is left" "$b" "<chief letter>"
lacks "no <TICKET> placeholder is left" "$b" "# <TICKET>"
lacks "no unfilled <free text> tier is left" "$b" "<category>: <free text>"
lacks "the chief's own conclusion field never appears" "$b" "conclusion"

# the launcher's own Tier gate: a copy arms through headed-arm-worker.sh --dry-run
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$WORK/preflight.sh"
mkdir -p "$WORK/arm" "$WORK/handovers" "$WORK/verdicts/j2599a/scratch"
rc=0; arm_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" HANDOVER_DIR="$WORK/handovers" bash "$HERE/headed-arm-worker.sh" --dry-run --judge --chief "$CHIEF" HIMMEL-3746-judge-j2599a "$DOC" "$WORK/sig" 9999999999 "$WORK/arm.log" claude-opus-5-5 2>&1)" || rc=$?
if [ "$rc" = 0 ] && case "$arm_out" in *"headed-arm-worker: would exec:"*) true ;; *) false ;; esac; then
    pass "headed-arm-worker --judge's Tier and prior-art gates accept the generated brief (dry-run completed, rc 0)"
else
    fail "headed-arm-worker --judge did not complete a dry run on the generated brief (rc=$rc): $arm_out"
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
    python3 "$SUT" "$WORK/$2.json" --chief "$CHIEF" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>"$WORK/$2.err"; rc=$?
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

gen_ok() {
    rm -rf "$BUCKET"
    gen_out="$(python3 "$SUT" "$WORK/$1.json" --chief "$CHIEF" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" 2>"$WORK/$1.err")"; gen_rc=$?
    gen_doc="$(cat "$BUCKET"/*-judge-j2599a-*.md 2>/dev/null)"
}
mutate dfind 'd["delta_class"]="finding"; del d["tier"]'
gen_ok dfind
[ "$gen_rc" = 0 ] && pass "a finding-class delta spec generates (rc 0)" || fail "finding delta rc=$gen_rc: $(cat "$WORK/dfind.err")"
has "a finding delta prints model=claude-sonnet-5-5" "$gen_out" "model=claude-sonnet-5-5"
has "a finding delta brief names the Sonnet judge" "$gen_doc" "You are the judge for \`j2599a\`, claude-sonnet-5-5"
has "a finding delta brief carries the DELTA-JUDGE marker line for the head" "$gen_doc" "
DELTA-JUDGE: $HEAD40
"
has "a finding delta brief has a sonnet Tier line" "$gen_doc" "> **Tier:** sonnet — "
lacks "a finding delta brief has no opus Tier line" "$gen_doc" "> **Tier:** opus"
if [ -f "$DOC" ]; then
    bash "$HERE/brief-lint.sh" "$DOC" 2>"$WORK/lint2.err"; rc=$?
    [ "$rc" = 0 ] && pass "a finding delta brief passes brief-lint.sh" || fail "finding delta brief-lint rc=$rc: $(cat "$WORK/lint2.err")"
else fail "a finding delta brief passes brief-lint.sh (no brief written)"; fi

gen_ok spec
has "a first judge prints model=claude-opus-5-5" "$gen_out" "model=claude-opus-5-5"
lacks "a first judge brief carries no DELTA-JUDGE marker" "$gen_doc" "DELTA-JUDGE:"
mutate dtrust 'd["delta_class"]="trust"'
gen_ok dtrust
has "a trust delta prints model=claude-opus-5-5" "$gen_out" "model=claude-opus-5-5"
lacks "a trust delta brief carries no DELTA-JUDGE marker" "$gen_doc" "DELTA-JUDGE:"
has "a trust delta brief keeps the opus Tier line" "$gen_doc" "> **Tier:** opus — "

mutate dnone 'd["delta_class"]="none"';                              refuse "a none delta is refused: it needs no judge" dnone "delta_class"
mutate dbad 'd["delta_class"]="full"';                               refuse "an unknown delta_class is refused" dbad "delta_class"
mutate dnopr 'd["delta_class"]="finding"; del d["pr"]; del d["head"]'; refuse "a finding delta with no PR head is refused" dnopr "delta_class"
mutate dopus 'd["delta_class"]="finding"; d["model"]="claude-opus-5-5"'; refuse "a finding delta pinned to opus is refused" dopus "delta_class"

# The nonce <letter>-<qid>-<hex> must stay inside the vault token grammar (1-3 upper-case letters).
jletter() { # <label> <stderr fragment> <args...>: refused, rc 1, nothing written
    local n="$1" frag="$2"; shift 2
    rm -rf "$BUCKET"
    python3 "$SUT" "$WORK/spec.json" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" "$@" >/dev/null 2>"$WORK/jl.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/jl.err" && ! ls "$BUCKET"/*.md >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/jl.err"))"; fi
}
jletter "a 4-letter --letter is refused" "letter" --chief "$CHIEF" --letter ABCD
jletter "a lower-case --letter is refused" "letter" --chief "$CHIEF" --letter z
jletter "an explicitly empty --letter is refused" "letter" --chief "$CHIEF" --letter ""
jletter "a letter derived from the chief name that is 4 letters long is refused" "letter" --chief HIMMEL-nextleg-2026-10-13ABCD-roadmap-chief
rm -rf "$BUCKET"
python3 "$SUT" "$WORK/spec.json" --chief "$CHIEF" --letter ABC --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'ABC-j2599a-' "$BUCKET"/HIMMEL-3746-judge-j2599a-*.md && pass "a 3-letter --letter is accepted and minted" || fail "3-letter letter rc=$rc"

# The removal release refuses --console even with compatibility enabled.
rm -rf "$BUCKET"
HIMMEL_LEGACY_NAMES=1 python3 "$SUT" "$WORK/spec.json" --console "$CHIEF" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>"$WORK/old.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'unrecognized arguments: --console' "$WORK/old.err" && ! ls "$BUCKET"/*.md >/dev/null 2>&1 && pass "the old --console is unknown and writes no brief" || fail "old --console rc=$rc: $(cat "$WORK/old.err")"
! grep -q 'is deprecated: use' "$WORK/old.err" && pass "the old --console offers no forwarding" || fail "old --console still forwards: $(cat "$WORK/old.err")"
rm -rf "$BUCKET"
HIMMEL_LEGACY_NAMES=0 python3 "$SUT" "$WORK/spec.json" --console "$CHIEF" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>"$WORK/off.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'unrecognized arguments: --console' "$WORK/off.err" && ! ls "$BUCKET"/*.md >/dev/null 2>&1 && pass "legacy names off: --console is an unknown option (rc 2, nothing written)" || fail "off --console rc=$rc: $(cat "$WORK/off.err")"
rm -rf "$BUCKET"
python3 "$SUT" "$WORK/spec.json" --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>"$WORK/none.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'required: --chief' "$WORK/none.err" && pass "no chief flag at all is still refused (rc 2)" || fail "missing chief rc=$rc: $(cat "$WORK/none.err")"
python3 "$SUT" "$WORK/spec.json" --chief "$CHIEF" --letter ABC --bucket "$BUCKET" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" >/dev/null 2>&1

# the judge reads pin to the PR head sha directly, never FETCH_HEAD
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
gb="$(cat "$BUCKET"/HIMMEL-3746-judge-j2599a-*.md 2>/dev/null)"
has "generated brief names the sha-pinned read" "$gb" "git cat-file -t $HEAD40"
has "generated brief names the sha-pinned diff" "$gb" "git diff origin/main...$HEAD40"
has "generated brief names the sha-pinned tree read" "$gb" "git show $HEAD40:<path>"
has "generated brief forbids FETCH_HEAD" "$gb" "never FETCH_HEAD"
lacks "generated brief has no FETCH_HEAD tree read" "$gb" "git show FETCH_HEAD"
lacks "generated brief gives no refspec fetch" "$gb" "refs/judge/pr-"
for f in .claude/agents/judge.md .claude/agents/judge-ro.md docs/handover/chief-sections/judge.md docs/handover/judge-brief-template.md; do
    c="$(cat "$REPO_ROOT/$f")"
    has "$f names the sha-pinned read" "$c" "git cat-file -t <sha>"
    lacks "$f gives no refspec fetch" "$c" "refs/judge/pr-"
    has "$f forbids FETCH_HEAD" "$c" "never FETCH_HEAD"
done

CREPO="$WORK/crepo"
mkdir -p "$CREPO"
(
    cd "$CREPO" && git -c init.defaultBranch=main init -q && git config user.email t@t && git config user.name t \
        && git config commit.gpgsign false && printf 'do_a() {\n  :\n}\n' > a.sh && git add a.sh && git commit -qm base \
        && git update-ref refs/remotes/origin/main HEAD && printf '# more\n' >> a.sh && git commit -qam change
) || fail "ceilings fixture repo"
CHEAD="$(git -C "$CREPO" rev-parse HEAD)"
printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote\nC-0001\ta.sh\tdo_a\tthe a.sh helper never handles CRLF\ta CRLF report\t\topen\t2026-11-08\t\t\n' > "$WORK/ceilings.tsv"
cp "$(command -v bash)" "$WORK/claude"
sed -e "s/\"head\": \"$HEAD40\"/\"head\": \"$CHEAD\"/" -e 's/"qid": "j2599a"/"qid": "j2599c"/' "$WORK/spec.json" > "$WORK/cspec.json"
cbrief() { # <ledger> <letter> [env...]: generate the ceilings brief under a claude-named shell, cwd in the fixture repo
    local led=$1 letter=$2
    shift 2
    rm -rf "$WORK/cbucket"
    # shellcheck disable=SC2016  # the single-quoted script runs in the claude-named shell
    (cd "$CREPO" && env -u ANTHROPIC_BASE_URL -u ANTHROPIC_MODEL -u HERMES_ENGINE -u CODEX_ADAPTER -u CODEX_THREAD_ID -u CLAUDE_PID \
        CLAUDECODE=1 HIMMEL_CEILINGS_LEDGER="$led" "$@" "$WORK/claude" -c 'python3 "$0" "$@"; rc=$?; exit $rc' "$SUT" "$WORK/cspec.json" \
        --chief "$CHIEF" --bucket "$WORK/cbucket" --date 2026-10-13 --letter "$letter" --handover-root "$WORK/handovers" --scratch-root "$WORK/cverdicts") >/dev/null 2>&1
    cat "$WORK"/cbucket/*-judge-j2599c-2026-10-13-RESUME.md 2>/dev/null
}
cb="$(cbrief "$WORK/ceilings.tsv" C)"
has "ceilings: the brief carries the row" "$cb" "C-0001 a.sh [do_a]"
has "ceilings: the item says cite by id only" "$cb" "Cite a row by its id only; never quote its ceiling or trigger."
has "ceilings: the item names the primary-checkout lookup by absolute path" "$cb" "bash $(cd "$HERE/../.." && pwd)/ledger/ceiling-lookup.sh --range origin/main...$CHEAD"
printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote\n' > "$WORK/empty-ceilings.tsv"
cb="$(cbrief "$WORK/empty-ceilings.tsv" D)"
has "ceilings: an empty ledger says none" "$cb" "CEILINGS: none for the 1 touched files"
cb="$(cbrief "$WORK/no-such-ceilings.tsv" E)"
has "ceilings: a missing ledger says not read" "$cb" "CEILINGS: not read (no ledger for"
lacks "ceilings: the main fixture spec's brief (no such head) still carries no row" "$b" "C-0001"
python3 - "$WORK/cspec.json" "$WORK/nopr.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1])); s.pop('pr'); s.pop('head'); s['qid'] = 'j2599d'; s['completion'] = 'Rule GO or NO-GO.'
json.dump(s, open(sys.argv[2], 'w'))
PYEOF
rm -rf "$WORK/nbucket"
(cd "$CREPO" && HIMMEL_CEILINGS_LEDGER="$WORK/ceilings.tsv" python3 "$SUT" "$WORK/nopr.json" --chief "$CHIEF" --bucket "$WORK/nbucket" \
    --date 2026-10-13 --letter F --handover-root "$WORK/handovers" --scratch-root "$WORK/nverdicts") >/dev/null 2>&1
nb="$(cat "$WORK"/nbucket/*-judge-j2599d-2026-10-13-RESUME.md 2>/dev/null)"
has "ceilings: control, the no-pr brief was written" "$nb" "j2599d"
lacks "ceilings: a spec with no pr carries no ceilings item" "$nb" "Recorded ceilings"

# --dispatch-json: one native Agent input object on stdout, no bucket, lock or RESUME write.
HOOKS_DIR="$(cd "$HERE/../../hooks" && pwd)"
DBUCKET="$WORK/dbucket"; DSCRATCH="$WORK/dverdicts"
dj() { # <spec name>: run dispatch mode; stdout -> $dj_out, stderr -> $WORK/dj.err, rc -> $dj_rc
    dj_out="$(python3 "$SUT" "$WORK/$1.json" --chief "$CHIEF" --dispatch-json --bucket "$DBUCKET" --date 2026-10-13 \
        --scratch-root "$DSCRATCH" 2>"$WORK/dj.err")"; dj_rc=$?
}
jf() { printf '%s' "$dj_out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(json.dumps(v) if not isinstance(v, str) else v)' "$1" 2>/dev/null; }
guards() { # <payload json>: "<agent-model rc> <subagent-model rc> <agent-model stdout bytes>"
    local o1 r1 r2
    o1="$(printf '%s' "$1" | bash "$HOOKS_DIR/guard-agent-model.sh" 2>/dev/null)"; r1=$?
    printf '%s' "$1" | env -u SUBAGENT_MODEL_OK bash "$HOOKS_DIR/guard-subagent-model.sh" >/dev/null 2>&1; r2=$?
    printf '%s %s %s' "$r1" "$r2" "${#o1}"
}
as_call() { printf '%s' "$1" | python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":json.load(sys.stdin)}))'; }

dj spec
[ "$dj_rc" = 0 ] && pass "dispatch: a first judge spec emits (rc 0)" || fail "dispatch rc=$dj_rc: $(cat "$WORK/dj.err")"
keys="$(printf '%s' "$dj_out" | python3 -I -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)"
[ "$keys" = "description,model,prompt,run_in_background,subagent_type" ] && pass "dispatch: stdout is exactly one Agent input object" || fail "dispatch keys: '$keys' out: $dj_out"
[ "$(jf subagent_type)" = "judge-ro" ] && pass "dispatch: subagent_type is judge-ro" || fail "dispatch subagent_type: $(jf subagent_type)"
[ "$(jf model)" = "opus" ] && pass "dispatch: a first judge maps claude-opus-5-5 to the alias opus" || fail "dispatch model: $(jf model)"
[ "$(jf run_in_background)" = "false" ] && pass "dispatch: run_in_background is false" || fail "dispatch bg: $(jf run_in_background)"
p="$(jf prompt)"
has "dispatch: the prompt carries the question" "$p" "Does PR 2599 parse the SUCCESSION bullet strictly enough that an ambiguous line reads missing?"
has "dispatch: the prompt carries the head" "$p" "git diff origin/main...$HEAD40"
has "dispatch: the prompt carries a RETASK nonce in the chief letter's shape" "$p" "RETASK: your nonce is \`Z-j2599a-"
has "dispatch: the prompt names the direct parent as the only authority" "$p" "direct parent"
has "dispatch: the prompt is read-only" "$p" "read-only"
has "dispatch: the prompt carries the result contract" "$p" "**GO**"
jbl="$(printf '%s\n' "$p" | grep -E '^JUDGE-BRIEF: [0-9a-f]{16}$')"
[ -n "$jbl" ] && pass "dispatch: the prompt carries a JUDGE-BRIEF line of its own" || fail "dispatch: no JUDGE-BRIEF line"
rt="$(printf '%s' "$p" | grep -oE 'Z-j2599a-[0-9a-f]{8}' | head -1)"
case "$jbl" in *"${rt##*-}"*) fail "dispatch: the JUDGE-BRIEF marker reuses the RETASK nonce" ;; *) pass "dispatch: JUDGE-BRIEF and RETASK are distinct nonces" ;; esac
lacks "dispatch: no headed-session lock instruction" "$p" "queue-lock"
lacks "dispatch: no RESUME instruction" "$p" "RESUME"
lacks "dispatch: no scratch-file instruction for a judge with no Write tool" "$p" "Put every scratch file"
lacks "dispatch: no DELTA-JUDGE on a first judge" "$p" "DELTA-JUDGE:"
lacks "dispatch: no ESCALATION on a first judge" "$p" "ESCALATION:"
[ ! -e "$DBUCKET" ] && pass "dispatch: no bucket document written" || fail "dispatch wrote $DBUCKET: $(ls -R "$DBUCKET")"
[ ! -e "$DSCRATCH" ] && pass "dispatch: no scratch dir created" || fail "dispatch created $DSCRATCH"
diag="$(cat "$WORK/dj.err")"
has "dispatch: diagnostics go to stderr" "$diag" "model=opus"
first="$dj_out"; dj spec
[ "$dj_rc" = 0 ] && [ ! -e "$DBUCKET" ] && pass "dispatch: rerunning the same qid succeeds with no write" || fail "dispatch rerun rc=$dj_rc"
g="$(guards "$(as_call "$first")")"
[ "$g" = "0 0 0" ] && pass "dispatch: a first judge passes both model guards silently" || fail "first judge guards: $g"

mutate nodo 'del d["do_not"]'
dj nodo
lacks "dispatch: the default scope names no verdict file for an in-process judge" "$(jf prompt)" "verdict file"
has "dispatch: the default scope says the verdict is the reply" "$(jf prompt)" "your verdict is your reply"

dj dfind
[ "$dj_rc" = 0 ] && [ "$(jf model)" = "sonnet" ] && pass "dispatch: a finding delta maps to the alias sonnet" || fail "finding delta rc=$dj_rc model=$(jf model): $(cat "$WORK/dj.err")"
has "dispatch: a finding delta carries its DELTA-JUDGE line" "$(jf prompt)" "
DELTA-JUDGE: $HEAD40
"
g="$(guards "$(as_call "$dj_out")")"
[ "$g" = "0 0 0" ] && pass "dispatch: a finding delta passes both model guards" || fail "finding delta guards: $g"
dj dtrust
[ "$dj_rc" = 0 ] && [ "$(jf model)" = "opus" ] && pass "dispatch: a trust delta stays on opus" || fail "trust delta rc=$dj_rc model=$(jf model)"
g="$(guards "$(as_call "$dj_out")")"
[ "$g" = "0 0 0" ] && pass "dispatch: a trust delta passes both model guards" || fail "trust delta guards: $g"

djrefuse() { # <label> <spec name> <stderr fragment>
    dj "$2"
    if [ "$dj_rc" = 1 ] && [ -z "$dj_out" ] && grep -q "$3" "$WORK/dj.err" && [ ! -e "$DBUCKET" ]; then pass "$1"; else fail "$1 (rc=$dj_rc, out=$dj_out, err: $(cat "$WORK/dj.err"))"; fi
}
mutate fnr 'd["model"]="claude-fable-5-2"'
djrefuse "dispatch: Fable without an escalation_reason is refused" fnr "escalation_reason"
mutate fph 'd["model"]="claude-fable-5-2"; d["escalation_reason"]="n/a"'
djrefuse "dispatch: Fable with a placeholder escalation_reason is refused" fph "escalation_reason"
mutate fshort 'd["model"]="claude-fable-5-2"; d["escalation_reason"]="hard"'
djrefuse "dispatch: Fable with a too-short escalation_reason is refused" fshort "escalation_reason"
mutate fok 'd["model"]="claude-fable-5-2"; d["escalation_reason"]="a cross-file lock replay Opus returned above-my-tier on"'
dj fok
[ "$dj_rc" = 0 ] && [ "$(jf model)" = "fable" ] && pass "dispatch: Fable with a valid escalation_reason maps to the alias fable" || fail "fable ok rc=$dj_rc model=$(jf model): $(cat "$WORK/dj.err")"
has "dispatch: Fable renders the ESCALATION line" "$(jf prompt)" "
ESCALATION: a cross-file lock replay Opus returned above-my-tier on
"
g="$(guards "$(as_call "$dj_out")")"
[ "${g% *}" = "0 0" ] && pass "dispatch: a Fable judge with its reason passes both model guards" || fail "fable guards: $g"
stripped="$(printf '%s' "$dj_out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d["prompt"]="\n".join(l for l in d["prompt"].split("\n") if not l.startswith("ESCALATION:")); print(json.dumps(d))')"
g="$(guards "$(as_call "$stripped")")"
[ "${g%% *}" = "2" ] && pass "dispatch: the same Fable call without its ESCALATION line is denied" || fail "stripped fable guards: $g"
mutate fhaiku 'd["model"]="claude-haiku-5-5"'
djrefuse "dispatch: a Haiku judge is refused" fhaiku "haiku"
mutate fold 'd["model"]="claude-opus-4-1-20250805"'
djrefuse "dispatch: an unrepresentable model id is refused" fold "alias"
mutate f1m 'd["model"]="claude-opus-5-5[1m]"'
djrefuse "dispatch: a session-only model setting is refused" f1m "alias"
mutate erlegacy 'd["escalation_reason"]="a cross-file lock replay Opus returned above-my-tier on"'
dj erlegacy
[ "$dj_rc" = 1 ] && grep -q "escalation_reason" "$WORK/dj.err" && pass "dispatch: an escalation_reason on a non-Fable judge is refused" || fail "non-fable reason rc=$dj_rc: $(cat "$WORK/dj.err")"

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
