#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-run-shell-tests-live-state.sh — the runner keeps a suite off
# the operator's live state and fails a suite that writes into it.
#
#   L1. Live-state env (HIMMEL_CONSOLE_*, HIMMEL_INBOX*, HANDOVER_DIR,
#       CLAUDE_CONFIG_DIR, CODEX_HOME) the caller has points at the runner's
#       sentinels; a write
#       into one fails that suite and names the variable, and the caller's own
#       paths are never reached.
#   L2. A crontab/at/atq/atrm call reaches the runner's recording shim, never
#       the next one on PATH, and fails the suite with the call named.
#   L3. A process the suite leaves running in its group fails the suite and is
#       terminated.
#   L4. A dirty sentinel is reset, so the next suite is not blamed; a suite
#       that points the variable at its own file is not flagged.
#   L5. Sentinels or scheduler shims that cannot be set up abort the run
#       before any suite.
#   L6. A suite that removes the scheduler shims fails, and the next suite
#       meets recreated shims.
#   L7. Sentinels that cannot be reset after a suite abort the run, naming
#       that suite, before a later suite runs.
#   L8. Under the default hard-fail list a listed suite still fails on a leak,
#       and any other suite gets a [LIVE-STATE] WARN and passes. L1-L7 run
#       with every suite hard (SUITE_LIVE_HARD='*').
#   L9. An unlisted suite's scheduler call is recorded and then reaches the
#       next scheduler on PATH; a hard-fail suite's call is refused.
#  L10. A dir sentinel replaces only a value the caller has: with none the
#       var stays unset and a suite's HOME fixture is read; with one the
#       suite sees the sentinel, never the caller's value.
#  L11. A shim forwards only for the runner that installed it: a nested
#       runner's unlisted suite under a hard outer suite reaches no scheduler,
#       and the two shims never exec each other in a loop.
#
# Platform guard: bash-only, like every suite in this family; Linux/macOS.
#
# Usage: bash scripts/ci/test-run-shell-tests-live-state.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
export SUITE_LIVE_HARD='*'

sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-live.XXXXXX") || { fail "L: mktemp failed"; rst_tally; }
trap 'rm -rf "$SUITE_LOCK_SANDBOX" "$sb"' EXIT
# A row that drops its env prefix, or a runner that does not yet move HOME,
# writes this sandbox and never the station's real ~/.himmel or ~/.claude.
export HOME="$sb/outer-home"
mkdir -p "$HOME"
mkdir -p "$sb/scripts" "$sb/live/handovers" "$sb/live/claude" "$sb/live/codex" "$sb/live/workdir" "$sb/outerbin"

# The caller's live state, as a chief worker carries it on the station.
printf '# chief\n\n## Results\n- 00:00 LIVE — caller\n' > "$sb/live/chief.md"
cp "$sb/live/chief.md" "$sb/live/chief.orig"
# The next scheduler on PATH after the runner's shim: records, never schedules.
for _t in crontab at atq atrm; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\nexit 0\n' "$_t" "$sb/outer-sched.log" > "$sb/outerbin/$_t"
  chmod +x "$sb/outerbin/$_t"
done

# The bullet merge-on-green appended to the inherited chief doc on 6079's
# parent, copied from that replay's output.
cat > "$sb/scripts/test-a-chief-doc.sh" <<'SHEOF'
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
cat > "$sb/scripts/test-i-rm-shims.sh" <<'SHEOF'
#!/usr/bin/env bash
rm -rf "${HIMMEL_SUITE_CRONTAB_LOG%/*}/bin"
exit 0
SHEOF
cat > "$sb/scripts/test-j-cron-after.sh" <<'SHEOF'
#!/usr/bin/env bash
crontab -l >/dev/null 2>&1
exit 0
SHEOF
chmod +x "$sb/scripts/"*.sh

out=$(PATH="$sb/outerbin:$PATH" RST_LIVE_CALLER="$sb/live" \
  HIMMEL_CONSOLE_DOC="$sb/live/chief.md" HIMMEL_CONSOLE_NAME=caller-chief \
  HIMMEL_CONSOLE_RELAY=caller-relay HIMMEL_CONSOLE_WORKDIR="$sb/live/workdir" \
  HIMMEL_INBOX_SEND=caller-send HANDOVER_DIR="$sb/live/handovers" \
  CLAUDE_CONFIG_DIR="$sb/live/claude" CODEX_HOME="$sb/live/codex" \
  SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts" 2>&1)
rc=$?

echo "== L1: live-state env points at sentinels; a write fails the suite =="
if [ "$rc" -eq 1 ]; then pass "L1: run exits 1"; else fail "L1: expected rc=1, got $rc; out: $out"; fi
if cmp -s "$sb/live/chief.md" "$sb/live/chief.orig"; then
  pass "L1: the caller's chief doc is byte-identical"
else
  fail "L1: the caller's chief doc was written: $(cat "$sb/live/chief.md")"
fi
for _d in handovers claude codex workdir; do
  if [ -z "$(ls -A "$sb/live/$_d")" ]; then
    pass "L1: the caller's $_d dir is untouched"
  else
    fail "L1: the caller's $_d dir was written: $(ls -A "$sb/live/$_d")"
  fi
done
if grepq "$out" -E '\[LIVE-STATE\] .*test-a-chief-doc\.sh .*HIMMEL_CONSOLE_DOC'; then
  pass "L1: a chief-doc write names HIMMEL_CONSOLE_DOC"
else
  fail "L1: no [LIVE-STATE] HIMMEL_CONSOLE_DOC line for test-a; out: $out"
fi
if grepq "$out" -E '\[FAIL\] .*test-a-chief-doc\.sh'; then
  pass "L1: the chief-doc writer is a [FAIL]"
else
  fail "L1: test-a-chief-doc.sh is not a [FAIL]; out: $out"
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
  pass "L1: a chief-workdir write names HIMMEL_CONSOLE_WORKDIR"
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

echo "== L6: a suite that removes the scheduler shims fails, and the shims return =="
if grepq "$out" -E '\[LIVE-STATE\] .*test-i-rm-shims\.sh .*removed the crontab scheduler shim'; then
  pass "L6: removing the shims names them"
else
  fail "L6: no [LIVE-STATE] shim line for test-i; out: $out"
fi
if grepq "$out" -E '\[LIVE-STATE\] .*test-j-cron-after\.sh .*crontab -l'; then
  pass "L6: the next suite's crontab call hits a recreated shim"
else
  fail "L6: test-j's crontab call was not recorded by the shim; out: $out"
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
mkdir -p "$sb/chmodfail"
printf '#!/usr/bin/env bash\ncase "$*" in *himmel-live-sentinel*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v chmod)" > "$sb/chmodfail/chmod"
chmod +x "$sb/chmodfail/chmod"
out5b=$(PATH="$sb/chmodfail:$PATH" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts5" 2>&1)
rc5b=$?
if [ "$rc5b" -eq 2 ]; then pass "L5: a shim that cannot be made executable exits 2"; else fail "L5: shim chmod failure: expected rc=2, got $rc5b; out: $out5b"; fi
if [ ! -e "$sb/ran5" ]; then pass "L5: no suite ran without its shims"; else fail "L5: a suite ran without its shims; out: $out5b"; fi

echo "== L7: sentinels that cannot be reset after a suite abort the run =="
if [ "$(id -u)" = 0 ]; then
  pass "L7: skipped as root, where a read-only dir does not stop rm"
else
  mkdir -p "$sb/scripts7"
  cat > "$sb/scripts7/test-a-stuck.sh" <<SHEOF
#!/usr/bin/env bash
printf %s "\$HANDOVER_DIR" > "$sb/stuck7"
: > "\$HANDOVER_DIR/stuck"
chmod 500 "\$HANDOVER_DIR"
exit 0
SHEOF
  printf '#!/usr/bin/env bash\n: > %q\nexit 0\n' "$sb/ran7" > "$sb/scripts7/test-b-later.sh"
  chmod +x "$sb/scripts7/"*.sh
  out7=$(HANDOVER_DIR="$sb/live/handovers" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/scripts7" 2>&1)
  rc7=$?
  _stuck=$(cat "$sb/stuck7" 2>/dev/null)
  if [ -n "$_stuck" ]; then chmod 700 "$_stuck" 2>/dev/null; rm -rf "${_stuck%/state/*}"; fi
  if [ "$rc7" -eq 2 ]; then pass "L7: run exits 2"; else fail "L7: expected rc=2, got $rc7; out: $out7"; fi
  if grepq "$out7" -E 'could not reset the live-state sentinels after .*test-a-stuck\.sh'; then
    pass "L7: the error names the suite that dirtied the sentinels"
  else
    fail "L7: no reset error naming test-a-stuck.sh; out: $out7"
  fi
  if [ ! -e "$sb/ran7" ]; then pass "L7: no later suite ran"; else fail "L7: a later suite ran on unreset sentinels; out: $out7"; fi
fi

echo "== L8: only a hard-fail suite fails on a leak; any other suite WARNs and passes =="
# The call test-arm-resume-proxy.sh made on CI shard 8, copied from its log.
mkdir -p "$sb/root8/scripts/handover" "$sb/root8/scripts/cloud"
printf '#!/usr/bin/env bash\ncrontab -l >/dev/null 2>&1\nexit 0\n' > "$sb/root8/scripts/handover/test-merge-on-green.sh"
printf '#!/usr/bin/env bash\ncrontab -l >/dev/null 2>&1\nexit 0\n' > "$sb/root8/scripts/cloud/test-x-leaks.sh"
chmod +x "$sb/root8/scripts/handover/test-merge-on-green.sh" "$sb/root8/scripts/cloud/test-x-leaks.sh"
# The real scheduler as an unlisted suite meets it: a listing it can check.
mkdir -p "$sb/realbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho "0 3 * * * fake-job"\n' "$sb/real-crontab.log" > "$sb/realbin/crontab"
chmod +x "$sb/realbin/crontab"
out8=$(PATH="$sb/realbin:$PATH" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE -u SUITE_LIVE_HARD bash "$RUNNER" "$sb/root8" 2>&1)
rc8=$?
if [ "$rc8" -eq 1 ]; then pass "L8: run exits 1"; else fail "L8: expected rc=1, got $rc8; out: $out8"; fi
if grepq "$out8" -E '\[FAIL\] .*scripts/handover/test-merge-on-green\.sh' \
  && grepq "$out8" -E '\[LIVE-STATE\] [^W].*test-merge-on-green\.sh .*crontab -l'; then
  pass "L8: a hard-fail suite still fails on a scheduler call"
else
  fail "L8: test-merge-on-green.sh did not fail on its crontab call; out: $out8"
fi
if grepq "$out8" -E '\[LIVE-STATE\] WARN .*test-x-leaks\.sh .*crontab -l' \
  && grepq "$out8" -E '\[PASS\] .*test-x-leaks\.sh'; then
  pass "L8: a suite off the list WARNs and passes"
else
  fail "L8: test-x-leaks.sh did not WARN and pass; out: $out8"
fi

echo "== L9: an unlisted suite's scheduler call reaches the next scheduler on PATH; a hard-fail suite's never does =="
mkdir -p "$sb/root9/scripts/handover" "$sb/root9/scripts/himmelctl"
printf '#!/usr/bin/env bash\ncrontab -l >/dev/null 2>&1\nexit 0\n' > "$sb/root9/scripts/handover/test-merge-on-green.sh"
# Uninstall enumerates the crontab and stops when it cannot (test-standalone-bundle.sh on CI).
printf '#!/usr/bin/env bash\ncrontab -l | grep -q fake-job || { echo "could not enumerate crontab"; exit 1; }\nexit 0\n' > "$sb/root9/scripts/himmelctl/test-x-uninstall.sh"
chmod +x "$sb/root9/scripts/handover/test-merge-on-green.sh" "$sb/root9/scripts/himmelctl/test-x-uninstall.sh"
rm -f "$sb/real-crontab.log"
out9=$(PATH="$sb/realbin:$PATH" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE -u SUITE_LIVE_HARD bash "$RUNNER" "$sb/root9" 2>&1)
calls9=$(cat "$sb/real-crontab.log" 2>/dev/null)
if grepq "$out9" -E '\[LIVE-STATE\] WARN .*test-x-uninstall\.sh .*crontab -l' \
  && grepq "$out9" -E '\[PASS\] .*test-x-uninstall\.sh' && [ "$calls9" = "-l" ]; then
  pass "L9: an unlisted suite is recorded and then reaches the next scheduler"
else
  fail "L9: test-x-uninstall.sh did not reach the next scheduler once; calls: [$calls9]; out: $out9"
fi
if grepq "$out9" -E '\[FAIL\] .*scripts/handover/test-merge-on-green\.sh'; then
  pass "L9: a hard-fail suite is still refused"
else
  fail "L9: test-merge-on-green.sh was not refused; out: $out9"
fi

echo "== L10: a dir sentinel replaces only a caller's value; an unset one stays unset =="
mkdir -p "$sb/root10/scripts" "$sb/root10b/scripts"
# himmel-update.sh's settings lookup, as test-himmel-update-plugin-update.sh meets it on CI.
cat > "$sb/root10/scripts/test-home-fixture.sh" <<'SHEOF'
#!/usr/bin/env bash
HOME=$(mktemp -d "${TMPDIR:-/tmp}/rst-home.XXXXXX") || exit 1
mkdir -p "$HOME/.claude" && echo fixture > "$HOME/.claude/settings.json"
settings="${CLAUDE_USER_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
grep -q fixture "$settings" 2>/dev/null || { echo "read $settings, not the HOME fixture"; rm -rf "$HOME"; exit 1; }
rm -rf "$HOME"
for v in CLAUDE_CONFIG_DIR CODEX_HOME HANDOVER_DIR HIMMEL_CONSOLE_WORKDIR HIMMEL_CONSOLE_RUNDIR; do
  [ -z "${!v+x}" ] || { echo "$v is set to ${!v}"; exit 1; }
done
exit 0
SHEOF
cat > "$sb/root10b/scripts/test-sees-sentinel.sh" <<'SHEOF'
#!/usr/bin/env bash
for v in HANDOVER_DIR CLAUDE_CONFIG_DIR; do
  case "${!v-}" in */himmel-live-sentinel.*/state/"$v") ;; *) echo "$v=${!v-unset} is not the sentinel"; exit 1 ;; esac
done
exit 0
SHEOF
chmod +x "$sb/root10/scripts/test-home-fixture.sh" "$sb/root10b/scripts/test-sees-sentinel.sh"
out10=$(env -u HANDOVER_DIR -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HIMMEL_CONSOLE_WORKDIR -u HIMMEL_CONSOLE_RUNDIR -u CLAUDE_USER_SETTINGS -u SUITE_TIER_MODE SUITE_TIMEOUT=60 bash "$RUNNER" "$sb/root10" 2>&1)
if grepq "$out10" -E '\[PASS\] .*test-home-fixture\.sh'; then
  pass "L10: with no caller value the var stays unset and a suite's HOME fixture is read"
else
  fail "L10: test-home-fixture.sh did not read its HOME fixture; out: $out10"
fi
out10b=$(HANDOVER_DIR="$sb/live/handovers" CLAUDE_CONFIG_DIR="$sb/live/claude" SUITE_TIMEOUT=60 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb/root10b" 2>&1)
if grepq "$out10b" -E '\[PASS\] .*test-sees-sentinel\.sh'; then
  pass "L10: with a caller value the suite sees the sentinel, never the live value"
else
  fail "L10: test-sees-sentinel.sh saw a non-sentinel value; out: $out10b"
fi

echo "== L11: a nested runner's forwarding never passes through an outer hard suite's shim =="
mkdir -p "$sb/root11/scripts/handover" "$sb/inner11/scripts/cloud"
printf '#!/usr/bin/env bash\ncrontab -l >/dev/null 2>&1\nexit 0\n' > "$sb/inner11/scripts/cloud/test-x-leaks.sh"
printf '#!/usr/bin/env bash\nbash %q %q > %q 2>&1\nexit 0\n' "$RUNNER" "$sb/inner11" "$sb/inner11.out" >"$sb/root11/scripts/handover/test-merge-on-green.sh"
chmod +x "$sb/inner11/scripts/cloud/test-x-leaks.sh" "$sb/root11/scripts/handover/test-merge-on-green.sh"
rm -f "$sb/real-crontab.log"
out11=$(PATH="$sb/realbin:$PATH" SUITE_TIMEOUT=20 env -u SUITE_TIER_MODE -u SUITE_LIVE_HARD bash "$RUNNER" "$sb/root11" 2>&1)
calls11=$(cat "$sb/real-crontab.log" 2>/dev/null)
if [ -z "$calls11" ]; then
  pass "L11: the nested unlisted suite's call never reached the next scheduler past the outer shim"
else
  fail "L11: the real crontab saw [$calls11] through an outer hard suite's shim; out: ${out11:0:2000}"
fi
n11=$(printf '%s\n' "$out11" | grep -c 'test-merge-on-green\.sh — scheduler call: crontab -l')
if [ "$n11" = 1 ]; then
  pass "L11: the outer shim recorded the forwarded call once and refused it"
else
  fail "L11: the outer shim recorded $n11 calls (a shim loop); out: ${out11:0:2000}"
fi
if grepq "$(cat "$sb/inner11.out" 2>/dev/null)" -E '\[LIVE-STATE\] WARN .*test-x-leaks\.sh .*crontab -l'; then
  pass "L11: the nested runner ran its unlisted suite"
else
  fail "L11: the nested runner did not run test-x-leaks.sh; inner: $(cat "$sb/inner11.out" 2>/dev/null)"
fi

# L12-L13: the decoy station home. Under home-canary the runner moves each suite's
# HOME to a decoy laid out like the station, and a write into it fails the suite.
# w_run <name> <body> [env args...] — one fixture suite test-k-<name>.sh in its own
# scan root, the inner runner started as home-canary starts it. Sets w_out, w_rc.
: > "$sb/exempt.txt"
w_repo=$(cd "$RST_FIXTURE_DIR/../.." && pwd)
w_run() {
  local _n="$1" _body="$2" _a _canary="$sb/home-$1"
  local _unset=() _set=()
  shift 2
  mkdir -p "$sb/w-$_n/scripts" "$sb/home-$_n"
  printf '#!/usr/bin/env bash\nREPO=%q\n%s\nexit 0\n' "$w_repo" "$_body" > "$sb/w-$_n/scripts/test-k-$_n.sh"
  chmod +x "$sb/w-$_n/scripts/test-k-$_n.sh"
  # -u NAME drops a variable; NAME=value overrides a default below; CANARY=off
  # starts the runner without HIMMEL_CANARY_HOME, as a station run does.
  _a="HIMMEL_CANARY_HOME=$_canary"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u) _unset[${#_unset[@]}]="-u"; _unset[${#_unset[@]}]="$2"; shift 2 ;;
      CANARY=off) _unset[${#_unset[@]}]="-u"; _unset[${#_unset[@]}]="HIMMEL_CANARY_HOME"; _a="W_NO_CANARY=1"; shift ;;
      *) _set[${#_set[@]}]="$1"; shift ;;
    esac
  done
  w_out=$(env ${_unset[@]+"${_unset[@]}"} HOME="$sb/home-$_n" "$_a" \
    SUITE_LIVE_EXEMPT="$sb/exempt.txt" SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' \
    ${_set[@]+"${_set[@]}"} bash "$RUNNER" "$sb/w-$_n/scripts" 2>&1)
  w_rc=$?
}
# w_expect <row> <name> <path-regex> — the run failed, named the suite and the path.
w_expect() {
  if [ "$w_rc" -eq 1 ] \
    && grepq "$w_out" -E "\[LIVE-STATE\] .*test-k-$2\.sh — .*$3" \
    && grepq "$w_out" -E "\[FAIL\] .*test-k-$2\.sh"; then
    pass "$1: the suite fails and the line names it and $3"
  else
    fail "$1: expected rc=1, a [LIVE-STATE] line naming test-k-$2.sh and $3, and a [FAIL]; rc=$w_rc out: ${w_out:0:1500}"
  fi
}
w_clean() {
  if [ "$w_rc" -eq 0 ] && ! grepq "$w_out" -E '\[LIVE-STATE\]' && grepq "$w_out" -E '\[PASS\] .*test-k-'"$2"'\.sh'; then
    pass "$1: the suite passes with no [LIVE-STATE] line"
  else
    fail "$1: expected rc=0, a [PASS] and no [LIVE-STATE] line; rc=$w_rc out: ${w_out:0:1500}"
  fi
}

echo "== L12: a write into the live-shaped paths under HOME fails the suite =="
w_run l12 'mkdir -p "$HOME/.himmel/state/holds" && echo x >> "$HOME/.himmel/state/holds/events.log"'
w_expect L12 l12 '\.himmel/state/holds/events\.log'
# The station config route: himmel.conf names the handover root.
w_conf='. "$REPO/scripts/lib/load-dotenv.sh"; load_dotenv --root "${TMPDIR:-/tmp}/rst-no-root" HANDOVER_DIR >/dev/null 2>&1; [ -n "${HANDOVER_DIR:-}" ] || exit 0'
w_run l12b "$w_conf"'
mkdir -p "$HANDOVER_DIR/u" && : > "$HANDOVER_DIR/u/leaked.md"' -u HANDOVER_DIR
w_expect L12b l12b 'leaked\.md|decoy handover root'
w_run l12c 'mkdir -p "$HOME/.claude/projects" && : > "$HOME/.claude/projects/x"'
w_expect L12c l12c '\.claude/projects'
w_run l12d '[ -f "$HOME/.himmel/himmel.conf" ] || exit 0
echo "X=1" >> "$HOME/.himmel/himmel.conf"'
w_expect L12d l12d '\.himmel/himmel\.conf'
w_run l12e 'mkdir -p "$HOME/.himmel" && : > "$HOME/.himmel/x.json" && rm -f "$HOME/.himmel/x.json"
rm -f "$HOME/.claude.json"'
w_expect L12e l12e '\.himmel'
if grepq "$w_out" -E 'removed .*\.claude\.json'; then pass "L12e: a removed seed file is named"; else fail "L12e: no 'removed .claude.json' line; out: ${w_out:0:1500}"; fi
w_run l12f "$w_conf"'
rm -rf "$HANDOVER_DIR"' -u HANDOVER_DIR
w_expect L12f l12f 'removed'
w_run l12g 'mkdir -p "$HOME/.local/share/himmel/graphify" && : > "$HOME/.local/share/himmel/graphify/x"'
w_expect L12g l12g '\.local/share/himmel'
w_run l12h 'mkdir -p "$HOME/.local/state/himmel/bus" && : > "$HOME/.local/state/himmel/bus/x"'
w_expect L12h l12h '\.local/state/himmel/bus/x'
w_run l12i 'd="${XDG_STATE_HOME:-$HOME/.local/state}/himmel/bus-waker"; mkdir -p "$d" && : > "$d/x"' XDG_STATE_HOME="$sb/xdg-state"
w_expect L12i l12i '\.local/state/himmel/bus-waker/x'
if [ -z "$(ls -A "$sb/xdg-state" 2>/dev/null)" ]; then pass "L12i: the host's XDG_STATE_HOME stays empty"; else fail "L12i: the suite wrote the host XDG_STATE_HOME: $(ls -A "$sb/xdg-state")"; fi

echo "== L13: a suite that writes only under its own temp HOME passes =="
w_run l13 'HOME=$(mktemp -d "${TMPDIR:-/tmp}/rst-own-home.XXXXXX") || exit 1
mkdir -p "$HOME/.himmel/state" "$HOME/.claude" && : > "$HOME/.himmel/state/x" && : > "$HOME/.claude/y"
rm -rf "$HOME"'
w_clean L13 l13

echo "== L14: reading the decoy trips nothing =="
w_run l14 'cat "$HOME/.himmel/himmel.conf" "$HOME/.claude/settings.json" > /dev/null 2>&1; ls -A "$HOME/.claude" > /dev/null'
w_clean L14 l14

echo "== L15: three suites on two lanes: the decoy is reset, the counts include every lane once =="
mkdir -p "$sb/w-l15/scripts" "$sb/home-l15"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/w-l15/scripts/test-k-1-clean.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/w-l15/scripts/test-k-2-clean.sh"
printf '#!/usr/bin/env bash\nmkdir -p "$HOME/.himmel/state/holds" && echo x >> "$HOME/.himmel/state/holds/events.log"\nexit 0\n' > "$sb/w-l15/scripts/test-k-3-writer.sh"
chmod +x "$sb/w-l15/scripts/"*.sh
out15=$(env HOME="$sb/home-l15" HIMMEL_CANARY_HOME="$sb/home-l15" SUITE_LIVE_EXEMPT="$sb/exempt.txt" \
  SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' SUITE_JOBS=2 bash "$RUNNER" "$sb/w-l15/scripts" 2>&1)
rc15=$?
if [ "$rc15" -eq 1 ] && grepq "$out15" -E '\[LIVE-STATE\] .*test-k-3-writer\.sh — .*events\.log' \
  && ! grepq "$out15" -E '\[LIVE-STATE\] .*test-k-[12]-clean\.sh'; then
  pass "L15: only the writer is named"
else
  fail "L15: expected rc=1 and a line for the writer only; rc=$rc15 out: ${out15:0:1800}"
fi
if grepq "$out15" -x 'live-witness: on, 3 suites watched, 1 hard, 0 warn'; then
  pass "L15: the summary counts every lane once"
else
  fail "L15: no 'live-witness: on, 3 suites watched, 1 hard, 0 warn' line; out: ${out15:0:1800}"
fi
mkdir -p "$sb/w-l15b/scripts" "$sb/home-l15b"
cp "$sb/w-l15/scripts/test-k-3-writer.sh" "$sb/w-l15b/scripts/test-k-1-writer.sh"
cp "$sb/w-l15/scripts/test-k-2-clean.sh" "$sb/w-l15b/scripts/test-k-2-clean.sh"
out15b=$(env HOME="$sb/home-l15b" HIMMEL_CANARY_HOME="$sb/home-l15b" SUITE_LIVE_EXEMPT="$sb/exempt.txt" \
  SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' SUITE_JOBS=1 bash "$RUNNER" "$sb/w-l15b/scripts" 2>&1)
if grepq "$out15b" -E '\[PASS\] .*test-k-2-clean\.sh' && ! grepq "$out15b" -E '\[LIVE-STATE\] .*test-k-2-clean\.sh'; then
  pass "L15: a clean suite after the writer in the same lane passes (the decoy was reset)"
else
  fail "L15: test-k-2-clean.sh was blamed for the writer; out: ${out15b:0:1800}"
fi

echo "== L16: a clean suite pays no find; a dirty one pays one per hit root =="
mkdir -p "$sb/findbin" "$sb/w-l16c/scripts" "$sb/home-l16c"
_realfind=$(command -v find)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$sb/find.log" "$_realfind" > "$sb/findbin/find"
chmod +x "$sb/findbin/find"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/w-l16c/scripts/test-k-l16c.sh"
chmod +x "$sb/w-l16c/scripts/test-k-l16c.sh"
: > "$sb/find.log"
out16c=$(env PATH="$sb/findbin:$PATH" HOME="$sb/home-l16c" HIMMEL_CANARY_HOME="$sb/home-l16c" SUITE_LIVE_EXEMPT="$sb/exempt.txt" \
  SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' bash "$RUNNER" "$sb/w-l16c/scripts" 2>&1)
n16c=$(grep -c 'himmel-live-sentinel' "$sb/find.log")
if [ "$n16c" = 0 ] && grepq "$out16c" -E '^live-witness: on, '; then
  pass "L16: a clean suite leaves no find call naming the decoy"
else
  fail "L16: clean suite: $n16c find calls naming the decoy, or no live-witness line; out: ${out16c:0:1500}"
fi
: > "$sb/find.log"
out16=$(env PATH="$sb/findbin:$PATH" HOME="$sb/home-l12" HIMMEL_CANARY_HOME="$sb/home-l12" SUITE_LIVE_EXEMPT="$sb/exempt.txt" \
  SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' bash "$RUNNER" "$sb/w-l12/scripts" 2>&1)
n16=$(grep -c 'himmel-live-sentinel' "$sb/find.log")
if [ "$n16" = 1 ] && grepq "$out16" -E '^live-witness: on, '; then
  pass "L16: the one-root dirty suite leaves exactly one find call"
else
  fail "L16: dirty suite: $n16 find calls naming the decoy, or no live-witness line; out: ${out16:0:1500}"
fi

echo "== L17: an exempt line turns a hit into a WARN; a bad line aborts the run =="
mkdir -p "$sb/w-l17/scripts" "$sb/home-l17"
printf '#!/usr/bin/env bash\nmkdir -p "$HOME/.himmel/state/holds" && echo x >> "$HOME/.himmel/state/holds/events.log"\nexit 0\n' > "$sb/w-l17/scripts/test-k-l17.sh"
chmod +x "$sb/w-l17/scripts/test-k-l17.sh"
printf '# a quarantined leak\n*/test-k-l17.sh HIMMEL-1 measured\n' > "$sb/exempt-l17.txt"
out17=$(env HOME="$sb/home-l17" HIMMEL_CANARY_HOME="$sb/home-l17" SUITE_LIVE_EXEMPT="$sb/exempt-l17.txt" \
  SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' bash "$RUNNER" "$sb/w-l17/scripts" 2>&1)
rc17=$?
if [ "$rc17" -eq 0 ] && grepq "$out17" -E '\[LIVE-STATE\] WARN .*test-k-l17\.sh — .*events\.log' \
  && grepq "$out17" -E '\[PASS\] .*test-k-l17\.sh' && grepq "$out17" -x 'live-witness: on, 1 suites watched, 0 hard, 1 warn'; then
  pass "L17: an exempt suite WARNs and passes"
else
  fail "L17: expected rc=0, a WARN line, a [PASS] and '1 suites watched, 0 hard, 1 warn'; rc=$rc17 out: ${out17:0:1800}"
fi
printf '*/test-k-l17.sh measured\n' > "$sb/exempt-nokey.txt"
printf '*/test-*.sh HIMMEL-1 family\n' > "$sb/exempt-family.txt"
for _bad in nokey family; do
  rm -f "$sb/ran17"
  printf '#!/usr/bin/env bash\n: > %q\nexit 0\n' "$sb/ran17" > "$sb/w-l17/scripts/test-k-l17.sh"
  out17x=$(env HOME="$sb/home-l17" HIMMEL_CANARY_HOME="$sb/home-l17" SUITE_LIVE_EXEMPT="$sb/exempt-$_bad.txt" \
    SUITE_TIMEOUT=60 SUITE_LIVE_HARD='*' bash "$RUNNER" "$sb/w-l17/scripts" 2>&1)
  rc17x=$?
  if [ "$rc17x" -eq 2 ] && [ ! -e "$sb/ran17" ]; then
    pass "L17: a $_bad exempt line exits 2 before any suite"
  else
    fail "L17: $_bad exempt line: expected rc=2 and no suite run; rc=$rc17x ran=$([ -e "$sb/ran17" ] && echo yes || echo no) out: ${out17x:0:1200}"
  fi
done
if ! grep -q 'measurement' "$w_repo/scripts/ci/live-write-exempt.txt" 2>/dev/null; then
  pass "L17: the shipped exempt file holds no measurement line"
else
  fail "L17: scripts/ci/live-write-exempt.txt still holds a measurement line"
fi

echo "== L18: off the canary the runner leaves HOME alone and says so once =="
w_run l18 'mkdir -p "$HOME/.himmel/state/holds" && echo x >> "$HOME/.himmel/state/holds/events.log"' CANARY=off
n18=$(printf '%s\n' "$w_out" | grep -c '^live-witness: off')
if [ "$w_rc" -eq 0 ] && [ "$n18" = 1 ] && [ -f "$sb/home-l18/.himmel/state/holds/events.log" ]; then
  pass "L18: one 'live-witness: off' line, the suite wrote the caller's HOME and passed"
else
  fail "L18: expected rc=0, one off line and the caller's HOME written; rc=$w_rc off-lines=$n18 out: ${w_out:0:1500}"
fi
w_run l18b 'mkdir -p "$HOME/.himmel/state/holds" && echo x >> "$HOME/.himmel/state/holds/events.log"' HIMMEL_CANARY_HOME="$sb/other"
n18b=$(printf '%s\n' "$w_out" | grep -c '^live-witness: off')
if [ "$w_rc" -eq 0 ] && [ "$n18b" = 1 ] && [ -f "$sb/home-l18b/.himmel/state/holds/events.log" ]; then
  pass "L18b: a canary that is not HOME is off too"
else
  fail "L18b: expected rc=0, one off line and the caller's HOME written; rc=$w_rc off-lines=$n18b out: ${w_out:0:1500}"
fi

echo "== L19: a scheduler WARN and a hard witness hit tag separately in one suite =="
w_run l19 'crontab -l >/dev/null 2>&1
mkdir -p "$HOME/.himmel/state" && : > "$HOME/.himmel/state/x"' SUITE_LIVE_HARD='*/no-such-suite.sh' PATH="$sb/realbin:$PATH"
if [ "$w_rc" -eq 1 ] && grepq "$w_out" -E '\[LIVE-STATE\] WARN .*test-k-l19\.sh — scheduler call: crontab -l' \
  && grepq "$w_out" -E '\[LIVE-STATE\] [^W].*test-k-l19\.sh — wrote .*\.himmel' && grepq "$w_out" -E '\[FAIL\] .*test-k-l19\.sh'; then
  pass "L19: the scheduler line is WARN, the witness line is hard, the suite fails"
else
  fail "L19: expected rc=1, a WARN scheduler line and a hard witness line; rc=$w_rc out: ${w_out:0:1800}"
fi

echo "== L20: a shard with no suites still prints the witness line =="
mkdir -p "$sb/w-l20/scripts" "$sb/home-l20"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/w-l20/scripts/test-k-l20.sh"
chmod +x "$sb/w-l20/scripts/test-k-l20.sh"
out20=$(env HOME="$sb/home-l20" HIMMEL_CANARY_HOME="$sb/home-l20" SUITE_LIVE_EXEMPT="$sb/exempt.txt" \
  SUITE_TIMEOUT=60 bash "$RUNNER" --shard 2/2 "$sb/w-l20/scripts" 2>&1)
rc20=$?
if [ "$rc20" -eq 0 ] && grepq "$out20" -x 'live-witness: on, 0 suites watched, 0 hard, 0 warn'; then
  pass "L20: 0 suites in the shard, the zero-count line, rc 0"
else
  fail "L20: expected rc=0 and the zero-count line; rc=$rc20 out: ${out20:0:1500}"
fi

rst_tally
