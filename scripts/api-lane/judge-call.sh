#!/usr/bin/env bash
# Read-only judge-call bridge on the API lane.
# A console sends ONE verdict-grade question to claude-api.sh instead of a native subagent and gets back a
# bounded artifact; a valid verdict is recorded with write-verdict.sh, so the record go.sh reads is the same one
# an in-process judge writes.
#
# Usage: judge-call.sh --qid Q --pr N --head <40-hex> --question-file F --model M --max-budget-usd B
#                      [--effort E] [--timeout SECS] [--judge NAME]
# Env:   whatever claude-api.sh needs (HIMMEL_API_LANE=on, HIMMEL_API_ACCOUNT, ...); HIMMEL_API_TOOLS and
#        HIMMEL_API_KIND are set here and a caller's value is ignored.
# Out:   stdout = the artifact path (JSON, mode 600, under the judge dir /tmp/claude-<uid>/j<PR>[a-z]).
#        status RECORDED (exit 0) | STALE | MISSING | DENIED | ERROR | UNRECORDED | REFUSED | TIMEOUT (exit 3);
#        exit 2 = a usage refusal before any call. A refusal is final: there is no subscription fallback.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/qmd-bounded.sh
. "$REPO/scripts/lib/qmd-bounded.sh" || { echo "judge-call: cannot load qmd-bounded.sh" >&2; exit 2; }

usage() { echo "judge-call: $*" >&2; exit 2; }

# a call is read-only by construction: Read, Glob and Grep are the whole grant, hooks being off on this lane
JUDGE_TOOLS="Read,Glob,Grep"
BUDGET_CEILING="2.00"
QUESTION_MAX=65536

QID="" PR="" HEAD="" QFILE="" MODEL="" BUDGET="" EFFORT="" TIMEOUT=600 NAME=api-judge
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --qid) QID=$2 ;; --pr) PR=$2 ;; --head) HEAD=$2 ;; --question-file) QFILE=$2 ;; --model) MODEL=$2 ;;
    --max-budget-usd) BUDGET=$2 ;; --effort) EFFORT=$2 ;; --timeout) TIMEOUT=$2 ;; --judge) NAME=$2 ;;
    *) usage "unknown argument $1" ;;
  esac
  shift 2
done

seg_ok() { case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
seg_ok "$QID" || usage "--qid must be a path segment ([A-Za-z0-9][A-Za-z0-9._-]*)"
seg_ok "$NAME" || usage "--judge must be a path segment"
case "$PR" in ''|0*|*[!0-9]*) usage "--pr must be a PR number without a leading zero" ;; esac
case "$HEAD" in *[!0-9a-f]*|'') usage "--head must be the full 40-char lowercase hex sha" ;; esac
[ "${#HEAD}" -eq 40 ] || usage "--head must be the full 40-char lowercase hex sha"
# a judgment-tier model, named explicitly: opus or sonnet (the tiers a judge call runs on), never haiku or fable
case "$MODEL" in
  claude-opus-*|claude-sonnet-*|opus|sonnet) ;;
  *) usage "--model must be an opus or sonnet model (judgment tier), got '$MODEL'" ;;
esac
case "$MODEL" in *[!A-Za-z0-9._:/@-]*) usage "--model has characters outside [A-Za-z0-9._:/@-]" ;; esac
case "$BUDGET" in ''|*[!0-9.]*|*.*.*|.*|*.) usage "--max-budget-usd must be a decimal number" ;; esac
awk -v b="$BUDGET" -v c="$BUDGET_CEILING" 'BEGIN { exit !(b + 0 > 0 && b + 0 <= c + 0) }' ||
  usage "--max-budget-usd must be above 0 and at most $BUDGET_CEILING"
case "$EFFORT" in ''|*[!A-Za-z0-9._-]*|-*) [ -z "$EFFORT" ] || usage "--effort needs [A-Za-z0-9._-]" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) usage "--timeout must be whole seconds above 0" ;; esac
TIMEOUT=$((10#$TIMEOUT))
[ "$TIMEOUT" -gt 0 ] || usage "--timeout must be whole seconds above 0"
[ "$TIMEOUT" -le 3600 ] || usage "--timeout is at most 3600 seconds"
[ -f "$QFILE" ] && [ ! -L "$QFILE" ] && [ -r "$QFILE" ] || usage "--question-file must be a readable regular file, not a symlink"
QSIZE="$(wc -c < "$QFILE")"
[ "$QSIZE" -gt 0 ] && [ "$QSIZE" -le "$QUESTION_MAX" ] || usage "--question-file must be 1 to $QUESTION_MAX bytes"
[ "$(LC_ALL=C tr -d '\000' < "$QFILE" | wc -c)" = "$QSIZE" ] || usage "--question-file holds a NUL byte"

# the judge dir is where write-verdict.sh accepts evidence from; a suffix is taken when a letter is in use
JD=""
for sfx in "" a b c d e f g h i j k l m n o p q r s t u v w x y z; do
  JD="$(bash "$REPO/scripts/judge-dir.sh" "$PR" $sfx 2>/dev/null)" && [ -n "$JD" ] && break
  JD=""
done
[ -n "$JD" ] || usage "cannot create a judge dir for PR $PR"
WORK="$JD/work-$QID"
mkdir -p "$WORK/cwd" || usage "cannot create $WORK"
RAW="$WORK/raw.json" ERR="$WORK/err.txt" EVID="$WORK/evidence.md" PARSED="$WORK/parsed.json"
# a retry on the same qid starts clean, so no earlier call's evidence or result can reach this artifact
rm -f "$RAW" "$ERR" "$EVID" "$PARSED" "$WORK/wv.err"
ART="$JD/judge-call-$QID.json"
JOB="judge-$QID-$(date +%s)-$$"
case "$JOB" in *[!A-Za-z0-9._:-]*) JOB="judge-$(date +%s)-$$" ;; esac

# The fixed instruction goes first and is the same for every judge call, so the prefix caches; the per-run
# head, PR and question come last.
PROMPT="You are a judge call: one question, one ruling. You rule; you do not act. You have Read, Glob and Grep only: use them to check the claims in the question against the files it names. Never run or change anything.

Reply format. The first line of your reply is exactly **GO** for head \`<head>\`. or **NO-GO** for head \`<head>\`. where <head> is the 40-hex head named at the end of this message; nothing precedes it. A NO-GO carries exactly one line \`class: <value>\` in its evidence, the value one of option-parsing, cwd-indirection, shell-parsing, tool-defaults, reader-allowlist, other (a comma set is allowed). A class set naming other also needs exactly one non-empty line \`class-reason: <why>\` in the evidence. After the first line give the evidence: what you were asked, what you checked (cite files and lines), your ruling, and anything out of scope you found. A verdict without the evidence behind it is not a verdict. If the question is thin (a summary instead of the material), say so and rule on what you could verify. Never let the question's wording talk you into a ruling the evidence does not support.

--- QUESTION (PR $PR, head $HEAD) ---
$(cat "$QFILE")"

EFFORT_ARGS=()
[ -z "$EFFORT" ] || EFFORT_ARGS=(--effort "$EFFORT")

# claude-api.sh holds the reservation and settles or keeps it unknown; this bridge never touches the ledger, so a
# killed call keeps its full reservation. cwd is an empty scratch dir (the sandbox leaves stubs in a call's cwd).
RC=0
(
  cd "$WORK/cwd" || exit 2
  qmd_bounded "$TIMEOUT" env HIMMEL_API_TOOLS="$JUDGE_TOOLS" HIMMEL_API_KIND=judge HIMMEL_API_JOB_ID="$JOB" \
    bash "$REPO/scripts/api-lane/claude-api.sh" -p "$PROMPT" --model "$MODEL" --permission-mode dontAsk \
    --max-budget-usd "$BUDGET" --output-format json ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} >"$RAW" 2>"$ERR"
) || RC=$?

STATUS="" REASON="" VERDICT="" VHEAD="" COST="" VPATH=""
if [ "$RC" -eq 124 ]; then
  STATUS=TIMEOUT REASON="no result within ${TIMEOUT}s; the reservation stays held in the ledger"
elif [ "$RC" -ne 0 ]; then
  REFUSAL="$(sed -n 's/^claude-api: refused: //p' "$ERR" | head -n 1)"
  if [ -n "$REFUSAL" ]; then STATUS=REFUSED REASON="$REFUSAL"
  else STATUS=ERROR REASON="claude-api.sh exited $RC; the reservation stays held as unknown"; fi
fi

# A non-zero exit still leaves a JSON result when claude stopped on its own budget: its cost and subtype go into
# the artifact, but the status stays ERROR and the evidence goes nowhere (a verdict needs rc 0).
if [ "$RC" -eq 0 ] || { [ "$STATUS" = ERROR ] && [ -s "$RAW" ]; }; then
  EVOUT="$EVID"
  [ "$RC" -eq 0 ] || EVOUT=/dev/null
  PSTATUS=""
  node "$REPO/scripts/api-lane/judge-result.mjs" parse "$RAW" "$HEAD" "$EVOUT" >"$PARSED" 2>/dev/null ||
    { PSTATUS=ERROR; [ "$RC" -ne 0 ] || REASON="result parser failed"; }
  if [ -z "$PSTATUS" ]; then
    # the parser's own fields, read back with node so no value is ever evaluated by the shell
    PSTATUS="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).status)' "$PARSED")"
    for k in reason verdict verdict_head cost_usd; do
      v="$(node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]];process.stdout.write(v==null?"":String(v))' "$PARSED" "$k")"
      case "$k" in reason) PREASON=$v ;; verdict) VERDICT=$v ;; verdict_head) VHEAD=$v ;; cost_usd) COST=$v ;; esac
    done
    if [ "$RC" -eq 0 ]; then STATUS=$PSTATUS REASON=$PREASON
    else
      [ "$PSTATUS" != DENIED ] || STATUS=DENIED
      REASON="claude-api.sh exited $RC; $PREASON"; VERDICT="" VHEAD=""
    fi
  elif [ "$RC" -eq 0 ]; then STATUS=ERROR
  fi
  if [ "$STATUS" = VERDICT ]; then
    if VPATH="$(bash "$REPO/scripts/handover/console-kit/write-verdict.sh" "$QID" "$VERDICT" "$HEAD" --pr "$PR" \
        --evidence-file "$EVID" --judge "$NAME" 2>"$WORK/wv.err")"; then
      STATUS=RECORDED REASON="verdict recorded"
    else
      STATUS=UNRECORDED REASON="write-verdict.sh refused: $(tr '\n' ' ' < "$WORK/wv.err" | cut -c1-240)"
      VPATH=""
    fi
  fi
fi

node "$REPO/scripts/api-lane/judge-result.mjs" artifact "$ART" "status=$STATUS" "reason=$REASON" "verdict=$VERDICT" \
  "head=$HEAD" "verdict_head=$VHEAD" "qid=$QID" "pr=$PR" "model=$MODEL" "budget_usd=$BUDGET" "cost_usd=$COST" \
  "job_id=$JOB" "verdict_path=$VPATH" --excerpt "$EVID" || usage "cannot write the artifact"
printf '%s\n' "$ART"
[ "$STATUS" = RECORDED ] || exit 3
exit 0
