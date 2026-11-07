#!/usr/bin/env bash
# Tests for scripts/handover/set-handover-dir.sh.
# The T14/T17 rows set HOME and HIMMEL_CONFIG_DIR inside $(...) on purpose: each case needs its own env.
# shellcheck disable=SC2030,SC2031
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/set-handover-dir.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label"
    else echo "FAIL $label — expected '$expected', got '$actual'"; FAILED=$((FAILED + 1)); fi
}
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label (rc=$actual)"
    else echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HDIR="$TMP/state/handovers"
mkdir -p "$HDIR"
HDIR_CANON="$(cd "$HDIR" && pwd)"

# T1: appended to a .env that lacks the key (other lines preserved).
ENV="$TMP/a.env"
printf 'USER_SLUG=tester\nJIRA_PROJECT_KEY=HIMMEL\n' > "$ENV"
bash "$SCRIPT" "$HDIR" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T1 append rc=0" 0 "$?"
assert_eq "T1 key value" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV")"
assert_eq "T1 preserved other lines" "2" "$(grep -cE '^(USER_SLUG|JIRA_PROJECT_KEY)=' "$ENV")"

# T2: idempotent — second identical run keeps exactly one line.
bash "$SCRIPT" "$HDIR" --env-file "$ENV" >/dev/null 2>&1
assert_eq "T2 single HANDOVER_DIR line" "1" "$(grep -cE '^[[:space:]]*HANDOVER_DIR=' "$ENV")"

# T3: update in place — new value replaces old, line count unchanged.
OTHER="$TMP/state2/handovers"
mkdir -p "$OTHER"
OTHER_CANON="$(cd "$OTHER" && pwd)"
bash "$SCRIPT" "$OTHER" --env-file "$ENV" >/dev/null 2>&1
assert_eq "T3 updated value" "HANDOVER_DIR=$OTHER_CANON" "$(grep '^HANDOVER_DIR=' "$ENV")"
assert_eq "T3 still one line" "1" "$(grep -cE '^[[:space:]]*HANDOVER_DIR=' "$ENV")"

# T4: creates the .env when missing.
ENV2="$TMP/new-dir/fresh.env"
bash "$SCRIPT" "$HDIR" --env-file "$ENV2" >/dev/null 2>&1
assert_rc "T4 create .env rc=0" 0 "$?"
assert_eq "T4 created with key" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV2" 2>/dev/null)"

# T5: non-existent handover dir → fail-closed rc=2.
bash "$SCRIPT" "$TMP/nope" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T5 missing dir rc=2" 2 "$?"

# T6: no arg → usage error rc=1.
bash "$SCRIPT" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T6 usage rc=1" 1 "$?"

# T7b: stored path is forward-slash normalized (no backslashes).
case "$(grep '^HANDOVER_DIR=' "$ENV")" in
    *\\*) echo "FAIL T7b no backslashes in stored path"; FAILED=$((FAILED + 1)) ;;
    *)    echo "PASS T7b no backslashes in stored path" ;;
esac

# T7: a commented example line is left intact; an active line is appended.
ENV3="$TMP/commented.env"
printf '# HANDOVER_DIR=/c/example/path\n' > "$ENV3"
bash "$SCRIPT" "$HDIR" --env-file "$ENV3" >/dev/null 2>&1
assert_eq "T7 comment preserved" "1" "$(grep -c '^# HANDOVER_DIR=' "$ENV3")"
assert_eq "T7 active line added" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV3")"

# T8: --env-file=<path> equals form parses the same as the space form.
ENV4="$TMP/eq.env"
bash "$SCRIPT" "$HDIR" --env-file="$ENV4" >/dev/null 2>&1
assert_eq "T8 equals-form --env-file" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV4" 2>/dev/null)"

# T9: unknown flag → usage error rc=1.
bash "$SCRIPT" "$HDIR" --bogus >/dev/null 2>&1
assert_rc "T9 unknown flag rc=1" 1 "$?"

# T10: target exists but is not a regular file (a directory) → refuse rc=1
# with the specific guard diagnostic (asserting the message, not just rc=1,
# locks in the guard — a bare set -e fall-through would also yield rc=1).
mkdir -p "$TMP/envdir"
t10_out=$(bash "$SCRIPT" "$HDIR" --env-file "$TMP/envdir" 2>&1); t10_rc=$?
assert_rc "T10 non-regular-file target rc=1" 1 "$t10_rc"
case "$t10_out" in
    *"not a regular file"*) echo "PASS T10 emits guard diagnostic" ;;
    *) echo "FAIL T10 emits guard diagnostic — got: $t10_out"; FAILED=$((FAILED + 1)) ;;
esac

# T11: --inline replaces a stale vault path with an empty record, in place.
ENV5="$TMP/inline.env"
printf 'USER_SLUG=tester\nHANDOVER_DIR=/stale/vault/handovers\nJIRA_PROJECT_KEY=HIMMEL\n' > "$ENV5"
bash "$SCRIPT" --inline --env-file "$ENV5" >/dev/null 2>&1
assert_rc "T11 inline rc=0" 0 "$?"
assert_eq "T11 stale path replaced by an empty value" "HANDOVER_DIR=" "$(grep '^HANDOVER_DIR=' "$ENV5")"
assert_eq "T11 other lines kept" "2" "$(grep -cE '^(USER_SLUG|JIRA_PROJECT_KEY)=' "$ENV5")"

# T12: re-running --inline, and --inline after --inline on a fresh file, leave one line.
bash "$SCRIPT" --inline --env-file "$ENV5" >/dev/null 2>&1
assert_rc "T12 re-run on an existing file rc=0" 0 "$?"
ENV6="$TMP/inline-fresh.env"
bash "$SCRIPT" --inline --env-file "$ENV6" >/dev/null 2>&1
assert_rc "T12 fresh file rc=0" 0 "$?"
bash "$SCRIPT" --inline --env-file "$ENV6" >/dev/null 2>&1
assert_rc "T12 repeat on the fresh file rc=0" 0 "$?"
assert_eq "T12 re-run keeps one line" "1" "$(grep -cE '^[[:space:]]*HANDOVER_DIR=' "$ENV5")"
assert_eq "T12 fresh file gets one empty line" "HANDOVER_DIR=" "$(cat "$ENV6")"

# T13: --inline with a dir is a usage error rc=1.
bash "$SCRIPT" --inline "$HDIR" --env-file "$ENV6" >/dev/null 2>&1
assert_rc "T13 --inline plus a dir rc=1" 1 "$?"

# T14: an empty record reads as unset: load_dotenv overrides nothing and the resolver
# falls back to the repo's handovers/ even though the .env still has the line.
T14_REPO="$TMP/t14repo"
mkdir -p "$T14_REPO/handovers"
git -C "$T14_REPO" init -q
printf 'HANDOVER_DIR=/stale/vault/handovers\n' > "$T14_REPO/.env"
bash "$SCRIPT" --inline --env-file "$T14_REPO/.env" >/dev/null 2>&1
LIB="$(cd "$(dirname "$SCRIPT")/../lib" && pwd)"
mkdir -p "$TMP/t14home"
t14_root=$(cd "$T14_REPO" && unset HANDOVER_DIR && export HOME="$TMP/t14home" HIMMEL_CONFIG_DIR="$TMP/t14home/.himmel" && . "$LIB/load-dotenv.sh" && . "$LIB/handover-path.sh" \
    && load_dotenv --root "$T14_REPO" HANDOVER_DIR 2>/dev/null && handover_root 2>&1)
assert_eq "T14 resolver lands on the repo handovers/" "$(cd "$T14_REPO/handovers" && pwd)" "$t14_root"

# file_mode <path>: octal mode, GNU stat first then BSD stat (macOS).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# T15: an in-place update keeps a 0600 .env at 0600 under a permissive umask (the
# temp file must not take the umask mode), for a path and for --inline.
ENV7="$TMP/mode.env"
printf 'USER_SLUG=tester\nHANDOVER_DIR=/stale/vault/handovers\n' > "$ENV7"
chmod 600 "$ENV7"
(umask 022; bash "$SCRIPT" "$HDIR" --env-file "$ENV7" >/dev/null 2>&1)
assert_eq "T15 path update keeps mode 600" "600" "$(file_mode "$ENV7")"
(umask 022; bash "$SCRIPT" --inline --env-file "$ENV7" >/dev/null 2>&1)
assert_eq "T15 inline update keeps mode 600" "600" "$(file_mode "$ENV7")"
assert_eq "T15 inline value written" "HANDOVER_DIR=" "$(grep '^HANDOVER_DIR=' "$ENV7")"

# T16: an in-place update through a symlinked .env writes the target and keeps the
# link (the link must not be replaced by a regular file with the target left stale).
mkdir -p "$TMP/t16"
printf 'USER_SLUG=tester\nHANDOVER_DIR=/stale/vault/handovers\n' > "$TMP/t16/real.env"
ln -s real.env "$TMP/t16/.env"
bash "$SCRIPT" "$HDIR" --env-file "$TMP/t16/.env" >/dev/null 2>&1
assert_rc "T16 symlinked .env rc=0" 0 "$?"
if [ -L "$TMP/t16/.env" ]; then echo "PASS T16 link kept"; else echo "FAIL T16 link kept — replaced by a regular file"; FAILED=$((FAILED + 1)); fi
assert_eq "T16 target updated" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$TMP/t16/real.env")"

# T17: the handover-setup.md reconcile reads himmel.conf with `_himmel_config_layers
# HANDOVER_DIR`; a conf value beats the .env that set-handover-dir.sh writes, and a
# process-env value (what a settings `env` pin becomes) beats the conf. Pins the
# order the prose relies on to put a project pin over a conf root.
T17_REPO="$TMP/t17repo"
T17_CONF="$TMP/t17conf"
mkdir -p "$T17_REPO" "$T17_CONF" "$TMP/t17home"
git -C "$T17_REPO" init -q
printf 'HANDOVER_DIR=/conf/vault/handovers\n' > "$T17_CONF/himmel.conf"
bash "$SCRIPT" "$HDIR" --env-file "$T17_REPO/.env" >/dev/null 2>&1
t17_read=$(cd "$T17_REPO" && unset HANDOVER_DIR && export HOME="$TMP/t17home" HIMMEL_CONFIG_DIR="$T17_CONF" && . "$LIB/load-dotenv.sh" && _himmel_config_layers HANDOVER_DIR)
assert_eq "T17 config read finds the conf root" "HANDOVER_DIR=/conf/vault/handovers" "$t17_read"
t17_conf_wins=$(cd "$T17_REPO" && unset HANDOVER_DIR && export HOME="$TMP/t17home" HIMMEL_CONFIG_DIR="$T17_CONF" && . "$LIB/load-dotenv.sh" && load_dotenv --root "$T17_REPO" HANDOVER_DIR 2>/dev/null && printf '%s' "$HANDOVER_DIR")
assert_eq "T17 conf root beats the .env choice" "/conf/vault/handovers" "$t17_conf_wins"
t17_pin_wins=$(cd "$T17_REPO" && export HANDOVER_DIR="$HDIR_CANON" HOME="$TMP/t17home" HIMMEL_CONFIG_DIR="$T17_CONF" && . "$LIB/load-dotenv.sh" && load_dotenv --root "$T17_REPO" HANDOVER_DIR 2>/dev/null && printf '%s' "$HANDOVER_DIR")
assert_eq "T17 a settings-env pin beats the conf root" "$HDIR_CANON" "$t17_pin_wins"

# T18: handover-setup.md step 2 reads the .env layer through the loader (the secrets
# guard refuses a direct read): no line prints `unset`, the inline record prints empty,
# and a path prints the path (HIMMEL_CONFIG_DIR points at nothing, so no conf layer answers).
t18_read() {
    # shellcheck disable=SC2016  # the body is single-quoted on purpose: $1/$2 are bash -c positionals
    (cd "$1" && env -u HANDOVER_DIR HOME="$TMP/t17home" HIMMEL_CONFIG_DIR="${2:-/nonexistent}" \
        bash -c '. "$1/load-dotenv.sh" && load_dotenv --root "$2" HANDOVER_DIR 2>/dev/null && printf "%s" "${HANDOVER_DIR-unset}"' _ "$LIB" "$1")
}
T18_REPO="$TMP/t18repo"
mkdir -p "$T18_REPO"
git -C "$T18_REPO" init -q
: > "$T18_REPO/.env"
assert_eq "T18 no line reads unset" "unset" "$(t18_read "$T18_REPO")"
bash "$SCRIPT" --inline --env-file "$T18_REPO/.env" >/dev/null 2>&1
assert_eq "T18 inline record reads empty" "" "$(t18_read "$T18_REPO")"
bash "$SCRIPT" "$HDIR" --env-file "$T18_REPO/.env" >/dev/null 2>&1
assert_eq "T18 a path reads the path" "$HDIR_CANON" "$(t18_read "$T18_REPO")"
# a wrong clone path (a sourcing failure) is a failed read: non-zero, not a plausible `unset`
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are bash -c positionals
t18_bad=$(cd "$T18_REPO" && env -u HANDOVER_DIR HOME="$TMP/t17home" HIMMEL_CONFIG_DIR=/nonexistent \
    bash -c '. "$1/load-dotenv.sh" && load_dotenv --root "$2" HANDOVER_DIR 2>/dev/null && printf "%s" "${HANDOVER_DIR-unset}"' _ "$TMP/no-such-clone/scripts/lib" "$T18_REPO" 2>/dev/null)
t18_bad_rc=$?
if [ "$t18_bad_rc" -ne 0 ] && [ -z "$t18_bad" ]; then echo "PASS T18 a wrong clone path fails with no output (rc=$t18_bad_rc)"
else echo "FAIL T18 a wrong clone path fails with no output — rc=$t18_bad_rc out='$t18_bad'"; FAILED=$((FAILED + 1)); fi

# T19: every command the prose puts in a fenced bash block passes the REAL secrets guard
# (block-read-secrets.sh, which adopt.sh copies into every guarded project). The old jq
# filter '.env.HANDOVER_DIR' matches .env.* and was refused; it stays a RED control here.
GUARD="$(cd "$(dirname "$SCRIPT")/../hooks" && pwd)/block-read-secrets.sh"
SETUP_MD="$(cd "$(dirname "$SCRIPT")/../.." && pwd)/marketplace/plugins/handover/commands/handover-setup.md"
guard_rc() { jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' <<<"$1" | bash "$GUARD" >/dev/null 2>&1; echo "$?"; }
guard_read_rc() { jq -Rn --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}' | bash "$GUARD" >/dev/null 2>&1; echo "$?"; }
assert_rc "T19 control: the old jq filter on the settings file is refused" 2 \
    "$(guard_rc "jq -r '.env.HANDOVER_DIR // empty' /r/.claude/settings.json")"
t19_n=0; t19_bad=0
while IFS= read -r t19_line; do
    [ -n "$t19_line" ] || continue
    t19_cmd=$(printf '%s' "$t19_line" | sed -e 's#<writer>#/h/scripts/handover/set-handover-dir.sh#g' -e 's#<himmel-clone>#/h#g' -e 's#<repo-root>#/r#g' -e 's#<chosen-path>#/x#g')
    t19_n=$((t19_n + 1))
    if [ "$(guard_rc "$t19_cmd")" != "0" ]; then t19_bad=$((t19_bad + 1)); echo "FAIL T19 the guard refuses a command in the prose: $t19_cmd"; FAILED=$((FAILED + 1)); fi
done < <(awk '/^[[:space:]]*```bash[[:space:]]*$/ {f=1; next} /^[[:space:]]*```[[:space:]]*$/ {f=0} f {sub(/^[[:space:]]+/, ""); print}' "$SETUP_MD")
if [ "$t19_n" -gt 0 ] && [ "$t19_bad" -eq 0 ]; then echo "PASS T19 all $t19_n fenced prose commands pass the secrets guard"
elif [ "$t19_n" -eq 0 ]; then echo "FAIL T19 found no fenced bash commands in handover-setup.md"; FAILED=$((FAILED + 1)); fi
assert_rc "T19 Read of the project settings file passes the guard" 0 "$(guard_read_rc "/r/.claude/settings.json")"
assert_rc "T19 Read of the user settings file passes the guard" 0 "$(guard_read_rc "/home/u/.claude/settings.json")"

echo
if [ "$FAILED" -eq 0 ]; then echo "All set-handover-dir tests passed."
else echo "$FAILED set-handover-dir test(s) failed."; exit 1; fi
