#!/usr/bin/env bash
# block-subagent-release-operator.sh — PreToolUse Bash chain member: denies an
# in-process subagent any Bash command that names both the word `release` and
# the word `operator`, so a subagent never writes an operator-chain row with
# `jira release operator ...` (spec-review included: a critic subagent must not
# record its own verdict). operatorFence in the jira CLI reads only the
# environment, and a subagent inherits the chief's.
#
# A security fence, so it fails CLOSED: no jq denies every call, and stdin that
# is not a JSON object is denied. `agent_id` absent or null is the main session
# (the chief) and is allowed without reading the command; any other value is a
# subagent.
#
# The match: the command is normalised (backslash-newline pairs deleted, `$'`
# and `$"` turned into `'` and `"`, then every `'`, `"` and `\` deleted), split
# into words at every space, TAB, CR, newline and shell metacharacter, and matches
# when both words appear, anywhere and in either order. A command that matches is
# still allowed when the whole raw string is a plain read or a quoted-heredoc
# write, and a `--decision` word beside a `--words` word is denied first. What it
# cannot see (text built at run time, a nested claude session, a chief in another
# repo, the Monitor tool) is the fence residual named in
# docs/internals/enforcement.md.
#
# Bypass (set in the shell that launched Claude Code; session-sticky, a per-call
# prefix does not reach the hook): SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1
set -uo pipefail
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?;if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    printf '%s\n' "$1" >&2
    exit 2
}

BYPASS='Bypass: SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1 in the shell that launched Claude Code.'
P1='block-subagent-release-operator: a subagent may not run a Bash command that names both release and operator; jira release operator writes an operator-chain row, and only the main session (the chief) records one. A command that names both is allowed only when the whole command is a plain read (cd, grep, sed -n, cat, head, tail, wc, ls, cut, uniq, echo, or git grep, diff, log and show with their usual options; no variables, command substitution or unquoted glob at the start of a word) or a quoted-heredoc write (cat > PATH with a quoted delimiter) followed only by echo or by wc, ls, head, tail or cat of PATH. A session that has the Write tool should use it to write a file.'
P2='block-subagent-release-operator-word-free: a subagent may not run a Bash command that carries both --decision and --words; jira create, move and release request write an operator-chain row from those two options, and only the main session (the chief) records one.'
P2ROUTE='To file a ticket, give it an explicit placement and no --words (a jira release request needs none), or hand the exact command line back to the chief to run.'

[ "${SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 \
    || deny "block-subagent-release-operator: cannot read the hook input without jq; every Bash call is denied until jq is on PATH. $BYPASS"

# stdin is read once by the builtin, so a closed fd 0 ends at once with empty input (a $(jq) reading
# fd 0 itself would read its own output pipe, which takes the free fd 0, and hang).
input=""
IFS= read -r -d '' input 2>/dev/null || true # swallow-ok: read -d '' returns 1 at EOF on every input; empty input is the parse deny below
verdict=$(jq -r '
def ctl: "\\x00-\\x08\\x0a-\\x1f\\x7f";
def piecere:
  "[A-Za-z0-9_./:,+@%=*-]+|\u0027[^\u0027" + ctl + "]*\u0027|\"(?:[^\"\\\\$`!" + ctl + "]|\\\\[^$`!" + ctl + "])*\"";
def wordre: "\\A(?!=)(?:" + piecere + ")+";
def mkword:
  . as $raw
  | [match(piecere; "g") | .string] as $ps
  | ($ps | map(if startswith("\u0027") then .[1:-1]
               elif startswith("\"") then (.[1:-1] | gsub("\\\\(?<c>[\\\\\"])"; .c))
               else . end) | join("")) as $deq
  | ($ps | map(select((startswith("\u0027") or startswith("\"")) | not)) | join("")) as $unq
  | {t: "word", raw: $raw, deq: $deq, quoted: ($raw | test("[\u0027\"]")), star: ($unq | contains("*"))};
def lex:
  {rest: ., toks: [], prev: "start", bad: false}
  | until(.rest == "" or .bad;
      .rest as $r
      | if ($r | test("\\A[ \\t]+")) then
          ($r | match("\\A[ \\t]+").length) as $n
          | .toks += [{t: "blank"}] | .rest = $r[$n:] | .prev = "blank"
        elif ($r | test("\\A(?:&&|\\|\\||;|\\||\\n)")) then
          ($r | match("\\A(?:&&|\\|\\||;|\\||\\n)").length) as $n
          | .toks += [{t: "sep"}] | .rest = $r[$n:] | .prev = "sep"
        elif (.prev == "blank") and ($r | test("\\A(?:2>/dev/null|2>&1)(?:[ \\t;&|\\n]|\\z)")) then
          ($r | match("\\A(?:2>/dev/null|2>&1)").length) as $n
          | .toks += [{t: "redir"}] | .rest = $r[$n:] | .prev = "redir"
        elif ($r | test(wordre)) then
          ($r | match(wordre).string) as $w
          | .toks += [($w | mkword)] | .rest = $r[($w | length):] | .prev = "word"
        else .bad = true end)
  | if .bad then null else .toks end;
def segs: reduce .[] as $t ([[]]; if $t.t == "sep" then . + [[]] else .[-1] += [$t] end);
def opnd($w; $s):
  if ($w.deq | test("\\A[A-Za-z_][A-Za-z0-9_]*=")) then .ok = false
  elif $w.star and (($s.glob | not) or ($w.deq | test("\\A[A-Za-z0-9_./]") | not)) then .ok = false
  else (.ops += [$w.deq] | .i += 1) end;
def parseargs($ws; $s):
  {i: 0, ok: true, dd: false, ops: []}
  | until(.i >= ($ws | length) or (.ok | not);
      $ws[.i] as $w
      | if .dd then opnd($w; $s)
        elif ($s.dd and $w.deq == "--") then (.dd = true | .i += 1)
        elif (($s.anyopt | not) and ($w.deq | startswith("-"))) then
          if $w.star then .ok = false
          elif ($s.flag != null and ($w.deq | test($s.flag))) then .i += 1
          elif ($s.att != null and ($w.deq | test($s.att))) then .i += 1
          elif (($s.val // {}) | has($w.deq)) then
            ($ws[.i + 1]) as $v
            | if ($v != null and ($v.deq | startswith("-") | not) and ($v.star | not) and ($v.deq | test($s.val[$w.deq])))
              then .i += 2 else .ok = false end
          else .ok = false end
        else opnd($w; $s) end);
def num: "\\A[0-9]+\\z";
def list: "\\A[0-9][0-9,-]*\\z";
def tbl: {
  cd: {},
  grep: {flag: "\\A-[nilLcwvEFrRHhosqxI]+\\z", att: "\\A(?:-[ABCm][0-9]+|--(?:include|exclude|exclude-dir)=.*)\\z",
         val: {"-e": "\\A", "-A": num, "-B": num, "-C": num, "-m": num}, dd: true, glob: true},
  cat: {flag: "\\A-n\\z", dd: true, glob: true},
  head: {att: "\\A(?:-[0-9]+|-n[0-9]+)\\z", val: {"-n": num, "-c": num}, glob: true},
  tail: {att: "\\A(?:-[0-9]+|-n[0-9]+)\\z", val: {"-n": num, "-c": num}, glob: true},
  wc: {flag: "\\A-[lcw]\\z", glob: true},
  ls: {flag: "\\A-(?:l|a|la|1|d)\\z", glob: true},
  cut: {att: "\\A-(?:[cf][0-9][0-9,-]*|d.)\\z", val: {"-c": list, "-d": "\\A.\\z", "-f": list}},
  uniq: {flag: "\\A-c\\z"},
  echo: {anyopt: true}
};
def gitspec: {
  grep: {flag: "\\A(?:-[nilwEFc]|--cached)\\z", val: {"-e": "\\A"}, dd: true},
  diff: {flag: "\\A--(?:stat|name-only|name-status|no-ext-diff|cached)\\z", att: "\\A-(?:G.+|S.+|U[0-9]+)\\z",
         val: {"-G": "\\A", "-S": "\\A"}, dd: true},
  log: {flag: "\\A--(?:oneline|stat)\\z", att: "\\A(?:-[0-9]+|-G.+|-S.+|--grep=.*|--format=(?:(?!%G).)*)\\z",
        val: {"-n": num, "--grep": "\\A", "-G": "\\A", "-S": "\\A"}, dd: true},
  show: {flag: "\\A--(?:stat|name-only|no-ext-diff)\\z", dd: true}
};
def gitok($ws):
  {i: 0, ok: true, done: false}
  | until(.done or (.ok | not);
      $ws[.i] as $w
      | if $w == null then .ok = false
        elif $w.deq == "--no-pager" then .i += 1
        elif ($w.deq == "-C") then
          ($ws[.i + 1]) as $d
          | if ($d != null and ($d.deq | startswith("-") | not) and ($d.star | not)) then .i += 2 else .ok = false end
        else .done = true end)
  | if .ok | not then false
    else .i as $i
      | $ws[$i].deq as $sub
      | if (gitspec | has($sub)) then parseargs($ws[$i + 1:]; gitspec[$sub]).ok else false end
    end;
def sedok($ws):
  if ($ws | length) < 2 then false
  elif ($ws[0].deq == "-n" and ($ws[1].deq | test("\\A[0-9]+(?:,[0-9]+)?p(?:;[0-9]+(?:,[0-9]+)?p)*\\z"))) then
    parseargs($ws[2:]; {}).ok
  else false end;
def segok($ctx):
  . as $ws
  | if length == 0 then false
    else $ws[0] as $w0
      | if $w0.quoted then false
        else $w0.deq as $n
          | if ($ctx != null and ((["echo", "wc", "ls", "head", "tail", "cat"] | index($n)) == null)) then false
            elif $n == "git" then gitok($ws[1:])
            elif $n == "sed" then sedok($ws[1:])
            elif (tbl | has($n)) then
              parseargs($ws[1:]; tbl[$n]) as $r
              | $r.ok
                and (if $n == "cd" then ($r.ops | length) == 1
                     elif $n == "uniq" then ($r.ops | length) <= 1
                     elif ($ctx != null and $n != "echo") then all($r.ops[]; . == $ctx.path)
                     else true end)
            else false end
        end
    end;
def rok($ctx):
  if length > 20000 then false
  else (sub("\\n\\z"; "") | lex) as $t
    | if $t == null then false
      else ($t | segs | all(.[]; (map(select(.t == "word")) | segok($ctx))))
      end
  end;
def catre: "\\Acat[ \\t]+(?:>>|>\\||>)[ \\t]*(?<p>[A-Za-z0-9_./+@%:][A-Za-z0-9_./+@%:-]*)[ \\t]+<<[ \\t]*\u0027(?<d>[A-Za-z_]+)\u0027[ \\t]*\\z";
def cdseg:
  (lex) as $t
  | if $t == null then false
    else ($t | segs) as $s
      | (($s | length) == 1
         and ($s[0] | map(select(.t == "word")) | (length > 0 and .[0].deq == "cd" and segok(null))))
    end;
def hok:
  split("\n") as $L
  | (($L[0] | capture("\\A[ \\t]*(?<pre>cd[ \\t]+[^;&|\\n]*?)[ \\t]*(?:;|&&)[ \\t]*(?<rest>cat[ \\t].*)\\z")) // null) as $pc
  | (if ($L[0] | test(catre)) then {cat: $L[0], ci: 0}
     elif ($pc != null and ($pc.rest | test(catre)) and ($pc.pre | cdseg)) then {cat: $pc.rest, ci: 0}
     elif (($L | length) > 1 and ($L[1] | test(catre)) and ($L[0] | cdseg)) then {cat: $L[1], ci: 1}
     else null end) as $h
  | if $h == null then false
    else
      ($h.cat | capture(catre)) as $m
      | ([range($h.ci + 1; $L | length)] | map(select($L[.] == $m.d)) | first) as $j
      | if $j == null then false
        else
          ($L[$j + 1:]) as $t0
          | (if ($t0 | length) > 1 and $t0[-1] == "" then $t0[:-1] else $t0 end) as $t
          | if ($t | length) == 0 or $t == [""] then true
            else ($t | join("\n")) as $tt
              | if ($tt | length) > 20000 then false
                else (($tt | lex) as $tk
                  | if $tk == null then false
                    else ($tk | segs | all(.[]; (map(select(.t == "word")) | segok({path: $m.p})))) end)
                end
            end
        end
    end;
if type != "object" then "parse"
elif .agent_id == null then "allow"
else
  ((.tool_input.command // "") | if type == "string" then . else tostring end) as $cmd
  | ($cmd
      | gsub("\\\\\n"; "")
      | gsub("\\$\u0027"; "\u0027") | gsub("\\$\""; "\"")
      | gsub("[\u0027\"\\\\]"; "")
      | [splits("[ \t\r\n;&|()<>{}`]+")]) as $w
  | (any($w[]; startswith("--decision")) and any($w[]; startswith("--words"))) as $p2
  | (any($w[]; . == "release") and any($w[]; . == "operator")) as $both
  | if $p2 then (if $both then "deny-p1p2" else "deny-p2" end)
    elif ($both | not) then "allow"
    elif ($cmd | (rok(null) or hok)) then "allow"
    else "deny-p1" end
end' <<<"$input" 2>/dev/null) || verdict=parse

case "$verdict" in
    allow) exit 0 ;;
    deny-p1) deny "$P1 $BYPASS" ;;
    deny-p1p2) deny "$P1 $P2ROUTE $BYPASS" ;;
    deny-p2) deny "$P2 $P2ROUTE $BYPASS" ;;
    *)
        deny "block-subagent-release-operator: cannot parse the hook input as a JSON object; the call is denied. $BYPASS" ;;
esac
