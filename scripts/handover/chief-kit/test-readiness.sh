#!/usr/bin/env bash
# scripts/handover/chief-kit/test-readiness.sh - readiness.sh append and read rows R1-R14
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RD="${READINESS_SH:-$HERE/readiness.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }

W="$(mktemp -d "${TMPDIR:-/tmp}/readiness-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
M="$W/m"
REL="$W/rel"
REC="$REL/v1/readiness.jsonl"
mkdir -p "$M" "$REL/v1"
E0=1800000000
export READINESS_NOW_EPOCH=$E0
export HIMMEL_RELEASE_STATE_DIR="$REL"
unset CLAUDE_PID SESSION_NAME_CMDLINE_FILE

T_STATUS="To Do"; T_CAT="To Do"; T_LABELS='["standalone","backlog","phase:design"]'; T_FIX='["v1"]'
T_BLOCKS='[]'; T_BY='["HIMMEL-8102"]'; T_BODY=$'Impact\nfixture body'; T_UPD="2026-11-15T11:00:00.000+0100"; T_COMMENT='_(none)_'
deft() { T_STATUS="To Do"; T_CAT="To Do"; T_LABELS='["standalone","backlog","phase:design"]'; T_FIX='["v1"]'
    T_BLOCKS='[]'; T_BY='["HIMMEL-8102"]'; T_BODY=$'Impact\nfixture body'; T_UPD="2026-11-15T11:00:00.000+0100"; T_COMMENT='_(none)_'; }
writet() {
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "High"\nlabels: %s\nfixVersions: %s\nparent: null\ncreated: "2026-11-15T10:00:00.000+0100"\nupdated: "%s"\nresolution: null\nresolved: null\nlinks:\n  blocks: %s\n  blocked_by: %s\n  relates: ["relates to HIMMEL-8103"]\n---\n\n# %s: fixture ticket\n\n## Description\n\n%s\n\n## Comments\n\n%s\n' \
        "$1" "$T_STATUS" "$T_CAT" "$T_LABELS" "$T_FIX" "$T_UPD" "$T_BLOCKS" "$T_BY" "$1" "$T_BODY" "$T_COMMENT" > "$M/$1.md"
}
blocker_open() { printf -- '---\nkey: "HIMMEL-8102"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "To Do"\npriority: "High"\nlabels: []\nfixVersions: ["v1"]\nparent: null\ncreated: "x"\nupdated: "x"\nresolution: null\nresolved: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-8102: blocker\n\n## Description\n\nb\n\n## Comments\n\n_(none)_\n' > "$M/HIMMEL-8102.md"; }
blocker_done() { sed -i 's/^status: "To Do"/status: "Done"/; s/^statusCategory: "To Do"/statusCategory: "Done"/' "$M/HIMMEL-8102.md"; } # gnu-ok: the chief kit is Linux-only
fresh() { deft; writet FIXT-101; writet FIXT-102; blocker_open; rm -rf "$REL"; mkdir -p "$REL/v1"; }

ap() { bash "$RD" append "$@" --by fixture --mirror "$M"; }
rd() { bash "$RD" read "$1" --mirror "$M"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
tree() { find "$W" -type f -not -path "$W/fxrepo/*" -not -path "$W/home/*" -not -path "$W/o" -not -path "$W/e" | sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1; }

fresh
ap v1 FIXT-101 a --evidence x >"$W/o" 2>"$W/e"; rc=$?
check "R1: append a exits 0" "$rc" "0"
ap v1 FIXT-101 c --evidence y --blocker HIMMEL-8102 >"$W/o" 2>"$W/e"; rc=$?
check "R1: append c exits 0" "$rc" "0"
out="$(rd v1)"; rc=$?
check "R1: read exits 0" "$rc" "0"
check "R1: read prints exactly one line for the key" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
check "R1: the latest row wins (decision c)" "$(printf '%s' "$out" | jq -r .decision)" "c"
check "R1: blocker" "$(printf '%s' "$out" | jq -r .blocker)" "HIMMEL-8102"
check "R1: state live" "$(printf '%s' "$out" | jq -r .state)" "live"
check "R1: cat To Do" "$(printf '%s' "$out" | jq -r .cat)" "To Do"
check "R1: why null" "$(printf '%s' "$out" | jq -r .why)" "null"
check "R1: the record holds both rows" "$(wc -l "$REC" | cut -d' ' -f1)" "2"
check "R1: row key order" "$(sed -n 1p "$REC" | jq -c 'keys_unsorted')" '["ts","key","decision","blocker","evidence","stamp","by"]'
check "R1: ts is UTC from READINESS_NOW_EPOCH" "$(sed -n 1p "$REC" | jq -r .ts)" "2027-01-15T08:00:00Z"
check "R1: by is the given name" "$(sed -n 1p "$REC" | jq -r .by)" "fixture"
check "R1: an a row stores a null blocker" "$(sed -n 1p "$REC" | jq -r '.blocker')" "null"
ap v1 FIXT-102 b --evidence z >/dev/null 2>&1
check "R1b: read prints one line per key, sorted by key" "$(rd v1 | jq -r .key | tr '\n' ' ')" "FIXT-101 FIXT-102 "

fresh
ap v1 FIXT-101 a --evidence x >/dev/null 2>&1
before="$(sha "$REC")"
ap v1 FIXT-101 e --evidence x >/dev/null 2>&1; rc=$?
check "R2: a bad decision letter exits 2" "$rc" "2"
check "R2: and the record is unchanged" "$(sha "$REC")" "$before"

fresh
ap v1 FIXT-101 a --evidence x >/dev/null 2>&1
before="$(sha "$REC")"
ap v1 FIXT-101 c --evidence y >/dev/null 2>&1; rc=$?
check "R3: c without --blocker exits 2" "$rc" "2"
ap v1 FIXT-101 a --evidence y --blocker HIMMEL-8102 >/dev/null 2>&1; rc=$?
check "R3: a with --blocker exits 2" "$rc" "2"
ap v1 FIXT-101 b --evidence y --blocker 964 >/dev/null 2>&1; rc=$?
check "R3: b with --blocker exits 2" "$rc" "2"
T_FIX='["v2"]'; writet FIXT-103; T_FIX='["v1"]'
ap v1 FIXT-103 a --evidence y >"$W/o" 2>"$W/e"; rc=$?
check "R3: a key whose fixVersions lacks the version exits 2" "$rc" "2"
ap v1 FIXT-101 c --evidence y --blocker 'PR 5484' >"$W/o" 2>"$W/e"; rc=$?
check "R3: --blocker 'PR 5484' exits 2" "$rc" "2"
contains "R3: it says a bare number is an operator decision number" "$(cat "$W/e")" "operator decision number"
contains "R3: and a PR ruling names the PR's ticket KEY" "$(cat "$W/e")" "ticket KEY"
ap v1 FIXT-101 c --evidence y --blocker '#5484' >"$W/o" 2>"$W/e"; rc=$?
check "R3: --blocker '#5484' exits 2" "$rc" "2"
contains "R3: the same message" "$(cat "$W/e")" "operator decision number"
check "R3: the refusals leave the record unchanged" "$(sha "$REC")" "$before"
bash "$RD" >"$W/o" 2>"$W/e"; rc=$?
check "R3: no arguments exits 2" "$rc" "2"
contains "R3: usage says a bare number is an operator decision number" "$(cat "$W/e")" "operator decision number"
contains "R3: usage says a PR ruling names the ticket KEY" "$(cat "$W/e")" "ticket KEY"
ap v1 FIXT-102 c --evidence y --blocker 964 >/dev/null 2>&1; rc=$?
check "R3: c with a bare decision number blocker exits 0" "$rc" "0"
ap v1 FIXT-102 d --evidence y >/dev/null 2>&1; rc=$?
check "R3: d without a blocker exits 0" "$rc" "0"
check "R3: that d row stores a null blocker" "$(rd v1 | jq -r 'select(.key=="FIXT-102") | .blocker')" "null"

fresh
ap v1 FIXT-101 a --evidence x >/dev/null 2>&1
check "R4: the fixture's stamp is the spec vector" "$(sed -n 1p "$REC" | jq -r .stamp)" "s1:1d8ce3b2884a1209"
T_UPD="2026-11-16T09:00:00.000+0100"; T_COMMENT=$'### Someone — 2026-11-16\n\na receipt comment'; writet FIXT-101
check "R4: a new updated and a comment stay live" "$(rd v1 | jq -r .state)" "live"
deft; T_STATUS="In Progress"; T_CAT="In Progress"; T_LABELS='["standalone","backlog","phase:build","worker-blocked"]'; writet FIXT-101
check "R4: In Progress plus phase and worker-blocked labels stay live" "$(rd v1 | jq -r .state)" "live"
check "R4: and cat reads In Progress" "$(rd v1 | jq -r .cat)" "In Progress"
deft; T_LABELS='["phase:design","backlog","standalone"]'; writet FIXT-101
check "R4: reordered labels stay live" "$(rd v1 | jq -r .state)" "live"
deft; T_BODY=$'Impact\nfixture body changed'; writet FIXT-101
check "R4: a body change is stale" "$(rd v1 | jq -r .state)" "stale"
check "R4: with why stamp" "$(rd v1 | jq -r .why)" "stamp"
ap v1 FIXT-101 a --evidence again >/dev/null 2>&1
check "R4: the changed body stamps s1:96ebce484c63f8d3" "$(sed -n 2p "$REC" | jq -r .stamp)" "s1:96ebce484c63f8d3"
deft; T_BLOCKS='["HIMMEL-8104"]'; writet FIXT-101
check "R4: a blocks link is stale" "$(rd v1 | jq -r .state)" "stale"

FXR="$W/fxrepo"; mkdir -p "$FXR/scripts/handover/chief-kit" "$W/home"
git -C "$FXR" init -q -b main
cp -R "$HERE/../../lib" "$FXR/scripts/lib"; cp "$RD" "$FXR/scripts/handover/chief-kit/readiness.sh"
fx() { (cd "$FXR" && env -u HIMMEL_RELEASE_STATE_DIR -u USER_SLUG -u HANDOVER_DIR -u HIMMEL_CONFIG_DIR -u CLAUDE_PID HOME="$W/home" "$@" bash "$FXR/scripts/handover/chief-kit/readiness.sh" append v1 FIXT-101 a --evidence x --by fixture --mirror "$M"); }
fresh; mkdir -p "$W/h"
printf 'HANDOVER_DIR=%s\n' "$W/h" > "$FXR/.env"
fx USER_SLUG=u >"$W/o" 2>"$W/e"; rc=$?
check "R5a: USER_SLUG in the environment, HANDOVER_DIR in the .env: exit 0" "$rc" "0"
check "R5a: the record lands under the repo's basename" "$([ -f "$W/h/u/fxrepo/release/v1/readiness.jsonl" ] && echo yes || echo no)" "yes"
rm -rf "$W/h"; mkdir -p "$W/h" "$W/home/.himmel"
printf 'USER_SLUG=u\n' > "$W/home/.himmel/himmel.conf"
fx >"$W/o" 2>"$W/e"; rc=$?
check "R5b: USER_SLUG from ~/.himmel/himmel.conf: exit 0" "$rc" "0"
check "R5b: the same path" "$([ -f "$W/h/u/fxrepo/release/v1/readiness.jsonl" ] && echo yes || echo no)" "yes"
rm -rf "$W/h" "$W/home/.himmel"; mkdir -p "$W/h3"
printf 'HANDOVER_DIR=%s\n' "$W/h3" > "$FXR/.env"
snap="$(tree)"
fx >"$W/o" 2>"$W/e"; rc=$?
check "R5c: USER_SLUG nowhere exits 3" "$rc" "3"
contains "R5c: and stderr names USER_SLUG" "$(cat "$W/e")" "USER_SLUG"
check "R5c: no file is written under the scratch tree" "$(tree)" "$snap"

fresh
ap v1 FIXT-101 c --evidence y --blocker HIMMEL-8102 >/dev/null 2>&1
blocker_done
out="$(rd v1)"
check "R6: a Done blocker makes the c row stale" "$(printf '%s' "$out" | jq -r .state)" "stale"
check "R6: with why blocker-done" "$(printf '%s' "$out" | jq -r .why)" "blocker-done"
blocker_open
T_STATUS="Done"; T_CAT="Done"; writet FIXT-101
check "R6: a Done ticket is omitted" "$(rd v1 | wc -l | tr -d ' ')" "0"
deft; T_FIX='["v2"]'; writet FIXT-101
check "R6: a ticket that left the version is omitted" "$(rd v1 | wc -l | tr -d ' ')" "0"
deft; writet FIXT-101
READINESS_NOW_EPOCH=$((E0 + 3600)) ap v1 FIXT-101 c --evidence y2 --blocker HIMMEL-8102 >/dev/null 2>&1
out="$(READINESS_NOW_EPOCH=$((E0 + 7200)) rd v1)"
check "R6: an identical re-append keeps since at the first row's ts" "$(printf '%s' "$out" | jq -r .since)" "2027-01-15T08:00:00Z"
check "R6: age_s is 7200 at +7200" "$(printf '%s' "$out" | jq -r .age_s)" "7200"
T_BLOCKS='["HIMMEL-8104"]'; writet FIXT-101
check "R6: a blocks link makes the row stale" "$(rd v1 | jq -r .state)" "stale"
deft; writet FIXT-101
out="$(READINESS_NOW_EPOCH=$((E0 + 7200)) rd v1)"
check "R6: removing it reads live again" "$(printf '%s' "$out" | jq -r .state)" "live"
check "R6: with the same since" "$(printf '%s' "$out" | jq -r .since)" "2027-01-15T08:00:00Z"
ap v1 FIXT-101 a --evidence ruled >/dev/null 2>&1
check "R6: a different decision starts a new run" "$(rd v1 | jq -r .since)" "2027-01-15T08:00:00Z"

fresh
for i in $(seq 1 20); do
    bash "$RD" append v1 FIXT-101 a --evidence "n$i" --by fixture --mirror "$M" >/dev/null 2>&1 &
done
wait
check "R7: twenty concurrent appends leave 20 lines" "$(wc -l "$REC" | cut -d' ' -f1)" "20"
check "R7: every line is a valid row" "$(jq -c . "$REC" | wc -l | tr -d ' ')" "20"
orig20="$(sed -n 20p "$REC")"
truncate -s -1 "$REC"
check "R7: stripping the final newline leaves 19 complete lines" "$(wc -l "$REC" | cut -d' ' -f1)" "19"
rd v1 >/dev/null 2>&1; rc=$?
check "R7: read ignores the unterminated final row and exits 0" "$rc" "0"
ap v1 FIXT-101 a --evidence next >"$W/o" 2>"$W/e"; rc=$?
check "R7: append after a valid unterminated row exits 0" "$rc" "0"
contains "R7: and says it completed the row" "$(cat "$W/e")" "completed an unterminated final row"
check "R7: 21 complete lines" "$(wc -l "$REC" | cut -d' ' -f1)" "21"
check "R7: the 20th row is byte-identical to its original" "$(sed -n 20p "$REC")" "$orig20"
printf '{"ts":"2027-01' >> "$REC"
rd v1 >/dev/null 2>&1; rc=$?
check "R7: read ignores a half row and exits 0" "$rc" "0"
ap v1 FIXT-101 a --evidence after-half >"$W/o" 2>"$W/e"; rc=$?
check "R7: append after a half row exits 0" "$rc" "0"
contains "R7: and says it dropped the torn line" "$(cat "$W/e")" "dropped a torn final line"
check "R7: 22 complete lines" "$(wc -l "$REC" | cut -d' ' -f1)" "22"
printf 'junk\n' >> "$REC"
before="$(sha "$REC")"
rd v1 >"$W/o" 2>"$W/e"; rc=$?
check "R7: read exits 4 on a junk line" "$rc" "4"
contains "R7: and names the line number" "$(cat "$W/e")" "line 23"
ap v1 FIXT-101 a --evidence blocked >"$W/o" 2>"$W/e"; rc=$?
check "R7: append exits 4 on a junk line" "$rc" "4"
contains "R7: and names the line number" "$(cat "$W/e")" "line 23"
check "R7: the record is unchanged by the refusal" "$(sha "$REC")" "$before"

fresh
before="$(sha "$REC")"
for case_ in $'a\xe2\x80\xa8b' $'a\xe2\x80\xa9b' $'a\xc2\x85b' $'a\nb' $'a\tb'; do
    ap v1 FIXT-101 a --evidence "$case_" >/dev/null 2>&1; rc=$?
    check "R8: evidence with a Cc/Zl/Zp character exits 2 ($(printf '%s' "$case_" | od -An -tx1 | tr -d ' \n'))" "$rc" "2"
done
check "R8: nothing was written" "$(sha "$REC")" "$before"
ev=$'caf\xc3\xa9 \xf0\x9f\x98\x80'
ap v1 FIXT-101 a --evidence "$ev" >/dev/null 2>&1; rc=$?
check "R8: evidence with an accent and an emoji exits 0" "$rc" "0"
check "R8: the record file is pure ASCII" "$(LC_ALL=C grep -c -P '[^\x00-\x7F]' "$REC")" "0"
check "R8: the accent is stored as an escape" "$(grep -c 'u00e9' "$REC")" "1"
check "R8: read returns it unchanged" "$(rd v1 | jq -r .evidence)" "$ev"

fresh
rm -rf "$REL/vnone"
ap vnone FIXT-999 a --evidence x >/dev/null 2>&1; rc=$?
check "R9: a key with no mirror file exits 3" "$rc" "3"
check "R9: and creates no record" "$([ -e "$REL/vnone" ] && echo yes || echo no)" "no"
printf 'not a mirror file\n' > "$M/FIXT-998.md"
ap v1 FIXT-998 a --evidence x >/dev/null 2>&1; rc=$?
check "R9: an unparsable mirror file exits 3" "$rc" "3"
ap v1 FIXT-101 a --evidence x >/dev/null 2>&1
rm -f "$M/FIXT-101.md"
out="$(rd v1)"
check "R9: a deleted mirror file reads stale" "$(printf '%s' "$out" | jq -r .state)" "stale"
check "R9: with why no-ticket" "$(printf '%s' "$out" | jq -r .why)" "no-ticket"
check "R9: and cat null" "$(printf '%s' "$out" | jq -r .cat)" "null"

fresh
snap="$(tree)"
ap ../x FIXT-101 a --evidence x >/dev/null 2>&1; rc=$?
check "R10: a version of ../x exits 2" "$rc" "2"
ap v1 ../x a --evidence x >/dev/null 2>&1; rc=$?
check "R10: a key of ../x exits 2" "$rc" "2"
rd ../x >/dev/null 2>&1; rc=$?
check "R10: read of ../x exits 2" "$rc" "2"
check "R10: nothing is written" "$(tree)" "$snap"
check "R10: and nothing outside the release root" "$([ -e "$W/x" ] && echo yes || echo no)" "no"

fresh
rm -rf "$REL/v1"
rd v1 >/dev/null 2>&1; rc=$?
check "R11: read with the version directory absent exits 3" "$rc" "3"
mkdir -p "$REL/v1"
out="$(rd v1)"; rc=$?
check "R11: read with a directory and no record exits 0" "$rc" "0"
check "R11: and prints nothing" "$out" ""
HIMMEL_RELEASE_STATE_DIR="$W/nope" bash "$RD" read v1 --mirror "$M" >/dev/null 2>&1; rc=$?
check "R11: a missing release root exits 3" "$rc" "3"

fresh
before="$(sha "$REC")"
ap v1 FIXT-101 c --evidence x --blocker FIXT-101 >/dev/null 2>&1; rc=$?
check "R12: a blocker equal to the key exits 2" "$rc" "2"
ap v1 FIXT-101 a --evidence '' >/dev/null 2>&1; rc=$?
check "R12: empty evidence exits 2" "$rc" "2"
ap v1 FIXT-101 a --evidence "$(printf 'x%.0s' $(seq 1 1025))" >/dev/null 2>&1; rc=$?
check "R12: 1025 characters of evidence exit 2" "$rc" "2"
ap v1 FIXT-101 a --evidence "$(printf 'x%.0s' $(seq 1 1024))" >/dev/null 2>&1; rc=$?
check "R12: 1024 characters of evidence exit 0" "$rc" "0"
rm -f "$REC"
bash "$RD" append v1 FIXT-101 a --evidence x --by 'a b' --mirror "$M" >/dev/null 2>&1; rc=$?
check "R12: a by with a space exits 2" "$rc" "2"
bash "$RD" append v1 FIXT-101 a --evidence x --mirror "$M" >"$W/o" 2>"$W/e"; rc=$?
check "R12: no --by and no session name exits 2" "$rc" "2"
contains "R12: with the by unresolvable message" "$(cat "$W/e")" "by unresolvable"
printf 'claude\0-n\0sess-1\0' > "$W/cmdline"
CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$W/cmdline" bash "$RD" append v1 FIXT-101 a --evidence x --mirror "$M" >/dev/null 2>&1; rc=$?
check "R12: the session name is the default by" "$rc" "0"
check "R12: the row carries it" "$(sed -n 1p "$REC" | jq -r .by)" "sess-1"
printf '{"lastSync":"2026-11-16T08:00:00.000Z","total":1}\n' > "$M/.cursor.json"
ap v1 FIXT-103 a --evidence x >"$W/o" 2>"$W/e"; rc=$?
check "R12: a key outside the version exits 2" "$rc" "2"
contains "R12: and the message names the mirror's lastSync" "$(cat "$W/e")" "2026-11-16T08:00:00.000Z"

fresh
ln -s /dev/full "$REC"
ap v1 FIXT-101 a --evidence x >"$W/o" 2>"$W/e"; rc=$?
check "R13: a write error (ENOSPC) exits 4" "$rc" "4"
lacks "R13: with no traceback" "$(cat "$W/e")" "Traceback"
rm -f "$REC"

fresh
ap v1 FIXT-101 a --evidence x >/dev/null 2>&1
sed -i 's/2027-01-15T08:00:00Z/2027-99-15T08:00:00Z/' "$REC" # gnu-ok: the chief kit is Linux-only
rd v1 >"$W/o" 2>"$W/e"; rc=$?
check "R14: read of a row with month 99 exits 4" "$rc" "4"
lacks "R14: with no traceback" "$(cat "$W/e")" "Traceback"
ap v1 FIXT-101 a --evidence y >/dev/null 2>&1; rc=$?
check "R14: append after it exits 4" "$rc" "4"

printf '%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
