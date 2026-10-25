#!/bin/sh
# Test seam HIMMEL_REPORT_DOCTOR for the Setup page's Verify step: records its argv and the state dir it was given,
# then prints the doctor's --json rows. $STUB_LEAK is planted in a row's message and remedy and on stderr;
# $STUB_SLEEP holds the run back (seconds).
printf '%s\n' "$*" >> "$STUB_ARGV"
printf '%s\n' "${HIMMEL_DOCTOR_STATE_DIR:-}" >> "$STUB_ARGV.state"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
printf 'doctor stderr %s\n' "${STUB_LEAK:-}" >&2
printf '%s\n' '{"sev":"OK","id":"C1","msg":"guardrail hooks wired","remedy":""}'
# STUB_CRASH: dies after one OK row, before its Summary line.
if [ -n "${STUB_CRASH:-}" ]; then exit 2; fi
printf '%s\n' '{"sev":"OK","id":"C2","msg":"node resolves","remedy":""}'
printf '%s\n' '{"sev":"INFO","id":"C3","msg":"no cron job armed","remedy":""}'
printf '%s\n' "{\"sev\":\"WARN\",\"id\":\"C4\",\"msg\":\"token ${STUB_LEAK:-none} expires soon\",\"remedy\":\"rotate it: ${STUB_LEAK:-none}\"}"
printf '%s\n' '{"sev":"FAIL","id":"C5","msg":"qmd index is missing","remedy":"run qmd update"}'
printf 'Summary: 1 FAIL  1 WARN  1 INFO\n' >&2
# the doctor exits 1 exactly when a FAIL row was printed; STUB_RC forces another code
exit "${STUB_RC:-1}"
