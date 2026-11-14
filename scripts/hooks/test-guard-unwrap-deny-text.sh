#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands are literal text with $ and backticks, never expanded here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/gudt.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"

g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c core.hooksPath=/dev/null \
  -c commit.gpgsign=false -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
if ! { g init -q "$T/repo" && g -C "$T/repo" commit -q --allow-empty -m fixture \
  && g -C "$T/repo" worktree add -q -b wt "$T/wt"; }; then
  echo "FAIL: cannot build the worktree fixture"; exit 1
fi
printf 'a\n' >"$T/wt/f"
printf 'a\n' >"$T/wt/pat.txt"

SIX="block-read-secrets.sh block-destructive-commands.sh block-tail-pipe-on-gates.sh require-quiet-run.sh block-infra-destroy.sh block-bare-qmd-query.sh"
L1='guard-unwrap: refusing a command whose quoting this guard cannot read and that runs a nested shell, an eval or a quoted command word.'
P2='    (denied with its variable expansions removed or defaulted — a variable that expands to nothing, or to its default word, leaves this command; rc=2)'

pass=0; fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "FAIL $1"; }

run() {
  local hook=$1 c=$2 json
  shift 2
  json=$(jq -cn --arg c "$c" --arg d "$T/wt" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  (cd "$T/wt" && printf '%s' "$json" | env -i HOME="$T/home" PATH="$PATH" TMPDIR="$T" "$@" \
    bash "$HERE/$hook" >/dev/null 2>"$T/err")
  RC=$?
}

want_rc() {
  if [ "$RC" = "$2" ]; then ok; else no "$1: want rc $2, got $RC"; sed 's/^/    | /' "$T/err"; fi
}
first_is() {
  if [ "$(head -n 1 "$T/err")" = "$2" ]; then ok; else no "$1: first stderr line is not: $2"; fi
}
has_exact() {
  if grep -qxF -- "$2" "$T/err"; then ok; else no "$1: no stderr line: $2"; fi
}
has_line() {
  local row=$1 pre=$2 line s hit
  shift 2
  while IFS= read -r line; do
    case "$line" in "$pre"*) ;; *) continue ;; esac
    hit=1
    for s in "$@"; do case "$line" in *"$s"*) ;; *) hit=0 ;; esac; done
    [ "$hit" = 1 ] && { ok; return; }
  done <"$T/err"
  no "$row: no stderr line starting '$pre' holding: $*"
}
lacks() {
  if grep -qF -- "$2" "$T/err"; then no "$1: stderr holds '$2'"; else ok; fi
}
after_is() {
  local next
  next=$(grep -A1 -xF -- "$2" "$T/err" | sed -n 2p)
  case "$next" in "$3"*) ok ;; *) no "$1: the line after '$2' does not start '$3'" ;; esac
}
only_grep_f() {
  local all gf
  all=$(grep -o -- '-f' "$T/err" | wc -l | tr -d ' ')
  gf=$(grep -o -- 'grep -f' "$T/err" | wc -l | tr -d ' ')
  if [ "$all" = "$gf" ]; then ok; else no "$1: stderr names a -f other than grep -f"; fi
}
allowed_by_six() {
  local h
  for h in $SIX; do
    run "$h" "$2"
    if [ "$RC" = 0 ] && [ ! -s "$T/err" ]; then ok; else no "$1 $h: want rc 0 and empty stderr, got rc $RC"; sed 's/^/    | /' "$T/err"; fi
  done
}

BRS=block-read-secrets.sh
R1='grep -n -E "^   ```bash" -A3 f'
R2='grep -n '\''ready-go\|READY_GO\|AUTO_GO_[A-Z_]*=\|\${AUTO_GO_[A-Z_]*'\'' f'
R3='grep -n "^load_dotenv()\|^_load_dotenv_primary_for()\|LOAD_DOTENV\|-z \"\${!\|already set\|wins" f'

run "$BRS" "$R1"
want_rc R1 2
first_is R1 "$L1"
has_line R1 '    Cause: ' 'a backtick inside double quotes'
has_line R1 '    Retry: ' 'single quotes' 'grep -f <file>'
has_line R1 '    Single-run bypass: ' 'their own terminal'
after_is R1 "$L1" '    Cause: '
only_grep_f R1
lacks R1 'sed -f'

site2_text_without_tokenizer_cause() {
  run "$BRS" "$2"
  want_rc "$1" 2
  first_is "$1" "$L1"
  has_exact "$1" "$P2"
  after_is "$1" "$P2" '    Cause: this guard cannot know what a variable holds'
  has_line "$1" '    Retry with no $ in the command text: ' '[$]' 'grep -f <file>'
  has_line "$1" '    Single-run bypass: ' 'their own terminal'
  lacks "$1" "Cause: this guard's tokenizer"
  only_grep_f "$1"
  lacks "$1" 'sed -f'
}
site2_text_without_tokenizer_cause R2 "$R2"
site2_text_without_tokenizer_cause R3 "$R3"

allowed_by_six G1 'grep -n -E '\''^   ```bash'\'' -A3 f'
allowed_by_six G2 'grep -n -f pat.txt f'
allowed_by_six G4 'grep -n '\''ready-go\|READY_GO\|AUTO_GO_[A-Z_]*=\|[$]{AUTO_GO_[A-Z_]*'\'' f'
allowed_by_six G5 'grep -n "^load_dotenv()\|^_load_dotenv_primary_for()\|LOAD_DOTENV\|-z \"[$]{!\|already set\|wins" f'

run "$BRS" 'grep -n '\''^load_dotenv()\|^_load_dotenv_primary_for()\|LOAD_DOTENV\|-z "${!\|already set\|wins'\'' f'
want_rc "G6 single quotes alone stay denied by the expansion re-read" 2

run "$BRS" 'bash -c "grep -n \"\$X\" f"'
want_rc "S1 variable in a nested shell" 2
has_exact "S1 variable in a nested shell" "$P2"
allowed_by_six "S1 value spelled out" 'bash -c "grep -n \"x\" f"'

run "$BRS" 'case x in a) bash -c '\''echo hi'\'';; esac'
want_rc "S2 case statement" 2
first_is "S2 case statement" "$L1"
has_line "S2 case statement" '    Cause: ' 'a case arm ending in ;;'
allowed_by_six "S2 nested call split out" 'bash -c '\''echo hi'\'''

run "$BRS" '$V${Z}cat .env'
want_rc N1 2
case "$(head -n 1 "$T/err")" in
  '⛔ block-read-secrets: refusing Bash command that reads a secret file:'*) ok ;;
  *) no "N1: first stderr line is not the secret refusal" ;;
esac
run "$BRS" 'cat .env'
want_rc N2 2
run "$BRS" 'grep -n -f pat.txt .env'
want_rc M1 2

allowed_by_six N4 'grep -n '\''a'\'' f'
allowed_by_six "I5 untokenizable" 'echo "abc'
allowed_by_six "I5 expansion re-read" 'cat $F'

run "$BRS" "$R1" READ_SECRETS_OK=1
want_rc "N5 READ_SECRETS_OK" 2
first_is "N5 READ_SECRETS_OK" "$L1"

echo "guard-unwrap-deny-text: $pass passed, $fail failed"
[ "$fail" = 0 ]
