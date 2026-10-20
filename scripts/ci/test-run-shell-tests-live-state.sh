#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-live-state.sh — the runner keeps a suite off
# the operator's live state and fails a suite that writes into it.
#
#   L1. Live-state env (HIMMEL_CONSOLE_*, HIMMEL_INBOX*, HANDOVER_DIR,
#       CLAUDE_CONFIG_DIR, CODEX_HOME) points at the runner's sentinels; a write
#       into one fails that suite and names the variable, and the caller's own
#       paths are never reached.
#   L2. A crontab/at/atq/atrm call reaches the runner's recording shim, never
#       the next one on PATH, and fails the suite with the call named.
#   L3. A process the suite leaves running in its group fails the suite and is
#       terminated.
#   L4. A dirty sentinel is reset, so the next suite is not blamed; a suite
#       that points the variable at its own file is not flagged.
#   L5. Sentinels that cannot be set up abort the run before any suite.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin. L3 is skipped on Git Bash, where the runner does not take the census.
#
# Usage: bash scripts/ci/test-run-shell-tests-live-state.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-live.XXXXXX") || { fail "L: mktemp failed"; rst_tally; }
trap 'rm -rf "$SUITE_LOCK_SANDBOX" "$sb"' EXIT
mkdir -p "$sb/scripts" "$sb/live/handovers" "$sb/live/claude" "$sb/live/codex" "$sb/live/workdir" "$sb/outerbin"

# The caller's live state, as a console leg carries it on the station.
printf '# console\n\n## Results\n- 00:00 LIVE — caller\n' > "$sb/live/console.md"
cp "$sb/live/console.md" "$sb/live/console.orig"
# The next scheduler on PATH after the runner's shim: records, never schedules.
for _t in crontab at atq atrm; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\nexit 0\n' "$_t" "$sb/outer-sched.log" > "$sb/outerbin/$_t"
  chmod +x "$sb/outerbin/$_t"
done

# The bullet merge-on-green appended to the inherited console doc on 6079's
# parent, copied from that replay's output.
cat > "$sb/scripts/test-a-console-doc.sh" <<'SHEOF'
#!/usr/bin/env bash
printf -- '- 22:03 PARTIAL HIMMEL-374: next slice not dispatched\n' >> "$HIMMEL_CONSOLE_DOC"
exit 0
SHEOF
cat > "$sb/scripts/test-b-clean.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
cat > "$sb/scripts/test-c-handover-dir.sh" <<'SHEOF'
#!/usr/bin/env bash
mkdir -p "$HANDOVER_DIR/yotamleo/himmel" && : > "$HANDOVER_DIR/yotamleo/himmel/leaked.md"
exit 0
SHEOF
cat > "$sb/scripts/test-d-claude-codex.sh" <<'SHEOF'
#!/usr/bin/env bash
: > "$CLAUDE_CONFIG_DIR/settings.json"
: > "$CODEX_HOME/config.toml"
exit 0
SHEOF
cat > "$sb/scripts/test-e-crontab.sh" <<'SHEOF'
#!/usr/bin/env bash
crontab -l >/dev/null 2>&1
printf '* * * * * true\n' | crontab - 2>/dev/null
atq >/dev/null 2>&1
exit 0
SHEOF
cat > "$sb/scripts/test-f-own-doc.sh" <<'SHEOF'
#!/usr/bin/env bash
d=$(mktemp -d "${TMPDIR:-/tmp}/rst-own.XXXXXX") || exit 1
HIMMEL_CONSOLE_DOC="$d/own.md"
printf -- '- own bullet\n' >> "$HIMMEL_CONSOLE_DOC"
rm -rf "$d"
exit 0
SHEOF
cat > "$sb/scripts/test-g-env-seen.sh" <<'SHEOF'
#!/usr/bin/env bash
# Prints what a suite inherits; fails if any caller value got through.
for v in HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_NAME HIMMEL_CONSOLE_RELAY HIMMEL_CONSOLE_WORKDIR HIMMEL_INBOX_SEND HANDOVER_DIR CLAUDE_CONFIG_DIR CODEX_HOME; do
  eval "val=\${$v-unset}"
  printf 'seen %s=%s\n' "$v" "$val"
  case "$val" in "$RST_LIVE_CALLER"*|caller-*) echo "caller value reached the suite: $v"; exit 1 ;; esac
done
exit 0
SHEOF
cat > "$sb/scripts/test-h-workdir.sh" <<'SHEOF'
#!/usr/bin/env bash
: > "$HIMMEL_CONSOLE_WORKDIR/precompact-1.snap"
exit 0
SHEOF
chmod +x "$sb/scripts/"*.sh

out=$(PATH="$sb/outerbin:$PATH" RST_LIVE_CALLER="$sb/live" \
  HIMMEL_CONSOLE_DOC="$sb/live/console.md" HIMMEL_CONSOLE_NAME=caller-console \
  HIMMEL_CONSOLE_RELAY=caller-relay HIMMEL_CONSOLE_WORKDIR="$sb/live/workdir" \
  HIMMEL_INBOX_SEND=caller-send HANDOVER_DIR="$sb/live/handovers" \
  CLAUDE_CONFIG_DIR="$sb/live/claude" CODEX_HOME="$sb/live/codex" \
  SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1)
rc=$?

echo "== L1: live-state env points at sentinels; a write fails the suite =="
if [ "$rc" -eq 1 ]; then pass "L1: run exits 1"; else fail "L1: expected rc=1, got $rc; out: $out"; fi
if cmp -s "$sb/live/console.md" "$sb/live/console.orig"; then
  pass "L1: the caller's console doc is byte-identical"
else
  fail "L1: the caller's console doc was written: $(cat "$sb/live/console.md")"
fi
for _d in handovers claude codex workdir; do
  if [ -z "$(ls -A "$sb/live/$_d")" ]; then
    pass "L1: the caller's $_d dir is untouched"
  else
    fail "L1: the caller's $_d dir was written: $(ls -A "$sb/live/$_d")"
  fi
done
if grepq "$out" -E '\[LIVE-STATE\] .*test-a-console-doc\.sh .*HIMMEL_CONSOLE_DOC'; then
  pass "L1: a console-doc write names HIMMEL_CONSOLE_DOC"
else
  fail "L1: no [LIVE-STATE] HIMMEL_CONSOLE_DOC line for test-a; out: $out"
fi
if grepq "$out" -E '\[FAIL\] .*test-a-console-doc\.sh'; then
  pass "L1: the console-doc writer is a [FAIL]"
else
  fail "L1: test-a-console-doc.sh is not a [FAIL]; out: $out"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-c-handover-dir\.sh .*HANDOVER_DIR'; then
  pass "L1: a handover-dir write names HANDOVER_DIR"
else
  fail "L1: no [LIVE-STATE] HANDOVER_DIR line for test-c; out: $out"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-d-claude-codex\.sh .*CLAUDE_CONFIG_DIR' \
  && grepq "$out" -E '\[LIVE-STATE\] .*test-d-claude-codex\.sh .*CODEX_HOME'; then
  pass "L1: claude and codex config writes name CLAUDE_CONFIG_DIR and CODEX_HOME"
else
  fail "L1: no [LIVE-STATE] CLAUDE_CONFIG_DIR/CODEX_HOME lines for test-d; out: $out"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-h-workdir\.sh .*HIMMEL_CONSOLE_WORKDIR'; then
  pass "L1: a console-workdir write names HIMMEL_CONSOLE_WORKDIR"
else
  fail "L1: no [LIVE-STATE] HIMMEL_CONSOLE_WORKDIR line for test-h; out: $out"
fi
if grepq "$out" -E '\[PASS\] .*test-g-env-seen\.sh'; then
  pass "L1: no caller value of a live-state variable reaches a suite"
else
  fail "L1: a caller live-state value reached test-g; out: $out"
fi

echo "== L2: scheduler calls hit the recording shim and fail the suite =="
if [ ! -s "$sb/outer-sched.log" ]; then
  pass "L2: no scheduler call reached the next crontab/at on PATH"
else
  fail "L2: a scheduler call got past the runner's shim: $(cat "$sb/outer-sched.log")"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-e-crontab\.sh .*crontab -l' \
  && grepq "$out" -E '\[LIVE-STATE\] .*test-e-crontab\.sh .*crontab -' \
  && grepq "$out" -E '\[LIVE-STATE\] .*test-e-crontab\.sh .*atq'; then
  pass "L2: every recorded call is named"
else
  fail "L2: the crontab/atq calls are not all named for test-e; out: $out"
fi
if grepq "$out" -E '\[FAIL\] .*test-e-crontab\.sh'; then
  pass "L2: the scheduler caller is a [FAIL]"
else
  fail "L2: test-e-crontab.sh is not a [FAIL]; out: $out"
fi

echo "== L4: a dirty sentinel is reset; a suite's own path is not flagged =="
if grepq "$out" -E '\[PASS\] .*test-b-clean\.sh'; then
  pass "L4: the clean suite after a dirty one passes"
else
  fail "L4: test-b-clean.sh was blamed for test-a's write; out: $out"
fi
if grepq "$out" -E '\[PASS\] .*test-f-own-doc\.sh'; then
  pass "L4: a suite writing its own HIMMEL_CONSOLE_DOC passes"
else
  fail "L4: test-f-own-doc.sh was flagged; out: $out"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-(b-clean|f-own-doc|g-env-seen)\.sh'; then
  fail "L4: a clean suite got a [LIVE-STATE] line; out: $out"
else
  pass "L4: no [LIVE-STATE] line for a clean suite"
fi

echo "== L3: a process left in the suite's group fails the suite =="
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) echo "SKIP L3: the runner takes no process census on Git Bash" ;;
  *)
  sb3=$(mktemp -d "${TMPDIR:-/tmp}/rst-live3.XXXXXX") || { fail "L3: mktemp failed"; rst_tally; }
  mkdir -p "$sb3/scripts"
  cat > "$sb3/scripts/test-survivor.sh" <<SHEOF
#!/usr/bin/env bash
sleep 300 >/dev/null 2>&1 &
echo \$! > "$sb3/survivor.pid"
exit 0
SHEOF
  chmod +x "$sb3/scripts/test-survivor.sh"
  out3=$(SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb3/scripts" 2>&1)
  rc3=$?
  if [ "$rc3" -eq 1 ]; then pass "L3: run exits 1"; else fail "L3: expected rc=1, got $rc3; out: $out3"; fi
  if grepq "$out3" -E '\[LIVE-STATE\] .*test-survivor\.sh .*survived'; then
    pass "L3: the survivor is named"
  else
    fail "L3: no [LIVE-STATE] survivor line; out: $out3"
  fi
  _spid=$(cat "$sb3/survivor.pid" 2>/dev/null)
  if [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null; then
    fail "L3: the survivor $_spid is still running"
    kill -KILL "$_spid" 2>/dev/null
  else
    pass "L3: the survivor was terminated"
  fi
  rm -rf "$sb3"
  ;;
esac

echo "== L5: sentinels that cannot be set up abort the run before any suite =="
mkdir -p "$sb/mkfail" "$sb/scripts5"
printf '#!/usr/bin/env bash\ncase "$*" in *himmel-live-sentinel*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v "mktemp")" > "$sb/mkfail/mktemp"
chmod +x "$sb/mkfail/mktemp"
printf '#!/usr/bin/env bash\n: > %q\nexit 0\n' "$sb/ran5" > "$sb/scripts5/test-ran.sh"
chmod +x "$sb/scripts5/test-ran.sh"
out5=$(PATH="$sb/mkfail:$PATH" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts5" 2>&1)
rc5=$?
if [ "$rc5" -eq 2 ]; then pass "L5: run exits 2"; else fail "L5: expected rc=2, got $rc5; out: $out5"; fi
if [ ! -e "$sb/ran5" ]; then pass "L5: no suite ran"; else fail "L5: a suite ran without sentinels; out: $out5"; fi

rst_tally
