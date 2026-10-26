#!/usr/bin/env bash
# billed-exempt: operator-run single measured call, its whole purpose; never scheduled
# operator-run, ONE measured Haiku call through claude-api.sh, to show
# which balance a print-mode call under a linked-org API key draws from.
# The key never passes through argv, a log or a model context: this script reads
# it itself and hands it only to the launcher's environment.
#
# Usage: measure-credit.sh <A|B> <key-id> <key-source> <remaining-usd-before>
#   key-source: an op:// reference (read with `op read`) or a private env file
#               holding one ANTHROPIC_API_KEY=<key> line (never sourced).
#   remaining-usd-before: the Console's Promotional credits figure, read just now;
#               it refreshes the account's snapshot (the gate refuses one older than 600s).
# Prints only the launcher's verdict, the run's outcome fields and its cost.
set -u
set +x
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$#" -eq 4 ] || { echo "usage: measure-credit.sh <A|B> <key-id> <key-source> <remaining-usd-before>" >&2; exit 2; }
ACCOUNT="$1" KEY_ID="$2" SOURCE="$3" BEFORE="$4"
case "$BEFORE" in ""|*[!0-9.]*) echo "measure-credit: remaining-usd must be a plain decimal" >&2; exit 2 ;; esac

case "$SOURCE" in
  op://*) KEY="$(op read "$SOURCE")" || { echo "measure-credit: op read failed" >&2; exit 2; } ;;
  *) [ -f "$SOURCE" ] || { echo "measure-credit: key source is neither op:// nor a file" >&2; exit 2; }
     KEY="$(sed -n 's/^ANTHROPIC_API_KEY=//p' "$SOURCE" | head -n 1)" ;;
esac
[ -n "$KEY" ] || { echo "measure-credit: no ANTHROPIC_API_KEY in the key source" >&2; exit 2; }

# Refresh the operator snapshot with the figure just read from the Console; the refresh also moves the
# reconciled-spend watermark, so spend the Console already shows is not counted again.
node "$REPO/scripts/api-lane/grant-snapshot.mjs" "$ACCOUNT" "$BEFORE" || exit 2

# An empty scratch cwd keeps the call small: no project CLAUDE.md or hooks load.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/measure-credit.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out.json"
(cd "$WORK" && ANTHROPIC_API_KEY="$KEY" HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT="$ACCOUNT" HIMMEL_API_KEY_ID="$KEY_ID" \
  HIMMEL_API_JOB_ID="measure-credit-$(date +%s)" HIMMEL_API_TOOLS="" \
  bash "$REPO/scripts/api-lane/claude-api.sh" -p "Reply with the single word: ok" \
    --model claude-haiku-5-5 --permission-mode default --max-budget-usd 0.05 --output-format json >"$OUT")
RC=$?
unset KEY
echo "launcher_rc=$RC"
# shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
node -e '
  let r = {}; try { r = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); } catch {}
  for (const k of ["type", "subtype", "is_error", "terminal_reason", "api_error_status", "total_cost_usd", "num_turns"]) console.log(`${k}=${r[k] ?? ""}`);
  for (const [m, u] of Object.entries(r.modelUsage || {})) console.log(`model=${m} cost_usd=${u.costUSD} cost_basis=${u.costBasis ?? ""}`);
' "$OUT"
exit "$RC"
