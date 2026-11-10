#!/usr/bin/env bash
# scripts/handover/test-suite-coverage.sh — Covers suite-coverage.sh:
# fixture runner for each verdict branch, then the real run-shell-tests.sh for
# the three suites the ticket names.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/suite-coverage.sh"
REAL="$HERE/../ci/run-shell-tests.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/suite-coverage.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
# expect <desc> <ere> <actual> [want-rc]: verdict text AND, when given, exit status ($rc of the call just made)
expect() {
  if ! grep -Eq -- "$2" <<< "$3"; then bad "$1" "$3"
  elif [ -n "${4:-}" ] && [ "${rc:-}" != "$4" ]; then bad "$1 (rc=${rc:-?}, want $4)" "$3"
  else pass "$1"; fi
}

cat > "$tmp/runner.sh" <<'EOF'
SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-600}" 600)
_suite_timeout_for() {
  case "${1#./}" in
    scripts/slow/test-slow.sh|*/scripts/slow/test-slow.sh)
      printf '1700' ;;
    *)
      printf '%s' "$SUITE_TIMEOUT" ;;
  esac
}
SKIP_LIST="
scripts/vm/test-vm.sh  # drives a real VM over SSH
scripts/big/test-big.sh  # superseded by its two --only wrappers below: test-big-fast.sh and test-big-slow.sh
"
SUITE_TIER_DEFAULT="
scripts/slow/test-slow.sh  extended  # measured 843s
"
EOF

out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/vm/test-vm.sh 2>&1); rc=$?
expect "SKIP_LIST suite is uncovered, never verified" 'not run in CI.*uncovered' "$out" 0
mkdir -p "$tmp/scripts/big"; : > "$tmp/scripts/big/test-big-fast.sh"; : > "$tmp/scripts/big/test-big-slow.sh"
out=$(bash "$SC" --runner "$tmp/runner.sh" --root "$tmp" scripts/big/test-big.sh 2>&1); rc=$?
expect "superseded suite names its wrappers" 'superseded by .*test-big-fast.sh.*test-big-slow.sh' "$out" 0
# a wrapper that is missing, or itself in SKIP_LIST, carries no coverage
rm "$tmp/scripts/big/test-big-slow.sh"
out=$(bash "$SC" --runner "$tmp/runner.sh" --root "$tmp" scripts/big/test-big.sh 2>&1); rc=$?
expect "superseded by a missing wrapper is uncovered" 'uncovered.*test-big-slow.sh \(missing\)' "$out" 0
if grep -q 'carry the coverage' <<< "$out"; then bad "missing wrapper must not claim the coverage" "$out"; else pass "missing wrapper claims no coverage"; fi
: > "$tmp/scripts/big/test-big-slow.sh"
sed 's|^scripts/vm/test-vm.sh .*|&\
scripts/big/test-big-slow.sh  # skipped too|' "$tmp/runner.sh" > "$tmp/runner-skipwrap.sh"
out=$(bash "$SC" --runner "$tmp/runner-skipwrap.sh" --root "$tmp" scripts/big/test-big.sh 2>&1); rc=$?
expect "superseded by a SKIP_LIST wrapper is uncovered" 'uncovered.*test-big-slow.sh \(in SKIP_LIST\)' "$out" 0
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
expect "extended tier is nightly only with its cap" 'nightly only.*1700' "$out" 0
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/plain/test-plain.sh 2>&1); rc=$?
expect "unlisted suite runs in PR CI" 'runs in PR CI' "$out" 0
out=$(bash "$SC" --runner "$tmp/runner.sh" ./scripts/vm/test-vm.sh 2>&1); rc=$?
expect "./-spelled path matches" 'not run in CI' "$out" 0
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/vm/pre-test-vm.sh 2>&1); rc=$?
expect "suffix match respects the / boundary" 'runs in PR CI' "$out" 0
sed 's/SUITE_TIMEOUT:-600}" 600)/SUITE_TIMEOUT:-777}" 777)/' "$tmp/runner.sh" > "$tmp/runner-777.sh"
out=$(bash "$SC" --runner "$tmp/runner-777.sh" scripts/plain/test-plain.sh 2>&1); rc=$?
expect "cap reads the runner's own default, not a hardcoded 600" 'runs in PR CI \(cap 777s\)' "$out" 0
bash "$SC" --runner "$tmp/none.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "missing runner exits 2"; else bad "missing runner exits 2"; fi

# shellcheck source=../lib/timeout-bin.sh
. "$HERE/../lib/timeout-bin.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
  "$_TIMEOUT_BIN" 5 bash "$SC" scripts/x/test-x.sh --runner >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then pass "trailing --runner without a value exits 2 (no hang)"; else bad "trailing --runner without a value exits 2 (rc=$rc)"; fi
else
  echo "SKIP: trailing --runner no-hang row (no timeout binary)"
fi
out=$(bash "$SC" scripts/nope/test-nonexistent.sh 2>&1); rc=$?
expect "real: a nonexistent suite is unknown, not 'runs in PR CI'" 'unknown' "$out" 3
if [ "$rc" -eq 3 ]; then pass "unknown suite exits 3"; else bad "unknown suite exits 3 (rc=$rc)"; fi
out=$(bash "$SC" scripts/handover/suite-coverage.sh 2>&1); rc=$?
expect "real: an existing non-test file is unknown" 'unknown' "$out" 3
# a runner with SKIP_LIST and the cap function but no SUITE_TIER_DEFAULT table is unintelligible
awk '/^SUITE_TIER_DEFAULT="/ {skip=1} !skip {print} skip && /^"$/ {skip=0}' "$tmp/runner.sh" > "$tmp/no-tier.sh"
bash "$SC" --runner "$tmp/no-tier.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "runner without a SUITE_TIER_DEFAULT table exits 2"; else bad "runner without a SUITE_TIER_DEFAULT table exits 2 (rc=$rc)"; fi
# an unterminated table swallows the rest of the runner: unparseable, not merely long
sed '/^SUITE_TIER_DEFAULT="/,$ {/^"$/d}' "$tmp/runner.sh" > "$tmp/open-tier.sh"
bash "$SC" --runner "$tmp/open-tier.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "unterminated SUITE_TIER_DEFAULT table exits 2"; else bad "unterminated SUITE_TIER_DEFAULT table exits 2 (rc=$rc)"; fi
printf 'not a runner\n'> "$tmp/junk.sh"
bash "$SC" --runner "$tmp/junk.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "incompatible runner exits 2"; else bad "incompatible runner exits 2 (rc=$rc)"; fi

# The runner is data, never executed. Hostile shell in the cap function
# body or the default line must not run, and the cap still comes from the data.
cat > "$tmp/hostile.sh" <<EOF
SUITE_TIMEOUT=\$(_suite_num SUITE_TIMEOUT "\${SUITE_TIMEOUT:-600}" 600)
_suite_timeout_for() {
  touch "$tmp/pwned-body"
  case "\${1#./}" in
    scripts/slow/test-slow.sh|*/scripts/slow/test-slow.sh)
      printf '1700' ;;
    *)
      printf '%s' "\$SUITE_TIMEOUT" ;;
  esac
}
$(sed -n '/^SKIP_LIST="/,$p' "$tmp/runner.sh")
EOF
out=$(bash "$SC" --runner "$tmp/hostile.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
if [ -e "$tmp/pwned-body" ]; then bad "runner function body is never executed"; else pass "runner function body is never executed"; fi
expect "hostile body still yields the data cap" 'nightly only.*1700' "$out" 0
# the shape the old helper really evaluated: the default line, with a command substitution
sed "s|^SUITE_TIMEOUT=.*|SUITE_TIMEOUT=\$(_suite_num SUITE_TIMEOUT \"\$(touch $tmp/pwned-default)\" 600)|" "$tmp/runner.sh" > "$tmp/hostile-default.sh"
out=$(bash "$SC" --runner "$tmp/hostile-default.sh" scripts/plain/test-plain.sh 2>&1); rc=$?
if [ -e "$tmp/pwned-default" ]; then bad "runner default line is never executed"; else pass "runner default line is never executed"; fi
expect "hostile default line is unreadable, exit 2" 'no readable' "$out" 2
# an unrecognised default line or arm shape fails visibly, never a guessed cap
# shellcheck disable=SC2016 # a literal replacement line for the fixture runner
sed 's|^SUITE_TIMEOUT=.*|SUITE_TIMEOUT=$(whatever)|' "$tmp/runner.sh" > "$tmp/bad-default.sh"
out=$(bash "$SC" --runner "$tmp/bad-default.sh" scripts/plain/test-plain.sh 2>&1); rc=$?
expect "unparseable default timeout exits 2" 'no readable' "$out" 2
sed "s|printf '1700' ;;|printf '%s' \"\$(id -u)\" ;;|" "$tmp/runner.sh" > "$tmp/bad-arm.sh"
out=$(bash "$SC" --runner "$tmp/bad-arm.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
expect "unparseable cap arm exits 2" 'unrecognised line' "$out" 2

# mk_runner <file> <case-body>: a fixture runner whose Linux case holds exactly <case-body>.
# shellcheck disable=SC2016 # literal runner source lines
mk_runner() {
  { echo 'SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-600}" 600)'
    echo '_suite_timeout_for() {'; echo '  case "${1#./}" in'; printf '%s\n' "$2"; echo '  esac'; echo '}'
    sed -n '/^SKIP_LIST="/,$p' "$tmp/runner.sh"; } > "$1"
}
H='    scripts/slow/test-slow.sh|*/scripts/slow/test-slow.sh)'
B="      printf '1700' ;;"
# shellcheck disable=SC2016
STAR=$'    *)\n      printf \'%s\' "$SUITE_TIMEOUT" ;;'
# rejects <desc> <case-body> <message-ere>: the helper must exit 2 with THAT message and never answer a cap
rejects() {
  mk_runner "$tmp/shape.sh" "$2"
  out=$(bash "$SC" --runner "$tmp/shape.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && grep -Eq -- "$3" <<< "$out" && ! grep -q 'cap [0-9]' <<< "$out"; then pass "$1"; else bad "$1 (rc=$rc)" "$out"; fi
}
# accepts <desc> <ere> <case-body>
accepts() {
  mk_runner "$tmp/shape.sh" "$3"
  out=$(bash "$SC" --runner "$tmp/shape.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
  expect "$1" "$2" "$out" 0
}
rejects "one-line arm fails, not the default" "$H printf '1700' ;;"$'\n'"$STAR" 'unrecognised line'
rejects "header with a trailing comment fails" "$H  # why"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "header at other indentation fails" "      scripts/slow/test-slow.sh|*/scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "continued pattern list fails" "    scripts/slow/test-slow.sh|"$'\n'"    */scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "an empty trailing alternative fails" "    scripts/slow/test-slow.sh|)"$'\n'"$B"$'\n'"$STAR" 'empty alternative'
rejects "an empty leading alternative fails" "    |scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'empty alternative'
rejects "an empty middle alternative fails" "    scripts/slow/test-slow.sh||*/scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'empty alternative'
rejects "quoted arm pattern fails" '    "scripts/slow/test-slow.sh")'$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "leading-paren arm fails" "    (scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "spaced alternation fails" "    scripts/slow/test-slow.sh | */scripts/slow/test-slow.sh)"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "an arm with an extra body command fails" "$H"$'\n'"      sleep 1"$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "a * arm with another body fails" "$H"$'\n'"$B"$'\n'"    *)"$'\n'"      printf '%s' \"\$FOO\" ;;" 'unrecognised line'
rejects "a non-* arm answering SUITE_TIMEOUT fails" "$H"$'\n'"      printf '%s' \"\$SUITE_TIMEOUT\" ;;"$'\n'"$STAR" 'only the \* arm may answer'
rejects "a case with no * arm fails" "$H"$'\n'"$B" 'no complete case table'
rejects "an unsupported conditional fails" "$H"$'\n'"      if [ -n \"\${X:-}\" ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR" 'unsupported condition'
# one-line elif and a sequence of two conditionals are not the single if/else shape
rejects "a one-line elif fails" "$H"$'\n'"      if [ \"\${X:-all}\" = fast ]; then printf '1800'; elif [ \"\${Y:-all}\" = fast ]; then printf '3600'; else printf '10800'; fi ;;"$'\n'"$STAR" 'unrecognised line'
rejects "a sequence of two conditionals fails" "$H"$'\n'"      if [ \"\${X:-all}\" = fast ]; then printf '1800'; else printf '3600'; fi; if [ \"\${Y:-all}\" = fast ]; then printf '1'; else printf '10800'; fi ;;"$'\n'"$STAR" 'unrecognised line'
rejects "an && condition fails" "$H"$'\n'"      if [ \"\${X:-a}\" = a ] && [ \"\${Y:-b}\" = c ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR" 'unsupported condition'
rejects "an uppercase condition literal fails" "$H"$'\n'"      if [ \"\${X:-FAST}\" = FAST ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR" 'unsupported condition'
rejects "a tab-indented header fails" $'\tscripts/slow/test-slow.sh)'$'\n'"$B"$'\n'"$STAR" 'unrecognised line'
rejects "CRLF line endings fail" "$H"$'\r\n'"$B"$'\r\n'"$STAR" 'unrecognised line'
rejects "a * header with another pattern may not answer the default" "$H"$'\n'"$B"$'\n'"    *|scripts/x/test-x.sh)"$'\n'"      printf '%s' \"\$SUITE_TIMEOUT\" ;;" 'only the \* arm may answer'
# a case that never closes is unreadable
mk_runner "$tmp/noesac.sh" "$H"$'\n'"$B"$'\n'"$STAR"
sed '/^  esac$/d' "$tmp/noesac.sh" > "$tmp/noesac2.sh"
out=$(bash "$SC" --runner "$tmp/noesac2.sh" scripts/slow/test-slow.sh 2>&1); rc=$?
if [ "$rc" -eq 2 ] && ! grep -q 'cap [0-9]' <<< "$out"; then pass "a case with no esac fails"; else bad "a case with no esac fails (rc=$rc)" "$out"; fi
accepts "a * arm literal is read" 'cap 777s' "    scripts/other/test-other.sh)"$'\n'"      printf '5' ;;"$'\n'"    *)"$'\n'"      printf '777' ;;"
accepts "conditional true by default takes its then branch" 'cap 9000s' "$H"$'\n'"      if [ \"\${X:-fast}\" = fast ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR"
accepts "conditional false by default takes the smaller else branch" 'cap 1700s' "$H"$'\n'"      if [ \"\${X:-all}\" = fast ] || [ \"\${Y:-}\" = fast ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR"
accepts "a true later alternative makes the condition true" 'cap 9000s' "$H"$'\n'"      if [ \"\${X:-all}\" = fast ] || [ \"\${Y:-fast}\" = fast ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR"
accepts "a true third alternative makes the condition true" 'cap 9000s' "$H"$'\n'"      if [ \"\${X:-a}\" = b ] || [ \"\${Y:-a}\" = c ] || [ \"\${Z:-fast}\" = fast ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR"
accepts "a true first alternative stays true after a false last one" 'cap 9000s' "$H"$'\n'"      if [ \"\${X:-fast}\" = fast ] || [ \"\${Y:-all}\" = fast ]; then printf '9000'; else printf '1700'; fi ;;"$'\n'"$STAR"
accepts "a comment mentioning printf is skipped" 'cap 1700s' "$H"$'\n'"      # was printf '9999' once"$'\n'"$B"$'\n'"$STAR"
accepts "a trailing comment after ;; is read" 'cap 1700s' "$H"$'\n'"      printf '1700' ;;  # measured"$'\n'"$STAR"

out=$(bash "$SC" --runner "$REAL" scripts/test-install-symmetry-vm.sh 2>&1); rc=$?
expect "real: install-symmetry-vm not run in CI" 'not run in CI' "$out" 0
out=$(bash "$SC" --runner "$REAL" scripts/handover/test-arm-resume.sh 2>&1); rc=$?
expect "real: arm-resume superseded by both wrappers" 'superseded by .*test-arm-resume-fast.sh.*test-arm-resume-1879.sh' "$out" 0
out=$(bash "$SC" --runner "$REAL" scripts/handover/test-arm-resume-1879.sh 2>&1); rc=$?
expect "real: arm-resume-1879 runs with a 1700s cap" '1700' "$out" 0
out=$(bash "$SC" --runner "$REAL" scripts/eval/guard-corpus/test-guard-corpus.sh 2>&1); rc=$?
expect "real: guard-corpus takes the unset-environment branch, 10800s" 'cap 10800s' "$out" 0
out=$(bash "$SC" --runner "$REAL" scripts/handover/test-suite-coverage.sh 2>&1); rc=$?
expect "real: an unlisted suite gets the runner's 600s default" 'runs in PR CI \(cap 600s\)' "$out" 0
out=$(bash "$SC" --runner "$REAL" scripts/hooks/test-block-destructive-commands-b.sh 2>&1); rc=$?
expect "real: the [abcd] bracket glob matches, 1200s" 'cap 1200s' "$out" 0

# C1/C2: a scripts/testing SKIP_LIST entry runs in PR CI through the ci-quick claude-startup group; any other entry stays uncovered
sed 's|^scripts/vm/test-vm.sh .*|&\
scripts/testing/test-a.sh  # reason\
scripts/foo/test-b.sh  # reason|' "$tmp/runner.sh" > "$tmp/runner-ct.sh"
out=$(bash "$SC" --runner "$tmp/runner-ct.sh" scripts/testing/test-a.sh 2>&1); rc=$?
expect "C1 a scripts/testing SKIP_LIST entry runs in PR CI (claude-startup group)" '^scripts/testing/test-a.sh: runs in PR CI \(ci-quick claude-startup group\)$' "$out" 0
out=$(bash "$SC" --runner "$tmp/runner-ct.sh" scripts/foo/test-b.sh 2>&1); rc=$?
expect "C2 any other SKIP_LIST entry is still not run in CI" '^scripts/foo/test-b.sh: not run in CI \(SKIP_LIST\)' "$out" 0

# C3: on the real tree the entries given the claude-startup verdict are exactly the recorder's --expected set
exp="$(bash "$HERE/../ci/claude-startup-row.sh" --expected 2>&1)"; erc=$?
if [ "$erc" -eq 0 ] && [ -n "$exp" ]; then pass "C3 --expected exits 0 with a non-empty set"; else bad "C3 --expected exits 0 with a non-empty set (rc=$erc)" "$exp"; fi
all_skip="$(awk '$0 == "SKIP_LIST=\"" {on=1; next} on && $0 == "\"" {exit} on {sub(/#.*/, ""); if (NF) print $1}' "$REAL")"
# shellcheck disable=SC2086 # one path per word, none holds a space
cov="$(bash "$SC" --runner "$REAL" $all_skip 2>&1 | sed -n 's/: runs in PR CI (ci-quick claude-startup group)$//p' | LC_ALL=C sort)"
if [ -n "$cov" ] && [ "$cov" = "$(printf '%s\n' "$exp" | LC_ALL=C sort)" ]; then pass "C3 suite-coverage's claude-startup set equals --expected"; else bad "C3 suite-coverage's claude-startup set equals --expected" "suite-coverage: $(printf '%s' "$cov" | tr '\n' ' ') | expected: $(printf '%s' "$exp" | tr '\n' ' ')"; fi

[ "$fail" -eq 0 ] && echo "PASS: suite-coverage" || echo "FAIL: suite-coverage"
exit "$fail"
