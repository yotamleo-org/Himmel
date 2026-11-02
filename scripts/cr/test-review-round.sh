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
for f in chokepoint-seam-guard.sh load-dotenv.sh shared-branch-lock.sh go-gate.sh gh-read.sh; do
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

# A finding the way the production writer shaped it, at a real head.
real_row() { # branch head id verdict [text]
    if [ "$4" = deferred ]; then
        CR_LEDGER="$ledger" bash "$LA" finding --branch "$1" --head "$2" --model stub --id "$3" \
            --severity sug --file f.txt --line 1 --verdict deferred --deferred-to HIMMEL-9001 \
            --fu-class polish --reason "tracked in the fixture"
    elif [ -n "${5:-}" ]; then
        CR_LEDGER="$ledger" bash "$LA" finding --branch "$1" --head "$2" --model stub --id "$3" \
            --severity sug --file f.txt --line 1 --verdict "$4" --text "$5"
    else
        CR_LEDGER="$ledger" bash "$LA" finding --branch "$1" --head "$2" --model stub --id "$3" \
            --severity sug --file f.txt --line 1 --verdict "$4"
    fi
}
# The defect: a finding row written with head "", which ledger-append can no longer write.
blank_row() { # branch id verdict [perspective]
    printf '{"kind":"finding","ts":"2026-11-02T17:20:47Z","branch":"%s","head":"","model":"coverage-deferral","finding_id":"%s","severity":"sug","file":"","line":"","verdict":"%s","artifact":"diff","perspective":"%s"}\n' \
        "$1" "$2" "$3" "${4:-off}" >> "$ledger"
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

# (1) a blank-head row whose finding id is also recorded at a real head on the branch
# is skipped and counted; the twin is judged on its own row.
real_row rr-twin "$head_a" cov-1 deferred
blank_row rr-twin cov-1 deferred
promote rr-twin
assert_eq "$rc" "0" "a blank-head row with a twin lets promote exit 0"
assert_has "$out" "skip-blank-head cov-1" "the skipped blank-head row is named"
assert_has "$out" "1 blank-head skipped" "the summary line counts the skipped blank-head row"
assert_eq "$before" "$after" "skipping a blank-head row rewrites and deletes nothing"

# (2) no twin: promote refuses, names the id, and says blank head, not write failure.
blank_row rr-notwin cov-2 deferred
promote rr-notwin
assert_eq "$rc" "1" "a blank-head row with no twin refuses promote"
assert_has "$err" "cov-2" "the refusal names the finding id"
assert_has "$err" "blank head" "the refusal says blank head"
assert_lacks "$err" "ledger write failed" "the refusal is not reported as a write failure"
assert_eq "$before" "$after" "a refused promote writes nothing"

# (3) the twin decides: an unadjudicated twin keeps promote from passing.
real_row rr-open "$head_a" cov-3 ""
blank_row rr-open cov-3 deferred
promote rr-open
assert_eq "$rc" "3" "a blank-head row whose twin is still open does not let promote pass"
assert_has "$out" "still-open cov-3@" "the twin is reported still-open"
assert_has "$out" "skip-blank-head cov-3" "the blank-head row is still skipped, not judged"

# (4) the twin decides: an agreed twin re-raised at the clean head stays open.
real_row rr-reraise "$head_a" cov-4 "" "tidy the cov-4 fixture"
CR_LEDGER="$ledger" bash "$LA" amend --branch rr-reraise --head "$head_a" --id cov-4 \
    --set verdict=agreed --reason "agreed in the fixture" 2>/dev/null
real_row rr-reraise "$head_b" cov-4b "" "tidy the cov-4 fixture"
blank_row rr-reraise cov-4 ""
promote rr-reraise
assert_eq "$rc" "3" "a blank-head row whose twin is re-raised does not let promote pass"
assert_has "$out" "still-open cov-4@" "the re-raised twin is reported still-open"

# (5) an agreed twin that was not re-raised is promoted as usual; the blank row adds nothing.
real_row rr-promote "$head_a" cov-5 "" "tidy the cov-5 fixture"
CR_LEDGER="$ledger" bash "$LA" amend --branch rr-promote --head "$head_a" --id cov-5 \
    --set verdict=agreed --reason "agreed in the fixture" 2>/dev/null
blank_row rr-promote cov-5 ""
promote rr-promote
assert_eq "$rc" "0" "a blank-head row beside a promotable twin lets promote exit 0"
assert_has "$out" "promoted cov-5@" "the twin is promoted"
assert_has "$out" "skip-blank-head cov-5" "the blank-head row is skipped"

# (6) a twin must be on the same branch: a row of that id on another branch is no twin.
real_row rr-other "$head_a" cov-6 deferred
blank_row rr-elsewhere cov-6 deferred
promote rr-elsewhere
assert_eq "$rc" "1" "a twin on another branch does not count"
assert_has "$err" "cov-6" "the cross-branch refusal names the id"

# (7) a twin must share the perspective: the same id under another perspective is no twin.
CR_LEDGER="$ledger" bash "$LA" finding --branch rr-persp --head "$head_a" --model stub --id cov-7 \
    --severity sug --file f.txt --line 1 --verdict deferred --perspective on --fu-class polish --deferred-to HIMMEL-9001
blank_row rr-persp cov-7 deferred off
promote rr-persp
assert_eq "$rc" "1" "a twin under another perspective does not count"

# (8) an empty finding id cannot have a twin.
blank_row rr-noid "" deferred
promote rr-noid
assert_eq "$rc" "1" "a blank-head row with no finding id refuses promote"
assert_has "$err" "blank head" "the no-id refusal says blank head"

git -C "$repo" checkout -q main 2>/dev/null

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-review-round (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-review-round\n'
