#!/usr/bin/env bash
# scripts/lib/test-rename-aliases.sh -- shape test for the R1 seed rows in
# scripts/lib/rename-aliases.tsv: every seed row is present, byte for byte, in
# the registry's own vocabulary; no old name is listed twice; an exact name sits
# above the prefix that would swallow it (first match wins); HIMMEL_WORKER
# stays do-not-rename.
#
# RENAME_ALIASES_FILE points the rows at another copy of the registry, so a
# mutant (the HIMMEL_WORKER row deleted) can be shown to turn a row red.
#
# Platform guard (gitbash-only): pure awk and bash 3.2-safe, no .ps1 twin needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="${RENAME_ALIASES_FILE:-$HERE/rename-aliases.tsv}"
[ -f "$REG" ] || { echo "FAIL: registry missing: $REG" >&2; exit 1; }

# The R1 seed rows, '|' separated: old|new|kind|direction|slice|remove-at.
# kind prose|env|env-prefix|marker|do-not-rename; direction warn|fail for prose,
# restrict|permit|value for env and env-prefix (the env-alias.sh function that
# resolves OLD against NEW: env_alias_restrict, env_alias_permit, alias_env),
# old-to-new for a marker, keep for do-not-rename. A prefix ends in '_'.
SEED='console|chief|prose|fail|V5|never
leg|worker|prose|fail|V4a|never
supervisor session|chief|prose|warn|D|never
worker session|worker|prose|warn|D|never
ticket sequence|dependency chain|prose|fail|R2|never
batch of workers|parallel wave|prose|fail|R2|never
wave|parallel wave|prose|fail|R2|never
HIMMEL_OVERNIGHT|HIMMEL_AFK|env|permit|V3|pending-N2892
HIMMEL_INITIATIVE_OVERNIGHT|HIMMEL_INITIATIVE_AFK|env|value|V3|pending-N2892
CADENCE_BANK_MAX_PCT|CADENCE_USAGE_MAX_PCT|env|permit|V1|pending-N2892
CONSOLE_FG_OK|CHIEF_FG_OK|env|permit|V5|pending-N2892
CONSOLE_DISPATCH_OK|CHIEF_DISPATCH_OK|env|permit|V5|pending-N2892
CONSOLE_DISPATCH_DISABLE|CHIEF_DISPATCH_DISABLE|env|restrict|V5|pending-N2892
LEG_CONTEXT_HANDOFF_OK|WORKER_SESSION_CONTEXT_HANDOFF_OK|env|permit|V4a|pending-N2892
HIMMEL_LEAN_LEG|HIMMEL_LEAN_WORKER_SESSION|env|value|V4a|pending-N2892
PARKED-BANK|PARKED-USAGE|marker|old-to-new|V1|never
OVERNIGHT_|AFK_|env-prefix|value|V3|pending-N2892
CADENCE_BANK_|CADENCE_USAGE_|env-prefix|value|V1|pending-N2892
BANK_LIFT_|USAGE_LIFT_|env-prefix|value|V1|pending-N2892
CODEX_BANK_|CODEX_USAGE_|env-prefix|value|V1|pending-N2892
CLAUDEX_BANK_|CLAUDEX_USAGE_|env-prefix|value|V1|pending-N2892
CR_MARKER_|REVIEW_MARKER_|env-prefix|value|V2|pending-N2892
CONSOLE_|CHIEF_|env-prefix|value|V5|pending-N2892
HIMMEL_LEG_|HIMMEL_WORKER_SESSION_|env-prefix|value|V4a|pending-N2892
HEADED_ARM_LEG_|HEADED_ARM_WORKER_|env-prefix|value|V4a|pending-N2892
LEG_|WORKER_SESSION_|env-prefix|value|V4a|pending-N2892
HIMMEL_WORKER|HIMMEL_WORKER|do-not-rename|keep|none|never
HIMMEL_CONSOLE_|HIMMEL_CONSOLE_|do-not-rename|keep|none|never'

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

# rows: the registry's data lines (no comment, blank line or header) with their line number.
ROWS="$(awk -F'\t' '/^[[:space:]]*(#|$)/ || $1 == "old" { next } { print NR "\t" $0 }' "$REG")"

# --- every row has six columns ---
BAD="$(printf '%s\n' "$ROWS" | awk -F'\t' 'NF != 7 { print $1 }' | tr '\n' ' ')"
check "every row has six columns (bad lines: $BAD)" "" "$BAD"

# --- no old name twice: first match wins, a second row is dead ---
DUP="$(printf '%s\n' "$ROWS" | awk -F'\t' '{ n[$2]++ } END { for (k in n) if (n[k] > 1) print k }' | sort | tr '\n' ' ')"
check "no old name listed twice ($DUP)" "" "$DUP"

# --- each seed row is present, byte for byte ---
n=0
while IFS= read -r want; do
  n=$((n + 1))
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "seed row '$old'" "$tabbed" "$got"
done <<EOF
$SEED
EOF
check "seed table was read (not vacuous)" "yes" "$([ "$n" -ge 28 ] && echo yes || echo no)"

# --- an exact seed name sits above every prefix row that would swallow it ---
ORDER="$(printf '%s\n' "$ROWS" | awk -F'\t' '
  { line[NR] = $1; old[NR] = $2; kind[NR] = $4; n = NR }
  END {
    for (p = 1; p <= n; p++) {
      if (kind[p] != "env-prefix" && kind[p] != "do-not-rename") continue
      if (old[p] !~ /_$/) continue
      for (e = p + 1; e <= n; e++) {
        if (kind[e] != "env" && kind[e] != "marker" && kind[e] != "do-not-rename") continue
        if (old[e] ~ /_$/) continue
        if (index(old[e], old[p]) == 1) print old[e] " below " old[p]
      }
    }
  }' | tr '\n' ' ')"
check "exact names above the prefixes that swallow them ($ORDER)" "" "$ORDER"

# --- the dispatched-lane security marker prefix stays out of the rename ---
check "HIMMEL_WORKER is do-not-rename" "do-not-rename keep" "$(awk -F'\t' '$1 == "HIMMEL_WORKER" { print $3 " " $4 }' "$REG")"
check "HIMMEL_CONSOLE_ is do-not-rename" "do-not-rename keep" "$(awk -F'\t' '$1 == "HIMMEL_CONSOLE_" { print $3 " " $4 }' "$REG")"

if [ "$FAIL" -ne 0 ]; then
  echo "test-rename-aliases: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-rename-aliases: $PASS passed"
