#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail is the test-assert idiom (pass and fail always return 0)
set -u
repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
GC="$repo_root/scripts/himmelctl/lib/graph-choices.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }
[ -f "$GC" ] || { echo "FAIL: $GC not found"; exit 1; }

WS="$(mktemp -d -t graph-choices-test.XXXXXX)" || exit 1; trap 'chmod -R u+rwx "$WS" 2>/dev/null; rm -rf "$WS"' EXIT
unset HIMMEL_LUNA_CONFIG_PATH XDG_DATA_HOME

fresh_home() {
    H="$WS/$1"; mkdir -p "$H/.himmel"
    export HOME="$H" USERPROFILE="$H" HIMMEL_CONFIG_DIR="$H/.himmel" HIMMEL_CONFIG_AUDIT_DIR="$H/.himmel/state/config-audit"
    export HIMMEL_API_CREDIT_CONFIG="$WS/no-roster.json"
    export HIMMELCTL_CACHE_DIR="$H/cache"; mkdir -p "$HIMMELCTL_CACHE_DIR"; : > "$HIMMELCTL_CACHE_DIR/.env"
}
cfg() { printf '%s\n' "$1" > "$HOME/.himmel/config.json"; }
gc() { node "$GC" "$@"; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }
mkrepo() { mkdir -p "$1/.git"; }

NO_CHOICE='Without a graph choice, graphify builds the code structure from a local parse for free, and a semantic pass that runs on a repo other than himmel describes its markdown on this machine'"'"'s Claude subscription, only after a usage check and never on an API key; choose none to keep the structure only.'
NONE_S='With the graph choice none, graphify builds only the code structure from a local parse, with no model calls and no cost.'
SET_S='This station'"'"'s graph choice runs through its daily graph job on the repos it lists; this run makes no semantic call.'
INVALID_S='The graph choice in ~/.himmel/config.json is not valid, so no semantic call runs; the doctor (C88) names the problem.'
CHECK_DEFAULT='no graph choice: a semantic pass on a repo other than himmel uses this machine'"'"'s Claude subscription after the usage check, never an API key'
WORST_DEFAULT='With no graph choice: a semantic pass that runs uses this machine'"'"'s Claude subscription; usage is checked once, before the run starts, and the run does not stop if the budget runs out while it works.'
FIX_P='sign the claude CLI in on this machine; or, to stop semantic passes here, set graphify.choices to {"version":1,"corpora":[],"primary":"none"} in ~/.himmel/config.json and run bash scripts/lib/config-audit.sh accept'
FIX_C='remove the variable from this job'"'"'s environment (crontab or shell profile); or stop semantic passes here as FIX_PREFLIGHT says'
FIX_H='remove apiKeyHelper from ~/.claude/settings.json, or set GRAPHIFY_CLAUDE_SOURCE_CONFIG_DIR to a Claude config without it; or stop semantic passes here as FIX_PREFLIGHT says'

echo "C1: role for true, false, no file"
fresh_home c1a; cfg '{"graphify":{"semantic_api_ok":true}}'; expect_eq "C1 semantic_api_ok true reads publisher" "$(gc role)" publisher
fresh_home c1b; cfg '{"graphify":{"semantic_api_ok":false}}'; expect_eq "C1 semantic_api_ok false reads adopter" "$(gc role)" adopter
fresh_home c1c; expect_eq "C1 no file reads adopter" "$(gc role)" adopter
fresh_home c1d; rmdir "$HOME/.himmel"; expect_eq "C1 no ~/.himmel reads adopter" "$(gc role)" adopter

echo "C2: unreadable shapes; a bad vm section leaves publisher"
fresh_home c2a; printf '{"graphify":{"semantic_api_ok":true}}\n' > "$WS/c2a-real.json"; ln -s "$WS/c2a-real.json" "$HOME/.himmel/config.json"
expect_eq "C2 symlinked config.json reads unreadable" "$(gc role)" unreadable
fresh_home c2b; mkdir -p "$WS/c2b-real"; printf '{}\n' > "$WS/c2b-real/config.json"; rm -rf "$HOME/.himmel"; ln -s "$WS/c2b-real" "$HOME/.himmel"
export HIMMEL_CONFIG_DIR="$HOME/.himmel"
expect_eq "C2 symlinked ~/.himmel reads unreadable" "$(gc role)" unreadable
fresh_home c2c; cfg 'not json {'; expect_eq "C2 non-JSON reads unreadable" "$(gc role)" unreadable
fresh_home c2d; : > "$HOME/.himmel/config.json"; expect_eq "C2 empty reads unreadable" "$(gc role)" unreadable
fresh_home c2e; cfg '{"graphify":"on"}'; expect_eq "C2 a graphify string reads unreadable" "$(gc role)" unreadable
fresh_home c2f; cfg '[1,2]'; expect_eq "C2 a JSON array reads unreadable" "$(gc role)" unreadable
fresh_home c2g; cfg '{"vm":"broken","graphify":{"semantic_api_ok":true}}'; expect_eq "C2 a bad vm section with the key true reads publisher" "$(gc role)" publisher
fresh_home c2h; cfg '{}'; chmod 000 "$HOME"
if ls "$HOME/.himmel" >/dev/null 2>&1; then echo "  SKIP: C2 an unsearchable HOME (this user reads mode 000)"
else expect_eq "C2 a station dir that cannot be stat'ed reads unreadable, never adopter" "$(gc role)" unreadable; fi
chmod 700 "$HOME"

echo "C3: invalid stores, all or nothing, no value echoed"
for doc in \
  '{"version":1,"corpora":[],"primary":"auto"}' \
  '{"version":1,"corpora":[],"primary":"sk-ant-planted-c3"}' \
  '{"version":1,"corpora":[],"primary":"A","fallbacks":["A"],"max_usd_per_pass":5}' \
  '{"version":1,"corpora":[],"primary":"none","fallbacks":["subscription"]}'; do
    fresh_home c3; cfg "{\"graphify\":{\"choices\":$doc}}"
    out="$(gc route)"; st="$(gc route --state)"
    expect_eq "C3 $(printf '%s' "$doc" | cut -c1-60) reads invalid" "$st" invalid
    hasnt "C3 no planted value in route output" "$out$(gc check)$(gc sentence)" "sk-ant"
done

echo "C4: a partly valid document never applies"
fresh_home c4; mkrepo "$WS/c4-repo"
cfg "{\"graphify\":{\"choices\":{\"version\":1,\"corpora\":[{\"name\":\"good\",\"root\":\"$WS/c4-repo\"},{\"name\":\".bad\",\"root\":\"$WS/c4-repo\"}],\"primary\":\"subscription\"}}}"
expect_eq "C4 one bad corpus makes the whole store invalid" "$(gc route --state)" invalid
expect_eq "C4 the good corpus is not listed" "$(gc listed "$WS/c4-repo"; echo $?)" 1

echo "C5: a root with no .git is refused"
mkdir -p "$WS/c5-nogit"; out="$(gc root-check "$WS/c5-nogit")"; rc=$?
if [ "$rc" -eq 1 ]; then has "C5 root-check refuses with the reason" "$out" ".git"; else fail "C5 root-check rc=$rc: $out"; fi
mkrepo "$WS/c5-repo"; gc root-check "$WS/c5-repo" >/dev/null && pass "C5 a git root passes" || fail "C5 a git root refused"

echo "C6: route on no file reads default"
fresh_home c6; out="$(gc route)"
expect_eq "C6 state default, order subscription, no corpora" "$out" '{"state":"default","corpora":[],"order":["subscription"],"max_usd_per_pass":null,"errors":[]}'

echo "C6b: corpora and no primary is default; fallbacks and no primary is invalid"
fresh_home c6b; mkrepo "$WS/c6b-repo"
cfg "{\"graphify\":{\"choices\":{\"version\":1,\"corpora\":[{\"name\":\"r\",\"root\":\"$WS/c6b-repo\"}]}}}"
expect_eq "C6b corpora, no primary reads default" "$(gc route --state)" default
has "C6b its order is the subscription" "$(gc route)" '"order":["subscription"]'
cfg '{"graphify":{"choices":{"version":1,"corpora":[],"fallbacks":["subscription"]}}}'
expect_eq "C6b fallbacks, no primary reads invalid" "$(gc route --state)" invalid

echo "C6c: primary none reads none with an empty order"
fresh_home c6c; cfg '{"graphify":{"choices":{"version":1,"corpora":[],"primary":"none"}}}'
expect_eq "C6c state none" "$(gc route --state)" none
has "C6c empty order" "$(gc route)" '"order":[]'

echo "C6d: route --state prints the one word for each state"
fresh_home c6d1; expect_eq "C6d default" "$(gc route --state)" default
fresh_home c6d2; cfg '{"graphify":{"choices":{"version":1,"primary":"none"}}}'; expect_eq "C6d none" "$(gc route --state)" none
fresh_home c6d3; cfg '{"graphify":{"choices":{"version":1,"primary":"subscription"}}}'; expect_eq "C6d set" "$(gc route --state)" set
fresh_home c6d4; cfg '{"graphify":{"choices":{"version":1,"primary":"auto"}}}'; expect_eq "C6d invalid" "$(gc route --state)" invalid
fresh_home c6d5; cfg 'nope'; expect_eq "C6d unreadable" "$(gc route --state)" unreadable

echo "C7: listed matches a root reached through a symlinked parent"
fresh_home c7; mkrepo "$WS/c7-real/repo"; ln -s "$WS/c7-real" "$WS/c7-link"
cfg "{\"graphify\":{\"choices\":{\"version\":1,\"corpora\":[{\"name\":\"repo\",\"root\":\"$WS/c7-real/repo\"}],\"primary\":\"none\"}}}"
gc listed "$WS/c7-link/repo" && pass "C7 listed through the symlinked parent" || fail "C7 listed missed the symlinked path"
gc listed "$WS/c5-repo" && fail "C7 an unlisted root reads listed" || pass "C7 an unlisted root is not listed"

echo "C8: the cap"
fresh_home c8; cfg '{"graphify":{"choices":{"version":1,"primary":"subscription","fallbacks":["A"]}}}'
expect_eq "C8 cap missing with a letter in fallbacks is invalid" "$(gc route --state)" invalid
cfg '{"graphify":{"choices":{"version":1,"primary":"A","max_usd_per_pass":0.1}}}'
expect_eq "C8 cap under 0.25 is invalid" "$(gc route --state)" invalid

echo "C9: root-check refuses a root the classifier names"
fresh_home c9
c9_env() { printf 'LUNA_VAULT_PATH=%s\nHANDOVER_DIR=%s\n' "$1" "$2" > "$HIMMELCTL_CACHE_DIR/.env"; }
c9_refused() {
    local out rc; out="$(gc root-check "$2")"; rc=$?
    if [ "$rc" -eq 1 ]; then has "$1" "$out" "$3"; else fail "$1 (rc=$rc, out=$out)"; fi
}
c9_env "$WS/c9-vault" "$WS/c9-hand"
mkrepo "$WS/c9-vault"; mkrepo "$WS/c9-hand/repo"; mkrepo "$WS/c9-obs"; mkdir -p "$WS/c9-obs/.obsidian"; mkrepo "$WS/c9-salus"; : > "$WS/c9-salus/.salus"; mkrepo "$WS/c9-plain"
mkrepo "$WS/c9-himmel"
out="$(GRAPHIFY_HIMMEL_ROOT="$WS/c9-himmel" gc root-check "$WS/c9-himmel")"; rc=$?
if [ "$rc" -eq 1 ]; then has "C9 a himmel checkout is refused" "$out" himmel-code; else fail "C9 a himmel checkout (rc=$rc, out=$out)"; fi
c9_refused "C9 a root inside HANDOVER_DIR is refused" "$WS/c9-hand/repo" handover-state
c9_refused "C9 the configured vault is refused" "$WS/c9-vault" luna-personal
c9_refused "C9 a .obsidian root is refused" "$WS/c9-obs" luna-personal
c9_refused "C9 a .salus root is refused" "$WS/c9-salus" salus
gc root-check "$WS/c9-plain" >/dev/null && pass "C9 a plain git root still passes" || fail "C9 a plain git root refused"
mkdir -p "$WS/c9-phi-dir/phi-roots"; mkrepo "$WS/c9-badphi"
out="$(CLAUDE_GLM_CONFIG_DIR="$WS/c9-phi-dir" gc root-check "$WS/c9-badphi")"; rc=$?
if [ "$rc" -eq 1 ]; then has "C9 an unreadable PHI list refuses with the classifier reason" "$out" "cannot be classified"; else fail "C9 unreadable PHI list rc=$rc: $out"; fi

echo "C10: root-check also looks below the root"
mkrepo "$WS/c10-salus"; mkdir -p "$WS/c10-salus/sub"; : > "$WS/c10-salus/sub/.salus"
c9_refused "C10 a nested .salus is refused" "$WS/c10-salus" salus
mkrepo "$WS/c10-phi"; mkdir -p "$WS/c10-phi/nested" "$WS/c10-phicfg"; printf '%s\n' "$WS/c10-phi/nested" > "$WS/c10-phicfg/phi-roots"
out="$(CLAUDE_GLM_CONFIG_DIR="$WS/c10-phicfg" gc root-check "$WS/c10-phi")"; rc=$?
if [ "$rc" -eq 1 ]; then has "C10 a nested PHI root is refused" "$out" salus; else fail "C10 nested PHI root rc=$rc: $out"; fi
mkrepo "$WS/c10-obs"; mkdir -p "$WS/c10-obs/notes/.obsidian"
c9_refused "C10 a nested .obsidian is refused" "$WS/c10-obs" luna-personal
mkrepo "$WS/c10-v"; mkdir -p "$WS/c10-v/vault"; c9_env "$WS/c10-v/vault" "$WS/c9-hand"
c9_refused "C10 a configured vault below the root is refused" "$WS/c10-v" luna-personal
mkrepo "$WS/c10-inline"; mkdir -p "$WS/c10-inline/handovers"; : > "$WS/c10-inline/handovers/note.md"; c9_env "$WS/c9-vault" "$WS/c10-inline/handovers"
gc root-check "$WS/c10-inline" >/dev/null && pass "C10 an inline handovers folder below the root is not refused (A8)" || fail "C10 an inline handovers folder refused"

echo "C11: a name of . or .. is refused"
fresh_home c11
for n in . ..; do
    cfg "{\"graphify\":{\"choices\":{\"version\":1,\"corpora\":[{\"name\":\"$n\",\"root\":\"$WS/c5-repo\"}],\"primary\":\"none\"}}}"
    expect_eq "C11 name '$n' is invalid" "$(gc route --state)" invalid
done

echo "C12: a missing root leaves route valid and fails root-check alone"
fresh_home c12; cfg "{\"graphify\":{\"choices\":{\"version\":1,\"corpora\":[{\"name\":\"gone\",\"root\":\"$WS/c12-gone\"}],\"primary\":\"none\"}}}"
expect_eq "C12 route stays none" "$(gc route --state)" none
gc root-check "$WS/c12-gone" >/dev/null && fail "C12 root-check passed a missing root" || pass "C12 root-check fails the missing root"

echo "C13 and C14: pending and out"
fresh_home c13; o="$(gc out acme)"
case "$o" in "$HOME/.local/share/himmel/graphify/choices/acme/graphify-out") pass "C14 out ends in graphify-out under choices/<name>" ;; *) fail "C14 out: $o" ;; esac
expect_eq "C13 no batch prints nothing" "$(gc pending acme)" ""
mkdir -p "$o/semantic-batch"; printf '{}\n' > "$o/semantic-batch/batch.json"
expect_eq "C13 pending prints the waiting batch's path" "$(gc pending acme)" "$o/semantic-batch"

echo "C15: worst-case lines"
fresh_home c15; expect_eq "C15 default prints WORST_DEFAULT_LINE exactly" "$(gc worst-case)" "$WORST_DEFAULT"
cfg '{"graphify":{"choices":{"version":1,"primary":"A","fallbacks":["subscription"],"max_usd_per_pass":5}}}'
out="$(gc worst-case)"
has "C15 a route with a letter names its cap" "$out" "up to 5.00 USD a day, as an estimate"
has "C15 a route with the subscription names its step" "$out" "up to 150 markdown files a fire; usage is checked once, before the run starts, and the run does not stop if the budget runs out while it works."

echo "C16: a release install says there is no himmel graph"
REL="$WS/c16-release"; mkdir -p "$REL/scripts/himmelctl/lib" "$REL/scripts/lib"
cp "$GC" "$REL/scripts/himmelctl/lib/"; cp "$repo_root/scripts/lib/api-credit-state.mjs" "$REL/scripts/lib/"
fresh_home c16
has "C16 remedy on a release install" "$(node "$REL/scripts/himmelctl/lib/graph-choices.js" remedy)" "this release install has no himmel graph"
expect_eq "C16 first-question on a release install" "$(node "$REL/scripts/himmelctl/lib/graph-choices.js" first-question)" "This release install has no himmel graph; a git install pulls it from us."
expect_eq "C16 first-question on a git install" "$(gc first-question)" "The himmel code graph comes from us with each update; you do not build it."
hasnt "C16 remedy on an adopter names no refresh-graph-map.sh" "$(gc remedy)" "refresh-graph-map.sh"

echo "C17: check over a fixture pass log"
fresh_home c17; mkdir -p "$HOME/.claude/graph-choices-cadence"
cat > "$HOME/.claude/graph-choices-cadence/graph-choices.log" <<'LOG'
[fired 2026-11-08T04:40:00Z]
2026-11-08T04:40:05Z acme ok
2026-11-09T04:40:05Z acme bank-refused
[exit rc=0]
2026-11-10T04:40:05Z acme bank-refused
2026-11-11T04:40:05Z acme bank-refused
2026-11-11T04:40:06Z acme ALERT key-rejected the A key was rejected
LOG
out="$(gc check)"
has "C17 counts three consecutive bank-refused" "$out" "bank-refused in a row: 3"
has "C17 the last word per corpus" "$out" "pass: acme bank-refused"
has "C17 the open alert" "$out" "alert: acme key-rejected the A key was rejected"
hasnt "C17 skips the runner's own lines" "$out" "fired"
fresh_home c17b; has "C17 no log reads as no pass yet" "$(gc check)" "pass: no pass yet"

echo "C18: both docs carry the two sentences verbatim"
for doc in docs/internals/graph-cadence.md docs/setup/new-machine.md; do
    flat="$(tr '\n' ' ' < "$repo_root/$doc" | tr -s ' ')"
    has "C18 $doc holds NO_CHOICE_SENTENCE" "$flat" "$NO_CHOICE"
    has "C18 $doc holds NONE_SENTENCE" "$flat" "$NONE_S"
done

echo "C19: check on each unreadable cause prints the file, its cause word and its fixed line"
fresh_home c19a; printf '{}\n' > "$WS/c19a.json"; ln -s "$WS/c19a.json" "$HOME/.himmel/config.json"
out="$(gc check)"; has "C19 symlink cause" "$out" "cause=symlink"; has "C19 symlink fixed line names the file" "$out" "graph config unreadable (cause=symlink): ~/.himmel or ~/.himmel/config.json is a symlink"
has "C19 a linked file without the key reads linked=not-publisher" "$out" "linked=not-publisher"
printf '{"graphify":{"semantic_api_ok":true}}\n' > "$WS/c19a.json"; has "C19 a linked publisher file reads linked=publisher" "$(gc check)" "linked=publisher"
fresh_home c19b; mkdir -p "$WS/c19b"; printf '{}\n' > "$WS/c19b/config.json"; rm -rf "$HOME/.himmel"; ln -s "$WS/c19b" "$HOME/.himmel"
has "C19 symlinked ~/.himmel cause" "$(gc check)" "cause=symlink"
fresh_home c19c; cfg '{}'; chmod 000 "$HOME/.himmel/config.json"
if [ -r "$HOME/.himmel/config.json" ]; then echo "  SKIP: C19 mode 000 (this user reads mode 000)"
else has "C19 mode cause" "$(gc check)" "graph config unreadable (cause=mode): ~/.himmel/config.json cannot be read"; fi
chmod 600 "$HOME/.himmel/config.json"
fresh_home c19d; cfg 'not json'; has "C19 not-json cause" "$(gc check)" "graph config unreadable (cause=not-json): ~/.himmel/config.json is not a JSON object"
fresh_home c19e; : > "$HOME/.himmel/config.json"; has "C19 empty cause" "$(gc check)" "graph config unreadable (cause=empty): ~/.himmel/config.json is empty"
fresh_home c19f; cfg '{"graphify":"sk-ant-c19f"}'; out="$(gc check)"
has "C19 graphify-shape cause" "$out" "graph config unreadable (cause=graphify-shape): the graphify key in ~/.himmel/config.json is not an object"
hasnt "C19 no file byte in check" "$out" "sk-ant"
fresh_home c19g; mkdir -p "$HOME/.himmel/config.json"; has "C19 not-a-file cause" "$(gc check)" "cause=not-a-file"

echo "C21: decision 780 routes over any subset of letters"
fresh_home c21; cfg '{"graphify":{"choices":{"version":1,"primary":"A","max_usd_per_pass":5}}}'
expect_eq "C21 primary A alone reads set" "$(gc route --state)" set
out="$(gc worst-case)"; has "C21 worst-case names A alone" "$out" "The API steps (A):"
cfg '{"graphify":{"choices":{"version":1,"primary":"C","fallbacks":["A"],"max_usd_per_pass":5}}}'
has "C21 C then A keeps that order" "$(gc route)" '"order":["C","A"]'
cfg '{"graphify":{"choices":{"version":1,"primary":"AB","max_usd_per_pass":5}}}'
expect_eq "C21 a value that is not one capital letter is invalid" "$(gc route --state)" invalid
out="$(node -e 'const g=require(process.argv[1]);console.log(JSON.stringify(g.rosterCheck({version:1,primary:"D",max_usd_per_pass:5},[{account:"D",configured:true}])))' "$GC")"
expect_eq "C21 (stub-only) a stubbed roster with D configured passes" "$out" "[]"

echo "C23: check prints each roster line by reason word"
roster_row() {
    fresh_home "c23-$1"
    if [ "$2" = MISSING ]; then export HIMMEL_API_CREDIT_CONFIG="$WS/c23-none.json"
    else printf '%s\n' "$2" > "$WS/c23-$1.json"; export HIMMEL_API_CREDIT_CONFIG="$WS/c23-$1.json"; fi
    has "C23 $1" "$(gc check)" "$3"
}
roster_row no-file MISSING "roster: no API account is set up here, or its roster cannot be read; none is offered"
roster_row not-json 'nope' "roster: no API account is set up here, or its roster cannot be read; none is offered"
roster_row empty '{"version":1,"ledger_path":"/tmp/c23-ledger.json","accounts":{}}' "roster: the API roster lists no account"
roster_row d-row '{"version":1,"ledger_path":"/tmp/c23-ledger.json","accounts":{"D":{"organization_id":"o","cycle_id":"c","cap_usd":"1"}}}' "roster: a row in the API roster names a letter outside A, B, C, or is damaged; the whole roster is refused, so no account runs"
roster_row string-row '{"version":1,"ledger_path":"/tmp/c23-ledger.json","accounts":{"A":"x"}}' "roster: a row in the API roster names a letter outside A, B, C, or is damaged"
roster_row identity '{"version":1,"ledger_path":"/tmp/c23-ledger.json","accounts":{"A":{"organization_id":"bad id sk-ant-c23","cycle_id":"c","cap_usd":"1"}}}' "roster: the API roster is refused (invalid-identity); no account runs"
hasnt "C23 the any-other line names no value" "$(gc check)" "sk-ant"

echo "C24: rosterCheck"
rc24() { node -e 'const g=require(process.argv[1]);console.log(JSON.stringify(g.rosterCheck(JSON.parse(process.argv[2]),JSON.parse(process.argv[3]))))' "$GC" "$1" "$2"; }
ROWS='[{"account":"A","configured":true},{"account":"B","configured":false},{"account":"C","configured":true}]'
expect_eq "C24 an unconfigured B is refused naming B" "$(rc24 '{"primary":"A","fallbacks":["B"]}' "$ROWS")" '["B is not a configured API account"]'
expect_eq "C24 a D row on a stubbed roster with no D is refused naming D" "$(rc24 '{"primary":"D"}' "$ROWS")" '["D is not a configured API account"]'
expect_eq "C24 an unreadable roster refuses A with its roster line" "$(rc24 '{"primary":"A"}' '{"accounts":"unreadable","reason":"unreadable-state"}')" '["no API account is set up here, or its roster cannot be read; none is offered"]'
expect_eq "C24 subscription alone passes on an unreadable roster" "$(rc24 '{"primary":"subscription"}' '{"accounts":"unreadable","reason":"unreadable-state"}')" '[]'
expect_eq "C24 none passes on an unreadable roster" "$(rc24 '{"primary":"none"}' '{"accounts":"unreadable","reason":"unreadable-state"}')" '[]'

echo "C25: check names the no-choice line only in state default"
fresh_home c25a; has "C25 default prints CHECK_DEFAULT_LINE" "$(gc check)" "$CHECK_DEFAULT"
fresh_home c25b; cfg '{"graphify":{"choices":{"version":1,"primary":"none"}}}'; hasnt "C25 none does not" "$(gc check)" "$CHECK_DEFAULT"
fresh_home c25c; cfg '{"graphify":{"semantic_api_ok":true}}'; hasnt "C25 a publisher does not" "$(gc check)" "$CHECK_DEFAULT"

echo "C26: sentence --state, the station's own state, and --fix"
fresh_home c26
expect_eq "C26 --state default" "$(gc sentence --state default)" "$NO_CHOICE"
expect_eq "C26 --state none" "$(gc sentence --state none)" "$NONE_S"
expect_eq "C26 --state set" "$(gc sentence --state set)" "$SET_S"
expect_eq "C26 --state invalid" "$(gc sentence --state invalid)" "$INVALID_S"
expect_eq "C26 no flag on no file is the default text" "$(gc sentence)" "$NO_CHOICE"
cfg '{"graphify":{"choices":{"version":1,"primary":"none"}}}'; expect_eq "C26 no flag on none is the none text" "$(gc sentence)" "$NONE_S"
cfg 'broken'; expect_eq "C26 no flag on unreadable prints nothing" "$(gc sentence)" ""
expect_eq "C26 --fix preflight" "$(gc sentence --fix preflight)" "$FIX_P"
expect_eq "C26 --fix credential" "$(gc sentence --fix credential)" "$FIX_C"
expect_eq "C26 --fix helper" "$(gc sentence --fix helper)" "$FIX_H"
gc sentence --fix other >/dev/null 2>&1 && fail "C26 an unknown --fix word passes" || pass "C26 an unknown --fix word refuses"

echo
if [ "$FAILS" -eq 0 ]; then echo "test-graph-choices: all passed"; exit 0; fi
echo "test-graph-choices: $FAILS FAILURES"; exit 1
