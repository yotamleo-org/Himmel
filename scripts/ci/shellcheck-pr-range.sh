#!/usr/bin/env bash
# pr-range lint -- the PR-path lint for CI's lint job.
#
# `pre-commit run shellcheck --all-files` is one serial ~9 min shellcheck (the
# hook is require_serial) and cannot be sharded: shellcheck resolves `source`
# across the files of ONE invocation, so SC2034 "unused" verdicts depend on the
# input set. So a PR lints the files it changed PLUS their source-graph
# neighbours — files that source/`.` a changed (or deleted) file, and files a
# changed file sources — through the SAME hook (its `types` and `exclude` still
# apply to --files). "Changed" is the PR's own diff against its merge base, and the
# selected set is binned by forward source closure and linted in parallel
# (sweep_all), with selection and lint timings printed.
#
# Fail-safe direction: when in doubt, lint everything (--all-files) if
#   - the diff cannot be computed or a neighbour lookup errors,
#   - a changed shell file has a variable-glued source name ("${D}x.sh") or a source line naming
#     a tracked shell file without a .sh/.bash name (dynamic, uncertain); a changed non-shell
#     file is not scanned for forward edges, and a line naming no .sh/.bash adds no edge,
#   - .pre-commit-config.yaml, a .shellcheckrc/shellcheckrc at ANY depth (the nearest
#     rc shadows the root one for untouched files), the CI workflow or this script changed,
#   - a changed path contains a newline anywhere, or a neighbour path needs quoting.
# Renames are split into delete+add (--no-renames) so the old path's consumers are
# found, a directory a rename left also selects the files naming it, and
# `# shellcheck source=` directive edges count as source edges.
#
# Usage: shellcheck-pr-range.sh [--dry-run] <base-sha>
#    or: shellcheck-pr-range.sh --sweep <list-file>
#   --dry-run prints "ALL <reason>" or "FILES" + the file list, runs nothing.
#   --sweep bins and lints exactly the newline-separated paths in <list-file>, with no selection
#   (scripts/ci/shellcheck-sweep-parity.sh compares it with one serial run).
set -u

dry=0
sweepfile=""
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
if [ "${1:-}" = "--sweep" ]; then sweepfile="${2:?usage: shellcheck-pr-range.sh --sweep <list-file>}"; set -- sweep; fi
base="${1:?usage: shellcheck-pr-range.sh [--dry-run] <base-sha>}"

src_re='(^|[;&|{(![:space:]])(source|\.)[[:space:]]'
dir_re='shellcheck[[:space:]].*source='

run_all() {
  echo "shellcheck-pr-range: ALL FILES ($1)" >&2
  if [ "$dry" = 1 ]; then echo "ALL $1"; exit 0; fi
  sweep_all
}

# The full sweep, binned by forward source closure and run in parallel. One serial
# `--all-files` is ~8 min unloaded and overran the lint job's cap on a loaded runner.
# A file's lint verdict depends on the files it sources (an unused-variable or unreachable-
# function finding needs the sourced file beside it) and never on the files that source it,
# so a bin holds each of its root files together with that root's whole directed closure: every
# file it sources, transitively, over the source/`.`/`# shellcheck source=` edges. A name is
# resolved with a leading `$VAR/` or `${VAR}/` stripped (shellcheck does the same), then by path
# suffix, else same directory, else basename. An over-wide edge only duplicates a file into one
# more bin. Every file is the root of exactly one bin; a lib in the closure of roots in several
# bins is an input of each of them. Roots are packed largest closure first onto the nproc bins,
# each going where it adds the least load (bytes of files the bin does not hold yet), then one
# `pre-commit --files` runs per bin. A file identify does not type shell (the library the hook's
# `types: [shell]` uses) is a root with no edges and no weight: it goes in its bin's fill list, behind
# the shell inputs. The findings of all bins are
# printed once each; the exit status is non-zero if any bin fails. Anything unplannable -> serial.
# `sweep_all <files>` bins just that newline-separated list (the PR's selected set, already
# closed under its source neighbours); with no argument it bins the whole tree.
subset=""
serial_sweep() {
  if [ -n "$subset" ]; then
    set -o pipefail
    printf '%s\n' "$subset" | tr '\n' '\0' | xargs -0 pre-commit run shellcheck --show-diff-on-failure --files
    exit $?
  fi
  exec pre-commit run shellcheck --all-files --show-diff-on-failure
}
# The planned files the hook types shell, one path per line on stdout. Asking identify (the library
# pre-commit types files with) rather than matching a name keeps the two in step: it types an
# executable dotfile by its shebang and a PKGBUILD.md by its PKGBUILD part. The interpreter is
# $SHELLCHECK_RANGE_PY when set, else pre-commit's own, else python3: the first that can import
# identify. A failure returns non-zero, and the caller then treats every file as shell.
shell_typed() {
  local py pc sb a b cands=""
  local prog='import os, sys
try:
    from identify import identify
except Exception:
    sys.exit(3)
out = sys.stdout.buffer
for raw in sys.stdin.buffer.read().split(b"\n"):
    if not raw:
        continue
    try:
        shell = "shell" in identify.tags_from_path(os.fsdecode(raw))
    except Exception:
        shell = True
    if shell:
        out.write(raw + b"\n")'
  if [ -n "${SHELLCHECK_RANGE_PY+x}" ]; then
    cands=$SHELLCHECK_RANGE_PY
  else
    if pc=$(command -v pre-commit) && sb=$(head -n 1 "$pc" 2> /dev/null); then
      sb=${sb#\#!}
      read -r a b <<< "$sb"
      case "${a##*/}" in env) a=$(command -v "$b") || a="" ;; esac # swallow-ok: no resolvable interpreter, the next candidate is tried
      cands=$a
    fi
    cands="$cands
python3"
  fi
  while IFS= read -r py; do
    [ -n "$py" ] || continue
    "$py" -I -c "$prog" < "$1" 2> /dev/null && return 0 # read-sink-ok: $1 is the sweep's own plan list in its mktemp dir, never a caller path
  done <<EOF
$cands
EOF
  return 1
}
stage_t() {
  echo "shellcheck-pr-range: stage $1 took $((SECONDS - t_stage))s" >&2
  t_stage=$SECONDS
}
sweep_plan() {
  local plan
  # macOS has no nproc; sysctl hw.ncpu is its CPU count
  n=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null) || n=1 # swallow-ok: no CPU count means no parallelism, the serial sweep runs
  [ "${n:-1}" -gt 1 ] 2>/dev/null || serial_sweep
  # Four bins peak near 16 GiB of resident memory on the whole tree, past a 16 GB hosted runner, which kills the sweep.
  if [ "$n" -gt 2 ]; then n=2; fi
  # prim-ok: ci.yml runs a BASE-commit copy extracted to RUNNER_TEMP with no scripts/lib, so it cannot source prim.sh
  sd=$(mktemp -d "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") || serial_sweep
  if [ -n "$subset" ]; then plan=$subset; else plan=$(git ls-files) || serial_sweep; fi
  case "$plan" in '"'* | *'
"'*) rm -rf "$sd"; serial_sweep ;; esac
  printf '%s\n' "$plan" > "$sd/files" || { rm -rf "$sd"; serial_sweep; }
  printf '%s\n' "$plan" | tr '\n' '\0' | xargs -0 wc -c -- > "$sd/sizes" 2>/dev/null || : # swallow-ok: a missing size only flattens the weights
  # no classification, or an empty one, means every file is shell: it keeps its edges and weight, which can
  # only widen a bin (and the size guard below then falls back to the serial sweep)
  { shell_typed "$sd/files" > "$sd/shell" && [ -s "$sd/shell" ]; } || cp "$sd/files" "$sd/shell" || { rm -rf "$sd"; serial_sweep; }
  git grep -n -I -E -e "$src_re" -e "$dir_re" -- . > "$sd/grep" 2>/dev/null || [ "$?" -eq 1 ] || { rm -rf "$sd"; serial_sweep; }
  stage_t sweep_plan
}
sweep_pack() {
  # stage 1: one line per file, "<closure weight> <root> <member> <weight> ...", the root first, weight -1 for a
  # file identify does not type shell. Stage 2 packs the roots; it writes bin.K (the shell inputs, a root's lib
  # before the roots), fill.K (non-shell roots) and roots.K (every root of the bin).
  awk '
    function edge(a, b) { if (a != b && !((a SUBSEP b) in ed)) { ed[a, b] = 1; adj[a] = adj[a] b "\n" } }
    function wgt(x) { return ((x in wt) ? wt[x] : 0) + 1 }
    FILENAME == ARGV[1] { n++; f[n] = $0; isf[$0] = 1; k = split($0, q, "/"); byname[q[k]] = byname[q[k]] "\n" $0; next }
    FILENAME == ARGV[2] { sh[$0] = 1; next }
    FILENAME == ARGV[3] { s = $0; sub(/^[ \t]+/, "", s); v = s + 0; sub(/^[0-9]+ /, "", s); wt[s] = v; next }
    {
      i = index($0, ":"); file = substr($0, 1, i - 1); rest = substr($0, i + 1); sub(/^[0-9]+:/, "", rest)
      if (!(file in isf) || !(file in sh)) next
      if (rest ~ /^[[:space:]]*#/ && rest !~ /shellcheck[[:space:]]+source=/) next
      d = file; sub(/[^\/]*$/, "", d)
      while (match(rest, /[A-Za-z0-9_.\/+-]*[A-Za-z0-9_+-]\.(sh|bash)/)) {
        nm = substr(rest, RSTART, RLENGTH); pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
        rest = substr(rest, RSTART + RLENGTH)
        if (pre == "$") sub(/^[A-Za-z_][A-Za-z0-9_]*\//, "", nm)
        sub(/^(\.\.?\/)+/, "", nm); sub(/^\/+/, "", nm)
        k = split(nm, q, "/"); base = q[k]
        if (k == 1 && ((d base) in isf)) { edge(file, d base); continue }
        m = split(byname[base], c, "\n")
        for (j = 1; j <= m; j++) if (c[j] != "" && (k == 1 || c[j] == nm || substr(c[j], length(c[j]) - length(nm)) == "/" nm)) edge(file, c[j])
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        r = f[i]
        if (!(r in sh)) { printf "-1\t%s\n", r; continue }
        sp = 0; cnt = 0; stack[++sp] = r; vis[r] = i
        while (sp > 0) {
          x = stack[sp--]; mem[++cnt] = x
          m = split(adj[x], t, "\n")
          for (j = 1; j <= m; j++) if (t[j] != "" && vis[t[j]] != i) { vis[t[j]] = i; stack[++sp] = t[j] }
        }
        tot = 0; line = ""
        for (j = 1; j <= cnt; j++) { tot += wgt(mem[j]); line = line "\t" mem[j] "\t" wgt(mem[j]) }
        printf "%d\t%s%s\n", tot, r, line
      }
    }' "$sd/files" "$sd/shell" "$sd/sizes" "$sd/grep" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | awk -F '\t' -v P="$n" -v sd="$sd" '
    $1 < 0 { b = nf++ % P + 1; nfill[b]++; fill[b, nfill[b]] = $2; nroot[b]++; roots[b, nroot[b]] = $2; used[b] = 1; next }
    {
      best = 0
      for (b = 1; b <= P; b++) {
        add = 0
        for (j = 3; j < NF; j += 2) if (!((b, $j) in inb)) add += $(j + 1)
        if (best == 0 || load[b] + add < bl) { best = b; bl = load[b] + add }
      }
      b = best; used[b] = 1; load[b] = bl
      for (j = 3; j < NF; j += 2) if (!((b, $j) in inb)) { inb[b, $j] = 1; nlib[b]++; lib[b, nlib[b]] = $j }
      isroot[b, $2] = 1; nroot[b]++; roots[b, nroot[b]] = $2
    }
    END {
      for (b = 1; b <= P; b++) {
        if (!used[b]) continue
        printf "" > (sd "/bin." b)
        for (j = 1; j <= nlib[b]; j++) if (!((b, lib[b, j]) in isroot)) print lib[b, j] >> (sd "/bin." b)
        for (j = 1; j <= nroot[b]; j++) {
          print roots[b, j] > (sd "/roots." b)
          if (!((b, roots[b, j]) in inb)) continue
          print roots[b, j] >> (sd "/bin." b)
        }
        for (j = 1; j <= nfill[b]; j++) print fill[b, j] >> (sd "/fill." b)
        close(sd "/bin." b); close(sd "/roots." b); close(sd "/fill." b)
      }
    }' || { rm -rf "$sd"; serial_sweep; }
  stage_t sweep_pack
}
sweep_verify() {
  local i k nb
  set -- "$sd"/bin.*
  [ -f "$1" ] || { rm -rf "$sd"; serial_sweep; }
  nb=$#
  # every selected file must be the root of exactly one bin, and sit in that bin, else a pass would be vacuous
  sort "$sd/files" > "$sd/files.s"
  cat "$sd"/roots.* | sort > "$sd/rootsall.s"
  cmp -s "$sd/files.s" "$sd/rootsall.s" || { rm -rf "$sd"; serial_sweep; }
  for i in "$sd"/bin.*; do
    k=${i##*/bin.}
    { cat "$i"; [ ! -f "$sd/fill.$k" ] || cat "$sd/fill.$k"; } | sort -u > "$sd/held.s"
    sort "$sd/roots.$k" > "$sd/root.s"
    [ -z "$(comm -13 "$sd/held.s" "$sd/root.s")" ] || { rm -rf "$sd"; serial_sweep; }
  done
  echo "shellcheck-pr-range: parallel full sweep over $nb bins ($(cat "$sd"/bin.* | wc -l | tr -d ' ') shell inputs for $(wc -l < "$sd/files" | tr -d ' ') files)" >&2
  # SHELLCHECK_RANGE_KEEP_PLAN=<dir> keeps the bin, fill and root lists for a test to read
  if [ -n "${SHELLCHECK_RANGE_KEEP_PLAN:-}" ]; then
    mkdir -p "$SHELLCHECK_RANGE_KEEP_PLAN" || exit 1
    for i in "$sd"/bin.* "$sd"/fill.* "$sd"/roots.*; do
      if [ -f "$i" ]; then cp "$i" "$SHELLCHECK_RANGE_KEEP_PLAN/" || exit 1; fi
    done
  fi
  # xargs splits past ~128 KB of arguments, which would cut a bin across runs; the fill list
  # comes last, so only non-shell files can fall in a later run
  for i in "$sd"/bin.*; do
    [ "$(wc -c < "$i")" -le 100000 ] || { rm -rf "$sd"; serial_sweep; }
  done
  stage_t sweep_verify
}
sweep_lint() {
  local i k r
  for i in "$sd"/bin.*; do
    k=${i##*/bin.}
    ( set -o pipefail; { cat "$i"; [ ! -f "$sd/fill.$k" ] || cat "$sd/fill.$k"; } | tr '\n' '\0' | xargs -0 pre-commit run shellcheck --show-diff-on-failure --files > "$i.out" 2>&1; echo $? > "$i.rc" ) &
  done
  wait
  # iterate the bins, not their outputs: a bin with no rc (its subshell died) is a failure
  for i in "$sd"/bin.[0-9]*; do
    case "$i" in *.out | *.rc) continue ;; esac
    [ -f "$i.out" ] || [ "$rc" -ne 0 ] || rc=1
    r=$(cat "$i.rc" 2>/dev/null) || r=1 # swallow-ok: a missing rc is a failed bin
    case "$r" in '' | *[!0-9]*) r=1 ;; esac
    [ "$rc" -ne 0 ] || rc=$r
  done
  stage_t sweep_lint
}
sweep_dedup() {
  set -- "$sd"/bin.*.out
  [ -f "$1" ] || return 0
  # a lib in several bins is linted in each, so the same finding can print more than once: print each once
  awk '
    function flush() { if (blk != "") { sub(/\n+$/, "", blk); if (!(blk in seen)) { seen[blk] = 1; print blk; print "" } } blk = "" }
    FNR == 1 { flush(); mode = 0 }
    /^shellcheck\.\.\.+(Passed|Failed|Skipped)/ { flush(); mode = 0; print; next }
    /^In .* line [0-9]+:$/ { flush(); mode = 1; blk = $0; next }
    /^For more information:$/ { flush(); mode = 2; pend = 1; next }
    mode == 1 { blk = blk "\n" $0; next }
    mode == 2 { if ($0 ~ /^  https?:/) { if (!($0 in url)) { url[$0] = 1; if (pend) { print "For more information:"; pend = 0 } print } next } if ($0 == "") next; mode = 0 }
    { print }
    END { flush() }' "$@" || rc=1 # swallow-ok: a failed dedup is an unclean sweep, never a quiet pass
  stage_t sweep_dedup
}
sweep_all() {
  local rc=0 sd n
  [ $# -eq 0 ] || subset=$1
  t_lint=$SECONDS
  t_stage=$SECONDS
  sweep_plan
  sweep_pack
  sweep_verify
  sweep_lint
  sweep_dedup
  rm -rf "$sd"
  echo "shellcheck-pr-range: lint took $((SECONDS - t_lint))s" >&2
  exit "$rc"
}

# -z + quotePath=false: a non-ASCII path must reach the lint verbatim; a NUL count that
# disagrees with the line count means a newline in a name -> uncertain.
git() { command git -c core.quotePath=false "$@"; }
if [ -n "$sweepfile" ]; then
  sweeplist=$(grep -v '^$' "$sweepfile" 2> /dev/null) || sweeplist="" # swallow-ok: an unreadable or blank list is refused just below
  [ -n "$sweeplist" ] || { echo "shellcheck-pr-range: --sweep list $sweepfile is missing or empty" >&2; exit 2; }
  sweep_all "$sweeplist"
fi
dz=$(mktemp "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") || run_all "mktemp failed"
trap 'rm -f "$dz"' EXIT
# The PR's OWN diff against its merge base (three-dot), so commits merged forward from main are
# not re-linted. On a pull_request run HEAD is GitHub's merge ref, whose parents are the base
# branch tip (^1) and the PR head (^2): a rerun reuses the event's stale base.sha, so base..HEAD
# would span every main commit since, while ^1...^2 is exactly the PR's own change.
t_sel=$SECONDS
rng="$base...HEAD"
if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && git rev-parse -q --verify 'HEAD^2' > /dev/null && ! git rev-parse -q --verify 'HEAD^3' > /dev/null; then
  rng='HEAD^1...HEAD^2'
fi
git diff -z --no-renames --name-only --diff-filter=ACMRTD "$rng" > "$dz" || run_all "git diff failed"
changed=$(tr '\0' '\n' < "$dz")
[ "$(tr -d '\0' < "$dz" | wc -c)" -eq "$(tr -d '\0\n' < "$dz" | wc -c)" ] || run_all "newline in a changed path"
[ -n "$changed" ] || { echo "shellcheck-pr-range: no changed files" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

case "
$changed
" in
  *"
.pre-commit-config.yaml
"* | *"
.shellcheckrc
"* | *"
shellcheckrc
"* | *"/.shellcheckrc
"* | *"/shellcheckrc
"* | *"
.github/workflows/ci.yml
"* | *"
scripts/ci/shellcheck-pr-range.sh
"*) run_all "lint config, workflow or the range script changed" ;;
esac

# A moved file's consumers may name its OLD directory (a glob or loop over it), which the
# basename lookup below cannot see. Each directory a rename left (status R, -M) has its
# consumers selected too; the output is NUL-delimited status, old, new triples.
git diff -z -M --name-status --diff-filter=R "$rng" > "$dz" || run_all "git diff -M failed"
olddirs=$(tr '\0' '\n' < "$dz" | awk 'NR % 3 == 2 { o = $0 } NR % 3 == 0 { od = o; nd = $0; sub(/[^\/]*$/, "", od); sub(/[^\/]*$/, "", nd); if (od != "" && od != nd) print od }' | sort -u)

tracked=$(git ls-files) || run_all "git ls-files failed"
list=$(mktemp "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") ||run_all "mktemp failed"
trap 'rm -f "$dz" "$list" "$list.n" "$list.g"' EXIT
# every source/. line and `# shellcheck source=` directive in the tree, grepped ONCE: the
# closure below looks consumers up in this file instead of re-grepping the tree per file
case "$tracked" in *:*) run_all "a tracked path contains a colon" ;; esac
git grep -n -I -E -e "$src_re" -e "$dir_re" -- . > "$list.g" 2>/dev/null || [ "$?" -eq 1 ] || run_all "git grep failed"

# keep only lines whose source/. sits at command position OUTSIDE quotes: a `.` inside a jq
# or sed program is not a source command. Quoted spans are blanked for the test only; the
cmd_pos() {
  local l b
  # one left-to-right scan, so an apostrophe inside a double-quoted span opens nothing; a
  # double-quoted span holding $( or a backtick is executable, so the scan stops there
  # (no \x27 and no ;-joined label: BSD sed has neither, so the apostrophe is spliced in and
  # the label loop is three -e pieces)
  local prog='s/^(([^"'"'"'\\]|\\.)*)("([^"\\$`]|\\.|\$[^("\\])*"|'"'"'[^'"'"']*'"'"')/\1_/'
  while IFS= read -r l; do
    b=$(printf '%s\n' "$l" | sed -E -e ':a' -e "$prog" -e 'ta')
    printf '%s\n' "$b" | grep -qE -e "$src_re" && printf '%s\n' "$l"
  done
  return 0
}
# may the shellcheck hook lint this file (identify's shell type: by extension, by name such as
# PKGBUILD or .kshrc, or by shebang)? True for everything except a file of a KNOWN non-shell type
# with no shell shebang, so a type this list has never heard of keeps its forward edges: a wrong
# yes only widens the selection, a wrong no would drop an edge the full sweep followed.
is_shell() {
  case "$1" in
    *.md | *.markdown | *.txt | *.rst | *.json | *.jsonc | *.yml | *.yaml | *.toml | *.xml | *.html | *.htm | *.css | *.svg | *.png | *.jpg | *.jpeg | *.gif | *.ico | *.pdf | *.lock | *.tsv | *.csv | *.js | *.mjs | *.cjs | *.jsx | *.ts | *.tsx | *.py | *.rb | *.sql | *.gql | *.graphql) ;;
    *) return 0 ;;
  esac
  local first=
  # read-sink-ok: $1 is a path from the PR's own git diff, read for its first line only and never echoed
  IFS= read -r first < "$1"
  case "$first" in '#!'*sh* | '#!'*cbsd*) return 0 ;; esac
  return 1
}
# consumers of $1: a source/. line or a `# shellcheck source=` directive naming it
consumers() { ( set -o pipefail; N="$1" awk '{ c = $0; sub(/^[^:]*:[0-9]+:/, "", c); if (index(c, ENVIRON["N"])) { sub(/:.*/, ""); print } }' "$list.g" | sort -u > "$list.n" ); }

printf '%s\n' "$changed" > "$list"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  consumers "$d"
  rc=$?
  [ "$rc" -le 1 ] || run_all "git grep failed on $d"
  cat "$list.n" >> "$list"
done <<EOF
$olddirs
EOF
while IFS= read -r f; do
  [ -n "$f" ] || continue
  b=$(basename "$f")
  # files that source this one (changed, added or deleted)
  consumers "$b"
  rc=$?
  [ "$rc" -le 1 ] || run_all "git grep failed on $f"
  cat "$list.n" >> "$list"
  # files this one sources (only if it still exists)
  [ -f "$f" ] || continue
  # forward edges only from files the hook feeds to shellcheck; the text of any other
  # file (README, SKILL.md, .json, .mjs) cannot change a verdict. The hook's `exclude` is not
  # applied here: scanning an excluded vendored file only widens the selection, never narrows it.
  is_shell "$f" || continue
  # directive targets: `# shellcheck source=<path>` names a file shellcheck follows
  grep -E -e "^[[:space:]]*#[[:space:]]*${dir_re}" "$f" 2>/dev/null | sed 's/.*source=//; s/[[:space:]].*$//' | grep -v '^/dev/null$' | while IFS= read -r d; do
    d=${d##*/}
    [ -n "$d" ] && printf '%s\n' "$tracked" | awk -v n="$d" '{ k=split($0,p,"/"); if (p[k]==n) print }'
  done >> "$list"
  # a source line under a `# shellcheck source=<x>.sh` directive is static: the directive names its
  # target (the directive loop above added that edge); comment lines in between, such as a stacked
  # `# shellcheck disable=`, do not break the cover, a blank or code line does
  mark=$(printf '\001')
  lines=$(sed -E -e "/^[[:space:]]*#[[:space:]]*shellcheck[[:space:]].*source=[^[:space:]]+\.(sh|bash)([[:space:]]|\$)/{" -e ':a' -e 'n' -e '/^[[:space:]]*#/ba' -e "s/^/$mark/" -e '}' "$f" 2>/dev/null | grep -E -e "$src_re" | grep -v "^$mark" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//' | cmd_pos)
  [ -n "$lines" ] || continue
  # a line naming no *.sh/*.bash (a bare "$VAR", jq/Python heredoc text, a .env tail)
  # adds no edge: shellcheck cannot follow it (SC1090), so no other input can change this file's
  # verdict. It stays dynamic only when its operand names a tracked file that may be shell under
  # another name shape (no extension, .bats, a shebang file, ...), which shellcheck could follow.
  nolit=$(printf '%s\n' "$lines" | grep -vE '[A-Za-z0-9_.+-]+\.(sh|bash)')
  lines=$(printf '%s\n' "$lines" | grep -E '[A-Za-z0-9_.+-]+\.(sh|bash)')
  if [ -n "$nolit" ]; then
    if [ -z "${shnames+x}" ]; then
      sb=$(git grep -l -I -E -e '^#!.*(sh|cbsd)' -- .) || [ "$?" -eq 1 ] || run_all "git grep failed on shebangs"
      # shell by shebang, or a name with no extension (PKGBUILD, .kshrc, ...), or a shell extension other than .sh/.bash
      shnames=$({ printf '%s\n' "$sb" | awk -F/ 'NF && $NF !~ /\.(sh|bash)$/ { print $NF }'; printf '%s\n' "$tracked" | awk -F/ 'NF && ($NF ~ /^\.?[^.]*$/ || $NF ~ /\.(bats|ksh|zsh|dash|ash|csh|tcsh)$/) { print $NF }'; } | sort -u)
    fi
    ops=$(printf '%s\n' "$nolit" | grep -oE '(^|[;&|{(![:space:]])(source|\.)[[:space:]]+[^[:space:];&|)]*')
    # an operand built by a command substitution can name any file
    grep -qE '\$\(|`' <<< "$ops" && run_all "command substitution in a source operand in $f"
    # the operand's literal tail: the word after `source`/`.`, quotes dropped, past its last `/`
    tails=$(sed -E -e 's/^.*(source|\.)[[:space:]]+//' -e "s/[\"']//g" -e 's/.*\///' -e 's/^(\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)//' <<< "$ops")
    if [ -n "$shnames" ] && grep -qxF -e "$shnames" <<< "$tails"; then
      run_all "source line naming a shell file without a .sh/.bash name in $f"
    fi
  fi
  [ -n "$lines" ] || continue
  # a name glued to a variable expansion ("${D}x.sh", "$N.sh") passes the check above but is dynamic
  printf '%s\n' "$lines" | grep -qE '(\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)[A-Za-z0-9_.+-]*\.(sh|bash)' && run_all "variable-glued source name in $f"
  names=$(printf '%s\n' "$lines" | grep -oE '[A-Za-z0-9_.+-]+\.(sh|bash)')
  printf '%s\n' "$names" | while IFS= read -r n; do
    printf '%s\n' "$tracked" | awk -v n="$n" '{ k=split($0,p,"/"); if (p[k]==n) print }'
  done >> "$list"
done <<EOF
$changed
EOF
# closure: an untouched lib's SC2034 verdict depends on ALL its consumers being in the input set,
# and a consumer's own verdict on ITS consumers -- iterate until no new file appears (bounded)
done_set=""
i=0
while :; do
  i=$((i + 1))
  [ "$i" -le 20 ] || run_all "neighbour closure did not converge"
  cur=$(sort -u "$list")
  todo=$(printf '%s\n' "$cur" | grep -vxF -e "$done_set" -e '' || true)
  [ -n "$todo" ] || break
  done_set=$cur
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    consumers "$(basename "$f")"
    rc=$?
    [ "$rc" -le 1 ] || run_all "git grep failed on $f"
    cat "$list.n" >> "$list"
  done <<EOF
$todo
EOF
done
rm -f "$list.n"

# a quoted path (special chars) cannot be matched back to a file: lint everything
grep -q '^"' "$list" && run_all "path needing quotes in the neighbour set"
# only paths that exist at HEAD; the hook itself filters by type/exclude
files=$(sort -u "$list" | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)
[ -n "$files" ] || { echo "shellcheck-pr-range: nothing lintable (only deletions)" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

if [ "$dry" = 1 ]; then echo "shellcheck-pr-range: selection took $((SECONDS - t_sel))s" >&2; echo "FILES"; printf '%s\n' "$files"; exit 0; fi
echo "shellcheck-pr-range: $(printf '%s\n' "$files" | wc -l) files (changed + neighbours), selection took $((SECONDS - t_sel))s" >&2
sweep_all "$files"
