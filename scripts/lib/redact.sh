# shellcheck shell=bash
# redact.sh — redact(): the secret shapes a hook must never write to disk or send off the host.
# Sourced by scripts/hooks/log-classifier-denial.sh (before a denial is logged) and
# scripts/hooks/afk-denied-to-request.sh (a command that matches any shape files nothing).
# scripts/lib/afk-sudo/afk_sudo.py ports the same shapes line by line; test-afk-sudo.sh holds
# the two to the same output.
# redact_check: reads stdin, returns 0 when no shape matches, else 10+i for the first
# shape i that does and prints `shape=<name> precision=<high|low>`. Callers spawn it as
# `bash -c '. <abs>/scripts/lib/redact.sh && redact_check'`.
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
# The sed shapes live in four index-aligned arrays (match regex, replacement, name,
# precision): redact() builds its sed argv from them and redact_check greps the same
# regexes, so the two cannot drift. The PEM block is the awk pass, the last name.
#
# Bash 3.2-compatible.
_redact_kw='([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd])'
REDACT_SHAPE_RE=(
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'AKIA[0-9A-Z]{16}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '[0-9]{8,10}:[A-Za-z0-9_-]{35}'
    '([Bb]earer) [A-Za-z0-9._-]{20,}'
    "$_redact_kw"'([\"'"'"']?[[:space:]]*[:=][[:space:]]*)\"[^\"]*\"'
    "$_redact_kw"'([\"'"'"']?[[:space:]]*[:=][[:space:]]*)'"'"'[^'"'"']*'"'"
    "$_redact_kw"'([\"'"'"']?[[:space:]]*[:=][[:space:]]*[\"'"'"']?)[^[:space:]\"'"'"']+'
    '(--[a-z-]*(password|passwd|token|secret|api-?key)[a-z-]*)[[:space:]]+[^[:space:]-][^[:space:]]*'
    '(^|[[:space:]])-p[^[:space:]-][^[:space:]]*'
)
REDACT_SHAPE_REPL=(
    '[REDACTED]'
    '[REDACTED]'
    '[REDACTED]'
    '[REDACTED]'
    '[REDACTED]'
    '[REDACTED]'
    '\1 [REDACTED]'
    '\1\2\"[REDACTED]\"'
    '\1\2'"'"'[REDACTED]'"'"
    '\1\2[REDACTED]'
    '\1 [REDACTED]'
    '\1-p[REDACTED]'
)
REDACT_SHAPE_NAMES=(gh github_pat sk_ant akia xox bot_token bearer pass_dq pass_sq pass_bare flag_secret dash_p pem)
REDACT_SHAPE_PRECISION=(high high high high high high high low low low low low high)

redact() {
    local _i=0 _args=()
    while [ "$_i" -lt "${#REDACT_SHAPE_RE[@]}" ]; do
        _args+=(-e "s/${REDACT_SHAPE_RE[$_i]}/${REDACT_SHAPE_REPL[$_i]}/g")
        _i=$((_i+1))
    done
    printf '%s' "$1" | sed -E "${_args[@]}" \
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

redact_check() {
    local _in _i=0 _rc _pem
    _in=$(cat && printf x) || return 2
    _in=${_in%x}
    while [ "$_i" -lt "${#REDACT_SHAPE_RE[@]}" ]; do
        LC_ALL=C grep -E -q -e "${REDACT_SHAPE_RE[$_i]}" 2>/dev/null <<<"$_in"
        _rc=$?
        if [ "$_rc" = 0 ]; then
            printf 'shape=%s precision=%s\n' "${REDACT_SHAPE_NAMES[$_i]}" "${REDACT_SHAPE_PRECISION[$_i]}"
            return $((10 + _i))
        fi
        [ "$_rc" = 1 ] || return 2
        _i=$((_i+1))
    done
    _pem=$(LC_ALL=C awk '/-----BEGIN[A-Z ]*PRIVATE KEY-----/ { print "y"; exit }' <<<"$_in") || return 2
    if [ "$_pem" = y ]; then
        printf 'shape=%s precision=%s\n' "${REDACT_SHAPE_NAMES[$_i]}" "${REDACT_SHAPE_PRECISION[$_i]}"
        return $((10 + _i))
    fi
    return 0
}
