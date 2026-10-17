#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-ticket-standard-check.sh — ticket-standard-check.sh refuse/warn/park rules.
# Hermetic: every draft and queue lives in a mktemp dir; HANDOVER_DIR is never read
# because TICKET_STANDARD_QUEUE_DIR is always forced.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/ticket-standard-check.sh"
td="$(mktemp -d "${TMPDIR:-/tmp}/ticket-standard.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'chmod -R u+w "$td" 2>/dev/null; rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
has(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1: [$3] not in [$2]";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1: [$3] found in [$2]";; *) ok "$1";; esac; }

# mkdraft <file> [skip-section ...] — a complete draft minus the named sections
mkdraft(){
  local f="$1"; shift
  local s body out=""
  for s in Impact What Why Plan DoD Proof "Agent detail"; do
    case " $* " in *" $s "*) continue;; esac
    case "$s" in
      Impact) body="Anyone filing a ticket sees right away what is missing.";;
      What) body="Check a ticket draft before it is filed.";;
      Why) body="Tickets without a plan fail late.";;
      Plan) body="1. Write the checker.
2. Add the tests.";;
      DoD) body="- A draft missing a DoD is refused.";;
      Proof) body="Run the checker on a real draft: refused, then accepted.";;
      "Agent detail") body="Script lives in the himmel-ops plugin.";;
    esac
    out+="## $s"$'\n'"$body"$'\n\n'
  done
  printf '%s' "$out" >"$f"
}
qcount(){ find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
# run <type> <draft> <queue> [extra flags] -> sets rc, out
run(){
  local t="$1" d="$2" q="$3"; shift 3
  out="$(TICKET_STANDARD_QUEUE_DIR="$q" bash "$tool" --type "$t" --draft "$d" "$@" 2>&1)"; rc=$?
}

# --- Task missing DoD: refused, parked, original untouched ---
q="$td/q1"; mkdraft "$td/t1.md" DoD; before="$(cksum <"$td/t1.md")"
run Task "$td/t1.md" "$q" --sector "Planning & tracking"
check "Task missing DoD exits 1" "$rc" 1
has "names DoD" "$out" "DoD"
check "one queue file" "$(qcount "$q")" 1
has "prints queue path" "$out" "$q"
check "original unchanged" "$(cksum <"$td/t1.md")" "$before"
qf="$(find "$q" -type f | head -1)"
check "queue copy equals draft" "$(cksum <"$qf")" "$before"

# --- second refusal writes a second file ---
run Task "$td/t1.md" "$q" --sector X
check "second refusal exits 1" "$rc" 1
check "two queue files, none overwritten" "$(qcount "$q")" 2

# --- each missing section refused ---
for s in Impact What Why Plan Proof "Agent detail"; do
  q="$td/q-$s"; mkdraft "$td/d.md" "$s"
  run Task "$td/d.md" "$q" --sector X
  check "Task missing $s exits 1" "$rc" 1
  has "Task missing $s named" "$out" "$s"
done

# --- placeholder-only Proof ---
q="$td/q-ph"; mkdraft "$td/ph.md" Proof; printf '## Proof\nTBD\n' >>"$td/ph.md"
run Task "$td/ph.md" "$q" --sector X
check "placeholder Proof exits 1" "$rc" 1
has "placeholder Proof named" "$out" "Proof"

# --- complete Task passes, queue empty ---
q="$td/q-ok"; mkdraft "$td/ok.md"
run Task "$td/ok.md" "$q" --sector X
check "complete Task exits 0" "$rc" 0
check "complete Task parks nothing" "$(qcount "$q")" 0

# --- Story and Bug follow the Task rule ---
for t in Story Bug; do
  q="$td/q-$t"; run "$t" "$td/t1.md" "$q" --sector X
  check "$t missing DoD exits 1" "$rc" 1
  check "$t parked" "$(qcount "$q")" 1
done

# --- Epic and Subtask warn only ---
printf '## Impact\nSomething\n' >"$td/bare.md"
for t in Epic Subtask; do
  q="$td/q-$t"; run "$t" "$td/bare.md" "$q" --sector X
  check "$t without Plan/DoD/Proof exits 0" "$rc" 0
  has "$t warns" "$out" "warn"
  check "$t parks nothing" "$(qcount "$q")" 0
done

# --- Sector: missing warns, flag or draft line satisfies ---
q="$td/q-sec"
run Task "$td/ok.md" "$q"
check "no Sector still exits 0" "$rc" 0
has "no Sector warns" "$out" "Sector"
printf 'Sector: Planning & tracking\n' >"$td/sec.md"; cat "$td/ok.md" >>"$td/sec.md"
run Task "$td/sec.md" "$q"
check "Sector line in draft exits 0" "$rc" 0
hasnt "Sector line in draft: no Sector warning" "$out" "Sector"

# --- unusable queue dir fails loudly ---
mkdir "$td/ro"; chmod 500 "$td/ro"
run Task "$td/t1.md" "$td/ro/sub" --sector X
if [ "$(id -u)" -eq 0 ]; then ok "skip read-only dir check as root"
else [ "$rc" -ne 0 ] && ok "unusable queue dir does not exit 0 (rc=$rc)" || bad "unusable queue dir exit 0"; fi
printf 'x' >"$td/file"; run Task "$td/t1.md" "$td/file" --sector X
[ "$rc" -ne 0 ] && ok "queue path that is a file does not exit 0" || bad "queue path file exit 0"

# --- usage errors exit 2 ---
run Nope "$td/ok.md" "$td/q-u"; check "bad --type exits 2" "$rc" 2
run Task "$td/missing.md" "$td/q-u"; check "missing draft exits 2" "$rc" 2

# --- negative control: empty Proof flips 0 -> 1 ---
q="$td/q-nc"; mkdraft "$td/nc.md"
run Task "$td/nc.md" "$q" --sector X; check "control complete exits 0" "$rc" 0
mkdraft "$td/nc2.md" Proof; printf '## Proof\n\n' >>"$td/nc2.md"
run Task "$td/nc2.md" "$q" --sector X; check "control emptied Proof exits 1" "$rc" 1

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED: $fails"; exit 1; }
