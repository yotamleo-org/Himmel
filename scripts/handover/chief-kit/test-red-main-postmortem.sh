#!/usr/bin/env bash
# PLATFORM GUARD: chief kit, Linux-only; Bash 3.2-compatible.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="${SUT:-$HERE/red-main-postmortem.sh}"
IS="$REPO_ROOT/scripts/cr/impacted-suites.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
contains() {
    if grep -Fq -- "$3" <<< "$2"; then pass "$1"; else fail "$1 (wanted: $3; got: $2)"; fi
}
lacks() {
    if grep -Fq -- "$3" <<< "$2"; then fail "$1 (unwanted: $3; got: $2)"; else pass "$1"; fi
}

W="$(mktemp -d "${TMPDIR:-/tmp}/test-red-main-postmortem.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
FX="$W/repo"
mkdir -p "$FX/scripts/lib" "$W/bin"
git -C "$FX" init -q
git -C "$FX" config user.email t@e
git -C "$FX" config user.name t
for x in a b c; do
    printf '# lib %s\n' "$x" > "$FX/scripts/lib/$x.sh"
    # shellcheck disable=SC2016  # the fixture suite body keeps $d literal
    printf 'bash "$d/lib/%s.sh"\n' "$x" > "$FX/scripts/test-$x.sh"
done
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: base"
base="$(git -C "$FX" rev-parse HEAD)"
printf '# changed\n' >> "$FX/scripts/lib/a.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "fix: touch a (#101)"
printf '# changed\n' >> "$FX/scripts/lib/b.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "fix: touch b (#102)"
head="$(git -C "$FX" rev-parse HEAD)"

cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then cat "$STUB_RUNS"; exit 0; fi
if [ "${1:-}" = run ] && [ "${2:-}" = download ]; then
    id="$3"; dir=""
    echo "$id" >> "$STUB_DIR/dl.log"
    case "${STUB_DL_FAIL:-}" in '') ;; 1 | "$id") echo 'connection reset by peer' >&2; exit 1 ;; esac
    [ -z "${STUB_DL_ABSENT:-}" ] || { echo 'no valid artifacts found to download' >&2; exit 1; }
    while [ "$#" -gt 0 ]; do [ "$1" = -D ] && dir="$2"; shift; done
    [ -f "$STUB_DIR/red-$id" ] && cp "$STUB_DIR/red-$id" "$dir/shard-red-suites.txt"
    exit 0
fi
exit 1
STUB
chmod +x "$W/bin/gh"
unset STUB_DL_FAIL STUB_DL_ABSENT
export STUB_DIR="$W" STUB_RUNS="$W/runs"
export RED_MAIN_GH="$W/bin/gh" RED_MAIN_IMPACTED="$IS" RED_MAIN_REPO="$FX"
export RED_MAIN_MAX_RUNS=3 RED_MAIN_MAX_COMMITS=10
run_sut() { RED_MAIN_STATE="$W/seen" bash "$SUT" 2>/dev/null; echo "$?" > "$W/rc"; }
rc_zero() { [ "$(cat "$W/rc")" = 0 ]; }

printf '900\t%s\tfailure\n899\t%s\tsuccess\n' "$head" "$base" > "$W/runs"

printf 'scripts/test-b.sh\n' > "$W/red-900"
out="$(run_sut)"
contains 'yes: the line names the run, the PR and the suite' "$out" 'red-main run 900 #102 scripts/test-b.sh suite in its impacted list: yes'
lacks 'yes: a PR that did not select the suite gets no line' "$out" '#101'
lacks 'yes: no no-line for a suite some PR selected' "$out" 'impacted list: no'

out="$(run_sut)"
if [ -z "$out" ] && rc_zero; then pass 'a reported run prints nothing on the next call'; else fail "second call printed: $out (rc $(cat "$W/rc"))"; fi

rm -f "$W/seen"
printf 'scripts/test-c.sh\n' > "$W/red-900"
out="$(run_sut)"
contains 'no: the first PR of the range is named' "$out" 'red-main run 900 #101 scripts/test-c.sh suite in its impacted list: no'
contains 'no: the second PR of the range is named' "$out" 'red-main run 900 #102 scripts/test-c.sh suite in its impacted list: no'
lacks 'no: no yes line' "$out" 'impacted list: yes'

rm -f "$W/seen"
printf 'scripts/test-a.sh\nscripts/test-c.sh\n' > "$W/red-900"
out="$(run_sut)"
contains 'mixed: the selected suite reads yes with its PR' "$out" '#101 scripts/test-a.sh suite in its impacted list: yes'
contains 'mixed: the missed suite reads no' "$out" 'scripts/test-c.sh suite in its impacted list: no'

rm -f "$W/seen" "$W/red-900"
out="$(run_sut)"
contains 'unknown: a missing failing-suite list is said, not guessed' "$out" 'red-main run 900 unknown: no failing-suite list'
if grep -Fxq 900 "$W/seen"; then pass 'unknown: the run is marked seen'; else fail 'unknown: run 900 not in the seen file'; fi

rm -f "$W/seen"
printf '900\t%s\tsuccess\n' "$head" > "$W/runs"
out="$(run_sut)"
if [ -z "$out" ] && rc_zero; then pass 'a green main prints nothing'; else fail "green main printed: $out (rc $(cat "$W/rc"))"; fi

printf '900\t%s\tfailure\n899\t%s\tsuccess\n' "$head" "$base" > "$W/runs"
printf 'scripts/test-b.sh\n' > "$W/red-900"
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" -k 1 5 bash "$SUT" --repo >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 2 ]; then pass 'a trailing --repo is a usage error, not a hang'; else fail "trailing --repo exited $rc (124 = hang)"; fi
else
    pass 'a trailing --repo row skipped: no timeout binary to bound it'
fi

rm -f "$W/seen"
out="$(RED_MAIN_MAX_COMMITS=1 run_sut)"
contains 'a range longer than the commit cap says so' "$out" 'red-main run 900 unknown: range holds more than 1 commit'
lacks 'a range longer than the commit cap prints no no-line' "$out" 'impacted list: no'

rm -f "$W/seen"
printf 'scripts/test-c.sh\n' > "$W/red-900"
cat > "$W/bin/is" <<STUB
#!/usr/bin/env bash
case "\$2" in "$head"*) exit 2 ;; esac
exec bash "$IS" "\$@"
STUB
out="$(RED_MAIN_IMPACTED="$W/bin/is" run_sut)"
contains 'a commit whose selection cannot be read leaves the suite unknown' "$out" 'red-main run 900 scripts/test-c.sh unknown'
lacks 'an unchecked PR never lets a no-line print' "$out" 'impacted list: no'

rm -f "$W/seen"
printf 'scripts/test-b.sh\n' > "$W/red-900"
out="$(STUB_DL_FAIL=1 run_sut)"
if [ -z "$out" ] && rc_zero && ! grep -Fxq 900 "$W/seen"; then pass 'a failed artifact download prints nothing and the run is retried'; else fail "transient download failure: out=$out rc=$(cat "$W/rc") seen=$(cat "$W/seen")"; fi
out="$(run_sut)"
contains 'the retry after a failed download reports the run' "$out" 'red-main run 900 #102 scripts/test-b.sh suite in its impacted list: yes'

rm -f "$W/seen" "$W/dl.log"
printf '901\t%s\tfailure\n900\t%s\tfailure\n899\t%s\tsuccess\n' "$head" "$head" "$base" > "$W/runs"
printf 'scripts/test-b.sh\n' > "$W/red-901"
out="$(STUB_DL_FAIL=901 run_sut)"
contains 'a run whose download failed does not hold back the older run' "$out" 'red-main run 900 #102 scripts/test-b.sh suite in its impacted list: yes'
if rc_zero && [ "$(head -n 1 "$W/dl.log")" = 901 ] && ! grep -Fxq 901 "$W/seen" && grep -Fxq 900 "$W/seen"; then pass 'the failed run is tried first, left unseen, and the older run is marked seen'; else fail "download order or seen file wrong: dl=$(cat "$W/dl.log") seen=$(cat "$W/seen")"; fi
rm -f "$W/seen" "$W/dl.log"
out="$(STUB_DL_FAIL=1 run_sut)"
if [ -z "$out" ] && rc_zero && [ "$(wc -l < "$W/dl.log")" -eq 2 ] && ! grep -Fq 9 "$W/seen"; then pass 'when every download fails nothing is reported and nothing is marked seen'; else fail "all-failed downloads: out=$out downloads=$(cat "$W/dl.log") seen=$(cat "$W/seen")"; fi
printf '900\t%s\tfailure\n899\t%s\tsuccess\n' "$head" "$base" > "$W/runs"

rm -f "$W/seen"
out="$( ( exec 9>"$W/seen.lock"; flock -n 9 || { echo LOCKFAIL; exit 3; }; run_sut ) )"
if [ -z "$out" ] && rc_zero && ! grep -Fxq 900 "$W/seen"; then pass 'a second probe while one runs reports nothing and marks nothing'; else fail "probe ran under a held lock: out=$out"; fi

rm -f "$W/seen"
out="$(STUB_DL_ABSENT=1 run_sut)"
contains 'an artifact GitHub reports absent is unknown at once' "$out" 'red-main run 900 unknown: no failing-suite list'
if grep -Fxq 900 "$W/seen"; then pass 'an absent artifact marks the run seen'; else fail 'run 900 not marked seen for an absent artifact'; fi

rm -f "$W/seen"
out="$(RED_MAIN_MAX_COMMITS=08 run_sut)"
contains 'a zero-padded commit cap is read as decimal' "$out" 'red-main run 900 #102 scripts/test-b.sh suite in its impacted list: yes'

if [ "$failures" -gt 0 ]; then printf 'FAIL: %s case(s) failed\n' "$failures"; exit 1; fi
printf 'OK: all red-main-postmortem cases passed\n'
