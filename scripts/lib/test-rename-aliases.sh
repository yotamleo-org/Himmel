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
# restrict|permit|value|cap for env and env-prefix (the env-alias.sh function that
# resolves OLD against NEW: env_alias_restrict, env_alias_permit, alias_env,
# alias_env_cap),
# old-to-new for a marker, keep for do-not-rename. A prefix ends in '_'.
SEED='console|chief|prose|fail|V5|never
leg|worker|prose|fail|V4a|never
supervisor session|chief|prose|warn|D|never
worker session|worker|prose|warn|D|never
ticket sequence|dependency chain|prose|fail|R2|never
batch of workers|parallel wave|prose|fail|R2|never
wave|parallel wave|prose|fail|R2|never
HIMMEL_OVERNIGHT|HIMMEL_AFK|env|permit|V3|X
HIMMEL_INITIATIVE_OVERNIGHT|HIMMEL_INITIATIVE_AFK|env|value|V3|X
CADENCE_BANK_MAX_PCT|CADENCE_USAGE_MAX_PCT|env|cap|V1|X
CONSOLE_FG_OK|CHIEF_FG_OK|env|permit|V5|pending-N2892
CONSOLE_DISPATCH_OK|CHIEF_DISPATCH_OK|env|permit|V5|pending-N2892
CONSOLE_DISPATCH_DISABLE|CHIEF_DISPATCH_DISABLE|env|restrict|V5|pending-N2892
LEG_CONTEXT_HANDOFF_OK|WORKER_SESSION_CONTEXT_HANDOFF_OK|env|permit|V4a|pending-N2892
HIMMEL_LEAN_LEG|HIMMEL_LEAN_WORKER_SESSION|env|value|V4a|pending-N2892
PARKED-BANK|PARKED-USAGE|marker|old-to-new|V1|never
OVERNIGHT_|AFK_|env-prefix|value|V3|X
CADENCE_BANK_|CADENCE_USAGE_|env-prefix|value|V1|X
BANK_LIFT_|USAGE_LIFT_|env-prefix|value|V1|X
CODEX_BANK_|CODEX_USAGE_|env-prefix|value|V1|X
CLAUDEX_BANK_|CLAUDEX_USAGE_|env-prefix|value|V1|X
CR_MARKER_|REVIEW_MARKER_|env-prefix|value|V2|X
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

# --- slice V3: every old name of the overnight family names its afk successor ---
V3_ROWS='IL_OVERNIGHT_ALL|IL_AFK_ALL|identifier|old-to-new|V3|X
OVERNIGHT|AFK|identifier|old-to-new|V3|X
OVERNIGHT_DOC|AFK_DOC|identifier|old-to-new|V3|X
OVERNIGHT_LIMIT|AFK_LIMIT|identifier|old-to-new|V3|X
OVERNIGHT_PRIORITY|AFK_PRIORITY|identifier|old-to-new|V3|X
OVERNIGHT_PROJECT|AFK_PROJECT|identifier|old-to-new|V3|X
OVERNIGHT_STATUS|AFK_STATUS|identifier|old-to-new|V3|X
OVERNIGHT_STOP_DIR|AFK_STOP_DIR|identifier|old-to-new|V3|X
overnight-mode.md|afk-mode.md|identifier|old-to-new|V3|X
overnight-shift|afk-shift|identifier|old-to-new|V3|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V3 row '$old'" "$tabbed" "$got"
done <<EOF
$V3_ROWS
EOF
LEFT="$(printf '%s\n' "$ROWS" | awk -F'\t' 'toupper($2) ~ /OVERNIGHT/ && $6 != "V3" { print $2 }' | tr '\n' ' ')"
check "no overnight name left outside slice V3 ($LEFT)" "" "$LEFT"

# --- slice V1a: every old name of the lift family names its usage successor ---
V1A_ROWS='BANK_LIFT_BIN|USAGE_LIFT_BIN|identifier|old-to-new|V1|X
BANK_LIFT_FILE|USAGE_LIFT_FILE|identifier|old-to-new|V1|X
BANK_LIFT_REASON|USAGE_LIFT_REASON|identifier|old-to-new|V1|X
BANK_LIFT_STANDING|USAGE_LIFT_STANDING|identifier|old-to-new|V1|X
BANK_LIFT_STUB_OUT|USAGE_LIFT_STUB_OUT|identifier|old-to-new|V1|X
BOARD_BANK_LIFT|BOARD_USAGE_LIFT|identifier|old-to-new|V1|X
bank-lift.json|usage-lift.json|identifier|old-to-new|V1|X
bank-lift.sh|usage-lift.sh|identifier|old-to-new|V1|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V1a row '$old'" "$tabbed" "$got"
done <<EOF
$V1A_ROWS
EOF
LEFT="$(printf '%s\n' "$ROWS" | awk -F'\t' 'toupper($2) ~ /BANK[-_]LIFT/ && $6 != "V1" { print $2 }' | tr '\n' ' ')"
check "no lift name left outside slice V1 ($LEFT)" "" "$LEFT"

# --- slice V1b: every old usage env name the code reads both ways names its successor ---
V1B_ROWS='CLAUDEX_BANK_OK|CLAUDEX_USAGE_OK|env|permit|V1|X
CLAUDEX_BANK_REFUSE_PCT|CLAUDEX_USAGE_REFUSE_PCT|env|cap|V1|X
CLAUDEX_BANK_WARN_PCT|CLAUDEX_USAGE_WARN_PCT|env|cap|V1|X
BANK_CACHE_FILE|USAGE_MONITOR_CACHE_FILE|identifier|old-to-new|V1|X
BANK_SAMPLES_FILE|USAGE_MONITOR_SAMPLES_FILE|identifier|old-to-new|V1|X
BANK_STATE_FILE|USAGE_MONITOR_STATE_FILE|identifier|old-to-new|V1|X
CADENCE_BANK_CACHE|CADENCE_USAGE_CACHE|identifier|old-to-new|V1|X
CADENCE_BANK_CALLER_PID|CADENCE_USAGE_CALLER_PID|identifier|old-to-new|V1|X
CADENCE_BANK_CODEX_TIMEOUT|CADENCE_USAGE_CODEX_TIMEOUT|identifier|old-to-new|V1|X
CADENCE_BANK_LANE|CADENCE_USAGE_LANE|identifier|old-to-new|V1|X
CADENCE_BANK_LAUNCH|CADENCE_USAGE_LAUNCH|identifier|old-to-new|V1|X
CADENCE_BANK_LEDGER|CADENCE_USAGE_LEDGER|identifier|old-to-new|V1|X
CADENCE_BANK_LEG|CADENCE_USAGE_LEG|identifier|old-to-new|V1|X
CADENCE_BANK_MAX_AGE|CADENCE_USAGE_MAX_AGE|identifier|old-to-new|V1|X
CADENCE_BANK_PRODUCER|CADENCE_USAGE_PRODUCER|identifier|old-to-new|V1|X
CADENCE_BANK_SKIP_REFRESH|CADENCE_USAGE_SKIP_REFRESH|identifier|old-to-new|V1|X
CADENCE_BANK_STATUS_CMD|CADENCE_USAGE_STATUS_CMD|identifier|old-to-new|V1|X
CODEX_BANK_CACHE|CODEX_USAGE_CACHE|identifier|old-to-new|V1|X
CODEX_BANK_CACHE_TTL_SECONDS|CODEX_USAGE_CACHE_TTL_SECONDS|identifier|old-to-new|V1|X
CODEX_BANK_PROBE_CMD|CODEX_USAGE_PROBE_CMD|identifier|old-to-new|V1|X
CODEX_BANK_PROBE_TIMEOUT_MS|CODEX_USAGE_PROBE_TIMEOUT_MS|identifier|old-to-new|V1|X
CODEX_BANK_REFRESH_BACKOFF_MS|CODEX_USAGE_REFRESH_BACKOFF_MS|identifier|old-to-new|V1|X
CODEX_BANK_REFRESH_BOX_MS|CODEX_USAGE_REFRESH_BOX_MS|identifier|old-to-new|V1|X
HIMMEL_STOP_GUARD_BANK_PREFLIGHT|HIMMEL_STOP_GUARD_USAGE_PREFLIGHT|identifier|old-to-new|V1|X
IMPL_GUARD_BANK_BUDGET_SECS|IMPL_GUARD_USAGE_BUDGET_SECS|identifier|old-to-new|V1|X
IMPL_GUARD_BANK_STATUS_CMD|IMPL_GUARD_USAGE_STATUS_CMD|identifier|old-to-new|V1|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V1b row '$old'" "$tabbed" "$got"
done <<EOF
$V1B_ROWS
EOF

# --- slice V3: the old command and doc stay as stubs that point at the new file ---
ROOT="$HERE/../.."
stub() {
  local old="$1" new="$2" link
  link="($(basename "$new"))"
  check "$new exists" "yes" "$([ -f "$ROOT/$new" ] && echo yes || echo no)"
  check "$old points at $new" "yes" "$(grep -qF -- "$link" "$ROOT/$old" 2>/dev/null && echo yes || echo no)"
}
stub .claude/commands/overnight-shift.md .claude/commands/afk-shift.md
stub docs/handover/overnight-mode.md docs/handover/afk-mode.md

# --- slice V1c: the five usage scripts, each old path a forwarder to the new one ---
V1C_ROWS='bank-attribution.sh|usage-attribution.sh|identifier|old-to-new|V1|X
bank-monitor.sh|usage-monitor.sh|identifier|old-to-new|V1|X
bank-preflight.sh|usage-preflight.sh|identifier|old-to-new|V1|X
bank-status.ts|usage-status.ts|identifier|old-to-new|V1|X
codex-bank-probe.ts|codex-usage-probe.ts|identifier|old-to-new|V1|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V1c row '$old'" "$tabbed" "$got"
done <<EOF
$V1C_ROWS
EOF
# The shipped forwarder runs beside a stub of its target: argv, stdout and the
# exit code pass through, stderr is the one deprecation line.
# shellcheck source=fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/fixture-tempdir.sh"
FT=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$FT"' EXIT
forwards() {  # forwards <runner> <dir> <old> <new> <stub source>
  local runner="$1" dir="$2" old="$3" new="$4" src="$5" d out rc err
  d="$FT/$old"
  mkdir -p "$d"
  check "$dir/$new exists" "yes" "$([ -f "$ROOT/$dir/$new" ] && echo yes || echo no)"
  cp "$ROOT/$dir/$old" "$d/$old" 2>/dev/null || { check "$dir/$old exists" "yes" "no"; return; }
  [ "$old" = bank-preflight.sh ] && cp "$ROOT/scripts/lib/chokepoint-seam-guard.sh" "$d/"
  printf '%s\n' "$src" > "$d/$new"
  out="$("$runner" "$d/$old" 'a b' c 2> "$d/err")"
  rc=$?
  err="$(cat "$d/err")"
  check "$old forwards argv and stdout to $new" "NEW:a b|c" "$out"
  check "$old keeps the exit code of $new" 7 "$rc"
  check "$old prints one deprecation line" "$old is deprecated: use '$new' instead" "$err"
  [ "$runner" = bash ] || return 0
  out="$(bash -c '. "$1"; echo "rc=$?"' _ "$d/$old" 2> "$d/err")"
  check "$old refuses to be sourced and runs nothing" "rc=2" "$out"
  check "$old names the run spelling when sourced" "$old is deprecated: run '$new', do not source it" "$(cat "$d/err")"
  # shellcheck disable=SC2016 # $0 is expanded by the inner bash, not here
  out="$(bash -c '. "$0"; echo "rc=$?"' "$d/$old" 2> "$d/err")"
  check "$old refuses to be sourced as \$0 and runs nothing" "rc=2" "$out"
}
# shellcheck disable=SC2016 # the stub body is expanded by the stub, not here
SH_STUB='printf "NEW:%s|%s" "$1" "$2"; exit 7'
TS_STUB='process.stdout.write("NEW:" + process.argv.slice(2).join("|")); process.exit(7);'
forwards bash scripts/lib bank-preflight.sh usage-preflight.sh "$SH_STUB"
forwards bash scripts/lib bank-monitor.sh usage-monitor.sh "$SH_STUB"
forwards bash scripts/lib bank-attribution.sh usage-attribution.sh "$SH_STUB"
forwards bun scripts/lanes bank-status.ts usage-status.ts "$TS_STUB"
forwards bun scripts/lanes codex-bank-probe.ts codex-usage-probe.ts "$TS_STUB"

# --- slice V2a: the review marker clearer, its old path a forwarder ---
V2A_ROWS='CLEAR_CR_MARKER_BUDGET_WAIT|CLEAR_REVIEW_MARKER_BUDGET_WAIT|env|value|V2|X
clear-cr-marker.sh|clear-review-marker.sh|identifier|old-to-new|V2|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V2a row '$old'" "$tabbed" "$got"
done <<EOF
$V2A_ROWS
EOF
# The clearer forwarder hands off to the anchor and runs the seam guard before
# it forwards, so the fixture carries both beside it in the scripts/ layout.
d="$FT/v2a"
mkdir -p "$d/cr" "$d/lib"
check "scripts/cr/clear-review-marker.sh exists" "yes" "$([ -f "$ROOT/scripts/cr/clear-review-marker.sh" ] && echo yes || echo no)"
if cp "$ROOT/scripts/cr/clear-cr-marker.sh" "$ROOT/scripts/cr/anchor-handoff.sh" "$d/cr/" 2>/dev/null &&
   cp "$ROOT/scripts/lib/chokepoint-seam-guard.sh" "$d/lib/"; then
  printf '%s\n' "$SH_STUB" > "$d/cr/clear-review-marker.sh"
  out="$(cd "$d" && env -u HIMMEL_REPO bash "$d/cr/clear-cr-marker.sh" 'a b' c 2> "$d/err")"
  rc=$?
  check "clear-cr-marker.sh forwards argv and stdout to clear-review-marker.sh" "NEW:a b|c" "$out"
  check "clear-cr-marker.sh keeps the exit code of clear-review-marker.sh" 7 "$rc"
  check "clear-cr-marker.sh prints one deprecation line" \
    "clear-cr-marker.sh is deprecated: use 'clear-review-marker.sh' instead" "$(cat "$d/err")"
  check "clear-cr-marker.sh hands off to the anchor before it forwards" yes \
    "$(awk '/anchor-handoff\.sh/ { h = NR } /^exec / { e = NR } END { print (h && e && h < e) ? "yes" : "no" }' "$d/cr/clear-cr-marker.sh")"
else
  check "scripts/cr/clear-cr-marker.sh exists" "yes" "no"
fi

# --- slice V2b: the CodeRabbit and review libs, each old path a sourcing alias ---
V2B_ROWS='cr-available.sh|coderabbit-available.sh|identifier|old-to-new|V2|X
cr-body-findings.sh|coderabbit-body-findings.sh|identifier|old-to-new|V2|X
cr-default-base.sh|review-default-base.sh|identifier|old-to-new|V2|X
cr-high-risk-diff.sh|review-high-risk-diff.sh|identifier|old-to-new|V2|X
cr-ledger-evidence.sh|review-ledger-evidence.sh|identifier|old-to-new|V2|X
cr-merge-gate.sh|review-merge-gate.sh|identifier|old-to-new|V2|X
cr-signal.sh|coderabbit-signal.sh|identifier|old-to-new|V2|X
cr-trigger-ledger.sh|coderabbit-trigger-ledger.sh|identifier|old-to-new|V2|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V2b row '$old'" "$tabbed" "$got"
  new="$(printf '%s' "$want" | cut -d'|' -f2)"
  # The hooks and the frozen red-control fixtures still source the old path,
  # so it loads the new file and stays silent.
  d="$FT/v2b-$old"
  mkdir -p "$d" "$FT/v2b-cwd"
  check "scripts/lib/$new exists" "yes" "$([ -f "$ROOT/scripts/lib/$new" ] && echo yes || echo no)"
  cp "$ROOT/scripts/lib/$old" "$d/$old" 2>/dev/null || { check "scripts/lib/$old exists" "yes" "no"; continue; }
  # shellcheck disable=SC2016 # the stub body is expanded when sourced, not here
  printf 'v2b_probe() { printf "NEW:%%s" "$1"; }\nreturn 5\n' > "$d/$new"
  out="$(cd "$FT/v2b-cwd" && bash -c '. "$1"; printf "rc=%s|" "$?"; v2b_probe x' _ "$d/$old" 2> "$d/err")"
  check "$old sources $new from another cwd and keeps its status" "rc=5|NEW:x" "$out"
  check "$old prints nothing when sourced" "" "$(cat "$d/err")"
  out="$(cd "$d" && bash -c '. ./"$1"; v2b_probe y' _ "$old" 2>/dev/null)"
  check "$old sources $new from a relative path" "NEW:y" "$out"
done <<EOF
$V2B_ROWS
EOF

# --- slice V2c: the sweep gate's refusal reason, read in both spellings ---
V2C_ROWS='missing-class-sweep|missing-variant-sweep|marker|old-to-new|V2|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V2c row '$old'" "$tabbed" "$got"
done <<EOF
$V2C_ROWS
EOF
check "clear-review-marker.sh refuses with reason=missing-variant-sweep" yes \
  "$(grep -q 'REFUSED reason=missing-variant-sweep ' "$ROOT/scripts/cr/clear-review-marker.sh" && echo yes || echo no)"
for spelling in missing-class-sweep missing-variant-sweep; do
  got="$(python3 -I -c 'import re, sys
sys.path.insert(0, sys.argv[1])
import friction
print(" ".join(r[2] for r in friction.DOC_RULES if re.search(r[0], sys.argv[2])))' "$ROOT/scripts/eval/friction" "clear-cr-marker refused: $spelling" 2>&1)"
  check "friction reads $spelling as missing-variant-sweep" "missing-variant-sweep" "$got"
done

# --- slice V5a: the chief script and its context lib, /chief the canonical command ---
V5A_ROWS='console-context.sh|chief-context.sh|identifier|old-to-new|V5|X
console.sh|chief.sh|identifier|old-to-new|V5|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V5a row '$old'" "$tabbed" "$got"
done <<EOF
$V5A_ROWS
EOF
forwards bash scripts/handover/console console.sh chief.sh "$SH_STUB"
# The launchers and the arm tests still source the old lib path, so it loads
# the new file and stays silent.
d="$FT/v5a-lib"
mkdir -p "$d" "$FT/v5a-cwd"
check "scripts/lib/chief-context.sh exists" "yes" "$([ -f "$ROOT/scripts/lib/chief-context.sh" ] && echo yes || echo no)"
if cp "$ROOT/scripts/lib/console-context.sh" "$d/console-context.sh" 2>/dev/null; then
  # shellcheck disable=SC2016 # the stub body is expanded when sourced, not here
  printf 'v5a_probe() { printf "NEW:%%s" "$1"; }\nreturn 5\n' > "$d/chief-context.sh"
  out="$(cd "$FT/v5a-cwd" && bash -c '. "$1"; printf "rc=%s|" "$?"; v5a_probe x' _ "$d/console-context.sh" 2> "$d/err")"
  check "console-context.sh sources chief-context.sh from another cwd and keeps its status" "rc=5|NEW:x" "$out"
  check "console-context.sh prints nothing when sourced" "" "$(cat "$d/err")"
else
  check "scripts/lib/console-context.sh exists" "yes" "no"
fi
stub .claude/commands/supervisor-session.md .claude/commands/chief.md
stub .claude/commands/console.md .claude/commands/chief.md
stub marketplace/plugins/himmel-ops/commands/supervisor-session.md marketplace/plugins/himmel-ops/commands/chief.md
stub marketplace/plugins/himmel-ops/commands/console.md marketplace/plugins/himmel-ops/commands/chief.md
for a in supervisor-session console; do
  check ".claude/commands/$a.md runs chief.sh" "yes" "$(grep -qxF -- "bash scripts/handover/console/chief.sh \$ARGUMENTS" "$ROOT/.claude/commands/$a.md" && [ -f "$ROOT/scripts/handover/console/chief.sh" ] && echo yes || echo no)"
  check "himmel-ops $a.md runs /himmel-ops:chief" "yes" "$(grep -qF -- "\`/himmel-ops:chief \$ARGUMENTS\`" "$ROOT/marketplace/plugins/himmel-ops/commands/$a.md" && echo yes || echo no)"
done

# --- slice V5b-1: the chief launcher, waiter and budget env names, each old name still read ---
V5B1_ROWS='CONSOLE_ARM_FOREGROUND|CHIEF_ARM_FOREGROUND|identifier|old-to-new|V5|X
CONSOLE_BUCKET|CHIEF_BUCKET|identifier|old-to-new|V5|X
CONSOLE_BUS_CLI|CHIEF_BUS_CLI|identifier|old-to-new|V5|X
CONSOLE_BUS_PREDECESSOR|CHIEF_BUS_PREDECESSOR|identifier|old-to-new|V5|X
CONSOLE_BUS_PROFILES_MJS|CHIEF_BUS_PROFILES_MJS|identifier|old-to-new|V5|X
CONSOLE_CACHE_READ_BUDGET_M|CHIEF_CACHE_READ_BUDGET_M|identifier|old-to-new|V5|X
CONSOLE_CONTEXT|CHIEF_CONTEXT|identifier|old-to-new|V5|X
CONSOLE_CONTEXT_|CHIEF_CONTEXT_|identifier|old-to-new|V5|X
CONSOLE_CONTEXT_RECORD_DIR|CHIEF_CONTEXT_RECORD_DIR|identifier|old-to-new|V5|X
CONSOLE_CONTEXT_RESOLVED_MODE|CHIEF_CONTEXT_RESOLVED_MODE|identifier|old-to-new|V5|X
CONSOLE_CONTEXT_RESOLVED_SOURCE|CHIEF_CONTEXT_RESOLVED_SOURCE|identifier|old-to-new|V5|X
CONSOLE_DOC|CHIEF_DOC|identifier|old-to-new|V5|X
CONSOLE_ENV|CHIEF_ENV|identifier|old-to-new|V5|X
CONSOLE_FILL_PERCENT|CHIEF_FILL_PERCENT|identifier|old-to-new|V5|X
CONSOLE_FLAG|CHIEF_FLAG|identifier|old-to-new|V5|X
CONSOLE_HEADED_ARM|CHIEF_HEADED_ARM|identifier|old-to-new|V5|X
CONSOLE_LAUNCH_ENV|CHIEF_LAUNCH_ENV|identifier|old-to-new|V5|X
CONSOLE_MODE|CHIEF_MODE|identifier|old-to-new|V5|X
CONSOLE_MODEL|CHIEF_MODEL|identifier|old-to-new|V5|X
CONSOLE_NAME|CHIEF_NAME|identifier|old-to-new|V5|X
CONSOLE_PRECOMPACT_DOC|CHIEF_PRECOMPACT_DOC|identifier|old-to-new|V5|X
CONSOLE_PRECOMPACT_WORKDIR|CHIEF_PRECOMPACT_WORKDIR|identifier|old-to-new|V5|X
CONSOLE_TEMPLATE_DIR|CHIEF_TEMPLATE_DIR|identifier|old-to-new|V5|X
CONSOLE_TURN_BUDGET|CHIEF_TURN_BUDGET|identifier|old-to-new|V5|X
CONSOLE_WAIT|CHIEF_WAIT|identifier|old-to-new|V5|X
CONSOLE_WAIT_BANK|CHIEF_WAIT_USAGE|identifier|old-to-new|V5|X
CONSOLE_WAIT_BUDGET|CHIEF_WAIT_BUDGET|identifier|old-to-new|V5|X
CONSOLE_WAIT_BUDGET_TIMEOUT|CHIEF_WAIT_BUDGET_TIMEOUT|identifier|old-to-new|V5|X
CONSOLE_WAIT_CLOSE|CHIEF_WAIT_CLOSE|identifier|old-to-new|V5|X
CONSOLE_WAIT_CLOSE_HANGS|CHIEF_WAIT_CLOSE_HANGS|identifier|old-to-new|V5|X
CONSOLE_WAIT_CLOSE_TIMEOUT|CHIEF_WAIT_CLOSE_TIMEOUT|identifier|old-to-new|V5|X
CONSOLE_WAIT_DISPATCH|CHIEF_WAIT_DISPATCH|identifier|old-to-new|V5|X
CONSOLE_WAIT_DISPATCH_TIMEOUT|CHIEF_WAIT_DISPATCH_TIMEOUT|identifier|old-to-new|V5|X
CONSOLE_WAIT_FAIL_WAKE|CHIEF_WAIT_FAIL_WAKE|identifier|old-to-new|V5|X
CONSOLE_WAIT_HANDOVER_MIN|CHIEF_WAIT_HANDOVER_MIN|identifier|old-to-new|V5|X
CONSOLE_WAIT_INTERVAL|CHIEF_WAIT_INTERVAL|identifier|old-to-new|V5|X
CONSOLE_WAIT_LEG_EVENT|CHIEF_WAIT_WORKER_EVENT|identifier|old-to-new|V5|X
CONSOLE_WAIT_LOCK_STATUS|CHIEF_WAIT_LOCK_STATUS|identifier|old-to-new|V5|X
CONSOLE_WAIT_PAGE_CMD|CHIEF_WAIT_PAGE_CMD|identifier|old-to-new|V5|X
CONSOLE_WAIT_PAGE_TIMEOUT|CHIEF_WAIT_PAGE_TIMEOUT|identifier|old-to-new|V5|X
CONSOLE_WAIT_POLL_SEC|CHIEF_WAIT_POLL_SEC|identifier|old-to-new|V5|X
CONSOLE_WAIT_RELAY|CHIEF_WAIT_RELAY|identifier|old-to-new|V5|X
CONSOLE_WAIT_SUCCESSION_SEC|CHIEF_WAIT_SUCCESSION_SEC|identifier|old-to-new|V5|X
CONSOLE_WAIT_TICK|CHIEF_WAIT_TICK|identifier|old-to-new|V5|X
CONSOLE_WAIT_TICK_TIMEOUT|CHIEF_WAIT_TICK_TIMEOUT|identifier|old-to-new|V5|X
CONSOLE_WAIT_TRACKER|CHIEF_WAIT_TRACKER|identifier|old-to-new|V5|X
CONSOLE_WAIT_TRACKER_STALE_MIN|CHIEF_WAIT_TRACKER_STALE_MIN|identifier|old-to-new|V5|X
CONSOLE_WAIT_UNOWNED_REWAKE_MIN|CHIEF_WAIT_UNOWNED_REWAKE_MIN|identifier|old-to-new|V5|X
CONSOLE_WORK_DIR|CHIEF_WORK_DIR|identifier|old-to-new|V5|X'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V5b-1 row '$old'" "$tabbed" "$got"
done <<EOF
$V5B1_ROWS
EOF

# --- slice V5b-2: the hook-side env names and test locals, each old env name still read;
# three retired or foreign names are kept ---
V5B2_ROWS='CONSOLE_DISPATCH_LOG|CHIEF_DISPATCH_LOG|identifier|old-to-new|V5|X
CONSOLE_DISPATCH_TRANSCRIPT_HEAD_LINES|CHIEF_DISPATCH_TRANSCRIPT_HEAD_LINES|identifier|old-to-new|V5|X
CONSOLE_FG_LIST|CHIEF_FG_LIST|identifier|old-to-new|V5|X
CONSOLE_KIT_FIXTURE|CONSOLE_KIT_FIXTURE|identifier|keep|none|never
CONSOLE_PAYLOAD|CHIEF_PAYLOAD|identifier|old-to-new|V5|X
CONSOLE_PAYLOAD_ACTIVE|CHIEF_PAYLOAD_ACTIVE|identifier|old-to-new|V5|X
CONSOLE_ROLE|CONSOLE_ROLE|identifier|keep|none|never
CONSOLE_SESSION_NAME|CHIEF_SESSION_NAME|identifier|old-to-new|V5|X
CONSOLE_TRANSCRIPT|CHIEF_TRANSCRIPT|identifier|old-to-new|V5|X
CONSOLE_VERB|CONSOLE_VERB|identifier|keep|none|never'
while IFS= read -r want; do
  tabbed="$(printf '%s' "$want" | tr '|' '\t')"
  old="${want%%|*}"
  got="$(printf '%s\n' "$ROWS" | awk -F'\t' -v o="$old" '$2 == o { sub(/^[0-9]+\t/, ""); print; exit }')"
  check "V5b-2 row '$old'" "$tabbed" "$got"
done <<EOF
$V5B2_ROWS
EOF

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
