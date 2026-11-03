#!/usr/bin/env bash
# make-chain-log.sh <outdir> - build the hook-chain run log that goes with journal.jsonl. Synthetic, temp dir only.
#   1. the static rows beside this script (hook-runs.jsonl);
#   2. rows the REAL launcher writes for three refusing stub guards: a secret-bearing line, a long line and a huge
#      identifier-like run (each bounded at 10 s). The launcher marks its own rows test-origin because a log override
#      is set, so jq rewrites that one field; the redaction under test is the launcher's real output;
#   3. one 2 MB identifier-like denyLine written straight into a production row.
# Result: <outdir>/hook-runs.jsonl. A launcher that exits other than 2 fails this script; the 10 s bound needs a GNU timeout
# (scripts/lib/timeout-bin.sh), and without one the launcher runs unbounded.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 1
REPO="$(cd "$HERE/../../../../.." && pwd)" || exit 1
OUT="$1"
# shellcheck source=../../../../lib/timeout-bin.sh
. "$REPO/scripts/lib/timeout-bin.sh" 2>/dev/null
mkdir -p "$OUT/stubs" || exit 1
RAW="$OUT/raw-runs.jsonl"
: >"$RAW" || exit 1

launch() { # <guard file name> <tool call id> <shell that prints the refusal on stderr>
  printf '#!/usr/bin/env bash\n%s\nexit 2\n' "$3" >"$OUT/stubs/$1" || exit 1
  chmod +x "$OUT/stubs/$1" || exit 1
  local rc=0
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"%s","session_id":"sess-8575","tool_input":{"command":"true"}}' "$2" |
    RUN_HOOK_CHAIN_SKIP_LOG="$OUT/raw-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$RAW" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 10} node "$REPO/scripts/hooks/run-hook-with-bash.js" --chain "$OUT/stubs/$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "make-chain-log: the launcher exited $rc for $2, not the deny 2" >&2; exit 1; }
}

launch block-read-secrets.sh toolu_sec1 'echo "refused: API_TOKEN=SECRETVALUE8575zq was read" >&2'
launch read-clamp.sh toolu_long1 'yes "denied" | head -n 100 | tr "\n" " " >&2'
launch block-destructive-commands.sh toolu_huge1 "head -c 300000 /dev/zero | tr '\\0' 'a' >&2"

cp "$HERE/hook-runs.jsonl" "$OUT/hook-runs.jsonl" || exit 1
jq -c '.origin = "production"' "$RAW" >>"$OUT/hook-runs.jsonl" || exit 1
head -c 2000000 /dev/zero | tr '\0' 'b' >"$OUT/huge-line.txt" || exit 1
jq -cn --rawfile line "$OUT/huge-line.txt" '{ts: "2026-11-02T12:00:20.000Z", v: 1, origin: "production", event: "PreToolUse", session: "sess-8575", callId: "toolu_huge2", tool: "Bash", invocation: "000000000b01", exit: 2, elapsed: 20,
  members: [{member: "block-git-stash.sh", occurrence: 1, outcome: "deny", reason: "RULE", elapsed: 11, denyLine: $line}]}' >>"$OUT/hook-runs.jsonl"
