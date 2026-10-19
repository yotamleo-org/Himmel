#!/usr/bin/env bash
# test-stuck-scan.sh — Exercises stuck-scan.sh against a fixture Jira mirror and
# PATH-injected stub gh / pgrep / jira CLI. Clock pinned by STUCK_SCAN_NOW.
# bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-stuck-scan.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SS="${STUCK_SCAN:-$HERE/stuck-scan.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
has() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then pass "$1"; else fail "$1 (no match for '$2' in: $3)"; fi
}
hasnt() { # <name> <pattern> <text>
    if printf '%s\n' "$3" | grep -Eq -- "$2"; then fail "$1 (unexpected '$2' in: $3)"; else pass "$1"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stuck-scan-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

NOW="2026-10-19T20:00:00+00:00"
M="$WORK/mirror"
mkdir -p "$M" "$WORK/bin"

mk() { # <key> <status> <updated> <fixver> [comment-body ...]  (one ### block per body)
    local key="$1" st="$2" upd="$3" ver="$4"; shift 4
    {
        printf -- '---\nkey: "%s"\ntype: "Bug"\nstatus: "%s"\nfixVersions: ["%s"]\nupdated: "%s"\n---\n\n# %s: t\n\n## Description\n\nbody\n\n## Comments\n\n' "$key" "$st" "$ver" "$upd" "$key"
        if [ "$#" -eq 0 ]; then printf '_(none)_\n'; fi
        local n=0 b
        for b in "$@"; do
            n=$((n + 1))
            printf '### Someone — 2026-10-19T1%d:00:00.000+0000\n\n%s\n\n' "$n" "$b"
        done
    } > "$M/$key.md"
}

OLD="2026-10-19T15:00:00.000+0000"   # 5h before NOW
mk HIMMEL-9001 "In Progress" "$OLD" v1.1.3                 # orphan
mk HIMMEL-9002 "In Progress" "$OLD" v1.1.3                 # owned by a leg
mk HIMMEL-9003 "In Review"   "$OLD" v1.1.3                 # owned by an open PR
mk HIMMEL-9004 "IN CI"       "$OLD" v1.1.3 'DISPOSITION (2026-10-19): BLOCKED-BY 3206'          # blocker PR open
mk HIMMEL-9005 "IN CI"       "$OLD" v1.1.3 'DISPOSITION (2026-10-19): BLOCKED-BY PR 3207'       # blocker PR merged
mk HIMMEL-9006 "In Progress" "$OLD" v1.1.3 'DISPOSITION (2026-10-19): BLOCKED-BY HIMMEL-9010'  # blocker ticket open
mk HIMMEL-9007 "In Progress" "$OLD" v1.1.3 'DISPOSITION (2026-10-19): BLOCKED-BY HIMMEL-9011'  # blocker ticket Done
mk HIMMEL-9008 "In Progress" "$OLD" v1.1.3 'DISPOSITION (2026-10-19): BLOCKED-BY 3206' 'plain follow-up'  # latest comment has no disposition
mk HIMMEL-9009 "In Progress" "2026-10-19T19:50:00.000+0000" v1.1.3   # 10 min old: under threshold
mk HIMMEL-9010 "In Progress" "2026-10-19T19:55:00.000+0000" v1.1.3
mk HIMMEL-9011 "Done"        "$OLD" v1.1.3
mk HIMMEL-9012 "To Do"       "$OLD" v1.1.3
mk HIMMEL-9013 "In Progress" "2026-10-17T20:00:00.000+0000" v1.1.4   # orphan, other version, 2d old

cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_GH_FAIL:-}" = 1 ] && { echo "gh: simulated failure" >&2; exit 1; }
case "$1 $2" in
    "pr list") cat "$STUB_PRS" ;;
    *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
STUB
cat > "$WORK/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_PGREP"
STUB
cat > "$WORK/jira-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_JIRA_LOG"
f=""; prev=""
for a in "$@"; do [ "$prev" = --comment-file ] && f="$a"; prev="$a"; done
[ -n "$f" ] && cat "$f" >> "$STUB_JIRA_LOG"
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/pgrep" "$WORK/jira-stub"

cat > "$WORK/prs.json" <<'JSON'
[
 {"number":3300,"title":"fix(x): [HIMMEL-9003] a fix","headRefName":"fix/himmel-9003-a","body":""},
 {"number":3206,"title":"feat(y): [HIMMEL-6000] other","headRefName":"feat/himmel-6000-b","body":"mentions HIMMEL-9001 only in passing"}
]
JSON
printf '1234 claude --session x -n HIMMEL-9002-N2900-thing-2026-10-19\n1235 claude -n HIMMEL-nextleg-2026-10-19AA-roadmap-console\n' > "$WORK/pgrep.txt"

export PATH="$WORK/bin:$PATH"
export STUCK_SCAN_NOW="$NOW" STUCK_SCAN_MIRROR="$M" STUB_PRS="$WORK/prs.json" STUB_PGREP="$WORK/pgrep.txt"
export STUCK_SCAN_JIRA_CMD="$WORK/jira-stub" STUB_JIRA_LOG="$WORK/jira.log"

out="$(bash "$SS" 2>&1)"; rc=$?
check "scan exits 0" 0 "$rc"
has   "orphan In Progress is STUCK with its age" '^STUCK HIMMEL-9001 In Progress 5h$' "$out"
hasnt "ticket owned by a live leg is quiet" 'HIMMEL-9002' "$out"
hasnt "ticket owned by an open PR (title/branch) is quiet" 'HIMMEL-9003' "$out"
has   "BLOCKED-BY an open PR prints BLOCKED-BY" '^BLOCKED-BY HIMMEL-9004 3206$' "$out"
has   "BLOCKED-BY a merged PR is re-flagged STUCK" '^STUCK HIMMEL-9005 IN CI 5h$' "$out"
has   "BLOCKED-BY an open ticket prints BLOCKED-BY" '^BLOCKED-BY HIMMEL-9006 HIMMEL-9010$' "$out"
has   "BLOCKED-BY a Done ticket is re-flagged STUCK" '^STUCK HIMMEL-9007 In Progress 5h$' "$out"
has   "only the latest comment carries the disposition" '^STUCK HIMMEL-9008 In Progress 5h$' "$out"
hasnt "a ticket under the threshold is quiet" 'HIMMEL-9009' "$out"
hasnt "a Done ticket is quiet" 'HIMMEL-9011' "$out"
hasnt "a To Do ticket is quiet" 'HIMMEL-9012' "$out"
has   "age in days past 48h" '^STUCK HIMMEL-9013 In Progress 2d$' "$out"

out="$(bash "$SS" --version v1.1.4 2>&1)"
check "--version keeps only that fixVersion" "STUCK HIMMEL-9013 In Progress 2d" "$out"

out="$(bash "$SS" --min 600 2>&1)"
hasnt "--min raises the threshold" 'HIMMEL-900[1-8]' "$out"

out="$(STUB_GH_FAIL=1 bash "$SS" 2>&1)"; rc=$?
check "gh failure exits 3" 3 "$rc"
has   "gh failure prints STUCK-UNKNOWN, not an all-clear" '^STUCK-UNKNOWN' "$out"

# --- dispose
: > "$WORK/jira.log"
out="$(bash "$SS" dispose HIMMEL-9001 BLOCKED-BY 3206 2>&1)"; rc=$?
check "dispose BLOCKED-BY exits 0" 0 "$rc"
log="$(cat "$WORK/jira.log")"
has "dispose calls jira comment on the key with a comment file" '^comment HIMMEL-9001 --comment-file ' "$log"
has "dispose body carries the DISPOSITION line" '^DISPOSITION \([^)]*\): BLOCKED-BY 3206$' "$log"

: > "$WORK/jira.log"
bash "$SS" dispose HIMMEL-9001 OPERATOR "pick a lane for the retry" >/dev/null 2>&1
has "dispose OPERATOR keeps the whole ask" 'OPERATOR pick a lane for the retry$' "$(cat "$WORK/jira.log")"

for v in RESUME PARKED; do
    : > "$WORK/jira.log"
    bash "$SS" dispose HIMMEL-9001 "$v" some-arg >/dev/null 2>&1; rc=$?
    check "dispose $v exits 0" 0 "$rc"
    has "dispose $v is recorded" "$v some-arg\$" "$(cat "$WORK/jira.log")"
done

: > "$WORK/jira.log"
bash "$SS" dispose HIMMEL-9001 NONSENSE x >/dev/null 2>&1; rc=$?
check "dispose with an unknown verb exits 2" 2 "$rc"
bash "$SS" dispose HIMMEL-9001 BLOCKED-BY >/dev/null 2>&1; rc=$?
check "dispose without an argument exits 2" 2 "$rc"
bash "$SS" dispose not-a-key RESUME x >/dev/null 2>&1; rc=$?
check "dispose with a malformed key exits 2" 2 "$rc"
check "refused dispose posts nothing" "" "$(cat "$WORK/jira.log")"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
