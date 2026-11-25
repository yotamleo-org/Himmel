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
#   g. the queue library is a static source (the hook-integrity walk resolves it in both layouts) bound to the startup config by
#      equality, and the registered hook commands adopt and release through the real recorder and runner.
#   h. the library is spelled from CLAUDE_PROJECT_DIR: the project layout and the plugin copy's own layout adopt, verify,
#      finish and clean up; a missing, empty, relative, decoy or library-less project root refuses and nothing is sourced.
#   i. cleanup is a SessionEnd hook: it returns inside the 3 s budget its plugin entry declares while the lease is still held, a
#      detached copy releases it shortly after (rows wait for that with a bounded poll), a cleanup stopped by its bound leaves
#      the lease, the attempt directory and one cleanup-failed line for a chief, and under Codex the entry touches nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/readiness-session.sh"
PLUGIN_COPY="$HERE/../../marketplace/plugins/himmel-ops/scripts/readiness-session.sh"
QL="$(cd "$HERE/../handover" && pwd -P)/queue-lock.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
PROJ="$REPO_ROOT"

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
# The environment a session hook runs under: CLAUDE_PROJECT_DIR is the project root (Claude Code exports it to a hook; the
# adapter exports its own checkout's root to the child it runs). PROJ_ENV overrides it for ONE call: __unset__ (not
# exported at all), __empty__ (exported empty), or any other value verbatim.
penv() {
  case "${PROJ_ENV-}" in
    '') env -i CLAUDE_PROJECT_DIR="$PROJ" "$@" ;;
    __unset__) env -i "$@" ;;
    __empty__) env -i CLAUDE_PROJECT_DIR= "$@" ;;
    *) env -i CLAUDE_PROJECT_DIR="$PROJ_ENV" "$@" ;;
  esac
}
henv() { penv PATH="$PATH" HOME="$FAKEHOME" XDG_RUNTIME_DIR="$XDG" HANDOVER_DIR="$HD" "$@"; }
ql_status() { qenv bash "$QL" status "$1" 2>/dev/null | tail -n 1; }
ql_owner() { jq -r .session "$(find "$HD/.locks/queue" -maxdepth 1 -name "*$(basename "$1" .md | tr -c 'A-Za-z0-9_\n-' '-')*.lock" | head -n 1)/owner.json" 2>/dev/null; }
# The cleanup verb returns at once and a detached copy does the release, so a row waits for the effect it asserts with a bounded
# poll (every 0.1 s, never a fixed sleep); CLEAN_WAIT is the upper bound for the success and the failure case alike.
CLEAN_WAIT=20
poll() { # <seconds> <command...>: succeeds as soon as the command does, fails when the time is up
  local max=$(($1 * 10)) i=0; shift
  while ! "$@"; do i=$((i + 1)); [ "$i" -lt "$max" ] || return 1; sleep 0.1; done
}
# shellcheck disable=SC2329  # both are run through poll
path_gone() { [ ! -e "$1" ]; }
# shellcheck disable=SC2329
path_there() { [ -e "$1" ]; }

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
  printf '%s' "$payload" | henv "$@" bash "$HOOK" "$verb" > "$tmp/out" 2> "$tmp/err"; H_RC=$?
  H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
}
# adapter <verb> <dir>: what the adapter runs (no hook JSON, an environment of PATH, HOME and the checkout's CLAUDE_PROJECT_DIR)
adapter() {
  penv PATH="$PATH" HOME="$FAKEHOME" bash "$HOOK" "$@" > "$tmp/out" 2> "$tmp/err"; H_RC=$?
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
  printf '%s' "$junk" | henv bash "$HOOK" startup > "$tmp/out" 2> "$tmp/err"; H_RC=$?; H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
  check "b. hook payload '$junk' is a silent no-op" "$H_RC:$H_OUT:$H_ERR" "0::"
done
refused "junk hook payloads"

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
good_attempt; first_dir="$A_DIR"; first_doc="$A_DOC"; good_attempt
drop_registration "$first_doc" both
adapter verify "$first_dir"; check "c. an attempt whose own registration is gone refuses even though another attempt is adopted" "$H_RC" "1"
adapter verify "$A_DIR"; check "c. ... while the other adopted attempt still verifies" "$H_RC" "0"

good_attempt
adapter finish "$A_DIR"
check "d. finish releases the adopted lease: exit 0 and quiet" "$H_RC:$H_OUT:$H_ERR" "0::"
check "d. ... the lock is free" "$(ql_status "$A_DOC")" "free"
check "d. ... the attempt directory (confirmation, startup config, any credential file) is removed" "$([ -e "$A_DIR" ] && echo present || echo gone)" "gone"
check "d. ... and the registration is forgotten" "$(grep -rlF -- "$A_DOC" "$XDG/himmel-queue-lock" 2>/dev/null | wc -l | tr -d ' ')" "0"
good_attempt; touch "$A_DIR/credentials.json"; chmod 600 "$A_DIR/credentials.json"; adapter finish "$A_DIR"
check "d. finish also removes a credential file" "$([ -e "$A_DIR" ] && echo present || echo gone)" "gone"
adapter finish "$A_DIR"; check "d. finish after finish refuses (no confirmation any more)" "$H_RC" "1"
good_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-d1 >/dev/null 2>&1
adapter finish "$A_DIR"
check "d. finish refuses when the lock changed hands and the successor keeps it" "$H_RC:$(ql_owner "$A_DOC")" "1:succ-token-d1"
check "d. ... and the attempt directory is kept (nothing was released)" "$([ -e "$A_DIR" ] && echo present || echo gone)" "present"
mk_attempt; adapter finish "$A_DIR"
check "d. finish before adoption refuses and leaves the lease and transport" "$H_RC:$(ql_owner "$A_DOC"):$([ -e "$A_DIR/lease-token" ] && echo kept)" "1:$A_TOK:kept"
good_attempt; chmod 555 "$XDG/himmel-readiness"; adapter finish "$A_DIR"; chmod 700 "$XDG/himmel-readiness"
check "d. finish whose attempt directory survives (a read-only attempts root) exits non-zero after releasing the lease" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "1:free:present"
check "d. ... and says why" "$H_ERR" "readiness-session: attempt-dir-kept"
rm -rf "$A_DIR"
good_attempt; hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
check "d. cleanup of an adopted session releases its lease and removes its directory" "$H_RC:$H_OUT:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0::free:gone"
mk_attempt; hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
check "d. cleanup of an unadopted session releases the transported token and removes the directory" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:free:gone"
mk_attempt; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-d2 >/dev/null 2>&1; hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_there "$A_DIR/cleanup-failed"
check "d. cleanup never releases a successor's lock" "$H_RC:$(ql_owner "$A_DOC")" "0:succ-token-d2"
check "d. ... the refused cleanup leaves the attempt directory and one line saying why" "$([ -e "$A_DIR" ] && echo present || echo gone):$(wc -l < "$A_DIR/cleanup-failed" 2>/dev/null | tr -d ' '):$(grep -c 'refused: readiness-session: release refused' "$A_DIR/cleanup-failed" 2>/dev/null)" "present:1:1"
hook cleanup "$(uuid)"; check "d. cleanup of a session with no attempt directory is a silent no-op" "$H_RC:$H_OUT:$H_ERR" "0::"
hook bogus "$(uuid)"; check "d. an unknown verb is a usage error" "$H_RC" "2"

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
mk_attempt; before="$(scope_files)"; mkdir -p "$tmp/lnk-$n" "$tmp/tgt-$n"; : > "$tmp/tgt-$n/real.jsonl"; ln -s "$tmp/tgt-$n/real.jsonl" "$tmp/lnk-$n/$A_SID.jsonl"
H_TR="$tmp/lnk-$n/$A_SID.jsonl" hook startup "$A_SID"
check "f. a symlink with the session's exact transcript name, pointing at a regular file: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "an exact-name symlinked transcript" "$before"
mk_attempt; before="$(scope_files)"; : > "$tmp/other.jsonl"; H_TR="$tmp/other.jsonl" hook startup "$A_SID"
check "f. a transcript that is not named for this session: reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "a transcript named for another session" "$before"
mk_attempt; before="$(scope_files)"; other_id="$(uuid)"; : > "$tmp/$other_id.jsonl"; H_TR="$tmp/$other_id.jsonl" hook startup "$A_SID"
check "f. another session's transcript (a valid-looking uuid name): reason" "$H_ERR" "readiness-session: no-transcript"; not_adopted "another session's transcript" "$before"
mk_attempt; before="$(scope_files)"
printf '{"session_id":"%s","hook_event_name":"SessionStart","transcript_path":["x"]}' "$A_SID" | henv bash "$HOOK" startup > "$tmp/out" 2> "$tmp/err"; H_RC=$?; H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
check "f. a non-string transcript_path: silent exit 0, one reason" "$H_RC:$H_OUT:$H_ERR" "0::readiness-session: no-transcript"; not_adopted "a non-string transcript_path" "$before"
f_good() { mk_attempt; hook startup "$A_SID"; check "f. setup: a good adoption" "$(confirmed)" "yes"; }
f_verify_refuses() { adapter verify "$A_DIR"; check "f. $1: verify refuses" "$H_RC" "1"; check "f. $1: verify prints only a reason code" "$([ -z "$H_OUT" ] && echo quiet)" "quiet"; no_leak "f. $1"; }
f_good; rm -f "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"; f_verify_refuses "the session's transcript removed"
f_good; rm -f "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "the liveness marker removed"
f_good; printf 'host=%s\ntranscript=%s\n' "some-other-host" "$FAKEHOME/.claude/projects/p/$A_SID.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming another host"
f_good; : > "$tmp/elsewhere.jsonl"; printf 'host=%s\ntranscript=%s\n' "$(lv_hostname)" "$tmp/elsewhere.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming a transcript of another session"
f_good; printf 'host=%s\ntranscript=%s\n' "$(lv_hostname)" "relative/$A_SID.jsonl" > "$(lockdir_of "$A_DOC")/liveness"; f_verify_refuses "a marker naming a relative transcript"
f_good; adapter verify "$A_DIR"; check "f. a good adoption still verifies after all of the above" "$H_RC" "0"
# the act check reads an unparsable heartbeat as unknown, never as fresh: only a young transcript can then authorise
f_tr() { printf '%s' "$FAKEHOME/.claude/projects/p/$A_SID.jsonl"; }
set_hb() { local o; o="$(lockdir_of "$A_DOC")/owner.json"; jq -c ".heartbeat = $1" "$o" > "$tmp/o.json" && cat "$tmp/o.json" > "$o"; }
f_good; set_hb '"not-a-date"'; touch -t 202001010000 "$(f_tr)"; f_verify_refuses "an unparsable heartbeat and an old transcript"
f_good; set_hb '"not-a-date"'; adapter verify "$A_DIR"; check "f. an unparsable heartbeat and a young transcript verifies" "$H_RC" "0"
f_good; set_hb '"2020-01-01T00:00:00Z"'; touch -t 202001010000 "$(f_tr)"; f_verify_refuses "a parsable old heartbeat and an old transcript"
# SessionEnd after the session lost its transcript: verify fails, and the session still releases its own lease
f_good; rm -f "$(f_tr)"; H_TR="$(f_tr)" hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
check "f. cleanup of an adopted session whose transcript is gone releases its own lease and removes its directory" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:free:gone"
f_good; rm -f "$(f_tr)"; qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1; qenv bash "$QL" acquire "$A_DOC" succ-token-f1 >/dev/null 2>&1
H_TR="$(f_tr)" hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_there "$A_DIR/cleanup-failed"
check "f. ... a successor's lease is never released, and the directory stays with one line saying why" "$(ql_owner "$A_DOC"):$(wc -l < "$A_DIR/cleanup-failed" 2>/dev/null | tr -d ' ')" "succ-token-f1:1"
f_good; rm -f "$(f_tr)"; drop_registration "$A_DOC" sidecar
grep -rlxF -- "$A_TOK" "$XDG/himmel-queue-lock" | while IFS= read -r tf; do rm -f -- "$tf"; done
H_TR="$(f_tr)" hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_there "$A_DIR/cleanup-failed"
check "f. ... with no token left to release, the lease and the directory stay with one line saying why" "$(ql_owner "$A_DOC"):$(wc -l < "$A_DIR/cleanup-failed" 2>/dev/null | tr -d ' ')" "$A_TOK:1"
qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1
# an interrupted adoption resumes: a run killed after publishing and before removing the transport, and a partial write
f_good; printf '%s\n' "$A_TOK" > "$A_DIR/lease-token"; chmod 600 "$A_DIR/lease-token"; hook startup "$A_SID"
check "f. a repeat startup completes an adoption whose transport was left behind" "$H_RC:$H_ERR:$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo present || echo gone)" "0::yes:gone"
adapter verify "$A_DIR"; check "f. ... and verify then succeeds" "$H_RC" "0"
mkdir -p "$tmp/shim"
cat > "$tmp/shim/jq" <<SH
#!/bin/sh
if [ "\${1:-}" = -cn ]; then printf '{"schema":"readiness-att'; exit 1; fi
exec "$(command -v jq)" "\$@"
SH
chmod +x "$tmp/shim/jq"
mk_attempt; hook startup "$A_SID" PATH="$tmp/shim:$PATH"
check "f. a failed confirmation write leaves no partial confirmation behind" "$H_ERR:$(find "$A_DIR" -name '*confirmation*' | wc -l | tr -d ' ')" "readiness-session: confirmation-not-published:0"
hook startup "$A_SID"
check "f. ... and a healthy repeat startup adopts" "$H_RC:$H_ERR:$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo present || echo gone)" "0::yes:gone"
adapter verify "$A_DIR"; check "f. ... and verify then succeeds" "$H_RC" "0"

# --- g. the queue library is a STATIC source bound to the startup config by equality, and the registered hook commands
#        adopt and release through the REAL recorder and runner (cycle 5 review F1)
PLUGIN_ROOT="$REPO_ROOT/marketplace/plugins/himmel-ops"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# the walk the runner makes: the files the script sources (transitively) and every source statement it could not resolve
closure_of() { # <root> <rel script> -> {"files":[...],"unresolved":[...]}
  node -e '
const m = require(process.argv[1]); const path = require("path");
const root = process.argv[2]; const seen = new Set(); const queue = [process.argv[3]]; const bad = [];
while (queue.length) {
  const rel = queue.shift(); if (seen.has(rel)) continue; seen.add(rel);
  const r = m.sourcedClosure(path.join(root, rel), root);
  for (const u of r.unresolved) bad.push(rel + ": " + u);
  for (const lib of r.libs) queue.push(path.relative(root, lib));
}
console.log(JSON.stringify({ files: [...seen].sort(), unresolved: bad }));
' "$HERE/hook-integrity.js" "$1" "$2" 2>&1
}
CLO="$(closure_of "$REPO_ROOT" scripts/hooks/readiness-session.sh)"
check "g. the session script's whole sourced closure resolves statically (no source statement the integrity walk cannot turn into a file)" "$(printf '%s' "$CLO" | jq -c '.unresolved' 2>/dev/null || echo "$CLO")" "[]"
check "g. the one handover library it sources is the real queue-lock.sh" "$(printf '%s' "$CLO" | jq -c '[.files[] | select(startswith("scripts/handover/"))]' 2>/dev/null || echo "$CLO")" '["scripts/handover/queue-lock.sh"]'
# the control: the old dynamic spelling is exactly what the walk refuses, so the two rows above discriminate
mkdir -p "$tmp/wroot/scripts/hooks" "$tmp/wroot/scripts/lib"
# the two libraries the cleanup verb sources resolve in this root, so only the queue library statements are in question
cp -p "$REPO_ROOT/scripts/lib/detach.sh" "$REPO_ROOT/scripts/lib/timeout-bin.sh" "$tmp/wroot/scripts/lib/"
# shellcheck disable=SC2016  # the sed program is literal text: the variable names are the file's own spelling
sed 's/\. "\$RS_QL_LIB"/. "$RS_QL"/' "$HOOK" > "$tmp/wroot/scripts/hooks/readiness-session.sh"
check "g. control: sourcing the startup-bound variable instead is unresolved in all three statements" "$(closure_of "$tmp/wroot" scripts/hooks/readiness-session.sh | jq -c '.unresolved | length' 2>/dev/null || echo broken)" "3"
# the plugin copy is walked at its OWN location: its library resolves through CLAUDE_PROJECT_DIR to the same project file
PCLO="$(closure_of "$REPO_ROOT" marketplace/plugins/himmel-ops/scripts/readiness-session.sh)"
check "g. the plugin copy's whole sourced closure resolves statically too, to the same one handover library" "$(printf '%s' "$PCLO" | jq -c '[.unresolved, [.files[] | select(startswith("scripts/handover/"))]]' 2>/dev/null || echo "$PCLO")" '[[],["scripts/handover/queue-lock.sh"]]'
# the control: a prefix the walk does not model (any variable other than the project root) leaves the library unresolved
# shellcheck disable=SC2016  # the sed program is literal text: the variable names are the file's own spelling
sed 's#^RS_QL_LIB="\${CLAUDE_PROJECT_DIR:-}/scripts#RS_QL_LIB="${RS_PROJECT_ROOT:-}/scripts#' "$HOOK" > "$tmp/wroot/scripts/hooks/readiness-session.sh"
check "g. control: a library prefix that is not the project root is unresolved in all three statements" "$(closure_of "$tmp/wroot" scripts/hooks/readiness-session.sh | jq -c '.unresolved | length' 2>/dev/null || echo broken)" "3"

# a startup queue_lock that is not the sourced library never runs: the equality check refuses it before any source
mkdir -p "$tmp/decoy"; printf 'touch "%s"\n' "$tmp/decoy-sourced" > "$tmp/decoy/queue-lock.sh"
decoy_untouched() { [ -e "$tmp/decoy-sourced" ] && echo sourced || echo untouched; }
mk_attempt; jq --arg q "$tmp/decoy/queue-lock.sh" '.queue_lock = $q' "$A_DIR/startup.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/startup.json"
hook startup "$A_SID"
check "g. a startup queue_lock that is another file: reason" "$H_ERR" "readiness-session: startup-queue-lock"
check "g. ... the decoy library is never sourced" "$(decoy_untouched)" "untouched"
check "g. ... nothing is adopted: no confirmation, the transport and the lease untouched" "$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo kept):$(ql_owner "$A_DOC")" "no:kept:$A_TOK"
adapter verify "$A_DIR"
check "g. ... verify refuses and the decoy is still never sourced" "$H_RC:$(decoy_untouched)" "1:untouched"
good_attempt; jq --arg q "$tmp/decoy/queue-lock.sh" '.queue_lock = $q' "$A_DIR/startup.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/startup.json"
adapter verify "$A_DIR"
check "g. an adopted attempt whose startup queue_lock was swapped for another file: verify refuses and the decoy is never sourced" "$H_RC:$(decoy_untouched)" "1:untouched"
adapter finish "$A_DIR"
check "g. ... finish refuses too, the lease is kept and the decoy is never sourced" "$H_RC:$(ql_owner "$A_DOC"):$(decoy_untouched)" "1:$A_TOK:untouched"

# the registered commands, through the real recorder and runner, on a real project repository holding the real script
START_CMD="$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("scripts/hooks/readiness-session.sh") and endswith(" startup"))] | if length == 1 then .[0] else "" end' "$HOOKS_JSON")"
END_CMD="$(jq -r '[.hooks.SessionEnd[].hooks[].command | select(contains("scripts/hooks/readiness-session.sh") and endswith(" cleanup"))] | if length == 1 then .[0] else "" end' "$HOOKS_JSON")"
check "g. the normal plugin inventory registers exactly one startup (SessionStart) and one cleanup (SessionEnd) command, each with its verb" "$([ -n "$START_CMD" ] && [ -n "$END_CMD" ] && echo both || echo missing)" "both"
GP="$tmp/gproj"; GREC="$tmp/grec"
gg() { git -C "$GP" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }
# g_project [sed-expression]: a fresh project repo (own origin, published anchor) holding the real script's sourced closure
g_project() {
  rm -rf "$GP" "$tmp/gorigin.git" "$GREC"; mkdir -p "$GP" "$GREC"
  git init -q -b main "$GP" && git init -q --bare -b main "$tmp/gorigin.git" && gg remote add origin "$tmp/gorigin.git" || return 1
  local rel
  while IFS= read -r rel; do
    mkdir -p "$GP/$(dirname "$rel")"; cp -p "$REPO_ROOT/$rel" "$GP/$rel"
  done < <(printf '%s' "$CLO" | jq -r '.files[]')
  [ -z "${1:-}" ] || sed -i.bak "$1" "$GP/scripts/hooks/readiness-session.sh" && rm -f "$GP/scripts/hooks/readiness-session.sh.bak"
  gg add -A && gg commit -q -m fixture && gg push -q origin main:refs/heads/main && gg fetch -q origin
}
g_record() { printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$1" | env -i PATH="$PATH" HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$GP" HIMMEL_HOOK_INTEGRITY_DIR="$GREC" bash "$HERE/record-hook-integrity.sh" > /dev/null 2>&1; }
g_run() { # <command> <session id> <event>: the registered command exactly as Claude Code runs it (sh -c), payload on stdin
  local tr="$FAKEHOME/.claude/projects/p/$2.jsonl" payload
  mkdir -p "$FAKEHOME/.claude/projects/p"; : > "$tr"
  payload="$(jq -cn --arg sid "$2" --arg tr "$tr" --arg ev "$3" '{session_id:$sid,hook_event_name:$ev,source:"startup",transcript_path:$tr}')"
  env -i PATH="$PATH" HOME="$FAKEHOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$GP" HIMMEL_HOOK_INTEGRITY_DIR="$GREC" XDG_RUNTIME_DIR="$XDG" HANDOVER_DIR="$HD" HIMMEL_READINESS=1 sh -c "$1" <<< "$payload" > "$tmp/out" 2> "$tmp/err"; H_RC=$?
  H_OUT="$(cat "$tmp/out")"; H_ERR="$(cat "$tmp/err")"
}
# g_attempt: a launcher-shaped attempt whose startup queue_lock is THIS project's queue-lock.sh, recorded for its session id
g_attempt() { QL_REAL="$QL"; QL="$GP/scripts/handover/queue-lock.sh"; mk_attempt; QL="$QL_REAL"; g_record "$A_SID"; }
if g_project; then
  g_attempt
  check "g. setup: the real recorder wrote the session's record" "$([ -f "$GREC/$A_SID.json" ] && echo recorded || echo none)" "recorded"
  g_run "$START_CMD" "$A_SID" SessionStart
  check "g. the registered startup command adopts through the real runner: exit 0 and nothing on stdout" "$H_RC:$H_OUT" "0:"
  check "g. ... the confirmation is published and the transport is gone" "$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo present || echo gone)" "yes:gone"
  check "g. ... the lease is still held by the transported token and fresh" "$(ql_owner "$A_DOC"):$(ql_status "$A_DOC")" "$A_TOK:status: FRESH"
  no_leak "g. the registered startup command"
  HOOK_REAL="$HOOK"; HOOK="$GP/scripts/hooks/readiness-session.sh"; PROJ_ENV="$GP" adapter verify "$A_DIR"; HOOK="$HOOK_REAL"
  check "g. ... and the adapter's verify (from the same project) succeeds" "$H_RC:$H_OUT:$H_ERR" "0::"
  g_run "$END_CMD" "$A_SID" SessionEnd; poll "$CLEAN_WAIT" path_gone "$A_DIR"
  check "g. the registered cleanup command releases the adopted lease and removes the attempt through the real runner" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:free:gone"
  before_tree="$(find "$XDG" "$HD" 2>/dev/null | sort | md5sum)"; generic="$(uuid)"
  g_record "$generic"; g_run "$START_CMD" "$generic" SessionStart; gs="$H_RC:$H_OUT:$H_ERR"; g_run "$END_CMD" "$generic" SessionEnd
  check "g. a generic session: startup and cleanup are silent exit-0 no-ops and touch neither the queue nor the runtime directory" "$gs:$H_RC:$H_OUT:$H_ERR:$([ "$before_tree" = "$(find "$XDG" "$HD" 2>/dev/null | sort | md5sum)" ] && echo unchanged || echo changed)" "0:::0:::unchanged"
  g_attempt; printf '\n# tampered after the session pin\n' >> "$GP/scripts/handover/queue-lock.sh"
  g_run "$START_CMD" "$A_SID" SessionStart
  check "g. tamper: an edited queue-lock.sh is denied by the runner (exit 2) and names the library" "$H_RC:$(printf '%s' "$H_ERR" | grep -c 'queue-lock.sh')" "2:1"
  check "g. ... and nothing is adopted: no confirmation, the transport and the lease untouched" "$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo kept):$(ql_owner "$A_DOC")" "no:kept:$A_TOK"
else
  check "g. setup: the project fixture could not be built" "unavailable" "available"
fi
# unresolvable: the old dynamic spelling is denied by the real runner before the script runs
# shellcheck disable=SC2016  # the sed program is literal text: the variable names are the file's own spelling
if g_project 's/\. "\$RS_QL_LIB"/. "$RS_QL"/'; then
  g_attempt; g_run "$START_CMD" "$A_SID" SessionStart
  check "g. unresolvable: a script sourcing the startup-bound variable is denied by the runner (exit 2, unresolved source)" "$H_RC:$(printf '%s' "$H_ERR" | grep -c 'unresolved source statement')" "2:1"
  check "g. ... and nothing is adopted: no confirmation, the transport and the lease untouched" "$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo kept):$(ql_owner "$A_DOC")" "no:kept:$A_TOK"
else
  check "g. setup: the unresolvable-source fixture could not be built" "unavailable" "available"
fi
if g_project; then
  g_attempt; jq --arg q "$tmp/decoy/queue-lock.sh" '.queue_lock = $q' "$A_DIR/startup.json" > "$tmp/t.json" && cat "$tmp/t.json" > "$A_DIR/startup.json"
  g_run "$START_CMD" "$A_SID" SessionStart
  check "g. refusal: a startup queue_lock naming another file adopts nothing through the real runner and the decoy is never sourced" "$H_RC:$(confirmed):$(ql_owner "$A_DOC"):$(decoy_untouched)" "0:no:$A_TOK:untouched"
else
  check "g. setup: the refusal fixture could not be built" "unavailable" "available"
fi

# --- h. the queue library is bound to CLAUDE_PROJECT_DIR (cycle 5 recheck R2-1): the registered project layout AND the plugin
#        copy's own layout adopt, verify, finish and clean up; a missing, empty, relative, wrong or decoy project directory
#        refuses and the decoy library is never sourced
with_hook() { local saved="$HOOK" rc; HOOK="$1"; shift; "$@"; rc=$?; HOOK="$saved"; return "$rc"; }
mkdir -p "$tmp/dproj/scripts/handover" "$tmp/emptyproj"; printf 'touch "%s"\n' "$tmp/decoy-sourced" > "$tmp/dproj/scripts/handover/queue-lock.sh"
ln -s "$REPO_ROOT" "$tmp/projlink"
h_good() { mk_attempt; hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID"; check "h. setup: a good adoption" "$(confirmed)" "yes"; }
for tool_label in project plugin; do
  tool="$HOOK"; [ "$tool_label" = plugin ] && tool="$PLUGIN_COPY"
  # the layout adopts, verifies, finishes and cleans up (the plugin copy has no ../handover sibling; the project root supplies the library)
  mk_attempt; with_hook "$tool" hook startup "$A_SID" CLAUDE_CODE_SESSION_ID="$A_SID"
  check "h. $tool_label layout: startup adopts: exit 0, silent, the confirmation published, the transport gone" "$H_RC:$H_OUT:$H_ERR:$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo present || echo gone)" "0:::yes:gone"
  no_leak "h. $tool_label layout startup"
  check "h. $tool_label layout: the lock is still held by the transported token and fresh" "$(ql_owner "$A_DOC"):$(ql_status "$A_DOC")" "$A_TOK:status: FRESH"
  with_hook "$tool" adapter verify "$A_DIR"
  check "h. $tool_label layout: verify (run with the checkout's project root) succeeds" "$H_RC:$H_OUT:$H_ERR" "0::"
  with_hook "$tool" adapter finish "$A_DIR"
  check "h. $tool_label layout: finish releases exactly the adopted lease and removes the attempt" "$H_RC:$H_OUT:$H_ERR:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:::free:gone"
  mk_attempt; with_hook "$tool" hook startup "$A_SID"; with_hook "$tool" hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
  check "h. $tool_label layout: cleanup of an adopted session releases its lease and removes its directory" "$H_RC:$H_OUT:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0::free:gone"
  mk_attempt; with_hook "$tool" hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
  check "h. $tool_label layout: cleanup of an unadopted session releases the transported token and removes the directory" "$H_RC:$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "0:free:gone"
  mk_attempt; PROJ_ENV="$tmp/projlink" with_hook "$tool" hook startup "$A_SID"
  check "h. $tool_label layout: a symlinked spelling of the same project root adopts (equal physical directory)" "$H_RC:$(confirmed)" "0:yes"
  adapter finish "$A_DIR"
  for mode in __unset__ __empty__ relative decoy nolib; do
    pe="$mode"; cwd="$tmp"
    case "$mode" in relative) pe="."; cwd="$REPO_ROOT" ;; decoy) pe="$tmp/dproj" ;; nolib) pe="$tmp/emptyproj" ;; esac
    mk_attempt; before="$(scope_files)"
    back="$PWD"; cd "$cwd" || exit 1; PROJ_ENV="$pe" with_hook "$tool" hook startup "$A_SID"; cd "$back" || exit 1
    check "h. $tool_label layout, $mode project root: startup refuses with the one reason code" "$H_RC:$H_OUT:$H_ERR" "0::readiness-session: startup-queue-lock"
    check "h. $tool_label layout, $mode project root: nothing is adopted: no confirmation, the transport kept, the lease still the transported token's" "$(confirmed):$([ -e "$A_DIR/lease-token" ] && echo kept):$(ql_owner "$A_DOC")" "no:kept:$A_TOK"
    check "h. $tool_label layout, $mode project root: nothing is registered and the decoy library is never sourced" "$(scope_files):$(decoy_untouched)" "$before:untouched"
  done
  for mode in __unset__ relative decoy; do
    pe="$mode"; cwd="$tmp"
    case "$mode" in relative) pe="."; cwd="$REPO_ROOT" ;; decoy) pe="$tmp/dproj" ;; esac
    h_good; back="$PWD"; cd "$cwd" || exit 1
    PROJ_ENV="$pe" with_hook "$tool" adapter verify "$A_DIR"; v_rc="$H_RC"; v_out="$H_OUT"
    PROJ_ENV="$pe" with_hook "$tool" adapter finish "$A_DIR"; f_rc="$H_RC"
    cd "$back" || exit 1
    check "h. $tool_label layout, $mode project root on an adopted attempt: verify and finish refuse quietly, the decoy is never sourced" "$v_rc:$v_out:$f_rc:$(decoy_untouched)" "1::1:untouched"
    check "h. $tool_label layout, $mode project root on an adopted attempt: the lease is kept and the attempt stays" "$(ql_owner "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "$A_TOK:present"
    with_hook "$tool" adapter verify "$A_DIR"
    check "h. $tool_label layout: ... and the right project root still verifies the same attempt" "$H_RC" "0"
    with_hook "$tool" adapter finish "$A_DIR"
  done
done

# --- i. cleanup is a SessionEnd hook: it returns inside the declared budget, a detached copy releases afterwards under a bound,
#        and a cleanup that is stopped leaves the lease and the attempt directory where a chief can see them
DECLARED="$(jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | endswith(" cleanup")) | .timeout] | .[0]' "$HOOKS_JSON")"
check "i. the registered cleanup declares the 3 s budget of the other SessionEnd hooks" "$DECLARED" "3"
good_attempt
i_t0="$(date +%s)"; hook cleanup "$A_SID" READINESS_SESSION_TEST_DELAY=5; i_t1="$(date +%s)"
check "i. cleanup returns inside the declared budget while its release still waits: exit 0, silent" "$H_RC:$H_OUT:$H_ERR:$([ $((i_t1 - i_t0)) -lt "$DECLARED" ] && echo inside || echo over)" "0:::inside"
check "i. ... the lease is still held and the attempt directory still there when it returns" "$(ql_owner "$A_DOC"):$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "$A_TOK:status: FRESH:present"
poll "$CLEAN_WAIT" path_gone "$A_DIR"
check "i. ... and the detached copy releases the lease shortly after and removes the directory" "$(ql_status "$A_DOC"):$([ -e "$A_DIR" ] && echo present || echo gone)" "free:gone"
# a cleanup that its bound stops: the lease stays held, the directory stays, one line says why, and the chief's sweep lists the lease
good_attempt; hook cleanup "$A_SID" READINESS_SESSION_TEST_DELAY=60 READINESS_SESSION_CLEANUP_BOUND_SECS=1; poll "$CLEAN_WAIT" path_there "$A_DIR/cleanup-failed"
check "i. a cleanup stopped by its bound leaves the lease held, the confirmation in place and one line saying so" "$(ql_owner "$A_DOC"):$(ql_status "$A_DOC"):$([ -e "$A_DIR/confirmation.json" ] && echo kept || echo lost):$(wc -l < "$A_DIR/cleanup-failed" 2>/dev/null | tr -d ' '):$(grep -c 'did not finish within 1s and was stopped' "$A_DIR/cleanup-failed" 2>/dev/null)" "$A_TOK:status: FRESH:kept:1:1"
check "i. ... and queue-lock.sh status --sweep (the chief's LOCKS check) lists that lease" "$(qenv bash "$QL" status --sweep "$HD" 2>/dev/null | grep -cF -- "session=$A_TOK ")" "1"
qenv bash "$QL" release "$A_DOC" "$A_TOK" >/dev/null 2>&1
# Codex: a plugin hook has CLAUDE_PLUGIN_ROOT and no CLAUDE_PROJECT_DIR, so the registered entry exits without touching the script
good_attempt
cx_payload="$(jq -cn --arg sid "$A_SID" '{session_id:$sid,hook_event_name:"SessionEnd",reason:"other"}')"
cx_t0="$(date +%s)"
env -i PATH="$PATH" HOME="$FAKEHOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" XDG_RUNTIME_DIR="$XDG" HANDOVER_DIR="$HD" sh -c "$END_CMD" <<< "$cx_payload" > "$tmp/out" 2> "$tmp/err"; cx_rc=$?
cx_t1="$(date +%s)"
check "i. Codex (no CLAUDE_PROJECT_DIR): the registered cleanup exits 0, silent, inside the budget" "$cx_rc:$(cat "$tmp/out"):$(cat "$tmp/err"):$([ $((cx_t1 - cx_t0)) -lt "$DECLARED" ] && echo inside || echo over)" "0:::inside"
check "i. ... and it released nothing: the lease and the directory are still there after a bounded wait for any release" "$(poll 2 path_gone "$A_DIR" && echo released || echo untouched):$(ql_owner "$A_DOC")" "untouched:$A_TOK"
hook cleanup "$A_SID"; poll "$CLEAN_WAIT" path_gone "$A_DIR"
check "i. ... control: the same attempt is released once the project root is present" "$(ql_status "$A_DOC")" "free"

check "e. the himmel-ops plugin copy is byte-identical" "$(cmp -s "$HOOK" "$PLUGIN_COPY" && echo same || echo differs)" "same"
check "e. the plugin copy is executable like its source" "$([ -x "$PLUGIN_COPY" ] && echo yes || echo no)" "yes"

adapter verify "$GOOD_DIR"; check "a. the first attempt is still adopted and verifies after every other case" "$H_RC" "0"
adapter finish "$GOOD_DIR"; check "a. ... and its finish releases only its own lease" "$H_RC:$(ql_status "$GOOD_DOC")" "0:free"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-readiness-session.sh"; exit 0; fi
echo "FAIL - test-readiness-session.sh ($fails failure(s))"; exit 1
