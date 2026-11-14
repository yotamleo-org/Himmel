#!/usr/bin/env bash
# billed-opt-in: arming
# graph-choices-pass.sh -- the daily graph pass: runs each corpus the user chose, on the accounts the user chose, under a
# spend cap, and never lets a failed or rejected account fall through to the subscription.
#
# No args. The HIMMEL-GraphChoices runner (graph-choices-cadence.sh arm) is the only opt-in: storing a choice alone
# spends nothing. Prints one result line per corpus (`graph-choices-pass: <corpus> <word> [reason]`), plus
# `graph-choices-pass: <corpus> ALERT <word> <reason>` for every alert so a station with no Telegram still reads it in
# the runner's log (~/.claude/graph-choices-cadence/graph-choices.log). Lines that name no corpus read
# `graph-choices-pass: - <text>`.
#
# Per fire: role (a publisher touches nothing; an unreadable config alerts under graph-config-unreadable); a batch
# directory whose corpus left the store is printed; each corpus's root is checked and its free AST pass runs with the
# graph outside the repo; with no route (none, or no choice) the sentence is printed and nothing else runs; otherwise
# the route runs per corpus in store order, each step at most once, at most one new batch or one subscription run a
# fire. A step's outcome is the first line of its --result-file, never log text.
#
# Exit: 0 when the pass finished, whatever the words were; non-zero only on a crash.
#
# Seams (tests): GRAPH_CHOICES_AST_UPDATE, GRAPH_CHOICES_SEMANTIC_UPDATE.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GC="$REPO/scripts/himmelctl/lib/graph-choices.js"
AST_UPDATE="${GRAPH_CHOICES_AST_UPDATE:-$HERE/ast-update.sh}"
SEM_UPDATE="${GRAPH_CHOICES_SEMANTIC_UPDATE:-$HERE/semantic-update.sh}"
PIN="$REPO/scripts/lib/native-auth-pin.sh"
ALERT="$REPO/scripts/luna/cadence-alert.sh"
LOGF="${HOME:-/tmp}/.claude/graph-choices-cadence/graph-choices.log"

say() { printf 'graph-choices-pass: - %s\n' "$*"; }
word_line() { printf 'graph-choices-pass: %s %s\n' "$1" "$2"; }

alert_text() {
  case "$1" in
    no-route) A_REASON="no account had room"; A_CAUSE="every account in the route was out of credit or room"; A_DO="add credit or a route step; the next fire tries again" ;;
    key-rejected) A_REASON="an account rejected its API key"; A_CAUSE="HTTP 401 or 403 from the provider"; A_DO="rotate the key or remove the letter from the route" ;;
    fence-denied) A_REASON="the egress fence refused this corpus"; A_CAUSE="the root classifies as a corpus that may not leave the machine"; A_DO="remove the corpus from the choice" ;;
    over-cap) A_REASON="the estimate is over the daily cap"; A_CAUSE="the first file of the sorted plan is over max_usd_per_pass"; A_DO="add the file to .graphify-corpus-ignore or raise max_usd_per_pass" ;;
    corpus-failed) A_REASON="the semantic pass failed for this corpus"; A_CAUSE="a poll, graphify extract or merge failed"; A_DO="read the pass log" ;;
    partial) A_REASON="some chunks failed"; A_CAUSE="the good chunks merged; the failed files retry"; A_DO="read the pass log if it repeats" ;;
    ast-failed) A_REASON="the structure pass failed"; A_CAUSE="graphify update or its lock failed"; A_DO="read the pass log" ;;
    *) A_REASON="the pass stopped"; A_CAUSE="an account or host failure, or no valid result word"; A_DO="read the pass log" ;;
  esac
}

# alert <corpus> <word> [detail]: the sender (deduped by its own script) and the log line C88 reads
alert() {
  local name="$1" word="$2" detail="${3:-}"
  alert_text "$word"
  bash "$ALERT" fail "graph-choices-$name" "$A_REASON" "$LOGF" "$A_CAUSE" "$A_DO" >/dev/null 2>&1
  printf 'graph-choices-pass: %s ALERT %s %s\n' "$name" "$word" "${detail:-$A_REASON}"
}
clear_alert() { bash "$ALERT" clear "graph-choices-$1" >/dev/null 2>&1; }

command -v node >/dev/null 2>&1 || { echo "graph-choices-pass: node is not on PATH" >&2; exit 1; }

# --- 1. role -----------------------------------------------------------------------------------------------------
role="$(node "$GC" role 2>/dev/null)"
[ -n "$role" ] || { echo "graph-choices-pass: the choice store could not be read (graph-choices.js role failed)" >&2; exit 1; }
case "$role" in
  publisher)
    bash "$ALERT" clear graph-config-unreadable >/dev/null 2>&1
    say "this station publishes the himmel graph; the HIMMEL-GraphMap cadence owns it, so this pass touches nothing"
    exit 0 ;;
  unreadable)
    cause="$(node "$GC" check 2>/dev/null | sed -n 's/^cause=//p' | head -n 1)"
    case "$cause" in symlink | not-a-file | mode | not-json | empty | graphify-shape | missing | publisher-key-lost) ;; *) cause="" ;; esac
    if [ -z "$cause" ]; then
      say "graph config unreadable"
      bash "$ALERT" fail graph-config-unreadable "graph config unreadable" "$LOGF" "unknown, see log" "run bash scripts/himmelctl/himmelctl.sh doctor" >/dev/null 2>&1
      exit 0
    fi
    lines="$(node "$GC" alert-lines "$cause" 2>/dev/null)"
    first="$(printf '%s\n' "$lines" | sed -n 1p)"
    fix="$(printf '%s\n' "$lines" | sed -n 2p)"
    say "$first"
    say "$fix"
    bash "$ALERT" fail graph-config-unreadable "graph config unreadable (cause=$cause)" "$LOGF" "${first#*): }" "$fix" >/dev/null 2>&1
    exit 0 ;;
esac
bash "$ALERT" clear graph-config-unreadable >/dev/null 2>&1

# --- the route, read once ----------------------------------------------------------------------------------------
parsed="$(node "$GC" route 2>/dev/null | node -e '
const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log("S\t" + r.state);
console.log("K\t" + (r.max_usd_per_pass == null ? "" : String(r.max_usd_per_pass)));
console.log("O\t" + r.order.join(","));
for (const c of r.corpora) console.log("C\t" + c.name + "\t" + c.root);
for (const e of r.errors) console.log("E\t" + String(e).replace(/[^ -~]/g, "?"));
' 2>/dev/null)"
[ -n "$parsed" ] || { echo "graph-choices-pass: the route could not be parsed" >&2; exit 1; }
STATE="" CAP="" ORDER=""
NAMES=() ROOTS=() ERRS=()
while IFS=$'\t' read -r tag a b; do
  case "$tag" in
    S) STATE="$a" ;;
    K) CAP="$a" ;;
    O) ORDER="$a" ;;
    C) NAMES+=("$a"); ROOTS+=("$b") ;;
    E) ERRS+=("$a") ;;
  esac
done <<<"$parsed"

in_store() { local n; for n in ${NAMES[@]+"${NAMES[@]}"}; do [ "$n" != "$1" ] || return 0; done; return 1; }
out_of() { node "$GC" out "$1" 2>/dev/null; }

# --- 2. a batch directory whose corpus left the store -------------------------------------------------------------
probe_out="$(out_of probe)"
if [ -n "$probe_out" ]; then
  choices_dir="$(dirname "$(dirname "$probe_out")")"
  for batch in "$choices_dir"/*/graphify-out/semantic-batch; do
    [ -f "$batch/batch.json" ] || continue
    gone="$(basename "$(dirname "$(dirname "$batch")")")"
    in_store "$gone" && continue
    say "$gone left the store but a batch waits at $batch; to resume it put $gone back in the graph choice, to drop it remove that directory"
  done
fi

if [ "$STATE" = invalid ]; then
  say "$(node "$GC" sentence --state invalid 2>/dev/null)"
  for e in ${ERRS[@]+"${ERRS[@]}"}; do say "invalid: $e"; done
  exit 0
fi
if [ "${#NAMES[@]}" -eq 0 ]; then
  case "$STATE" in none) s=none ;; *) s=default ;; esac
  say "$(node "$GC" sentence --state "$s" 2>/dev/null)"
  exit 0
fi

# --- 3. each corpus: root check, then the free AST pass ----------------------------------------------------------
# shellcheck source=../lib/prim.sh
. "$REPO/scripts/lib/prim.sh" || exit 1
WORK="$(tmpdir)" || { echo "graph-choices-pass: no scratch directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
OK_NAMES=() OK_ROOTS=()
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  name="${NAMES[$i]}" root="${ROOTS[$i]}"
  i=$((i + 1))
  why="$(node "$GC" root-check "$root" 2>/dev/null | head -n 1 | tr -c '[:print:]' '?')"
  if ! node "$GC" root-check "$root" >/dev/null 2>&1; then
    say "$name skipped: ${why:-the root cannot be used}"
    continue
  fi
  out="$(out_of "$name")"
  ast_out="$(GRAPHIFY_OUT="$out" bash "$AST_UPDATE" "$root" 2>&1 </dev/null)"
  rc=$?
  if [ "$rc" -eq 4 ]; then
    say "$name skipped: the structure pass is locked by another refresh"
    continue
  elif [ "$rc" -ne 0 ]; then
    say "$name skipped: the structure pass failed (rc $rc): $(printf '%s' "$ast_out" | tail -n 1 | tr -c '[:print:]' '?' | cut -c1-160)"
    word_line "$name" "stopped"
    alert "$name" ast-failed
    continue
  fi
  OK_NAMES+=("$name") OK_ROOTS+=("$root")
done

# --- 4. no route: the sentence, and any waiting batch's path -----------------------------------------------------------
if [ "$STATE" != set ]; then
  for name in ${OK_NAMES[@]+"${OK_NAMES[@]}"}; do
    waiting="$(node "$GC" pending "$name" 2>/dev/null)"
    [ -z "$waiting" ] || say "$name has a waiting batch at $waiting; it is not polled while no route runs; resume it by choosing a route, or remove that directory"
  done
  case "$STATE" in none) s=none ;; *) s=default ;; esac
  say "$(node "$GC" sentence --state "$s" 2>/dev/null)"
  exit 0
fi

# --- 5. the route on each corpus ---------------------------------------------------------------------------------------
STEPS=()
run=""
for tok in $(printf '%s' "$ORDER" | tr ',' ' '); do
  if [ "$tok" = subscription ]; then
    [ -z "$run" ] || { STEPS+=("L:$run"); run=""; }
    STEPS+=("S")
  else
    run="${run:+$run,}$tok"
  fi
done
[ -z "$run" ] || STEPS+=("L:$run")

run_letters() { # name root letters rf
  GRAPHIFY_OUT="$(out_of "$1")" HIMMEL_API_LANE=on bash "$SEM_UPDATE" --name "$1" --corpus-root "$2" --backend claude-api \
    --corpus-class adopter-repo --account-order "$3" --max-run-usd "$CAP" --result-file "$4" </dev/null >>"$WORK/semantic.out" 2>&1
}

# the subscription step: its own subshell sources the pin library, so any function shadowing exit, return or unset
# exists only here; the launch sits inside the keyword gate's then arm and nothing relies on a return or an exit
run_sub() { # name root rf
  local name="$1" root="$2" rf="$3"
  (
    GRAPHIFY_OUT="$(out_of "$name")"
    export GRAPHIFY_OUT
    # shellcheck source=../lib/native-auth-pin.sh
    if ! { [ -r "$PIN" ] && . "$PIN"; } 2>/dev/null; then printf 'stopped\n' >"$rf"; exit 0; fi
    native_auth_pin_env || { printf 'stopped\n' >"$rf"; exit 0; }
    native_auth_scrub_env
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}${!LQ_API_*}" ]]; then
      bash "$SEM_UPDATE" --name "$name" --corpus-root "$root" --backend claude-cli --corpus-class adopter-repo \
        --result-file "$rf" </dev/null >>"$WORK/semantic.out" 2>&1
    else
      echo "graph-choices-pass: subscription step refused: an API credential name survived the scrub"
      printf 'stopped\n' >"$rf"
    fi
  )
}

next_letter_step() { # from-index -> prints the index of the next L step, or nothing
  local j="$1"
  while [ "$j" -lt "${#STEPS[@]}" ]; do
    case "${STEPS[$j]}" in L:*) printf '%s' "$j"; return 0 ;; esac
    j=$((j + 1))
  done
  return 0
}

END_FIRE=0
c=0
while [ "$c" -lt "${#OK_NAMES[@]}" ] && [ "$END_FIRE" -eq 0 ]; do
  name="${OK_NAMES[$c]}" root="${OK_ROOTS[$c]}"
  c=$((c + 1))
  s=0
  while [ "$s" -lt "${#STEPS[@]}" ]; do
    step="${STEPS[$s]}"
    s=$((s + 1))
    rf="$WORK/result.$name.$s"
    rm -f "$rf"
    case "$step" in
      L:*) run_letters "$name" "$root" "${step#L:}" "$rf" ;;
      S) run_sub "$name" "$root" "$rf" ;;
    esac
    word="$(head -n 1 "$rf" 2>/dev/null)"
    rej="$(sed -n '2s/^rejected //p' "$rf" 2>/dev/null | tr -cd 'A-Z,')"
    case "$word" in
      no-op | pending | merged | submitted | extracted | partial | no-route | key-rejected | bank-refused | batch-pending | fence-denied | over-cap | locked | corpus-failed | stopped) ;;
      *) word="" ;;
    esac
    more=0
    [ "$s" -lt "${#STEPS[@]}" ] && more=1
    case "$word" in
      no-op | pending | merged)
        word_line "$name" "$word"; clear_alert "$name"; break ;;
      submitted)
        word_line "$name" submitted; clear_alert "$name"
        [ -z "$rej" ] || printf 'graph-choices-pass: %s ALERT key-rejected %s\n' "$name" "$rej"
        END_FIRE=1; break ;;
      extracted)
        word_line "$name" extracted; clear_alert "$name"; END_FIRE=1; break ;;
      partial)
        word_line "$name" partial; alert "$name" partial
        [ "$step" = S ] && END_FIRE=1
        break ;;
      no-route)
        if [ "$more" -eq 1 ]; then say "$name no-route: trying the next step"; continue; fi
        word_line "$name" no-route "every account in the route is out of credit or room"
        alert "$name" no-route
        END_FIRE=1; break ;;
      key-rejected)
        j="$(next_letter_step "$s")"
        if [ -n "$j" ]; then say "$name key-rejected ${rej:-?}: the next letter step runs, never the subscription"; s="$j"; continue; fi
        word_line "$name" key-rejected "${rej:-?}"
        printf 'graph-choices-pass: %s ALERT key-rejected %s\n' "$name" "${rej:-?}"
        END_FIRE=1; break ;;
      bank-refused)
        if [ "$more" -eq 1 ]; then say "$name bank-refused: trying the next step"; continue; fi
        word_line "$name" bank-refused "the usage check did not say PROCEED, so no subscription run started"
        END_FIRE=1; break ;;
      batch-pending)
        if [ "$more" -eq 1 ]; then say "$name batch-pending: the next step polls it"; continue; fi
        word_line "$name" batch-pending
        waiting="$(node "$GC" pending "$name" 2>/dev/null)"
        [ -z "$waiting" ] || say "$name has a waiting batch at $waiting; the next fire polls it"
        break ;;
      fence-denied | over-cap | corpus-failed)
        word_line "$name" "$word"; alert "$name" "$word"; break ;;
      locked)
        word_line "$name" locked; break ;;
      *)
        word_line "$name" stopped "no valid result word or the step stopped"
        alert "$name" stopped
        END_FIRE=1; break ;;
    esac
  done
done
exit 0
