#!/usr/bin/env bash
# Suite: every slash command the vault template's manual names is provided by a
# himmel plugin. An agent in an adopter vault follows the manual literally, so a
# command no plugin provides sends it to a dead end.
#
# Platform guard (posix-bash): pure POSIX bash 3.2+ plus awk/find/grep/sed/mktemp.
#
# Usage: bash scripts/docs/test-vault-manual-commands.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TPL="$ROOT/templates/luna-second-brain"

pass=0
fail=0
ok() { echo "ok: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

named_commands() {
    awk '{
        s = " " $0
        while (match(s, /[ \t`(]\/[a-z]([a-z0-9-]*[a-z0-9])?/)) {
            name = substr(s, RSTART + 1, RLENGTH - 1)
            s = substr(s, RSTART + RLENGTH)
            if (s !~ /^[a-zA-Z0-9\/._-]/) print NR ":" name
        }
    }' "$1"
}

provided() {
    local f
    for f in "$ROOT"/marketplace/plugins/*/commands/"$1".md \
             "$ROOT"/marketplace/plugins/*/skills/"$1"/SKILL.md \
             "$ROOT"/plugins/*/commands/"$1".md \
             "$ROOT"/plugins/*/skills/"$1"/SKILL.md; do
        [ -f "$f" ] && return 0
    done
    return 1
}

dead_commands() {
    local f hit hits
    for f in "$@"; do
        if ! { [ -f "$f" ] && [ -r "$f" ] && hits="$(named_commands "$f")"; }; then
            echo "${f#"$ROOT"/}: missing or unreadable"
            continue
        fi
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            provided "${hit#*:/}" || echo "${f#"$ROOT"/}:${hit%%:*}: ${hit#*:}"
        done <<EOF
$hits
EOF
    done
}

dead="$(
    dead_commands "$TPL/_CLAUDE.md" "$TPL/AGENTS.md"
    if ! docs="$(find -L "$TPL/docs" -type f -name '*.md')" || [ -z "$docs" ]; then
        echo "templates/luna-second-brain/docs: no reference file could be listed"
    fi
    while IFS= read -r f; do
        [ -n "$f" ] && dead_commands "$f"
    done <<EOF
$docs
EOF
)"
if [ -z "$dead" ]; then
    ok "the vault manual names only commands a plugin provides"
else
    bad "the vault manual names commands no plugin provides:"
    printf '%s\n' "$dead" | sed 's/^/  /' >&2
fi

if control="$(named_commands "$TPL/_CLAUDE.md")" \
    && [ "$(printf '%s\n' "$control" | grep -c ':/contra$')" -gt 0 ] && provided contra; then
    ok "control: /contra is named in _CLAUDE.md and provided"
else
    bad "control: /contra is not named in _CLAUDE.md or no plugin provides it"
fi

fx="$(mktemp "${TMPDIR:-/tmp}/vault-manual-cmds.XXXXXX")" || exit 1
trap 'rm -f "$fx"' EXIT
cat > "$fx" <<'EOF'
Run `/contra` daily.
Then /contra /not-a-real-command on one line.
See docs/luna and ~/.local/share and /usr/bin/env.
EOF
got="$(dead_commands "$fx")"
if [ "$got" = "$fx:2: /not-a-real-command" ]; then
    ok "fixture: only /not-a-real-command is flagged"
else
    bad "fixture: expected only /not-a-real-command flagged, got: $got"
fi
missing="$(dead_commands "$fx.absent" "$TPL/docs")"
if [ "$missing" = "$fx.absent: missing or unreadable
templates/luna-second-brain/docs: missing or unreadable" ]; then
    ok "fixture: a missing manual file and a directory are reported"
else
    bad "fixture: a missing manual file or a directory was not reported, got: $missing"
fi

echo "vault-manual-commands: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
