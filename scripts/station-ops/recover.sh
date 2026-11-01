#!/usr/bin/env bash
# recover.sh - the user-side half of the reboot-recover station op.
# Run by the user unit himmel-recover.service (installed by reboot-recover.sh) at the operator's login. Acts only
# when root armed a marker (/var/lib/himmel/reboot-recover.json) for THIS user, and only once per arming:
#   1. checks the services (default telegram-bridge.service; HIMMEL_RECOVER_SERVICES overrides), starting one that is down
#   2. verifies the Telegram bridge (<repo>/scripts/telegram/restart-bridge.sh status)
#   3. re-arms the chief from the marker's handover doc (<repo>/scripts/handover/arm-resume.sh --handover DOC --force --time now+2min)
#   4. sends a one-message status through the bridge bot (token and operator id as afk-run reads them), if both exist
# With no marker, a marker for another user, or an arming already recovered: prints why and does nothing (exit 0).
# Exit 0 normally; 1 when the marker is unreadable or a step the marker asked for failed (the status still goes out).
# Env (test seams, all optional): HIMMEL_RECOVER_ROOT (path prefix for /var/lib/himmel and /etc/himmel),
# HIMMEL_RECOVER_STATE (state dir), TELEGRAM_ENV, AFK_TELEGRAM_API.
set -u
RR=${HIMMEL_RECOVER_ROOT:-}
marker="$RR/var/lib/himmel/reboot-recover.json"
state_dir=${HIMMEL_RECOVER_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/himmel}
done_file="$state_dir/recover-done"

if [ ! -f "$marker" ]; then echo "recover: no marker, nothing to do"; exit 0; fi
mkdir -p "$state_dir" 2>/dev/null && [ -w "$state_dir" ] || { echo "recover: cannot record completion in $state_dir; not recovering" >&2; exit 1; }
exec 9> "$state_dir/recover.lock"
flock -n 9 || { echo "recover: already running; nothing to do"; exit 0; } # gnu-ok: Linux only # prim-ok: a user-side Linux unit, sources no libs
fields=$(python3 -I -c 'import json, sys
m = json.load(open(sys.argv[1]))
print("\n".join(str(m[k]) for k in ("user", "doc", "repo", "armed_at")))' "$marker" 2>/dev/null) || { echo "recover: the marker $marker is unreadable" >&2; exit 1; }
{ read -r m_user; read -r m_doc; read -r m_repo; read -r m_armed; } <<< "$fields"
if [ "$m_user" != "$(id -un)" ]; then echo "recover: the marker is for $m_user, not $(id -un); nothing to do"; exit 0; fi
if [ -f "$done_file" ] && [ "$(cat "$done_file")" = "$m_armed" ]; then echo "recover: this arming was already recovered; nothing to do"; exit 0; fi

rc=0
svc_report=''
for svc in ${HIMMEL_RECOVER_SERVICES:-telegram-bridge.service}; do
    if systemctl --user is-active --quiet "$svc"; then svc_report="$svc_report $svc=up"
    else
        systemctl --user start "$svc" >/dev/null 2>&1
        sleep 1
        if systemctl --user is-active --quiet "$svc"; then svc_report="$svc_report $svc=started"
        else svc_report="$svc_report $svc=DOWN"; rc=1; fi
    fi
done

if bash "$m_repo/scripts/telegram/restart-bridge.sh" status --repo "$m_repo" >/dev/null 2>&1; then bridge=up
else bridge=DOWN; rc=1; fi

when=$(date -d '+2 minutes' +%H:%M) # gnu-ok: Linux only # prim-ok: a user-side Linux unit, sources no libs
if [ -f "$m_doc" ] && out=$(bash "$m_repo/scripts/handover/arm-resume.sh" --handover "$m_doc" --force --time "$when" 2>&1); then
    chief="re-armed from $(basename "$m_doc") at $when"
else
    chief="NOT re-armed from $(basename "$m_doc"): ${out:-no such doc}"; chief=${chief//$'\n'/ }; chief=${chief:0:200}; rc=1
fi
printf '%s\n' "$m_armed" > "$done_file" || { echo "recover: cannot record completion in $done_file" >&2; rc=1; }

status="reboot recovery on $(hostname -s): services$svc_report; bridge $bridge; chief $chief"
echo "recover: $status"

env_file=${TELEGRAM_ENV:-$HOME/.claude/channels/telegram/.env}
chat=$(python3 -I -c 'import json, sys
print(int(json.load(open(sys.argv[1])).get("operator_id") or 0) or "")' "$RR/etc/himmel/afk-sudo.json" 2>/dev/null)
token=$(sed -n 's/^TELEGRAM_BOT_TOKEN[[:space:]]*=[[:space:]]*//p' "$env_file" 2>/dev/null | tr -d '"'"'"' \r' | grep -m1 .)
if [ -n "$chat" ] && [ -n "$token" ]; then
    printf 'url = "%s/bot%s/sendMessage"\n' "${AFK_TELEGRAM_API:-https://api.telegram.org}" "$token" \
        | curl -sS -m 10 -o /dev/null -K - --data-urlencode "chat_id=$chat" --data-urlencode "text=$status" >/dev/null \
        || echo "recover: the Telegram status could not be sent" >&2
else
    echo "recover: no bridge token or operator id; status not sent" >&2
fi
exit $rc
