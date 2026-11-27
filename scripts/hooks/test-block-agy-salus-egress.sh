#!/usr/bin/env bash
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
HOOK="$HOOKS/block-agy-salus-egress.sh"
ADAPTER="$HOOKS/antigravity-hook-adapter.sh"
CLASSIFIER="$REPO/scripts/handover/chief-kit/salus_marked.py"
VAULT_HOOK="$REPO/templates/luna-second-brain/_profiles/salus/.claude/hooks/block-cloud-egress.sh"
MATRIX="$REPO/scripts/guardrails/egress-matrix.json"
MATRIX_EVAL="$REPO/scripts/guardrails/egress-matrix-eval.mjs"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
unset CLAUDE_GLM_CONFIG_DIR

# shellcheck source=lib-fixture-root.sh
# shellcheck disable=SC1091
. "$HOOKS/lib-fixture-root.sh"
_FROOT="$(fixture_root)" || exit 1
# prim-ok: the fixture must sit outside every temp path or the main-checkout fence exempts it
TMP="$(mktemp -d "$_FROOT/.himmel-agy-salus-egress-XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

export HOME="$TMP/home"
export T3CODE_HOME="$TMP/t3home"
export RUN_HOOK_CHAIN_RUN_LOG="$TMP/hook-runs.jsonl"
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/hook-skips.jsonl"
export HIMMEL_HOOK_INTEGRITY_DIR="$TMP/integrity"
export HIMMEL_PRIMARY_BASELINE_DIR="$TMP/baseline"
export HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO"
mkdir -p "$HOME/.himmel" "$HOME/.gemini/config" "$T3CODE_HOME/userdata/providers/antigravity" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED","reviewDecision":""}\n' ;;
  *"pr list"*) printf '1\n' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FORGE=github
export GH_CMD="$TMP/bin/gh"

mk_vault() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    touch "$1/.single-writer"
    printf 'ok\n' > "$1/note.md"
}
SALUS_VAULT="$TMP/salus-vault"; mk_vault "$SALUS_VAULT"; touch "$SALUS_VAULT/.salus"
PLAIN_DIR="$TMP/plain"; mk_vault "$PLAIN_DIR"

hook_payload() {
    jq -cn --arg t "$1" --arg c "$2" --arg cwd "$3" --argjson ws "${4:-[]}" \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c},cwd:$cwd,workspace_paths:$ws}'
}
run_hook() {
    local hook="$1" json="$2"
    shift 2
    printf '%s' "$json" | env "$@" bash "$hook" >/dev/null 2>"$TMP/hook.err"
}
expect_rc() {
    local label="$1" want="$2" hook="$3" json="$4"
    shift 4
    local rc
    run_hook "$hook" "$json" "$@"; rc=$?
    if [ "$rc" -ne "$want" ]; then
        bad "$label (rc=$rc want $want, stderr=<$(cat "$TMP/hook.err")>)"
    elif [ "$want" -eq 2 ] && ! grep -qF 'block-agy-salus-egress' "$TMP/hook.err"; then
        bad "$label (refused without the hook's reason: $(cat "$TMP/hook.err"))"
    else
        ok "$label"
    fi
}

make_pre() {
    local tool="$1" args_json="$2" cwd="$3" ws="${4:-}"
    if [ -n "$ws" ]; then
        jq -cn --arg t "$tool" --argjson a "$args_json" --arg cwd "$cwd" --argjson ws "$ws" \
            '{hookEventName:"PreToolUse",conversationId:"conv-1",cwd:$cwd,workspacePaths:$ws,toolCall:{id:"call_1",name:$t,args:$a}}'
    else
        jq -cn --arg t "$tool" --argjson a "$args_json" --arg cwd "$cwd" \
            '{hookEventName:"PreToolUse",conversationId:"conv-1",cwd:$cwd,toolCall:{id:"call_1",name:$t,args:$a}}'
    fi
}
adapter_reason() {
    local json="$1"
    shift
    printf '%s' "$json" | env "$@" bash "$ADAPTER" 2>/dev/null | jq -r 'select(.decision == "deny") | .reason // empty' 2>/dev/null
}
adapter_deny() {
    local label="$1" needle="$2" json="$3" reason
    shift 3
    reason="$(adapter_reason "$json" "$@")"
    if [ -n "$reason" ] && grep -qF -- "$needle" <<<"$reason"; then ok "$label"; else bad "$label (reason=<$reason>, want '$needle')"; fi
}

echo "== U1 pattern parity with the vault floor (I4) =="
FORM='^[[:space:]]*\*"[^"]*"\*(\|\*"[^"]*"\*)*\)'
u1_patterns() {
    local f="$1" lines n
    lines="$(grep -E -- "$FORM" "$f")"
    n="$(grep -cE -- "$FORM" "$f")"
    [ "$n" = 1 ] || return 1
    grep -oE -- "$FORM" <<<"$lines" | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//'
}
u1_check() {
    local a b
    a="$(u1_patterns "$1")" || return 1
    b="$(u1_patterns "$2")" || return 1
    [ -n "$a" ] && [ "$a" = "$b" ]
}
if u1_check "$VAULT_HOOK" "$HOOK"; then ok "U1 the two pattern lists are equal, in order"; else bad "U1 pattern lists differ or a pattern line is malformed"; fi
n_pat="$(u1_patterns "$VAULT_HOOK" | grep -c .)"
if [ "$n_pat" = 10 ]; then ok "U1 the vault floor holds ten patterns"; else bad "U1 the vault floor holds $n_pat patterns"; fi

cp "$HOOK" "$TMP/mut-del.sh"
sed -i.bak 's/\*"scp "\*|//' "$TMP/mut-del.sh"
if u1_check "$VAULT_HOOK" "$TMP/mut-del.sh"; then bad "U1 mutation: a deleted pattern passed the check"; else ok "U1 mutation: a deleted pattern fails the check"; fi
cp "$HOOK" "$TMP/mut-swap.sh"
sed -i.bak 's/\*"scp "\*|\*"rclone "\*)/*"rclone "*|*"scp "*)/' "$TMP/mut-swap.sh"
if grep -qF '*"rclone "*|*"scp "*)' "$TMP/mut-swap.sh" && ! u1_check "$VAULT_HOOK" "$TMP/mut-swap.sh"; then
    ok "U1 mutation: two swapped patterns fail the ordered check"
else
    bad "U1 mutation: two swapped patterns passed the ordered check"
fi
cp "$HOOK" "$TMP/mut-twice.sh"
grep -E -- "$FORM" "$HOOK" >> "$TMP/mut-twice.sh"
if u1_check "$VAULT_HOOK" "$TMP/mut-twice.sh"; then bad "U1 mutation: two pattern lines passed"; else ok "U1 mutation: two pattern lines fail the check"; fi
sed 's/\*"git push"\*|/*"git push"* |/' "$HOOK" > "$TMP/mut-shape.sh"
if u1_check "$VAULT_HOOK" "$TMP/mut-shape.sh"; then bad "U1 mutation: a pattern line off the form passed"; else ok "U1 mutation: a pattern line off the form fails the check"; fi

vault_payload() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    cmd="${pat}x"
    expect_rc "U1 positive '$cmd': the agy hook refuses in a salus cwd" 2 "$HOOK" "$(hook_payload Bash "$cmd" "$SALUS_VAULT")"
    printf '%s' "$(vault_payload "$cmd")" | (cd "$SALUS_VAULT" && bash "$VAULT_HOOK") >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 2 ]; then ok "U1 positive '$cmd': the vault floor refuses"; else bad "U1 positive '$cmd': the vault floor gave rc=$rc"; fi
done <<EOF
$(u1_patterns "$VAULT_HOOK")
EOF
for cmd in "curly x" "scpx y" "git remotes"; do
    expect_rc "U1 near miss '$cmd': the agy hook allows in a salus cwd" 0 "$HOOK" "$(hook_payload Bash "$cmd" "$SALUS_VAULT")"
    printf '%s' "$(vault_payload "$cmd")" | (cd "$SALUS_VAULT" && bash "$VAULT_HOOK") >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then ok "U1 near miss '$cmd': the vault floor allows"; else bad "U1 near miss '$cmd': the vault floor gave rc=$rc"; fi
done

echo "== U2b the egress matrix still rules salus x google-antigravity (I11) =="
u2b_check() {
    node --input-type=module -e '
        import { readFileSync } from "node:fs";
        import { evaluate } from "'"$MATRIX_EVAL"'";
        const m = JSON.parse(readFileSync(process.argv[1], "utf8"));
        const first = (u) => m.rules.find((r) => (r.corpus === "*" || r.corpus === "salus")
            && (r.provider === "*" || r.provider === "google-antigravity") && (r.purpose === "*" || r.purpose === u));
        const errs = [];
        if (evaluate(m, "salus", "google-antigravity", "inference").verdict !== "allow") errs.push("inference is not allow");
        for (const u of m.purposes) {
            if (u === "inference") continue;
            if (evaluate(m, "salus", "google-antigravity", u).verdict !== "deny") errs.push(u + " is not deny");
            if (!first(u) || first(u).hard !== true) errs.push(u + " first match is not hard");
        }
        if (errs.length) { console.log(errs.join("; ")); process.exit(1); }
    ' "$1"
}
if out="$(u2b_check "$MATRIX")"; then ok "U2b inference allow, every other purpose a hard deny"; else bad "U2b $out"; fi
if grep -q '^allow' <<<"$(node "$MATRIX_EVAL" salus google-antigravity inference)"; then ok "U2b the CLI prints allow for inference"; else bad "U2b the CLI does not print allow for inference"; fi
jq '.rules = [{corpus:"salus",provider:"google-antigravity",purpose:"*",verdict:"allow"}] + .rules' "$MATRIX" > "$TMP/matrix-open.json"
if u2b_check "$TMP/matrix-open.json" >/dev/null; then bad "U2b mutation: an allow row before the wildcard passed"; else ok "U2b mutation: an allow row before the wildcard fails the check"; fi
jq '.rules |= map(if .corpus == "salus" and .provider == "*" and .purpose == "*" then del(.hard) else . end)' "$MATRIX" > "$TMP/matrix-soft.json"
if u2b_check "$TMP/matrix-soft.json" >/dev/null; then bad "U2b mutation: a soft wildcard passed"; else ok "U2b mutation: a soft wildcard fails the check"; fi

echo "== U3 to U5, U7: the hook fails closed (I7, I8) =="
mkdir -p "$TMP/lone/scripts/hooks"
cp "$HOOK" "$TMP/lone/scripts/hooks/"
expect_rc "U3 no classifier beside the hook: search_web in a plain dir refused" 2 "$TMP/lone/scripts/hooks/block-agy-salus-egress.sh" "$(hook_payload search_web '' "$PLAIN_DIR")"
expect_rc "U3 no classifier beside the hook: Bash ls allowed" 0 "$TMP/lone/scripts/hooks/block-agy-salus-egress.sh" "$(hook_payload Bash ls "$PLAIN_DIR")"

SHIM="$TMP/shim"
mkdir -p "$SHIM"
REAL_BASH="$(command -v bash)"; REAL_JQ="$(command -v jq)"
ln -s "$REAL_BASH" "$SHIM/bash"
printf '#!%s\nprintf "x\\n" >> %q\nexec %q "$@"\n' "$REAL_BASH" "$TMP/jq.log" "$REAL_JQ" > "$SHIM/jq"
printf '#!%s\nprintf "x\\n" >> %q\nexit 1\n' "$REAL_BASH" "$TMP/py.log" > "$SHIM/python3"
chmod +x "$SHIM/jq" "$SHIM/python3"
printf '%s' "$(hook_payload Bash ls "$PLAIN_DIR")" | env PATH="$SHIM" "$SHIM/bash" "$HOOK" >/dev/null 2>&1; rc=$?
jq_n="$(grep -c . "$TMP/jq.log" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$jq_n" = 1 ] && [ ! -e "$TMP/py.log" ]; then
    ok "U4 Bash ls: one jq read, no python3"
else
    bad "U4 Bash ls (rc=$rc jq calls=$jq_n python3 log present=$([ -e "$TMP/py.log" ] && echo yes || echo no))"
fi
printf '%s' "$(hook_payload search_web '' "$PLAIN_DIR")" | env PATH="$SHIM" "$SHIM/bash" "$HOOK" >/dev/null 2>&1; rc=$?
py_n="$(grep -c . "$TMP/py.log" 2>/dev/null)"
if [ "$rc" -eq 2 ] && [ "$py_n" = 1 ]; then ok "U4 search_web with a crashing python3: refused after one classifier call"; else bad "U4 search_web (rc=$rc python3 calls=$py_n)"; fi

ws_dirs() {
    local n="$1" i out="["
    for i in $(seq 1 "$n"); do
        mkdir -p "$TMP/ws/$i"
        [ "$i" -gt 1 ] && out="$out,"
        out="$out\"$TMP/ws/$i\""
    done
    printf '%s]' "$out"
}
expect_rc "U5 8 workspace paths, none salus: allowed" 0 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" "$(ws_dirs 8)")"
expect_rc "U5 9 workspace paths refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" "$(ws_dirs 9)")"
expect_rc "U5 a numeric workspace entry refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" '[7]')"
expect_rc "U5 workspace_paths as a string refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" '"/tmp"')"
expect_rc "U5 workspace_paths as an object refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" '{}')"
expect_rc "U5 an empty workspace entry refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" '[""]')"
expect_rc "U5 a relative workspace entry refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" '["rel/dir"]')"
expect_rc "U5 a relative cwd refused" 2 "$HOOK" "$(hook_payload search_web '' "rel/dir")"
expect_rc "U5 an empty cwd refused" 2 "$HOOK" "$(hook_payload search_web '' "")"
expect_rc "U5 no cwd key refused" 2 "$HOOK" '{"tool_name":"search_web","tool_input":{}}'
expect_rc "U5 control: a plain cwd with no workspace_paths key allowed" 0 "$HOOK" "$(jq -cn --arg c "$PLAIN_DIR" '{tool_name:"search_web",tool_input:{},cwd:$c}')"
expect_rc "U5 the salus vault listed second refused" 2 "$HOOK" "$(hook_payload search_web '' "$PLAIN_DIR" "[\"$PLAIN_DIR\",\"$SALUS_VAULT\"]")"
expect_rc "malformed JSON refused" 2 "$HOOK" '{not json'

sed -n '1,/^trap /p' "$HOOK" > "$TMP/exit3.sh"
printf 'exit 3\n' >> "$TMP/exit3.sh"
printf '{}' | bash "$TMP/exit3.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "U7 a body exiting 3 under the EXIT trap reports 2"; else bad "U7 a body exiting 3 reported $rc"; fi

echo "== U2a the adapter's arm table (I5) =="
u2a_check() {
    python3 -I - "$1" <<'PY'
import re
import sys

HOOK = 'block-agy-salus-egress.sh'
TABLE = {
    'schedule': 'refused-always', 'swarm|run_workflow': 'refused-always',
    'define_subagent|manage_subagents': 'refused-always', 'manage_task': 'refused-always',
    'run_command': 'floor', 'search_web|send_message|ask_question': 'floor',
    'list_resources|read_resource': 'floor', 'mcp_*': 'floor', 'call_mcp_tool': 'floor',
    'read_file': 'local', 'edit_file': 'local', 'write_file': 'local', 'exit_plan_mode|update_steps': 'local',
    'invoke_subagent': 'inherits-cwd',
    '*': 'default-deny',
}
src = open(sys.argv[1], encoding='utf-8').read().split('\n')
errs = []
SH = re.compile(r'[A-Za-z0-9_.-]+\.sh\b')
NAME = r'[A-Za-z0-9_.-]+\.sh'


def fn_body(name):
    starts = [i for i, l in enumerate(src) if l == name + '() {']
    if len(starts) != 1:
        errs.append('%s() is not defined exactly once' % name)
        return []
    end = next((i for i in range(starts[0], len(src)) if src[i] == '}'), None)
    return src[starts[0] + 1:end]


mcp_base, mcp_tail = None, []
for line in fn_body('run_mcp_gate'):
    m = re.match(r'^\s*local -a chain=\(((?:%s ?)+)\)\s*$' % NAME, line)
    if m:
        if mcp_base is not None:
            errs.append('run_mcp_gate sets its chain array twice')
        mcp_base = m.group(1).split()
        continue
    if re.match(r'^\s*(\[ .* \] (\|\||&&) )?chain\+=\((%s ?)+\)\s*$' % NAME, line):
        continue
    if 'run_chain_with_payload' in line:
        m = re.match(r'^\s*run_chain_with_payload gate "\$payload" "\$\{chain\[@\]\}"((?: %s)*)\s*$' % NAME, line)
        if not m:
            errs.append('run_mcp_gate: chain call outside the grammar: ' + line.strip())
        else:
            mcp_tail = m.group(1).split()
        continue
    if SH.search(line):
        errs.append('run_mcp_gate: a .sh token outside a chain: ' + line.strip())
if mcp_base is None:
    errs.append('run_mcp_gate has no local -a chain=(...) line')
    mcp_base = []
MCP_CHAIN = mcp_base + mcp_tail

start = [i for i, l in enumerate(src) if l == 'case "$RAW_TOOL" in']
if len(start) != 1:
    print('the tool case block is not found exactly once')
    sys.exit(1)
arms, cur, depth, i, pending = {}, None, 1, start[0] + 1, False
while i < len(src):
    line = src[i]
    s = line.strip()
    if pending:
        m = re.match(r'^\s*(%s)( \\)?$' % NAME, line)
        if not m:
            errs.append('%s: chain continuation outside the grammar: %s' % (cur, s))
            pending = False
        else:
            arms[cur]['chains'][-1].append(m.group(1))
            pending = m.group(2) is not None
        i += 1
        continue
    if re.match(r'^case .* in$', s):
        depth += 1
    elif s == 'esac':
        depth -= 1
        if depth == 0:
            break
    elif depth == 1 and re.match(r'^\s*[A-Za-z0-9_*|-]+\)', line):
        m = re.match(r'^    ([A-Za-z0-9_*|-]+)\)$', line)
        if not m:
            errs.append('a depth-1 label line outside the grammar: ' + s)
        else:
            cur = m.group(1)
            if cur in arms:
                errs.append('label %s appears twice' % cur)
            arms[cur] = {'chains': [], 'mcp': False}
        i += 1
        continue
    if cur is not None:
        if 'run_chain_with_payload' in line:
            m1 = re.match(r'^\s*run_chain_with_payload gate "\$PAYLOAD" \\$', line)
            m2 = re.match(r'^\s*run_chain_with_payload gate "\$PAYLOAD"((?: %s)+)\s*$' % NAME, line)
            if m1:
                arms[cur]['chains'].append([])
                pending = True
            elif m2:
                arms[cur]['chains'].append(m2.group(1).split())
            else:
                errs.append('%s: chain call outside the grammar: %s' % (cur, s))
        elif re.search(r'\brun_mcp_gate\b', line):
            arms[cur]['mcp'] = True
            arms[cur]['chains'].append(list(MCP_CHAIN))
        elif SH.search(line):
            errs.append('%s: a .sh token outside a chain: %s' % (cur, s))
    i += 1

for label in arms:
    if label not in TABLE:
        errs.append('label %s has no row in the arm table' % label)
for label in TABLE:
    if label not in arms:
        errs.append('table row %s names no adapter arm' % label)
for label, arm in arms.items():
    verdict = TABLE.get(label)
    if verdict == 'floor':
        if not arm['chains']:
            errs.append('floor arm %s runs no chain' % label)
        for chain in arm['chains']:
            if HOOK not in chain:
                errs.append('floor arm %s has a chain without %s' % (label, HOOK))
        if arm['mcp'] and HOOK not in mcp_base:
            errs.append('floor arm %s: run_mcp_gate base chain lacks %s' % (label, HOOK))
    elif verdict == 'local':
        for chain in arm['chains']:
            if HOOK in chain:
                errs.append('local arm %s names %s' % (label, HOOK))
if errs:
    print('; '.join(errs))
    sys.exit(1)
PY
}
if out="$(u2a_check "$ADAPTER")"; then ok "U2a every arm has a verdict, every floor chain runs the hook"; else bad "U2a $out"; fi

echo "== U2c mutations of the arm table =="
sed 's/local -a chain=(block-agy-salus-egress.sh /local -a chain=(/' "$ADAPTER" > "$TMP/adapter-nomcp.sh"
if grep -qF 'local -a chain=(mcp-policy.sh' "$TMP/adapter-nomcp.sh" && ! u2a_check "$TMP/adapter-nomcp.sh" >/dev/null; then
    ok "U2c mutation: the hook deleted from the mcp chain fails U2a"
else
    bad "U2c mutation: the hook deleted from the mcp chain passed U2a"
fi
awk '
    /^    search_web\|send_message\|ask_question\)$/ { print "    search_web|ask_question)"; next }
    /^    exit_plan_mode\|update_steps\)$/ {
        print "    send_message)"
        print "        PAYLOAD=\"$(build_claude_payload \"$RAW_TOOL\" raw)\" || emit_deny \"x\""
        print "        run_chain_with_payload gate \"$PAYLOAD\" peer-taint-gate.sh"
        print "        exit 0"
        print "        ;;"
    }
    { print }
' "$ADAPTER" > "$TMP/adapter-relabel.sh"
if grep -qxF '    send_message)' "$TMP/adapter-relabel.sh" && ! u2a_check "$TMP/adapter-relabel.sh" >/dev/null; then
    ok "U2c mutation: send_message moved to an arm with no row fails U2a"
else
    bad "U2c mutation: send_message moved to an arm with no row passed U2a"
fi
awk '/^    manage_task\)$/ { print "    evil_tool) run_chain_with_payload gate \"$PAYLOAD\" peer-taint-gate.sh ;;" } { print }' "$ADAPTER" > "$TMP/adapter-inline.sh"
if u2a_check "$TMP/adapter-inline.sh" >/dev/null; then bad "U2c mutation: an inline arm passed U2a"; else ok "U2c mutation: an inline arm fails U2a"; fi

echo "== U2-drive each floor arm refuses through the real adapter =="
for t in search_web send_message ask_question; do
    adapter_deny "U2-drive $t in the salus vault" "block-agy-salus-egress" "$(make_pre "$t" '{}' "$SALUS_VAULT")"
done
for t in list_resources read_resource; do
    adapter_deny "U2-drive $t in the salus vault" "block-agy-salus-egress" "$(make_pre "$t" '{"ServerName":"t3-code","Uri":"x"}' "$SALUS_VAULT")"
done
adapter_deny "U2-drive mcp graphify route" "block-agy-salus-egress" "$(make_pre mcp_graphify_query '{}' "$SALUS_VAULT")"
adapter_deny "U2-drive mcp t3-code route" "block-agy-salus-egress" "$(make_pre mcp_t3-code_t3_environment_read '{}' "$SALUS_VAULT")"
adapter_deny "U2-drive mcp t3-code unwatch_pull_request route" "block-agy-salus-egress" \
    "$(make_pre mcp_t3-code_unwatch_pull_request '{"url":"https://github.com/o/r/pull/99"}' "$SALUS_VAULT")"
adapter_deny "U2-drive lazy call_mcp_tool route" "block-agy-salus-egress" \
    "$(make_pre call_mcp_tool '{"ServerName":"graphify","ToolName":"graph_stats","Arguments":{}}' "$SALUS_VAULT")"
adapter_deny "U2-drive run_command scp" "block-agy-salus-egress" "$(make_pre run_command '{"CommandLine":"scp x h:"}' "$SALUS_VAULT")"
for t in schedule swarm run_workflow define_subagent manage_subagents manage_task unknown_tool_xyz; do
    adapter_deny "U2-drive refused tool $t" "antigravity-hook-adapter" "$(make_pre "$t" '{}' "$SALUS_VAULT")"
done

echo "== U6 the adapter guards every PHI list the classifier reads (I10) =="
GLM_OUT="$TMP/glm-out"
u6_expected() {
    printf '%s\n' "$1/.config/claude-codex/phi-roots" "$1/.config/claude-codex/egress-denylist"
    if [ -n "$2" ]; then
        printf '%s\n' "$2/phi-roots" "$2/egress-denylist"
    else
        printf '%s\n' "$1/.config/claude-glm/phi-roots" "$1/.config/claude-glm/egress-denylist"
    fi
}
u6_round() {
    local tag="$1" glm="$2" h="$TMP/u6-home-$1" lists list root="$TMP/u6-root" k=0
    mkdir -p "$h/.himmel" "$root"
    U6ENV=(HOME="$h")
    [ -z "$glm" ] || U6ENV+=(CLAUDE_GLM_CONFIG_DIR="$glm")
    lists="$(u6_expected "$h" "$glm")"
    got="$(env "${U6ENV[@]}" python3 -I "$CLASSIFIER" lists)"
    if [ "$got" = "$lists" ]; then ok "U6 $tag: lists prints the expected four paths"; else bad "U6 $tag: lists printed <$got>"; fi
    while IFS= read -r list; do
        k=$((k+1))
        rm -rf "$h/.config" "$GLM_OUT"
        mkdir -p "$(dirname "$list")"
        printf '%s\n' "$root" > "$list"
        env "${U6ENV[@]}" python3 -I "$CLASSIFIER" salus "$root"; rc=$?
        if [ "$rc" -eq 0 ]; then ok "U6 $tag list $k seeded alone marks its root"; else bad "U6 $tag list $k seeded alone gave rc=$rc"; fi
        adapter_deny "U6 $tag edit_file of list $k denied" "self-protect" \
            "$(make_pre edit_file "$(jq -cn --arg p "$list" '{Path:$p,Target:"a",Replacement:"b"}')" "$PLAIN_DIR")" "${U6ENV[@]}"
        adapter_deny "U6 $tag write_file of list $k's directory denied" "self-protect" \
            "$(make_pre write_file "$(jq -cn --arg p "$(dirname "$list")" '{Path:$p,Content:""}')" "$PLAIN_DIR")" "${U6ENV[@]}"
    done <<EOF
$lists
EOF
    rm -rf "$h/.config" "$GLM_OUT" "$TMP/u6-target"
    mkdir -p "$h/.config" "$TMP/u6-target"
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        rm -rf "$d" "$TMP/u6-target"; mkdir -p "$(dirname "$d")" "$TMP/u6-target"
        ln -s "$TMP/u6-target" "$d"
        adapter_deny "U6 $tag symlinked ${d##*/}: edit of the target list denied" "self-protect" \
            "$(make_pre edit_file "$(jq -cn --arg p "$TMP/u6-target/phi-roots" '{Path:$p,Target:"a",Replacement:"b"}')" "$PLAIN_DIR")" "${U6ENV[@]}"
        adapter_deny "U6 $tag symlinked ${d##*/}: write to the target directory denied" "self-protect" \
            "$(make_pre write_file "$(jq -cn --arg p "$TMP/u6-target" '{Path:$p,Content:""}')" "$PLAIN_DIR")" "${U6ENV[@]}"
        rm -f "$d"
    done <<EOF
$(printf '%s\n' "$lists" | sed 's#/[^/]*$##' | sort -u)
EOF
    rm -rf "$TMP/u6-target" "$root"
}
u6_round "glm-unset" ""
u6_round "glm-outside-home" "$GLM_OUT"
py_markers="$(grep -oE "'\.salus(-profile)?'" "$CLASSIFIER" | tr -d "'" | sort -u | tr '\n' ' ')"
ad_markers="$(grep -oE '^[[:space:]]*\.salus\|\.salus-profile\)' "$ADAPTER" | tr -d ' )' | tr '|' '\n' | sort -u | tr '\n' ' ')"
if [ -n "$py_markers" ] && [ "$py_markers" = "$ad_markers" ]; then ok "U6 the classifier's marker names equal the adapter's ($py_markers)"; else bad "U6 marker names differ: classifier <$py_markers> adapter <$ad_markers>"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
