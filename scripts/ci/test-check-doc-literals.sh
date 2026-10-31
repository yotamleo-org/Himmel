#!/usr/bin/env bash
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+.
#
# Test for scripts/ci/check-doc-literals.sh.
#
# Part 1 plants doc lines in a fixture repo. The RED row is the real
# docs/himmel-bus.md register row: a doc flag and role the CLI does not accept.
# Part 2 pins the declared accept lists to each CLI's own source, so a parser
# that gains or loses a flag fails here until the list in the gate is updated.
#
# Usage: bash scripts/ci/test-check-doc-literals.sh
# shellcheck disable=SC2016  # fixture doc lines are literal text, nothing should expand
set -uo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/check-doc-literals.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h8302d.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false

# run_case <name> <want rc> <path> <content> [gate args...]: a fresh tree holding
# only <path>, then the gate over it.
run_case() {
    local name="$1" want="$2" path="$3" content="$4" rc out
    shift 4
    git -C "$repo" rm -rfq --ignore-unmatch . >/dev/null 2>&1
    mkdir -p "$repo/$(dirname "$path")" || { fail "$name: setup mkdir failed"; return; }
    printf '%s\n' "$content" > "$repo/$path" || { fail "$name: setup write failed"; return; }
    git -C "$repo" add -A || { fail "$name: setup add failed"; return; }
    out=$(bash "$GATE" --root "$repo" "$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}

# The register row of docs/himmel-bus.md as PR 4288 left it (the (c)1 case).
BUS_DOC_ROW='| `register <name> --role worker\|chief\|judge\|consult [--chief <c>] [--pair <worker>] [--predecessor <old>]` | Reserve an identity (launcher use) |'
# The same row in the spellings the parser accepts today.
BUS_OK_ROW='| `register <name> --role worker\|console\|judge\|consult [--console <c>] [--pair <worker>] [--predecessor <old>]` | Reserve an identity (launcher use) |' # old-term-ok: the parser spelling

echo "== RED: a doc literal the CLI refuses =="
run_case "bus register row from docs/himmel-bus.md" 1 docs/himmel-bus.md "$BUS_DOC_ROW"
case "$LAST_OUT" in *docs/himmel-bus.md:1:*--chief*) pass "finding names the file, line and --chief" ;; *) fail "finding names --chief: $LAST_OUT" ;; esac
case "$LAST_OUT" in *"role 'chief'"*) pass "finding names the role value" ;; *) fail "finding names the role value: $LAST_OUT" ;; esac
run_case "retired tick flag" 1 docs/a.md 'run `bash scripts/handover/chief-kit/tick.sh --legs "a b"` first' # old-term-ok: the retired flag
run_case "unknown board flag in a fence" 1 docs/a.md 'node scripts/handover/chief-kit/board.mjs --doc d.md --nope x'
run_case "refused launcher flag" 1 docs/a.md 'headed-arm-worker.sh --console me' # old-term-ok: the refused flag
run_case "bus send with an unknown flag" 1 docs/a.md 'bus send chief body.md --urgent'
run_case "--role=value form is checked too" 1 docs/a.md 'bus register x --role=chief'
run_case "flag in a SKILL.md" 1 marketplace/plugins/x/skills/y/SKILL.md 'run chief.sh --nope'
run_case "flag in a slash command" 1 .claude/commands/z.md 'run gen-briefs --nope'
run_case "flag on append-results.sh" 1 docs/handover/worker-preface.md 'bash scripts/handover/chief-kit/append-results.sh --force doc text'

echo "== GREEN: the doc and the CLI agree =="
run_case "bus register row in the parser spellings" 0 docs/himmel-bus.md "$BUS_OK_ROW"
run_case "tick flags" 0 docs/a.md 'bash scripts/handover/chief-kit/tick.sh --doc d --workers "a b" --verbose'
run_case "flag after a pipe belongs to the next command" 0 docs/a.md 'tick.sh --doc d | grep --color x'
run_case "flag after && belongs to the next command" 0 docs/a.md 'tick.sh --doc d && git log --oneline'
run_case "flag after a closing backtick is prose" 0 docs/a.md 'see `tick.sh` and the --nope notes'
run_case "--flag=value form" 0 docs/a.md 'chief.sh next --model=opus --bucket himmel'
run_case "role placeholder is skipped" 0 docs/a.md 'bus register x --role <role>'
run_case "--role=value form, accepted value" 0 docs/a.md 'bus register x --role=judge'
run_case "a closing backtick ends the bus invocation" 0 docs/a.md 'run `bus status` and read the --nope notes'
run_case "a closing backtick ends the gen-briefs invocation" 0 docs/a.md 'run `gen-briefs` and read the --nope notes'
run_case "another tool named like a suffix" 0 docs/a.md 'bash test-tick.sh --nope'
run_case "old-term-ok marker skips the line" 0 docs/a.md 'headed-arm-worker.sh --console me <!-- old-term-ok: shows the refusal -->'
run_case "history dirs are not scanned" 0 docs/migration/old.md 'tick.sh --nope x'
run_case "non-doc paths are not scanned" 0 scripts/x.sh 'tick.sh --nope x'

echo "== --warn reports and exits 0 =="
run_case "warn mode prints the finding" 0 docs/a.md 'tick.sh --nope x' --warn
case "$LAST_OUT" in *--nope*) pass "warn output carries the finding" ;; *) fail "warn output carries the finding: $LAST_OUT" ;; esac

echo "== a broken scan is an error, never a finding =="
mkdir -p "$tmp/badbin"
printf '#!/bin/sh\nexit 2\n' > "$tmp/badbin/awk"
chmod +x "$tmp/badbin/awk"
git -C "$repo" rm -rfq --ignore-unmatch . >/dev/null 2>&1
mkdir -p "$repo/docs"
printf 'tick.sh --doc d\n' > "$repo/docs/a.md"
git -C "$repo" add -A
out=$(PATH="$tmp/badbin:$PATH" bash "$GATE" --root "$repo" --warn 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "failing awk exits 2 even with --warn (rc=2)"; else fail "failing awk: want rc=2 got rc=$rc: $out"; fi

echo "== declared accept lists match each CLI's own source =="
sorted() { tr ' ' '\n' | grep -E '^--' | sort | uniq | tr '\n' ' '; }
# Case-label flags of a shell parser (a label line ends in ) or carries a ;).
sh_flags() {
    awk '/^[[:space:]]*-[-a-zA-Z0-9|=*]*\)/ {
        head = $0; sub(/\).*/, "", head); rest = $0; sub(/^[^)]*\)/, "", rest)
        if (rest ~ /^[[:space:]]*$/ || rest ~ /;/) print head }' "$1" | grep -oE -- '--[a-z0-9-]+'
}
src_flags() {
    local name="$1" src="$ROOT/$2"
    case "$name" in
        bus) awk '/options: \{/ { on = 1; next } on && /^[[:space:]]*\},?$/ { exit } on' "$src" | grep -oE '[a-z]+: \{ type' | sed -e 's/: { type//' -e 's/^/--/' ;;
        board.mjs) { grep -E '\]\.includes\(args\[i\]\)' "$src"; grep -E "includes\('--changed'\)" "$src"; } | grep -oE "'--[a-z]+'" | tr -d "'" ;;
        gen-briefs) { grep -oE "add_argument\('--[a-z-]+'" "$src" | sed -e "s/add_argument('//" -e "s/'//"; echo "--help"; } ;;
        *) sh_flags "$src" ;;
    esac
}
table=$(bash "$GATE" --list-accept) || { fail "--list-accept failed"; table=""; }
nrows=0
while IFS="$(printf '\t')" read -r name src _re flags roles refused; do
    [ -n "$name" ] || continue
    nrows=$((nrows+1))
    [ -r "$ROOT/$src" ] || { fail "$name: source $src unreadable"; continue; }
    [ "$flags" = - ] && flags=""
    [ "$refused" = - ] && refused=""
    want=$(printf '%s %s\n' "$flags" "$refused" | sorted)
    got=$(src_flags "$name" "$src" | sorted)
    if [ "$want" = "$got" ]; then pass "$name: declared flags (+ refused) equal the parser's"; else fail "$name: declared [$want] but parser has [$got]"; fi
    if [ "$name" = bus ]; then
        src_roles=$(grep -E "^const ROLES = " "$ROOT/marketplace/plugins/himmel-bus/lib/identity.mjs" | grep -oE "'[a-z]+'" | tr -d "'" | sort | tr '\n' ' ')
        decl_roles=$(printf '%s\n' "$roles" | tr ' ' '\n' | sort | tr '\n' ' ')
        if [ "$src_roles" = "$decl_roles" ]; then pass "bus: declared roles equal ROLES in identity.mjs"; else fail "bus: declared roles [$decl_roles] but ROLES is [$src_roles]"; fi
    fi
done <<EOF
$table
EOF
if [ "$nrows" -ge 7 ]; then pass "all seven declared CLIs are covered ($nrows rows)"; else fail "expected 7 declared CLIs, saw $nrows"; fi

echo
if [ "$failures" -eq 0 ]; then echo "check-doc-literals: all cases passed"; else echo "check-doc-literals: $failures case(s) FAILED"; fi
[ "$failures" -eq 0 ]
