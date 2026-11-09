#!/usr/bin/env bash
# review-round.sh promote over a finding row with a blank head.
# Scratch repo and scratch ledger only; the real ledger is never touched.
# Bash 3.2-safe; no network.
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
for f in chokepoint-seam-guard.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh gh-read.sh open-review-threads.sh; do
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
assert_eq "$rc:$(case "$out" in *"0 of 3"*) echo round ;; esac)" "1:round" "control: every thread resolved, judge-go reaches the round check"
STUB_PRS='[]' STUB_THREADS="$(th_page "$th_open")" jg
assert_eq "$rc" "1" "control: a branch with no open PR has no thread to read"
STUB_THREADS_FAIL=1 jg
assert_eq "$rc" "1" "an unreadable thread read does not stand in for a clean one: it warns and goes on"
assert_has "$out" "could not read the review threads" "the unreadable read is named"
unset STUB_PRS STUB_THREADS
git -C "$repo" checkout -q main 2>/dev/null

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-review-round (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-review-round\n'
