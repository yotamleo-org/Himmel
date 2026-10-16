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
contains "diff: twin parity"                   "$out" "[ps1-twin-parity]"
contains "diff: twin names the unchanged ps1"  "$out" "twin foo.ps1 unchanged"
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

# promotion proposals: agreed recurrences since the rung was set (optional
# `rung_since`, else the whole ledger) across distinct branches; PROPOSE when >= N and >= M.
cat > "$tmp/promo-kf.json" <<'KFJSON'
{"classes":[
{"id":"spread","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["spread/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"shell-lint [x] (advisory)","prompt":false,"evidence":{}},
{"id":"one-branch","kind":"fix","rung":"advisory","title":"t","source":"s","globs":["onebranch/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"stale","kind":"fix","rung":"advisory","rung_since":"2026-09-01","title":"t","source":"s","globs":["stale/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}},
{"id":"prompt-only","kind":"rebuttal","rung":"prompt","title":"t","source":"s","globs":["ponly/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":true,"evidence":{}},
{"id":"already-gated","kind":"fix","rung":"gate","title":"t","source":"s","globs":["gated/**"],"detector":null,"learning_match":null,"canonical":"c","coverage":"c","prompt":false,"evidence":{}}
]}
KFJSON
pf() { printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"codex","finding_id":"%s","severity":"imp","file":"%s","line":1,"verdict":"agreed"}\n' "$@"; }
{
  pf 2026-09-10T00:00:00Z b1 aaaaaaa f1 spread/a.sh
  pf 2026-09-11T00:00:00Z b2 bbbbbbb f2 spread/b.sh
  pf 2026-09-12T00:00:00Z b2 ccccccc f3 spread/c.sh
  pf 2026-09-10T00:00:00Z b1 ddddddd f4 onebranch/a.sh
  pf 2026-09-11T00:00:00Z b1 eeeeeee f5 onebranch/b.sh
  pf 2026-09-12T00:00:00Z b1 fffffff f6 onebranch/c.sh
  pf 2026-08-10T00:00:00Z b1 1111111 f7 stale/a.sh
  pf 2026-08-11T00:00:00Z b2 2222222 f8 stale/b.sh
  pf 2026-08-12T00:00:00Z b3 3333333 f9 stale/c.sh
  pf 2026-09-10T00:00:00Z b1 4444444 f10 ponly/a.md
  pf 2026-09-11T00:00:00Z b2 5555555 f11 ponly/b.md
  pf 2026-09-12T00:00:00Z b3 6666666 f12 ponly/c.md
  pf 2026-09-10T00:00:00Z b1 7777777 f13 gated/a.sh
  pf 2026-09-11T00:00:00Z b2 8888888 f14 gated/b.sh
  pf 2026-09-12T00:00:00Z b3 9999999 f15 gated/c.sh
} > "$tmp/promo-ledger.jsonl"
pl="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder 2>&1)"; plrc=$?
check "promote: --ladder exit 0" "$plrc" "0"
contains "promote: section header names N and M" "$pl" "promotion proposals (agreed recurrences >= 3 across >= 2 branches"
contains "promote: crossing class proposed with rung, counts, host" "$pl" "PROPOSE [spread] advisory -> gate recurrences=3 branches=2 host=scripts/lint/shell-lint.sh"
not_contains "promote: one-branch class not proposed" "$pl" "PROPOSE [one-branch]"
not_contains "promote: recurrences before rung_since do not count" "$pl" "PROPOSE [stale]"
contains "promote: prompt class targets advisory" "$pl" "PROPOSE [prompt-only] prompt -> advisory recurrences=3 branches=3"
not_contains "promote: a gate class is never proposed" "$pl" "PROPOSE [already-gated]"
pl2="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder --min-recurrences 3 --min-branches 1 2>&1)"
contains "promote: --min-branches 1 lets the one-branch class cross" "$pl2" "PROPOSE [one-branch] advisory -> gate recurrences=3 branches=1"
pl3="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" KNOWN_FINDINGS_PROMOTE_N=4 bash "$SCRIPT" --ladder 2>&1)"
not_contains "promote: env N=4 raises the bar" "$pl3" "PROPOSE [spread]"
KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --ladder --min-recurrences x >/dev/null 2>&1; check "promote: non-numeric N exits 2" "$?" "2"
cp "$tmp/promo-kf.json" "$tmp/promo-kf-copy.json"
pr="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf-copy.json" CR_LEDGER="$tmp/promo-ledger.jsonl" bash "$SCRIPT" --refresh 2>&1)"
contains "promote: --refresh prints the proposals" "$pr" "PROPOSE [spread] advisory -> gate"
check "promote: refresh never changes a rung" "$(node -e 'console.log(require(process.argv[1]).classes.map(c=>c.rung).join())' "$tmp/promo-kf-copy.json")" "advisory,advisory,advisory,prompt,gate"
pn="$(KNOWN_FINDINGS_FILE="$tmp/promo-kf.json" CR_LEDGER="$tmp/absent-ledger.jsonl" bash "$SCRIPT" --ladder 2>&1)"
contains "promote: unreadable ledger says so, no proposals" "$pn" "proposals unavailable"

# --refresh on a COPY: ledger + learnings evidence rewritten; shipped JSON untouched
cp "$HERE/known-findings.json" "$tmp/kf.json"
before_sum="$(cksum < "$HERE/known-findings.json")"
{
  echo '{"kind":"finding","ts":"2026-08-01T00:00:00Z","branch":"b","head":"aaaa111","model":"codex","finding_id":"codex-1","severity":"imp","file":"scripts/hooks/x.sh","line":1,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-08-01T00:00:01Z","branch":"b","head":"aaaa111","model":"codex","finding_id":"codex-2","severity":"imp","file":"scripts/hooks/x.sh","line":2,"verdict":""}'
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
