#!/usr/bin/env bash
# scripts/guardrails/check-git-env-scrub.sh — gate: trust-path git calls must
# scrub the repository-redirecting GIT_* variables.
#
# WHY: a git subprocess on a trust path inherits the caller's GIT_* env, so an
# attacker-set value steers which repo/worktree/index/object store it actually
# answers about (PR 1212 anchor-handoff.sh, PR 1217 plugin-profiles.mjs — both
# this class). This gate stops a new unscrubbed call from landing.
#
# The scrub set is the 14 variables scripts/lib/git-clean.sh and
# scripts/lanes/git-clean.mjs clear (GIT_NO_REPLACE_OBJECTS is deliberately
# NOT in it). A hand scrub of only the original four no longer
# counts.
#
# Trust paths (fixed, not discovered): scripts/handover/**, scripts/lanes/**,
# scripts/hooks/**, scripts/cr/**, scripts/lib/go-gate.sh. Excluded within
# those: test-*.sh, *.test.{mjs,js,cjs,ts}, test-*.ps1, test_*.py, and
# anything under a fixtures/ or test-fixtures/ directory — those run git in
# scratch fixtures by design.
#
# Scanned extensions: .sh .mjs .js .cjs .ts .py .ps1.
#
# Three detectors, deliberately different units:
#
#   shell (*.sh)   FILE-LEVEL. A file that invokes git must scrub the full set
#                  ONCE, before that first invocation: `unset` of all 14
#                  (several lines allowed), or sourcing scripts/lib/git-clean.sh
#                  (a real `.`/`source` command) and calling git_env_scrub as a
#                  command, or a per-call `env -u NAME ...` of all 14 on the
#                  call itself, or an own-line `# git-env-ok: <reason>` comment.
#                  An unset / git_env_scrub inside a function counts only when
#                  that function is called before the first invocation.
#                  A git invocation is `git`, `\git`, a path ending /git, a
#                  variable assigned a git path (`G=$(command -v git)`) at
#                  command position, or the same inside `bash -c '...'` /
#                  `eval "..."` payloads. Line continuations are joined; a `#`
#                  starts a comment only at a word start (`$#`, `${#x}` do not).
#                  A shebang-less .sh that invokes git needs an own-line
#                  `# sourced-lib: <reason>` marker (a bare marker fails).
#
#   JS (.mjs/.js/.cjs/.ts)  PER-CALL, token-based (strings, comments and
#                  templates are real tokens, not regex text). Any call whose
#                  first argument is the string 'git' (or 'git ...') — a spawn
#                  primitive or a wrapper such as run('git', ...) — or a const
#                  holding 'git', is a hit unless ALL 14 names appear in that
#                  call's own paren-balanced argument span as real code (a bare
#                  identifier, a quoted object key, or x['NAME']), or its line
#                  carries a real trailing `// git-env-ok: <reason>` comment.
#                  A nearby gitClean() call masks nothing.
#
#   py/ps1         FILE-LEVEL, like shell: all 14 names must appear in code
#                  before the first git call, or `# git-env-ok: <reason>`.
#
# Exemption: a non-empty reason only — a bare marker still fails.
#
# Ratchet: scripts/guardrails/git-env-baseline.txt (`#` lines are comments).
# `SHELL:<path>` / `FILE:<path>` grandfather a whole file; `JS:<path>:<hash>`
# grandfathers one unscrubbed JS call by trimmed-line hash, WITH MULTIPLICITY.
#
# The gate does not trust its environment: it clears the GIT_* set from its own
# process (keeping GIT_INDEX_FILE under --staged, where a hook legitimately
# points it at the index being committed) and reads the baseline only from the
# tracked default or an explicit --baseline FILE — never from an inherited
# variable.
#
# Modes:
#   [--baseline FILE] --staged        scan trust-path files as STAGED.
#   [--baseline FILE] --tree [PATH...] scan trust-path files on disk; PATH args
#                                      override the default trust-path set.
#   [--baseline FILE] --files [FILE...] scan only the named files, keeping those
#                                      that are trust-path scannable (a PR's
#                                      changed files). A missing file fails
#                                      closed; no files scans nothing; a baseline
#                                      entry is judged stale only for a named
#                                      file or one gone from disk.
#   --emit-baseline                   print every hit's baseline key; exit 0.
#
# Exit: 0 = clean; 1 = unscrubbed/unexempted hit(s) outside the baseline;
# 2 = usage/setup error.
set -euo pipefail

usage() {
    echo "usage: $0 [--baseline FILE] --staged | --tree [PATH...] | --files [FILE...] | --emit-baseline" >&2
    exit 2
}

SCRUB_VARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT"

BASELINE_ARG=""
if [ "${1:-}" = "--baseline" ]; then
    [ "$#" -ge 2 ] || usage
    BASELINE_ARG="$2"
    shift 2
fi

MODE=""
TREE_PATHS=()
FILES_MODE=0
EMIT_BASELINE=0
case "${1:-}" in
    --staged)
        shift
        [ "$#" -eq 0 ] || usage
        MODE=staged
        ;;
    --tree)
        shift
        MODE=tree
        TREE_PATHS=("$@")
        ;;
    --files)
        shift
        MODE=tree
        FILES_MODE=1
        TREE_PATHS=("$@")
        ;;
    --emit-baseline)
        shift
        [ "$#" -eq 0 ] || usage
        MODE=tree
        EMIT_BASELINE=1
        ;;
    *)
        usage
        ;;
esac

# Self-scrub: this gate's own git calls (repo discovery, ls-files, diff
# --cached, show) must not follow an inherited redirect.
for _v in $SCRUB_VARS; do
    if [ "$MODE" = staged ] && [ "$_v" = GIT_INDEX_FILE ]; then continue; fi
    unset "$_v"
done
unset _v

if [ -n "$BASELINE_ARG" ]; then
    case "$BASELINE_ARG" in
        /*) : ;;
        *) BASELINE_ARG="$PWD/$BASELINE_ARG" ;;
    esac
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "check-git-env-scrub: not inside a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

BASELINE_FILE="${BASELINE_ARG:-$REPO_ROOT/scripts/guardrails/git-env-baseline.txt}"

# Baseline entries (comments and blanks dropped), one per array element.
BASE_ENTRIES=()
if [ "$EMIT_BASELINE" -ne 1 ] && [ -r "$BASELINE_FILE" ]; then
    while IFS= read -r _b || [ -n "$_b" ]; do
        case "$_b" in ''|'#'*) continue ;; esac
        BASE_ENTRIES+=("$_b")
    done < "$BASELINE_FILE"
fi

baseline_has() {
    local e
    [ "${#BASE_ENTRIES[@]}" -gt 0 ] || return 1
    for e in "${BASE_ENTRIES[@]}"; do
        [ "$e" = "$1" ] && return 0
    done
    return 1
}

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum
    else
        shasum -a 256
    fi
}

line_hash() {
    printf '%s' "$1" | sha256_hex | cut -c1-12
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_excluded_path() {
    case "$1" in
        */test-*.sh|test-*.sh) return 0 ;;
        */test-*.ps1|test-*.ps1|*.Tests.ps1) return 0 ;;
        */test_*.py|test_*.py) return 0 ;;
        *.test.mjs|*.test.js|*.test.cjs|*.test.ts) return 0 ;;
        */fixtures/*|*/test-fixtures/*) return 0 ;;
    esac
    return 1
}

scannable() {
    case "$1" in
        *.sh|*.mjs|*.js|*.cjs|*.ts|*.py|*.ps1) return 0 ;;
    esac
    return 1
}

# ---- shell detector (awk, one pass per file) ----
# Prints one line: R <first-unscrubbed-line|0> <exempt> <exempt-noreason>
#                    <sourced-lib> <sourced-lib-noreason>
read -r -d '' SH_AWK <<'AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Blanks quoted content and truncates at a word-start `#`; leaves "$NAME"
# unquoted so a quoted variable expansion stays visible. Sets rawcut to the
# raw text before the comment.
function strip(s,   out, n, i, c, prev, instr, cmdsub, saved, rest) {
  out = ""; instr = 0; cmdsub = 0; saved = 0; n = length(s); rawcut = s
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    prev = (i > 1) ? substr(s, i - 1, 1) : ""
    if (cmdsub == 0 && instr != 1 && c == "$" && substr(s, i + 1, 1) == "(") {
      saved = instr; instr = 0; cmdsub = 1; out = out "$("; i++; continue
    }
    if (cmdsub > 0) {
      if (c == "(") { cmdsub++; out = out c; continue }
      if (c == ")") { cmdsub--; out = out c; if (cmdsub == 0) instr = saved; continue }
    }
    if (instr == 0) {
      if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == "#" && (i == 1 || prev ~ /[ \t;&|(]/)) { rawcut = substr(s, 1, i - 1); break }
      else if (c == "\047") { instr = 1; out = out " " }
      else if (c == "\"") {
        rest = substr(s, i)
        if (match(rest, /^"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"/)) {
          out = out " " substr(rest, 2, RLENGTH - 2) " "; i += RLENGTH - 1; continue
        }
        instr = 2; out = out " "
      } else out = out c
    } else if (instr == 1) {
      if (c == "\047") instr = 0; else out = out " "
    } else {
      if (c == "\\") { i++; out = out "  " }
      else if (c == "\"") instr = 0
      else out = out " "
    }
  }
  return out
}

# Splits code on command separators into SEGS[]/TERMS[]; returns the count.
function split_segs(code,   n, i, c, cur, k) {
  n = length(code); cur = ""; k = 0
  for (i = 1; i <= n; i++) {
    c = substr(code, i, 1)
    if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "{" || c == "}" || c == "`") {
      if (trim(cur) != "" || c == ")") { k++; SEGS[k] = cur; TERMS[k] = c }
      cur = ""
    } else cur = cur c
  }
  if (trim(cur) != "") { k++; SEGS[k] = cur; TERMS[k] = "" }
  return k
}

function comment(t,   r) {
  if (match(t, /^#[ \t]*git-env-ok:/)) {
    r = trim(substr(t, RLENGTH + 1)); if (r != "") exempt = 1; else exempt_nr = 1
    return
  }
  if (match(t, /^#[ \t]*sourced-lib:/)) {
    r = trim(substr(t, RLENGTH + 1)); if (r != "") srclib = 1; else srclib_nr = 1
    return
  }
  if (t ~ /^#[ \t]*sourced-lib[ \t]*$/) srclib_nr = 1
}

function is_env_word(x,   nm) {
  if (x ~ /^(.*\/)?env$/) return 1
  if (x ~ /^\$/) { nm = x; gsub(/[${}]/, "", nm); return (nm in ISENV) }
  return 0
}

# Is the git invocation scrubbed at this point? SEGU = per-call -u names.
function scrubbed_now(   k, v) {
  if (helper_scrub || (infn != "" && (infn in FNHELP))) return 1
  for (k = 1; k <= nsv; k++) {
    v = SV[k]
    if (((GSET SUBSEP v) in SET) || (infn != "" && ((infn SUBSEP v) in SET)) || (v in SEGU)) continue
    return 0
  }
  return 1
}

function invoke(no) {
  if (!scrubbed_now()) { first = no; stop = 1 }
}

function seg(s, term, no,   w, nw, i, idx, x, cw, vn, k, tgt, probe, envseen) {
  s = trim(s)
  if (s == "") return
  nw = split(s, w, /[ \t]+/)
  if (nw == 1 && term == ")") return
  delete SEGU
  idx = 1; wrapped = 0; envseen = 0
  while (idx <= nw) {
    x = w[idx]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { idx++; continue }
    if (x ~ /^(!|then|do|else|elif|if|while|until|time|command|exec|builtin|nohup|nice|sudo|xargs|stdbuf|timeout)$/ || is_env_word(x)) { if (is_env_word(x)) envseen = 1; wrapped = 1; idx++; continue }
    if (wrapped && x ~ /^-/) { if (x == "-u" && envseen && idx < nw) SEGU[w[idx + 1]] = 1; if (x == "-u" || x == "-C" || x == "-S" || x == "-n") idx += 2; else idx++; continue }
    if (wrapped && x ~ /^[0-9.]+[smhd]?$/) { idx++; continue }
    break
  }
  cw = (idx <= nw) ? w[idx] : ""
  sub(/^\\/, "", cw)
  tgt = (infn == "") ? GSET : infn
  if (cw == "unset") {
    for (k = idx + 1; k <= nw; k++) if (w[k] in ISSV) SET[tgt, w[k]] = 1
    return
  }
  if (cw == "git_env_scrub") {
    if (helper_src) { if (infn == "") helper_scrub = 1; else FNHELP[infn] = 1 }
    return
  }
  if (cw != "" && (cw in FNDEF)) {
    for (k = 1; k <= nsv; k++) if (((cw SUBSEP SV[k]) in SET)) SET[tgt, SV[k]] = 1
    if ((cw in FNHELP) && helper_src) { if (infn == "") helper_scrub = 1; else FNHELP[infn] = 1 }
    return
  }
  isgit = 0
  if (cw == "git" || cw ~ /^(\/|~\/|\.\.?\/).*\/git$/ || cw ~ /^\/git$/) isgit = 1
  else if (cw ~ /^\$/) { vn = cw; gsub(/[${}]/, "", vn); if (vn in ISGIT) isgit = 1 }
  if (!isgit) {
    probe = " " s ((term == "") ? " " : "")
    if (probe ~ /[ \t\\]git[ \t]/) isgit = 1
  }
  if (isgit) invoke(no)
}

function process(line, no,   t, code, nseg, k, tmp, rhs, vname, pay, opens, closes, fname) {
  if (stop) return
  t = trim(line)
  if (t == "") return
  if (substr(t, 1, 1) == "#") { comment(t); return }
  if (pendfn != "") { if (t ~ /^\{/) { infn = pendfn; fndepth = depth } pendfn = "" }
  code = strip(line)
  if (rawcut ~ /(^|[;&|(]|then|do|else)[ \t]*(\.|source)[ \t]+[^;&|]*git-clean\.sh/) helper_src = 1
  if (match(rawcut, /^[ \t]*(local[ \t]+|export[ \t]+|readonly[ \t]+|declare[ \t]+(-[A-Za-z]+[ \t]+)?)?[A-Za-z_][A-Za-z0-9_]*=/)) {
    tmp = substr(rawcut, RSTART, RLENGTH); rhs = substr(rawcut, RSTART + RLENGTH)
    vname = tmp; sub(/=$/, "", vname); sub(/^.*[ \t]/, "", vname)
    if (rhs ~ /^["\047]?(git|\/[^ \t"\047]*\/git|\$\{[A-Za-z_0-9]+:-(\/[^}]*\/)?git\}|\$\([^)]*[ \t]git[ \t]*(\|\|[^)]*)?\))["\047]?([ \t;&|)]|$)/) ISGIT[vname] = 1
    if (rhs ~ /^["\047]?(env|\/[^ \t"\047]*\/env|\$\{[A-Za-z_0-9]+:-(\/[^}]*\/)?env\}|\$\([^)]*[ \t]env[ \t]*(\|\|[^)]*)?\))["\047]?([ \t;&|)]|$)/) ISENV[vname] = 1
  }
  # function definition?
  fname = ""
  if (match(code, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_.:-]*[ \t]*\(\)/) || match(code, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_.:-]*/)) {
    tmp = substr(code, RSTART, RLENGTH)
    sub(/^[ \t]*function[ \t]+/, "", tmp); sub(/[ \t]*\(\).*$/, "", tmp); sub(/^[ \t]+/, "", tmp)
    fname = tmp
    FNDEF[fname] = 1
    if (substr(code, RSTART + RLENGTH) ~ /\{/) { infn = fname; fndepth = depth }
    else pendfn = fname
  }
  # bash -c '<payload>' / eval <payload>: scan the raw payload for a git word
  pay = ""
  if (match(rawcut, /(^|[;&|( \t`])(bash|sh|zsh|dash|ksh)[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+/)) pay = substr(rawcut, RSTART + RLENGTH)
  else if (match(rawcut, /(^|[;&|( \t`])eval[ \t]+/)) pay = substr(rawcut, RSTART + RLENGTH)
  if (pay != "" && (" " pay " ") ~ /[;&|( \t`"\047\\]git[ \t"\047;)|&]/) {
    delete SEGU
    tmp = rawcut
    while (match(tmp, /-u[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      vname = substr(tmp, RSTART, RLENGTH); sub(/^-u[ \t]+/, "", vname); SEGU[vname] = 1
      tmp = substr(tmp, RSTART + RLENGTH)
    }
    invoke(no)
    if (stop) return
  }
  nseg = split_segs(code)
  for (k = 1; k <= nseg && !stop; k++) seg(SEGS[k], TERMS[k], no)
  tmp = code; gsub(/\$\{[^}]*\}/, "X", tmp)
  opens = gsub(/\{/, "{", tmp); closes = gsub(/\}/, "}", tmp)
  depth += opens - closes
  if (infn != "" && depth <= fndepth) infn = ""
}

BEGIN {
  nsv = split(scrub, SV, " ")
  for (i = 1; i <= nsv; i++) ISSV[SV[i]] = 1
  GSET = "@g"; first = 0; stop = 0; depth = 0; infn = ""; pendfn = ""
  pend = ""; pendno = 0; helper_src = 0; helper_scrub = 0
  exempt = 0; exempt_nr = 0; srclib = 0; srclib_nr = 0
}
{
  if (pend == "") pendno = NR
  physical = $0
  line = pend physical
  pend = ""
  tt = physical; sub(/^[ \t]+/, "", tt)
  if (substr(tt, 1, 1) != "#" && physical ~ /\\$/) {
    m = physical; nb = 0
    while (substr(m, length(m), 1) == "\\") { nb++; m = substr(m, 1, length(m) - 1) }
    if (nb % 2 == 1) { pend = substr(line, 1, length(line) - 1) " "; next }
  }
  process(line, pendno)
}
END {
  if (pend != "") process(pend, pendno)
  print "R " first " " exempt " " exempt_nr " " srclib " " srclib_nr
}
AWK

# ---- JS detector (awk: tokenizer + per-call span) ----
# Prints `H <line> <kind>` (kind = unscrubbed | noreason), one per hit line.
read -r -d '' JS_AWK <<'AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function addtok(type, val, ln, own) { nt++; TT[nt] = type; TV[nt] = val; TL[nt] = ln; TOWN[nt] = own }

function tokenize(   ln, s, n, i, c, top, j, d, p, sub1, seen, two, prevt, prevv, kw) {
  tsp = 0; incom = 0
  for (ln = 1; ln <= NR; ln++) {
    s = LINES[ln]; n = length(s); i = 1; seen = 0
    if (incom) {
      p = index(s, "*/")
      if (p == 0) continue
      i = p + 2; incom = 0
    }
    while (i <= n) {
      c = substr(s, i, 1)
      # Template text is buffered into a T token per chunk; a `${...}`
      # substitution is ordinary code, so a call inside it is tokenized (and
      # detected) like any other.
      if (tsp > 0 && TSTK[tsp] == "T") {
        if (c == "\\") { TBUF[tsp] = TBUF[tsp] substr(s, i, 2); i += 2; continue }
        if (c == "`") {
          addtok("T", TBUF[tsp], TLN[tsp], 0); tsp--; seen = 1
          i++; continue
        }
        if (c == "$" && substr(s, i + 1, 1) == "{") {
          addtok("T", TBUF[tsp], TLN[tsp], 0)
          tsp++; TSTK[tsp] = "E"; TBR[tsp] = 0
          i += 2; continue
        }
        TBUF[tsp] = TBUF[tsp] c; i++; continue
      }
      if (tsp > 0 && TSTK[tsp] == "E") {
        if (c == "{") TBR[tsp]++
        else if (c == "}") {
          if (TBR[tsp] == 0) { tsp--; TBUF[tsp] = ""; TLN[tsp] = ln; i++; continue }
          TBR[tsp]--
        }
      }
      if (c == " " || c == "\t") { i++; continue }
      two = substr(s, i, 2)
      if (two == "//") { addtok("C", substr(s, i), ln, !seen); break }
      if (two == "/*") {
        p = index(substr(s, i + 2), "*/")
        if (p == 0) { incom = 1; break }
        i = i + p + 3; continue
      }
      if (c == "\047" || c == "\"") {
        j = i + 1
        while (j <= n) { d = substr(s, j, 1); if (d == "\\") j += 2; else if (d == c) break; else j++ }
        addtok("S", substr(s, i + 1, j - i - 1), ln, 0); seen = 1; i = j + 1; continue
      }
      if (c == "`") { tsp++; TSTK[tsp] = "T"; TBUF[tsp] = ""; TLN[tsp] = ln; i++; continue }
      if (c ~ /[A-Za-z_$]/) {
        j = i
        while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_$]/) j++
        addtok("I", substr(s, i, j - i), ln, 0); seen = 1; i = j; continue
      }
      if (c ~ /[0-9]/) {
        j = i
        while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_.]/) j++
        addtok("N", substr(s, i, j - i), ln, 0); seen = 1; i = j; continue
      }
      if (c == "/") {
        prevt = (nt > 0) ? TT[nt] : ""; prevv = (nt > 0) ? TV[nt] : ""
        kw = (prevt == "I" && prevv ~ /^(return|typeof|case|in|of|delete|void|throw|new|else|do|yield|await)$/)
        if (!kw && (prevt == "I" || prevt == "N" || prevt == "S" || prevt == "T" || (prevt == "P" && (prevv == ")" || prevv == "]" || prevv == "}")))) {
          addtok("P", c, ln, 0); seen = 1; i++; continue
        }
        j = i + 1; d = 0
        while (j <= n) {
          p = substr(s, j, 1)
          if (p == "\\") { j += 2; continue }
          if (p == "[") d = 1
          else if (p == "]") d = 0
          else if (p == "/" && d == 0) break
          j++
        }
        addtok("R", "", ln, 0); seen = 1; i = j + 1; continue
      }
      addtok("P", c, ln, 0); seen = 1; i++
    }
    if (tsp > 0 && TSTK[tsp] == "T") TBUF[tsp] = TBUF[tsp] "\n"
  }
}

function detect(   k, a, cand, open, callee, m, m2, depthp, nfound, v, ok, ln, kind, r) {
  for (k = 1; k + 3 <= nt; k++) {
    if (TT[k] == "I" && TV[k] ~ /^(const|let|var)$/ && TT[k + 1] == "I" && TT[k + 2] == "P" && TV[k + 2] == "=" && TT[k + 3] == "S" && TV[k + 3] ~ /^git([ \t]|$)/) GITC[TV[k + 1]] = 1
  }
  for (k = 1; k <= nt; k++) if (TT[k] == "C") COM[TL[k]] = TV[k]
  # Drop the comment tokens so one sitting between `(` and the first
  # argument cannot hide the call.
  m2 = 0
  for (k = 1; k <= nt; k++) {
    if (TT[k] == "C") continue
    m2++; TT[m2] = TT[k]; TV[m2] = TV[k]; TL[m2] = TL[k]; TOWN[m2] = TOWN[k]
  }
  for (k = m2 + 1; k <= nt; k++) { delete TT[k]; delete TV[k]; delete TL[k]; delete TOWN[k] }
  nt = m2
  for (k = 1; k <= nt; k++) {
    if (TT[k] != "I") continue
    callee = TV[k]; cand = 0; open = 0
    if (TT[k + 1] == "P" && TV[k + 1] == "(") {
      a = k + 2
      if ((TT[a] == "S" || TT[a] == "T") && TV[a] ~ /^git([ \t]|$)/) cand = 1
      else if (TT[a] == "I" && (TV[a] in GITC)) cand = 1
      open = k + 1
    } else if (TT[k + 1] == "T" && TV[k + 1] ~ /^git([ \t]|$)/) cand = 1
    if (!cand) continue
    if (callee ~ /^(if|while|switch|for|return|typeof|catch|function|includes|has|log|info|warn|error|debug|print|echo|console|equal|strictEqual|deepEqual|notEqual|notStrictEqual|ok|assert|push|add|indexOf|lastIndexOf|startsWith|endsWith|test|match|join|resolve|basename|dirname|toBe|toEqual|eq|set|get|delete|describe|it|require|String|some|every|filter|split|replace|format|which|exists|expect|Error|TypeError|RangeError|SyntaxError)$/) continue
    if (callee ~ /^(is[A-Z_]|can[A-Z]|check|find[A-Z]|has[A-Z]|command[A-Z]|assert|expect|which|exists|ensure)/) continue
    ln = TL[k]
    # scrub inside the call's own paren-balanced span
    delete FOUND; nfound = 0
    if (open > 0) {
      depthp = 0
      for (m = open; m <= nt; m++) {
        if (TT[m] == "P" && TV[m] == "(") depthp++
        else if (TT[m] == "P" && TV[m] == ")") { depthp--; if (depthp == 0) break }
        v = TV[m]
        if (TT[m] == "I" && (v in ISSV)) FOUND[v] = 1
        else if (TT[m] == "S" && (v in ISSV)) {
          ok = 0
          if (TT[m + 1] == "P" && TV[m + 1] == ":") ok = 1
          if (m >= 2 && TT[m - 1] == "P" && TV[m - 1] == "[" && (TT[m - 2] == "I" || (TT[m - 2] == "P" && (TV[m - 2] == "]" || TV[m - 2] == ")")))) ok = 1
          if (ok) FOUND[v] = 1
        }
      }
      for (v in FOUND) nfound++
    }
    if (nfound >= nsv) continue
    # real trailing comment marker on the call's line
    kind = "unscrubbed"
    r = ""
    if ((ln in COM) && match(COM[ln], /^\/\/[ \t]*git-env-ok:/)) {
      r = trim(substr(COM[ln], RLENGTH + 1))
      if (r != "") continue
      kind = "noreason"
    }
    print "H " ln " " kind
  }
}

BEGIN { nsv = split(scrub, SV, " "); for (i = 1; i <= nsv; i++) ISSV[SV[i]] = 1; nt = 0 }
{ LINES[NR] = $0 }
END { tokenize(); detect() }
AWK

# ---- py / ps1 detector (awk, file-level) ----
# Prints `R <first|0> <exempt> <exempt-noreason>`.
read -r -d '' FL_AWK <<'AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function has_name(code, nm,   re) {
  re = "(^|[^A-Za-z0-9_])" nm "([^A-Za-z0-9_]|$)"
  return (code ~ re)
}
BEGIN { nsv = split(scrub, SV, " "); first = 0; exempt = 0; exempt_nr = 0; blockc = 0 }
{
  t = trim($0)
  if (first) next
  if (lang == "ps1") {
    if (blockc) { if (t ~ /#>/) blockc = 0; next }
    if (t ~ /^<#/) { if (t !~ /#>/) blockc = 1; next }
  }
  if (t == "") next
  if (t ~ /^#/) {
    if (match(t, /^#[ \t]*git-env-ok:/)) {
      r = trim(substr(t, RLENGTH + 1)); if (r != "") exempt = 1; else exempt_nr = 1
    }
    next
  }
  code = $0
  p = match(code, /[ \t]#/)
  if (p > 0) code = substr(code, 1, p - 1)
  for (k = 1; k <= nsv; k++) if (has_name(code, SV[k])) SEEN[SV[k]] = 1
  gc = 0
  if (lang == "py") { if (code ~ /["\047]git(["\047]|[ \t])/) gc = 1 }
  else { if ((" " code " ") ~ /[ \t;|({&]git[ \t]/) gc = 1 }
  if (gc) {
    all = 1
    for (k = 1; k <= nsv; k++) if (!(SV[k] in SEEN)) { all = 0; break }
    if (!all) first = NR
  }
}
END { print "R " first " " exempt " " exempt_nr " 0 0" }
AWK

# HITS accumulates human-readable "file[:line]: message" for the report.
# BASELINE_KEYS accumulates the matching machine keys, in the same order.
HITS=()
BASELINE_KEYS=()
# USED_BASELINE: baseline keys that grandfathered a real hit this run — what
# is left over in the baseline is stale.
USED_BASELINE=()
FULL_SCAN=0

# File-level result handling shared by shell and py/ps1.
# $1 file, $2 awk R line, $3 key prefix, $4 has_shebang (shell only), $5 hint
file_level_verdict() {
    local f="$1" res="$2" prefix="$3" has_shebang="$4" first exempt exempt_nr srclib srclib_nr _r
    read -r _r first exempt exempt_nr srclib srclib_nr <<<"$res"
    [ "${first:-0}" -eq 0 ] && return 0
    [ "$exempt" -eq 1 ] && return 0
    if [ "$has_shebang" -eq 0 ] && [ "$srclib" -eq 1 ] && [ "$prefix" = SHELL ]; then
        return 0
    fi
    local key="$prefix:$f"
    if [ "$EMIT_BASELINE" -ne 1 ] && baseline_has "$key"; then
        USED_BASELINE+=("$key")
        return 0
    fi
    if [ "$exempt_nr" -eq 1 ]; then
        HITS+=("$f:$first: git-env-ok marker with no reason")
    elif [ "$srclib_nr" -eq 1 ] && [ "$has_shebang" -eq 0 ]; then
        HITS+=("$f:$first: sourced-lib marker with no reason, and no GIT_* env scrub before first git invocation")
    elif [ "$has_shebang" -eq 0 ] && [ "$prefix" = SHELL ]; then
        HITS+=("$f:$first: no GIT_* env scrub before first git invocation (shebang-less — mark '# sourced-lib: <reason>' if this file is only ever sourced)")
    else
        HITS+=("$f:$first: no GIT_* env scrub before first git invocation")
    fi
    BASELINE_KEYS+=("$key")
}

scan_shell_file() {
    local f="$1" src="$2"
    is_excluded_path "$f" && return 0
    local first_line has_shebang=0 res
    IFS= read -r first_line < "$src" || first_line=""
    case "$first_line" in '#!'*) has_shebang=1 ;; esac
    res=$(LC_ALL=C awk -v scrub="$SCRUB_VARS" "$SH_AWK" "$src")
    file_level_verdict "$f" "$res" SHELL "$has_shebang"
}

scan_filelevel_file() {
    local f="$1" src="$2" lang="$3" res
    is_excluded_path "$f" && return 0
    res=$(LC_ALL=C awk -v scrub="$SCRUB_VARS" -v lang="$lang" "$FL_AWK" "$src")
    file_level_verdict "$f" "$res" FILE 1
}

scan_js_file() {
    local f="$1" content="$2" hits h lineno kind line trimmed hash
    is_excluded_path "$f" && return 0
    hits=$(LC_ALL=C awk -v scrub="$SCRUB_VARS" "$JS_AWK" "$content")
    [ -n "$hits" ] || return 0

    local -a remaining=()
    if [ "$EMIT_BASELINE" -ne 1 ] && [ "${#BASE_ENTRIES[@]}" -gt 0 ]; then
        local e
        for e in "${BASE_ENTRIES[@]}"; do
            case "$e" in
                "JS:$f:"*) remaining+=("${e#JS:"$f":}") ;;
            esac
        done
    fi

    while IFS= read -r h; do
        [ -n "$h" ] || continue
        lineno=$(printf '%s' "$h" | cut -d' ' -f2)
        kind=$(printf '%s' "$h" | cut -d' ' -f3)
        line=$(sed -n "${lineno}p" "$content")
        trimmed=$(trim "$line")
        if [ "$kind" = noreason ]; then
            HITS+=("$f:$lineno: git-env-ok marker with no reason")
            continue
        fi
        hash=$(line_hash "$trimmed")
        local consumed=0 idx
        if [ "${#remaining[@]}" -gt 0 ]; then
            for idx in "${!remaining[@]}"; do
                if [ "${remaining[$idx]}" = "$hash" ]; then
                    unset 'remaining[idx]'
                    USED_BASELINE+=("JS:$f:$hash")
                    consumed=1
                    break
                fi
            done
        fi
        [ "$consumed" -eq 1 ] && continue
        HITS+=("$f:$lineno: unscrubbed JS git subprocess call")
        BASELINE_KEYS+=("JS:$f:$hash")
    done <<<"$hits"
}

is_trust_path() {
    local m
    m=$(printf '%s' "$1" | grep -E '^scripts/handover/|^scripts/lanes/|^scripts/hooks/|^scripts/cr/|^scripts/lib/go-gate\.sh$') || true
    [ -n "$m" ]
}

scan_one() {
    local f="$1" src="$2"
    case "$f" in
        *.sh) scan_shell_file "$f" "$src" ;;
        *.mjs|*.js|*.cjs|*.ts) scan_js_file "$f" "$src" ;;
        *.py) scan_filelevel_file "$f" "$src" py ;;
        *.ps1) scan_filelevel_file "$f" "$src" ps1 ;;
    esac
}

if [ "$MODE" = staged ]; then
    tmp_list=$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-list.XXXXXX") || exit 2
    trap 'rm -f "$tmp_list"' EXIT
    # ACMR, not ACM: a rename INTO a trust path must be scanned too.
    git diff --cached --name-only --diff-filter=ACMR > "$tmp_list"
    while IFS= read -r f || [ -n "$f" ]; do
        [ -z "$f" ] && continue
        is_trust_path "$f" || continue
        scannable "$f" || continue
        tmp_blob=$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-blob.XXXXXX") || exit 2
        if git show ":$f" > "$tmp_blob" 2>/dev/null; then
            scan_one "$f" "$tmp_blob"
        fi
        rm -f "$tmp_blob"
    done < "$tmp_list"
else
    if [ "$FILES_MODE" -eq 1 ]; then
        for p in ${TREE_PATHS[@]+"${TREE_PATHS[@]}"}; do
            scannable "$p" || continue
            is_trust_path "$p" || continue
            if [ ! -f "$p" ]; then
                echo "check-git-env-scrub: --files path does not exist: $p" >&2
                exit 2
            fi
            scan_one "$p" "$p"
        done
    elif [ "${#TREE_PATHS[@]}" -gt 0 ]; then
        for p in "${TREE_PATHS[@]}"; do
            if [ -f "$p" ]; then
                scannable "$p" && scan_one "$p" "$p"
            elif [ -d "$p" ]; then
                while IFS= read -r f; do
                    scan_one "$f" "$f"
                done < <(find "$p" -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.cjs' -o -name '*.ts' -o -name '*.py' -o -name '*.ps1' \) | sort)
            else
                # A renamed/moved fixture must FAIL loud, not silently scan
                # nothing and report clean.
                echo "check-git-env-scrub: --tree path does not exist: $p" >&2
                exit 2
            fi
        done
    else
        # Captured with its own exit status, and floored at >0 files so an
        # empty listing can never read as "clean".
        tree_list=$(git ls-files 'scripts/handover' 'scripts/lanes' 'scripts/hooks' 'scripts/cr' 'scripts/lib/go-gate.sh') || {
            echo "check-git-env-scrub: git ls-files failed while listing trust paths" >&2
            exit 2
        }
        FULL_SCAN=1
        scanned=0
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            scannable "$f" || continue
            is_trust_path "$f" || continue
            scanned=$((scanned + 1))
            scan_one "$f" "$f"
        done <<<"$tree_list"
        if [ "$scanned" -eq 0 ]; then
            echo "check-git-env-scrub: 0 trust-path files scanned — refusing to report clean" >&2
            exit 2
        fi
    fi
fi

if [ "$EMIT_BASELINE" -eq 1 ]; then
    if [ "${#BASELINE_KEYS[@]}" -gt 0 ]; then
        printf '%s\n' "${BASELINE_KEYS[@]}" | sort
    fi
    exit 0
fi

# Stale baseline entries: in the full real-tree scan (and, for the files it
# names, --files) an entry that grandfathered no hit is dead. USED_BASELINE has multiplicity.
STALE=()
if { [ "$FULL_SCAN" -eq 1 ] || [ "$FILES_MODE" -eq 1 ]; } && [ "${#BASE_ENTRIES[@]}" -gt 0 ]; then
    declare -a stale_pool=()
    if [ "${#USED_BASELINE[@]}" -gt 0 ]; then
        for u in "${USED_BASELINE[@]}"; do stale_pool+=("$u"); done
    fi
    for bline in "${BASE_ENTRIES[@]}"; do
        if [ "$FILES_MODE" -eq 1 ]; then
            # --files sees only the named files: judge an entry only when its
            # file was named or no longer exists on disk (deleted or renamed).
            bpath="${bline#*:}"
            case "$bline" in JS:*) bpath="${bpath%:*}" ;; esac
            relevant=0
            [ -e "$bpath" ] || relevant=1
            for p in ${TREE_PATHS[@]+"${TREE_PATHS[@]}"}; do
                [ "$p" = "$bpath" ] && relevant=1
            done
            [ "$relevant" -eq 1 ] || continue
        fi
        found=-1
        for idx in "${!stale_pool[@]}"; do
            if [ "${stale_pool[$idx]}" = "$bline" ]; then found=$idx; break; fi
        done
        if [ "$found" -ge 0 ]; then
            unset 'stale_pool[found]'
        else
            STALE+=("$bline")
        fi
    done
fi
if [ "${#STALE[@]}" -gt 0 ]; then
    echo "check-git-env-scrub: ${#STALE[@]} stale baseline entr(y/ies) in $BASELINE_FILE (no matching hit any more):" >&2
    for s in "${STALE[@]}"; do
        echo "  $s" >&2
    done
    echo "Remove them, or regenerate with: $0 --emit-baseline > scripts/guardrails/git-env-baseline.txt" >&2
    [ "${#HITS[@]}" -gt 0 ] || exit 1
fi

if [ "${#HITS[@]}" -gt 0 ]; then
    echo "check-git-env-scrub: ${#HITS[@]} unscrubbed trust-path git finding(s):" >&2
    for h in "${HITS[@]}"; do
        echo "  $h" >&2
    done
    echo "" >&2
    echo "Shell: unset the full GIT_* set (see scripts/lib/git-clean.sh), or source it" >&2
    echo "and call git_env_scrub, before the file's first git invocation, or mark the" >&2
    echo "file '# git-env-ok: <reason>'." >&2
    echo "JS: route the call through gitClean() in scripts/lanes/git-clean.mjs, drop" >&2
    echo "every name in the call's env, or mark the line '// git-env-ok: <reason>'." >&2
    exit 1
fi

echo "check-git-env-scrub: clean"
exit 0
