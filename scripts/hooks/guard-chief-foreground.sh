#!/usr/bin/env bash
# guard-chief-foreground.sh — PreToolUse hook (matcher "Bash"):
# a CHIEF session must run a long chief-kit script with the Bash tool's
# run_in_background: true, never in the foreground. A foreground run blocks the
# chief turn for minutes and every worker's SendMessage (READY, MERGED, BLOCKED,
# quote-backs) queues behind it. Prose ("run it in the background") drifted
# twice, so per root CLAUDE.md's "Adding a rule" it is a hook.
#
# TRIP CONDITION: HIMMEL_CONSOLE_DOC is set (a cheap first gate, before stdin is
# read) AND the session's own `-n` name ends in `-chief` or `-console` (a worker launched from
# a chief inherits the env var, so the name is the real identity) AND the Bash command runs a script named in
# scripts/handover/chief-kit/long-running.txt (a grep or cat that merely names
# it is not a run) AND the run is detached or tool_input.run_in_background is
# not true.
#
# DENY: structured permissionDecision "deny" on stdout plus exit 2 + stderr (the
# guard-chief-dispatch.sh idiom); the message gives the exact re-issue shape.
# A WORKFLOW nudge, not a security fence: fails OPEN on missing jq, an
# unparseable payload or an unreadable list (scripts/hooks/CLAUDE.md).
#
# Single-run bypass (set in the shell that LAUNCHED Claude Code; a per-call
# prefix does not reach this hook): CHIEF_FG_OK=1. A set falsy value keeps the
# guard on.
#
# Test seam: CHIEF_FG_LIST points at an alternate list file. Bash
# 3.2-compatible. Exit codes: 0 allow; 2 refuse.
set -uo pipefail

[ -n "${HIMMEL_CONSOLE_DOC:-}" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${CHIEF_FG_OK:-}" in
    ''|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

bg=$(printf '%s' "$input" | jq -r '.tool_input.run_in_background // false' 2>/dev/null) || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# A worker launched from a chief's Bash inherits HIMMEL_CONSOLE_DOC as ambient env,
# so the env var alone cannot tell them apart: only a session named `*-chief`/`*-console`
# is a chief (the chief-compact-reinject.sh rule). Unresolvable name: allow.
lib="$HERE/../lib/session-name.sh"
# shellcheck source=scripts/lib/session-name.sh
{ [ -r "$lib" ] && . "$lib"; } 2>/dev/null || exit 0
sname=$(current_session_name 2>/dev/null) || exit 0
case "$sname" in *-console|*-chief) ;; *) exit 0 ;; esac

list="${CHIEF_FG_LIST:-$HERE/../handover/chief-kit/long-running.txt}"
[ -r "$list" ] || exit 0

names=""
names_json=""
named=""
while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    names="$names$name
"
    names_json="$names_json${names_json:+,}\"$name\""
    case "$cmd" in *"$name"*) named=1 ;; esac
done < "$list"
[ -n "$named" ] || exit 0

runners="sudo|doas|su|runuser|pkexec|script|xargs|parallel|watch|timeout|nice|stdbuf|setsid|ionice|chrt|taskset|flock|ssh|unshare|nsenter|chroot|busybox|time|strace|ltrace|firejail|bwrap|systemd-run"

# swallow-ok: read -d '' on a literal heredoc always returns 1 at EOF
IFS= read -r -d '' VERDICT_JQ <<'VERDICT_JQ_EOF' || true
def base: (. // "") | sub("^.*/"; "");
def listed: IN($L[]);
def shells: ["bash","sh","zsh","dash","ksh","rbash","mksh","ash"];
def isrunner: (.prog // "") | IN(($R | split("|"))[]);
def sword:
  def go($i):
    (.argv[$i]) as $x
    | if $x == null or $x.t != "lit" or ($x.g // false) then null
      else $x.v as $o
        | if $o == "--" or $o == "-" or ($o | startswith("--")) then go($i + 1)
          elif ($o | test("^[-+][A-Za-z]+$")) then go($i + (if ($o | test("[oO]")) then 2 else 1 end))
          else $o end
      end;
  go(1);
def scriptword:
  (.prog // "") as $p
  | if .opaque != null then null
    elif ($p | IN(shells[])) then (if .body != null or .stdin then null else sword end)
    elif ($p | IN("node", "bun", "python", "python3")) then
      ([.argv[1:][] | select(.t != "lit" or (.v | startswith("-") | not))] | first) as $a
      | if $a != null and $a.t == "lit" then $a.v else null end
    else null end;
def runs:
  (.prog // "") as $p
  | if .opaque == null and ($p | listed) then $p
    elif .opaque == null and ((scriptword | base) | listed) then (scriptword | base)
    elif .opaque != null and isrunner then
      ([.argv[1:][] | select(.t == "lit" and (.v | test("\\s") | not)) | .v | base | select(listed)] | first)
    else null end;
def detached:
  ((.in // []) | any(. == "bg" or . == "coproc"))
  or ((.via // []) | any(. == "nohup"))
  or ((.prog // "") | IN("setsid", "systemd-run"))
  or (isrunner and any(.argv[1:][]?; .t == "lit" and (.v == "setsid" or .v == "nohup")));
def hasname($s): ($s | type == "string") and any($L[]; . as $n | $s | contains($n));
def opaque_naming:
  (.opaque != null and any(.argv[]?; hasname(.raw // "")))
  or (.body != null and ((.via // []) | any(. == "nohup")) and hasname(.body));
[.[] | select(runs != null) | {n: runs, d: detached}] as $r
| if any($r[]; .d) then "detach " + ($r | map(select(.d)) | first | .n)
  elif any(.[]; opaque_naming) then "legacy " + (($r | first | .n) // "-")
  elif ($r | length) > 0 then "run " + $r[0].n
  else "none -" end
VERDICT_JQ_EOF

verdict=""
lib_ast="$HERE/../lib/bash-ast.sh"
# shellcheck source=../lib/bash-ast.sh
if { [ -r "$lib_ast" ] && . "$lib_ast"; } 2>/dev/null; then
    ast_rc=0
    pos=$(BASH_AST_MAX_S=5 bash_ast_positions "$cmd" 2>/dev/null) || ast_rc=$? # swallow-ok: the rc is read next
    if [ "$ast_rc" = 0 ]; then
        # swallow-ok: a failed verdict falls back to the regex reader, never to a denial
        verdict=$(printf '%s' "$pos" | jq -r --argjson L "[$names_json]" --arg R "$runners" "$VERDICT_JQ" 2>/dev/null) || verdict=""
    fi
fi

rhit=""
rdet=""
regex_read() {
    local name esc tail tok assign wrap q via_interp via_path
    q="[\"']?"
    tail='($|[[:space:];&|)])'
    tok='[^[:space:];&|()]+'
    assign="([A-Za-z_][A-Za-z0-9_]*=(${tok})?[[:space:]]+)*"
    wrap="${assign}(((nohup|${runners})([[:space:]]+${tok})*)[[:space:]]+)?"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        esc=$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')
        via_interp="(^|[;&|(])[[:space:]]*${wrap}(bash|sh|node|bun|python3?)[[:space:]]+${q}([^[:space:]]*/)?${esc}${q}${tail}"
        via_path="(^|[;&|(])[[:space:]]*${wrap}${q}[^[:space:]]*/${esc}${q}${tail}"
        if printf '%s' "$cmd" | grep -Eq -e "$via_interp" -e "$via_path"; then
            rhit="$name"
            break
        fi
    done <<EOF
$names
EOF
    [ -n "$rhit" ] || return 0
    if printf '%s' "$cmd" | grep -Eq -e '(^|[^&<>|])&([^&>]|$)' -e '(^|[^[:alnum:]_-])(nohup|setsid|systemd-run)($|[^[:alnum:]_-])'; then
        rdet=1
    fi
}

emit_deny() {
    local reason
    reason=$(printf '%s' "$1" | jq -Rs . 2>/dev/null) \
        || reason='"guard-chief-foreground: chief session denied a long chief-kit script"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$1" >&2
    exit 2
}

hit=""
detach=""
case "$verdict" in
    "none "*) exit 0 ;;
    "detach "*) hit="${verdict#detach }"; detach=1 ;;
    "run "*) hit="${verdict#run }" ;;
    "legacy "*)
        regex_read
        hit="$rhit"
        [ -n "$hit" ] || { hit="${verdict#legacy }"; [ "$hit" != "-" ] || hit=""; }
        detach="$rdet"
        ;;
    *)
        regex_read
        hit="$rhit"
        detach="$rdet"
        ;;
esac
[ -n "$hit" ] || exit 0

if [ -n "$detach" ]; then
    detach_msg="You are a CHIEF session running a long chief-kit script (${hit}) DETACHED — DENIED.

The harness reads a background command's output, and wakes you, only when the command itself exits.
A run detached with \`&\` or \`coproc\` outlives the command, so its output and its wake reach no reader.
A detached chief-wait.sh also holds the one-waiter lock, so your real arm is then refused with exit 3.
\`nohup\`, \`setsid\` and \`systemd-run\` are refused too: under run_in_background a kit script never needs them.

Re-issue the SAME command without the \`&\`, \`coproc\`, \`nohup\`, \`setsid\` or \`systemd-run\`, with the Bash tool's
run_in_background set to true (and timeout: 7200000 for chief-wait.sh):
  Bash(command: <the command you just tried, detach word removed>, run_in_background: true)

Bypass for one session: relaunch with CHIEF_FG_OK=1 in the launching
shell (a per-call prefix does not reach this hook)."
    emit_deny "$detach_msg"
fi

[ "$bg" = "true" ] && exit 0

# A bounded run is allowed in the foreground: `timeout N` (a whole 1..90 seconds, an `s`
# suffix, or 1m / 1.5m) as the OUTERMOST command, wrapping the interpreter or script path
# directly, with no chain, pipe, substitution or newline anywhere. Anything else (-k, nohup,
# a chain before or after, N > 90 or 0) stays denied.
case "$hit:$cmd" in
    chief-wait.sh:*|console-wait.sh:*|run-suite.sh:*) ;;
    *[\;\&\|\`\$\(]*|*"
"*) ;;
    *)
        dur=$(printf '%s' "$cmd" | sed -nE 's/^[[:space:]]*timeout[[:space:]]+([0-9.]+[sm]?)[[:space:]]+((bash|sh|node|bun|python3?)[[:space:]]+|[^[:space:]]*\/).*/\1/p')
        case "$dur" in
            1m|1.5m) exit 0 ;;
            [1-9]|[1-9][0-9]|[1-9]s|[1-9][0-9]s) [ "${dur%s}" -le 90 ] && exit 0 ;;
        esac ;;
esac

deny_msg="You are a CHIEF session running a long chief-kit script (${hit}) in the foreground — DENIED.

A foreground run blocks this chief turn for minutes, and every worker's SendMessage (READY, MERGED,
BLOCKED, quote-backs) queues behind it.

Re-issue the SAME command with the Bash tool's run_in_background set to true:
  Bash(command: <the command you just tried>, run_in_background: true)
The completion arrives as a task notification; do not poll its output file or sleep on it. Keep
handling worker messages meanwhile and read the result when the notification lands.

A bounded run is allowed in the foreground: make \`timeout 90\` (1 to 90 s) the outermost command, e.g.
  timeout 90 bash scripts/handover/chief-kit/ready-check.sh <args>
chief-wait.sh and suites stay background. Short scripts (append-results.sh, go.sh, write-verdict.sh,
fleet-manifest.sh, worker-event.sh) are not on the list and stay foreground. The list is scripts/handover/chief-kit/long-running.txt.

Bypass for one session: relaunch with CHIEF_FG_OK=1 in the launching
shell (a per-call prefix does not reach this hook)."

emit_deny "$deny_msg"
