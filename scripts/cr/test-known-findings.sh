#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C intentional in check(); backticks in fixture strings are literal markdown/CSV
# Test harness for known-findings.sh: detectors over a fixture
# repo diff, --prompt / --list / --json shapes, --refresh on a COPY of the JSON
# (never the shipped one), and the usage contract.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }   # no pipeline: see test-cr-tune.sh (HIMMEL-1430)
HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/known-findings.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/kf-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fails=0
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# ── fixture repo ────────────────────────────────────────────────────────────
# Bait files live in testdata/known-findings/ (data, not code — so the detectors
# skip them in THIS repo's own diffs) and are copied into a throwaway git repo.
FIX="$HERE/testdata/known-findings"
repo="$tmp/repo"; mkdir -p "$repo/scripts/hooks" "$repo/docs"
( cd "$repo" && git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false ) || { echo "FAIL - fixture init"; exit 1; }
cp "$FIX/base.sh" "$repo/scripts/foo.sh"
printf 'Write-Host twin\n' > "$repo/scripts/foo.ps1"
printf '# Foo\n\nRun `foo --old-flag` or `foo --keep-flag`.\n' > "$repo/docs/x.md"
( cd "$repo" && git add -A && git commit -qm base ) || { echo "FAIL - fixture base commit"; exit 1; }
base="$(cd "$repo" && git rev-parse HEAD)"

# Change 1: every detector fires once, exclusions hold (see testdata/known-findings/README.md).
cp "$FIX/change1.sh" "$repo/scripts/foo.sh"
cp "$FIX/new.md" "$repo/docs/new.md"
cp "$FIX/new-hook.sh" "$repo/scripts/hooks/new-hook.sh"
( cd "$repo" && git add -A && git commit -qm change1 ) || { echo "FAIL - fixture change1 commit"; exit 1; }

out="$(cd "$repo" && bash "$SCRIPT" --diff "$base...HEAD" 2>&1)"; rc=$?
check "diff: exit 0 (advisory)" "$rc" "0"
contains "diff: mktemp-no-template fires"      "$out" "[mktemp-no-template]"
contains "diff: mktemp cites file:line"        "$out" "scripts/foo.sh:4"
not_contains "diff: templated mktemp excluded" "$out" "scripts/foo.sh:5"
contains "diff: gnu-only-utility (timeout)"    "$out" "[gnu-only-utility]"
contains "diff: timeout cites line 6"          "$out" "scripts/foo.sh:6"
not_contains "diff: gnu-ok marker excluded"    "$out" "scripts/foo.sh:7"
contains "diff: bash32 fires"                  "$out" "[bash32-portability]"
contains "diff: octal on UPPERCASE arith"      "$out" "[octal-leading-zero]"
contains "diff: octal cites line 9"            "$out" "scripts/foo.sh:9"
not_contains "diff: 10# excluded"              "$out" "scripts/foo.sh:10"
contains "diff: handover literal path"         "$out" "[handover-root-bootstrap]"
contains "diff: test-coverage-gap"             "$out" "[test-coverage-gap]"
contains "diff: docs-flag-drift"               "$out" "[docs-flag-drift]"
contains "diff: removed flag still in docs"    "$out" "--old-flag still in docs/x.md"
not_contains "diff: kept flag not reported"    "$out" "--keep-flag still"
contains "diff: md-fence-no-lang"              "$out" "[md-fence-no-lang]"
contains "diff: bare fence cites docs/new.md:3" "$out" "docs/new.md:3"
contains "diff: hook-fail-direction"           "$out" "[hook-fail-direction]"
contains "diff: grep -q pipe under pipefail"   "$out" "[grep-q-pipe-under-pipefail]"
contains "diff: grep -q pipe cites line 13"    "$out" "scripts/foo.sh:13"
# Red-first pairs: each new detector must fire on its bait line AND
# stay silent on the correct spelling one line below it.
contains "diff: jq // swallows false"          "$out" "[jq-alternative-swallows-false]"
contains "diff: jq // cites line 14"           "$out" "scripts/foo.sh:14"
not_contains "diff: jq |type presence excluded" "$out" "scripts/foo.sh:15"
not_contains "diff: jq // on a string field excluded" "$out" "scripts/foo.sh:16"
contains "diff: non-ASCII bracket expression"  "$out" "[non-ascii-bracket-expression]"
contains "diff: non-ASCII bracket cites line 17" "$out" "scripts/foo.sh:17"
not_contains "diff: alternation spelling excluded" "$out" "scripts/foo.sh:18"
contains "diff: hardcoded /usr/bin/ coreutil"  "$out" "scripts/foo.sh:19"
not_contains "diff: bare cat control excluded" "$out" "scripts/foo.sh:20"
# The exclude must not carry a whole-line `| type` clause, which would
# suppress this genuinely buggy line. Line 22 must FIRE; line 15 (the
# safe `(.agent_id | type) == "string"`) must STILL stay silent — it is excluded
# by the main pattern needing `//`, never by an exclude clause.
contains "diff: jq // with a trailing |type still fires" "$out" "scripts/foo.sh:22"
contains "diff: summary line counts classes"   "$out" "class(es) match this diff"
# Red-first bait/control pairs for the hottest rebuttal classes
# (change1.sh lines 24-34): the detector pre-flags the exact shape critics
# re-raise, and stays silent on the near-miss one line below it.
contains "diff: errexit rebuttal pre-flagged"       "$out" "[errexit-false-positive]"
contains "diff: errexit bare rm -f cites line 24"   "$out" "scripts/foo.sh:24"
contains "diff: errexit bare wait cites line 25"    "$out" "scripts/foo.sh:25"
contains "diff: errexit [ ] && assign cites line 26" "$out" "scripts/foo.sh:26"
not_contains "diff: rm -f || true compound excluded" "$out" "scripts/foo.sh:27"
not_contains "diff: wait with an operand excluded"  "$out" "scripts/foo.sh:28"
contains "diff: octal single-bracket date -gt cites line 29" "$out" "scripts/foo.sh:29"
not_contains "diff: octal [[ ]] is arithmetic, not the rebuttal shape" "$out" "scripts/foo.sh:30"
contains "diff: handover git-common-dir cites line 32" "$out" "scripts/foo.sh:32"
not_contains "diff: handover --show-toplevel excluded" "$out" "scripts/foo.sh:33"
contains "diff: mktemp with a redirect cites line 34" "$out" "scripts/foo.sh:34"

# --json: parseable, hits carry id + where
jout="$(cd "$repo" && bash "$SCRIPT" --diff "$base...HEAD" --json 2>&1)"
printf '%s' "$jout" > "$tmp/out.json"
jids="$(node -e 'const j=require(process.argv[1]);console.log(j.hits.map(h=>h.id).sort().join(","));console.log("files="+j.files)' "$tmp/out.json" 2>&1)"
contains "json: ids include mktemp + twin" "$jids" "mktemp-no-template"
contains "json: files count present"      "$jids" "files=3"

# Change 2: a test file changes alongside a hook edit that states its direction → no coverage gap, no hook flag.
printf '#!/usr/bin/env bash\n# new-hook.sh — fail-open workflow nudge\necho hi\n' > "$repo/scripts/hooks/new-hook.sh"
printf '#!/usr/bin/env bash\necho test\n' > "$repo/scripts/hooks/test-new-hook.sh"   # paired: same dir + stem
( cd "$repo" && git add -A && git commit -qm change2 ) || { echo "FAIL - fixture change2 commit"; exit 1; }
out2="$(cd "$repo" && bash "$SCRIPT" --diff "HEAD~1...HEAD" 2>&1)"
not_contains "diff2: no coverage gap when a PAIRED test changed" "$out2" "[test-coverage-gap]"
not_contains "diff2: hook with stated direction not flagged (not new)" "$out2" "[hook-fail-direction]"

# Change 2b: an UNRELATED test edit does not clear the gap for a source it is not
# paired with (different stem, different dir) — panel r2 codex-3.
mkdir -p "$repo/scripts/other" && printf '#!/usr/bin/env bash\necho other\n' > "$repo/scripts/other/test-zzz.sh"
printf '# touched\n' >> "$repo/scripts/hooks/new-hook.sh"
( cd "$repo" && git add -A && git commit -qm change2b ) || { echo "FAIL - fixture change2b commit"; exit 1; }
out2b="$(cd "$repo" && bash "$SCRIPT" --diff "HEAD~1...HEAD" 2>&1)"
contains "diff2b: unrelated test does not clear the coverage gap" "$out2b" "[test-coverage-gap]"
contains "diff2b: the unpaired source is the one listed" "$out2b" "scripts/hooks/new-hook.sh"

# Change 3: the same bait under a testdata/ dir is fixture data, never a hit.
mkdir -p "$repo/scripts/testdata/kf" && cp "$FIX/change1.sh" "$repo/scripts/testdata/kf/bait.sh" && cp "$FIX/new.md" "$repo/scripts/testdata/kf/bait.md"
( cd "$repo" && git add -A && git commit -qm change3 ) || { echo "FAIL - fixture change3 commit"; exit 1; }
out4="$(cd "$repo" && bash "$SCRIPT" --diff "HEAD~1...HEAD" 2>&1)"
contains "diff3: testdata bait is skipped" "$out4" "no known class matches"

# Change 4: a `bin.js` CLI entry point has no natural like-named
# test file — it's the dispatcher a whole test/ dir exercises (real case:
# scripts/himmelctl/bin.js paired with scripts/himmelctl/test/test-wizard-questions.sh,
# PR #2273). Any changed test under the entry point's own dir or a subdirectory
# counts, without a stem-name pair. `wizard.js` in the same dir is a RED
# control: it is NOT named `bin`, so it still needs its own exact-name pair
# and must stay flagged even though the same test/ dir file changed.
mkdir -p "$repo/scripts/himmelctl/test"
printf '#!/usr/bin/env node\nconsole.log("bin v1");\n' > "$repo/scripts/himmelctl/bin.js"
printf '#!/usr/bin/env node\nconsole.log("wizard v1");\n' > "$repo/scripts/himmelctl/wizard.js"
printf '#!/usr/bin/env bash\necho v1\n' > "$repo/scripts/himmelctl/test/test-wizard-questions.sh"
( cd "$repo" && git add -A && git commit -qm himmelctl-base ) || { echo "FAIL - fixture himmelctl base commit"; exit 1; }
printf '#!/usr/bin/env node\nconsole.log("bin v2");\n' > "$repo/scripts/himmelctl/bin.js"
printf '#!/usr/bin/env node\nconsole.log("wizard v2");\n' > "$repo/scripts/himmelctl/wizard.js"
printf '#!/usr/bin/env bash\necho v2\n' > "$repo/scripts/himmelctl/test/test-wizard-questions.sh"
( cd "$repo" && git add -A && git commit -qm change4 ) || { echo "FAIL - fixture change4 commit"; exit 1; }
out5="$(cd "$repo" && bash "$SCRIPT" --diff "HEAD~1...HEAD" 2>&1)"
not_contains "diff5: bin.js entry point paired with any changed test/ dir file" "$out5" "scripts/himmelctl/bin.js"
contains "diff5 RED control: a non-bin source in the same dir still needs its own pair" "$out5" "scripts/himmelctl/wizard.js"

# Change 5: the containment check
# (tDir !== dir && !tDir.startsWith(dir + "/")) must special-case dir === "."
# for a truly ROOT-level bin.js entry point -- path.posix.dirname of a root
# file is ".", so a test under test/ (dirname "test") satisfies neither
# tDir !== dir NOR tDir.startsWith("./") without that case, wrongly flagging
# it as unpaired. The shipped test-coverage-gap class's globs all require a
# "scripts/" or "marketplace/" prefix, so this path is unreachable through
# the default JSON (dormant per the ticket) -- exercised here with a minimal
# custom class whose globs allow a bare "bin.js".
cat > "$tmp/root-bin-kf.json" <<'KFJSON'
{"classes":[{"id":"root-bin-gap","kind":"checklist","rung":"advisory","title":"t","source":"s","globs":["bin.js"],"detector":{"type":"no-test-change"},"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}]}
KFJSON
rootrepo="$tmp/rootrepo"; mkdir -p "$rootrepo/test"
( cd "$rootrepo" && git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false ) || { echo "FAIL - root-bin fixture init"; exit 1; }
printf '#!/usr/bin/env node\nconsole.log("root bin v1");\n' > "$rootrepo/bin.js"
printf '#!/usr/bin/env bash\necho v1\n' > "$rootrepo/test/test-root.sh"
( cd "$rootrepo" && git add -A && git commit -qm base ) || { echo "FAIL - root-bin fixture base commit"; exit 1; }
printf '#!/usr/bin/env node\nconsole.log("root bin v2");\n' > "$rootrepo/bin.js"
printf '#!/usr/bin/env bash\necho v2\n' > "$rootrepo/test/test-root.sh"
( cd "$rootrepo" && git add -A && git commit -qm change ) || { echo "FAIL - root-bin fixture change commit"; exit 1; }
out6="$(cd "$rootrepo" && KNOWN_FINDINGS_FILE="$tmp/root-bin-kf.json" bash "$SCRIPT" --diff "HEAD~1...HEAD" 2>&1)"
not_contains "diff6: a ROOT-level bin.js (dir \".\") is paired by any changed test/ dir file" "$out6" "bin.js"

# Empty / clean diff
out3="$(cd "$repo" && bash "$SCRIPT" --diff "HEAD...HEAD" 2>&1)"; rc3=$?
check "clean diff exits 0" "$rc3" "0"
contains "clean diff says so" "$out3" "no known class matches"

# --prompt: rebuttal classes only, with the do-not-re-raise framing
p="$(bash "$SCRIPT" --prompt 2>&1)"
contains "prompt: framing" "$p" "do NOT re-raise"
contains "prompt: errexit rebuttal present" "$p" "[errexit-false-positive]"
contains "prompt: handover rebuttal present" "$p" "[handover-root-bootstrap]"
not_contains "prompt: fix classes excluded" "$p" "[mktemp-no-template]"

# --list: markdown table with every class id
l="$(bash "$SCRIPT" --list 2>&1)"
contains "list: table header" "$l" "| id | kind | rung | source | detector | title |"
contains "list: has gnu-only-utility row" "$l" '`gnu-only-utility`'
contains "list: has octal-arith-unnormalized row" "$l" '`octal-arith-unnormalized`'
contains "list: octal-leading-zero rebuttal kept" "$l" '`octal-leading-zero`'
# a pipe (or newline) in any cell must not split the markdown row.
cat > "$tmp/pipe-kf.json" <<'KFJSON'
{"classes":[{"id":"pipe-title","kind":"checklist","rung":"human","title":"a|b\nc","source":"s|t","globs":[],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}]}
KFJSON
lp="$(KNOWN_FINDINGS_FILE="$tmp/pipe-kf.json" bash "$SCRIPT" --list 2>&1)"
lrow="$(grep -F '`pipe-title`' <<< "$lp")"
contains "list: pipe in title escaped" "$lrow" 'a\|b c'
contains "list: pipe in source escaped" "$lrow" 's\|t'
check "list: pipe-title is one row with 7 unescaped separators" "$(tr -cd '|' <<< "${lrow//\\|/}" | wc -c | tr -d ' ')" "7"

# every class carries a rung (design|gate|advisory|prompt|human).
# --ladder prints the count per rung, then the promotion queue (prompt/advisory
# classes with agreed ledger recurrences); a class missing/with a bad rung is a
# schema error (exit 2), never a silent miss.
rungs="$(node -e 'const j=require(process.argv[1]);const ok=["design","gate","advisory","prompt","human"];console.log(j.classes.filter(c=>!ok.includes(c.rung)).length)' "$HERE/known-findings.json" 2>&1)"
check "rung: every shipped class has a valid rung" "$rungs" "0"
lad="$(bash "$SCRIPT" --ladder 2>&1)"; ladrc=$?
check "ladder: exit 0" "$ladrc" "0"
contains "ladder: rung counts header" "$lad" "rung counts:"
contains "ladder: lists every rung" "$lad" "design=0 gate=0 advisory="
contains "ladder: promotion queue section" "$lad" "promotion queue"
contains "ladder: queue names an advisory class with agreed recurrences" "$lad" "[errexit-false-positive]"
not_contains "ladder: a class with 0 agreed recurrences is not queued" "$lad" "[pr-check-anchor-handshake-escalation]"
cat > "$tmp/norung-kf.json" <<'KFJSON'
{"classes":[{"id":"no-rung","kind":"checklist","title":"t","source":"s","globs":[],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}]}
KFJSON
KNOWN_FINDINGS_FILE="$tmp/norung-kf.json" bash "$SCRIPT" --list >/dev/null 2>&1; check "schema: class missing rung fails (--list)" "$?" "2"
KNOWN_FINDINGS_FILE="$tmp/norung-kf.json" bash "$SCRIPT" --prompt >/dev/null 2>&1; check "schema: --prompt stays fail-soft on a class missing rung" "$?" "0"
KNOWN_FINDINGS_FILE="$tmp/norung-kf.json" bash "$SCRIPT" --ladder >/dev/null 2>&1; check "schema: class missing rung fails (--ladder)" "$?" "2"
sed 's/"kind":"checklist"/"kind":"checklist","rung":"bogus"/' "$tmp/norung-kf.json" > "$tmp/badrung-kf.json"
KNOWN_FINDINGS_FILE="$tmp/badrung-kf.json" bash "$SCRIPT" --ladder >/dev/null 2>&1; check "schema: class with an invalid rung fails" "$?" "2"

# promotion proposals: real recurrences since the rung was set (optional
# `rung_since`, else the whole ledger) across distinct branches; PROPOSE when >= N and >= M.
# Dates are relative to now: the gate rung only counts the last 30 days.
rd() { node -e 'console.log(new Date(Date.now()-process.argv[1]*864e5).toISOString().slice(0,19)+"Z")' "$1"; }
cat > "$tmp/promo-kf.json" <<'KFJSON'
{"classes":[
{"id":"spread","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["spread/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"shell-lint [x] (advisory)","prompt":false,"evidence":{}},
{"id":"one-branch","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["onebranch/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"stale","kind":"fix","rung":"advisory","rung_since":"@SINCE@","title":"t","source":"s","globs":["stale/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"prompt-only","kind":"fix","rung":"prompt","title":"t","source":"s","globs":["ponly/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"no-branch","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["nobranch/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"already-gated","kind":"fix","rung":"gate","title":"t","source":"s","globs":["gated/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}
]}
KFJSON
sed -i.bak "s/@SINCE@/$(rd 15 | cut -c1-10)/" "$tmp/promo-kf.json"
pf() { printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"codex","finding_id":"%s","severity":"imp","file":"%s","line":1,"verdict":"agreed","text":"a needle here"}\n' "$@"; }
{
  pf "$(rd 12)" b1 aaaaaaa f1 spread/a.sh
  pf "$(rd 11)" b2 bbbbbbb f2 spread/b.sh
  pf "$(rd 10)" b2 ccccccc f3 spread/c.sh
  pf "$(rd 12)" b1 ddddddd f4 onebranch/a.sh
  pf "$(rd 11)" b1 eeeeeee f5 onebranch/b.sh
  pf "$(rd 10)" b1 fffffff f6 onebranch/c.sh
  pf "$(rd 22)" b1 1111111 f7 stale/a.sh
  pf "$(rd 21)" b2 2222222 f8 stale/b.sh
  pf "$(rd 20)" b3 3333333 f9 stale/c.sh
  pf "$(rd 12)" b1 4444444 f10 ponly/a.md
  pf "$(rd 11)" b2 5555555 f11 ponly/b.md
  pf "$(rd 10)" b3 6666666 f12 ponly/c.md
  pf "$(rd 12)" b1 abababa f16 nobranch/a.sh
  pf "$(rd 11)" b1 bcbcbcb f17 nobranch/b.sh
  pf "$(rd 10)" "" cdcdcdc f18 nobranch/c.sh
  pf "$(rd 12)" b1 7777777 f13 gated/a.sh
  pf "$(rd 11)" b2 8888888 f14 gated/b.sh
  pf "$(rd 10)" b3 9999999 f15 gated/c.sh
} > "$tmp/promo-ledger.jsonl"
pl="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder --min-recurrences 3 --min-branches 2 2>&1)"; plrc=$?
check "promote: --ladder exit 0" "$plrc" "0"
contains "promote: section header names N and M" "$pl" "promotion proposals (real recurrences, verdict agreed/confirmed/fixed, attributed by globs and match; >= 3 across >= 2 branches"
contains "promote: crossing class proposed with rung, counts, host" "$pl" "PROPOSE [spread] advisory -> gate recurrences=3 branches=2 host=scripts/lint/shell-lint.sh"
not_contains "promote: one-branch class not proposed" "$pl" "PROPOSE [one-branch]"
not_contains "promote: recurrences before rung_since do not count" "$pl" "PROPOSE [stale]"
contains "promote: prompt class targets advisory" "$pl" "PROPOSE [prompt-only] prompt -> advisory recurrences=3 branches=3"
not_contains "promote: a finding with no branch is not a distinct branch" "$pl" "PROPOSE [no-branch]"
not_contains "promote: a gate class is never proposed" "$pl" "PROPOSE [already-gated]"
pl2="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder --min-recurrences 3 --min-branches 1 2>&1)"
contains "promote: --min-branches 1 lets the one-branch class cross" "$pl2" "PROPOSE [one-branch] advisory -> gate recurrences=3 branches=1"
pl3="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" KNOWN_FINDINGS_PROMOTE_N=4 bash "$SCRIPT" --ladder 2>&1)"
not_contains "promote: env N=4 raises the bar" "$pl3" "PROPOSE [spread]"
KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder --min-recurrences x >/dev/null 2>&1; check "promote: non-numeric N exits 2" "$?" "2"
cp "$tmp/promo-kf.json" "$tmp/promo-kf-copy.json"
pr="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf-copy.json" CR_LEDGER="$tmp/promo-ledger.jsonl" KNOWN_FINDINGS_PROMOTE_N=3 KNOWN_FINDINGS_PROMOTE_M=2 bash "$SCRIPT" --refresh 2>&1)"
contains "promote: --refresh prints the proposals" "$pr" "PROPOSE [spread] advisory -> gate"
check "promote: refresh never changes a rung" "$(node -e 'console.log(require(process.argv[1]).classes.map(c=>c.rung).join())' "$tmp/promo-kf-copy.json")" "advisory,advisory,advisory,prompt,advisory,gate"
pn="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/absent-ledger.jsonl" bash "$SCRIPT" --ladder 2>&1)"
contains "promote: unreadable ledger says so, no proposals" "$pn" "proposals unavailable"

# ladder v2: a fixed verdict is a real verdict; a finding is attributed to a class only when its
# globs AND the class `match` regex (over the finding text) hit; rebuttal classes never climb above
# prompt (retire instead); platform windows is never proposed; the gate rung needs N=10 M=5 within 30 days.
cat > "$tmp/v2-kf.json" <<'KFJSON'
{"classes":[
{"id":"fx","kind":"fix","rung":"prompt","title":"t","source":"s","globs":["fx/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"glob-only","kind":"fix","rung":"prompt","title":"t","source":"s","globs":["go/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"no-match","kind":"fix","rung":"prompt","title":"t","source":"s","globs":["nm/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"reb","kind":"rebuttal","rung":"prompt","title":"t","source":"s","globs":["reb/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"reb-dead","kind":"rebuttal","rung":"prompt","title":"t","source":"s","globs":["rd/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"win","kind":"fix","rung":"prompt","platform":"windows","title":"t","source":"s","globs":["win/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"adv3","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["adv3/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"adv10","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["adv10/**"],"match":"needle","detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}
]}
KFJSON
vf() { printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"codex","finding_id":"%s","severity":"imp","file":"%s","line":1,"verdict":"%s","text":"%s"}\n' "$@"; }
{
  vf "$(rd 2)" b1 a000001 f1 fx/a.sh fixed "a needle here"
  vf "$(rd 3)" b1 a000002 f2 fx/b.sh fixed "a needle here"
  vf "$(rd 4)" b2 a000003 f3 fx/c.sh "" "a needle here"
  printf '{"kind":"amend","ts":"%s","branch":"b2","target_head":"a000003","finding_id":"f3","set":{"verdict":"fixed"},"reason":"r"}\n' "$(rd 4)"
  vf "$(rd 2)" b1 a000011 g1 go/a.sh fixed "something else"
  vf "$(rd 3)" b1 a000012 g2 go/b.sh fixed "something else"
  vf "$(rd 4)" b2 a000013 g3 go/c.sh fixed "something else"
  vf "$(rd 2)" b1 a000021 n1 nm/a.sh fixed "a needle here"
  vf "$(rd 3)" b1 a000022 n2 nm/b.sh fixed "a needle here"
  vf "$(rd 4)" b2 a000023 n3 nm/c.sh fixed "a needle here"
  for i in 1 2 3 4 5 6 7 8 9 10; do vf "$(rd 2)" "rb$((i % 5))" "a0001$i" "r$i" reb/a.sh fixed "a needle here"; done
  for i in 1 2 3 4 5 6 7 8 9 10; do vf "$(rd 90)" "rd$i" "a0002$i" "d$i" rd/a.sh disproved "a needle here"; done
  vf "$(rd 2)" b1 a000031 w1 win/a.sh fixed "a needle here"
  vf "$(rd 3)" b1 a000032 w2 win/b.sh fixed "a needle here"
  vf "$(rd 4)" b2 a000033 w3 win/c.sh fixed "a needle here"
  vf "$(rd 2)" b1 a000041 x1 adv3/a.sh fixed "a needle here"
  vf "$(rd 3)" b1 a000042 x2 adv3/b.sh fixed "a needle here"
  vf "$(rd 4)" b2 a000043 x3 adv3/c.sh fixed "a needle here"
  for i in 1 2 3 4 5 6 7 8 9 10; do vf "$(rd 5)" "ab$((i % 5))" "a0005$i" "y$i" adv10/a.sh fixed "a needle here"; done
} > "$tmp/v2-ledger.jsonl"
v2="$(KNOWN_FINDINGS_FILE="$tmp/v2-kf.json" CR_LEDGER="$tmp/v2-ledger.jsonl" bash "$SCRIPT" --ladder 2>&1)"
contains "v2: 3 fixed findings across 2 branches propose prompt -> advisory" "$v2" "PROPOSE [fx] prompt -> advisory recurrences=3 branches=2"
not_contains "v2: glob hit without a text match is not attributed" "$v2" "PROPOSE [glob-only]"
not_contains "v2: a class with no match is skipped by the proposals" "$v2" "PROPOSE [no-match]"
not_contains "v2: a rebuttal class is never proposed above prompt" "$v2" "PROPOSE [reb] prompt -> advisory"
contains "v2: a rebuttal class that is mostly disproved with no real finding in 30 days is proposed for retire" "$v2" "PROPOSE [reb-dead] retire"
not_contains "v2: a rebuttal class with real findings in 30 days is not retired" "$v2" "PROPOSE [reb] retire"
not_contains "v2: platform windows is never proposed" "$v2" "PROPOSE [win]"
not_contains "v2: the gate rung needs more than 3 recurrences across 2 branches" "$v2" "PROPOSE [adv3]"
contains "v2: the gate rung is proposed at 10 recurrences across 5 branches within 30 days" "$v2" "PROPOSE [adv10] advisory -> gate recurrences=10 branches=5"
cp "$tmp/v2-kf.json" "$tmp/v2-kf-copy.json"
KNOWN_FINDINGS_FILE="$tmp/v2-kf-copy.json" CR_LEDGER="$tmp/v2-ledger.jsonl" bash "$SCRIPT" --refresh >/dev/null 2>&1
v2q="$(KNOWN_FINDINGS_FILE="$tmp/v2-kf-copy.json" CR_LEDGER="$tmp/v2-ledger.jsonl" bash "$SCRIPT" --ladder 2>&1)"
contains "v2: the queue counts a fixed-only class" "$v2q" "[fx] rung=prompt kind=fix agreed=3"
not_contains "v2: the queue skips a class with no match" "$v2q" "[no-match] rung="
check "v2: --refresh stats count fixed as a real verdict, attributed by match" "$(node -e 'const c=require(process.argv[1]).classes;console.log(c.find(x=>x.id==="fx").evidence.ledger.agreed+","+c.find(x=>x.id==="glob-only").evidence.ledger.findings)' "$tmp/v2-kf-copy.json")" "3,0"
lst="$(bash "$SCRIPT" --list 2>&1)"
for rid in ps1-twin-parity ps1-bom-policy scheduler-task-xml-encoding worker-worktree-plugin-profile; do
  not_contains "retired: $rid is gone from --list" "$lst" "\`$rid\`"
done
check "retired: gnu-only-utility canonical text has no Git Bash" "$(node -e 'console.log(/Git Bash/.test(require(process.argv[1]).classes.find(x=>x.id==="gnu-only-utility").canonical))' "$HERE/known-findings.json")" "false"

# --refresh on a COPY: ledger + learnings evidence rewritten; shipped JSON untouched
cp "$HERE/known-findings.json" "$tmp/kf.json"
before_sum="$(cksum < "$HERE/known-findings.json")"
{
  echo '{"kind":"finding","ts":"2026-08-01T00:00:00Z","branch":"b","head":"aaaa111","model":"codex","finding_id":"codex-1","severity":"imp","file":"scripts/hooks/x.sh","line":1,"verdict":"disproved","text":"fail-open errexit"}'
  echo '{"kind":"finding","ts":"2026-08-01T00:00:01Z","branch":"b","head":"aaaa111","model":"codex","finding_id":"codex-2","severity":"imp","file":"scripts/hooks/x.sh","line":2,"verdict":"","text":"fail-open errexit"}'
  echo '{"kind":"amend","ts":"2026-08-01T00:01:00Z","branch":"b","target_head":"aaaa111","finding_id":"codex-2","set":{"verdict":"agreed"},"reason":"t"}'
  echo '{"kind":"finding","ts":"2026-08-01T00:00:02Z","branch":"b","head":"aaaa111","model":"glm","finding_id":"glm-1","severity":"sug","file":"docs/a.md","line":3,"verdict":"agreed"}'
  # Append-order = last write wins: an amend to codex-1 (disproved→agreed) that
  # lands AFTER a later finding row must still win, and a finding row written
  # after an amend must beat that amend (panel r1 codex-2 on this script).
  echo '{"kind":"finding","ts":"2026-08-01T00:02:00Z","branch":"b","head":"aaaa111","model":"codex","finding_id":"codex-2","severity":"imp","file":"scripts/hooks/x.sh","line":2,"verdict":"disproved"}'
  echo '{"kind":"amend","ts":"2026-08-01T00:03:00Z","branch":"b","target_head":"aaaa111","finding_id":"codex-1","set":{"verdict":"agreed"},"reason":"t"}'
} > "$tmp/ledger.jsonl"
printf 'Learning,Repository,File,Pull Request,URL,Created By,Usage,Last Used,Created At,Updated At\n' > "$tmp/learn.csv"
printf '"In Bash scripts using `set -e`, a bare `wait` returns zero, ""quoted"".",himmel,scripts/a.sh,1,,u,"250","x","y","z"\n' >> "$tmp/learn.csv"  # leak-allow: hostname test fixture CR-learnings CSV row's repository field
printf '"Totally novel learning about widgets\nspanning two lines.",himmel,scripts/b.sh,2,,u,"7","x","y","z"\n' >> "$tmp/learn.csv"  # leak-allow: hostname test fixture CR-learnings CSV row's repository field
r="$(KNOWN_FINDINGS_FILE="$tmp/kf.json" CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --refresh --learnings "$tmp/learn.csv" 2>&1)"; rrc=$?
check "refresh: exit 0" "$rrc" "0"
contains "refresh: hook class sees 2 ledger findings (amend resolved)" "$r" "hook-fail-direction: ledger findings=2 agreed=1 disproved=1"
contains "refresh: errexit learning attributed (250 uses) + shell bucket" "$r" "errexit-false-positive: ledger findings=2 agreed=1 disproved=1 (50%) deferred=0 unadjudicated=0 | learnings rows=1 uses=250"
contains "refresh: unmatched learning surfaced as candidate" "$r" "Totally novel learning"
contains "refresh: export summary" "$r" "learnings export: 2 rows, 257 uses, 1 rows matched no class"
check "refresh: shipped JSON untouched" "$(cksum < "$HERE/known-findings.json")" "$before_sum"
ev="$(node -e 'const j=require(process.argv[1]);const c=j.classes.find(c=>c.id==="errexit-false-positive");console.log(c.evidence.learnings_uses, j.learnings_export.rows, j.refreshed_at.length)' "$tmp/kf.json" 2>&1)"
check "refresh: JSON evidence + export summary + date written" "$ev" "250 2 10"

# A missing ledger must not zero the stored ledger evidence (panel r6 codex-1).
ev_before="$(node -e 'const j=require(process.argv[1]);console.log(JSON.stringify(j.classes.find(c=>c.id==="hook-fail-direction").evidence.ledger))' "$tmp/kf.json" 2>&1)"
rml="$(KNOWN_FINDINGS_FILE="$tmp/kf.json" CR_LEDGER="$tmp/absent-ledger.jsonl" bash "$SCRIPT" --refresh 2>&1)"; rmlrc=$?
check "refresh with a missing ledger still exits 0" "$rmlrc" "0"
contains "refresh with a missing ledger says so" "$rml" "ledger not readable"
ev_after="$(node -e 'const j=require(process.argv[1]);console.log(JSON.stringify(j.classes.find(c=>c.id==="hook-fail-direction").evidence.ledger))' "$tmp/kf.json" 2>&1)"
check "refresh with a missing ledger leaves ledger evidence unchanged" "$ev_after" "$ev_before"

# CodeRabbit's export starts with a UTF-8 BOM (EF BB BF) — the first
# header must still read as "Learning". BOM-free input (learn.csv above) is the control.
{ printf '\357\273\277'; cat "$tmp/learn.csv"; } > "$tmp/learn-bom.csv"
cp "$HERE/known-findings.json" "$tmp/kf-bom.json"
rb="$(KNOWN_FINDINGS_FILE="$tmp/kf-bom.json" CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --refresh --learnings "$tmp/learn-bom.csv" 2>&1)"; rbrc=$?
check "refresh: BOM-prefixed learnings csv exits 0" "$rbrc" "0"
contains "refresh: BOM csv parses (export summary)" "$rb" "learnings export: 2 rows, 257 uses, 1 rows matched no class"

# --prompt: the anchor-handshake rebuttal is present, and the
# framing forbids re-raising it unless the code regressed.
contains "prompt: anchor-handshake rebuttal present" "$p" "[pr-check-anchor-handshake-escalation]"

# ── pr-check-anchor-handshake-escalation must match the REAL
# escalation-claim finding (quoted verbatim from .git/cr-critic-scores.jsonl /
# the CodeRabbit App review on PR #2078) and must NOT match a finding shaped
# like the stale-value residual -- a real, different, still-open
# bug this catalogue entry must never suppress. Exercised through --refresh's
# learning_match attribution (the only place a class's regex is actually
# tested against finding-shaped prose), on a COPY, with an absent ledger so
# only the learnings-attribution path is in play.
cp "$HERE/known-findings.json" "$tmp/kf-anchor.json"
printf 'Learning,Repository,File,Pull Request,URL,Created By,Usage,Last Used,Created At,Updated At\n' > "$tmp/anchor-learn.csv"
{
  printf '"In `scripts/cr/pr-check-context.sh`, `HIMMEL_REPO` and `PR_CHECK_ANCHOR_DELEGATED` are process-environment inputs. The repository under review does not load `.env` files or source repository-supplied paths before the anchor is selected; `scripts/guardrails/lib.sh` is sourced only from `HIMMEL_ROOT`, which derives from the executing script location and is validated as a Himmel checkout. Therefore, an actor that controls the launching environment can replace the anchor through `HIMMEL_REPO` before any delegation-handshake check runs.",himmel,scripts/cr/pr-check-context.sh,2078,,coderabbitai,"9","x","y","z"\n'  # leak-allow: hostname test fixture reproducing the real HIMMEL-2377 CR learning row
  printf '"In `scripts/cr/pr-check-context.sh`, the `PR_CHECK_ANCHOR_DELEGATED` identity handshake currently verifies only the anchor path. A stale value from an earlier run can be accepted on a different branch or HEAD, suppressing delegation and ledger logging while reporting delegated=yes.",himmel,scripts/cr/pr-check-context.sh,2078,,coderabbitai,"4","x","y","z"\n'  # leak-allow: hostname test fixture for the stale-value-residual CR learning row, same incident
} >> "$tmp/anchor-learn.csv"
ar="$(KNOWN_FINDINGS_FILE="$tmp/kf-anchor.json" CR_LEDGER="$tmp/absent-ledger.jsonl" bash "$SCRIPT" --refresh --learnings "$tmp/anchor-learn.csv" 2>&1)"; arrc=$?
[ "$arrc" -eq 0 ] || printf '  (refresh output: %s)
' "$ar" >&2
check "anchor rebuttal: refresh exit 0" "$arrc" "0"
aev="$(node -e 'const j=require(process.argv[1]);const c=j.classes.find(c=>c.id==="pr-check-anchor-handshake-escalation");console.log(c.evidence.learnings_uses+" "+c.evidence.learnings_rows)' "$tmp/kf-anchor.json" 2>&1)"
# The critical assertion: 9 uses / 1 row proves ONLY the escalation-claim CSV
# row attributed here -- the stale-value-shaped row (4 uses) did
# NOT. Were the entry's learning_match broadened to also catch it, this would
# read "13 2" instead -- silently folding a real, still-open bug into a rebuttal
# that tells critics never to re-raise it.
check "anchor rebuttal: ONLY the real escalation-claim learning attributes (9 uses, 1 row, not 13/2)" "$aev" "9 1"

# learnings feed: PROPOSE-CLASS / STALE / PONYTAIL / DUPLICATE / PROMOTE-HINT lines and the re-measure counts.
# Every case runs --refresh on a COPY of the shipped catalogue with its own tiny CSV and an absent ledger.
LHDR='Learning,Repository,File,Pull Request,URL,Created By,Usage,Last Used,Created At,Updated At'
LFILE='scripts/cr/known-findings.sh'
lrow() { printf '"%s",himmel,%s,1,,u,"%s","x","y","z"\n' "$1" "$2" "$3"; }  # leak-allow: hostname test fixture CR-learnings CSV row's repository field
lrun() { # <name> <csv> [status-tsv]; prints the refresh output
  cp "$HERE/known-findings.json" "$tmp/kf-$1.json"
  KNOWN_FINDINGS_FILE="$tmp/kf-$1.json" CR_LEDGER="$tmp/absent-ledger.jsonl" KNOWN_FINDINGS_TICKET_STATUS="${3:-$tmp/no-such-status.tsv}" bash "$SCRIPT" --refresh --learnings "$2" 2>&1
  echo "$?" > "$tmp/rc-$1"
}
{ echo "$LHDR"; lrow 'Always frobnicate the zorble widget quickly.' "$LFILE" 3; lrow 'Never forget to frobnicate the zorble widget slowly.' "$LFILE" 4; } > "$tmp/l-cluster.csv"
lc="$(lrun cluster "$tmp/l-cluster.csv")"
check "feed: two unmatched rows sharing a rule give exactly one PROPOSE-CLASS" "$(printf '%s\n' "$lc" | grep -c '^PROPOSE-CLASS ')" "1"
contains "feed: PROPOSE-CLASS names id, rows, uses and globs" "$lc" "PROPOSE-CLASS id=frobnicate-zorble-widget rows=2 uses=7 globs=scripts/cr/** match=frobnicate[\\s\\S]{1,120}?zorble[\\s\\S]{1,120}?widget kind=fix canonical="
lcm="$(printf '%s\n' "$lc" | sed -n 's/^PROPOSE-CLASS .* match=\(.*\) kind=.*/\1/p')"
check "feed: the proposed match regex matches its own source learning" "$(node -e 'console.log(new RegExp(process.argv[1],"i").test("Always frobnicate the zorble widget quickly."))' "$lcm")" "true"

{ echo "$LHDR"; lrow 'On Windows the pwsh launcher needs a quuxbar wrapper.' "$LFILE" 1; lrow 'A perfectly live frobnitz remark.' "$LFILE" 2; } > "$tmp/l-win.csv"
lw="$(lrun win "$tmp/l-win.csv")"
contains "feed: a Windows row is STALE with the reason" "$lw" "STALE row=1 uses=1 reason=windows"
not_contains "feed: a live row is not STALE" "$lw" "STALE row=2"
contains "feed: summary carries the four counts" "$lw" "learnings_export: rows=2 live_rows=1 stale_rows=1 unmatched_rows=2"
check "feed: counts persist in the JSON summary" "$(node -e 'const e=require(process.argv[1]).learnings_export;console.log(e.rows,e.live_rows,e.stale_rows,e.unmatched_rows)' "$tmp/kf-win.json")" "2 1 1 2"

{ echo "$LHDR"; lrow 'GLM glitch handling for the blorptag wrapper.' "$LFILE" 1; lrow 'Check the zonkdrift wrapper handles empty input.' 'scripts/cr/no-such-file-zz.sh' 2; lrow 'Private repo propagation must skip the vaultish dir.' "$LFILE" 1; } > "$tmp/l-gone.csv"
lg="$(lrun gone "$tmp/l-gone.csv")"
contains "feed: a GLM row is STALE" "$lg" "STALE row=1 uses=1 reason=glm"
contains "feed: a row citing a file absent from git ls-files is STALE file-gone" "$lg" "STALE row=2 uses=2 reason=file-gone"
contains "feed: a private-repo propagation row is STALE" "$lg" "STALE row=3 uses=1 reason=private-repo-propagation"
{ echo "$LHDR"; printf '"Check the zonkdrift wrapper handles empty input.",other-repo,scripts/no-such-file-zz.sh,1,,u,"2","x","y","z"\n'; } > "$tmp/l-other.csv"  # leak-allow: fixture row from another repository
not_contains "feed: a missing file in ANOTHER repository is not file-gone" "$(lrun other "$tmp/l-other.csv")" "reason=file-gone"
{ echo "$LHDR"; printf '"Check the zonkdrift wrapper handles empty input.",someone/Himmel,scripts/no-such-file-zz.sh,1,,u,"2","x","y","z"\n'; printf '"Check the quuxfold wrapper handles empty input.",,scripts/no-such-file-zz.sh,1,,u,"2","x","y","z"\n'; } > "$tmp/l-ident.csv"  # leak-allow: fixture rows with a foreign owner and an unknown repository
not_contains "feed: a same-basename repository under another owner or an unknown repository is not file-gone" "$(lrun ident "$tmp/l-ident.csv")" "reason=file-gone"

printf 'HIMMEL-7001\tIn Progress\nHIMMEL-7002\tDone\n' > "$tmp/status.tsv"
{ echo "$LHDR"; lrow 'Defer the snarfle cache fix to HIMMEL-7001 until later.' "$LFILE" 2; lrow 'Defer the gizmo rewrite to HIMMEL-7002 for now.' "$LFILE" 2; } > "$tmp/l-defer.csv"
ld="$(lrun defer "$tmp/l-defer.csv" "$tmp/status.tsv")"
contains "feed: a row deferring to an open ticket is PONYTAIL" "$ld" "PONYTAIL row=1 uses=2 ticket=HIMMEL-7001 status=In Progress"
contains "feed: a row deferring to a Done ticket is STALE" "$ld" "STALE row=2 uses=2 reason=closed-deferral HIMMEL-7002 (Done)"
lu="$(lrun deferu "$tmp/l-defer.csv")"
not_contains "feed: unavailable Jira status never makes a row STALE" "$lu" "reason=closed-deferral"
contains "feed: unavailable Jira status is reported as unknown" "$lu" "STATUS-UNKNOWN row=2 ticket=HIMMEL-7002"

{ echo "$LHDR"; lrow 'Identical wibblefrotz remark about the same rule head here.' "$LFILE" 1; lrow 'Identical wibblefrotz remark about the same rule head here.' "$LFILE" 1; } > "$tmp/l-dup.csv"
lp="$(lrun dup "$tmp/l-dup.csv")"
check "feed: two rows with the same file and rule head are one DUPLICATE group" "$(printf '%s\n' "$lp" | grep -c '^DUPLICATE ')" "1"
contains "feed: DUPLICATE lists the rows" "$lp" "DUPLICATE rows=1,2 uses=2"
{ echo "$LHDR"; lrow 'Identical wibblefrotz remark about the same rule head here.' "$LFILE" 1; printf '"Identical wibblefrotz remark about the same rule head here.",other-repo,%s,1,,u,"1","x","y","z"\n' "$LFILE"; } > "$tmp/l-dupr.csv"  # leak-allow: fixture row from another repository
not_contains "feed: same file and head in different repositories is not a DUPLICATE" "$(lrun dupr "$tmp/l-dupr.csv")" "DUPLICATE "
fill="$(printf 'the %.0s' $(seq 1 60))"
{ echo "$LHDR"; lrow "Always frobnicate $fill zorble widget quickly." "$LFILE" 3; lrow 'Never forget to frobnicate the zorble widget slowly.' "$LFILE" 4; } > "$tmp/l-mc.csv"
contains "feed: a proposal that misses a source row is flagged match-check=failed" "$(lrun mc "$tmp/l-mc.csv")" "match-check=failed"
not_contains "feed: a proposal matching every source row carries no match-check flag" "$lc" "match-check=failed"
{ echo "$LHDR"; lrow 'Always frobnicate the zorble widget quickly.' "$LFILE" 3; printf '"Never forget to frobnicate the zorble widget slowly.",other-repo,%s,1,,u,"4","x","y","z"\n' "$LFILE"; } > "$tmp/l-clr.csv"  # leak-allow: fixture row from another repository
not_contains "feed: rows from different repositories never form one cluster" "$(lrun clr "$tmp/l-clr.csv")" "PROPOSE-CLASS "
{ echo "$LHDR"; lrow 'Always frobnicate the zorble widget quickly.' "$LFILE" 3; lrow 'Never forget to frobnicate the zorble widget slowly.' "$LFILE" 4; lrow 'Always frobnicate the zorble widget quickly.' 'docs/internals/known-findings.md' 3; lrow 'Never forget to frobnicate the zorble widget slowly.' 'docs/internals/testing.md' 4; } > "$tmp/l-id.csv"
check "feed: two clusters sharing a phrase get distinct ids" "$(lrun id "$tmp/l-id.csv" | sed -n 's/^PROPOSE-CLASS id=\([^ ]*\) .*/\1/p' | sort -u | wc -l | tr -d ' ')" "2"
{ echo "$LHDR"; lrow 'A very popular quuzmarker rule.' "$LFILE" 120; } > "$tmp/l-hot.csv"
contains "feed: a row with 100+ uses gets a promotion hint" "$(lrun hot "$tmp/l-hot.csv")" "PROMOTE-HINT row=1 uses=120"

for rcf in "$tmp"/rc-*; do check "feed: refresh exits 0 ($(basename "$rcf"))" "$(cat "$rcf")" "0"; done

# --diff --area gives each hit a state; an open hit blocks (exit 3) until a preflight row closes it
contains "diff: new hook with no bypass var is flagged" "$out" "[hook-no-bypass-row]"
AL="$tmp/area-ledger.jsonl"; : > "$AL"
bout="$(cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area 2>&1)"; brc=$?
check "area: an open hit exits 3" "$brc" "3"
contains "area: each hit carries a state slot" "$bout" "state=open"
contains "area: prints the preflight summary line" "$bout" "preflight: classes hit"
contains "area: summary names fixed, waived and checked" "$bout" "· fixed 0 · waived 0 · checked 0"
bash "$SCRIPT" --area >/dev/null 2>&1; check "area: --area without --diff → exit 2" "$?" "2"
abranch="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
ajson="$(cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area --json 2>&1)"
AJ="$ajson" AB="$abranch" AH="$(cd "$repo" && git rev-parse HEAD)" node -e 'const j=JSON.parse(process.env.AJ);const hs=j.hits.map((h,i)=>({class:h.id,state:i===0?"checked":"waived",...(i===0?{}:{ref:"fixture"})}));console.log(JSON.stringify({kind:"preflight",branch:process.env.AB,head:process.env.AH,hits:hs}))' > "$AL"
cout="$(cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area 2>&1)"; crc=$?
check "area: a preflight row closing every hit exits 0" "$crc" "0"
not_contains "area: no hit stays open after the pass is recorded" "$cout" "state=open"
contains "area: a waived hit shows its state and reason" "$cout" "state=waived (fixture)"
printf '%s\n' '{"kind":"preflight","branch":"other-branch","head":"x","hits":[]}' >> "$AL"
cp "$AL" "$AL.cur"
AJ="$ajson" AB="$abranch" node -e 'const j=JSON.parse(process.env.AJ);const hs=j.hits.map(h=>({class:h.id,state:"checked"}));console.log(JSON.stringify({kind:"preflight",branch:process.env.AB,head:"0000000",hits:hs}))' >> "$AL"
( cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area >/dev/null 2>&1 ); erc=$?
check "area: a preflight row recorded at an older head closes nothing" "$erc" "3"
cp "$AL.cur" "$AL"
AJ="$ajson" AB="$abranch" AH="$(cd "$repo" && git rev-parse HEAD)" node -e 'const j=JSON.parse(process.env.AJ);const hs=j.hits.map(h=>({class:h.id,state:"fixed"}));console.log(JSON.stringify({kind:"preflight",branch:process.env.AB,head:process.env.AH,hits:hs}))' >> "$AL"
( cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area >/dev/null 2>&1 ); frc=$?
check "area: a class recorded fixed that still hits stays open" "$frc" "3"
cp "$AL.cur" "$AL"
AL2="$tmp/e2e-ledger.jsonl"; : > "$AL2"
e2e_hits=(); while IFS= read -r e2e_id; do e2e_hits+=(--hit "$e2e_id=checked"); done < <(AJ="$ajson" node -e 'for (const h of JSON.parse(process.env.AJ).hits) console.log(h.id)')
( cd "$repo" && CR_LEDGER="$AL2" bash "$HERE/ledger-append.sh" preflight --head "$(git rev-parse HEAD)" "${e2e_hits[@]}" >/dev/null 2>&1 )
( cd "$repo" && CR_LEDGER="$AL2" bash "$SCRIPT" --diff "$base...HEAD" --area >/dev/null 2>&1 ); e2rc=$?
check "area: a pass written by ledger-append without --branch closes the hits" "$e2rc" "0"
( cd "$repo" && CR_LEDGER="$AL" bash "$SCRIPT" --diff "$base...HEAD" --area >/dev/null 2>&1 ); drc=$?
check "area: a preflight row of another branch is ignored, the latest own row still holds" "$drc" "0"

# usage contract
bash "$SCRIPT" >/dev/null 2>&1; check "no mode → exit 2" "$?" "2"
# bare --diff defaults to <default-branch>...HEAD (the fixture HEAD IS its default branch → empty diff → clean)
outd="$(cd "$repo" && bash "$SCRIPT" --diff 2>&1)"; rcd=$?
check "bare --diff exits 0 (default range)" "$rcd" "0"
contains "bare --diff on the default branch reads clean" "$outd" "no known class matches"
bash "$SCRIPT" --bogus >/dev/null 2>&1; check "unknown option → exit 2" "$?" "2"
KNOWN_FINDINGS_FILE="$tmp/nope.json" bash "$SCRIPT" --list >/dev/null 2>&1; check "missing JSON → exit 2" "$?" "2"
bash "$SCRIPT" --refresh --learnings "$tmp/nope.csv" >/dev/null 2>&1; check "missing learnings csv → exit 2" "$?" "2"
( cd "$repo" && bash "$SCRIPT" --diff "nosuchref...HEAD" >/dev/null 2>&1 ); check "bad range → exit 2, not a false clean" "$?" "2"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
