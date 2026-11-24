#!/usr/bin/env bash
set -uo pipefail
unset HANDOVER_DIR

REPO_ROOT="$(git rev-parse --show-toplevel)"
OPS=scripts/station-ops
PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bypass-service-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }

mk() {
    D="$tmp/$1"; R="$D/repo"; B="$D/bucket"; Q="$B/bypass-queue"; H="$D/home"; BIN="$D/bin"; U="$D/units"
    mkdir -p "$R/$OPS/units" "$R/scripts/himmelctl/lib" "$Q" "$H" "$BIN" "$U"
    local f
    for f in bypass-launchd.sh bypass-service.sh bypass-flag-tiers.tsv units/himmel-bypass-launchd.service units/com.himmel.bypass-launchd.plist; do
        [ -f "$REPO_ROOT/$OPS/$f" ] && cp "$REPO_ROOT/$OPS/$f" "$R/$OPS/$f"
    done
    cp "$REPO_ROOT/scripts/himmelctl/lib/bypass-flags.json" "$R/scripts/himmelctl/lib/bypass-flags.json"
    g -C "$R" init -q && g -C "$R" add -A && g -C "$R" commit -q -m seed
    cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STUB_DIR/calls"
[ "${1:-}" = --user ] && shift
verb=${1:-}; shift
case $verb in
    is-enabled) [ -e "$STUB_DIR/enabled" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
    is-active) [ -e "$STUB_DIR/active" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
    enable) touch "$STUB_DIR/enabled"; case " $* " in *" --now "*) touch "$STUB_DIR/active" ;; esac ;;
    disable) rm -f "$STUB_DIR/enabled"; case " $* " in *" --now "*) rm -f "$STUB_DIR/active" ;; esac ;;
    restart) touch "$STUB_DIR/active"; [ -z "${STUB_LOADED:-}" ] || printf '%s\n' "$STUB_LOADED" > "$STUB_Q/.loaded" ;;
    try-restart) [ -e "$STUB_DIR/active" ] || exit 0; [ -z "${STUB_LOADED:-}" ] || printf '%s\n' "$STUB_LOADED" > "$STUB_Q/.loaded" ;;
    show) echo "MainPID=4242"; echo "ActiveEnterTimestamp=Tue 2026-11-24 21:00:00 CET" ;;
esac
exit 0
STUB
    cat > "$BIN/loginctl" <<'STUB'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> "$STUB_DIR/calls"
case ${1:-} in
    enable-linger) [ -z "${STUB_LINGER_FAIL:-}" ] || { echo "Access denied" >&2; exit 1; }; touch "$STUB_DIR/linger" ;;
    show-user) [ -e "$STUB_DIR/linger" ] && echo yes || echo no ;;
esac
exit 0
STUB
    cat > "$BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$STUB_DIR/calls"
exit 0
STUB
    chmod +x "$BIN/systemctl" "$BIN/loginctl" "$BIN/launchctl"
    : > "$D/calls"
}
svc() {
    env -u CLAUDECODE HOME="$H" PATH="$BIN:$PATH" HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$U" STUB_DIR="$D" STUB_Q="$Q" \
        BYPASSD_CONFIRM_SECS=1 "$@" 2>&1
}
svc_run() { svc bash "$R/$OPS/bypass-service.sh" "$@"; }
svc_cc() {
    env CLAUDECODE=1 HOME="$H" PATH="$BIN:$PATH" HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$U" STUB_DIR="$D" STUB_Q="$Q" \
        BYPASSD_CONFIRM_SECS=1 STUB_LOADED="${STUB_LOADED:-}" bash "$R/$OPS/bypass-service.sh" "$@" 2>&1
}
cur_ids() {
    local s t r
    s=$(g -C "$R" rev-parse HEAD:$OPS/bypass-launchd.sh); t=$(g -C "$R" rev-parse HEAD:$OPS/bypass-flag-tiers.tsv)
    r=$(g -C "$R" rev-parse HEAD:scripts/himmelctl/lib/bypass-flags.json)
    printf '%s/%s/%s' "$s" "$t" "$r"
}
calls() { cat "$D/calls" 2>/dev/null; }
UNIT=himmel-bypass-launchd.service
PLIST=com.himmel.bypass-launchd.plist

echo "== the templates exist and render without a placeholder left =="
mk render
assert_eq "the systemd unit template is in the checkout" yes "$([ -f "$R/$OPS/units/$UNIT" ] && echo yes || echo no)"
assert_eq "the LaunchAgent template is in the checkout" yes "$([ -f "$R/$OPS/units/$PLIST" ] && echo yes || echo no)"
out=$(svc_run render --bucket "$B")
for want in "Restart=on-failure" "WatchdogSec=" "Type=notify" "NotifyAccess=all" "KillMode=process" "Environment=BYPASSD_SERVICE=1" \
    "--until forever" "--bucket $B" "$R/$OPS/bypass-launchd.sh" "WantedBy=default.target" "RestartPreventExitStatus=3" \
    "UnsetEnvironment=" "BYPASSD_SEND" "BYPASSD_LAUNCHER" "BYPASSD_CHILD_PASS" "BASH_ENV" "Environment=HOME=%h" "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus" "Environment=TELEGRAM_ACCESS_PATH=%h/.claude/channels/telegram/access.json" \
    "Environment=BRIDGE_ROOT=%h/.claude/handover/bridge" \
    "ExecStart=/bin/bash -p " "Environment=PATH=/usr/local/bin:/usr/bin:/bin" "Environment=LC_ALL=C" "Environment=TZ=UTC" \
    "SHELLOPTS" "BASHOPTS" "PS4" "POSIXLY_CORRECT" "LOCPATH" "GCONV_PATH"; do
    assert_contains "the rendered unit has: $want" "$want" "$out"
done
assert_absent "the rendered unit has no @ placeholder left" "@" "$out"
assert_absent "the rendered unit drops NoNewPrivileges on purpose (workers keep sudo)" "NoNewPrivileges" "$out"
assert_absent "the rendered unit's PATH has no user directory" ".local/bin" "$(printf '%s\n' "$out" | grep '^Environment=PATH=')"
assert_absent "the rendered unit's PATH has no bun directory" ".bun/bin" "$(printf '%s\n' "$out" | grep '^Environment=PATH=')"
out=$(env -u CLAUDECODE BYPASSD_SERVICE_OS=Darwin HOME="$H" PATH="$BIN:$PATH" STUB_DIR="$D" bash "$R/$OPS/bypass-service.sh" render --bucket "$B" 2>&1)
for want in "com.himmel.bypass-launchd" "RunAtLoad" "KeepAlive" "SuccessfulExit" "BYPASSD_SERVICE" "forever" "$B" "ThrottleInterval" \
    "TELEGRAM_ACCESS_PATH" "BRIDGE_ROOT" "<key>HOME</key>" "<string>-p</string>" "<key>LC_ALL</key>" "<key>TZ</key>"; do
    assert_contains "the rendered plist has: $want" "$want" "$out"
done
assert_absent "the rendered plist has no @ placeholder left" "@" "$out"
assert_absent "the rendered plist's PATH has no user directory" ".local/bin" "$(printf '%s\n' "$out" | grep -A1 '<key>PATH</key>')"

echo "== on writes the unit and turns it on; off writes the stop file and turns it off =="
mk onoff
touch "$Q/stop"
out=$(svc_run on --bucket "$B"); rc=$?
assert_eq "on exits 0" 0 "$rc"
assert_absent "on records no handover dir when the operator's shell has none" "handover_dir=" "$(cat "$H/.himmel/state/bypass-service/config" 2>/dev/null)"
assert_contains "RED B1: the rendered unit unsets HANDOVER_DIR, so the manager's value never reaches the daemon" "UnsetEnvironment=HANDOVER_DIR " "$(cat "$U/$UNIT" 2>/dev/null)"
assert_absent "RED B1: the unit pins no HANDOVER_DIR line" "HANDOVER_DIR=" "$(cat "$U/$UNIT" 2>/dev/null)"
assert_eq "on writes the unit file" yes "$([ -f "$U/$UNIT" ] && echo yes || echo no)"
assert_contains "on runs daemon-reload" "systemctl --user daemon-reload" "$(calls)"
assert_contains "on runs enable --now on the unit" "systemctl --user enable --now $UNIT" "$(calls)"
assert_contains "on enables lingering so a reboot brings it back" "loginctl enable-linger" "$(calls)"
assert_eq "on removes the stop file" no "$([ -e "$Q/stop" ] && echo yes || echo no)"
assert_contains "on remembers the bucket" "bucket=$B" "$(cat "$H/.himmel/state/bypass-service/config" 2>/dev/null)"
out=$(svc_run on); rc=$?
assert_eq "a second on, with no --bucket, reuses the remembered one and exits 0" 0 "$rc"
out=$(svc_run off); rc=$?
assert_eq "off exits 0" 0 "$rc"
assert_eq "off writes the stop file" yes "$([ -e "$Q/stop" ] && echo yes || echo no)"
assert_contains "off disables and stops the unit" "systemctl --user disable --now $UNIT" "$(calls)"
out=$(svc_run on --bucket "$B"); rc=$?
mk handover-dir
out=$(HANDOVER_DIR=/srv/handovers svc_run on --bucket "$B")
assert_contains "on records the operator's HANDOVER_DIR in the config record" "handover_dir=/srv/handovers" "$(cat "$H/.himmel/state/bypass-service/config" 2>/dev/null)"
mk lingerfail
out=$(STUB_LINGER_FAIL=1 svc_run on --bucket "$B"); rc=$?
assert_eq "on with a refused enable-linger still exits 0" 0 "$rc"
assert_contains "on tells the operator the one command to run" "loginctl enable-linger" "$out"
assert_contains "on says lingering is not enabled" "lingering is not enabled" "$out"
mk handstart
printf '#!/usr/bin/env bash\nsleep 60\n' > "$D/bypass-launchd.sh"
bash "$D/bypass-launchd.sh" & HAND=$!
ln -s "$HAND" "$Q/.lock.pid"
out=$(svc_run on --bucket "$B"); rc=$?
kill "$HAND" 2>/dev/null; wait "$HAND" 2>/dev/null
assert_eq "on with a hand-started daemon holding the lock exits 1" 1 "$rc"
assert_contains "on names the live pid" "$HAND" "$out"
assert_absent "on enables nothing while a hand-started daemon runs" "enable" "$(calls)"
mk restartverb
svc_run on --bucket "$B" >/dev/null; : > "$D/calls"
printf '%s\n' "$(cur_ids)" > "$Q/.loaded"
out=$(svc_run restart); rc=$?
assert_eq "restart (the operator's verb) exits 0" 0 "$rc"
assert_contains "restart clears a failed state first" "systemctl --user reset-failed $UNIT" "$(calls)"
assert_contains "restart restarts the unit" "systemctl --user restart $UNIT" "$(calls)"
svc_run off >/dev/null; : > "$D/calls"
out=$(svc_run restart); rc=$?
assert_eq "restart on a daemon that is off exits 2" 2 "$rc"
assert_contains "restart on a daemon that is off names the way back" "himmelctl bypass on" "$out"
assert_absent "restart on a daemon that is off restarts nothing" "restart" "$(calls)"
mk reon
svc_run on --bucket "$B" >/dev/null
: > "$D/calls"
svc_run on --bucket "$B" >/dev/null
assert_absent "a second on with an unchanged unit restarts nothing" "systemctl --user restart" "$(calls)"
printf '# edited\n' >> "$U/$UNIT"
: > "$D/calls"
svc_run on --bucket "$B" >/dev/null
assert_contains "an on that rewrites a running unit restarts it, so it runs the new unit" "systemctl --user restart $UNIT" "$(calls)"
mk twobucket
svc_run on --bucket "$B" >/dev/null
mkdir -p "$D/bucket2/bypass-queue"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$D/bypass-launchd.sh"
bash "$D/bypass-launchd.sh" & HAND2=$!
ln -s "$HAND2" "$D/bucket2/bypass-queue/.lock.pid"
: > "$D/calls"
out=$(svc_run on --bucket "$D/bucket2"); rc=$?
kill "$HAND2" 2>/dev/null; wait "$HAND2" 2>/dev/null
assert_eq "RED CR: on for another bucket, held by a hand-started daemon, exits 1 although the unit runs" 1 "$rc"
assert_absent "RED CR: and does not restart the running unit" "systemctl --user restart" "$(calls)"
assert_contains "RED CR: and keeps the remembered bucket" "bucket=$B" "$(cat "$H/.himmel/state/bypass-service/config" 2>/dev/null)"
mk mac
out=$(env -u CLAUDECODE BYPASSD_SERVICE_OS=Darwin HOME="$H" PATH="$BIN:$PATH" STUB_DIR="$D" bash "$R/$OPS/bypass-service.sh" on --bucket "$B" 2>&1)
assert_eq "macOS on writes the LaunchAgent" yes "$([ -f "$H/Library/LaunchAgents/$PLIST" ] && echo yes || echo no)"
assert_contains "macOS on bootstraps it through launchctl" "launchctl bootstrap" "$(calls)"
assert_absent "macOS on never calls systemctl" "systemctl" "$(calls)"

echo "== status reads and changes nothing =="
mk status
svc_run on --bucket "$B" >/dev/null
printf '%s\n' "$(cur_ids)" > "$Q/.loaded"; touch "$Q/.heartbeat"
: > "$D/calls"
out=$(svc_run status); rc=$?
assert_eq "status of a running current daemon exits 0" 0 "$rc"
for want in "enabled: yes" "active: yes" "linger: yes" "code: current" "unit: current" "stop file: no" "heartbeat:"; do
    assert_contains "status prints: $want" "$want" "$out"
done
for verb in enable disable restart start stop daemon-reload enable-linger bootstrap kickstart; do
    assert_absent "status never runs $verb" " $verb" "$(calls)"
done
printf 'aaaaaaaaaaaa/bbbbbbbbbbbb/cccccccccccc\n' > "$Q/.loaded"
assert_contains "status says STALE when the loaded ids differ from the checkout" "code: STALE" "$(svc_run status)"
printf '# edited\n' >> "$U/$UNIT"
assert_contains "status says the unit is STALE against the template" "unit: STALE" "$(svc_run status)"
assert_contains "and names himmelctl bypass on" "himmelctl bypass on" "$(svc_run status)"

echo "== a Claude session cannot turn the unit on, off or restart it; status still works =="
mk claude
for verb in on off restart; do
    out=$(svc_cc "$verb" --bucket "$B"); rc=$?
    assert_eq "$verb under CLAUDECODE exits 2" 2 "$rc"
    assert_contains "$verb under CLAUDECODE says it refuses" "refusing" "$out"
done
assert_eq "the refused verbs wrote no unit file" no "$([ -e "$U/$UNIT" ] && echo yes || echo no)"
assert_eq "the refused verbs ran no service manager command" "" "$(calls)"
assert_contains "status under CLAUDECODE still answers" "enabled:" "$(svc_cc status)"

echo "== restart-if-changed restarts only an enabled unit whose script bytes changed (also under CLAUDECODE) =="
mk rc
svc_run on --bucket "$B" >/dev/null
UNIT_SUM=$(cksum < "$U/$UNIT")
printf 'aaaaaaaaaaaa/bbbbbbbbbbbb/cccccccccccc\n' > "$Q/.loaded"
: > "$D/calls"
out=$(STUB_LOADED=$(cur_ids) svc_cc restart-if-changed); rc=$?
assert_eq "an enabled unit with changed ids: exit 0" 0 "$rc"
assert_contains "it says restarted" "restarted" "$out"
assert_eq "it try-restarted the unit exactly once" 1 "$(grep -c "systemctl --user try-restart $UNIT" "$D/calls")"
assert_eq "the service-manager verbs it ran are only is-enabled, is-active, show and try-restart" "" \
    "$(awk '{print $3}' "$D/calls" | sort -u | grep -v -x -e is-enabled -e is-active -e show -e try-restart)"
for verb in enable daemon-reload link edit set-environment import-environment disable reset-failed; do
    assert_absent "the restart path never runs $verb" "systemctl --user $verb" "$(calls)"
done
assert_absent "the restart path never touches lingering" "enable-linger" "$(calls)"
assert_eq "the unit file is byte-identical after the restart" "$UNIT_SUM" "$(cksum < "$U/$UNIT")"
printf '%s\n' "$(cur_ids)" > "$Q/.loaded"; : > "$D/calls"
out=$(svc_cc restart-if-changed); rc=$?
assert_contains "unchanged ids: says current" "current" "$out"
assert_absent "unchanged ids: no restart" "restart" "$(calls)"
printf 'aaaaaaaaaaaa/bbbbbbbbbbbb/cccccccccccc\n' > "$Q/.loaded"; : > "$D/calls"
out=$(svc_cc restart-if-changed --check)
assert_contains "--check says it would restart" "would restart" "$out"
assert_absent "--check restarts nothing" "restart" "$(calls)"
out=$(svc_cc restart-if-changed); rc=$?
assert_eq "a restart that does not load the new code exits 1" 1 "$rc"
assert_contains "and says so" "did not" "$out"
rm -f "$Q/.loaded"; : > "$D/calls"
out=$(STUB_LOADED=$(cur_ids) svc_cc restart-if-changed)
assert_contains "a missing .loaded counts as changed" "restarted" "$out"
printf 'aaaaaaaaaaaa/bbbbbbbbbbbb/cccccccccccc\n' > "$Q/.loaded"
rm -f "$D/active"; : > "$D/calls"
out=$(svc_cc restart-if-changed); rc=$?
assert_eq "an enabled but stopped unit: exit 0" 0 "$rc"
assert_contains "an enabled but stopped unit: says inactive and names the operator's command" "himmelctl bypass restart" "$out"
assert_absent "an enabled but stopped unit is never started by the update" "restart" "$(calls)"
assert_eq "and stays stopped" no "$([ -e "$D/active" ] && echo yes || echo no)"
touch "$D/active"
rm -f "$D/enabled"; : > "$D/calls"
out=$(svc_cc restart-if-changed); rc=$?
assert_eq "a disabled unit: exit 0" 0 "$rc"
assert_contains "a disabled unit: names the one command" "himmelctl bypass on" "$out"
assert_absent "a disabled unit is never restarted" "restart" "$(calls)"
mk nocfg
out=$(svc_cc restart-if-changed); rc=$?
assert_eq "no config record: exit 0" 0 "$rc"
assert_contains "no config record: names the one command" "himmelctl bypass on" "$out"
assert_absent "no config record: nothing run" "systemctl --user restart" "$(calls)"
out=$(env -u CLAUDECODE BYPASSD_SERVICE_OS=Darwin HOME="$H" PATH=/usr/bin:/bin bash "$R/$OPS/bypass-service.sh" restart-if-changed 2>&1); rc=$?
assert_eq "RED m1: no config record on a host with no service manager: exit 0" 0 "$rc"
assert_contains "RED m1: and names the one command, no manager probe" "himmelctl bypass on" "$out"

echo
echo "bypass-service: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
