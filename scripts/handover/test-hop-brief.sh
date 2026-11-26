#!/usr/bin/env bash
# scripts/handover/test-hop-brief.sh - hermetic suite for hop-brief.py and its two modules,
# scripts/lib/transcript_deliveries.py (the delivery classifier) and scripts/lib/handover_tokens.py (the token helper).
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HB="$HERE/hop-brief.py"
LIB="$ROOT/scripts/lib"
PY="$(command -v python3)"
T="$(mktemp -d "${TMPDIR:-/tmp}/hop-brief-test.XXXXXX")" || { echo "test-hop-brief: mktemp -d failed" >&2; exit 1; }
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_NAME CLAUDE_CONFIG_DIR HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_CONTEXT_SHARE WORKER_SESSION_CONTEXT_HANDOFF_OK HIMMEL_WORKER
export HANDOVER_DIR="$T/handovers"
mkdir -p "$HANDOVER_DIR"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hb() { "$PY" -I "$HB" "$@"; }
probe() { "$PY" -I "$T/probe.py" "$@"; }

CHIEF="T-chief"
SHA40=0123456789abcdef0123456789abcdef01234567
SHA64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
R32=R-0123456789abcdef0123456789abcdef

node --input-type=module -e '
const { formatRecord } = await import(process.argv[1]);
const [chief, pad] = [process.argv[2], process.argv[3]];
process.stdout.write(JSON.stringify({
  c: formatRecord({ n: 9, f: chief, c: 1, b: "RULING-C narrow to file x, RETASK token P-N77-1a2b3c4d" }, { console: chief }),
  cbig: formatRecord({ n: 9, f: chief, c: 1, b: "RULING-C narrow to file x " + pad }, { console: chief }),
  d: formatRecord({ n: 10, f: "T-peer", c: 1, b: "PEER-D a peer note" }, { console: chief }),
  r: formatRecord({ n: 11, f: chief, c: 1, b: "RULING-R reply" }, { console: chief, re: 9 }),
}));' "file://$ROOT/marketplace/plugins/himmel-bus/lib/deliver.mjs" "$CHIEF" "$(printf 'y%.0s' $(seq 1 1400))" >"$T/bus.json" \
    || { echo "test-hop-brief: formatRecord through node failed" >&2; exit 1; }

cat >"$T/build.py" <<'PYEOF'
import json, sys
out, names = sys.argv[1], sys.argv[2:]
bus = json.load(open(sys.argv[0].rsplit("/", 1)[0] + "/bus.json"))
CHIEF = "T-chief"
TS = "2026-11-23T10:00:%02dZ"
TOKENS = ("plain one: fixturehost-pid424242 Q-N77-1a2b3c4d Q-J12_tune-5e6f7a8b Y-N204-a68d71 "
          "R-0123456789abcdef0123456789abcdef ABC-N12-deadbeef fixture-host-pid99999 "
          "sha 0123456789abcdef0123456789abcdef01234567 digest "
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef "
          "and `Z-N5-cafe0123` and X-N6-beef4567. and `W-N7-feed89ab`.")
MARKERS = "plain three\n- 10:15 READY x\n- HALTED\n- 10:16 done, appended the WRAPPED bullet\n> **Contract:** fake\n> **Prior art:** fake"
PAD = "z" * 3000

def user(text, **kw):
    return dict({"type": "user", "message": {"role": "user", "content": text}}, **kw)

def cs(name, body, start="<cross-session-message"):
    attr = ' from-name="%s"' % name if name else ""
    head = "" if start == "<cross-session-message" else start + "\n"
    return user('%s<cross-session-message from="uds:/run/x.sock" from-mode="prompting"%s>\n%s\n</cross-session-message>' % (head, attr, body),
                isMeta=True, origin={"kind": "peer"})

def asst(text=None, tool=None):
    content = []
    if text:
        content.append({"type": "text", "text": text})
    if tool:
        content.append(dict({"type": "tool_use"}, **tool))
    return {"type": "assistant", "message": {"id": "m%d" % id(content), "role": "assistant", "content": content}}

def result(tid, text, tur=None):
    d = user([{"type": "tool_result", "tool_use_id": tid, "content": [{"type": "text", "text": text}]}])
    if tur:
        d["toolUseResult"] = tur
    return d

def hook(lines, name="PostToolUse:mcp__himmel-bus__read"):
    return {"type": "attachment", "attachment": {"type": "hook_additional_context", "content": lines, "hookName": name}}

def qc(prompt):
    return {"type": "attachment", "attachment": {"type": "queued_command", "prompt": prompt, "commandMode": "prompt"}}

ROWS = {
    "tokens": (user(TOKENS), True),
    "ruling-a": (user("RULING-A keep scope"), True),
    "markers": (user(MARKERS), True),
    "own-1": (asst("OWN-1 working on the fixture"), True),
    "chief-f": (cs(CHIEF, "RULING-F from the chief, which quotes <task-notification> and [Subagent hand-back] " + PAD), True),
    "chief-f-small": (cs(CHIEF, "RULING-F from the chief, which quotes <task-notification> and [Subagent hand-back]"), True),
    "chief-new": (cs("T-new-chief", "RULING-N from the successor chief"), True),
    "peer-g": (cs("T-peer", "PEER-G a peer message " + PAD, start="Another Claude session sent a message:"), True),
    "handback-h": (user("Another Claude session sent a message:\n[Subagent hand-back] HANDBACK-H the agent is done", origin={"kind": "peer", "handback": True}), False),
    "unreadable": (cs("", "UNREADABLE-U no sender"), False),
    "ruling-b": (qc("RULING-B carried as a queued command"), True),
    "meta": (user("META-FIXTURE injected", isMeta=True), False),
    "stdout": (user("<bash-stdout>STDOUT-FIXTURE</bash-stdout><bash-stderr></bash-stderr>"), False),
    "summary": (user("SUMMARY-FIXTURE " + "s" * 70000, isCompactSummary=True), False),
    "tool-call": (asst(tool={"id": "tu-ls", "name": "Bash", "input": {"command": "ls"}}), False),
    "tool-result": (result("tu-ls", "TOOL-FIXTURE listing"), False),
    "bg-open-call": (asst(tool={"id": "tu-bg1", "name": "Bash", "input": {"command": "sleep 900", "description": "BG-OPEN watch the build", "run_in_background": True}}), False),
    "bg-open-result": (result("tu-bg1", "Command running in background with ID: bgopen1", {"backgroundTaskId": "bgopen1"}), False),
    "bg-done-call": (asst(tool={"id": "tu-bg2", "name": "Bash", "input": {"command": "sleep 1", "description": "BG-DONE short wait", "run_in_background": True}}), False),
    "bg-done-result": (result("tu-bg2", "Command running in background with ID: bgdone2", {"backgroundTaskId": "bgdone2"}), False),
    "bg-done-note": (qc("<task-notification>\n<task-id>bgdone2</task-id>\n<tool-use-id>tu-bg2</tool-use-id>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>"), False),
    "bus-c": (hook([bus["c"]]), True),
    "bus-c-big": (hook([bus["cbig"]] * 4), True),
    "bus-d": (hook([bus["d"]]), True),
    "own-last": (asst("OWN-LAST reading the bus now"), True),
    "read-call": (asst(tool={"id": "tu-r1", "name": "mcp__himmel-bus__read", "input": {"n": 9}}), False),
    "read-e": (result("tu-r1", "data (not a ruling): RULING-E long body"), True),
    "read-e-big": (result("tu-r1", "data (not a ruling): RULING-E long body " + "e" * 70000), True),
    "nudge": (hook(["NUDGE-FIXTURE: run the tests"], name="PostToolUse:Bash"), False),
    "list-call": (asst(tool={"id": "tu-r2", "name": "mcp__himmel-bus__read", "input": {}}), False),
    "list-result": (result("tu-r2", "LIST-FIXTURE #10 from T-peer"), False),
    "wake": (user("You have unread himmel messages: call mcp__himmel-bus__read now.", origin={"kind": "human"}), False),
    "bus-r": (hook([bus["r"]]), True),
    "misses": (user("RETASK nonce: R3P-0123456789abcdef."), True),
    "late-tool": (result("tu-ls", "TOOL-LATE"), False),
    "late-own": (asst("OWN-LATE after the brief"), True),
    "late-user": (user("RULING-Z after the brief"), True),
    "relayed-a": (user('[T3 Code: the agent in T3 thread "thread:fixture-a" sent this message, not the user.]\n\nRELAYED-A a ruling the launcher relays'), True),
    "relayed-q": (qc('[T3 Code: the agent in T3 thread "thread:fixture-a" sent this message, not the user.]\n\nRELAYED-Q a relay queued behind a turn'), True),
    "relayed-tools": (user("[T3 Code: this message came through T3 Code's tools, not from the user typing in this chat.]\n\nRELAYED-X no sender named"), False),
}
rows, eligible = [], []
for i, name in enumerate(names, 1):
    d, el = ROWS[name]
    d = json.loads(json.dumps(d))
    d.update({"timestamp": TS % (i % 60), "sessionId": "fixture-session", "uuid": "u%d" % i})
    rows.append(d)
    if el:
        eligible.append("L%d" % i)
open(out, "w").write("".join(json.dumps(r) + "\n" for r in rows))
open(out + ".eligible", "w").write(" ".join(eligible) + "\n")
PYEOF

cat >"$T/probe.py" <<'PYEOF'
import json, os, re, sys
sys.path.insert(0, os.environ["HB_LIB"])
import transcript_deliveries as td
import handover_tokens as ht
cmd = sys.argv[1]
if cmd == "kinds":
    chiefs = sys.argv[3].split(",") if len(sys.argv) > 3 else []
    for it, el, dl in td.classify(td.read_rows(sys.argv[2]), chiefs):
        m = re.search(r"\b[A-Z]{3,}-[A-Z0-9]+\b", it.text)
        print(it.id, it.kind, "E" if el else "-", "D" if dl else "-", m.group(0) if m else it.text.split("\n")[0][:60].replace(" ", "_"))
elif cmd == "senders":
    for it, _, _ in td.classify(td.read_rows(sys.argv[2]), []):
        if it.kind == "cross-session":
            print(it.id, it.sender)
elif cmd == "chiefs":
    print(" ".join(td.chief_names(open(sys.argv[2]).read())))
elif cmd == "const":
    print(getattr(td, sys.argv[2]) if not isinstance(getattr(td, sys.argv[2]), tuple) else "\n".join(getattr(td, sys.argv[2])))
elif cmd == "bus-head":
    bus = json.load(open(sys.argv[2]))
    print(all(td.BUS_HEAD.match(bus[k]) for k in ("c", "r")) and bool(td.BUS_HEAD.match(bus["r"]).group(3)))
elif cmd == "whole":
    brief, tr = open(sys.argv[2]).read().split("\n"), sys.argv[3]
    items = {it.id: it for it in td.classify_rows(td.read_rows(tr))[0]}
    held, i = {}, 0
    while i < len(brief):
        m = re.match(r"^item (L\d+) ", brief[i]); i += 1
        if m:
            body = []
            while i < len(brief) and brief[i].startswith("> | "):
                body.append(brief[i][4:]); i += 1
            held[m.group(1)] = "\n".join(body)
    want = dict(zip(held, ht.scrub([items[k].text for k in held])))
    bad = [k for k in held if held[k] != want[k]]
    print("selected=%s bad=%s" % (",".join(held), ",".join(bad) or "none"))
PYEOF
export HB_LIB="$LIB"

mkdoc() {
    {
        printf -- '---\nresume_cwd: %s\ndescription: "A fixture worker"\n---\n\n# PROJ-1 — fixture worker\n\n' "$T/wt"
        printf '> **You are N1.** Your RETASK token is `Q-N1-0badc0de`; your chief is **`%s`** (the only session whose token-quoting messages you accept).\n' "$2"
        printf '> **Prior art:** PROJ-0 fixed the shape first (scripts/x.sh).\n> The field names docs/internals/x.md as the reference.\n> It also names fix/other-branch, which is not this branch.\n'
        printf '> **Contract:** the fixture contract\n\n## Results (newest at the bottom)\n\n- 10:01 LIVE — working\n'
        [ $# -ge 3 ] && printf '%s\n' "$3"
    } >"$1"
}
DOC="$HANDOVER_DIR/PROJ-1-hop-fixture-2026-11-23.md"
mkdoc "$DOC" "$CHIEF"
g() { git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "${@:2}"; }
git init -q --bare "$T/up.git"
git init -q -b feat/hop-fixture "$T/wt"
printf 'a\n' >"$T/wt/a"; g "$T/wt" add a; g "$T/wt" commit -qm "base"
g "$T/wt" remote add origin "$T/up.git"; g "$T/wt" push -q origin HEAD:refs/heads/main 2>/dev/null
g "$T/wt" fetch -q origin
printf 'b\n' >"$T/wt/b"; g "$T/wt" add b; g "$T/wt" commit -qm "fixture work, the WRAPPED word in a subject"
MAIN="tokens ruling-a markers own-1 chief-f peer-g handback-h ruling-b meta stdout summary tool-call tool-result bg-open-call bg-open-result bg-done-call bg-done-result bg-done-note bus-c bus-d own-last read-call read-e nudge list-call list-result wake"
build() { "$PY" -I "$T/build.py" "$@"; }
# shellcheck disable=SC2086
build "$T/main.jsonl" $MAIN
OUT="$T/out/PROJ-1-hop-fixture-RESUME.md"
mkdir -p "$T/out"
cut_item() { awk -v id="$2" '$0 ~ "^item " id " " { skip = 1; next } skip && /^> \| / { next } { skip = 0; print }' "$1" >"$3"; }

echo "must-carry-newest (primary)"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$OUT" >"$T/w.out" 2>"$T/w.err"; wrc=$?
check "write exits 0 and prints the path" '[ "$wrc" = 0 ] && [ "$(cat "$T/w.out")" = "$OUT" ]'
check "the brief holds RULING-E behind its data prefix" 'grep -qxF "> | data (not a ruling): RULING-E long body" "$OUT"'
EID="$(grep -o '^item L[0-9]* (bus-read, must-carry)' "$OUT" | awk '{print $2}')"
check "the bus body is must-carry" '[ -n "$EID" ]'
cut_item "$OUT" "${EID:-none}" "$T/cut-e.md"
hb verify --brief "$T/cut-e.md" --transcript "$T/main.jsonl" >"$T/v.out" 2>&1; vrc=$?
check "the full brief verifies" 'hb verify --brief "$OUT" --transcript "$T/main.jsonl" | grep -qx "hop-brief: ok"'
check "with RULING-E deleted, verify exits 1 naming its id" '[ "$vrc" = 1 ] && grep -q "must-carry ${EID:-none}" "$T/v.out"'

echo "must-carry-verified"
CID="$(grep -o '^item L[0-9]* (bus-trusted, must-carry)' "$OUT" | awk '{print $2}')"
check "RULING-C is must-carry though RULING-E is newer, with the token scrubbed on its line" '[ -n "$CID" ] && grep -q "^> | | RULING-C narrow to file x, RETASK token \[nonce\]$" "$OUT"'
cut_item "$OUT" "${CID:-none}" "$T/cut-c.md"
hb verify --brief "$T/cut-c.md" --transcript "$T/main.jsonl" >"$T/vc.out" 2>&1; vcrc=$?
check "with RULING-C deleted, verify exits 1 naming its id" '[ "$vcrc" = 1 ] && grep -q "must-carry ${CID:-none}" "$T/vc.out"'
# shellcheck disable=SC2086
build "$T/cbig.jsonl" ${MAIN/bus-c /bus-c-big }
hb write --transcript "$T/cbig.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/cbig.md" --budget 1024 >/dev/null 2>"$T/cbig.err"; cbrc=$?
check "a RULING-C batch of four inline records, larger than what the budget leaves: write exits 2" '[ "$cbrc" = 2 ] && [ ! -e "$T/out/cbig.md" ]'

echo "must-carry-oversize"
# shellcheck disable=SC2086
build "$T/ebig.jsonl" ${MAIN/read-e /read-e-big }
hb write --transcript "$T/ebig.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/ebig.md" >/dev/null 2>"$T/ebig.err"; ebrc=$?
check "a newest delivery larger than the budget: write exits 2 with one line and leaves no file" '[ "$ebrc" = 2 ] && [ "$(wc -l <"$T/ebig.err")" = 1 ] && [ ! -e "$T/out/ebig.md" ] && ! ls -A "$T/out" | grep -q "\.tmp-"'

echo "delivery-shapes"
probe kinds "$T/main.jsonl" "$CHIEF" >"$T/kinds"
kind_of() { grep -F "_$1" "$T/kinds" | head -1 | awk '{print $3 $4}'; }
kind_line() { grep -F "$1" "$T/kinds" | head -1 | awk '{print $3 $4}'; }
for r in RULING-B RULING-F; do check "$r is a delivery" '[ "$(kind_line "$r")" = ED ]'; done
check "RULING-C is a delivery" '[ "$(kind_line "|_RULING-C")" = ED ] || [ "$(grep bus-trusted "$T/kinds" | awk "{print \$3 \$4}")" = ED ]'
check "RULING-E is a delivery" '[ "$(kind_line "RULING-E")" = ED ]'
check "PEER-D is eligible and not a delivery" '[ "$(grep bus-data "$T/kinds" | awk "{print \$3 \$4}")" = E- ]'
check "PEER-G is eligible and not a delivery" '[ "$(kind_line "PEER-G")" = E- ]'
for k in hook-context bus-list wake meta local-command hand-back; do
    check "the $k row is neither eligible nor a delivery" '[ "$(grep " $k " "$T/kinds" | head -1 | awk "{print \$3 \$4}")" = -- ]'
done
check "the summary row is neither" '[ "$(kind_line "SUMMARY-FIXTURE")" = -- ]'
check "with the nudge, the list and the wake line newest, the newest delivery is still RULING-E" '[ "$(grep " D " "$T/kinds" | tail -1 | awk "{print \$1}")" = "$EID" ]'
check "the oversized summary does not cause exit 2" '[ "$wrc" = 0 ]'
# shellcheck disable=SC2086
build "$T/r.jsonl" $MAIN bus-r
hb write --transcript "$T/r.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/r.md" >/dev/null 2>&1
RID="$(grep -o '^item L[0-9]* (bus-trusted, must-carry)' "$T/out/r.md" | awk '{print $2}')"
check "a trusted record with re is a delivery and the newest one" '[ "$RID" = "L28" ] && grep -q "^> | bus #11 from T-chief re #9:$" "$T/out/r.md"'
cut_item "$T/out/r.md" "${RID:-none}" "$T/cut-r.md"
check "with RULING-R deleted, verify exits 1" '! hb verify --brief "$T/cut-r.md" --transcript "$T/r.jsonl" >/dev/null 2>&1'

echo "meta-cross-session (census: every real cross-session row is isMeta)"
check "the chief's isMeta cross-session row is a delivery, not a meta row" 'grep -F "RULING-F" "$T/kinds" | grep -q " cross-session E D "'

echo "handback-start-no-tag (census: hand-backs start like a cross-session message, with no tag)"
check "a hand-back with the cross-session start and no tag is a hand-back, not an unreadable sender" 'grep -F "HANDBACK-H" "$T/kinds" | grep -q " hand-back - - "'

echo "chief-sendmessage-newest"
build "$T/f.jsonl" tokens ruling-a markers own-1 chief-f
hb write --transcript "$T/f.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/f.md" >/dev/null 2>&1
FID="$(grep -o '^item L[0-9]* (cross-session, must-carry)' "$T/out/f.md" | awk '{print $2}')"
check "the brief holds RULING-F whole although its body quotes a task notification and a hand-back" '[ "$FID" = L5 ] && grep -q "^> | RULING-F from the chief, which quotes <task-notification> and \[Subagent hand-back\] z" "$T/out/f.md"'
cut_item "$T/out/f.md" L5 "$T/cut-f.md"
check "with RULING-F deleted, verify exits 1" 'hb verify --brief "$T/cut-f.md" --transcript "$T/f.jsonl" | grep -q "must-carry L5"'
mkdoc "$T/handovers/PROJ-1-succ-2026-11-23.md" T-old-chief "- 10:02 SUCCESSION accepted: $CHIEF replaces T-old-chief"
hb write --transcript "$T/f.jsonl" --doc "$T/handovers/PROJ-1-succ-2026-11-23.md" --worktree "$T/wt" --out "$T/out/fs.md" >/dev/null 2>&1
check "with the chief named only by a SUCCESSION bullet, RULING-F is still must-carry" 'grep -q "^item L5 (cross-session, must-carry)$" "$T/out/fs.md" && grep -qF "your chief is **\`$CHIEF\`**" "$T/out/fs.md"'

echo "peer-sendmessage-not-newest"
build "$T/g.jsonl" tokens ruling-a markers own-1 chief-f peer-g
hb write --transcript "$T/g.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/g.md" --budget 1024 >/dev/null 2>&1
check "the brief holds RULING-F" 'grep -q "^item L5 (cross-session, must-carry)$" "$T/out/g.md"'
check "PEER-G is listed as omitted and counted eligible" 'grep -qx "omitted-ids: L6" "$T/out/g.md" && grep -qx "eligible: 6" "$T/out/g.md" && ! grep -q "PEER-G" "$T/out/g.md"'

echo "subagent-handback-not-delivery"
build "$T/h.jsonl" tokens ruling-a markers own-1 chief-f handback-h
hb write --transcript "$T/h.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/h.md" >"$T/h.out" 2>&1; hrc=$?
check "write exits 0, the brief lacks HANDBACK-H, eligible does not count it, RULING-F is still the newest delivery" '[ "$hrc" = 0 ] && ! grep -q HANDBACK-H "$T/out/h.md" && grep -qx "eligible: 5" "$T/out/h.md" && grep -q "^item L5 (cross-session, must-carry)$" "$T/out/h.md"'

echo "sender-unreadable"
build "$T/u.jsonl" tokens ruling-a markers own-1 chief-f unreadable
hb write --transcript "$T/u.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/u.md" >"$T/u.out" 2>&1; urc=$?
check "a newest cross-session message with no from-name: write exits 3 and names the row" '[ "$urc" = 3 ] && grep -q "L6" "$T/u.out" && [ ! -e "$T/out/u.md" ]'
build "$T/u2.jsonl" tokens ruling-a markers own-1 unreadable chief-f
hb write --transcript "$T/u2.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/u2.md" >/dev/null 2>&1; u2rc=$?
check "the same message before RULING-F: write exits 0 and the brief lacks it" '[ "$u2rc" = 0 ] && ! grep -q UNREADABLE-U "$T/out/u2.md"'

echo "bus-shape-pin, wake-line-pin, wrapper-start-pin, chief-clause-pin"
check "bus-shape-pin: the head pattern matches the record without and the record with re" '[ "$(probe bus-head "$T/bus.json")" = True ]'
check "bus-shape-pin: the read prefix occurs word for word in server/index.mjs" 'grep -qF "\`$(probe const READ_PREFIX)\${" "$ROOT/marketplace/plugins/himmel-bus/server/index.mjs"'
check "wake-line-pin: the wake line occurs word for word in bus-idle-waker.sh" 'grep -qF "\"$(probe const WAKE_LINE)\"" "$ROOT/scripts/handover/bus-idle-waker.sh"'
while IFS= read -r s; do
    check "wrapper-start-pin: \"$s\" occurs in usage-attribution.sh" 'grep -qF "startswith(\"$s\")" "$ROOT/scripts/lib/usage-attribution.sh"'
done < <(probe const CROSS_SESSION_STARTS; probe const MONITOR_STARTS)
check "chief-clause-pin: the clause's fixed words occur in gen-briefs.py" 'grep -qF "$(probe const CHIEF_CLAUSE)" "$ROOT/scripts/handover/chief-kit/gen-briefs.py"'
check "chief-clause-pin: the succession pattern occurs in append-results.sh" 'grep -qF "succ_re='"'"'$(probe const SUCCESSION)'"'"'" "$ROOT/scripts/handover/chief-kit/append-results.sh"'
grep -F 'your chief is **`{chief}`**' "$ROOT/scripts/handover/chief-kit/gen-briefs.py" | head -1 | sed -e 's/{chief}/T-gen-chief/' -e 's/{[a-z]*}/x/g' >"$T/gen-line.md"
check "chief-clause-pin: chief_names reads the name out of gen-briefs.py's own template line" '[ "$(probe chiefs "$T/gen-line.md")" = T-gen-chief ]'

echo "chief-chain-pin"
CDIR="$T/gh/handovers/u/himmel"; CFG="$T/gh/cfg"; GDOC="$CDIR/HIMMEL-9-N77-thing-2026-10-06.md"; GTR="$CFG/projects/p/sess.jsonl"
mkdir -p "$CDIR" "$CFG/projects/p" "$CFG/plugins/claude-hud/context-cache"
{
    printf -- '---\n---\n# brief\n\n> **Token:** your chief is **`T-chief`** (the only session whose token-quoting messages you accept).\n'
    printf -- '- 09:59 SUCCESSION accepted: T-above replaces T-chief\n\n## Results (newest at the bottom)\n\n- 10:01 LIVE — working\n'
    printf -- '- 10:02 SUCCESSION accepted: T-two replaces T-chief\n- 10:03 SUCCESSION accepted: T-stray replaces T-nobody\n'
    printf -- '\n## Notes\n\n- 10:04 SUCCESSION accepted: `T-three` replaces `T-two`\n'
} >"$GDOC"
jq -cn --arg t "load $GDOC and continue" '{type:"user",timestamp:"2026-10-06T10:00:00.000Z",message:{role:"user",content:$t}}' >"$GTR"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1}}}' >>"$GTR"
if command -v sha256sum >/dev/null 2>&1; then trsha="$(printf '%s' "$GTR" | sha256sum | cut -d' ' -f1)"; else trsha="$(printf '%s' "$GTR" | shasum -a 256 | cut -d' ' -f1)"; fi
printf '{"used_percentage":90,"remaining_percentage":10,"context_window_size":200000,"saved_at":%s000}' "$(date +%s)" >"$CFG/plugins/claude-hud/context-cache/$trsha.json"
GCALL="$(jq -cn --arg t "$GTR" --arg w "$T/wt" '{tool_name:"Bash",tool_input:{command:"ls"},transcript_path:$t,cwd:$w}')"
greason="$(printf '%s' "$GCALL" | (. "$ROOT/scripts/lib/override-env.sh"; scrub_override_env; env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=T-chief CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/gh/handovers" HIMMEL_WORKER_SESSION_CONTEXT_MODE=handoff bash "$ROOT/scripts/hooks/guard-worker-context-handoff.sh" 2>&1))"
guard_chief="$(printf '%s' "$greason" | grep -o 'SendMessage your chief [A-Za-z0-9._-]*:' | head -1 | sed -e 's/^SendMessage your chief //' -e 's/:$//')"
check "chief_names returns the clause's name and the chained names only" '[ "$(probe chiefs "$GDOC")" = "T-chief T-two T-three" ]'
check "its last name equals the chief the guard names in its deny text" '[ -n "$guard_chief" ] && [ "$guard_chief" = T-three ]'
stop_at_heading="$(awk '/^## Results/{s=1;next} s&&/^## /{s=0} s&&/SUCCESSION accepted: T-two replaces T-chief/{c="T-two"} END{print c}' "$GDOC")"
check "control: a walk that stops at the next heading names the earlier chief, so the row tells the two apart" '[ "$stop_at_heading" = T-two ] && [ "$stop_at_heading" != "$guard_chief" ]'

echo "no-tool-result"
for s in TOOL-FIXTURE LIST-FIXTURE NUDGE-FIXTURE STDOUT-FIXTURE SUMMARY-FIXTURE META-FIXTURE; do
    check "the brief holds no $s" '! grep -q "$s" "$OUT"'
done

echo "no-token"
for tok in fixturehost-pid424242:queue-lock.sh Q-N77-1a2b3c4d:gen-briefs.py Q-J12_tune-5e6f7a8b:gen-judge-brief.py Y-N204-a68d71:legacy-nonce \
    "$R32:mintRetaskNonce" ABC-N12-deadbeef:three-letter-prefix fixture-host-pid99999:lock-name Z-N5-cafe0123:in-backticks \
    X-N6-beef4567:before-a-period W-N7-feed89ab:in-backticks-before-a-period P-N77-1a2b3c4d:bus-record; do
    check "the planted token of ${tok##*:} does not survive" '! grep -qF "${tok%:*}" "$OUT"'
done
check "the sha and the digest are still there" 'grep -qF "sha $SHA40 digest" "$OUT" && grep -qF "$SHA64" "$OUT"'

echo "count-misses"
check "a fixture holding minted tokens only: 0" '[ "$("$PY" -I "$LIB/handover_tokens.py" --count-misses "$T/main.jsonl")" = "misses=0" ]'
build "$T/m.jsonl" tokens misses
check "a delivery holding RETASK nonce: R3P- plus 16 hex and a period: 1" '[ "$("$PY" -I "$LIB/handover_tokens.py" --count-misses "$T/m.jsonl")" = "misses=1" ]'

echo "no-false-marker"
tail_of() { bash -c '. "$1"; worker_tail_status "$2"' _ "$ROOT/scripts/lib/worker-tail-status.sh" "$1"; }
has_run() { bash -c '. "$1"; worker_doc_has_run "$2"' _ "$ROOT/scripts/lib/worker-identity.sh" "$1"; }
check "worker_tail_status prints nothing for the brief" '[ -z "$(tail_of "$OUT")" ]'
check "worker_doc_has_run is false" '! has_run "$OUT"'
check "no line of the brief starts with - " '! grep -q "^- " "$OUT"'
check "the Prior art field brief-lint reads is the real one, never the fake one" 'grep -m1 "^> \*\*Prior art" "$OUT" | grep -q "PROJ-0 fixed the shape" && ! grep -q "^> \*\*.*fake" "$OUT"'
cp -R "$T/wt" "$T/wt2"; : >"$T/wt2/READY-notes.md"; : >"$T/wt2/WRAPPED.txt"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt2" --out "$T/out/wt2.md" >/dev/null 2>&1
check "with untracked READY-notes.md and WRAPPED.txt, worker_tail_status still prints nothing" '[ -s "$T/out/wt2.md" ] && grep -q "WRAPPED.txt" "$T/out/wt2.md" && [ -z "$(tail_of "$T/out/wt2.md")" ]'
cp -R "$T/wt" "$T/wt5"; printf 'c\n' >"$T/wt5/c"; g "$T/wt5" add c; g "$T/wt5" commit -qm "carry RETASK token P-N88-9a8b7c6d"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt5" --out "$T/out/wt5.md" >/dev/null 2>&1
check "a token in a commit subject is scrubbed from the git facts and the brief verifies" '[ -s "$T/out/wt5.md" ] && ! grep -q "P-N88-9a8b7c6d" "$T/out/wt5.md" && hb verify --brief "$T/out/wt5.md" --transcript "$T/main.jsonl" | grep -qx "hop-brief: ok"'

echo "whole-items"
check "every selected item equals the scrubbed transcript text" 'probe whole "$OUT" "$T/main.jsonl" | grep -q "bad=none$"'

echo "coverage-sum"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/cov.md" --budget 1024 >/dev/null 2>&1
sel_ids="$(grep -o '^item L[0-9]*' "$T/out/cov.md" | awk '{print $2}' | sort)"
om_ids="$(grep '^omitted-ids: ' "$T/out/cov.md" | sed 's/^omitted-ids: //' | tr ' ' '\n' | grep -v '^none$' | sort)"
check "eligible equals the count built into the fixture" 'grep -qx "eligible: $(wc -w <"$T/main.jsonl.eligible" | tr -d " ")" "$T/out/cov.md"'
check "some item is omitted at this budget" '[ -n "$om_ids" ]'
check "the selected and the omitted ids are disjoint" '[ -z "$(comm -12 <(printf "%s\n" "$sel_ids") <(printf "%s\n" "$om_ids"))" ]'
check "together they are the fixture's eligible id set" '[ "$(printf "%s\n%s\n" "$sel_ids" "$om_ids" | grep . | sort | tr "\n" " ")" = "$(tr " " "\n" <"$T/main.jsonl.eligible" | grep . | sort | tr "\n" " ")" ]'
one_om="$(printf '%s\n' "$om_ids" | head -1)"
check "read --id of an omitted id prints it" 'hb read --transcript "$T/main.jsonl" --id "$one_om" | head -1 | grep -q "^item $one_om "'
check "read of a tool result marks it untrusted" 'hb read --transcript "$T/main.jsonl" --id L13 | head -1 | grep -q "untrusted"'

echo "verify-after-growth"
cp "$T/main.jsonl" "$T/grow.jsonl"; build "$T/grow-tail.jsonl" late-tool late-own; cat "$T/grow-tail.jsonl" >>"$T/grow.jsonl"
check "verify exits 0" 'hb verify --brief "$OUT" --transcript "$T/grow.jsonl" >/dev/null'
check "verify --fresh exits 0" 'hb verify --brief "$OUT" --transcript "$T/grow.jsonl" --fresh --worktree "$T/wt" >/dev/null'

echo "verify-fresh"
cp "$T/main.jsonl" "$T/newer.jsonl"; build "$T/newer-tail.jsonl" late-user; cat "$T/newer-tail.jsonl" >>"$T/newer.jsonl"
check "a newer user message: verify exits 0" 'hb verify --brief "$OUT" --transcript "$T/newer.jsonl" >/dev/null'
check "a newer user message: verify --fresh exits 1 naming it" 'hb verify --brief "$OUT" --transcript "$T/newer.jsonl" --fresh --worktree "$T/wt" | grep -q "fresh: newer delivery L28"'
cp -R "$T/wt" "$T/wt3"; printf 'c\n' >"$T/wt3/c"; g "$T/wt3" add c; g "$T/wt3" commit -qm later
check "a new commit: verify exits 0" 'hb verify --brief "$OUT" --transcript "$T/main.jsonl" >/dev/null'
check "a new commit: verify --fresh exits 1 naming it" 'hb verify --brief "$OUT" --transcript "$T/main.jsonl" --fresh --worktree "$T/wt3" | grep -q "fresh: head moved"'
cp -R "$T/wt" "$T/wt4"; : >"$T/wt4/untracked.txt"
check "an untracked file: verify --fresh exits 1 naming it" 'hb verify --brief "$OUT" --transcript "$T/main.jsonl" --fresh --worktree "$T/wt4" | grep -q "fresh: dirty tree"'

echo "write-deadline"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/dl.md" --deadline 0 >/dev/null 2>&1; dlrc=$?
check "write --deadline 0 exits 4 and leaves no file and no temp file" '[ "$dlrc" = 4 ] && [ ! -e "$T/out/dl.md" ] && ! ls -A "$T/out" | grep -q "\.tmp-"'

echo "background-list"
check "the unfinished background call is listed by id with its description" 'grep -qx "task bgopen1" "$OUT" && grep -qx "> | BG-OPEN watch the build" "$OUT"'
check "the finished one is not" '! grep -q "bgdone2\|BG-DONE" "$OUT"'

echo "git-facts"
bash "$HERE/worker-resume-brief.sh" "$DOC" --dry-run --repo "$T/wt" --branch feat/hop-fixture >"$T/facts.raw" 2>/dev/null
sed -e 's/^## RESUME BRIEF (generated [^ ]* by/## RESUME BRIEF (by/' \
    -e "s/^- \[ \] (paste the operator's request verbatim here -- do not paraphrase)\$/See the carried deliveries below./" \
    -e "s/^- \[ \] (fill from the mission doc's step list)\$/See the predecessor doc and the worker's last message below./" \
    -e '$d' "$T/facts.raw" >"$T/facts.want"
awk '/^source: /{s=1;next} s&&/^> \| /{print substr($0,5);next} s&&/^> \|$/{print "";next} s{exit}' "$OUT" >"$T/facts.got"
check "the embedded block equals the dry-run output with the four substitutions" '[ -s "$T/facts.want" ] && cmp -s "$T/facts.want" "$T/facts.got"'
check "it sits right after the source: line" 'grep -A1 "^source: " "$OUT" | tail -1 | grep -qx "> | "'
check "the branch is the worktree's, not one the doc names" 'grep -q "branch:\*\* \`feat/hop-fixture\`" "$T/facts.got" && ! grep -q "fix/other-branch" "$T/facts.got"'
check "the brief's last line is the Results heading" '[ "$(tail -1 "$OUT")" = "## Results (newest at the bottom)" ]'

echo "missing-input"
sed '/^> \*\*Prior art/,/^> It also/d' "$DOC" >"$T/handovers/PROJ-1-noprior.md"
hb write --transcript "$T/main.jsonl" --doc "$T/handovers/PROJ-1-noprior.md" --worktree "$T/wt" --out "$T/out/x.md" >/dev/null 2>&1; m1=$?
sed 's/your chief is \*\*`T-chief`\*\*/your chief is T-chief/' "$DOC" >"$T/handovers/PROJ-1-nochief.md"
hb write --transcript "$T/main.jsonl" --doc "$T/handovers/PROJ-1-nochief.md" --worktree "$T/wt" --out "$T/out/x.md" >/dev/null 2>&1; m2=$?
mkdir -p "$T/nonode"
PATH="$T/nonode" "$PY" -I "$HB" write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/x.md" >/dev/null 2>&1; m3=$?
check "no Prior art field: exit 3" '[ "$m1" = 3 ]'
check "no chief clause: exit 3" '[ "$m2" = 3 ]'
check "no node on PATH: exit 3" '[ "$m3" = 3 ] && [ ! -e "$T/out/x.md" ]'
hb write --transcript "$T/none.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/x.md" >/dev/null 2>&1; m4=$?
check "no transcript: exit 3" '[ "$m4" = 3 ]'

echo "launcher-accepts"
mkdir -p "$T/stub" "$T/mirror"
printf 'type: Task\nlabels: \n' >"$T/mirror/PROJ-1.md"
cat >"$T/stub/index.js" <<'JSEOF'
const a = process.argv.slice(2);
const keys = (from) => a.slice(a.indexOf(from) + 1).filter((k) => /^[A-Z][A-Z0-9]*-[0-9]+$/.test(k));
if (a[0] === 'release' && a[1] === 'core-check') for (const k of keys('--key')) console.log('NOT-CORE ' + k);
else if (a[0] === 'release' && a[1] === 'bucket-check') for (const k of keys('--mirror')) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
else if (a[0] === 'release' && a[1] === 'spec-check') process.exit(0);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
JSEOF
export BRIEF_LINT_JIRA_CLI="$T/stub/index.js" BRIEF_LINT_MIRROR="$T/mirror"
bash "$HERE/chief-kit/brief-lint.sh" "$OUT" >"$T/lint.out" 2>&1; lrc=$?
check "brief-lint exits 0 on the brief" '[ "$lrc" = 0 ]'
check "the brief holds no Contract line" '! grep -q "^> \*\*Contract:\*\*" "$OUT"'
(
    export HEADED_ARM_WORKER_PROFILES="$HERE/../lanes/plugin-profiles.mjs" PLUGIN_PROFILES_ADAPTERS="$HERE/../guardrails/himmel-adapters.json" UNGUARDED_LAUNCH_OK=1 HOME="$T/home"
    unset HIMMEL_CONSOLE_DOC WORKER_SESSION_LANE HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_RECORDER WORKER_SESSION_CLAUDE_BIN HEADED_ARM_WORKER_CLAUDE_BIN HEADED_ARM_WORKER_TARGET HEADED_ARM_WORKER_SHIM
    mkdir -p "$HOME"
    bash "$HERE/chief-kit/headed-arm-worker.sh" --dry-run --no-profile PROJ-1-hop-fixture-RESUME "$OUT" "$T/nosig" 99999999999 "$T/worker.log" claude-sonnet-5
) >"$T/arm.out" 2>&1; arc=$?
check "headed-arm-worker.sh --dry-run on the brief exits 0" '[ "$arc" = 0 ]' || sed 's/^/    /' "$T/arm.out" | tail -5

echo "no-launch"
mkdir -p "$T/rec"
for b in claude tmux konsole; do printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$b" "$T/launch.log" >"$T/rec/$b"; chmod +x "$T/rec/$b"; done
: >"$T/launch.log"
PATH="$T/rec:$PATH" "$PY" -I "$HB" write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/nl.md" >/dev/null 2>&1
PATH="$T/rec:$PATH" "$PY" -I "$HB" verify --brief "$T/out/nl.md" --transcript "$T/main.jsonl" --fresh --worktree "$T/wt" >/dev/null 2>&1
PATH="$T/rec:$PATH" "$PY" -I "$HB" read --transcript "$T/main.jsonl" --id L2 >/dev/null 2>&1
check "write, verify and read leave the launch record empty" '[ -s "$T/out/nl.md" ] && [ ! -s "$T/launch.log" ]'

echo "deterministic"
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/d1.md" >/dev/null 2>&1
hb write --transcript "$T/main.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/d2.md" >/dev/null 2>&1
check "two writes on the same input give the same bytes" '[ -s "$T/out/d1.md" ] && cmp -s "$T/out/d1.md" "$T/out/d2.md"'

echo "transcript_deliveries --count"
"$PY" -I "$LIB/transcript_deliveries.py" --count "$T/main.jsonl" >"$T/count.out" 2>&1
check "counts per kind, no text" 'grep -qx "cross-session-named=2" "$T/count.out" && grep -qx "hand-back=1" "$T/count.out" && ! grep -q "RULING\|PEER" "$T/count.out"'

echo "relayed-not-operator (a T3 agent-relayed message never counts as the operator)"
build "$T/rl.jsonl" tokens ruling-a own-1 relayed-a relayed-q
probe kinds "$T/rl.jsonl" "$CHIEF" >"$T/rl.kinds"
probe senders "$T/rl.jsonl" >"$T/rl.senders"
check "the relayed message is a cross-session row, eligible and not a delivery" 'grep -F "RELAYED-A" "$T/rl.kinds" | grep -q " cross-session E - "'
check "the relayed message that arrives as a queued command is the same" 'grep -F "RELAYED-Q" "$T/rl.kinds" | grep -q " cross-session E - "'
check "its sender is the thread id the wrapper names" 'grep -qx "L4 thread:fixture-a" "$T/rl.senders" && grep -qx "L5 thread:fixture-a" "$T/rl.senders"'
check "control: a real operator message stays operator, eligible and a delivery" 'grep -F "RULING-A" "$T/rl.kinds" | grep -q " operator E D "'
hb write --transcript "$T/rl.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/rl.md" >/dev/null 2>&1; rlrc=$?
check "the newest operator message is the only must-carry item, the relayed ones are not" '[ "$rlrc" = 0 ] && [ "$(grep -c "^item .*must-carry" "$T/out/rl.md")" = 1 ] && grep -qx "item L2 (operator, must-carry)" "$T/out/rl.md"'
check "the relayed messages are still carried, as data" 'grep -qx "item L4 (cross-session)" "$T/out/rl.md" && grep -qx "item L5 (cross-session)" "$T/out/rl.md"'
check "the full brief verifies" 'hb verify --brief "$T/out/rl.md" --transcript "$T/rl.jsonl" | grep -qx "hop-brief: ok"'
build "$T/rc.jsonl" tokens ruling-a own-1 chief-f-small relayed-a
probe kinds "$T/rc.jsonl" "$CHIEF" >"$T/rc.kinds"
check "control: the chief's cross-session message keeps its class and stays a delivery" 'grep -F "RULING-F" "$T/rc.kinds" | grep -q " cross-session E D "'
hb write --transcript "$T/rc.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/rc.md" >/dev/null 2>&1
check "control: a relayed message newer than the chief's ruling leaves the ruling must-carry" 'grep -qx "item L4 (cross-session, must-carry)" "$T/out/rc.md" && [ "$(grep -c "^item .*must-carry" "$T/out/rc.md")" = 1 ]'
build "$T/rx.jsonl" tokens ruling-a own-1 relayed-tools
probe kinds "$T/rx.jsonl" "$CHIEF" >"$T/rx.kinds"
check "a relayed message that names no thread is an unreadable sender, neither eligible nor a delivery" 'grep -F "RELAYED-X" "$T/rx.kinds" | grep -q " unreadable-sender - - "'
hb write --transcript "$T/rx.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/rx.md" >"$T/rx.out" 2>&1; rxrc=$?
check "newer than the newest delivery, it stops the write: exit 3 naming its row" '[ "$rxrc" = 3 ] && grep -q "L4" "$T/rx.out" && [ ! -e "$T/out/rx.md" ]'
build "$T/rx2.jsonl" tokens ruling-a relayed-tools ruling-b
hb write --transcript "$T/rx2.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/rx2.md" >/dev/null 2>&1; rx2rc=$?
check "older than the newest delivery, the write goes on and the brief lacks it" '[ "$rx2rc" = 0 ] && ! grep -q "RELAYED-X" "$T/out/rx2.md"'

echo "no-delivery (a brief with nothing the chief or the operator sent never verifies)"
build "$T/nd.jsonl" own-1 relayed-a
hb write --transcript "$T/nd.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/nd.md" >/dev/null 2>&1; ndrc=$?
hb verify --brief "$T/out/nd.md" --transcript "$T/nd.jsonl" >"$T/nd.out" 2>&1; ndv=$?
check "the writer still writes it: exit 0 with the two eligible items" '[ "$ndrc" = 0 ] && grep -qx "eligible: 2" "$T/out/nd.md"'
check "verify exits 1 naming the missing delivery" '[ "$ndv" = 1 ] && grep -q "verify failed: no-delivery" "$T/nd.out"'

echo "empty-brief (a transcript the writer cannot read never yields an ok brief)"
printf '{"role":"user","content":"hello"}\n{"role":"assistant","content":"hi"}\n' >"$T/foreign.jsonl"
hb write --transcript "$T/foreign.jsonl" --doc "$DOC" --worktree "$T/wt" --out "$T/out/foreign.md" >/dev/null 2>"$T/foreign.err"; frc=$?
check "a transcript of a foreign format: write exits 3 naming the cause and leaves no file" '[ "$frc" = 3 ] && grep -q "no readable item" "$T/foreign.err" && [ ! -e "$T/out/foreign.md" ]'
printf 'source: session foreign transcript %s head %s row 2 budget 16000\neligible: 0\nselected: 0\n' "$T/foreign.jsonl" "$SHA40" >"$T/out/empty.md"
hb verify --brief "$T/out/empty.md" --transcript "$T/foreign.jsonl" >"$T/ev.out" 2>&1; evrc=$?
check "the empty brief the old writer wrote for it: verify exits 1 naming the empty check" '[ "$evrc" = 1 ] && grep -q "verify failed: empty" "$T/ev.out"'

FX="$HERE/fixtures/hop-brief-adapters"
NONCE=Q-N77-1a2b3c4d; LOCK=fixturehost-pid424242
adapter_checks() {
    ac_label="$1" ac_fix="$2" ac_op="$3" ac_rel="$4" ac_relcopy="$5"
    hb write --transcript "$ac_fix" --doc "$DOC" --worktree "$T/wt" --out "$T/out/$ac_label.md" >"$T/$ac_label.out" 2>"$T/$ac_label.err"; arc=$?
    check "$ac_label: write exits 0 and the brief is not empty" '[ "$arc" = 0 ] && grep -qx "eligible: 6" "$T/out/$ac_label.md" && grep -qx "selected: 6" "$T/out/$ac_label.md"'
    check "$ac_label: the operator message is the must-carry item, under the id of its row" 'grep -qx "item $ac_op (operator, must-carry)" "$T/out/$ac_label.md" && [ "$(grep -c "^item .*must-carry" "$T/out/$ac_label.md")" = 1 ]'
    check "$ac_label: the relayed message is carried as data, not must-carry" 'grep -qx "item $ac_rel (cross-session)" "$T/out/$ac_label.md"'
    check "$ac_label: no harness-injected, developer, tool, compaction or handoff text is carried" '! grep -q "AGENTS-FIXTURE\|DEVELOPER-FIXTURE\|TOOL-FIXTURE\|REASONING-FIXTURE\|COMPACT-FIXTURE\|HANDOFF-FIXTURE" "$T/out/$ac_label.md"'
    check "$ac_label: the nonce and the lock token are scrubbed" '! grep -qF "$NONCE" "$T/out/$ac_label.md" && ! grep -qF "$LOCK" "$T/out/$ac_label.md" && grep -q "\[nonce\]" "$T/out/$ac_label.md"'
    check "$ac_label: the brief verifies" 'hb verify --brief "$T/out/$ac_label.md" --transcript "$ac_fix" | grep -qx "hop-brief: ok"'
    cut_item "$T/out/$ac_label.md" "$ac_op" "$T/out/$ac_label-cut.md"
    hb verify --brief "$T/out/$ac_label-cut.md" --transcript "$ac_fix" >"$T/$ac_label-cut.out" 2>&1; crc=$?
    check "$ac_label: with the newest delivery removed, verify exits 1 naming its id" '[ "$crc" = 1 ] && grep -q "must-carry $ac_op" "$T/$ac_label-cut.out"'
    check "$ac_label: read prints the operator item by its id" 'hb read --transcript "$ac_fix" --id "$ac_op" | head -1 | grep -qx "item $ac_op (operator)"'
    hb write --transcript "$ac_relcopy" --doc "$DOC" --worktree "$T/wt" --out "$T/out/$ac_label-rel.md" >/dev/null 2>&1; rrc=$?
    hb verify --brief "$T/out/$ac_label-rel.md" --transcript "$ac_relcopy" >"$T/$ac_label-rel.out" 2>&1; rvc=$?
    check "$ac_label: the operator message made a relayed one is no delivery: the brief never verifies" '[ "$rrc" = 0 ] && [ "$rvc" = 1 ] && grep -q "verify failed: no-delivery" "$T/$ac_label-rel.out"'
}

echo "adapter-codex (a raw Codex rollout, which the old writer turned into an empty brief that verified ok)"
CX="$FX/codex-rollout.jsonl"
cx_op="L$(grep -n RULING-OP "$CX" | head -1 | cut -d: -f1)"; cx_rel="L$(grep -n RELAYED-A "$CX" | head -1 | cut -d: -f1)"
jq -c 'if ((.payload.content? // null) | type) == "array" and (((.payload.content[0].text? // "") | startswith("RULING-OP")))
       then .payload.content[0].text |= "[T3 Code: the agent in T3 thread \"thread:fixture-a\" sent this message, not the user.]\n\n" + . else . end' "$CX" >"$T/codex-rel.jsonl"
check "the jq built a relayed copy of the operator row and left the rest" '[ "$(wc -l <"$T/codex-rel.jsonl")" = "$(wc -l <"$CX")" ] && [ "$(grep -c "thread:fixture-a" "$T/codex-rel.jsonl")" = 1 ]'
adapter_checks codex "$CX" "$cx_op" "$cx_rel" "$T/codex-rel.jsonl"

echo "adapter-t3-items (a Gemini thread: the T3 thread items, an antigravity transcript is no file)"
GM="$FX/t3-thread-items.json"
gm_op="L$(( $(jq '[.items[] | select(.text | startswith("RULING-OP"))][0].position' "$GM") + 1 ))"
gm_rel="L$(( $(jq '[.items[] | select(.text | startswith("RELAYED-A"))][0].position' "$GM") + 1 ))"
jq '(.items[] | select(.text | startswith("RULING-OP"))) |= (.createdBy = "agent" | .creationSource = "mcp" | .senderThreadId = "thread:fixture-a")' "$GM" >"$T/gm-rel.json"
adapter_checks gemini "$GM" "$gm_op" "$gm_rel" "$T/gm-rel.json"
jq '(.items[] | select(.text | startswith("OWN-1"))) |= (.textTruncated = true | .nextTextOffset = 20)' "$GM" >"$T/gm-trunc.json"
hb write --transcript "$T/gm-trunc.json" --doc "$DOC" --worktree "$T/wt" --out "$T/out/gm-trunc.md" >/dev/null 2>"$T/gm-trunc.err"; gtrc=$?
check "gemini: an item the thread read cut off is no input: write exits 3 naming textTruncated" '[ "$gtrc" = 3 ] && grep -q "textTruncated" "$T/gm-trunc.err" && [ ! -e "$T/out/gm-trunc.md" ]'
jq '(.items[] | select(.text | startswith("RELAYED-B"))) |= del(.senderThreadId)' "$GM" >"$T/gm-nosender.json"
hb write --transcript "$T/gm-nosender.json" --doc "$DOC" --worktree "$T/wt" --out "$T/out/gm-nosender.md" >"$T/gm-nosender.out" 2>&1; gnrc=$?
check "gemini: a relayed item with no sender thread, newer than the newest delivery: write exits 3" '[ "$gnrc" = 3 ] && [ ! -e "$T/out/gm-nosender.md" ]'

echo "hop-brief: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
