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
export UNGUARDED_LAUNCH_OK=1  # HIMMEL-9026: scratch fixtures; guard rows drop it
unset CLAUDE_GLM_CONFIG_DIR  # the classifier reads it for its claude-glm lists: an inherited one would redirect every row
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
# A template brief opens with front matter carrying its description and the absolute directory its worker starts in.
CW_HIM="$tmp/cwd-himmel"; git init -q "$CW_HIM"; mkdir -p "$CW_HIM/scripts/handover/chief-kit"; : > "$CW_HIM/scripts/handover/chief-kit/headed-arm-worker.sh"
mk() { # name lines...
    local n="$1"; shift
    mk_raw "$n" '---' 'description: Check the lint on a test brief' "resume_cwd: $CW_HIM" '---' "$@"
}

# A worker brief (a `> **Contract:**` line) carries the search directive as a continuation of its Prior art field.
# shellcheck disable=SC2016  # the backticks are literal brief text, not command substitution
DIR_LINE='> Before you design, run `bash /x/scripts/lib/qmd-bounded.sh query -c jira-himmel "lint"` (tickets and PRs) and `bash /x/scripts/lib/qmd-bounded.sh query -c luna "lint"` (specs, audits and decisions), and `bash scripts/graphify/worker-graph.sh explain "brief-lint"`, and cite what each returned. Your Results carry a `graph-qmd: <what each returned and whether used>` bullet, or `graph-qmd: n/a, shipping` on a resume that only ships.'

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
mk filled '# brief' '> **Prior art:** HIMMEL-2581 (graphify non-adoption); fixed in #1500 (qmd jira-himmel)' "$DIR_LINE" '' '> **Contract:** y'
mk nf_q '# brief' '> **Prior art:** none found (qmd -c jira-himmel "prior art field")' "$DIR_LINE" '' '> **Contract:** y'
mk titled '# brief' '> **Prior art (required, HIMMEL-4573):** HIMMEL-2581 (graphify non-adoption)' "$DIR_LINE" '' '> **Contract:** y'
mk titled_bare '# brief' '> **Prior art (required, HIMMEL-4573):** none' '' '> **Contract:** y'
mk nf_ph '# brief' '> **Prior art:** none found (<query>)' '' '> **Contract:** y'
mk multi '# brief' '> **Prior art:**' '> HIMMEL-2581 graphify non-adoption (qmd jira-himmel)' '> #1500 prior fix' "$DIR_LINE" '' '> **Contract:** y'
mk first_none_then_more '# brief' '> **Prior art:** none' '> HIMMEL-1 is related' "$DIR_LINE" '' '> **Contract:** y'

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
mk tmpl_ok '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' "$DIR_LINE" '> **Contract:** y' '## Results'
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
PA='> **Prior art:** none found (qmd -c jira-himmel "x")'$'\n'"$DIR_LINE"
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
        | sed -E 's/<[^>]*>/filled/g; s/<[^>]*$/filled/; s/^> \*\*Writes:\*\*.*/> **Writes:** scripts\/fixture.sh/; s|^resume_cwd: filled$|resume_cwd: '"$CW_HIM"'|' > "$2"
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
# 6b and 6c pass whether or not the placeholder is quoted: put `a: b` inside its quotes and parse the line.
tmpl_desc_parsed() { # template: the description line with `a: b` in the placeholder's place, parsed as YAML
    grep -m1 '^description:' "$1" | sed -E 's/^(description: ")[^"]*(")$/\1a: b\2/' \
        | python3 -I -c 'import sys,yaml; print(yaml.safe_load(sys.stdin.read())["description"],end="")' 2>/dev/null || printf 'PARSE-ERROR'
}
[ "$(tmpl_desc_parsed "$DOCS/worker-brief-template.md")" = "a: b" ] && ok "6d the worker template's description placeholder is quoted" || bad "6d worker template description placeholder is not double-quoted: $(tmpl_desc_parsed "$DOCS/worker-brief-template.md")"
[ "$(tmpl_desc_parsed "$DOCS/judge-brief-template.md")" = "a: b" ] && ok "6e the judge template's description placeholder is quoted" || bad "6e judge template description placeholder is not double-quoted: $(tmpl_desc_parsed "$DOCS/judge-brief-template.md")"

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
printf -- '---\nkey: "HIMMEL-9418"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: ["core"]\n---\n# HIMMEL-9418: t\n\nWrite the design in docs/x.md only.\n' > "$tmp/cg-mirror/HIMMEL-9418.md"   # core by label, its body names only a docs path
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
  const paths = (opt('--paths') || '').split(',').filter(Boolean);
  const abs = paths.find((p) => p.startsWith('/'));
  if (abs) { console.error('release core-check: --paths takes repository-relative paths; ' + abs + ' is absolute'); process.exit(1); }
  const hit = paths.find((p) => /^(scripts\/handover\/|marketplace\/plugins\/himmel-bus\/)/.test(p));
  const design = a.includes('--docs-only') && paths.length > 0 && paths.every((p) => p.startsWith('docs/') || p.endsWith('.md'));
  for (const k of a.slice(a.indexOf('--key') + 1)) {
    const t = ticket(k);
    if (!t) console.log('UNKNOWN ' + k);
    else if (t.type === 'Bug') console.log('BYPASS ' + k + ' bug a Bug is not gated');
    else if (hit) console.log('CORE ' + k + ' ' + hit);
    else if (t.labels.includes('core')) console.log(design ? 'BYPASS ' + k + ' design core by label only, docs-only leg' : 'CORE ' + k + ' label core');
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
} else if (a[0] === 'release' && a[1] === 'bucket-check') {
  if (process.env.BRIEF_LINT_TEST_LOG) fs.appendFileSync(process.env.BRIEF_LINT_TEST_LOG, a.join(' ') + '\n');
  for (const k of a.slice(a.indexOf('--mirror') + 2)) {
    let v = '';
    try { v = fs.readFileSync((process.env.BRIEF_LINT_TEST_BUCKET || '') + '/' + k, 'utf8').trim(); } catch (e) { v = ''; }
    if (v === 'EXIT1') { console.error('stub jira: bucket-check failed'); process.exit(1); }
    if (v === 'NOLINE') continue;
    if (v === 'SLEEP') { setTimeout(() => console.log('IN ' + k), 8000); continue; }
    console.log(v || 'IN ' + k + ' current=v1.1.3 via=mirror');
  }
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
# the path list is holds.py's parser (a parenthetical is not a write there); the shape lint stays raw, so the prose is still refused
mk core_paren '# HIMMEL-9411 — a core fix' "$PA" '> **Contract:** y' '> **Writes:** scripts/handover/chief-kit/next-dispatchable.sh (see the ticket)' '## Results (newest at the bottom)'
expect_rc "8e2 a prose token on a Writes line is still refused, whatever path list holds.py reads" 1 "$tmp/core_paren.md"
# a broken holds.py must not fail the core check: the path list falls back to the raw split of the Writes text
KIT8="$tmp/kit8/scripts/handover"; mkdir -p "$KIT8"; cp -r "$HERE" "$KIT8/chief-kit"; ln -s "$HERE/../../lib" "$tmp/kit8/scripts/lib"
printf 'raise RuntimeError("broken")\n' > "$KIT8/chief-kit/holds.py"
rc=0; bash "$KIT8/chief-kit/brief-lint.sh" "$tmp/core_docs.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "8e3 a broken holds.py: a docs-only brief still passes the core check" || bad "8e3 broken holds.py docs brief rc=$rc want 0"
rc=0; bash "$KIT8/chief-kit/brief-lint.sh" "$tmp/core_none.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8e4 a broken holds.py: a core brief with no spec is still refused as core (exit 3)" || bad "8e4 broken holds.py core brief rc=$rc want 3"
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
mk nw_dot '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '> **Writes:** see ticket. v1.2' '## Results (newest at the bottom)'
mk nw_clean '# HIMMEL-9417 — names no path' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk nw_two '# HIMMEL-9411 — a second Writes line holds the core path' "$PA" '> **Contract:** y' '> **Writes:** docs/handover/running-a-chief.md' '> **Writes:** scripts/handover/chief-kit/next-dispatchable.sh' '## Results (newest at the bottom)'
expect_rc "8h6 a core-labelled key with no Writes line is a core refusal" 3 "$tmp/nw_label.md"
expect_rc "8h7 a key core by its ticket's own paths, no Writes line, is a core refusal" 3 "$tmp/nw_ticket.md"
expect_rc "8h8 a 'none named' Writes line falls back to the ticket's paths" 3 "$tmp/nw_none.md"
rc=0; bash "$LINT" --core-only "$tmp/nw_prose.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h9 --core-only: a prose Writes line falls back to the ticket's paths" || bad "8h9 --core-only prose Writes (rc=$rc)"
expect_rc "8h10 a key that names no core path passes without a Writes line" 0 "$tmp/nw_clean.md"
expect_rc "8h11 every Writes line is read, not the first" 3 "$tmp/nw_two.md"
rc=0; bash "$LINT" --core-only "$tmp/nw_dot.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h14 prose with a dot ('ticket.', 'v1.2') is no path and falls back to the ticket's paths" || bad "8h14 dotted prose Writes (rc=$rc)"
rc=0; bash "$LINT" --core-only "$tmp/nw_ticket.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8h12 --core-only resolves the same paths" || bad "8h12 --core-only no Writes (rc=$rc)"
# an absolute handover-root Writes path is a non-core Writes path, never an argument to the CLI (core.ts refuses absolute --paths)
mk abs_plain '# HIMMEL-9417 — absolute state Writes' "$PA" '> **Contract:** y' "> **Writes:** $tmp/state/specs/design.md" '## Results (newest at the bottom)'
mk abs_design '# HIMMEL-9415 — a design leg by label' "$PA" '> **Contract:** y' "> **Writes:** $tmp/state/specs/design.md" '## Results (newest at the bottom)'
mk abs_core '# HIMMEL-9411 — absolute state plus a core path' "$PA" '> **Contract:** y' "> **Writes:** $tmp/state/specs/design.md scripts/handover/chief-kit/next-dispatchable.sh" '## Results (newest at the bottom)'
mk abs_outside '# HIMMEL-9416 — an absolute path outside the root is no path' "$PA" '> **Contract:** y' '> **Writes:** /etc/passwd' '## Results (newest at the bottom)'
HANDOVER_DIR="$tmp/state" expect_rc "8m1 a keyed brief with an absolute handover-root Writes path passes on an unlabelled ticket" 0 "$tmp/abs_plain.md"
HANDOVER_DIR="$tmp/state" expect_rc "8m2 an absolute .md under the root on a core-labelled ticket is a design leg (rc 0)" 0 "$tmp/abs_design.md"
err="$(HANDOVER_DIR="$tmp/state" bash "$LINT" "$tmp/abs_design.md" 2>&1 >/dev/null)"
grep -Fq 'bypass=design' <<< "$err" && ok "8m3 the design bypass is printed" || bad "8m3 design bypass: $err"
HANDOVER_DIR="$tmp/state" expect_rc "8m4 an absolute path beside a core repo path gives a core refusal" 3 "$tmp/abs_core.md"
err="$(HANDOVER_DIR="$tmp/state" bash "$LINT" "$tmp/abs_core.md" 2>&1 >/dev/null)"
{ grep -Fq 'is core' <<< "$err" && ! grep -Fq 'CORE-CHECK-FAILED' <<< "$err"; } && ok "8m5 the refusal says core, not CORE-CHECK-FAILED" || bad "8m5 refusal text: $err"
rc=0; HANDOVER_DIR="$tmp/state" bash "$LINT" --core-only "$tmp/abs_outside.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "8m6 --core-only: an absolute path outside the root is no path, the ticket's own paths decide (core)" || bad "8m6 outside absolute (rc=$rc)"
rc=0; HANDOVER_DIR="$tmp/state" bash "$LINT" --core-only "$tmp/abs_design.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "8m7 --core-only resolves the handover root too" || bad "8m7 --core-only absolute Writes (rc=$rc)"
# docs_only comes from the brief's raw Writes tokens only: never from a filtered or ticket-derived path list
mk dn_ticket '# HIMMEL-9418 — core by label, no Writes line, body names only docs/x.md' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk dn_unknown '# HIMMEL-9415 — core by label, a code file beside a docs path' "$PA" '> **Contract:** y' '> **Writes:** docs/a.md setup.py' '## Results (newest at the bottom)'
mk dn_docs '# HIMMEL-9415 — core by label, a docs-only leg' "$PA" '> **Contract:** y' '> **Writes:** docs/a.md' '## Results (newest at the bottom)'
expect_rc "8n1 no Writes line on a core-labelled ticket naming only docs/x.md is not a design leg" 3 "$tmp/dn_ticket.md"
expect_rc "8n2 'docs/a.md setup.py' on a core-labelled ticket is not a design leg" 3 "$tmp/dn_unknown.md"
expect_rc "8n3 a docs-only Writes line on a core-labelled ticket is a design leg (control)" 0 "$tmp/dn_docs.md"
# a minerva design leg: the `> **Design leg:** minerva` line plus Writes confined to state-repo specs/ files launches on a
# core NO-SPEC key; the fixture ticket is core both by its label and by the core path its own body names
printf -- '---\nkey: "HIMMEL-9419"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: ["core"]\n---\n# HIMMEL-9419: t\n\nEdit scripts/handover/chief-kit/go.sh to add a guard.\n' > "$tmp/cg-mirror/HIMMEL-9419.md"
DL='> **Design leg:** minerva'
mk dl_specs '# HIMMEL-9419 — minerva spec + plan' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/design/HIMMEL-9419-x.md specs/plans/HIMMEL-9419-x.md' '## Results (newest at the bottom)'
mk dl_build '# HIMMEL-9419 — the build' "$PA" '> **Contract:** y' '> **Writes:** scripts/handover/chief-kit/go.sh' '## Results (newest at the bottom)'
mk dl_core '# HIMMEL-9419 — marker on a core build' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/design/HIMMEL-9419-x.md scripts/handover/chief-kit/go.sh' '## Results (newest at the bottom)'
mk dl_code '# HIMMEL-9419 — marker on a code write' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/design/HIMMEL-9419-x.md setup.py' '## Results (newest at the bottom)'
mk dl_nomark '# HIMMEL-9419 — specs Writes, no marker' "$PA" '> **Contract:** y' '> **Writes:** specs/design/HIMMEL-9419-x.md specs/plans/HIMMEL-9419-x.md' '## Results (newest at the bottom)'
mk dl_abs '# HIMMEL-9419 — absolute bucket specs' "$PA" '> **Contract:** y' "$DL" "> **Writes:** $tmp/state/u/r/specs/design/HIMMEL-9419-x.md" '## Results (newest at the bottom)'
expect_rc "8q1 a minerva design leg writing only state-repo specs/ files launches on a core NO-SPEC key" 0 "$tmp/dl_specs.md"
err="$(bash "$LINT" "$tmp/dl_specs.md" 2>&1 >/dev/null)"
grep -Fq 'HIMMEL-9419 bypass=design' <<< "$err" && ok "8q1b the design leg is shown and logged as bypass=design" || bad "8q1b design-leg bypass line: $err"
expect_rc "8q2 a build brief on the same key is still refused NO-SPEC (control)" 3 "$tmp/dl_build.md"
expect_rc "8q3 the marker on a brief that also writes a core repo path is refused" 3 "$tmp/dl_core.md"
err="$(bash "$LINT" "$tmp/dl_code.md" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 3 ] && grep -Fq 'design leg' <<< "$err" && grep -Fq 'setup.py' <<< "$err"; } \
    && ok "8q4 the marker on a brief that writes any repo file is refused, naming the file" || bad "8q4 marker plus repo code (rc=$rc): $err"
expect_rc "8q5 specs/ Writes without the marker are no design leg: the ticket's own paths decide (core)" 3 "$tmp/dl_nomark.md"
HANDOVER_DIR="$tmp/state" expect_rc "8q6 the marker with an absolute specs/ path under the handover root launches" 0 "$tmp/dl_abs.md"
# each row isolates one clause of the state-repo specs/ test: a .md token that fails only that clause is refused by name
dl_refused() { # label doc token [--core-only]
    local err rc=0
    err="$(bash "$LINT" ${4:+"$4"} "$2" 2>&1 >/dev/null)" || rc=$?
    { [ "$rc" -eq 3 ] && grep -Fq 'design leg' <<< "$err" && grep -Fq -- "$3" <<< "$err"; } && ok "$1" || bad "$1 (rc=$rc): $err"
}
mk dl_repomd '# HIMMEL-9419 — marker on a repo .md' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/design/HIMMEL-9419-x.md marketplace/plugins/himmel-bus/SKILL.md' '## Results (newest at the bottom)'
mk dl_dotdot '# HIMMEL-9419 — marker on a specs/ traversal' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/../scripts/HIMMEL-9419-x.md' '## Results (newest at the bottom)'
mk dl_dot '# HIMMEL-9419 — marker on a specs/ dot segment' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs/./HIMMEL-9419-x.md' '## Results (newest at the bottom)'
mk dl_empty '# HIMMEL-9419 — marker on a specs/ empty segment' "$PA" '> **Contract:** y' "$DL" '> **Writes:** specs//HIMMEL-9419-x.md' '## Results (newest at the bottom)'
mk dl_absout '# HIMMEL-9419 — absolute bucket file outside specs/' "$PA" '> **Contract:** y' "$DL" "> **Writes:** $tmp/state/u/r/HIMMEL-9419-x.md" '## Results (newest at the bottom)'
dl_refused "8q7 the marker beside a repo .md file outside specs/ is refused, naming it" "$tmp/dl_repomd.md" 'marketplace/plugins/himmel-bus/SKILL.md'
# the full lint refuses a . or .. segment first; --core-only (a launch with --no-prior-art-check) reaches the core rule alone
dl_refused "8q8 --core-only: the marker on a specs/ path with a .. segment is refused" "$tmp/dl_dotdot.md" 'specs/../scripts/HIMMEL-9419-x.md' --core-only
dl_refused "8q9 --core-only: the marker on a specs/ path with a . segment is refused" "$tmp/dl_dot.md" 'specs/./HIMMEL-9419-x.md' --core-only
dl_refused "8q10 the marker on a specs/ path with an empty segment is refused" "$tmp/dl_empty.md" 'specs//HIMMEL-9419-x.md'
HANDOVER_DIR="$tmp/state" dl_refused "8q11 the marker on an absolute bucket .md outside specs/ is refused" "$tmp/dl_absout.md" "$tmp/state/u/r/HIMMEL-9419-x.md"
# a relative token is a path only when it reads as a repo file: n/a and and/or name nothing
mk na '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '> **Writes:** n/a' '## Results (newest at the bottom)'
mk andor '# HIMMEL-9416 — core by its own body' "$PA" '> **Contract:** y' '> **Writes:** and/or' '## Results (newest at the bottom)'
expect_rc "8o1 'Writes: n/a' falls back to the ticket's paths (core)" 3 "$tmp/na.md"
expect_rc "8o2 'Writes: and/or' falls back to the ticket's paths (core)" 3 "$tmp/andor.md"
# a BYPASS that cannot be recorded is a refusal, and the launcher shows the bypass it passes
mkdir -p "$tmp/unwritable"
mk unwritable '# HIMMEL-9414 — a bug fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
cp "$tmp/unwritable.md" "$tmp/unwritable/unwritable.md"; mkdir -p "$tmp/unwritable/core-gate.jsonl"
expect_rc "8p1 a bypass row that cannot be written is a refusal (rc 3)" 3 "$tmp/unwritable/unwritable.md"
rc=0; out="$(run_worker "$tmp/unwritable/unwritable.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'not written' <<< "$out"; } && ok "8p2 the launcher refuses a bypass it cannot record" || bad "8p2 launcher unwritable log (rc=$rc): $out"
mk byp_l '# HIMMEL-9414 — a bug fix' "$PA" '> **Contract:** y' "$CORE_W" '## Results (newest at the bottom)'
rc=0; out="$(run_worker "$tmp/byp_l.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 0 ] && grep -Fq 'bypass=bug' <<< "$out"; } && ok "8p3 the launcher shows the bypass= line at rc 0" || bad "8p3 launcher bypass echo (rc=$rc): $out"
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

BK="$tmp/bk"; BKLOG="$tmp/bk-argv.log"; mkdir -p "$BK"
export BRIEF_LINT_MIRROR="$tmp/cg-mirror" BRIEF_LINT_JIRA_CLI="$tmp/cg-stub/index.js" BRIEF_LINT_TEST_BUCKET="$BK" BRIEF_LINT_TEST_LOG="$BKLOG"
bk_set() { printf '%s\n' "$2" > "$BK/$1"; }
bk_lint() { rc=0; : > "$BKLOG"; err="$(env "$@" 2>&1 >/dev/null)" || rc=$?; }
bk_calls() { grep -c 'bucket-check' "$BKLOG" || true; }  # swallow-ok: grep -c exits 1 on a count of 0
in_order() { local s="$1" p; shift; for p in "$@"; do case "$s" in *"$p"*) s="${s#*"$p"}" ;; *) return 1 ;; esac; done; }
RES0='## Results (newest at the bottom)'
for k in 9421 9422 9423 9424 9425 9426 9427 9428 9429 9430 9431 9432 9433 9434 9435 9436 9437 9438 9439; do cg_ticket "HIMMEL-$k" Task Medium; done
cg_ticket ZZZ-1 Task Medium
mk bk_out '# HIMMEL-9421 — a later-version build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9421 'OUTSIDE HIMMEL-9421 v1.1.4 current=v1.1.3 open=57'
bk_lint bash "$LINT" "$tmp/bk_out.md"
[ "$rc" -eq 3 ] && ok "8r1 a v1.1.4 ticket with v1.1.3 open is refused (exit 3)" || bad "8r1 outside key rc=$rc want 3: $err"
{ grep -Fq 'HIMMEL-9421' <<< "$err" && grep -Fq 'v1.1.4' <<< "$err" && grep -Fq 'v1.1.3' <<< "$err" && grep -Fq '57 open' <<< "$err"; } \
    && ok "8r2 the refusal names the key, its version, current and the open count" || bad "8r2 OUTSIDE fields: $err"
in_order "$err" 'out-of-version' 'release request' 'parallel work' 'At 0 open' 'releases it in Jira' \
    && ok "8r3 the refusal text holds its clauses in order, the 0-open clause beside the Jira release" || bad "8r3 refusal text order: $err"
! grep -Fq 'VERSION_GATE_OK' <<< "$err" && ok "8r3b the refusal names no off switch (decision 855)" || bad "8r3b refusal names VERSION_GATE_OK: $err"
rc=0; err="$(VERSION_GATE_OK=1 bash "$LINT" "$tmp/bk_out.md" 2>&1 >/dev/null)" || rc=$?
{ [ "$rc" -eq 3 ] && [ ! -e "$tmp/version-gate.jsonl" ]; } && ok "8r4 VERSION_GATE_OK=1 passes nothing and logs no row (decision 855)" || bad "8r4 VERSION_GATE_OK rc=$rc want 3, row written=$([ -e "$tmp/version-gate.jsonl" ] && echo yes || echo no): $err"
bk_set HIMMEL-9421 'OUTSIDE HIMMEL-9421 none current=v1.1.3 open=57'
bk_lint bash "$LINT" "$tmp/bk_out.md"
[ "$rc" -eq 3 ] && ok "8r5 a versionless ticket is refused" || bad "8r5 versionless rc=$rc want 3: $err"
bk_set HIMMEL-9421 'IN HIMMEL-9421 current=v1.1.3 via=mirror'
bk_lint bash "$LINT" "$tmp/bk_out.md"
[ "$rc" -eq 0 ] && ok "8r6 a ticket in the current version passes" || bad "8r6 IN rc=$rc want 0: $err"
bk_set HIMMEL-9421 'OUTSIDE HIMMEL-9421 v1.1.4 current=v1.1.3 open=0'
bk_lint bash "$LINT" --core-only "$tmp/bk_out.md"
[ "$rc" -eq 3 ] && ok "8r7 --core-only cannot skip the bucket rule on an outside key" || bad "8r7 --core-only outside rc=$rc want 3: $err"
bk_lint bash "$LINT" --judge "$tmp/bk_out.md"
{ [ "$rc" -eq 0 ] && [ "$(bk_calls)" -eq 0 ]; } && ok "8r8 --judge skips the bucket rule and asks nothing" || bad "8r8 judge rc=$rc calls=$(bk_calls): $err"
mk bk_judge '# HIMMEL-9421 — a later-version review' "$PA" '> **Completion condition:** z' "$RES0"
bk_lint bash "$LINT" --judge "$tmp/bk_judge.md"
{ [ "$rc" -eq 0 ] && [ "$(bk_calls)" -eq 0 ]; } && ok "8r8b a judge brief on an outside key passes with no bucket-check call" || bad "8r8b judge brief rc=$rc calls=$(bk_calls): $err"
bk_lint bash "$LINT" --skip-bucket "$tmp/bk_out.md"
{ [ "$rc" -eq 0 ] && [ "$(bk_calls)" -eq 0 ]; } && ok "8r8c --skip-bucket (the generator's flag) skips the rule and asks nothing" || bad "8r8c --skip-bucket rc=$rc calls=$(bk_calls): $err"
mk bk_none '# HIMMEL-9422 — an adopter build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9422 'NONE HIMMEL-9422 /m/ADOPT'
bk_lint bash "$LINT" "$tmp/bk_none.md"
{ [ "$rc" -eq 0 ] && grep -Fq 'HIMMEL-9422 bypass=' <<< "$err"; } && ok "8r9 NONE passes and prints a bypass= line with the key" || bad "8r9 NONE rc=$rc: $err"
mk bk_appr '# HIMMEL-9423 — an approved build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9423 'APPROVED HIMMEL-9423 decision=901 record=O-R1-ov-901'
bk_lint bash "$LINT" "$tmp/bk_appr.md"
{ [ "$rc" -eq 0 ] && grep -Fq 'HIMMEL-9423 bypass=' <<< "$err" && grep -Fq 'decision=901' <<< "$err"; } && ok "8r10 APPROVED passes and prints a bypass= line with the decision" || bad "8r10 APPROVED rc=$rc: $err"
mk bk_done '# HIMMEL-9424 — a closed ticket' "$PA" '> **Contract:** y' "$RES0"
mk bk_done_ran '# HIMMEL-9424 — a closed ticket' "$PA" '> **Contract:** y' "$RES0" '- 10:00 LIVE — started'
bk_set HIMMEL-9424 'DONE HIMMEL-9424'
bk_lint bash "$LINT" "$tmp/bk_done.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'new ticket' <<< "$err" && grep -Fq 'reopen' <<< "$err"; } && ok "8r11 a Done ticket on a new doc is refused, naming a new ticket or a reopen" || bad "8r11 DONE new doc rc=$rc: $err"
bk_lint bash "$LINT" "$tmp/bk_done_ran.md"
{ [ "$rc" -eq 0 ] && grep -Fq 'HIMMEL-9424 bypass=' <<< "$err"; } && ok "8r12 a Done ticket on a doc that has run passes with a bypass= line" || bad "8r12 DONE run doc rc=$rc: $err"
bk_lint bash "$LINT" --core-only "$tmp/bk_done_ran.md"
{ [ "$rc" -eq 0 ] && grep -Fq 'HIMMEL-9424 bypass=' <<< "$err"; } && ok "8r13 --core-only: the run doc passes too, on a shell that loaded no worker-identity.sh" || bad "8r13 DONE run doc --core-only rc=$rc: $err"
mk bk_fail '# HIMMEL-9425 — a build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9425 'FAILED HIMMEL-9425 no readable mirror at /m/HIMMEL'
bk_lint bash "$LINT" "$tmp/bk_fail.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'FAILED' <<< "$err" && grep -Fq 'HIMMEL-9425' <<< "$err" && grep -Fq 'no readable mirror' <<< "$err"; } && ok "8r14 FAILED refuses by name, with the verdict's reason" || bad "8r14 FAILED rc=$rc: $err"
mk bk_exit1 '# HIMMEL-9426 — a build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9426 EXIT1
bk_lint bash "$LINT" "$tmp/bk_exit1.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'bucket-check' <<< "$err" && grep -Fq 'exited 1' <<< "$err"; } && ok "8r15 a CLI exiting 1 refuses by name" || bad "8r15 CLI exit 1 rc=$rc: $err"
mk bk_sleep '# HIMMEL-9427 — a build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9427 SLEEP
bk_lint BRIEF_LINT_VERDICT_TIMEOUT=1 bash "$LINT" "$tmp/bk_sleep.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'bucket-check' <<< "$err" && grep -Fq 'timed out' <<< "$err"; } && ok "8r16 a CLI sleeping past BRIEF_LINT_VERDICT_TIMEOUT refuses by name" || bad "8r16 sleeping CLI rc=$rc: $err"
mk bk_noline '# HIMMEL-9428 — a build' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9428 NOLINE
bk_lint bash "$LINT" "$tmp/bk_noline.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'no parseable' <<< "$err" && grep -Fq 'HIMMEL-9428' <<< "$err"; } && ok "8r17 a CLI printing no verdict line refuses, naming the key" || bad "8r17 no verdict line rc=$rc: $err"
bk_set HIMMEL-9428 'MAYBE HIMMEL-9428 current=v1.1.3'
bk_lint bash "$LINT" "$tmp/bk_noline.md"
[ "$rc" -eq 3 ] && ok "8r17b a verdict word the lint does not know is no answer" || bad "8r17b unknown verdict rc=$rc: $err"
bk_lint BRIEF_LINT_JIRA_CLI="$tmp/no-dist/index.js" bash "$LINT" "$tmp/bk_noline.md"
[ "$rc" -eq 3 ] && ok "8r18 no built CLI refuses (the core rule says so first)" || bad "8r18 no CLI rc=$rc: $err"
bk_set HIMMEL-9428 'IN HIMMEL-9428 current=v1.1.3 via=mirror'
bk_lint BRIEF_LINT_VERDICT_TIMEOUT=abc bash "$LINT" "$tmp/bk_noline.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'BRIEF_LINT_VERDICT_TIMEOUT' <<< "$err"; } && ok "8r19 a non-numeric BRIEF_LINT_VERDICT_TIMEOUT refuses by name" || bad "8r19 bad timeout rc=$rc: $err"
bk_lint BRIEF_LINT_VERDICT_TIMEOUT=9999 bash "$LINT" "$tmp/bk_noline.md"
[ "$rc" -eq 0 ] && ok "8r20 a BRIEF_LINT_VERDICT_TIMEOUT above 120 is clamped, not refused" || bad "8r20 clamp rc=$rc: $err"
mkdir -p "$tmp/bkd"
printf -- '---\ndescription: Check the lint on a test brief\nresume_cwd: %s\n---\n# a title with no key\n%s\n> **Contract:** y\n%s\n' "$CW_HIM" "$PA" "$RES0" > "$tmp/bkd/HIMMEL-9429-x.md"
bk_set HIMMEL-9429 'OUTSIDE HIMMEL-9429 v1.1.4 current=v1.1.3 open=3'
bk_lint bash "$LINT" "$tmp/bkd/HIMMEL-9429-x.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'HIMMEL-9429' <<< "$err"; } && ok "8r21 a keyless title on a keyed doc name is asked, and refused for an outside key" || bad "8r21 doc-name key rc=$rc: $err"
bk_lint bash "$LINT" --core-only "$tmp/bkd/HIMMEL-9429-x.md"
[ "$rc" -eq 3 ] && ok "8r21b --core-only reads the doc name's key too" || bad "8r21b --core-only doc name rc=$rc: $err"
mk bk_pair '# HIMMEL-9430 + HIMMEL-9431 — a pair' "$PA" '> **Contract:** y' "$RES0"
bk_set HIMMEL-9431 'OUTSIDE HIMMEL-9431 v1.1.4 current=v1.1.3 open=2'
bk_lint bash "$LINT" "$tmp/bk_pair.md"
{ [ "$rc" -eq 3 ] && grep -Fq 'HIMMEL-9431' <<< "$err" && ! grep -Fq 'HIMMEL-9430 is' <<< "$err"; } && ok "8r22 a two-key title: the second, outside key is refused by name and the first is not" || bad "8r22 pair rc=$rc: $err"
bk_lint bash "$LINT" "$tmp/tmpl_ok.md"
{ [ "$rc" -eq 0 ] && [ "$(bk_calls)" -eq 0 ]; } && ok "8r23 a brief with no key in its title or doc name makes no bucket-check call" || bad "8r23 keyless rc=$rc calls=$(bk_calls): $err"
mkdir -p "$tmp/bkhome/.himmel/state/jira-mirror"; ln -s "$tmp/cg-mirror" "$tmp/bkhome/.himmel/state/jira-mirror/ZZZ"
mk bk_zzz '# ZZZ-1 — another project' "$PA" '> **Contract:** y' "$RES0"
bk_lint -u BRIEF_LINT_MIRROR HOME="$tmp/bkhome" bash "$LINT" --core-only "$tmp/bk_zzz.md"
{ [ "$rc" -eq 0 ] && grep -Fq -- "--mirror $tmp/bkhome/.himmel/state/jira-mirror/ZZZ" "$BKLOG"; } && ok "8r24 the --mirror argument is the key's own project" || bad "8r24 mirror argument rc=$rc: $(cat "$BKLOG") $err"  # read-sink-ok: BKLOG is this suite's own scratch log under its mktemp dir
unset BRIEF_LINT_MIRROR BRIEF_LINT_JIRA_CLI BRIEF_LINT_TEST_SIGNED BRIEF_LINT_TEST_BUCKET BRIEF_LINT_TEST_LOG

# 9. A worker brief (a Contract line) carries the search directive, the notes query over BOTH collections and the graph
# symbol named, whatever its Prior art line cites. A ticket key or #PR does not replace it.
VAGUE='> **Prior art:** related work exists, see the ticket'
KEYED='> **Prior art:** HIMMEL-8707 counts graph and qmd use; fixed in #4534'
RES='## Results (newest at the bottom)'
mk s_vague '# brief' "$VAGUE" '' '> **Contract:** y' "$RES"
mk s_vague_dir '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mk s_key '# brief' "$KEYED" '' '> **Contract:** y' "$RES"
mk s_nf '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' '' '> **Contract:** y' "$RES"
mk s_vague_ran '# brief' "$VAGUE" '' '> **Contract:** y' "$RES" '- 10:00 LIVE — started'
mk s_judge '# brief' "$VAGUE" '' '> **Completion condition:** z' "$RES"
mk s_nocontract '# brief' "$KEYED" '' '> **Why:** x' "$RES"
# the same directive with one piece removed, or left as a placeholder
mk s_nograph '# brief' "$VAGUE" "${DIR_LINE//worker-graph.sh/graph.sh}" '' '> **Contract:** y' "$RES"
mk s_nonotes '# brief' "$VAGUE" "${DIR_LINE//qmd-bounded.sh/qmd.sh}" '' '> **Contract:** y' "$RES"
mk s_noresults '# brief' "$VAGUE" "${DIR_LINE//graph-qmd:/results:}" '' '> **Contract:** y' "$RES"
mk s_noluna '# brief' "$VAGUE" "${DIR_LINE//-c luna/-c vault}" '' '> **Contract:** y' "$RES"
mk s_nojira '# brief' "$VAGUE" "${DIR_LINE//-c jira-himmel/-c tickets}" '' '> **Contract:** y' "$RES"
mk s_topic '# brief' "$VAGUE" "${DIR_LINE//\"lint\"/\"<topic>\"}" '' '> **Contract:** y' "$RES"
mk s_symbol '# brief' "$VAGUE" "${DIR_LINE//\"brief-lint\"/\"<symbol>\"}" '' '> **Contract:** y' "$RES"
mk s_emptyq '# brief' "$VAGUE" "${DIR_LINE//\"lint\"/\"\"}" '' '> **Contract:** y' "$RES"
mk s_emptysym '# brief' "$VAGUE" "${DIR_LINE//\"brief-lint\"/\"\"}" '' '> **Contract:** y' "$RES"
mk s_blankq '# brief' "$VAGUE" "${DIR_LINE//\"lint\"/\"  \"}" '' '> **Contract:** y' "$RES"
mk s_blanksym '# brief' "$VAGUE" "${DIR_LINE//\"brief-lint\"/\"  \"}" '' '> **Contract:** y' "$RES"
mk s_noarg '# brief' "$VAGUE" "${DIR_LINE//explain \"brief-lint\"/explain}" '' '> **Contract:** y' "$RES"
# a leg that writes no code names no symbol, and an adopter repo has no Jira mirror and no himmel graph: each says so
# shellcheck disable=SC2016  # the backticks are literal brief text, not command substitution
NOGRAPH_LINE='> Before you design, run `bash /x/scripts/lib/qmd-bounded.sh query -c jira-himmel "lint"` (tickets and PRs) and `bash /x/scripts/lib/qmd-bounded.sh query -c luna "lint"` (specs, audits and decisions), and cite what each returned. This leg has no graph lookup (it names no code path). Your Results carry a `graph-qmd: <what the notes search returned and whether used>` bullet saying so.'
# shellcheck disable=SC2016  # literal backticks again
ADAPTER_LINE='> Before you design, run `bash /x/scripts/lib/qmd-bounded.sh query -c luna "lint"` (specs, audits and decisions; this repo has no Jira mirror, so no ticket search), and cite what each returned. This leg has no graph lookup (an adopter repo has no himmel graph). Your Results carry a `graph-qmd: <what the notes search returned and whether used>` bullet saying so.'
# The three "no ..." phrases count only where true, judged from resume_cwd and the Writes line.
CW_ADP="$tmp/cwd-adapter"; git init -q "$CW_ADP"
CW_SAL="$tmp/cwd-salus"; git init -q "$CW_SAL"; : > "$CW_SAL/.salus"
mkc() { # name cwd lines...
    local n="$1" cw="$2"; shift 2
    mk_raw "$n" '---' 'description: Check the lint on a test brief' "resume_cwd: $cw" '---' "$@"
}
mkc s_nogl "$CW_HIM" '# brief' "$VAGUE" "$NOGRAPH_LINE" '' '> **Writes:** none named' '> **Contract:** y' "$RES"
mkc s_nogl_false "$CW_HIM" '# brief' "$VAGUE" "$NOGRAPH_LINE" '' '> **Writes:** scripts/x.sh' '> **Contract:** y' "$RES"
mkc s_adapter "$CW_ADP" '# brief' "$VAGUE" "$ADAPTER_LINE" '' '> **Contract:** y' "$RES"
mkc s_adapter_false "$CW_HIM" '# brief' "$VAGUE" "$ADAPTER_LINE" '' '> **Contract:** y' "$RES"
mkc s_adapter_noluna "$CW_ADP" '# brief' "$VAGUE" "${ADAPTER_LINE//-c luna/-c vault}" '' '> **Contract:** y' "$RES"
# shellcheck disable=SC2016  # literal backticks again
SALUS_LINE='> This repo is salus-marked (PHI): no notes search and no graph lookup, because a query would send text off this machine. Your Results carry a `graph-qmd: n/a, salus-marked repo` bullet saying so.'
mkc s_salus "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
mkc s_salus_false "$CW_HIM" '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
mkc s_primary "$CW_HIM" '# brief' "$VAGUE" "${DIR_LINE//bash \/x/bash <primary checkout>}" '' '> **Contract:** y' "$RES"
mkc s_query_ph "$CW_HIM" '# brief' "$VAGUE" "${DIR_LINE//\"lint\"/\"<query>\"}" '' '> **Contract:** y' "$RES"
mkc s_expand "$CW_HIM" '# brief' "$VAGUE" "${DIR_LINE//\"lint\"/\"\$(touch /tmp/x)\"}" '' '> **Contract:** y' "$RES"
mkc s_tick "$CW_HIM" '# brief' "$VAGUE" "${DIR_LINE//\"brief-lint\"/\"a\`b\"}" '' '> **Contract:** y' "$RES"
expect_rc "9a a worker brief with no directive is refused" 1 "$tmp/s_vague.md"
err="$(bash "$LINT" "$tmp/s_vague.md" 2>&1 >/dev/null)"
{ grep -Fq 'qmd-bounded.sh' <<< "$err" && grep -Fq 'worker-graph.sh' <<< "$err" && grep -Fq 'graph-qmd:' <<< "$err" && grep -Fq -- '-c luna' <<< "$err"; } \
    && ok "9b the refusal names both search scripts, both collections and the graph-qmd: Results bullet" || bad "9b refusal text: $err"
expect_rc "9c the directive in the Prior art field passes a line that cites nothing" 0 "$tmp/s_vague_dir.md"
expect_rc "9d a cited ticket key and #PR do not replace the directive" 1 "$tmp/s_key.md"
expect_rc "9d2 none found (query) does not replace the directive" 1 "$tmp/s_nf.md"
expect_rc "9e a resume (Results already holds a bullet) is not made to fail" 0 "$tmp/s_vague_ran.md"
rc=0; bash "$LINT" --judge "$tmp/s_judge.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "9h a judge brief is not held to the worker directive" || bad "9h --judge on a brief with no directive (rc=$rc)"
expect_rc "9h2 a brief with no Contract line (a fixture, the lane canary) is not held to it" 0 "$tmp/s_nocontract.md"
expect_rc "9k a directive without the graph lookup is refused" 1 "$tmp/s_nograph.md"
expect_rc "9l a directive without the notes search is refused" 1 "$tmp/s_nonotes.md"
expect_rc "9m a directive without the graph-qmd: Results bullet is refused" 1 "$tmp/s_noresults.md"
expect_rc "9n a directive that searches only jira-himmel is refused" 1 "$tmp/s_noluna.md"
expect_rc "9n2 a directive that searches only luna is refused" 1 "$tmp/s_nojira.md"
expect_rc "9o a directive that still says <topic> is refused" 1 "$tmp/s_topic.md"
expect_rc "9p a directive that still says <symbol> is refused" 1 "$tmp/s_symbol.md"
expect_rc "9s a leg with no code path says it has no graph lookup in place of the command" 0 "$tmp/s_nogl.md"
expect_rc "9t an adopter-repo directive (luna only, no Jira mirror, no graph lookup) passes" 0 "$tmp/s_adapter.md"
expect_rc "9t2 an adopter-repo directive still has to search luna" 1 "$tmp/s_adapter_noluna.md"
expect_rc "9u 'no graph lookup' is refused when the leg names a code path" 1 "$tmp/s_nogl_false.md"
expect_rc "9u2 'no Jira mirror' is refused when resume_cwd is a himmel checkout" 1 "$tmp/s_adapter_false.md"
expect_rc "9v a salus-marked resume_cwd may say it searches nothing" 0 "$tmp/s_salus.md"
expect_rc "9v2 'no notes search' is refused when resume_cwd is not salus-marked" 1 "$tmp/s_salus_false.md"
expect_rc "9w the template's <primary checkout> placeholder is refused" 1 "$tmp/s_primary.md"
expect_rc "9w2 any angle-bracket placeholder, not just <topic>, is refused" 1 "$tmp/s_query_ph.md"
expect_rc "9x a quoted query with \$(...) is refused" 1 "$tmp/s_expand.md"
expect_rc "9x2 a quoted symbol with a backtick is refused" 1 "$tmp/s_tick.md"
# An unreadable guard list fails closed (marked); a missing one reads as not marked.
H_BAD="$tmp/home-bad"; mkdir -p "$H_BAD/.config/claude-glm/phi-roots"; H_NONE="$tmp/home-none"; mkdir -p "$H_NONE"
HOME="$H_BAD" python3 -I "$HERE/salus_marked.py" salus "$CW_HIM"; rc=$?
[ "$rc" = 0 ] && ok "9y an unreadable phi-roots list reads as salus-marked" || bad "9y unreadable phi-roots rc=$rc"
HOME="$H_NONE" python3 -I "$HERE/salus_marked.py" salus "$CW_HIM"; rc=$?
[ "$rc" = 10 ] && ok "9y2 an absent list reads as not marked (exit 10, a code a crash cannot produce)" || bad "9y2 absent list rc=$rc"

# The classifier answers yes (0) or no (10); anything else is a crash and the lint refuses.
sal_rc() { # label want-rc home cwd [env assignments...]
    local label="$1" want="$2" home="$3" cwd="$4" rc=0; shift 4
    env HOME="$home" "$@" python3 -I "$HERE/salus_marked.py" salus "$cwd" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (rc=$rc want $want)"; fi
}
unset CLAUDE_GLM_CONFIG_DIR
H_BADB="$tmp/home-badbytes"; mkdir -p "$H_BADB/.config/claude-codex"; printf '\377\376\000bad\n' > "$H_BADB/.config/claude-codex/phi-roots"
sal_rc "10a a phi-roots list with bad bytes reads as salus-marked, not as a crash" 0 "$H_BADB" "$CW_HIM"
KIT="$tmp/kit"; mkdir -p "$KIT/scripts/handover/chief-kit" "$KIT/scripts/lib"
cp "$LINT" "$KIT/scripts/handover/chief-kit/"; cp "$HERE/../../lib/"*.sh "$KIT/scripts/lib/"
mkc s_kit_ok "$CW_HIM" '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
KLINT="$KIT/scripts/handover/chief-kit/brief-lint.sh"
rc=0; bash "$KLINT" "$tmp/s_kit_ok.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10b the lint copy with no classifier beside it is refused" || bad "10b missing classifier gave rc=$rc"
for code in 1 7 127; do
    printf 'import sys\nsys.exit(%s)\n' "$code" > "$KIT/scripts/handover/chief-kit/salus_marked.py"
    rc=0; bash "$KLINT" "$tmp/s_kit_ok.md" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 3 ] && ok "10c a classifier that exits $code is refused, not read as not-marked" || bad "10c classifier exit $code gave rc=$rc"
done
printf 'raise RuntimeError("boom")\n' > "$KIT/scripts/handover/chief-kit/salus_marked.py"
rc=0; bash "$KLINT" "$tmp/s_kit_ok.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10d a classifier that raises is refused" || bad "10d raising classifier gave rc=$rc"
printf 'import sys\nsys.exit(10)\n' > "$KIT/scripts/handover/chief-kit/salus_marked.py"
rc=0; bash "$KLINT" "$tmp/s_kit_ok.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "10e a classifier that answers no (10) passes a brief that carries the directive" || bad "10e answer-no classifier gave rc=$rc"

# A salus-marked brief names none of the search, anywhere, and says it searches nothing.
mkc s_salus_dir "$CW_SAL" '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mkc s_salus_both "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mkc s_salus_nowords "$CW_SAL" '# brief' "$VAGUE" '' '> **Contract:** y' "$RES"
mkc s_salus_nocontract "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" "$DIR_LINE" '' '> **Why:** x'
mkc s_salus_ran "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" "$DIR_LINE" '' '> **Contract:** y' "$RES" '- 10:00 LIVE — started'
mkc s_salus_graphify "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" 'Then run graphify query "x".' '' '> **Contract:** y' "$RES"
mkc s_salus_cflag "$CW_SAL" '# brief' "$VAGUE" "$SALUS_LINE" 'Try qmd query -c luna later.' '' '> **Contract:** y' "$RES"
expect_rc "10f a salus-marked brief that names the whole directive is refused" 3 "$tmp/s_salus_dir.md"
expect_rc "10g the words plus the commands are refused too" 3 "$tmp/s_salus_both.md"
expect_rc "10h a salus-marked brief without the words is refused" 1 "$tmp/s_salus_nowords.md"
expect_rc "10i a salus-marked doc with no Contract line is held to it too" 3 "$tmp/s_salus_nocontract.md"
expect_rc "10j a salus-marked doc that has run is held to it too" 3 "$tmp/s_salus_ran.md"
expect_rc "10k a graphify command in a salus-marked brief is refused" 3 "$tmp/s_salus_graphify.md"
expect_rc "10l a '-c luna' command in a salus-marked brief is refused" 3 "$tmp/s_salus_cflag.md"
err="$(bash "$LINT" "$tmp/s_salus_both.md" 2>&1 >/dev/null)"
{ grep -Fq 'salus-marked' <<< "$err" && ! grep -Fq 'worker-graph.sh' <<< "$err" && ! grep -Fq 'qmd-bounded.sh' <<< "$err"; } \
    && ok "10m the salus refusal states only the salus rule" || bad "10m salus refusal text: $err"

# --no-prior-art-check (the lint's --core-only) cannot clear the salus refusal or a classifier crash, and the launcher's
# refusal for either offers no flag. A python3 stand-in that fails only for salus_marked.py makes the classifier crash.
FAKEBIN="$tmp/fakebin"; mkdir -p "$FAKEBIN"; REAL_PY="$(command -v python3)"
printf '#!/bin/sh\ncase "$*" in *salus_marked.py*) exit 7 ;; esac\nexec %s "$@"\n' "$REAL_PY" > "$FAKEBIN/python3"; chmod +x "$FAKEBIN/python3"
rc=0; bash "$LINT" --core-only "$tmp/s_salus_both.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10m2 --core-only still refuses a salus-marked brief that names a search" || bad "10m2 --core-only on a salus brief with the search rc=$rc"
rc=0; PATH="$FAKEBIN:$PATH" bash "$LINT" --core-only "$tmp/s_kit_ok.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10m3 --core-only refuses when the classifier crashes" || bad "10m3 --core-only with a crashing classifier rc=$rc"
rc=0; out="$(run_worker "$tmp/s_salus_both.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'salus-marked' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "10m4 the launcher refuses a salus-marked brief with a search and names no flag" || bad "10m4 launcher salus refusal (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/s_salus_both.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'salus-marked' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "10m5 --no-prior-art-check does not clear the salus refusal" || bad "10m5 launcher salus refusal with the flag (rc=$rc): $out"
rc=0; out="$(PATH="$FAKEBIN:$PATH" run_worker "$tmp/s_kit_ok.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'cannot classify' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "10m6 a crashing classifier is refused by the launcher with the flag, and names no flag" || bad "10m6 launcher with a crashing classifier (rc=$rc): $out"

# A relative resume_cwd is resolved by the launcher against its own directory, so the salus check runs on it as written.
mkc s_rel_salus "." '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mkc s_rel_salus_nc "." '# brief' "$VAGUE" "$DIR_LINE" '' '> **Why:** x'
rc=0; (cd "$CW_SAL" && bash "$LINT" --core-only "$tmp/s_rel_salus.md") >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10m7 --core-only refuses a relative resume_cwd that resolves into a salus-marked directory" || bad "10m7 --core-only relative salus rc=$rc"
rc=0; (cd "$CW_SAL" && bash "$LINT" --core-only "$tmp/s_rel_salus_nc.md") >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10m8 the same for a doc with no Contract line" || bad "10m8 relative salus, no Contract line, rc=$rc"
rc=0; out="$(cd "$CW_SAL" && run_worker "$tmp/s_rel_salus.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'salus-marked' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "10m9 the launcher with the flag refuses a relative salus resume_cwd and names no flag" || bad "10m9 launcher, relative salus, flag (rc=$rc): $out"
rc=0; out="$(cd "$CW_SAL" && run_worker "$tmp/s_rel_salus_nc.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -Fq 'salus-marked' <<< "$out" && ! grep -Fq 'no-prior-art-check' <<< "$out"; } \
    && ok "10m10 the launcher refuses a relative salus resume_cwd on a doc with no Contract line" || bad "10m10 launcher, relative salus, no Contract (rc=$rc): $out"
rc=0; (cd "$CW_HIM" && bash "$LINT" --core-only "$tmp/s_rel_salus.md") >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "10m11 a relative resume_cwd that resolves outside any salus-marked directory still passes --core-only" || bad "10m11 relative non-salus --core-only rc=$rc"

# The lint reads resume_cwd with a copy of the launcher's parse: pin the two blocks together.
# shellcheck disable=SC2016  # the sed patterns match literal $ in the two scripts' text
parse_block() { # file lint|launcher: the resume_cwd parse, the launcher's names mapped to the lint's
    case "$2" in
        lint) sed -n '/^cwd="\$(awk/,/^case "\$cwd" in/p' "$1" ;;
        launcher) sed -n '/^_worker_rcwd="\$(awk/,/^case "\$_worker_rcwd" in/p' "$1" | sed 's/_worker_rcwd/cwd/g; s/"\$DOC"/"$doc"/' ;;
    esac
}
PB_LINT="$(parse_block "$LINT" lint)"; PB_LAUNCH="$(parse_block "$WORKER" launcher)"
{ [ "$(wc -l <<< "$PB_LINT")" -ge 8 ] && [ "$PB_LINT" = "$PB_LAUNCH" ]; } \
    && ok "10z the lint's resume_cwd parse is the launcher's, line for line" || bad "10z the two resume_cwd parses differ (lint $(wc -l <<< "$PB_LINT") lines, launcher $(wc -l <<< "$PB_LAUNCH")): $(diff <(echo "$PB_LINT") <(echo "$PB_LAUNCH") | head -5)"
sed 's/fm == 1 \&\&/fm >= 1 \&\&/' "$WORKER" > "$tmp/worker-mut1.sh"
sed 's/\\~|\\~\/\*/\\~/' "$WORKER" > "$tmp/worker-mut2.sh"
sed 's/_worker_rcwd#\\"/_worker_rcwd#x/' "$WORKER" > "$tmp/worker-mut3.sh"
for m in 1 2 3; do
    [ "$(parse_block "$tmp/worker-mut$m.sh" launcher)" != "$PB_LINT" ] && ok "10z$m a changed launcher parse (mutation $m) no longer matches the lint's" || bad "10z$m mutation $m of the launcher parse went unnoticed"
done

# A list line that is a comment, relative, or ~-based is read as such, and a git that is not on PATH reads a repo as marked.
H_C="$tmp/home-comment"; mkdir -p "$H_C/.config/claude-codex"; printf '# phi roots\nrelative/phi\n\n' > "$H_C/.config/claude-codex/phi-roots"
rc=0; (cd "$CW_HIM" && env HOME="$H_C" python3 -I "$HERE/salus_marked.py" salus "$CW_HIM") || rc=$?
[ "$rc" = 10 ] && ok "11a a comment or relative list line marks nothing" || bad "11a comment/relative list line rc=$rc (want 10)"
H_TL="$tmp/home-tilde-list"; mkdir -p "$H_TL/.config/claude-codex" "$H_TL/phi"
# shellcheck disable=SC2088  # the literal ~ is the list line under test
printf '~/phi\n' > "$H_TL/.config/claude-codex/phi-roots"
sal_rc "11b a ~/ list line is expanded against HOME" 0 "$H_TL" "$H_TL/phi"
NOGIT="$tmp/nogit-bin"; mkdir -p "$NOGIT"; ln -s "$REAL_PY" "$NOGIT/python3"
sal_rc "11c with no git on PATH a repo reads as marked" 0 "$H_NONE" "$CW_HIM" PATH="$NOGIT"
sal_rc "11d with no git on PATH a directory outside any repo is still not marked" 10 "$H_NONE" "$tmp/not-a-repo-at-all" PATH="$NOGIT"

# resume_cwd is read the way the launcher reads it, and a fresh worker brief must carry an absolute one.
mk_raw s_nocwd '---' 'description: Check the lint on a test brief' '---' '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mk_raw s_relcwd '---' 'description: Check the lint on a test brief' 'resume_cwd: some/where' '---' '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mk_raw s_bodycwd '---' 'description: Check the lint on a test brief' '---' '# brief' "$VAGUE" "$DIR_LINE" "resume_cwd: $CW_HIM" '' '> **Contract:** y' "$RES"
mk_raw s_nocwd_ran '---' 'description: Check the lint on a test brief' '---' '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES" '- 10:00 LIVE — started'
mk_raw s_quotedcwd '---' 'description: Check the lint on a test brief' "resume_cwd: \"$CW_SAL\"  " '---' '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
mk_raw s_squotedcwd '---' 'description: Check the lint on a test brief' "resume_cwd: '$CW_SAL'" '---' '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
H_T="$tmp/home-tilde"; mkdir -p "$H_T/proj"; : > "$H_T/proj/.salus"
mk_raw s_tildecwd '---' 'description: Check the lint on a test brief' 'resume_cwd: ~/proj' '---' '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
expect_rc "10n a fresh worker brief with no resume_cwd is refused" 1 "$tmp/s_nocwd.md"
expect_rc "10o a relative resume_cwd is refused" 1 "$tmp/s_relcwd.md"
expect_rc "10p a resume_cwd line outside the front matter is not read" 1 "$tmp/s_bodycwd.md"
expect_rc "10q a doc that has run is not made to fail for a missing resume_cwd" 0 "$tmp/s_nocwd_ran.md"
expect_rc "10r a double-quoted resume_cwd with trailing spaces is read as the launcher reads it" 0 "$tmp/s_quotedcwd.md"
expect_rc "10s a single-quoted resume_cwd is read as the launcher reads it" 0 "$tmp/s_squotedcwd.md"
rc=0; HOME="$H_T" bash "$LINT" "$tmp/s_tildecwd.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "10t a ~/ resume_cwd is expanded against HOME" || bad "10t tilde resume_cwd rc=$rc"

# A linked worktree outside a marked primary, a repo that holds a listed root, GIT_* in the env, a failing git.
GP="$tmp/primary-marked"; git init -q "$GP"; : > "$GP/.salus"
git -C "$GP" -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$GP" worktree add -q "$tmp/outside-wt" -b outside-wt; mkdir -p "$tmp/outside-wt/sub"
sal_rc "10u a linked worktree outside a salus-marked primary reads as marked" 0 "$H_NONE" "$tmp/outside-wt"
sal_rc "10u2 a subdirectory of that worktree reads as marked" 0 "$H_NONE" "$tmp/outside-wt/sub"
sal_rc "10u3 a stray GIT_DIR in the environment does not hide the primary" 0 "$H_NONE" "$tmp/outside-wt" GIT_DIR="$CW_HIM/.git"
sal_rc "10u4 an unmarked repo in a GIT_DIR environment is still not marked" 10 "$H_NONE" "$CW_HIM" GIT_DIR="$GP/.git"
GB="$tmp/badgit"; mkdir -p "$GB/sub"; printf 'gitdir: /nonexistent/gitdir\n' > "$GB/.git"
sal_rc "10v a directory whose .git git cannot read reads as marked" 0 "$H_NONE" "$GB"
sal_rc "10v2 a subdirectory of it reads as marked" 0 "$H_NONE" "$GB/sub"
sal_rc "10v3 a directory with no .git at all is not marked" 10 "$H_NONE" "$tmp/not-a-repo-at-all"
sal_rc "10v4 a directory not made yet inside an unmarked repo is not marked" 10 "$H_NONE" "$CW_HIM/not/made/yet"
# The walk up the parent chain, with no git in play (a plain directory tree), and the same rows against a walk that stops at the directory itself.
MP="$tmp/marked-plain"; mkdir -p "$MP/a/b" "$tmp/marked-profile/a"; : > "$MP/.salus"; : > "$tmp/marked-profile/.salus-profile"
sal_rc "10v5 a .salus two levels up marks a directory below it" 0 "$H_NONE" "$MP/a/b"
sal_rc "10v6 a .salus-profile one level up marks a directory below it" 0 "$H_NONE" "$tmp/marked-profile/a"
mkdir -p "$tmp/walk-mut"; sed 's/^    return \[d\] + .*/    return [d]/' "$HERE/salus_marked.py" > "$tmp/walk-mut/salus_marked.py"
{ ! cmp -s "$HERE/salus_marked.py" "$tmp/walk-mut/salus_marked.py"; } && ok "10v7 the walk mutant differs from the classifier" || bad "10v7 the walk mutant did not apply"
rc=0; env HOME="$H_NONE" python3 -I "$tmp/walk-mut/salus_marked.py" salus "$MP/a/b" || rc=$?
[ "$rc" = 10 ] && ok "10v8 a walk that stops at the directory misses the marker two levels up (10v5 goes RED)" || bad "10v8 walk mutant rc=$rc (want 10)"
rc=0; env HOME="$H_NONE" python3 -I "$tmp/walk-mut/salus_marked.py" salus "$GB/sub" || rc=$?
[ "$rc" = 10 ] && ok "10v9 a walk that stops at the directory misses the .git one level up (10v2 goes RED)" || bad "10v9 walk mutant on .git rc=$rc (want 10)"
GR="$tmp/repo-with-root"; git init -q "$GR"; mkdir -p "$GR/src" "$GR/vault"
H_R="$tmp/home-holds-root"; mkdir -p "$H_R/.config/claude-codex"; printf '%s\n' "$GR/vault" > "$H_R/.config/claude-codex/phi-roots"
sal_rc "10w a repo that holds a listed root is marked from a directory beside the root" 0 "$H_R" "$GR/src"
mkc s_holds_dir "$GR/src" '# brief' "$VAGUE" "$DIR_LINE" '' '> **Contract:** y' "$RES"
mkc s_holds_words "$GR/src" '# brief' "$VAGUE" "$SALUS_LINE" '' '> **Contract:** y' "$RES"
rc=0; HOME="$H_R" bash "$LINT" "$tmp/s_holds_dir.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && ok "10w2 the lint refuses the directive there" || bad "10w2 lint on a repo holding a listed root rc=$rc"
rc=0; HOME="$H_R" bash "$LINT" "$tmp/s_holds_words.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "10w3 the lint accepts the salus words there" || bad "10w3 lint on a repo holding a listed root rc=$rc"

# Every list the lanes read: claude-codex's egress-denylist, and claude-glm's directory from CLAUDE_GLM_CONFIG_DIR.
H_D="$tmp/home-codex-deny"; mkdir -p "$H_D/.config/claude-codex"; printf '%s\n' "$CW_HIM" > "$H_D/.config/claude-codex/egress-denylist"
sal_rc "10x a claude-codex egress-denylist root reads as marked" 0 "$H_D" "$CW_HIM"
G_D="$tmp/glm-dir"; mkdir -p "$G_D"; printf '%s\n' "$CW_HIM" > "$G_D/phi-roots"
sal_rc "10y CLAUDE_GLM_CONFIG_DIR is read for phi-roots" 0 "$H_NONE" "$CW_HIM" CLAUDE_GLM_CONFIG_DIR="$G_D"
G_E="$tmp/glm-dir-empty"; mkdir -p "$G_E"
H_G="$tmp/home-glm-default"; mkdir -p "$H_G/.config/claude-glm"; printf '%s\n' "$CW_HIM" > "$H_G/.config/claude-glm/phi-roots"
sal_rc "10y2 CLAUDE_GLM_CONFIG_DIR replaces the default claude-glm directory" 10 "$H_G" "$CW_HIM" CLAUDE_GLM_CONFIG_DIR="$G_E"
sal_rc "10y3 with it unset the default claude-glm directory is read" 0 "$H_G" "$CW_HIM"
expect_rc "9q a directive with an empty quoted query is refused" 1 "$tmp/s_emptyq.md"
expect_rc "9r a directive with an empty quoted symbol is refused" 1 "$tmp/s_emptysym.md"
expect_rc "9q2 a directive with a blank (whitespace-only) quoted query is refused" 1 "$tmp/s_blankq.md"
expect_rc "9r2 a directive with a blank (whitespace-only) quoted symbol is refused" 1 "$tmp/s_blanksym.md"
expect_rc "9r3 a graph lookup with no quoted argument at all is refused" 1 "$tmp/s_noarg.md"
err="$(bash "$LINT" "$tmp/s_topic.md" 2>&1 >/dev/null)"
grep -Fq 'placeholder' <<< "$err" && ok "9o2 the placeholder refusal says placeholder" || bad "9o2 refusal text: $err"
rc=0; out="$(run_worker "$tmp/s_vague.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -ne 0 ] && grep -Fq 'graph-qmd:' <<< "$out"; } && ok "9i the launcher refuses it too" || bad "9i launcher on a brief with no directive (rc=$rc): $out"
for t in qmd-bounded.sh worker-graph.sh 'graph-qmd:' '-c jira-himmel' '-c luna'; do
    grep -Fq -- "$t" "$tmp/filled_worker.md" && ok "9j the worker brief template carries $t" || bad "9j the worker brief template lacks $t"
done

# bash 3.2 (macOS) finds the end of a $( ... ) by counting raw quotes and parentheses and knows nothing of a heredoc
# or a comment, so one apostrophe in a comment inside the core-gate python heredoc ran the substitution on past its real end.
# Emulate that count and require it to end where the block does, on the line that starts with the closing parenthesis.
# The heredoc is a statement of its own, not inside a $( ... ), for the same reason.
rc=0; python3 -I - "$LINT" > "$tmp/m32.out" 2>&1 <<'PY' || rc=$?
import sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
start = next(n for n, l in enumerate(lines, 1) if l.startswith('    core_err="$(python3'))
real = next(n for n in range(start + 1, len(lines) + 1) if lines[n - 1].startswith(')"'))
i = lines[start - 1].index('$(') + 2
depth, quote, ln = 1, None, start
while True:
    s = lines[ln - 1]
    while i < len(s):
        c = s[i]
        if quote:
            if quote == '"' and c == '\\':
                i += 1
            elif c == quote:
                quote = None
        elif c == '\\':
            i += 1
        elif c in '\'"`':
            quote = c
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                print('line %d (real end line %d)' % (ln, real))
                sys.exit(0 if ln == real else 1)
        i += 1
    i, ln = 0, ln + 1
PY
out="$(cat "$tmp/m32.out")"
[ "$rc" = 0 ] && ok "11a the core-gate command substitution ends where bash 3.2 counts it to end ($out)" || bad "11a bash 3.2 would end the core-gate command substitution early: $out"

# 12. The front matter must parse as YAML: a fresh brief whose block does not parse, repeats a key or wraps a quoted
#     value is refused (exit 3, with and without --core-only), two last lines name the fault and the fix, and every
#     refusal counts itself in front-matter-refusals.jsonl beside the brief. A doc that has run, a lone session_ids:
#     line, and a missing PyYAML never refuse.
mkfm() { # name front-matter-lines...: a fresh brief that passes every other check
    local n="$1"; shift
    mk_raw "$n" '---' "$@" '---' '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' "$DIR_LINE" '' '> **Contract:** y' '## Results (newest at the bottom)'
}
fm_tail() { # lint args... : the lint's last two stderr lines
    bash "$LINT" "$@" 2>&1 >/dev/null | tail -n 2
}
fm_rows() { # doc: how many refusal rows sit beside it
    local f; f="$(dirname "$1")/front-matter-refusals.jsonl"
    if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}
RC="resume_cwd: $CW_HIM"
SID='session_ids:,11111111-1111-4111-8111-111111111111'
mkfm fm_colon "$RC" 'description: a: b' 'template_version: 3'
rm -f "$tmp/front-matter-refusals.jsonl"
rc=0; t2="$(fm_tail "$tmp/fm_colon.md")"; bash "$LINT" "$tmp/fm_colon.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "12a an unquoted colon in the description is exit 3" || bad "12a unquoted colon description (rc=$rc)"
[ "$(sed -n 1p <<< "$t2" | cut -d: -f1-2)" = "$tmp/fm_colon.md:3" ] && ok "12b line one of the refusal names the doc and the line" || bad "12b refusal line one: $(sed -n 1p <<< "$t2")"
[ "$(sed -n 2p <<< "$t2")" = 'replace lines 3-3 with: description: "a: b"' ] && ok "12c line two is the replacement line" || bad "12c refusal line two: $(sed -n 2p <<< "$t2")"
[ "$(fm_rows "$tmp/fm_colon.md")" = 2 ] && ok "12d each refusal appends one row beside the brief" || bad "12d refusal rows: $(fm_rows "$tmp/fm_colon.md")"
rc=0; bash "$LINT" --core-only "$tmp/fm_colon.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "12e --core-only does not clear the refusal" || bad "12e --core-only (rc=$rc)"
mkfm fm_dupstatus "$RC" 'description: ok' 'status: a' 'status: b'
t2="$(fm_tail "$tmp/fm_dupstatus.md")"; rc=0; bash "$LINT" "$tmp/fm_dupstatus.md" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 3 ] && grep -q ':5:.*status' <<< "$t2" && ! grep -q 'replace lines' <<< "$t2"; } && ok "12f a repeated key is exit 3, names line and key, no replacement" || bad "12f repeated status (rc=$rc): $t2"
mkfm fm_dupdesc "$RC" 'description: one' 'description: two'
t2="$(fm_tail "$tmp/fm_dupdesc.md")"; rc=0; bash "$LINT" "$tmp/fm_dupdesc.md" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 3 ] && ! grep -q 'replace lines' <<< "$t2" && grep -q 'double-quote' <<< "$t2"; } && ok "12g two description lines are exit 3 with the generic fix" || bad "12g repeated description (rc=$rc): $t2"
mkfm fm_wrap0 "$RC" 'description: "Fix this' 'thing now"'
t2="$(fm_tail "$tmp/fm_wrap0.md")"; rc=0; bash "$LINT" "$tmp/fm_wrap0.md" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 3 ] && [ "$(sed -n 2p <<< "$t2")" = 'replace lines 3-4 with: description: "Fix this thing now"' ]; } && ok "12h a quoted value wrapped at column 0 is exit 3 and folds" || bad "12h column-0 wrap (rc=$rc): $t2"
mkfm fm_wrapind "$RC" 'description: "Fix this' '  thing now"'
t2="$(fm_tail "$tmp/fm_wrapind.md")"; rc=0; bash "$LINT" "$tmp/fm_wrapind.md" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 3 ] && [ "$(sed -n 2p <<< "$t2")" = 'replace lines 3-4 with: description: "Fix this thing now"' ]; } && ok "12i an indented wrapped quoted value is exit 3 and folds" || bad "12i indented wrap (rc=$rc): $t2"
mkfm fm_wrapkey "$RC" 'description: "Fix: a' 'second: line"' 'template_version: 3'
t2="$(fm_tail "$tmp/fm_wrapkey.md")"; fix="$(sed -n 2p <<< "$t2")"
printf '%s\n' "$(sed -n 1,2p "$tmp/fm_wrapkey.md")" "${fix#*with: }" "$(sed -n '5,$p' "$tmp/fm_wrapkey.md")" > "$tmp/fm_wrapkey_fixed.md"
keys="$(python3 -I -c 'import sys,yaml; t=open(sys.argv[1]).read().split("\n---\n")[0].lstrip("-\n"); print(" ".join(sorted(yaml.safe_load(t))))' "$tmp/fm_wrapkey_fixed.md" 2>&1)"
{ [ "$(sed -n 2p <<< "$t2" | cut -c1-23)" = 'replace lines 3-4 with:' ] && [ "$keys" = 'description resume_cwd template_version' ]; } && ok "12j a wrapped value holding a key shape gets a range over both lines, and pasting it leaves no second key" || bad "12j wrapped key shape: $t2 keys=[$keys]"
mkfm fm_sid_bad "$RC" 'description: a: b' "$SID"
rc=0; bash "$LINT" "$tmp/fm_sid_bad.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && ok "12k a bad description beside session_ids:,<uuid> is exit 3" || bad "12k bad description beside the id (rc=$rc)"
# controls: each of these must pass
mkfm fm_good "$RC" 'description: "a plain description"' 'template_version: 3'
expect_rc "12l a valid brief passes" 0 "$tmp/fm_good.md"
mk_raw fm_colon_run '---' "$RC" 'description: a: b' '---' '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' '## Results (newest at the bottom)' '- 10:00 LIVE — started'
expect_rc "12m the bad brief with a Results bullet passes (it has run)" 0 "$tmp/fm_colon_run.md"
mkfm fm_sid_only "$RC" 'description: "valid"' "$SID"
expect_rc "12n session_ids:,<uuid> with a valid description and no bullet passes (the writer heals it)" 0 "$tmp/fm_sid_only.md"
mkfm fm_oneline "$RC" 'description: "a: b"'
expect_rc "12o a one-line quoted a: b passes" 0 "$tmp/fm_oneline.md"
mkfm fm_merge "$RC" 'description: "merge keys"' 'base: &b' '  x: 1' 'child:' '  <<: *b' '  y: 2'
expect_rc "12p a merge key passes" 0 "$tmp/fm_merge.md"
mkfm fm_alias "$RC" 'description: "recursive alias"' 'a: &a' '  b: *a'
expect_rc "12q a recursive alias ends and passes" 0 "$tmp/fm_alias.md"
sed 's/$/\r/' "$tmp/fm_good.md" > "$tmp/fm_crlf.md"
expect_rc "12r a valid brief with CRLF line endings passes" 0 "$tmp/fm_crlf.md"
mk_raw fm_noclose '---' "$RC" 'description: a: b' '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")'
rc=0; bash "$LINT" "$tmp/fm_noclose.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 3 ] && ok "12s an opening --- with no close has no block, so it is not refused for its front matter" || bad "12s unclosed front matter was refused (rc=$rc)"
# no PyYAML: a python3 on PATH that runs with -S has no site-packages
mkdir -p "$tmp/nopy"; printf '#!/bin/sh\nexec %s -S "$@"\n' "$(command -v python3)" > "$tmp/nopy/python3"; chmod +x "$tmp/nopy/python3"
rc=0; out="$(PATH="$tmp/nopy:$PATH" bash "$LINT" "$tmp/fm_colon.md" 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && grep -q "brief-lint: bypass=no-pyyaml $tmp/fm_colon.md" <<< "$out"; } && ok "12t without PyYAML the lint passes and prints bypass=no-pyyaml" || bad "12t no PyYAML (rc=$rc): $out"
# a refusal count that cannot be written is still a refusal with the same two lines
mkdir -p "$tmp/unw/front-matter-refusals.jsonl"; cp "$tmp/fm_colon.md" "$tmp/unw/fm_colon.md"
rc=0; t2="$(fm_tail "$tmp/unw/fm_colon.md")"; bash "$LINT" "$tmp/unw/fm_colon.md" >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 3 ] && [ "$(sed -n 2p <<< "$t2")" = 'replace lines 3-3 with: description: "a: b"' ]; } && ok "12u an unwritable refusal count still refuses with the same two lines" || bad "12u unwritable count (rc=$rc): $t2"
# launcher: the refusal reaches the operator without the Prior art advice, and the flag does not clear it
rc=0; out="$(run_worker "$tmp/fm_colon.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'replace lines 3-3' <<< "$out" && ! grep -q 'fill the Prior art line' <<< "$out"; } && ok "12v the launcher refuses a bad front matter without the Prior art advice" || bad "12v launcher refusal (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fm_colon.md" --profile worker-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'replace lines 3-3' <<< "$out"; } && ok "12w --no-prior-art-check does not clear the front-matter refusal" || bad "12w launcher with the flag (rc=$rc): $out"
rc=0; out="$(PATH="$tmp/nopy:$PATH" run_worker "$tmp/fm_colon.md" --profile worker-impl)" || rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'bypass=no-pyyaml' <<< "$out"; } && ok "12x bypass=no-pyyaml reaches the launcher's output" || bad "12x launcher without PyYAML (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fm_good.md" --profile worker-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "12y a valid brief launches" || bad "12y valid brief (rc=$rc): $out"
rc=0; out="$(run_worker "$tmp/fm_good.md" --profile worker-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "12z a valid brief launches with --no-prior-art-check" || bad "12z valid brief with the flag (rc=$rc): $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
