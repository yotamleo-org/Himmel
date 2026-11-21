#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the check() shape of the sibling suites
# readiness-adapter-suite.sh - the readiness adapter's own suite (readiness-tools.test.mjs), run whole, with its accounting.
#
#   bash scripts/handover/chief-kit/readiness-adapter-suite.sh
#
# The file's credential and port groups drive the BUILT primary Jira CLI (scripts/jira, npm run build; READINESS_PRIMARY_CLI names
# another build) against a loopback fixture with fake credentials. A checkout without that build has no stand-in client and no skip:
# the run fails by name (PREREQUISITE-ABSENT). So this is not a test-*.sh suite, which the shell runner would also run on checkouts
# that have no build: CI runs it in the node-suites (jira) job, after the build, and a local run needs the build the same way.
# test-readiness-worker.sh keeps the rows that need no build.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/readiness-adapter-suite.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }  # prim-ok: the suite's own scratch directory, removed by its EXIT trap
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
export HOME="$tmp/home"
mkdir -p "$HOME"

# --- 9. the adapter's MCP envelope, over the configuration this very launcher generates (and the registration of its suite)
# readiness-tools.test.mjs runs the real launcher in its own contained fixture worlds, then spawns the adapter with exactly the
# command and argv of each GENERATED strict MCP config and speaks MCP to it. The WHOLE file runs here, no name filter: the
# C0 envelope group and the credential, port and adoption groups (those drive a private byte-copy of the built primary Jira CLI
# against a loopback fixture with fake credentials, so they need the primary checkout's untracked build; without it the file
# FAILS loudly in its own setup - there is no stand-in client and no skip). Its summary must show real passes and no skip.
rc=0
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" node --test --test-reporter=spec "$HERE/readiness-tools.test.mjs" > "$tmp/envelope.out" 2>&1 || rc=$?
env_pass="$(sed -n 's/^ℹ pass \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
env_fail="$(sed -n 's/^ℹ fail \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
env_skip="$(sed -n 's/^ℹ skipped \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
env_todo="$(sed -n 's/^ℹ todo \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
[ "$rc" -eq 0 ] || tail -n 30 "$tmp/envelope.out"
check "the adapter suite exits 0 with no failure, skip or todo" "$rc:${env_fail:-?}:${env_skip:-?}:${env_todo:-?}" "0:0:0:0"
check "the adapter suite really ran its rows (not a vacuous pass)" "$([ "${env_pass:-0}" -ge 20 ] && echo ran || echo "only:${env_pass:-0}")" "ran"
# The registration runs the WHOLE adapter suite. What the file declares is derived from the file itself and checked against what the
# runner printed, so the credential, port and adoption rows cannot go unrun behind a green exit:
#   groups  every top-level group the file declares, whatever its modifier (describe, describe.skip, ...), must report passed;
#           a top-level opener whose name this derivation cannot read is itself a miss, never silently dropped
#   skips   the runner's SKIP and TODO lines at any depth (its own `skipped` counter does not see a skipped group)
#   rows    the passes are at least the file's own test( count (loops only add rows, so this is a floor, never the proof)
adapter_fact() { # <groups|skips|rows> <test file> <node --test output>
    local fact="$1" file="$2" out="$3" grp missing="" named=0 openers declared pass
    case "$fact" in
        groups)
            openers="$(grep -cE "^describe(\.[a-z]+)?\(" "$file")"
            while IFS= read -r grp; do
                [ -n "$grp" ] || continue
                named=$((named + 1))
                grep -qF -- "✔ $grp (" "$out" || missing="${missing}[$grp]"
            done < <(sed -nE "s/^describe(\.[a-z]+)?\('([^']*)'.*/\2/p" "$file")
            [ "$named" -eq "$openers" ] || missing="${missing}[${openers}-openers-but-${named}-named]"
            printf '%s' "${missing:-none}" ;;
        skips) grep -cE '^[[:space:]]*﹣| # (SKIP|TODO)$|^ℹ todo [1-9][0-9]*$' "$out" || true ;;
        rows)
            declared="$(grep -cE '^[[:space:]]*test\(' "$file")"
            pass="$(sed -n 's/^ℹ pass \([0-9]*\)$/\1/p' "$out" | tail -n 1)"
            [ "${pass:-0}" -ge "$declared" ] && printf enough || printf 'pass:%s declared:%s' "${pass:-0}" "$declared" ;;
    esac
}
check "every top-level group of the adapter suite ran and passed (the credential, port and adoption rows included)" "$(adapter_fact groups "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "none"
check "no group, test or todo of the adapter suite was skipped, at any depth" "$(adapter_fact skips "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "0"
check "the adapter suite passed at least as many rows as the file declares" "$(adapter_fact rows "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "enough"
# The prerequisite of the credential and port groups is the primary checkout's untracked build of the Jira CLI (scripts/jira, npm run
# build): a clean checkout has none, and then these rows fail by name - they are never stood in for, skipped or run against a host.
check "the adapter suite's named prerequisite is present: the built primary Jira CLI (no PREREQUISITE-ABSENT in the run)" "$(grep -c 'PREREQUISITE-ABSENT' "$tmp/envelope.out" || true)" "0"  # swallow-ok: grep -c exits 1 when it counts zero lines; the printed count is the value compared
rc=0
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" READINESS_PRIMARY_CLI="$tmp/no-such-build/index.js" node --test --test-reporter=spec --test-name-pattern='C0 fixture sanity' "$HERE/readiness-tools.test.mjs" > "$tmp/prereq.out" 2>&1 || rc=$?
check "prerequisite control: with no build the sanity row fails (rc != 0) and names PREREQUISITE-ABSENT and the missing path" "$([ "$rc" -ne 0 ] && echo failed):$(grep -c "PREREQUISITE-ABSENT: the built primary Jira CLI is required at $tmp/no-such-build/index.js" "$tmp/prereq.out" | sed 's/^[1-9][0-9]*$/named/')" "failed:named"

# The accounting is itself checked on tiny fixtures run by the same runner (no adapter, no primary CLI, nothing of the file above):
# a valid file is accounted clean, and each way a group or row stops running behind a green exit is seen. The fixture keeps more
# passing rows than it declares, as the real file does, so the row floor alone could never notice a skipped group.
fx_write() { # <file> <legacy suffix> <nested suffix> <last-test suffix>: each '' or .skip or .todo
    cat > "$1" <<FX_EOF
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
describe$2('legacy group', () => {
  test('legacy row one', () => assert.ok(true));
  test('legacy row two', () => assert.ok(true));
});
describe('envelope group', () => {
  for (const n of [1, 2, 3, 4, 5, 6]) test(\`envelope row \${n}\`, () => assert.ok(n));
  describe$3('nested group', () => { test('nested row', () => assert.ok(true)); });
  test$4('last row', () => assert.ok(true));
});
FX_EOF
}
fx_facts() { # <name> <legacy> <nested> <test> [double-quote the legacy group name] [reason form]: groups|skips|rows|runner's own skipped count
    local f="$tmp/acct-$1.test.mjs" o="$tmp/acct-$1.out"
    fx_write "$f" "$2" "$3" "$4"
    case "${6:-}" in
        nested-reason) sed -i.bak "s/describe('nested group', ()/describe('nested group', { skip: 'because' }, ()/" "$f" ;;  # prim-ok: rewrites a fixture file this suite just wrote in its own scratch directory
        todo-reason) sed -i.bak "s/test('last row', ()/test('last row', { todo: 'later' }, ()/" "$f" ;;  # prim-ok: rewrites a fixture file this suite just wrote in its own scratch directory
    esac
    [ -z "${5:-}" ] || sed -i.bak "s/'legacy group'/\"legacy group\"/" "$f"  # prim-ok: rewrites a fixture file this suite just wrote in its own scratch directory
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" node --test --test-reporter=spec "$f" > "$o" 2>&1 || true
    printf '%s|%s|%s|%s' "$(adapter_fact groups "$f" "$o")" "$(adapter_fact skips "$f" "$o")" "$(adapter_fact rows "$f" "$o")" "$(sed -n 's/^ℹ skipped \([0-9]*\)$/\1/p' "$o" | tail -n 1)"
}
check "accounting control: a valid full file is accounted clean (every group passed, nothing skipped, enough rows)" "$(fx_facts valid '' '' '')" "none|0|enough|0"
check "accounting control: a skipped top-level group is a missing group and a skip even though the runner's own skipped count stays 0 and the row floor still holds" "$(fx_facts legacy-skipped .skip '' '')" "[legacy group]|1|enough|0"
check "accounting control: a skipped nested group is a skip at depth although every top-level group still passed" "$(fx_facts nested-skipped '' .skip '')" "none|1|enough|0"
check "accounting control: a skipped test is a skip" "$(fx_facts test-skipped '' '' .skip)" "none|1|enough|1"
check "accounting control: a todo test is seen in its row and the summary" "$(fx_facts test-todo '' '' .todo)" "none|2|enough|0"
check "accounting control: a nested group skipped with a reason is seen despite zero skipped rows" "$(fx_facts nested-reason '' '' '' '' nested-reason)" "none|1|enough|0"
check "accounting control: a todo test with a reason is seen despite zero skipped rows" "$(fx_facts todo-reason '' '' '' '' todo-reason)" "none|1|enough|0"
# and on the REAL file: its legacy adoption/ownership group skipped in a copy of the text, with the real run's own output rewritten
# the way the runner prints a skipped suite; the unmodified pair is the valid full-file control (the three checks above)
sed "s/^describe('C0s2 adopted ownership'/describe.skip('C0s2 adopted ownership'/" "$HERE/readiness-tools.test.mjs" > "$tmp/real-skipped.test.mjs"
sed "s/^✔ \(C0s2 adopted ownership ([0-9.]*ms)\)$/﹣ \1 # SKIP/" "$tmp/envelope.out" > "$tmp/real-skipped.out"
check "accounting control (the real file): its skipped C0s2 adopted ownership group is a missing group and a skip" "$(adapter_fact groups "$tmp/real-skipped.test.mjs" "$tmp/real-skipped.out")|$(adapter_fact skips "$tmp/real-skipped.test.mjs" "$tmp/real-skipped.out")" "[C0s2 adopted ownership]|1"
check "accounting control: a top-level group whose name the derivation cannot read is a miss, not dropped" "$(fx_facts unnamed '' '' '' dq)" "[2-openers-but-1-named]|0|enough|0"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - readiness-adapter-suite.sh"; exit 0; fi
echo "FAIL - readiness-adapter-suite.sh ($fails failure(s))"; exit 1
