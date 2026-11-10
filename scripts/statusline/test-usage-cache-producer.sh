#!/usr/bin/env bash
# Test for scripts/statusline/usage-cache-producer.sh.
#
# The producer runs once per statusline render. It reads the Claude Code
# statusline stdin JSON and maintains TWO single-writer files:
#   A. consumer cache  (CLAUDE_USAGE_CACHE)  — himmel schema for cap-guards.
#   B. hud snapshot    (HUD_USAGE_SNAPSHOT)  — claude-hud externalUsagePath.
#
# Self-contained: every case builds its own temp HOME + output paths via env,
# so it NEVER touches the real ~/.claude or /tmp/claude cache. Cleans up on exit.
# Usage: bash scripts/statusline/test-usage-cache-producer.sh
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # PRODUCER/mtime used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # helper fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

STATUSLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCER="$STATUSLINE_DIR/usage-cache-producer.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test"; exit 1; }

# All per-case mktemp -d workdirs land under one suite TMPDIR, swept on exit
# (CR codex-2: the per-case dirs were never removed).
SUITE_TMP=$(mktemp -d)
export TMPDIR="$SUITE_TMP"
trap 'rm -rf "$SUITE_TMP"' EXIT

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0
  ( eval "$body" ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# mtime helper (GNU stat then BSD stat) — mirrors statusline.sh idiom.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# --- cases --------------------------------------------------------------------

run_test "(1) stdin WITH rate_limits -> consumer cache mirrors five_hour/seven_day" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"2026-07-06T18:00:00Z\"},\"seven_day\":{\"utilization\":12.7,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" \
    | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "63.4" ] || exit 1;
  [ "$(jq -r ".five_hour.resets_at" "$CLAUDE_USAGE_CACHE")" = "2026-07-06T18:00:00Z" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "12.7" ] || exit 1;
  [ "$(jq -r ".seven_day.resets_at" "$CLAUDE_USAGE_CACHE")" = "2026-07-10T00:00:00Z" ] || exit 1;
'

run_test "(2) same run -> hud snapshot exactly-2-keys + rounded used_percentage + updated_at" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"2026-07-06T18:00:00Z\"},\"seven_day\":{\"utilization\":12.7,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" \
    | bash "$PRODUCER";
  [ "$(jq -r ".five_hour|keys|sort|join(\",\")" "$HUD_USAGE_SNAPSHOT")" = "resets_at,used_percentage" ] || exit 1;
  [ "$(jq -r ".seven_day|keys|length" "$HUD_USAGE_SNAPSHOT")" = "2" ] || exit 1;
  [ "$(jq -r ".five_hour.used_percentage" "$HUD_USAGE_SNAPSHOT")" = "63" ] || exit 1;
  [ "$(jq -r ".seven_day.used_percentage" "$HUD_USAGE_SNAPSHOT")" = "13" ] || exit 1;
  u=$(jq -r ".updated_at // empty" "$HUD_USAGE_SNAPSHOT"); [ -n "$u" ] || exit 1;
'

run_test "(3) no rate_limits + stubbed OAuth -> fetched primary wins, missing primary falls back, hud gains balance_label" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # pre-seed cache with good five_hour/seven_day, NO oauth_checked_at (=> OAuth stale => fetch)
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "[ -n \"\${OAUTH_MARKER:-}\" ] \&\& : > \"\$OAUTH_MARKER\"" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"extra_usage\":{\"is_enabled\":true,\"used_credits\":350,\"monthly_limit\":5000,\"utilization\":7}}" "JSON" > "$stub";
  export OAUTH_MARKER="$W/marker"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  # fetched primaries now WIN (the old order discarded them)
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "99" ] || exit 1;
  # seven_day absent from the fetch -> prev survives via the // $p fallback
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "8" ] || exit 1;
  # Partial primary fetch has no aggregate freshness provenance.
  jq -e ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE" >/dev/null && exit 1;
  # extra_usage merged from fetch
  [ "$(jq -r ".extra_usage.used_credits" "$CLAUDE_USAGE_CACHE")" = "350" ] || exit 1;
  # hud snapshot gains balance_label
  bl=$(jq -r ".balance_label // empty" "$HUD_USAGE_SNAPSHOT"); [ -n "$bl" ] || exit 1;
'

run_test "(3b) HIMMEL-1841: extra_usage-only fetch does NOT stamp primaries_refreshed_at" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3b.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"extra_usage\":{\"utilization\":7}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "40" ] || exit 1;
  jq -e ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE" >/dev/null && exit 1;
  exit 0;
'

run_test "(3c) HIMMEL-1866: extra_usage-only fetch preserves primaries_refreshed_at" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3c.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"extra_usage\":{\"utilization\":7}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || exit 1;
'

run_test "(3d) HIMMEL-1866: empty fetched window preserves prior utilization" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3d.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "40" ] || exit 1;
'

run_test "(3e) thin five_hour fetch keeps prior reset/dollars and partial-fetch provenance" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\",\"used_dollars\":12},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\",\"limit_dollars\":100},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":0}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  bash "$PRODUCER" </dev/null;
  jq -e ".five_hour == {utilization:0,resets_at:\"R5\",used_dollars:12} and .seven_day == {utilization:8,resets_at:\"R7\",limit_dollars:100}" "$CLAUDE_USAGE_CACHE" || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || exit 1;
'

run_test "(3f) thin seven_day fetch keeps prior reset/dollars; two valid fetched primaries refresh provenance and HUD stays two-key" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\",\"used_dollars\":12},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\",\"limit_dollars\":100},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  before=$(date +%s); bash "$PRODUCER" </dev/null;
  jq -e ".seven_day == {utilization:20,resets_at:\"R7\",limit_dollars:100}" "$CLAUDE_USAGE_CACHE" || exit 1;
  stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
  [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ] || exit 1;
  jq -e ".five_hour == {used_percentage:10,resets_at:\"R5\"} and .seven_day == {used_percentage:20,resets_at:\"R7\"}" "$HUD_USAGE_SNAPSHOT" || exit 1;
'

run_test "(3g) complete OAuth windows replace every fetched key and refresh provenance" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  prior="{\"utilization\":40,\"resets_at\":\"old\",\"limit_dollars\":100,\"used_dollars\":40,\"remaining_dollars\":60}";
  printf "%s" "{\"five_hour\":$prior,\"seven_day\":$prior,\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  five="{\"utilization\":10,\"resets_at\":\"new5\",\"limit_dollars\":200,\"used_dollars\":20,\"remaining_dollars\":180}";
  seven="{\"utilization\":20,\"resets_at\":\"new7\",\"limit_dollars\":300,\"used_dollars\":60,\"remaining_dollars\":240}";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":$five,\"seven_day\":$seven}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  before=$(date +%s); bash "$PRODUCER" </dev/null;
  jq -e --argjson five "$five" --argjson seven "$seven" ".five_hour == \$five and .seven_day == \$seven" "$CLAUDE_USAGE_CACHE" || exit 1;
  stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
  [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ] || exit 1;
'

run_test "(3h) explicit fetched null wins over prior reset/dollars in either primary" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  prior="{\"utilization\":40,\"resets_at\":\"old\",\"used_dollars\":12}";
  printf "%s" "{\"five_hour\":$prior,\"seven_day\":$prior}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10,\"resets_at\":null,\"used_dollars\":null},\"seven_day\":{\"utilization\":20,\"resets_at\":null,\"used_dollars\":null}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  bash "$PRODUCER" </dev/null;
  jq -e ".five_hour == {utilization:10,resets_at:null,used_dollars:null} and .seven_day == {utilization:20,resets_at:null,used_dollars:null}" "$CLAUDE_USAGE_CACHE" || exit 1;
'

run_test "(3i) thin OAuth windows never carry fields across known accounts" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-current\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  prior="{\"utilization\":40,\"resets_at\":\"other-account-reset\",\"used_dollars\":12}";
  printf "%s" "{\"account\":\"different-account\",\"five_hour\":$prior,\"seven_day\":$prior,\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  bash "$PRODUCER" </dev/null;
  jq -e ".five_hour == {utilization:10} and .seven_day == {utilization:20} and (.account != null and .account != \"different-account\")" "$CLAUDE_USAGE_CACHE" || exit 1;
'

run_test "(3j) missing or null fetched utilization ignores the whole window and preserves provenance" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  prior="{\"utilization\":40,\"resets_at\":\"old\",\"used_dollars\":12}";
  printf "%s" "{\"five_hour\":$prior,\"seven_day\":$prior,\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"resets_at\":\"ignored\"},\"seven_day\":{\"utilization\":null,\"resets_at\":\"ignored\"}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  bash "$PRODUCER" </dev/null;
  jq -e --argjson prior "$prior" ".five_hour == \$prior and .seven_day == \$prior and .primaries_refreshed_at == 1234567890" "$CLAUDE_USAGE_CACHE" || exit 1;
'

run_test "(3k) valid OAuth windows replace malformed same-account primaries without losing a healthy sibling" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-fields.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-current\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  export USAGE_FORCE_REFRESH=1;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":1},\"seven_day\":{\"utilization\":2}}}" | bash "$PRODUCER";
  acct=$(jq -er ".account" "$CLAUDE_USAGE_CACHE") || exit 1;
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  for window in five_hour seven_day; do
    for malformed in "\"corrupt\"" "[]" "42" "true"; do
      jq -n --arg acct "$acct" --arg window "$window" --argjson malformed "$malformed" \
        "{account:\$acct,five_hour:{utilization:1,resets_at:\"old\"},seven_day:{utilization:2,resets_at:\"old\"},primaries_refreshed_at:1234567890} | .[\$window] = \$malformed" > "$CLAUDE_USAGE_CACHE" || exit 1;
      before=$(date +%s); bash "$PRODUCER" </dev/null;
      jq -e --arg acct "$acct" --arg window "$window" \
        ".account == \$acct and .five_hour == ({utilization:10} + (if \$window == \"five_hour\" then {} else {resets_at:\"old\"} end)) and .seven_day == ({utilization:20} + (if \$window == \"seven_day\" then {} else {resets_at:\"old\"} end))" "$CLAUDE_USAGE_CACHE" || exit 1;
      stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
      [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ] || exit 1;
    done;
  done;
'

run_test "(4) atomicity: temp+mv pattern present AND cache intact after failing OAuth stub (no partial/tmp file)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # static: producer writes via temp + mv -f
  grep -q "mv -f" "$PRODUCER" || exit 1;
  grep -q "\.tmp" "$PRODUCER" || exit 1;
  # seed a good cache; a FAILING (non-JSON) OAuth stub must not clobber it
  good="{\"five_hour\":{\"utilization\":55,\"resets_at\":\"RR\"},\"seven_day\":{\"utilization\":9,\"resets_at\":\"RR7\"},\"extra_usage\":{}}";
  printf "%s" "$good" > "$CLAUDE_USAGE_CACHE";
  fstub="$W/failstub.sh"; printf "%s\n" "#!/usr/bin/env bash" "echo not-json-{{" > "$fstub";
  chmod +x "$fstub"; export USAGE_OAUTH_CMD="$fstub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ "$(cat "$CLAUDE_USAGE_CACHE")" = "$good" ] || exit 1;
  # no leftover temp files in EITHER pattern: PID fallback (.tmp) or mktemp (.XXXXXX -> cache.json.??????)
  ls "$W"/*.tmp >/dev/null 2>&1 && exit 1;
  ls "$W"/cache.json.?????? >/dev/null 2>&1 && exit 1;
  ls "$W"/hud.json.?????? >/dev/null 2>&1 && exit 1;
  exit 0;
'

run_test "(5a) TTL throttle: fresh consumer cache (within USAGE_CACHE_TTL) is NOT rewritten on rates path" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  seed="{\"five_hour\":{\"utilization\":1,\"resets_at\":\"X\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"Y\"},\"extra_usage\":{}}";
  printf "%s" "$seed" > "$CLAUDE_USAGE_CACHE";
  m1=$(mtime "$CLAUDE_USAGE_CACHE");
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  m2=$(mtime "$CLAUDE_USAGE_CACHE");
  [ "$(cat "$CLAUDE_USAGE_CACHE")" = "$seed" ] || exit 1;
  [ "$m1" = "$m2" ] || exit 1;
'

run_test "(5b) OAuth throttle: fresh oauth_checked_at -> stub NOT invoked (marker absent)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  now=$(date +%s);
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{\"is_enabled\":true},\"oauth_checked_at\":$now}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh"; export OAUTH_MARKER="$W/marker";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "echo {}" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ -e "$OAUTH_MARKER" ] && exit 1;
  exit 0;
'

run_test "(5c) OAuth throttle: stale oauth_checked_at -> stub IS invoked (marker present)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  now=$(date +%s); old=$((now - 4000));
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{\"is_enabled\":true},\"oauth_checked_at\":$old}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh"; export OAUTH_MARKER="$W/marker";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "echo '"'"'{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":100,\"monthly_limit\":5000}}'"'"'" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ -e "$OAUTH_MARKER" ] || exit 1;
  exit 0;
'

run_test "(6) shape guard: five_hour/seven_day are JSON objects on the no-rates path" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # no pre-existing cache (prev null); stub returns ONLY extra_usage
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "echo '"'"'{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":10,\"monthly_limit\":100}}'"'"'" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour|type" "$CLAUDE_USAGE_CACHE")" = "object" ] || exit 1;
  [ "$(jq -r ".seven_day|type" "$CLAUDE_USAGE_CACHE")" = "object" ] || exit 1;
'

run_test "(7) static no-spawn: no background/disown in producer" '
  ! grep -Eq "&[[:space:]]*disown|\([^)]*&[[:space:]]*\)" "$PRODUCER";
'

run_test "(8) seven_day-only rate_limits still mirrors (CR codex-1); the absent five_hour is an empty window, not carried" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  # pre-seed with five_hour so the preserve path is observable; make it STALE vs TTL
  printf "%s" "{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"old\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  export USAGE_CACHE_TTL=0;
  printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" | bash "$PRODUCER";
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  jq -e ".five_hour == {}" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
'

run_test "(9) HIMMEL-3364: both stdin windows stamp primaries_refreshed_at=now, and bank-preflight PROCEEDs on the result" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-9\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  before=$(date +%s);
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":23,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":46,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  stamp=$(jq -r ".primaries_refreshed_at // empty" "$CLAUDE_USAGE_CACHE");
  [ -n "$stamp" ] || exit 1;
  [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(( $(date +%s) + 1 ))" ] || exit 1;
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
      CADENCE_USAGE_WORKER=test3364 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
  [ "$v" = "PROCEED" ] || exit 1;
'

run_test "(9b) HIMMEL-3364: both stdin windows refresh a stale prior stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9b.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":1},\"seven_day\":{\"utilization\":1},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":23},\"seven_day\":{\"utilization\":46}}}" | bash "$PRODUCER";
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" != "1234567890" ] || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" -gt 1234567890 ] || exit 1;
'

run_test "(9c) HIMMEL-3364: a stdin payload with no valid seven_day carries the prior stamp; with no prior stamp none is invented" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9c.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":33},\"seven_day\":{\"utilization\":1},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":12}}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "12" ] || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || exit 1;
  printf "%s" "{\"five_hour\":{\"utilization\":33},\"seven_day\":{\"utilization\":1},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":12}}}" | bash "$PRODUCER";
  jq -e "has(\"primaries_refreshed_at\") | not" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  exit 0;
'

run_test "(10) HIMMEL-1712: rates path stamps account (16-hex hash, never the raw uuid)/derived_at/produced_by" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-10.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  before=$(date +%s);
  printf "%s" "{\"session_id\":\"sess-10\",\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  acct=$(jq -r ".account // empty" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] || exit 1;
  [ "$acct" != "uuid-account-A" ] || exit 1;
  [[ "$acct" =~ ^[0-9a-f]{16}$ ]] || exit 1;
  derived=$(jq -r ".derived_at // empty" "$CLAUDE_USAGE_CACHE");
  [ -n "$derived" ] && [ "$derived" -ge "$before" ] || exit 1;
  produced_by=$(jq -r ".produced_by // empty" "$CLAUDE_USAGE_CACHE");
  [[ "$produced_by" =~ ^[^:]+:[0-9]+$ ]] || exit 1;
'

run_test "(11) HIMMEL-1712: oauth path stamps account/derived_at/produced_by too" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"session_id\":\"sess-11\",\"model\":{}}" | bash "$PRODUCER";
  acct=$(jq -r ".account // empty" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] || exit 1;
  [[ "$acct" =~ ^[0-9a-f]{16}$ ]] || exit 1;
  jq -e ".derived_at" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  jq -e ".produced_by" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
'

run_test "(12) HIMMEL-1712: a session keeps stamping its FIRST-seen identity after ~/.claude.json flips mid-session; a NEW session picks up the current one" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-12.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-S\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_first=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ -n "$acct_first" ] && [ "$acct_first" != "null" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-S\",\"rate_limits\":{\"five_hour\":{\"utilization\":11,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_second=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_second" = "$acct_first" ] || exit 1;
  printf "%s" "{\"session_id\":\"sess-T\",\"rate_limits\":{\"five_hour\":{\"utilization\":12,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_new_session=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_new_session" != "$acct_first" ] || exit 1;
'

run_test "(13) HIMMEL-1712: no readable ~/.claude.json -> account stamped null (UNKNOWN), never fabricated" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-13.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"session_id\":\"sess-13\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  jq -e "has(\"account\")" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "null" ] || exit 1;
'

run_test "(14) HIMMEL-1712 CR (panel round 1, codex-1): a partial window is NOT carried forward from a cache stamped for a DIFFERENT known account" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-14.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-A\",\"rate_limits\":{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"}}}" | bash "$PRODUCER";
  acct_a=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_a" ] && [ "$acct_a" != "null" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-B\",\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  acct_b=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ "$acct_b" != "$acct_a" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".five_hour" "$CLAUDE_USAGE_CACHE")" = "{}" ] || exit 1;
'

run_test "(15) HIMMEL-1712 CR (panel round 2, codex-1): a legacy cache with NO account field is not relabeled under a known current identity" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-15.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-C\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"old\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"session_id\":\"sess-C\",\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  acct=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] && [ "$acct" != "null" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".five_hour" "$CLAUDE_USAGE_CACHE")" = "{}" ] || exit 1;
'

run_test "(16) HIMMEL-1712 CR (panel round 4, codex-1): a session whose FIRST render finds no identity stays pinned UNKNOWN even after the identity becomes available; a NEW session picks up the now-available one" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-16.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-U\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "null" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-D\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-U\",\"rate_limits\":{\"five_hour\":{\"utilization\":11,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "null" ] || exit 1;
  printf "%s" "{\"session_id\":\"sess-V\",\"rate_limits\":{\"five_hour\":{\"utilization\":12,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_new=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_new" ] && [ "$acct_new" != "null" ] || exit 1;
'

run_test "(17) HIMMEL-1712 CR (panel round 8, codex-1): OAuth fetch is skipped, not mislabeled, when ~/.claude.json flips mid-session" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-17.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  export USAGE_OAUTH_TTL=0;
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"session_id\":\"sess-17\",\"model\":{}}" | bash "$PRODUCER";
  acct_first=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_first" ] && [ "$acct_first" != "null" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  stub2="$W/stub2.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"seven_day\":{\"utilization\":88}}" "JSON" > "$stub2";
  chmod +x "$stub2"; export USAGE_OAUTH_CMD="$stub2";
  printf "%s" "{\"session_id\":\"sess-17\",\"model\":{}}" | bash "$PRODUCER";
  acct_second=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_second" = "$acct_first" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
'

run_test "(18) HIMMEL-1712 CR (panel round 9, codex-2): OAuth fetch is skipped, not mislabeled, when the on-disk identity becomes unreadable mid-session" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-18.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  export USAGE_OAUTH_TTL=0;
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"session_id\":\"sess-18\",\"model\":{}}" | bash "$PRODUCER";
  acct_first=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_first" ] && [ "$acct_first" != "null" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
  rm -f "$HOME/.claude.json";
  stub2="$W/stub2.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"seven_day\":{\"utilization\":88}}" "JSON" > "$stub2";
  chmod +x "$stub2"; export USAGE_OAUTH_CMD="$stub2";
  printf "%s" "{\"session_id\":\"sess-18\",\"model\":{}}" | bash "$PRODUCER";
  acct_second=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_second" = "$acct_first" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
'

run_test "(18b) HIMMEL-3729: an identity flip DURING the OAuth fetch discards the fetched numbers instead of stamping them under the pinned account" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-18b.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  export USAGE_OAUTH_TTL=0;
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"session_id\":\"sess-18b\",\"model\":{}}" | bash "$PRODUCER";
  acct_first=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_first" ] && [ "$acct_first" != "null" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
  # The stub flips the on-disk identity to account B DURING the fetch, then returns numbers.
  stub2="$W/stub2.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat > \"\$HOME/.claude.json\" <<JSON" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" "JSON" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"seven_day\":{\"utilization\":88}}" "JSON" > "$stub2";
  chmod +x "$stub2"; export USAGE_OAUTH_CMD="$stub2";
  err=$(printf "%s" "{\"session_id\":\"sess-18b\",\"model\":{}}" | bash "$PRODUCER" 2>&1 >/dev/null);
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "$acct_first" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "10" ] || exit 1;
  printf "%s" "$err" | grep -q "on-disk account identity changed during the OAuth fetch" || exit 1;
'

run_test "(19) HIMMEL-1712 item 4: USAGE_FORCE_REFRESH=1 bypasses the rates-path TTL and stamps a fresh derived_at" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-19.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  seed="{\"five_hour\":{\"utilization\":1,\"resets_at\":\"X\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"Y\"},\"extra_usage\":{},\"derived_at\":1}";
  printf "%s" "$seed" > "$CLAUDE_USAGE_CACHE";
  export USAGE_FORCE_REFRESH=1;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "63.4" ] || exit 1;
  [ "$(jq -r ".derived_at" "$CLAUDE_USAGE_CACHE")" != "1" ] || exit 1;
'

run_test "(20) HIMMEL-1712 item 4: USAGE_FORCE_REFRESH=1 bypasses the OAuth TTL (stub invoked despite fresh oauth_checked_at)" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-20.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  now=$(date +%s);
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{\"is_enabled\":true},\"oauth_checked_at\":$now}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh"; export OAUTH_MARKER="$W/marker";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "echo {}" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  export USAGE_FORCE_REFRESH=1;
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ -e "$OAUTH_MARKER" ] || exit 1;
'

run_test "(21) HIMMEL-1712 item 5: a cross-account overwrite (rates path) emits a stderr WARN naming both account hashes, and still overwrites" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-21.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-A\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER" >/dev/null 2>"$W/err1.log";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-B\",\"rate_limits\":{\"five_hour\":{\"utilization\":11,\"resets_at\":\"R\"}}}" | bash "$PRODUCER" >/dev/null 2>"$W/err2.log";
  grep -qi "different account" "$W/err2.log" || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "11" ] || exit 1;
'

run_test "(22) HIMMEL-3846: a session-less OAuth write stamps the CURRENT identity hash and names its caller in produced_by (caller:pid)" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-22.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh"; want=$(current_account_hash); [ -n "$want" ] || exit 1;
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub"; export USAGE_OAUTH_TTL=0;
  export USAGE_PRODUCER_CALLER="bank-preflight/worker-x";
  bash "$PRODUCER" </dev/null;
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "$want" ] || exit 1;
  [[ "$(jq -r ".produced_by" "$CLAUDE_USAGE_CACHE")" =~ ^bank-preflight/worker-x:[0-9]+$ ]] || exit 1;
'

run_test "(23) HIMMEL-3846: an unnamed caller is stamped unknown:pid; a caller name with shell/JSON-hostile bytes is sanitized" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-23.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD USAGE_PRODUCER_CALLER;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  [[ "$(jq -r ".produced_by" "$CLAUDE_USAGE_CACHE")" =~ ^unknown:[0-9]+$ ]] || exit 1;
  export USAGE_CACHE_TTL=0; export USAGE_PRODUCER_CALLER="a b\"\$(x);c";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":64,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  [[ "$(jq -r ".produced_by" "$CLAUDE_USAGE_CACHE")" =~ ^a_b___x__c:[0-9]+$ ]] || exit 1;
'

run_test "(24) a real account switch STILL reads as a mismatch, an unchanged account never does (the account-identity guard is not weakened)" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-24.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  usage_cache_account_mismatch "$CLAUDE_USAGE_CACHE" && exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  usage_cache_account_mismatch "$CLAUDE_USAGE_CACHE" || exit 1;
'

run_test "(11a) HIMMEL-8827 oauth: API-empty five_hour + numeric seven_day stamps, and drops the stale carried five_hour" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11a.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  for empty in "{\"utilization\":null,\"resets_at\":\"R\"}" "{}" "null"; do
    printf "%s" "{\"five_hour\":{\"utilization\":90,\"resets_at\":\"old\"},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    stub="$W/stub.sh";
    printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":$empty,\"seven_day\":{\"utilization\":43,\"resets_at\":\"R7\"}}" "JSON" > "$stub";
    chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
    before=$(date +%s); bash "$PRODUCER" </dev/null || exit 1;
    stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
    [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ] || exit 1;
    jq -e ".five_hour == {} and .seven_day.utilization == 43" "$CLAUDE_USAGE_CACHE" || exit 1;
  done;
'

run_test "(11b) HIMMEL-8827 stdin: rate_limits with an empty five_hour + numeric seven_day stamps, and drops the stale carried five_hour" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11b.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  for empty in "null" "{}"; do
    printf "%s" "{\"five_hour\":{\"utilization\":90},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    before=$(date +%s);
    printf "%s" "{\"rate_limits\":{\"five_hour\":$empty,\"seven_day\":{\"utilization\":43}}}" | bash "$PRODUCER" || exit 1;
    stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
    [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ] || exit 1;
    jq -e ".five_hour == {} and .seven_day.utilization == 43" "$CLAUDE_USAGE_CACHE" || exit 1;
  done;
'

run_test "(11c) HIMMEL-8827 control: a malformed oauth five_hour or a missing or malformed seven_day keeps the prior stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11c.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh"; : > "$stub"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  for payload in \
    "{\"five_hour\":{\"utilization\":\"x\"},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":-1},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":101},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":false},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":\"x\"}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":150}}" \
    "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":null}}" \
    "{\"five_hour\":{\"used_percentage\":95},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":150}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":-1}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":\"x\"}}" \
    "{\"five_hour\":{\"utilization\":10}}"; do
    printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "$payload" "JSON" > "$stub";
    bash "$PRODUCER" </dev/null || exit 1;
    jq -e ".derived_at != null" "$CLAUDE_USAGE_CACHE" >/dev/null || { echo "no cache written for: $payload" >&2; exit 1; };
    [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "stamped on: $payload" >&2; exit 1; };
  done;
'

run_test "(11d) HIMMEL-8827 control: stdin windows out of range or without a valid seven_day keep the prior stamp; both numeric still stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11d.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  for rl in \
    "{\"five_hour\":{\"utilization\":101},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":-5},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":101}}" \
    "{\"five_hour\":{\"utilization\":10}}" \
    "{\"five_hour\":{\"utilization\":false},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":\"x\",\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":150}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":-1}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":\"x\"}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":null}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":\"x\"}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":-1}}" \
    "{\"five_hour\":{\"utilization\":\"10\"},\"seven_day\":{\"utilization\":43}}" \
    "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":\"43\"}}" \
    "{\"five_hour\":null,\"seven_day\":{\"utilization\":\"43\"}}" \
    "{\"five_hour\":{\"used_percentage\":false},\"seven_day\":{\"utilization\":43}}"; do
    printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    printf "%s" "{\"rate_limits\":$rl}" | bash "$PRODUCER" || exit 1;
    jq -e ".derived_at != null" "$CLAUDE_USAGE_CACHE" >/dev/null || { echo "no cache written for: $rl" >&2; exit 1; };
    [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "stamped on: $rl" >&2; exit 1; };
  done;
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":0},\"seven_day\":{\"utilization\":100}}}" | bash "$PRODUCER" || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" -gt 1234567890 ] || exit 1;
'

run_test "(11e) HIMMEL-8827: a fetch with an empty five_hour and numeric seven_day gives a bank verdict other than BANK-STALE" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11e.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-11e\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh";
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  for cs in "43 PROCEED" "100 SKIPPED-BANK"; do
    set -- $cs;
    rm -f "$CLAUDE_USAGE_CACHE";
    printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":null,\"resets_at\":null},\"seven_day\":{\"utilization\":$1,\"resets_at\":\"R7\"}}" "JSON" > "$stub";
    chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
    bash "$PRODUCER" </dev/null || exit 1;
    v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
        CADENCE_USAGE_WORKER=test8827 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
    [ "$v" = "$2" ] || { echo "seven_day $1: verdict $v, wanted $2" >&2; exit 1; };
  done;
  export USAGE_CACHE_TTL=0; unset USAGE_OAUTH_CMD;
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh"; want=$(current_account_hash); [ -n "$want" ] || exit 1;
  for c in "10 100 10 \"100\"" "100 10 \"100\" 10"; do
    set -- $c;
    printf "%s" "{\"five_hour\":{\"utilization\":$1},\"seven_day\":{\"utilization\":$2},\"account\":\"$want\",\"primaries_refreshed_at\":$(date +%s)}" > "$CLAUDE_USAGE_CACHE";
    printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":$3},\"seven_day\":{\"utilization\":$4}}}" | bash "$PRODUCER" || exit 1;
    v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
        CADENCE_USAGE_WORKER=test8827 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
    [ "$v" = "SKIPPED-BANK" ] || { echo "stdin five_hour $3 seven_day $4 over a fresh stamp ($1/$2): verdict $v, wanted SKIPPED-BANK" >&2; exit 1; };
  done;
'

run_test "(11g) HIMMEL-8827: the real stdin shape, used_percentage, stamps fresh and mirrors the numbers" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11g.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  for c in \
    "{\"five_hour\":{\"used_percentage\":42,\"resets_at\":1783339200},\"seven_day\":{\"used_percentage\":68,\"resets_at\":1783900800}}|42|68" \
    "{\"five_hour\":{\"used_percentage\":95},\"seven_day\":{\"utilization\":43}}|95|43" \
    "{\"five_hour\":null,\"seven_day\":{\"used_percentage\":43}}|null|43"; do
    rl=${c%%|*}; rest=${c#*|}; fh=${rest%%|*}; sd=${rest#*|};
    printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    printf "%s" "{\"rate_limits\":$rl}" | bash "$PRODUCER" || exit 1;
    [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" -gt 1234567890 ] || { echo "no fresh stamp for: $rl" >&2; exit 1; };
    [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "$sd" ] || { echo "seven_day not mirrored for: $rl" >&2; exit 1; };
    [ "$(jq -r ".five_hour.utilization // \"null\"" "$CLAUDE_USAGE_CACHE")" = "$fh" ] || { echo "five_hour not mirrored for: $rl" >&2; exit 1; };
  done;
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":1783339200},\"seven_day\":{\"used_percentage\":68,\"resets_at\":1783900800}}}" | bash "$PRODUCER" || exit 1;
  [ "$(jq -r ".five_hour.resets_at" "$CLAUDE_USAGE_CACHE")" = "1783339200" ] || exit 1;
  [ "$(jq -r ".seven_day.resets_at" "$CLAUDE_USAGE_CACHE")" = "1783900800" ] || exit 1;
'

run_test "(11h) HIMMEL-8827: an oauth fetch with a non-number window carries the cached window and the prior stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11h.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-11h\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh"; want=$(current_account_hash); [ -n "$want" ] || exit 1;
  stub="$W/stub.sh"; export USAGE_OAUTH_CMD="$stub"; export USAGE_OAUTH_TTL=0;
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  for c in "five_hour \"10\"" "five_hour false" "seven_day \"10\"" "seven_day false"; do
    set -- $c; w=$1; bad=$2;
    if [ "$w" = five_hour ]; then f=$bad; s=10; else f=10; s=$bad; fi;
    printf "%s" "{\"five_hour\":{\"utilization\":100},\"seven_day\":{\"utilization\":100},\"account\":\"$want\",\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":$f},\"seven_day\":{\"utilization\":$s}}" "JSON" > "$stub"; chmod +x "$stub";
    bash "$PRODUCER" </dev/null || exit 1;
    [ "$(jq -r ".$w.utilization" "$CLAUDE_USAGE_CACHE")" = "100" ] || { echo "oauth $w $bad: the cached high $w was not carried" >&2; exit 1; };
    [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "oauth $w $bad: stamped" >&2; exit 1; };
  done;
  printf "%s" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":100},\"account\":\"$want\",\"primaries_refreshed_at\":$(date +%s)}" > "$CLAUDE_USAGE_CACHE";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":\"10\"}}" "JSON" > "$stub"; chmod +x "$stub";
  bash "$PRODUCER" </dev/null || exit 1;
  v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
      CADENCE_USAGE_WORKER=test8827 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
  [ "$v" = "SKIPPED-BANK" ] || { echo "oauth seven_day string over a fresh stamp: verdict $v, wanted SKIPPED-BANK" >&2; exit 1; };
'

run_test "(11f) HIMMEL-8827: fully spent or fully free windows stamp fresh on both branches (0 and 100 are valid)" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11f.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh"; : > "$stub"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub"; export USAGE_CACHE_TTL=0;
  for cs in "0 0" "null 100" "0 100" "100 0"; do
    set -- $cs;
    for branch in oauth stdin; do
      printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
      before=$(date +%s);
      if [ "$branch" = oauth ]; then
        printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":$1},\"seven_day\":{\"utilization\":$2}}" "JSON" > "$stub";
        bash "$PRODUCER" </dev/null || exit 1;
      else
        printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":$1},\"seven_day\":{\"utilization\":$2}}}" | bash "$PRODUCER" || exit 1;
      fi;
      stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
      { [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ]; } || { echo "$branch five_hour=$1 seven_day=$2: stamp $stamp" >&2; exit 1; };
    done;
  done;
'

run_test "(25a) stdin: a valid seven_day with the five_hour key ABSENT stamps now and writes five_hour {}" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-25a.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  for rl in "{\"seven_day\":{\"utilization\":24,\"resets_at\":\"R7\"}}" "{\"seven_day\":{\"used_percentage\":24}}"; do
    printf "%s" "{\"five_hour\":{\"utilization\":90,\"resets_at\":\"old\"},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    before=$(date +%s);
    printf "%s" "{\"rate_limits\":$rl}" | bash "$PRODUCER" || exit 1;
    stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
    { [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ]; } || { echo "stdin $rl: stamp $stamp, wanted now" >&2; exit 1; };
    jq -e ".five_hour == {} and .seven_day.utilization == 24" "$CLAUDE_USAGE_CACHE" >/dev/null || { echo "stdin $rl: five_hour not {} or seven_day not 24" >&2; exit 1; };
  done;
'

run_test "(25b) oauth: a stale oauth_checked_at, no stdin, valid seven_day and an absent or empty five_hour stamps now; a throttled run leaves the stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-25b.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh"; export USAGE_OAUTH_CMD="$stub"; export OAUTH_MARKER="$W/marker";
  unset USAGE_OAUTH_TTL;
  for body in "{\"seven_day\":{\"utilization\":24}}" "{\"five_hour\":{},\"seven_day\":{\"utilization\":24}}"; do
    printf "%s" "{\"five_hour\":{\"utilization\":90},\"seven_day\":{\"utilization\":8},\"oauth_checked_at\":1234567890,\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "$body" "JSON" > "$stub"; chmod +x "$stub";
    before=$(date +%s);
    bash "$PRODUCER" </dev/null || exit 1;
    stamp=$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE");
    { [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(date +%s)" ]; } || { echo "oauth $body: stamp $stamp, wanted now" >&2; exit 1; };
    jq -e ".five_hour == {} and .seven_day.utilization == 24" "$CLAUDE_USAGE_CACHE" >/dev/null || { echo "oauth $body: five_hour not {} or seven_day not 24" >&2; exit 1; };
  done;
  now=$(date +%s);
  printf "%s" "{\"five_hour\":{\"utilization\":90},\"seven_day\":{\"utilization\":8},\"oauth_checked_at\":$now,\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "cat <<JSON" "{\"seven_day\":{\"utilization\":24}}" "JSON" > "$stub"; chmod +x "$stub";
  rm -f "$OAUTH_MARKER"; bash "$PRODUCER" </dev/null || exit 1;
  [ ! -e "$OAUTH_MARKER" ] || { echo "throttled run invoked the stub" >&2; exit 1; };
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "throttled run moved the stamp" >&2; exit 1; };
'

run_test "(25c) control: a malformed seven_day with the five_hour key absent keeps the prior stamp, and the preflight reads BANK-STALE" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-25c.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-25c\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh"; want=$(current_account_hash); [ -n "$want" ] || exit 1;
  stub="$W/stub.sh"; export USAGE_CACHE_TTL=0; export USAGE_OAUTH_TTL=0;
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  for sd in "\"x\"" "150" "\"24\""; do
    for branch in stdin oauth; do
      printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"account\":\"$want\",\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
      if [ "$branch" = stdin ]; then
        unset USAGE_OAUTH_CMD;
        printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":$sd}}}" | bash "$PRODUCER" || exit 1;
      else
        printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"seven_day\":{\"utilization\":$sd}}" "JSON" > "$stub"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
        bash "$PRODUCER" </dev/null || exit 1;
      fi;
      jq -e ".derived_at != null" "$CLAUDE_USAGE_CACHE" >/dev/null || { echo "$branch seven_day $sd: no cache written" >&2; exit 1; };
      [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "$branch seven_day $sd: stamped" >&2; exit 1; };
      v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
          CADENCE_USAGE_WORKER=test9821 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
      [ "$v" = "BANK-STALE" ] || { echo "$branch seven_day $sd: verdict $v, wanted BANK-STALE" >&2; exit 1; };
    done;
  done;
'

run_test "(25d) control: a PRESENT malformed five_hour with a valid seven_day keeps the prior stamp on both branches" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-25d.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh"; export USAGE_CACHE_TTL=0; export USAGE_OAUTH_TTL=0;
  for fh in "\"x\"" "false" "{\"utilization\":\"x\"}" "{\"utilization\":101}" "{\"utilization\":-1}" "{\"utilization\":\"10\"}"; do
    for branch in stdin oauth; do
      printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
      if [ "$branch" = stdin ]; then
        unset USAGE_OAUTH_CMD;
        printf "%s" "{\"rate_limits\":{\"five_hour\":$fh,\"seven_day\":{\"utilization\":24}}}" | bash "$PRODUCER" || exit 1;
      else
        printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":$fh,\"seven_day\":{\"utilization\":24}}" "JSON" > "$stub"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
        bash "$PRODUCER" </dev/null || exit 1;
      fi;
      [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || { echo "$branch five_hour $fh: stamped" >&2; exit 1; };
    done;
  done;
'

run_test "(25e) proof: a seven_day of 24 with no five_hour, through either branch, gives PROCEED (not BANK-STALE) from the preflight" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-25e.XXXXXX") || exit 1; export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-25e\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  . "$STATUSLINE_DIR/../lib/usage-cache-identity.sh"; want=$(current_account_hash); [ -n "$want" ] || exit 1;
  stub="$W/stub.sh"; export USAGE_CACHE_TTL=0; export USAGE_OAUTH_TTL=0;
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  for branch in stdin oauth; do
    printf "%s" "{\"five_hour\":{},\"seven_day\":{\"utilization\":24},\"account\":\"$want\",\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
    if [ "$branch" = stdin ]; then
      unset USAGE_OAUTH_CMD;
      printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":24}}}" | bash "$PRODUCER" || exit 1;
    else
      printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"seven_day\":{\"utilization\":24}}" "JSON" > "$stub"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
      bash "$PRODUCER" </dev/null || exit 1;
    fi;
    v=$(CADENCE_USAGE_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/ledger.jsonl" \
        CADENCE_USAGE_WORKER=test9821 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n1);
    [ "$v" = "PROCEED" ] || { echo "$branch: verdict $v, wanted PROCEED" >&2; exit 1; };
  done;
'

# --- summary ------------------------------------------------------------------
if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
