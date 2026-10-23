#!/usr/bin/env bash
# Haiku bulk-child process bridge on the API lane, for ONE task class: read-only class-sweep site
# enumeration. The caller gives a defect-class description and absolute file paths; one Haiku call returns the
# sites (file:line) where the class occurs, as a bounded JSON artifact. It is a trusted-dispatch caller of
# claude-api.sh and adds no launch path of its own.
#
# Usage: bulk-call.sh --task-id ID --class-file F --paths-file F --model haiku --max-budget-usd B
#                     [--effort E] [--timeout SECS]
#        bulk-call.sh --cancel ID
# Env:   whatever claude-api.sh needs (HIMMEL_API_LANE=on, HIMMEL_API_ACCOUNT, ...); HIMMEL_API_TOOLS and
#        HIMMEL_API_KIND are set here and a caller's value is ignored.
# Out:   stdout = the artifact path (JSON, mode 600, under /tmp/claude-<uid>/bulk-<ID>).
#        status OK (exit 0) | DENIED | ERROR | INVALID | REFUSED | TIMEOUT | CANCELLED (exit 3);
#        exit 2 = a usage refusal before any call; exit 4 = not a trusted dispatch. A refusal is final: there is
#        no subscription fallback.
# Trusted dispatch: refused from a console-spawned leg (HIMMEL_CONSOLE_LEG) and a console relay
# (HIMMEL_CONSOLE_RELAY), as write-verdict.sh and go.sh refuse them: a leg cannot spend the API credit on its own
# authority, its console launches the call.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/qmd-bounded.sh
. "$REPO/scripts/lib/qmd-bounded.sh" || { echo "bulk-call: cannot load qmd-bounded.sh" >&2; exit 2; }

usage() { echo "bulk-call: $*" >&2; exit 2; }
seg_ok() { case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

# Read, Glob and Grep are the whole grant: no Agent/Task tool, so the child cannot spawn, and no write or shell
BULK_TOOLS="Read,Glob,Grep"
BUDGET_CEILING="0.05"
CLASS_MAX=8192
PATHS_MAX=40
ROOT="/tmp/claude-$(id -u)"

# a pid and every descendant of it, deepest first, so a cancel reaches claude and anything it left running
# shellcheck disable=SC2329 # called from kill_tree
tree_pids() {
  local kid
  for kid in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$kid"; done
  echo "$1"
}

# TERM the whole tree, wait (bounded) for the call to stop and settle its reservation, then KILL whatever
# ignored it. A fixed short grace let the KILL land on claude-api.sh mid-settle on a loaded box.
# shellcheck disable=SC2329 # invoked from the TERM trap string below
kill_tree() {
  local pids p i=0 live=1
  pids="$(tree_pids "$1")"
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  # the call's own pid is this shell's child and stays a zombie until the wait below, so it is not polled
  while [ "$live" -eq 1 ] && [ "$i" -lt 100 ]; do
    live=0
    for p in $pids; do [ "$p" = "$1" ] || ! kill -0 "$p" 2>/dev/null || live=1; done
    [ "$live" -eq 0 ] || { sleep 0.1; i=$((i + 1)); }
  done
  for p in $pids; do kill -KILL "$p" 2>/dev/null; done
}

# cancel is trusted dispatch too: a leg cannot stop a call its console launched
[ -z "${HIMMEL_CONSOLE_LEG:-}" ] && [ -z "${HIMMEL_CONSOLE_RELAY:-}" ] ||
  { echo "bulk-call: refusing - a console leg or relay does not launch or cancel API calls on its own authority; ask your console" >&2; exit 4; }

if [ "${1:-}" = "--cancel" ]; then
  [ "$#" -eq 2 ] || usage "--cancel needs exactly one task id"
  seg_ok "$2" || usage "task id must be a path segment"
  # the running bridge holds this lock for its whole life, so a free lock means no run and the pid file is stale
  # (a reused pid is never signalled)
  if [ ! -f "$ROOT/bulk-$2.lock" ] || ! exec 9<"$ROOT/bulk-$2.lock"; then echo "bulk-call: no running task $2" >&2; exit 3; fi
  if flock -n 9; then echo "bulk-call: no running task $2" >&2; exit 3; fi
  P="$(cat "$ROOT/bulk-$2/pid" 2>/dev/null)"
  case "$P" in ''|*[!0-9]*) echo "bulk-call: task $2 has no pid yet" >&2; exit 3 ;; esac
  # the pid file can lag a restart: only the process that really holds the lock (fd 9) is signalled
  [ "$(readlink "/proc/$P/fd/9" 2>/dev/null)" = "$ROOT/bulk-$2.lock" ] || { echo "bulk-call: task $2 pid is not the lock holder" >&2; exit 3; }
  kill -TERM "$P" || { echo "bulk-call: cannot signal task $2" >&2; exit 3; }
  echo "bulk-call: cancel sent to task $2"
  exit 0
fi

TASK="" CFILE="" PFILE="" MODEL="" BUDGET="" EFFORT="" TIMEOUT=300
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --task-id) TASK=$2 ;; --class-file) CFILE=$2 ;; --paths-file) PFILE=$2 ;; --model) MODEL=$2 ;;
    --max-budget-usd) BUDGET=$2 ;; --effort) EFFORT=$2 ;; --timeout) TIMEOUT=$2 ;;
    *) usage "unknown argument $1" ;;
  esac
  shift 2
done

seg_ok "$TASK" || usage "--task-id must be a path segment ([A-Za-z0-9][A-Za-z0-9._-]*)"
# the bulk tier: Haiku, named explicitly; a judgment-tier call is the judge bridge's job
case "$MODEL" in claude-haiku-*|haiku) ;; *) usage "--model must be a haiku model (bulk tier), got '$MODEL'" ;; esac
case "$MODEL" in *[!A-Za-z0-9._:/@-]*) usage "--model has characters outside [A-Za-z0-9._:/@-]" ;; esac
case "$BUDGET" in ''|*[!0-9.]*|*.*.*|.*|*.) usage "--max-budget-usd must be a decimal number" ;; esac
awk -v b="$BUDGET" -v c="$BUDGET_CEILING" 'BEGIN { exit !(b + 0 > 0 && b + 0 <= c + 0) }' ||
  usage "--max-budget-usd must be above 0 and at most $BUDGET_CEILING"
case "$EFFORT" in ''|*[!A-Za-z0-9._-]*|-*) [ -z "$EFFORT" ] || usage "--effort needs [A-Za-z0-9._-]" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) usage "--timeout must be whole seconds above 0" ;; esac
TIMEOUT=$((10#$TIMEOUT))
[ "$TIMEOUT" -gt 0 ] && [ "$TIMEOUT" -le 3600 ] || usage "--timeout must be 1 to 3600 seconds"
for f in "$CFILE" "$PFILE"; do
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || usage "$f must be a readable regular file, not a symlink"
  [ "$(LC_ALL=C tr -d '\000' < "$f" | wc -c)" = "$(wc -c < "$f")" ] || usage "$f holds a NUL byte"
done
CSIZE="$(wc -c < "$CFILE")"
[ "$CSIZE" -gt 0 ] && [ "$CSIZE" -le "$CLASS_MAX" ] || usage "--class-file must be 1 to $CLASS_MAX bytes"
NPATHS=0
while IFS= read -r p || [ -n "$p" ]; do
  [ -n "$p" ] || continue
  case "$p" in /*) ;; *) usage "every path must be absolute: $p" ;; esac
  case "/$p/" in */../*|*/./*) usage "a path may not hold a . or .. segment: $p" ;; esac
  [ -f "$p" ] && [ ! -L "$p" ] || usage "not a regular file (or a symlink): $p"
  NPATHS=$((NPATHS + 1))
done < "$PFILE"
[ "$NPATHS" -gt 0 ] && [ "$NPATHS" -le "$PATHS_MAX" ] || usage "--paths-file must list 1 to $PATHS_MAX files"

# one task id = one owned work dir; a live run on the same id is refused, a finished one is started clean
WORK="$ROOT/bulk-$TASK"
mkdir -p "$ROOT" 2>/dev/null
# checked before the chmod, which would follow a planted symlink and change its target
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] && [ -O "$ROOT" ] || usage "$ROOT must be a real directory owned by this user"
chmod 700 "$ROOT" || usage "cannot restrict $ROOT to this user"
exec 9>"$ROOT/bulk-$TASK.lock" || usage "cannot open the task lock"
flock -n 9 || usage "task $TASK is already running"
rm -rf "$WORK"
mkdir -p "$WORK/cwd" || usage "cannot create $WORK"
chmod 700 "$WORK"
RAW="$WORK/raw.json" ERR="$WORK/err.txt" PARSED="$WORK/parsed.json" SITES="$WORK/sites.json"
ART="$WORK/bulk-$TASK.json"
JOB="bulk-$TASK-$(date +%s)-$$"
case "$JOB" in *[!A-Za-z0-9._:-]*) JOB="bulk-$(date +%s)-$$" ;; esac

# The fixed instruction goes first and is the same for every bulk call, so the prefix caches; the class text and
# the paths come last.
PROMPT="You are a bulk child: one mechanical task, no judgment calls. You have Read, Glob and Grep only. Never run or change anything.

Task: find every site where the defect class below occurs in the listed files. Read each listed file. Report a site only when you can point at the line; do not guess and do not read files that are not listed.

Reply with ONE JSON object and nothing else (no prose, no code fence): {\"sites\":[{\"file\":\"<a listed path, copied exactly>\",\"line\":<1-based line number>,\"why\":\"<one short phrase>\"}]}. An empty sites array is a valid answer.

--- DEFECT CLASS ---
$(cat "$CFILE")

--- FILES (absolute paths, one per line) ---
$(cat "$PFILE")"

EFFORT_ARGS=()
[ -z "$EFFORT" ] || EFFORT_ARGS=(--effort "$EFFORT")

# claude-api.sh holds the reservation and settles or keeps it unknown; this bridge never touches the ledger, so a
# killed call keeps its full reservation. cwd is an empty scratch dir (the sandbox leaves stubs in a call's cwd).
CANCELLED=0 CALL=""
trap 'CANCELLED=1; kill_tree "$CALL"' TERM INT
RC=0
(
  cd "$WORK/cwd" || exit 2
  qmd_bounded "$TIMEOUT" env HIMMEL_API_TOOLS="$BULK_TOOLS" HIMMEL_API_KIND=bulk HIMMEL_API_JOB_ID="$JOB" \
    bash "$REPO/scripts/api-lane/claude-api.sh" -p "$PROMPT" --model "$MODEL" --permission-mode dontAsk \
    --max-budget-usd "$BUDGET" --output-format json ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} >"$RAW" 2>"$ERR"
) &
CALL=$!
# published only once the TERM trap is installed, so a cancel can never hit a bridge that has no handler yet
echo "$$" > "$WORK/pid"
wait "$CALL" || RC=$?
# a trapped signal ends the first wait early; reap the killed call before reading its files
[ "$CANCELLED" -eq 0 ] || wait "$CALL" 2>/dev/null

STATUS="" REASON="" COST=""
if [ "$CANCELLED" -eq 1 ]; then
  STATUS=CANCELLED REASON="cancelled by the dispatcher; the reservation stays held in the ledger"
elif [ "$RC" -eq 124 ]; then
  STATUS=TIMEOUT REASON="no result within ${TIMEOUT}s; the reservation stays held in the ledger"
elif [ "$RC" -ne 0 ]; then
  REFUSAL="$(sed -n 's/^claude-api: refused: //p' "$ERR" | head -n 1)"
  if [ -n "$REFUSAL" ]; then STATUS=REFUSED REASON="$REFUSAL"
  else STATUS=ERROR REASON="claude-api.sh exited $RC; the reservation stays held as unknown"; fi
fi

# A non-zero exit can still leave a JSON result (claude stopped on its own budget): its cost goes into the
# artifact, but the status stays ERROR and no site is kept.
if [ "$CANCELLED" -eq 0 ] && { [ "$RC" -eq 0 ] || { [ "$STATUS" = ERROR ] && [ -s "$RAW" ]; }; }; then
  if node "$REPO/scripts/api-lane/bulk-result.mjs" parse "$RAW" "$PFILE" "$SITES" >"$PARSED" 2>/dev/null; then
    # the parser's own fields, read back with node so no value is ever evaluated by the shell
    pf() { node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]];process.stdout.write(v==null?"":String(v))' "$PARSED" "$1"; }
    PSTATUS="$(pf status)"; COST="$(pf cost_usd)"
    if [ "$RC" -eq 0 ]; then STATUS=$PSTATUS REASON="$(pf reason)"
    else REASON="claude-api.sh exited $RC; $(pf reason)"; fi
  else
    [ "$RC" -ne 0 ] || { STATUS=ERROR REASON="result parser failed"; }
  fi
fi

node "$REPO/scripts/api-lane/bulk-result.mjs" artifact "$ART" "status=$STATUS" "reason=$REASON" "task_id=$TASK" \
  "class=class-sweep" "model=$MODEL" "budget_usd=$BUDGET" "cost_usd=$COST" "job_id=$JOB" --sites "$SITES" ||
  usage "cannot write the artifact"
rm -f "$WORK/pid"
# the writer can downgrade OK to ERROR; the exit code follows the artifact, not the pre-write status
STATUS="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).status))' "$ART" 2>/dev/null)" || STATUS=ERROR
printf '%s\n' "$ART"
[ "$STATUS" = OK ] || exit 3
exit 0
