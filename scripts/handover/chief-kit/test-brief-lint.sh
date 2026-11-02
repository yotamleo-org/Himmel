#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the ok/bad reporting lines, as in test-headed-arm-worker.sh
# scripts/handover/chief-kit/test-brief-lint.sh - suite for brief-lint.sh
# the arming-time check that a worker or judge brief carries a
# filled `> **Prior art:**` line, plus the headed-arm-worker.sh call site that
# refuses an arming with a failing brief unless --no-prior-art-check is passed.
#
# Asserts:
#   1. A brief with no Prior art line, an empty one, a bare `none` (any case or
#      trailing punctuation), an unfilled `<placeholder>`, or `none found` with
#      no query all FAIL (exit 1, reason on stderr).
#   2. A filled line, `none found (<query>)`, and a multi-line filled field PASS.
#   3. Usage errors exit 2 (no arg, unreadable file).
#   4. headed-arm-worker.sh refuses a template-shaped brief (carries a `> **Contract:**`
#      or `> **Completion condition:**` line) that fails the lint, naming
#      --no-prior-art-check; the flag lets it through; a filled brief passes;
#      a relay or consult launch is not gated; a brief with neither
#      field is gated too (4e).
#   5. a fresh brief with no front-matter `description:` (or the
#      template placeholder) FAILS, naming the field; a doc whose Results already
#      holds a bullet (a resume) passes without one. headed-arm-worker.sh refuses a
#      fresh template-shaped launch with no description, --no-prior-art-check
#      or not, and still resumes a doc that has run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/brief-lint.sh"
WORKER="$HERE/headed-arm-worker.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/brief-lint.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect_rc() { # label want-rc doc
    local rc=0 err
    err="$(bash "$LINT" "$3" 2>&1 >/dev/null)" || rc=$?
    if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$rc want $2): $err"; fi
}
mk_raw() { # name lines...
    local f="$tmp/$1.md"; shift
    printf '%s\n' "$@" > "$f"
}
# A template brief opens with front matter carrying its description.
mk() { # name lines...
    local n="$1"; shift
    mk_raw "$n" '---' 'description: Check the lint on a test brief' '---' "$@"
}

mk none '# brief' '> **Why:** x' '> **Contract:** y'
mk empty '# brief' '> **Prior art:**' '' '> **Contract:** y'
mk empty_sp '# brief' '> **Prior art:**    ' '' '> **Contract:** y'
mk bare_none '# brief' '> **Prior art:** none' '' '> **Contract:** y'
mk bare_None '# brief' '> **Prior art:** None.' '' '> **Contract:** y'
mk bare_NONE '# brief' '> **Prior art:**   NONE  ' '' '> **Contract:** y'
mk placeholder '# brief' '> **Prior art:** <related tickets, prior fixes, graph neighbours, with source>' '' '> **Contract:** y'
mk nf_noq '# brief' '> **Prior art:** none found' '' '> **Contract:** y'
mk nf_emptyq '# brief' '> **Prior art:** none found ()' '' '> **Contract:** y'
mk next_field '# brief' '> **Prior art:**' '> **Contract:** y'
mk empty_then_quote '# brief' '> **Prior art:**' '> ' '> unrelated quoted line' '' '> **Contract:** y'
mk nonepad_then_quote '# brief' '> **Prior art:** none' '>   ' '> unrelated quoted line' '' '> **Contract:** y'
mk filled '# brief' '> **Prior art:** HIMMEL-2581 (graphify non-adoption); fixed in #1500 (qmd jira-himmel)' '' '> **Contract:** y'
mk nf_q '# brief' '> **Prior art:** none found (qmd -c jira-himmel "prior art field")' '' '> **Contract:** y'
mk titled '# brief' '> **Prior art (required, HIMMEL-4573):** HIMMEL-2581 (graphify non-adoption)' '' '> **Contract:** y'
mk titled_bare '# brief' '> **Prior art (required, HIMMEL-4573):** none' '' '> **Contract:** y'
mk nf_ph '# brief' '> **Prior art:** none found (<query>)' '' '> **Contract:** y'
mk multi '# brief' '> **Prior art:**' '> HIMMEL-2581 graphify non-adoption (qmd jira-himmel)' '> #1500 prior fix' '' '> **Contract:** y'
mk first_none_then_more '# brief' '> **Prior art:** none' '> HIMMEL-1 is related' '' '> **Contract:** y'

expect_rc "1a no field fails" 1 "$tmp/none.md"
expect_rc "1b empty fails" 1 "$tmp/empty.md"
expect_rc "1c whitespace-only fails" 1 "$tmp/empty_sp.md"
expect_rc "1d bare none fails" 1 "$tmp/bare_none.md"
expect_rc "1e bare None. fails" 1 "$tmp/bare_None.md"
expect_rc "1f bare NONE fails" 1 "$tmp/bare_NONE.md"
expect_rc "1g unfilled placeholder fails" 1 "$tmp/placeholder.md"
expect_rc "1h none found without a query fails" 1 "$tmp/nf_noq.md"
expect_rc "1i none found () fails" 1 "$tmp/nf_emptyq.md"
expect_rc "1j empty line followed directly by the next field fails" 1 "$tmp/next_field.md"
expect_rc "1k none found (<query>) placeholder fails" 1 "$tmp/nf_ph.md"
expect_rc "1l titled field with a bare none fails" 1 "$tmp/titled_bare.md"
expect_rc "1m whitespace-only quote line ends the field, so an empty field fails" 1 "$tmp/empty_then_quote.md"
expect_rc "1n bare none then a whitespace-only quote line then unrelated text fails" 1 "$tmp/nonepad_then_quote.md"
expect_rc "2e template-titled field (required, ticket) passes" 0 "$tmp/titled.md"
expect_rc "2a filled passes" 0 "$tmp/filled.md"
expect_rc "2b none found (query) passes" 0 "$tmp/nf_q.md"
expect_rc "2c multi-line filled passes" 0 "$tmp/multi.md"
expect_rc "2d none then a continuation line passes (field is non-empty)" 0 "$tmp/first_none_then_more.md"

rc=0; bash "$LINT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "3a no arg exits 2" || bad "3a no arg exits 2 (rc=$rc)"
rc=0; bash "$LINT" "$tmp/does-not-exist.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "3b unreadable file exits 2" || bad "3b unreadable file exits 2 (rc=$rc)"

# 4. Launcher call site. --dry-run exits before any launch, so no stubs needed;
# the gate must run before the dry-run exit. A fixed preflight stub keeps the
# bank state out of it.
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$tmp/preflight.sh"; chmod +x "$tmp/preflight.sh"
mk tmpl_bad '# brief' '> **Why:** x' '> **Contract:** y' '## Results'
mk tmpl_bad_judge '# brief' '> **Completion condition:** z' '## Results'
mk tmpl_ok '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' '> **Contract:** y' '## Results'
mk_raw fixture_plain '# fixture brief' '## Results'
mk_raw fixture_plain_ok '---' 'description: a plain fixture brief' '---' '# fixture brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' '## Results'
run_worker() { # doc args...
    local doc="$1"; shift
    HEADED_ARM_WORKER_PREFLIGHT="$tmp/preflight.sh" WORKER_SESSION_REPO="$tmp" \
        bash "$WORKER" --dry-run "$@" "HIMMEL-9999-x" "$doc" "$tmp/signal" 9999999999 "$tmp/log" claude-sonnet-5-5 2>&1
}
rc=0; out="$(run_worker "$tmp/tmpl_bad.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--no-prior-art-check'; } \
    && ok "4a failing template brief is refused, flag named" || bad "4a failing template brief is refused (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/tmpl_bad_judge.md" --judge)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--no-prior-art-check'; } \
    && ok "4b failing judge brief is refused" || bad "4b failing judge brief is refused (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/tmpl_bad.md" --profile worker-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "4c --no-prior-art-check lets it through" || bad "4c --no-prior-art-check (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/tmpl_ok.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "4d filled template brief passes" || bad "4d filled template brief (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fixture_plain.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--no-prior-art-check'; } \
    && ok "4e a brief with no Contract/Completion field and no Prior art is refused (HIMMEL-4619)" || bad "4e field-less brief is refused (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fixture_plain.md" --profile worker-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "4e2 --no-prior-art-check lets a field-less brief through" || bad "4e2 field-less brief with the flag (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fixture_plain_ok.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "4e3 a field-less brief with a Prior art line and description arms (control)" || bad "4e3 field-less brief with Prior art (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/tmpl_bad.md" --relay)" || rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q -- 'no-prior-art-check'; } && ok "4f relay launch is not gated" || bad "4f relay launch is not gated (rc=$rc): $out"

# 5. description field.
PA='> **Prior art:** none found (qmd -c jira-himmel "x")'
mk_raw desc_none '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk_raw desc_ph '---' 'description: <one plain-language line: what this worker is doing and why>' '---' '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk_raw desc_resumed '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)' '- 10:00 LIVE — started'
expect_rc "5a fresh brief with no description fails" 1 "$tmp/desc_none.md"
err="$(bash "$LINT" "$tmp/desc_none.md" 2>&1 >/dev/null)"
grep -q 'description:' <<< "$err" && ok "5b the failure names the description: field" || bad "5b the failure names the description: field: $err"
grep -q 'first line' <<< "$err" && ok "5b2 the failure says the '---' must be the first line" || bad "5b2 the failure does not name the first-line rule: $err"
expect_rc "5c placeholder description fails" 1 "$tmp/desc_ph.md"
expect_rc "5d a resumed doc (Results bullet) passes without a description" 0 "$tmp/desc_resumed.md"
rc=0; out="$(run_worker "$tmp/desc_none.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'description:' <<< "$out"; } \
    && ok "5e launcher refuses a fresh brief with no description" || bad "5e launcher refuses a fresh brief with no description (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/desc_none.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'description:' <<< "$out"; } \
    && ok "5f --no-prior-art-check does not bypass the description refusal" || bad "5f --no-prior-art-check bypassed the description refusal (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/desc_resumed.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "5g launcher resumes a doc that has run without a description" || bad "5g launcher resume of a pre-description doc (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/desc_none.md" --relay)" || rc=$?
[ "$rc" -eq 0 ] && ok "5h relay launch is not gated on a description" || bad "5h relay launch gated on a description (rc=$rc): $out"

# 6. Every brief template the launcher gates, filled the way a chief fills it
#    (each `<placeholder>` replaced), launches: a template that lacks a field the
#    gates require would refuse every brief written from it.
DOCS="$HERE/../../../docs/handover"
fill_template() { # template out
    awk '/^```markdown$/ { inb = 1; next } inb && /^```$/ { exit } inb' "$1" \
        | sed -E 's/<[^>]*>/filled/g; s/<[^>]*$/filled/; s/^> \*\*Writes:\*\*.*/> **Writes:** scripts\/fixture.sh/' > "$2"
}
fill_template "$DOCS/worker-brief-template.md" "$tmp/filled_worker.md"
fill_template "$DOCS/judge-brief-template.md" "$tmp/filled_judge.md"
grep -Eq '^> \*\*(Contract|Completion condition):\*\*' "$tmp/filled_worker.md" \
    && grep -Eq '^> \*\*(Contract|Completion condition):\*\*' "$tmp/filled_judge.md" \
    && ok "6a both filled templates are template-shaped (gated)" || bad "6a a filled template is not gate-shaped"
rc=0; out="$(run_worker "$tmp/filled_worker.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "6b a filled worker-brief-template launches" || bad "6b filled worker-brief-template refused (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/filled_judge.md" --judge)" || rc=$?
[ "$rc" -eq 0 ] && ok "6c a filled judge-brief-template launches" || bad "6c filled judge-brief-template refused (rc=$rc): $out"

# 7. Writes is a path list; prose belongs on Writes note.
mk writes_paren "$PA" '> **Writes:** scripts/x/a.sh (no scripts/lib file until the chief rules)'
mk writes_word "$PA" '> **Writes:** scripts/x/a.sh and scripts/x/b.sh'
mk writes_wrapped_word "$PA" '> **Writes:** scripts/x/a.sh' '> no scripts/lib/'
mk writes_paths "$PA" "> **Writes:** \`scripts/x/a.sh\`, scripts/x/ README.md .gitignore new-file.sh"
mk writes_note "$PA" '> **Writes:** scripts/x/a.sh' '> **Writes note:** no scripts/lib file until the chief rules (read only)'
mk writes_none "$PA" '> **Writes:** none named' '> **Writes note:** scripts/lib/ is not a write'
mk writes_empty "$PA" '> **Writes:**' '> **Writes note:** scripts/lib/ is not a write'
expect_rc "7i an empty Writes is refused until the chief fills it" 1 "$tmp/writes_empty.md"
err="$(bash "$LINT" "$tmp/writes_empty.md" 2>&1 >/dev/null)"
grep -q 'chief' <<< "$err" && ok "7j an empty Writes refusal tells the chief to fill it" || bad "7j empty Writes refusal lacks chief hint: $err"
expect_rc "7a a parenthetical on Writes is refused" 1 "$tmp/writes_paren.md"
expect_rc "7b a non-path word on Writes is refused" 1 "$tmp/writes_word.md"
expect_rc "7c prose on a Writes continuation is refused" 1 "$tmp/writes_wrapped_word.md"
expect_rc "7d a path-only Writes line passes" 0 "$tmp/writes_paths.md"
expect_rc "7e prose on Writes note passes" 0 "$tmp/writes_note.md"
expect_rc "7f explicit none named passes" 0 "$tmp/writes_none.md"
for unsafe_path in 'scripts/lib/../config-ui/panel.ts' 'scripts/./x/a.sh' "$tmp/outside.sh"; do
    mk writes_unsafe "$PA" "> **Writes:** $unsafe_path"
    expect_rc "7k non-canonical Writes path is refused: $unsafe_path" 1 "$tmp/writes_unsafe.md"
done
mk writes_dotted "$PA" '> **Writes:** .github/workflows/check.yml scripts/.hidden/file.sh'
expect_rc "7l dotted names without dot segments still pass" 0 "$tmp/writes_dotted.md"
mkdir -p "$tmp/state"
mk writes_state "$PA" "> **Writes:** $tmp/state/specs/design.md"
HANDOVER_DIR="$tmp/state" expect_rc "7m normalized absolute state path passes" 0 "$tmp/writes_state.md"
mkdir -p "$tmp/outside"
ln -s "$tmp/outside" "$tmp/state/link"
mk writes_state_symlink "$PA" "> **Writes:** $tmp/state/link/spec.md"
HANDOVER_DIR="$tmp/state" expect_rc "7r absolute state symlink escaping the root is refused" 1 "$tmp/writes_state_symlink.md"
rc=0; out="$(HANDOVER_DIR="$tmp/state" run_worker "$tmp/writes_state.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "7s launcher preserves the configured state root for absolute Writes" || bad "7s launcher lost the configured state root (rc=$rc): $out"
mkdir -p "$tmp/dotenv-repo" || exit 1
git init -q "$tmp/dotenv-repo" || exit 1
printf 'HANDOVER_DIR=%s\n' "$tmp/state" > "$tmp/dotenv-repo/.env" || exit 1
rc=0; out="$(cd "$tmp/dotenv-repo" && env -u HANDOVER_DIR HOME="$tmp/dotenv-repo" HIMMEL_CONFIG_DIR="$tmp/dotenv-repo/no-config" HIMMELCTL_CACHE_DIR="$tmp/dotenv-repo/no-cache" bash "$LINT" "$tmp/writes_state.md" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok "7t absolute state Writes uses the dotenv-only root" || bad "7t dotenv-only root was not loaded (rc=$rc): $out"
HANDOVER_DIR="$tmp/missing-state" expect_rc "7o relative Writes needs no state root" 0 "$tmp/writes_paths.md"
HANDOVER_DIR="$tmp/missing-state" expect_rc "7p older brief needs no state root" 0 "$tmp/filled.md"
HANDOVER_DIR="$tmp/missing-state" expect_rc "7q absolute Writes without a resolvable state root is refused" 1 "$tmp/writes_state.md"
for unsafe_state_path in "$tmp/state-other/specs/design.md" "$tmp/state/../outside.md" "$tmp/state//specs/design.md"; do
    mk writes_state_unsafe "$PA" "> **Writes:** $unsafe_state_path"
    HANDOVER_DIR="$tmp/state" expect_rc "7n noncanonical or outside state path is refused: $unsafe_state_path" 1 "$tmp/writes_state_unsafe.md"
done
err="$(bash "$LINT" "$tmp/writes_paren.md" 2>&1 >/dev/null)"
grep -Fq '> **Writes note:**' <<< "$err" && ok "7g refusal names Writes note as the replacement" || bad "7g refusal lacks Writes note hint: $err"
rc=0; out="$(run_worker "$tmp/writes_word.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -ne 0 ] && grep -Fq '> **Writes note:**' <<< "$out"; } && ok "7h launcher refuses prose Writes with the fix hint" || bad "7h launcher accepted prose Writes (rc=$rc): $out"

# 8. The core gate's brief-lint half: every brief whose title names ticket keys is checked, whatever its shape, whether or
# not it has run. A key core-check answers NOT-CORE or BYPASS for passes; UNKNOWN refuses; CORE passes only when
# spec-check answers SPEC ok for it. A line the brief writes itself (Spec:, Core gate:) passes nothing. The CLI is a
# fixture stand-in over a fixture mirror (the real dist/ is untracked, absent in CI); the rows run in CI.
mkdir -p "$tmp/cg-mirror" "$tmp/cg-stub" "$tmp/cg-signed" "$tmp/no-dist"
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$tmp/cg-mirror/.cursor.json"
cg_ticket() { # <KEY> <type> <priority>
    printf -- '---\nkey: "%s"\nstatus: "To Do"\ntype: "%s"\npriority: "%s"\nlabels: []\n---\n# %s: t\n' "$1" "$2" "$3" "$1" > "$tmp/cg-mirror/$1.md"
}
cg_ticket HIMMEL-9411 Task Medium   # core Writes, no spec
cg_ticket HIMMEL-9412 Task Medium   # core Writes, no spec (second key of a pair)
cg_ticket HIMMEL-9413 Task Medium   # core Writes, signed
cg_ticket HIMMEL-9414 Bug Medium    # a Bug: core-check answers BYPASS
printf -- '---\nkey: "HIMMEL-9415"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: ["core"]\n---\n# HIMMEL-9415: t\n' > "$tmp/cg-mirror/HIMMEL-9415.md"   # core by its label
printf -- '---\nkey: "HIMMEL-9416"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: []\n---\n# HIMMEL-9416: t\n\nEdit scripts/handover/chief-kit/go.sh to change the GO path.\n' > "$tmp/cg-mirror/HIMMEL-9416.md"   # core by the path its own body names
cg_ticket HIMMEL-9417 Task Medium   # names no path
printf '/state/specs/spec.md O-R1-9413\n' > "$tmp/cg-signed/HIMMEL-9413"
cat > "$tmp/cg-stub/index.js" <<'STUBEOF'
const fs = require('fs');
const a = process.argv.slice(2);
const opt = (n) => { const i = a.indexOf(n); return i < 0 ? null : a[i + 1]; };
const mirror = opt('--mirror');
const ticket = (k) => {
  let t;
  try { t = fs.readFileSync(mirror + '/' + k + '.md', 'utf8'); } catch (e) { return null; }
  const f = (n) => ((t.match(new RegExp('^' + n + ': (.*)$', 'm')) || [])[1] || '').replace(/"/g, '');
  return { type: f('type'), labels: f('labels') };
};
if (a[0] === 'release' && a[1] === 'core-check') {
  const hit = (opt('--paths') || '').split(',').filter(Boolean).find((p) => /^(scripts\/handover\/|marketplace\/plugins\/himmel-bus\/)/.test(p));
  for (const k of a.slice(a.indexOf('--key') + 1)) {
    const t = ticket(k);
    if (!t) console.log('UNKNOWN ' + k);
    else if (t.type === 'Bug') console.log('BYPASS ' + k + ' bug a Bug is not gated');
    else if (hit) console.log('CORE ' + k + ' ' + hit);
    else if (t.labels.includes('core')) console.log('CORE ' + k + ' label core');
    else console.log('NOT-CORE ' + k);
  }
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  let missing = 0;
  for (const k of a.slice(a.indexOf('--mirror') + 2)) {
    let r = '';
    try { r = fs.readFileSync(process.env.BRIEF_LINT_TEST_SIGNED + '/' + k, 'utf8').trim(); } catch (e) { missing = 1; }
    console.log(r ? 'SPEC ok ' + k + ' ' + r : 'NO-SPEC ' + k);
  }
  process.exit(missing);
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUBEOF
export BRIEF_LINT_MIRROR="$tmp/cg-mirror" BRIEF_LINT_JIRA_CLI="$tmp/cg-stub/index.js" BRIEF_LINT_TEST_SIGNED="$tmp/cg-signed"
CORE_W='> **Writes:** scripts/handover/chief-kit/next-dispatchable.sh'
mk core_none '# HIMMEL-9411 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
mk core_signed '# HIMMEL-9413 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
mk core_self_gate '# HIMMEL-9411 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '> **Core gate:** HIMMEL-9411 bypass=design — written by the brief itself' '## Results (newest at the bottom)'
mk core_self_spec '# HIMMEL-9411 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '> **Spec:** HIMMEL-9411 /state/specs/spec.md (O-R1-9411)' '## Results (newest at the bottom)'
mk core_docs '# HIMMEL-9411 — a docs fix' "$PA" '> **Contract:** y' '> **Writes:** docs/internals/x.md' '## Results (newest at the bottom)'
mk core_ran '# HIMMEL-9411 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)' '- 10:00 LIVE — started'
mk bug_ran '# HIMMEL-9414 — a bug fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)' '- 10:00 LIVE — started'
mk core_judge '# HIMMEL-9411 — a core review' "$PA" '> **Completion condition:** z' "$CORE_W" '## Results (newest at the bottom)'
mk core_nocontract '# HIMMEL-9411 — a core fix' "$PA" "$CORE_W" '## Results (newest at the bottom)'
mk core_unknown '# HIMMEL-9499 — a core fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
mk core_pair '# HIMMEL-9413 + HIMMEL-9412 — a core pair' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
expect_rc "8a a core build brief with no signed spec is refused (exit 3)" 3 "$tmp/core_none.md"
err="$(bash "$LINT" "$tmp/core_none.md" 2>&1 >/dev/null)"
grep -Fq 'core brief HIMMEL-9411 is core' <<< "$err" && grep -Fq 'no signed minerva spec' <<< "$err" \
    && ok "8a2 the refusal names the key and the missing spec" || bad "8a2 refusal text: $err"
! grep -Eq 'Spec:|Core gate|bypass=' <<< "$err" && ok "8a3 the refusal names no line that would make it pass" || bad "8a3 refusal names a passing line: $err"
expect_rc "8b a core brief whose key spec-check answers SPEC ok passes" 0 "$tmp/core_signed.md"
expect_rc "8c a self-written Core gate: bypass= line passes nothing" 3 "$tmp/core_self_gate.md"
expect_rc "8d a self-written Spec: line passes nothing when spec-check says NO-SPEC" 3 "$tmp/core_self_spec.md"
expect_rc "8e a non-core brief (docs-only Writes) passes" 0 "$tmp/core_docs.md"
expect_rc "8f a Results bullet does not exempt a core key" 3 "$tmp/core_ran.md"
expect_rc "8f2 a doc that has run passes when core-check answers BYPASS for its key" 0 "$tmp/bug_ran.md"
expect_rc "8g a judge brief naming a core key is gated too" 3 "$tmp/core_judge.md"
expect_rc "8g2 a keyed brief with no Contract line is gated too" 3 "$tmp/core_nocontract.md"
expect_rc "8h a key the mirror lacks is refused, never passed" 3 "$tmp/core_unknown.md"
expect_rc "8h2 every title key is checked: a signed first key does not carry an unsigned second" 3 "$tmp/core_pair.md"
err="$(bash "$LINT" "$tmp/core_pair.md" 2>&1 >/dev/null)"
grep -Fq 'HIMMEL-9412' <<< "$err" && ! grep -Fq 'brief HIMMEL-9413 is core' <<< "$err" \
    && ok "8h3 the refusal names only the unsigned key" || bad "8h3 refusal text: $err"
rc=0; bash "$LINT" --core-only "$tmp/core_none.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h4 --core-only runs the core rule" || bad "8h4 --core-only on a core brief (rc=$rc)"
rc=0; bash "$LINT" --core-only "$tmp/none.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "8h5 --core-only skips the prior-art check" || bad "8h5 --core-only on a keyless no-prior-art brief (rc=$rc)"
# a brief with no usable Writes path is classified by the paths its ticket names in the mirror, never as no path at all
mk nw_label '# HIMMEL-9415 — core by label' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk nw_ticket '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk nw_none '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '> **Writes:** none named' '## Results (newest at the bottom)'
mk nw_prose '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '> **Writes:** see the ticket' '## Results (newest at the bottom)'
mk nw_clean '# HIMMEL-9417 — names no path' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk nw_two '# HIMMEL-9411 — a second Writes line holds the core path' "$PA" '> **Contract:** y' '> **Writes:** docs/handover/running-a-chief.md' '> **Writes:** scripts/handover/chief-kit/next-dispatchable.sh' '## Results (newest at the bottom)'
expect_rc "8h6 a core-labelled key with no Writes line is a core refusal" 3 "$tmp/nw_label.md"
expect_rc "8h7 a key core by its ticket's own paths, no Writes line, is a core refusal" 3 "$tmp/nw_ticket.md"
expect_rc "8h8 a 'none named' Writes line falls back to the ticket's paths" 3 "$tmp/nw_none.md"
rc=0; bash "$LINT" --core-only "$tmp/nw_prose.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h9 --core-only: a prose Writes line falls back to the ticket's paths" || bad "8h9 --core-only prose Writes (rc=$rc)"
expect_rc "8h10 a key that names no core path passes without a Writes line" 0 "$tmp/nw_clean.md"
expect_rc "8h11 every Writes line is read, not the first" 3 "$tmp/nw_two.md"
rc=0; bash "$LINT" --core-only "$tmp/nw_ticket.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h12 --core-only resolves the same paths" || bad "8h12 --core-only no Writes (rc=$rc)"
# a BYPASS is printed and logged beside the brief, once
mk byp '# HIMMEL-9414 — a bug fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
rm -f "$tmp/core-gate.jsonl"
err="$(bash "$LINT" "$tmp/byp.md" 2>&1 >/dev/null)"; bash "$LINT" "$tmp/byp.md" >/dev/null 2>&1
{ grep -Fq 'bypass=bug' <<< "$err" && [ "$(grep -c '"outcome": "bypass"' "$tmp/core-gate.jsonl")" -eq 1 ] && grep -Fq '"key": "HIMMEL-9414"' "$tmp/core-gate.jsonl"; } \
    && ok "8h13 a BYPASS prints bypass=<class> and logs one core-gate.jsonl row" || bad "8h13 bypass log: $err"
# the launcher: --no-prior-art-check skips only the prior-art check; the core refusal stands and does not suggest the flag
rc=0; out="$(run_worker "$tmp/core_none.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'core brief HIMMEL-9411 is core' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "8i the launcher refuses a core brief without suggesting --no-prior-art-check" || bad "8i launcher core refusal (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/core_none.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'core brief HIMMEL-9411 is core' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "8i2 --no-prior-art-check does not skip the core gate" || bad "8i2 --no-prior-art-check skipped the core gate (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/core_signed.md" --profile worker-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "8i3 --no-prior-art-check still launches a signed core brief" || bad "8i3 signed core brief with the flag (rc=$rc): $out"
rc=0; bash "$LINT" --judge "$tmp/core_none.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "8i6 brief-lint --judge skips the core rule" || bad "8i6 --judge on a core brief (rc=$rc)"
rc=0; out="$(run_worker "$tmp/core_none.md" --judge)" || rc=$?
{ [ "$rc" -eq 0 ] && ! grep -Fq 'is core' <<< "$out"; } \
    && ok "8i7 the launcher's --judge launches a judge brief naming a core key" || bad "8i7 launcher --judge on a core key (rc=$rc): $out"
mk core_emptywrites '# HIMMEL-9417 — names no path' "$PA" '> **Contract:** y' '> **Writes:**' '## Results (newest at the bottom)'
rc=0; out="$(run_worker "$tmp/core_emptywrites.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'Writes' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "8i4 an empty Writes line refusal does not offer --no-prior-art-check" || bad "8i4 empty Writes hint (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/core_emptywrites.md" --profile worker-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "8i5 --no-prior-art-check launches a keyed brief whose ticket names no core path" || bad "8i5 empty Writes with the flag (rc=$rc): $out"
export BRIEF_LINT_JIRA_CLI="$tmp/no-dist/index.js"
expect_rc "8j an absent dist/ is CORE-CHECK-FAILED, not a pass" 3 "$tmp/core_none.md"
err="$(bash "$LINT" "$tmp/core_none.md" 2>&1 >/dev/null)"
grep -Fq 'CORE-CHECK-FAILED: build the jira CLI (npm --prefix' <<< "$err" \
    && ok "8j2 the refusal names the build command" || bad "8j2 refusal text: $err"
printf '// valid JavaScript that exits 0 and prints no verdict line\n' > "$tmp/junk.js"
BRIEF_LINT_JIRA_CLI="$tmp/junk.js" expect_rc "8k a core-check that prints no verdict line is CORE-CHECK-FAILED" 3 "$tmp/core_none.md"
printf "const a = process.argv.slice(2);\nif (a[1] === 'core-check') console.log('CORE ' + a[a.indexOf('--key') + 1] + ' x'); else console.log('junk');\n" > "$tmp/junk-spec.js"
BRIEF_LINT_JIRA_CLI="$tmp/junk-spec.js" expect_rc "8k2 a spec-check that prints no verdict line is CORE-CHECK-FAILED" 3 "$tmp/core_none.md"
BRIEF_LINT_JIRA_CLI="$tmp/no-dist/index.js" expect_rc "8l a brief with no ticket key in its title never asks the CLI" 0 "$tmp/tmpl_ok.md"
unset BRIEF_LINT_MIRROR BRIEF_LINT_JIRA_CLI BRIEF_LINT_TEST_SIGNED

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
