#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the check() shape of the sibling suites
# test-readiness-session.sh - suite for scripts/hooks/readiness-session.sh, the readiness role's trusted session-side
# lease owner (C0s cycle 2): SessionStart adoption + private AttemptConfirmation, the adapter's per-act verify and
# finish, and session cleanup.
#
# Everything runs the REAL readiness-session.sh against the REAL, unchanged queue-lock.sh in a scratch handover root,
# runtime directory and HOME. No native claude, provider, VM, real queue, real config or secret is touched, and this
# suite does NOT prove that Claude Code delivers the SessionStart hook or its PostToolUse self-heartbeat (that is C0v).
#
# Asserts:
#   a. startup: the ACTUAL hook session id equals the minted scope -> the on-behalf lease is adopted with the scope set
#      explicitly, the same-scope token file + .doc sidecar + current holder are verified, ONLY THEN the exact private
#      AttemptConfirmation (mode 0600, seven fields) is published and the transport removed; nothing is printed.
#   b. every wrong shape publishes nothing (so every act and finish refuse): another session id, a mismatched
#      CLAUDE_CODE_SESSION_ID, a tampered scope, a missing/loose/symlinked transport, a loose attempt directory or startup
#      file, a bad startup field, a token that is not the holder's, a lease that changed hands. A session with no attempt
#      directory is a silent no-op.
#   c. verify (run before EVERY act): fresh and consistent confirmation + current holder, else exit 1; a lost
#      registration, a changed holder, a reappeared transport or a tampered confirmation each refuse.
#   d. finish / cleanup release exactly the adopted (or unadopted transport) token and never a successor's lock.
#   e. no token or credential reaches any stdout/stderr; the plugin copy is byte-identical.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/readiness-session.sh"
PLUGIN_COPY="$HERE/../../marketplace/plugins/himmel-ops/scripts/readiness-session.sh"
QL="$(cd "$HERE/../handover" && pwd -P)/queue-lock.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/readiness-session-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
XDG="$tmp/xdg"; HD="$tmp/hd"; FAKEHOME="$tmp/home"
mkdir -p "$HD/u/r" "$FAKEHOME/.claude"; mkdir -m 700 "$XDG"
# pin every queue-lock input to this scratch root; nothing ambient may reach the real queue
unset QUEUE_LOCK_SESSION_SCOPE QUEUE_LOCK_ON_BEHALF QUEUE_LOCK_FORCE_RELEASE QUEUE_LOCK_TAKEOVER CLAUDE_CODE_SESSION_ID HANDOVER_DIR XDG_RUNTIME_DIR CLAUDE_CONFIG_DIR 2>/dev/null || true

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
modeof() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-F' 'a-f'; }
qenv() { env -i PATH="$PATH" HOME="$FAKEHOME" XDG_RUNTIME_DIR="$XDG" HANDOVER_DIR="$HD" "$@"; }
ql_status() { qenv bash "$QL" status "$1" 2>/dev/null | tail -n 1; }
ql_owner() { jq -r .session "$(find "$HD/.locks/queue" -maxdepth 1 -name "*$(basename "$1" .md | tr -c 'A-Za-z0-9_\n-' '-')*.lock" | head -n 1)/owner.json" 2>/dev/null; }

n=0
# mk_attempt: a launcher-shaped attempt (what headed-arm-worker.sh leaves) -> A_DOC A_SID A_DIR A_TOK
mk_attempt() {
  n=$((n + 1))
  A_DOC="$HD/u/r/readiness-v1.$n.0.md"; printf -- '---\ndescription: fixture\n---\n' > "$A_DOC"
  A_SID="$(uuid)"; A_DIR="$XDG/himmel-readiness/$A_SID"
  mkdir -p "$XDG/himmel-readiness"; chmod 700 "$XDG/himmel-readiness"; mkdir -m 700 "$A_DIR"
  jq -n --arg sid "$A_SID" --arg ver "v1.$n.0" --arg doc "$A_DOC" --arg ql "$QL" --arg xdg "$XDG" --arg hd "$HD" \
    '{schema:"readiness-startup-v1",attempt_id:("attempt-" + $sid),session_scope:$sid,version:$ver,doc:$doc,lane:"native",model:"fixture-model",queue_lock:$ql,runtime_dir:$xdg,handover_dir:$hd,port:{kind:"copy"}}' > "$A_DIR/startup.json"
  chmod 600 "$A_DIR/startup.json"
  # shellcheck disable=SC2016 # the backticks around the token are literal text in acquire's output
  A_TOK="$(qenv env QUEUE_LOCK_ON_BEHALF=1 bash "$QL" acquire "$A_DOC" 2>/dev/null | sed -n 's/^release-token: `\(.*\)`$/\1/p' | tail -n 1)"
  printf '%s\n' "$A_TOK" > "$A_DIR/lease-token"; chmod 600 "$A_DIR/lease-token"
}
# startup <sid> [ENV=val ...] / cleanup <sid>: the hook, fed the hook JSON on stdin; H_OUT H_ERR H_RC
# The payload carries the session's own transcript_path (what Claude Code sends): by default <home>/.claude/projects/p/<sid>.jsonl,
# created here. H_TR=<path> sends exactly that path (not created); H_TR= (empty) sends no transcript_path at all.
hook() {
  local verb="$1" sid="$2" tr payload; shift 2
  tr="$FAKEHOME/.claude/projects/p/$sid.jsonl"
  if [ "${H_TR+set}" = set ]; then tr="$H_TR"; else mkdir -p "$FAKEHOME/.claude/projects/p"; : > "$tr"; fi
  payload="$(jq -cn --arg sid "$sid" --arg tr "$tr" '{session_id:$sid,hook_event_name:"SessionStart",source:"startup"} + (if $tr == "" then {} else {transcript_path:$tr} end)')"
  printf '%s' "$payload" | qenv "$@" bash "$HOOK" "$verb" > "$tmp/out" 2> "$tmp/err"; H_RC=$?
  H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
}
# adapter <verb> <dir>: what the adapter runs (no hook JSON, an empty environment but PATH)
adapter() {
  env -i PATH="$PATH" HOME="$FAKEHOME" bash "$HOOK" "$@" > "$tmp/out" 2> "$tmp/err"; H_RC=$?
  H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
}
# drop_registration <doc> <both|sidecar>: lose this doc's registration (and only its) from the scope token directory
drop_registration() {
  local sc
  while IFS= read -r sc; do
    [ -n "$sc" ] || continue
    grep -qxF -- "$1" "$sc" || continue
    rm -f -- "$sc"
    [ "$2" != both ] || rm -f -- "${sc%.doc}"
  done < <(find "$XDG/himmel-queue-lock" -type f -name '*.doc')
}
confirmed() { [ -f "$A_DIR/confirmation.json" ] && echo yes || echo no; }
scope_files() { find "$XDG/himmel-queue-lock" -type f 2>/dev/null | wc -l | tr -d ' '; }
no_leak() { # no_leak <label> : the token is in no captured output
  local hit=no
  grep -qF -- "$A_TOK" "$tmp/out" "$tmp/err" 2>/dev/null && hit=yes
  check "$1: the token reaches neither stdout nor stderr" "$hit" "no"
}

# --- a. a good adoption
mk_attempt
check "a. the on-behalf lease is held by the transported token before the session starts" "$(ql_owner "$A_DOC")" "$A_TOK"
check "a. nothing is registered for any scope before the session adopts" "$(scope_files)" "0"
lockdir_of() { find "$HD/.locks/queue" -maxdepth 1 -name "*$(basename "$1" .md | tr -c 'A-Za-z0-9_\n-' '-')*.lock" | head -n 1; }
check "a. the unadopted lease carries no liveness marker" "$([ -e "$(lockdir_of "$A_DOC")/liveness" ] && echo marker || echo none)" "none"
mkdir -p "$FAKEHOME/.claude/projects/p"; : > "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"
hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID" CLAUDE_CONFIG_DIR="$FAKEHOME/.claude"
check "a. startup exits 0 and prints nothing on stdout" "$H_RC:$H_OUT" "0:"
check "a. startup prints nothing on stderr either" "$H_ERR" ""
no_leak "a. startup"
check "a. the AttemptConfirmation is published, mode 0600, exactly the seven signed fields" \
  "$(modeof "$A_DIR/confirmation.json"):$(jq -S -c . "$A_DIR/confirmation.json" 2>/dev/null)" \
  "600:$(jq -S -c -n --arg sid "$A_SID" --arg doc "$A_DOC" --arg ver "v1.$n.0" '{adopted:true,attempt_id:("attempt-" + $sid),doc:$doc,schema:"readiness-attempt-v1",session_scope:$sid,startup_session_id:$sid,version:$ver}')"
check "a. the confirmation carries no token" "$(grep -cF -- "$A_TOK" "$A_DIR/confirmation.json")" "0"
check "a. the transport is removed after adoption" "$([ -e "$A_DIR/lease-token" ] && echo present || echo gone)" "gone"
check "a. the lock is still held by the same token and fresh" "$(ql_owner "$A_DOC"):$(ql_status "$A_DOC")" "$A_TOK:status: FRESH"
check "a. the same-scope token file and .doc sidecar are registered (and only they)" "$(scope_files)" "2"
check "a. the adopted lease carries the session's OWN transcript as its liveness marker" "$(sed -n 's/^transcript=//p' "$(lockdir_of "$A_DOC")/liveness" 2>/dev/null)" "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"
check "a. the sidecar names the doc" "$(grep -rlF -- "$A_DOC" "$XDG/himmel-queue-lock" | wc -l | tr -d ' ')" "1"
adapter verify "$A_DIR"
check "a. verify succeeds on the adopted attempt" "$H_RC:$H_OUT:$H_ERR" "0::"
no_leak "a. verify"
cp "$A_DIR/confirmation.json" "$tmp/confirmation.before"
hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID" CLAUDE_CONFIG_DIR="$FAKEHOME/.claude"
check "a. a repeated startup (resume, compaction) is a silent no-op that leaves the confirmation byte-identical" "$H_RC:$H_OUT:$H_ERR:$(cmp -s "$tmp/confirmation.before" "$A_DIR/confirmation.json" && echo same)" "0:::same"
check "a. ... and registers nothing twice" "$(scope_files)" "2"
GOOD_DIR="$A_DIR"; GOOD_DOC="$A_DOC"

# --- b. every wrong shape publishes nothing and leaves the lease and transport exactly as the launcher left them
refused() { # refused <label> : no confirmation, the lease still held by the transported token, transport untouched
  check "b. $1: exits 0 (a hook never blocks)" "$H_RC" "0"
  check "b. $1: stdout stays empty" "$H_OUT" ""
  check "b. $1: no confirmation is published" "$(confirmed)" "no"
  check "b. $1: the lease still belongs to the transported token" "$(ql_owner "$A_DOC")" "$A_TOK"
  check "b. $1: nothing was registered for the attempt's scope" "$(find "$XDG/himmel-queue-lock" -type f 2>/dev/null | grep -c . | tr -d ' ')" "2"
  no_leak "b. $1"
  adapter verify "$A_DIR"
  check "b. $1: verify refuses" "$H_RC" "1"
}
mk_attempt
other="$(uuid)"
hook startup "$other"
check "b. a session with no attempt directory is a silent no-op" "$H_RC:$H_OUT:$H_ERR" "0::"
check "b. ... and creates nothing" "$([ -e "$XDG/himmel-readiness/$other" ] && echo yes || echo no)" "no"
refused "another session started (the minted id never started)"
hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$other"
check "b. a CLAUDE_CODE_SESSION_ID that differs from the hook's: one reason code" "$H_ERR" "readiness-session: session-id-mismatch"
refused "a CLAUDE_CODE_SESSION_ID that differs from the hook session id"
for junk in '' 'not json' '{"session_id":"not-a-uuid"}' '{"session_id":["x"]}' '[]' '{"hook_event_name":"SessionStart"}'; do
  printf '%s' "$junk" | qenv bash "$HOOK" startup > "$tmp/out" 2> "$tmp/err"; H_RC=$?; H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
  check "b. hook payload '$junk' is a silent no-op" "$H_RC:$H_OUT:$H_ERR" "0::"
done
refused "junk hook payloads"

# the attempt directory, startup file and transport must be exactly the private shapes
mk_attempt; chmod 755 "$A_DIR"; hook startup "$A_SID"; chmod 700 "$A_DIR"
check "b. a loose attempt directory: reason" "$H_ERR" "readiness-session: attempt-dir"; refused "a loose (0755) attempt directory"
mk_attempt; chmod 644 "$A_DIR/startup.json"; hook startup "$A_SID"; chmod 600 "$A_DIR/startup.json"
check "b. a loose startup file: reason" "$H_ERR" "readiness-session: startup-file"; refused "a loose (0644) startup file"
mk_attempt; chmod 644 "$A_DIR/lease-token"; hook startup "$A_SID"; chmod 600 "$A_DIR/lease-token"
check "b. a loose transport: reason" "$H_ERR" "readiness-session: no-transport"; refused "a loose (0644) transport"
mk_attempt; mv "$A_DIR/lease-token" "$tmp/real-token"; ln -s "$tmp/real-token" "$A_DIR/lease-token"; hook startup "$A_SID"
check "b. a symlinked transport: reason" "$H_ERR" "readiness-session: no-transport"; refused "a symlinked transport"
mk_attempt; ln "$A_DIR/lease-token" "$tmp/hardlink"; hook startup "$A_SID"
check "b. a transport with two links: reason" "$H_ERR" "readiness-session: no-transport"; refused "a hard-linked transport"
mk_attempt; rm -f "$A_DIR/lease-token"; hook startup "$A_SID"
check "b. a missing transport: reason" "$H_ERR" "readiness-session: no-transport"; refused "a missing transport"
mk_attempt
jq --arg s "$(uuid)" '.session_scope = $s' "$A_DIR/startup.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/startup.json"; hook startup "$A_SID"
check "b. a startup file whose scope is not its directory's id: reason" "$H_ERR" "readiness-session: scope-dir-mismatch"; refused "a tampered scope"
for mut in '.lane = "claudex"' '.schema = "other"' '.doc = "relative.md"' '.doc = "/no/such/doc.md"' '.queue_lock = "relative/queue-lock.sh"' '.queue_lock = "/bin/true"' '.attempt_id = ""' '.version = ""' '.runtime_dir = "relative"' 'del(.session_scope)'; do
  mk_attempt; jq "$mut" "$A_DIR/startup.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/startup.json"; hook startup "$A_SID"
  refused "a startup file with the mutation $mut"
done
# a token that is not the holder's: adopt itself refuses
mk_attempt; printf '%s\n' "somebody-elses-token" > "$A_DIR/lease-token"; hook startup "$A_SID"
check "b. a transport token that is not the holder's: reason" "$H_ERR" "readiness-session: adopt-refused"; refused "a transport token that is not the holder's"
# the lease changed hands between the launch and the session start (a successor holds it now)
mk_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-b1 >/dev/null 2>&1
hook startup "$A_SID"
check "b. a lease that changed hands: reason" "$H_ERR" "readiness-session: adopt-refused"
check "b. ... and the successor's lock is untouched" "$(ql_owner "$A_DOC")" "succ-token-b1"
check "b. ... and no confirmation is published" "$(confirmed)" "no"
adapter finish "$A_DIR"
check "b. ... finish refuses and the successor still holds it" "$H_RC:$(ql_owner "$A_DOC")" "1:succ-token-b1"

# --- c. verify refuses every drift after a good adoption
good_attempt() { mk_attempt; hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID"; check "c. setup: a good adoption" "$(confirmed)" "yes"; }
verify_refuses() { adapter verify "$A_DIR"; check "c. $1: verify refuses" "$H_RC" "1"; check "c. $1: verify prints only a reason code" "$([ -z "$H_OUT" ] && echo quiet)" "quiet"; no_leak "c. $1"; }
good_attempt; rm -f "$A_DIR/confirmation.json"; verify_refuses "a missing confirmation"
good_attempt; jq '.adopted = false' "$A_DIR/confirmation.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/confirmation.json"; verify_refuses "adopted: false"
good_attempt; jq '.attempt_id = "other"' "$A_DIR/confirmation.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/confirmation.json"; verify_refuses "another attempt id"
good_attempt; jq '.startup_session_id = "other"' "$A_DIR/confirmation.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/confirmation.json"; verify_refuses "a startup identity that is not the scope"
good_attempt; jq '.extra = 1' "$A_DIR/confirmation.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/confirmation.json"; verify_refuses "an extra confirmation field"
good_attempt; jq '.doc = "/other.md"' "$A_DIR/confirmation.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/confirmation.json"; verify_refuses "another doc"
good_attempt; chmod 644 "$A_DIR/confirmation.json"; verify_refuses "a loose confirmation"
good_attempt; printf '%s\n' "$A_TOK" > "$A_DIR/lease-token"; chmod 600 "$A_DIR/lease-token"; verify_refuses "a reappeared transport"
good_attempt; drop_registration "$A_DOC" both; verify_refuses "a lost registration (token file and sidecar gone)"
good_attempt; drop_registration "$A_DOC" sidecar; verify_refuses "a lost sidecar"
good_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; verify_refuses "a released lock"
good_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-c1 >/dev/null 2>&1; verify_refuses "a lock that changed hands"
check "c. ... and the successor still holds it" "$(ql_owner "$A_DOC")" "succ-token-c1"
good_attempt; chmod 755 "$A_DIR"; verify_refuses "a loose attempt directory"; chmod 700 "$A_DIR"
adapter verify "relative/dir"; check "c. a relative attempt directory refuses" "$H_RC" "1"
adapter verify "$tmp/no-such-dir"; check "c. a missing attempt directory refuses" "$H_RC" "1"
adapter verify; check "c. a missing operand is a usage error" "$H_RC" "2"
# a second session's registration never satisfies another attempt: verify reads the attempt's OWN scope
good_attempt; first_dir="$A_DIR"; first_doc="$A_DOC"; good_attempt
drop_registration "$first_doc" both
adapter verify "$first_dir"; check "c. an attempt whose own registration is gone refuses even though another attempt is adopted" "$H_RC" "1"
adapter verify "$A_DIR"; check "c. ... while the other adopted attempt still verifies" "$H_RC" "0"

# --- d. finish / cleanup
good_attempt
adapter finish "$A_DIR"
check "d. finish releases the adopted lease: exit 0 and quiet" "$H_RC:$H_OUT:$H_ERR" "0::"
check "d. ... the lock is free" "$(ql_status "$A_DOC")" "free"
check "d. ... the attempt directory (confirmation, startup config, any credential file) is removed" "$([ -e "$A_DIR" ] && echo present || echo gone)" "gone"
check "d. ... and the registration is forgotten" "$(grep -rlF -- "$A_DOC" "$XDG/himmel-queue-lock" 2>/dev/null | wc -l | tr -d ' ')" "0"
good_attempt; touch "$A_DIR/credentials.json"; chmod 600 "$A_DIR/credentials.json"; adapter finish "$A_DIR"
check "d. finish also removes a credential file" "$([ -e "$A_DIR" ] && echo present || echo gone)" "gone"
adapter finish "$A_DIR"; check "d. finish after finish refuses (no confirmation any more)" "$H_RC" "1"
# a successor holds the lock: finish never releases it
good_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-d1 >/dev/null 2>&1
adapter finish "$A_DIR"
check "d. finish refuses when the lock changed hands and the successor keeps it" "$H_RC:$(ql_owner "$A_DOC")" "1:succ-token-d1"
check "d. ... and the attempt directory is kept (nothing was released)" "$([ -e "$A_DIR" ] && echo present || echo gone)" "present"
# finish on an unadopted attempt: nothing is released
mk_attempt; adapter finish "$A_DIR"
check "d. finish before adoption refuses and leaves the lease and transport" "$H_RC:$(ql_owner "$A_DOC"):$([ -e "$A_DIR/lease-token" ] && echo kept)" "1:$A_TOK:kept"
# cleanup (SessionEnd): adopted
good_attempt; hook cleanup "$A_SID"
check "d. cleanup of an adopted session releases its lease and removes its directory" "$H_RC:$H_OUT:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0::free:gone"
# cleanup: unadopted (the session ended before it adopted): the transport token releases it
mk_attempt; hook cleanup "$A_SID"
check "d. cleanup of an unadopted session releases the transported token and removes the directory" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:free:gone"
# cleanup never releases a successor
mk_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-d2 >/dev/null 2>&1; hook cleanup "$A_SID"
check "d. cleanup never releases a successor's lock" "$H_RC:$(ql_owner "$A_DOC")" "0:succ-token-d2"
hook cleanup "$(uuid)"; check "d. cleanup of a session with no attempt directory is a silent no-op" "$H_RC:$H_OUT:$H_ERR" "0::"
hook bogus "$(uuid)"; check "d. an unknown verb is a usage error" "$H_RC" "2"

# --- f. liveness comes from the ACTUAL SessionStart payload (session_id + transcript_path), never from an ambient environment
lv_field() { sed -n "s/^$2=//p" "$(lockdir_of "$1")/liveness" 2>/dev/null | head -n 1; }
# shellcheck disable=SC2016  # the literal $1 belongs to the inner bash, which sources the real queue-lock.sh and asks it for its own host name
lv_hostname() { qenv bash -c '. "$1" >/dev/null 2>&1; _ql_hostname' x "$QL"; }
# an unadopted attempt must stay exactly as the launcher left it: no confirmation, the same holder, nothing registered, no marker
not_adopted() { # not_adopted <label> <registered-files-before>
  check "f. $1: no confirmation is published" "$(confirmed)" "no"
  check "f. $1: the lease still belongs to the transported token, and its transport is kept" "$(ql_owner "$A_DOC"):$([ -e "$A_DIR/lease-token" ] && echo kept)" "$A_TOK:kept"
  check "f. $1: nothing was registered for the attempt's scope" "$(scope_files)" "$2"
  check "f. $1: no liveness marker was written" "$([ -e "$(lockdir_of "$A_DOC")/liveness" ] && echo marker || echo none)" "none"
  no_leak "f. $1"
  adapter verify "$A_DIR"; check "f. $1: verify refuses" "$H_RC" "1"
}
mkdir -p "$FAKEHOME/.claude/projects/p"
# the positive control: NO CLAUDE_CODE_SESSION_ID, NO CLAUDE_CONFIG_DIR - the payload alone drives the session identity and the liveness marker
mk_attempt; before="$(scope_files)"
hook startup "$A_SID"
check "f. env unset: startup exits 0, silent" "$H_RC:$H_OUT:$H_ERR" "0::"
check "f. env unset: the confirmation is published" "$(confirmed)" "yes"
check "f. env unset: the adopted lease's liveness marker names this host and the PAYLOAD's transcript" \
  "$(lv_field "$A_DOC" host):$(lv_field "$A_DOC" transcript)" "$(lv_hostname):$FAKEHOME/.claude/projects/p/$A_SID.jsonl"
adapter verify "$A_DIR"; check "f. env unset: verify succeeds" "$H_RC:$H_OUT:$H_ERR" "0::"
# an ambient CLAUDE_CODE_SESSION_ID / CLAUDE_CONFIG_DIR that would find ANOTHER transcript never decides the marker
mk_attempt; mkdir -p "$tmp/decoy/projects/q"; : > "$tmp/decoy/projects/q/$A_SID.jsonl"
hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID" CLAUDE_CONFIG_DIR="$tmp/decoy"
check "f. an ambient config dir holding a decoy transcript: the marker still names the payload's transcript" "$(lv_field "$A_DOC" transcript)" "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"
# no valid transcript in the payload: nothing is adopted, registered or published (the unadopted transport stays for SessionEnd)
mk_attempt; before="$(scope_files)"; H_TR='' hook startup "$A_SID"
check "f. a payload with no transcript_path: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a payload with no transcript_path" "$before"
mk_attempt; before="$(scope_files)"; H_TR="$tmp/never-written/$A_SID.jsonl" hook startup "$A_SID"
check "f. a missing transcript: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a transcript file that does not exist" "$before"
mk_attempt; before="$(scope_files)"; H_TR="relative/$A_SID.jsonl" hook startup "$A_SID"
check "f. a relative transcript path: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a relative transcript path" "$before"
mk_attempt; before="$(scope_files)"; mkdir -p "$tmp/dirtr/$A_SID.jsonl"; H_TR="$tmp/dirtr/$A_SID.jsonl" hook startup "$A_SID"
check "f. a transcript that is a directory: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a transcript that is a directory" "$before"
mk_attempt; before="$(scope_files)"; : > "$tmp/real-$A_SID.jsonl"; ln -s "$tmp/real-$A_SID.jsonl" "$tmp/link-$A_SID.jsonl"; H_TR="$tmp/link-$A_SID.jsonl" hook startup "$A_SID"
check "f. a symlinked transcript: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a symlinked transcript" "$before"
mk_attempt; before="$(scope_files)"; : > "$tmp/other.jsonl"; H_TR="$tmp/other.jsonl" hook startup "$A_SID"
check "f. a transcript that is not named for this session: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a transcript named for another session" "$before"
mk_attempt; before="$(scope_files)"; other_id="$(uuid)"; : > "$tmp/$other_id.jsonl"; H_TR="$tmp/$other_id.jsonl" hook startup "$A_SID"
check "f. another session's transcript (a valid-looking uuid name): reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "another session's transcript" "$before"
mk_attempt; before="$(scope_files)"
printf '{"session_id":"%s","hook_event_name":"SessionStart","transcript_path":["x"]}' "$A_SID" | qenv bash "$HOOK" startup > "$tmp/out" 2> "$tmp/err"; H_RC=$?; H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
check "f. a non-string transcript_path: silent exit 0, one reason" "$H_RC:$H_OUT:$H_ERR" "0::readiness-session: no-transcript"; not_adopted "a non-string transcript_path" "$before"
# after a good adoption the marker is part of every fresh check: verify refuses when it is gone, wrong or its transcript vanished
f_good() { mk_attempt; hook startup "$A_SID"; check "f. setup: a good adoption" "$(confirmed)" "yes"; }
f_verify_refuses() { adapter verify "$A_DIR"; check "f. $1: verify refuses" "$H_RC" "1"; check "f. $1: verify prints only a reason code" "$([ -z "$H_OUT" ] && echo quiet)" "quiet"; no_leak "f. $1"; }
f_good; rm -f "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"; f_verify_refuses "the session's transcript removed"
f_good; rm -f "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "the liveness marker removed"
f_good; printf 'host=%s\ntranscript=%s\n' "some-other-host" "$FAKEHOME/.claude/projects/p/$A_SID.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming another host"
f_good; : > "$tmp/elsewhere.jsonl"; printf 'host=%s\ntranscript=%s\n' "$(lv_hostname)" "$tmp/elsewhere.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming a transcript of another session"
f_good; printf 'host=%s\ntranscript=%s\n' "$(lv_hostname)" "relative/$A_SID.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming a relative transcript"
f_good; adapter verify "$A_DIR"; check "f. a good adoption still verifies after all of the above" "$H_RC" "0"

# --- e. the plugin copy
check "e. the himmel-ops plugin copy is byte-identical" "$(cmp -s "$HOOK" "$PLUGIN_COPY" && echo same || echo differs)" "same"
check "e. the plugin copy is executable like its source" "$([ -x "$PLUGIN_COPY" ] && echo yes || echo no)" "yes"

# the first adopted attempt of section a still verifies after everything above (sessions never interfere)
adapter verify "$GOOD_DIR"; check "a. the first attempt is still adopted and verifies after every other case" "$H_RC" "0"
adapter finish "$GOOD_DIR"; check "a. ... and its finish releases only its own lease" "$H_RC:$(ql_status "$GOOD_DOC")" "0:free"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-readiness-session.sh"; exit 0; fi
echo "FAIL - test-readiness-session.sh ($fails failure(s))"; exit 1
