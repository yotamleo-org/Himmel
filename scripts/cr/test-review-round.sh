#!/usr/bin/env bash
# review-round.sh promote over a finding row with a blank head.
# Scratch repo and scratch ledger only; the real ledger is never touched.
# Bash 3.2-safe; no network.
# The start-bounded rows set PATH and TMPDIR for one start inside a subshell on purpose, pass a
# single-quoted script to bash -c, and glob a temp dir with ls: each is the intended shape.
# shellcheck disable=SC2030,SC2031,SC2016,SC2012
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }
assert_has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac; }
assert_lacks() { case "$1" in *"$2"*) fail "$3 (unexpected '$2'; got: $1)" ;; *) pass "$3" ;; esac; }

fx="$tmp/fx"
mkdir -p "$fx/scripts/cr" "$fx/scripts/guardrails" "$fx/scripts/lib"
for f in anchor-handoff.sh base-resolver.sh review-round.sh ledger-append.sh ledger-amend-auth.js \
         known-findings.sh known-findings.json critic-pre-existing-tag.py; do
    cp "$HERE/$f" "$fx/scripts/cr/$f"
done
for f in chokepoint-seam-guard.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh gh-read.sh open-review-threads.sh qmd-bounded.sh; do
    cp "$HERE/../lib/$f" "$fx/scripts/lib/$f"
done
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/lib.sh"
mkdir -p "$tmp/ghr-root"
printf 'himmel_github_token_vm2=%s\n' ghp_ROUNDSREADTOKEN > "$tmp/ghr-root/.env"
export GH_READ_ENV_ROOT="$tmp/ghr-root" HIMMEL_SECRETS_KEYRING=off
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
export HOME="$tmp/home"
mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
chmod 600 "$HOME/.config/himmel/go-hmac.key"

repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    printf 'base\n' > f.txt
    git add f.txt
    git commit -q -m base
    printf 'a\n' >> f.txt
    git commit -q -am head-a
    printf 'b\n' >> f.txt
    git commit -q -am head-b
) || { printf 'FAIL - fixture setup\n' >&2; exit 1; }
head_a="$(git -C "$repo" rev-parse HEAD~1)"
head_b="$(git -C "$repo" rev-parse HEAD)"
git_dir="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
ledger="$git_dir/cr-critic-scores.jsonl"
: > "$ledger"
LA="$fx/scripts/cr/ledger-append.sh"
RR="$fx/scripts/cr/review-round.sh"

# The shape of a row: model, severity, file, artifact. A scenario sets these for the real-head
# row (TW_*) and the blank-head row (BL_*); shapes() puts both back to the same default.
shapes() {
    TW_MODEL=stub TW_SEV=sug TW_FILE=f.txt TW_ART=diff TW_PERSP=off
    BL_MODEL=stub BL_SEV=sug BL_FILE=f.txt BL_ART=diff BL_HEAD=""
}
shapes

# A finding the way the production writer shapes it, at a head.
real_row() { # branch head id verdict [text]
    local x=""
    case "$4" in
        deferred) x="--deferred-to HIMMEL-9001 --fu-class polish --reason tracked" ;;
        disproved) x="--reason disproved" ;;
    esac
    if [ -n "${5:-}" ]; then
        # shellcheck disable=SC2086  # $x is a fixed list of one-word flags and values
        CR_LEDGER="$ledger" bash "$LA" finding --branch "$1" --head "$2" --model "$TW_MODEL" --id "$3" \
            --severity "$TW_SEV" --file "$TW_FILE" --line 1 --verdict "$4" --artifact "$TW_ART" \
            --perspective "$TW_PERSP" --text "$5" $x || fail "fixture write failed: $3"
    else
        # shellcheck disable=SC2086
        CR_LEDGER="$ledger" bash "$LA" finding --branch "$1" --head "$2" --model "$TW_MODEL" --id "$3" \
            --severity "$TW_SEV" --file "$TW_FILE" --line 1 --verdict "$4" --artifact "$TW_ART" \
            --perspective "$TW_PERSP" $x || fail "fixture write failed: $3"
    fi
}
# The defect: a finding row written with no real head, which ledger-append can no longer write.
blank_row() { # branch id verdict [perspective]
    local extra=""
    [ "$3" != deferred ] || extra=',"deferred_to":"HIMMEL-9001","fu_class":"polish"'
    printf '{"kind":"finding","ts":"2026-11-02T17:20:47Z","branch":"%s","head":"%s","model":"%s","finding_id":"%s","severity":"%s","file":"%s","line":"","verdict":"%s","artifact":"%s","perspective":"%s"%s}\n' \
        "$1" "$BL_HEAD" "$BL_MODEL" "$2" "$BL_SEV" "$BL_FILE" "$3" "$BL_ART" "${4:-off}" "$extra" >> "$ledger"
}
# promote <branch>: sets out, err, rc; the ledger is read before and after.
promote() {
    git -C "$repo" branch -f "$1" "$head_b" >/dev/null 2>&1
    git -C "$repo" checkout -q "$1"
    before="$(cksum < "$ledger")"
    out="$(cd "$repo" && bash "$RR" promote --branch "$1" --head "$head_b" 2>"$tmp/err")"; rc=$?
    err="$(cat "$tmp/err")"
    after="$(cksum < "$ledger")"
}
refused() { # label: the last promote exited 1, said blank head, wrote nothing (callers check the id)
    assert_eq "$rc" "1" "$1: promote refuses"
    assert_has "$err" "blank head" "$1: the refusal says blank head"
    assert_eq "$before" "$after" "$1: a refused promote writes nothing"
}

# (1) five blank-head rows shaped like the ones on PR 4582 (model coverage-deferral, sug, deferred,
# empty file), their rows at a real head written later: all five are skipped and counted.
TW_MODEL=coverage-deferral TW_FILE="" BL_MODEL=coverage-deferral BL_FILE=""
for n in 8830 8859 8864 8865 8866; do blank_row rr-twin "cov-$n" deferred; done
for n in 8830 8859 8864 8865 8866; do real_row rr-twin "$head_a" "cov-$n" deferred; done
shapes
promote rr-twin
assert_eq "$rc" "0" "five PR-4582-shaped blank rows with later twins let promote exit 0"
assert_has "$out" "skip-blank-head cov-8866" "a skipped blank-head row is named"
assert_has "$out" "5 blank-head skipped" "the summary line counts the skipped blank-head rows"
assert_eq "$before" "$after" "skipping blank-head rows rewrites and deletes nothing"

# (2) no twin: promote refuses, names the id, and says blank head, not write failure.
blank_row rr-notwin cov-2 deferred
promote rr-notwin
refused "no twin"
assert_has "$err" "cov-2" "no twin: the refusal names the finding id"
assert_lacks "$err" "ledger write failed" "no twin: the refusal is not reported as a write failure"

# (3) the twin decides: an unadjudicated twin keeps promote from passing.
blank_row rr-open cov-3 deferred
real_row rr-open "$head_a" cov-3 ""
promote rr-open
assert_eq "$rc" "3" "a blank-head row whose twin is still open does not let promote pass"
assert_has "$out" "still-open cov-3@" "the twin is reported still-open"
assert_has "$out" "skip-blank-head cov-3" "the blank-head row is still skipped, not judged"

# (4) the twin decides: an agreed twin re-raised at the clean head stays open.
blank_row rr-reraise cov-4 ""
real_row rr-reraise "$head_a" cov-4 "" "tidy the cov-4 fixture"
CR_LEDGER="$ledger" bash "$LA" amend --branch rr-reraise --head "$head_a" --id cov-4 \
    --set verdict=agreed --reason "agreed in the fixture" 2>/dev/null || fail "fixture amend failed: cov-4"
real_row rr-reraise "$head_b" cov-4b "" "tidy the cov-4 fixture"
promote rr-reraise
assert_eq "$rc" "3" "a blank-head row whose twin is re-raised does not let promote pass"
assert_has "$out" "still-open cov-4@" "the re-raised twin is reported still-open"

# (5) an agreed twin that was not re-raised is promoted as usual; the blank row adds nothing.
blank_row rr-promote cov-5 ""
real_row rr-promote "$head_a" cov-5 "" "tidy the cov-5 fixture"
CR_LEDGER="$ledger" bash "$LA" amend --branch rr-promote --head "$head_a" --id cov-5 \
    --set verdict=agreed --reason "agreed in the fixture" 2>/dev/null || fail "fixture amend failed: cov-5"
promote rr-promote
assert_eq "$rc" "0" "a blank-head row beside a promotable twin lets promote exit 0"
assert_has "$out" "promoted cov-5@" "the twin is promoted"
assert_has "$out" "skip-blank-head cov-5" "the blank-head row is skipped"

# (6) a twin must be on the same branch.
blank_row rr-elsewhere cov-6 deferred
real_row rr-other "$head_a" cov-6 deferred
promote rr-elsewhere
refused "twin on another branch"
assert_has "$err" "cov-6" "twin on another branch: the refusal names the id"

# (7) a twin must share the perspective.
blank_row rr-persp cov-7 deferred off
TW_PERSP=on
real_row rr-persp "$head_a" cov-7 deferred
shapes
promote rr-persp
refused "twin under another perspective"

# (8) an empty finding id cannot have a twin.
blank_row rr-noid "" deferred
BL_HEAD="$head_a"
blank_row rr-noid "" deferred
shapes
promote rr-noid
refused "no finding id, even beside a later row that has none either"

# (9) a twin must share the artifact.
BL_ART=diff TW_ART=spec
blank_row rr-art cov-9 deferred
real_row rr-art "$head_a" cov-9 deferred
shapes
promote rr-art
refused "twin under another artifact"

# (10) a twin must share the model.
TW_MODEL=other-critic
blank_row rr-model cov-10 deferred
real_row rr-model "$head_a" cov-10 deferred
shapes
promote rr-model
refused "twin from another model"

# (11) a twin must share the severity: a Critical blank row beside a sug row of that id.
BL_SEV=crit
blank_row rr-sev cov-11 ""
real_row rr-sev "$head_a" cov-11 deferred
shapes
promote rr-sev
refused "twin with another severity"

# (12) a twin must share the file.
TW_FILE=z.sh
blank_row rr-file cov-12 deferred
real_row rr-file "$head_a" cov-12 deferred
shapes
promote rr-file
refused "twin on another file"

# (13) a twin must come after the blank row in the ledger: an older row is not its retry.
real_row rr-order "$head_a" cov-13 deferred
blank_row rr-order cov-13 deferred
promote rr-order
refused "twin earlier in the file"

# (14) a twin must carry a commit-shaped head.
blank_row rr-shape cov-14 deferred
real_row rr-shape not-a-commit cov-14 deferred
promote rr-shape
refused "twin at a head that is not commit-shaped"

# (14b) a twin must carry a head that names a commit here, not only one shaped like a commit.
blank_row rr-ghost cov-14b deferred
real_row rr-ghost 0123456789012345678901234567890123456789 cov-14b deferred
promote rr-ghost
refused "twin at a commit-shaped head that is not a commit here"

# (14c) a spec row headed by a document id cannot rescue a blank row (a document id is no commit either).
BL_ART=spec TW_ART=spec
blank_row rr-spec cov-14c deferred
real_row rr-spec design-doc-1 cov-14c deferred
shapes
promote rr-spec
refused "spec row whose twin is headed by a document id"

# (14d) a ref name that resolves to a commit is not a commit-shaped head: ledger-append writes any
# non-hex head verbatim, and HEAD resolves here, so only the shape rule keeps it from rescuing a blank row.
blank_row rr-refname cov-14d deferred
real_row rr-refname HEAD cov-14d deferred
promote rr-refname
refused "twin headed by a ref name that resolves to a commit"

# (15) two blank rows of one id do not vouch for each other.
blank_row rr-two cov-15 deferred
blank_row rr-two cov-15 deferred
promote rr-two
refused "two blank rows and no real head"

# (16) a Critical blank row beside an older, disproved sug row of the same id (ids recur across PRs):
# the case that would otherwise pass promote with an open Critical in the ledger.
real_row rr-recur "$head_a" codex-1 disproved
BL_MODEL=claude-floor BL_SEV=crit BL_FILE=z.sh
blank_row rr-recur codex-1 ""
shapes
promote rr-recur
refused "Critical blank row beside an older disproved row of that id"

# (17) a head of only spaces is blank, and a twin rescues it like any blank row.
BL_HEAD="  "
blank_row rr-space cov-17 deferred
shapes
real_row rr-space "$head_a" cov-17 deferred
promote rr-space
assert_eq "$rc" "0" "a whitespace-only head row beside a later twin lets promote exit 0"
assert_has "$out" "skip-blank-head cov-17" "the whitespace-only head row is skipped like a blank one"

# (18) promote --check: the merge's gate 4c verdict as a read. Same decisions as the real verb, nothing written,
# and it needs no checked-out branch (it is run for a PR branch the caller does not hold).
# promote_check <branch>: sets out, err, rc, before, after, and lines_before, lines_after.
promote_check() {
    before="$(cksum < "$ledger")"; lines_before="$(wc -l < "$ledger")"
    out="$(cd "$repo" && bash "$RR" promote --check --branch "$1" --head "$head_b" 2>"$tmp/err")"; rc=$?
    err="$(cat "$tmp/err")"
    after="$(cksum < "$ledger")"; lines_after="$(wc -l < "$ledger")"
}
# (18a) an agreed, un-re-raised finding is promotable: --check reports the verdict (exit 0) and writes nothing.
real_row rr-chk "$head_a" chk-1 "" "tidy the chk-1 fixture"
CR_LEDGER="$ledger" bash "$LA" amend --branch rr-chk --head "$head_a" --id chk-1 \
    --set verdict=agreed --reason "agreed in the fixture" 2>/dev/null || fail "fixture amend failed: chk-1"
git -C "$repo" checkout -q main 2>/dev/null
promote_check rr-chk
assert_eq "$rc" "0" "18a promote --check on a promotable finding exits 0"
assert_has "$out" "chk-1@" "18a promote --check names the finding"
assert_eq "$before" "$after" "18a promote --check leaves the ledger byte-identical"
assert_eq "$lines_before" "$lines_after" "18a promote --check adds no ledger line"
# control: the real verb on the same fixture still amends the ledger.
promote rr-chk
assert_eq "$rc" "0" "18a control: the real promote exits 0"
assert_has "$out" "promoted chk-1@" "18a control: the real promote promotes the finding"
if [ "$before" != "$after" ]; then pass "18a control: the real promote rewrites the ledger"; else fail "18a control: the real promote must write"; fi
# (18b) a finding gate 4c refuses: --check exits 3, writes nothing, and says what the real verb says.
real_row rr-chk2 "$head_a" chk-2 ""
promote_check rr-chk2
assert_eq "$rc" "3" "18b promote --check on an unadjudicated finding exits 3"
assert_has "$out" "still-open chk-2@" "18b promote --check names the still-open finding"
assert_eq "$before" "$after" "18b promote --check leaves the ledger byte-identical on a refusal"
assert_eq "$lines_before" "$lines_after" "18b promote --check adds no ledger line on a refusal"
check_out="$out"
promote rr-chk2
assert_eq "$rc" "3" "18b control: the real promote exits 3 on the same fixture"
assert_eq "$check_out" "$out" "18b one verdict: --check prints what the real promote prints"
# (18c) --check belongs to promote.
bad_rc=0; (cd "$repo" && bash "$RR" from --check --branch rr-chk2 >/dev/null 2>&1) || bad_rc=$?
assert_eq "$bad_rc" "2" "18c --check on another verb is a usage error"

git -C "$repo" checkout -q main 2>/dev/null

# (19) start|check --pr <n> --head <H> reviews an outside PR whose branch is not checked out.
# The gh stub serves the author, the head branch and the head; the lib reads them, the caller cannot name them.
cp "$HERE/../lib/outside-contributors.sh" "$HERE/../lib/timeout-bin.sh" "$fx/scripts/lib/"
mkdir -p "$tmp/prbin" "$fx/scripts/cr/perspectives"
cat > "$tmp/prbin/gh" <<'STUB'
#!/usr/bin/env bash
printf '{"author":{"login":"%s","id":"%s"},"headRefName":"feat/outside-thing","headRefOid":"%s"}\n' "$STUB_LOGIN" "$STUB_ID" "$STUB_OID"
STUB
chmod +x "$tmp/prbin/gh"
printf '# fixture outside-security perspective\n' > "$fx/scripts/cr/perspectives/outside-security.md"
psha="$(sha256sum < "$fx/scripts/cr/perspectives/outside-security.md" | cut -d' ' -f1)"
mkdir -p "$HOME/.himmel"
appr="$HOME/.himmel/outside-pr-approvals.jsonl"
printf '[{"login":"Goomal","id":"U_goomal"}]\n' > "$HOME/.himmel/outside-contributors.json"
(
    cd "$repo" || exit 1
    for n in 3 4 5; do printf 'p%s\n' "$n" >> f.txt; git commit -q -am "head-$n"; done
) || fail "fixture: extra heads"
h1="$head_a"; h2="$head_b"; h3="$(git -C "$repo" rev-parse HEAD~2)"; h4="$(git -C "$repo" rev-parse HEAD~1)"; h5="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b elsewhere 2>/dev/null
rr_pr() { # verb pr head [login id]: sets out, rc
    out="$(cd "$repo" && PATH="$tmp/prbin:$PATH" STUB_LOGIN="${4:-Goomal}" STUB_ID="${5:-U_goomal}" STUB_OID="$3" bash "$RR" "$1" --pr "$2" --head "$3" 2>"$tmp/err")"; rc=$?
    err="$(cat "$tmp/err")"
}
pr_state() { local f n=0; for f in "$git_dir"/cr-review-rounds/outside-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
pr_approve() { # pr head stage
    jq -nc --argjson pr "$1" --arg h "$2" --arg s "$3" '{pr:$pr,head:$h,stage:$s,from:1,chat:1,message_id:77,ts:"2026-11-06T10:00:00Z"}' >> "$appr"
}
rr_pr start 7 "$h1"
assert_eq "$rc:$out" "0:1" "T2.1 start --pr for a listed author returns a full round, branch not checked out"
assert_eq "$(cat "$git_dir/cr-review-rounds/outside-7.round" 2>/dev/null)" "1" "T2.1 the state is keyed outside-7"
assert_eq "$(cat "$git_dir/cr-review-rounds/outside-7.head" 2>/dev/null)" "$h1" "T2.1 the round records the head it ran on"
rr_pr start 7 "$h1"
assert_eq "$rc:$out" "0:1" "start --pr at the head the counted round ran on reuses that round"
before_pr="$(cksum "$git_dir"/cr-review-rounds/outside-7.* | tr '\n' ' ')"
rr_pr check 7 "$h2"
assert_eq "$rc:$out" "0:2 allowlist" "check --pr names the round a new head would take and who authorized it"
assert_eq "$(cksum "$git_dir"/cr-review-rounds/outside-7.* | tr '\n' ' ')" "$before_pr" "check --pr writes nothing"
rr_pr start 7 "$h2"; rr_pr start 7 "$h3"
assert_eq "$rc:$out" "0:3" "a third head is the third full round"
rr_pr start 7 "$h4"
assert_eq "$rc" "5" "T2.41 a 4th head for a listed author exits 5"
assert_eq "$(cat "$git_dir/cr-review-rounds/outside-7.round")" "3" "T2.41 the refused start leaves the count at 3"
rr_pr check 7 "$h4"
assert_eq "$rc" "5" "T2.41 check --pr gives the same refusal"
pr_approve 7 "$h4" review
rr_pr start 7 "$h4"
assert_eq "$rc:$out" "0:4" "T2.42 the 4th head with an exact approval returns a full round, never a delta"
rr_pr start 7 "$h5"
assert_eq "$rc" "5" "a 5th head with no approval for it exits 5"
# an unlisted author
n0="$(pr_state)"
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.40 an unlisted author's start --pr exits 5"
assert_eq "$(pr_state)" "$n0" "T2.40 and writes no state"
rr_pr check 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.40 check --pr refuses an unlisted author too"
pr_approve 9 "$h1" review
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.49 an unlisted author with a review approval and no audit row exits 5"
assert_eq "$(pr_state)" "$n0" "T2.49 and writes no state"
audit_row() { # head
    local rpt="$tmp/audit-report.md"
    printf 'report\n' > "$rpt"
    jq -nc --arg h "$1" --arg ps "$psha" --arg r "$rpt" --arg rs "$(sha256sum < "$rpt" | cut -d' ' -f1)" \
        '{kind:"security-audit",ts:"2026-11-06T10:00:00Z",pr:9,branch:"feat/outside-thing",head:$h,verdict:"pass",perspective_sha256:$ps,report:$r,report_sha256:$rs,status:"ok"}' >> "$ledger"
}
: > "$appr"; audit_row "$h1"
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.54 an unlisted author with an audit pass and no approval exits 5"
pr_approve 9 "$h1" ci
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.54 an approval with stage ci exits 5"
printf '{"pr":9,"head":"%s","message_id":78}\n' "$h1" > "$appr"
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc" "5" "T2.54 an approval with no stage exits 5"
assert_eq "$(pr_state)" "$n0" "T2.54 none of those wrote state"
: > "$appr"; pr_approve 9 "$h1" review
rr_pr start 9 "$h1" Stranger U_stranger
assert_eq "$rc:$out" "0:1" "control: the same unlisted author with both a review approval and an audit pass starts round 1"
# the old verbs still require the checked-out branch, and --pr takes no --branch
bad_rc=0; (cd "$repo" && bash "$RR" start --branch not-checked-out --head "$h1" >/dev/null 2>&1) || bad_rc=$?
assert_eq "$bad_rc" "2" "start --branch for a branch that is not checked out is still refused"
bad_rc=0; (cd "$repo" && PATH="$tmp/prbin:$PATH" STUB_LOGIN=Goomal STUB_ID=U_goomal STUB_OID="$h1" bash "$RR" start --pr 7 --branch elsewhere --head "$h1" >/dev/null 2>&1) || bad_rc=$?
assert_eq "$bad_rc" "2" "--pr with --branch is a usage error"
bad_rc=0; (cd "$repo" && bash "$RR" promote --pr 7 --head "$h1" >/dev/null 2>&1) || bad_rc=$?
assert_eq "$bad_rc" "2" "--pr belongs to start and check only"
bad_rc=0; (cd "$repo" && bash "$RR" start --pr 7 --head abc123 >/dev/null 2>&1) || bad_rc=$?
assert_eq "$bad_rc" "2" "--pr needs a full 40-hex head"
git -C "$repo" checkout -q main 2>/dev/null

mkdir -p "$tmp/thbin"
cat > "$tmp/thbin/gh" <<'STUB'
#!/usr/bin/env bash
q="" prev=""
for a in "$@"; do
    if [ "$prev" = -q ] || [ "$prev" = --jq ]; then q=$a; fi
    prev=$a
done
case "${1:-} ${2:-}" in
    "pr list") printf '%s' "$STUB_PRS" | jq -r "$q"; exit $? ;;
    "api graphql")
        [ "${STUB_THREADS_FAIL:-0}" = 1 ] && { echo "graphql boom" >&2; exit 1; }
        printf '%s' "$STUB_THREADS" | jq -r "$q"; exit $? ;;
esac
echo "unexpected gh: $*" >&2
exit 1
STUB
chmod +x "$tmp/thbin/gh"
th_resolved='{"isResolved":true,"path":"README.md","line":1,"originalLine":1,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-11-09T04:58:00Z","url":"u0"}]}}'
th_open='{"isResolved":false,"path":"scripts/jira/src/policy.ts","line":88,"originalLine":88,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-11-09T05:07:51Z","url":"https://github.com/o/r/pull/5053#discussion_r1"}]}}'
th_page() { printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}}' "$1"; }
git -C "$repo" checkout -q -b jg9712 main
jg_h="$(git -C "$repo" rev-parse HEAD)"
jg() { out="$(cd "$repo" && PATH="$tmp/thbin:$PATH" bash "$RR" judge-go --branch jg9712 --head "$jg_h" "$@" 2>&1)"; rc=$?; }
export STUB_PRS='[{"number":5053}]'
STUB_THREADS="$(th_page "$th_resolved,$th_open")"; export STUB_THREADS
jg
assert_eq "$rc" "8" "9712 judge-go refuses while PR 5053 has an unresolved thread"
assert_has "$out" "scripts/jira/src/policy.ts:88" "9712 the refusal names the thread's file and line"
assert_has "$out" "coderabbitai at 2026-11-09T05:07:51Z" "9712 the refusal names who posted it and when"
assert_has "$out" "--open-threads-ok" "9712 the refusal names the chief's override"
assert_lacks "$out" "README.md" "9712 a resolved thread is not named"
jg --open-threads-ok "chief ruled the thread answered in the PR body"
assert_eq "$rc" "1" "9712 the override passes the thread read and reaches the round check"
assert_has "$out" "WARNING" "9712 the override warns loudly"
assert_has "$out" "scripts/jira/src/policy.ts:88" "9712 the override still names the open thread"
jg --open-threads-ok 'bad "quote"'
assert_eq "$rc" "2" "9712 an override reason that cannot sit in a ledger row is refused"
STUB_THREADS="$(th_page "$th_resolved")"; export STUB_THREADS
jg
assert_eq "$rc:$(case "$out" in (*"0 of 3"*) echo round ;; esac)" "1:round" "control: every thread resolved, judge-go reaches the round check"
STUB_PRS='[]' STUB_THREADS="$(th_page "$th_open")" jg
assert_eq "$rc" "1" "control: a branch with no open PR has no thread to read"
STUB_THREADS_FAIL=1 jg
assert_eq "$rc" "1" "an unreadable thread read does not stand in for a clean one: it warns and goes on"
assert_has "$out" "could not read the review threads" "the unreadable read is named"
unset STUB_PRS STUB_THREADS
git -C "$repo" checkout -q main 2>/dev/null

# shellcheck source=../lib/qmd-bounded.sh
# shellcheck disable=SC1091
. "$fx/scripts/lib/qmd-bounded.sh"
unset CR_REVIEW_START_TIMEOUT_SECS RR_STUB_NODE RR_STUB_GIT RR_STUB_GH RR_STUB_PS RR_STUB_LOCKLIB
sb="$tmp/stub-bin"
RRTMP="$tmp/rr-tmp"
mkdir -p "$sb" "$RRTMP"
RR_REAL_NODE="$(command -v node)"; RR_REAL_GIT="$(command -v git)"; RR_REAL_PS="$(command -v ps)"
RR_REAL_GH="$tmp/prbin/gh"
export RR_REAL_NODE RR_REAL_GIT RR_REAL_PS RR_REAL_GH
cat > "$sb/node" <<'STUB'
#!/usr/bin/env bash
tag="rr-stub-${RR_STUB_TAG:-x}"
case "${RR_STUB_NODE:-}" in
    hang) [ "${MODE:-}" != avail ] || exec -a "$tag" sleep 600 ;;
    holder) [ "${3:-}" != before ] || ( exec -a "$tag" sleep 30 & ) ;;
    slow) [ "${MODE:-}" != avail ] || sleep 1 ;;
    slow-seen) [ "${MODE:-}" != seen ] || sleep 1 ;;
    term-trap) [ "${MODE:-}" != avail ] || exec bash -c 'trap "" TERM; exec -a "$0" sleep 600' "$tag" ;;
esac
exec "$RR_REAL_NODE" "$@"
STUB
cat > "$sb/git" <<'STUB'
#!/usr/bin/env bash
if [ "${RR_STUB_GIT:-}" = hang-ancestor ] && [ "${1:-}" = merge-base ] && [ "${2:-}" = --is-ancestor ]; then
    exec -a "rr-stub-${RR_STUB_TAG:-x}" sleep 600
fi
exec "$RR_REAL_GIT" "$@"
STUB
cat > "$sb/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${RR_STUB_GH:-}" = hang-pr-view ] && [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    exec -a "rr-stub-${RR_STUB_TAG:-x}" sleep 600
fi
exec "$RR_REAL_GH" "$@"
STUB
cat > "$sb/ps" <<'STUB'
#!/usr/bin/env bash
case "${RR_STUB_PS:-}" in
    hang) for a in "$@"; do [ "$a" != -A ] || exec -a "rr-stub-${RR_STUB_TAG:-x}" sleep 600; done ;;
    fail-ppid) if [ "${1:-}" = -o ] && [ "${2:-}" = "ppid=" ]; then exit 0; fi ;;
esac
exec "$RR_REAL_PS" "$@"
STUB
chmod +x "$sb/node" "$sb/git" "$sb/gh" "$sb/ps"
mv "$fx/scripts/lib/shared-branch-lock.sh" "$fx/scripts/lib/shared-branch-lock-real.sh"
cat > "$fx/scripts/lib/shared-branch-lock.sh" <<'STUB'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${RR_STUB_LOCKLIB:-}" ] && [ -e "${RR_STUB_LOCKMARK:-/nonexistent}" ]; then
    case "$RR_STUB_LOCKLIB:${1:-}" in
        hang-status:status|hang-release:release-if-owner)
            exec bash -c 'trap "" TERM; exec -a "$0" sleep 600' "rr-stub-${RR_STUB_TAG:-x}" ;;
    esac
fi
exec bash "$here/shared-branch-lock-real.sh" "$@"
STUB
LOCKLIB="$fx/scripts/lib/shared-branch-lock.sh"

rr_branch() {
    rb="$1"
    git -C "$repo" checkout -q -b "$rb" "$head_b" 2>/dev/null || { fail "$1: fixture branch"; return 1; }
    [ "${2:-}" = settled ] || return 0
    (cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_a" >/dev/null 2>&1) || fail "$1: round 1 fixture"
    CR_LEDGER="$ledger" bash "$LA" avail --branch "$rb" --head "$head_a" --model "stub-$rb" --status ok >/dev/null 2>&1 || fail "$1: avail fixture"
}
rr_save() { rm -rf "$tmp/rr-save"; cp -R "$git_dir/cr-review-rounds" "$tmp/rr-save"; }
rr_restore() { rm -rf "$git_dir/cr-review-rounds"; cp -R "$tmp/rr-save" "$git_dir/cr-review-rounds"; }
rr_begin() {
    row="$1"
    RR_STUB_TAG="$1-$$"; export RR_STUB_TAG
    rr_branch "$1" "${2:-settled}"
    rr_save
}
rr_end() { pkill -KILL -f "rr-stub-$RR_STUB_TAG" 2>/dev/null; git -C "$repo" checkout -q main 2>/dev/null; return 0; }
rr_lock_status() { (cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" status . "$1" 2>&1); }
rr_wait_tag() {
    local n=0
    while ! pgrep -f "rr-stub-$RR_STUB_TAG" >/dev/null 2>&1; do
        n=$((n + 1)); [ "$n" -le 300 ] || return 1
        sleep 0.1
    done
}
rr_reap() {
    local n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt $(($2 * 10)) ]; do n=$((n + 1)); sleep 0.1; done
    kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null; reap_rc=$?
}
rr_run_to() {
    local secs="$1" t0
    shift
    t0="$(date +%s)"
    (
        cd "$repo" || exit 1
        export PATH="$sb:$PATH" TMPDIR="$RRTMP" RR_ERRF="$tmp/rr.err"
        : > "$RR_ERRF"
        qmd_bounded "$secs" bash -c 'x="$(bash "$0" start "$@" 2>"$RR_ERRF")"; rc=$?; printf %s "$x"; exit "$rc"' "$RR" "$@"
    ) > "$tmp/rr.out" 2>/dev/null
    printf '%s\n' "$?" > "$tmp/rr.rc"
    printf '%s\n' "$(( $(date +%s) - t0 ))" > "$tmp/rr.dur"
}
rr_load() { sout="$(cat "$tmp/rr.out")"; serr="$(cat "$tmp/rr.err")"; src="$(cat "$tmp/rr.rc")"; sdur="$(cat "$tmp/rr.dur")"; }
rr_run() { rr_run_to "$@"; rr_load; }
assert_under() { if [ "$1" -lt "$2" ]; then pass "$3"; else fail "$3 (took ${1}s, want under ${2}s)"; fi; }
assert_nonempty() { if [ -n "$1" ]; then pass "$2"; else fail "$2 (empty)"; fi; }
assert_gone() { if pgrep -f "rr-stub-$RR_STUB_TAG" >/dev/null 2>&1; then fail "$1 (a stub process is still running)"; else pass "$1"; fi; }
rr_sig_run() {
    ( cd "$repo" && PATH="$sb:$PATH" TMPDIR="$RRTMP" RR_STUB_NODE=hang exec bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/sg.out" 2>"$tmp/sg.err" ) &
    sg_pid=$!
    rr_wait_tag
    sleep 1
    kill -TERM "$sg_pid" 2>/dev/null
    rr_reap "$sg_pid" 20
    sg_rc="$reap_rc"; sg_err="$(cat "$tmp/sg.err")"
    pkill -KILL -f "rr-stub-$RR_STUB_TAG" 2>/dev/null
}
rr_stop_run() {
    local o i=0 d f="$3" pair=0
    rm -rf "$RRTMP"/review-round-start.*
    ( cd "$repo" && PATH="$sb:$PATH" TMPDIR="$RRTMP" CR_REVIEW_START_TIMEOUT_SECS="$B" exec bash "$RR" start --branch "$1" --head "$2" >"$tmp/ss.out" 2>"$tmp/ss.err" ) &
    o=$!
    ss_paired=0
    while [ "$i" -lt 300 ] && kill -0 "$o" 2>/dev/null; do
        pair="$(ps -A -o pid=,ppid=,pgid= | awk -v o="$o" '$2 == o && $1 == $3 { n++ } END { print n + 0 }')"
        [ "$pair" -lt 2 ] || break
        i=$((i + 1)); sleep 0.05
    done
    if [ "$pair" -ge 2 ]; then
        ss_paired=1
        kill -STOP "$o"
        i=0; d=""
        while [ "$i" -lt 300 ]; do
            for d in "$RRTMP"/review-round-start.*; do [ -d "$d" ] && break; done
            if [ -d "$d" ] && [ -s "$d/$f" ] && [ -e "$d/flag" ]; then break; fi
            i=$((i + 1)); sleep 0.1
        done
        kill -CONT "$o"
    fi
    rr_reap "$o" 60
    ss_rc="$reap_rc"; ss_out="$(cat "$tmp/ss.out")"; ss_err="$(cat "$tmp/ss.err")"
}

RR_STUB_TAG="selfcheck-$$"; export RR_STUB_TAG
MODE=avail RR_STUB_NODE=hang qmd_bounded 2 "$sb/node" -e 1 >/dev/null 2>&1
sc_rc=$?
pkill -KILL -f "rr-stub-$RR_STUB_TAG" 2>/dev/null
if [ "$sc_rc" -ne 124 ]; then
    fail "start-bounded: the node stub in $sb does not hang under MODE=avail (rc $sc_rc)"
    printf 'FAIL test-review-round (%s failures)\n' "$fails" >&2
    exit 1
fi

rr_begin tprobe
t0="$(date +%s)"
(cd "$repo" && bash "$RR" start --branch tprobe --head "$head_b" >/dev/null 2>&1) || fail "tprobe: the plain start failed"
T=$(( $(date +%s) - t0 ))
rr_end
B=$(( 2 * T + 3 ))
[ "$B" -ge 3 ] || B=3

row=start-bounded-hung-child-stops
rr_begin "$row"
RR_STUB_NODE=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 12)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: a hung child ends in a refusal, exit 5"
assert_under "$sdur" $((B + 5)) "$row: the refusal comes inside the bound plus 5 s"
assert_has "$serr" "did not finish within ${B}s" "$row: the refusal says the bound"
assert_has "$serr" "last step: reviewed-head" "$row: the refusal names the step"
assert_has "$serr" "rr-stub-" "$row: the refusal names the stuck process"
assert_has "$serr" "the counter lock it held was released" "$row: the refusal says the lock was released"
rr_end

row=start-bounded-hung-increment-stops
rr_begin "$row"
RR_STUB_GIT=hang-ancestor CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 12)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: a hung git child ends in a refusal, exit 5"
assert_under "$sdur" $((B + 5)) "$row: the refusal comes inside the bound plus 5 s"
assert_has "$serr" "last step: increment" "$row: the refusal names the increment step"
rr_end

row=start-pr-bounded-authorize-stops
rr_begin "$row" plain
STUB_LOGIN=Goomal STUB_ID=U_goomal STUB_OID="$h1" RR_STUB_GH=hang-pr-view CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 30)) --pr 31 --head "$h1"
assert_eq "$src" "5" "$row: a hung gh read ends in a refusal, exit 5"
assert_under "$sdur" $((B + 5)) "$row: the refusal comes inside the bound plus 5 s"
assert_has "$serr" "did not finish within ${B}s" "$row: the refusal says the bound"
assert_has "$serr" "last step: authorize" "$row: the refusal names the authorize step"
assert_eq "$(rr_lock_status outside-31)" "free" "$row: the lock for outside-31 is free"
n=0; while pgrep -f "rr-stub-$RR_STUB_TAG" >/dev/null 2>&1 && [ "$n" -lt 250 ]; do n=$((n + 1)); sleep 0.1; done
rr_end

row=start-bounded-ps-hangs
rr_begin "$row"
RR_STUB_NODE=hang RR_STUB_PS=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 14)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: a hung ps still ends in a refusal, exit 5"
assert_under "$sdur" $((B + 7)) "$row: the refusal comes inside the bound plus 7 s"
assert_has "$serr" "tree not read" "$row: the refusal says the tree was not read"
rr_end

for lk in status release; do
    row="start-bounded-lock-$lk-hangs"
    rr_begin "$row"
    lm="$tmp/lockmark.$lk"; rm -f "$lm"
    if [ "$lk" = status ]; then lim=$((B + 6 + 11 + 3)); else lim=$((B + 6 + 22 + 3)); fi
    (RR_STUB_NODE=hang RR_STUB_LOCKLIB="hang-$lk" RR_STUB_LOCKMARK="$lm" QMD_KILL_GRACE_SECS=60 CR_REVIEW_START_TIMEOUT_SECS="$B" \
        rr_run_to $((lim + 30)) --branch "$rb" --head "$head_b") &
    bgp=$!
    rr_wait_tag && : > "$lm"
    wait "$bgp"
    rr_load
    assert_eq "$src" "5" "$row: a hung lock call still ends in a refusal, exit 5"
    assert_under "$sdur" "$lim" "$row: the refusal comes inside the bound plus the lock caps"
    assert_has "$serr" "the counter lock was not checked" "$row: the refusal says the lock was not checked"
    rr_end
    (cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
done

row=start-detached-holder-returns
rr_begin "$row"
RR_STUB_NODE=holder rr_run 20 --branch "$rb" --head "$head_b"
assert_eq "$src" "0" "$row: a start whose child outlives it still returns"
assert_under "$sdur" 5 "$row: the capture returns in under 5 s"
assert_nonempty "$sout" "$row: the capture holds the round answer"
rr_end

row=start-bounded-fast-same-output
rr_begin "$row"
rr_restore
(cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/i2.a.out" 2>"$tmp/i2.a.err"); a_rc=$?
rr_restore
(cd "$repo" && bash -c '_RR_START_INNER=1 _RR_START_CALLER=$PPID bash "$0" start --branch "$1" --head "$2" >"$3" 2>"$4"; r=$?; exit "$r"' \
    "$RR" "$rb" "$head_b" "$tmp/i2.b.out" "$tmp/i2.b.err"); b_rc=$?
assert_eq "$a_rc:$b_rc" "0:0" "$row: both runs exit 0"
if [ -s "$tmp/i2.a.out" ] && cmp -s "$tmp/i2.a.out" "$tmp/i2.b.out"; then pass "$row: stdout is byte-equal to the body alone"; else fail "$row: stdout differs from the body alone"; fi
if cmp -s "$tmp/i2.a.err" "$tmp/i2.b.err"; then pass "$row: stderr is byte-equal to the body alone"; else fail "$row: stderr differs from the body alone"; fi
rr_end

row=start-bounded-answer-after-bound
rr_begin "$row"
RR_STUB_NODE=slow rr_stop_run "$rb" "$head_b" out
assert_eq "$ss_rc" "0" "$row: an answered start is not refused after the bound"
assert_nonempty "$ss_out" "$row: the answer is printed"
assert_lacks "$ss_err" "did not finish" "$row: no refusal line"
rr_end

row=start-bounded-self-exit-after-bound
rr_begin "$row" plain
(cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_a" >/dev/null 2>&1) || fail "$row: round 1 fixture"
rr_save
k=0
while [ "$k" -lt 5 ]; do
    k=$((k + 1))
    rr_restore
    RR_STUB_NODE=slow-seen rr_stop_run "$rb" "$head_b" err
    assert_eq "$ss_rc" "8" "$row: run $k: a body that exits 8 by itself keeps its code"
    assert_has "$ss_err" "a dead round" "$row: run $k: the body's own stderr line is kept"
    assert_lacks "$ss_err" "did not finish" "$row: run $k: no refusal line"
    [ "$ss_paired" -eq 1 ] || break
done
rr_end

row=start-bounded-no-late-refusal
rr_begin "$row"
k=0; nl_bad=0
while [ "$k" -lt 10 ] && [ "$nl_bad" -eq 0 ]; do
    k=$((k + 1))
    rr_restore
    RR_STUB_NODE=slow CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 30)) --branch "$rb" --head "$head_b"
    if [ "$src" != 0 ] || [ -z "$sout" ]; then nl_bad=1; fail "$row: run $k: rc $src, answer '$sout', stderr: $serr"; fi
done
[ "$nl_bad" -ne 0 ] || pass "$row: ten starts near the bound all answer"
rr_end

row=start-bounded-cleans-tree-and-lock
rr_begin "$row"
RR_STUB_NODE=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 12)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: the hung start is refused, exit 5"
assert_gone "$row: no stub process is left"
assert_eq "$(rr_lock_status "$rb")" "free" "$row: the lock is free"
rr_run $((B + 30)) --branch "$rb" --head "$head_b"
assert_eq "$src" "0" "$row: the next plain start exits 0"
assert_nonempty "$sout" "$row: the next plain start gives an answer"
rr_end

row=start-bounded-term-trapping-child
rr_begin "$row"
RR_STUB_NODE=term-trap CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 12)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: a child that ignores TERM is still refused, exit 5"
assert_gone "$row: the TERM-ignoring child is gone"
rr_end

row=start-bounded-lock-other-owner-kept
rr_begin "$row"
lockdir="$git_dir/himmel-cr-review-round/$rb.lock"
(RR_STUB_NODE=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run_to $((B + 12)) --branch "$rb" --head "$head_b") &
bgp=$!
rr_wait_tag
mv "$lockdir" "$lockdir.aside" 2>/dev/null
sleep 300 &
spid=$!
(cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID="$spid" bash "$LOCKLIB" acquire . "$rb" row >/dev/null 2>&1)
wait "$bgp"
rr_load
assert_eq "$src" "5" "$row: the start is refused, exit 5"
assert_has "$serr" "it holds no counter lock" "$row: the refusal says it holds no counter lock"
assert_has "$(rr_lock_status "$rb")" "\"pid\":$spid" "$row: the lock still names the other holder"
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
(cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
rm -rf "$lockdir.aside"
rr_end

row=start-bounded-lock-no-owner
rr_begin "$row"
lockdir="$git_dir/himmel-cr-review-round/$rb.lock"
(RR_STUB_NODE=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run_to $((B + 12)) --branch "$rb" --head "$head_b") &
bgp=$!
rr_wait_tag
rm -f "$lockdir/owner.json"
wait "$bgp"
rr_load
assert_eq "$src" "5" "$row: the start is refused, exit 5"
assert_has "$serr" "has no owner record; if no start or grant is running" "$row: the refusal names the missing owner record"
(cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
rr_end

row=start-bounded-signal-cleans
rr_begin "$row"
rr_sig_run
assert_eq "$sg_rc" "5" "$row: TERM to the outer ends in a refusal, exit 5"
assert_has "$sg_err" "was stopped by signal inside its 240s bound" "$row: the refusal says the signal"
assert_gone "$row: no stub process is left"
assert_eq "$(rr_lock_status "$rb")" "free" "$row: the lock is free"
(cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
rr_end

wp="$tmp/wrap.pid"
rr_wrap_start() {
    bash -c 'echo $$ > "$1"; cd "$2"; bash "$3" start --branch "$4" --head "$5" >"$6" 2>&1; true' _ "$wp" "$repo" "$RR" "$1" "$2" "$tmp/wrap.out"
}
snapf() { printf '%s' "$git_dir/cr-review-rounds/$1.start.bak"; }
row=start-bounded-caller-pid
rr_begin "$row" plain
rr_wrap_start "$rb" "$head_b"
want="$(cat "$wp")"
assert_eq "$(sed -n 's/^pid //p' "$(snapf "$rb")")" "$want" "$row: the snapshot names the shell that ran start"
assert_eq "$(cat "$git_dir/cr-review-rounds/$rb.delta.run")" "$want" "$row: .delta.run names the shell that ran start"
rr_end

row=start-bounded-continue-caller-pid
rr_begin "$row" plain
bash -c 'cd "$1"; bash "$2" start --branch "$3" --head "$4" >/dev/null 2>&1; true' _ "$repo" "$RR" "$rb" "$head_b"
dead="$(sed -n 's/^pid //p' "$(snapf "$rb")")"
if [ -n "$dead" ] && ! kill -0 "$dead" 2>/dev/null; then pass "$row: the setup shell has ended"; else fail "$row: the setup shell ($dead) is still alive"; fi
rr_wrap_start "$rb" "$head_b"
want="$(cat "$wp")"
assert_has "$(cat "$(snapf "$rb")")" "continued 1" "$row: the restart continues the snapshot"
assert_eq "$(sed -n 's/^pid //p' "$(snapf "$rb")")" "$want" "$row: the snapshot now names the restarting shell"
assert_eq "$(cat "$git_dir/cr-review-rounds/$rb.delta.run")" "$want" "$row: .delta.run names the restarting shell"
rr_end

row=start-pr-bounded-caller-pid
rr_begin "$row" plain
bash -c 'echo $$ > "$1"; cd "$2"; export PATH="$3:$PATH" STUB_LOGIN=Goomal STUB_ID=U_goomal STUB_OID="$5"; bash "$4" start --pr 33 --head "$5" >/dev/null 2>&1; bash "$4" start --pr 33 --head "$5" >/dev/null 2>&1; true' _ "$wp" "$repo" "$sb" "$RR" "$h1"
want="$(cat "$wp")"
assert_eq "$(sort -u "$git_dir/cr-review-rounds/outside-33.delta.run")" "$want" "$row: outside-33.delta.run names the shell that ran start"
assert_eq "$(wc -l < "$git_dir/cr-review-rounds/outside-33.delta.run" | tr -d ' ')" "2" "$row: a second start at the same head appends it again"
rr_end

row=start-bounded-delta-restart-caller
rr_begin "$row" plain
dr_h1="$(git -C "$repo" rev-parse HEAD)"
bash -c 'cd "$1"; bash "$2" start --branch "$3" --head "$4" >/dev/null 2>&1; true' _ "$repo" "$RR" "$rb" "$dr_h1"
CR_LEDGER="$ledger" bash "$LA" avail --branch "$rb" --head "$dr_h1" --model "stub-$rb" --status ok >/dev/null 2>&1
for n in 2 3; do
    printf 'dr%s\n' "$n" >> "$repo/f.txt"; git -C "$repo" commit -q -am "$row $n"
    dr_h="$(git -C "$repo" rev-parse HEAD)"
    bash -c 'cd "$1"; bash "$2" start --branch "$3" --head "$4" >/dev/null 2>&1; true' _ "$repo" "$RR" "$rb" "$dr_h"
    CR_LEDGER="$ledger" bash "$LA" avail --branch "$rb" --head "$dr_h" --model "stub-$rb" --status ok >/dev/null 2>&1
done
TW_FILE=z.sh real_row "$rb" "$dr_h" dr-1 "" "a finding at the third round"
printf 'dr4\n' >> "$repo/f.txt"; git -C "$repo" commit -q -am "$row 4"
dr_h4="$(git -C "$repo" rev-parse HEAD)"
bash -c 'cd "$1"; bash "$2" start --branch "$3" --head "$4" >"$5" 2>&1; true' _ "$repo" "$RR" "$rb" "$dr_h4" "$tmp/dr.first"
wp_first="$(cat "$tmp/dr.first")"
case "$wp_first" in *delta*) pass "$row: the post-cap start is a delta round" ;; *) fail "$row: the post-cap start was not a delta round ($wp_first)" ;; esac
CR_LEDGER="$ledger" bash "$LA" avail --branch "$rb" --head "$dr_h4" --model "stub-$rb" --status unavailable >/dev/null 2>&1
bash -c 'echo $$ > "$1"; cd "$2"; bash "$3" start --branch "$4" --head "$5" >"$6" 2>&1; echo "rc=$?" >> "$6"; true' _ "$wp" "$repo" "$RR" "$rb" "$dr_h4" "$tmp/dr.again"
case "$(cat "$tmp/dr.again")" in *delta*rc=0*) pass "$row: the restart reuses the pending delta" ;; *) fail "$row: the restart did not reuse the pending delta ($(cat "$tmp/dr.again"))" ;; esac
rr_end

row=start-bounded-live-restart
rr_begin "$row" plain
bash -c 'cd "$1"; bash "$2" start --branch "$3" --head "$4" >"$5" 2>&1; echo "rc=$?" >> "$5"; bash "$2" start --branch "$3" --head "$4" >"$6" 2>&1; echo "rc=$?" >> "$6"; true' _ "$repo" "$RR" "$rb" "$head_b" "$tmp/lr.1" "$tmp/lr.2"
assert_has "$(cat "$tmp/lr.1")" "rc=0" "$row: the first start exits 0"
assert_has "$(cat "$tmp/lr.2")" "rc=0" "$row: the restart from the same shell exits 0"
assert_has "$(cat "$(snapf "$rb")")" "continued 1" "$row: the restart is answered from the snapshot"
rr_end

row=start-body-unconfirmed-caller-refused
rr_begin "$row"
sleep 0 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
before_ub="$(cat "$git_dir/cr-review-rounds/$rb".* 2>/dev/null | cksum)"
ub_err="$(cd "$repo" && _RR_START_INNER=1 _RR_START_CALLER="$dead_pid" bash "$RR" start --branch "$rb" --head "$head_b" 2>&1 >/dev/null)"; ub_rc=$?
assert_eq "$ub_rc" "5" "$row: a body whose caller cannot be confirmed exits 5"
assert_has "$ub_err" "cannot confirm the caller" "$row: it says so"
assert_eq "$(cat "$git_dir/cr-review-rounds/$rb".* 2>/dev/null | cksum)" "$before_ub" "$row: no round file changed"
rr_end

row=start-no-split-when-ps-fails
rr_begin "$row"
rr_restore
(cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/ns.ref.out" 2>"$tmp/ns.ref.err"); ref_rc=$?
rr_restore
(cd "$repo" && PATH="$sb:$PATH" RR_STUB_PS=fail-ppid bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/ns.out" 2>"$tmp/ns.err"); ns_rc=$?
assert_eq "$ns_rc" "$ref_rc" "$row: the exit code is the plain start's"
if cmp -s "$tmp/ns.out" "$tmp/ns.ref.out"; then pass "$row: stdout is the plain start's"; else fail "$row: stdout differs from the plain start"; fi
assert_has "$(sed -n '1p' "$tmp/ns.err")" "review-round: start runs unbounded" "$row: the first stderr line says start runs unbounded"
if [ "$(sed -n '2,$p' "$tmp/ns.err")" = "$(cat "$tmp/ns.ref.err")" ]; then pass "$row: the rest of stderr is the plain start's"; else fail "$row: the rest of stderr differs from the plain start"; fi
rr_end

row=start-bounded-lib-absent
rr_begin "$row"
rr_restore
(cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/la.ref.out" 2>"$tmp/la.ref.err")
mv "$fx/scripts/lib/qmd-bounded.sh" "$fx/scripts/lib/qmd-bounded.sh.away"
rr_restore
(cd "$repo" && bash "$RR" start --branch "$rb" --head "$head_b" >"$tmp/la.out" 2>"$tmp/la.err")
if cmp -s "$tmp/la.out" "$tmp/la.ref.out" && cmp -s "$tmp/la.err" "$tmp/la.ref.err"; then pass "$row: a fast start without the library is the same start"; else fail "$row: a fast start without the library differs"; fi
rr_restore
RR_STUB_NODE=hang CR_REVIEW_START_TIMEOUT_SECS="$B" rr_run $((B + 12)) --branch "$rb" --head "$head_b"
assert_eq "$src" "5" "$row: a hung start without the library is refused, exit 5"
assert_has "$serr" "the counter lock was not checked" "$row: the refusal says the lock was not checked"
mv "$fx/scripts/lib/qmd-bounded.sh.away" "$fx/scripts/lib/qmd-bounded.sh"
(cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
rr_end

row=start-bounded-bound-parse
rr_begin "$row"
for bp in 0 281 abc "" 280; do
    rr_restore
    want_n=240; [ "$bp" != 280 ] || want_n=280
    CR_REVIEW_START_TIMEOUT_SECS="$bp" rr_sig_run
    assert_has "$sg_err" "stopped by signal inside its ${want_n}s bound" "$row: '$bp' reads as ${want_n}s"
    (cd "$repo" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCKLIB" release . "$rb" >/dev/null 2>&1)
done
rr_end

row=start-bounded-no-temp-left
left="$(ls -d "$RRTMP"/review-round-start.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$left" "0" "$row: no review-round-start directory is left after the success, refusal and signal rows"

git -C "$repo" checkout -q main 2>/dev/null

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-review-round (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-review-round\n'
