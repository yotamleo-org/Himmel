#!/usr/bin/env bash
# Tests for note-polish.sh: the PR-ticket lookup (D4a) and the one polish-noted
# Jira comment. Hermetic: gh is GH_CMD and the Jira CLI is JIRA_CMD, both stubs
# that log their argv; nothing reaches the network.
# Bash 3.2-safe. Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NP="$HERE/note-polish.sh"
tmp="$(mktemp -d -t note-polish-test.XXXXXX)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }
assert_has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac; }

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NP_GH_LOG"
[ "${1:-} ${2:-}" = "pr list" ] || { echo "gh-stub: unexpected: $*" >&2; exit 99; }
[ -n "${GH_PR_JSON:-}" ] || exit 0
q=""
while [ $# -gt 0 ]; do [ "$1" = -q ] && q="$2"; shift; done
printf '%s' "$GH_PR_JSON" | jq -r "$q"
STUB
cat > "$tmp/jira" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NP_JIRA_LOG"
case "${1:-}" in
    comments)
        [ "${NP_COMMENTS_FAIL:-}" = 1 ] && { echo "jira: 500" >&2; exit 1; }
        [ -z "${NP_COMMENTS:-}" ] || printf '%s\n' "$NP_COMMENTS"
        ;;
    comment)
        while [ $# -gt 0 ]; do [ "$1" = --comment-file ] && cp "$2" "$NP_BODY"; shift; done
        [ "${NP_COMMENT_FAIL:-}" = 1 ] && { echo "jira: comment refused" >&2; exit 1; }
        ;;
    *) echo "jira-stub: unexpected: $*" >&2; exit 99 ;;
esac
exit 0
STUB
chmod +x "$tmp/gh" "$tmp/jira"
export NP_GH_LOG="$tmp/gh.log" NP_JIRA_LOG="$tmp/jira.log" NP_BODY="$tmp/body"
export GH_CMD="$tmp/gh" JIRA_CMD="$tmp/jira" JIRA_PROJECT_KEY=HIMMEL
unset GH_PR_JSON NP_COMMENTS NP_COMMENTS_FAIL NP_COMMENT_FAIL

list="$tmp/list.jsonl"
printf '%s\n' \
    '{"id":"critic-1","file":"a.sh","line":3,"severity":"sug","class_source":"ledger","text":"tidy the loop"}' \
    '{"id":"critic-2","file":"b.md","line":"","severity":"nit","class_source":"default","text":"a typo"}' > "$list"
head_sha=0123456789abcdef0123456789abcdef01234567

run_np() { # run_np <branch> [list]: one call, logs reset
    : > "$NP_GH_LOG"; : > "$NP_JIRA_LOG"; rm -f "$NP_BODY"
    np_rc=0
    np_out="$(bash "$NP" --branch "$1" --head "$head_sha" --list-file "${2:-$list}" 2>&1)" || np_rc=$?
}
comment_calls() { { grep -c '^comment ' "$NP_JIRA_LOG" || true; } | tr -d ' '; }

GH_PR_JSON='[{"title":"fix(cr): [HIMMEL-77] a change"}]' run_np fix/himmel-55-x
assert_eq "$np_rc" 0 "D4a one open PR exits 0 ($np_out)"
assert_has "$(cat "$NP_JIRA_LOG")" "comment HIMMEL-77 --comment-file" "D4a one open PR takes ticket_key_from_title of its title"
assert_has "$(cat "$NP_GH_LOG")" "pr list --head fix/himmel-55-x --state open --json title -q .[].title" "D4a the lookup is the open-PR title list for the branch"

GH_PR_JSON='[{"title":"fix: SHA-256 pin check [HIMMEL-77] x"}]' run_np fix/himmel-55-x
assert_has "$(cat "$NP_JIRA_LOG")" "comment HIMMEL-77 --comment-file" "D4a an unbracketed SHA-256 before the bracketed key picks the bracketed key"

GH_PR_JSON='[{"title":"fix: [HIMMEL-77] a"},{"title":"fix: [HIMMEL-78] b"}]' run_np fix/himmel-55-x
assert_eq "$np_rc" 6 "D4a two open PRs exit 6"
assert_eq "$(wc -c < "$NP_JIRA_LOG" | tr -d ' ')" 0 "D4a two open PRs post nothing"

GH_PR_JSON='[{"title":"fix: no key here"}]' run_np fix/himmel-55-x
assert_eq "$np_rc" 6 "D4a a title with no bracketed key exits 6"

run_np fix/himmel-55-x
assert_eq "$np_rc" 0 "D4a no open PR exits 0 ($np_out)"
assert_has "$(cat "$NP_JIRA_LOG")" "comment HIMMEL-55 --comment-file" "D4a no open PR takes the branch-name key"

run_np fix/himmel-55-himmel-56
assert_eq "$np_rc" 6 "D4a a branch with two keys exits 6"
assert_has "$np_out" "ambiguous or missing PR ticket" "D4a a branch with two keys names the reason"
assert_eq "$(wc -c < "$NP_JIRA_LOG" | tr -d ' ')" 0 "D4a a branch with two keys posts nothing"

run_np fix/no-key-here
assert_eq "$np_rc" 6 "D4a a branch with no key exits 6"

NP_COMMENT_FAIL=1 run_np fix/himmel-55-x
assert_eq "$np_rc" 6 "a failed jira comment exits 6"

long="$(printf 'x%.0s' $(seq 1 400))"
printf '{"id":"critic-3","file":"c.sh","line":9,"severity":"sug","class_source":"ledger","text":"%s"}\n' "$long" >> "$list"
run_np fix/himmel-55-x
body="$(cat "$NP_BODY" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$body" | sed -n 1p)" "polish-noted: fix/himmel-55-x $head_sha" "the comment body has the polish-noted line"
assert_eq "$(printf '%s\n' "$body" | sed -n 2p)" "- critic-1 a.sh:3 [sug, class ledger]: tidy the loop" "the comment body has one line per list entry"
assert_eq "$(printf '%s\n' "$body" | sed -n 3p)" "- critic-2 b.md [nit, class default]: a typo" "an entry with no line names its file alone"
assert_eq "$(printf '%s\n' "$body" | sed -n 4p)" "- critic-3 c.sh:9 [sug, class ledger]: $(printf 'x%.0s' $(seq 1 300))" "the comment body cuts the text to 300"
assert_eq "$(printf '%s\n' "$body" | wc -l | tr -d ' ')" 4 "the comment body has one line per list entry and no more"

batch="$tmp/batch.jsonl"
printf '%s\n' \
    '{"id":"batch-1-abc123def456","file":"a.sh","line":3,"severity":"sug","class_source":"batch","text":"a.sh:3: NIT: one"}' \
    '{"id":"batch-2-abc123def456","file":"b.md","line":"","severity":"sug","class_source":"batch","text":"b.md: LOW: two"}' > "$batch"
run_np fix/himmel-55-x "$batch"
assert_eq "$np_rc" 0 "a batch list exits 0 ($np_out)"
assert_eq "$(sed -n 1p "$NP_BODY" 2>/dev/null)" "polish-noted: fix/himmel-55-x $head_sha crbatchabc123def456" "a batch list puts crbatch<hash> on line 1, taking the hash from the first batch id"
assert_has "$(cat "$NP_JIRA_LOG")" "comments HIMMEL-55" "a batch list reads the ticket's comments first"

NP_COMMENTS="polish-noted: fix/himmel-55-x feedface crbatchabc123def456" run_np fix/himmel-55-x "$batch"
assert_eq "$np_rc" 0 "a ticket that already holds the crbatch line exits 0"
assert_has "$np_out" "already noted" "a ticket that already holds the crbatch line says already noted"
assert_eq "$(comment_calls)" 0 "a ticket that already holds the crbatch line is skipped"

NP_COMMENTS_FAIL=1 run_np fix/himmel-55-x "$batch"
assert_eq "$np_rc" 6 "a failed comments read exits 6"
assert_eq "$(comment_calls)" 0 "a failed comments read posts nothing"

np_rc=0
bash "$NP" --branch fix/himmel-55-x --head "$head_sha" >/dev/null 2>&1 || np_rc=$?
assert_eq "$np_rc" 2 "a missing --list-file is a usage error"

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-note-polish (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-note-polish\n'
