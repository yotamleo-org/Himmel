# bash-ast-bwimc.jq — block-write-into-main-checkout as a predicate over the
# bash-ast model. Input: the shfmt JSON of one command. $E is
# {home, home_taint, cdpath_taint, cwd, st}: `cwd` the tool payload's cwd,
# `st` the cwd state the command starts in ({cwds, unres, stack}).
#
# The predicate decides WHICH paths a command writes and under which mode;
# the guard's own resolvers decide whether a path lands in a protected
# checkout. It prints records, each a field list joined by \u001f and ended
# by \u001e, for the guard to run in order:
#
#   chk  ABS RAW MODE         _bwimc_check_abs ABS RAW MODE
#   deny KIND RAW RESOLVED    _bwimc_deny KIND RAW RESOLVED
#   dird ABS RAW ISDIR DIRMODE CHILDMODE NOTDIRMODE BASE…
#        a destination whose meaning depends on whether ABS is a directory
#        (cp/mv/ln): ISDIR 1 = it is one by its option (-t); otherwise the
#        guard tests it. A directory is checked under DIRMODE and each
#        ABS/BASE under CHILDMODE; anything else is ABS under NOTDIRMODE.
#   cwd  ABS                  a git commit in the repo at ABS
#   root ABS                  the records up to the next `root` run behind a
#        chroot to ABS (empty: no chroot); the guard's _bwimc_chroot
#   reparse BODY STATE        a shell body (bash -c, eval, env -S, script -c,
#        su -c, a heredoc fed to a shell) to run through this predicate
#        again, starting in the cwd STATE (JSON)
#   needpath PATH             the predicate needs whether PATH is a searchable
#        directory, and its canonical form: the guard adds it to $E.dirs and
#        runs the predicate again; when acting on records it skips these
#
# A relative path is checked against EVERY directory the command may be in
# at that point: each cwd a cd may have reached and the payload cwd, since a
# cd can fail. An unknown cwd denies a relative target (unresolved-cd).
#
# ponytail: a command whose program word is itself dynamic (`$(echo rm) f`),
# a target that STARTS dynamic (`"$(mktemp)"`, `$X/f`), a pipe into a bare
# shell (`… | bash`), a user function or alias shadowing a verb, and a
# command fed by xargs' stdin are not resolved — the same residuals the
# regex engine carries; upgrade path = a value model for `$VAR` assignments.

import "bash-ast" as ba;

def isabs: test("^(/|[A-Za-z]:[/\\\\])");
def pjoin($b; $p): if ($p | isabs) then $p else ($b | sub("/+$"; "")) + "/" + $p end;
def mfo($v; $mode):
  if $mode == "entry" and ($v | test("(/|/\\.|/\\.\\.)$|^\\.\\.?$")) then "follow" else $mode end;
def base_of: split("/") | last;

# A word becomes one operand per word bash makes of it.
def operands: if .t == "lit" then . as $w | .vals[] | {k: "lit", raw: (if ($w.vals | length) > 1 then .v else $w.raw end), v, g, gp}
              else {k: .t, raw, pfx, dynfirst, why, ak, subs} end;
def mkop($s; $g):
  {k: "lit", v: $s, raw: $s, g: $g,
   gp: (if $g then ($s | sub("[*?\\[].*$"; "") | if test("/") then sub("/[^/]*$"; "/") else "./" end) else null end)};
# the operand minus its first $n characters (`of=X`, `-tX`, `--opt=X`)
def tail_op($n):
  if .k == "lit" then mkop(.v[$n:]; (.g and (.v[$n:] | test("[*?\\[]"))))
  elif .k == "dyn" then . + {pfx: (.pfx[$n:]), dynfirst: ((.pfx | length) <= $n), raw: (.raw[$n:])}
  else . end;
def tv: if .k == "lit" then .v else "" end;
def islong($full; $t): ($t | startswith("--")) and (($t[2:] | split("=")[0]) as $n | $n != "" and ($full | startswith($n)));
def lval($t): if ($t | test("=")) then ($t | sub("^[^=]*="; "")) else null end;

def rec_deny($k; $raw; $res): [["deny", $k, $raw, $res]];

# the records that check operand $o as a write under $mode, in cwd state $st
def target($o; $mode; $st):
  def at($p; $m):
    if ($p | isabs) then [["chk", $p, $o.raw, $m]]
    elif $st.unres then rec_deny("unresolved-cd"; $o.raw; $p)
    else [(($st.cwds + (if $st.jail then [] else [$E.cwd] end)) | unique)[] | ["chk", pjoin(.; $p), $o.raw, $m]] end;
  if $o.k == "amb" then rec_deny($o.ak; $o.raw; ($o.why // ""))
  elif $o.k == "psub" then []
  elif $o.k == "dyn" then
    if ($o.pfx | test("/")) then at($o.pfx | sub("/[^/]*$"; "/"); "follow")
    elif $o.dynfirst then []
    else at("./"; "follow") end
  elif $o.v == "" then []
  elif ($o.v | test("[\u0000-\u001f\u007f]")) then rec_deny("ast-unresolved"; $o.raw; "a control byte in the target")
  elif $o.g then at($o.gp; "follow")
  else at($o.v; mfo($o.v; $mode)) end;

# every absolute path a lit operand names in state $st (empty when unresolved)
def abs_all($o; $st):
  if ($o.v | isabs) then [$o.v] elif $st.unres then [] else [(($st.cwds + (if $st.jail then [] else [$E.cwd] end)) | unique)[] | pjoin(.; $o.v)] end;

def merge($a; $b):
  (($a.mut // []) + ($b.mut // []) | unique) as $m
  | if $a.unres or $b.unres then $a + {unres: true, mut: $m}
    else $a + {cwds: (($a.cwds + $b.cwds) | unique), mut: $m} | (if (.cwds | length) > 8 then .unres = true else . end) end;

# The cwd after `env -C`/`sudo -D` to operand $o from $st.
def chdir($o; $st):
  if $st.unres or $o.k != "lit" or $o.g then $st + {unres: true}
  elif ($o.v | test("[\u0000-\u001f\u007f]")) then $st + {unres: true}
  elif $E.cdpath_taint and ($o.v | test("^(/|\\./|\\.\\./|\\.$|\\.\\.$)") | not) then $st + {unres: true}
  elif ($o.v | isabs) then $st + {cwds: [$o.v]}
  else $st + {cwds: [$st.cwds[] | pjoin(.; $o.v)]} end;

def home_op: if $E.home_taint then {k: "amb", raw: "~", ak: "home-reassigned", why: ""} else mkop($E.home; false) end;

# A `cd`/`pushd` the shell may fail leaves the real cwd where it was, so the
# modelled one goes unresolved: a non-literal target, an extra operand, a
# redirect other than fd 0-2 to /dev/null, a relative target under the CDPATH
# taint, `-P` with `..`, a target that is not a searchable directory, or one
# an earlier command in this call removed, moved or chmod-ed (`mut`). Whether
# a path is a directory comes from $E.dirs ({path: {d, c}}, c = canonical);
# an unknown path prints `needpath PATH` for the guard to look up and run the
# predicate again.
def nullredir:
  ((.fd // "1") | IN("0", "1", "2")) and (.op | IN(">", ">>", "<", "&>", ">|"))
  and ([.w | operands] | length == 1 and .[0].k == "lit" and .[0].v == "/dev/null");
def muthit($p; $st):
  (($E.dirs // {})[$p].c // $p) as $c
  | any(($st.mut // [])[]; . == "*" or (. as $m | [$m, (($E.dirs // {})[$m].c // $m)] | any(.[]; . as $x | any($p, $c; (. + "/") | startswith($x + "/")))));
def cdgo($o; $st; $phys; $extra; $R):
  ($st + {unres: true}) as $u
  | if $st.jail or $o.k != "lit" or $o.g then {r: [], st: $u}
    elif ($o.v | test("[\u0000-\u001f\u007f]")) then {r: [], st: $u}
    elif ($o.v | isabs | not) and $st.unres then {r: [], st: $u}
    elif $extra or any($R[]; nullredir | not) then {r: [], st: $u}
    elif $E.cdpath_taint and ($o.v | test("^(/|\\./|\\.\\./|\\.$|\\.\\.$)") | not) then {r: [], st: $u}
    elif $phys and (("/" + $o.v + "/") | test("/\\.\\./")) then {r: [], st: $u}
    else (if ($o.v | isabs) then [$o.v] else [$st.cwds[] | pjoin(.; $o.v)] end) as $T
      | [$T[] | select(($E.dirs // {})[.] == null)] as $need
      | if ($need | length) > 0 then {r: [$need[] | ["needpath", .]], st: $u}
        elif any($T[]; $E.dirs[.].d != true) or any($T[]; muthit(.; $st)) then {r: [], st: $u}
        else {r: [], st: ($st + {cwds: $T, unres: false})} end
    end;

# The paths a simple command removes, moves or chmods, for muthit: the
# operands after an rm/rmdir/mv/chmod/… word, `*` for anything unresolved,
# for xargs, a find that deletes or execs, or a shell string naming one.
def mutnote($a; $st):
  def mverb: IN("rm", "rmdir", "mv", "chmod", "unlink", "rename", "chown", "chgrp", "setfacl");
  ($a | map(if .k == "lit" then .v else "" end)) as $t
  | (first(range(0; $a | length) as $i | select($a[$i].k == "lit" and ($t[$i] | base_of | mverb)) | $i) // null) as $vi
  | ([$a[] | select(.k == "lit" and (.v | test("\\s")) and (.v | test("(^|[\\s;&|(])(rm|rmdir|mv|chmod|unlink|find|xargs)([\\s;&|)]|$)")))] | length > 0) as $str
  | if any($t[]; base_of == "xargs") or $str
       or (any($t[]; base_of == "find") and any($t[]; IN("-delete", "-exec", "-execdir", "-ok", "-okdir"))) then ["*"]
    elif $vi == null then []
    else $a[$vi + 1:] as $ops
      | (reduce range(0; $ops | length) as $j ({dd: false, l: []};
          ($ops[$j] | tv) as $x
          | if (.dd | not) and $x == "--" then .dd = true
            elif $ops[$j].k == "lit" and $x == "" then .
            elif (.dd | not) and $ops[$j].k == "lit" and ($x | startswith("-")) then .
            elif $ops[$j].k != "lit" or $ops[$j].g or ($st.unres and ($x | isabs | not)) then .l += ["*"]
            else .l += [abs_all($ops[$j]; $st)[] | sub("/+$"; "") | if . == "" then "/" else . end] end)) | .l
    end;

# A body run as shell code: literal → parse it again; otherwise deny when its
# static text names a write.
def body_rec($txt; $lit; $st):
  if $lit then [["reparse", $txt, ($st | tojson)]]
  elif ($txt | test(">|(^|[^A-Za-z0-9_-])(tee|sed|cp|mv|rm|touch|truncate|ln|install|rsync|dd|tar|git|eval|bash|sh|zsh|dash|ksh|cd|pushd)([^A-Za-z0-9_-]|$)"))
  then rec_deny("unsafe-interp-body"; $txt; "")
  else [] end;
# A body built from a variable or from a substitution that reads repository or
# file data (git log/show/cat-file…, cat, head, `$(<f)`) can carry any write.
def datadeny($ops):
  def reader:
    (.argv[0].vals[0].v? // "" | base_of) as $p
    | ($p | IN("cat", "head", "tail", "tac", "less", "more", "nl", "od", "xxd", "strings", "base64", "sed", "awk", "cut", "sort", "uniq", "tr", "grep", "jq", "yq", "rev", "paste"))
      or ($p == "git" and ([.argv[1:][] | .vals[0].v? // ""] | map(select(startswith("-") | not)) | .[0] // "" | IN("log", "show", "cat-file", "blame", "grep", "diff", "rev-list", "notes", "var", "config", "describe", "for-each-ref", "shortlog", "format-patch", "archive")));
  [$ops[] | select(.k != "lit")
   | select((.raw | test("\\$[A-Za-z_{@*#?0-9!-]"))
            or any(.subs[]?[]? | .. | objects | select(.k? == "stmt");
                   (.cmd == null and any(.redirs[]; .op == "<")) or (.cmd.k? == "call" and (.cmd | reader))))]
  | if length > 0 then rec_deny("unsafe-interp-body"; .[0].raw; "a shell body read from a variable or from file data") else [] end;
def op_body($o; $st): body_rec(($o.v // $o.raw); ($o.k == "lit"); $st) + datadeny([$o]);

def optloop($a; $vals):
  # index of the first operand after leading options; $vals lists the
  # options that take the next word as their value
  def go($i): if $i >= ($a | length) then $i
              else ($a[$i] | tv) as $t
              | if $t == "--" then $i + 1
                elif ($t | startswith("-")) and $t != "-" then (if any($vals[]; . == $t) then go($i + 2) else go($i + 1) end)
                else $i end end;
  go(0);

# ---- verb predicates: $a = the operands after the program word ----------

def v_sed($a; $st):
  ($a | length) as $n
  | def go($i; $s):
      if $i >= $n then $s
      else $a[$i] as $o | ($o | tv) as $t
      | if $s.dd then go($i + 1; $s + {bare: ($s.bare + [$o])})
        elif $t == "--" then go($i + 1; $s + {dd: true})
        elif $t == "-e" or $t == "--expression" or $t == "-f" or $t == "--file" then go($i + 2; $s + {ef: true})
        elif ($t | test("^-[ef].|^--expression=|^--file=")) then go($i + 1; $s + {ef: true})
        elif ($t | startswith("--")) then
          if islong("expression"; $t) or islong("file"; $t) then go($i + (if ($t | test("=")) then 1 else 2 end); $s + {ef: true})
          elif islong("follow-symlinks"; $t) then go($i + 1; $s + {fs: true})
          elif islong("in-place"; $t) then go($i + 1; $s + {ip: true})
          else go($i + 1; $s) end
        elif ($t | startswith("-")) and $t != "-" then
          ($t[1:] | explode | map([.] | implode)) as $b
          | (first(range(0; $b | length) | select($b[.] == "i" or $b[.] == "e" or $b[.] == "f" or $b[.] == "l")) // null) as $k
          | if $k == null then go($i + 1; $s)
            elif $b[$k] == "i" then go($i + 1; $s + {ip: true})
            elif $b[$k] == "l" then go($i + 1; $s)
            else go($i + (if $k == ($b | length) - 1 then 2 else 1 end); $s + {ef: true}) end
        else go($i + 1; $s + {bare: ($s.bare + [$o])}) end
      end;
  go(0; {dd: false, ef: false, fs: false, ip: false, bare: []}) as $s
  | if $s.ip | not then []
    else (if $s.fs then "follow" else "entry" end) as $m
      | [($s.bare | if ($s.ef | not) and length >= 1 then .[1:] else . end)[] | target(.; $m; $st)[]] end;

def v_tee($a; $st):
  def go($i; $dd):
    if $i >= ($a | length) then []
    else ($a[$i] | tv) as $t
    | if ($dd | not) and $t == "--" then go($i + 1; true)
      elif ($dd | not) and ($t | startswith("-")) then go($i + 1; false)
      else target($a[$i]; "follow"; $st) + go($i + 1; $dd) end end;
  go(0; false);

def v_rmlike($verb; $a; $st):
  (if $verb == "rm" then "entry" else "follow" end) as $m
  | def go($i; $dd):
      if $i >= ($a | length) then []
      else ($a[$i] | tv) as $t
      | if $dd then target($a[$i]; $m; $st) + go($i + 1; true)
        elif $t == "--" then go($i + 1; true)
        elif ($t == "-s" or $t == "--size" or $t == "-r" or $t == "--reference") and $verb == "truncate" then go($i + 2; false)
        elif ($t | startswith("-")) then go($i + 1; false)
        else target($a[$i]; $m; $st) + go($i + 1; false) end end;
    go(0; false);

def opt_scan($t):
  if ($t | startswith("--")) then
    if islong("no-target-directory"; $t) then {bigt: true}
    elif islong("no-dereference"; $t) then {smalln: true}
    elif islong("remove-destination"; $t) then {rmdest: true}
    elif islong("force"; $t) then {force: true}
    elif islong("target-directory"; $t) then (lval($t) as $v | if ($v // "") != "" then {tdirs: ($t | length) - ($v | length)} else {twant: true} end)
    else {} end
  elif ($t | test("^-.")) then
    ($t[1:] | explode | map([.] | implode)) as $b
    | (first(range(0; $b | length) | select($b[.] == "t")) // null) as $k
    | ($b[: (if $k == null then ($b | length) else $k end)]) as $pre
    | {bigt: any($pre[]; . == "T"), smalln: any($pre[]; . == "n"), force: any($pre[]; . == "f")}
      + (if $k == null then {} elif $k < ($b | length) - 1 then {tdirs: ($k + 2)} else {twant: true} end)
  else {} end;

# cp/mv/ln: options, then the operand list and the target directory
def cpscan($a):
  def go($i; $s):
    if $i >= ($a | length) then $s
    else $a[$i] as $o | ($o | tv) as $t
    | if $s.dd then go($i + 1; $s + {ops: ($s.ops + [$o])})
      elif $t == "--" then go($i + 1; $s + {dd: true})
      elif ($t | startswith("-")) and $t != "-" then
        opt_scan($t) as $f
        # jq-alt-ok: an absent flag and a false one both mean unset
        | ($s + {bigt: ($s.bigt or ($f.bigt // false)), smalln: ($s.smalln or ($f.smalln // false)),
                  rmdest: ($s.rmdest or ($f.rmdest // false)), force: ($s.force or ($f.force // false))}) as $s2 # jq-alt-ok: an absent flag and a false one both mean unset
        | if $f.tdirs then go($i + 1; $s2 + {tdir: ($o | tail_op($f.tdirs))})
          elif $f.twant then go($i + 2; $s2 + {tdir: $a[$i + 1]})
          else go($i + 1; $s2) end
      else go($i + 1; $s + {ops: ($s.ops + [$o])}) end end;
  go(0; {dd: false, ops: [], tdir: null, bigt: false, smalln: false, rmdest: false, force: false});

def dird($d; $isdir; $dm; $cm; $nm; $srcs; $st):
  if $d.k == "lit" and ($d.g | not) and ($d.v != "") and ($d.v | test("[\u0000-\u001f\u007f]") | not) then
    if ($d.v | isabs | not) and $st.unres then rec_deny("unresolved-cd"; $d.raw; $d.v)
    else [abs_all($d; $st)[] | ["dird", ., $d.raw, (if $isdir then "1" else "0" end), $dm, $cm, $nm]
          + [$srcs[] | select(.k == "lit" and (.g | not)) | .v | base_of]] end
  else target($d; "follow"; $st) end;

def v_cpmv($verb; $a; $st):
  cpscan($a) as $s
  | ($verb == "mv" and $s.bigt) as $nodrf
  | ($verb == "cp" and $s.rmdest) as $rmdest
  | ($verb == "cp" and $s.force) as $force
  | (if $verb == "mv" or $rmdest then "entry" elif $force then "both" else "follow" end) as $cm
  | (if $s.tdir != null then {d: $s.tdir, srcs: $s.ops, isdir: true}
     elif ($s.ops | length) >= 2 then {d: $s.ops[-1], srcs: $s.ops[:-1], isdir: false}
     else null end) as $p
  | if $p == null then []
    else
      (if $verb == "mv" then [$p.srcs[] | target(.; "entry"; $st)[]] else [] end)
      + (if $nodrf and ($p.isdir | not) then target($p.d; "entry"; $st)
         else (($p.d.v // "") as $v
               | (if $verb == "mv" or $rmdest then mfo($v; "entry") elif $force then "both" else "follow" end)) as $nm
           | dird($p.d; $p.isdir; "follow"; $cm; $nm; $p.srcs; $st) end)
    end;

def v_ln($a; $st):
  cpscan($a) as $s
  | ($s.bigt or $s.smalln) as $nodrf
  | (if $s.tdir != null then {d: $s.tdir, srcs: $s.ops, isdir: true}
     elif ($s.ops | length) >= 2 then {d: $s.ops[-1], srcs: $s.ops[:-1], isdir: false}
     else null end) as $p
  | if $p == null then []
    elif $nodrf and ($p.isdir | not) then target($p.d; "entry"; $st)
    else dird($p.d; $p.isdir; "follow"; "entry"; mfo($p.d.v // ""; "entry"); $p.srcs; $st) end;

def v_install($a; $st):
  def go($i; $s):
    if $i >= ($a | length) then $s
    else $a[$i] as $o | ($o | tv) as $t
    | if $s.dd then go($i + 1; $s + {ops: ($s.ops + [$o])})
      elif $t == "--" then go($i + 1; $s + {dd: true})
      elif ($t | test("^-t.")) then go($i + 1; $s + {tdir: ($o | tail_op(2))})
      elif $t == "-t" or $t == "--target-directory" then go($i + 2; $s + {tdir: $a[$i + 1]})
      elif ($t | startswith("--target-directory=")) then go($i + 1; $s + {tdir: ($o | tail_op(19))})
      elif $t == "-d" or $t == "--directory" then go($i + 1; $s + {dm: true})
      elif any(("-m","--mode","-o","--owner","-g","--group","-S","--suffix","--strip-program"); . == $t) then go($i + 2; $s)
      elif ($t | startswith("-")) then go($i + 1; $s)
      else go($i + 1; $s + {ops: ($s.ops + [$o])}) end end;
  go(0; {dd: false, ops: [], tdir: null, dm: false}) as $s
  | if $s.tdir != null then target($s.tdir; "follow"; $st)
    elif $s.dm then [$s.ops[] | target(.; "follow"; $st)[]]
    elif ($s.ops | length) >= 2 then target($s.ops[-1]; "follow"; $st)
    else [] end;

def _rsync_vals: ["-e","-f","--filter","--exclude","--exclude-from","--include","--include-from","--files-from",
  "--temp-dir","-T","--backup-dir","--link-dest","--compare-dest","--copy-dest","--partial-dir","--log-file",
  "--log-file-format","--out-format","--password-file","--bwlimit","--timeout","--contimeout","--port",
  "--address","--sockopts","--usermap","--groupmap","--chown","--rsync-path","--rsh","--protocol",
  "--checksum-seed","--max-size","--min-size","--modify-window","--skip-compress","--chmod","-B",
  "--block-size","-M","--remote-option","--suffix","--max-delete","--iconv","--compress-level",
  "--checksum-choice","--write-batch","--only-write-batch","--read-batch","--stop-after"];

def v_rsync($a; $st):
  def go($i; $s):
    if $i >= ($a | length) then $s
    else $a[$i] as $o | ($o | tv) as $t
    | if $s.dd then go($i + 1; $s + {ops: ($s.ops + [$o])})
      elif $t == "--" then go($i + 1; $s + {dd: true})
      elif any(_rsync_vals[]; . == $t) then go($i + 2; $s)
      elif ($t | startswith("-")) then go($i + 1; $s)
      else go($i + 1; $s + {ops: ($s.ops + [$o])}) end end;
  go(0; {dd: false, ops: []}) as $s
  | if ($s.ops | length) < 2 then []
    else $s.ops[-1] as $d | ($d.v // $d.raw) as $v
      | if ($v | test("^[A-Za-z]:[/\\\\]")) then target($d; "follow"; $st)
        elif ($v | startswith("rsync://")) or ($v | split("/")[0] | test(":")) then []
        else target($d; "follow"; $st) end end;

def v_dd($a; $st):
  [$a[] | select((.v // .pfx // "") | startswith("of=")) | target(tail_op(3); "follow"; $st)[]];

def v_tar($a; $st):
  def go($i; $s):
    if $i >= ($a | length) then $s
    else $a[$i] as $o | ($o | tv) as $t
    | if $t == "--directory" then go($i + 2; $s + {dirs: ($s.dirs + [$a[$i + 1] | select(. != null)])})
      elif ($t | startswith("--directory=")) then go($i + 1; $s + {dirs: ($s.dirs + [$o | tail_op(12)])})
      elif $t == "--file" then go($i + 2; $s + {f: $a[$i + 1]})
      elif ($t | startswith("--file=")) then go($i + 1; $s + {f: ($o | tail_op(7))})
      elif $t == "--extract" or $t == "--get" then go($i + 1; $s + {x: true})
      elif any(("--create","--append","--update","--catenate","--concatenate","--delete"); . == $t) then go($i + 1; $s + {w: true})
      elif ($t | startswith("--")) then go($i + 1; $s)
      elif ($t | test("^-.")) then
        ($t[1:] | explode | map([.] | implode)) as $b
        | (first(range(0; $b | length) | select($b[.] | test("^[fCbLNTXFHIKVg]$"))) // null) as $k
        | ($b[: ($k // ($b | length))]) as $fl
        | ($s + {x: ($s.x or any($fl[]; . == "x")), w: ($s.w or any($fl[]; IN("c", "r", "u", "A")))}) as $s2
        | if $k == null then go($i + 1; $s2)
          elif $k < ($b | length) - 1 then
            go($i + 1; $s2 + (if $b[$k] == "C" then {dirs: ($s2.dirs + [$o | tail_op($k + 2)])}
                              elif $b[$k] == "f" then {f: ($o | tail_op($k + 2))} else {} end))
          else go($i + 2; $s2 + (if $a[$i + 1] == null then {}
                                 elif $b[$k] == "C" then {dirs: ($s2.dirs + [$a[$i + 1]])}
                                 elif $b[$k] == "f" then {f: $a[$i + 1]} else {} end)) end
      elif $i == 0 and ($t | test("^[a-zA-Z]+$")) then
        ($t | explode | map([.] | implode)) as $b
        | reduce $b[] as $c ({s: ($s + {x: ($s.x or any($b[]; . == "x")), w: ($s.w or any($b[]; IN("c", "r", "u", "A")))}), j: ($i + 1)};
            if ($c | test("^[fCbLNTXFHIKVg]$")) then
              (if $a[.j] == null then . elif $c == "C" then .s.dirs += [$a[.j]] elif $c == "f" then .s.f = $a[.j] else . end) | .j += 1
            else . end)
        | go(.j; .s)
      else go($i + 1; $s) end end;
  go(0; {x: false, w: false, f: null, dirs: []}) as $s
  # create, append, update and delete write the -f archive
  | (if $s.w and $s.f != null and ($s.f | tv) != "-" then target($s.f; "follow"; $st) else [] end)
  + if $s.x | not then []
    # an extract with no -C lands in the cwd
    else reduce ($s.dirs | if length == 0 then [mkop("."; false)] else . end)[] as $d ({c: null, r: []};
        (if $d.k == "lit" and ($d.g | not) and ($d.v | isabs | not) and .c != null and .c.k == "lit" and (.c.g | not)
         then mkop(.c.v + "/" + $d.v; false) + {raw: (.c.raw + "/" + $d.raw)} else $d end) as $c
        | {c: $c, r: (.r + target($c; "follow"; $st))})
      | .r end;

# git [opts] commit: the repo it commits in
def v_git($a; $st):
  def go($i; $s):
    if $i >= ($a | length) then null
    else ($a[$i] | tv) as $t
    | if ($t | ascii_downcase) == "commit" then $s
      elif $t == "-C" then go($i + 2; $s + {c: ($s.c + [$a[$i + 1]])})
      elif $t == "--git-dir" then go($i + 2; $s + {gd: $a[$i + 1]})
      elif ($t | startswith("--git-dir=")) then go($i + 1; $s + {gd: ($a[$i] | tail_op(10))})
      elif any(("--work-tree","-c","--namespace","--config-env","--exec-path","--super-prefix"); . == $t) then go($i + 2; $s)
      elif ($t | startswith("-")) then go($i + 1; $s)
      else null end end;
  go(0; {c: [], gd: null}) as $s
  | if $s == null then []
    elif $st.jail then rec_deny("chroot-git"; ([$a[] | .raw] | join(" ")); "")
    elif any(($s.c + [$s.gd | select(. != null)])[]; . == null or .k != "lit" or .g) then
      rec_deny("unresolved-git-target"; ([$a[] | .raw] | join(" ")); "")
    else (reduce $s.c[] as $c ($st; chdir($c; .))) as $d
      | (if $s.gd != null then chdir($s.gd | .v |= sub("/\\.git/*$"; "") | if .v == "" then .v = "/" else . end; $d) else $d end) as $g
      | if $g.unres then rec_deny("unresolved-cd"; "git commit"; "")
        else [(($g.cwds + (if ($s.c | length) == 0 and $s.gd == null then [$E.cwd] elif ($s.c + [$s.gd] | map(select(. != null)) | all(.v | isabs)) then [] else [$E.cwd] end)) | unique)[] | ["cwd", .]] end
    end;

def shells: ["bash","sh","zsh","dash","ksh","rbash","mksh","ash","busybox"];

# ---- the walk -----------------------------------------------------------

def own_words:
  ((.redirs[] | (.w, (.hdoc.words[]?))), (.cmd | select(. != null)
    | if .k == "call" then (.argv[], (.assigns[] | .w, .arr[]?))
      elif .k == "compound" or .k == "other" then .words[] else empty end))
  | select(. != null);

def write_redir: (.op | IN(">", ">>", ">|", "&>", "&>>", "<>")) or (.op == ">&" and ((.w.vals[0].v? // "x") | test("^([0-9]+|-)$") | not));

def go($st):
  def seq($l; $s0):
    reduce $l[] as $x ({r: [], st: $s0}; . as $acc | ($x | go($acc.st)) as $o | {r: ($acc.r + $o.r), st: $o.st});
  # one simple command: $a its operands, $R its statement's redirects
  def call($a; $R; $st):
    if ($a | length) == 0 then {r: [], st: $st}
    else $a[0] as $p | $a[1:] as $rest
    | if $p.k == "amb" then {r: rec_deny($p.ak; $p.raw; ($p.why // "")), st: $st}
      elif $p.k != "lit" then {r: [], st: $st}
      else ($p.v | base_of | ascii_downcase | sub("\\.exe$"; "")) as $n
      | ($rest | map(tv)) as $t
      | def after($i): call($rest[$i:]; $R; $st);
        def keep($r): {r: $r, st: $st};
        # $more run under the new root $ro: every absolute path it names is
        # checked as itself and mapped into the root (`root` records set the
        # guard's _bwimc_chroot), and its cwd is the root's `/`
        def jailed($ro; $more):
          if $st.jail then keep(rec_deny("unresolved-chroot"; $ro.raw; "a chroot inside a chroot"))
          elif $ro.k != "lit" or $ro.g or $ro.v == "" then keep(rec_deny("unresolved-chroot"; $ro.raw; ""))
          elif ($ro.v | test("^/+$")) then call($more; $R; $st)
          else abs_all($ro; $st) as $rs
            | if ($rs | length) != 1 then keep(rec_deny("unresolved-chroot"; $ro.raw; ""))
              else keep([["root", $rs[0]]] + (call($more; $R; {cwds: ["/"], unres: false, stack: [], jail: true}) | .r) + [["root", ""]]) end
          end;
        if $n == "cd" or $n == "pushd" then
          # options: -P -L -e -@ bundles only, so `cd -1/..` is an operand
          (def ci($j): if $j < ($t | length) and ($t[$j] | test("^-[PLe@]+$")) then ci($j + 1)
                       elif $j < ($t | length) and $t[$j] == "--" then $j + 1 else $j end;
           ci(0)) as $i
          | any($t[:$i][]; test("^-[a-zA-Z@]*P")) as $phys
          | $rest[$i] as $o
          | (($rest | length) > $i + 1) as $extra
          | if $o == null then
              if $n == "cd" then cdgo(home_op; $st; false; false; $R)
              elif (($st.stack // []) | length) > 0 then {r: [], st: ($st + {unres: true})}
              else {r: [], st: $st} end
            else ($st | if $n == "pushd" then .stack = ((.stack // []) + [{cwds, unres}]) else . end) as $s1
              | if ($o | tv) == "-" or (($o | tv) | test("^[+-][0-9]")) then {r: [], st: ($s1 + {unres: true})}
                else cdgo($o; $s1; $phys; $extra; $R) end
            end
        elif $n == "popd" then
          if ($rest | length) == 0 and (($st.stack // []) | length) > 0 then {r: [], st: ($st + $st.stack[-1] + {stack: $st.stack[:-1]})}
          else {r: [], st: ($st + {unres: true})} end
        elif $n == "command" then
          (optloop($rest; []) as $i | if any($t[:$i][]; test("^-[a-zA-Z]*[vV]")) then keep([]) else after($i) end)
        # `--` as the program: what `time -p --` and `nohup --` leave behind
        elif $n == "builtin" or $n == "nohup" or $n == "--" then after(0)
        elif $n == "exec" then after(optloop($rest; ["-a"]))
        elif $n == "time" then after(optloop($rest; ["-f","-o","--format","--output"]))
        elif $n == "setsid" then after(optloop($rest; []))
        elif $n == "nice" then after(optloop($rest; ["-n","--adjustment"]))
        elif $n == "timeout" then after(optloop($rest; ["-s","-k","--signal","--kill-after"]) + 1)
        elif $n == "stdbuf" then after(optloop($rest; ["-i","-o","-e","--input","--output","--error"]))
        elif $n == "ionice" then (if any($t[]; . == "-p" or . == "-P" or . == "-u") then keep([]) else after(optloop($rest; ["-c","-n","--class","--classdata"])) end)
        elif $n == "chrt" then (if any($t[]; . == "-p" or . == "--pid") then keep([]) else after(optloop($rest; ["-T","-P","-D"]) + 1) end)
        elif $n == "taskset" then (if any($t[]; test("^-[a-z]*p")) then keep([]) else after(optloop($rest; []) + 1) end)
        elif $n == "doas" then after(optloop($rest; ["-u","-C"]))
        elif $n == "xargs" then after(optloop($rest; ["-I","-L","-n","-P","-s","-d","-E","-a","--arg-file","--delimiter","--max-args","--max-procs","--max-chars","--max-lines","--replace","--eof"]))
        elif $n == "env" then
          def eg($i; $s):
            if $i >= ($rest | length) then $s + {i: $i}
            else $rest[$i] as $o | ($o | tv) as $x
            | if $x == "--" then eg($i + 1; $s + {dd: true})
              elif ($s.dd | not) and $x == "--chdir" then eg($i + 2; $s + {cd: $rest[$i + 1]})
              elif ($s.dd | not) and ($x | startswith("--chdir=")) then eg($i + 1; $s + {cd: ($o | tail_op(8))})
              elif ($s.dd | not) and $x == "--split-string" then $s + {S: $rest[$i + 1], i: ($i + 2)}
              elif ($s.dd | not) and ($x | startswith("--split-string=")) then $s + {S: ($o | tail_op(15)), i: ($i + 1)}
              elif ($s.dd | not) and ($x == "--unset" or $x == "--argv0") then eg($i + 2; $s)
              elif ($s.dd | not) and ($x | startswith("--")) then eg($i + 1; $s)
              elif ($s.dd | not) and $x == "-" then eg($i + 1; $s)
              # a short bundle: flags i0v, then at most one of C S u a whose
              # value is the bundle's rest or the next word; any other letter
              # is an option this model does not know
              elif ($s.dd | not) and ($x | startswith("-")) then
                if ($x | test("^-[i0v]*([CSua].*)?$")) then
                  ($x | capture("^-(?<f>[i0v]*)(?<l>[CSua]?)(?<v>.*)$")) as $m
                  | if $m.l == "" then eg($i + 1; $s)
                    else (if $m.v == "" then [$rest[$i + 1], 2] else [($o | tail_op(2 + ($m.f | length))), 1] end) as [$val, $adv]
                    | if $m.l == "C" then eg($i + $adv; $s + {cd: $val})
                      elif $m.l == "S" then $s + {S: $val, i: ($i + $adv)}
                      else eg($i + $adv; $s) end end
                else $s + {bad: $o, i: $i} end
              elif ($x | test("^[A-Za-z_][A-Za-z0-9_]*=")) or ($o.k == "dyn" and ($o.pfx | test("^[A-Za-z_][A-Za-z0-9_]*="))) then eg($i + 1; $s)
              else $s + {i: $i} end end;
          eg(0; {dd: false}) as $e
          | (if $e.cd then chdir($e.cd; $st) else $st end) as $cst
          | if $e.bad then keep(rec_deny("ast-unresolved"; $e.bad.raw; "an env option this model does not know"))
            elif $e.S then
              ($rest[$e.i:]) as $more
              | keep(body_rec((([$e.S] + $more) | map(.v // .raw) | join(" ")); all(([$e.S] + $more)[]; .k == "lit"); $cst) + datadeny([$e.S] + $more))
            else call($rest[$e.i:]; $R; $cst) | .st = $st end
        elif $n == "sudo" then
          def sg($i; $s):
            if $i >= ($rest | length) then $s + {i: $i}
            else $rest[$i] as $o | ($o | tv) as $x
            | if $x == "--" then $s + {i: ($i + 1)}
              elif $x == "--chdir" then sg($i + 2; $s + {cd: $rest[$i + 1]})
              elif ($x | startswith("--chdir=")) then sg($i + 1; $s + {cd: ($o | tail_op(8))})
              elif $x == "--chroot" then sg($i + 2; $s + {root: $rest[$i + 1]})
              elif ($x | startswith("--chroot=")) then sg($i + 1; $s + {root: ($o | tail_op(9))})
              elif $x == "--login" then sg($i + 1; $s + {login: true})
              elif any(("--user","--group","--close-from","--host","--prompt","--other-user","--role","--type","--command-timeout"); . == $x) then sg($i + 2; $s)
              elif ($x | startswith("--")) then sg($i + 1; $s)
              # a short bundle: flags, then at most one valued letter whose
              # value is the bundle's rest or the next word; `-i` starts in
              # the target user's home; any other letter fails closed
              elif ($x | test("^-[AbBEeHiKklnPSsVv]*([CDghpRrTtUu].*)?$")) and $x != "-" then
                ($x | capture("^-(?<f>[AbBEeHiKklnPSsVv]*)(?<l>[CDghpRrTtUu]?)(?<v>.*)$")) as $m
                | ($s + (if ($m.f | test("i")) then {login: true} else {} end)) as $s
                | if $m.l == "" then sg($i + 1; $s)
                  else (if $m.v == "" then [$rest[$i + 1], 2] else [($o | tail_op(2 + ($m.f | length))), 1] end) as [$val, $adv]
                  | if $m.l == "D" then sg($i + $adv; $s + {cd: $val})
                    elif $m.l == "R" then sg($i + $adv; $s + {root: $val})
                    else sg($i + $adv; $s) end end
              elif ($x | startswith("-")) and $x != "-" then $s + {bad: $o, i: $i}
              elif ($x | test("^[A-Za-z_][A-Za-z0-9_]*=")) then sg($i + 1; $s)
              else $s + {i: $i} end end;
          sg(0; {}) as $e
          | if $e.bad then keep(rec_deny("ast-unresolved"; $e.bad.raw; "a sudo option this model does not know"))
            elif $e.root != null and $e.cd then keep(rec_deny("unresolved-chroot"; $e.root.raw; "sudo -R with -D"))
            elif $e.root != null then jailed($e.root; $rest[$e.i:])
            else (if $e.login then $st + {unres: true} elif $e.cd then chdir($e.cd; $st) else $st end) as $cst
              | call($rest[$e.i:]; $R; $cst) | .st = $st end
        elif $n == "chroot" then
          (optloop($rest; ["--userspec","--groups"]) as $i
           | if $rest[$i] == null then keep([]) else jailed($rest[$i]; $rest[$i + 1:]) end)
        elif $n == "eval" then
          (if ($rest | length) == 0 then keep([])
           else {r: (body_rec(($rest | map(.v // .raw) | join(" ")); all($rest[]; .k == "lit"); $st) + datadeny($rest)),
                 st: (if any($rest[]; (.v // .raw) | test("(^|[^A-Za-z0-9_])(cd|pushd|popd)([^A-Za-z0-9_]|$)")) then $st + {unres: true} else $st end)} end)
        elif $n == "su" or $n == "runuser" or $n == "script" or $n == "flock" then
          (first(range(0; $rest | length) as $i
             | ($t[$i]) as $x
             | if ($x | test("^-[a-zA-Z]*c$")) or $x == "--command" then $rest[$i + 1]
               elif ($x | startswith("--command=")) then ($rest[$i] | tail_op(10))
               else empty end) // null) as $b
          | if $b != null then keep(op_body($b; $st))
            elif $n == "flock" then
              (optloop($rest; ["-E","-w","--conflict-exit-code","--timeout"]) as $i | after($i + 1))
            else keep([]) end
        elif any(shells[]; . == $n) then
          def sh($i):
            if $i >= ($rest | length) then {k: "stdin"}
            else ($t[$i]) as $x
            | if ($x | test("^-[a-zA-Z]*c[a-zA-Z]*$")) then {k: "c", b: $rest[$i + 1]}
              elif $x == "-o" or $x == "+o" or $x == "-O" or $x == "+O" then sh($i + 2)
              elif $x == "--" then {k: "file"}
              elif ($x | test("^[-+]")) and $rest[$i].k == "lit" then sh($i + 1)
              else {k: "file"} end end;
          sh(0) as $m
          | if $m.k == "c" then keep(if $m.b == null then [] else op_body($m.b; $st) end)
            elif $m.k == "stdin" then
              ([$R[] | select((.fd // "0") == "0" and (.op | IN("<<", "<<-", "<<<")))] | last) as $h
              | if $h == null then keep([])
                elif $h.hdoc != null then
                  keep(if $h.hdoc.lit then [["reparse", $h.hdoc.text, ($st | tojson)]] else rec_deny("unresolved-heredoc"; $p.raw; "") end)
                else keep([$h.w | operands] | if length == 1 then op_body(.[0]; $st) else rec_deny("ast-unresolved"; $h.w.raw; "") end)
              end
            else keep([]) end
        elif $n == "sed" then keep(v_sed($rest; $st))
        elif $n == "tee" then keep(v_tee($rest; $st))
        elif $n == "rm" or $n == "touch" or $n == "truncate" then keep(v_rmlike($n; $rest; $st))
        elif $n == "cp" or $n == "mv" then keep(v_cpmv($n; $rest; $st))
        elif $n == "ln" then keep(v_ln($rest; $st))
        elif $n == "install" then keep(v_install($rest; $st))
        elif $n == "rsync" then keep(v_rsync($rest; $st))
        elif $n == "dd" then keep(v_dd($rest; $st))
        elif $n == "tar" or $n == "gtar" or $n == "bsdtar" then keep(v_tar($rest; $st))
        elif $n == "git" then keep(v_git($rest; $st))
        # grep may be ugrep, whose --filter runs commands and --save-config writes
        elif ($n | IN("grep", "egrep", "fgrep", "ugrep", "ug")) and any($t[]; test("^--(filter|save-config)")) then
          keep(rec_deny("ast-unresolved"; $p.raw; "ugrep --filter or --save-config"))
        else keep([]) end
      end
    end;
  if type == "array" then seq(.; $st)
  else . as $S
  | [$S | own_words | .subs[] | go($st)] as $sg
  | ([$sg[].r[]]) as $sr
  | ($st + {mut: ((($st.mut // []) + [$sg[].st.mut[]?]) | unique)}) as $st
  | ([$S.redirs[] | select(write_redir) | .w | operands | target(.; "follow"; $st)[]]) as $rr
  | ($S.cmd) as $c
  | (if $c == null then {r: [], st: $st}
     elif $c.k == "call" then
       [$c.argv[] | operands] as $a
       | call($a; $S.redirs; $st) as $o
       | mutnote($a; $st) as $m
       | {r: ($o.r + [$m[] | select(. != "*" and ($E.dirs // {})[.] == null) | ["needpath", .]]),
          st: ($o.st + {mut: ((($o.st.mut // []) + $m) | unique)})}
     elif $c.k == "and" or $c.k == "or" then
       # `y` runs after x succeeded (&&) or failed (||): a failed x may have
       # moved the cwd part-way, so `||` starts y from both states
       ($c.x | go($st)) as $x
       | ($c.y | go(if $c.k == "and" then $x.st else merge($st; $x.st) end)) as $y
       | {r: ($x.r + $y.r), st: merge($st; merge($x.st; $y.st))}
     elif $c.k == "pipe" then
       ($c.x | go($st)) as $x | ($c.y | go($st)) as $y | {r: ($x.r + $y.r), st: merge($st; $y.st)}
     elif $c.k == "sub" then {r: ($c.body | go($st) | .r), st: $st}
     elif $c.k == "block" then ($c.body | go($st))
     elif $c.k == "compound" then
       (reduce $c.bodies[] as $b ($st; merge(.; ($b | go($st) | .st)))) as $m1
       | [$c.bodies[] | go($m1)] as $p2
       | {r: [$p2[].r[]], st: (reduce $p2[].st as $s ($m1; merge(.; $s)))}
     # zsh reads `time -p` as running a command named -p: the body may not run
     elif $c.k == "wrap" then ($c.body | go($st))
       | (if $c.t == "CoprocClause" then .st = $st elif $c.posix then .st = merge($st; .st) else . end)
     else {r: [], st: $st} end) as $o
  | {r: ($sr + $rr + $o.r), st: (if $S.bg then $st else $o.st end)}
  end;

ba::model($E) | go($E.st) | .r[] | map(tostring) | join("\u001f") + "\u001e"
