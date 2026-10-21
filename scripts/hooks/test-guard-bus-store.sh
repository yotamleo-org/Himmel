#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-bus-store.sh
# A speed bump over the himmel-bus store (threat model T3, T5, T6): a session's
# Bash/Write/Edit that reaches under the bus root, calls `bus register|bind|
# rebind`, or assigns HIMMEL_BUS_* is denied; `bus status|peers|wait|send|adopt`
# stay allowed. Fails CLOSED on a payload it cannot parse that names the bus
# root. The guard is text matching: the "residual" rows pin what it deliberately
# does NOT catch, so nobody mistakes it for a fence.
#
# Payloads are built with jq from plain strings, so no row needs shell quoting.
# bash 3.2-safe. Platform guard (gitbash-only): env + jq, no git/path work.
# The single-quoted $VAR rows are literal command text, never expanded.
# shellcheck disable=SC2016
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-bus-store.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

ROOT='/var/tmp/fixture-state/himmel/bus'

bash_json()  { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
file_json()  { jq -nc --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p,content:"x"}}'; }
cwd_json()   { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

# run <json> [ENV=val ...] -> sets RC and OUT
run() {
    local json="$1"; shift
    OUT="$(printf '%s' "$json" | env -u BUS_STORE_GUARD_OK "$@" bash "$HOOK" 2>/dev/null)"
    RC=$?
}

deny()  { # deny <label> <json> [ENV=val ...]
    local label="$1" json="$2"; shift 2
    run "$json" "$@"
    local reason
    reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
    case "$reason" in
        "bus store-deny: "*) if [ "$RC" = 2 ]; then ok "$label"; else bad "$label - reason ok but rc=$RC"; fi ;;
        *) bad "$label - expected deny (rc=$RC) got: $OUT" ;;
    esac
}
allow() { # allow <label> <json> [ENV=val ...]  — allow must be rc 0 AND silent
    local label="$1" json="$2"; shift 2
    run "$json" "$@"
    if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "$label"; else
        bad "$label - expected silent allow, rc=$RC out=$OUT"; fi
}

[ -f "$HOOK" ] || { bad "hook not found: $HOOK"; echo "Summary: $pass passed, $fail failed"; exit 1; }

echo "== T3: registration verbs and env =="
deny "bus register x --role console" "$(bash_json 'bus register x --role console')"
deny "bus bind x 1" "$(bash_json 'bus bind x 1')"
deny "bus rebind x 1" "$(bash_json 'bus rebind x 1')"
deny "path-qualified bin/bus register" "$(bash_json 'node marketplace/plugins/himmel-bus/bin/bus register x --role leg')"
deny "register after a benign command" "$(bash_json 'echo hi; bus register x --role leg')"
deny "HIMMEL_BUS_NAME=x claude" "$(bash_json 'HIMMEL_BUS_NAME=x claude')"
deny "export HIMMEL_BUS_NAME=x" "$(bash_json 'export HIMMEL_BUS_NAME=x; claude')"
deny "HIMMEL_BUS_NAME+=x claude (append assignment)" "$(bash_json 'HIMMEL_BUS_NAME+=x claude')"
deny "env HIMMEL_BUS_NAME=x claude" "$(bash_json 'env HIMMEL_BUS_NAME=x claude')"

echo "== T3/T6: writes under the bus root =="
deny "printf into peers/x.json" "$(bash_json "printf '{}' > $ROOT/peers/x.json")"
deny "tee into the log" "$(bash_json "echo x | tee -a $ROOT/log/a.jsonl")"
deny "XDG-relative spelling" "$(bash_json 'echo x >> "$XDG_STATE_HOME/himmel/bus/cur/a"')"
deny "tilde spelling" "$(bash_json 'rm -f ~/.local/state/himmel/bus/peers/x.json')"
deny "relative spelling after cd" "$(bash_json 'cd ~/.local/state && echo x > himmel/bus/cur/a')"
deny "Write under the bus root" "$(file_json Write "$ROOT/peers/x.json")"
deny "Edit under the bus root" "$(file_json Edit "$ROOT/cur/a")"
deny "MultiEdit under the bus root" "$(file_json MultiEdit "$ROOT/log/a.jsonl")"
deny "Write via .. segments" "$(file_json Write "/tmp/../var/tmp/fixture-state/himmel/bus/peers/y.json")"

echo "== T6: a symlink alias into the bus root (resolved-path rule) =="
SCR="$(mktemp -d "${TMPDIR:-/tmp}/guard-fixture.XXXXXX")" || exit 1
trap 'rm -rf "$SCR"' EXIT
mkdir -p "$SCR/state/himmel/bus/peers" && ln -s "$SCR/state/himmel/bus" "$SCR/alias"
deny "Write through a symlink alias with no 'bus' in the path" "$(file_json Write "$SCR/alias/peers/x.json")"
deny "Edit through a symlink alias with no 'bus' in the path" "$(file_json Edit "$SCR/alias/peers/x.json")"
allow "Write to a real non-bus path beside the alias" "$(file_json Write "$SCR/other.txt")"

echo "== T5: reads under the bus root =="
deny "cat a log" "$(bash_json "cat $ROOT/log/other.jsonl")"
deny "head a log" "$(bash_json "head -n 5 $ROOT/log/other.jsonl")"
deny "grep the log dir" "$(bash_json "grep -r token $ROOT/log/")"
deny "ls the bus root" "$(bash_json "ls $ROOT")"

echo "== option parsing: options before the verb, split quoting =="
deny "bus --role leg register legX" "$(bash_json 'bus --role leg register legX')"
deny "bus --role=console register x" "$(bash_json 'bus --role=console register x')"
deny "bin/bus --unacked bind x 123" "$(bash_json 'node marketplace/plugins/himmel-bus/bin/bus --unacked bind x 123')"
deny "bus 'register' x (quoted verb)" "$(bash_json "bus 'register' x")"
deny "\"bus\" register x (quoted word)" "$(bash_json '"bus" register x')"
deny "register after && in a later segment" "$(bash_json 'cd /tmp && bus --role leg rebind x 1')"
allow "bus send naming a file called register.txt" "$(bash_json 'bus send console /tmp/register.txt')"
allow "bus status then an unrelated bind word in a LATER segment" "$(bash_json 'bus status; echo bind later')"

echo "== path spelling: repeated slashes and /./ =="
deny "himmel//bus" "$(bash_json 'cat /var/tmp/fixture-state/himmel//bus/log/a.jsonl')"
deny "himmel/./bus" "$(bash_json 'cat /var/tmp/fixture-state/himmel/./bus/log/a.jsonl')"
deny "himmel/.//bus" "$(bash_json 'cat /var/tmp/fixture-state/himmel/.//bus/log/a.jsonl')"

echo "== cwd indirection (payload .cwd) =="
STATE_DIR='/var/tmp/fixture/.local/state/himmel'
deny "cwd under the bus root" "$(cwd_json 'ls' "$STATE_DIR/bus/log")"
deny "cwd is the himmel state dir + bounded bus/ token" "$(cwd_json 'cat bus/log/legB.0.jsonl' "$STATE_DIR")"
allow "cwd is the himmel state dir, no bus token" "$(cwd_json 'ls' "$STATE_DIR")"
allow "bus/ token under an ordinary cwd" "$(cwd_json 'cat bus/readme.txt' '/tmp')"

echo "== trust-judge j2355b: continuations, bare bus token, in-command cd, XDG =="
deny "backslash-newline continuation splits bus from the verb" \
    "$(bash_json $'node marketplace/plugins/himmel-bus/bin/bus \\\n--role console \\\nregister legX')"
deny "a verb word split across a continuation (bash joins it with no space)" \
    "$(bash_json $'bus reg\\\nister legX')"
deny "bus split across a continuation: no literal bus in the raw JSON (verb)" \
    "$(bash_json $'b\\\nus register legX')"
deny "root split across a continuation: no literal bus in the raw JSON (path)" \
    "$(bash_json $'cat /var/tmp/fixture-state/himmel/bu\\\ns/log/a.jsonl')"
deny "quote split b''us register" "$(bash_json "b''us register x")"
deny "double-quote split b\"\"us register (JSON-escaped quote, no literal bus)" "$(bash_json 'b""us register x')"
deny "double-quote split under the state dir" "$(bash_json 'cat /var/tmp/fixture-state/himmel/b""us/log/a.jsonl')"
deny "command substitution b\$(true)us register" "$(bash_json 'b$(true)us register x')"
deny "backtick substitution b\`true\`us register" "$(bash_json 'b`true`us register x')"
deny "substitution with a space b\$(printf u)s register" "$(bash_json 'b$(printf u)s register x')"
deny "backtick substitution with a space b\`printf u\`s register" "$(bash_json 'b`printf u`s register x')"
deny "quoted substitution with a space b\"\$(printf u)\"s register" "$(bash_json 'b"$(printf u)"s register x')"
allow "a process substitution alone is no bus word (its body is its own segment)" "$(bash_json 'cat <(printf bu) register')"
deny "verb as ANSI-C hex escape" "$(bash_json "bus \$'reg\\x69ster' x")"
deny "verb as ANSI-C octal escape" "$(bash_json "bus \$'\\162egister' x")"
deny "verb with an expansion inside (reg\$x)" "$(bash_json 'bus reg$x x')"
deny "verb with a ? glob" "$(bash_json 'bus r?gister x')"
deny "verb with a [i] glob" "$(bash_json 'bus reg[i]ster x')"
deny "verb with a braced expansion (re\${x}ister)" "$(bash_json 'bus re${x}ister x')"
deny "verb with a command substitution inside" "$(bash_json 'bus reg$(printf i)ster x')"
allow "bus send with a bare variable body file" "$(bash_json 'bus send console $BODY --re 4')"
allow "bus send with variable recipient" "$(bash_json 'bus send $to /tmp/b.txt')"
allow "bus status --for a variable" "$(bash_json 'bus status --for $c')"
deny "env name split by quotes: export HIMMEL_BUS_\"NAME\"=x" "$(bash_json 'export HIMMEL_BUS_"NAME"=x')"
deny "env name split by single quotes" "$(bash_json "HIMMEL_BUS_'NAME'=x claude")"
deny "env name split by a backslash" "$(bash_json 'HIMMEL_BUS_NA\ME=x claude')"
deny "env assignment as an ANSI-C word" "$(bash_json "export \$'HIMMEL_BUS_NAME=x'")"
deny "env name ending in an expansion" "$(bash_json 'export HIMMEL_BUS_${x}=1')"
deny "env name with an expansion in the middle" "$(bash_json 'export HIM${y}EL_BUS_NAME=x')"
deny "env name via ANSI-C escape for a letter" "$(bash_json "export \$'HIMMEL_\\x42US_NAME=x'")"
allow "env with variable name and value" "$(bash_json 'env "$K=$V" cmd')"
allow "a quoted assignment unrelated to the bus" "$(bash_json 'FOO="a b" cmd')"
deny "glob b?s under the state dir" "$(bash_json 'cat /var/tmp/fixture-state/himmel/b?s/log/a.jsonl')"
deny "glob b*s under the state dir" "$(bash_json 'cat /var/tmp/fixture-state/himmel/b*s/log/a.jsonl')"
deny "glob b[u]s under the state dir" "$(bash_json 'cat /var/tmp/fixture-state/himmel/b[u]s/log/a.jsonl')"
deny "brace expansion b{u,x}s under the state dir" "$(bash_json 'cat /var/tmp/fixture-state/himmel/b{u,x}s/log/a.jsonl')"
deny "expansion b\${x}us register" "$(bash_json 'b${x}us register x')"
deny "ANSI-C \$'\\x62'us register" "$(bash_json "\$'\\x62'us register x")"
deny "glob verb path b?s register" "$(bash_json 'b?s register x')"
deny "in-command cd then glob b?s" "$(bash_json 'cd ~/.local/state/himmel && cat b?s/log/a')"
deny "cwd state dir + glob b?s" "$(cwd_json 'cat b?s/log/a' "$STATE_DIR")"
deny "cwd state dir + bare star" "$(cwd_json 'cat */log/a' "$STATE_DIR")"
allow "state dir via \$XDG_STATE_HOME with no bus word" "$(bash_json 'cd $XDG_STATE_HOME/himmel && ls')"
allow "quotes and a glob in an unrelated command" "$(bash_json "git grep -n 'foo' -- 'scripts/*.sh'")"
allow "\$HOME path in an unrelated command" "$(bash_json 'ls $HOME/projects')"
deny "cwd state dir + grep -rh . bus" "$(cwd_json 'grep -rh . bus' "$STATE_DIR")"
deny "cwd state dir + cp -r bus" "$(cwd_json 'cp -r bus /tmp/b' "$STATE_DIR")"
deny "cwd state dir + find bus" "$(cwd_json 'find bus -type f' "$STATE_DIR")"
deny "cwd state dir + tar cf - bus" "$(cwd_json 'tar cf - bus' "$STATE_DIR")"
deny "in-command cd ~/.local/state/himmel then bus/" "$(bash_json 'cd ~/.local/state/himmel && cat bus/log/x.jsonl')"
deny "in-command cd \$XDG_STATE_HOME/himmel then bus" "$(bash_json 'cd $XDG_STATE_HOME/himmel && tar cf - bus')"
deny "in-command cd \${XDG_STATE_HOME}/himmel then bus" "$(bash_json 'cd ${XDG_STATE_HOME}/himmel && ls bus')"
deny "XDG_STATE_HOME with a trailing slash, cwd is its himmel dir" \
    "$(cwd_json 'ls bus' '/srv/xdg/himmel')" XDG_STATE_HOME=/srv/xdg/
deny "XDG_STATE_HOME literal in the command, then bus" \
    "$(bash_json 'cd /srv/xdg/himmel && cat bus/log/x.jsonl')" XDG_STATE_HOME=/srv/xdg/
allow "in-command cd into the state dir with no bus token" "$(bash_json 'cd ~/.local/state/himmel && ls')"
allow "bus send from an ordinary cwd" "$(cwd_json 'bus send console /tmp/b.txt --re 4' '/tmp')"
allow "bus status from an ordinary cwd" "$(cwd_json 'bus status' '/tmp')"
deny  "a separator inside a quoted option value does not hide the verb (model)" \
    "$(bash_json 'bus --note "a;b" register legX')"

echo "== command-position model: a quoted string is one word, a heredoc body is data =="
deny  "a commit message naming bus and register" "$(bash_json 'git commit -m "fix bus register retry"')"
allow "bus send with a summary that says rebind" "$(bash_json 'bus send console /tmp/b.txt --summary "rebind done"')"
allow "a heredoc body naming bus register is data" "$(bash_json $'cat > /tmp/notes.md <<\'EOF\'\nbus register x\nEOF')"
deny  "bus register inside a bash -c body" "$(bash_json 'bash -c "bus register x"')"
deny  "bus register inside an eval body" "$(bash_json "eval 'bus register x'")"
deny  "bus register behind a runner the model cannot read (text reader)" "$(bash_json 'nice bus register x')"
deny  "bus register behind xargs (text reader)" "$(bash_json 'echo x | xargs bus register')"
deny  "bus register behind env (text reader)" "$(bash_json 'env -i bus register x')"
deny  "bus register behind env NAME=value" "$(bash_json 'env HOME=/tmp bus register x')"
allow "an env value naming bus register is data (text reader)" "$(bash_json "env X='bus register x' true")"
deny  "a heredoc fed to a shell (text reader)" "$(bash_json $'bash <<\'EOF\'\nbus register x\nEOF')"
deny  "a script file run by a shell (text reader)" "$(bash_json 'echo "bus register x" > /tmp/f.sh; bash /tmp/f.sh')"
deny  "a script file run by path (text reader)" \
    "$(bash_json 'echo "bus register x" > /tmp/f.sh; chmod +x /tmp/f.sh; /tmp/f.sh')"
deny  "a script file sourced (text reader)" "$(bash_json 'echo "bus register x" > /tmp/f.sh; . /tmp/f.sh')"
deny  "a quoted string written to a file for a later call to run" "$(bash_json 'echo "bus register x" > /tmp/f.sh')"
deny  "a trap string runs later" "$(bash_json "trap 'bus register x' EXIT")"
deny  "a git alias runs its string" "$(bash_json "git -c alias.r='!bus register x' r")"
deny  "prlimit then bash -c" "$(bash_json "prlimit --as=100000000 bash -c 'bus register x'")"
deny  "tmux runs its string" "$(bash_json "tmux new -d 'bus register x'")"
deny  "expect spawns its string" "$(bash_json "expect -c 'spawn bus register x'")"
deny  "an alias defined then used" "$(bash_json $'alias r=\'bus register x\'\nr')"
allow "a verb before the bus word in one word (text reader, as on main)" "$(bash_json 'git commit -m "register the bus"')"

echo "== model failures: the text reader decides =="
# A heredoc body naming bus register is allowed by the model and denied by the
# text reader, so a deny here proves the call fell back.
HDOC=$'cat > /tmp/notes.md <<\'EOF\'\nbus register x\nEOF'
STUBS="$(mktemp -d "${TMPDIR:-/tmp}/busstore-stubs.XXXXXX")" || exit 1
REAL_JQ="$(command -v jq)"
stub_path() { # stub_path <name> -> a dir of real cat/tr/readlink, plus jq and shfmt per <name>
    local d="$STUBS/$1" t
    mkdir -p "$d"
    for t in cat tr readlink; do ln -s "$(command -v "$t")" "$d/$t"; done
    printf '%s\n' "$d"
}
stub_run() { # stub_run <dir> <json>
    OUT="$(printf '%s' "$2" | env -i PATH="$1" "$BASH" "$HOOK" 2>/dev/null)"
    RC=$?
}
D="$(stub_path rc3)"; ln -s "$REAL_JQ" "$D/jq"; ln -s "$(command -v shfmt || echo /nonexistent)" "$D/shfmt"
stub_run "$D" "$(bash_json "$HDOC"$'\n)')"
if [ "$RC" = 2 ]; then ok "parse failure (rc 3) -> text reader denies"; else bad "parse failure (rc 3): rc=$RC"; fi
D="$(stub_path rc4)"; ln -s "$REAL_JQ" "$D/jq"
printf '#!/bin/sh\necho not-json\n' > "$D/shfmt"; chmod +x "$D/shfmt"
stub_run "$D" "$(bash_json "$HDOC")"
if [ "$RC" = 2 ]; then ok "model error (rc 4) -> text reader denies"; else bad "model error (rc 4): rc=$RC"; fi
D="$(stub_path jqfail)"; ln -s "$(command -v shfmt || echo /nonexistent)" "$D/shfmt"
printf '#!/bin/sh\nfor a; do case "$a" in *"def isbus"*) exit 5 ;; esac; done\nexec "%s" "$@"\n' "$REAL_JQ" > "$D/jq"
chmod +x "$D/jq"
stub_run "$D" "$(bash_json "$HDOC")"
if [ "$RC" = 2 ]; then ok "verdict jq failure -> text reader denies"; else bad "verdict jq failure: rc=$RC"; fi
rm -rf "$STUBS"

echo "== no shfmt: the text reader decides, exactly as before the model =="
NOSHFMT="$(mktemp -d "${TMPDIR:-/tmp}/busstore-noshfmt.XXXXXX")" || exit 1
for t in jq cat tr readlink; do ln -s "$(command -v "$t")" "$NOSHFMT/$t"; done
OUT="$(printf '%s' "$(bash_json 'bus register x')" | env -i PATH="$NOSHFMT" "$BASH" "$HOOK" 2>/dev/null)"
RC=$?
if [ "$RC" = 2 ]; then ok "no shfmt, bus register -> deny"; else bad "no shfmt, bus register: rc=$RC"; fi
OUT="$(printf '%s' "$(bash_json 'git commit -m "fix bus register retry"')" | env -i PATH="$NOSHFMT" "$BASH" "$HOOK" 2>/dev/null)"
RC=$?
if [ "$RC" = 2 ]; then ok "no shfmt, quoted bus register text -> deny (text reader)"; else bad "no shfmt, quoted text: rc=$RC"; fi
OUT="$(printf '%s' "$(bash_json 'bus status')" | env -i PATH="$NOSHFMT" "$BASH" "$HOOK" 2>/dev/null)"
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "no shfmt, bus status -> allow, silent"; else bad "no shfmt, bus status: rc=$RC out=$OUT"; fi
rm -rf "$NOSHFMT"

echo "== allowed bus verbs =="
allow "bus status" "$(bash_json 'bus status')"
allow "bus status <name>" "$(bash_json 'bus status x')"
allow "bus peers" "$(bash_json 'bus peers')"
allow "bus wait" "$(bash_json 'bus wait --for x')"
allow "bus send" "$(bash_json 'bus send console /tmp/body.txt --re 4')"
allow "bus adopt" "$(bash_json 'bus adopt new-console')"
allow "path-qualified bin/bus send" "$(bash_json 'node marketplace/plugins/himmel-bus/bin/bus send console /tmp/b.txt')"

echo "== unrelated work stays silent =="
allow "plain ls" "$(bash_json 'ls -la')"
allow "git grep for the env var name" "$(bash_json 'git grep HIMMEL_BUS_NAME scripts')"
allow "echo of the env var" "$(bash_json 'echo $HIMMEL_BUS_NAME')"
allow "himmel-bus plugin path (hyphen)" "$(bash_json 'ls marketplace/plugins/himmel-bus/lib')"
allow "bus-deliver hook path" "$(bash_json 'bash scripts/hooks/bus-deliver-hook.sh')"
allow "sibling file himmel/bus.json is not the bus root (Bash)" "$(bash_json 'cat /tmp/himmel/bus.json')"
allow "sibling file himmel/bus.json is not the bus root (Write)" "$(file_json Write '/tmp/himmel/bus.json')"
deny  "the bus root as a trailing directory still denies" "$(bash_json 'ls /tmp/himmel/bus')"
allow "Write to an ordinary file" "$(file_json Write '/tmp/x.txt')"
allow "Edit in the himmel-bus plugin" "$(file_json Edit 'marketplace/plugins/himmel-bus/lib/store.mjs')"
allow "non-Bash non-file tool" "$(jq -nc '{tool_name:"Agent",tool_input:{prompt:"cat himmel/bus/log/a"}}')"

echo "== substitution openers: a body is its own segment, an opener alone is no candidate =="
allow "two process substitutions" "$(bash_json 'diff <(sort a.txt) <(sort b.txt)')"
allow "gh pr create with two command substitutions" "$(bash_json 'gh pr create --title "$(git log -1 --format=%s)" --body "$(cat /tmp/body.md)"')"
allow "git commit with two command-substitution messages" "$(bash_json 'git commit -m "$(cat a.txt)" -m "$(cat b.txt)"')"
allow "two arithmetic expansions" "$(bash_json 'echo $((a + b)) $((c + d))')"
allow "two assignments from substitutions" "$(bash_json 'A=$(git rev-parse HEAD) B=$(cat x.txt) make')"
allow "bus send with a substitution body" "$(bash_json 'bus send c "$(cat /tmp/m.txt)" --summary "$(date)"')"
deny  "bus register inside a command substitution" "$(bash_json '$(bus register x)')"
deny  "bus rebind inside a quoted command substitution" "$(bash_json 'echo "$(bus rebind z)"')"
deny  "bus bind inside a process substitution" "$(bash_json 'cat <(bus bind y)')"
deny  "bus register inside backticks" "$(bash_json 'echo `bus register x`')"
deny  "bus register behind an assignment substitution" "$(bash_json 'X=$(bus register y) true')"
deny  "a closed substitution between bus and the verb" "$(bash_json 'bus $(true) register legX')"
deny  "a quoted substitution between bus and the verb" "$(bash_json 'bus "$(:)" bind x')"
deny  "a process substitution between bus and the verb" "$(bash_json 'bus <(:) rebind x')"
deny  "an open substitution with a body between bus and the verb" "$(bash_json 'bus $(echo a b) register x')"
deny  "a quoted open substitution with a body between bus and the verb" "$(bash_json 'bus "$(cat f)" register x')"
deny  "a bus word inside a closed body still pairs with a verb after it (a pop never lowers seen)" "$(bash_json 'echo $(bus status) register')"
deny  "a quoted paren in a subshell does not hide the verb" "$(bash_json "( bus --summary ')' register legX --role console )")"
deny  "a quoted paren in a command substitution does not hide the verb" "$(bash_json 'echo "$(bus --summary '"')'"' register legX --role console)"')"
deny  "an escaped paren in a backtick body does not hide the verb" "$(bash_json 'echo `bus --summary \) bind x 1`')"
deny  "a nested substitution between bus and the verb" "$(bash_json 'bus $(echo $(date) x) register y')"

echo "== no jq: the raw root text is still scanned =="
NOJQ="$(mktemp -d)" || exit 1
for t in cat tr readlink; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
OUT="$(printf '%s' "$(bash_json "cat $ROOT/log/a")" | env -i PATH="$NOJQ" "$BASH" "$HOOK" 2>/dev/null)"
RC=$?
if [ "$RC" = 2 ]; then ok "no jq, payload naming the root -> deny"; else bad "no jq, root named: rc=$RC"; fi
OUT="$(printf '%s' "$(bash_json 'ls /tmp')" | env -i PATH="$NOJQ" "$BASH" "$HOOK" 2>/dev/null)"
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "no jq, ordinary payload -> allow, silent"; else bad "no jq, ordinary: rc=$RC out=$OUT"; fi
rm -rf "$NOJQ"

echo "== fail closed on an unparseable payload that names the root =="
run "not json at all: cat $ROOT/log/a.jsonl"
if [ "$RC" = 2 ]; then ok "garbage naming the bus root -> deny"; else bad "garbage naming the root: rc=$RC"; fi
run "not json at all"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "garbage not naming the root -> allow, silent"; else bad "garbage without root: rc=$RC out=$OUT"; fi
run ''
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "empty stdin -> allow, silent"; else bad "empty stdin: rc=$RC out=$OUT"; fi
run '{"tool_name":"Bash","tool_input":{"command":["cat","himmel/bus/log/a"]}}'
if [ "$RC" = 2 ]; then ok "non-string command naming the root -> deny"; else bad "non-string command: rc=$RC"; fi

echo "== bypass =="
allow "BUS_STORE_GUARD_OK=1 + bus register -> allow" "$(bash_json 'bus register x --role leg')" BUS_STORE_GUARD_OK=1
deny  "BUS_STORE_GUARD_OK=0 does not bypass" "$(bash_json 'bus register x --role leg')" BUS_STORE_GUARD_OK=0

echo "== residual: a speed bump, not a fence (pins what text matching misses) =="
allow "residual: interpreter assembles the path" \
    "$(bash_json "python3 -c \"import os; open(os.path.expanduser('~/.local/state/hi'+'mmel/b'+'us/cur/a'),'w')\"")"

echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
