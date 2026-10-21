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
if [ -n "${STUB_REPLAY-}" ]; then cat "$STUB_REPLAY"; else printf '{"risk_assessment":{"score":0},"issues":[]}\n'; fi
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"

skill="$tmpdir/skill"
mkdir -p "$skill"
printf '# a skill\n' > "$skill/SKILL.md"

run() { # run <report> [env assignments...] -- runs the wrapper hermetically
    local report="$1"; shift
    rm -f "$tmpdir/argv" "$tmpdir/provider"
    env -u SKILLSPECTOR_PROVIDER STUB_ARGV="$tmpdir/argv" STUB_PROVIDER="$tmpdir/provider" \
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

echo "skillspector-scan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
