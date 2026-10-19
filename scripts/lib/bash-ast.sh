# shellcheck shell=bash
# bash-ast.sh — one entry point that parses a Bash command once (shfmt
# --to-json) and returns its COMMAND POSITIONS, so a PreToolUse guard reads
# where each simple command runs instead of re-tokenizing the text.
#
#   bash_ast_positions CMD [S0] [TAGS] — prints one JSON array; each element is
#   one simple command (inside substitutions, subshells, nested `bash -c` and
#   `eval` bodies too):
#
#     prog     the program after unwrapping command/builtin/exec/nohup/env,
#              basename only; null for a redirect-only statement
#     argv     [arg] from the program word on; arg is {t:"lit", v, g, raw}
#              (one per word bash makes: brace expansion splits a word, g = an
#              unquoted glob char survived) or {t:"dyn"|"amb", raw}
#     via      the wrappers unwrapped, in order; lookup = `command -v/-V`
#     redirs   [{op, fd, w:arg|null, hdoc, text}]: a heredoc body is DATA
#              (hdoc true, w null, text its literal body or null)
#     assigns  the names of prefix assignments
#     cwd      the directories it can run in: each a chain of cd targets
#              from the caller's cwd ([] = that cwd), null = unknown
#     ecwd     where its words expand and its redirects open: cwd, except
#              that `env -C D` moves only cwd
#     in       enclosing contexts: pipe subshell brace compound bg subst
#              coproc shell-c eval
#     opaque   why this model cannot see what runs (sudo, xargs, find
#              -exec, source, a non-literal command word, a shell reading
#              stdin, …), else null
#     body     the literal `bash -c`/`eval` body, re-parsed into the
#              positions that follow it
#
#   S0 is the starting cwd set (default [[]]); TAGS the starting `in`.
#   rc 2 = shfmt or jq missing (the message says so; the caller fails closed),
#   rc 3 = shfmt could not parse the command, rc 4 = the model failed.
#
# Nav algebra: `a && b` runs b where a succeeded, `a || b` where a failed; a
# failed cd does not move. A subshell, `&`, `$(…)` and coproc do not carry a
# cd out. A pipe carries its LAST element's cd out as one candidate beside
# the cwd it started in (bash runs it in a subshell, zsh in the current
# shell). A loop, an if or a case whose body moves the cwd, a function, a
# `source`, an `eval`, `set`/`shopt`/`alias`, a declare/export, or an
# assignment to CDPATH, HOME, PWD, OLDPWD, GLOBIGNORE, BASHOPTS or SHELLOPTS
# adds an unknown candidate from there on. `env -C D` moves only its own
# command. A cd target that is not one literal non-glob word, `cd -`, `popd`
# and a bare `pushd` are unknown. Past 16 candidates the set is unknown.
#
# The model below the BEGIN marker is a verbatim copy of the canonical
# scripts/hooks/lib/bash-ast.jq (a hook reads no .jq file at run time, so the
# integrity pin covers it here); test-bash-ast.sh fails when they drift.
#
# ponytail: a CDPATH or alias from the user's rc files is not visible to the
# hook, and zsh-only syntax is read as bash; upgrade path = a per-shell model
# fed from the shell snapshot.

# >>> BEGIN bash-ast (canonical: scripts/hooks/lib/bash-ast.jq) >>>
IFS= read -r -d '' _BASH_AST_JQ <<'BASH_AST_JQ_EOF' || true # swallow-ok: read -d '' returns 1 at the heredoc's end
# bash-ast.jq — the shared Bash command model. Input: the
# `shfmt -ln bash --to-json` tree of ONE Bash command. `ba::model($env)`
# turns it into the normalized model a guard predicate reads, so the
# predicate never re-tokenizes text:
#
#   stmt  {k:"stmt", cmd, redirs:[redir], bg, neg}
#   cmd   {k:"call", assigns:[{name, w}], argv:[word]}
#         {k:"and"|"or"|"pipe", x:stmt, y:stmt}       a && b, a || b, a | b
#         {k:"sub"|"block", body:[stmt]}              ( … ) and { …; }
#         {k:"compound", t, bodies:[[stmt]], words:[word]}
#             if/while/for/case/select and a function body: bodies that run
#             zero or more times, in an order the predicate does not assume
#         {k:"other", t, words:[word]}                [[ ]], (( )), declare, let
#         {k:"wrap", t, body:[stmt]}                  time, coproc
#         null                                        a redirect-only `> f`
#   redir {op, fd, w:word, hdoc:{lit, text, words}|null}
#         A heredoc body is DATA: `text` is its literal text when it has no
#         expansion (`lit`), and the command substitutions inside it, which
#         DO run, sit in `words` like any other word's.
#   word  {raw, t:"lit"|"dyn"|"amb", vals, pfx, dynfirst, why, ak, subs}
#         t "lit": `vals` lists every word bash makes of it, after quote
#         removal, brace expansion (capped at 64), tilde and $HOME, each
#         {v, g, gp}: g = an unquoted glob character survived, gp = the
#         glob-free directory prefix the match lands under.
#         t "dyn": an expansion this model cannot evaluate; `pfx` is the
#         static text before it, `dynfirst` says the word STARTS dynamic.
#         t "amb": the word reads differently across the shells we run
#         under, or past a cap; `ak` is the guard deny kind, `why` the reason.
#         `subs` holds the stmt lists of every $(…), `…` and <(…) inside the
#         word: they run, so a predicate walks them like top-level code.
#
# Fail closed: a node kind this module does not know raises an error, and so
# does any jq failure, so the caller denies rather than guessing.
#
# ponytail: the alias table, `shopt` state and a function shadowing a builtin
# (`touch(){ :; }`) are not modelled — every call is read by its literal
# program name; upgrade path = a definitions pass over FuncDecl names.

def _known: ["File","CallExpr","IfClause","WhileClause","ForClause","CaseClause",
  "Block","Subshell","BinaryCmd","FuncDecl","ArithmCmd","TestClause","DeclClause",
  "LetClause","TimeClause","CoprocClause","WordIter","CStyleLoop","Word","Lit",
  "SglQuoted","DblQuoted","ParamExp","CmdSubst","ArithmExp","ProcSubst","ExtGlob",
  "BinaryArithm","UnaryArithm","ParenArithm","BinaryTest","UnaryTest","ParenTest"];

def assert_known:
  ([.. | objects | .Type? // empty] | unique - _known) as $u
  | if ($u | length) > 0 then error("bash-ast: unknown node kind " + ($u | map(tostring) | join(",")))
    else . end;

# ---- words -------------------------------------------------------------
# A static segment is ENCODED: every quoted or escaped byte is preceded by
# \u0001, so brace, glob and tilde handling see only the live characters.
def _protect: gsub("(?<c>[\\[\\]{}*?,~\u0001])"; "\u0001\(.c)");
def _decode: gsub("\u0001(?<c>.)"; "\(.c)"; "s");

def _unq_lit: gsub("\\\\\n"; "") | gsub("\\\\(?<c>.)"; "\u0001\(.c)"; "s");
def _dq_lit: gsub("\\\\\n"; "") | gsub("\\\\(?<c>[$`\"\\\\])"; "\(.c)") | _protect;

# $'…' as bash 5 decodes it. Only escapes every shell we run under agrees on
# are decoded; \u, \U, \c, an unknown escape or a decoded control byte
# (other than tab and newline) or non-ASCII byte makes the word ambiguous.
def _ansic:
  [scan("\\\\(?:[0-7]{1,3}|x[0-9A-Fa-f]{1,2}|.)|[^\\\\]+|\\\\$"; "s")]
  | map(
      if startswith("\\") | not then {v: .}
      elif . == "\\" then {amb: "a trailing backslash"}
      else .[1:] as $e
        | ({"a":7,"b":8,"e":27,"E":27,"f":12,"n":10,"r":13,"t":9,"v":11,
            "\\":92,"'":39,"\"":34,"?":63}[$e]) as $m
        | if $m != null then {c: $m}
          elif ($e | test("^[0-7]{1,3}$")) then
            {c: ($e | explode | reduce .[] as $d (0; . * 8 + $d - 48))}
          elif ($e | test("^x[0-9A-Fa-f]{1,2}$")) then
            {c: ($e[1:] | ascii_downcase | explode
                 | reduce .[] as $d (0; . * 16 + (if $d >= 97 then $d - 87 else $d - 48 end)))}
          else {amb: ("the escape \\" + $e)} end
      end)
  | if any(.[]; has("amb")) then {amb: (map(.amb // empty) | first)}
    elif any(.[]; (has("c") and (.c > 126 or (.c < 32 and .c != 9 and .c != 10)))
                  or (has("v") and (.v | test("[^\\t\\n\\x20-\\x7e]")))) then
      {amb: "a decoded control or non-ASCII byte"}
    else {v: (map(if has("c") then ([.c] | implode) else .v end) | join(""))} end;

def _simple_pe: (keys - ["Type","Pos","End","Dollar","Rbrace","Short","Param"]) == [];

def _is_pwd_subst:
  (.Stmts | length) == 1
  and (.Stmts[0] | (.Redirs // []) == [] and .Cmd.Type? == "CallExpr"
       and (.Cmd.Assigns // []) == [] and (.Cmd.Args | length) == 1
       and (.Cmd.Args[0].Parts | length) == 1
       and .Cmd.Args[0].Parts[0].Type == "Lit" and .Cmd.Args[0].Parts[0].Value == "pwd");

def _raw_part:
  if .Type == "Lit" then .Value
  elif .Type == "SglQuoted" then (if .Dollar then "$'" else "'" end) + .Value + "'"
  elif .Type == "DblQuoted" then "\"" + ([.Parts[]? | _raw_part] | join("")) + "\""
  elif .Type == "ParamExp" then (if .Short then "$" + .Param.Value else "${" + (.Param.Value // "") + "…}" end)
  elif .Type == "CmdSubst" then "$(…)"
  elif .Type == "ProcSubst" then .Op + "…)"
  elif .Type == "ArithmExp" then "$((…))"
  elif .Type == "ExtGlob" then .Op + .Pattern.Value + ")"
  else "…" end;

# one word part to a list of segments: {s} static (encoded) or {d: kind}
def _segs($env; $dq):
  if .Type == "Lit" then [{s: (.Value | if $dq then _dq_lit else _unq_lit end)}]
  elif .Type == "SglQuoted" then
    if .Dollar then (.Value | _ansic) as $a
      | if $a.amb then [{d: "amb", why: ("$'…' with " + $a.amb)}] else [{s: ($a.v | _protect)}] end
    else [{s: (.Value | _protect)}] end
  elif .Type == "DblQuoted" then
    ([.Parts[]? | _segs($env; true)] | add // []) | if . == [] then [{s: ""}] else . end
  elif .Type == "ParamExp" then
    if _simple_pe and .Param.Value == "HOME" then
      if $env.home_taint then [{d: "amb", why: "HOME is reassigned in this command", ak: "home-reassigned"}]
      else [{s: ($env.home | _protect)}] end
    elif _simple_pe and .Param.Value == "PWD" then
      if $env.pwd_taint then [{d: "amb", why: "PWD is reassigned in this command"}] else [{d: "pwd"}] end
    else [{d: "param"}] end
  elif .Type == "CmdSubst" then if _is_pwd_subst then [{d: "pwd"}] else [{d: "subst"}] end
  elif .Type == "ProcSubst" then [{d: "psub"}]
  elif .Type == "ArithmExp" then [{d: "arith"}]
  elif .Type == "ExtGlob" then [{s: ((.Op | _protect) + "*" + (.Pattern.Value | _protect) + "\u0001)")}]
  else error("bash-ast: unknown word part " + (.Type | tostring)) end;

# ---- brace expansion over an encoded string -----------------------------
def _bclose($a; $i):
  def go($j; $d; $c):
    if $j >= ($a | length) then null
    elif $a[$j] == 1 then go($j + 2; $d; $c)
    elif $a[$j] == 123 then go($j + 1; $d + 1; $c)
    elif $a[$j] == 125 then (if $d == 0 then {close: $j, commas: $c} else go($j + 1; $d - 1; $c) end)
    elif $a[$j] == 44 and $d == 0 then go($j + 1; $d; $c + [$j])
    else go($j + 1; $d; $c) end;
  go($i + 1; 0; []);

# {x..y} and {x..y..step}: bash takes the step's magnitude and the endpoints'
# direction; a step of 0 counts as 1
def _terms($x; $y; $z):
  ((if $z == 0 then 1 else ($z | fabs) end) * (if $y >= $x then 1 else -1 end)) as $s
  | if ((($x - $y) | fabs) / ($s | fabs)) >= 64 then error("bash-ast: brace cap")
    else [range($x; $y + (if $s > 0 then 1 else -1 end); $s)] end;

def _seq($in):
  if ($in | test("^-?[0-9]{1,6}\\.\\.-?[0-9]{1,6}(\\.\\.-?[0-9]{1,6})?$")) then
    ($in | split("..")) as $e
    | ($e | map(tonumber)) as $n
    # a zero-padded endpoint pads every term to the wider endpoint, as bash does
    | (if any($e[:2][]; test("^-?0[0-9]")) then ($e[:2] | map(length) | max) else 0 end) as $w
    | [_terms($n[0]; $n[1]; $n[2] // 1)[]
       | (if . < 0 then "-" else "" end) as $sg | (fabs | tostring) as $d
       | $sg + ([range(0; $w - ($sg | length) - ($d | length))] | map("0") | join("")) + $d]
  elif ($in | test("^[A-Za-z]\\.\\.[A-Za-z](\\.\\.-?[0-9]{1,6})?$")) then
    ($in | explode) as $c
    | [_terms($c[0]; $c[3]; ($in[6:] | if . == "" then 1 else tonumber end))[] | [.] | implode | _protect]
  # a longer number is still a range in bash, but past what tonumber keeps exact
  elif ($in | test("^(-?[0-9]+\\.\\.-?[0-9]+|[A-Za-z]\\.\\.[A-Za-z])(\\.\\.-?[0-9]+)?$")) then error("bash-ast: brace cap")
  else null end;

def _brace:
  def exp($n):
    if $n > 64 then error("bash-ast: brace cap")
    else
      explode as $a
      | (def find($i):
           if $i >= ($a | length) then null
           elif $a[$i] == 1 then find($i + 2)
           elif $a[$i] == 123 then
             (_bclose($a; $i)) as $m
             | if $m == null then null
               elif ($m.commas | length) > 0 then {open: $i} + $m
               elif (($a[$i + 1:$m.close] | implode) as $in | ($in | test("\u0001") | not) and _seq($in) != null) then {open: $i} + $m
               else find($i + 1) end
           else find($i + 1) end;
         find(0)) as $f
      | if $f == null then [$a | implode]
        else ($a[:$f.open] | implode) as $pre | ($a[$f.close + 1:] | implode) as $suf
          | (if ($f.commas | length) > 0 then
               [[$f.open] + $f.commas, $f.commas + [$f.close]] | transpose | map($a[.[0] + 1:.[1]] | implode)
             else _seq($a[$f.open + 1:$f.close] | implode) end) as $alts
          | [$alts[] | ($pre + . + $suf) | exp($n + ($alts | length))[]]
        end
    end;
  exp(1) | if length > 64 then error("bash-ast: brace cap") else . end;

def _glob_pfx:
  # the encoded text before the first live glob character, cut back to its
  # directory ("./" when it names no directory), decoded
  (explode | . as $a
   | (def g($i): if $i >= ($a | length) then null
                 elif $a[$i] == 1 then g($i + 2)
                 elif ($a[$i] == 42 or $a[$i] == 63 or $a[$i] == 91) then $i
                 else g($i + 1) end; g(0)) as $p
   | if $p == null then null else ($a[:$p] | implode | _decode
       | if test("/") then sub("/[^/]*$"; "/") else "./" end) end);

def _tilde($env):
  if test("^([A-Za-z_][A-Za-z0-9_]*=)?~(/|$)") then
    if $env.home_taint then error("home-reassigned")
    else sub("^(?<p>([A-Za-z_][A-Za-z0-9_]*=)?)~"; "\(.p)\($env.home | _protect)") end
  elif test("^([A-Za-z_][A-Za-z0-9_]*=)?~") then error("tilde")
  else . end;

def _subs: [.. | objects | select(.Type? == "CmdSubst" or .Type? == "ProcSubst") | .Stmts];

def word($env):
  . as $w
  | ([.Parts[] | _raw_part] | join("")) as $raw
  | ([.Parts[] | _segs($env; false)] | add // []) as $segs0
  # a leading $(pwd)/$PWD is the cwd when a `/` or the word end follows it
  | (if ($segs0[0].d? == "pwd") and (($segs0 | length) == 1 or (($segs0[1].s? // "") | startswith("/")))
     then [{s: "."}] + $segs0[1:] else $segs0 end) as $segs
  | ([$w | _subs[]] | map(.)) as $subs
  | ([$segs[] | select(.d == "amb")] | first) as $amb
  | if $amb != null then {raw: $raw, t: "amb", why: $amb.why, ak: ($amb.ak // "ast-unresolved"), subs: $subs}
    elif any($segs[]; has("d")) then
      ([limit(($segs | map(has("d")) | index(true)); $segs[])] | map(.s) | join("")) as $p
      | ($p | try _tilde($env) catch "\u0000") as $pt
      | if $pt == "\u0000" then {raw: $raw, t: "amb", why: "a ~ prefix this model does not expand", ak: "ast-unresolved", subs: $subs}
        else {raw: $raw, t: "dyn", pfx: ($pt | (_glob_pfx // _decode)), dynfirst: ($segs[0] | has("d")), dk: (first($segs[] | select(has("d"))).d), subs: $subs} end
    else
      ($segs | map(.s) | join("")) as $enc
      | (try ($enc | _brace) catch null) as $alts
      | if $alts == null then {raw: $raw, t: "amb", why: "a brace expansion past 64 words", ak: "ast-unresolved", subs: $subs}
        else
          (try [$alts[] | _tilde($env)] catch ("\u0000" + .)) as $ex
          | if ($ex | type) == "string" then
              {raw: $raw, t: "amb", subs: $subs,
               why: (if $ex == "\u0000home-reassigned" then "HOME is reassigned in this command" else "a ~ prefix this model does not expand" end),
               ak: (if $ex == "\u0000home-reassigned" then "home-reassigned" else "ast-unresolved" end)}
            else {raw: $raw, t: "lit", subs: $subs,
                  vals: [$ex[] | _glob_pfx as $gp | {v: _decode, g: ($gp != null), gp: $gp}]} end
        end
    end;

# ---- statements ---------------------------------------------------------
def _hdoc($env):
  if . == null then null
  else
    (.Parts // []) as $p
    | ([$p[] | select(.Type != "Lit")] | length == 0) as $lit
    | {lit: $lit,
       text: (if $lit then ($p | map(.Value) | join("")) else null end),
       words: [{Parts: $p} | word($env)]}
  end;

def _redir($env):
  {op: .Op, fd: (.N.Value // null), w: (if .Word then (.Word | word($env)) else null end),
   hdoc: (.Hdoc | _hdoc($env))};

def _stmts($env):
  def st:
   def body: [(. // [])[] | st];
   def cm:
    .Type as $t
    | if $t == "CallExpr" then
        {k: "call", argv: [(.Args // [])[] | word($env)],
         assigns: [(.Assigns // [])[] | {name: .Name.Value, w: (if .Value then (.Value | word($env)) else null end),
                                         arr: [(.Array.Elems // [])[] | .Value | select(. != null) | word($env)]}]}
      elif $t == "BinaryCmd" then
        {k: ({"&&": "and", "||": "or", "|": "pipe", "|&": "pipe"}[.Op] // error("bash-ast: unknown operator " + .Op)),
         x: (.X | st), y: (.Y | st)}
      elif $t == "Subshell" then {k: "sub", body: (.Stmts | body)}
      elif $t == "Block" then {k: "block", body: (.Stmts | body)}
      elif $t == "IfClause" then
        {k: "compound", t: $t, words: [],
         bodies: [recurse(.Else // empty) | (.Cond, .Then) | body]}
      elif $t == "WhileClause" then {k: "compound", t: $t, words: [], bodies: [(.Cond | body), (.Do | body)]}
      elif $t == "ForClause" then
        {k: "compound", t: $t, bodies: [.Do | body],
         words: [(.Loop.Items // [])[] | word($env)] + [.Loop | (.Init, .Cond, .Post) | select(. != null) | .. | objects | select(.Parts?) | word($env)]}
      elif $t == "CaseClause" then
        {k: "compound", t: $t, words: ([.Word | word($env)] + [(.Items // [])[] | (.Patterns // [])[] | word($env)]),
         bodies: [(.Items // [])[] | .Stmts | body]}
      elif $t == "FuncDecl" then {k: "compound", t: $t, words: [], bodies: [[.Body | st]]}
      elif $t == "TimeClause" or $t == "CoprocClause" then {k: "wrap", t: $t, posix: (.PosixFormat // false), body: [.Stmt | select(. != null) | st]}
      elif ($t == "ArithmCmd" or $t == "TestClause" or $t == "DeclClause" or $t == "LetClause") then
        {k: "other", t: $t, words: [.. | objects | select(has("Parts") and (has("Type") | not) or .Type? == "Word") | word($env)]}
      else error("bash-ast: unknown command kind " + ($t | tostring)) end;
   {k: "stmt", bg: (.Background // false), neg: (.Negated // false),
    redirs: [(.Redirs // [])[] | _redir($env)],
    cmd: (if .Cmd == null then null else (.Cmd | cm) end)};
  [(. // [])[] | st];

# A word's `subs` come out of word() as raw shfmt stmt lists; normalize them
# the same way, all the way down.
def stmts($env):
  _stmts($env) | ((.. | objects | select(has("subs")) | .subs) |= map(stmts($env)));

# The model of a whole File node.
# PWD is tainted when the text names it anywhere but a $PWD expansion's own
# parameter (an assignment, export, read, for-loop name, nameref …).
def model($env):
  assert_known
  | ([walk(if type == "object" and .Type? == "ParamExp" then del(.Param) else . end) | .. | strings | select(test("PWD"))] | length > 0) as $pt
  | .Stmts | stmts($env + {pwd_taint: $pt});

# The flat view: every simple command anywhere (inside substitutions and
# heredoc bodies too), with the redirects of the statement that holds it.
def calls:
  [.[] | recurse(
     (.cmd | select(. != null) | (.x, .y, (.body // [])[], ((.bodies // [])[][]))),
     (.. | objects | select(has("subs")) | .subs[][])
   ) | select(.k == "stmt")]
  | unique_by(tojson)
  | map({argv: (.cmd | if .k? == "call" then .argv else [] end), redirs});
BASH_AST_JQ_EOF
# <<< END bash-ast <<<

IFS= read -r -d '' _BASH_AST_POS_JQ <<'BASH_AST_POS_EOF' || true # swallow-ok: read -d '' returns 1 at the heredoc's end
# ---- command positions --------------------------------------------------
def _names: "\\b(GLOBIGNORE|CDPATH|HOME|PWD|OLDPWD|BASHOPTS|SHELLOPTS)\\b";
def _shells: ["bash","sh","zsh","dash","ksh","rbash","mksh","ash"];
def _runners: ["sudo","doas","su","runuser","pkexec","script","xargs","parallel","watch",
  "timeout","nice","stdbuf","setsid","ionice","chrt","taskset","flock","ssh","unshare",
  "nsenter","chroot","busybox","time","strace","ltrace","firejail","bwrap","systemd-run"];

# a cwd set: unique candidates, null = unknown, past 16 unknown
def _u($a; $b): ($a + $b) | unique | if length > 16 then [null] else . end;
def _cdto($S; $t): [$S[] | if . == null or $t == null then null else . + [$t] end] | unique;

def _args: . as $w
  | if .t == "lit" then .vals[] | {t: "lit", v, g, raw: $w.raw} else {t: $w.t, raw: $w.raw} end;
def _l1: if .t? == "lit" and (.g | not) then .v else null end;
def _redir:
  {op, fd, hdoc: (.hdoc != null), text: (.hdoc.text? // null),
   w: (if .hdoc != null or .w == null then null
       elif .w.t == "lit" and (.w.vals | length) == 1 then {t: "lit", v: .w.vals[0].v, g: .w.vals[0].g, raw: .w.raw}
       elif .w.t == "lit" then {t: "amb", raw: .w.raw}
       else {t: .w.t, raw: .w.raw} end)};

def _opts_command:
  (.a[0] | _l1) as $o
  | if $o == "--" then .a |= .[1:]
    elif $o != null and ($o | test("^-[pvV]+$")) then
      (if ($o | test("[vV]")) then .lookup = true else . end) | .a |= .[1:] | _opts_command
    elif $o != null and ($o | startswith("-")) then .opaque = "an option of command this model does not read"
    else . end;
def _opts_exec:
  (.a[0] | _l1) as $o
  | if $o == "--" then .a |= .[1:]
    elif $o == null or ($o | startswith("-") | not) then .
    elif ($o | test("^-[cl]*a$")) then .a |= .[2:] | _opts_exec
    elif ($o | test("^-[cl]+$")) then .a |= .[1:] | _opts_exec
    else .opaque = "an option of exec this model does not read" end;
def _opts_env:
  (.a[0] | _l1) as $o
  | if $o == "--" then .a |= .[1:]
    elif $o == null then (if (.a | length) > 0 then .opaque = "an env argument this model cannot read" else . end)
    elif ($o | IN("-", "-i", "--ignore-environment", "-0", "--null", "-v", "--debug")) then .a |= .[1:] | _opts_env
    elif ($o | IN("-u", "--unset")) then .a |= .[2:] | _opts_env
    elif ($o | test("^(-u.|--unset=)")) then .a |= .[1:] | _opts_env
    elif ($o | IN("-C", "--chdir")) then .cdx += [.a[1] | _l1] | .a |= .[2:] | _opts_env
    elif ($o | test("^-C.")) then .cdx += [$o[2:]] | .a |= .[1:] | _opts_env
    elif ($o | startswith("--chdir=")) then .cdx += [$o[8:]] | .a |= .[1:] | _opts_env
    elif ($o | startswith("-")) then .opaque = "an env option this model does not read"
    elif ($o | test("^[A-Za-z_][A-Za-z0-9_]*=")) then
      (if ($o | split("=")[0] | test(_names)) then .taint = true else . end) | .a |= .[1:] | _opts_env
    else . end;

def _unwrap:
  if .opaque != null or .lookup or (.a | length) == 0 then .
  else (.a[0] | _l1) as $c0
  | if $c0 == null then .opaque = "a command word this model cannot read"
    else ($c0 | sub("^.*/"; "")) as $n
    | if $n == "command" then .via += [$n] | .a |= .[1:] | _opts_command | _unwrap
      elif $n == "builtin" then .via += [$n] | .a |= .[1:] | _unwrap
      elif $n == "exec" then .via += [$n] | .a |= .[1:] | _opts_exec | _unwrap
      elif $n == "nohup" then .via += [$n] | .a |= .[1:] | (if (.a[0] | _l1) == "--" then .a |= .[1:] else . end) | _unwrap
      elif $n == "env" then .via += [$n] | .a |= .[1:] | _opts_env | _unwrap
      else . end
    end
  end;

# `sh -c BODY`: the body is re-parsed; no -c and no script reads stdin
def _shell:
  def go($i; $c):
    .a[$i] as $x | ($x | _l1) as $o
    | if $x == null then (if $c then . else .opaque = "a shell reading commands from stdin" end)
      elif $o == null then .opaque = "a shell argument this model cannot read"
      elif $o == "--" or $o == "-" then go($i + 1; $c)
      elif ($o | startswith("--")) then go($i + 1; $c)
      elif ($o | test("^[-+][A-Za-z]+$")) then
        if ($o | test("s")) then .opaque = "a shell reading commands from stdin"
        else go($i + (if ($o | test("[oO]")) then 2 else 1 end); $c or ($o | test("^-[A-Za-z]*c"))) end
      elif $c then .body = $o
      else . end;
  go(1; false);

def _classify:
  if .opaque != null or .lookup or (.a | length) == 0 then .prog = (.via | last)
  else (.a[0].v | sub("^.*/"; "")) as $n
  | .prog = $n
  | if ($n | IN(_shells[])) then _shell
    elif $n == "eval" then
      if (.a | length) == 1 then .
      elif all(.a[1:][]; .t == "lit" and (.g | not)) then .body = (.a[1:] | map(.v) | join(" ")) | .taint = true
      else .opaque = "an eval of a word this model cannot read" | .taint = true end
    elif $n == "source" or $n == "." then .opaque = "it runs a file in this shell" | .taint = true
    elif ($n | IN(_runners[])) then .opaque = "it runs its arguments as a command (" + $n + ")"
    elif $n == "find" and any(.a[]; (.v // "") | IN("-exec", "-execdir", "-ok", "-okdir")) then .opaque = "find runs a command"
    elif ($n | IN("set", "shopt", "alias", "unalias", "enable", "trap")) then .taint = true
    # the two array readers are spelled split so shell-lint's bash32 check skips this jq text
    elif ($n | IN("read", "unset", "map" + "file", "read" + "array", "printf", "getopts"))
         and any(.a[1:][]; (.v // .raw) | test(_names)) then .taint = true
    else . end
  end;

def _cdargs($p):
  (.[0] | _l1) as $o
  | if length == 0 then .
    elif $o == "--" then .[1:]
    elif $o != null and (($p == "cd" and ($o | test("^-[LPe@]+$"))) or ($p == "popd" and $o == "-n")) then .[1:] | _cdargs($p)
    else . end;

def _nav($S; $env):
  if .taint then {ok: _u($S; [null]), fail: _u($S; [null])}
  elif .opaque != null or .lookup or .prog == null then {ok: $S, fail: $S}
  elif (.prog | IN("cd", "pushd", "popd")) and all(.via[]; IN("command", "builtin")) then
    .prog as $p
    | (.a[1:] | _cdargs($p)) as $r
    | if $p == "popd" then {ok: [null], fail: $S}
      elif $p == "pushd" and (.a[1] | _l1) == "-n" then {ok: $S, fail: $S}
      else
        (if ($r | length) == 0 then (if $p == "cd" and ($env.home_taint | not) then $env.home else null end)
         elif ($r | length) == 1 then ($r[0] | _l1)
           | (if . == null or startswith("-") or ($p == "pushd" and test("^[+-][0-9]+$")) then null else . end)
         else null end) as $t
        | {ok: _cdto($S; $t), fail: $S}
      end
  else {ok: $S, fail: $S} end;

def _pos($st; $S; $tg):
  {prog, argv: .a, via, lookup, redirs: ($st.redirs | map(_redir)), assigns: [], cwd: $S, ecwd: $S,
   in: $tg, opaque, body};

# . = a stmt or a stmt list; returns {ok, fail, pos}: the cwd sets after it
# succeeded and failed, and every position inside it
def _w($S; $tags; $env):
  def subs($S; $tg): [.[] | select(. != null) | .subs[]? | _w($S; $tg + ["subst"]; $env) | .pos[]];
  if type == "array" then
    if length == 0 then {ok: $S, fail: $S, pos: []}
    else reduce .[] as $s (null;
        (if . == null then $S else _u(.ok; .fail) end) as $in
        | (.pos // []) as $acc
        | ($s | _w($in; $tags; $env)) as $r
        | {ok: $r.ok, fail: $r.fail, pos: ($acc + $r.pos)})
    end
  else
    . as $st
    | ($tags + (if $st.bg then ["bg"] else [] end)) as $tg
    | ([$st.redirs[] | .w, (.hdoc.words // [])[]] | subs($S; $tg)) as $rp
    | $st.cmd as $c
    | (if $c == null then
         {ok: $S, fail: $S, pos: [{prog: null, a: [], via: [], lookup: false, opaque: null, body: null} | _pos($st; $S; $tg)]}
       elif $c.k == "call" then
         ([$c.argv[], $c.assigns[].w, $c.assigns[].arr[]] | subs($S; $tg)) as $sp
         | ($c.assigns | map(.name)) as $an
         | ({a: [$c.argv[] | _args], via: [], cdx: [], opaque: null, lookup: false, body: null,
             taint: any($an[]; test(_names))} | _unwrap | _classify) as $u
         | (reduce $u.cdx[] as $d ($S; _cdto(.; $d))) as $pc
         | ($u | _nav($S; $env)) as $nv
         | {ok: $nv.ok, fail: $nv.fail, pos: ($sp + [$u | _pos($st; $pc; $tg) | .assigns = $an | .ecwd = $S])}
       elif $c.k == "and" then
         ($c.x | _w($S; $tg; $env)) as $x | ($c.y | _w($x.ok; $tg; $env)) as $y
         | {ok: $y.ok, fail: _u($x.fail; $y.fail), pos: ($x.pos + $y.pos)}
       elif $c.k == "or" then
         ($c.x | _w($S; $tg; $env)) as $x | ($c.y | _w($x.fail; $tg; $env)) as $y
         | {ok: _u($x.ok; $y.ok), fail: $y.fail, pos: ($x.pos + $y.pos)}
       elif $c.k == "pipe" then
         ($c.x | _w($S; $tg + ["pipe"]; $env)) as $x | ($c.y | _w($S; $tg + ["pipe"]; $env)) as $y
         | _u($S; _u($y.ok; $y.fail)) as $o
         | {ok: $o, fail: $o, pos: ($x.pos + $y.pos)}
       elif $c.k == "sub" then {ok: $S, fail: $S, pos: ($c.body | _w($S; $tg + ["subshell"]; $env) | .pos)}
       elif $c.k == "block" then $c.body | _w($S; $tg + ["brace"]; $env)
       elif $c.k == "compound" then
         ($c.words | subs($S; $tg)) as $wp
         | (if $c.t == "FuncDecl" then [null] else $S end) as $s0
         | [$c.bodies[] | _w($s0; $tg + ["compound"]; $env)] as $p1
         | (reduce $p1[] as $r ($s0; _u(.; _u($r.ok; $r.fail)))) as $m1
         | if $c.t == "FuncDecl" then {ok: _u($S; [null]), fail: _u($S; [null]), pos: ($wp + [$p1[].pos[]])}
           elif $m1 == ($s0 | unique) then {ok: $s0, fail: $s0, pos: ($wp + [$p1[].pos[]])}
           else _u($m1; [null]) as $m
             | {ok: $m, fail: $m, pos: ($wp + [$c.bodies[] | _w($m; $tg + ["compound"]; $env) | .pos[]])} end
       elif $c.k == "wrap" then
         ($c.body | _w($S; $tg + (if $c.t == "CoprocClause" then ["coproc"] else [] end); $env))
         | if $c.t == "CoprocClause" then .ok = $S | .fail = $S
           elif $c.posix then .ok = _u($S; .ok) | .fail = _u($S; .fail)
           else . end
       elif $c.k == "other" then
         ($c.words | subs($S; $tg)) as $wp
         | (if $c.t == "DeclClause" then _u($S; [null]) else $S end) as $o
         | {ok: $o, fail: $o,
            pos: ($wp + [{prog: ({"DeclClause": "declare", "TestClause": "[[", "ArithmCmd": "((", "LetClause": "let"}[$c.t]),
                          a: [$c.words[] | _args], via: [], lookup: false, opaque: null, body: null} | _pos($st; $S; $tg)])}
       else error("bash-ast: unknown model kind " + ($c.k | tostring)) end) as $r
    # a redirect on a subshell, brace group, loop or wrap opens its file in the outer cwd
    | (if $c != null and ($c.k | IN("sub", "block", "compound", "wrap")) and ($st.redirs | length) > 0
       then [{prog: null, a: [], via: [], lookup: false, opaque: null, body: null} | _pos($st; $S; $tg)]
       else [] end) as $sr
    | ($r | .pos = ($sr + .pos)) as $r
    | (if $st.neg then {ok: $r.fail, fail: $r.ok} else {ok: $r.ok, fail: $r.fail} end) as $nf
    | if $st.bg then {ok: $S, fail: $S, pos: ($rp + $r.pos)} else $nf + {pos: ($rp + $r.pos)} end
  end;

def positions($home; $s0; $tags):
  ([walk(if type == "object" and .Type? == "ParamExp" then del(.Param) else . end) | .. | strings
    | select(test("HOME"))] | length > 0 or $home == "") as $ht
  | {home: $home, home_taint: $ht} as $env
  | model($env) | _w($s0; $tags; $env) | .pos;
BASH_AST_POS_EOF

bash_ast_positions() {
    local cmd=$1 s0=${2:-'[[]]'} tags=${3:-'[]'} depth=${4:-0} tree pos line inner acc rc
    if ! command -v shfmt >/dev/null 2>&1; then
        echo "bash-ast: shfmt not on PATH, so the command model cannot run and the guard fails closed. Install shfmt (a station install goes to a test VM first)." >&2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "bash-ast: jq not on PATH, so the command model cannot run and the guard fails closed." >&2
        return 2
    fi
    tree=$(printf '%s' "$cmd" | shfmt -ln bash --to-json 2>/dev/null) || {
        echo "bash-ast: shfmt could not parse the command." >&2
        return 3
    }
    pos=$(printf '%s' "$tree" | jq -c --arg home "${HOME:-}" --argjson s0 "$s0" --argjson tags "$tags" \
        "$_BASH_AST_JQ$_BASH_AST_POS_JQ"'positions($home; $s0; $tags)' 2>/dev/null) || {
        echo "bash-ast: the command model could not read the command." >&2
        return 4
    }
    if ! printf '%s' "$pos" | jq -e 'any(.[]; .body != null)' >/dev/null; then
        printf '%s\n' "$pos"
        return 0
    fi
    if [ "$depth" -ge 4 ]; then
        printf '%s' "$pos" | jq -c 'map(if .body != null then .opaque = "shell bodies nested past depth 4" else . end)'
        return 0
    fi
    acc=$pos
    while IFS= read -r line; do
        inner=$(bash_ast_positions "$(printf '%s' "$line" | jq -r .body)" \
            "$(printf '%s' "$line" | jq -c .cwd)" \
            "$(printf '%s' "$line" | jq -c '.in + [if .prog == "eval" then "eval" else "shell-c" end]')" \
            $((depth + 1)))
        rc=$?
        [ "$rc" = 0 ] || return "$rc"
        acc="$acc"$'\n'"$inner"
    done < <(printf '%s' "$pos" | jq -c '.[] | select(.body != null)')
    printf '%s\n' "$acc" | jq -cs 'add'
}
