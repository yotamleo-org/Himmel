#!/usr/bin/env bash
# shellcheck disable=SC2154  # failures is set by the sourced testlib
# Usage: bash scripts/test-himmel-doctor-b.sh
set -uo pipefail
# shellcheck source=tests/testlib-himmel-doctor.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-himmel-doctor.sh"

# ── C30: telegram-bridge liveness ───────────────────────────────
# check_c30 must never touch the REAL telegram-bridge.service -- every
# case below points HIMMEL_DOCTOR_SYSTEMCTL at a fake binary or a nonexistent
# path, never at the real "systemctl" on PATH.

echo "== C30: unit enabled, active, live MainPID -> OK naming the pid and NRestarts =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 live: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled "$$" 2
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F "pid $$" && grepq "$out" -F '2 restart'; then
    pass "C30 -> OK, names pid $$ and 2 restarts"
else
    fail "C30 live -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (CR round 1 E1): unit enabled-runtime, active, live MainPID -> STILL OK naming the pid (same as permanent 'enabled') =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 enabled-runtime: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabledruntime "$$" 0
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F "pid $$"; then
    pass "C30 -> OK, enabled-runtime names pid $$ (not misread as 'no unit installed')"
else
    fail "C30 enabled-runtime -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30: unit enabled but MainPID=0 -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 mainpid-zero: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled 0 3
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C30-bridge-liveness' && grepq "$out" -F 'MainPID=0'; then
    pass "C30 -> WARN (MainPID=0, armed but not running)"
else
    fail "C30 mainpid-zero -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30: unit enabled, MainPID names a pid that is NOT alive -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 dead-pid: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
# A guaranteed-dead pid: spawn a trivial child, reap it, then CONFIRM with
# kill -0 that the pid is actually gone (never assume a bare high number is
# unused -- pid reuse is a real risk, so this verifies rather than guesses).
dead_pid=""
for _try in 1 2 3 4 5; do
    ( exit 0 ) & _cand=$!
    wait "$_cand" 2>/dev/null
    if ! kill -0 "$_cand" 2>/dev/null; then dead_pid="$_cand"; break; fi
done
if [ -z "$dead_pid" ]; then
    fail "C30 dead-pid: could not obtain a confirmed-dead pid after 5 tries"
else
    fake_systemctl "$t/probe" enabled "$dead_pid" 1
    out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C30-bridge-liveness' && grepq "$out" -F "MainPID=$dead_pid"; then
        pass "C30 -> WARN (MainPID $dead_pid is enabled but the pid is dead)"
    else
        fail "C30 dead-pid -> $(printf '%s' "$out" | grep C30)"
    fi
fi
rm -rf "$t"

echo "== C30 (CR round 2): unit enabled, but the MainPID show query FAILS -> INFO/undetermined, must NEVER read as MainPID=0/WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 mainpid-query-fails: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled FAIL 0
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C30-bridge-liveness' && grepq "$out" -F 'MainPID query failed' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'MainPID=0'; then
    pass "C30 -> INFO (MainPID query failure never read as MainPID=0/armed-but-not-running)"
else
    fail "C30 mainpid-query-fails -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (CR round 3, finding 2): unit enabled, MainPID query SUCCEEDS but returns EMPTY -> INFO/undetermined, must NEVER read as a live MainPID=0/WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 mainpid-empty-success: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled EMPTY 0
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C30-bridge-liveness' && grepq "$out" -F 'unreadable value' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'MainPID=0'; then
    pass "C30 -> INFO (a SUCCESSFUL query that returned no value is undetermined, never a false MainPID=0/armed-but-not-running)"
else
    fail "C30 mainpid-empty-success -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

# The "other direction" for this finding -- a SUCCESSFUL query that returns
# a literal numeric "0" must STILL WARN, unlike the unreadable-value case
# above -- is already covered by the pre-existing "unit enabled but
# MainPID=0 -> WARN" row further up this file; no need to duplicate it here.

echo "== C30 (CR round 2): unit enabled, live MainPID, but the NRestarts show query FAILS -> STILL OK (liveness known), restart count reported unknown =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 nrestarts-query-fails: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled "$$" FAIL
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F "pid $$" && grepq "$out" -F 'restart count unknown' && ! grepq "$out" -F '0 restart' && ! grepq "$out" 'WARN C30-bridge-liveness'; then
    pass "C30 -> OK, pid $$ reported, NRestarts degraded to unknown rather than falsely claiming 0"
else
    fail "C30 nrestarts-query-fails -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (item 4, CR round 3): unit enabled, live MainPID, NRestarts show query SUCCEEDS but returns a non-numeric value -> STILL OK, wording must not name a query FAILURE that never happened =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 nrestarts-nonnumeric-success: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" enabled "$$" EMPTY
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F "pid $$" && grepq "$out" -F 'no usable restart count' && ! grepq "$out" -F 'NRestarts query failed' && ! grepq "$out" 'WARN C30-bridge-liveness'; then
    pass "C30 -> OK, pid $$ reported, a SUCCESSFUL-but-unreadable NRestarts is worded distinctly from a query FAILURE that did not happen"
else
    fail "C30 nrestarts-nonnumeric-success -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30: no unit installed on this host (systemctl present, is-enabled -> not-found) -> OK, says NOT INSTALLED, never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 no-unit: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" notfound
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F 'no telegram-bridge.service installed' && ! grepq "$out" -F 'installed but not enabled' && ! grepq "$out" 'WARN C30-bridge-liveness'; then
    pass "C30 -> OK, says NOT installed (never a WARN)"
else
    fail "C30 no-unit -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (CR round 1 E2): unit INSTALLED but disabled (not not-found) -> OK, but the message must say INSTALLED-not-enabled, never the not-found wording =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 installed-disabled: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" disabled
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C30-bridge-liveness' && grepq "$out" -F 'installed but not enabled' && ! grepq "$out" -F 'no telegram-bridge.service installed' && ! grepq "$out" 'WARN C30-bridge-liveness'; then
    pass "C30 -> OK, distinctly says INSTALLED-but-disabled (never the not-found wording)"
else
    fail "C30 installed-disabled -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (CR round 1 E5): systemctl present but the user bus is unreachable (this station's real wording) -> INFO, NEVER read as absent/disabled =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 bus-unreachable: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" busfail
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C30-bridge-liveness' && grepq "$out" -F 'bus unreachable' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'installed but not enabled'; then
    pass "C30 -> INFO (bus-unreachable skipped cleanly, never misread as installed-but-disabled)"
else
    fail "C30 bus-unreachable -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (CR round 1 E5): same, but the OLDER systemd bus-failure wording -> also INFO, never misread =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 bus-unreachable-old: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" busfailold
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C30-bridge-liveness' && grepq "$out" -F 'bus unreachable' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'installed but not enabled'; then
    pass "C30 -> INFO (older bus-unreachable wording also skipped cleanly)"
else
    fail "C30 bus-unreachable-old -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

echo "== C30 (item 3, CR round 3): systemctl absent entirely -> OK, wording scoped to SYSTEMD persistence, never a whole-host absence claim (a Windows scheduled task is C24's concern, not this check's) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 no-systemctl: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/no-such-systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if { grepq "$out" 'OK   C30-bridge-liveness' || grepq "$out" 'INFO C30-bridge-liveness'; } \
   && ! grepq "$out" 'WARN C30-bridge-liveness' \
   && grepq "$out" -F 'systemd-unit bridge persistence' \
   && ! grepq "$out" -F 'no bridge persistence possible here'; then
    pass "C30 -> OK/INFO (no systemctl on this host, wording scoped to systemd — never claims no persistence is possible at all)"
else
    fail "C30 no-systemctl -> $(printf '%s' "$out" | grep C30)"
fi
rm -rf "$t"

# ── C31: codex still wires the dropped tokensave server ────────
# tokensave was evaluated and dropped (it lost to plain Grep+Read on every
# measured op). The finding is now inverted from the old check:
# an ENABLED [mcp_servers.tokensave] table in the codex config is itself the
# WARN, and the remedy is to remove it by hand. One seam: CODEX_HOME (codex's
# OWN env var, not a test-only invention) selects the config file. THIS
# station may or may not wire tokensave, so the WARN row is not observable
# here live: every case below drives it from a stub config. The real
# ~/.codex/config.toml is never mutated by this suite.
#
# write_codex_config <dir> <mode> — writes <dir>/config.toml.
#   wired      the table shape read off this station's REAL ~/.codex/config.toml
#              (verified 2026-09-06 — `args` first, then an absolute `command`),
#              surrounded by the same kind of neighbouring [mcp_servers.*] and
#              per-tool sub-tables a real wired config carries. The point of
#              copying the real shape is that the parser must not be validated
#              against a wording only this suite and the parser agree on.
#   wired-comment  same as wired but with a trailing TOML comment on the
#              parent-table header line (`[mcp_servers.tokensave] # ...`) —
#              a valid TOML header, still wired.
#   subtables  ONLY per-tool [mcp_servers.tokensave.tools.*] tables and NO
#              parent table. The real config carries 80+ of these, and they
#              declare no `command` — codex spawns nothing from them, so this
#              is NOT wired.
#   commented  the parent table present but commented out — also not wired.
#   unwired    a real-shaped config wiring a DIFFERENT MCP server only.
#   wired-disabled  the parent table carries `enabled = false` in its own
#              body, followed by the same per-tool sub-tables `wired` emits
#              — proves the body scan still stops at the next table header.
#   wired-disabled-large  same as wired-disabled, but with several THOUSAND
#              filler key lines between `enabled = false` and the next table
#              header. This size is the entire point (regression
#              guard): `enabled = false` lands on line 4 of the body while a
#              large remainder is still unwritten, which is exactly the
#              shape that turns a `printf | grep -q` pipeline's SUCCESSFUL
#              early-exit match into a pipefail failure via SIGPIPE. Do not
#              "simplify" this down to a small fixture — that silently
#              deletes the regression coverage.
#   wired-subtable-disabled  the parent table is enabled (no `enabled` key),
#              but a per-tool sub-table carries its OWN `enabled = false` —
#              negative control: that must NOT read as the parent disabled.
#   wired-quoted-key  same as `wired` but the header spells the key as the
#              TOML literal-string form `[mcp_servers.'tokensave']`.
#   wired-spaced-dot  same as `wired` but the header has whitespace around
#              the dotted-key separator: `[mcp_servers . tokensave]`.
#   wired-spaced-brackets  same as `wired` but with whitespace immediately
#              inside both the opening and closing brackets:
#              `[ mcp_servers.tokensave ]`.
#   wired-quoted-first  same as `wired` but the FIRST segment is a
#              basic-string key: `["mcp_servers".tokensave]`.
#   wired-pathological  same as `wired` but combines several dimensions at
#              once — whitespace inside both brackets, a quoted first
#              segment, a literal-string second segment, and a trailing
#              comment: `[ "mcp_servers" . 'tokensave' ]  # local`.
#   wired-disabled-quoted-basic  same as `wired-disabled` but the disabled
#              key is spelled as the TOML basic-string form `"enabled"`.
#   wired-disabled-quoted-literal  same as `wired-disabled` but the disabled
#              key is spelled as the TOML literal-string form `'enabled'`.
#   wired-disabled-string  same as `wired-disabled` but the VALUE is the TOML
#              string `"false"`, not the boolean `false` — negative control:
#              only the KEY spelling is widened, never the value, so this
#              must still read as wired/enabled (WARN), never disabled.
write_codex_config() {
    local dir="$1" mode="$2"
    mkdir -p "$dir"
    cat > "$dir/config.toml" <<'TOML'
model = "gpt-5.1-codex-max"

[mcp_servers.graphify]
args = ["mcp"]
command = "/home/example/.local/bin/graphify"
TOML
    case "$mode" in
        wired)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-comment)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave] # local server
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        subtables)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        commented)
            cat >> "$dir/config.toml" <<'TOML'

# [mcp_servers.tokensave]
# args = ["serve"]
# command = "/home/example/.local/bin/tokensave"
TOML
            ;;
        unwired) : ;;
        wired-disabled)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"
enabled = false

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-disabled-large)
            {
                cat <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"
enabled = false
TOML
                seq 1 5000 | sed 's/^/filler_key_/; s/$/ = "x"/'
                cat <<'TOML'

[mcp_servers.other]
command = "/home/example/.local/bin/other"
TOML
            } >> "$dir/config.toml"
            ;;
        wired-subtable-disabled)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"
enabled = false

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-quoted-key)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.'tokensave']
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-spaced-dot)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers . tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-spaced-brackets)
            cat >> "$dir/config.toml" <<'TOML'

[ mcp_servers.tokensave ]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-quoted-first)
            cat >> "$dir/config.toml" <<'TOML'

["mcp_servers".tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-pathological)
            cat >> "$dir/config.toml" <<'TOML'

[ "mcp_servers" . 'tokensave' ]  # local
args = ["serve"]
command = "/home/example/.local/bin/tokensave"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-disabled-quoted-basic)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"
"enabled" = false

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-disabled-quoted-literal)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"
'enabled' = false

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        wired-disabled-string)
            cat >> "$dir/config.toml" <<'TOML'

[mcp_servers.tokensave]
args = ["serve"]
command = "/home/example/.local/bin/tokensave"
enabled = "false"

[mcp_servers.tokensave.tools.tokensave_affected]
approval_mode = "auto"

[mcp_servers.tokensave.tools.tokensave_blame]
approval_mode = "auto"
TOML
            ;;
        *) fail "write_codex_config: unknown mode '$mode'"; return 1 ;;
    esac
}

# Sanity: the fixture's own wired table must be byte-identical to the shape the
# doctor's parser is asked to recognise on a REAL station. Asserted here rather
# than assumed, so a future edit to either side cannot quietly drift them apart.
c31_fx="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 fixture: mktemp -d failed"; exit 1; }
write_codex_config "$c31_fx" wired
if grepq "$(cat "$c31_fx/config.toml")" -F '[mcp_servers.tokensave]
args = ["serve"]' && grepq "$(cat "$c31_fx/config.toml")" -E '^command = "/[^"]*/tokensave"$'; then
    pass "C31 fixture — the wired stub carries this station's real table shape (bare [mcp_servers.tokensave], args before an absolute command)"
else
    fail "C31 fixture: the wired stub drifted from the real ~/.codex/config.toml shape -> $(cat "$c31_fx/config.toml")"
fi
rm -rf "$c31_fx"

echo "== C31: codex wires an ENABLED tokensave table -> WARN naming the removal remedy VERBATIM =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C31-tokensave-dropped' \
   && grepq "$out" -F 'tokensave was tried and dropped' \
   && grepq "$out" -F "remove the [mcp_servers.tokensave] table" \
   && grepq "$out" -F "$t/codex/config.toml"; then
    pass "C31 -> WARN naming the removal remedy verbatim"
else
    fail "C31 wired -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: a valid TOML trailing comment on the header must not read as unwired -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-comment: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-comment
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C31-tokensave-dropped' && ! grepq "$out" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (a trailing TOML comment on the header is still a valid wired table)"
else
    fail "C31 wired-comment -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: the WARN remedy shell-escapes a codex config path containing spaces (copy-pasteability contract) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 spaces-path: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/my codex"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/my codex" wired
cfg_q="$(printf '%q' "$t/my codex/config.toml")"
out="$(CODEX_HOME="$t/my codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C31-tokensave-dropped' \
   && grepq "$out" -F "from $cfg_q" \
   && ! grepq "$out" -F "from $t/my codex/config.toml by hand"; then
    pass "C31 -> WARN remedy shell-escapes a codex config path with spaces"
else
    fail "C31 spaces-path -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: the codex config wires some OTHER server but not tokensave -> OK, NEVER a WARN (nothing to remove) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 unwired: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" unwired
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C31-tokensave-dropped' && grepq "$out" -F 'does not wire tokensave' && ! grepq "$out" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (tokensave was never wired for codex — nothing to remove)"
else
    fail "C31 unwired -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: ONLY per-tool [mcp_servers.tokensave.tools.*] sub-tables, no parent table -> NOT wired -> OK, never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 subtables: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" subtables
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C31-tokensave-dropped' && grepq "$out" -F 'does not wire tokensave' && ! grepq "$out" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (per-tool sub-tables declare no command — a substring match on '[mcp_servers.tokensave' would have warned here)"
else
    fail "C31 subtables -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: the parent table present but COMMENTED OUT -> NOT wired -> OK, never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 commented: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" commented
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C31-tokensave-dropped' && grepq "$out" -F 'does not wire tokensave' && ! grepq "$out" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (a commented-out table is not wiring)"
else
    fail "C31 commented -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: no codex config at all -> OK, says so distinctly, never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 no-config: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(CODEX_HOME="$t/no-such-codex-home" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C31-tokensave-dropped' && grepq "$out" -F 'no codex config' \
   && ! grepq "$out" -F 'does not wire tokensave' && ! grepq "$out" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK, 'no codex config' is worded distinctly from a config that simply does not wire tokensave"
else
    fail "C31 no-config -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

# A config that cannot be READ says nothing about what it wires. Reading a
# failed grep as "not wired" would assert an OK from evidence that never
# established it — the same finding class C30's MainPID-query rows exist for.
if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then
    echo "== C31: unreadable config -> SKIPPED (running as root: mode 000 is still readable) =="
else
    echo "== C31: the codex config exists but is UNREADABLE -> INFO/undetermined, never OK-not-wired and never a WARN =="
    t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 unreadable: mktemp -d failed"; exit 1; }
    mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
    write_codex_config "$t/codex" wired
    chmod 000 "$t/codex/config.toml"
    out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'INFO C31-tokensave-dropped' && grepq "$out" -F 'not readable' \
       && ! grepq "$out" 'OK   C31-tokensave-dropped' && ! grepq "$out" 'WARN C31-tokensave-dropped'; then
        pass "C31 -> INFO (an unreadable config is undetermined — never a clean OK, never a WARN)"
    else
        fail "C31 unreadable -> $(printf '%s' "$out" | grep C31)"
    fi
    chmod 600 "$t/codex/config.toml"
    rm -rf "$t"
fi

echo "== C31: enabled = false on the tokensave table -> OK (disabled), never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-disabled: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-disabled
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'OK   C31-tokensave-dropped' && grepq "$c31_line" -F 'disabled' && ! grepq "$c31_line" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (table present but enabled = false — nothing to remove)"
else
    fail "C31 wired-disabled -> $c31_line"
fi
rm -rf "$t"

echo "== C31: \"enabled\" (basic-string key) = false on the tokensave table -> OK (disabled), never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-disabled-quoted-basic: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-disabled-quoted-basic
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'OK   C31-tokensave-dropped' && grepq "$c31_line" -F 'disabled' && ! grepq "$c31_line" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (basic-string key \"enabled\" = false — nothing to remove)"
else
    fail "C31 wired-disabled-quoted-basic -> $c31_line"
fi
rm -rf "$t"

echo "== C31: 'enabled' (literal-string key) = false on the tokensave table -> OK (disabled), never a WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-disabled-quoted-literal: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-disabled-quoted-literal
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'OK   C31-tokensave-dropped' && grepq "$c31_line" -F 'disabled' && ! grepq "$c31_line" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (literal-string key 'enabled' = false — nothing to remove)"
else
    fail "C31 wired-disabled-quoted-literal -> $c31_line"
fi
rm -rf "$t"

echo "== C31: enabled = \"false\" (a TOML STRING, not the boolean) -> still WARN (value-not-key negative control) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-disabled-string: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-disabled-string
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'WARN C31-tokensave-dropped' && ! grepq "$c31_line" -F 'disabled'; then
    pass "C31 -> WARN (enabled = \"false\" is the TOML string, not the boolean — only the KEY spelling is widened, never the value)"
else
    fail "C31 wired-disabled-string -> $c31_line"
fi
rm -rf "$t"

echo "== C31: enabled = false on a LARGE tokensave table body -> OK (disabled), never a WARN (HIMMEL-1430 regression guard) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-disabled-large: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-disabled-large
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'OK   C31-tokensave-dropped' && grepq "$c31_line" -F 'disabled' && ! grepq "$c31_line" 'WARN C31-tokensave-dropped'; then
    pass "C31 -> OK (large disabled body — the enabled=false match must not be lost to an early-exit pipeline race under pipefail)"
else
    fail "C31 wired-disabled-large -> $c31_line"
fi
rm -rf "$t"

echo "== C31: enabled = false in a SUB-table only (parent enabled) -> still WARN (negative control for the range scan) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-subtable-disabled: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-subtable-disabled
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'WARN C31-tokensave-dropped' && ! grepq "$c31_line" -F 'disabled'; then
    pass "C31 -> WARN (a sub-table's own enabled = false must not disable the parent table)"
else
    fail "C31 wired-subtable-disabled -> $c31_line"
fi
rm -rf "$t"

echo "== C31: a literal-string header key [mcp_servers.'tokensave'] is recognised as wiring -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-quoted-key: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-quoted-key
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C31-tokensave-dropped' && ! grepq "$out" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (literal-string header key [mcp_servers.'tokensave'] recognised as wired)"
else
    fail "C31 wired-quoted-key -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: whitespace around the dotted-key separator [mcp_servers . tokensave] is recognised as wiring -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-spaced-dot: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-spaced-dot
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C31-tokensave-dropped' && ! grepq "$out" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (whitespace around the dotted-key separator recognised as wired)"
else
    fail "C31 wired-spaced-dot -> $(printf '%s' "$out" | grep C31)"
fi
rm -rf "$t"

echo "== C31: whitespace immediately inside both brackets [ mcp_servers.tokensave ] is recognised as wiring -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-spaced-brackets: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-spaced-brackets
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'WARN C31-tokensave-dropped' && ! grepq "$c31_line" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (whitespace immediately inside both brackets recognised as wired)"
else
    fail "C31 wired-spaced-brackets -> $c31_line"
fi
rm -rf "$t"

echo "== C31: a quoted FIRST segment [\"mcp_servers\".tokensave] is recognised as wiring -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-quoted-first: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-quoted-first
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'WARN C31-tokensave-dropped' && ! grepq "$c31_line" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (quoted first segment recognised as wired)"
else
    fail "C31 wired-quoted-first -> $c31_line"
fi
rm -rf "$t"

echo "== C31: a pathological but valid combined spelling [ \"mcp_servers\" . 'tokensave' ]  # local is recognised as wiring -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c31.XXXXXX")" || { fail "C31 wired-pathological: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
write_codex_config "$t/codex" wired-pathological
out="$(CODEX_HOME="$t/codex" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c31_line="$(printf '%s' "$out" | grep 'C31-tokensave-dropped')"
if grepq "$c31_line" 'WARN C31-tokensave-dropped' && ! grepq "$c31_line" -F 'does not wire tokensave'; then
    pass "C31 -> WARN (combined whitespace + quoting + trailing-comment spelling recognised as wired)"
else
    fail "C31 wired-pathological -> $c31_line"
fi
rm -rf "$t"

# write_c32_shim DEST -- writes a C32 test fixture matching the REAL
# installer's shim shape: 100% STATIC content, marker only, no
# per-checkout data embedded in the file AT ALL. check_c32 never reads
# anything from a hook file beyond the plain marker-presence grep; the
# target value comes from HIMMEL_DOCTOR_MAIN_REF_TARGET below (which stands
# in for `git config --local --get himmel-main-ref.target` in production).
write_c32_shim() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    printf '#!/usr/bin/env bash\n# himmel-main-ref-transaction-v1\nexit 0\n' > "$dest"
    chmod +x "$dest"
}

echo "== C32 (HIMMEL-2095, panel round 10, CodeRabbit PR #2195): git < 2.31 does NOT fail on an unsupported --path-format -- it ECHOES the option as output and still exits 0, returning a garbled/relative value -- must WARN UNVERIFIED, never a false OK (this repo's declared minimum is git 2.30, docs/setup/new-machine.md) =="
# The first fix pass for this finding assumed an unsupported --path-format
# makes `rev-parse` FAIL (exit nonzero) -- proven WRONG on this station
# (git 2.55): `git rev-parse --totally-unknown-option --git-path hooks`
# prints the unknown option back as its own output line, THEN the
# (relative, since the format request was never honoured) resolved path,
# and still exits 0. `rev-parse` echoes options it does not recognise; it
# does not reject them. This shim reproduces THAT mechanism precisely,
# not a hard failure: it strips --path-format=absolute out of the argv,
# echoes it back as its own line (matching git's own observed behaviour
# byte-for-byte), then execs the REAL git with the remaining args -- which
# for `rev-parse --git-path hooks` (no format flag) genuinely returns a
# RELATIVE path with rc=0, exactly reproducing the two-line, rc=0, non-
# absolute value a real 2.30 station would produce. Every OTHER git
# invocation (rev-parse --show-toplevel for this file's own REPO_ROOT,
# rev-parse --git-dir for check_c32's own repo probe, and everything else
# every other check in this suite runs) passes through unaffected, since
# none of them pass --path-format=absolute.
c32ver_fakegit_dir="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32-fakegit.XXXXXX")" || { fail "C32 git-2.30: mktemp -d (fakegit) failed"; exit 1; }
c32ver_real_git="$(command -v git)"
cat > "$c32ver_fakegit_dir/git" <<GITSHIM
#!/usr/bin/env bash
saw_path_format=0
args=()
for a in "\$@"; do
    if [ "\$a" = "--path-format=absolute" ]; then
        saw_path_format=1
        continue
    fi
    args+=("\$a")
done
if [ "\$saw_path_format" -eq 1 ]; then
    echo "--path-format=absolute"
fi
exec "$c32ver_real_git" "\${args[@]}"
GITSHIM
chmod +x "$c32ver_fakegit_dir/git"
# Sanity-check the shim itself reproduces the coordinator's own probe
# before trusting it as this test's RED/GREEN instrument.
c32ver_probe="$(PATH="$c32ver_fakegit_dir:$PATH" git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path hooks 2>&1)"
c32ver_probe_lines="$(printf '%s\n' "$c32ver_probe" | wc -l)"
if [ "$c32ver_probe_lines" -ne 2 ] || ! grepq "$c32ver_probe" '^--path-format=absolute$'; then
    fail "C32 git-2.30 shim sanity: does not reproduce the echo-back shape (got: $c32ver_probe)"
fi
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 git-2.30: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$c32ver_fakegit_dir:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C32-main-ref-guard' && ! grepq "$out" 'OK   C32-main-ref-guard' && grepq "$out" -F 'UNVERIFIED'; then
    pass "C32 -> WARN UNVERIFIED (git echoes an unsupported --path-format and exits 0 -- the garbled non-absolute value is rejected, never read as OK or as 'not a git repo')"
else
    fail "C32 git-2.30 -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t" "$c32ver_fakegit_dir"

echo "== C32 (HIMMEL-2095): reference-transaction guard installed, target resolves -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 installed: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
write_c32_shim "$t/hooks/reference-transaction"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="$REPO_ROOT/scripts/hooks/check-main-ref-transaction.sh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C32-main-ref-guard' && ! grepq "$out" 'WARN C32-main-ref-guard'; then
    pass "C32 -> OK (Himmel's marker present, configured target resolves)"
else
    fail "C32 installed -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095): guard installed, but its configured TARGET check script is missing -> WARN, not OK (the shim fails open silently; this check is the only thing that catches it) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 broken-target: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
write_c32_shim "$t/hooks/reference-transaction"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="/nonexistent/does-not-exist/check-main-ref-transaction.sh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C32-main-ref-guard' && ! grepq "$out" 'OK   C32-main-ref-guard' && grepq "$out" -F 'fails OPEN' && grepq "$out" -F '/nonexistent/does-not-exist/check-main-ref-transaction.sh'; then
    pass "C32 -> WARN (installed but configured target missing, names the broken target path)"
else
    fail "C32 broken-target -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095, panel round 9): configured target is a READABLE DIRECTORY, not a regular file -> WARN, not OK (the shim would fail-CLOSED on this shape, so certifying it as protecting is worse than the missing-file case) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 target-is-directory: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
write_c32_shim "$t/hooks/reference-transaction"
mkdir -p "$t/target-is-a-directory"
# `[ -r DIR ]` is TRUE for a readable directory -- a bare readability check
# (this test's RED control, run against the code as committed before this
# fix) reports this shape as a resolvable target and OK-protecting, even
# though the real shim's `exec bash "$target"` would fail on a directory
# argument and fail-CLOSE the hook (every ref update refused) instead of
# the documented fail-open. GREEN requires BOTH readable AND a regular
# file before reporting OK.
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="$t/target-is-a-directory" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C32-main-ref-guard' && ! grepq "$out" 'OK   C32-main-ref-guard' && grepq "$out" -F 'not-a-regular-file'; then
    pass "C32 -> WARN (configured target is a directory, not a regular file -- never reported as protecting)"
else
    fail "C32 target-is-directory -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095): guard marker present + target resolves, but NOT EXECUTABLE -> WARN, not OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 not-executable: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
write_c32_shim "$t/hooks/reference-transaction"
chmod -x "$t/hooks/reference-transaction"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="$REPO_ROOT/scripts/hooks/check-main-ref-transaction.sh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C32-main-ref-guard' && ! grepq "$out" 'OK   C32-main-ref-guard' && grepq "$out" -F 'NOT EXECUTABLE'; then
    pass "C32 -> WARN (marker + resolvable target, but not executable -- git would silently ignore it)"
else
    fail "C32 not-executable -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095, codex-2, panel round 3): marker present, but NO target configured at all -> WARN as UNVERIFIED, never fall through to OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 no-target-configured: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
write_c32_shim "$t/hooks/reference-transaction"
# HIMMEL_DOCTOR_MAIN_REF_TARGET set to EMPTY (not unset -- presence, not
# non-emptiness, matches check_c32's own `${VAR+set}` test) deterministically
# forces the "no target configured" branch regardless of what this real
# checkout's own `git config himmel-main-ref.target` actually holds. This
# reproduces the ORIGINAL panel-round-2 finding in its current form: an
# empty target_path used to skip the unreadable-target WARN entirely and
# fall through to an unconditional OK -- a broken/unconfigured shim
# certifying itself as protecting.
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C32-main-ref-guard' && ! grepq "$out" 'OK   C32-main-ref-guard' && grepq "$out" -F 'no target is configured'; then
    pass "C32 -> WARN (no target configured -> UNVERIFIED, never silently OK)"
else
    fail "C32 no-target-configured -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095, codex-1, panel round 3): the hook FILE's content is irrelevant beyond the marker -- nothing in it is ever read, parsed, or executed for the target =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 no-eval: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
canary="$t/PWNED_CANARY"
rm -f "$canary"
# Two earlier rounds each carried the target INSIDE the hook file's TEXT --
# an `eval`-ed shell assignment, then a literal comment line
# (whose fix was broken by an embedded newline) -- and each
# broke a different way. The redesign removes the question rather
# than patching it a third time: the target lives ONLY in git config now
# (see install-main-ref-transaction.sh's header), and check_c32 never reads
# hook-file content beyond the plain marker grep. Proven here: the fixture
# file carries hostile, command-substitution-shaped TEXT in the OLD
# `target=$(...)` shape -- UNCOMMENTED, a literal `target=` assignment, not
# decoration. This case exists to catch the round-2 RCE coming back (a
# marker-carrying hook executing arbitrary commands during a read-only
# himmel-doctor run) -- an earlier draft of this
# fixture had this same line commented out (`# target=$(...)`), so it began
# with `# ` and could never match check_c32's own eval-based parser had one
# ever been restored: the case would have stayed green even with the RCE
# back, proving nothing while reading as coverage. Verified BOTH ways by
# hand (not committed, since restoring the eval path here would itself be
# the round-2 bug): with a temporary eval-based parser reinstated in
# check_c32, this exact fixture creates the canary and the case goes RED;
# with the real (git-config-only, never-reads-the-file) parser, it stays
# GREEN. The REAL target for this case comes from
# HIMMEL_DOCTOR_MAIN_REF_TARGET (standing in for git config), pointed at a
# real, readable script. The canary must never appear, and the verdict
# must correctly reflect the real target, proving check_c32 reads NEITHER
# the marker line's neighbours NOR anything else in the file -- and, unlike
# the earlier draft, that this is actually exercised, not merely written
# down.
# shellcheck disable=SC2016 # the $(...) inside this printf is literal decorative text for the fixture file, never expanded here
printf '#!/usr/bin/env bash\n# himmel-main-ref-transaction-v1\ntarget=$(touch %s; echo /nonexistent/never-reached.sh)\nexit 0\n' "$canary" > "$t/hooks/reference-transaction"
chmod +x "$t/hooks/reference-transaction"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" HIMMEL_DOCTOR_MAIN_REF_TARGET="$REPO_ROOT/scripts/hooks/check-main-ref-transaction.sh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if [ ! -f "$canary" ] && grepq "$out" 'OK   C32-main-ref-guard'; then
    pass "C32 -> never executes/parses hostile file content (no canary), verdict follows the configured target only (OK, real readable script)"
else
    fail "C32 no-eval -> canary_exists=$([ -f "$canary" ] && echo yes || echo no) out=$(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095): guard NOT installed (no reference-transaction file) -> WARN with the install remedy =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 missing: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
# Both WARN branches of check_c32 share generic words ("NOT", and even
# "install-main-ref-transaction.sh" -- the foreign-hook branch's remedy also
# names the installer). Pin the MISSING branch's own distinguishing phrase
# and, as a negative twin, rule out the foreign-hook branch's phrase -- a
# loose `-F 'install-main-ref-transaction.sh'` check here would pass even if
# check_c32 emitted the foreign-hook message by mistake (CR finding).
if grepq "$out" 'WARN C32-main-ref-guard' && grepq "$out" -F 'guard NOT installed at' && ! grepq "$out" -F "is NOT Himmel's main-branch reference-transaction guard"; then
    pass "C32 -> WARN (missing, names the installer as remedy, not the foreign-hook branch)"
else
    fail "C32 missing -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

echo "== C32 (HIMMEL-2095): a FOREIGN reference-transaction hook (no marker) -> WARN, never claimed as ours =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C32 foreign: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/hooks"; write_settings "$t/claude" "$WRAPPER"
printf '#!/usr/bin/env bash\n# some other tool'"'"'s hook\nexit 0\n' > "$t/hooks/reference-transaction"
out="$(HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR="$t/hooks" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
# `-F 'NOT'` alone is too loose -- BOTH WARN branches say "NOT" ("is NOT
# Himmel's guard" vs "guard NOT installed at"), so that
# assertion would pass even if check_c32 emitted the MISSING-hook message
# for a hook that is actually present-but-foreign (the exact confusion this
# case exists to catch). Pin the foreign branch's own phrase and rule out
# the missing branch's phrase as a negative twin.
if grepq "$out" 'WARN C32-main-ref-guard' && grepq "$out" -F "is NOT Himmel's main-branch reference-transaction guard" && ! grepq "$out" -F 'guard NOT installed at'; then
    pass "C32 -> WARN (foreign hook present, not claimed as Himmel's, not the missing-hook branch)"
else
    fail "C32 foreign -> $(printf '%s' "$out" | grep C32)"
fi
rm -rf "$t"

# =============================================================================
# C33: graphify graph staleness
# =============================================================================

echo "== C33: HANDOVER_DIR set but unresolvable -> WARN (the runner refuses with rc=2; broken is not healthy) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 no-root: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
# A HANDOVER_DIR pointed at a non-existent path fails handover_root() closed
# (rc=2) — graph-cadence.sh refuses the same state, so C33 must not call it OK.
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/does-not-exist" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep -A1 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'handover root is broken' && grepq "$c33_line" -F 'NOT the same as healthy' \
    && ! grepq "$c33_line" -F 'bash scripts/graphify/graph-cadence.sh'; then
    pass "C33 -> WARN (handover root unresolvable)"
else
    fail "C33 no-root -> $c33_line"
fi
rm -rf "$t"

echo "== C33: handover root resolvable but no ledger file -> OK, never WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 no-ledger: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover"; write_settings "$t/claude" "$WRAPPER"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'OK   C33-graph-stale' && grepq "$c33_line" -F 'ledger absent'; then
    pass "C33 -> OK (handover root resolvable, ledger absent — not yet armed)"
else
    fail "C33 no-ledger -> $c33_line"
fi
rm -rf "$t"

echo "== C33: ledger present but EMPTY (readable) -> OK, the benign half of the split =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 empty-ledger: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
: > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'OK   C33-graph-stale' && grepq "$c33_line" -F 'present but empty'; then
    pass "C33 -> OK (ledger readable and genuinely empty — cadence armed but never fired)"
else
    fail "C33 empty-ledger -> $c33_line"
fi
rm -rf "$t"

# PR-B panel r3, codex-1. The row above and this one are the SAME `tail`
# returning an empty string; only its exit status tells them apart. Before the
# fix both landed on the OK above, so C33 reported a ledger it could not read
# as "has not completed a run yet" -- healthy. Asserting the WARN alone would
# not have caught that: the OK row was already green and stayed green. What
# makes this pair load-bearing is that they pin the SPLIT, not either verdict.
#
# Skipped for root and on filesystems where the mode does not deny the owner
# (Git Bash / Windows): chmod 000 is the fixture's whole mechanism, and where
# it does not bite the file is READABLE, so the test would assert a WARN the
# code correctly does not emit. Probing the fixture rather than the platform
# keeps it honest about what it actually established -- this is codex-3's
# class, applied here at the point it was learned rather than
# repeated as a new instance of it.
echo "== C33: ledger present but UNREADABLE -> WARN, never the empty-ledger OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 unreadable: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"skipped","pr":null,"duration_s":1,"error":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
chmod 000 "$t/handover/.graph-cadence/ledger.jsonl" 2>/dev/null || true
if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then
    echo "  SKIP: C33 unreadable-ledger — running as root, chmod 000 does not deny read"
elif tail -n 1 "$t/handover/.graph-cadence/ledger.jsonl" >/dev/null 2>&1; then
    echo "  SKIP: C33 unreadable-ledger — chmod 000 did not deny this filesystem, fixture cannot be built"
else
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
    c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
    if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'could not be READ'; then
        pass "C33 -> WARN (unreadable ledger: undetermined, never a silent OK)"
    else
        fail "C33 unreadable -> $c33_line"
    fi
    if grepq "$c33_line" -F 'present but empty'; then
        fail "C33 unreadable -> reported as the EMPTY-ledger OK, the exact codex-1 defect"
    else
        pass "C33 unreadable is not misreported as the empty-ledger case"
    fi
fi
chmod 644 "$t/handover/.graph-cadence/ledger.jsonl" 2>/dev/null || true
rm -rf "$t"

echo "== C33: fresh healthy ledger row -> OK, reports commits-behind + age =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 healthy: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"skipped","pr":null,"duration_s":1,"error":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'OK   C33-graph-stale' && grepq "$c33_line" -F '2 commits behind main'; then
    pass "C33 -> OK (fresh row: commits-behind reported, no staleness)"
else
    fail "C33 healthy -> $c33_line"
fi
rm -rf "$t"

echo "== C33: fresh action=published-channel row (graph-data publish) -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 published-channel: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"published-channel","pr":null,"duration_s":1,"error":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'OK   C33-graph-stale' && grepq "$c33_line" -F '(action=published-channel)'; then
    pass "C33 -> OK (fresh published-channel row is a known-good action)"
else
    fail "C33 published-channel -> $c33_line"
fi
rm -rf "$t"

echo "== C33: last recorded action=failed -> WARN immediately, regardless of age =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 failed-action: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":40,"action":"failed","pr":null,"duration_s":5,"error":"boom"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep -A1 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'FAILED (boom)' && ! grepq "$c33_line" -F 'graph-cadence.sh'; then
    pass "C33 -> WARN (last recorded action=failed)"
else
    fail "C33 failed-action -> $c33_line"
fi
# a failed row whose error carries the lane's refusal names that reason.
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":40,"action":"failed","pr":null,"duration_s":5,"error":"semantic-update.sh exited 1: semantic-update: graphify extract exited 1 (refused: stale-snapshot) -- graph and manifest untouched"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'refused: stale-snapshot'; then
    pass "C33 -> WARN names the ledger's refusal reason"
else
    fail "C33 refusal reason -> $c33_line"
fi
printf '{"ts":"%s","head":"aaa","graph_head":null,"merges_behind":null,"action":"failed","pr":null,"duration_s":88,"error":"semantic-update.sh exited 2: semantic-update: account A credit exhausted; retrying the batch on the other account semantic-batch: credit exhausted (HTTP 400) semantic-update: submitting the batch failed (rc 5) -- nothing submitted, graph and manifest untouched"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep -A1 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'FAILED (API credit exhausted)' \
    && ! grepq "$c33_line" -F '? commits' && ! grepq "$c33_line" -F 'graph-cadence.sh'; then
    pass "C33 -> WARN names the credit refusal, no '?' count, no bare-cadence remedy"
else
    fail "C33 credit refusal -> $c33_line"
fi
printf '{"ts":"%s","head":"aaa","graph_head":null,"merges_behind":null,"action":"failed","pr":null,"duration_s":97,"error":"semantic-update.sh exited 2: [graphify extract] wrote /x/graph.json — 0 nodes, 0 edges (no clustering) semantic-update: refusing the batch: auto routing: no account has room ({\\"verdict\\":\\"SKIPPED-BANK\\",\\"reason\\":\\"no-account-with-headroom\\"}) semantic-update: submitting the batch failed (rc 2) -- nothing submitted, graph and manifest untouched"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep -A1 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'FAILED (no API account has credit room)' \
    && ! grepq "$c33_line" -F 'graph-cadence.sh'; then
    pass "C33 -> WARN names the auto-routing credit refusal"
else
    fail "C33 no-room refusal -> $c33_line"
fi
# a cadence alert whose Telegram send failed is its own WARN.
mkdir -p "$t/home/.himmel/state"
printf '2026-10-23T14:35:00Z graph-cadence semantic-failed\n' > "$t/home/.himmel/state/cadence-alert-send-failed"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
al_line="$(printf '%s' "$out" | grep 'C33-alert-delivery')"
if grepq "$al_line" 'WARN C33-alert-delivery' && grepq "$al_line" -F 'graph-cadence'; then
    pass "C33 -> WARN when the last cadence alert could not be delivered"
else
    fail "C33 alert delivery -> $al_line"
fi
rm -f "$t/home/.himmel/state/cadence-alert-send-failed"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
if grep -q 'C33-alert-delivery' <<< "$out"; then
    fail "C33 alert delivery reported with no failed-send marker"
else
    pass "C33 alert delivery is silent without the marker"
fi
# WARN never FAILs the scripted exit code (mirrors C7/C8/C9/C10's own
# contract) — assert the overall run still exits 0.
rc=0; CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "C33 WARN never flips himmel-doctor's own exit code"
else
    fail "C33 WARN flipped the exit code" "rc=$rc"
fi
rm -rf "$t"

echo "== C33: last row is old (beyond 3x the armed interval) -> WARN on age alone =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 stale-age: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
OLD_EPOCH=$(( $(date -u +%s) - 100000 ))
OLD_TS="$(date -u -d "@$OLD_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$OLD_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
if [ -z "$OLD_TS" ]; then
    fail "C33 stale-age: could not derive a portable old timestamp — skipping this case's assertion"
else
    printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":40,"action":"merged","pr":null,"duration_s":5,"error":null}\n' \
        "$OLD_TS" > "$t/handover/.graph-cadence/ledger.jsonl"
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
    c33_line="$(printf '%s' "$out" | grep -A1 'C33-graph-stale')"
    if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F '3x the armed interval' \
        && ! grepq "$c33_line" -F 'graph-cadence.sh'; then
        pass "C33 -> WARN (last run older than 3x the armed cadence interval)"
    else
        fail "C33 stale-age -> $c33_line"
    fi
fi
rm -rf "$t"

echo "== C33: BSD date fallback (no GNU -d) reads a Z timestamp as UTC, not local time =="
# The shim emulates BSD date on top of GNU date, so a host without GNU -d cannot build it.
if ! date -u -d '1 hour ago' +%s >/dev/null 2>&1; then
    echo "  SKIP: C33 bsd-date — host date lacks GNU -d, the BSD emulation shim cannot be built"
else
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 bsd-date: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence" "$t/shim"; write_settings "$t/claude" "$WRAPPER"
REAL_DATE="$(command -v date)"
# Emulates BSD date: rejects GNU -d; `date -j [-u] -f FMT TS +%s` parses TS as
# UTC only under -u, else as the zone in $TZ. Anything else passes through.
cat > "$t/shim/date" <<SHIM
#!/usr/bin/env bash
case "\$1" in
    -d) exit 1 ;;
    -j)
        utc=0; shift
        [ "\$1" = "-u" ] && { utc=1; shift; }
        [ "\$1" = "-f" ] || exit 1
        ts="\$3"; ts="\${ts%Z}"
        if [ "\$utc" = 1 ]; then TZ=UTC "$REAL_DATE" -d "\$ts" +%s; else "$REAL_DATE" -d "\$ts" +%s; fi ;;
    *) exec "$REAL_DATE" "\$@" ;;
esac
SHIM
chmod +x "$t/shim/date"
# Row stamped one hour ago; with local time at UTC+14 a local-time read puts it 15h back.
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"skipped","pr":null,"duration_s":1,"error":null}\n' \
    "$("$REAL_DATE" -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(PATH="$t/shim:$PATH" TZ=Etc/GMT-14 CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'OK   C33-graph-stale' && grepq "$c33_line" -F 'run 1h ago'; then
    pass "C33 -> BSD date fallback parses the Z timestamp as UTC (age 1h)"
else
    fail "C33 bsd-date -> $c33_line"
fi
rm -rf "$t"
fi

echo "== C33: jq not on PATH -> WARN, never falls through to OK (codex-8: 'cannot tell' is not 'healthy') =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 no-jq: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"skipped","pr":null,"duration_s":1,"error":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
# Shadow PATH: symlink every REAL /usr/bin entry except jq into a private
# dir, then use ONLY that dir (plus /bin) as PATH -- `command -v jq` inside
# the doctor's own subprocess must genuinely fail, not merely be told to.
NOJQ_BIN="$t/nojq-bin"
mkdir -p "$NOJQ_BIN"
for f in /usr/bin/*; do
    b="${f##*/}"
    [ "$b" = "jq" ] && continue
    [ -x "$f" ] && ln -s "$f" "$NOJQ_BIN/$b" 2>/dev/null
done
# PATH is ONLY the shadow dir -- NOT also /bin: on a merged-/usr distro
# (Arch/CachyOS et al.) /bin is a symlink to /usr/bin, so appending it would
# silently reintroduce the very jq this test exists to hide.
#
# CodeRabbit (PR #2209): guard the curated PATH like this file's two other
# curated-PATH cases already do (the gh-absent case, and C19's cmp/diff case
# at line ~1131, which both document that Git Bash .exe symlinks do not
# execute). Because PATH is replaced WHOLESALE, the `bash "$DOC"` lookup
# itself has to resolve inside $NOJQ_BIN -- so where the symlinks are inert
# the doctor never runs at all and this case fails for an environment reason
# rather than a code one. That is the same false-red the sibling cases were
# guarded against, and this case (added on this branch) simply had not
# inherited the convention.
#
# Probe the curated PATH itself rather than sniffing the platform: it must be
# able to run bash AND must genuinely lack jq. Both halves matter -- without
# the second, a shadow dir that accidentally still exposed jq would "pass" the
# probe and then assert a WARN the doctor is right not to emit.
if PATH="$NOJQ_BIN" bash -c 'command -v bash >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1' 2>/dev/null; then
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" PATH="$NOJQ_BIN" bash "$DOC" --no-color 2>&1)"
    c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
    if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'jq not on PATH'; then
        pass "C33 -> WARN (jq missing, never a silent OK)"
    else
        fail "C33 no-jq -> $c33_line"
    fi
else
    echo "  SKIP: C33 no-jq — the curated shadow PATH cannot run bash without jq here (Git Bash .exe symlinks are inert), so the fixture cannot be built"
fi
rm -rf "$t"

echo "== C33: unparseable/unrecognized ledger row action -> WARN, never OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 bad-action: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"%s","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"some-future-action-this-doctor-does-not-know","pr":null,"duration_s":1,"error":null}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'unrecognized or undetermined'; then
    pass "C33 -> WARN (unrecognized action value, never a silent OK)"
else
    fail "C33 bad-action -> $c33_line"
fi
rm -rf "$t"

echo "== C33: RECOGNIZED action but a MISSING timestamp -> WARN (age cannot be established), never OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 no-ts: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"head":"aaa","graph_head":"bbb","merges_behind":2,"action":"skipped","pr":null,"duration_s":1,"error":null}\n' \
    > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'missing or unparseable timestamp'; then
    pass "C33 -> WARN (recognized action, missing ts -- age undetermined, never a silent OK)"
else
    fail "C33 no-ts -> $c33_line"
fi
rm -rf "$t"

echo "== C33: RECOGNIZED action but an INVALID (unparseable) timestamp -> WARN, never OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c33.XXXXXX")" || { fail "C33 bad-ts: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/handover/.graph-cadence"; write_settings "$t/claude" "$WRAPPER"
printf '{"ts":"not-a-real-timestamp","head":"aaa","graph_head":"bbb","merges_behind":2,"action":"merged","pr":null,"duration_s":1,"error":null}\n' \
    > "$t/handover/.graph-cadence/ledger.jsonl"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" HANDOVER_DIR="$t/handover" bash "$DOC" --no-color 2>&1)"
c33_line="$(printf '%s' "$out" | grep 'C33-graph-stale')"
if grepq "$c33_line" 'WARN C33-graph-stale' && grepq "$c33_line" -F 'missing or unparseable timestamp'; then
    pass "C33 -> WARN (recognized action, unparseable ts -- age undetermined, never a silent OK)"
else
    fail "C33 bad-ts -> $c33_line"
fi
rm -rf "$t"

# ── C34: cost-guard wiring ─────────────────────────────────────
# check_c32 reads TRACKED REPO FILES (hooks.json, the two guard scripts,
# context-fill.sh) through $REPO_ROOT, not operator machine state, so there
# is no HOME/CLAUDE_DIR seam to redirect. himmel-doctor.sh resolves
# REPO_ROOT via `git rev-parse --show-toplevel` FIRST and only falls back to
# $HIMMEL_REPO when that fails (see its own top-of-file resolution) — so
# each fixture below runs from a non-git cwd (a fresh mktemp -d, never
# nested under this checkout) with HIMMEL_REPO pointing at a from-scratch
# fake repo tree. The other checks source their own libs from
# $REPO_ROOT/scripts/lib/*, which do not exist in these minimal fixtures;
# those sourcing lines fail loudly to stderr (the script has no `set -e`,
# so it keeps running) and are irrelevant here — only the C34 line matters.
c32_fixture_base() {
    local root="$1"
    mkdir -p "$root/scripts/hooks" "$root/marketplace/plugins/himmel-ops/hooks"
}
run_doctor_fake_repo() {
    # run_doctor_fake_repo <fake-repo-root> <home-scratch-dir>
    (cd "$1" && HIMMEL_REPO="$1" HIMMEL_DOCTOR_ROOT="$1" CLAUDE_DIR="$2/claude" HOME="$2" DOCTOR_OBSERVABILITY_SKIP=1 bash "$DOC" --no-color 2>/dev/null)
}

# missing validation/reporting would hide a configured invalid lift.
echo "== C34: configured lift reports validation reason =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-lift.XXXXXX")" || exit 1
c32_fixture_base "$t"
mkdir -p "$t/scripts/lib" "$t/home/.himmel/state"
cp "$REPO_ROOT/scripts/lib/usage-lift.sh" "$REPO_ROOT/scripts/lib/usage-cache-identity.sh" "$t/scripts/lib/"
printf '%s' '{broken' > "$t/home/.himmel/state/usage-lift.json"
chmod 600 "$t/home/.himmel/state/usage-lift.json"
out="$(USAGE_LIFT_FILE="$t/home/.himmel/state/usage-lift.json" CADENCE_USAGE_CACHE="$t/cache.json" run_doctor_fake_repo "$t" "$t/home")"
if grepq "$out" -F 'lift set but INVALID: parse'; then pass "C34 explains malformed lift"; else fail "C34 missing invalid lift reason"; fi
chmod 666 "$t/home/.himmel/state/usage-lift.json"
out="$(USAGE_LIFT_FILE="$t/home/.himmel/state/usage-lift.json" CADENCE_USAGE_CACHE="$t/cache.json" run_doctor_fake_repo "$t" "$t/home")"
if grepq "$out" -F 'lift set but INVALID: trust'; then pass "C34 explains untrusted lift"; else fail "C34 missing trust reason"; fi
rm -f "$t/home/.himmel/state/usage-lift.json"
printf '%s' '{broken' > "$t/home/.himmel/state/bank-lift.json" # old-term-ok
chmod 600 "$t/home/.himmel/state/bank-lift.json" # old-term-ok
out="$( (unset USAGE_LIFT_FILE; CADENCE_USAGE_CACHE="$t/cache.json" run_doctor_fake_repo "$t" "$t/home") )"
if grepq "$out" -F 'lift set but INVALID: parse'; then fail "C34 read the retired bank-lift.json"; else pass "C34 ignores the retired bank-lift.json"; fi # old-term-ok
rm -rf "$t"

echo "== C34: lift after an account switch -> remedy per reason, followed OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-follow.XXXXXX")" || exit 1
c32_fixture_base "$t"
mkdir -p "$t/scripts/lib" "$t/home/.himmel/state"
cp "$REPO_ROOT/scripts/lib/usage-lift.sh" "$REPO_ROOT/scripts/lib/usage-cache-identity.sh" "$t/scripts/lib/"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-doctor-follow-a"}}' > "$t/login-a.json"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-doctor-follow-b"}}' > "$t/login-b.json"
c34_ha="$(. "$REPO_ROOT/scripts/lib/usage-cache-identity.sh"; current_account_hash "$t/login-a.json")"
c34_hb="$(. "$REPO_ROOT/scripts/lib/usage-cache-identity.sh"; current_account_hash "$t/login-b.json")"
c34_now="$(date +%s)"
c34_lift() {
    jq -cn --arg a "$c34_ha" --argjson s "$1" --arg by "$2" --argjson u "$((c34_now+3600))" \
        '{window:"seven_day",until:$u,standing:$s,account:$a,set_by:$by,set_at:"x"}' > "$t/home/.himmel/state/usage-lift.json"
    chmod 600 "$t/home/.himmel/state/usage-lift.json"
}
c34_follow_line() {
    printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":10,"resets_at":%s}}' \
        "$1" "$((c34_now+86400))" > "$t/cache.json"
    USAGE_LIFT_FILE="$t/home/.himmel/state/usage-lift.json" CADENCE_USAGE_CACHE="$t/cache.json" \
        CLAUDE_ACCOUNT_CONFIG="$t/login-b.json" run_doctor_fake_repo "$t" "$t/home" \
        | grep -A1 'C34-cost-guards: lift set' | grep -E 'C34-cost-guards: lift set|^ +→'
}
c34_no_hash() { ! grepq "$1" -E '[0-9a-f]{5}'; }
c34_lift true "$(id -un)"
c34_line="$(c34_follow_line "$c34_ha")"
if grepq "$c34_line" -F 'lift set but INVALID: cache-account' && grepq "$c34_line" -F 'force a refresh' && c34_no_hash "$c34_line"; then
    pass "C34 cache-account names the cache refresh"
else
    fail "C34 cache-account remedy -> $c34_line"
fi
c34_lift false "$(id -un)"
c34_line="$(c34_follow_line "$c34_hb")"
if grepq "$c34_line" -F 'lift set but INVALID: account' && grepq "$c34_line" -F 'one-window lift does not follow an account switch' && c34_no_hash "$c34_line"; then
    pass "C34 window lift on another account names the re-set"
else
    fail "C34 account remedy -> $c34_line"
fi
c34_lift true not-the-operator
c34_line="$(c34_follow_line "$c34_hb")"
if grepq "$c34_line" -F 'lift set but INVALID: set_by' && grepq "$c34_line" -F 'not set by this user' && c34_no_hash "$c34_line"; then
    pass "C34 set_by names the one-time standing re-set"
else
    fail "C34 set_by remedy -> $c34_line"
fi
c34_lift true "$(id -un)"
c34_line="$(c34_follow_line "$c34_hb")"
if grepq "$c34_line" -F 'OK   C34-cost-guards: lift set and VALID (standing=true, followed)' && c34_no_hash "$c34_line"; then
    pass "C34 followed standing lift reads VALID, followed"
else
    fail "C34 followed -> $c34_line"
fi
rm -rf "$t"

echo "== C34: everything wired (real copies of the 3 target files) -> all three rows OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 all-wired: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
cp "$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json" "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_lines="$(printf '%s' "$out" | grep 'C34-cost-guards')"
if grepq "$c32_lines" 'OK   C34-cost-guards: guard-subagent-model.sh exists and is registered' \
   && grepq "$c32_lines" 'OK   C34-cost-guards: guard-implementor-dispatch.sh is weekly' \
   && grepq "$c32_lines" 'OK   C34-cost-guards: context-fill.sh supports --warn-at'; then
    pass "C34 -> all three rows OK when everything is wired"
else
    fail "C34 all-wired -> $c32_lines"
fi
rm -rf "$t"

echo "== C34: guard-subagent-model.sh missing entirely -> WARN naming the missing script =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 script-missing: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
printf '{}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'guard-subagent-model')"
if grepq "$c32_line" 'WARN C34-cost-guards' && grepq "$c32_line" -F 'missing or unreadable'; then
    pass "C34 -> WARN naming the missing guard-subagent-model.sh"
else
    fail "C34 script-missing -> $c32_line"
fi
rm -rf "$t"

echo "== C34: guard-subagent-model.sh present but NOT referenced in hooks.json -> WARN naming the missing registration =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 not-registered: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
printf '{"hooks":{"PreToolUse":[]}}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'guard-subagent-model')"
if grepq "$c32_line" 'WARN C34-cost-guards' && grepq "$c32_line" -F 'not registered under a PreToolUse entry whose matcher includes Agent in marketplace/plugins/himmel-ops/hooks/hooks.json'; then
    pass "C34 -> WARN naming the missing hooks.json registration"
else
    fail "C34 not-registered -> $c32_line"
fi
rm -rf "$t"

echo "== C34: guard-subagent-model.sh mentioned under the WRONG matcher -> WARN, not the false OK (CR round 3, HIMMEL-2653) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 wrong-matcher: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash|PowerShell","hooks":[{"command":"guard-subagent-model.sh"}]}]}}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'guard-subagent-model')"
if grepq "$c32_line" 'WARN C34-cost-guards' && ! grepq "$c32_line" 'OK   C34-cost-guards'; then
    pass "C34 -> WARN (not OK) when the guard is mentioned only under a non-Agent matcher"
else
    fail "C34 wrong-matcher -> $c32_line"
fi
rm -rf "$t"

echo "== C34: guard-subagent-model.sh mentioned only under a non-PreToolUse event -> WARN, not the false OK (CR round 3, HIMMEL-2653) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 wrong-event: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"command":"guard-subagent-model.sh"}]}]}}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'guard-subagent-model')"
if grepq "$c32_line" 'WARN C34-cost-guards' && ! grepq "$c32_line" 'OK   C34-cost-guards'; then
    pass "C34 -> WARN (not OK) when the guard is mentioned only under a non-PreToolUse event"
else
    fail "C34 wrong-event -> $c32_line"
fi
rm -rf "$t"

echo "== C34: guard-implementor-dispatch.sh present but does not mention seven_day -> WARN (dispatch gate is five-hour-blind) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 five-hour-blind: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/context-fill.sh" "$t/scripts/context-fill.sh"
printf '#!/usr/bin/env bash\n# no weekly bank awareness here\nexit 0\n' > "$t/scripts/hooks/guard-implementor-dispatch.sh"
printf '{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"command":"guard-subagent-model.sh"}]}]}}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'five-hour-blind')"
if grepq "$c32_line" 'WARN C34-cost-guards' && grepq "$c32_line" -F 'five-hour-blind'; then
    pass "C34 -> WARN naming the five-hour-blind guard"
else
    fail "C34 five-hour-blind -> $c32_line"
fi
rm -rf "$t"

echo "== C34: context-fill.sh present but no --warn-at support -> INFO, not WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c32.XXXXXX")" || { fail "C34 no-warn-at: mktemp -d failed"; exit 1; }
c32_fixture_base "$t"
cp "$REPO_ROOT/scripts/hooks/guard-subagent-model.sh" "$t/scripts/hooks/guard-subagent-model.sh"
cp "$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh" "$t/scripts/hooks/guard-implementor-dispatch.sh"
printf '#!/usr/bin/env bash\n# no fill-threshold flag here\nexit 0\n' > "$t/scripts/context-fill.sh"
printf '{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"command":"guard-subagent-model.sh"}]}]}}' > "$t/marketplace/plugins/himmel-ops/hooks/hooks.json"
out="$(run_doctor_fake_repo "$t" "$t/home")"
c32_line="$(printf '%s' "$out" | grep 'C34-cost-guards' | grep -F 'warn-at')"
if grepq "$c32_line" 'INFO C34-cost-guards' && ! grepq "$c32_line" 'WARN C34-cost-guards'; then
    pass "C34 -> INFO (not WARN) when context-fill.sh lacks --warn-at"
else
    fail "C34 no-warn-at -> $c32_line"
fi
rm -rf "$t"

# ── C15: tier-aware plugin drift ────────────────────────────────
# check_c15 reads REPO_ROOT/docs/setup/settings-template.json — same
# git-toplevel-first / HIMMEL_REPO-fallback resolution as C34 above — so
# these fixtures reuse the same from-scratch fake-repo + run_doctor_fake_repo
# idiom to supply a controlled onDemandPlugins shape instead of depending on
# the real (co-owned) template.
c15_fixture_base() {
    mkdir -p "$1/docs/setup"
}

echo "== C15: an operator-enabled onDemandPlugins spec is reported INFO, not counted as drift =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c15.XXXXXX")" || { fail "C15 ondemand-enabled: mktemp -d failed"; exit 1; }
c15_fixture_base "$t"
cat > "$t/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": false }, "onDemandPlugins": { "od1@mp": { "neededBy": "x" } } }
EOF
mkdir -p "$t/home/claude"
cat > "$t/home/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": true } }
EOF
out="$(run_doctor_fake_repo "$t" "$t/home")"
c15_main="$(printf '%s' "$out" | grep -F 'C15-plugins:')"
c15_od="$(printf '%s' "$out" | grep -F 'C15-plugins-ondemand')"
if grepq "$c15_main" 'OK   C15-plugins:' && grepq "$c15_od" 'INFO C15-plugins-ondemand' && grepq "$c15_od" -F 'od1@mp'; then
    pass "C15 -> an enabled on-demand spec is OK/no-drift on the main line and named in a separate INFO line"
else
    fail "C15 ondemand-enabled -> main=[$c15_main] ondemand=[$c15_od]"
fi
rm -rf "$t"

echo "== C15: a genuine beyond-floor plugin still WARNs, even alongside an enabled on-demand spec =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c15.XXXXXX")" || { fail "C15 mixed-drift: mktemp -d failed"; exit 1; }
c15_fixture_base "$t"
cat > "$t/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": false }, "onDemandPlugins": { "od1@mp": { "neededBy": "x" } } }
EOF
mkdir -p "$t/home/claude"
cat > "$t/home/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": true, "rogue@mp": true } }
EOF
out="$(run_doctor_fake_repo "$t" "$t/home")"
c15_main="$(printf '%s' "$out" | grep -F 'C15-plugins:')"
c15_od="$(printf '%s' "$out" | grep -F 'C15-plugins-ondemand')"
if grepq "$c15_main" 'WARN C15-plugins:' && grepq "$c15_main" -F 'rogue@mp' && ! grepq "$c15_main" -F 'od1@mp' && grepq "$c15_od" -F 'od1@mp'; then
    pass "C15 -> WARN names only the genuine drift (rogue@mp); the enabled on-demand spec (od1@mp) is excluded from it"
else
    fail "C15 mixed-drift -> main=[$c15_main] ondemand=[$c15_od]"
fi
rm -rf "$t"

echo "== C15: a malformed (non-object) onDemandPlugins degrades to INFO skip, never a false OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c15.XXXXXX")" || { fail "C15 ondemand-malformed: mktemp -d failed"; exit 1; }
c15_fixture_base "$t"
cat > "$t/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true }, "onDemandPlugins": [ "od1@mp" ] }
EOF
mkdir -p "$t/home/claude"
cat > "$t/home/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true } }
EOF
out="$(run_doctor_fake_repo "$t" "$t/home")"
c15_main="$(printf '%s' "$out" | grep -F 'C15-plugins:')"
if grepq "$c15_main" 'INFO C15-plugins:' && grepq "$c15_main" -F 'non-object onDemandPlugins'; then
    pass "C15 -> a malformed onDemandPlugins skips the check via INFO, not a false OK"
else
    fail "C15 ondemand-malformed -> $c15_main"
fi
rm -rf "$t"

echo "== C15: a user sibling settings.local.json enable is reconciliation input, not current runtime state =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c15.XXXXXX")" || { fail "C15 ondemand-sidecar-only: mktemp -d failed"; exit 1; }
c15_fixture_base "$t"
cat > "$t/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": false }, "onDemandPlugins": { "od1@mp": { "neededBy": "x" } } }
EOF
mkdir -p "$t/home/claude"
cat > "$t/home/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": false } }
EOF
cat > "$t/home/claude/settings.local.json" <<'EOF'
{ "enabledPlugins": { "od1@mp": true } }
EOF
out="$(run_doctor_fake_repo "$t" "$t/home")"
c15_main="$(printf '%s' "$out" | grep -F 'C15-plugins:')"
c15_od="$(printf '%s' "$out" | grep -F 'C15-plugins-ondemand' || true)"
if grepq "$c15_main" 'OK   C15-plugins:' && [ -z "$c15_od" ]; then
    pass "C15 -> sidecar-only od1@mp=true is not reported as current runtime state"
else
    fail "C15 ondemand-sidecar-only -> main=[$c15_main] ondemand=[$c15_od]"
fi
rm -rf "$t"

echo "== C15: an on-demand enable applied to user settings.json is current runtime state despite a stale sibling false =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c15.XXXXXX")" || { fail "C15 ondemand-applied-setting: mktemp -d failed"; exit 1; }
c15_fixture_base "$t"
cat > "$t/docs/setup/settings-template.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": false }, "onDemandPlugins": { "od1@mp": { "neededBy": "x" } } }
EOF
mkdir -p "$t/home/claude"
cat > "$t/home/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "always@mp": true, "od1@mp": true } }
EOF
cat > "$t/home/claude/settings.local.json" <<'EOF'
{ "enabledPlugins": { "od1@mp": false } }
EOF
out="$(run_doctor_fake_repo "$t" "$t/home")"
c15_main="$(printf '%s' "$out" | grep -F 'C15-plugins:')"
c15_od="$(printf '%s' "$out" | grep -F 'C15-plugins-ondemand' || true)"
if grepq "$c15_main" 'OK   C15-plugins:' && grepq "$c15_od" 'INFO C15-plugins-ondemand' && grepq "$c15_od" -F 'od1@mp'; then
    pass "C15 -> settings.json od1@mp=true is reported as current runtime state; sibling false does not mask it"
else
    fail "C15 ondemand-applied-setting -> main=[$c15_main] ondemand=[$c15_od]"
fi
rm -rf "$t"

echo "== C36: no .git under the temp dir -> OK, no stray-git warning (GREEN) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c36.XXXXXX")" || { fail "C36 clean: mktemp -d failed"; exit 1; }
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C36-stray-tmp-git' && ! grepq "$out" 'WARN C36-stray-tmp-git'; then
    pass "C36 clean temp dir -> OK, no warning"
else
    fail "C36 clean -> $(printf '%s' "$out" | grep C36-stray-tmp-git)"
fi
rm -rf "$t"

echo "== C36: EMPTY .git directly under the temp dir -> WARN naming rmdir (RED) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c36.XXXXXX")" || { fail "C36 empty: mktemp -d failed"; exit 1; }
mkdir -p "$t/.git"
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C36-stray-tmp-git' && grepq "$out" -F "rmdir $t/.git"; then
    pass "C36 empty .git -> WARN naming the rmdir remedy"
else
    fail "C36 empty -> $(printf '%s' "$out" | grep C36-stray-tmp-git)"
fi
rm -rf "$t"

echo "== C36: NON-EMPTY .git directly under the temp dir -> WARN, stop, not deleted =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c36.XXXXXX")" || { fail "C36 nonempty: mktemp -d failed"; exit 1; }
mkdir -p "$t/.git"
: > "$t/.git/HEAD"
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C36-stray-tmp-git' && grepq "$out" -F 'NOT deleted' && ! grepq "$out" -F 'rmdir'; then
    pass "C36 non-empty .git -> WARN, stop, not deleted (no rmdir remedy)"
else
    fail "C36 nonempty -> $(printf '%s' "$out" | grep C36-stray-tmp-git)"
fi
rm -rf "$t"

echo "== C36: removing the empty .git clears the warning (RED -> GREEN) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c36.XXXXXX")" || { fail "C36 clear: mktemp -d failed"; exit 1; }
mkdir -p "$t/.git"
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
grepq "$out" 'WARN C36-stray-tmp-git' || fail "C36 clear: precondition WARN did not fire"
rmdir "$t/.git"
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C36-stray-tmp-git' && ! grepq "$out" 'WARN C36-stray-tmp-git'; then
    pass "C36 clear -> rmdir clears the warning back to OK"
else
    fail "C36 clear -> $(printf '%s' "$out" | grep C36-stray-tmp-git)"
fi
rm -rf "$t"

# CodeRabbit (PR #2229): a temp dir with a space in it must produce a
# copy-pasteable (shell-escaped) rmdir remedy, not a broken one.
echo "== C36: EMPTY .git under a temp dir path containing a space -> rmdir remedy is shell-escaped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c36.XXXXXX")" || { fail "C36 spaced path: mktemp -d failed"; exit 1; }
t_spaced="$t/has space"
mkdir -p "$t_spaced/.git"
out="$(PATH="$FAKEBIN:$PATH" TMPDIR="$t_spaced" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
expected_q="$(printf '%q' "$t_spaced/.git")"
if grepq "$out" 'WARN C36-stray-tmp-git' && grepq "$out" -F "rmdir $expected_q"; then
    pass "C36 spaced path -> WARN naming a shell-escaped rmdir remedy"
else
    fail "C36 spaced path -> $(printf '%s' "$out" | grep C36-stray-tmp-git)"
fi
rm -rf "$t"

# --- C37: vendored-skill overlap ------
# One case per branch of check_c37_vendored_skill_dupes: OK (rc 0), WARN (rc 10),
# and every INFO skip (no node, detector absent, rc 2, any other rc, no jq,
# unparsable --json). Every case runs in a FAKE repo whose scripts/lib is a
# symlink to the real one (the doctor sources its libs from HIMMEL_REPO, so an
# empty fake repo would leave resolve_node undefined and turn every case into the
# "no node" branch for the wrong reason) and whose detector is a copy of the real
# one -- the detector derives its repoRoot from its own path, so the fake
# marketplace/plugins/lean-skills/skills tree is what it sees. The detector's
# VENDORED_DUPES_* seams keep it off the operator's real ~/.claude and cwd walk.
c37_setup() {
    c37_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c37.XXXXXX")" || { fail "C37 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c37_t/scripts/lanes" "$c37_t/marketplace/plugins/lean-skills/skills/test-driven-development" "$c37_t/home" "$c37_t/cfg"
    ln -s "$REPO_ROOT/scripts/lib" "$c37_t/scripts/lib"
    cp "$REPO_ROOT/scripts/lanes/vendored-skill-dupes.mjs" "$c37_t/scripts/lanes/vendored-skill-dupes.mjs"
    printf '{"enabledPlugins":{"lean-skills@himmel":true}}' > "$c37_t/cfg/settings.json"
}
c37_detector_rc() {  # rc the detector itself gives this fixture (precondition probe)
    env VENDORED_DUPES_HOME="$c37_t/home" VENDORED_DUPES_CWD="" VENDORED_DUPES_CONFIG_DIR="$c37_t/cfg" \
        node "$c37_t/scripts/lanes/vendored-skill-dupes.mjs" --json >/dev/null 2>&1
    echo $?
}
c37_run() {  # c37_run [extra env assignments...] -> the doctor's stdout
    (cd "$c37_t" && env HIMMEL_REPO="$c37_t" HIMMEL_DOCTOR_ROOT="$c37_t" CLAUDE_DIR="$c37_t/claude" HOME="$c37_t/home" DOCTOR_OBSERVABILITY_SKIP=1 \
        VENDORED_DUPES_HOME="$c37_t/home" VENDORED_DUPES_CWD="" VENDORED_DUPES_CONFIG_DIR="$c37_t/cfg" \
        "$@" "$BASH" "$DOC" --no-color 2>/dev/null)
}
c37_overlap() {  # turn the fixture into a rc=10 overlap
    printf '{"enabledPlugins":{"lean-skills@himmel":true,"superpowers@claude-plugins-official":true}}' > "$c37_t/cfg/settings.json"
}

echo "== C37: enabled lean-skills, no upstream enabled (detector rc 0) -> OK =="
c37_setup
if [ "$(c37_detector_rc)" != 0 ]; then fail "C37 rc0: precondition -- the detector did not exit 0"; else
    out="$(c37_run)"
    if grepq "$out" 'OK   C37-vendored-skill-dupes' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
        pass "C37 rc 0 -> OK, no overlap"
    else
        fail "C37 rc0 -> $(printf '%s' "$out" | grep C37)"
    fi
fi
rm -rf "$c37_t"

echo "== C37: upstream superpowers also enabled (detector rc 10) -> WARN naming plugin + skill count =="
c37_setup; c37_overlap
if [ "$(c37_detector_rc)" != 10 ]; then fail "C37 rc10: precondition -- the detector did not exit 10"; else
    out="$(c37_run)"
    if grepq "$out" 'WARN C37-vendored-skill-dupes' && grepq "$out" -F 'superpowers@claude-plugins-official (1 skills)' \
       && ! grepq "$out" 'OK   C37-vendored-skill-dupes'; then
        pass "C37 rc 10 -> WARN naming superpowers@claude-plugins-official (1 skills)"
    else
        fail "C37 rc10 -> $(printf '%s' "$out" | grep C37)"
    fi
fi
rm -rf "$c37_t"

echo "== C37: a settings layer is unparseable (detector rc 2) -> INFO skip, never WARN/FAIL =="
c37_setup
printf '{ this is not json' > "$c37_t/cfg/settings.json"
if [ "$(c37_detector_rc)" != 2 ]; then fail "C37 rc2: precondition -- the detector did not exit 2"; else
    out="$(c37_run)"
    if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'unreadable/unparseable' \
       && ! grepq "$out" 'WARN C37-vendored-skill-dupes' && ! grepq "$out" 'FAIL C37-vendored-skill-dupes'; then
        pass "C37 rc 2 -> INFO skip naming the unreadable settings layer"
    else
        fail "C37 rc2 -> $(printf '%s' "$out" | grep C37)"
    fi
fi
rm -rf "$c37_t"

echo "== C37: detector exits an unexpected rc -> INFO skip carrying the rc =="
c37_setup
printf 'process.exit(7);\n' > "$c37_t/scripts/lanes/vendored-skill-dupes.mjs"
out="$(c37_run)"
if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'unavailable (rc=7)' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
    pass "C37 other rc -> INFO skip, rc named"
else
    fail "C37 other rc -> $(printf '%s' "$out" | grep C37)"
fi
rm -rf "$c37_t"

echo "== C37: detector script absent -> INFO skip =="
c37_setup
rm -f "$c37_t/scripts/lanes/vendored-skill-dupes.mjs"
out="$(c37_run)"
if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'vendored-skill-dupes.mjs not found' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
    pass "C37 detector absent -> INFO skip"
else
    fail "C37 detector absent -> $(printf '%s' "$out" | grep C37)"
fi
rm -rf "$c37_t"

echo "== C37: no node resolvable -> INFO skip =="
c37_setup
if PATH="$NOGH" bash -c 'command -v node >/dev/null 2>&1'; then fail "C37 no-node: precondition -- node is on the curated PATH"; else
    out="$(c37_run PATH="$NOGH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$c37_t/none" FNM_DIR="$c37_t/none")"
    if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'no node found' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
        pass "C37 no node -> INFO skip"
    else
        fail "C37 no node -> $(printf '%s' "$out" | grep C37)"
    fi
fi
rm -rf "$c37_t"

echo "== C37: overlap found but jq missing -> INFO skip, not a WARN with an empty summary =="
c37_setup; c37_overlap
NOJQ="$c37_t/nojq"; mkdir -p "$NOJQ"
for _tool in bash sh git node sort tail sed cat date mktemp mkdir dirname uname wc tr head cp rm mv chmod grep basename; do
    _p="$(command -v "$_tool" 2>/dev/null)" && ln -sf "$_p" "$NOJQ/$_tool" 2>/dev/null
done
if [ "$(c37_detector_rc)" != 10 ]; then fail "C37 no-jq: precondition -- the detector did not exit 10"
elif PATH="$NOJQ" bash -c 'command -v jq >/dev/null 2>&1'; then fail "C37 no-jq: precondition -- jq is on the curated PATH"
else
    out="$(c37_run PATH="$NOJQ")"
    if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'unparsable' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
        pass "C37 no jq -> INFO skip"
    else
        fail "C37 no jq -> $(printf '%s' "$out" | grep C37)"
    fi
fi
rm -rf "$c37_t"

echo "== C37: rc 10 with non-JSON --json output -> INFO skip =="
c37_setup
printf 'process.stdout.write("not json\\n"); process.exit(10);\n' > "$c37_t/scripts/lanes/vendored-skill-dupes.mjs"
out="$(c37_run)"
if grepq "$out" 'INFO C37-vendored-skill-dupes' && grepq "$out" -F 'unparsable' && ! grepq "$out" 'WARN C37-vendored-skill-dupes'; then
    pass "C37 unparsable --json -> INFO skip"
else
    fail "C37 unparsable --json -> $(printf '%s' "$out" | grep C37)"
fi
rm -rf "$c37_t"

# --- C38 / C39: uv + GNU timeout presence, reported up front ----
# Seams: HIMMEL_DOCTOR_UV (uv command, default `uv`) and HIMMEL_DOCTOR_TIMEOUT_BINS
# (space-separated GNU-timeout candidates, default `timeout gtimeout`). /usr/bin
# holds the REAL uv and timeout on this station and TOOLS_PATH cannot scrub it, so
# "absent" is an absolute nonexistent path (`command -v` on one never falls
# through to PATH -- same shape as the HIMMEL_DOCTOR_SYSTEMCTL seam). "Present"
# is a stub FIRST on PATH. Every case asserts what the doctor will SEE before
# running it, so a stub that silently failed to take effect cannot pass.
c3839_setup() {
    c3839_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c3839.XXXXXX")" || { fail "C38/C39 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c3839_t/darwin" "$c3839_t/uvbin" "$c3839_t/tbin" "$c3839_t/badt"
    printf '#!/bin/sh\necho Darwin\n' > "$c3839_t/darwin/uname"
    printf '#!/bin/sh\nexit 0\n' > "$c3839_t/uvbin/uv"
    printf '#!/bin/sh\nexit 0\n' > "$c3839_t/tbin/gtimeout"
    printf '#!/bin/sh\nexit 1\n' > "$c3839_t/badt/timeout"
    chmod +x "$c3839_t/darwin/uname" "$c3839_t/uvbin/uv" "$c3839_t/tbin/gtimeout" "$c3839_t/badt/timeout"
    c3839_absent_uv="$c3839_t/no-uv"
    c3839_absent_t="$c3839_t/no-timeout $c3839_t/no-gtimeout"
}

echo "== C38: no uv -> WARN naming uv + graphify never installing, curl hint on Linux (RED) =="
c3839_setup
if [ -e "$c3839_absent_uv" ] || PATH="$FAKEBIN:$PATH" bash -c 'command -v "$1"' _ "$c3839_absent_uv" >/dev/null 2>&1; then
    fail "C38 no-uv: precondition — the absent-uv seam path resolves"
elif [ "$(PATH="$FAKEBIN:$PATH" uname -s)" != Linux ]; then
    fail "C38 no-uv: precondition — the uname stub did not report Linux"
else
    out="$(PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_UV="$c3839_absent_uv" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C38-uv-graphify' && grepq "$out" 'uv' && grepq "$out" -F 'graphify is uv-managed' \
       && grepq "$out" -F 'https://astral.sh/uv/install.sh' && ! grepq "$out" -F 'brew install uv'; then
        pass "C38 no uv -> WARN naming uv/graphify, astral curl hint (not brew) on Linux"
    else
        fail "C38 no uv -> $(printf '%s' "$out" | grep -A1 C38)"
    fi
fi
rm -rf "$c3839_t"

echo "== C38: uv on PATH -> OK, no WARN =="
c3839_setup
if [ "$(PATH="$c3839_t/uvbin:$FAKEBIN:$PATH" command -v uv)" != "$c3839_t/uvbin/uv" ]; then
    fail "C38 uv-present: precondition — the stub uv is not what PATH resolves"
else
    out="$(PATH="$c3839_t/uvbin:$FAKEBIN:$PATH" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C38-uv-graphify' && ! grepq "$out" 'WARN C38-uv-graphify'; then
        pass "C38 uv present -> OK, no warning"
    else
        fail "C38 uv present -> $(printf '%s' "$out" | grep -A1 C38)"
    fi
fi
rm -rf "$c3839_t"

echo "== C38: no uv on Darwin -> remedy is brew install uv =="
c3839_setup
if [ "$(PATH="$c3839_t/darwin:$PATH" uname -s)" != Darwin ] || PATH="$c3839_t/darwin:$PATH" bash -c 'command -v "$1"' _ "$c3839_absent_uv" >/dev/null 2>&1; then
    fail "C38 darwin: precondition — uname is not Darwin or the absent-uv seam resolves"
else
    out="$(PATH="$c3839_t/darwin:$PATH" HIMMEL_DOCTOR_UV="$c3839_absent_uv" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C38-uv-graphify' && grepq "$out" -F 'brew install uv' && ! grepq "$out" -F 'astral.sh'; then
        pass "C38 darwin no uv -> WARN with the brew install uv remedy"
    else
        fail "C38 darwin no uv -> $(printf '%s' "$out" | grep -A1 C38)"
    fi
fi
rm -rf "$c3839_t"

echo "== C39: Darwin without a functional timeout/gtimeout -> WARN naming coreutils, unbounded refresh (RED) =="
c3839_setup
if [ "$(PATH="$c3839_t/darwin:$PATH" uname -s)" != Darwin ]; then
    fail "C39 darwin no-timeout: precondition — the uname stub did not report Darwin"
elif PATH="$c3839_t/darwin:$PATH" bash -c 'for c in $1; do command -v "$c" >/dev/null 2>&1 && exit 1; done; exit 0' _ "$c3839_absent_t"; then
    out="$(PATH="$c3839_t/darwin:$PATH" HIMMEL_DOCTOR_TIMEOUT_BINS="$c3839_absent_t" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C39-gtimeout-darwin' && grepq "$out" -F 'brew install coreutils' && grepq "$out" -F 'unbounded'; then
        pass "C39 darwin no timeout -> WARN naming coreutils / unbounded"
    else
        fail "C39 darwin no timeout -> $(printf '%s' "$out" | grep -A1 C39)"
    fi
else
    fail "C39 darwin no-timeout: precondition — an absent-timeout seam candidate resolves"
fi
rm -rf "$c3839_t"

echo "== C39: Darwin with a functional gtimeout on PATH -> OK =="
c3839_setup
if [ "$(PATH="$c3839_t/tbin:$c3839_t/darwin:$PATH" command -v gtimeout)" != "$c3839_t/tbin/gtimeout" ] \
   || ! "$c3839_t/tbin/gtimeout" -k 1 1 true; then
    fail "C39 darwin gtimeout: precondition — the stub gtimeout is not resolvable/functional"
else
    out="$(PATH="$c3839_t/tbin:$c3839_t/darwin:$PATH" HIMMEL_DOCTOR_TIMEOUT_BINS="$c3839_t/no-timeout gtimeout" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C39-gtimeout-darwin' && ! grepq "$out" 'WARN C39-gtimeout-darwin'; then
        pass "C39 darwin gtimeout present -> OK"
    else
        fail "C39 darwin gtimeout present -> $(printf '%s' "$out" | grep -A1 C39)"
    fi
fi
rm -rf "$c3839_t"

echo "== C39: Darwin with a timeout that fails the -k probe (BSD-like) -> WARN, not OK =="
c3839_setup
if PATH="$c3839_t/badt:$PATH" timeout -k 1 1 true >/dev/null 2>&1; then # gnu-ok: runs the suite's own stub timeout (first on PATH), never the host binary
    fail "C39 darwin bad-timeout: precondition — the stub timeout passed the -k probe"
else
    out="$(PATH="$c3839_t/badt:$c3839_t/darwin:$PATH" HIMMEL_DOCTOR_TIMEOUT_BINS="timeout $c3839_t/no-gtimeout" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C39-gtimeout-darwin' && grepq "$out" -F 'brew install coreutils'; then
        pass "C39 darwin non-functional timeout -> WARN (on PATH is not enough)"
    else
        fail "C39 darwin non-functional timeout -> $(printf '%s' "$out" | grep -A1 C39)"
    fi
fi
rm -rf "$c3839_t"

echo "== C39: Linux without timeout/gtimeout -> no macOS WARN =="
c3839_setup
if [ "$(PATH="$FAKEBIN:$PATH" uname -s)" != Linux ]; then
    fail "C39 linux: precondition — the uname stub did not report Linux"
else
    out="$(PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_TIMEOUT_BINS="$c3839_absent_t" CLAUDE_DIR="$c3839_t/claude" HOME="$c3839_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C39-gtimeout-darwin' && ! grepq "$out" 'WARN C39-gtimeout-darwin'; then
        pass "C39 linux no timeout -> OK (macOS-only check skipped), no WARN"
    else
        fail "C39 linux no timeout -> $(printf '%s' "$out" | grep -A1 C39)"
    fi
fi
rm -rf "$c3839_t"

# --- C78: shfmt presence, reported up front ----
# Seam: HIMMEL_DOCTOR_SHFMT (the shfmt command, default `shfmt`). "Absent" is an
# absolute nonexistent path, "present" a stub first on PATH, as for C38.
c78_setup() {
    c78_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c78.XXXXXX")" || { fail "C78 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c78_t/darwin" "$c78_t/sbin"
    printf '#!/bin/sh\necho Darwin\n' > "$c78_t/darwin/uname"
    printf '#!/bin/sh\nexit 0\n' > "$c78_t/sbin/shfmt"
    chmod +x "$c78_t/darwin/uname" "$c78_t/sbin/shfmt"
    c78_absent="$c78_t/no-shfmt"
}

echo "== C78: no shfmt on Linux -> WARN naming the denied verbs, apt-get remedy (RED) =="
c78_setup
if PATH="$FAKEBIN:$PATH" bash -c 'command -v "$1"' _ "$c78_absent" >/dev/null 2>&1 || [ "$(PATH="$FAKEBIN:$PATH" uname -s)" != Linux ]; then
    fail "C78 linux no-shfmt: precondition — the absent seam resolves or uname is not Linux"
else
    out="$(PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_SHFMT="$c78_absent" CLAUDE_DIR="$c78_t/claude" HOME="$c78_t/home" bash "$DOC" --only C78 --no-color 2>&1)"
    if grepq "$out" 'WARN C78-shfmt' && grepq "$out" -F 'stash, ref-plumbing or graphify verb' \
       && grepq "$out" -F 'apt-get install -y shfmt' && ! grepq "$out" -F 'brew install shfmt'; then
        pass "C78 linux no shfmt -> WARN naming the denied verbs, apt-get remedy"
    else
        fail "C78 linux no shfmt -> $(printf '%s' "$out" | grep -A1 C78)"
    fi
fi
rm -rf "$c78_t"

echo "== C78: no shfmt on Darwin -> remedy is brew install shfmt =="
c78_setup
if [ "$(PATH="$c78_t/darwin:$PATH" uname -s)" != Darwin ]; then
    fail "C78 darwin: precondition — the uname stub did not report Darwin"
else
    out="$(PATH="$c78_t/darwin:$PATH" HIMMEL_DOCTOR_SHFMT="$c78_absent" CLAUDE_DIR="$c78_t/claude" HOME="$c78_t/home" bash "$DOC" --only C78 --no-color 2>&1)"
    if grepq "$out" 'WARN C78-shfmt' && grepq "$out" -F 'brew install shfmt' && ! grepq "$out" -F 'apt-get'; then
        pass "C78 darwin no shfmt -> WARN with the brew remedy"
    else
        fail "C78 darwin no shfmt -> $(printf '%s' "$out" | grep -A1 C78)"
    fi
fi
rm -rf "$c78_t"

echo "== C78: shfmt on PATH -> OK, no WARN =="
c78_setup
if [ "$(PATH="$c78_t/sbin:$FAKEBIN:$PATH" command -v shfmt)" != "$c78_t/sbin/shfmt" ]; then
    fail "C78 present: precondition — the stub shfmt is not what PATH resolves"
else
    out="$(PATH="$c78_t/sbin:$FAKEBIN:$PATH" CLAUDE_DIR="$c78_t/claude" HOME="$c78_t/home" bash "$DOC" --only C78 --no-color 2>&1)"
    if grepq "$out" 'OK   C78-shfmt' && ! grepq "$out" 'WARN C78-shfmt'; then
        pass "C78 shfmt present -> OK, no warning"
    else
        fail "C78 shfmt present -> $(printf '%s' "$out" | grep -A1 C78)"
    fi
fi
rm -rf "$c78_t"

# --- C79: an installed plugin cache that differs from the checkout at the same version ---
# The hooks.json lines are copied from the real station cache
# (~/.claude/plugins/cache/himmel/himmel-ops/0.4.141/hooks/hooks.json): the cache
# lacks the `Bash|` alternative main's egress matcher carries.
c79_main='{ "matcher": "Bash|mcp__.*[Aa][Gg][Ee][Nn][Tt][-_][Nn][Aa][Tt][Ii][Vv][Ee].*" }'
c79_cache='{ "matcher": "mcp__.*[Aa][Gg][Ee][Nn][Tt][-_][Nn][Aa][Tt][Ii][Vv][Ee].*" }'
c79_setup() {   # <cache hooks.json content>
    c79_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c79.XXXXXX")" || { fail "C79 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c79_t/repo/marketplace/.claude-plugin" "$c79_t/repo/marketplace/plugins/p1/.claude-plugin" "$c79_t/repo/marketplace/plugins/p1/hooks" \
             "$c79_t/claude/plugins/cache/himmel/p1/1.0.0/hooks" "$c79_t/home"
    printf '{"name":"himmel","plugins":[{"name":"p1","source":"./plugins/p1"}]}\n' > "$c79_t/repo/marketplace/.claude-plugin/marketplace.json"
    printf '{"name":"p1","version":"1.0.0"}\n' > "$c79_t/repo/marketplace/plugins/p1/.claude-plugin/plugin.json"
    printf '%s\n' "$c79_main" > "$c79_t/repo/marketplace/plugins/p1/hooks/hooks.json"
    printf '%s\n' "$1" > "$c79_t/claude/plugins/cache/himmel/p1/1.0.0/hooks/hooks.json"
    printf '{"version":2,"plugins":{"p1@himmel":[{"scope":"user","installPath":"%s","version":"1.0.0"}]}}\n' \
        "$c79_t/claude/plugins/cache/himmel/p1/1.0.0" > "$c79_t/claude/plugins/installed_plugins.json"
    printf '{"enabledPlugins":{"p1@himmel":true}}\n' > "$c79_t/claude/settings.json"
}
echo "== C79: a same-version cache whose hooks.json differs from the checkout -> WARN naming the file (RED) =="
c79_setup "$c79_cache"
out="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
if grepq "$out" 'WARN C79-plugin-cache-drift' && grepq "$out" -F 'p1@himmel' && grepq "$out" -F 'hooks/hooks.json' && grepq "$out" -F 'himmel-update.sh --only plugin-refresh'; then
    pass "C79 drifted cache -> WARN naming the plugin, the file and the repair"
else
    fail "C79 drifted cache -> $(printf '%s' "$out" | grep -A1 C79)"
fi
rm -rf "$c79_t"

echo "== C79: an identical cache -> OK, no WARN =="
c79_setup "$c79_main"
out="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
if grepq "$out" 'OK   C79-plugin-cache-drift' && ! grepq "$out" 'WARN C79-plugin-cache-drift'; then
    pass "C79 identical cache -> OK"
else
    fail "C79 identical cache -> $(printf '%s' "$out" | grep -A1 C79)"
fi
rm -rf "$c79_t"

echo "== C79: a cache at an older version than the checkout is not this check's finding =="
c79_setup "$c79_cache"
printf '{"name":"p1","version":"1.0.1"}\n' > "$c79_t/repo/marketplace/plugins/p1/.claude-plugin/plugin.json"
out="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
printf '{"name":"p1","version":"1.0.0"}\n' > "$c79_t/repo/marketplace/plugins/p1/.claude-plugin/plugin.json"
out_same="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
if ! grepq "$out" 'C79-plugin-cache-drift' && grepq "$out_same" 'WARN C79-plugin-cache-drift'; then
    pass "C79 version lag -> no drift finding (the same fixture at equal versions WARNs)"
else
    fail "C79 version lag -> $(printf '%s' "$out" | grep -A1 C79) / equal: $(printf '%s' "$out_same" | grep -A1 C79)"
fi
rm -rf "$c79_t"

echo "== C79: a disabled plugin is skipped, since the repair leaves it alone (RED) =="
c79_setup "$c79_cache"
printf '{"enabledPlugins":{"p1@himmel":false}}\n' > "$c79_t/claude/settings.json"
out="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
printf '{"enabledPlugins":{"p1@himmel":true}}\n' > "$c79_t/claude/settings.json"
out_on="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
if ! grepq "$out" 'C79-plugin-cache-drift' && grepq "$out_on" 'WARN C79-plugin-cache-drift'; then
    pass "C79 disabled plugin -> no drift finding (the same fixture enabled WARNs)"
else
    fail "C79 disabled plugin -> $(printf '%s' "$out" | grep -A1 C79) / enabled: $(printf '%s' "$out_on" | grep -A1 C79)"
fi
rm -rf "$c79_t"

echo "== C79: a skills-only drift (hooks identical) -> WARN naming the skill file (RED) =="
c79_setup "$c79_main"
mkdir -p "$c79_t/repo/marketplace/plugins/p1/skills/s" "$c79_t/claude/plugins/cache/himmel/p1/1.0.0/skills/s"
printf 'new\n' > "$c79_t/repo/marketplace/plugins/p1/skills/s/SKILL.md"
printf 'old\n' > "$c79_t/claude/plugins/cache/himmel/p1/1.0.0/skills/s/SKILL.md"
out="$(CLAUDE_DIR="$c79_t/claude" HOME="$c79_t/home" bash "$DOC" --only C79 --no-color --root "$c79_t/repo" 2>&1)"
if grepq "$out" 'WARN C79-plugin-cache-drift' && grepq "$out" -F 'skills/s/SKILL.md'; then
    pass "C79 skills-only drift -> WARN naming the skill file"
else
    fail "C79 skills-only drift -> $(printf '%s' "$out" | grep -A1 C79)"
fi
rm -rf "$c79_t"

# --- C40: qmd vector-search health ------------------------------
# Seam: HIMMEL_DOCTOR_QMD_CURL (the curl binary C40 uses, default `curl`). The
# stub answers by C40_MODE and logs each call's -m bound + JSON-RPC method, so a
# case can assert the vec probe is BOUNDED (-m) and really sent a vec sub-query.
# Every case runs the stub against the init payload first (precondition) so a
# stub that silently failed to take effect cannot pass.
c40_setup() {
    c40_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c40.XXXXXX")" || { fail "C40 setup: mktemp -d failed"; exit 1; }
    cat > "$c40_t/curl" <<'STUB'
#!/usr/bin/env bash
m=""; d=""; w=""; k=""
while [ $# -gt 0 ]; do
    case "$1" in -m) m="$2"; shift ;; -d) d="$2"; shift ;; -w) w="$2"; shift ;; -K) k=$(cat) ;; esac
    shift
done
mode="${C40_MODE:-ok}"
# Like real curl, `-w %{http_code}` appends the status AFTER the body ("000" when
# no HTTP exchange happened); finish <code> [rc] models that and exits.
finish() { [ -n "$w" ] && printf '%s' "$1"; exit "${2:-0}"; }
# The live daemon frames every reply as an SSE event (`event: message`, then
# `data: <json>`), not a bare JSON body -- model that by default. C40_FRAME=plain
# gives the bare body so both framings stay covered.
pfx() { [ "${C40_FRAME:-sse}" = sse ] && printf 'event: message\ndata: '; return 0; }
note=""
[ "$mode" = novec ] && note=" Note: No vector embeddings yet. Run \`qmd embed\` to enable semantic search."
[ "$mode" = stale ] && note=" Note: ${C40_PENDING:-12} documents need embedding. Run \`qmd embed\`."
case "$d" in
    *'"method":"initialize"'*)
        echo "init m=$m" >> "$C40_LOG"
        case "$mode" in
            down|downfb|downstart) finish 000 7 ;;
            inithang) finish 000 28 ;;
            slowinit) [ "${m:-0}" -lt 8 ] && finish 000 28 ;;
            reset) finish 000 52 ;;
            empty204) finish 204 0 ;;
            foreign) pfx; printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"other-server"}}}'; finish 200 ;;
            # the daemon's real reply without its bearer token.
            auth) case "$k" in *"Authorization: Bearer "*) ;; *) printf '%s' '{"error":"Unauthorized"}'; finish 401 ;; esac ;;
        esac
        [ "$mode" = init_multiline ] && { printf '{\n  "result": {\n    "serverInfo": {\n      "version": "2.8.3",\n      "name": "qmd"\n    }\n  }\n}\n'; finish 200; }
        pfx; printf '%s' "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"qmd\",\"version\":\"2.8.3\"},\"instructions\":\"QMD is your local search engine.$note\"}}"
        finish 200 ;;
    *'"type":"vec"'*)
        echo "vec m=$m" >> "$C40_LOG"
        case "$mode" in
            hang) exit 28 ;;
            # the fork's real answer to a vec-only search while the embedder is down or the breaker is open:
            # no isError, "No results returned" text, structuredContent.embedSkipped true (test/mcp-embed-fallback.test.ts)
            embedskip) pfx; printf '%s' '{"result":{"content":[{"type":"text","text":"No results returned for \"qmd doctor probe\". Note: the embedding service did not answer in time or is down; the meaning-based part of the search was skipped, so this is not a confirmed miss."}],"structuredContent":{"results":[],"embedSkipped":true}},"jsonrpc":"2.0","id":2}'; exit 0 ;;
            iserror) pfx; printf '%s' '{"result":{"content":[{"type":"text","text":"embedding model failed to load"}],"isError":true},"jsonrpc":"2.0","id":2}'; exit 0 ;;
            rpcerr) pfx; printf '%s' '{"error":{"code":-32603,"message":"vector store unavailable"},"jsonrpc":"2.0","id":2}'; exit 0 ;;
            garbage) pfx; printf '%s' 'not json at all'; exit 0 ;;
            trunc) pfx; printf '%s' '{"jsonrpc":"2.0","id":2,"result":'; exit 0 ;;
            truncobj) pfx; printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"No res'; exit 0 ;;
            partial) pfx; printf '%s' '{"result":{"content":[{"type":"text","text":"x"'; exit 18 ;;
            iserror_spaced) pfx; printf '%s' '{"result": {"content": [{"type": "text", "text": "embedding model failed to load"}], "isError": true}, "jsonrpc": "2.0", "id": 2}'; exit 0 ;;
        esac
        pfx; printf '%s' '{"result":{"content":[{"type":"text","text":"No results found"}],"structuredContent":{"results":[]}},"jsonrpc":"2.0","id":2}'
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$c40_t/curl"
    : > "$c40_t/log"
    # the alert sender stub: one line per delivered alert, never the real Telegram path
    cat > "$c40_t/send" <<'SEND'
#!/usr/bin/env bash
printf '%s %s\n' "${HIMMEL_ALERT_KIND:-}" "$1" >> "$C40_SENT"
SEND
    chmod +x "$c40_t/send"; : > "$c40_t/sent"
    mkdir -p "$c40_t/qmdbin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$c40_t/qmdbin/qmd"; chmod +x "$c40_t/qmdbin/qmd"
    c40_nq_path=""
    local d
    IFS=: read -ra c40_path_dirs <<< "$PATH"
    for d in "${c40_path_dirs[@]}"; do [ -x "$d/qmd" ] || c40_nq_path="${c40_nq_path:+$c40_nq_path:}$d"; done
}
# C40 composes himmelctl status's qmd-daemon item, so a case feeds it
# a status fixture (DOCTOR_STATUS_JSON) instead of running a 13s real status.
c40_status() { # <desired true|false> <actual> <detail> — writes $c40_t/status.json
    jq -n --argjson d "$1" --arg a "$2" --arg t "$3" '{items:[{id:"qmd-daemon",desired:$d,actual:$a,detail:$t}]}' > "$c40_t/status.json"
}
c40_probe_fixture() {
    local p="$c40_nq_path" node_bin
    local item_id=qmd-daemon # t13b-ok: manifest item id passed to the probe, starts nothing
    node_bin="$(command -v node)" || { fail "C40 probe fixture: node required"; return 1; }
    [ "$2" = yes ] && p="$c40_t/qmdbin:$p"
    env -u XDG_CONFIG_HOME -u QMD_HTTP_AUTH_FILE -u QMD_HTTP_TOKEN_FILE -u BUN_INSTALL \
        PATH="$p" HOME="$c40_t/home" C40_MODE="$1" C40_LOG=/dev/null HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" HIMMEL_DOCTOR_QMD_URL=http://localhost:1/mcp \
        "$node_bin" -e '
const fs = require("fs"); const [root, id] = process.argv.slice(1);
const { runProbe } = require(root + "/scripts/himmelctl/lib/probes.js");
const item = JSON.parse(fs.readFileSync(root + "/scripts/install/manifest.json", "utf8")).items.find((i) => i.id === id);
const v = runProbe(item, { repoRoot: root, targetPath: root, scope: "user", env: process.env });
console.log(JSON.stringify({ items: [{ id, desired: true, actual: v.actual, detail: v.detail }] }));
' "$REPO_ROOT" "$item_id" > "$c40_t/status.json"
}
c40_run() { # <mode>
    case "$1" in
        down) c40_probe_fixture down "${C40_QMD_SETUP:-yes}" ;;
        probeok) c40_probe_fixture probeok yes ;;
        downfb) rm -f "$c40_t/status.json" ;;
        downstart) c40_status true starting "the qmd daemon is starting (start marker 5s old)" ;;
        inithang) c40_status true degraded "a process accepted the connection but did not answer initialize within 10s -- wedged" ;;
        reset|empty204) c40_status true degraded "a process returned no usable initialize reply (curl rc=52, HTTP 204)" ;;
        foreign) c40_status true degraded "a process answers but it is NOT qmd (initialize reply has no qmd serverInfo)" ;;
        *) c40_status true present "initialize answered in 0.3s" ;;
    esac
    # CI runners export XDG_CONFIG_HOME, which would point the token path past the fixture HOME.
    env -u XDG_CONFIG_HOME -u QMD_HTTP_AUTH_FILE -u QMD_HTTP_TOKEN_FILE \
        PATH="$FAKEBIN:$PATH" C40_MODE="$1" C40_PENDING="${C40_PENDING:-12}" C40_LOG="$c40_t/log" HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" DOCTOR_STATUS_JSON="$c40_t/status.json" \
        C40_SENT="$c40_t/sent" CADENCE_ALERT_SEND_CMD="$c40_t/send" HIMMEL_DOCTOR_QMD_BIN="${C40_QMD_BIN:-$c40_t/qmdbin/qmd}" \
        CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1
}
c40_precond() { # <mode> — the stub must answer the init payload the way the mode says
    local got rc
    got="$(C40_MODE="$1" C40_LOG="$c40_t/log" "$c40_t/curl" -s -m 3 -d '{"method":"initialize"}' http://x)"; rc=$?
    : > "$c40_t/log"
    case "$1" in
        down) [ "$rc" -eq 7 ] && [ -z "$got" ] ;;
        inithang|slowinit) [ "$rc" -eq 28 ] && [ -z "$got" ] ;;
        reset) [ "$rc" -eq 52 ] && [ -z "$got" ] ;;
        empty204) [ "$rc" -eq 0 ] && [ -z "$got" ] ;;
        *) [ "$rc" -eq 0 ] && [ -n "$got" ] ;;
    esac
}

echo "== C40: operator opt-out flag -> INFO 'qmd off by operator', no probe (HIMMEL-4494) =="
c40_setup
mkdir -p "$c40_t/home/.himmel/state"; : > "$c40_t/home/.himmel/state/qmd-daemon.off"
out="$(c40_run down)"
if grepq "$out" 'INFO C40-qmd-vec.*qmd off by operator' && ! grepq "$out" 'WARN C40-qmd-vec' && [ ! -s "$c40_t/log" ]; then
    pass "C40 opt-out flag -> INFO qmd off by operator, curl never called"
else
    fail "C40 opt-out flag -> $(printf '%s' "$out" | grep C40) log=$(tr '\n' ' ' < "$c40_t/log")"
fi
rm -rf "$c40_t"

echo "== C40: served vec probe -> OK, probe bounded and really vec (RED) =="
c40_setup
if ! c40_precond ok; then fail "C40 ok: precondition — stub did not answer init"
else
    out="$(c40_run ok)"
    if grepq "$out" 'OK   C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec' && grep -Eq '^vec m=[0-9]+$' "$c40_t/log"; then
        pass "C40 served vec probe -> OK; vec sub-query sent with a -m bound"
    else
        fail "C40 served vec probe -> $(printf '%s' "$out" | grep -A1 C40) log=$(tr '\n' ' ' < "$c40_t/log")"
    fi
fi
rm -rf "$c40_t"

echo "== C40: daemon that requires the bearer token (HIMMEL-5227, RED) =="
c40_setup
out="$(c40_run auth)"
if grepq "$out" 'WARN C40-qmd-vec.*HTTP 401.*bearer token' && ! grepq "$out" 'NOT qmd'; then
    pass "C40 401 without a token file -> WARN naming the bearer token, not NOT-qmd"
else
    fail "C40 401 without a token file -> $(printf '%s' "$out" | grep -A1 C40)"
fi
mkdir -p "$c40_t/home/.config/qmd"; printf 'tok-for-the-test-only\n' > "$c40_t/home/.config/qmd/http-token"; chmod 600 "$c40_t/home/.config/qmd/http-token"
out="$(c40_run auth)"
if grepq "$out" 'OK   C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
    pass "C40 with the token file -> initialize and vec probe authenticate -> OK"
else
    fail "C40 with the token file -> $(printf '%s' "$out" | grep -A1 C40)"
fi
rm -rf "$c40_t"

echo "== C40: slow-but-alive daemon (initialize answers in ~5s under load) -> OK, not a wedge WARN (HIMMEL-4383, RED) =="
c40_setup
if ! c40_precond slowinit; then fail "C40 slowinit: precondition — stub did not time out at -m 3"
else
    out="$(c40_run slowinit)"
    if grepq "$out" 'OK   C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
        pass "C40 slow-but-alive initialize -> OK (budget covers loaded latency)"
    else
        fail "C40 slow-but-alive initialize -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-4432): the verdict FOLLOWS himmelctl status's qmd-daemon item, not C40's own probe (RED) =="
# The stub curl answers every initialize happily (mode ok); only the status
# fixture varies, so a verdict that tracks the fixture cannot come from a probe.
c40_setup
c40_status false absent "not wanted"
out="$(PATH="$FAKEBIN:$PATH" C40_MODE=ok C40_LOG="$c40_t/log" HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" DOCTOR_STATUS_JSON="$c40_t/status.json" CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C40-qmd-vec' && grepq "$out" -F 'not wanted' && ! grepq "$out" 'WARN C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec' && [ ! -s "$c40_t/log" ]; then
    pass "C40 qmd-daemon desired=false -> INFO not wanted, no daemon contact"
else
    fail "C40 not wanted -> $(printf '%s' "$out" | grep -A1 C40) log=$(tr '\n' ' ' < "$c40_t/log")"
fi
c40_status true absent "no qmd daemon answering"
out="$(PATH="$FAKEBIN:$PATH" C40_MODE=ok C40_LOG="$c40_t/log" HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" DOCTOR_STATUS_JSON="$c40_t/status.json" CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec' && [ ! -s "$c40_t/log" ]; then
    pass "C40 status says absent (stub would answer) -> INFO skip, follows status"
else
    fail "C40 status absent -> $(printf '%s' "$out" | grep -A1 C40) log=$(tr '\n' ' ' < "$c40_t/log")"
fi
c40_status true degraded "status-owned wedge detail"
out="$(PATH="$FAKEBIN:$PATH" C40_MODE=ok C40_LOG="$c40_t/log" HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" DOCTOR_STATUS_JSON="$c40_t/status.json" CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'status-owned wedge detail' && ! grepq "$out" 'OK   C40-qmd-vec' && [ ! -s "$c40_t/log" ]; then
    pass "C40 status says degraded (stub would answer) -> WARN carrying status's detail"
else
    fail "C40 status degraded -> $(printf '%s' "$out" | grep -A1 C40) log=$(tr '\n' ' ' < "$c40_t/log")"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-4432): unknown status (no qmd-daemon item) keeps C40's own probe, never a silent pass =="
c40_setup
printf '{"items":[]}' > "$c40_t/status.json"
out="$(PATH="$FAKEBIN:$PATH" C40_MODE=inithang C40_LOG="$c40_t/log" HIMMEL_DOCTOR_QMD_CURL="$c40_t/curl" DOCTOR_STATUS_JSON="$c40_t/status.json" CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'did not answer'; then
    pass "C40 no qmd-daemon item in status -> own probe still WARNs on a wedge"
else
    fail "C40 unknown status -> $(printf '%s' "$out" | grep -A1 C40)"
fi
rm -rf "$c40_t"

# A pinned daemon answers a down embedder within its 15 s budget (the embedskip row below); this row
# still proves the probe's own curl bound: a daemon that never answers at all (wedged server, or a
# pre-breaker pin) gives curl rc 28 -> WARN, never OK.
echo "== C40: vec query hangs (curl rc 28) -> WARN naming the timeout, not OK =="
c40_setup
if ! c40_precond hang; then fail "C40 hang: precondition — stub did not answer init"
else
    out="$(c40_run hang)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'timed out' && grepq "$out" -F 'vector' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 hung vec query -> WARN naming the timeout"
    else
        fail "C40 hung vec query -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: embed skipped (vec-only answer with structuredContent.embedSkipped) -> WARN, not OK =="
c40_setup
if ! c40_precond embedskip; then fail "C40 embedskip: precondition — stub did not answer init"
else
    out="$(c40_run embedskip)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'embedder did not answer' && grepq "$out" -F 'vec search is not being served' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 embed skipped -> WARN naming the embedder, not OK"
    else
        fail "C40 embed skipped -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: vec tool error -> WARN carrying the daemon's own reason =="
c40_setup
if ! c40_precond iserror; then fail "C40 iserror: precondition — stub did not answer init"
else
    out="$(c40_run iserror)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'embedding model failed to load'; then
        pass "C40 vec tool error -> WARN with the daemon's reason"
    else
        fail "C40 vec tool error -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: JSON-RPC error on the vec probe -> WARN carrying the message =="
c40_setup
if ! c40_precond rpcerr; then fail "C40 rpcerr: precondition — stub did not answer init"
else
    out="$(c40_run rpcerr)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'vector store unavailable'; then
        pass "C40 JSON-RPC error -> WARN with the message"
    else
        fail "C40 JSON-RPC error -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: unrecognised vec reply -> WARN, never a false OK =="
c40_setup
if ! c40_precond garbage; then fail "C40 garbage: precondition — stub did not answer init"
else
    out="$(c40_run garbage)"
    if grepq "$out" 'WARN C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 unrecognised reply -> WARN (a vec probe that proved nothing is not OK)"
    else
        fail "C40 unrecognised reply -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: index has no vector embeddings -> WARN naming qmd embed =="
c40_setup
if ! c40_precond novec; then fail "C40 novec: precondition — stub did not answer init"
else
    out="$(c40_run novec)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'no vector index' && grepq "$out" -F 'qmd embed'; then
        pass "C40 no vector index -> WARN with the qmd embed remedy"
    else
        fail "C40 no vector index -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-6324): daemon started before the installed qmd build -> WARN stale daemon, not 'no vector index' (RED) =="
c40_setup
mkdir -p "$c40_t/home/.cache/qmd" "$c40_t/home/.himmel/qmd-fork"
echo $$ > "$c40_t/home/.cache/qmd/mcp.pid"
echo c3b84dd > "$c40_t/home/.himmel/qmd-fork/.himmel-build-ok"
touch -t 202610180048 "$c40_t/home/.cache/qmd/mcp.pid"
touch -t 202610180405 "$c40_t/home/.himmel/qmd-fork/.himmel-build-ok"
if ! c40_precond novec; then fail "C40 stale daemon: precondition — stub did not answer init"
else
    out="$(XDG_CACHE_HOME="$c40_t/home/.cache" QMD_FORK_DIR="$c40_t/home/.himmel/qmd-fork" c40_run novec)"
    if grepq "$out" 'WARN C40-qmd-vec.*older than the installed qmd build' && grepq "$out" -F "ensure-qmd-daemon.sh --recycle-if-stale $c40_t/home/.himmel/qmd-fork/.himmel-build-ok" && ! grepq "$out" -F 'pkill' && ! grepq "$out" -F 'pgrep -af' && ! grepq "$out" -F 'no vector index'; then
        pass "C40 daemon older than the build -> WARN stale daemon naming the one-command recycle with the build stamp, no process-list kill"
    else
        fail "C40 daemon older than the build -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
    sleep 0 & c40_dead=$!; wait "$c40_dead"
    echo "$c40_dead" > "$c40_t/home/.cache/qmd/mcp.pid"
    touch -t 202610180048 "$c40_t/home/.cache/qmd/mcp.pid"
    out="$(XDG_CACHE_HOME="$c40_t/home/.cache" QMD_FORK_DIR="$c40_t/home/.himmel/qmd-fork" c40_run novec)"
    if grepq "$out" -F 'no vector index' && ! grepq "$out" -F 'older than the installed'; then
        pass "C40 leftover pid file of a dead daemon -> no stale-daemon WARN"
    else
        fail "C40 leftover pid file of a dead daemon -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
    echo $$ > "$c40_t/home/.cache/qmd/mcp.pid"
    touch -t 202610180500 "$c40_t/home/.cache/qmd/mcp.pid"
    out="$(XDG_CACHE_HOME="$c40_t/home/.cache" QMD_FORK_DIR="$c40_t/home/.himmel/qmd-fork" c40_run novec)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'no vector index' && ! grepq "$out" -F 'older than the installed'; then
        pass "C40 daemon started after the build -> the no-vector-index WARN stands"
    else
        fail "C40 daemon started after the build -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-4860): documents awaiting embedding at/above the floor -> WARN with count + fix =="
c40_setup
if ! c40_precond stale; then fail "C40 backlog: precondition — stub did not answer init"
else
    out="$(C40_PENDING=462 c40_run stale)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F '462 docs not embedded, invisible to vec search' && grepq "$out" -F 'qmd-reindex.sh'; then
        pass "C40 backlog 462 -> WARN naming count and the fix"
    else
        fail "C40 backlog 462 -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
    out="$(C40_PENDING=50 c40_run stale)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F '50 docs not embedded'; then
        pass "C40 backlog at the floor (50) -> WARN"
    else
        fail "C40 backlog at floor -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
    out="$(C40_PENDING=49 c40_run stale)"
    if grepq "$out" 'INFO C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
        pass "C40 backlog just under the floor (49) -> INFO only"
    else
        fail "C40 backlog 49 -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
    out="$(C40_PENDING=462 HIMMEL_DOCTOR_QMD_PENDING_WARN=1000 c40_run stale)"
    if grepq "$out" 'INFO C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
        pass "C40 HIMMEL_DOCTOR_QMD_PENDING_WARN raises the floor"
    else
        fail "C40 floor override -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: documents awaiting embedding -> OK plus an INFO naming the count =="
c40_setup
if ! c40_precond stale; then fail "C40 stale: precondition — stub did not answer init"
else
    out="$(c40_run stale)"
    if grepq "$out" 'OK   C40-qmd-vec' && grepq "$out" 'INFO C40-qmd-vec' && grepq "$out" -F '12 documents'; then
        pass "C40 documents awaiting embedding -> OK + INFO count"
    else
        fail "C40 documents awaiting embedding -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel): initialize itself times out (daemon holds the port but is wedged) -> WARN, not the optional-service INFO skip =="
c40_setup
if ! c40_precond inithang; then fail "C40 inithang: precondition — stub did not time out on init"
else
    out="$(c40_run inithang)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'did not answer' && ! grepq "$out" 'INFO C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 initialize timeout -> WARN (a wedged daemon is not an absent one)"
    else
        fail "C40 initialize timeout -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel): pretty-printed \"isError\": true tool error -> WARN, never a false OK =="
c40_setup
if ! c40_precond iserror_spaced; then fail "C40 iserror_spaced: precondition — stub did not answer init"
else
    out="$(c40_run iserror_spaced)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'embedding model failed to load' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 spaced isError:true -> WARN with the daemon's reason"
    else
        fail "C40 spaced isError:true -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel r2): pretty-printed initialize (serverInfo/name on separate lines) is still qmd -> OK, not a foreign-listener WARN =="
c40_setup
if ! c40_precond init_multiline; then fail "C40 init_multiline: precondition — stub did not answer init"
else
    out="$(c40_run init_multiline)"
    if grepq "$out" 'OK   C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
        pass "C40 multi-line initialize reply -> recognised as qmd"
    else
        fail "C40 multi-line initialize reply -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel r2): truncated vec reply (rc 0, body cut before the result object) -> WARN, never OK =="
c40_setup
if ! c40_precond trunc; then fail "C40 trunc: precondition — stub did not answer init"
else
    out="$(c40_run trunc)"
    if grepq "$out" 'WARN C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 truncated reply -> WARN"
    else
        fail "C40 truncated reply -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel r3): body cut INSIDE the result object (curl rc 0, opens with {\"result\":{) -> WARN unparseable, never OK =="
c40_setup
if ! c40_precond truncobj; then fail "C40 truncobj: precondition — stub did not answer init"
else
    out="$(c40_run truncobj)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'unparseable' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 body cut inside the result object -> WARN unparseable"
    else
        fail "C40 body cut inside the result object -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel r3): a bare JSON reply (no SSE framing) is classified the same way =="
c40_setup
if ! C40_FRAME=plain c40_precond ok; then fail "C40 plain: precondition — stub did not answer init"
else
    out_ok="$(C40_FRAME=plain c40_run ok)"
    out_cut="$(C40_FRAME=plain c40_run truncobj)"
    if grepq "$out_ok" 'OK   C40-qmd-vec' && ! grepq "$out_ok" 'WARN C40-qmd-vec' \
        && grepq "$out_cut" 'WARN C40-qmd-vec' && ! grepq "$out_cut" 'OK   C40-qmd-vec'; then
        pass "C40 bare JSON reply -> OK when whole, WARN when cut"
    else
        fail "C40 bare JSON reply -> ok:[$(printf '%s' "$out_ok" | grep C40)] cut:[$(printf '%s' "$out_cut" | grep C40)]"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (CR panel r2): vec reply cut off mid-transfer (curl rc 18 with a partial body) -> WARN, never OK =="
c40_setup
if ! c40_precond partial; then fail "C40 partial: precondition — stub did not answer init"
else
    out="$(c40_run partial)"
    if grepq "$out" 'WARN C40-qmd-vec' && ! grepq "$out" 'OK   C40-qmd-vec'; then
        pass "C40 mid-transfer cut-off -> WARN"
    else
        fail "C40 mid-transfer cut-off -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10928): refused connection where qmd is set up -> WARN naming the url, never 'optional' (RED) =="
c40_setup
if ! c40_precond down; then fail "C40 down: precondition — stub did not fail init"
else
    out="$(c40_run down)"
    c40_line="$(printf '%s' "$out" | grep -A1 C40-qmd-vec)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$c40_line" -F 'localhost:1/mcp' && grepq "$c40_line" 'not answering' \
        && ! grepq "$c40_line" 'optional' && ! grep -q '^vec ' "$c40_t/log"; then
        pass "C40 refused, qmd set up -> WARN naming the url, no 'optional', no vec probe"
    else
        fail "C40 refused, qmd set up -> $c40_line status=$(cat "$c40_t/status.json")"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10928): refused connection on a station with no qmd setup -> INFO skip, qmd is optional =="
c40_setup
out="$(C40_QMD_SETUP=no c40_run down)"
if grepq "$out" 'INFO C40-qmd-vec.*qmd is optional' && ! grepq "$out" 'WARN C40-qmd-vec' && ! grep -q '^vec ' "$c40_t/log"; then
    pass "C40 refused, no qmd setup -> INFO skip (qmd is optional), no vec probe"
else
    fail "C40 refused, no qmd setup -> $(printf '%s' "$out" | grep -A1 C40) status=$(cat "$c40_t/status.json")"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10928): qmd set up and answering, verdict from the real probe -> OK, no WARN =="
c40_setup
out="$(c40_run probeok)"
if grepq "$out" 'OK   C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec' && grep -q '"actual":"present"' "$c40_t/status.json"; then
    pass "C40 qmd up (real probe present) -> OK, no WARN"
else
    fail "C40 qmd up -> $(printf '%s' "$out" | grep -A1 C40) status=$(cat "$c40_t/status.json")"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10933): a refused connection where qmd is set up sends ONE alert per outage, re-armed once qmd answers (RED) =="
c40_setup
c40_run down >/dev/null; c40_run down >/dev/null
c40_n1="$(grep -c . "$c40_t/sent")"
c40_msg="$(head -n1 "$c40_t/sent")"
c40_run probeok >/dev/null
c40_run down >/dev/null
c40_n2="$(grep -c . "$c40_t/sent")"
c40_run iserror >/dev/null
c40_run down >/dev/null
c40_n3="$(grep -c . "$c40_t/sent")"
c40_run empty204 >/dev/null
c40_run down >/dev/null
c40_n4="$(grep -c . "$c40_t/sent")"
if [ "$c40_n1" = 1 ] && printf '%s' "$c40_msg" | grep -Fq 'cadence:qmd-outage qmd-outage: ' && printf '%s' "$c40_msg" | grep -Fq 'not answering' \
    && grep -Fq 'qmd-outage' "$c40_t/home/.himmel/state/cadence-alerts.log" && [ "$c40_n2" = 2 ] && [ "$c40_n3" = 3 ] && [ "$c40_n4" = 4 ]; then
    pass "C40 refused, qmd set up -> exactly one alert across two runs, a second after the daemon answered in between"
else
    fail "C40 outage alert -> after two refused runs: $c40_n1 sent (want 1), after recovery and a new outage: $c40_n2 (want 2), after a daemon that answered but failed its vec query and a third outage: $c40_n3 (want 3), after a status-reported empty 204 reply and a fourth outage: $c40_n4 (want 4); first message [$c40_msg]"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10933): a refused connection with no qmd setup, or a starting daemon, sends no alert =="
c40_setup
out_a="$(C40_QMD_SETUP=no c40_run down)"
out_b="$(c40_run downstart)"
if [ ! -s "$c40_t/sent" ] && grepq "$out_a" 'INFO C40-qmd-vec' && ! grepq "$out_a" 'WARN C40-qmd-vec' \
    && grepq "$out_b" 'INFO C40-qmd-vec.*is starting' && ! grepq "$out_b" 'WARN C40-qmd-vec'; then
    pass "C40 no qmd setup / daemon starting -> no alert"
else
    fail "C40 no-alert cases -> sent: $(cat "$c40_t/sent")"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10933): status unreadable and the connection refused where qmd is set up -> WARN naming the url, never 'optional', one alert (RED) =="
c40_setup
if ! c40_precond down; then fail "C40 downfb: precondition — stub did not fail init"
else
    out="$(c40_run downfb)"; c40_run downfb >/dev/null
    c40_line="$(printf '%s' "$out" | grep -A1 C40-qmd-vec)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$c40_line" -F 'localhost:8181/mcp' && grepq "$c40_line" 'not answering' \
        && ! grepq "$c40_line" 'optional' && [ "$(grep -c . "$c40_t/sent")" = 1 ]; then
        pass "C40 fallback refused, qmd set up -> WARN, no 'optional', one alert across two runs"
    else
        fail "C40 fallback refused, qmd set up -> $c40_line sent=$(grep -c . "$c40_t/sent")"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-10933): status unreadable and the connection refused with no qmd setup -> INFO skip, no alert =="
c40_setup
out="$(C40_QMD_BIN="$c40_t/no-such-qmd" c40_run downfb)"
if grepq "$out" 'INFO C40-qmd-vec.*qmd is optional' && ! grepq "$out" 'WARN C40-qmd-vec' && [ ! -s "$c40_t/sent" ]; then
    pass "C40 fallback refused, no qmd setup -> INFO skip (qmd is optional), no alert"
else
    fail "C40 fallback refused, no qmd setup -> $(printf '%s' "$out" | grep -A1 C40) sent=$(cat "$c40_t/sent")"
fi
rm -rf "$c40_t"

echo "== C40: foreign listener on the qmd port -> WARN, no vec probe =="
c40_setup
if ! c40_precond foreign; then fail "C40 foreign: precondition — stub did not answer init"
else
    out="$(c40_run foreign)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'NOT qmd' && ! grep -q '^vec ' "$c40_t/log"; then
        pass "C40 foreign listener -> WARN, vec probe not sent to a non-qmd server"
    else
        fail "C40 foreign listener -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40: curl seam absent -> INFO skip =="
c40_setup
out="$(PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_QMD_CURL="$c40_t/no-such-curl" CLAUDE_DIR="$c40_t/claude" HOME="$c40_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C40-qmd-vec' && ! grepq "$out" 'WARN C40-qmd-vec'; then
    pass "C40 no curl -> INFO skip"
else
    fail "C40 no curl -> $(printf '%s' "$out" | grep -A1 C40)"
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-3224): an unusable HIMMEL_DOCTOR_QMD_VEC_TIMEOUT falls back to 30 with one INFO naming it (curl -m 0 = no timeout = a hang) =="
for c40_bad in 0 abc 1.5 -5 ''; do
    c40_setup
    if ! c40_precond ok; then fail "C40 timeout '$c40_bad': precondition — stub did not answer init"
    else
        out="$(HIMMEL_DOCTOR_QMD_VEC_TIMEOUT="$c40_bad" c40_run ok)"
        if grep -qx 'vec m=30' "$c40_t/log" && grepq "$out" 'INFO C40-qmd-vec' \
            && grepq "$out" -F "HIMMEL_DOCTOR_QMD_VEC_TIMEOUT='$c40_bad'" && grepq "$out" 'OK   C40-qmd-vec'; then
            pass "C40 timeout '$c40_bad' -> probe bounded at 30s + INFO naming the rejected value"
        else
            fail "C40 timeout '$c40_bad' -> vec bound=[$(grep '^vec ' "$c40_t/log")] $(printf '%s' "$out" | grep -A1 C40)"
        fi
    fi
    rm -rf "$c40_t"
done

echo "== C40 (HIMMEL-3224): a valid positive-integer timeout passes through, no rejection INFO =="
c40_setup
if ! c40_precond ok; then fail "C40 timeout 7: precondition — stub did not answer init"
else
    out="$(HIMMEL_DOCTOR_QMD_VEC_TIMEOUT=7 c40_run ok)"
    if grep -qx 'vec m=7' "$c40_t/log" && ! grepq "$out" -F 'HIMMEL_DOCTOR_QMD_VEC_TIMEOUT='; then
        pass "C40 timeout 7 -> used as-is, silent"
    else
        fail "C40 timeout 7 -> vec bound=[$(grep '^vec ' "$c40_t/log")] $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-3224): HTTP 204 / empty initialize body is a WARN naming the status, not 'no server answering' =="
c40_setup
if ! c40_precond empty204; then fail "C40 empty204: precondition — stub did not return an empty 204"
else
    out="$(c40_run empty204)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'HTTP 204' && ! grepq "$out" -F 'no qmd server answering' \
        && ! grepq "$out" 'INFO C40-qmd-vec' && ! grep -q '^vec ' "$c40_t/log"; then
        pass "C40 empty 204 -> WARN naming HTTP 204, no vec probe"
    else
        fail "C40 empty 204 -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

echo "== C40 (HIMMEL-3224): connection dropped without a reply (curl rc 52) is a WARN naming the rc =="
c40_setup
if ! c40_precond reset; then fail "C40 reset: precondition — stub did not fail with rc 52"
else
    out="$(c40_run reset)"
    if grepq "$out" 'WARN C40-qmd-vec' && grepq "$out" -F 'curl rc=52' && ! grepq "$out" -F 'no qmd server answering' && ! grepq "$out" 'INFO C40-qmd-vec'; then
        pass "C40 transport failure rc 52 -> WARN naming the rc"
    else
        fail "C40 transport failure rc 52 -> $(printf '%s' "$out" | grep -A1 C40)"
    fi
fi
rm -rf "$c40_t"

# --- C45-qmd-daemon: daemon RSS + uptime vs the recycle ceiling --
# The qmd daemon grows native memory over hours until vec queries time out. The
# qmd plugin's SessionStart hook recycles it over QMD_RSS_CEILING_MB; this row
# reports RSS and uptime (one ps call, no network) and WARNs over the ceiling.
# Seams: HIMMEL_DOCTOR_QMD_PIDFILE (the daemon pidfile), HIMMEL_DOCTOR_QMD_PS
# (the ps binary; the stub prints C44D_ROW for the pid it is asked about).
# An operator-exported ceiling (0 = off) must not leak into the default cases;
# the 08/lots cases set it per call.
unset QMD_RSS_CEILING_MB
c44d_setup() {
    c44d_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c44.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
    mkdir -p "$c44d_t/home" "$c44d_t/claude"
    echo 4242 > "$c44d_t/mcp.pid"
    # shellcheck disable=SC2016 # the stub expands C44D_ROW at ITS run time
    printf '#!/usr/bin/env bash\n[ -n "${C44D_ROW:-}" ] || exit 1\necho "$C44D_ROW"\n' > "$c44d_t/ps"
    chmod +x "$c44d_t/ps"
}
c44d_run() { # <ps row> [<pidfile>]
    PATH="$FAKEBIN:$PATH" C44D_ROW="$1" HIMMEL_DOCTOR_QMD_PS="$c44d_t/ps" \
        HIMMEL_DOCTOR_QMD_PIDFILE="${2:-$c44d_t/mcp.pid}" \
        CLAUDE_DIR="$c44d_t/claude" HOME="$c44d_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C45-qmd-daemon: under the ceiling -> OK with RSS and uptime (RED) =="
c44d_setup
out="$(c44d_run '1048576 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181')"
if grepq "$out" 'OK   C45-qmd-daemon' && grepq "$out" -F 'RSS 1024 MB' && grepq "$out" -F 'up 04:31:07' && ! grepq "$out" 'WARN C45-qmd-daemon'; then
    pass "C45-qmd-daemon under ceiling -> OK naming RSS + uptime"
else
    fail "C45-qmd-daemon under ceiling -> $(printf '%s' "$out" | grep -A1 C45-qmd-daemon)"
fi
rm -rf "$c44d_t"

echo "== C45-qmd-daemon: over the ceiling -> WARN naming RSS and the ceiling (RED) =="
c44d_setup
out="$(c44d_run '7340032 1-02:03:04 bun /x/dist/cli/qmd.js mcp --http --port 8181')"
if grepq "$out" 'WARN C45-qmd-daemon' && grepq "$out" -F 'RSS 7168 MB' && grepq "$out" -F 'ceiling 4096 MB' && grepq "$out" -F 'up 1-02:03:04'; then
    pass "C45-qmd-daemon over ceiling -> WARN naming RSS, uptime and ceiling"
else
    fail "C45-qmd-daemon over ceiling -> $(printf '%s' "$out" | grep -A1 C45-qmd-daemon)"
fi
rm -rf "$c44d_t"

echo "== C45-qmd-daemon: half a MB over the ceiling still WARNs; a leading-zero ceiling reads as decimal; a non-numeric one is off =="
c44d_setup
out="$(c44d_run '4194816 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181')"
out_oct="$(QMD_RSS_CEILING_MB=08 c44d_run '1048576 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181')"
out_bad="$(QMD_RSS_CEILING_MB=lots c44d_run '7340032 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181')"
if grepq "$out" 'WARN C45-qmd-daemon' && grepq "$out_oct" 'WARN C45-qmd-daemon' && grepq "$out_oct" -F 'ceiling 8 MB' \
    && grepq "$out_bad" 'OK   C45-qmd-daemon'; then
    pass "C45-qmd-daemon compares in KB and reads a leading-zero ceiling as decimal"
else
    fail "C45-qmd-daemon KB/decimal/invalid -> half=[$(printf '%s' "$out" | grep C45-qmd-daemon)] oct=[$(printf '%s' "$out_oct" | grep C45-qmd-daemon)] bad=[$(printf '%s' "$out_bad" | grep C45-qmd-daemon)]"
fi
rm -rf "$c44d_t"

echo "== C45-qmd-daemon: no pidfile / dead pid / non-qmd pid -> silent =="
c44d_setup
out_nopid="$(c44d_run '1048576 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181' "$c44d_t/absent.pid")"
out_dead="$(c44d_run '')"
out_foreign="$(c44d_run '1048576 04:31:07 /usr/bin/vim notes.md')"
if ! grepq "$out_nopid" 'C45-qmd-daemon' && ! grepq "$out_dead" 'C45-qmd-daemon' && ! grepq "$out_foreign" 'C45-qmd-daemon'; then
    pass "C45-qmd-daemon stays silent without a live qmd daemon behind the pidfile"
else
    fail "C45-qmd-daemon silent cases -> nopid=[$(printf '%s' "$out_nopid" | grep C45-qmd-daemon)] dead=[$(printf '%s' "$out_dead" | grep C45-qmd-daemon)] foreign=[$(printf '%s' "$out_foreign" | grep C45-qmd-daemon)]"
fi
rm -rf "$c44d_t"

# --- C41: MCP server credential on the command line --------------
# A key passed as an argv element is readable by any local user through ps and
# /proc/<pid>/cmdline. C41 scans the MCP server specs (user ~/.claude.json incl.
# per-project entries, plus <root>/.mcp.json, <root>/.claude/mcp-profiles/local.*.json
# and <root>/marketplace/plugins/*/.mcp.json) and WARNs on a credential-shaped
# flag+value or a key-shaped argument -- printing the server NAME and flag only,
# never the value. Seam: HIMMEL_DOCTOR_MCP_ROOT (the <root> above, default the
# checkout); HOME is redirected per case for the user-level file.
c41_setup() {
    c41_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c41.XXXXXX")" || { fail "C41 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c41_t/home" "$c41_t/root"
}
c41_run() {
    PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c41_t/claude" HOME="$c41_t/home" HIMMEL_DOCTOR_MCP_ROOT="$c41_t/root" \
        bash "$DOC" --no-color 2>&1
}

echo "== C41: '--api-key <value>' in a server's args -> WARN naming server + flag, never the value =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"mcpServers":{"fc":{"command":"npm","args":["exec","some-mcp","--","--api-key","NOT-A-REAL-VALUE-zq81x"]}}}
EOF
out="$(c41_run)"
if grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" -F "'fc'" && grepq "$out" -F -- '--api-key' && ! grepq "$out" -F 'NOT-A-REAL-VALUE'; then
    pass "C41 flag+value -> WARN with server and flag, value withheld"
else
    fail "C41 flag+value -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: '--token=<value>' inline form -> WARN =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"mcpServers":{"inl":{"command":"npx","args":["-y","some-mcp","--access-token=NOT-A-REAL-VALUE-zq81x"]}}}
EOF
out="$(c41_run)"
if grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" -F "'inl'" && grepq "$out" -F -- '--access-token' && ! grepq "$out" -F 'NOT-A-REAL-VALUE'; then
    pass "C41 inline --flag=value -> WARN, value withheld"
else
    fail "C41 inline --flag=value -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: a key-shaped argument with no credential flag -> WARN =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"mcpServers":{"bare":{"command":"npx","args":["some-mcp","sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"]}}}
EOF
out="$(c41_run)"
if grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" -F "'bare'" && ! grepq "$out" -F 'sk-aaaaaaaa'; then
    pass "C41 key-shaped argument -> WARN, value withheld"
else
    fail "C41 key-shaped argument -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: camelCase credential flags (--accessToken/--clientSecret/--authToken) with ordinary values -> WARN =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"mcpServers":{"camelA":{"command":"npx","args":["srv","--accessToken","notarealvalue"]},"camelB":{"command":"npx","args":["srv","--clientSecret","notarealvalue"]},"camelC":{"command":"npx","args":["srv","--authToken","notarealvalue"]}}}
EOF
out="$(c41_run)"
if grepq "$out" -F "'camelA'" && grepq "$out" -F "'camelB'" && grepq "$out" -F "'camelC'" && ! grepq "$out" -F 'notarealvalue'; then
    pass "C41 camelCase credential flags -> WARN for all three, value withheld"
else
    fail "C41 camelCase credential flags -> $(printf '%s' "$out" | grep -A3 C41)"
fi
rm -rf "$c41_t"

echo "== C41: a 3-segment JWT argument, and a URL carrying ?token= (inline --flag=URL or bare) -> WARN =="
for c41_case in \
    'jwt|"srv","eyJNOTAREALVALUE1.eyJNOTAREALVALUE2.NOTAREALSIG-zq81x"' \
    'inlineurl|"srv","--url=https://example.invalid/mcp?token=NOT-A-REAL-VALUE-zq81x"' \
    'bareurl|"srv","https://example.invalid/mcp?apikey=NOT-A-REAL-VALUE-zq81x"' \
    'urlpassword|"srv","https://example.invalid/mcp?password=NOT-A-REAL-VALUE-zq81x"' \
    'urlpasswd|"srv","--url=https://example.invalid/mcp?passwd=NOT-A-REAL-VALUE-zq81x"' \
    'urlcredential|"srv","https://example.invalid/mcp?credentials=NOT-A-REAL-VALUE-zq81x"'; do
    c41_name="${c41_case%%|*}"; c41_args="${c41_case#*|}"
    c41_setup
    printf '{"mcpServers":{"%s":{"command":"npx","args":[%s]}}}\n' "$c41_name" "$c41_args" > "$c41_t/home/.claude.json"
    out="$(c41_run)"
    if grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" -F "'$c41_name'" && ! grepq "$out" -F 'NOT-A-REAL-VALUE' && ! grepq "$out" -F 'NOTAREALVALUE'; then
        pass "C41 $c41_name -> WARN, value withheld"
    else
        fail "C41 $c41_name -> $(printf '%s' "$out" | grep -A1 C41)"
    fi
    rm -rf "$c41_t"
done

echo "== C41: env-block key, --key-file <path>, --keyboard, bare --token flag -> no WARN, OK =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"mcpServers":{"ok1":{"command":"npx","args":["-y","some-mcp","--key-file","/run/secrets/k","--secret-file","/run/secrets/s","--keyboard","us","--token","--verbose"],"env":{"SOME_API_KEY":"NOT-A-REAL-VALUE-zq81x"}},"http1":{"type":"http","url":"https://example.invalid/mcp"}}}
EOF
out="$(c41_run)"
if grepq "$out" 'OK   C41-mcp-argv-key' && ! grepq "$out" 'WARN C41-mcp-argv-key'; then
    pass "C41 env / file / non-credential flags -> OK"
else
    fail "C41 safe shapes -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: a per-project mcpServers entry in ~/.claude.json is scanned =="
c41_setup
cat > "$c41_t/home/.claude.json" <<'EOF'
{"projects":{"/some/proj":{"mcpServers":{"projsrv":{"command":"npx","args":["some-mcp","--secret","NOT-A-REAL-VALUE-zq81x"]}}}}}
EOF
out="$(c41_run)"
if grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" -F "'projsrv'" && ! grepq "$out" -F 'NOT-A-REAL-VALUE'; then
    pass "C41 project-scoped entry -> WARN"
else
    fail "C41 project-scoped entry -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: repo-level .mcp.json, generated mcp-profiles and plugin .mcp.json are scanned =="
c41_setup
mkdir -p "$c41_t/root/.claude/mcp-profiles" "$c41_t/root/marketplace/plugins/p1"
cat > "$c41_t/root/.mcp.json" <<'EOF'
{"mcpServers":{"rootsrv":{"command":"npx","args":["some-mcp","--client-secret","NOT-A-REAL-VALUE-zq81x"]}}}
EOF
cat > "$c41_t/root/.claude/mcp-profiles/local.minimal.json" <<'EOF'
{"mcpServers":{"profsrv":{"command":"npx","args":["some-mcp","--api-key","NOT-A-REAL-VALUE-zq81x"]}}}
EOF
cat > "$c41_t/root/marketplace/plugins/p1/.mcp.json" <<'EOF'
{"mcpServers":{"plugsrv":{"command":"bash","args":["run.sh","--password","NOT-A-REAL-VALUE-zq81x"]}}}
EOF
out="$(c41_run)"
if grepq "$out" -F "'rootsrv'" && grepq "$out" -F "'profsrv'" && grepq "$out" -F "'plugsrv'" && ! grepq "$out" -F 'NOT-A-REAL-VALUE'; then
    pass "C41 repo-level configs -> all three flagged, value withheld"
else
    fail "C41 repo-level configs -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: an unparseable config -> INFO naming the file, no WARN, no crash =="
c41_setup
printf '{ this is not json' > "$c41_t/home/.claude.json"
out="$(c41_run)"
if grepq "$out" 'INFO C41-mcp-argv-key' && ! grepq "$out" 'WARN C41-mcp-argv-key' && grepq "$out" 'Summary:'; then
    pass "C41 unparseable config -> INFO skip"
else
    fail "C41 unparseable config -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

echo "== C41: no MCP config anywhere -> OK =="
c41_setup
out="$(c41_run)"
if grepq "$out" 'OK   C41-mcp-argv-key' && ! grepq "$out" 'WARN C41-mcp-argv-key'; then
    pass "C41 no MCP config -> OK"
else
    fail "C41 no MCP config -> $(printf '%s' "$out" | grep -A1 C41)"
fi
rm -rf "$c41_t"

# --- C42: sweep health alarms ------------------------------------
# C42 delegates to `worktree.sh prune --health` (alarm lines only, empty = healthy,
# exit 0/1) and WARNs once per line. Seam: DOCTOR_SWEEP_HEALTH_SCRIPT -- a stub
# here, so no case makes a live forge call or reads real branches.
c42_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c42.XXXXXX")" || { fail "C42 setup: mktemp -d failed"; exit 1; }
c42_stub() { # $1 exit code, $2.. stdout lines
    local rc="$1" l; shift
    # shellcheck disable=SC2016  # $1/$* belong to the generated stub, not to this shell
    { printf '#!/bin/sh\n[ "$1 $2" = "prune --health" ] || { echo "stub: wrong args: $*" >&2; exit 9; }\n'
      for l in "$@"; do printf 'echo %s\n' "'$l'"; done
      printf 'exit %s\n' "$rc"; } > "$c42_t/stub.sh"
}
c42_run() {
    PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c42_t/claude" HOME="$c42_t" DOCTOR_SWEEP_HEALTH_SCRIPT="${1:-$c42_t/stub.sh}" \
        bash "$DOC" --no-color 2>&1
}

echo "== C42: healthy sweep (no output, rc 0) -> OK =="
c42_stub 0
out="$(c42_run)"
if grepq "$out" 'OK   C42-sweep-health' && ! grepq "$out" 'WARN C42-sweep-health'; then
    pass "C42 healthy -> OK"
else
    fail "C42 healthy -> $(printf '%s' "$out" | grep -A1 C42)"
fi

echo "== C42: three alarm lines -> one WARN per line, with the alarm text and a per-type remedy =="
c42_stub 1 'LOST-COMMITS fix/x pr#12 ahead=3' 'STUCK /w/fix+y worktree has tracked changes since 2026-09-21T10:00Z' 'SWEEP-ERROR fix/z no merge base with origin/main -- unrelated history'
out="$(c42_run)"
n="$(printf '%s\n' "$out" | grep -c 'WARN C42-sweep-health')"
if [ "$n" = 3 ] && grepq "$out" -F 'LOST-COMMITS fix/x pr#12 ahead=3' && grepq "$out" -F 'STUCK /w/fix+y' \
   && grepq "$out" -F 'SWEEP-ERROR fix/z no merge base' && grepq "$out" -F 'git log <branch> --not origin/main' \
   && grepq "$out" -F 'worktree.sh prune --dry-run' && grepq "$out" -F 'unlanded-work.sh --health' \
   && ! grepq "$out" 'OK   C42-sweep-health' && ! grepq "$out" 'FAIL C42'; then
    pass "C42 alarms -> 3 WARN lines (n=$n), remedies per type, no OK, no FAIL"
else
    fail "C42 alarms -> n=$n: $(printf '%s' "$out" | grep -A1 C42)"
fi

echo "== C42: script missing -> OK skip =="
out="$(c42_run "$c42_t/no-such-script.sh")"
if grepq "$out" 'OK   C42-sweep-health' && grepq "$out" -F 'not found'; then
    pass "C42 missing script -> OK skip"
else
    fail "C42 missing script -> $(printf '%s' "$out" | grep -A1 C42)"
fi

echo "== C42: check could not run (rc 2) -> INFO, not a false-clean OK =="
c42_stub 2
out="$(c42_run)"
if grepq "$out" 'INFO C42-sweep-health' && grepq "$out" -F 'could not run' && ! grepq "$out" 'OK   C42-sweep-health'; then
    pass "C42 rc 2 -> INFO"
else
    fail "C42 rc 2 -> $(printf '%s' "$out" | grep -A1 C42)"
fi

echo "== C42: rc 1 with no alarm lines -> INFO, not a false-clean OK =="
c42_stub 1
out="$(c42_run)"
if grepq "$out" 'INFO C42-sweep-health' && ! grepq "$out" 'OK   C42-sweep-health' && ! grepq "$out" 'WARN C42-sweep-health'; then
    pass "C42 rc 1 + empty output -> INFO"
else
    fail "C42 rc 1 + empty output -> $(printf '%s' "$out" | grep -A1 C42)"
fi

echo "== C42: the REAL worktree.sh against a fixture repo with a stuck worktree -> WARN STUCK =="
c42_repo="$c42_t/repo"
git init -q --bare "$c42_t/origin.git" && git clone -q "$c42_t/origin.git" "$c42_repo" 2>/dev/null
git -C "$c42_repo" checkout -q -b main
git -C "$c42_repo" -c user.email=t@t.local -c user.name=T commit -q --allow-empty -m init
git -C "$c42_repo" push -q origin HEAD:main && git -C "$c42_repo" remote set-head origin main
mkdir -p "$c42_repo/.git/sweep-health"
git -C "$c42_repo" worktree add -q "$c42_t/wt-stuck" -b feat/stuck >/dev/null 2>&1
printf '%s\t%s\t%s\t%s\n' "$c42_t/wt-stuck" "$(($(date +%s) - 100 ))" 9 "uncommitted changes" > "$c42_repo/.git/sweep-health/stuck.tsv"
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c42_t/claude" HOME="$c42_t" DOCTOR_SWEEP_HEALTH_SCRIPT="$REPO_ROOT/scripts/worktree.sh" \
    bash "$DOC" --no-color --root "$c42_repo" 2>&1)"
if grepq "$out" 'WARN C42-sweep-health' && grepq "$out" -F 'STUCK ' && ! grepq "$out" 'INFO C42-sweep-health'; then
    pass "C42 real worktree.sh prune --health -> WARN STUCK"
else
    fail "C42 real worktree.sh prune --health -> $(printf '%s' "$out" | grep -A1 C42)"
fi
rm -rf "$c42_t"

# --- C43: bare `rtk hook claude` PreToolUse entry ---------------
# `rtk init -g` re-adds this entry, bypassing rtk-hook-guard.sh and regressing
# the guard. Read-only detection only, mirrors C6-hooks' settings.json fixture
# shape.
echo "== C43: bare 'rtk hook claude' PreToolUse entry -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c43-bare.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] } ] } }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C43-rtk-hook' && grepq "$out" -F 'bypasses rtk-hook-guard.sh' && ! grepq "$out" 'OK   C43-rtk-hook'; then
    pass "C43 bare rtk hook entry -> WARN"
else
    fail "C43 bare rtk hook entry -> $(printf '%s' "$out" | grep -A1 C43)"
fi
rm -rf "$t"

echo "== C43: guard-wrapped rtk hook (rtk-hook-guard.sh) -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c43-guarded.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"/himmel/scripts/hooks/rtk-hook-guard.sh\"" } ] } ] } }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C43-rtk-hook' && ! grepq "$out" 'WARN C43-rtk-hook'; then
    pass "C43 guard-wrapped -> OK"
else
    fail "C43 guard-wrapped -> $(printf '%s' "$out" | grep -A1 C43)"
fi
rm -rf "$t"

echo "== C43: no hooks at all -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c43-nohooks.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C43-rtk-hook' && ! grepq "$out" 'WARN C43-rtk-hook'; then
    pass "C43 no hooks -> OK"
else
    fail "C43 no hooks -> $(printf '%s' "$out" | grep -A1 C43)"
fi
rm -rf "$t"

# --- C46: enabledPlugins true for a plugin that is not installed -
# project/local settings come from a fixture dir, never the host checkout's .claude/
c46_proj="$(mktemp -d "${TMPDIR:-/tmp}/c46-proj.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }
export HIMMEL_DOCTOR_PROJECT_CLAUDE_DIR="$c46_proj"
echo "== C46: enabled-but-not-installed plugin -> WARN naming the file =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-missing.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }; mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
cat > "$t/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "atlassian@claude-plugins-official": true, "kept@himmel": true, "off@himmel": false } }
EOF
cat > "$t/claude-stub" <<'EOF'
#!/usr/bin/env bash
echo '[{"id":"kept@himmel","scope":"user","enabled":true}]'
EOF
chmod +x "$t/claude-stub"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C46-plugin-enabled-missing' && grepq "$out" -F 'atlassian@claude-plugins-official' && grepq "$out" -F "$t/claude/settings.json"; then
    c46="$(printf '%s' "$out" | grep -F 'C46-plugin-enabled-missing')"
    # only the missing one is named; installed (kept) and disabled (off) are not
    if [[ "$c46" == *kept@himmel* || "$c46" == *off@himmel* ]]; then fail "C46 names a plugin that is installed or disabled: $c46"; else
    pass "C46 enabled-but-missing -> WARN"; fi
else
    fail "C46 enabled-but-missing -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t"

echo "== C46: every enabled plugin installed -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-ok.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }; mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
cat > "$t/claude/settings.json" <<'EOF'
{ "enabledPlugins": { "kept@himmel": true, "atlassian@claude-plugins-official": false } }
EOF
cat > "$t/claude-stub" <<'EOF'
#!/usr/bin/env bash
echo '[{"id":"kept@himmel","scope":"user","enabled":true}]'
EOF
chmod +x "$t/claude-stub"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C46-plugin-enabled-missing' && ! grepq "$out" 'WARN C46-plugin-enabled-missing'; then
    pass "C46 all installed -> OK"
else
    fail "C46 all installed -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t"

echo "== C46: empty plugin list -> every enabled entry WARNs; failing list -> INFO skip =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-empty.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }; mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
echo '{ "enabledPlugins": { "atlassian@claude-plugins-official": true } }' > "$t/claude/settings.json"
printf '#!/usr/bin/env bash\necho "[]"\n' > "$t/claude-stub"; chmod +x "$t/claude-stub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$t/claude-fail"; chmod +x "$t/claude-fail"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C46-plugin-enabled-missing' && grepq "$out" -F 'atlassian@claude-plugins-official'; then
    pass "C46 empty list -> WARN"
else
    fail "C46 empty list -> $(printf '%s' "$out" | grep -A1 C46)"
fi
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-fail" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C46-plugin-enabled-missing' && ! grepq "$out" 'WARN C46-plugin-enabled-missing'; then
    pass "C46 failing list -> INFO skip"
else
    fail "C46 failing list -> $(printf '%s' "$out" | grep -A1 C46)"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/claude-blank"; chmod +x "$t/claude-blank"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-blank" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C46-plugin-enabled-missing' && ! grepq "$out" 'WARN C46-plugin-enabled-missing'; then
    pass "C46 blank list output -> INFO skip"
else
    fail "C46 blank list output -> $(printf '%s' "$out" | grep -A1 C46)"
fi
echo '{ not json' > "$t/claude/settings.json"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C46-plugin-enabled-missing' && grepq "$out" -F "$t/claude/settings.json" && ! grepq "$out" 'OK   C46-plugin-enabled-missing'; then
    pass "C46 unparseable settings -> INFO naming the file, not OK"
else
    fail "C46 unparseable settings -> $(printf '%s' "$out" | grep -A1 C46)"
fi
echo '{ "enabledPlugins": { "atlassian@claude-plugins-official": true } }' > "$t/claude/settings.local.json"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C46-plugin-enabled-missing' && grepq "$out" -F 'unparseable, not scanned' && grepq "$out" -F "$t/claude/settings.json"; then
    pass "C46 WARN also names an unparseable file it could not scan"
else
    fail "C46 WARN + unparseable -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t"

echo "== C46: install scope must match this checkout (HIMMEL-4046) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-scope.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }
mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
echo '{ "enabledPlugins": { "scoped@himmel": true } }' > "$t/claude/settings.json"
c46_root="$(git rev-parse --show-toplevel)"
# JSON via jq (--arg escapes the path); the stubs cat it, so no path is embedded in shell source
jq -nc --arg p "/elsewhere/other-project" '[{id:"scoped@himmel",scope:"project",projectPath:$p}]' > "$t/list-other.json"
jq -nc --arg p "$c46_root" '[{id:"scoped@himmel",scope:"project",projectPath:$p}]' > "$t/list-here.json"
cat > "$t/claude-other" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/list-other.json"
EOF
cat > "$t/claude-here" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/list-here.json"
EOF
chmod +x "$t/claude-other" "$t/claude-here"
out="$(HIMMEL_DOCTOR_ROOT="$c46_root" HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-other" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C46-plugin-enabled-missing' && grepq "$out" -F 'scoped@himmel'; then
    pass "C46 install at another project path -> WARN"
else
    fail "C46 install at another project path -> $(printf '%s' "$out" | grep -A1 C46)"
fi
out="$(HIMMEL_DOCTOR_ROOT="$c46_root" HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-here" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C46-plugin-enabled-missing' && ! grepq "$out" 'WARN C46-plugin-enabled-missing'; then
    pass "C46 install at this checkout's project path -> OK"
else
    fail "C46 install at this checkout's project path -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t"

echo "== C46: claude not resolvable -> INFO skip =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-noclaude.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }; mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
echo '{ "enabledPlugins": { "x@y": true } }' > "$t/claude/settings.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C46-plugin-enabled-missing' && ! grepq "$out" 'WARN C46-plugin-enabled-missing'; then
    pass "C46 no claude -> INFO skip"
else
    fail "C46 no claude -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t"

echo "== C46: project-local settings are read from the seam dir only (HIMMEL-5084) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c46-seam.XXXXXX")" || { echo "FATAL: C46 setup mktemp failed" >&2; exit 1; }; mkdir -p "$t/claude" "$t/home" || { echo "FATAL: C46 setup mkdir failed" >&2; exit 1; }
echo '{ "enabledPlugins": { "kept@himmel": true } }' > "$t/claude/settings.json"
cat > "$t/claude-stub" <<'EOF'
#!/usr/bin/env bash
echo '[{"id":"kept@himmel","scope":"user","enabled":true}]'
EOF
chmod +x "$t/claude-stub"
echo '{ "enabledPlugins": { "ghost@host": true } }' > "$c46_proj/settings.local.json"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C46-plugin-enabled-missing' && grepq "$out" -F "$c46_proj/settings.local.json"; then
    pass "C46 control: a missing plugin in the seam dir's settings.local.json is reported"
else
    fail "C46 seam control -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -f "$c46_proj/settings.local.json"
out="$(HIMMEL_DOCTOR_CLAUDE_BIN="$t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C46-plugin-enabled-missing'; then
    pass "C46 seam dir empty -> OK, host checkout settings.local.json not read"
else
    fail "C46 seam empty -> $(printf '%s' "$out" | grep -A1 C46)"
fi
rm -rf "$t" "$c46_proj"
unset HIMMEL_DOCTOR_PROJECT_CLAUDE_DIR c46_proj

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
