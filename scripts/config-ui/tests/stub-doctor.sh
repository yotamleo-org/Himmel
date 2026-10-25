#!/bin/sh
# Test seam HIMMEL_REPORT_DOCTOR for the Setup page's Verify step: records its argv and the state dir it was given,
# then prints the doctor's --json rows. $STUB_LEAK is planted in a row's message and remedy and on stderr;
# $STUB_SLEEP holds the run back (seconds).
printf '%s\n' "$*" >> "$STUB_ARGV"
printf '%s\n' "${HIMMEL_DOCTOR_STATE_DIR:-}" >> "$STUB_ARGV.state"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
printf 'doctor stderr %s\n' "${STUB_LEAK:-}" >&2
printf '%s\n' '{"sev":"OK","id":"C1","msg":"guardrail hooks wired","remedy":""}'
printf '%s\n' '{"sev":"OK","id":"C2","msg":"node resolves","remedy":""}'
printf '%s\n' '{"sev":"INFO","id":"C3","msg":"no cron job armed","remedy":""}'
printf '%s\n' "{\"sev\":\"WARN\",\"id\":\"C4\",\"msg\":\"token ${STUB_LEAK:-none} expires soon\",\"remedy\":\"rotate it: ${STUB_LEAK:-none}\"}"
printf '%s\n' '{"sev":"FAIL","id":"C5","msg":"qmd index is missing","remedy":"run qmd update"}'
exit 1
