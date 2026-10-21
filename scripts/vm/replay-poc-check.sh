#!/usr/bin/env bash
# replay-poc-check.sh — POC: ONE model-driven check run through
# record-once / replay-without-model (scripts/vm/lib/model-replay.sh), in the
# fixed verify shape Launch -> Doctor -> Drive -> Evidence -> Cleanup.
#
# The check is the trivial live `claude -p` dispatch of
# scripts/lib/test-claude-headless-live.sh: a haiku worker writes the line OK to
# a file. The first run records that artifact; later runs restore it with no
# model call until an input changes. The key covers the model, the prompt and
# scripts/lib/claude-headless.sh (the code under test), so editing the wrapper
# re-records. What replay does NOT re-check: the live dispatch plumbing itself
# (registry row, artifact verdict) — that is the live self-test's job; this check
# asserts only the artifact the model produced.
#
# Phases:
#   Launch   scratch work dir + the check's inputs
#   Doctor   read-only: is this run worth driving? (inputs readable; if a model
#            call would be needed, bank-preflight must say PROCEED)
#   Drive    replay_run: replay a recording, or record via claude-headless.sh
#   Evidence a fixed file: $HIMMEL_REPLAY_ROOT/evidence/last.json
#   Cleanup  remove the work dir (the recording and evidence are kept)
#
# Usage: bash scripts/vm/replay-poc-check.sh [--record]
#   --record   force a live model call and overwrite the recording
# Env: HIMMEL_REPLAY_ROOT  cache + evidence root (default ~/.himmel/replay-poc)
#      HIMMEL_REPLAY_MODE  auto | record | replay-only (see model-replay.sh)
# Exit: 0 asserted OK (replay or record); 1 assertion or dispatch failed;
#       3 doctor: not worth driving (bank not PROCEED and nothing to replay);
#       4 replay-only with no recording.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/model-replay.sh
. "$REPO/scripts/vm/lib/model-replay.sh" || exit 1

[ "${1:-}" = "--record" ] && HIMMEL_REPLAY_MODE=record
export HIMMEL_REPLAY_MODE="${HIMMEL_REPLAY_MODE:-auto}"
ROOT="${HIMMEL_REPLAY_ROOT:-$HOME/.himmel/replay-poc}"
CACHE="$ROOT/cache"
EVIDENCE="$ROOT/evidence"
MODEL=haiku
SUT="$REPO/scripts/lib/claude-headless.sh"

now_ms() { local n; n="$(date +%s%N 2>/dev/null)"; case "$n" in *N|"") echo "$(date +%s)000" ;; *) echo $((n / 1000000)) ;; esac; }
t0="$(now_ms)"

# --- Launch -------------------------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/replay-poc.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
ARTIFACT="$W/artifact.txt"
PROMPT="$W/prompt.txt"
# A relative artifact name keeps the prompt, and so the key, identical on every run.
cat > "$PROMPT" <<'EOF'
Run exactly this and nothing else: write the single line OK to the file
artifact.txt in the current directory (create it if it does not exist), then
stop. Do not ask questions.
EOF
KEY="$(replay_key "$MODEL" "$PROMPT" "$SUT")" || exit 1

# --- Doctor (read-only) -------------------------------------------------------
recorded=no
replay_valid "$CACHE" "$KEY" && recorded=yes
need_model=yes
[ "$recorded" = yes ] && [ "$HIMMEL_REPLAY_MODE" != record ] && need_model=no
if [ "$need_model" = yes ] && [ "$HIMMEL_REPLAY_MODE" != replay-only ]; then
  verdict="$(CADENCE_USAGE_LEG=replay-poc bash "$REPO/scripts/lib/usage-preflight.sh" 2>/dev/null | tail -1)"
  if [ "$verdict" != PROCEED ]; then
    echo "replay-poc-check: doctor: a model call is needed and bank-preflight says '${verdict:-?}' - not driving" >&2
    exit 3
  fi
fi
echo "replay-poc-check: doctor ok (key ${KEY:0:12}, recorded=$recorded, model call needed=$need_model)"

# --- Drive --------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked indirectly by replay_run
record_cmd() {
  HIMMEL_REGISTRY_DIR="$W/registry" bash "$SUT" \
    --role replay-poc --ticket HIMMEL-5420 --worktree "$W" --cwd "$W" \
    --artifact "$ARTIFACT" --permission-mode acceptEdits \
    --allowed-tools "Write" --model "$MODEL" --prompt-file "$PROMPT"
}
replay_run "$CACHE" "$KEY" "$ARTIFACT" -- record_cmd
drive_rc=$?

# --- Evidence -----------------------------------------------------------------
t1="$(now_ms)"
content="$(cat "$ARTIFACT" 2>/dev/null)"
ok=false
[ "$drive_rc" -eq 0 ] && [ "$content" = OK ] && ok=true
if ! { mkdir -p "$EVIDENCE" && jq -n --arg key "$KEY" --arg mode "${REPLAY_MODE_USED:-none}" \
    --argjson calls "${REPLAY_MODEL_CALLS:-0}" --argjson wall "$((t1 - t0))" --argjson rc "$drive_rc" \
    --arg artifact "$content" --argjson ok "$ok" \
    '{key:$key, mode:$mode, model_calls:$calls, wall_ms:$wall, drive_rc:$rc, artifact:$artifact, ok:$ok}' \
    > "$EVIDENCE/last.json"; }; then
  echo "replay-poc-check: could not write evidence to $EVIDENCE/last.json" >&2
  exit 1
fi
echo "replay-poc-check: mode=${REPLAY_MODE_USED:-none} model_calls=${REPLAY_MODEL_CALLS:-0} wall_ms=$((t1 - t0)) ok=$ok (evidence: $EVIDENCE/last.json)"

# --- Cleanup: the EXIT trap removes $W ----------------------------------------
[ "$drive_rc" -eq 4 ] && exit 4
[ "$ok" = true ] || exit 1
exit 0
