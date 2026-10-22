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

# These rows catch a rewrite that loses facts or bypasses the ticket shape check.
# shellcheck disable=SC2016 # Backticks in Markdown fixtures are literal data.
humanizer_rows(){
  local facts="$here/humanizer-facts.py" original="$td/original.md" rewrite="$td/rewrite.md"
  printf 'HIMMEL-6967 checks 42 rows in scripts/check.sh using `bash scripts/check.sh --count 42`.\n' >"$original"
  printf 'Using `bash scripts/check.sh --count 42`, scripts/check.sh checks 42 rows for HIMMEL-6967.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
  check "faithful rewrite passes" "$rc" 0
  for pair in 'HIMMEL-6967 HIMMEL-6968' '42 43' 'scripts/check.sh scripts/other.sh' '--count --total'; do
    from="${pair% *}"; to="${pair#* }"
    sed "s|$from|$to|g" "$original" >"$rewrite"
    out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
    check "changed fact $from refused" "$rc" 1
  done
  printf '\n```bash\nbash scripts/check.sh --count 42\n```\n' >>"$original"
  cp "$original" "$rewrite"
  out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
  check "unchanged fenced command passes" "$rc" 0
  sed 's/bash scripts\/check.sh/sh scripts\/check.sh/g' "$original" >"$rewrite"
  out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
  check "changed fenced command refused" "$rc" 1
  for removed in HIMMEL-6967 42; do
    sed "s/$removed//g" "$original" >"$rewrite"
    out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
    check "dropped $removed refused" "$rc" 1
  done
  printf 'Read .env before filing.\n' >"$td/dotfile.md"
  printf 'Read .other before filing.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/dotfile.md" "$rewrite" 2>&1)"; rc=$?
  check "changed bare dotfile refused" "$rc" 1
  printf 'bash scripts/check.sh --count 42\n' >"$td/command.md"
  printf 'bash scripts/check.sh --total 42\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/command.md" "$rewrite" 2>&1)"; rc=$?
  check "changed bare command refused" "$rc" 1
  printf 'HIMMEL-6967 took 42 seconds.\n' >"$td/number.md"
  printf 'HIMMEL-6967 took 142 seconds.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/number.md" "$rewrite" 2>&1)"; rc=$?
  check "number substring is not preservation" "$rc" 1
  printf 'Use v1.2 before filing.\n' >"$td/version.md"
  printf 'Use v9.2 before filing.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/version.md" "$rewrite" 2>&1)"; rc=$?
  check "changed prefixed version refused" "$rc" 1
  printf 'Before filing, use v1.2.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/version.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful prefixed version passes" "$rc" 0
  printf 'Read scripts/check before filing.\n' >"$td/path.md"
  printf 'Read scripts/other before filing.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/path.md" "$rewrite" 2>&1)"; rc=$?
  check "changed extensionless path refused" "$rc" 1
  printf 'Before filing, read scripts/check.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/path.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful extensionless path passes" "$rc" 0
  printf 'Use 1e3 rows before filing.\n' >"$td/exponent.md"
  printf 'Use 2e3 rows before filing.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/exponent.md" "$rewrite" 2>&1)"; rc=$?
  check "changed exponent number refused" "$rc" 1
  printf 'Before filing, use 1e3 rows.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/exponent.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful exponent number passes" "$rc" 0
  printf 'Before filing, read .env.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/dotfile.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful sentence-final dotfile passes" "$rc" 0
  printf 'Before filing, read .other.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/dotfile.md" "$rewrite" 2>&1)"; rc=$?
  check "changed sentence-final dotfile refused" "$rc" 1
  : >"$rewrite"
  out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
  check "empty rewrite refused" "$rc" 1
  printf 'Run ``echo `pwd` `` before filing.\n' >"$td/nested.md"
  printf 'Run ``echo `whoami` `` before filing.\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/nested.md" "$rewrite" 2>&1)"; rc=$?
  check "changed nested-backtick command refused" "$rc" 1
  cp "$td/nested.md" "$rewrite"
  out="$(python3 -I "$facts" "$td/nested.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful nested-backtick command passes" "$rc" 0
  printf '    cd staging\n    pwd\n' >"$td/indented.md"
  printf '    pwd\n    cd staging\n' >"$rewrite"
  out="$(python3 -I "$facts" "$td/indented.md" "$rewrite" 2>&1)"; rc=$?
  check "reordered indented commands refused" "$rc" 1
  cp "$td/indented.md" "$rewrite"
  out="$(python3 -I "$facts" "$td/indented.md" "$rewrite" 2>&1)"; rc=$?
  check "faithful indented block passes" "$rc" 0
  mkdraft "$td/ticket-original.md"
  printf 'HIMMEL-6967 covers 42 rows.\n' >>"$td/ticket-original.md"
  sed 's/42/43/' "$td/ticket-original.md" >"$rewrite"
  run Task "$td/ticket-original.md" "$td/q-humanizer" --sector X --rewrite "$rewrite"
  check "unsafe rewrite never blocks original ticket" "$rc" 0
  has "unsafe rewrite reported" "$out" "rewrite refused"
  sed 's/Tickets without a plan fail late./Without a plan, tickets fail late./' "$td/ticket-original.md" >"$rewrite"
  run Task "$td/ticket-original.md" "$td/q-humanizer" --sector X --rewrite "$rewrite"
  check "faithful ticket rewrite accepted" "$rc" 0
  has "chosen ticket body identified" "$out" "humanizer: accepted"
  run Task "$td/ticket-original.md" "$td/q-humanizer" --sector X
  check "skip never blocks ticket" "$rc" 0
  has "ticket offers deterministic pass" "$out" "deterministic"
  hasnt "ticket does not offer a model rewrite" "$out" "/humanizer"
  run Task "$td/ticket-original.md" "$td/q-humanizer" --sector X --rewrite "$td/absent.md"
  check "missing rewrite never blocks original" "$rc" 0
  mkdraft "$rewrite" Proof
  printf 'HIMMEL-6967 covers 42 rows.\n' >>"$rewrite"
  run Task "$td/ticket-original.md" "$td/q-humanizer" --sector X --rewrite "$rewrite"
  check "accepted facts cannot bypass missing Proof" "$rc" 1

  cat >"$original" <<'NORMALIZE'
**Proof** — HIMMEL-6967 checks 42 rows in scripts/check.sh.
- `check` – “Ready” and ‘done’.
Additionally — review the robust result.
NORMALIZE
  printf '**Proof:** HIMMEL-6967 checks 42 rows in scripts/check.sh.\n- `check`: "Ready" and '\''done'\''.\nAdditionally, review the robust result.\n' >"$td/expected.md"
  before="$(cksum <"$original")"
  out="$(python3 -I "$facts" --normalize "$original" "$rewrite" 2>&1)"; rc=$?
  check "deterministic normalization succeeds" "$rc" 0
  check "normalization changes only the specified punctuation" "$(cat "$rewrite")" "$(cat "$td/expected.md")"
  check "normalization leaves original untouched" "$(cksum <"$original")" "$before"
  has "banned words are advisory flags" "$out" "word flags (advisory only): additionally, robust"
  out="$(python3 -I "$facts" "$original" "$rewrite" 2>&1)"; rc=$?
  check "normalized candidate passes independent fact check" "$rc" 0
  out="$(python3 -I "$facts" --normalize "$rewrite" "$td/again.md" 2>&1)"; rc=$?
  check "normalization is repeatable" "$rc" 0
  check "normalization is idempotent" "$(cat "$td/again.md" 2>/dev/null)" "$(cat "$rewrite")"
  out="$(python3 -I "$facts" --normalize "$original" "$original" 2>&1)"; rc=$?
  check "normalization refuses in-place output" "$rc" 2
  check "in-place refusal preserves original" "$(cksum <"$original")" "$before"
  printf 'Run `printf “do not change”` before filing.\n' >"$td/protected.md"
  out="$(python3 -I "$facts" --normalize "$td/protected.md" "$td/protected-out.md" 2>&1)"; rc=$?
  check "normalization refuses changed protected code" "$rc" 1
  check "unsafe normalization writes no candidate" "$([ -e "$td/protected-out.md" ] && printf yes || printf no)" no
}

if [ "${1:-}" = --humanizer-only ]; then
  humanizer_rows
  [ "$fails" -eq 0 ] && { echo PASS; exit 0; }
  echo "FAILED: $fails"; exit 1
fi
humanizer_rows

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

# --- empty Proof followed by an unrelated heading must not borrow its lines ---
q="$td/q-notes"; mkdraft "$td/notes.md" Proof "Agent detail"
printf '## Proof\n\n## Notes\nsome unrelated line\n\n## Agent detail\nfiles\n' >>"$td/notes.md"
run Task "$td/notes.md" "$q" --sector X
check "empty Proof before ## Notes exits 1" "$rc" 1
has "empty Proof before ## Notes named" "$out" "Proof"

# --- bold heading ends a section; bold-wrapped placeholder is not content ---
q="$td/q-bold"; mkdraft "$td/bold.md" Proof "Agent detail"
printf '## Proof\n\n**Notes**\nsome unrelated line\n\n## Agent detail\nfiles\n' >>"$td/bold.md"
run Task "$td/bold.md" "$q" --sector X
check "empty Proof before **Notes** exits 1" "$rc" 1
q="$td/q-boldph"; mkdraft "$td/boldph.md" Proof; printf '## Proof\n**TBD**\n' >>"$td/boldph.md"
run Task "$td/boldph.md" "$q" --sector X
check "bold-wrapped TBD Proof exits 1" "$rc" 1

# --- indented heading ends a section; closing hashes still name the section ---
q="$td/q-indent"; mkdraft "$td/indent.md" Proof "Agent detail"
printf '## Proof\n\n  ## Notes\nsome unrelated line\n\n## Agent detail\nfiles\n' >>"$td/indent.md"
run Task "$td/indent.md" "$q" --sector X
check "empty Proof before indented heading exits 1" "$rc" 1
q="$td/q-closing"; mkdraft "$td/closing.md" Proof; printf '## Proof ##\nRun it on a real draft.\n' >>"$td/closing.md"
run Task "$td/closing.md" "$q" --sector X
check "heading with closing hashes exits 0" "$rc" 0

# --- a failing awk fails closed, never reports success ---
mkdir "$td/fakebin"; printf '#!/bin/sh\nexit 3\n' >"$td/fakebin/awk"; chmod +x "$td/fakebin/awk"
mkdraft "$td/awk.md" Proof
out="$(PATH="$td/fakebin:$PATH" TICKET_STANDARD_QUEUE_DIR="$td/q-awk" bash "$tool" --type Task --draft "$td/awk.md" --sector X 2>&1)"; rc=$?
check "failing awk exits 2" "$rc" 2

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

# --- code inside a section: heading-shaped lines in a fence or indented code are content ---
q="$td/q-fence"; fn=$'\x60\x60\x60'
mkdraft "$td/f1.md" Proof "Agent detail"; printf '## Proof\n%sbash\n# run the checker\nbash tool.sh --type Task\n%s\n\n## Agent detail\nx\n' "$fn" "$fn" >>"$td/f1.md"
run Task "$td/f1.md" "$q" --sector X; check "fenced Proof with # comment exits 0" "$rc" 0
mkdraft "$td/f2.md" Proof "Agent detail"; printf '## Proof\n\n    # run the checker\n    bash tool.sh --type Task\n\n## Agent detail\nx\n' >>"$td/f2.md"
run Task "$td/f2.md" "$q" --sector X; check "indented-code Proof with # comment exits 0" "$rc" 0
mkdraft "$td/f3.md" Proof "Agent detail"; printf '## Proof\n~~~\n## Plan\nbash tool.sh\n~~~\n\n## Agent detail\nx\n' >>"$td/f3.md"
run Task "$td/f3.md" "$q" --sector X; check "~~~ fence with ## heading line exits 0" "$rc" 0
mkdraft "$td/f4.md" Proof; printf '## Proof\n%s\n%s\n' "$fn" "$fn" >>"$td/f4.md"
run Task "$td/f4.md" "$q" --sector X; check "empty fence pair Proof exits 1" "$rc" 1
mkdraft "$td/f7.md" Proof "Agent detail"; printf '## Proof\n%s\n~~~\n# note\n## Plan\nbash tool.sh\n%s\n\n## Agent detail\nx\n' "$fn" "$fn" >>"$td/f7.md"
run Task "$td/f7.md" "$q" --sector X; check "~~~ inside a backtick fence does not close it" "$rc" 0
mkdraft "$td/f9.md" Plan Proof; printf '## Proof\n    %s\n    cmd\n\n## Plan\n1. step\n' "$fn" >>"$td/f9.md"
run Task "$td/f9.md" "$q" --sector X; check "indented fence-looking line opens no fence" "$rc" 0
mkdraft "$td/f8.md" Proof "Agent detail"; bt="${fn%??}"; printf '## Proof\n%s%s\n%s\n# note\n## Plan\nbash tool.sh\n%s%s\n\n## Agent detail\nx\n' "$fn" "$bt" "$fn" "$fn" "$bt" >>"$td/f8.md"
run Task "$td/f8.md" "$q" --sector X; check "triple fence inside a four-backtick fence does not close it" "$rc" 0
mkdraft "$td/f5.md" Proof "Agent detail"; printf '## Proof\n\n## Agent detail\nx\n' >>"$td/f5.md"
run Task "$td/f5.md" "$q" --sector X; check "heading-only Proof exits 1" "$rc" 1
mkdraft "$td/f6.md" Plan Proof; printf '## Proof\n%s\ncmd\n%s\n## Plan\n\n' "$fn" "$fn" >>"$td/f6.md"
run Task "$td/f6.md" "$q" --sector X; check "empty Plan after fence still ends Proof, exits 1" "$rc" 1
has "empty Plan named" "$out" "Plan"

# --- stability metric rule: a CI/guard/stability ticket names the scorecard metric it moves ---
q="$td/q-metric"
mkdraft "$td/m1.md"; printf 'Labels: audit-6022, ci-red\n' >>"$td/m1.md"
run Task "$td/m1.md" "$q" --sector X
check "CI-labelled draft with no Metric exits 1" "$rc" 1
has "names Metric" "$out" "Metric"
check "metric-less draft is parked" "$(qcount "$q")" 1
mkdraft "$td/m2.md"; printf 'Labels: Guard\nMetric: TBD\n' >>"$td/m2.md"
run Task "$td/m2.md" "$q" --sector X; check "placeholder Metric exits 1" "$rc" 1
mkdraft "$td/m3.md"; printf 'Labels: stability\nMetric: red_main_count falls from 2 to 0\n' >>"$td/m3.md"
run Task "$td/m3.md" "$q" --sector X; check "named Metric exits 0" "$rc" 0
mkdraft "$td/m4.md"; printf 'Labels: operator-directed, theme-ship-loop-gates\n' >>"$td/m4.md"
run Task "$td/m4.md" "$q" --sector X; check "unrelated labels need no Metric" "$rc" 0
mkdraft "$td/m5.md"; printf 'Labels: ci\n' >>"$td/m5.md"
run Epic "$td/m5.md" "$q" --sector X; check "Epic without Metric only warns" "$rc" 0
has "Epic warns about Metric" "$out" "Metric"
mkdraft "$td/m6.md"; printf 'Labels: guardrail\n' >>"$td/m6.md"
run Task "$td/m6.md" "$q" --sector X; check "guardrail label without Metric exits 1" "$rc" 1
mkdraft "$td/m7.md"; printf 'Labels: guardrail\n**Metric:** red_main_count falls\n' >>"$td/m7.md"
run Task "$td/m7.md" "$q" --sector X; check "bold **Metric:** is accepted" "$rc" 0
mkdraft "$td/m8.md"; printf 'Labels: ci\n- Metric: queue_wait_p90 falls\n' >>"$td/m8.md"
run Task "$td/m8.md" "$q" --sector X; check "bulleted - Metric: is accepted" "$rc" 0
mkdraft "$td/m9.md"; printf 'Labels: ci\nMETRIC: queue_wait_p90 falls\n' >>"$td/m9.md"
run Task "$td/m9.md" "$q" --sector X; check "upper-case METRIC: is accepted" "$rc" 0
mkdraft "$td/m10.md"; printf 'Labels: ci\n- **metric:** TBD\n' >>"$td/m10.md"
run Task "$td/m10.md" "$q" --sector X; check "bulleted bold placeholder Metric exits 1" "$rc" 1

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED: $fails"; exit 1; }
