#!/usr/bin/env bash
# scripts/report/test-himmel-report.sh - suite for himmel_report.py (/himmel-report).
# Every case runs under a sandbox HOME; nothing is written under the real HOME and the
# `gh` that "sends" is a stub that records its argv.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REPORT="$HERE/himmel_report.py"
FRICTION="$REPO/scripts/eval/friction/friction.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-report-test.XXXXXX")" || { echo "test-himmel-report: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in output";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: '$3' leaked";; *) pass "$1";; esac; }
ok_if() { if [ "$2" = yes ]; then pass "$1"; else fail "$1"; fi; }
nfiles() { find "$1" -type f | wc -l | tr -d ' '; }

export HOME="$TMP/home"; mkdir -p "$HOME"
unset HIMMEL_USER_REPORTS HIMMEL_REPORT_GH HIMMEL_REPORT_GITLEAKS 2>/dev/null || true

# a stub gh that records its argv and the body file it was handed
GH="$TMP/gh-stub"
cat >"$GH" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
while [ $# -gt 0 ]; do
  case "$1" in --body-file) cp "$2" "$GH_BODY";; esac
  shift
done
echo "https://github.com/yotamleo-org/Himmel/issues/1"
EOF
chmod +x "$GH"
export GH_CALLS="$TMP/gh-calls" GH_BODY="$TMP/gh-body"

# fixture refusal: a real guard denial text carrying three secret shapes and a home path
AKIA="AKIA$(printf 'ABCDEFGHIJKLMNOP')"
BEARER="Bearer abcdefghijklmnopqrstuvwxyz012345"
TG="123456789:$(printf 'ABCdefGHIjklMNOpqrSTUvwxYZ0123456789-')"
FAKEHOME="/$(printf 'ho')me/someone"
REFUSAL="$TMP/refusal.txt"
cat >"$REFUSAL" <<EOF
PreToolUse:Bash hook error: [x]: guard-pr-check-literal: DENIED - \`cat <<EOF\` (HIMMEL-3383): 'r[0-9a-f]*' does not resolve to this root's scripts/cr/ or scripts/handover/ writer by its text alone.
cwd $FAKEHOME/work key $AKIA auth: $BEARER bot $TG
EOF

# RED: the command exists and drafts without sending
OUT="$(python3 -I "$REPORT" draft --text-file "$REFUSAL" 2>"$TMP/err")"
eq "draft exits 0" "$?" "0"
has "draft says it is not sent" "$OUT" "NOT SENT"
hasnt "draft output: no AWS key" "$OUT" "$AKIA"
hasnt "draft output: no bearer token" "$OUT" "abcdefghijklmnopqrstuvwxyz012345"
hasnt "draft output: no telegram token" "$OUT" "ABCdefGHIjklMNOpqrSTUvwxYZ0123456789"
hasnt "draft output: no home path" "$OUT" "$FAKEHOME"
has "draft output: redaction marker" "$OUT" "[REDACTED]"
has "draft output: classified like friction" "$OUT" "text-mentions-gate-path"
ID="$(printf '%s' "$OUT" | sed -n 's/^report-id: //p' | head -1)"
ok_if "draft prints a report id" "$([ -n "$ID" ] && echo yes)"
DRAFT="$HOME/.himmel/reports/$ID.md"
ok_if "draft file written under the sandbox HOME" "$([ -f "$DRAFT" ] && echo yes)"
hasnt "draft file: no AWS key" "$(cat "$DRAFT" 2>/dev/null)" "$AKIA"

# local lesson: known-findings schema, loadable by known-findings.sh
LESSONS="$HOME/.himmel/known-findings.local.json"
eq "lesson file has one class" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["classes"]))' "$LESSONS")" "1"
LIST="$(KNOWN_FINDINGS_FILE="$LESSONS" bash "$REPO/scripts/cr/known-findings.sh" --list 2>&1)"
eq "known-findings.sh --list loads the lesson file" "$?" "0"
has "known-findings.sh --list names the lesson" "$LIST" "user-text-mentions-gate-path"
has "guard-override suggestion names the hook" "$OUT" "guard-pr-check-literal"
has "guard-override suggestion points at the launching shell" "$OUT" "launching shell"

# repeating the same report does not double-count or double-write
OUT2="$(python3 -I "$REPORT" draft --text-file "$REFUSAL" 2>&1)"
has "second identical report is recognised" "$OUT2" "already reported"
eq "lesson file still has one class" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["classes"]))' "$LESSONS")" "1"
eq "report ledger has one row" "$(wc -l <"$HOME/.himmel/state/user-reports.jsonl" | tr -d ' ')" "1"

# consent: nothing is sent without --yes
HIMMEL_REPORT_GH="$GH" python3 -I "$REPORT" send "$ID" >"$TMP/send0.out" 2>&1
eq "send without --yes exits 4" "$?" "4"
ok_if "send without --yes never calls gh" "$([ ! -e "$GH_CALLS" ] && echo yes)"
has "send without --yes says not sent" "$(cat "$TMP/send0.out")" "not sent"
HIMMEL_REPORT_GH="$GH" python3 -I "$REPORT" send "$ID" --yes >"$TMP/send1.out" 2>&1
eq "send --yes exits 0" "$?" "0"
eq "send --yes calls gh once" "$(wc -l <"$GH_CALLS" | tr -d ' ')" "1"
has "send --yes targets the himmel repo" "$(cat "$GH_CALLS")" "issue create -R yotamleo-org/Himmel"
hasnt "sent body: no AWS key" "$(cat "$GH_BODY")" "$AKIA"
has "send --yes prints the issue url" "$(cat "$TMP/send1.out")" "issues/1"
HIMMEL_REPORT_GH="$GH" python3 -I "$REPORT" send "nosuchid" --yes >/dev/null 2>&1
eq "send of an unknown id exits 2" "$?" "2"

# friction.py: user reports are a third verdict source
FOUT="$TMP/friction.json"
python3 -I "$FRICTION" --repo "$REPO" --now 2099-01-01T00:00:00Z --days 36500 \
  --projects "$TMP/noproj" --docs "$TMP/nodocs" --reports "$HOME/.himmel/state/user-reports.jsonl" \
  --json "$FOUT" --md "$TMP/friction.md" >/dev/null 2>&1
eq "friction reads the reports file" "$?" "0"
eq "friction counts the user report by class" \
  "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([[r["source"], r["class"], r["count"]] for r in d["user_reports"]])' "$FOUT")" \
  "[['hook:guard-pr-check-literal', 'text-mentions-gate-path', 1]]"
eq "friction meta carries the user report total" \
  "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["meta"]["user_reports"])' "$FOUT")" "1"
has "friction markdown lists user reports" "$(cat "$TMP/friction.md")" "User-reported over-denies"
python3 -I "$FRICTION" --repo "$REPO" --now 2099-01-01T00:00:00Z --days 36500 --projects "$TMP/noproj" --docs "$TMP/nodocs" \
  --reports "$HOME/.himmel/state/user-reports.jsonl" --record --eval-ledger "$TMP/runs.jsonl" >/dev/null 2>&1
eq "friction --record carries user_reported_over_deny" \
  "$(python3 -I -c 'import json,sys; m=json.loads(open(sys.argv[1]).readline())["metrics"]; print(m["user_reported_over_deny"], m["user_over_deny:hook:guard-pr-check-literal/text-mentions-gate-path"])' "$TMP/runs.jsonl")" "1 1"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-01-01T00:00:00Z --days 7 --projects "$TMP/noproj" --docs "$TMP/nodocs" \
  --reports "$HOME/.himmel/state/user-reports.jsonl" --json "$TMP/old.json" --md "$TMP/old.md" >/dev/null 2>&1
eq "a report outside the window is not counted" \
  "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["meta"]["user_reports"])' "$TMP/old.json")" "0"

# review-point kind: no hook, so the lesson is a rebuttal and no override suggestion is printed
RV="$TMP/review.txt"; printf 'critic: bare wait returns before the jobs finish (token=abcdefghijklmnop1234)\n' >"$RV"
OUT3="$(python3 -I "$REPORT" draft --kind review --class bare-wait-claim --text-file "$RV" 2>&1)"
eq "review draft exits 0" "$?" "0"
has "review draft names the class" "$OUT3" "bare-wait-claim"
hasnt "review draft: no guard-override suggestion" "$OUT3" "launching shell"
hasnt "review draft: token value redacted" "$OUT3" "abcdefghijklmnop1234"
eq "lesson file now has two classes" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["classes"]))' "$LESSONS")" "2"

# fail closed: a gitleaks hit on the redacted draft refuses and writes nothing new
STUB="$TMP/gitleaks-stub"; printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB"; chmod +x "$STUB"
BEFORE="$(nfiles "$HOME/.himmel/reports")"
printf 'some other refusal text, different bytes\n' >"$TMP/other.txt"
HIMMEL_REPORT_GITLEAKS="$STUB" python3 -I "$REPORT" draft --text-file "$TMP/other.txt" >"$TMP/gl.out" 2>&1
eq "a gitleaks hit exits 3" "$?" "3"
eq "a gitleaks hit writes no draft" "$(nfiles "$HOME/.himmel/reports")" "$BEFORE"

# empty input is refused
: >"$TMP/empty.txt"
python3 -I "$REPORT" draft --text-file "$TMP/empty.txt" >/dev/null 2>&1
eq "empty input exits 2" "$?" "2"

echo "himmel-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
