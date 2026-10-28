#!/usr/bin/env bash
# test-escape-class-corpus.sh — differential escape-class test across every
# PreToolUse Bash guard.
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
block-himmel-config-writes.sh|||deny|||-|||-|||cp /tmp/f ~/.himmel/config.json
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
allow-thread-resolve.sh|||exempt|||-|||-|||-
'
# Exempt rows (each is printed as EXEMPT on every run, never skipped silently):
#   read-clamp.sh, require-quiet-run.sh — workflow NUDGES, not security fences;
#     scripts/hooks/CLAUDE.md "Fail-open vs fail-closed" says they prefer a false
#     negative to a false positive, and read-clamp's header says it fails OPEN on
#     "an unrecognised Bash shape". The fail-closed policy applies to fences.
#   check-cr-marker-on-pr-create.sh — its deny needs a branch CR marker written
#     by the pre-push hook; the fixture for that is a follow-up.
#   allow-thread-resolve.sh — an allow-only hook: it never denies, and any shape
#     but its one anchored resolve command gets no decision, so there is no
#     protected action to wrap in a splitter-misreading construct.

# <hook> <shape-id> <ticket> — a shape the guard allows today; one Bug per guard.
KNOWN_FAILURES='
block-rogue-claude-schedule.sh bs-newline-inside-word HIMMEL-5333
guard-pr-check-literal.sh ansi-c-command-word HIMMEL-5335
# block-git-stash.sh keeps only its literal core; these evasion
# shapes are accepted misses, not chased.
block-git-stash.sh expansion-default-empty HIMMEL-5745
block-git-stash.sh expansion-strip-empty HIMMEL-5745
block-git-stash.sh expansion-indirect-empty HIMMEL-5745
block-git-stash.sh expansion-adjacent-empty HIMMEL-5745
block-git-stash.sh expansion-empty-arg HIMMEL-5745
block-git-stash.sh zsh-modifier-tail-braceless HIMMEL-5745
block-git-stash.sh zsh-modifier-tail-braced HIMMEL-5745
block-git-stash.sh zsh-modifier-root-braceless HIMMEL-5745
block-git-stash.sh zsh-modifier-root-braced HIMMEL-5745
block-git-stash.sh zsh-subscript-braceless HIMMEL-5745
block-git-stash.sh zsh-subscript-braced HIMMEL-5745
block-git-stash.sh zsh-paramflag-indirect-empty HIMMEL-5745
block-git-stash.sh zsh-modifier-empty-arg HIMMEL-5745
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
  out=$(cd "$T/repo" && printf '%s' "$json" | env -i HOME="$T/home" PATH="$PATH" TMPDIR="$T/tmp" \
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
NOT_COMMAND_GUARDS=" auto-arm-on-cap.sh guard-worker-context-handoff.sh block-subagent-park.sh guard-identical-denied-retry.sh run-hook-with-bash.js "
missing=""
for h in $wired; do
  case "$NOT_COMMAND_GUARDS" in *" $h "*) continue ;; esac
  case "
$declared
" in *"
$h
"*) ;; *) missing="$missing $h" ;; esac
done
if [ -z "$wired" ]; then
  fail=$((fail+1)); echo "FAIL completeness: no Bash-matched hook read from $SETTINGS (missing, unparseable or empty)"
elif [ -n "$missing" ]; then
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
  case "$p1" in *=*)
    case "$tmpl" in *@@P1@@*|*@@PS@@*) return 1 ;; esac
    # an assignment only stays an assignment at command-word position: a row
    # whose probe showed bash running `ZZ=1 printf` as a command name (an
    # expansion before it) never executes the protected action, so "allow" is
    # right for it. When the probe could not run, only the plain control is safe.
    case " $ASSIGN_SKIP " in *" ${1%%|||*} "*) return 1 ;; esac
    [ -z "$ASSIGN_UNKNOWN" ] || [ "${1%%|||*}" = plain-prefix-control ] || return 1 ;;
  esac
  ps="$(printf '%s' "$p1" | cut -c1)\\${NL}$(printf '%s' "$p1" | cut -c2-) $pr"
  subst "$tmpl" '<NL>' "$NL"; c="$SUBST"
  subst "$c" '@@PS@@' "$ps"; c="$SUBST"
  subst "$c" '@@P1@@' "$p1"; c="$SUBST"
  subst "$c" '@@PR@@' "$pr"; c="$SUBST"
  subst "$c" '@@P@@' "$payload"; BUILT="$SUBST"
}

shape_lines=$(grep -v '^#' "$SHAPES" 2>/dev/null | grep -v '^[[:space:]]*$')
if [ -z "$shape_lines" ]; then
  fail=$((fail+1)); echo "FAIL corpus: no shapes read from $SHAPES (missing, unreadable or empty)"
fi
ASSIGN_SKIP=""      # shape ids whose template breaks a leading VAR=value payload
ASSIGN_UNKNOWN=""   # set when the probe could not run (no sandbox)

# ---- shape self-check: bash itself must run the payload in every shape -------
# A row that does not execute its payload makes "allow" the right answer and
# would teach guards to over-deny, so each row is run once with a harmless
# printf payload inside the sandbox runner (never unconfined; a missing sandbox
# is a loud SKIP, not an unsandboxed run).
if bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- bash -c 'exit 0' >/dev/null 2>&1; then
  while IFS= read -r line; do
    id="${line%%|||*}"
    build "$line" "printf PAYLOAD_RAN" || continue
    case "$id" in
      zsh-*) command -v zsh >/dev/null 2>&1 || { echo "SKIP shape $id: zsh is not installed"; ASSIGN_SKIP="$ASSIGN_SKIP $id"; continue; }
             got=$(bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- env -u V -u Z -u Q -u R zsh -fc "$BUILT" 2>/dev/null </dev/null) ;;
      *) got=$(bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- env -u V -u Z -u Q -u R bash -c "$BUILT" 2>/dev/null </dev/null) ;;
    esac
    case "$got" in
      *PAYLOAD_RAN*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); echo "FAIL shape $id: bash did not run the payload (got: $got)" ;;
    esac
    # second probe: a payload that LEADS with VAR=value (an env prefix)
    build "$line" "ZZ_ASSIGN=1 printf PAYLOAD_RAN" || continue
    case "$id" in
      zsh-*) command -v zsh >/dev/null 2>&1 || { ASSIGN_SKIP="$ASSIGN_SKIP $id"; continue; }
             got=$(bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- env -u V -u Z -u Q -u R zsh -fc "$BUILT" 2>/dev/null </dev/null) ;;
      *) got=$(bash "$REPO_ROOT/scripts/lib/sandbox-run.sh" -- env -u V -u Z -u Q -u R bash -c "$BUILT" 2>/dev/null </dev/null) ;;
    esac
    case "$got" in *PAYLOAD_RAN*) ;; *) ASSIGN_SKIP="$ASSIGN_SKIP $id" ;; esac
  done <<EOF
$shape_lines
EOF
else
  echo "SKIP shape self-check: sandbox-run.sh has no confinement here (bwrap/prlimit/sandbox-exec)"
  ASSIGN_UNKNOWN=1
fi
[ -z "$ASSIGN_SKIP" ] || echo "NOTE rows not applied to a leading VAR=value payload (bash runs it as a command name):$ASSIGN_SKIP"

# DIAG-7120 begin (temporary, removed before the fix commit)
# shellcheck disable=SC2088 # literal ~ is payload text the hook must see
if [ -n "${GITHUB_ACTIONS:-}" ] || [ -e "$HERE/.diag-7120" ]; then
  DG=$(mktemp -d "$BASE/diag.XXXXXX") || exit 1
  mkdir -p "$DG/home"
  git init -q -b main "$DG/repo"
  cat > "$DG/run.pl" <<'PERL'
use Time::HiRes qw(time);
my ($hook, $json, $err) = @ARGV;
my $t = time;
my $pid = fork();
if (!$pid) {
  open(STDIN, '<', $json); open(STDOUT, '>', '/dev/null'); open(STDERR, '>', $err);
  exec('env', '-i', "HOME=$ENV{DG_HOME}", "PATH=$ENV{PATH}", "PS4=$ENV{DG_PS4}", @ENV{qw(DG_E1 DG_E2)}, 'bash', split(' ', $ENV{DG_BASHOPT}), $hook) or die;
}
$SIG{ALRM} = sub { kill 9, $pid; print "TIMEOUT "; };
alarm 100;
waitpid($pid, 0);
printf "rc=%d secs=%.2f\n", $? >> 8, time - $t;
PERL
  dg() { # dg LABEL HOOK COMMAND [E1 [E2 [BASHOPT]]]
    printf '%s' "$3" > "$DG/cmd.txt"
    jq -Rsc --arg d "$DG/repo" '{tool_name:"Bash",tool_input:{command:.},cwd:$d}' < "$DG/cmd.txt" > "$DG/in.json"
    printf '%s: ' "$1"
    ( cd "$DG/repo" && DG_HOME="$DG/home" DG_E1="${4:-A=1}" DG_E2="${5:-B=1}" DG_BASHOPT="${6:-}" DG_PS4='+ ${SECONDS} ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-} ' \
        perl "$DG/run.pl" "$HERE/$2" "$DG/in.json" "$DG/err" )
  }
  rep() { local n=$1 out='' i=0; while [ "$i" -lt "$n" ]; do out=$out$2; i=$((i + 1)); done; printf '%s' "$out"; }
  echo "DIAG bash=$BASH_VERSION uname=$(uname -sr) LANG=${LANG:-} LC_ALL=${LC_ALL:-}"
  U8=LC_ALL=en_US.UTF-8
  summ() { # every trace line that ran after a 2 s or longer gap: the gap is its own expansion
    awk '$1 ~ /^\++$/ && $2 ~ /^[0-9]+$/ { if (p != "" && $2 - p >= 2) printf "  gap %d->%d: %s\n", p, $2, substr($0, 1, 150); p = $2 }' "$DG/err" | head -22
  }
  # shellcheck disable=SC2016 # the snippet is program text for a fresh bash
  snip() { # snip LABEL LOCALE BODY — time BODY in a fresh bash over a 10 KB string
    {
      echo 't=$(printf "true %.0s" $(seq 2000))'
      printf '%s\n' "$3"
    } > "$DG/snip.sh"
    printf '%s %s: ' "$1" "$2"
    ( cd "$DG/repo" && DG_HOME="$DG/home" DG_E1="$2" DG_E2=B=1 DG_BASHOPT="" DG_PS4='+ ' perl "$DG/run.pl" "$DG/snip.sh" /dev/null "$DG/err" )
  }
  # shellcheck disable=SC2016 # the snippets are program text for a fresh bash
  for lc in "$U8" LC_ALL=C; do
    snip "class sed+tr 1 match" "$lc" 't="$t; x"; t=$(printf "%s" "$t" | sed -e "s/>&/> /g" -e "s/&>/ >/g" | tr "|;&(){}\`" "\n\n\n\n\n\n\n\n")'
  done
  for nw in 600 1000; do
    dg "els n=$nw dq utf8" block-edit-live-settings.sh "echo $(rep "$nw" '~/.cl$"a"ude/x ')> /tmp/out.txt" "$U8"
  done
  dg "els trace n=800 dq utf8" block-edit-live-settings.sh "echo $(rep 800 '~/.cl$"a"ude/x ')> /tmp/out.txt" "$U8" B=1 -x
  summ
  P=$(rep 2000 'true ')
  PW=$(rep 2000 'w ')
  dg "qmd pad=2000 bare utf8" block-bare-qmd-query.sh "${P}; qmd query x" "$U8"
  dg "qmd pad=2000 pipe-to-sh utf8" block-bare-qmd-query.sh "${P}; echo qmd query x | sh" "$U8"
  dg "qmd pad=2000 status utf8" block-bare-qmd-query.sh "qmd status; ${PW}" "$U8"
  dg "qmd pad=2000 bash -c utf8" block-bare-qmd-query.sh "qmd status; bash -c 'echo \$0' ${PW}" "$U8"
  dg "qmd trace pad=2000 pipe-to-sh utf8" block-bare-qmd-query.sh "${P}; echo qmd query x | sh" "$U8" B=1 -x
  summ
  dg "qmd trace pad=2000 bash -c utf8" block-bare-qmd-query.sh "qmd status; bash -c 'echo \$0' ${PW}" "$U8" B=1 -x
  summ
  rm -rf "$DG"
  exit 1
fi
# DIAG-7120 end

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
    elif [ "$V" != allow ]; then
      # a crash or odd exit status is not "the guard allowed it": never a known-fail
      fail=$((fail+1)); echo "FAIL $hook $id unexpected verdict ($V)"
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

if [ -n "${ESCAPE_CLASS_ONLY:-}" ]; then
  case "
$declared
" in *"
$ESCAPE_CLASS_ONLY
"*) ;; *) fail=$((fail+1)); echo "FAIL filter: ESCAPE_CLASS_ONLY=$ESCAPE_CLASS_ONLY matches no guard in GUARDS" ;; esac
fi

echo "escape-class: $pass passed, $kfail known-fail, $fail failed ($nshapes guards)"
[ "$fail" -eq 0 ]
