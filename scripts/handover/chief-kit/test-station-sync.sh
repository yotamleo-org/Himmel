#!/usr/bin/env bash
# scripts/handover/chief-kit/test-station-sync.sh - suite for station-sync.sh,
# the post-merge step that brings the station back to main. Hermetic:
# himmel-update.sh, the template upgrader and the qmd clone are stubs (the
# SS_UPDATE / SS_UPGRADE / SS_QMD_CLONE seams); nothing here runs a real update.
#
# Cases:
#   1. usage: no source / both sources                        -> rc 2
#   2. a merged diff touching marketplace/                    -> --only marketplace and --only bypass_daemon, nothing else
#   3. jira / config-ui / qmd pin / graphify pin / unrelated paths -> the mapped steps and --only bypass_daemon only; --versions always
#   4. a behind row                                           -> STATION=BEHIND:<components> + state file
#   5. non-comment local template hunk                        -> luna_template NOT applied, hunk named
#   6. comment-only local template hunk                       -> luna_template applied
#   7. withheld edit with no diff (snapshot baseline)         -> refused, fail-closed
#   8. tracked edit in the qmd fork clone                     -> reported, never discarded
#
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/station-sync.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/ss-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
# the config_ui retry marker lives under $HOME; a developer's real one must not steer these cases
export HOME="$W/home"; mkdir -p "$HOME"
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

cat > "$W/update" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1 $2" = "--only ${SS_T_FAIL:-}" ]; then
    # the real --only layout: the step's own error first, the status table after it
    printf '%s\n' "==> config UI rebuild" "    error: bun build exploded" "==> update chain status" \
        "    jira_cli       not-attempted" "    qmd_fork       not-attempted" "    hermes         not-attempted" \
        "    luna_template  not-attempted" "    config_ui      failed         build failed" >&2
    exit 1
fi
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; grep -qw behind "$SS_T_VERSIONS" && exit 1; exit 0; fi
exit 0
EOF2
cat > "$W/upgrade" <<'EOF2'
#!/usr/bin/env bash
cat "$SS_T_DRYRUN"
EOF2
chmod +x "$W/update" "$W/upgrade"
cat > "$W/ver-current" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    luna_template  current  v0.4.73     v0.4.73
    0 behind, 0 undetermined.
EOF2
cat > "$W/ver-behind" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    luna_template  behind   v0.4.71     v0.4.73
    codex          behind   0.162.1     0.163.0     run /himmel-update to upgrade
    2 behind, 0 undetermined.
EOF2
: > "$W/dry-clean"
mkdir -p "$W/vault"
export SS_UPDATE="$W/update" SS_UPGRADE="$W/upgrade" SS_CALLS="$W/calls" SS_STATE="$W/state" \
       SS_PRIMARY="$W" SS_VAULT="$W/vault" SS_QMD_CLONE="$W/no-such-clone" SS_T_DRYRUN="$W/dry-clean"
export HIMMEL_USAGE_STORE="$W/usage-store" SS_UCALLS="$W/ucalls" SS_TCALLS="$W/tcalls"
cat > "$W/usage-compute" <<'EOF2'
#!/usr/bin/env bash
echo "usage-compute $*" >> "$SS_UCALLS"
flock -n "$SS_STATE.lock" true; echo "lock-probe rc=$?" >> "$SS_UCALLS"
[ -z "${SS_T_UOUT:-}" ] || echo "$SS_T_UOUT"
[ -z "${SS_T_USTATE:-}" ] || echo "state-during-compute: $(cat "$SS_STATE" 2>/dev/null)" >> "$SS_UCALLS"
exit "${SS_T_URC:-0}"
EOF2
cat > "$W/timeout" <<'EOF2'
#!/usr/bin/env bash
echo "timeout $*" >> "$SS_TCALLS"
shift
exec "$@"
EOF2
chmod +x "$W/usage-compute" "$W/timeout"
export SS_USAGE_COMPUTE="$W/usage-compute" SS_TIMEOUT="$W/timeout"
READTOK=ghp_READTOKEN0123456789
mkdir -p "$W/ttroot" "$W/emptyroot" "$W/tt" "$W/himmelcfg"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$W/ttroot/.env"
: > "$W/emptyroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$W/tt/gh"
export GH_READ_ENV_ROOT="$W/emptyroot" HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$W/himmelcfg"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
run() {  # run <versions file> <path>...
    : > "$SS_CALLS"; rm -f "$SS_STATE"
    export SS_T_VERSIONS="$1"; shift
    printf '%s\n' "$@" > "$W/files"
    out="$(bash "$SCRIPT" --files "$W/files" 2>&1)"; rc=$?; calls="$(cat "$SS_CALLS" 2>/dev/null)"
}

bash "$SCRIPT" >/dev/null 2>&1; check "1 no source rc" "$?" 2
bash "$SCRIPT" --files "$W/x" --pr 5 >/dev/null 2>&1; check "1 two sources rc" "$?" 2

run "$W/ver-current" marketplace/plugins/foo/skill.md
check "2 rc" "$rc" 0
contains "2 marketplace step" "$calls" "update --only marketplace"
lacks "2 no jira step" "$calls" "--only jira_cli"
contains "2 versions run" "$calls" "update --versions"
contains "2 station ok" "$out" "STATION=OK"

run "$W/ver-current" scripts/jira/src/a.ts scripts/lib/qmd-bin.sh scripts/lib/graphify-bin.sh docs/x.md
contains "3 jira" "$calls" "update --only jira_cli"
contains "3 qmd" "$calls" "update --only qmd_fork"
contains "3 graphify" "$calls" "update --only graphify"
lacks "3 no marketplace" "$calls" "--only marketplace"
run "$W/ver-current" scripts/config-ui/agui-web/src/main.tsx scripts/config-ui/server.ts
contains "3 config ui step" "$calls" "update --only config_ui"
check "3 config ui step runs once" "$(printf '%s\n' "$calls" | grep -c -- '--only config_ui')" 1
lacks "3 config ui alone runs no jira step" "$calls" "--only jira_cli"
run "$W/ver-current" docs/x.md
check "3 docs only runs no mapped step" "$(printf '%s\n' "$calls" | grep -- '--only' | grep -vc bypass_daemon)" 0
contains "3 docs only still checks versions" "$calls" "update --versions"

run "$W/ver-behind" docs/x.md
check "4 rc" "$rc" 0
contains "4 behind" "$out" "STATION=BEHIND:luna_template,codex"
check "4 state file" "$(cat "$SS_STATE")" "BEHIND:luna_template,codex"
run "$W/ver-current" docs/x.md
check "4 state cleared" "$(cat "$SS_STATE")" "ok"

cat > "$W/dry-code" <<'EOF2'
  local edits withheld (not overwritten): scripts/foo.sh (backup: none) [baseline: git]
    --- a/foo
    +++ b/foo
    -# old comment
    +echo local-patch
EOF2
SS_T_DRYRUN="$W/dry-code" run "$W/ver-behind" templates/luna-second-brain/scripts/foo.sh
lacks "5 template not applied" "$calls" "--only luna_template"
contains "5 names the file" "$out" "LOCAL-DIFF luna_template scripts/foo.sh"
contains "5 names the hunk" "$out" "echo local-patch"
contains "5 reported behind" "$out" "BEHIND:luna_template"

cat > "$W/dry-comment" <<'EOF2'
  local edits withheld (not overwritten): scripts/foo.sh (backup: none) [baseline: git]
    --- a/foo
    +++ b/foo
    -# old comment
    +# new comment
EOF2
SS_T_DRYRUN="$W/dry-comment" run "$W/ver-current" templates/luna-second-brain/scripts/foo.sh
contains "6 template applied" "$calls" "update --only luna_template"
lacks "6 no local diff" "$out" "LOCAL-DIFF"

cat > "$W/dry-snap" <<'EOF2'
  local edits withheld (not overwritten): .obsidian/app.json (backup: none) [baseline: snapshot]
    recorded at the last upgrade: sha256:abc
EOF2
SS_T_DRYRUN="$W/dry-snap" run "$W/ver-behind" templates/luna-second-brain/.obsidian/app.json
lacks "7 snapshot edit not applied" "$calls" "--only luna_template"
contains "7 names the file" "$out" "LOCAL-DIFF luna_template .obsidian/app.json"

git init -q "$W/clone" && echo a > "$W/clone/f" && git -C "$W/clone" add f \
    && git -C "$W/clone" -c user.name=t -c user.email=t@t commit -qm init && echo b > "$W/clone/f"
SS_QMD_CLONE="$W/clone" run "$W/ver-current" docs/x.md
contains "8 clone edit reported" "$out" "LOCAL-DIFF qmd_fork f"
check "8 edit kept" "$(cat "$W/clone/f")" "b"

cat > "$W/update-broken" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
[ "$1" = "--versions" ] && { echo "boom" >&2; exit 4; }
exit 0
EOF2
chmod +x "$W/update-broken"
SS_UPDATE="$W/update-broken" run "$W/ver-current" docs/x.md
contains "9 unreadable --versions is not OK" "$out" "STATION=BEHIND:unverified"
check "9 state keeps the failure" "$(cat "$SS_STATE")" "BEHIND:unverified"

cat > "$W/upgrade-broken" <<'EOF2'
#!/usr/bin/env bash
echo "partial plan"
exit 2
EOF2
chmod +x "$W/upgrade-broken"
SS_UPGRADE="$W/upgrade-broken" run "$W/ver-behind" templates/luna-second-brain/scripts/foo.sh
lacks "10 failed dry-run: template not applied" "$calls" "--only luna_template"
contains "10 failed dry-run named" "$out" "LOCAL-DIFF luna_template (upgrade.sh --dry-run) rc=2"

cat > "$W/gh-broken" <<'EOF2'
#!/usr/bin/env bash
exit 1
EOF2
chmod +x "$W/gh-broken"
rm -f "$SS_STATE"
out="$(SS_GH="$W/gh-broken" bash "$SCRIPT" --pr 7 2>&1)"
contains "11 gh failure named" "$out" "STATION=failed:gh-pr-view"
check "11 gh failure persisted for tick" "$(cat "$SS_STATE")" "BEHIND:unverified"

SS_VAULT="$W/no-such-vault" run "$W/ver-current" templates/luna-second-brain/scripts/foo.sh
lacks "12 unresolved vault: template not applied" "$calls" "--only luna_template"
contains "12 unresolved vault named" "$out" "LOCAL-DIFF luna_template (vault unresolved)"

git init -q "$W/clone2" && echo a > "$W/clone2/f" && git -C "$W/clone2" add f \
    && git -C "$W/clone2" -c user.name=t -c user.email=t@t commit -qm init \
    && git -C "$W/clone2" worktree add -q "$W/wt" 2>/dev/null && echo b > "$W/wt/f"
SS_QMD_CLONE="$W/wt" run "$W/ver-current" docs/x.md
contains "13 linked-worktree clone edit reported" "$out" "LOCAL-DIFF qmd_fork f"

cat > "$W/update-unknown" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; exit 3; fi
exit 0
EOF2
chmod +x "$W/update-unknown"
SS_UPDATE="$W/update-unknown" run "$W/ver-current" docs/x.md
contains "14 undetermined components are not OK" "$out" "STATION=BEHIND:unverified"

cat > "$W/update-failstep" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; exit 0; fi
[ "$1 $2" != "--only bypass_daemon" ] || exit 0
exit 1
EOF2
chmod +x "$W/update-failstep"
SS_UPDATE="$W/update-failstep" run "$W/ver-current" marketplace/plugins/foo/skill.md
contains "15 failed step is not OK" "$out" "STATION=BEHIND:marketplace-failed"

# a sync killed mid-run must not leave the previous `ok` standing: the state reads
# BEHIND:pending while the steps run and is overwritten at the end
cat > "$W/update-snap" <<'EOF2'
#!/usr/bin/env bash
echo "state-during $1: $(cat "$SS_STATE" 2>/dev/null)" >> "$SS_CALLS"
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; exit 0; fi
exit 0
EOF2
chmod +x "$W/update-snap"
: > "$SS_CALLS"; echo ok > "$SS_STATE"; export SS_T_VERSIONS="$W/ver-current"
printf '%s\n' marketplace/plugins/foo/skill.md > "$W/files"
SS_UPDATE="$W/update-snap" bash "$SCRIPT" --files "$W/files" >/dev/null 2>&1
snap="$(cat "$SS_CALLS")"
contains "16 pending while the step runs" "$snap" "state-during --only: BEHIND:pending"
contains "16 pending while versions run" "$snap" "state-during --versions: BEHIND:pending"
check "16 final state replaces pending" "$(cat "$SS_STATE")" "ok"

# two merges close together start two syncs: they must run one after the other, and the
# earlier run's verdict must not be the last word while the later run is still going
cat > "$W/update-slow" <<'EOF2'
#!/usr/bin/env bash
if [ "$1" = "--versions" ]; then
    echo "enter $$" >> "$SS_CALLS"; sleep 1; echo "exit $$" >> "$SS_CALLS"
    cat "$SS_T_VERSIONS"; exit 0
fi
exit 0
EOF2
chmod +x "$W/update-slow"
: > "$SS_CALLS"; rm -f "$SS_STATE"; export SS_T_VERSIONS="$W/ver-current"
printf '%s\n' marketplace/plugins/foo/skill.md > "$W/files"
SS_UPDATE="$W/update-slow" bash "$SCRIPT" --files "$W/files" >/dev/null 2>&1 &
p1=$!
SS_UPDATE="$W/update-slow" bash "$SCRIPT" --files "$W/files" >/dev/null 2>&1 &
p2=$!
wait "$p1" "$p2"
seq="$(awk '{ print $1 }' "$SS_CALLS" | paste -sd, -)"
check "17 two syncs do not overlap" "$seq" "enter,exit,enter,exit"
check "17 final state after both runs" "$(cat "$SS_STATE")" "ok"

# A merge to the bridge's import graph restarts telegram-bridge.service once,
# at most one restart per 10 minutes. The unit name is read from the real unit file.
unit="$(basename "$HERE/../../telegram/systemd/telegram-bridge.service")"
cat > "$W/systemctl" <<'EOF2'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SS_SC_CALLS"
[ "$2" = "is-enabled" ] && exit "${SS_T_ENABLED:-0}"
exit 0
EOF2
chmod +x "$W/systemctl"
export SS_SYSTEMCTL="$W/systemctl" SS_SC_CALLS="$W/sc-calls"
run_bridge() {  # run_bridge <path>...   (keeps the debounce stamp between calls)
    : > "$SS_CALLS"; rm -f "$SS_STATE"
    export SS_T_VERSIONS="$W/ver-current"
    printf '%s\n' "$@" > "$W/files"
    out="$(bash "$SCRIPT" --files "$W/files" 2>&1)"; rc=$?; sc="$(cat "$SS_SC_CALLS" 2>/dev/null)"
}
: > "$SS_SC_CALLS"; rm -f "$W/bridge-restart.ts"
run_bridge scripts/lanes/plugin-profiles.json
contains "18 lanes path restarts the bridge" "$sc" "systemctl --user restart $unit"
contains "18 step line" "$out" "STEP bridge_restart rc=0"
check "18 one restart" "$(grep -c ' restart ' "$SS_SC_CALLS")" 1
if [ -s "$W/bridge-restart.ts" ]; then echo "ok - 18 debounce stamp written"; else echo "FAIL - 18 debounce stamp written"; fails=$((fails+1)); fi
run_bridge scripts/telegram/poller.ts
check "19 second sync inside 10 min: still one restart" "$(grep -c ' restart ' "$SS_SC_CALLS")" 1
contains "19 skip names the debounce" "$out" "SKIP bridge_restart debounce"
echo 1 > "$W/bridge-restart.ts"
run_bridge scripts/lib/foo.sh
check "20 stale stamp: restarts again" "$(grep -c ' restart ' "$SS_SC_CALLS")" 2
rm -f "$W/bridge-restart.ts"; : > "$SS_SC_CALLS"
run_bridge docs/x.md scripts/handover/foo.sh
lacks "21 outside the three dirs: no restart" "$sc" " restart "
contains "21 skip names the reason" "$out" "SKIP bridge_restart no-bridge-path"
if [ ! -e "$W/bridge-restart.ts" ]; then echo "ok - 21 no stamp"; else echo "FAIL - 21 no stamp"; fails=$((fails+1)); fi
rm -f "$W/bridge-restart.ts"
run_bridge scripts/lib/qmd-bin.sh
contains "23 a scripts/lib pin path also restarts the bridge" "$sc" "systemctl --user restart $unit"
contains "23 and still runs its own step" "$(cat "$SS_CALLS")" "update --only qmd_fork"
cat > "$W/systemctl-fail" <<'EOF2'
#!/usr/bin/env bash
[ "$2" = "restart" ] && exit 1
exit 0
EOF2
chmod +x "$W/systemctl-fail"
rm -f "$W/bridge-restart.ts"
SS_SYSTEMCTL="$W/systemctl-fail" run_bridge scripts/lanes/a.json
contains "24 failed restart is reported" "$out" "STEP bridge_restart rc=1"
contains "24 failed restart is not OK" "$out" "STATION=BEHIND:bridge_restart-failed"
if [ ! -e "$W/bridge-restart.ts" ]; then echo "ok - 24 no stamp after a failed restart"; else echo "FAIL - 24 no stamp after a failed restart"; fails=$((fails+1)); fi
rm -f "$W/bridge-restart.ts"; : > "$SS_SC_CALLS"
SS_T_ENABLED=1 run_bridge scripts/lanes/a.json
lacks "22 unit not enabled: no restart" "$sc" " restart "
contains "22 skip names the reason" "$out" "SKIP bridge_restart unit-not-enabled"

mkbypass() {
    cat > "$W/$1" <<EOF2
#!/usr/bin/env bash
echo "update \$*" >> "\$SS_CALLS"
if [ "\$1 \$2" = "--only bypass_daemon" ]; then printf '%s\n' '==> bypass launch daemon' '$2'; exit $3; fi
if [ "\$1" = "--versions" ]; then cat "\$SS_T_VERSIONS"; exit 0; fi
exit 0
EOF2
    chmod +x "$W/$1"
}
mkbypass update-failbypass "    failed: systemctl --user try-restart did not run" 1
mkbypass update-inactive "    inactive: the unit is enabled but not running; start it from your shell: himmelctl bypass restart" 0
mkbypass update-notenabled "    not-enabled: bypass daemon is off, turn it on from your shell: himmelctl bypass on" 0
mkbypass update-restarted "    restarted" 0
run_ghfail() {
    : > "$SS_CALLS"; rm -f "$SS_STATE"; export SS_T_VERSIONS="$W/ver-current"
    out="$(SS_GH="$W/gh-broken" bash "$SCRIPT" --pr 5 2>&1)"; rc=$?; calls="$(cat "$SS_CALLS" 2>/dev/null)"
}
first_sync() { printf '%s\n' "$out" | sed -n 1p | grep -cE '^SYNC start=[0-9TZ:-]+ pr=none$'; }

run "$W/ver-current" scripts/station-ops/bypass-launchd.sh
contains "R1 a launcher path runs the step" "$calls" "update --only bypass_daemon"
contains "R1 launcher path: step line" "$out" "STEP bypass_daemon rc=0"
check "R1 launcher path: first line is the dated SYNC line" "$(first_sync)" 1
run "$W/ver-current" docs/x.md
contains "R1 docs only still runs the step" "$calls" "update --only bypass_daemon"
contains "R1 docs only: step line" "$out" "STEP bypass_daemon rc=0"
contains "R1 docs only: station ok" "$out" "STATION=OK"
check "R1 docs only: first line is the dated SYNC line" "$(first_sync)" 1
SS_UPDATE="$W/update-restarted" run "$W/ver-current" docs/x.md
check "R1 restarted: the step's line follows the STEP line" "$(printf '%s\n' "$out" | grep -A1 '^STEP bypass_daemon' | tail -n 1)" "    restarted"
run "$W/ver-current" marketplace/plugins/foo/skill.md scripts/jira/src/a.ts
check "R1-order bypass_daemon is the first step" "$(printf '%s\n' "$calls" | grep -- '--only' | head -n 1)" "update --only bypass_daemon"

run_ghfail
contains "R1b a failing gh still runs the step" "$calls" "update --only bypass_daemon"
contains "R1b and names the gh failure" "$out" "STATION=failed:gh-pr-view"
check "R1b current: the state reads unverified only" "$(cat "$SS_STATE")" "BEHIND:unverified"
SS_UPDATE="$W/update-inactive" run_ghfail
check "R1b inactive: the marker joins the state" "$(cat "$SS_STATE")" "BEHIND:unverified,bypass_daemon-inactive"
SS_UPDATE="$W/update-failbypass" run_ghfail
check "R1b failed: the marker joins the state" "$(cat "$SS_STATE")" "BEHIND:unverified,bypass_daemon-failed"

SS_UPDATE="$W/update-failbypass" run "$W/ver-current" docs/x.md
contains "R2a a failing step reports its rc" "$out" "STEP bypass_daemon rc=1"
contains "R2a and is not OK" "$out" "STATION=BEHIND:bypass_daemon-failed"
check "R2a state agrees" "$(cat "$SS_STATE")" "BEHIND:bypass_daemon-failed"
SS_UPDATE="$W/update-inactive" run "$W/ver-current" docs/x.md
contains "R2b an inactive unit prints its line" "$out" "    inactive: the unit is enabled but not running"
contains "R2b and is not OK" "$out" "STATION=BEHIND:bypass_daemon-inactive"
check "R2b state agrees" "$(cat "$SS_STATE")" "BEHIND:bypass_daemon-inactive"
SS_UPDATE="$W/update-notenabled" run "$W/ver-current" docs/x.md
contains "R2c an off unit prints its line" "$out" "    not-enabled: bypass daemon is off"
contains "R2c and is not flagged" "$out" "STATION=OK"

FX="$W/fx"; mkdir -p "$FX/scripts/station-ops" "$W/fxhome"
git init -q "$FX"
cp "$HERE/../../himmel-update.sh" "$FX/scripts/himmel-update.sh"
# shellcheck disable=SC2016
libs="$(sed -n 's|^\. "\$ROOT/\(.*\)"$|\1|p' "$HERE/../../himmel-update.sh")"
check "R2e the copy list is not empty" "$([ -n "$libs" ] && echo yes)" yes
while IFS= read -r lib; do mkdir -p "$FX/$(dirname "$lib")"; cp "$HERE/../../../$lib" "$FX/$lib"; done <<EOF2
$libs
EOF2
printf '#!/usr/bin/env bash\necho "inactive: the unit is enabled but not running; start it from your shell: himmelctl bypass restart"\n' > "$FX/scripts/station-ops/bypass-service.sh"
cat > "$W/update-chain" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1 $2" = "--only bypass_daemon" ]; then exec bash "$SS_T_FXROOT/scripts/himmel-update.sh" --only bypass_daemon; fi
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; exit 0; fi
exit 0
EOF2
chmod +x "$W/update-chain"
direct="$(HOME="$W/fxhome" bash "$FX/scripts/himmel-update.sh" --only bypass_daemon 2>&1)"
contains "R2e validity: the copied step prints its header" "$direct" "==> bypass launch daemon"
contains "R2e validity: and an inactive line" "$direct" "    inactive: the unit is enabled but not running"
SS_T_FXROOT="$FX" HOME="$W/fxhome" SS_UPDATE="$W/update-chain" run "$W/ver-current" docs/x.md
contains "R2e the real re-render reaches the sync" "$out" "STATION=BEHIND:bypass_daemon-inactive"
printf '#!/usr/bin/env bash\necho current\n' > "$FX/scripts/station-ops/bypass-service.sh"
direct="$(HOME="$W/fxhome" bash "$FX/scripts/himmel-update.sh" --only bypass_daemon 2>&1)"
lacks "R2e validity: a current unit prints no header" "$direct" "==> bypass launch daemon"
SS_T_FXROOT="$FX" HOME="$W/fxhome" SS_UPDATE="$W/update-chain" run "$W/ver-current" docs/x.md
contains "R2e a current unit is OK" "$out" "STATION=OK"

mkdir -p "$W/sysbin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$SYS_CALLS"\nexit 0\n' > "$W/sysbin/systemctl"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "launchctl $*" >> "$SYS_CALLS"\nexit 0\n' > "$W/sysbin/launchctl"
chmod +x "$W/sysbin/systemctl" "$W/sysbin/launchctl"
cat > "$W/update-direct" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1 $2" = "--only bypass_daemon" ]; then systemctl --user try-restart himmel-bypass-launchd.service; fi
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; exit 0; fi
exit 0
EOF2
chmod +x "$W/update-direct"
export SYS_CALLS="$W/sys.calls"; : > "$SYS_CALLS"
PATH="$W/sysbin:$PATH" SS_SYSTEMCTL="$W/sysbin/systemctl" run "$W/ver-current" scripts/station-ops/bypass-launchd.sh
contains "R3 the stubbed run completed" "$out" "STATION=OK"
lacks "R3 the sync names neither unit" "$(cat "$W/sys.calls")" "bypass-launchd"
PATH="$W/sysbin:$PATH" bash "$W/update-direct" --only bypass_daemon
contains "R3 control: a direct restart is caught by the stubs" "$(cat "$W/sys.calls")" "himmel-bypass-launchd"

# 25-28: the config_ui retry marker (a rebuild that failed, or never ran for want of bun)
CUI_MARK="$HOME/.himmel/state/config-ui-rebuild-pending"
mkdir -p "$HOME/.himmel/state"; : > "$CUI_MARK"
run "$W/ver-current" docs/x.md
contains "25 marker owed: the sync runs config_ui though the merge touched no UI path" "$calls" "update --only config_ui"
contains "25 marker still there (the stub left it): the state is not ok" "$out" "STATION=BEHIND:config_ui-failed"
check "25 state file agrees" "$(cat "$SS_STATE")" "BEHIND:config_ui-failed"
rm -f "$CUI_MARK"
run "$W/ver-current" docs/x.md
lacks "26 no marker, no UI path: no config_ui step" "$calls" "--only config_ui"
contains "26 and the station reads ok" "$out" "STATION=OK"
: > "$CUI_MARK"
SS_T_FAIL=config_ui run "$W/ver-current" scripts/config-ui/server.ts
contains "27 a failed config_ui step reports its rc" "$out" "STEP config_ui rc=1"
contains "27 and keeps the step's own error, not just the table" "$out" "config_ui:     error: bun build exploded"
contains "27 and the failed table row" "$out" "config_ui:     config_ui      failed         build failed"
lacks "27 and not the unrelated table rows" "$out" "not-attempted"
check "27 the failure is named once" "$(printf '%s\n' "$out" | grep -c 'STATION=BEHIND:config_ui-failed$')" 1
rm -f "$CUI_MARK"

: > "$SS_UCALLS"; : > "$SS_TCALLS"; rm -rf "$HIMMEL_USAGE_STORE"
run "$W/ver-current" docs/x.md
check "29 a pass runs usage-compute once" "$(grep -c '^usage-compute' "$SS_UCALLS")" 1
lacks "29 incremental: no --print, no --since" "$(cat "$SS_UCALLS")" "--print"
lacks "29 incremental: no --since" "$(cat "$SS_UCALLS")" "--since"
contains "29 bounded by its own budget" "$(cat "$SS_UCALLS")" "--budget-seconds"
check "29 under one timeout" "$(grep -c '^timeout' "$SS_TCALLS")" 1
case "$(cut -d' ' -f2 "$SS_TCALLS")" in ''|*[!0-9]*) echo "FAIL - 29 timeout duration is a plain number"; fails=$((fails+1)) ;; *) echo "ok - 29 timeout duration is a plain number" ;; esac
lacks "29 timeout has no kill flag" "$(cat "$SS_TCALLS")" " -k"
lacks "29 timeout has no kill-after" "$(cat "$SS_TCALLS")" "--kill-after"
lacks "29 timeout has no signal flag" "$(cat "$SS_TCALLS")" " -s"
contains "29 step line" "$out" "STEP usage_compute rc=0"
contains "29 station ok" "$out" "STATION=OK"

: > "$SS_UCALLS"; mkdir -p "$HIMMEL_USAGE_STORE/.lock"
run "$W/ver-current" docs/x.md
check "30 locked store: compute not started" "$(grep -c '^usage-compute' "$SS_UCALLS")" 0
contains "30 skip names the reason" "$out" "SKIP usage_compute store-locked"
contains "30 station still ok" "$out" "STATION=OK"
rm -rf "$HIMMEL_USAGE_STORE"

: > "$SS_UCALLS"
SS_T_URC=3 run "$W/ver-current" docs/x.md
check "31 sync rc" "$rc" 0
contains "31 failed compute reported" "$out" "STEP usage_compute rc=3"
contains "31 station still ok" "$out" "STATION=OK"
check "31 state still ok" "$(cat "$SS_STATE")" "ok"
SS_T_URC=124 run "$W/ver-current" docs/x.md
contains "31 timed-out compute reported" "$out" "STEP usage_compute rc=124"
contains "31 station still ok after a timeout" "$out" "STATION=OK"

SS_T_UOUT="SECRET-RECORD-CONTENT" run "$W/ver-current" docs/x.md
lacks "32 compute output is not echoed" "$out" "SECRET-RECORD-CONTENT"

: > "$SS_UCALLS"
SS_T_USTATE=1 run "$W/ver-current" docs/x.md
contains "33 state is already final when the build runs" "$(cat "$SS_UCALLS")" "state-during-compute: ok"

: > "$SS_UCALLS"
run "$W/ver-current" docs/x.md
contains "34 the sync lock is free while the build runs" "$(cat "$SS_UCALLS")" "lock-probe rc=0"

printf '#!/usr/bin/env bash\necho marketplace/plugins/foo/skill.md\n' > "$W/gh-files"
chmod +x "$W/gh-files"
TTLOG="$W/tt.log"
logn() { grep -c -E -- "$1" "$TTLOG"; }
tt_pr() {
    : > "$SS_CALLS"; : > "$TTLOG"; rm -f "$SS_STATE"
    export SS_T_VERSIONS="$W/ver-current"
    out="$(env -u SS_GH GH_READ_ENV_ROOT="$1" PATH="$W/tt:$PATH" GH_STUB_DELEGATE="$W/gh-files" GH_STUB_READ_TOKEN="$READTOK" GHLOG="$TTLOG" bash "$SCRIPT" --pr 7 2>&1)"; rc=$?
    calls="$(cat "$SS_CALLS" 2>/dev/null)"
}
GH_STUB_MAINFAIL=rate tt_pr "$W/ttroot"
check "35 main spent: the PR sync exits 0" "$rc" 0
contains "35 main spent: the PR files read returns the paths, so the marketplace step runs" "$calls" "update --only marketplace"
contains "35 main spent: the station is ok" "$out" "STATION=OK"
lacks "35 main spent: no gh-pr-view failure" "$out" "STATION=failed:gh-pr-view"
check "35 main spent: the PR read logs tok=read" "$(logn '^tok=read argv=pr view 7 --json files ')" 1
check "35 main spent: no read logs tok=main" "$(logn '^tok=main ')" 0
tt_pr "$W/emptyroot"
contains "36 control, no read token: the marketplace step runs" "$calls" "update --only marketplace"
check "36 control: the PR read logs tok=main" "$(logn '^tok=main argv=pr view 7 --json files ')" 1
check "36 control: no call logs tok=read" "$(logn '^tok=read ')" 0

HV="$W/heal-versions"
cat > "$W/ver-heal-behind" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    plugins        behind   1/2         2 declared  version drift: a
    jira_cli       behind   built       source
    hermes         behind   abc1234     def5678
    codex          behind   0.162.1     0.163.0     run /himmel-update to upgrade
    4 behind, 0 undetermined.
EOF2
cat > "$W/update-heal" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
case "$1" in
    --only)
        [ "$2" != bypass_daemon ] || [ -z "${SS_T_BYPASS:-}" ] || printf '%s\n' '==> bypass launch daemon' "$SS_T_BYPASS"
        [ "$2" != "${SS_T_FAIL:-}" ] || { printf '%s\n' "error: build exploded" >&2; exit 1; }
        c="$2"; [ "$2" != marketplace ] || c=plugins
        sed "s/^\\(    $c  *\\)behind/\\1current/" "$SS_T_VERSIONS" > "$SS_T_VERSIONS.n" && mv "$SS_T_VERSIONS.n" "$SS_T_VERSIONS"
        exit 0 ;;
    --versions) cat "$SS_T_VERSIONS"; ! grep -qw behind "$SS_T_VERSIONS"; exit ;;
esac
exit 0
EOF2
chmod +x "$W/update-heal"
mkdir -p "$W/bucket"
HEAL_STAMP="$W/station-heal.ts"; HNOW=1700000000
heal() {
    : > "$SS_CALLS"; printf '%s\n' "$1" > "$SS_STATE"
    [ -z "${2:-}" ] || cp "$2" "$HV"
    export SS_T_VERSIONS="$HV"
    out="$(SS_UPDATE="$W/update-heal" SS_HEAL_NOW="${3:-$HNOW}" bash "$SCRIPT" --heal --bucket "$W/bucket" --chief test-chief 2>&1)"; rc=$?
    calls="$(cat "$SS_CALLS" 2>/dev/null)"
}
owed_rows() { bash "$HERE/owe.sh" list --bucket "$W/bucket" | grep -c .; }

bash "$SCRIPT" --heal >/dev/null 2>&1; check "37 --heal without a bucket and chief rc" "$?" 2
bash "$SCRIPT" --heal --pr 5 --bucket "$W/bucket" --chief c >/dev/null 2>&1; check "37 --heal with --pr rc" "$?" 2

: > "$SS_UCALLS"; rm -f "$HEAL_STAMP"
heal "BEHIND:plugins,hermes,jira_cli" "$W/ver-heal-behind"
check "38 heal rc" "$rc" 0
contains "38 plugins runs the marketplace step" "$calls" "update --only marketplace"
contains "38 jira_cli runs its step" "$calls" "update --only jira_cli"
lacks "38 hermes is never healed" "$calls" "--only hermes"
lacks "38 no step for a component the state does not name" "$calls" "--only luna_template"
contains "38 the re-check runs" "$calls" "update --versions"
contains "38 the heal reports hermes and codex as still behind" "$out" "STATION=BEHIND:hermes,codex"
check "38 the state is rewritten as a sync does" "$(cat "$SS_STATE")" "BEHIND:hermes,codex"
check "38 the heal runs no usage build" "$(grep -c '^usage-compute' "$SS_UCALLS")" 0
lacks "38 and prints no usage_compute line" "$out" "usage_compute"
check "38 stamp written" "$([ -s "$HEAL_STAMP" ] && echo yes)" "yes"
check "38 --versions then shows neither healed component behind" "$(grep -cE '^ +(plugins|jira_cli) +behind' "$HV")" 0

rm -f "$HEAL_STAMP"
heal "ok" "$W/ver-current"
contains "39 an ok station is not healed" "$out" "SKIP heal not-behind"
lacks "39 and runs no step" "$calls" "--only"
check "39 and runs no re-check" "$(printf '%s\n' "$calls" | grep -c -- '--versions')" 0
check "39 the state stays ok" "$(cat "$SS_STATE")" "ok"
heal "BEHIND:codex" "$W/ver-heal-behind"
contains "39 a component with no step stays reported" "$out" "SKIP heal nothing-healable"
lacks "39 and runs no step" "$calls" "--only"
heal "BEHIND:hermes" "$W/ver-heal-behind"
contains "39 a behind hermes stays reported" "$out" "SKIP heal nothing-healable"
lacks "39 and no hermes update runs" "$calls" "--only"
heal "BEHIND:pending" "$W/ver-heal-behind"
contains "39 a sync in flight is not healed" "$out" "SKIP heal nothing-healable"
check "39 neither case stamped" "$([ -e "$HEAL_STAMP" ] && echo yes || echo no)" "no"

rm -f "$HEAL_STAMP"
heal "BEHIND:jira_cli" "$W/ver-heal-behind"
contains "40 the first heal runs" "$calls" "update --only jira_cli"
heal "BEHIND:jira_cli" "$W/ver-heal-behind" "$((HNOW + 60))"
contains "40 a heal inside the window backs off" "$out" "SKIP heal backoff"
lacks "40 and runs nothing" "$calls" "update"
check "40 and leaves the state alone" "$(cat "$SS_STATE")" "BEHIND:jira_cli"
heal "BEHIND:jira_cli" "$W/ver-heal-behind" "$((HNOW + 1801))"
contains "40 a heal after the window runs again" "$calls" "update --only jira_cli"

rm -f "$HEAL_STAMP" "$W/bucket/owed.jsonl"
SS_T_FAIL=jira_cli heal "BEHIND:jira_cli" "$W/ver-heal-behind"
contains "41 a failing step reports its rc" "$out" "STEP jira_cli rc=1"
contains "41 and the station stays behind, naming the failed step" "$out" "jira_cli-failed"
check "41 exactly one owed row" "$(owed_rows)" 1
contains "41 the row names the component" "$(bash "$HERE/owe.sh" list --bucket "$W/bucket")" "jira_cli"
contains "41 the row is a step row" "$(bash "$HERE/owe.sh" list --bucket "$W/bucket")" "step"
SS_T_FAIL=jira_cli heal "BEHIND:jira_cli" "$W/ver-heal-behind" "$((HNOW + 60))"
contains "41 the second heal inside the window backs off" "$out" "SKIP heal backoff"
lacks "41 and retries nothing" "$calls" "--only"
check "41 and adds no owed row" "$(owed_rows)" 1
SS_T_FAIL=jira_cli heal "BEHIND:jira_cli" "$W/ver-heal-behind" "$((HNOW + 1801))"
contains "41 a heal after the window retries" "$calls" "update --only jira_cli"
check "41 the same failure that day replays the one row" "$(owed_rows)" 1

rm -rf "$HEAL_STAMP"; mkdir "$HEAL_STAMP"
heal "BEHIND:jira_cli" "$W/ver-heal-behind"
contains "42 a stamp that cannot be written skips the heal" "$out" "SKIP heal no-stamp"
lacks "42 and runs no step" "$calls" "--only"
rmdir "$HEAL_STAMP"

cat > "$W/ver-heal-plugins" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    plugins        behind   1/2         2 declared  version drift: a
    1 behind, 0 undetermined.
EOF2
inactive_line="    inactive: the unit is enabled but not running; start it from your shell: himmelctl bypass restart"
rm -f "$HEAL_STAMP" "$W/bucket/owed.jsonl"
heal "BEHIND:bypass_daemon-inactive" "$W/ver-current"
contains "R2d a marker-only state runs the step" "$calls" "update --only bypass_daemon"
contains "R2d and a current unit clears the marker" "$out" "STATION=OK"
check "R2d the state reads ok" "$(cat "$SS_STATE")" "ok"

rm -f "$HEAL_STAMP"
SS_T_BYPASS="$inactive_line" heal "BEHIND:bypass_daemon-inactive" "$W/ver-current"
contains "R2d a still-stopped unit is asked again" "$calls" "update --only bypass_daemon"
contains "R2d and keeps the marker" "$out" "STATION=BEHIND:bypass_daemon-inactive"
check "R2d the state keeps the marker" "$(cat "$SS_STATE")" "BEHIND:bypass_daemon-inactive"
lacks "R2d and files no false owed row" "$out" "OWED station-heal"
check "R2d no owed row exists" "$(owed_rows)" 0

rm -f "$HEAL_STAMP"
heal "BEHIND:plugins,bypass_daemon-failed" "$W/ver-heal-plugins"
contains "R2d a failed marker beside plugins runs the bypass step" "$calls" "update --only bypass_daemon"
contains "R2d and the marketplace step" "$calls" "update --only marketplace"
check "R2d a current unit clears the failed marker" "$(cat "$SS_STATE")" "ok"

rm -f "$HEAL_STAMP"
SS_T_BYPASS="$inactive_line" heal "BEHIND:bypass_daemon-failed" "$W/ver-current"
check "R2d the marker is rewritten from the fresh output" "$(cat "$SS_STATE")" "BEHIND:bypass_daemon-inactive"

rm -f "$HEAL_STAMP" "$W/bucket/owed.jsonl"
SS_T_FAIL=bypass_daemon heal "BEHIND:bypass_daemon-inactive" "$W/ver-current"
check "R2d a failing step rewrites the marker to failed" "$(cat "$SS_STATE")" "BEHIND:bypass_daemon-failed"
check "R2d and files one owed row" "$(owed_rows)" 1

rm -f "$HEAL_STAMP"
heal "BEHIND:jira_cli" "$W/ver-heal-behind"
contains "R2d control: the heal ran" "$calls" "update --only jira_cli"
lacks "R2d control: no marker, no bypass step" "$calls" "bypass_daemon"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
