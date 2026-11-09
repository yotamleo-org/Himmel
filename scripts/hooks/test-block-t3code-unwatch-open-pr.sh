#!/usr/bin/env bash
# Tests for scripts/hooks/block-t3code-unwatch-open-pr.sh. Hermetic:
# a stub `gh` on PATH answers `gh pr view`; payloads live in fixture files.
set -uo pipefail

unset T3CODE_UNWATCH_OK

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-t3code-unwatch-open-pr.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/t3unwatch.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GH_STUB_LOG="$TMP/gh.log"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) echo "gh: not found" >&2; exit 1 ;;
  garbage) echo "not json"; exit 0 ;;
  *) printf '{"state":"%s","mergeStateStatus":"%s","reviewDecision":"%s"}\n' \
       "${GH_STUB_STATE:-OPEN}" "${GH_STUB_MERGE_STATE:-BLOCKED}" "${GH_STUB_REVIEW:-}" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

printf '%s' '{"tool_name":"mcp__t3-code__unwatch_pull_request","tool_input":{"pullRequest":"https://github.com/o/r/pull/5054"}}' > "$TMP/p-url.json"
printf '%s' '{"tool_name":"mcp__t3-code__unwatch_pull_request","tool_input":{"number":77,"repo":"o/r"}}' > "$TMP/p-num.json"
printf '%s' '{"tool_name":"mcp__t3-code__other","tool_input":{"number":77}}' > "$TMP/p-other.json"
printf '%s' 'not json' > "$TMP/p-bad.json"

FAIL=0; N=0
# run <name> <payload> <want-rc> <stderr-grep|-> ; env set by caller
run() {
    local name="$1" payload="$2" want="$3" grep_for="$4" rc out
    N=$((N+1))
    : > "$GH_STUB_LOG"
    out=$(bash "$HOOK" < "$payload" 2>&1 >/dev/null); rc=$?
    if [ "$rc" != "$want" ]; then
        echo "FAIL $name: rc=$rc want=$want out=$out"; FAIL=$((FAIL+1)); return
    fi
    if [ "$grep_for" != "-" ] && ! grep -q -- "$grep_for" <<<"$out"; then
        echo "FAIL $name: stderr lacks '$grep_for': $out"; FAIL=$((FAIL+1)); return
    fi
    echo "ok   $name"
}

export GH_STUB_MODE=ok
GH_STUB_STATE=OPEN GH_STUB_MERGE_STATE=BLOCKED run "open+blocked denied, names state=OPEN" "$TMP/p-url.json" 2 "state=OPEN"
GH_STUB_STATE=OPEN GH_STUB_MERGE_STATE=BLOCKED run "deny names override" "$TMP/p-url.json" 2 "T3CODE_UNWATCH_OK"
GH_STUB_STATE=OPEN GH_STUB_MERGE_STATE=BLOCKED run "deny prints mergeStateStatus" "$TMP/p-url.json" 2 "mergeStateStatus=BLOCKED"
if grep -q -- "pr view 5054 --repo o/r" "$GH_STUB_LOG"; then echo "ok   url resolved to repo+number"; else echo "FAIL url resolution: $(cat "$GH_STUB_LOG")"; FAIL=$((FAIL+1)); fi
GH_STUB_STATE=OPEN run "number+repo payload denied" "$TMP/p-num.json" 2 "state=OPEN"
GH_STUB_STATE=MERGED run "MERGED allowed" "$TMP/p-url.json" 0 -
GH_STUB_STATE=CLOSED run "CLOSED allowed" "$TMP/p-url.json" 0 -
GH_STUB_STATE=OPEN run "other tool ignored" "$TMP/p-other.json" 0 -
if [ ! -s "$GH_STUB_LOG" ]; then echo "ok   other tool never calls gh"; else echo "FAIL other tool called gh"; FAIL=$((FAIL+1)); fi

T3CODE_UNWATCH_OK=1 GH_STUB_STATE=OPEN run "override allows OPEN" "$TMP/p-url.json" 0 "T3CODE_UNWATCH_OK"
if [ -s "$HOME/.himmel/t3code-unwatch-override.log" ]; then echo "ok   override logged"; else echo "FAIL override not logged"; FAIL=$((FAIL+1)); fi

GH_STUB_MODE=error run "unreadable PR fails open with warning" "$TMP/p-url.json" 0 "WARNING"
GH_STUB_MODE=garbage run "garbage gh output fails open with warning" "$TMP/p-url.json" 0 "WARNING"
run "unparseable hook input fails open" "$TMP/p-bad.json" 0 -

echo "$((N-FAIL))/$N cases (+ side checks) ; failures=$FAIL"
[ "$FAIL" = 0 ]
