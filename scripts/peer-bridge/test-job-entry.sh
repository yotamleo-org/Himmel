#!/usr/bin/env bash
# test-job-entry.sh - the in-guest job contract: job-entry.sh against a fake
# run-shell-tests.sh and a fake clock, then against a real tree at MIN_SHA.
# Bash 3.2-compatible.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
entry="$here/job-entry.sh"
min_sha="$(tr -d '[:space:]' < "$here/min-sha.txt")"
fail=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/job-entry.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
real_mv="$(command -v mv)"
real_date="$(command -v date)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

mkdir -p "$tmp/fixture/scripts/ci" "$tmp/bin"
cat > "$tmp/fixture/scripts/ci/run-shell-tests.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--only-list" ] || exit 2
suite="$(cat "$2")"
printf 'budget=%s ledger=%s suite=%s top=%s\n' "$SUITE_RUN_BUDGET" "${HIMMEL_SUITE_LEDGER:+set}" "$suite" "$(git rev-parse --show-toplevel)" >> "$FAKE_CALLS"
[ -f "$FAKE_RESULT" ] && { jq -e . "$FAKE_RESULT" >/dev/null || echo "unparsable result seen by a reader" >> "$FAKE_CALLS"; }
case "$suite" in
    *kill*) kill -KILL "$PPID"; exit 0 ;;
    *norow*) exit 0 ;;
esac
bash "$suite"; rc=$?
printf '{"v":1,"suite":"%s","rc":%d,"sec":1}\n' "$suite" "$rc" >> "$HIMMEL_SUITE_LEDGER"
EOF
printf 'exit 0\n' > "$tmp/fixture/scripts/test-pass.sh"
printf 'exit 1\n' > "$tmp/fixture/scripts/test-fail.sh"
printf 'exit 0\n' > "$tmp/fixture/scripts/test-norow.sh"
printf 'exit 0\n' > "$tmp/fixture/scripts/test-kill.sh"
cat > "$tmp/fixture/scripts/test-slow.sh" <<'EOF'
echo $(( $(cat "$FAKE_CLOCK") + 700 )) > "$FAKE_CLOCK"
EOF
git -C "$tmp/fixture" init -q
git -C "$tmp/fixture" add -A
git -C "$tmp/fixture" -c user.name=t -c user.email=t@t commit -q -m fixture
fixture_sha="$(git -C "$tmp/fixture" rev-parse HEAD)"

cat > "$tmp/bin/date" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "+%s" ] && [ -n "\${FAKE_CLOCK:-}" ]; then cat "\$FAKE_CLOCK"; else exec "$real_date" "\$@"; fi
EOF
cat > "$tmp/bin/mv" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do last="\$a"; done
case "\$last" in */.job-result.json) if jq -e . "\$1" >/dev/null 2>&1; then echo parsed; else echo torn; fi >> "\$FAKE_MOVES" ;; esac
exec "$real_mv" "\$@"
EOF
chmod +x "$tmp/bin/date" "$tmp/bin/mv"

src_tar() {
    mkdir "$1/src"
    git -C "$1/src" init -q
    git -C "$1/src" fetch -q --depth 1 "file://$2" "$3"
    tar -cf "$1/src.tar" -C "$1/src" .git
    rm -rf "$1/src"
}

n=0
job() {
    n=$((n + 1))
    w="$tmp/job$n"
    mkdir "$w"
    src_tar "$w" "$tmp/fixture" "$fixture_sha"
    : > "$w/calls"; : > "$w/moves"
    echo 1000000 > "$w/clock"
    printf '%s\n' "$@" > "$w/suites.txt"
}
run_job() {
    PATH="$tmp/bin:$PATH" FAKE_CLOCK="$w/clock" FAKE_CALLS="$w/calls" FAKE_MOVES="$w/moves" FAKE_RESULT="$w/.job-result.json" \
        bash "$entry" "$w/suites.txt" "$1"
}
outcomes() { jq -r '[.results[] | "\(.suite)=\(.outcome)"] | join(" ")' "$w/.job-result.json" 2>/dev/null || echo unparsable; }

job scripts/test-pass.sh scripts/test-fail.sh scripts/test-norow.sh
run_job 3600; rc=$?
check "rc 0 after a full run" "$rc" 0
check "rc 0 is pass, other rc is fail, no ledger row is error" "$(outcomes)" "0=pass 1=fail 2=error"
check "minutes is a number" "$(jq -r '.minutes | type' "$w/.job-result.json" 2>/dev/null)" number
check "one run-shell-tests call per suite" "$(wc -l < "$w/calls" | tr -d ' ')" 3
check "SUITE_RUN_BUDGET is the remaining backstop less 600" "$(cut -d' ' -f1 "$w/calls" | sort -u)" budget=3000
check "HIMMEL_SUITE_LEDGER is set for every call" "$(cut -d' ' -f2 "$w/calls" | sort -u)" ledger=set
check "suites run from the checked-out tree" "$(sed 's/.* top=//' "$w/calls" | sort -u)" "$(cd "$w/tree" 2>/dev/null && pwd -P)"
check "the tree is detached at the fetched sha" "$(git -C "$w/tree" rev-parse HEAD 2>/dev/null)" "$fixture_sha"
check "every rewrite moves a complete file into place" "$(sort -u "$w/moves")" parsed
check "a reader between suites always parses" "$(grep -c unparsable "$w/calls")" 0
check "no temp file is left" "$(find "$w" -maxdepth 1 -name '*.tmp' | wc -l | tr -d ' ')" 0
check "the log is in the work dir" "$([ -s "$w/job.log" ] && echo yes)" yes

job scripts/test-slow.sh scripts/test-pass.sh scripts/test-pass.sh
run_job 1359
check "a suite starts only while the budget is at least 60 s" "$(wc -l < "$w/calls" | tr -d ' ')" 1
check "suites after the budget runs out are error" "$(outcomes)" "0=pass 1=error 2=error"

job scripts/test-pass.sh
run_job 659
check "backstop 659 runs nothing" "$(wc -l < "$w/calls" | tr -d ' ')" 0
check "backstop 659 marks every suite error" "$(outcomes)" "0=error"
job scripts/test-pass.sh
run_job 660
check "backstop 660 runs the suite with budget 60" "$(cut -d' ' -f1 "$w/calls")" budget=60

job scripts/test-pass.sh scripts/test-kill.sh scripts/test-pass.sh
run_job 3600; rc=$?
check "a kill mid-suite ends job-entry" "$rc" 137
check "a kill mid-suite keeps the finished suites" "$(outcomes)" "0=pass"

job scripts/test-pass.sh
rm "$w/src.tar"
run_job 3600; rc=$?
check "a missing src.tar exits non-zero" "$([ "$rc" -ne 0 ] && echo yes)" yes
check "a missing src.tar marks every suite error" "$(outcomes)" "0=error"

job scripts/test-pass.sh
bash "$entry" "$w/suites.txt" 12x >/dev/null 2>&1; rc=$?
check "a non-numeric backstop is refused" "$rc" 2
bash "$entry" "$w/nolist.txt" 3600 >/dev/null 2>&1; rc=$?
check "a missing list file is refused" "$rc" 2

w="$tmp/minsha"
mkdir "$w"
src_tar "$w" "$root" "$min_sha"
printf '%s\n' scripts/lib/test-commit-class.sh > "$w/suites.txt"
HOME="$w/home" bash "$entry" "$w/suites.txt" 3600; rc=$?
check "a tree at MIN_SHA runs its own run-shell-tests.sh and ledger" "$rc:$(outcomes)" "0:0=pass"

check "bash -n is clean" "$(bash -n "$entry" 2>&1)" ""
check "no bash 4 features" "$(grep -nE 'declare -[A]|map[f]ile|read[a]rray|\$\{[A-Za-z_][A-Za-z0-9_]*[,^][,^]' "$entry")" ""

[ "$fail" -eq 0 ] && echo "test-job-entry: all passed"
exit "$fail"
