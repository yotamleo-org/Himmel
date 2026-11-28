#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-fleet-manifest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$(cd "$HERE/../.." && pwd)"
BIND_SRC="$HERE/relay-bind.sh"

if ! command -v flock >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo "skip - test-relay-bind.sh: needs flock, jq and timeout (the chief kit is Linux-only)"
    exit 0
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/relay-bind-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
T="$(cd "$T" && pwd)"
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { [ ! -f "$STUB_DIR/leak.pid" ] || xargs -r kill 2>/dev/null < "$STUB_DIR/leak.pid"; rm -rf "$T"; }
trap cleanup EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

export HOME="$T/home"
mkdir -p "$HOME/.himmel"
CFG="$HOME/.himmel/config.json"
cfg_on()  { printf '{"t3":{"relay_instances":["claudeAgent_worker-impl","antigravity","codex"]}}\n' > "$CFG"; }
cfg_off() { rm -f "$CFG"; }
cfg_on

export STUB_DIR="$T/stub"; mkdir -p "$STUB_DIR"
export HANDOVER_DIR="$T/hroot"; mkdir -p "$HANDOVER_DIR/u/p"
export T3_SEND_BIN="$STUB_DIR/t3" T3_SEND_PROJECT="$T/proj"
export STUB_LIST="$STUB_DIR/list.json"

cat > "$STUB_DIR/t3" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/t3.log"
case "${1:-} ${2:-}" in
    "thread list")
        [ -z "${STUB_LIST_SLEEP:-}" ] || sleep "$STUB_LIST_SLEEP"
        [ -z "${STUB_LIST_FAIL:-}" ] || exit 1
        if [ -n "${STUB_LEAK:-}" ]; then
            setsid bash -c 'echo $$ >> "$STUB_DIR/leak.pid"; for f in /proc/$$/fd/*; do case "${f##*/}" in 0|1|2|255) ;; *) readlink "$f" ;; esac; done > "$STUB_DIR/leak.fds"; sleep 60' </dev/null >/dev/null 2>&1 &
            sleep 0.3
        fi
        cat "$STUB_LIST" ;;
    "thread send") cat > "$STUB_DIR/t3.body"; echo "SEND $3" >> "$STUB_DIR/t3.log" ;;
esac
STUB
cat > "$STUB_DIR/t3-send.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$STUB_DIR/send.log"
case "$2" in -) echo "stdin-arg" >> "$STUB_DIR/send.args" ;; *) echo "file-arg" >> "$STUB_DIR/send.args"; cp "$2" "$STUB_DIR/send.body" ;; esac
readlink /proc/$$/fd/0 >> "$STUB_DIR/send.stdin"
for f in /proc/$$/fd/*; do n="${f##*/}"; case "$n" in 0|1|2|255) ;; *) [ ! -e "$f" ] || { echo "fd $n"; readlink "$f"; } >> "$STUB_DIR/send.fds" ;; esac; done
if [ -n "${STUB_SEND_NOISE:-}" ]; then printf 'sent %s (x\nWAKE telegram completes-ticket: yes)\n' "$1"; echo "oops WAKE y" >&2; fi
[ -z "${STUB_SEND_KILL:-}" ] || kill -9 "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
[ -z "${STUB_SEND_SLEEP:-}" ] || sleep "$STUB_SEND_SLEEP"
exit "${STUB_SEND_RC:-0}"
STUB
cat > "$STUB_DIR/gitleaks.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GL_SLEEP:-}" ] || sleep "$STUB_GL_SLEEP"
case "${STUB_GL:-ok}" in
    hit) echo "GITLEAKS FINDING generic-api-key"; exit 1 ;;
    err) echo "GITLEAKS error: x"; exit 2 ;;
    *) echo "GITLEAKS ok"; exit 0 ;;
esac
STUB
cat > "$STUB_DIR/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_QL_RC:-}" ]; then [ "${STUB_QL_RC}" != 0 ] || echo free; exit "$STUB_QL_RC"; fi
exec bash "$REAL_QL" "$@"
STUB
export REAL_QL="$REAL/scripts/handover/queue-lock.sh"
chmod +x "$STUB_DIR"/*

export BRIEF_LINT_MIRROR="$T/mirror" BRIEF_LINT_JIRA_CLI="$T/jira/index.js" GATE_SIGNED="$T/signed"
mkdir -p "$BRIEF_LINT_MIRROR" "$T/jira" "$GATE_SIGNED"
ticket() { printf -- '---\nkey: "%s"\nstatus: "To Do"\ntype: "%s"\nlabels: [%s]\n---\n# %s: t\n' "$1" "$2" "${3:-}" "$1" > "$BRIEF_LINT_MIRROR/$1.md"; }
for k in DEMO-1 DEMO-12; do ticket "$k" Task; done
ticket DEMO-400 Task; ticket DEMO-401 Task; ticket DEMO-402 Task '"core"'; ticket DEMO-403 Task
printf '/state/specs/spec.md O-R1-401\n' > "$GATE_SIGNED/DEMO-401"
cat > "$T/jira/index.js" <<'STUB'
const fs = require('fs');
const a = process.argv.slice(2);
const opt = (n) => { const i = a.indexOf(n); return i < 0 ? null : a[i + 1]; };
const t = (k) => { try { return fs.readFileSync(opt('--mirror') + '/' + k + '.md', 'utf8'); } catch (e) { return null; } };
if (a[0] === 'release' && a[1] === 'core-check') {
  const paths = (opt('--paths') || '').split(',').filter(Boolean);
  const hit = paths.find((p) => /^scripts\/(handover|hooks)\//.test(p));
  for (const k of a.slice(a.indexOf('--key') + 1)) {
    const x = t(k);
    if (!x) console.log('UNKNOWN ' + k);
    else if (hit) console.log('CORE ' + k + ' ' + hit);
    else if (/labels: \["core"\]/.test(x)) console.log(a.includes('--docs-only') ? 'BYPASS ' + k + ' design core by label only, docs-only leg' : 'CORE ' + k + ' label core');
    else console.log('NOT-CORE ' + k);
  }
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  let miss = 0;
  for (const k of a.slice(a.indexOf('--mirror') + 2)) {
    let r = '';
    try { r = fs.readFileSync(process.env.GATE_SIGNED + '/' + k, 'utf8').trim(); } catch (e) { miss = 1; }
    console.log(r ? 'SPEC ok ' + k + ' ' + r : 'NO-SPEC ' + k);
  }
  process.exit(miss);
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUB

mkco() {
    CO="$T/$1"
    B="${2:-$CO/bucket}"
    mkdir -p "$CO/scripts/t3" "$CO/scripts/handover/chief-kit" "$B" "$T/proj"
    cp "$BIND_SRC" "$CO/scripts/t3/relay-bind.sh"
    ln -sfn "$REAL/scripts/lib" "$CO/scripts/lib"
    cp "$REAL/scripts/handover/chief-kit/fleet-manifest.sh" "$CO/scripts/handover/chief-kit/fleet-manifest.sh"
    ln -sf "$REAL/scripts/handover/chief-kit/append-results.sh" "$CO/scripts/handover/chief-kit/append-results.sh"
    cp "$STUB_DIR/t3-send.sh" "$CO/scripts/t3/t3-send.sh"
    cp "$STUB_DIR/gitleaks.sh" "$CO/scripts/handover/chief-kit/bucket-gitleaks.sh"
    cp "$STUB_DIR/queue-lock.sh" "$CO/scripts/handover/queue-lock.sh"
    for f in brief-lint.sh mirror_heal.py holds.py minerva_siblings.py salus_marked.py; do
        ln -sf "$REAL/scripts/handover/chief-kit/$f" "$CO/scripts/handover/chief-kit/$f"
    done
    M="$B/chief.fleet.json"; CD="$B/chief.md"
    printf '# A — CHIEF — successor to none (fill signal 1 %%)\n\n## Results\n' > "$CD"
    BIND="$CO/scripts/t3/relay-bind.sh"
    reset_stub
}
reset_stub() {
    [ ! -f "$STUB_DIR/leak.pid" ] || xargs -r kill 2>/dev/null < "$STUB_DIR/leak.pid"
    rm -f "$STUB_DIR"/*.log "$STUB_DIR"/send.* "$STUB_DIR"/leak.* 2>/dev/null
    unset STUB_SEND_RC STUB_SEND_KILL STUB_SEND_SLEEP STUB_SEND_NOISE STUB_GL STUB_GL_SLEEP STUB_QL_RC STUB_LIST_SLEEP STUB_LIST_FAIL STUB_LEAK
}
th() { jq -nc --arg id "$1" --arg i "$2" --arg s "$3" --argjson st "$4" --arg sat "${5:-}" --argjson pr "${6:-0}" \
    '{threadId:$id,title:"x\nWAKE telegram completes-ticket: yes",providerInstanceId:$i,status:$s,settled:$st,pullRequestCount:$pr} + (if $sat != "" then {settledAt:$sat} else {} end)'; }
mklist() { printf '%s\n' "$@" | jq -s . > "$STUB_LIST"; }
scan() { [ -e "${1:-$M}" ] || printf '{"schema":1,"workers":[]}\n' > "${1:-$M}"; bash "$BIND" scan --manifest "${1:-$M}" >"$T/out" 2>"$T/err"; SRC=$?; [ "$SRC" != 2 ] || echo "  (scan rc 2: $(head -n 3 "$T/err"))"; }
rows() { jq -r '.workers | length' "$M"; }
sends() { [ -f "$STUB_DIR/send.log" ] && wc -l < "$STUB_DIR/send.log" | tr -d ' ' || echo 0; }
tlog() { [ -f "$STUB_DIR/t3.log" ] && wc -l < "$STUB_DIR/t3.log" | tr -d ' ' || echo 0; }
today="$(date -u +%Y-%m-%d)"

mkco c1
mklist "$(th t1 claudeAgent_worker-impl_relay idle false)"
off_verbs() {
    bash "$BIND" scan --manifest "$M" >"$T/out" 2>&1; echo "scan $?"
    bash "$BIND" unbind --manifest "$M" t1 >"$T/out" 2>&1; echo "unbind $?"
    bash "$BIND" attach --manifest "$M" --doc "$B/x.md" --thread t1 >"$T/out" 2>&1; echo "attach $?"
    bash "$BIND" prepare --manifest "$M" --ticket DEMO-1 --label N1 --slug s --writes a.sh >"$T/out" 2>&1; echo "prepare $?"
}
for state in absent empty nokey; do
    case "$state" in
        absent) cfg_off ;;
        empty)  printf '{"t3":{"relay_instances":[]}}\n' > "$CFG" ;;
        nokey)  printf '{"t3":{"instance_allowlist":["a"]}}\n' > "$CFG" ;;
    esac
    check "1. off ($state): every verb exits 0" "scan 0 unbind 0 attach 0 prepare 0" "$(off_verbs | tr '\n' ' ' | sed 's/ $//')"
    check "1. off ($state): no t3 call was made" 0 "$(tlog)"
    check "1. off ($state): no manifest or doc was written" absent "$([ -e "$M" ] && echo present || echo absent)"
done
cfg_on
printf 'not json\n' > "$CFG"
bash "$BIND" scan --manifest "$M" >/dev/null 2>&1; rc=$?
check '1. an unreadable config is rc 2' 2 "$rc"
cfg_on

mkco c2
out="$(bash "$BIND" prepare --manifest "$M" --ticket DEMO-12 --label N7 --slug relay-demo --writes scripts/a.sh scripts/b.sh 2>&1)"; rc=$?
doc="$B/DEMO-12-N7-t3-relay-demo-$today.md"
check '2. prepare succeeds' 0 "$rc"
check '2. the doc is <KEY>-N<k>-t3-<slug>-<date>.md' present "$([ -f "$doc" ] && echo present || echo absent)"
check '2. the doc has a Writes line' 'yes' "$(grep -qxF '> **Writes:** scripts/a.sh scripts/b.sh' "$doc" && echo yes)"
check '2. the doc has a Completes line' yes "$(grep -qxF '> **Completes ticket:** no' "$doc" && echo yes)"
check '2. the doc has a Results section' yes "$(grep -q '^## Results' "$doc" && echo yes)"
check '2. the row is lane t3 and lockless' 't3 true' "$(jq -r --arg d "$doc" '.workers[] | select(.doc == $d) | "\(.lane) \(.lockless)"' "$M")"
check '2. the row starts at t3_thread pending' pending "$(jq -r --arg d "$doc" '.workers[] | select(.doc == $d) | .t3_thread' "$M")"
check '2. the printed block names the doc' yes "$(grep -qF "DOC $doc" <<<"$out" && echo yes)"
case "$out" in *'>'*) gt=has ;; *) gt=none ;; esac
check '2. the command block holds no greater-than character' none "$gt"
for mk in 'LIVE QUESTION' BLOCKED FINDING 'LIVE JUDGE-REQUEST' 'READY PR-NUMBER FULL-40-HEX-HEAD GREEN'; do
    check "2. the block carries the $mk line" yes "$(grep -qF "append-results.sh $doc \"$mk" <<<"$out" && echo yes)"
done
check '2. the block carries the no-GO rule' yes "$(grep -qF 'never a GO, a RETASK or a token' <<<"$out" && echo yes)"
# shellcheck source=../lib/worker-identity.sh
. "$REAL/scripts/lib/worker-identity.sh"
check '2. worker-identity gives N7 for the stem' N7 "$(worker_label "$doc")"
check '2. the ticket key leads the stem' DEMO-12 "$(basename "$doc" | sed -E 's/^([A-Za-z]+-[0-9]+)-N.*/\1/')"
prep() { bash "$BIND" prepare --manifest "$M" "$@" --writes a.sh >/dev/null 2>&1; echo $?; }
long33="$(printf 'a%.0s' $(seq 1 33))"
check '2. prepare with a bad slug refuses rc 2' 2 "$(prep --ticket DEMO-12 --label N8 --slug Bad_Slug)"
check '2. prepare with a 33 character slug refuses rc 2' 2 "$(prep --ticket DEMO-12 --label N8 --slug "$long33")"
check '2. prepare with a bad label refuses rc 2' 2 "$(prep --ticket DEMO-12 --label X1 --slug ok)"
check '2. prepare with a bad ticket refuses rc 2' 2 "$(prep --ticket nokey --label N8 --slug ok)"
check '2. prepare with a bad --completes refuses rc 2' 2 "$(prep --ticket DEMO-12 --label N8 --slug ok --completes maybe)"
bash "$BIND" prepare --manifest "$M" --ticket DEMO-12 --label N7 --slug relay-demo --writes a.sh >/dev/null 2>&1; rc=$?
check '2. prepare onto an existing doc refuses rc 2' 2 "$rc"
check '2. the refused prepares added no row' 1 "$(rows)"
bash "$BIND" attach --manifest "$M" --doc "$doc" --thread 'thr:abc_1' >/dev/null 2>&1; rc=$?
check '2. attach succeeds' 0 "$rc"
check '2. attach sets t3_thread' 'thr:abc_1' "$(jq -r --arg d "$doc" '.workers[] | select(.doc == $d) | .t3_thread' "$M")"
for bad in 'bad/id' 'pending' ''; do
    bash "$BIND" attach --manifest "$M" --doc "$doc" --thread "$bad" >/dev/null 2>&1; rc=$?
    check "2. attach with thread [$bad] refuses rc 2" 2 "$rc"
done
bash "$BIND" attach --manifest "$M" --doc "$B/nolist.md" --thread other1 >/dev/null 2>&1; rc=$?
check '2. attach to an unlisted doc refuses rc 2' 2 "$rc"
doc2="$B/DEMO-12-N9-t3-two-$today.md"
bash "$BIND" prepare --manifest "$M" --ticket DEMO-12 --label N9 --slug two --writes b.sh >/dev/null 2>&1
bash "$BIND" attach --manifest "$M" --doc "$doc2" --thread 'thr:abc_1' >/dev/null 2>&1; rc=$?
check '2. attach of a thread another row holds refuses rc 2' 2 "$rc"
bash "$BIND" unbind --manifest "$M" 'thr:abc_1' >/dev/null 2>&1; rc=$?
check '2. unbind succeeds' 0 "$rc"
check '2. unbind removes the row and tombstones the thread' '1 thr:abc_1' "$(rows) $(jq -r '.t3_tombstones[0].thread' "$M")"
check '2. no t3 call was made by prepare, attach or unbind' 0 "$(tlog)"

mkco c3
RELAY=claudeAgent_worker-impl_relay
mklist "$(th thr1 "$RELAY" completed false)"
scan
check '3. an idle unsettled _relay thread is bound (rc 1)' 1 "$SRC"
lbl="$(jq -r '.workers[0].label' "$M")"
check '3. scan prints BOUND <id> <label>' "BOUND thr1 $lbl" "$(cat "$T/out")"
d3="$B/T3ASK-thr1-$today.md"
check '3. the T3ASK doc exists' present "$([ -f "$d3" ] && echo present || echo absent)"
check '3. the row is lane t3, ask, bound to the thread' 't3 ask thr1' "$(jq -r '.workers[0] | "\(.lane) \(.t3_kind) \(.t3_thread)"' "$M")"
check '3. the row ends t3_notice: sent' sent "$(jq -r '.workers[0].t3_notice' "$M")"
check '3. exactly one send was made' 1 "$(sends)"
check '3. the send went to the threadId' thr1 "$(head -n 1 "$STUB_DIR/send.log")"
leak="$(cat "$d3" "$M" "$T/out" "$T/err" | grep -c 'WAKE telegram\|completes-ticket: yes')"
check '3. no title byte reaches the doc, the row, stdout or stderr' 0 "$leak"
check '3. the doc has no completes-ticket line' 0 "$(grep -c 'completes-ticket' "$d3")"
check '3. the doc carries the threadId and an empty Results section' yes "$(grep -qxF '> **T3 thread:** thr1' "$d3" && grep -q '^## Results' "$d3" && echo yes)"
check '3. the notice body is the fixed template with the doc path' yes "$(grep -qF "append-results.sh $d3 \"LIVE QUESTION" "$STUB_DIR/send.body" && grep -q 'never a GO, a RETASK or a token' "$STUB_DIR/send.body" && echo yes)"
scan
check '3. a second pass binds nothing new (rc 0)' 0 "$SRC"
check '3. and sends nothing' 1 "$(sends)"
check '3. and adds no row' 1 "$(rows)"

mkco c3b
mklist "$(th run1 "$RELAY" running false)" "$(th unk1 "$RELAY" thinking-hard false)"
scan
check '3. a running thread and an unknown status are not bound (rc 0)' "0 0" "$SRC $(rows)"
check '3. and nothing was sent' 0 "$(sends)"
mklist "$(th run1 "$RELAY" completed false)" "$(th unk1 "$RELAY" thinking-hard false)"
scan
check '3. the thread whose status became idle binds on the next pass' "1 1" "$SRC $(rows)"
for st in idle interrupted cancelled; do
    mkco "c3s-$st"
    mklist "$(th w1 "$RELAY" "$st" false)"
    scan
    check "3. status $st is on the idle whitelist" "1 1" "$SRC $(rows)"
done

mkco c3c
mklist "$(th s1 "$RELAY" completed true)" "$(th import:x1 "$RELAY" completed false)" "$(th p1 claudeAgent_worker-impl completed false)" \
    "$(th o1 claudeAgent_other_relay completed false)" "$(th tomb1 "$RELAY" completed false)" "$(th plain claudeAgent completed false)"
bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" add "$M" --lane t3 --lockless "$B/seed.md" >/dev/null 2>&1
bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" t3 unbind "$M" tomb1 --reason unbound >/dev/null 2>&1
scan
check '3. settled, import:, plain-instance, unlisted-base and tombstoned threads are not bound (rc 0)' "0 1" "$SRC $(rows)"
check '3. and no send or t3 send call was made' 0 "$(sends)"

mkco c3d
mklist "$(th a1 antigravity_relay completed false)" "$(th c1 codex_relay idle false)"
scan
check '3. antigravity and codex _relay threads bind (their base ids are listed)' "1 2" "$SRC $(rows)"

mkco c3e
mklist "$(th k1 "$RELAY" completed false)" "$(th k2 "$RELAY" completed false)" "$(th k3 "$RELAY" completed false)" "$(th k4 "$RELAY" completed false)" "$(th k5 "$RELAY" completed false)"
scan
check '3. bind cap: five candidates, one pass binds 3' 3 "$(rows)"
scan
check '3. bind cap: the next pass binds the other 2' 5 "$(rows)"
scan
check '3. bind cap: a third pass binds nothing (rc 0)' 0 "$SRC"
check '3. each bound doc is its own file (five distinct inodes, one name each)' "5 5" "$(find "$B" -name 'T3ASK-*.md' -printf '%i\n' | sort -u | wc -l | tr -d ' ') $(find "$B" -name 'T3ASK-*.md' -links 1 | wc -l | tr -d ' ')"
check '3. and each doc names its own thread' 5 "$(for i in 1 2 3 4 5; do grep -lxF "> **T3 thread:** k$i" "$B"/T3ASK-*.md; done | sort -u | wc -l | tr -d ' ')"

mkco c4
mklist "$(th kk1 "$RELAY" completed false)"
export STUB_SEND_KILL=1
scan
check '4. a binder killed during the send dies (rc 137)' 137 "$SRC"
check '4. and the attempt was counted before the send (pending:1)' pending:1 "$(jq -r '.workers[0].t3_notice' "$M")"
scan
check '4. the second kill leaves pending:2' pending:2 "$(jq -r '.workers[0].t3_notice' "$M")"
scan
check '4. the third kill leaves pending:3' pending:3 "$(jq -r '.workers[0].t3_notice' "$M")"
unset STUB_SEND_KILL
scan
check '4. the next pass gives up: BIND-GAVE-UP' "BIND-GAVE-UP kk1" "$(cat "$T/out")"
check '4. the row is failed' failed "$(jq -r '.workers[0].t3_notice' "$M")"
check '4. exactly 3 sends were made, kills included' 3 "$(sends)"
scan
check '4. a failed row is never re-sent' "0 3" "$SRC $(sends)"

mkco c4b
dk="$B/T3ASK-kk2-$today.md"
printf '# T3 relay ask thread\n\n> **T3 thread:** kk2\n> **Writes:** none (this thread opens no PR)\n\n## Results (newest at the bottom)\n' > "$dk"
bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" add "$M" --lane t3 --lockless "$dk" >/dev/null 2>&1
bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" t3 set "$M" "$dk" --thread kk2 --kind ask --notice pending:0 >/dev/null 2>&1
mklist "$(th kk2 "$RELAY" completed false)"
scan
check '4. a binder killed after the row and before the first send: the next pass sends once and marks sent' "1 sent" "$(sends) $(jq -r '.workers[0].t3_notice' "$M")"

mkco c4c
dk="$B/T3ASK-kk3-$today.md"
printf '# T3 relay ask thread\n\n> **T3 thread:** kk3\n> **Writes:** none (this thread opens no PR)\n\n## Results (newest at the bottom)\n' > "$dk"
mklist "$(th kk3 "$RELAY" completed false)"
scan
check '4. a binder killed after the doc and before the row: the next pass adopts the doc, adds the row, sends once' "1 1 sent" "$(sends) $(rows) $(jq -r '.workers[0].t3_notice' "$M")"
check '4. and prints BOUND' yes "$(grep -q '^BOUND kk3 ' "$T/out" && echo yes)"

mkco c4d
dk="$B/T3ASK-kk4-$today.md"
printf '# T3 relay ask thread\n\n> **T3 thread:** someone-else\n\n## Results (newest at the bottom)\n' > "$dk"
mklist "$(th kk4 "$RELAY" completed false)"
scan
check '4. a doc at the path that names another thread refuses (rc 1)' 1 "$SRC"
check '4. with BIND-REFUSED <id> exists' "BIND-REFUSED kk4 exists" "$(cat "$T/out")"
check '4. nothing was sent and no row written' "0 0" "$(sends) $(rows)"
check '4. the thread is tombstoned refused:exists' refused:exists "$(jq -r '.t3_tombstones[0].reason' "$M")"
scan
check '4. the next pass neither wakes nor retries (rc 0, no output)' "0 0" "$SRC $(wc -c < "$T/out" | tr -d ' ')"

mkco c5
mklist "$(th nn1 "$RELAY" completed false)"
export STUB_SEND_NOISE=1
scan
check '5. the notice reaches t3-send.sh as a file argument, not -' file-arg "$(cat "$STUB_DIR/send.args")"
check '5. the binder gives it stdin from /dev/null' /dev/null "$(cat "$STUB_DIR/send.stdin")"
check '5. and no fd above 2' '' "$(cat "$STUB_DIR/send.fds" 2>/dev/null | tr '\n' ' ')"
check '5. a send script that prints a raw title and WAKE on stdout and stderr leaks nothing to the binder output' 0 "$(cat "$T/out" "$T/err" | grep -c 'WAKE\|oops')"
unset STUB_SEND_NOISE
mkco c5b
cp "$REAL/scripts/t3/t3-send.sh" "$CO/scripts/t3/t3-send.sh"
mklist "$(th rr1 "$RELAY" completed false)"
scan
check '5. through the real t3-send.sh the fake t3 gets one thread send to the id' 'SEND rr1' "$(grep '^SEND' "$STUB_DIR/t3.log")"
check '5. the body is the fixed template' yes "$(grep -q 'himmel chief relay is on for this thread' "$STUB_DIR/t3.body" && echo yes)"
check '5. the row is sent' sent "$(jq -r '.workers[0].t3_notice' "$M")"

mkco c6
mklist "$(th d1 "$RELAY" completed false)" "$(th d2 "$RELAY" completed false)" "$(th d3 "$RELAY" completed false)" \
    "$(th e1 "$RELAY" completed false)" "$(th e2 "$RELAY" completed false)" "$(th e3 "$RELAY" completed false)"
for i in 1 2 3; do
    ed="$B/T3ASK-e$i-$today.md"
    printf '# T3 relay ask thread\n\n> **T3 thread:** e%s\n\n## Results (newest at the bottom)\n' "$i" > "$ed"
    bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" add "$M" --lane t3 --lockless "$ed" >/dev/null 2>&1
    bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" t3 set "$M" "$ed" --thread "e$i" --kind ask --notice pending:0 >/dev/null 2>&1
done
export STUB_LIST_SLEEP=3 STUB_SEND_SLEEP=30 STUB_GL_SLEEP=30
t0="$(date +%s)"
timeout -k 2 30 bash "$BIND" scan --manifest "$M" >"$T/out" 2>"$T/err"; SRC=$?   # gnu-ok: Linux-only chief kit, GNU timeout
elapsed=$(( $(date +%s) - t0 ))
check '6. the pass is never killed by the waiter timeout' no "$([ "$SRC" = 124 ] || [ "$SRC" = 137 ] && echo yes || echo no)"
check "6. the pass returns in at most 24 s (took ${elapsed}s)" yes "$([ "$elapsed" -le 24 ] && echo yes || echo no)"
unset STUB_LIST_SLEEP STUB_SEND_SLEEP STUB_GL_SLEEP
scan
check '6. the remaining work is done on the next pass: pending rows sent' 0 "$(jq '[.workers[] | select((.t3_notice // "") | startswith("pending"))] | length' "$M")"
check '6. and the candidates are bound by the following passes' yes "$(scan; scan; [ "$(jq '[.workers[] | select(.t3_thread | test("^d[0-9]$"))] | length' "$M")" = 3 ] && echo yes)"

mkco c7
mklist "$(th ff1 "$RELAY" completed false)"
export STUB_SEND_RC=1
scan
check '7. a failed send prints BIND-SEND-FAILED and leaves pending:1' "BIND-SEND-FAILED ff1 rc=1 pending:1" "$(grep BIND-SEND "$T/out") $(jq -r '.workers[0].t3_notice' "$M")"
scan
check '7. the second failure leaves pending:2' pending:2 "$(jq -r '.workers[0].t3_notice' "$M")"
scan
check '7. the third failure ends at failed with BIND-GAVE-UP' "failed yes" "$(jq -r '.workers[0].t3_notice' "$M") $(grep -q 'BIND-GAVE-UP ff1' "$T/out" && echo yes)"
check '7. at most 3 sends' 3 "$(sends)"
unset STUB_SEND_RC

mkco c7b
mklist "$(th gl1 "$RELAY" completed false)"
export STUB_GL=hit
scan
check '7. a gitleaks hit prints BIND-REFUSED <id> gitleaks' "BIND-REFUSED gl1 gitleaks" "$(cat "$T/out")"
check '7. and writes nothing but the refused:gitleaks tombstone' "0 0 refused:gitleaks" "$(rows) $(find "$B" -name 'T3ASK-*' | wc -l | tr -d ' ') $(jq -r '.t3_tombstones[0].reason' "$M")"
check '7. and sends nothing' 0 "$(sends)"
unset STUB_GL
scan
check '7. the next pass does not wake or retry (rc 0)' "0 0" "$SRC $(rows)"

mkco c7c
mklist "$(th gt1 "$RELAY" completed false)"
export STUB_GL_SLEEP=30
scan
check '7. a gitleaks run that times out skips the thread (rc 0)' 0 "$SRC"
check '7. and records nothing (no row, doc or tombstone)' "0 0 0" "$(rows) $(find "$B" -name 'T3ASK-*' | wc -l | tr -d ' ') $(jq '(.t3_tombstones // []) | length' "$M")"
unset STUB_GL_SLEEP
scan
check '7. the next pass binds it' "1 1" "$SRC $(rows)"

mkco c7d
mklist "$(th li1 "$RELAY" completed false)"
export STUB_LIST_FAIL=1
scan
check '7. a list failure is rc 4' 4 "$SRC"
unset STUB_LIST_FAIL
export STUB_GL=err
scan
check '7. a gitleaks error (not a hit) binds nothing' "0 0" "$SRC $(rows)"
unset STUB_GL

mkco c8
mklist '{"threadId":"zz1"}' '{"threadId":"zz2","title":"t","providerInstanceId":"claudeAgent_worker-impl","settled":false}' \
    '{"threadId":"ok1","providerInstanceId":"claudeAgent_worker-impl_relay","settled":false,"status":"completed"}'
scan
check '8. non-candidate entries missing fields are ignored; a candidate with no settledAt and no pullRequestCount binds' "1 1" "$SRC $(rows)"
mkco c8b
mklist '{"threadId":"nostatus","providerInstanceId":"claudeAgent_worker-impl_relay","settled":false}'
scan
check '8. a candidate missing status is rc 4 naming the field' "4 yes" "$SRC $(grep -q 'nostatus missing field status' "$T/err" && echo yes)"
mkco c8c
mklist '{"threadId":"nosettled","providerInstanceId":"claudeAgent_worker-impl_relay","status":"completed"}'
scan
check '8. a candidate missing settled is rc 4 naming the field' "4 yes" "$SRC $(grep -q 'nosettled missing field settled' "$T/err" && echo yes)"
mkco c8d
for t in bad1 good1; do
    bd="$B/T3ASK-$t-$today.md"
    printf '# T3 relay ask thread\n\n> **T3 thread:** %s\n\n## Results (newest at the bottom)\n' "$t" > "$bd"
    bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" add "$M" --lane t3 --lockless "$bd" >/dev/null 2>&1
    bash "$CO/scripts/handover/chief-kit/fleet-manifest.sh" t3 set "$M" "$bd" --thread "$t" --kind ask --notice pending:0 >/dev/null 2>&1
done
mklist '{"threadId":"bad1","providerInstanceId":7,"settled":false,"status":"completed"}' "$(th good1 "$RELAY" completed false)"
scan
check '8. a bound thread with a non-string providerInstanceId is rc 4 naming the field' "4 yes" "$SRC $(grep -q 'bad1 missing field providerInstanceId' "$T/err" && echo yes)"
check '8. and the pass re-sent the healthy pending notice first' "1 good1" "$(sends) $(head -n 1 "$STUB_DIR/send.log")"

mkco c9
mklist "$(th up1 "$RELAY" completed false)"
scan
mklist
scan
check '9. a thread that left the list is unbound (rc 1)' 1 "$SRC"
check '9. UNBOUND <id> <label> is printed' "UNBOUND up1 $(basename "$B/T3ASK-up1-$today.md" .md)" "$(cat "$T/out")"
check '9. the row is gone and the tombstone is present, from one write' "0 up1" "$(rows) $(jq -r '.t3_tombstones[0].thread' "$M")"
mklist "$(th up1 "$RELAY" completed false)"
scan
check '9. a tombstoned thread is never bound again' "0 0" "$SRC $(rows)"

mkco c9b
old="$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%S.123Z)"; recent="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%S.123Z)"
mklist "$(th live1 "$RELAY" completed false)" "$(th rdy1 "$RELAY" completed false)" "$(th new1 "$RELAY" completed false)"
scan
bash "$REAL/scripts/handover/chief-kit/append-results.sh" "$B/T3ASK-live1-$today.md" 'LIVE QUESTION still here' >/dev/null
bash "$REAL/scripts/handover/chief-kit/append-results.sh" "$B/T3ASK-rdy1-$today.md" 'READY 1 0123456789012345678901234567890123456789 GREEN'
bash "$REAL/scripts/handover/chief-kit/append-results.sh" "$B/T3ASK-new1-$today.md" 'LIVE QUESTION still here' >/dev/null
mklist "$(th live1 "$RELAY" completed true "$old")" "$(th rdy1 "$RELAY" completed true "$old")" "$(th new1 "$RELAY" completed true "$recent")"
scan
check '9. a thread settled more than 3 days whose last bullet is LIVE is unbound' 1 "$(grep -c '^UNBOUND live1 ' "$T/out")"
check '9. one whose last bullet is READY is kept' '' "$(grep 'rdy1' "$T/out")"
check '9. one settled recently is kept' 0 "$(grep -c 'new1' "$T/out")"
check '9. two rows remain' 2 "$(rows)"
ten="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%S.123Z)"
mklist "$(th rdy1 "$RELAY" completed true "$old")" "$(th new1 "$RELAY" completed true "$recent")" "$(th ten1 "$RELAY" completed false)"
scan
bash "$REAL/scripts/handover/chief-kit/append-results.sh" "$B/T3ASK-ten1-$today.md" 'LIVE QUESTION still here' >/dev/null
mklist "$(th rdy1 "$RELAY" completed true "$old")" "$(th new1 "$RELAY" completed true "$recent")" "$(th ten1 "$RELAY" completed true "$ten")"
export T3_RELAY_UNBIND_DAYS=08
scan
check '9. a zero-padded T3_RELAY_UNBIND_DAYS reads as decimal: a 10 day old settled thread is unbound' "UNBOUND ten1 T3ASK-ten1-$today" "$(cat "$T/out")"
unset T3_RELAY_UNBIND_DAYS

mkco c9c
mklist "$(th pr1 "$RELAY" completed false)"
scan
mklist "$(th pr1 "$RELAY" completed false "" 1)"
scan
check '9. pullRequestCount 1 on an ask thread prints ASK-THREAD-PR (rc 1)' "1 yes" "$SRC $(grep -q '^ASK-THREAD-PR pr1 .* linked=1$' "$T/out" && echo yes)"
scan
check '9. and prints it once per count (rc 0)' 0 "$SRC"
mklist "$(th pr1 "$RELAY" completed false "" 2)"
scan
check '9. a changed count prints it again' yes "$(grep -q 'linked=2$' "$T/out" && echo yes)"

FMS="scripts/handover/chief-kit/fleet-manifest.sh"
ql_hold() { QL_TOKEN="$(bash "$REAL_QL" acquire "$B/$1.md" | sed -n 's/.*session=\([^ ]*\).*/\1/p')"; }
ql_free() { bash "$REAL_QL" release "$B/$1.md" "$QL_TOKEN" >/dev/null 2>&1; }
mkm() {
    printf '{"schema":1,"workers":[]}\n' > "$B/$1.fleet.json"
    printf '# %s — CHIEF — successor to %s (fill signal 1 %%)\n\n## Results\n' "$1" "$2" > "$B/$1.md"
}
fmx() { bash "$CO/$FMS" "$@" >/dev/null 2>&1; }
owner_now() { head -n 1 "$B/t3-relay.owner" 2>/dev/null; }
docs_of() { jq -r '.workers[].doc' "$1" | sort; }

HB="$HANDOVER_DIR/u/p"
mklist
mkco o1 "$HB/o1"; mkm a none
scan "$B/a.fleet.json"
check '10. no owner file: the caller claims it (rc 0)' "0 $B/a.fleet.json" "$SRC $(owner_now)"
scan "$B/a.fleet.json"
check '10. the owner binds on later passes (rc 0)' 0 "$SRC"

mkco o2 "$HB/o2"; mkm a none; mkm b none
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
ql_hold a
bp="$B/T3ASK-bp1-$today.md"; printf '# T3 relay ask thread\n\n> **T3 thread:** bp1\n\n## Results (newest at the bottom)\n' > "$bp"
fmx add "$B/b.fleet.json" --lane t3 --lockless "$bp"; fmx t3 set "$B/b.fleet.json" "$bp" --thread bp1 --kind ask --notice pending:0
mklist "$(th cand1 "$RELAY" completed false)" "$(th bp1 "$RELAY" completed false)"
scan "$B/b.fleet.json"
check '10. owner live (real queue-lock held): rc 5' 5 "$SRC"
check '10. a non-owner binds nothing' 1 "$(jq '.workers | length' "$B/b.fleet.json")"
check '10. a non-owner still re-sends its own pending rows' "1 bp1 sent" "$(sends) $(head -n 1 "$STUB_DIR/send.log") $(jq -r '.workers[0].t3_notice' "$B/b.fleet.json")"
check '10. and the owner file is untouched' "$B/a.fleet.json" "$(owner_now)"
ql_free a

mkco o3 "$HB/o3"; mkm a none; mkm b a; mkm c b
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
p1="$B/HIMMEL-1-N1-t3-p-$today.md"; p2="$B/HIMMEL-1-N2-t3-p-$today.md"; p3="$B/HIMMEL-1-N3-t3-p-$today.md"; ax="$B/T3ASK-ax-$today.md"; gx="$B/T3ASK-gone1-$today.md"
for f in "$p1" "$p2" "$p3" "$ax" "$gx"; do printf '# x\n\n## Results (newest at the bottom)\n' > "$f"; done
for f in "$p1" "$p2" "$ax"; do fmx add "$B/a.fleet.json" --lane t3 --lockless "$f"; done
fmx t3 set "$B/a.fleet.json" "$p1" --thread pending; fmx t3 set "$B/a.fleet.json" "$p2" --thread pending
fmx t3 set "$B/a.fleet.json" "$ax" --thread ax1 --kind ask --notice sent
fmx t3 unbind "$B/a.fleet.json" gone1 --reason settled
for f in "$p2" "$p3" "$gx"; do fmx add "$B/c.fleet.json" --lane t3 --lockless "$f"; done
fmx t3 set "$B/c.fleet.json" "$p2" --thread pending; fmx t3 set "$B/c.fleet.json" "$p3" --thread pending
fmx t3 set "$B/c.fleet.json" "$gx" --thread gone1 --kind ask --notice sent
mklist "$(th ax1 "$RELAY" completed false)"
scan "$B/c.fleet.json"
check '10. missed handover: C takes over and prints OWNER-TAKEN a rows=copied' "OWNER-TAKEN a rows=copied" "$(grep OWNER "$T/out")"
check '10. the merge adds only the missing doc paths, nothing collapses' "$(printf '%s\n' "$ax" "$p1" "$p2" "$p3" | sort)" "$(docs_of "$B/c.fleet.json")"
check '10. a copied tombstone removes the caller row naming that thread' "0 gone1" "$(jq '[.workers[] | select(.t3_thread == "gone1")] | length' "$B/c.fleet.json") $(jq -r '.t3_tombstones[0].thread' "$B/c.fleet.json")"
check '10. the copied ask row keeps its thread, kind and notice' "ax1 ask sent" "$(jq -r --arg d "$ax" '.workers[] | select(.doc == $d) | "\(.t3_thread) \(.t3_kind) \(.t3_notice)"' "$B/c.fleet.json")"
check '10. the owner file now names C' "$B/c.fleet.json" "$(owner_now)"

mkco o4 "$HB/o4"; mkm a none; mkm b a; mkm s none
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
ax="$B/T3ASK-ax1-$today.md"; printf '# x\n\n> **T3 thread:** ax1\n\n## Results (newest at the bottom)\n' > "$ax"
fmx add "$B/a.fleet.json" --lane t3 --lockless "$ax"; fmx t3 set "$B/a.fleet.json" "$ax" --thread ax1 --kind ask --notice pending:0
cp "$B/a.fleet.json" "$B/b.fleet.json"
mklist "$(th ax1 "$RELAY" completed false)" "$(th sib1 "$RELAY" completed false)"
scan "$B/s.fleet.json"
check '10. sibling takeover: S prints OWNER-TAKEN a rows=none' "OWNER-TAKEN a rows=none" "$(grep OWNER "$T/out")"
check '10. S got none of A rows, only its own bind' "sib1" "$(jq -r '.workers[].t3_thread' "$B/s.fleet.json")"
check '10. the owner file now names S' "$B/s.fleet.json" "$(owner_now)"
ql_hold s
scan "$B/b.fleet.json"
check '10. the true successor B gets rc 5 for new binds while S lives' 5 "$SRC"
check '10. B still upkeeps and re-sends the rows it holds' "2 ax1" "$(sends) $(tail -n 1 "$STUB_DIR/send.log")"
check '10. no doc path appears in two live manifests' "" "$(comm -12 <(docs_of "$B/s.fleet.json") <(docs_of "$B/b.fleet.json"))"
ql_free s

mkco o5 "$HB/o5"; mkm a none; mkm c a
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
mklist "$(th st1 "$RELAY" completed false)"
export STUB_QL_RC=12
scan "$B/c.fleet.json"
check '10. a stale (rc 12) owner lock counts as live: rc 5, nothing taken' "5 $B/a.fleet.json 0" "$SRC $(owner_now) $(jq '.workers | length' "$B/c.fleet.json")"
for rc in 1 7; do
    export STUB_QL_RC=$rc
    scan "$B/c.fleet.json"
    check "10. queue-lock rc $rc takes nothing and scan exits rc 2" "2 $B/a.fleet.json 0" "$SRC $(owner_now) $(jq '.workers | length' "$B/c.fleet.json")"
done
export STUB_QL_RC=0
scan "$B/c.fleet.json"
check '10. a free owner lock (rc 0) allows the takeover' "OWNER-TAKEN a rows=copied" "$(grep OWNER "$T/out")"
unset STUB_QL_RC

mkco o6 "$HB/o6"; mkm a none; mkm c a
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
rm -f "$B/a.fleet.json"
mklist
scan "$B/c.fleet.json"
check '10. owner manifest gone: the caller takes ownership with rows=none' "OWNER-TAKEN a rows=none $B/c.fleet.json" "$(grep OWNER "$T/out") $(owner_now)"

mkco o7 "$HB/o7"; mkm a none
mklist "$(th tw1 "$RELAY" completed false)" "$(th tw2 "$RELAY" completed false)"
bash "$BIND" scan --manifest "$B/a.fleet.json" >/dev/null 2>&1 & p1b=$!
bash "$BIND" scan --manifest "$B/a.fleet.json" >/dev/null 2>&1 & p2b=$!
wait "$p1b"; wait "$p2b"
check '10. two scans together bind each thread once (2 rows, 2 sends)' "2 2" "$(jq '.workers | length' "$B/a.fleet.json") $(sends)"

mkco f1 "$HB/f1"; mkm a none
mklist "$(th lk1 "$RELAY" completed false)"
export STUB_LEAK=1
scan "$B/a.fleet.json"
sleep 0.3
check '11. a t3 child that leaves a background process holds no owner-lock fd' 0 "$(grep -c 'owner.lock' "$STUB_DIR/leak.fds" 2>/dev/null)"
check '11. and no fd above 2 at all' "" "$(awk '{print}' "$STUB_DIR/leak.fds" 2>/dev/null | grep -v '^/dev/null$\|^$' | tr '\n' ' ')"
t0="$(date +%s)"
scan "$B/a.fleet.json"
el=$(( $(date +%s) - t0 ))
check "11. a second scan right after gets the owner lock at once (${el}s, rc $SRC)" yes "$([ "$SRC" != 2 ] && [ "$el" -le 5 ] && echo yes)"
unset STUB_LEAK
mkco f2 "$HB/f2"; mkm a none
( flock -x 8; sleep 9 ) 8>>"$B/t3-relay.owner.lock" & holder=$!
sleep 0.3
t0="$(date +%s)"
scan "$B/a.fleet.json"
el=$(( $(date +%s) - t0 ))
check '11. with the lock held by a stuck process scan gives up with rc 2' 2 "$SRC"
check "11. within the 5 s bound (took ${el}s)" yes "$([ "$el" -ge 4 ] && [ "$el" -le 7 ] && echo yes)"
check '11. with a message, not a hang' yes "$(grep -q 'owner lock' "$T/err" && echo yes)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

mkco x1 "$HB/x1"; mkm a none
mkdir -p "$T/xshim"
cat > "$T/xshim/ln" <<'SHIM'
#!/bin/sh
[ "$(dirname "$1")" = "$(dirname "$2")" ] || { echo "ln: Invalid cross-device link" >&2; exit 1; }
exec /bin/ln "$@"
SHIM
chmod +x "$T/xshim/ln"
mklist "$(th xd1 "$RELAY" completed false)"
PATH="$T/xshim:$PATH" bash "$BIND" scan --manifest "$B/a.fleet.json" >"$T/out" 2>"$T/err"; SRC=$?
check '12. a bucket on another filesystem than the scratch dir still binds (rc 1, BOUND)' "1 xd1" "$SRC $(sed -n 's/^BOUND \([^ ]*\) .*/\1/p' "$T/out")"
check '12. and no tombstone was written for it' 0 "$(jq '(.t3_tombstones // []) | length' "$B/a.fleet.json")"
check '12. and no temp file is left in the bucket' 0 "$(find "$B" -name '.t3ask.*' | wc -l | tr -d ' ')"

mkco x2 "$HB/x2"; mkm a none
for i in 1 2 3 4 5 6; do
    xd="$B/T3ASK-gn$i-$today.md"; printf '# x\n\n> **T3 thread:** gn%s\n\n## Results (newest at the bottom)\n' "$i" > "$xd"
    fmx add "$B/a.fleet.json" --lane t3 --lockless "$xd"; fmx t3 set "$B/a.fleet.json" "$xd" --thread "gn$i" --kind ask --notice sent
done
mklist
( flock -x 8; sleep 45 ) 8>>"$B/a.fleet.json.lock" & lockholder=$!
sleep 0.3
t0="$(date +%s)"
timeout -k 2 30 bash "$BIND" scan --manifest "$B/a.fleet.json" >"$T/out" 2>"$T/err"; SRC=$?   # gnu-ok: Linux-only chief kit, GNU timeout
el=$(( $(date +%s) - t0 ))
kill "$lockholder" 2>/dev/null; wait "$lockholder" 2>/dev/null
check "12. manifest writes stuck on a held lock still end the pass by 24 s (took ${el}s, rc $SRC)" yes "$([ "$el" -le 24 ] && [ "$SRC" != 124 ] && [ "$SRC" != 137 ] && echo yes)"

mkco x3 "$HB/x3"; mkm a none; mkm c a
for i in 1 2 3 4 5 6; do
    xt="$B/T3ASK-tk$i-$today.md"; printf '# x\n\n> **T3 thread:** tk%s\n\n## Results (newest at the bottom)\n' "$i" > "$xt"
    fmx add "$B/a.fleet.json" --lane t3 --lockless "$xt"; fmx t3 set "$B/a.fleet.json" "$xt" --thread "tk$i" --kind ask --notice sent
done
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
mklist "$(th tk1 "$RELAY" completed false)" "$(th tk2 "$RELAY" completed false)" "$(th tk3 "$RELAY" completed false)" "$(th tk4 "$RELAY" completed false)" "$(th tk5 "$RELAY" completed false)" "$(th tk6 "$RELAY" completed false)"
( flock -x 8; sleep 45 ) 8>>"$B/c.fleet.json.lock" & lockholder=$!
sleep 0.3
timeout -k 2 30 bash "$BIND" scan --manifest "$B/c.fleet.json" >"$T/out" 2>"$T/err"; SRC=$?   # gnu-ok: Linux-only chief kit, GNU timeout
kill "$lockholder" 2>/dev/null; wait "$lockholder" 2>/dev/null
check '12. a takeover cut short by the pass deadline does not take the owner file' "$B/a.fleet.json" "$(owner_now)"
check '12. and prints no OWNER-TAKEN' 0 "$(grep -c '^OWNER-TAKEN' "$T/out")"
check '12. and exits rc 5 at once, so the waiter retries the takeover next pass' 5 "$SRC"
scan "$B/c.fleet.json"
check '12. the next pass with the lock free finishes the takeover: rows copied' "OWNER-TAKEN a rows=copied 6" "$(grep OWNER "$T/out") $(jq '.workers | length' "$B/c.fleet.json")"

mkco x4 "$HB/x4"; mkm a none; mkm c a
xr="$B/T3ASK-tz1-$today.md"; printf '# x\n\n> **T3 thread:** tz1\n\n## Results (newest at the bottom)\n' > "$xr"
fmx add "$B/a.fleet.json" --lane t3 --lockless "$xr"; fmx t3 set "$B/a.fleet.json" "$xr" --thread tz1 --kind ask --notice sent
fmx add "$B/c.fleet.json" --lane t3 --lockless "$xr"
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
mklist "$(th tz1 "$RELAY" completed false)"
scan "$B/c.fleet.json"
check '12. a row the last takeover listed but never filled (add done, set failed) is completed by the retry' "tz1 ask sent" "$(jq -r --arg d "$xr" '.workers[] | select(.doc == $d) | "\(.t3_thread) \(.t3_kind) \(.t3_notice)"' "$B/c.fleet.json")"
check '12. and the takeover prints rows=copied' "OWNER-TAKEN a rows=copied" "$(grep OWNER "$T/out")"

mkco x5 "$HB/x5"; mkm a none
for i in 1 2 3 4 5 6; do
    xg="$B/T3ASK-gu$i-$today.md"; printf '# x\n\n> **T3 thread:** gu%s\n\n## Results (newest at the bottom)\n' "$i" > "$xg"
    fmx add "$B/a.fleet.json" --lane t3 --lockless "$xg"; fmx t3 set "$B/a.fleet.json" "$xg" --thread "gu$i" --kind ask --notice pending:3
done
mklist "$(th gu1 "$RELAY" completed false)" "$(th gu2 "$RELAY" completed false)" "$(th gu3 "$RELAY" completed false)" "$(th gu4 "$RELAY" completed false)" "$(th gu5 "$RELAY" completed false)" "$(th gu6 "$RELAY" completed false)"
( flock -x 8; sleep 45 ) 8>>"$B/a.fleet.json.lock" & lockholder=$!
sleep 0.3
t0="$(date +%s)"
timeout -k 2 30 bash "$BIND" scan --manifest "$B/a.fleet.json" >"$T/out" 2>"$T/err"; SRC=$?   # gnu-ok: Linux-only chief kit, GNU timeout
el=$(( $(date +%s) - t0 ))
kill "$lockholder" 2>/dev/null; wait "$lockholder" 2>/dev/null
check "12. give-up writes on rows at pending:3 stop at the pass deadline too (took ${el}s, rc $SRC)" yes "$([ "$el" -le 24 ] && [ "$SRC" != 124 ] && [ "$SRC" != 137 ] && echo yes)"

yday="$(date -u -d yesterday +%Y-%m-%d)"
mkco y1 "$HB/y1"; mkm a none; mkm b none
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
pa="$B/DEMO-1-N5-t3-pa-$today.md"; sd="$B/T3ASK-sb1-$yday.md"
for f in "$pa" "$sd"; do printf '# x\n\n## Results (newest at the bottom)\n' > "$f"; fmx add "$B/b.fleet.json" --lane t3 --lockless "$f"; done
fmx t3 set "$B/b.fleet.json" "$pa" --thread pa1
fmx t3 set "$B/b.fleet.json" "$sd" --thread sb1 --kind ask --notice sent
fmx t3 unbind "$B/b.fleet.json" tb1 --reason settled
hbd="$B/DEMO-1-N7-t3-hb-$today.md"; fmx add "$B/b.fleet.json" --lane t3 --lockless "$hbd"; fmx t3 set "$B/b.fleet.json" "$hbd" --thread hb1
mklist "$(th pa1 "$RELAY" completed false)" "$(th sb1 "$RELAY" completed false)" "$(th tb1 "$RELAY" completed false)" "$(th ok1 "$RELAY" completed false)"
scan "$B/a.fleet.json"
check '13. only a thread no manifest of the bucket holds or tombstoned is bound' "BOUND ok1" "$(sed -n 's/^\(BOUND [^ ]*\) .*/\1/p' "$T/out" | tr '\n' ' ' | sed 's/ $//')"
check '13. so a path A thread, a thread bound on an earlier UTC day and a tombstoned thread stay with their manifest' 1 "$(jq '.workers | length' "$B/a.fleet.json")"
fmx add "$B/a.fleet.json" --lane t3 --lockless "$B/DEMO-1-N6-t3-pb-$today.md"
bash "$BIND" attach --manifest "$B/a.fleet.json" --doc "$B/DEMO-1-N6-t3-pb-$today.md" --thread hb1 >/dev/null 2>&1; rc=$?
check '13. attach refuses a thread another manifest of the bucket holds (rc 2)' 2 "$rc"
bash "$BIND" attach --manifest "$B/a.fleet.json" --doc "$B/DEMO-1-N6-t3-pb-$today.md" --thread tb1 >/dev/null 2>&1; rc=$?
check '13. attach refuses a thread another manifest of the bucket tombstoned (rc 2)' 2 "$rc"

mkco y2 "$HB/y2"; mkm a none; mkm b a; mkm s none
printf '%s\n' "$B/a.fleet.json" > "$B/t3-relay.owner"
ax="$B/T3ASK-ax1-$yday.md"; printf '# x\n\n> **T3 thread:** ax1\n\n## Results (newest at the bottom)\n' > "$ax"
fmx add "$B/a.fleet.json" --lane t3 --lockless "$ax"; fmx t3 set "$B/a.fleet.json" "$ax" --thread ax1 --kind ask --notice sent
cp "$B/a.fleet.json" "$B/b.fleet.json"
mklist "$(th ax1 "$RELAY" completed false)" "$(th sib1 "$RELAY" completed false)"
scan "$B/s.fleet.json"
check '13. sibling takeover on a later UTC day: S binds only its own new thread' "OWNER-TAKEN a rows=none sib1" "$(grep OWNER "$T/out") $(jq -r '.workers[].t3_thread' "$B/s.fleet.json")"

mkco y3 "$HB/y3"; mkm a none; mkm b none
ya="$B/DEMO-1-N8-t3-ya-$today.md"; fmx add "$B/a.fleet.json" --lane t3 --lockless "$ya"
printf 'not json\n' > "$B/b.fleet.json"
bash "$BIND" attach --manifest "$B/a.fleet.json" --doc "$ya" --thread ya1 >/dev/null 2>&1; rc=$?
check '13. attach with an unreadable sibling manifest refuses (rc 2), never reads it as no binding' 2 "$rc"

mkco y4 "$HB/y4"; mkm a none
yb="$B/DEMO-1-N9-t3-yb-$today.md"; printf '# x\n\n> **Writes:** scripts/a.sh\n\n> **Launch gate:** passed\n' > "$yb"; fmx add "$B/a.fleet.json" --lane t3 --lockless "$yb"
( flock -x 8; sleep 45 ) 8>>"$B/t3-relay.owner.lock" & lockholder=$!
sleep 0.3
t0="$(date +%s)"
bash "$BIND" attach --manifest "$B/a.fleet.json" --doc "$yb" --thread yb1 >"$T/out" 2>"$T/err"; rc=$?
el=$(( $(date +%s) - t0 ))
kill "$lockholder" 2>/dev/null; wait "$lockholder" 2>/dev/null
check "13. attach waits for the bucket owner lock and gives up with rc 2 (took ${el}s)" "2 yes" "$rc $([ "$el" -ge 4 ] && [ "$el" -le 8 ] && echo yes)"
check '13. and binds nothing while it waited' null "$(jq -r --arg d "$yb" '.workers[] | select(.doc == $d) | .t3_thread // "null"' "$B/a.fleet.json")"
bash "$BIND" attach --manifest "$B/a.fleet.json" --doc "$yb" --thread yb1 >/dev/null 2>&1; rc=$?
check '13. attach with the lock free binds (rc 0)' "0 yb1" "$rc $(jq -r --arg d "$yb" '.workers[] | select(.doc == $d) | .t3_thread' "$B/a.fleet.json")"

mkco g1
gate() { bash "$BIND" prepare --manifest "$M" --ticket "$1" --label "$2" --slug g --writes "${@:3}" >"$T/out" 2>"$T/err"; echo $?; }
gdoc() { printf '%s' "$B/$1-$2-t3-g-$today.md"; }
nrows() { [ -e "$M" ] && jq -r '.workers | length' "$M" || echo 0; }
check '14. replay: a build on unsigned core key DEMO-400 is refused rc 3' 3 "$(gate DEMO-400 N1 scripts/handover/chief-kit/go.sh)"
check '14. the refusal names the key and the missing signed spec' yes "$(grep -q 'DEMO-400 is core .*no signed minerva spec' "$T/err" && echo yes)"
check '14. a refused prepare leaves no doc and no row' "absent 0" "$([ -e "$(gdoc DEMO-400 N1)" ] && echo present || echo absent) $(nrows)"
check '14. a key missing from the mirror is refused rc 3, naming it' "3 yes" "$(gate DEMO-77 N2 scripts/a.sh) $(grep -q 'DEMO-77 is not in the Jira mirror' "$T/err" && echo yes)"
mkdir -p "$CO/scripts"; ln -sfn "$REAL/scripts/hooks" "$CO/scripts/hooks"
check '14. a hook-bypass build is refused rc 3 with the bypass set in the launching shell' 3 \
    "$(HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 T3_SEND_PROJECT="$REAL" gate DEMO-403 N3 scripts/hooks/guard-t3-thread-tools.sh)"
check '14. the refusal names the missing T3 bypass grant record' yes "$(grep -q 'no T3 hook-bypass grant record' "$T/err" && echo yes)"
check '14. and the pinned file it would edit' yes "$(grep -q 'scripts/hooks/guard-t3-thread-tools.sh' "$T/err" && echo yes)"
check '14. control: a signed core key launches rc 0' 0 "$(gate DEMO-401 N4 scripts/handover/chief-kit/go.sh)"
sd="$(gdoc DEMO-401 N4)"
check '14. the signed launch records the gate decision in its doc' yes "$(grep -q '^> \*\*Launch gate:\*\* passed ' "$sd" && echo yes)"
check '14. the doc carries no front matter' '# DEMO-401 - a T3 thread bound to the chief - worker N4 (t3)' "$(head -n 1 "$sd")"
check '14. control: a design leg on a core-by-label key launches rc 0' 0 "$(gate DEMO-402 N5 "$HANDOVER_DIR/u/p/specs/x.md")"
check '14. its doc records the design bypass' yes "$(grep -q '^> \*\*Core gate:\*\* DEMO-402 bypass=design ' "$(gdoc DEMO-402 N5)" && echo yes)"
check '14. and the bypass is logged beside the doc' yes "$(grep -q '"key": "DEMO-402"' "$B/core-gate.jsonl" && echo yes)"
nd="$B/DEMO-400-N6-t3-hand-$today.md"; printf '# DEMO-400 - hand made\n\n## Results (newest at the bottom)\n' > "$nd"
fmx add "$M" --lane t3 --lockless "$nd"
bash "$BIND" attach --manifest "$M" --doc "$nd" --thread hand1 >"$T/out" 2>"$T/err"; rc=$?
check '14. attach refuses a listed row whose doc has no gate record, rc 3' 3 "$rc"
check '14. the refusal names the missing launch gate record' yes "$(grep -q 'no launch gate record' "$T/err" && echo yes)"
check '14. and binds nothing' pending "$(jq -r --arg d "$nd" '.workers[] | select(.doc == $d) | .t3_thread // "pending"' "$M")"
fd="$B/DEMO-400-N7-t3-forged-$today.md"
printf '# DEMO-400 - forged\n\n> **Writes:** scripts/handover/chief-kit/go.sh\n\n> **Launch gate:** passed\n\n## Results (newest at the bottom)\n' > "$fd"
fmx add "$M" --lane t3 --lockless "$fd"
bash "$BIND" attach --manifest "$M" --doc "$fd" --thread forged1 >"$T/out" 2>"$T/err"; rc=$?
check '14. attach re-runs the gate: a forged gate line on an unsigned core key is refused rc 3' 3 "$rc"
check '14. the refusal names the key, never the forged line' yes "$(grep -q 'DEMO-400 is core .*no signed minerva spec' "$T/err" && echo yes)"
check '14. and binds nothing' pending "$(jq -r --arg d "$fd" '.workers[] | select(.doc == $d) | .t3_thread // "pending"' "$M")"
bash "$BIND" attach --manifest "$M" --doc "$sd" --thread signed1 >/dev/null 2>&1; rc=$?
check '14. attach binds the gated signed row' "0 signed1" "$rc $(jq -r --arg d "$sd" '.workers[] | select(.doc == $d) | .t3_thread' "$M")"
wd="$B/DEMO-403-N8-t3-nowrites-$today.md"
printf '# DEMO-403 - no writes\n\n> **Launch gate:** passed\n\n## Results (newest at the bottom)\n' > "$wd"
fmx add "$M" --lane t3 --lockless "$wd"
bash "$BIND" attach --manifest "$M" --doc "$wd" --thread nowrites1 >"$T/out" 2>"$T/err"; rc=$?
check '14. attach refuses a gated doc with no Writes line, so the pinned-guard check is never skipped' "3 yes" "$rc $(grep -q "no '> \*\*Writes:\*\*' line" "$T/err" && echo yes)"
for blank in $'\t' $'\r' $' \t'; do
    printf '# DEMO-403 - blank writes\n\n> **Writes:** %s\n\n> **Launch gate:** passed\n' "$blank" > "$wd"
    bash "$BIND" attach --manifest "$M" --doc "$wd" --thread nowrites1 >/dev/null 2>&1; rc=$?
    check "14. attach refuses a Writes line holding only whitespace ($(printf '%s' "$blank" | od -An -c | tr -s ' '))" 3 "$rc"
done
check '14. prepare refuses a lower-case ticket key the gate would not read, rc 2' 2 "$(gate demo-400 N9 scripts/handover/chief-kit/go.sh)"
check '14. and writes no doc for it' absent "$([ -e "$(gdoc demo-400 N9)" ] && echo present || echo absent)"
ld="$B/demo-400-N10-t3-lower-$today.md"
printf '# demo-400 - lower\n\n> **Writes:** scripts/handover/chief-kit/go.sh\n\n> **Launch gate:** passed\n' > "$ld"
fmx add "$M" --lane t3 --lockless "$ld"
bash "$BIND" attach --manifest "$M" --doc "$ld" --thread lower1 >/dev/null 2>&1; rc=$?
check '14. attach refuses a doc whose name carries a lower-case ticket key, rc 3' 3 "$rc"
check '14. and binds nothing' pending "$(jq -r --arg d "$ld" '.workers[] | select(.doc == $d) | .t3_thread // "pending"' "$M")"

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-relay-bind.sh"
    exit 0
fi
echo "FAIL - test-relay-bind.sh ($fails failure(s))"
exit 1
