#!/usr/bin/env bash
# scripts/lib/test-rename-aliases.sh -- shape and seed rows of
# scripts/lib/rename-aliases.tsv: six TAB columns under
# the header, closed vocabularies, unique old names, an exact name never below
# a prefix that would swallow it, env names that env-alias.sh accepts, the
# HIMMEL_WORKER do-not-rename trap, and the ruled-term seed rows.
#
# RENAME_ALIASES_TSV points the rows at another copy, so a mutant (a seed row
# dropped, a column lost) can be shown to turn a row red.
#
# Platform guard (gitbash-only): pure bash/awk, no .ps1 twin needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="${RENAME_ALIASES_TSV:-$HERE/rename-aliases.tsv}"

FAIL=0
PASS=0
check() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label -- want '$want' got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

# rows: the data rows (comments and the header dropped), tab-separated
DATA=$(grep -v '^#' "$TSV" | grep -v '^$' | tail -n +2)
HEADER=$(grep -v '^#' "$TSV" | grep -v '^$' | head -n 1)

check "header" $'old\tnew\tkind\tdirection\tslice\tremove-at' "$HEADER"
check "rows were read (not vacuous)" "yes" "$([ "$(printf '%s\n' "$DATA" | wc -l)" -ge 25 ] && echo yes || echo no)"

bad=$(printf '%s\n' "$DATA" | awk -F'\t' 'NF != 6 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "" {print NR": "$0}')
check "every row has six non-empty columns" "" "$bad"

bad=$(printf '%s\n' "$DATA" | awk -F'\t' '$3 !~ /^(prose|env|env-prefix|marker|do-not-rename)$/ {print $1" kind="$3}')
check "kind is in the vocabulary" "" "$bad"

bad=$(printf '%s\n' "$DATA" | awk -F'\t' '
  ($3 == "env" || $3 == "env-prefix") && $4 !~ /^(restrict|permit|value)$/ {print $1" direction="$4}
  $3 == "prose" && $4 !~ /^(warn|fail)$/ {print $1" direction="$4}
  ($3 == "marker" || $3 == "do-not-rename") && $4 != "-" {print $1" direction="$4}')
check "direction fits the kind" "" "$bad"

bad=$(printf '%s\n' "$DATA" | awk -F'\t' '$5 !~ /^(-|R2|V1|V2|V3|V4a|V4b|V5|D|T)$/ {print $1" slice="$5} $6 !~ /^(X|never)$/ {print $1" remove-at="$6}')
check "slice and remove-at are in the vocabulary" "" "$bad"

check "old names are unique" "" "$(printf '%s\n' "$DATA" | cut -f1 | sort | uniq -d)"

# env names: every env row names are valid env-alias.sh names (a prefix drops its trailing *)
bad=$(printf '%s\n' "$DATA" | awk -F'\t' '
  $3 == "env" && ($1 !~ /^[A-Z_][A-Z0-9_]*$/ || $2 !~ /^[A-Z_][A-Z0-9_]*$/) {print $1" -> "$2}
  $3 == "env-prefix" && ($1 !~ /^[A-Z_][A-Z0-9_]*\*$/ || $2 !~ /^[A-Z_][A-Z0-9_]*\*$/) {print $1" -> "$2}')
check "env and env-prefix names are well formed" "" "$bad"

# first match wins: an exact env name must come before any earlier prefix that matches it
bad=$(printf '%s\n' "$DATA" | awk -F'\t' '
  { old[NR] = $1; kind[NR] = $3 }
  END {
    for (i = 1; i <= NR; i++) {
      if (kind[i] != "env-prefix" && kind[i] != "do-not-rename") continue
      p = old[i]; if (p !~ /\*$/) continue
      sub(/\*$/, "", p)
      for (j = i + 1; j <= NR; j++)
        if (kind[j] != "prose" && index(old[j], p) == 1) print old[j]" is below "old[i]
    }
  }')
check "no exact name sits below a prefix that swallows it" "" "$bad"

# HIMMEL_WORKER is a live security marker; no worker-session name may start with HIMMEL_WORKER_ unless SESSION_ follows
bad=$(printf '%s\n' "$DATA" | awk -F'\t' '$2 ~ /^HIMMEL_WORKER_/ && $2 !~ /^HIMMEL_WORKER_SESSION_/ {print $1" -> "$2}')
check "no new name starts with HIMMEL_WORKER_ without SESSION_" "" "$bad"
check "HIMMEL_WORKER is do-not-rename, never removed" $'HIMMEL_WORKER\t-\tdo-not-rename\t-\t-\tnever' \
  "$(printf '%s\n' "$DATA" | grep -F -x -e $'HIMMEL_WORKER\t-\tdo-not-rename\t-\t-\tnever' || true)"
check "HIMMEL_CONSOLE_* is do-not-rename (OD-1)" $'HIMMEL_CONSOLE_*\t-\tdo-not-rename\t-\t-\tnever' \
  "$(printf '%s\n' "$DATA" | grep -F -x -e $'HIMMEL_CONSOLE_*\t-\tdo-not-rename\t-\t-\tnever' || true)"

# the ruled-term seed rows (operator 2026-10-20), by old, new, kind
seed() {  # seed <old> <new> <kind> <direction>
  check "seed row: $1" "$1	$2	$3	$4" \
    "$(printf '%s\n' "$DATA" | awk -F'\t' -v o="$1" '$1 == o {print $1"\t"$2"\t"$3"\t"$4}')"
}
seed "console" "chief" "prose" "fail"
seed "leg" "worker" "prose" "fail"
seed "supervisor session" "chief" "prose" "warn"
seed "worker session" "worker" "prose" "warn"
seed "ticket sequence" "dependency chain" "prose" "fail"
seed "batch of workers" "parallel wave" "prose" "fail"
seed "wave" "parallel wave" "prose" "fail"
seed "CONSOLE_FG_OK" "CHIEF_FG_OK" "env" "permit"
seed "CADENCE_BANK_MAX_PCT" "CADENCE_USAGE_MAX_PCT" "env" "permit"
seed "HIMMEL_OVERNIGHT" "HIMMEL_AFK" "env" "permit"
seed "PARKED-BANK" "PARKED-USAGE" "marker" "-"
for fam in CADENCE_BANK_ BANK_LIFT_ CODEX_BANK_ CLAUDEX_BANK_ OVERNIGHT_ CR_MARKER CONSOLE_ HIMMEL_LEG_ HEADED_ARM_LEG_ LEG_; do
  check "env prefix row for $fam*" "1" \
    "$(printf '%s\n' "$DATA" | awk -F'\t' -v o="${fam}*" '$1 == o && $3 == "env-prefix" {n++} END {print n + 0}')"
done

if [ "$FAIL" -ne 0 ]; then
  echo "test-rename-aliases: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-rename-aliases: $PASS passed"
