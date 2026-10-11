#!/usr/bin/env bash
# test-escape-class-corpus.sh — differential escape-class test across every
# PreToolUse Bash guard (HIMMEL-5327).
#
# For each guard below, the PLAIN payload (its protected action) is the control
# and must be denied. Then every shape in escape-class-corpus.shapes wraps that
# same payload in a construct bash still executes but a naive splitter
# misreads; the guard must deny the shape wherever it denies the control.
#
# Result per (guard, shape):
#   PASS         denied, as the control was
#   KNOWN-FAIL   allowed, and listed in KNOWN_FAILURES with its Bug ticket — CI
#                stays green but the gap is printed every run
#   FAIL         allowed and not listed, OR listed but now denied (stale entry:
#                delete it), OR the control itself is not denied (broken row)
# A guard in GUARDS with payload `-` is EXEMPT and must say why.
#
# Policy, stated once: a guard that cannot parse a shape must FAIL CLOSED for a
# command that names its protected target.
#
# COMPLETENESS: every hook wired for the Bash matcher in .claude/settings.json
# must appear in GUARDS, so a new guard (which edits wire-hook-bash.mjs and
# settings.json, both of which select this suite in PR CI) cannot ship
# unexercised. The shared splitter libs (scripts/hooks/lib/shell-tokenize.sh,
# scripts/hooks/lib/guard-unwrap.sh, scripts/hooks/lib/headless-spawn-join.sh)
# are named here so an edit to one selects this suite as well.
#
# Nothing is executed: each command is only piped to a hook as JSON. Every run
# uses a scratch HOME and a scratch git repo on main.
# Platform guard: bash 3.2-safe; needs jq and git (SKIP without).
#   ESCAPE_CLASS_ONLY=<hook.sh>  limits the run to one guard.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SHAPES="$HERE/escape-class-corpus.shapes"
SETTINGS="$REPO_ROOT/.claude/settings.json"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

# <hook>|||<mode>|||<env words, blank-separated>|||<setup>|||<payload>
#   mode  deny      protected action: denied iff rc=2 or a deny decision
#         noapprove an APPROVER: "denied" means not auto-approved
#   setup (unused today, `-`)
#   @@T@@ scratch dir, @@REPO@@ scratch git repo on main (also the cwd)
# shellcheck disable=SC2016  # payloads are literal text with $ expansions, never expanded here
GUARDS='
auto-approve-safe-bash.sh|||noapprove|||-|||-|||rm -rf /tmp/x
block-bank-lift-writes.sh|||deny|||-|||-|||echo {} > ~/.himmel/state/bank-lift.json
block-bare-qmd-query.sh|||deny|||-|||-|||qmd query hello
block-chokepoint-env-prefix.sh|||deny|||-|||-|||ARMAUTOMERGE=1 bash scripts/handover/merge-on-green.sh
block-destructive-commands.sh|||deny|||-|||-|||rm -rf /tmp/x
block-edit-live-settings.sh|||deny|||-|||-|||cp x ~/.claude/settings.json
block-git-stash.sh|||deny|||-|||-|||git stash
block-jira-compound-write.sh|||deny|||-|||-|||node /x/scripts/jira/dist/index.js create --type Task --title a --desc "$(cat /tmp/a.md)"
block-read-secrets.sh|||deny|||-|||-|||cat .env
block-rogue-claude-schedule.sh|||deny|||-|||-|||schtasks /create /tn X /tr claude.exe /sc ONCE
block-tail-pipe-on-gates.sh|||deny|||-|||-|||bash scripts/ci/run-shell-tests.sh | tail -5
block-write-into-main-checkout.sh|||deny|||-|||-|||echo x > @@REPO@@/f
guard-bus-store.sh|||deny|||-|||-|||cat ~/.himmel/bus/foo
guard-pr-check-literal.sh|||deny|||-|||-|||bash scripts/cr/pr-check-context.sh
guard-relay-writes.sh|||deny|||HIMMEL_CONSOLE_RELAY=1 HANDOVER_DIR=@@T@@/ho|||-|||echo x > @@T@@/ho/inbox/m
read-clamp.sh|||exempt|||-|||-|||-
require-quiet-run.sh|||exempt|||-|||-|||-
check-cr-marker-on-pr-create.sh|||exempt|||-|||-|||-
'
# Exempt rows (each is printed as EXEMPT on every run, never skipped silently):
#   read-clamp.sh, require-quiet-run.sh — workflow NUDGES, not security fences;
#     scripts/hooks/CLAUDE.md "Fail-open vs fail-closed" says they prefer a false
#     negative to a false positive, and read-clamp's header says it fails OPEN on
#     "an unrecognised Bash shape". The fail-closed policy applies to fences.
#   check-cr-marker-on-pr-create.sh — its deny needs a branch CR marker written
#     by the pre-push hook; the fixture for that is a follow-up.

# <hook> <shape-id> <ticket> — a shape the guard allows today; one Bug per guard.
KNOWN_FAILURES='
block-bare-qmd-query.sh expansion-default-empty HIMMEL-5328
block-bare-qmd-query.sh expansion-strip-empty HIMMEL-5328
block-bare-qmd-query.sh expansion-indirect-empty HIMMEL-5328
block-bare-qmd-query.sh expansion-adjacent-empty HIMMEL-5328
block-bare-qmd-query.sh expansion-empty-word HIMMEL-5328
block-bare-qmd-query.sh expansion-empty-arg HIMMEL-5328
block-destructive-commands.sh expansion-default-empty HIMMEL-5329
block-destructive-commands.sh expansion-strip-empty HIMMEL-5329
block-destructive-commands.sh expansion-indirect-empty HIMMEL-5329
block-destructive-commands.sh expansion-adjacent-empty HIMMEL-5329
block-destructive-commands.sh expansion-empty-word HIMMEL-5329
block-git-stash.sh expansion-default-empty HIMMEL-5330
block-git-stash.sh expansion-strip-empty HIMMEL-5330
block-git-stash.sh expansion-indirect-empty HIMMEL-5330
block-git-stash.sh expansion-adjacent-empty HIMMEL-5330
block-git-stash.sh expansion-empty-word HIMMEL-5330
block-git-stash.sh expansion-empty-arg HIMMEL-5330
block-read-secrets.sh expansion-default-empty HIMMEL-5331
block-read-secrets.sh expansion-strip-empty HIMMEL-5331
block-read-secrets.sh expansion-indirect-empty HIMMEL-5331
block-read-secrets.sh expansion-adjacent-empty HIMMEL-5331
block-read-secrets.sh expansion-empty-word HIMMEL-5331
block-jira-compound-write.sh bs-newline-inside-word HIMMEL-5332
block-jira-compound-write.sh ansi-c-escaped-quote HIMMEL-5332
block-jira-compound-write.sh ansi-c-command-word HIMMEL-5332
block-jira-compound-write.sh hash-after-escaped-blank HIMMEL-5332
block-jira-compound-write.sh hash-after-escaped-operator HIMMEL-5332
block-jira-compound-write.sh quoted-heredoc-operator HIMMEL-5332
block-jira-compound-write.sh quoted-redirect-operator HIMMEL-5332
block-jira-compound-write.sh quoted-semicolon HIMMEL-5332
block-jira-compound-write.sh expansion-adjacent-empty HIMMEL-5332
block-jira-compound-write.sh expansion-empty-word HIMMEL-5332
block-rogue-claude-schedule.sh bs-newline-inside-word HIMMEL-5333
block-tail-pipe-on-gates.sh ansi-c-escaped-quote HIMMEL-5334
block-tail-pipe-on-gates.sh heredoc-body-with-quote HIMMEL-5334
block-tail-pipe-on-gates.sh heredoc-payload-on-opener-line HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-default-empty HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-strip-empty HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-indirect-empty HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-adjacent-empty HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-empty-word HIMMEL-5334
block-tail-pipe-on-gates.sh expansion-empty-arg HIMMEL-5334
guard-pr-check-literal.sh ansi-c-command-word HIMMEL-5335
'

# block-write-into-main-checkout.sh exempts any path with a tmp/ or temp/
# component, so the scratch repo must NOT live under /tmp or $TMPDIR: /dev/shm
# on Linux, else a throwaway dir under $HOME/.cache (removed by the trap).
BASE=""
for d in /dev/shm "$HOME/.cache"; do
  mkdir -p "$d" 2>/dev/null && [ -w "$d" ] && { BASE="$d"; break; }
done
[ -n "$BASE" ] || { echo "SKIP: no writable scratch base outside tmp/"; exit 0; }
T=$(mktemp -d "$BASE/escape-class.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/ho/inbox" || exit 1
if ! git init -q -b main "$T/repo" 2>/dev/null; then echo "FAIL fixture repo"; exit 1; fi
if ! git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
       commit -q --allow-empty -m init; then echo "FAIL fixture repo"; exit 1; fi

pass=0; kfail=0; fail=0

# subst <text> <marker> <value> : replace every <marker> by <value>, byte-exact
# (no pattern replacement, so a & or \ in the value is never special).
subst() {
  local t="$1" m="$2" v="$3" out=""
  while :; do
    case "$t" in *"$m"*) ;; *) break ;; esac
    out="$out${t%%"$m"*}$v"; t="${t#*"$m"}"
  done
  SUBST="$out$t"
}

NL='
'
# verdict <hook> <mode> <env> <command> -> sets V to deny|allow|?rc=N
verdict() {
  local hook="$1" mode="$2" envs="$3" cmd="$4" json out rc
  json=$(jq -cn --arg c "$cmd" --arg d "$T/repo" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  # shellcheck disable=SC2086  # $envs is a deliberate blank-separated word list
  out=$(printf '%s' "$json" | env -i HOME="$T/home" PATH="$PATH" TMPDIR="$T/tmp" \
    $envs bash "$HERE/$hook" 2>/dev/null)
  rc=$?
  case "$rc" in
    2) V=deny; return ;;
    0) ;;
    *) V="?rc=$rc"; return ;;
  esac
  case "$out" in
    *'"permissionDecision":"deny"'*|*'"permissionDecision": "deny"'*) V=deny; return ;;
  esac
  if [ "$mode" = noapprove ]; then
    case "$out" in
      *'"permissionDecision":"allow"'*|*'"permissionDecision": "allow"'*) V=allow ;;
      *) V=deny ;;
    esac
    return
  fi
  V=allow
}

known_ticket() {  # <hook> <shape> -> prints ticket or nothing
  local h s t
  while read -r h s t; do
    [ "$h" = "$1" ] && [ "$s" = "$2" ] && { printf '%s' "$t"; return; }
  done <<EOF
$KNOWN_FAILURES
EOF
}

# ---- completeness: every Bash-matched hook is in GUARDS ----------------------
declared=$(printf '%s\n' "$GUARDS" | sed -n 's/^\([A-Za-z0-9_.-]*\.sh\)|||.*/\1/p')
wired=$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash" or .matcher=="*" or .matcher=="Bash|Monitor" or .matcher=="Bash|PowerShell")
  | .hooks[]?.command' "$SETTINGS" 2>/dev/null \
  | grep -o 'scripts/hooks/[A-Za-z0-9_.-]*\.sh' | sed 's|scripts/hooks/||' | sort -u)
# Hooks whose own header documents them as watchdogs / context nudges that never
# deny a command shape; they are wired for Bash but have no protected action.
NOT_COMMAND_GUARDS=" auto-arm-on-cap.sh guard-leg-context-handoff.sh block-subagent-park.sh run-hook-with-bash.js "
missing=""
for h in $wired; do
  case "$NOT_COMMAND_GUARDS" in *" $h "*) continue ;; esac
  case "
$declared
" in *"
$h
"*) ;; *) missing="$missing $h" ;; esac
done
if [ -n "$missing" ]; then
  fail=$((fail+1)); echo "FAIL completeness: wired for Bash but absent from GUARDS:$missing"
else
  pass=$((pass+1)); echo "PASS completeness: every Bash-matched guard is in GUARDS"
fi

# build <shapes row> <payload> : sets BUILT; returns 1 when the row does not
# apply (it rewrites the first word and the payload's first word is VAR=value).
build() {
  local tmpl="${1#*|||}" payload="$2" p1 pr ps c
  tmpl="${tmpl#*|||}"
  p1="${payload%% *}"; pr="${payload#* }"
  case "$p1" in *=*) case "$tmpl" in *@@P1@@*|*@@PS@@*) return 1 ;; esac ;; esac
  ps="$(printf '%s' "$p1" | cut -c1)\\${NL}$(printf '%s' "$p1" | cut -c2-) $pr"
  subst "$tmpl" '<NL>' "$NL"; c="$SUBST"
  subst "$c" '@@PS@@' "$ps"; c="$SUBST"
  subst "$c" '@@P1@@' "$p1"; c="$SUBST"
  subst "$c" '@@PR@@' "$pr"; c="$SUBST"
  subst "$c" '@@P@@' "$payload"; BUILT="$SUBST"
}

shape_lines=$(grep -v '^#' "$SHAPES" | grep -v '^[[:space:]]*$')

# ---- shape self-check: bash itself must run the payload in every shape -------
# A row that does not execute its payload makes "allow" the right answer and
# would teach guards to over-deny, so each row is run once with a harmless
# printf payload inside the sandbox runner (never unconfined; a missing sandbox
# is a loud SKIP, not an unsandboxed run).
if bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- bash -c 'exit 0' >/dev/null 2>&1; then
  while IFS= read -r line; do
    id="${line%%|||*}"
    build "$line" "printf PAYLOAD_RAN" || continue
    got=$(bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- bash -c "$BUILT" 2>/dev/null </dev/null)
    case "$got" in
      *PAYLOAD_RAN*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); echo "FAIL shape $id: bash did not run the payload (got: $got)" ;;
    esac
  done <<EOF
$shape_lines
EOF
else
  echo "SKIP shape self-check: sandbox-run.sh has no confinement here (bwrap/prlimit/sandbox-exec)"
fi

# ---- the differential ---------------------------------------------------------
nshapes=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  rest="$g"
  hook="${rest%%|||*}"; rest="${rest#*|||}"
  mode="${rest%%|||*}"; rest="${rest#*|||}"
  envs="${rest%%|||*}"; rest="${rest#*|||}"
  payload="${rest#*|||}"  # the setup column ('-' today) is reserved
  [ -z "${ESCAPE_CLASS_ONLY:-}" ] || [ "$ESCAPE_CLASS_ONLY" = "$hook" ] || continue
  if [ "$mode" = exempt ]; then
    echo "EXEMPT $hook (reason: the note under GUARDS)"
    continue
  fi
  subst "$payload" '@@T@@' "$T"; payload="$SUBST"
  subst "$payload" '@@REPO@@' "$T/repo"; payload="$SUBST"
  subst "$envs" '@@T@@' "$T"; envs="$SUBST"
  [ "$envs" = - ] && envs=""
  verdict "$hook" "$mode" "$envs" "$payload"
  if [ "$V" != deny ]; then
    fail=$((fail+1)); echo "FAIL $hook control not denied ($V): $payload"
    continue
  fi
  while IFS= read -r line; do
    id="${line%%|||*}"
    build "$line" "$payload" || continue
    c="$BUILT"
    verdict "$hook" "$mode" "$envs" "$c"
    tk=$(known_ticket "$hook" "$id")
    if [ "$V" = deny ]; then
      if [ -n "$tk" ]; then
        fail=$((fail+1)); echo "FAIL $hook $id is now denied but is listed KNOWN_FAILURES ($tk): remove the entry"
      else
        pass=$((pass+1))
      fi
    else
      if [ -n "$tk" ]; then
        kfail=$((kfail+1)); echo "KNOWN-FAIL $hook $id ($V) -> $tk"
      else
        fail=$((fail+1)); echo "FAIL $hook $id ($V): allowed while its control is denied"
      fi
    fi
  done <<EOF
$shape_lines
EOF
  nshapes=$((nshapes+1))
done <<EOF
$(printf '%s\n' "$GUARDS")
EOF

echo "escape-class: $pass passed, $kfail known-fail, $fail failed ($nshapes guards)"
[ "$fail" -eq 0 ]
