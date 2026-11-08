#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# shellcheck disable=SC2016  # single-quoted scripts run in the stub shells
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ADD="$HERE/ceiling-add.sh"
LOOKUP="$HERE/ceiling-lookup.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/ceilings-ledger-test.XXXXXX")" || exit 1
work="$(cd "$work" && pwd -P)"
trap 'kill "${sleeper:-}" 2>/dev/null; rm -rf "$work"' EXIT
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing [$3] in [$2])" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (unexpected [$3] in [$2])" ;; *) ok "$1" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 ([$2] != [$3])"; }

SECRET="the parser never reads quoted globs"

fx="$work/repo"
mkdir -p "$fx"
(
    cd "$fx" || exit 1
    git -c init.defaultBranch=main init -q && git config user.email t@t.test && git config user.name t && git config commit.gpgsign false
    printf 'do_a() {\n  :\n}\n' > a.sh
    printf 'case "$x" in\n  ] [weird) ;;\nesac\nb_fn() { :; }\n' > b.sh
    printf 'c\n' > c.sh
    git add . && git commit -qm base
    git checkout -qb feature
    printf '# change\n' >> a.sh && printf '# change\n' >> b.sh
    git commit -qam change
) || { echo "FAIL: fixture repo setup" >&2; exit 1; }

export HIMMEL_CEILINGS_LEDGER="$work/ledger.tsv"
case "$HIMMEL_CEILINGS_LEDGER" in "$work"/*) ok "the ledger override is inside the work dir" ;; *) bad "the ledger override escapes the work dir"; exit 1 ;; esac
unset HIMMEL_BUCKET_DIR

add() { (cd "$fx" && bash "$ADD" "$@"); }

id1=$(add add --file a.sh --anchor do_a --ceiling "$SECRET" --trigger "a glob test fails" --ticket HIMMEL-1); rc=$?
eq "add exits 0" "$rc" 0
eq "add prints the first id" "$id1" C-0001
head1=$(head -n 1 "$HIMMEL_CEILINGS_LEDGER")
eq "the header is created on first write" "$head1" "$(printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote')"
id2=$(add add --file b.sh --anchor '] [weird' --ceiling "b ceiling" --trigger "b trigger"); eq "a second add gets the next id" "$id2" C-0002

refusal() {
    local label=$1 want=$2 out rc before after
    shift 2
    before=$(cat "$HIMMEL_CEILINGS_LEDGER")
    out=$(add "$@" 2>&1); rc=$?
    after=$(cat "$HIMMEL_CEILINGS_LEDGER")
    eq "$label exits 1" "$rc" 1
    has "$label names its reason" "$out" "$want"
    eq "$label writes nothing" "$after" "$before"
}
refusal "a tab in a field" "tab or a newline" add --file a.sh --anchor do_a --ceiling "$(printf 'x\ty')" --trigger t
refusal "a missing anchor" "anchor 'no_such' is not in a.sh" add --file a.sh --anchor no_such --ceiling x --trigger t
refusal "a missing file" "does not exist at HEAD" add --file gone.sh --anchor do_a --ceiling x --trigger t
refusal "an empty trigger on open" "needs a trigger" add --file a.sh --anchor do_a --ceiling x --trigger ""
refusal "a bad state" "is not open, lifted" set --id C-0001 --state closed --note n
printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\na.sh\tdo_a\tx\tt\t\tlifted\t\n' > "$work/nonote.tsv"
refusal "a closing state without a note" "state lifted needs a note" import --check "$work/nonote.tsv"
out=$(add import "$work/nonote.tsv" 2>&1); rc=$?
eq "import with neither --check nor --pr is usage (exit 2)" "$rc" 2
has "import names the missing --pr" "$out" "--pr"

for i in 1 2 3 4 5 6 7 8; do
    add add --file c.sh --anchor c --ceiling "parallel $i" --trigger t > "$work/par.$i" 2>&1 &
done
wait
ids=$(cat "$work"/par.* | sort -u | grep -c '^C-[0-9]\{4\}$')
eq "8 concurrent adds print 8 distinct ids" "$ids" 8
whole=$(awk -F '\t' 'NR > 1 && $4 ~ /^parallel / && NF == 10' "$HIMMEL_CEILINGS_LEDGER" | wc -l | tr -d ' ')
eq "8 concurrent adds leave 8 whole rows" "$whole" 8

cp "$HIMMEL_CEILINGS_LEDGER" "$work/before"
add set --id C-0002 --state lifted --note "fixed by the b rewrite" >/dev/null; eq "set exits 0" "$?" 0
prefix() { cmp -s "$1" <(head -c "$(wc -c < "$1" | tr -d ' ')" "$2"); }
prefix "$work/before" "$HIMMEL_CEILINGS_LEDGER" && ok "the bytes before set are a prefix of the bytes after" || bad "set rewrote ledger bytes"
idsout=$(cd "$fx" && bash "$LOOKUP" --ids -- b.sh)
eq "the reader shows the newest state (C-0002 lifted, so none open for b.sh)" "$idsout" "CEILINGS: none for the 1 touched files"
add set --id C-0002 --state open --note "reopened" >/dev/null
idsout=$(cd "$fx" && bash "$LOOKUP" --ids -- b.sh)
has "a reopened id is open again" "$idsout" "C-0002"

printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\na.sh\tdo_a\timported one\tt\t\topen\tmigration: from a marker\nc.sh\tc\timported two\t\t\tdropped\tmigration: pointer only\n' > "$work/draft.tsv"
out=$(add import --check "$work/draft.tsv"); eq "import --check passes a good draft" "$?" 0
cp "$HIMMEL_CEILINGS_LEDGER" "$work/before"
out=$(add import --pr 77 "$work/draft.tsv"); rc=$?
eq "import --pr exits 0" "$rc" 0
eq "import reports its counts" "$out" "import: 2 rows (open 1, lifted 0, dropped 1), skipped 0 already in the ledger"
prefix "$work/before" "$HIMMEL_CEILINGS_LEDGER" && ok "the bytes before import are a prefix of the bytes after" || bad "import rewrote ledger bytes"
n1=$(wc -l < "$HIMMEL_CEILINGS_LEDGER")
out=$(add import --pr 77 "$work/draft.tsv")
eq "a second import appends nothing" "$(wc -l < "$HIMMEL_CEILINGS_LEDGER")" "$n1"
eq "a second import reports skipped" "$out" "import: 0 rows (open 0, lifted 0, dropped 0), skipped 2 already in the ledger"

long=$(printf 'w%.0s' $(seq 1 1200))
refusal "a 1200-character add" "over 300 characters" add --file a.sh --anchor do_a --ceiling "$long" --trigger t
printf 'file\tanchor\tceiling\ttrigger\tticket\tstate\tnote\na.sh\tdo_a\t%s\tt\t\topen\tmigration: long block\n' "$long" > "$work/long.tsv"
out=$(add import --pr 78 "$work/long.tsv"); eq "a 1200-character migration row imports" "$?" 0

mkdir -p "$work/bin"
for n in claude codex copilot agy hermes other; do cp "$(command -v bash)" "$work/bin/$n"; done
clean_env=(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_MODEL -u HERMES_ENGINE -u CODEX_ADAPTER -u CODEX_THREAD_ID -u CLAUDE_PID -u CODEX_PROXY_BASE_URL)
under() {
    local stub=$1
    shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    (cd "$fx" && "${clean_env[@]}" ${envs[@]+"${envs[@]}"} "$work/bin/$stub" -c 'bash "$0" "$@"; rc=$?; exit $rc' "$LOOKUP" "$@")
}
range=(--range main...feature)

out=$(under claude CLAUDECODE=1 -- "${range[@]}"); rc=$?
eq "native: exit 0" "$rc" 0
has "native Claude (CLAUDECODE=1, claude ancestor) shows the row" "$out" "C-0001 a.sh [do_a] ceiling: $SECRET"
has "native: the header counts rows and files" "$out" "CEILINGS: 4 open rows for 2 of 2 touched files"
has "native: the preamble says cite by id only" "$out" "cite a row by its id only; never quote its ceiling or trigger"
out=$(under claude CLAUDECODE=1 ANTHROPIC_MODEL=claude-opus-5-5 -- "${range[@]}")
has "ANTHROPIC_MODEL=claude-opus-5-5 shows rows" "$out" "C-0001 a.sh"
out=$(under claude CLAUDECODE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:8787 -- "${range[@]}")
has "the headroom proxy URL (R32) shows rows" "$out" "C-0001 a.sh"
out=$(under claude CLAUDECODE=1 ANTHROPIC_BASE_URL=https://api.anthropic.com -- "${range[@]}")
has "the Anthropic API host shows rows" "$out" "C-0001 a.sh"
out=$(under claude CLAUDECODE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:8317 ANTHROPIC_MODEL=gpt-6.1-sol -- "${range[@]}")
has "claudex env is withheld" "$out" "CEILINGS: withheld (non-Claude session:"
lacks "claudex env shows no ceiling" "$out" "$SECRET"
out=$(under claude CLAUDECODE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:8788 -- "${range[@]}")
has "a loopback URL that is not the headroom proxy is withheld" "$out" "withheld"
out=$(under claude CLAUDECODE=1 ANTHROPIC_MODEL=gpt-6.1-sol -- "${range[@]}")
has "a non-Claude model is withheld" "$out" "ANTHROPIC_MODEL is not a Claude model"
out=$(under claude CLAUDECODE=1 CODEX_THREAD_ID=t1 -- "${range[@]}")
has "a codex runtime signal is withheld" "$out" "CODEX_THREAD_ID set"
out=$(under claude -u CLAUDECODE -- "${range[@]}")
has "Codex-CLI env (CLAUDECODE unset) is withheld" "$out" "CLAUDECODE is not 1"
out=$(cd "$fx" && env -i PATH="$PATH" HOME="$work" HIMMEL_CEILINGS_LEDGER="$HIMMEL_CEILINGS_LEDGER" bash "$LOOKUP" "${range[@]}")
has "an empty env is withheld" "$out" "withheld"
for agent in codex copilot agy hermes; do
    out=$(cd "$fx" && "${clean_env[@]}" CLAUDECODE=1 "$work/bin/claude" -c '"$0" -c "bash \"\$0\" \"\$@\"; rc=\$?; exit \$rc" "$@"; rc=$?; exit $rc' "$work/bin/$agent" "$LOOKUP" "${range[@]}")
    has "an inherited CLAUDECODE under a $agent process is withheld" "$out" "process chain runs under $agent"
    lacks "the $agent run shows no ceiling" "$out" "$SECRET"
done
out=$(cd "$fx" && "${clean_env[@]}" CLAUDECODE=1 "$work/bin/claude" -c 'CLAUDE_PID=$$ bash "$0" "$@"; rc=$?; exit $rc' "$LOOKUP" "${range[@]}")
has "CLAUDE_PID an ancestor shows rows" "$out" "C-0001 a.sh"
sleep 60 & sleeper=$!
out=$(under claude CLAUDECODE=1 CLAUDE_PID="$sleeper" -- "${range[@]}")
has "CLAUDE_PID not an ancestor is withheld" "$out" "CLAUDE_PID is not an ancestor"
rm -f "$work/orphan.out" "$work/orphan.done"
(cd "$fx" && "${clean_env[@]}" CLAUDECODE=1 "$work/bin/other" -c '( sleep 1; bash "$0" "$@" > "'"$work"'/orphan.out" 2>&1; : > "'"$work"'/orphan.done" ) & exit 0' "$LOOKUP" "${range[@]}")
for _ in $(seq 1 100); do [ -f "$work/orphan.done" ] && break; sleep 0.1; done
out=$(cat "$work/orphan.out" 2>/dev/null)
has "a chain with neither name is withheld" "$out" "no claude process in the process chain"

out=$(under other ANTHROPIC_BASE_URL=http://127.0.0.1:8317 ANTHROPIC_MODEL=gpt-6.1-sol -- --ids "${range[@]}")
has "--ids under a claudex env prints the header" "$out" "CEILINGS: 4 open rows for 2 of 2 touched files"
has "--ids prints id, file, anchor and ticket tab-separated" "$out" "$(printf 'C-0001\ta.sh\tdo_a\tHIMMEL-1')"
has "--ids keeps an anchor holding ] [ in one field" "$out" "$(printf 'C-0002\tb.sh\t] [weird\t')"
lacks "--ids prints no ceiling text" "$out" "$SECRET"
lacks "--ids prints no trigger text" "$out" "a glob test fails"
out=$(cd "$fx" && bash "$LOOKUP" --ids --all)
has "--ids --all lists every open row" "$out" "$(printf 'C-0002\tb.sh\t] [weird\t')"
has "--ids --all header" "$out" "open rows (ledger $HIMMEL_CEILINGS_LEDGER)"
lacks "--ids --all lists no closed row" "$out" "imported two"

out=$(under claude CLAUDECODE=1 -- -- a.sh)
longline=$(printf '%s\n' "$out" | grep 'migration\|wwwww' | head -n 1)
[ -n "$longline" ] && [ "$(printf '%s' "$longline" | LC_ALL=C tr -d '\200-\277' | wc -c)" -lt 400 ] \
    && ok "a 1200-character row is cut under 400 characters" || bad "the long row line is not under 400 characters: ${#longline}"
has "the cut row ends with an ellipsis before the trigger" "$out" "… | trigger: t"
export HIMMEL_CEILINGS_LEDGER="$work/many.tsv"
for i in $(seq 1 25); do add add --file c.sh --anchor c --ceiling "many $i" --trigger t >/dev/null; done
out=$(under claude CLAUDECODE=1 -- -- c.sh)
has "25 rows: the header counts 25" "$out" "CEILINGS: 25 open rows for 1 of 1 touched files"
eq "25 rows: 20 row lines" "$(printf '%s\n' "$out" | grep -c '^C-')" 20
has "25 rows: the more line names the next page" "$out" "+5 more: ceiling-lookup.sh --from 21 -- c.sh"
out=$(under claude CLAUDECODE=1 -- --from 21 -- c.sh)
eq "--from 21: the last 5 row lines" "$(printf '%s\n' "$out" | grep -c '^C-')" 5
has "--from 21: the page starts at the 21st row" "$out" "ceiling: many 21 "
lacks "--from 21: no more line on the last page" "$out" "more:"
has "--from 21: the header still counts every row" "$out" "CEILINGS: 25 open rows"
out=$(under claude CLAUDECODE=1 -- --from 0 -- c.sh)
has "--from 0 is a usage error read as not read" "$out" "CEILINGS: not read (usage: --from"

export HIMMEL_CEILINGS_LEDGER="$work/absent.tsv"
out=$(cd "$fx" && bash "$LOOKUP" --ids "${range[@]}"); rc=$?
eq "no ledger: exit 0" "$rc" 0
has "no ledger: not read" "$out" "CEILINGS: not read (no ledger for"
mkdir -p "$work/unreadable.tsv"
out=$(cd "$fx" && HIMMEL_CEILINGS_LEDGER="$work/unreadable.tsv" bash "$LOOKUP" --ids "${range[@]}"); rc=$?
eq "unreadable ledger: exit 0" "$rc" 0
has "unreadable ledger: not read" "$out" "CEILINGS: not read (ledger unreadable"
printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote\nC-0001\ta.sh\tshort row\n' > "$work/malformed.tsv"
out=$(cd "$fx" && HIMMEL_CEILINGS_LEDGER="$work/malformed.tsv" bash "$LOOKUP" --ids "${range[@]}"); rc=$?
eq "malformed row: exit 0" "$rc" 0
has "malformed row: not read" "$out" "CEILINGS: not read (malformed row at line 2)"
out=$(cd "$fx" && HIMMEL_CEILINGS_LEDGER="$work/many.tsv" bash "$LOOKUP" --ids --range main...no-such-branch); rc=$?
eq "bad range: exit 0" "$rc" 0
eq "bad range: not read" "$out" "CEILINGS: not read (bad range)"

cp "$work/many.tsv" "$work/torn.tsv"
printf 'C-0099\tc.sh\tc\thalf a ro' >> "$work/torn.tsv"
out=$(cd "$fx" && HIMMEL_CEILINGS_LEDGER="$work/torn.tsv" bash "$LOOKUP" --ids -- c.sh)
has "a torn last row: the whole rows are still read" "$out" "CEILINGS: 25 open rows for 1 of 1 touched files"
lacks "a torn last row is left out" "$out" "C-0099"

mkdir -p "$work/locked.tsv.lock"
out=$(cd "$fx" && HIMMEL_CEILINGS_LEDGER="$work/locked.tsv" bash "$ADD" add --file a.sh --anchor do_a --ceiling x --trigger t 2>&1); rc=$?
eq "a lock that cannot be taken exits 2" "$rc" 2
has "the lock failure names the recovery step" "$out" "remove $work/locked.tsv.lock and re-run"

hroot="$work/hroot"
mkdir -p "$hroot/tuser/himmel/specs/ledgers"
cp "$work/many.tsv" "$hroot/tuser/himmel/specs/ledgers/ceilings.tsv"
mkdir -p "$work/adopter" "$work/himmel"
for d in adopter himmel; do
    (cd "$work/$d" && git -c init.defaultBranch=main init -q && git config user.email t@t.test && git config user.name t \
        && git config commit.gpgsign false && printf 'c\n' > c.sh && git add c.sh && git commit -qm c) || bad "bucket fixture $d"
done
bucket_run() { (cd "$work/$1" && env -u HIMMEL_CEILINGS_LEDGER -u HIMMEL_BUCKET_DIR HANDOVER_DIR="$hroot" USER_SLUG=tuser \
    ANTHROPIC_BASE_URL=http://127.0.0.1:8317 ANTHROPIC_MODEL=gpt-6.1-sol bash "$LOOKUP" --ids -- c.sh); }
out=$(bucket_run adopter)
has "an adopter repo reads no himmel row" "$out" "CEILINGS: not read (no ledger for adopter)"
out=$(bucket_run himmel)
has "control: the himmel repo's bucket ledger is read" "$out" "CEILINGS: 25 open rows for 1 of 1 touched files"
lacks "--ids under a claudex env prints no ceiling text" "$out" "many 1"

[ "$fails" -eq 0 ] && { echo "PASS test-ceilings-ledger"; exit 0; }
echo "FAILURES in test-ceilings-ledger: $fails"
exit 1
