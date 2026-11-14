#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2317,SC2329
# test-graph-choices-pass.sh -- hermetic rows P1 to P25 for scripts/graphify/graph-choices-pass.sh.
#
# The real pass runs against a throwaway HOME holding the choice store, with stub ast-update.sh, semantic-update.sh,
# claude and alert sender. No paid call, no network, no real crontab, no real subscription launch, and no fixture
# carries a key value: planted credential names hold the word "planted".
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$here/../.." && pwd)"
PASS_REAL="$here/graph-choices-pass.sh"
GC="$REPO/scripts/himmelctl/lib/graph-choices.js"
REAL_LIB="$REPO/scripts/lib/native-auth-pin.sh"
BASE_PATH="$PATH"
fails=0
TD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/graph-choices-pass-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TD"' EXIT

# a fresh HOME holding {} for the whole suite (P6-9)
mkdir -p "$TD/suite-home/.himmel"
printf '{}\n' >"$TD/suite-home/.himmel/config.json"
export HOME="$TD/suite-home"

ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1: $2"; fails=$((fails + 1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "[$2] != [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in [$(printf '%s' "$2" | head -c 400)]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "found [$3] in [$(printf '%s' "$2" | head -c 400)]" ;; *) ok "$1" ;; esac; }
cnt() { local n=0; [ -f "$2" ] && n=$(grep -c -- "$1" "$2"); echo "$n"; }

# --- fixture -------------------------------------------------------------------------------------------------
new_fx() {
  FX="$TD/$1"
  H="$FX/home"
  mkdir -p "$H/.himmel" "$FX/bin" "$FX/repos" "$FX/xdg" "$FX/dedupe" "$FX/bat" "$FX/audit"
  printf '{}\n' >"$H/.himmel/config.json"
  : >"$FX/queue"
  PASS_BIN="$PASS_REAL"
  cat >"$FX/ast.sh" <<'EOF'
#!/usr/bin/env bash
echo "ast $1 out=${GRAPHIFY_OUT:-}" >>"$FX/ast.log"
rc=0
[ ! -f "$FX/ast-rc.$(basename "$1")" ] || rc="$(cat "$FX/ast-rc.$(basename "$1")")"
exit "$rc"
EOF
  cat >"$FX/sem.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FX/sem.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FX/sem.n"
echo "$*" >>"$FX/sem.log"
env | sed 's/=.*//' | sort >"$FX/sem-env.$n"
rf="" p=""
for a in "$@"; do [ "$p" = --result-file ] && rf="$a"; p="$a"; done
line="$(head -n 1 "$FX/queue" 2>/dev/null)"
tail -n +2 "$FX/queue" >"$FX/queue.t" 2>/dev/null && mv "$FX/queue.t" "$FX/queue"
[ -n "$line" ] || line=no-op
word="${line%%|*}" extra=""
case "$line" in *'|'*) extra="${line#*|}" ;; esac
[ "$word" = NORESULT ] && exit 0
[ -z "$rf" ] || { printf '%s\n' "$word" >"$rf"; [ -z "$extra" ] || printf '%s\n' "$extra" >>"$rf"; }
exit 0
EOF
  cat >"$FX/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >>"$FX/claude.log"
EOF
  cat >"$FX/send.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$FX/sent.log"
EOF
  cat >"$FX/plant.sh" <<'EOF'
export ANTHROPIC_PLANTED_RO=planted
readonly ANTHROPIC_PLANTED_RO
EOF
  chmod +x "$FX/ast.sh" "$FX/sem.sh" "$FX/bin/claude" "$FX/send.sh"
}

mkrepo() { mkdir -p "$FX/repos/$1/.git"; }

# cfg '<primary and fallbacks fragment>' <corpus name>...
cfg() {
  local frag="$1" cs="" sep="" n
  shift
  for n in "$@"; do
    mkrepo "$n"
    cs="$cs$sep{\"name\":\"$n\",\"root\":\"$FX/repos/$n\"}"
    sep=","
  done
  printf '{"graphify":{"choices":{"version":1,"corpora":[%s],%s,"max_usd_per_pass":5}}}\n' "$cs" "$frag" >"$H/.himmel/config.json"
}

queue() { : >"$FX/queue"; local l; for l in "$@"; do printf '%s\n' "$l" >>"$FX/queue"; done; }

run_pass() {
  OUT="$(env -i PATH="$FX/bin:$BASE_PATH" HOME="$H" HIMMEL_CONFIG_DIR="$H/.himmel" XDG_DATA_HOME="$FX/xdg" \
    GRAPHMAP_BAT_DIR="$FX/bat" HIMMEL_CONFIG_AUDIT_DIR="$FX/audit" CADENCE_ALERT_FILE="$FX/alerts.log" \
    CADENCE_ALERT_DEDUPE_DIR="$FX/dedupe" CADENCE_ALERT_SEND_CMD="$FX/send.sh" FX="$FX" \
    GRAPH_CHOICES_AST_UPDATE="$FX/ast.sh" GRAPH_CHOICES_SEMANTIC_UPDATE="$FX/sem.sh" HIMMEL_TEST_FIXTURE=1 \
    "$@" bash "$PASS_BIN" 2>&1)"
  RC=$?
}

run_check() {
  env -i PATH="$BASE_PATH" HOME="$H" HIMMEL_CONFIG_DIR="$H/.himmel" XDG_DATA_HOME="$FX/xdg" \
    GRAPHMAP_BAT_DIR="$FX/bat" HIMMEL_CONFIG_AUDIT_DIR="$FX/audit" node "$GC" check 2>&1
}

ncli() { cnt 'backend claude-cli' "$FX/sem.log"; }
napi() { cnt 'backend claude-api' "$FX/sem.log"; }
nsem() { cnt 'backend' "$FX/sem.log"; }
nast() { cnt 'ast ' "$FX/ast.log"; }
nsent() { cnt '' "$FX/sent.log"; }
nsentinel() { local n=0 f; for f in "$FX/dedupe/$1".*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
out_dir() { XDG_DATA_HOME="$FX/xdg" HOME="$H" HIMMEL_CONFIG_DIR="$H/.himmel" node "$GC" out "$1"; }

# a scratch tree of symlinks so the pass's REPO resolves to it; scripts/lib and scripts/graphify are linked file by
# file so a stub library and a modified pass copy can replace single entries
mk_tree() { # <dir> <libmode: shadow|pin1>
  local t="$1" mode="$2" e b d f
  mkdir -p "$t/scripts"
  for e in "$REPO"/scripts/*; do
    b="$(basename "$e")"
    case "$b" in lib | graphify) ;; *) ln -s "$e" "$t/scripts/$b" ;; esac
  done
  for d in lib graphify; do
    mkdir -p "$t/scripts/$d"
    for f in "$REPO/scripts/$d"/*; do [ -e "$f" ] && ln -s "$f" "$t/scripts/$d/$(basename "$f")"; done
  done
  rm -f "$t/scripts/lib/native-auth-pin.sh"
  case "$mode" in
    shadow) printf '. "%s"\nexit() { :; }\nreturn() { :; }\nunset() { :; }\n' "$REAL_LIB" >"$t/scripts/lib/native-auth-pin.sh" ;;
    pin1) printf '. "%s"\nnative_auth_pin_env() { return 1; }\n' "$REAL_LIB" >"$t/scripts/lib/native-auth-pin.sh" ;;
  esac
}

PLANTED=(ANTHROPIC_ORG_D_KEY=planted ANTHROPIC_AUTH_TOKEN=planted ANTHROPIC_BASE_URL=planted CLAUDE_CODE_USE_BEDROCK=planted anthropic_api_key=planted)

# --- P1 no store ----------------------------------------------------------------------------------------------
new_fx p1
run_pass
check "P1 rc" "$RC" 0
has "P1 the no-choice sentence" "$OUT" "Without a graph choice"
check "P1 no ast call" "$(nast)" 0
check "P1 no semantic call" "$(nsem)" 0

# --- P2 primary none with corpora -----------------------------------------------------------------------------
new_fx p2
cfg '"primary":"none"' c1
mkdir -p "$(out_dir c1)/semantic-batch"
: >"$(out_dir c1)/semantic-batch/batch.json"
run_pass
check "P2 rc" "$RC" 0
check "P2 ast called once" "$(nast)" 1
check "P2 no semantic call" "$(nsem)" 0
has "P2 the waiting batch path is printed" "$OUT" "$(out_dir c1)/semantic-batch"
has "P2 ast out dir is the choices graph dir" "$(cat "$FX/ast.log" 2>/dev/null)" "out=$(out_dir c1)"

# --- P3 publisher ---------------------------------------------------------------------------------------------
new_fx p3
mkrepo c1
printf '{"graphify":{"semantic_api_ok":true,"choices":{"version":1,"corpora":[{"name":"c1","root":"%s"}],"primary":"subscription"}}}\n' "$FX/repos/c1" >"$H/.himmel/config.json"
run_pass
check "P3 rc" "$RC" 0
has "P3 says why" "$OUT" "publishes"
check "P3 no ast call" "$(nast)" 0
check "P3 no semantic call" "$(nsem)" 0

# --- P4 route C,A: one letter call; no-route ends with an alert and no claude-cli call --------------------------
new_fx p4
cfg '"primary":"C","fallbacks":["A"]' c1
queue submitted
run_pass
check "P4 one semantic call" "$(nsem)" 1
has "P4 the letter call" "$(cat "$FX/sem.log")" "--backend claude-api"
has "P4 the corpus class" "$(cat "$FX/sem.log")" "--corpus-class adopter-repo"
has "P4 the order" "$(cat "$FX/sem.log")" "--account-order C,A"
has "P4 the cap from the store" "$(cat "$FX/sem.log")" "--max-run-usd 5"
new_fx p4b
cfg '"primary":"C","fallbacks":["A"]' c1
queue no-route
run_pass
check "P4 no-route: no claude-cli call" "$(ncli)" 0
has "P4 no-route: the word and a reason" "$OUT" "c1 no-route"
has "P4 no-route: an alert is sent" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"

# --- P5 route A,subscription: no-route then one claude-cli call, scrubbed ---------------------------------------
new_fx p5
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass "${PLANTED[@]}" CLAUDE_CODE_OAUTH_TOKEN=planted
check "P5 two calls" "$(nsem)" 2
check "P5 one claude-cli call" "$(ncli)" 1
envs="$(cat "$FX/sem-env.2" 2>/dev/null)"
has "P5 the oauth token reaches the stub" "$envs" "CLAUDE_CODE_OAUTH_TOKEN"
for v in ANTHROPIC_ORG_D_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK anthropic_api_key; do
  lacks "P5 $v does not reach the stub" "$envs" "$v"
done
# a planted name that survives the scrub (read-only, so unset cannot remove it)
new_fx p5ro
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass BASH_ENV="$FX/plant.sh"
check "P5 survivor: zero claude-cli calls" "$(ncli)" 0
has "P5 survivor: the word stopped" "$OUT" "c1 stopped"
# a stubbed native_auth_pin_env that returns 1
new_fx p5pin
mk_tree "$FX/tree" pin1
ln -sf "$PASS_REAL" "$FX/tree/scripts/graphify/graph-choices-pass.sh"
PASS_BIN="$FX/tree/scripts/graphify/graph-choices-pass.sh"
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass
check "P5 pin returns 1: zero claude-cli calls" "$(ncli)" 0
has "P5 pin returns 1: the word stopped" "$OUT" "c1 stopped"
# shadow sub-row (P5-1, P6-1): exit, return and unset shadowed where the gate runs
new_fx p5sh
mk_tree "$FX/tree" shadow
ln -sf "$PASS_REAL" "$FX/tree/scripts/graphify/graph-choices-pass.sh"
PASS_BIN="$FX/tree/scripts/graphify/graph-choices-pass.sh"
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass ANTHROPIC_AUTH_TOKEN=planted
check "P5-1 shadowed: zero claude-cli calls" "$(ncli)" 0
has "P5-1 shadowed: the word stopped" "$OUT" "c1 stopped"
has "P5-1 shadowed: the pass's refusal line" "$OUT" "graph-choices-pass: subscription step refused: an API credential name survived the scrub"
# positive control: the same tree with nothing planted launches once
new_fx p5pos
mk_tree "$FX/tree" shadow
ln -sf "$PASS_REAL" "$FX/tree/scripts/graphify/graph-choices-pass.sh"
PASS_BIN="$FX/tree/scripts/graphify/graph-choices-pass.sh"
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass
check "P5-1 control: one claude-cli call with nothing planted" "$(ncli)" 1
# RED control: a copy of the pass with the refuse-then-launch gate records a call under the same shadows
new_fx p5red
mk_tree "$FX/tree" shadow
rm -f "$FX/tree/scripts/graphify/graph-choices-pass.sh"
cat >"$TD/redctl.py" <<'EOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
out, hit = [], 0
for line in open(src).read().split("\n"):
    m = re.match(r'^(\s*)if (\[\[ -z "\$\{!ANTHROPIC_\*\}[^"]*" \]\]); then$', line)
    if m:
        ind, test = m.group(1), m.group(2)
        out.append(ind + test + ' || { echo "graph-choices-pass: subscription step refused: an API credential name survived the scrub"; printf \'stopped\\n\' >"$rf"; exit 0; }')
        out.append(ind + "if true; then")
        hit += 1
    else:
        out.append(line)
open(dst, "w").write("\n".join(out))
sys.exit(0 if hit == 1 else 3)
EOF
python3 -I "$TD/redctl.py" "$PASS_REAL" "$FX/tree/scripts/graphify/graph-choices-pass.sh"
check "P5-1 RED control: the pass has one gate to rewrite" "$?" 0
PASS_BIN="$FX/tree/scripts/graphify/graph-choices-pass.sh"
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route extracted
run_pass ANTHROPIC_AUTH_TOKEN=planted
[ "$(ncli)" -ge 1 ] && ok "P5-1 RED control: the refuse-then-launch copy launches under the shadows" || bad "P5-1 RED control" "no claude-cli call recorded"

# --- P6 route subscription,C: bank-refused then one letter call -------------------------------------------------
new_fx p6
cfg '"primary":"subscription","fallbacks":["C"]' c1
queue bank-refused submitted
run_pass
check "P6 two calls" "$(nsem)" 2
check "P6 one claude-cli then one letter" "$(ncli):$(napi)" "1:1"
new_fx p6b
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue no-route bank-refused
run_pass
check "P6 A,subscription: one call each" "$(napi):$(ncli)" "1:1"
has "P6 the reason is stated" "$OUT" "bank-refused"

# --- P7 batch-pending moves to the letter step -----------------------------------------------------------------
new_fx p7
cfg '"primary":"subscription","fallbacks":["C"]' c1
queue batch-pending pending
run_pass
check "P7 claude-cli then letter" "$(ncli):$(napi)" "1:1"
new_fx p7b
cfg '"primary":"subscription"' c1 c2
mkdir -p "$(out_dir c1)/semantic-batch"
: >"$(out_dir c1)/semantic-batch/batch.json"
queue batch-pending no-op
run_pass
check "P7 no letter left: the next corpus runs" "$(ncli)" 2
has "P7 the waiting path is printed" "$OUT" "$(out_dir c1)/semantic-batch"

# --- P8 two corpora ---------------------------------------------------------------------------------------------
new_fx p8s
cfg '"primary":"C"' c1 c2
queue submitted
run_pass
check "P8 submitted ends the fire" "$(nsem)" 1
for w in no-op pending merged; do
  new_fx p8$w
  cfg '"primary":"C"' c1 c2
  queue "$w" "$w"
  run_pass
  check "P8 $w lets the second go" "$(nsem)" 2
done
new_fx p8e
cfg '"primary":"subscription"' c1 c2
queue extracted
run_pass
check "P8 extracted ends the fire" "$(nsem)" 1

# --- P9 no result file or an unknown word ends the fire with an alert ------------------------------------------
for w in NORESULT banana; do
  new_fx p9$w
  cfg '"primary":"C"' c1 c2
  queue "$w"
  run_pass
  check "P9 $w ends the fire" "$(nsem)" 1
  has "P9 $w alerts" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"
done

# --- P10 fence-denied, over-cap, corpus-failed go on with an alert; locked goes on with none ------------------------
for w in fence-denied over-cap corpus-failed; do
  new_fx p10$w
  cfg '"primary":"C"' c1 c2
  queue "$w" no-op
  run_pass
  check "P10 $w lets the next corpus go" "$(nsem)" 2
  has "P10 $w alerts" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"
  has "P10 $w leaves a log line for C88" "$OUT" "c1 ALERT $w"
done
new_fx p10l
cfg '"primary":"C"' c1 c2
queue locked no-op
run_pass
check "P10 locked lets the next corpus go" "$(nsem)" 2
check "P10 locked sends no alert" "$(nsent)" 0

# --- P11 invalid store -----------------------------------------------------------------------------------------
new_fx p11
cfg '"primary":"banana"' c1
run_pass
check "P11 rc" "$RC" 0
has "P11 the sentence" "$OUT" "is not valid"
has "P11 a doctor-visible line" "$OUT" "invalid:"
check "P11 no calls" "$(nast):$(nsem)" "0:0"

# --- P12 a root that classifies at fire time is skipped ---------------------------------------------------------
new_fx p12
mkrepo c2
printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"c1","root":"%s"},{"name":"c2","root":"%s"}],"primary":"C","max_usd_per_pass":5}}}\n' "$REPO" "$FX/repos/c2" >"$H/.himmel/config.json"
run_pass
has "P12 the refused root is skipped with a line" "$OUT" "c1 skipped"
check "P12 only the second corpus ran" "$(nsem)" 1
lacks "P12 no ast call for the skipped root" "$(cat "$FX/ast.log" 2>/dev/null)" "ast $REPO "

# --- P13 real ast-update and real graphify leave the repo clean --------------------------------------------------
if command -v graphify >/dev/null 2>&1; then
  new_fx p13
  mkdir -p "$FX/repos/c1"
  git -C "$FX/repos/c1" init -q
  printf 'def hello():\n    return 1\n' >"$FX/repos/c1/a.py"
  git -C "$FX/repos/c1" add a.py
  git -C "$FX/repos/c1" -c user.email=t@example.invalid -c user.name=t commit -q -m seed
  printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"c1","root":"%s"}],"primary":"none"}}}\n' "$FX/repos/c1" >"$H/.himmel/config.json"
  run_pass GRAPH_CHOICES_AST_UPDATE="$REPO/scripts/graphify/ast-update.sh"
  check "P13 git status is empty after the real ast pass" "$(git -C "$FX/repos/c1" status --porcelain)" ""
else
  echo "SKIP - P13 graphify is not installed here; S7 step 4 is the proof"
fi

# --- P14 a deleted repo is skipped; a failed AST pass skips the semantic step ------------------------------------------
new_fx p14
cfg '"primary":"C"' c1 c2
rm -rf "$FX/repos/c1"
run_pass
has "P14 the deleted repo is skipped with a line" "$OUT" "c1 skipped"
check "P14 the second corpus still ran" "$(nsem)" 1
new_fx p14b
cfg '"primary":"C"' c1 c2
printf '1\n' >"$FX/ast-rc.c1"
run_pass
check "P14 a failed AST pass skips that corpus's semantic step" "$(nsem)" 1
has "P14 the failed AST pass alerts" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"

# --- P15 partial -----------------------------------------------------------------------------------------------
new_fx p15
cfg '"primary":"C"' c1 c2
queue partial no-op
run_pass
check "P15 partial from a letter step lets the next corpus go" "$(nsem)" 2
has "P15 an alert line" "$OUT" "c1 ALERT partial"
new_fx p15b
cfg '"primary":"subscription"' c1 c2
queue partial
run_pass
check "P15 partial from a subscription step ends the fire" "$(nsem)" 1
has "P15 an alert line" "$OUT" "c1 ALERT partial"

# --- P16 a batch directory whose corpus left the store ---------------------------------------------------------------
new_fx p16
cfg '"primary":"none"' c1
mkdir -p "$(dirname "$(dirname "$(out_dir c1)")")/gone/graphify-out/semantic-batch"
: >"$(dirname "$(dirname "$(out_dir c1)")")/gone/graphify-out/semantic-batch/batch.json"
run_pass
has "P16 the orphan batch path is printed" "$OUT" "/choices/gone/graphify-out/semantic-batch"

# --- P17 a daily over-cap alerts once; a clean word clears it; no sender still reaches C88 ----------------------------
new_fx p17
cfg '"primary":"C"' c1
queue over-cap over-cap
run_pass
run_pass
check "P17 two fires send one message" "$(nsent)" 1
queue no-op
run_pass
check "P17 a clean word clears the sentinel" "$(nsentinel graph-choices-c1)" 0
new_fx p17b
cfg '"primary":"C"' c1
queue over-cap
rm -f "$FX/send.sh"
run_pass
mkdir -p "$H/.claude/graph-choices-cadence"
printf '%s\n' "$OUT" >"$H/.claude/graph-choices-cadence/graph-choices.log"
has "P17 no sender: the line still reaches C88" "$(run_check)" "alert: c1 over-cap"

# --- P18 ast-update exit 4 skips the corpus with no alert -------------------------------------------------------------
new_fx p18
cfg '"primary":"C"' c1
printf '4\n' >"$FX/ast-rc.c1"
run_pass
check "P18 no semantic call" "$(nsem)" 0
check "P18 no alert" "$(nsent)" 0

# --- P19 three bank-refused fires show as three in check -------------------------------------------------------------
new_fx p19
cfg '"primary":"subscription"' c1
mkdir -p "$H/.claude/graph-choices-cadence"
for _ in 1 2 3; do
  queue bank-refused
  run_pass
  printf '%s\n' "$OUT" >>"$H/.claude/graph-choices-cadence/graph-choices.log"
done
has "P19 check counts three in a row" "$(run_check)" "bank-refused in a row: 3"

# --- P20 stopped, or no result file, from the first step: no claude-cli call -----------------------------------------
for w in stopped NORESULT; do
  new_fx p20$w
  cfg '"primary":"A","fallbacks":["subscription"]' c1
  queue "$w"
  run_pass
  check "P20 $w: zero claude-cli calls" "$(ncli)" 0
  has "P20 $w: the fire ends with an alert" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"
done

# --- P21 a symlinked and a non-JSON config spend nothing ------------------------------------------------------------
new_fx p21
mkrepo c1
printf '{"graphify":{"choices":{"version":1,"corpora":[{"name":"c1","root":"%s"}],"primary":"subscription"}}}\n' "$FX/repos/c1" >"$FX/real.json"
rm -f "$H/.himmel/config.json"
ln -s "$FX/real.json" "$H/.himmel/config.json"
run_pass
check "P21 symlink: no semantic call, no claude call" "$(nsem):$(cnt claude "$FX/claude.log")" "0:0"
has "P21 symlink: the reason is printed" "$OUT" "cause=symlink"
new_fx p21b
printf 'not json {\n' >"$H/.himmel/config.json"
run_pass
check "P21 non-JSON: no semantic call, no claude call" "$(nsem):$(cnt claude "$FX/claude.log")" "0:0"
has "P21 non-JSON: the reason is printed" "$OUT" "cause=not-json"

# --- P22 --account-order C,A in one call; A alone with no-route ends with an alert ------------------------------------
new_fx p22
cfg '"primary":"C","fallbacks":["A"]' c1
queue no-op
run_pass
check "P22 one call, one order" "$(grep -c -- '--account-order C,A' "$FX/sem.log"):$(nsem)" "1:1"
new_fx p22b
cfg '"primary":"A"' c1
queue no-route
run_pass
check "P22 A alone: zero claude-cli calls" "$(ncli)" 0
has "P22 A alone: the fire ends with an alert" "$(cat "$FX/sent.log" 2>/dev/null)" "graph-choices-c1"

# --- P23 an unreadable config alerts with a fixed line and never forwards bytes -----------------------------------------
new_fx p23
printf 'sk-ant-api03-planted not json\n' >"$H/.himmel/config.json"
run_pass
run_pass
sent="$(cat "$FX/sent.log" 2>/dev/null)"
check "P23 one message for two unreadable fires" "$(nsent)" 1
has "P23 the message names the cause" "$sent" "graph-config-unreadable"
has "P23 the cause word" "$sent" "not-json"
lacks "P23 no key-shaped bytes in the message" "$sent" "sk-ant"
lacks "P23 no key-shaped bytes in the output" "$OUT" "sk-ant"
lacks "P23 no key-shaped bytes in the alert log" "$(cat "$FX/alerts.log" 2>/dev/null)" "sk-ant"
printf '{}\n' >"$H/.himmel/config.json"
run_pass
check "P23 a readable fire clears the sentinel" "$(nsentinel graph-config-unreadable)" 0
new_fx p23m
rm -f "$H/.himmel/config.json"
printf '#!/usr/bin/env bash\nHIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto\n' >"$FX/bat/graphmap-publish-himmel.sh"
run_pass
has "P23 missing with a footprint: one message naming missing" "$(cat "$FX/sent.log" 2>/dev/null)" "missing"
check "P23 missing: exactly one message" "$(nsent)" 1

# --- P24 a rejected key on a submitted fire ---------------------------------------------------------------------------
new_fx p24
cfg '"primary":"A","fallbacks":["C"]' c1
queue 'submitted|rejected A'
run_pass
check "P24 the fire ends" "$(nsem)" 1
has "P24 the pass log carries the alert line" "$OUT" "ALERT key-rejected A"
mkdir -p "$H/.claude/graph-choices-cadence"
printf '%s\n' "$OUT" >"$H/.claude/graph-choices-cadence/graph-choices.log"
has "P24 check shows it" "$(run_check)" "alert: c1 key-rejected A"

# --- P25 key-rejected never reaches the subscription ------------------------------------------------------------------
new_fx p25
cfg '"primary":"A","fallbacks":["subscription","C"]' c1
queue 'key-rejected|rejected A' no-op
run_pass
check "P25 no claude-cli call, one letter call after" "$(ncli)" 0
check "P25 two letter calls in all" "$(napi)" 2
has "P25 the second call is the order C" "$(cat "$FX/sem.log")" "--account-order C "
new_fx p25b
cfg '"primary":"A","fallbacks":["subscription"]' c1
queue 'key-rejected|rejected A'
run_pass
check "P25 A,subscription: no claude-cli call" "$(ncli)" 0
has "P25 A,subscription: the fire ends with an alert" "$OUT" "ALERT key-rejected A"
new_fx p25m
cfg '"primary":"A","fallbacks":["B","subscription"]' c1
queue 'key-rejected|rejected A'
run_pass
check "P25 mixed: no claude-cli call" "$(ncli)" 0
has "P25 mixed: the log names A as rejected" "$OUT" "ALERT key-rejected A"
printf '%s\n' "$OUT" >"$H/.claude/graph-choices-cadence/graph-choices.log" 2>/dev/null || { mkdir -p "$H/.claude/graph-choices-cadence"; printf '%s\n' "$OUT" >"$H/.claude/graph-choices-cadence/graph-choices.log"; }
has "P25 mixed: check names A as rejected" "$(run_check)" "key-rejected A"

# --- K rows: graph-choices-cadence.sh arm, status and disarm over a fake crontab ------------------------------------------
CADENCE="$here/graph-choices-cadence.sh"
new_fx k
mkdir -p "$FX/tools" "$FX/prov"
printf '#!/bin/sh\nexit 0\n' >"$FX/tools/graphify"
cat >"$FX/tools/crontab" <<'EOF'
#!/bin/sh
case "$1" in
  -l) if [ -f "$CRON_FILE" ]; then cat "$CRON_FILE"; else echo "no crontab for tester" >&2; exit 1; fi ;;
  -) cat >"$CRON_FILE" ;;
esac
EOF
chmod +x "$FX/tools/graphify" "$FX/tools/crontab"
cad() { # cad <args...> -> OUT, RC; a throwaway HOME, the fake crontab, a stub graphify on PATH
  OUT="$(env -i PATH="$FX/tools:$BASE_PATH" HOME="$H" HIMMEL_PROVENANCE_DIR="$FX/prov" CRON_FILE="$FX/cron.txt" \
    GRAPH_CHOICES_CRONTAB="$FX/tools/crontab" GRAPH_CHOICES_BAT_DIR="$FX/bat-gc" bash "$CADENCE" "$@" 2>&1)"
  RC=$?
}
cad arm --dry-run
check "K1 arm --dry-run rc" "$RC" 0
has "K1 arm --dry-run prints the row" "$OUT" "40 4 * * * "
has "K1 the row carries the marker" "$OUT" "# HIMMEL-GraphChoices"
check "K1 arm --dry-run writes no crontab and no runner" "$([ -e "$FX/cron.txt" ] || [ -e "$FX/bat-gc" ] && echo wrote || echo clean)" clean
cad arm
check "K2 arm rc" "$RC" 0
check "K2 one cron row at 04:40 with the marker" "$(grep -c '^40 4 \* \* \* .* # HIMMEL-GraphChoices$' "$FX/cron.txt")" 1
runner="$(cat "$FX/bat-gc/graph-choices.sh" 2>/dev/null)"
has "K2 the runner stamps the format" "$runner" "himmel-cadence-runner-format:"
has "K2 the runner pins the graphify directory" "$runner" "export PATH=$FX/tools:"
has "K2 the runner carries the oauth token lines" "$runner" "CLAUDE_CODE_OAUTH_TOKEN"
has "K2 the runner fires the pass" "$runner" "graph-choices-pass.sh"
lacks "K2 the runner passes an empty flow" "$runner" "flow-run-ledger"
check "K2 the runner is executable" "$([ -x "$FX/bat-gc/graph-choices.sh" ] && echo yes || echo no)" yes
cad status
has "K3 status says ARMED" "$OUT" "ARMED      HIMMEL-GraphChoices"
cad arm
has "K4 a second arm without --force changes nothing" "$OUT" "already armed"
check "K4 still one row" "$(grep -c 'HIMMEL-GraphChoices' "$FX/cron.txt")" 1
cad arm --force --time 05:15
check "K4 --force re-renders the row at the new time" "$(grep -c '^15 5 \* \* \* .* # HIMMEL-GraphChoices$' "$FX/cron.txt")" 1
check "K4 and leaves exactly one row" "$(grep -c 'HIMMEL-GraphChoices' "$FX/cron.txt")" 1
printf '[fired 2026-11-06 04:40:00]\n[exit rc=0]\n' >"$FX/bat-gc/graph-choices.log"
cad disarm
check "K5 disarm removes the row" "$(grep -c 'HIMMEL-GraphChoices' "$FX/cron.txt")" 0
check "K5 disarm removes the runner but keeps the log" "$([ -e "$FX/bat-gc/graph-choices.sh" ] && echo runner || echo none):$([ -e "$FX/bat-gc/graph-choices.log" ] && echo log || echo nolog)" none:log
cad status
has "K5 status says not armed" "$OUT" "not armed  HIMMEL-GraphChoices"
cad arm --time 25:99
check "K6 a bad time is refused" "$RC" 1

echo
[ "$fails" -eq 0 ] && echo "all rows passed" || echo "$fails row(s) failed"
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
