#!/usr/bin/env bash
# Tests for skillspector-scan.sh — opt-in, advisory SkillSpector Stage 1
# (static, --no-llm) wrapper. Hermetic: SKILLSPECTOR_BIN is a stub, so CI
# needs no pip install and nothing leaves the machine. Cross-platform: bash.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SUT="$TOOLS_DIR/skillspector-scan.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/skillspector-scan-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

[ -f "$SUT" ] && s=ok || s=missing
assert "skillspector-scan.sh exists" ok "$s"
bash -n "$SUT" 2>/dev/null && s=ok || s=fail
assert "skillspector-scan.sh parses" ok "$s"

# Stub skillspector: records its argv and the provider it saw, prints a report.
stub="$tmpdir/skillspector-stub.sh"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_ARGV"
printf '%s\n' "${SKILLSPECTOR_PROVIDER-unset}" > "$STUB_PROVIDER"
if [ -n "${STUB_NET-}" ]; then
    if [ -r /proc/net/dev ]; then awk -F: 'NR>2 {gsub(/ /,"",$1); print $1}' /proc/net/dev | sort | tr '\n' ' ' > "$STUB_NET"; else printf 'no-proc' > "$STUB_NET"; fi
fi
if [ -n "${STUB_REPLAY-}" ]; then cat "$STUB_REPLAY"; else printf '{"risk_assessment":{"score":0},"issues":[]}\n'; fi # read-sink-ok: hermetic test stub, replays a fixture path the test itself set
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"

skill="$tmpdir/skill"
mkdir -p "$skill"
printf '# a skill\n' > "$skill/SKILL.md"

shimbin="$tmpdir/shimbin"
mkdir -p "$shimbin"
cat > "$shimbin/unshare" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_UNSHARE"
while [ "$#" -gt 0 ]; do case "$1" in --) shift; break ;; *) shift ;; esac; done
exec "$@"
EOF
chmod +x "$shimbin/unshare"

run() { # run <report> [env assignments...] -- runs the wrapper hermetically
    local report="$1"; shift
    rm -f "$tmpdir/argv" "$tmpdir/provider" "$tmpdir/unshare"
    env -u SKILLSPECTOR_PROVIDER STUB_ARGV="$tmpdir/argv" STUB_PROVIDER="$tmpdir/provider" \
        STUB_UNSHARE="$tmpdir/unshare" PATH="$shimbin:$PATH" \
        SKILLSPECTOR_BIN="$stub" "$@" bash "$SUT" "$skill" "$report" 2>"$tmpdir/err"
}

# -- Test 1: provider refusal (the default provider sends skill text to a third party)
echo "Test 1: provider refusal"
run "$tmpdir/r1.json"; rc=$?
assert "unset SKILLSPECTOR_PROVIDER is refused (rc 2)" 2 "$rc"
[ -e "$tmpdir/argv" ] && r=ran || r=not-run
assert "unset provider never invokes skillspector" not-run "$r"
[ -e "$tmpdir/r1.json" ] && r=written || r=none
assert "unset provider writes no report" none "$r"

run "$tmpdir/r2.json" SKILLSPECTOR_PROVIDER=nv_build; rc=$?
assert "nv_build provider is refused (rc 2)" 2 "$rc"
[ -e "$tmpdir/argv" ] && r=ran || r=not-run
assert "nv_build never invokes skillspector" not-run "$r"

run "$tmpdir/r3.json" SKILLSPECTOR_PROVIDER=anthropic; rc=$?
assert "an egressing provider (anthropic) is refused (rc 2)" 2 "$rc"

# -- Test 2: a no-egress provider runs Stage 1 only and stores the report
echo "Test 2: ollama runs Stage 1 and stores the report"
run "$tmpdir/r4.json" SKILLSPECTOR_PROVIDER=ollama; rc=$?
assert "ollama provider runs (rc 0)" 0 "$rc"
assert "argv is scan <dir> --no-llm --format json" "scan $skill --no-llm --format json" "$(cat "$tmpdir/argv" 2>/dev/null)"
assert "skillspector saw the no-egress provider" ollama "$(cat "$tmpdir/provider" 2>/dev/null)"
assert "report stored verbatim at the requested path" '{"risk_assessment":{"score":0},"issues":[]}' "$(cat "$tmpdir/r4.json" 2>/dev/null)"

# -- Test 3: the two pilot fixtures, replaying reports captured from a real
#    skillspector 2.12.0 @182a4753 run on the ubuntu_new VM (--no-llm).
echo "Test 3: pilot fixtures replay real reports"
FX="$SCRIPT_DIR/fixtures/skillspector"
for case in "exfil-env:0:score=28 issues=3 high=1" "curl-bash:1:score=73 issues=4 high=3"; do
    name="${case%%:*}"; rest="${case#*:}"; src_rc="${rest%%:*}"; want="${rest#*:}"
    run "$tmpdir/$name.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$FX/reports/$name.json" STUB_RC="$src_rc"; rc=$?
    assert "$name: wrapper rc 0 even when skillspector exits $src_rc (advisory)" 0 "$rc"
    assert "$name: stored report equals the real captured report" "$(cat "$FX/reports/$name.json")" "$(cat "$tmpdir/$name.json" 2>/dev/null)"
    got="$(run "$tmpdir/$name.2.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$FX/reports/$name.json" STUB_RC="$src_rc" | grep -o 'score=[0-9]* issues=[0-9]* high=[0-9]*')"
    assert "$name: summary line counts findings" "$want" "$got"
done
[ -f "$FX/exfil-env/SKILL.md" ] && [ -f "$FX/curl-bash/SKILL.md" ] && r=ok || r=missing
assert "both pilot fixture skills are vendored" ok "$r"

# -- Test 4: unavailable tool and bad usage
echo "Test 4: unavailable tool and usage"
env -u SKILLSPECTOR_PROVIDER SKILLSPECTOR_PROVIDER=ollama SKILLSPECTOR_BIN="$tmpdir/no-such-skillspector" \
    bash "$SUT" "$skill" "$tmpdir/r5.json" 2>/dev/null; rc=$?
assert "missing skillspector binary is unavailable (rc 3)" 3 "$rc"
[ -e "$tmpdir/r5.json" ] && r=written || r=none
assert "unavailable tool writes no report" none "$r"

env -u SKILLSPECTOR_PROVIDER SKILLSPECTOR_PROVIDER=ollama SKILLSPECTOR_BIN="$stub" \
    bash "$SUT" "$tmpdir/not-a-dir" "$tmpdir/r6.json" 2>/dev/null; rc=$?
assert "non-directory skill path is a usage error (rc 1)" 1 "$rc"

env -u SKILLSPECTOR_PROVIDER SKILLSPECTOR_PROVIDER=ollama SKILLSPECTOR_BIN="$stub" \
    bash "$SUT" 2>/dev/null; rc=$?
assert "no arguments is a usage error (rc 1)" 1 "$rc"

# -- Test 5: JSON that is not a scan report must never read as a clean scan
echo "Test 5: a non-report JSON is unavailable, not clean"
n=0
for body in '{"error":"failed"}' '{"risk_assessment":{"score":5}}' '{"issues":[]}' '[]' \
    '{"risk_assessment":{"score":5},"issues":[],"execution_successful":false}' \
    '{"risk_assessment":{"score":5},"issues":[],"analysis_completeness":{"is_complete":false}}'; do
    n=$((n+1))
    printf '%s\n' "$body" > "$tmpdir/bad$n.json"
    run "$tmpdir/rb$n.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$tmpdir/bad$n.json"; rc=$?
    assert "non-report JSON $body is unavailable (rc 3)" 3 "$rc"
    [ -e "$tmpdir/rb$n.json" ] && r=written || r=none
    assert "non-report JSON $body writes no report" none "$r"
done

# -- Test 6: a symlink at the report destination is refused, never followed
echo "Test 6: report destination symlink"
printf 'keep\n' > "$tmpdir/victim"
ln -s "$tmpdir/victim" "$tmpdir/link.json"
run "$tmpdir/link.json" SKILLSPECTOR_PROVIDER=ollama; rc=$?
assert "symlink at the report destination is unavailable (rc 3)" 3 "$rc"
assert "symlink target is left untouched" keep "$(cat "$tmpdir/victim")"

# -- Test 7: Phase 3.7 maps every non-zero wrapper rc to not scanned
echo "Test 7: Phase 3.7 reference rules"
DOC="$SCRIPT_DIR/../references/luna-ingest/phase-3-7-skill-scan.md"
grep -q 'any non-zero wrapper rc' "$DOC" && s=ok || s=missing
assert "Phase 3.7 treats any non-zero wrapper rc as unavailable" ok "$s"
grep -q 'not scanned (rc <n>)' "$DOC" && s=ok || s=missing
assert "Phase 3.7 lists a failed skill as not scanned (rc <n>)" ok "$s"
grep -qF 'skillspector-scan.sh" "' "$DOC" && grep -qF 'skill_tmp" "<vault>' "$DOC" && s=ok || s=missing
assert "Phase 3.7 scans the directory step 3 fills" ok "$s"
grep -qF 'skill_tmp/<skill-slug>' "$DOC" && s=present || s=gone
assert "Phase 3.7 no longer scans an uncreated subdirectory" gone "$s"
grep -q '?ref=<sha>' "$DOC" && s=ok || s=missing
assert "Phase 3.7 fetches contents at the pinned sha" ok "$s"

grep -qF 'truncated' "$DOC" && s=ok || s=missing
assert "Phase 3.7 refuses a truncated tree listing" ok "$s"

# -- Test 8: a scanner crash (rc other than 0 or 1) is unavailable even with valid JSON
echo "Test 8: scanner rc other than 0/1"
printf '%s\n' '{"risk_assessment":{"score":5},"issues":[]}' > "$tmpdir/ok-body.json"
for src_rc in 2 3 127; do
    run "$tmpdir/rc$src_rc.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$tmpdir/ok-body.json" STUB_RC="$src_rc"; rc=$?
    assert "scanner rc $src_rc with valid JSON is unavailable (rc 3)" 3 "$rc"
    [ -e "$tmpdir/rc$src_rc.json" ] && r=written || r=none
    assert "scanner rc $src_rc writes no report" none "$r"
done

# -- Test 9: status fields that are present must be booleans, not strings
echo "Test 9: string status fields"
n=0
for body in '{"risk_assessment":{"score":5},"issues":[],"execution_successful":"false"}' \
    '{"risk_assessment":{"score":5},"issues":[],"analysis_completeness":{"is_complete":"false"}}' \
    '{"risk_assessment":{"score":5},"issues":[],"execution_successful":"true"}'; do
    n=$((n+1))
    printf '%s\n' "$body" > "$tmpdir/str$n.json"
    run "$tmpdir/rs$n.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$tmpdir/str$n.json"; rc=$?
    assert "non-boolean status $body is unavailable (rc 3)" 3 "$rc"
done

# -- Test 10: harvest-clips decides the scan on the original tree URL
echo "Test 10: harvest-clips dispatch uses the pre-canonical url"
HC="$SCRIPT_DIR/../references/harvest-clips/phase-4-dispatch.md"
grep -qF 'pre-canonical' "$HC" && s=ok || s=missing
assert "dispatch decides --skill-scan on the pre-canonical source url" ok "$s"
grep -qF 'canonicalization strips' "$HC" && s=ok || s=missing
assert "dispatch states why the canonical url cannot carry the tree path" ok "$s"

echo "Test 11: the scan runs with the network denied"
run "$tmpdir/n1.json" SKILLSPECTOR_PROVIDER=ollama; rc=$?
assert "wrapper runs (rc 0) through unshare" 0 "$rc"
assert "the scanner is launched in a new user and network namespace" \
    "--user --map-root-user --net -- $stub scan $skill --no-llm --format json" "$(tail -n 1 "$tmpdir/unshare" 2>/dev/null)"

denybin="$tmpdir/denybin"
mkdir -p "$denybin"
printf '#!/usr/bin/env bash\necho "unshare: unshare failed: Operation not permitted" >&2\nexit 1\n' > "$denybin/unshare"
chmod +x "$denybin/unshare"
rm -f "$tmpdir/argv"
env -u SKILLSPECTOR_PROVIDER SKILLSPECTOR_PROVIDER=ollama STUB_ARGV="$tmpdir/argv" STUB_PROVIDER="$tmpdir/provider" \
    PATH="$denybin:$PATH" SKILLSPECTOR_BIN="$stub" bash "$SUT" "$skill" "$tmpdir/n2.json" 2>"$tmpdir/err"; rc=$?
assert "no network namespace on this host is refused (rc 2)" 2 "$rc"
[ -e "$tmpdir/argv" ] && r=ran || r=not-run
assert "no network namespace never invokes skillspector" not-run "$r"
[ -e "$tmpdir/n2.json" ] && r=written || r=none
assert "no network namespace writes no report" none "$r"
grep -qF 'api.osv.dev' "$tmpdir/err" && r=ok || r=missing
assert "the refusal names the api.osv.dev lookup it prevents" ok "$r"

rm -f "$tmpdir/argv" "$tmpdir/net"
env -u SKILLSPECTOR_PROVIDER SKILLSPECTOR_PROVIDER=ollama STUB_ARGV="$tmpdir/argv" STUB_PROVIDER="$tmpdir/provider" \
    STUB_NET="$tmpdir/net" SKILLSPECTOR_BIN="$stub" bash "$SUT" "$skill" "$tmpdir/n3.json" 2>"$tmpdir/err"; rc=$?
if unshare --user --map-root-user --net -- true >/dev/null 2>&1; then
    assert "real namespace: wrapper runs (rc 0)" 0 "$rc"
    assert "real namespace: the scanner sees only loopback" "lo " "$(cat "$tmpdir/net" 2>/dev/null)"
else
    assert "no real namespace: wrapper refuses (rc 2)" 2 "$rc"
    [ -e "$tmpdir/argv" ] && r=ran || r=not-run
    assert "no real namespace: skillspector never runs" not-run "$r"
fi

osv_ex='{"outcome":"partial","phase":"static","reason_code":"analyzer_runtime_error","path":"package-lock.json","fatal":false,"analyzers":["static_patterns_supply_chain_dependencies_analyzer_runtime_error"],"error_class":"ConnectError"}'
ref_ex='{"outcome":"partial","phase":"reference_resolution","reason_code":"reference_missing","path":"SKILL.md","fatal":false}'
other_ex='{"outcome":"partial","phase":"static","reason_code":"static_parse_limit","path":"a.js","fatal":false,"analyzers":["static_patterns_x"]}'
degraded='"limitations":["Analyzer static_patterns_supply_chain status: degraded."]'
offline_body() {
    printf '{"risk_assessment":{"score":24},"issues":[{"severity":"HIGH"}],"execution_successful":true,"analysis_completeness":{"is_complete":false,"status":"partial","execution_successful":true,"partially_inspected_files":%s,"entirely_uninspected_files":0,"ledger_exceptions":[%s],%s}}\n' "$2" "$1" "$3"
}
offline_body "$osv_ex,$ref_ex" 1 "$degraded" > "$tmpdir/osv-ok.json"
out="$(run "$tmpdir/n4.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$tmpdir/osv-ok.json")"; rc=$?
assert "a report whose only gap is the denied OSV lookup is stored (rc 0)" 0 "$rc"
printf '%s' "$out" | grep -qF 'deps=offline-fallback' && r=ok || r=missing
assert "the summary says the dependency lookup used the offline fallback" ok "$r"
out="$(run "$tmpdir/n4b.json" SKILLSPECTOR_PROVIDER=ollama)"
printf '%s' "$out" | grep -qF 'deps=offline-fallback' && r=present || r=absent
assert "a complete report carries no offline-fallback note" absent "$r"

n=0
for bad in "$(offline_body "$osv_ex,$other_ex" 2 "$degraded")" \
    "$(offline_body "$osv_ex" 2 "$degraded")" \
    "$(offline_body "$osv_ex" 1 '"limitations":["Analyzer static_patterns_supply_chain status: degraded.","Analyzer x status: failed."]')" \
    "$(offline_body "${osv_ex/ConnectError/ReadTimeout}" 1 "$degraded")" \
    "$(offline_body "$ref_ex" 0 '"limitations":[]')"; do
    n=$((n+1))
    printf '%s\n' "$bad" > "$tmpdir/osv-bad$n.json"
    run "$tmpdir/nb$n.json" SKILLSPECTOR_PROVIDER=ollama STUB_REPLAY="$tmpdir/osv-bad$n.json"; rc=$?
    assert "incomplete beyond the denied OSV lookup (case $n) is unavailable (rc 3)" 3 "$rc"
done

echo "skillspector-scan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
