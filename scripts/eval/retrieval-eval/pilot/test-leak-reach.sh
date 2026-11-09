#!/usr/bin/env bash
# test-leak-reach.sh -- B6 of the RAG pilot: the P12 leak scan (local reads only, never a search),
# collection-coverage and reachability boundaries, and the free G3 runner with its separate G0
# record (free-checks.sh). Fixture data only; no session, no model, no network, nothing billed.
#
# Platform guard: Linux bash (the reach rows SKIP loudly without an unprivileged bwrap).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixtures/leak"
LS="$HERE/leak-scan.py"
FC="$HERE/free-checks.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-leak.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
j() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }

mkdir -p "$W/ex/himmel/docs" "$W/ex/luna/notes" "$W/run/private" "$W/run/retained" "$W/bin"
printf '# Lock\nThe queue lock keeps one session per handover doc.\n' > "$W/ex/himmel/docs/lock.md"
printf '# Garden\nWater the tomatoes on Tuesdays.\n' > "$W/ex/luna/notes/garden.md"
cat > "$W/run/private/tasks.jsonl" <<'EOF'
{"id": "tq-0017", "question": "How many sessions may hold one handover document at a time?", "facts": [{"text": "one session per handover doc", "variants": []}], "files": [{"repo": "himmel", "path": "docs/lock.md"}]}
{"id": "tq-0023", "question": "On which weekday are the garden tomatoes watered?", "facts": [{"text": "Tuesdays", "variants": []}], "files": [{"repo": "luna", "path": "notes/garden.md"}]}
EOF
B="$W/run/private/tasks.jsonl"
for t in qmd graphify s-qmd; do cp "$FX/search-tripwire" "$W/bin/$t"; chmod +x "$W/bin/$t"; done
export TRIPWIRE_LOG="$W/tripwire.log" PATH="$W/bin:$PATH"
python3 -I - "$W/index.sqlite" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY, collection TEXT, path TEXT, title TEXT, hash TEXT)")
c.execute("CREATE TABLE content (hash TEXT PRIMARY KEY, doc TEXT)")
c.execute("CREATE TABLE llm_cache (hash TEXT, result TEXT)")
c.execute("INSERT INTO documents VALUES (1, 'himmel', 'docs/lock.md', 'Lock', 'h1')")
c.execute("INSERT INTO content VALUES ('h1', 'The queue lock keeps one session per handover doc.')")
c.execute("INSERT INTO llm_cache VALUES ('x', 'How many sessions may hold one handover document at a time?')")
c.commit()
EOF
scan() { python3 -I "$LS" --bank "$B" --export himmel="$W/ex/himmel" --export luna="$W/ex/luna" --private "$W/run/private" "$@"; }
scan --index "$W/index.sqlite" > "$W/clean.json"; rc=$?
eq "P12: clean copies and index scan clean" "0 0 0 0" "$rc $(j "$W/clean.json" question_leaks) $(j "$W/clean.json" id_leaks) $(j "$W/clean.json" private_path_leaks)"
eq "P12: the query cache is not corpus text (a cached question there is not a copy leak)" 0 "$(j "$W/clean.json" sources_with_leaks.index)"
eq "P12: required facts are listed for the checker, never a failure" '{"facts": 2, "never_seen": 0, "seen_in_sources": 2}' "$(j "$W/clean.json" facts_for_checker)"
eq "P12: the scan never searched (no qmd, graphify or s-qmd call)" "absent" "$([ -s "$W/tripwire.log" ] && echo present || echo absent)"
cp -r "$W/ex" "$W/ex-leak"; printf '\nasked: how many sessions may hold ONE handover\ndocument at a time?\n' >> "$W/ex-leak/himmel/docs/lock.md"
python3 -I "$LS" --bank "$B" --export himmel="$W/ex-leak/himmel" --export luna="$W/ex-leak/luna" > "$W/l1.json"; rc=$?
eq "P12: a task question planted in a copy (re-wrapped, re-cased) is detected" "3 1" "$rc $(j "$W/l1.json" question_leaks)"
eq "P12: the report never prints the leaked text" 0 "$(grep -c -i 'handover document' "$W/l1.json")"
cp "$W/index.sqlite" "$W/index-leak.sqlite"; sqlite3 "$W/index-leak.sqlite" "update content set doc = doc || ' see task tq-0023' where hash='h1'"
scan --index "$W/index-leak.sqlite" > "$W/l2.json"; rc=$?
eq "P12: a task id planted in an index text row is detected" "3 1 1" "$rc $(j "$W/l2.json" id_leaks) $(j "$W/l2.json" sources_with_leaks.index)"
cp -r "$W/ex" "$W/ex-path"; printf 'see %s/tasks.jsonl\n' "$W/run/private" >> "$W/ex-path/luna/notes/garden.md"
python3 -I "$LS" --bank "$B" --export himmel="$W/ex-path/himmel" --export luna="$W/ex-path/luna" --private "$W/run/private" > "$W/l3.json"; rc=$?
eq "P12: a private run path in a copy is detected (it names both the private dir and the bank file)" "3 2" "$rc $(j "$W/l3.json" private_path_leaks)"
python3 -I "$LS" --bank "$B" --export himmel="$W/ex-leak/himmel" --private-out "$W/private-findings.json" > /dev/null
eq "P12: which task leaked goes only to a private file" "600 tq-0017" "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$W/private-findings.json") $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["found"]["questions"][0][0])' "$W/private-findings.json")"
python3 -I "$LS" --bank "$B" --export himmel="$W/no-such-export" > /dev/null 2>&1
eq "P12: a requested export root that does not exist refuses, never a clean verdict" 3 "$?"
mkdir -p "$W/empty-export"
python3 -I "$LS" --bank "$B" --export himmel="$W/empty-export" > /dev/null 2>&1
eq "P12: a scan that read nothing refuses" 3 "$?"
cp -r "$W/ex" "$W/ex-auto"; printf 'see %s/retained/run-1.json\n' "$W/run" >> "$W/ex-auto/luna/notes/garden.md"
python3 -I "$LS" --bank "$B" --export himmel="$W/ex-auto/himmel" --export luna="$W/ex-auto/luna" --run-root "$W/run" > "$W/l4.json"; rc=$?
eq "P12: the run root's retained/ path is checked without being passed as --private" "3 1" "$rc $(j "$W/l4.json" private_path_leaks)"
cp -r "$W/ex" "$W/ex-bankpath"; printf 'bank at %s\n' "$B" >> "$W/ex-bankpath/luna/notes/garden.md"
python3 -I "$LS" --bank "$B" --export himmel="$W/ex-bankpath/himmel" --export luna="$W/ex-bankpath/luna" > "$W/l5.json"; rc=$?
eq "P12: the bank file's own path is always a private path" "3 1" "$rc $(j "$W/l5.json" private_path_leaks)"
printf 'collections:\n  vault:\n    path: %s\n' "$W" > "$W/covering.yml"
printf 'collections:\n  himmel:\n    path: %s\n' "$W/ex/himmel" > "$W/scoped.yml"
scan --config "$W/covering.yml" --run-root "$W/run" > "$W/c1.json"; rc=$?
eq "P12: a qmd collection that covers the run root fails" "3 1" "$rc $(j "$W/c1.json" collection_covers_run_root)"
eq "P12: a collection scoped to the copies passes" 0 "$(scan --config "$W/scoped.yml" --run-root "$W/run" > /dev/null; echo $?)"

# --- free-checks: the G3 report and the separate G0 record
printf '' > "$W/outcomes"
FRUN=(--suite-runner "$FX/fake-runner")
FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-a.json" "${FRUN[@]}" > /dev/null 2>&1
eq "G3: without live P12/reach inputs the report is INCOMPLETE, never PASS" '"INCOMPLETE" "SKIP" "SKIP"' "$(j "$W/g3-a.json" g3) $(j "$W/g3-a.json" checks.P12.status) $(j "$W/g3-a.json" checks.P15-live.status)"
eq "G3: missing auth readiness is recorded blocked with zero paid calls, while the unpaid checks still ran" '"blocked: no auth-readiness record" 0 "PASS"' "$(j "$W/g3-a.json" g0) $(j "$W/g3-a.json" paid_calls) $(j "$W/g3-a.json" checks.P10.status)"
LIVE=(--bank "$B" --export himmel="$W/ex/himmel" --export luna="$W/ex/luna" --index "$W/index.sqlite" --private "$W/run/private" --config "$W/scoped.yml" --run-root "$W/run")
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null; then
  mkdir -p "$W/home"; cp "$HERE/fixtures/run/stub-claude" "$W/stub-claude"; chmod +x "$W/stub-claude"
  REACH=(--reach-claude "$W/stub-claude" --reach-private "$W/run/private/tasks.jsonl" --reach-station "$W/station-cred" --reach-home "$W/home")
  printf 'x\n' > "$W/station-cred"
  FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-b.json" "${FRUN[@]}" "${LIVE[@]}" "${REACH[@]}" > /dev/null 2>&1
  eq "G3: every check passing is a G3 PASS" '"PASS" "PASS" "PASS"' "$(j "$W/g3-b.json" g3) $(j "$W/g3-b.json" checks.P12.status) $(j "$W/g3-b.json" checks.P15-live.status)"
  eq "G3: a fixture G3 PASS never forges paid readiness" 'false "blocked: no auth-readiness record"' "$(j "$W/g3-b.json" paid_ready) $(j "$W/g3-b.json" g0)"
  mkdir -p "$W/ex-bad/himmel"; cp -r "$W/ex/luna" "$W/ex-bad/luna"; cp -r "$W/run/private" "$W/ex-bad/himmel/private"
  FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-c.json" "${FRUN[@]}" --bank "$B" --export himmel="$W/ex-bad/himmel" --export luna="$W/ex-bad/luna" \
    --reach-claude "$W/stub-claude" --reach-private /work/himmel/private/tasks.jsonl --reach-station "$W/station-cred" --reach-home "$W/home" > /dev/null 2>&1
  eq "P15: a private task file reachable through a mis-built copy fails the reach check" '"FAIL" "FAIL"' "$(j "$W/g3-c.json" checks.P15-live.status) $(j "$W/g3-c.json" g3)"
  FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-d.json" "${FRUN[@]}" "${LIVE[@]}" --reach-claude "$(command -v python3)" --reach-private x --reach-station y > /dev/null 2>&1
  eq "P15: the reach probe refuses to run a real (ELF) binary as the CLI" '"FAIL"' "$(j "$W/g3-d.json" checks.P15-live.status)"
else
  printf 'SKIP - reach rows: no unprivileged bwrap on this host\n'
fi
printf 'test-q-runtime.sh skip\n' > "$W/outcomes"
FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-e.json" "${FRUN[@]}" "${LIVE[@]}" > /dev/null 2>&1
eq "G3: a skipped real-Q runtime fixture is not a pass" '"SKIP" "INCOMPLETE"' "$(j "$W/g3-e.json" checks.P13-Q.status) $(j "$W/g3-e.json" g3)"
printf 'test-score.sh fail\n' > "$W/outcomes"
FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-f.json" "${FRUN[@]}" "${LIVE[@]}" > /dev/null 2>&1; rc=$?
eq "G3: a failing free check fails G3" '"FAIL" "FAIL" 1' "$(j "$W/g3-f.json" checks.P10.status) $(j "$W/g3-f.json" g3) $rc"
eq "G3: --require-runtime is passed to the real-Q runtime fixture" "--require-runtime" "$(FAKE_OUTCOMES="$W/outcomes" bash "$FC" --out "$W/g3-g.json" --suite-runner echo --require-runtime > /dev/null 2>&1; j "$W/g3-g.json" checks.P13-Q.detail | grep -o -- '--require-runtime' | head -1)"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all leak/reach rows passed\n'
