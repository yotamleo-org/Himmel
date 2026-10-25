#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-docs-reviewer.sh — docs_review.py rule matching on fixture diffs, and
# the learn step: a learned remark is a candidate until one confirmation.
# Platform guard: bash 3.2+, python3.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/docs_review.py"
td="$(mktemp -d "${TMPDIR:-/tmp}/docs-reviewer.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
has(){ grep -q -F -- "$2" "$3" && ok "$1" || { bad "$1: no [$2] in"; sed 's/^/    /' "$3"; }; }
lacks(){
  grep -q -F -- "$2" "$3"
  case $? in
    0) bad "$1: unexpected [$2] in"; sed 's/^/    /' "$3" ;;
    1) ok "$1" ;;
    *) bad "$1: cannot read $3" ;;
  esac
}
run(){ python3 -I "$tool" "$@" >"$td/out" 2>"$td/err"; echo $?; }

# --- the rules file: at least 10 rules, each with a source and a quote ---
n=$(awk -F'\t' 'NR>1 && $1!="" {c++} END {print c+0}' "$here/rules.tsv")
[ "$n" -ge 10 ] && ok "rules.tsv holds $n rules" || bad "rules.tsv holds $n rules, want >= 10"
missing=$(awk -F'\t' 'NR>1 && ($7=="" || $8=="" || $6=="") {print $1}' "$here/rules.tsv")
check "every rule has a date, a source and a quote" "$missing" ""

# --- pattern rules on a diff: file:line, rule id, added lines only ---
rc=$(run check --diff "$here/fixtures/sample.diff")
check "findings exit 1" "$rc" 1
has "dormant row is R03" "docs/lanes.md:13: R03" "$td/out"
has "glm row is R04" "docs/lanes.md:13: R04" "$td/out"
has "name history is R01" "docs/lanes.md:15: R01" "$td/out"
has "ticket number is R02" "docs/lanes.md:15: R02" "$td/out"
has "dated note is R08" "docs/lanes.md:44: R08" "$td/out"
has "finding quotes the matched text" "matched: Name history" "$td/out"
lacks "a context line is not checked" "docs/lanes.md:16:" "$td/out"
lacks "an archive page is exempt" "docs/archive/" "$td/out"
lacks "a non-docs file is not checked" "scripts/lanes/run.sh" "$td/out"
has "judgement rules are listed per changed page" "CHECK docs/lanes.md: R10" "$td/out"
has "summary counts findings" "docs-review: 5 finding(s) in 1 page(s)" "$td/out"

rc=$(run check --diff "$here/fixtures/clean.diff")
check "a clean diff exits 0" "$rc" 0
has "a clean diff still lists the judgement checks" "CHECK docs/guide/start.md: R11" "$td/out"

# --- the prose rule: a long run with no list, table or heading ---
{
  printf 'diff --git a/docs/wall.md b/docs/wall.md\n--- a/docs/wall.md\n+++ b/docs/wall.md\n@@ -0,0 +1,15 @@\n'
  printf '+# Wall\n'
  i=1
  while [ "$i" -le 14 ]; do printf '+prose line %s of a long paragraph.\n' "$i"; i=$((i + 1)); done
} >"$td/wall.diff"
run check --diff "$td/wall.diff" >/dev/null
has "14 prose lines are R09 at the run's first line" "docs/wall.md:2: R09" "$td/out"
head -12 "$td/wall.diff" >"$td/short.diff"
run check --diff "$td/short.diff" >/dev/null
lacks "7 prose lines are not R09" "R09" "$td/out"

# --- diff parsing: git-quoted paths, and an added line that starts with ++ ---
{
  printf 'diff --git "a/docs/\\303\\251.md" "b/docs/\\303\\251.md"\n'
  printf '%s\n' '--- "a/docs/\303\251.md"' '+++ "b/docs/\303\251.md"' '@@ -0,0 +1 @@' '+The GLM lane.'
} >"$td/quoted.diff"
run check --diff "$td/quoted.diff" >/dev/null
has "a git-quoted non-ASCII path is reviewed" "docs/é.md:1: R04" "$td/out"
printf '%s\n' '--- a/docs/plus.md' '+++ b/docs/plus.md' '@@ -0,0 +1,2 @@' '+++ plus line' '+The GLM lane.' >"$td/plus.diff"
run check --diff "$td/plus.diff" >/dev/null
has "an added line starting with ++ is content, not a header" "docs/plus.md:2: R04" "$td/out"

# --- whole-file mode reads the page at the range's head ---
repo="$td/repo"
git init -q "$repo" && git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
mkdir -p "$repo/docs"
printf '# Page\nThe GLM lane runs here.\n' >"$repo/docs/page.md"
git -C "$repo" add . && git -C "$repo" commit -q -m one
printf '# Page\nThe GLM lane runs here.\nA new line.\n' >"$repo/docs/page.md"
git -C "$repo" commit -q -am two
(cd "$repo" && python3 -I "$tool" check --range HEAD~1..HEAD) >"$td/out" 2>&1
lacks "diff mode skips the unchanged GLM line" "docs/page.md:2: R04" "$td/out"
(cd "$repo" && python3 -I "$tool" check --range HEAD~1..HEAD --whole-file) >"$td/out" 2>&1
has "whole-file mode reports the unchanged GLM line" "docs/page.md:2: R04" "$td/out"
{ printf '# Fence\n```bash\n'; i=1; while [ "$i" -le 5 ]; do printf 'echo before %s\n' "$i"; i=$((i + 1)); done; printf '```\n'; } >"$repo/docs/fence.md"
git -C "$repo" add . && git -C "$repo" commit -q -m three
{ printf '# Fence\n```bash\n'; i=1; while [ "$i" -le 5 ]; do printf 'echo before %s\n' "$i"; i=$((i + 1)); done
  i=1; while [ "$i" -le 14 ]; do printf 'echo added %s\n' "$i"; i=$((i + 1)); done; printf '```\n'; } >"$repo/docs/fence.md"
git -C "$repo" commit -q -am four
(cd "$repo" && python3 -I "$tool" check --range HEAD~1..HEAD) >"$td/out" 2>&1
lacks "code added inside a fence opened above the hunk is not prose" "R09" "$td/out"
mkdir -p "$repo/docs/archive"
printf '# Old\nThe GLM lane.\n' >"$repo/docs/archive/old.md"
git -C "$repo" add . && git -C "$repo" commit -q -m five
git -C "$repo" mv docs/archive/old.md docs/moved.md && git -C "$repo" commit -q -m six
(cd "$repo" && python3 -I "$tool" check --range HEAD~1..HEAD --whole-file) >"$td/out" 2>&1
has "whole-file mode reviews a page renamed out of the archive" "docs/moved.md:2: R04" "$td/out"
{
  printf '%s\n' '--- /dev/null' '+++ b/docs/nested.md' '@@ -0,0 +1,17 @@' '+````markdown' '+```'
  i=1; while [ "$i" -le 14 ]; do printf '+echo nested %s\n' "$i"; i=$((i + 1)); done
  printf '%s\n' '+````'
} >"$td/nested.diff"
run check --diff "$td/nested.diff" >/dev/null
lacks "a shorter fence inside a longer one does not close it" "R09" "$td/out"
printf 'The GLM lane.\n' >"$repo/docs/np.md"
git -C "$repo" add . && git -C "$repo" commit -q -m seven && git -C "$repo" config diff.noprefix true
(cd "$repo" && python3 -I "$tool" check --range HEAD~1..HEAD) >"$td/out" 2>&1
has "a range diff is read the same under diff.noprefix" "docs/np.md:1: R04" "$td/out"
rc=$(cd "$repo" && python3 -I "$tool" check "--range=--output=$td/written" >/dev/null 2>&1; echo $?)
check "a range starting with a dash is refused" "$rc" 2
[ ! -e "$td/written" ] && ok "a dash range writes no file" || bad "a dash range wrote $td/written"

# --- input that is not a diff, and a broken rules file, are usage errors ---
printf 'not a diff\n' >"$td/prose.txt"
rc=$(run check --diff "$td/prose.txt")
check "input with no file header exits 2" "$rc" 2
: >"$td/empty.diff"
rc=$(run check --diff "$td/empty.diff")
check "empty input exits 2" "$rc" 2
head -1 "$here/rules.tsv" >"$td/bad.tsv"
printf 'R01\tactive\tpattern\t(\tr\t2026-10-25\ts\tq\n' >>"$td/bad.tsv"
rc=$(run check --rules "$td/bad.tsv" --diff "$here/fixtures/clean.diff")
check "a broken pattern in the rules file exits 2" "$rc" 2
lacks "a broken pattern is no traceback" "Traceback" "$td/err"
head -1 "$here/rules.tsv" >"$td/bad.tsv"
printf 'R01\tactive\tprose\tmany\tr\t2026-10-25\ts\tq\n' >>"$td/bad.tsv"
rc=$(run check --rules "$td/bad.tsv" --diff "$here/fixtures/clean.diff")
check "a non-numeric prose threshold exits 2" "$rc" 2
head -1 "$here/rules.tsv" >"$td/bad.tsv"
printf 'R01\tactiv\tpattern\tx\tr\t2026-10-25\ts\tq\n' >>"$td/bad.tsv"
run check --rules "$td/bad.tsv" --diff "$here/fixtures/clean.diff" >/dev/null
has "an unknown rule state is warned about" "R01 has unknown state" "$td/err"

# --- learn step: candidate until one confirmation ---
cp "$here/rules.tsv" "$td/rules.tsv"
rc=$(run learn --rules "$td/rules.tsv" --pattern 'foobar widget' --rule 'Say what the widget does.' \
  --source 'operator remark on PR 9999' --quote 'what is a foobar widget')
check "learn exits 0" "$rc" 0
new_id=$(awk -F'\t' 'END {print $1}' "$td/rules.tsv")
has "learn names the new candidate" "$new_id candidate" "$td/out"
check "the new rule is a candidate" "$(awk -F'\t' 'END {print $2}' "$td/rules.tsv")" candidate
run check --rules "$td/rules.tsv" --diff "$here/fixtures/sample.diff" >/dev/null
lacks "a candidate is not a finding" "docs/lanes.md:12: $new_id" "$td/out"
has "a candidate is listed as awaiting confirmation" "CANDIDATE $new_id" "$td/out"
rc=$(run confirm --rules "$td/rules.tsv" "$new_id" --by 'operator, chief conversation')
check "confirm exits 0" "$rc" 0
run check --rules "$td/rules.tsv" --diff "$here/fixtures/sample.diff" >/dev/null
has "a confirmed remark is a finding" "docs/lanes.md:12: $new_id" "$td/out"
has "the confirmation is recorded" "confirmed" "$td/rules.tsv"

rc=$(run learn --rules "$td/rules.tsv" --pattern 'x' --rule 'r' --source 's')
check "learn without a quote is refused" "$rc" 2
rc=$(run learn --rules "$td/rules.tsv" --pattern '(' --rule 'r' --source 's' --quote 'q')
check "learn with a broken pattern is refused" "$rc" 2
rc=$(run learn --rules "$td/rules.tsv" --pattern 'a	b' --rule 'r' --source 's' --quote 'q')
check "learn with a tab in a field is refused" "$rc" 2
rc=$(run learn --rules "$td/rules.tsv" --pattern 'x' --rule 'r' --source 's' --quote "$(printf 'a\rb')")
check "learn with a carriage return in a field is refused" "$rc" 2
rc=$(run confirm --rules "$td/rules.tsv" R999 --by x)
check "confirm of an unknown id is refused" "$rc" 2
rc=$(run confirm --rules "$td/rules.tsv" R01 --by x)
check "confirm of an active rule is refused" "$rc" 2

echo "# fails=$fails"
[ "$fails" -eq 0 ]
