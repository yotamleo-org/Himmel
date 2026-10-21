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
         words: ([(.Loop.Items // [])[] | word($env)] + [.Loop | (.Init, .Cond, .Post) | select(. != null) | .. | objects | select(.Parts?) | word($env)])}
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
