#!/usr/bin/env bash
# test-cancel-runs.sh — Exercises cancel-runs.sh against a PATH-injected stub gh.
# Fixture: 6 runs; 5 non-completed (2 on the kept head KEEP, 3 elsewhere) and 1
# completed run on another head that must never be cancelled. A second fixture
# adds 5 protected runs (main, push, schedule, workflow_dispatch, a tag).
# Runs happen inside a throwaway repo whose origin is o/r. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-cancel-runs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CR="${CANCEL_RUNS:-$HERE/cancel-runs.sh}"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then pass "$1"; else fail "$1 (no match for '$2' in: $3)"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cancel-runs-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

KEEP=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
KEEP2=cccccccccccccccccccccccccccccccccccccccc
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$WORK/runs.json" <<EOF
[
 {"databaseId":101,"status":"in_progress","headSha":"$KEEP","headBranch":"feat/a","event":"pull_request"},
 {"databaseId":102,"status":"queued","headSha":"$KEEP","headBranch":"feat/a","event":"pull_request"},
 {"databaseId":103,"status":"queued","headSha":"$OTHER","headBranch":"feat/b","event":"pull_request"},
 {"databaseId":104,"status":"in_progress","headSha":"$OTHER","headBranch":"feat/b","event":"pull_request"},
 {"databaseId":105,"status":"waiting","headSha":"$OTHER","headBranch":"feat/c","event":"pull_request"},
 {"databaseId":106,"status":"completed","headSha":"$OTHER","headBranch":"feat/c","event":"pull_request"}
]
EOF
# the same plus 5 protected non-completed runs: 107 push to main, 108 schedule,
# 109 workflow_dispatch on a branch, 110 push of a tag, 111 a pull_request run whose branch is main
jq --arg o "$OTHER" '. + [
 {"databaseId":107,"status":"queued","headSha":$o,"headBranch":"main","event":"push"},
 {"databaseId":108,"status":"queued","headSha":$o,"headBranch":"main","event":"schedule"},
 {"databaseId":109,"status":"in_progress","headSha":$o,"headBranch":"feat/d","event":"workflow_dispatch"},
 {"databaseId":110,"status":"queued","headSha":$o,"headBranch":"v1.2.3","event":"push"},
 {"databaseId":111,"status":"queued","headSha":$o,"headBranch":"main","event":"pull_request"}
]' "$WORK/runs.json" > "$WORK/runs-prot.json"
# 120 queued PR runs on one head, for the per-invocation cap
jq -n --arg o "$OTHER" '[range(1000;1120) | {databaseId:., status:"queued", headSha:$o, headBranch:"feat/z", event:"pull_request"}]' > "$WORK/runs-many.json"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: serves $STUB_RUNS (per --status), resolves PR heads, logs cancels.
# STUB_GH_FAIL=1 fails every call; STUB_FAIL_ID=<id> fails that cancel only.
[ -n "${STUB_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_ARGS_LOG"
[ "${STUB_GH_FAIL:-}" = 1 ] && { echo "gh: simulated failure" >&2; exit 1; }
case "$1 $2" in
    "run list")
        # An unfiltered listing is crowded out by newer completed runs (the --limit
        # cap); only a --status listing reaches the active ones.
        st=""
        while [ "$#" -gt 0 ]; do [ "$1" = "--status" ] && st="$2"; shift; done
        # STUB_DUP=1: run 103 also shows in the in_progress listing (it moved queued to in_progress mid-run).
        jq --arg st "$st" --arg dup "${STUB_DUP:-}" \
            '[.[] | select(if $st == "" then .status == "completed" else (.status == $st or ($dup == "1" and $st == "in_progress" and .databaseId == 103)) end)]' "$STUB_RUNS" ;;
    "run cancel")
        [ "$3" = "${STUB_FAIL_ID:-}" ] && { echo "gh: cannot cancel $3" >&2; exit 1; }
        printf '%s\n' "$3" >> "$STUB_CANCEL_LOG"
        if [ -n "${STUB_TIME_LOG:-}" ]; then printf '%s %s %s\n' "$3" "$(cat "$CANCEL_RUNS_FAKE_CLOCK")" "$(wc -l < "$CANCEL_RUNS_PACE_STATE" | tr -d ' ')" >> "$STUB_TIME_LOG"; fi ;;
    "pr view")
        case "$3" in
            3221) echo "$STUB_KEEP_SHA" ;;
            3222) echo "$STUB_KEEP2_SHA" ;;
            *) echo "gh: no such pr $3" >&2; exit 1 ;;
        esac ;;
    *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# a throwaway repo whose origin is o/r, and one with no origin at all
mkdir -p "$WORK/repo" "$WORK/norepo"
( cd "$WORK/repo" && git init -q . && git remote add origin https://github.com/o/r.git ) || { echo "git fixture failed" >&2; exit 1; }
( cd "$WORK/norepo" && git init -q . ) || { echo "git fixture failed" >&2; exit 1; }
mk_origin() { # <dir> <url>
    mkdir -p "$WORK/$1"
    ( cd "$WORK/$1" && git init -q . && git remote add origin "$2" ) || { echo "git fixture failed" >&2; exit 1; }
}
mk_origin ghe https://ghe.example.com/o/r.git
mk_origin ghe-ssh git@ghe.example.com:o/r.git
mk_origin ghe-port ssh://git@ghe.example.com:2222/o/r.git
mk_origin gh-ssh git@github.com:o/r.git
mk_origin gh-path /srv/git/o/r.git
mk_origin gh-upper https://GITHUB.COM/o/r.git
mk_origin gh-spoof https://github.com@evil.com/o/r.git
mk_origin gh-alias ssh://git@ssh.github.com:443/o/r.git

export PATH="$WORK/bin:$PATH"
export STUB_RUNS="$WORK/runs.json" STUB_CANCEL_LOG="$WORK/cancel.log"
export STUB_KEEP_SHA="$KEEP" STUB_KEEP2_SHA="$KEEP2"
# a fake clock: cancel-runs.sh reads the time from this file and "sleeps" by advancing it, so no test waits for real
export CANCEL_RUNS_FAKE_CLOCK="$WORK/clock" STUB_TIME_LOG="$WORK/times.log" CANCEL_RUNS_PACE_STATE="$WORK/pace"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY

# run <args>: dry by default. T_LEG=1 / T_RELAY=1 set the leg / relay markers; T_DIR the cwd.
run() {
    : > "$STUB_CANCEL_LOG"
    : > "$STUB_TIME_LOG"
    echo 1000 > "$CANCEL_RUNS_FAKE_CLOCK"
    if [ -n "${T_BAD_CLOCK:-}" ]; then echo abc > "$CANCEL_RUNS_FAKE_CLOCK"; fi
    # T_PACE_SEED: cancel times (seconds) a previous invocation left in the pacing state
    printf '%s' "${T_PACE_SEED:-}" | tr ' ' '\n' | grep . > "$CANCEL_RUNS_PACE_STATE" || : > "$CANCEL_RUNS_PACE_STATE"
    (
        unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY
        [ -n "${T_LEG:-}" ] && export HIMMEL_CONSOLE_LEG=1
        [ -n "${T_RELAY:-}" ] && export HIMMEL_CONSOLE_RELAY=1
        cd "${T_DIR:-$WORK/repo}" || exit 99
        bash "${T_CR:-$CR}" "$@" 2>&1
    )
}
live() { run --live "$@"; }
cancelled() { sort "$STUB_CANCEL_LOG" | tr '\n' ' '; }

out="$(live --keep-pr 3221)"; rc=$?
check "keep-pr exits 0" "0" "$rc"
check "keep-pr cancels exactly the 3 non-completed runs off the kept head" "103 104 105 " "$(cancelled)"
has "summary counts 3 cancelled, 0 failed, names the kept head" "^cancelled=3 failed=0 kept=$KEEP\$" "$out"

out="$(run --keep-pr 3221 --dry-run)"; rc=$?
check "dry-run exits 0" "0" "$rc"
check "dry-run cancels nothing" "" "$(cancelled)"
has "dry-run reports what it would cancel" "^cancelled=0 failed=0 kept=$KEEP would-cancel=3\$" "$out"

out="$(run --keep-pr 3221)"; rc=$?
check "no --live is a dry run: exits 0" "0" "$rc"
check "no --live cancels nothing" "" "$(cancelled)"
has "no --live reports would-cancel and says how to go live" "would-cancel=3" "$out"
has "no --live names --live on stderr" "pass --live" "$out"

out="$(run --keep-pr 3221 --live --dry-run)"; rc=$?
check "--live with --dry-run is contradictory, exit 2" "2" "$rc"
check "--live with --dry-run cancels nothing" "" "$(cancelled)"

out="$(live --keep-sha "$KEEP")"; rc=$?
check "keep-sha exits 0" "0" "$rc"
check "keep-sha cancels the same 3 runs" "103 104 105 " "$(cancelled)"
has "keep-sha summary names the kept head" "^cancelled=3 failed=0 kept=$KEEP\$" "$out"

out="$(live --keep-pr 3221 --keep-sha "$KEEP2")"; rc=$?
check "repeated keeps exit 0" "0" "$rc"
check "repeated keeps union (a second head with no runs changes nothing)" "103 104 105 " "$(cancelled)"
has "summary lists both kept heads" "^cancelled=3 failed=0 kept=$KEEP,$KEEP2\$" "$out"

out="$(live)"; rc=$?
check "no keep and no --all refuses with usage exit 2" "2" "$rc"
check "refusal cancels nothing" "" "$(cancelled)"

out="$(live --all)"; rc=$?
check "--all exits 0" "0" "$rc"
check "--all cancels every non-completed run, never the completed one" "101 102 103 104 105 " "$(cancelled)"
has "--all summary shows no kept list" '^cancelled=5 failed=0 kept=-$' "$out"

out="$(live --keep-pr 3221 --all)"; rc=$?
check "--keep-pr with --all is contradictory, exit 2" "2" "$rc"
check "contradiction cancels nothing" "" "$(cancelled)"

out="$(live --keep-pr 9999)"; rc=$?
check "an unresolvable keep PR refuses (fail closed), exit 1" "1" "$rc"
check "unresolvable keep cancels nothing" "" "$(cancelled)"

out="$(live --keep-sha not-a-sha)"; rc=$?
check "a malformed --keep-sha is a usage error" "2" "$rc"

out="$(STUB_FAIL_ID=104 live --keep-pr 3221)"; rc=$?
check "a failed cancel exits 1" "1" "$rc"
check "the other runs still cancel" "103 105 " "$(cancelled)"
has "summary counts the failure" "^cancelled=2 failed=1 kept=$KEEP\$" "$out"
has "the failed cancel is logged with its run, branch, sha, event and rc" "run=104 branch=feat/b sha=$OTHER event=pull_request rc=1" "$out"
has "the failed cancel keeps gh's own error text" "gh: cannot cancel 104" "$out"

out="$(live --keep-pr 3221)"; rc=$?
has "a successful cancel is logged with its run, branch, sha, event and rc" "run=103 branch=feat/b sha=$OTHER event=pull_request rc=0" "$out"
has "every cancel gets its own log line" "run=105 branch=feat/c sha=$OTHER event=pull_request rc=0" "$out"

out="$(STUB_DUP=1 live --keep-pr 3221)"; rc=$?
check "a duplicated run exits 0" "0" "$rc"
check "a run listed under two statuses is cancelled once" "103 104 105 " "$(cancelled)"
has "a duplicated run counts once" "^cancelled=3 failed=0 kept=$KEEP\$" "$out"

out="$(CANCEL_RUNS_LIMIT=2 live --keep-pr 3221)"; rc=$?
check "a listing that fills the cap still cancels what it saw" "103 104 105 " "$(cancelled)"
check "a listing that fills the cap exits 1 (re-run to drain the rest)" "1" "$rc"
has "the cap hit is named" "listing hit the cap of 2 runs" "$out"

out="$(STUB_GH_FAIL=1 live --keep-pr 3221)"; rc=$?
check "gh down refuses, exit 1" "1" "$rc"
check "gh down cancels nothing" "" "$(cancelled)"

# a console-spawned leg or a relay never cancels (same predicate go.sh uses), dry or live
out="$(T_LEG=1 live --keep-pr 3221)"; rc=$?
check "a console-spawned leg is refused, exit 3" "3" "$rc"
check "the leg refusal cancels nothing" "" "$(cancelled)"
has "the leg refusal names HIMMEL_CONSOLE_LEG" "HIMMEL_CONSOLE_LEG" "$out"

out="$(T_LEG=1 run --keep-pr 3221)"; rc=$?
check "a leg is refused on a dry run too, exit 3" "3" "$rc"

out="$(T_RELAY=1 live --keep-pr 3221)"; rc=$?
check "a console relay is refused, exit 3" "3" "$rc"
check "the relay refusal cancels nothing" "" "$(cancelled)"
has "the relay refusal names HIMMEL_CONSOLE_RELAY" "HIMMEL_CONSOLE_RELAY" "$out"

# the leg check fails closed: a tree without scripts/lib/go-gate.sh refuses
mkdir -p "$WORK/k/scripts/handover/console-kit" "$WORK/k/scripts/lib"
cp "$CR" "$WORK/k/scripts/handover/console-kit/cancel-runs.sh"
cp "$HERE/../../lib/git-clean.sh" "$WORK/k/scripts/lib/git-clean.sh"
out="$(T_CR="$WORK/k/scripts/handover/console-kit/cancel-runs.sh" live --keep-pr 3221)"; rc=$?
check "a missing go-gate.sh refuses (fail closed), exit 1" "1" "$rc"
check "the missing go-gate.sh cancels nothing" "" "$(cancelled)"

# the repo is pinned to origin
out="$(live --repo o/r --keep-pr 3221)"; rc=$?
check "--repo equal to origin is accepted" "0" "$rc"
check "--repo equal to origin cancels" "103 104 105 " "$(cancelled)"

out="$(live --repo x/y --keep-pr 3221)"; rc=$?
check "--repo that differs from origin refuses, exit 2" "2" "$rc"
check "the --repo mismatch cancels nothing" "" "$(cancelled)"
has "the --repo mismatch names both slugs" "x/y.*o/r" "$out"

out="$(T_DIR="$WORK/norepo" live --repo o/r --keep-pr 3221)"; rc=$?
check "no origin refuses even with --repo, exit 2" "2" "$rc"
check "no origin cancels nothing" "" "$(cancelled)"

out="$(live --repo not-a-slug --keep-pr 3221)"; rc=$?
check "a malformed --repo is a usage error" "2" "$rc"

# gh -R OWNER/REPO targets the default host, so only a github.com origin is accepted
out="$(T_DIR="$WORK/ghe" live --keep-pr 3221)"; rc=$?
check "an https origin on another host refuses, exit 2" "2" "$rc"
check "an other-host https origin cancels nothing" "" "$(cancelled)"
has "the other-host refusal names the host" "ghe.example.com" "$out"

out="$(T_DIR="$WORK/ghe-ssh" live --keep-pr 3221)"; rc=$?
check "an scp-style origin on another host refuses, exit 2" "2" "$rc"
check "an other-host scp-style origin cancels nothing" "" "$(cancelled)"

out="$(T_DIR="$WORK/ghe-port" live --keep-pr 3221)"; rc=$?
check "an ssh:// origin with a port on another host refuses, exit 2" "2" "$rc"

out="$(T_DIR="$WORK/gh-ssh" live --keep-pr 3221)"; rc=$?
check "an scp-style github.com origin is accepted" "0" "$rc"
check "an scp-style github.com origin cancels" "103 104 105 " "$(cancelled)"

out="$(T_DIR="$WORK/gh-path" live --keep-pr 3221)"; rc=$?
check "a local-path origin (no host) refuses, exit 2" "2" "$rc"

out="$(T_DIR="$WORK/gh-upper" live --keep-pr 3221)"; rc=$?
check "an uppercase GITHUB.COM origin is accepted" "0" "$rc"
check "an uppercase GITHUB.COM origin cancels" "103 104 105 " "$(cancelled)"

out="$(T_DIR="$WORK/gh-spoof" live --keep-pr 3221)"; rc=$?
check "a userinfo spoof (github.com@evil.com) refuses, exit 2" "2" "$rc"
check "a userinfo spoof cancels nothing" "" "$(cancelled)"

out="$(T_DIR="$WORK/gh-alias" live --keep-pr 3221)"; rc=$?
check "an ssh.github.com:443 origin refuses (fail closed), exit 2" "2" "$rc"

# every gh call names github.com, so an exported GH_HOST cannot redirect the cancels
export STUB_ARGS_LOG="$WORK/gh-args.log"
: > "$STUB_ARGS_LOG"
out="$(GH_HOST=ghe.example.com live --keep-pr 3221)"; rc=$?
check "GH_HOST set: the run still exits 0" "0" "$rc"
check "GH_HOST set: every call has a -R argument (pr view, run list, run cancel)" "3" "$(awk '/ -R /{split($0, a, " "); seen[a[1] " " a[2]]=1} END{n=0; for (k in seen) n++; print n}' "$STUB_ARGS_LOG")"
check "GH_HOST set: every -R argument is github.com/o/r" "0" "$(grep -e ' -R ' "$STUB_ARGS_LOG" | grep -vcE ' -R github\.com/o/r( |$)')"
unset STUB_ARGS_LOG

# main, tags and push/schedule/workflow_dispatch runs are protected
export STUB_RUNS="$WORK/runs-prot.json"
out="$(live --keep-pr 3221)"; rc=$?
check "protected runs: exits 0" "0" "$rc"
check "protected runs (main, push, schedule, dispatch, tag) are never cancelled" "103 104 105 " "$(cancelled)"
has "the summary counts the protected runs left alone" "^cancelled=3 failed=0 kept=$KEEP protected=5\$" "$out"

out="$(live --all)"; rc=$?
check "--all still leaves protected runs alone" "101 102 103 104 105 " "$(cancelled)"

out="$(live --keep-pr 3221 --include-protected)"; rc=$?
check "--include-protected cancels the protected runs too" "103 104 105 107 108 109 110 111 " "$(cancelled)"
has "--include-protected has no protected count" "^cancelled=8 failed=0 kept=$KEEP\$" "$out"

out="$(run --keep-pr 3221)"; rc=$?
has "a dry run reports the protected count" "would-cancel=3 protected=5\$" "$out"
export STUB_RUNS="$WORK/runs.json"

# a hard cap on cancels per invocation
out="$(live --keep-pr 3221 --max-cancels 2)"; rc=$?
# read-sink-ok: STUB_CANCEL_LOG is the stub log this suite exports under its own $WORK
check "--max-cancels stops at the cap" "2" "$(wc -l < "$STUB_CANCEL_LOG" | tr -d ' ')"
check "--max-cancels exits 1 (re-run to drain the rest)" "1" "$rc"
has "the cancel cap is named" "cap of 2 cancels" "$out"

for bad in 0 abc 501 99999999999999999999; do
    out="$(live --keep-pr 3221 --max-cancels "$bad")"; rc=$?
    check "--max-cancels $bad is a usage error" "2" "$rc"
    check "--max-cancels $bad cancels nothing" "" "$(cancelled)"
done

out="$(CANCEL_RUNS_LIMIT=abc live --keep-pr 3221)"; rc=$?
check "a non-numeric CANCEL_RUNS_LIMIT is a usage error" "2" "$rc"
check "a non-numeric CANCEL_RUNS_LIMIT cancels nothing" "" "$(cancelled)"

export STUB_RUNS="$WORK/runs-many.json"
out="$(live --keep-sha "$KEEP")"; rc=$?
# read-sink-ok: STUB_CANCEL_LOG is the stub log this suite exports under its own $WORK
check "the default cap cancels 100 of 120 runs" "100" "$(wc -l < "$STUB_CANCEL_LOG" | tr -d ' ')"
check "the default cap exits 1" "1" "$rc"
has "the default cap is named" "cap of 100 cancels" "$out"
out="$(live --keep-sha "$KEEP" --max-cancels 500)"; rc=$?
# read-sink-ok: STUB_CANCEL_LOG is the stub log this suite exports under its own $WORK
check "--max-cancels 500 raises the cap to cancel all 120" "120" "$(wc -l < "$STUB_CANCEL_LOG" | tr -d ' ')"
check "an uncapped run exits 0" "0" "$rc"
export STUB_RUNS="$WORK/runs.json"

# pacing: at most 10 cancels per minute and 30 per 10 minutes (the fake clock starts at 1000)
times_at() { awk -v t="$1" '$2 == t' "$STUB_TIME_LOG" | wc -l | tr -d ' '; }
time_of() { awk -v id="$1" '$1 == id {print $2}' "$STUB_TIME_LOG"; }
export STUB_RUNS="$WORK/runs-many.json"
out="$(live --keep-sha "$KEEP" --max-cancels 12)"; rc=$?
check "pacing: 12 runs, the first 10 cancel in the first minute" "10" "$(times_at 1000)"
check "pacing: the 11th cancel waits for the next minute window" "1060" "$(time_of 1010)"
check "pacing: the 12th cancel runs in the same later window" "1060" "$(time_of 1011)"
has "pacing: the wait is named on stderr" "pacing - waiting 60s" "$out"
# read-sink-ok: STUB_CANCEL_LOG is the stub log this suite exports under its own $WORK
check "pacing: the paced run still cancels all 12" "12" "$(wc -l < "$STUB_CANCEL_LOG" | tr -d ' ')"
out="$(live --keep-sha "$KEEP" --max-cancels 31)"; rc=$?
check "pacing: the 30th cancel runs at the third minute window" "1120" "$(time_of 1029)"
check "pacing: the 31st cancel waits for the 10-minute window" "1600" "$(time_of 1030)"
# read-sink-ok: STUB_CANCEL_LOG is the stub log this suite exports under its own $WORK
check "pacing: all 31 cancels happen" "31" "$(wc -l < "$STUB_CANCEL_LOG" | tr -d ' ')"
out="$(live --keep-sha "$KEEP" --max-cancels 5)"; rc=$?
check "pacing: a run under the limits never waits" "5" "$(times_at 1000)"
out="$(T_PACE_SEED="1000 1000 1000 1000 1000 1000 1000 1000 1000 1000" live --keep-sha "$KEEP" --max-cancels 1)"; rc=$?
check "pacing: a re-run keeps the limits of the last invocation (10 cancels at 1000, the next waits)" "1060" "$(time_of 1000)"
out="$(T_PACE_SEED="100 1000" live --keep-sha "$KEEP" --max-cancels 1)"; rc=$?
# read-sink-ok: CANCEL_RUNS_PACE_STATE is the state file this suite exports under its own $WORK
check "pacing: the state file drops stamps older than 10 minutes and keeps the new cancel" "1000 1000 " "$(tr '\n' ' ' < "$CANCEL_RUNS_PACE_STATE")"
out="$(T_BAD_CLOCK=1 live --keep-sha "$KEEP")"; rc=$?
check "pacing: a fake clock that is not an integer refuses, exit 2" "2" "$rc"
check "pacing: a refused fake clock cancels nothing" "" "$(cancelled)"
out="$(live --keep-sha "$KEEP" --max-cancels 2)"; rc=$?
check "pacing: the cancel is in the state file before gh runs (first cancel sees 1 stamp)" "1" "$(awk 'NR == 1 {print $3}' "$STUB_TIME_LOG")"
check "pacing: the second cancel sees 2 stamps" "2" "$(awk 'NR == 2 {print $3}' "$STUB_TIME_LOG")"
out="$(CANCEL_RUNS_PACE_STATE="$WORK/no-such-dir/pace" live --keep-sha "$KEEP")"; rc=$?
check "pacing: a state file that cannot be written refuses, exit 1" "1" "$rc"
check "pacing: an unwritable state file cancels nothing" "" "$(cancelled)"
export STUB_RUNS="$WORK/runs.json"

if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%d FAILED\n' "$fails"
exit 1
