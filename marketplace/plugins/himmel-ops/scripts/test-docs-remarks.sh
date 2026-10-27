#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-docs-remarks.sh — docs_remarks.py harvests operator remarks into candidate
# rows of the docs reviewer's rules file, and scopes a diff's docs pages for CI.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../../.."
tool="$here/../skills/docs-reviewer/docs_remarks.py"
td="$(mktemp -d "${TMPDIR:-/tmp}/docs-remarks.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
has(){ [ -r "$2" ] || { bad "$1: $2 unreadable"; return; }; grep -qF -- "$3" "$2" && ok "$1" || bad "$1: [$3] not in $2"; }
lacks(){ [ -r "$2" ] || { bad "$1: $2 unreadable"; return; }; grep -qF -- "$3" "$2" && bad "$1: [$3] still in $2" || ok "$1"; }

rules(){
    printf 'id\tstate\trule\tdate\tsource\tquote\n' >"$1"
    printf 'M01\tactive\tA page is current.\t2026-10-20\tdecisions (92)\talot of the docs are non relevent\n' >>"$1"
    printf 'M02\tactive\tEvery claim is correct.\t2026-10-21\tdecisions (115)\tauthnticity and correctness for the docs\n' >>"$1"
}

# --- harvest: the chief's recorded remarks file
rules "$td/r.tsv"
printf '# date\tsource\tquote\n2026-10-27\tdecisions 350\twhy does this page   start with the history?\n' >"$td/chief.tsv"
python3 "$tool" harvest --rules "$td/r.tsv" --remarks-file "$td/chief.tsv" --write >"$td/h.out" 2>"$td/h.err"
check "harvest: exit 0" "$?" 0
check "one fixture remark becomes one candidate row in a temp rules file" \
    "$(grep -c $'^M03\tcandidate\t' "$td/r.tsv")" 1
check "harvest: the row carries date, source and the quote" \
    "$(awk -F'\t' '$1 == "M03" { print $4 "|" $5 "|" $6 }' "$td/r.tsv")" \
    "2026-10-27|decisions 350|why does this page start with the history?"
has "harvest: the rule waits for the chief" "$td/r.tsv" 'pending: the chief writes the rule'
check "harvest: earlier rows untouched" "$(head -3 "$td/r.tsv" | md5sum)" "$(rules "$td/r0.tsv"; md5sum <"$td/r0.tsv")"

python3 "$tool" harvest --rules "$td/r.tsv" --remarks-file "$td/chief.tsv" --write >"$td/h2.out" 2>&1
check "harvest: a quote already in the table adds no row" "$(grep -c . "$td/r.tsv")" 4

rules "$td/rep.tsv"
printf '2026-10-28\tdecisions 360\talot of the docs are non relevent\n' >"$td/rep-in.tsv"
python3 "$tool" harvest --rules "$td/rep.tsv" --remarks-file "$td/rep-in.tsv" --write >"$td/rep.out" 2>&1
check "harvest: the same words from another source are a repeat row" "$(grep -c $'^M03\tcandidate\t.*decisions 360' "$td/rep.tsv")" 1

rules "$td/mal.tsv"
printf '2026-10-27\tdecisions 350\tfirst\n2026-10-27 no tabs here\n' >"$td/mal-in.tsv"
python3 "$tool" harvest --rules "$td/mal.tsv" --remarks-file "$td/mal-in.tsv" --write >"$td/mal.out" 2>&1
check "harvest: a malformed remarks line exits 1" "$?" 1
has "harvest: it names the file and line" "$td/mal.out" 'mal-in.tsv:2'
check "harvest: a malformed file writes nothing" "$(grep -c . "$td/mal.tsv")" 3

rules "$td/dry.tsv"
python3 "$tool" harvest --rules "$td/dry.tsv" --remarks-file "$td/chief.tsv" >"$td/dry.out" 2>&1
check "harvest: dry run leaves the table alone" "$(grep -c . "$td/dry.tsv")" 3
has "harvest: dry run prints the row" "$td/dry.out" $'M03\tcandidate'

# --- harvest: operator comments on merged docs PRs, via a fake gh
mkdir -p "$td/bin"
cat >"$td/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "pr list "*) echo '[{"number":7,"files":[{"path":"docs/a.md"}]},{"number":8,"files":[{"path":"scripts/x.sh"}]}]' ;;
  *"pulls/7/comments"*)
    echo '["op","2026-10-26T10:00:00Z","docs/a.md","12","who cares about this line?\nsay the gain first"]'
    echo '["op","2026-10-26T10:01:00Z","docs/a.md","13","Fixed at 1234abc."]'
    echo '["op","2026-10-26T10:02:00Z","scripts/x.sh","3","this name is odd"]'
    echo '["someone","2026-10-26T10:04:00Z","docs/a.md","14","another reviewer wrote this"]'
    echo '["op","2026-10-26T10:05:00Z","docs/a.md","15","<!-- generated --> summary"]'
    echo '["coderabbitai[bot]","2026-10-26T10:03:00Z","docs/a.md","9","<!-- coderabbit --> nit"]' ;;
  *"pulls/7/reviews"*) echo '["op","2026-10-26T11:00:00Z","","",""]' ;;
  *"issues/7/comments"*)
    echo '["op","2026-10-26T12:00:00Z","","","@coderabbitai review"]'
    echo '["op","2026-10-26T12:05:00Z","","","Rejected: out of scope."]' ;;
  *"/8/"*) echo '["op","2026-10-26T13:00:00Z","","","a remark on a code-only PR"]' ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$td/bin/gh"
rules "$td/g.tsv"
PATH="$td/bin:$PATH" python3 "$tool" harvest --rules "$td/g.tsv" --author op --write >"$td/g.out" 2>"$td/g.err"
check "gh: exit 0" "$?" 0
check "gh: one operator docs remark becomes one row" "$(grep -c $'\tcandidate\t' "$td/g.tsv")" 1
check "gh: source names the PR and the line" "$(awk -F'\t' '$1 == "M03" { print $5 }' "$td/g.tsv")" "PR 7 review comment docs/a.md:12"
has "gh: a multi-line comment is one TSV field" "$td/g.tsv" 'who cares about this line? say the gain first'
lacks "gh: an agent's thread reply is skipped" "$td/g.tsv" 'Fixed at'
lacks "gh: a CR command is skipped" "$td/g.tsv" '@coderabbitai'
lacks "gh: a code-file comment is skipped" "$td/g.tsv" 'this name is odd'
lacks "gh: a bot is skipped" "$td/g.tsv" 'coderabbit -->'
lacks "gh: another login's docs remark is skipped" "$td/g.tsv" 'another reviewer wrote this'
lacks "gh: a generated comment from the operator's login is skipped" "$td/g.tsv" 'generated -->'
lacks "gh: a PR with no docs page is skipped" "$td/g.tsv" 'code-only PR'

check "harvest: no source is a usage error" "$(python3 "$tool" harvest --rules "$td/g.tsv" >/dev/null 2>&1; echo $?)" 2

# --- scope: the changed docs pages of a diff, and the table's shape
repo="$td/repo"
mkdir -p "$repo/docs/archive" "$repo/site" "$repo/scripts"
git -C "$repo" init -q
for f in docs/a.md docs/archive/old.md README.md site/index.html scripts/x.sh; do echo one >"$repo/$f"; done
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
for f in docs/a.md docs/archive/old.md README.md site/index.html scripts/x.sh; do echo two >>"$repo/$f"; done
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam head
(cd "$repo" && python3 "$tool" scope --rules "$td/r.tsv" --base HEAD~1 --head HEAD) >"$td/s.out" 2>&1
check "scope: exit 0" "$?" 0
has "scope: counts the pages and the remarks" "$td/s.out" 'docs-review scope: 3 changed docs page(s)'
has "scope: active and candidate rows" "$td/s.out" '2 active and 1 candidate remark(s)'
has "scope: a docs page" "$td/s.out" '- M docs/a.md'
has "scope: README" "$td/s.out" '- M README.md'
has "scope: site" "$td/s.out" '- M site/index.html'
lacks "scope: docs/archive is exempt" "$td/s.out" 'docs/archive/old.md'
lacks "scope: a script is not a docs page" "$td/s.out" 'scripts/x.sh'

(cd "$repo" && python3 "$tool" scope --rules "$td/r.tsv" --base HEAD --head HEAD) >"$td/s0.out" 2>&1
has "scope: no docs change" "$td/s0.out" 'docs-review scope: no docs page changed'

rules "$td/bad.tsv"
printf 'M02\tlive\tdup\t2026-10-21\tx\t\n' >>"$td/bad.tsv"
(cd "$repo" && python3 "$tool" scope --rules "$td/bad.tsv" --base HEAD~1 --head HEAD) >"$td/b.out" 2>&1
check "scope: a malformed table exits 1" "$?" 1
has "scope: a duplicate id is named" "$td/b.out" 'duplicate id M02'
has "scope: an unknown state is named" "$td/b.out" "state 'live'"
has "scope: an empty quote is named" "$td/b.out" 'M02 has no quote'

git -C "$repo" mv docs/a.md scripts/a-notes.md
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm move
(cd "$repo" && python3 "$tool" scope --rules "$td/r.tsv" --base HEAD~1 --head HEAD) >"$td/mv.out" 2>&1
has "scope: a page renamed out of docs/ is in scope" "$td/mv.out" '- R docs/a.md → scripts/a-notes.md'

(cd "$root" && python3 "$tool" scope --base HEAD --head HEAD) >"$td/real.out" 2>&1
check "scope: the real remarks.tsv has a sound shape" "$?" 0

# --- wiring: the advisory CI step and the templates
ci="$root/.github/workflows/ci.yml"
step="$(awk '/^  [a-z][a-z0-9-]*:/ { injob = ($1 == "lint:") } injob && /- name: docs-review scope/ { s = 1 } s && /^      - / && !/docs-review scope/ { exit } s { print }' "$ci")"
case "$step" in *"continue-on-error: true"*) ok "ci: the lint job's docs-review step is advisory" ;; *) bad "ci: no advisory docs-review step in the lint job" ;; esac
case "$step" in *"docs_remarks.py scope"*) ok "ci: the step runs docs_remarks.py scope" ;; *) bad "ci: the step does not run docs_remarks.py scope" ;; esac
has "brief: READY quotes the docs-review scope line" "$root/docs/handover/worker-brief-template.md" 'docs-review scope:'
has "judge: the verdict quotes the docs-review summary line" "$root/docs/handover/judge-brief-template.md" "\`docs-review:\` summary line"

[ "$fails" = 0 ] && echo "PASS test-docs-remarks" || { echo "FAIL test-docs-remarks ($fails)"; exit 1; }
