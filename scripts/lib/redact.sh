# shellcheck shell=bash
# redact.sh — redact(): the secret shapes a hook must never write to disk or send off the host.
# Sourced by scripts/hooks/log-classifier-denial.sh (before a denial is logged) and
# scripts/hooks/afk-denied-to-request.sh (a command that matches any shape files nothing).
# scripts/lib/afk-sudo/afk_sudo.py ports the same shapes line by line; test-afk-sudo.sh holds
# the two to the same output.
#
# Not a full gitleaks port (that ruleset is upstream-maintained and huge) —
# a bounded set of the shapes most likely to appear in a denied command:
# GitHub/Slack/Telegram tokens, AWS keys, PEM key blocks, bearer auth headers,
# a key/secret/token/password/pass/pwd assignment of ANY value length (a short
# DB_PASS=hunter2 is exactly as sensitive as a long one), and the flag forms
# `--password X`, `--token X`, `mysql -pX`. The flag rules over-match
# (`ssh -p2222` reads as a -pX password): a false redaction costs nothing here,
# a leak does.
# ponytail: flag names are matched lowercase only (no BSD-sed `I` flag) and a
# space-separated `-p X` is not caught, upgrade: one awk pass if a real leak
# shows up.
#
# Bash 3.2-compatible.
redact() {
    printf '%s' "$1" | sed -E \
        -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
        -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
        -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED]/g' \
        -e 's/([Bb]earer) [A-Za-z0-9._-]{20,}/\1 [REDACTED]/g' \
        -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd])([\"'"'"']?[[:space:]]*[:=][[:space:]]*)\"[^\"]*\"/\1\2\"[REDACTED]\"/g' \
        -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd])([\"'"'"']?[[:space:]]*[:=][[:space:]]*)'"'"'[^'"'"']*'"'"'/\1\2'"'"'[REDACTED]'"'"'/g' \
        -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd])([\"'"'"']?[[:space:]]*[:=][[:space:]]*[\"'"'"']?)[^[:space:]\"'"'"']+/\1\2[REDACTED]/g' \
        -e 's/(--[a-z-]*(password|passwd|token|secret|api-?key)[a-z-]*)[[:space:]]+[^[:space:]-][^[:space:]]*/\1 [REDACTED]/g' \
        -e 's/(^|[[:space:]])-p[^[:space:]-][^[:space:]]*/\1-p[REDACTED]/g' \
        | awk '
            BEGIN { inkey = 0 }
            {
                line = $0
                if (!inkey && line ~ /-----BEGIN[A-Z ]*PRIVATE KEY-----/) {
                    if (line ~ /-----END[A-Z ]*PRIVATE KEY-----/) {
                        sub(/-----BEGIN[A-Z ]*PRIVATE KEY-----.*-----END[A-Z ]*PRIVATE KEY-----/, "[REDACTED-PEM]", line)
                        print line
                        next
                    }
                    sub(/-----BEGIN[A-Z ]*PRIVATE KEY-----.*/, "[REDACTED-PEM]", line)
                    print line
                    inkey = 1
                    next
                }
                if (inkey) {
                    if (line ~ /-----END[A-Z ]*PRIVATE KEY-----/) inkey = 0
                    next
                }
                print line
            }
        '
}
