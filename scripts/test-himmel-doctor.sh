#!/usr/bin/env bash
# shellcheck disable=SC2154  # failures is set by the sourced testlib
# Usage: bash scripts/test-himmel-doctor.sh
set -uo pipefail
# shellcheck source=tests/testlib-himmel-doctor.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-himmel-doctor.sh"

echo "== clean settings (node resolvable) -> exit 0 =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "clean -> rc0"; else fail "clean -> rc=$rc; $(printf '%s' "$out" | grep FAIL)"; fi
# write_settings' fixture carries no PreToolUse block at all -> guardrail-block.mjs
# detects mode=project -> C1-guardrail has nothing to check.
if grepq "$out" 'OK   C1-guardrail'; then pass "clean -> C1-guardrail OK (no guardrail block)"; else fail "clean -> $(printf '%s' "$out" | grep C1-guardrail)"; fi
rm -rf "$t"

# a full doctor run refreshes the statusline counts; a subset run
# (a *_SKIP seam set) never does. State dir pinned to a temp dir.
echo "== counts file: full run writes it, subset run does not =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-counts.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; write_settings "$t/claude" "$WRAPPER"
sub_out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_DOCTOR_STATE_DIR="$t/sub" bash "$DOC" --no-color 2>&1)"
if grepq "$sub_out" 'Summary:' && [ ! -e "$t/sub/counts" ]; then pass "subset run (SKIP seams set) reaches its Summary and writes no counts"; else fail "subset run: no Summary or wrote counts: $(printf '%s' "$sub_out" | tail -3)"; fi
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_DOCTOR_STATE_DIR="$t/full" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_ORPHAN_SCAN_SKIP=0 bash "$DOC" --no-color 2>&1)"
want="$(printf '%s\n' "$out" | sed -n -E 's/^Summary: ([0-9]+) FAIL +([0-9]+) WARN.*/fail=\1 warn=\2/p')"
if [ -n "$want" ] && [ "$(cat "$t/full/counts" 2>/dev/null)" = "$want" ]; then pass "full run writes counts matching its Summary ($want)"; else fail "full run counts '$(cat "$t/full/counts" 2>/dev/null)' != '$want'"; fi
# last.tsv is written with the counts from the same run, and a run
# from a linked worktree judges the station (primary) checkout, so it publishes
# the same state; a --root run judges another checkout and publishes nothing.
tsv_agrees_with_run() {
    local d="$1" run="$2" nl nd ne wl rows ids
    rows="$(grep '^FAIL \|^WARN ' "$d/last.tsv" | sort)"; nl="$(printf '%s\n' "$rows" | grep -c .)"
    ids="$(printf '%s\n' "$run" | sed -n -E 's/^(FAIL|WARN) +([^ :]+):.*/\1 \2/p' | sort -u)"; nd="$(printf '%s\n' "$ids" | grep -c .)"
    ne="$(printf '%s\n' "$run" | grep -c -E '^(FAIL|WARN) ')"
    wl="$(sed -n -E 's/^fail=([0-9]+) warn=([0-9]+)$/\1 \2/p' "$d/counts" | awk '{print $1+$2}')"
    [ "$rows" = "$ids" ] && [ "$wl" = "$ne" ] && { AGREE="$nl rows = $nd distinct ids, counts $wl = $ne emits"; return 0; }
    AGREE="last.tsv has $nl rows, run has $nd distinct ids; counts say $wl, run emitted $ne"; return 1
}
if [ -e "$t/full/last.tsv" ]; then
    if tsv_agrees_with_run "$t/full" "$out"; then pass "full run writes last.tsv matching the counts ($AGREE)"; else fail "last.tsv vs counts: $AGREE"; fi
else fail "full run did not write last.tsv"; fi
ctl="$t/ctl"; mkdir -p "$ctl"; ctl_out="$(printf 'WARN C1-a: x\nWARN C1-a: y\nFAIL C2-b: z\n')"
printf 'WARN C1-a\nWARN C1-a\nFAIL C2-b\n' > "$ctl/keys"
( . "$REPO_ROOT/scripts/doctor-counts.sh" && doctor_state_publish "$ctl" "$ctl/keys" 1 2 )
if tsv_agrees_with_run "$ctl" "$ctl_out"; then pass "control: a doubled id publishes one row and counts twice ($AGREE)"; else fail "control: a doubled id disagrees: $AGREE"; fi
printf 'fail=1 warn=1\n' > "$ctl/counts"
if tsv_agrees_with_run "$ctl" "$ctl_out"; then fail "control: counts from another run still agree"; else pass "control: counts from another run disagree"; fi
printf 'fail=1 warn=2\n' > "$ctl/counts"; printf 'FAIL C2-b\n' > "$ctl/last.tsv"
if tsv_agrees_with_run "$ctl" "$ctl_out"; then fail "control: a last.tsv from another run still agrees"; else pass "control: a last.tsv from another run disagrees"; fi
printf 'FAIL C9-z\nWARN C1-a\n' > "$ctl/last.tsv"
if tsv_agrees_with_run "$ctl" "$ctl_out"; then fail "control: a same-sized last.tsv with another id still agrees"; else pass "control: a same-sized last.tsv with another id disagrees"; fi
WTD="$t/wt"
if git -C "$REPO_ROOT" worktree add -q --detach "$WTD" HEAD 2>/dev/null; then
    # the fixture checks out HEAD; overlay the doctor under test so an
    # uncommitted change is what the worktree run executes.
    cp "$REPO_ROOT/scripts/himmel-doctor.sh" "$REPO_ROOT/scripts/doctor-counts.sh" "$WTD/scripts/"
    cp "$REPO_ROOT/scripts/graphify/check-graph-freshness.sh" "$REPO_ROOT/scripts/graphify/semantic-merge.py" "$WTD/scripts/graphify/"
    cp "$REPO_ROOT/scripts/lib/himmel-secrets" "$REPO_ROOT/scripts/lib/load-dotenv.sh" "$WTD/scripts/lib/"
    (cd "$WTD" && RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_DOCTOR_STATE_DIR="$t/wtstate" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_ORPHAN_SCAN_SKIP=0 bash "$WTD/scripts/himmel-doctor.sh" --no-color >/dev/null 2>&1)
    if [ -n "$want" ] && [ "$(cat "$t/wtstate/counts" 2>/dev/null)" = "$want" ] && cmp -s "$t/full/last.tsv" "$t/wtstate/last.tsv"; then pass "a worktree run publishes the same counts and last.tsv as the primary run"; else fail "worktree run state differs from the primary run: '$(cat "$t/wtstate/counts" 2>/dev/null)' vs '$want'"; fi
    root_out="$(cd "$WTD" && RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_DOCTOR_STATE_DIR="$t/rootstate" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_ORPHAN_SCAN_SKIP=0 bash "$WTD/scripts/himmel-doctor.sh" --no-color --root "$WTD" 2>&1)"
    if grepq "$root_out" 'Summary:' && [ ! -e "$t/rootstate/counts" ] && [ ! -e "$t/rootstate/last.tsv" ]; then pass "a --root run completes its report and publishes no counts and no last.tsv"; else fail "a --root run: no Summary or wrote state"; fi
    git -C "$REPO_ROOT" worktree remove --force "$WTD" >/dev/null 2>&1; git -C "$REPO_ROOT" worktree prune
else fail "could not create the worktree fixture"; fi
rm -rf "$t"

# P1: --json is the config UI's status feed. stdout must carry
# ONLY one JSON object per emit() call (everything else goes to stderr), and
# the row count and exit code must match a text run of the same fixture.
echo "== --json -> stdout is one JSON object per emit, nothing else =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-json.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; write_settings "$t/claude" "$WRAPPER"
txt="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>/dev/null)"; rc_txt=$?
js="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --json --no-color 2>/dev/null)"; rc_js=$?
n_txt="$(grep -cE '^(FAIL|WARN|INFO|OK) ' <<< "$txt")"
n_js="$(grep -c . <<< "$js")"
if jq -e -s 'length > 0 and all(.[]; ((keys - ["repo"]) == ["id","msg","remedy","scope","sev"]) and (.sev | IN("FAIL","WARN","INFO","OK")))' <<< "$js" >/dev/null 2>&1; then
    pass "--json -> every stdout line is a {sev,id,msg,remedy,scope[,repo]} object"
else
    fail "--json -> stdout is not JSON lines: $(head -3 <<< "$js")"
fi
# Each check declares its own scope: the machine checks are shared, the per-repo index checks
# (C33 graph, C70 semantic graph) are project rows that name the repo they judge, the rest default to project.
sc="$(jq -r 'select(.id | test("^C(22|38|44|45|52|80|83|86|40|12)-")) | select(.scope != "shared") | .id' <<< "$js")"
if [ -z "$sc" ] && [ "$(jq -r 'select(.id | test("^C(22|38|44|52|80|86)-")) | .id' <<< "$js" | grep -c .)" -ge 4 ]; then
    pass "--json -> C22 C38 C44 C45 C52 C80 C83 C86 (and C40, C12) declare scope shared"
else
    fail "--json -> machine checks not declared shared: [$sc]"
fi
rp="$(jq -r 'select(.id | test("^C(33|70)-")) | select(.scope != "project" or .repo != "himmel") | .id' <<< "$js")"
if [ -z "$rp" ] && [ "$(jq -r 'select(.id | test("^C(33|70)-")) | .id' <<< "$js" | grep -c .)" -ge 2 ]; then
    pass "--json -> C33 and C70 are project rows that name the repo they judge"
else
    fail "--json -> C33/C70 do not declare project + repo himmel: [$rp]"
fi
if [ -z "$(jq -r 'select(.id | test("^C(33|70)-") | not) | select(.repo != null) | .id' <<< "$js")" ]; then pass "--json -> no other check names a repo"; else fail "--json -> a check other than C33/C70 names a repo"; fi
if [ "$n_js" -eq "$n_txt" ] && [ "$n_txt" -gt 0 ]; then pass "--json -> $n_js rows = $n_txt text emits"; else fail "--json -> $n_js rows vs $n_txt text emits"; fi
if [ "$rc_js" -eq "$rc_txt" ]; then pass "--json -> exit code matches text run ($rc_js)"; else fail "--json -> rc=$rc_js vs text rc=$rc_txt"; fi
if grepq "$js" 'Summary:'; then fail "--json -> Summary line leaked to stdout"; else pass "--json -> Summary line kept off stdout"; fi
rm -rf "$t"

echo "== --file-issue with gh stub -> creates with resolved repo =="
t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"; make_gh "$t/gh" create
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if grepq "$out" 'CREATE me/repo'; then pass "file-issue -> created"; else fail "file-issue -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue dedup (existing open issue) -> skip create =="
t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"; make_gh "$t/gh" exists
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if grepq "$out" 'already exists' && ! grepq "$out" 'CREATE'; then pass "dedup -> skipped"; else fail "dedup -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue with gh ABSENT -> graceful, no crash =="
# Only run where the curated symlink PATH genuinely works (Linux) — Windows
# Git Bash symlinks to .exe tools don't execute, so skip there cleanly.
if PATH="$NOGH" bash -c 'git --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 && ! command -v gh >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"
    out="$(PATH="$NOGH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"; rc=$?
    if grepq "$out" 'gh not found' && { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; }; then pass "gh-absent -> graceful (rc=$rc)"; else fail "gh-absent -> rc=$rc; $(printf '%s' "$out" | tail -3)"; fi
    rm -rf "$t"
else
    pass "gh-absent -> (skipped: could not build a gh-less PATH on this host)"
fi

echo "== C1-guardrail: guardrail block baked to a missing node -> FAIL C1-guardrail, rc 1 =="
t="$(mktemp -d)"
write_guardrail_settings "$t/claude" "$t/gone/node"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'FAIL C1-guardrail'; then pass "guardrail stale node -> rc1, FAIL C1-guardrail"; else fail "guardrail stale node -> rc=$rc; $(printf '%s' "$out" | grep C1-guardrail)"; fi
rm -rf "$t"

echo "== C1-guardrail: guardrail block baked to a present node -> OK C1-guardrail =="
_real_node="$(command -v node 2>/dev/null || true)"
if [ -n "$_real_node" ]; then
    if command -v cygpath >/dev/null 2>&1; then _real_node="$(cygpath -m "$_real_node")"; fi
    t="$(mktemp -d)"
    write_guardrail_settings "$t/claude" "$_real_node"
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C1-guardrail'; then pass "guardrail present node -> OK C1-guardrail"; else fail "guardrail present node -> $(printf '%s' "$out" | grep C1-guardrail)"; fi
    rm -rf "$t"
else
    pass "guardrail present node -> (skipped: no node on PATH here)"
fi

echo "== C1-guardrail: --fix re-bakes the stale guardrail node (faked Linux uname) =="
t="$(mktemp -d)"
write_guardrail_settings "$t/claude" "$t/gone/node"
PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --fix --no-color >/dev/null 2>&1
# The assertion is just that the STALE path is gone.
if grep -q "$t/gone/node" "$t/claude/settings.json"; then
    fail "--fix -> stale node path still present in settings.json"
else
    pass "--fix -> stale node path replaced"
fi
if grep -q 'guardrail-skip-in-himmel.js' "$t/claude/settings.json"; then pass "--fix -> guardrail wiring still present"; else fail "--fix -> guardrail wiring missing after re-bake"; fi
rm -rf "$t"

echo "== C2: shadowed claude-obsidian marketplace -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude/plugins/cache/claude-obsidian-marketplace"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C2-obsidian'; then pass "C2 -> WARN (shadow)"; else fail "C2 -> $(printf '%s' "$out" | grep C2)"; fi
rm -rf "$t"

# C3 ignores handovers/ churn and WARNs only on a non-handover path
# dirty longer than the sync cadence (default 30 min).
c3_run() { # $1 = tmp root
    DOCTOR_MCP_PLUGINS_GLOB="$1/none/*.mcp.json" CLAUDE_DIR="$1/claude" HOME="$1/home" bash "$DOC" --no-color 2>&1
}
c3_vault() { # $1 = tmp root; sets v
    mkdir -p "$1/claude"; v="$1/home/Documents/luna"; mkdir -p "$v"
    git -C "$v" init -q 2>/dev/null; git -C "$v" config user.email t@t; git -C "$v" config user.name t
    : > "$v/.single-writer"; mkdir -p "$v/.git/info"; echo .single-writer >> "$v/.git/info/exclude"; write_settings "$1/claude" "$WRAPPER"
}

echo "== C3: stale dirty non-handover path in a single-writer vault -> WARN, no manual-commit advice =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"
echo dirty > "$v/note.md"
# ctime cannot be backdated (touch -t stamps a fresh one), so age the check: a clock 2 h ahead
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'WARN C3-luna' && ! grepq "$out" 'git -C .* commit'; then pass "C3 -> WARN (stale dirty non-handover)"; else fail "C3 stale -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C3: stale dirty path in a LOCAL-ONLY vault (no remote, no sync plugin) -> WARN says commit it =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo dirty > "$v/note.md"
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'WARN C3-luna' && grepq "$out" -F 'commit it' && ! grepq "$out" -F 'do not hand-commit' && ! grepq "$out" -F 'sync is stuck'; then pass "C3 local-only -> commit it"; else fail "C3 local-only -> $(printf '%s' "$out" | grep -A2 C3)"; fi
rm -rf "$t"

echo "== C3: the local-only remedy names the opt-in key and the real arm command =="
t="$(mktemp -d "${TMPDIR:-/tmp}/doctor-c3.XXXXXX")" || exit 1; c3_vault "$t"; echo dirty > "$v/note.md"
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'WARN C3-luna' && grepq "$out" -F 'LUNA_VAULT_AUTOCOMMIT=1' && grepq "$out" -F "scripts/luna/vault-stall-cadence.sh arm --vault $v"; then pass "C3 local-only remedy -> key + arm command"; else fail "C3 local-only remedy -> $(printf '%s' "$out" | grep -A2 C3)"; fi
rm -rf "$t"

echo "== C3: stale dirty path in a vault WITH a remote -> WARN keeps the sync-stuck advice =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; git -C "$v" remote add origin https://example.invalid/luna.git; echo dirty > "$v/note.md"
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'WARN C3-luna' && grepq "$out" -F 'do not hand-commit' && ! grepq "$out" -F 'commit it'; then pass "C3 remote -> sync advice"; else fail "C3 remote -> $(printf '%s' "$out" | grep -A2 C3)"; fi
rm -rf "$t"

echo "== C3: stale dirty path in a vault with a sync plugin but no remote -> WARN keeps the sync-stuck advice =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; mkdir -p "$v/.obsidian/plugins/obsidian-github-sync"; echo dirty > "$v/note.md"
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'WARN C3-luna' && grepq "$out" -F 'do not hand-commit' && ! grepq "$out" -F 'commit it'; then pass "C3 sync plugin -> sync advice"; else fail "C3 sync plugin -> $(printf '%s' "$out" | grep -A2 C3)"; fi
rm -rf "$t"

echo "== C3: fresh dirty non-handover path -> OK =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo dirty > "$v/note.md"
out="$(c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" 'WARN C3-luna'; then pass "C3 fresh dirty -> OK"; else fail "C3 fresh -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C3: handovers/-only dirt (even old) -> OK =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; mkdir -p "$v/handovers/u/r"
echo wip > "$v/handovers/u/r/doc.md"
out="$(HIMMEL_DOCTOR_C3_NOW=$(( $(date +%s) + 7200 )) c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" 'WARN C3-luna'; then pass "C3 handovers-only -> OK"; else fail "C3 handovers-only -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

# porcelain paths are read NUL-delimited (never quoted), renames
# age their destination, and a deletion ages by the vault's last commit.
echo "== C3: fresh dirty non-ASCII / quote-bearing names -> OK (not resolved as a missing quoted path) =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo dirty > "$v/café.md"; echo dirty > "$v/say \"hi\".md"
out="$(c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" 'WARN C3-luna'; then pass "C3 escaped names -> OK"; else fail "C3 escaped names -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C3: freshly moved file (unstaged delete + new path) after a recent commit -> OK =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo n > "$v/inbox.md"; touch -t 202001010000 "$v/inbox.md"
git -C "$v" add inbox.md; git -C "$v" commit -qm init; mkdir -p "$v/notes"; mv "$v/inbox.md" "$v/notes/inbox.md"
out="$(c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" 'WARN C3-luna'; then pass "C3 fresh move -> OK"; else fail "C3 fresh move -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C3: a leading-zero dirty window (08) is decimal on the deletion path (HIMMEL-4724) =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo n > "$v/gone.md"; git -C "$v" add gone.md; git -C "$v" commit -qm init; rm "$v/gone.md"
out="$(HIMMEL_DOCTOR_C3_DIRTY_MIN=08 c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" -F 'value too great'; then pass "C3 dirty window 08 -> decimal"; else fail "C3 dirty window 08 -> $(printf '%s' "$out" | grep -E 'C3|value too great')"; fi
rm -rf "$t"

echo "== C3: freshly staged rename of an old-mtime file -> OK (destination aged by its rename) =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo n > "$v/inbox.md"; touch -t 202001010000 "$v/inbox.md"
git -C "$v" add inbox.md; git -C "$v" commit -qm init; mkdir -p "$v/notes"; git -C "$v" mv inbox.md notes/inbox.md
out="$(c3_run "$t")"
if grepq "$out" 'OK  *C3-luna' && ! grepq "$out" 'WARN C3-luna'; then pass "C3 fresh rename -> OK"; else fail "C3 fresh rename -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C3: deletion when the vault's last commit is older than the window -> WARN =="
t="$(mktemp -d)" || exit 1; c3_vault "$t"; echo n > "$v/gone.md"; git -C "$v" add gone.md
GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git -C "$v" commit -qm init; rm "$v/gone.md"
out="$(c3_run "$t")"
if grepq "$out" 'WARN C3-luna.*gone.md'; then pass "C3 old deletion -> WARN"; else fail "C3 old deletion -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C4: forge decided on the origin's HOST, not a URL substring (fixtures/forge-origins.tsv) =="
# check_c4 is run in isolation (the whole doctor is ~12 s a run) with a
# stub emit, once per row of the answer table forge.sh's and status-report's suites
# read. INFO C4-forge must fire exactly when forge_detect says bitbucket.
_c4_body="$(awk '/^check_c4\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_c4_tsv="$REPO_ROOT/scripts/lib/fixtures/forge-origins.tsv"
_c4_repo="$(mktemp -d "${TMPDIR:-/tmp}/c4-forge.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
git init -q "$_c4_repo"
# c4_run <origin> [FORGE value] — echoes the "<sev> <id>" line check_c4 emits, if any.
c4_run() {
    git -C "$_c4_repo" remote remove origin 2>/dev/null
    git -C "$_c4_repo" remote add origin "$1"
    # shellcheck disable=SC2016  # the script text is meant to expand in the child shell
    ( cd "$_c4_repo" && env -u FORGE ${2:+FORGE="$2"} REPO_ROOT="$REPO_ROOT" bash -c \
        'set -uo pipefail; emit() { printf "%s %s\n" "$1" "$2"; }; '"$_c4_body"'; check_c4' 2>&1 )
}
_c4_n=0
while IFS=$'\t' read -r _c4_want _c4_url; do
    case "$_c4_want" in ''|'#'*) continue ;; esac
    _c4_got="$(c4_run "$_c4_url")"
    # shellcheck disable=SC2016  # $1 expands in the child shell
    _c4_fd="$(cd "$_c4_repo" && env -u FORGE bash -c '. "$1/scripts/lib/forge.sh"; forge_detect 2>/dev/null' _ "$REPO_ROOT")" || true
    [ -n "$_c4_fd" ] || _c4_fd=none
    if [ "$_c4_want" = bitbucket ]; then _c4_exp="INFO C4-forge"; else _c4_exp=""; fi
    if [ "$_c4_got" = "$_c4_exp" ]; then pass "C4 '$_c4_url' ($_c4_want) -> '${_c4_got:-nothing}'"; else fail "C4 '$_c4_url' ($_c4_want) -> expected '${_c4_exp:-nothing}', got '$_c4_got'"; fi
    if [ "$_c4_fd" != "$_c4_want" ]; then fail "C4 '$_c4_url': forge_detect says '$_c4_fd', fixture says '$_c4_want'"; fi
    _c4_n=$((_c4_n+1))
done < "$_c4_tsv"
if [ "$_c4_n" -ge 30 ]; then pass "C4 origin table was read ($_c4_n cases)"; else fail "C4 origin table was read: only $_c4_n cases from $_c4_tsv"; fi
# An inherited FORGE overrides forge_detect but says nothing about the ORIGIN C4 reports on.
_c4_got="$(c4_run 'https://bitbucket.org/t/r.git' github)"
if [ "$_c4_got" = "INFO C4-forge" ]; then pass "C4 ignores an inherited FORGE (bitbucket origin still reported)"; else fail "C4 ignores an inherited FORGE -> '$_c4_got'"; fi
_c4_got="$(c4_run 'https://github.com/o/r.git' bitbucket)"
if [ -z "$_c4_got" ]; then pass "C4 ignores an inherited FORGE (github origin stays quiet)"; else fail "C4 ignores an inherited FORGE (github origin) -> '$_c4_got'"; fi
rm -rf "$_c4_repo"

echo "== issue repo: resolve_issue_repo decides on the origin's HOST, not a URL substring =="
# resolve_issue_repo used to match `*github.com[:/]*` anywhere in the
# origin URL. Run in isolation (it only reads REPO_FLAG, the env and the origin),
# once per row: <expected owner/repo | none><TAB><origin url>.
_ri_body="$(awk '/^resolve_issue_repo\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_ri_repo="$(mktemp -d "${TMPDIR:-/tmp}/ri-forge.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
git init -q "$_ri_repo"
# ri_run <origin> [FORGE value] — echoes the resolved owner/repo, or `none` when it returns 1.
ri_run() {
    git -C "$_ri_repo" remote remove origin 2>/dev/null
    git -C "$_ri_repo" remote add origin "$1"
    # shellcheck disable=SC2016  # the script text is meant to expand in the child shell
    # GIT_CONFIG_GLOBAL/SYSTEM=/dev/null: an operator's url.<base>.insteadOf would rewrite the
    # scp-like origins under test (git@github.com: -> https://github.com/) before they are read.
    ( cd "$_ri_repo" && env -u FORGE -u HIMMEL_DOCTOR_ISSUE_REPO GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null ${2:+FORGE="$2"} REPO_ROOT="$REPO_ROOT" bash -c \
        'set -uo pipefail; REPO_FLAG=""; '"$_ri_body"'; if r="$(resolve_issue_repo)"; then printf "%s\n" "$r"; else echo none; fi' 2>/dev/null )
}
_ri_n=0
while IFS=$'\t' read -r _ri_want _ri_url; do
    case "$_ri_want" in ''|'#'*) continue ;; esac
    _ri_got="$(ri_run "$_ri_url")"
    if [ "$_ri_got" = "$_ri_want" ]; then pass "issue repo '$_ri_url' -> $_ri_got"; else fail "issue repo '$_ri_url' -> expected '$_ri_want', got '$_ri_got'"; fi
    _ri_n=$((_ri_n+1))
done <<'ROWS'
o/r	https://github.com/o/r.git
o/r	https://github.com/o/r
o/r	https://github.com/o/r/
o/r	https://user:tok@github.com/o/r.git
o/r	https://github.com:443/o/r.git
o/r	ssh://git@github.com/o/r.git
o/r	ssh://git@ssh.github.com:443/o/r.git
o/r	git@github.com:o/r.git
o/r	github.com:o/r.git
O/R	https://GitHub.COM/O/R.git
o/r	https://github.com/o/r/github.com/x
bitbucket.org/widgets	https://github.com/bitbucket.org/widgets.git
o/r	https://github.com./o/r.git
o/r	https://github.com.:443/o/r.git
o/r	ssh://git@ssh.github.com.:443/o/r.git
o/r	git@github.com.:o/r.git
o/r	github.com.:o/r.git
none	https://evil.example/github.com/x/y
none	https://user@evil.example/u@github.com:o/r.git
none	git@evil.example:github.com/x/y.git
none	https://notgithub.com/o/r.git
none	git@notgithub.com:o/r.git
none	https://github.com.example.net/o/r.git
none	https://github.com../o/r.git
none	https://github.example.com/o/r.git
none	https://gitlab.com/github.com/o/r.git
none	https://bitbucket.org/github.com/x/y
none	git@bitbucket.org:github.com/x/y.git
none	/srv/git/github.com/o/r.git
none	file:///srv/git/github.com/o/r.git
none	github.com/o/r.git
none	git@github.com:o/r.git://y
none	https://github.com/o/r.git://y
none	https://github.com/o
ROWS
if [ "$_ri_n" -ge 30 ]; then pass "issue repo origin table was read ($_ri_n cases)"; else fail "issue repo origin table was read: only $_ri_n cases"; fi
# Every row of the harness-wide forge table: a github origin resolves a repo, anything else does not.
_ri_m=0
while IFS=$'\t' read -r _ri_want _ri_url; do
    case "$_ri_want" in ''|'#'*) continue ;; esac
    _ri_got="$(ri_run "$_ri_url")"
    if [ "$_ri_want" = github ]; then
        case "$_ri_got" in none|'') fail "issue repo forge-table github '$_ri_url' -> '$_ri_got'" ;; *) pass "issue repo forge-table github '$_ri_url' -> $_ri_got" ;; esac
    elif [ "$_ri_got" = none ]; then pass "issue repo forge-table $_ri_want '$_ri_url' -> none"; else fail "issue repo forge-table $_ri_want '$_ri_url' -> expected none, got '$_ri_got'"; fi
    _ri_m=$((_ri_m+1))
done < "$REPO_ROOT/scripts/lib/fixtures/forge-origins.tsv"
if [ "$_ri_m" -ge 30 ]; then pass "issue repo forge table was read ($_ri_m cases)"; else fail "issue repo forge table was read: only $_ri_m cases"; fi
# An inherited FORGE overrides forge_detect but says nothing about the ORIGIN the issue is filed on.
_ri_got="$(ri_run 'https://github.com/o/r.git' bitbucket)"
if [ "$_ri_got" = o/r ]; then pass "issue repo ignores an inherited FORGE (github origin)"; else fail "issue repo ignores an inherited FORGE (github origin) -> '$_ri_got'"; fi
_ri_got="$(ri_run 'https://bitbucket.org/t/r.git' github)"
if [ "$_ri_got" = none ]; then pass "issue repo ignores an inherited FORGE (bitbucket origin)"; else fail "issue repo ignores an inherited FORGE (bitbucket origin) -> '$_ri_got'"; fi
rm -rf "$_ri_repo"

echo "== C26: no salus vault -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'no salus vault found'; then pass "C26 -> OK (no vault)"; else fail "C26 no-vault -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: salus vault with no .salus-profile -> OK skipped (not a salus deployment) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'not a salus-profile deployment'; then pass "C26 -> OK (no .salus-profile)"; else fail "C26 no-profile -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: .salus-profile present, .salus absent -> WARN (armed-but-inert) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
: > "$v/.salus-profile"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C26-salus-marker' && grepq "$out" 'armed-but-inert'; then pass "C26 -> WARN (profile without .salus)"; else fail "C26 profile-only -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: both .salus-profile and .salus present -> OK armed =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
: > "$v/.salus-profile"; : > "$v/.salus"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'PHI guards are armed'; then pass "C26 -> OK (both markers present)"; else fail "C26 both-markers -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C27: no claude-glm config dir -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'declared here'; then pass "C27 -> OK (no config dir)"; else fail "C27 no-dir -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: config dir present, no phi-roots/egress-denylist files -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; mkdir -p "$t/home/.config/claude-glm"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'readable regular files'; then pass "C27 -> OK (nothing declared)"; else fail "C27 empty-dir -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: readable phi-roots + egress-denylist -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; mkdir -p "$t/home/.config/claude-glm"
: > "$t/home/.config/claude-glm/phi-roots"; : > "$t/home/.config/claude-glm/egress-denylist"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'readable regular files'; then pass "C27 -> OK (both readable)"; else fail "C27 readable -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: phi-roots exists but is a directory (not a readable regular file) -> WARN (inert signal) =="
# A directory is the portable unreadable-policy fixture (same trick as
# scripts/graphify/test-refresh-graph-map.sh T43e): [-f] fails on a directory
# on every platform, unlike chmod 000 which does not reliably deny read to the
# owner on Windows.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"
mkdir -p "$t/home/.config/claude-glm/phi-roots"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C27-guard-signals' && grepq "$out" 'not a readable regular file'; then pass "C27 -> WARN (phi-roots is a directory)"; else fail "C27 unreadable -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

# No guard reads the neutral dir yet. Each row runs the doctor
# against a fixture HOME; c27_row prints the C27 line.
c27_row() { # <home parent>
    # HIMMEL_DOCTOR_ROOT: without it a worktree run sources the primary checkout's lib.
    HIMMEL_DOCTOR_ROOT="$REPO_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$1/none/*.mcp.json" CLAUDE_DIR="$1/claude" HOME="$1/home" bash "$DOC" --no-color 2>&1 | grep -A1 'C27-guard-signals'
}
c27_fixture() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")" || exit 1
    mkdir -p "$d/claude" "$d/home/.config/claude-glm" "$d/home/.config/himmel/phi"
    write_settings "$d/claude" "$WRAPPER"
    printf '%s' "$d"
}

echo "== C27: a root only under the old path -> WARN that forbids removing it =="
t="$(c27_fixture)" || exit 1; rmdir "$t/home/.config/himmel/phi"; printf '/synthetic/phi\n' > "$t/home/.config/claude-glm/phi-roots"
out="$(c27_row "$t")"
if grepq "$out" 'WARN C27-guard-signals' && grepq "$out" 'stays authoritative' && grepq "$out" 'Do NOT move or remove' && grepq "$out" 'no action is needed' && ! grepq "$out" -i 'copy'; then pass "C27 -> WARN (old only, keep it, no copy advice)"; else fail "C27 old-only -> $out"; fi
rm -rf "$t"

echo "== C27: a root only under the neutral dir -> FAIL, not enforced =="
t="$(c27_fixture)" || exit 1; printf '/synthetic/phi\n' > "$t/home/.config/himmel/phi/phi-roots"
out="$(c27_row "$t")"
if grepq "$out" 'FAIL C27-guard-signals' && grepq "$out" 'NOT enforced' && grepq "$out" '1 PHI root'; then pass "C27 -> FAIL (neutral only)"; else fail "C27 neutral-only -> $out"; fi
rm -rf "$t"

echo "== C27: both dirs but the neutral list has an extra root -> FAIL counts it =="
t="$(c27_fixture)" || exit 1; printf '/synthetic/phi\n/synthetic/extra\n' > "$t/home/.config/himmel/phi/phi-roots"; printf '/synthetic/phi\n' > "$t/home/.config/claude-glm/phi-roots"
out="$(c27_row "$t")"
if grepq "$out" 'FAIL C27-guard-signals' && grepq "$out" '1 PHI root'; then pass "C27 -> FAIL (extra neutral root)"; else fail "C27 extra-root -> $out"; fi
rm -rf "$t"

echo "== C27: no list entry appears anywhere in the doctor's output (--file-issue can post it) =="
t="$(c27_fixture)" || exit 1; printf '/synthetic/phi\n/synthetic/extra\n' > "$t/home/.config/himmel/phi/phi-roots"; printf '/synthetic/phi\n' > "$t/home/.config/claude-glm/phi-roots"
out="$(HIMMEL_DOCTOR_ROOT="$REPO_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'FAIL C27-guard-signals' && ! grepq "$out" '/synthetic/'; then pass "C27 -> no list entry in the output"; else fail "C27 entry-leak -> $(printf '%s' "$out" | grep -A1 C27)"; fi
rm -rf "$t"

echo "== C27: both dirs hold the same roots -> OK =="
t="$(c27_fixture)" || exit 1; printf '/synthetic/phi\n' > "$t/home/.config/himmel/phi/phi-roots"; printf '/synthetic/phi\n' > "$t/home/.config/claude-glm/phi-roots"
out="$(c27_row "$t")"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'readable regular files'; then pass "C27 -> OK (mirrored)"; else fail "C27 mirrored -> $out"; fi
rm -rf "$t"

echo "== C27: an unreadable neutral list -> FAIL =="
t="$(c27_fixture)" || exit 1; mkdir -p "$t/home/.config/himmel/phi/phi-roots"
out="$(c27_row "$t")"
if grepq "$out" 'FAIL C27-guard-signals' && grepq "$out" 'cannot be read'; then pass "C27 -> FAIL (unreadable neutral list)"; else fail "C27 unreadable-neutral -> $out"; fi
rm -rf "$t"

echo "== C27: a plain file where the neutral dir belongs -> FAIL, never skipped =="
t="$(c27_fixture)" || exit 1; rm -rf "$t/home/.config/claude-glm"; rmdir "$t/home/.config/himmel/phi"; : > "$t/home/.config/himmel/phi"
out="$(c27_row "$t")"
if grepq "$out" 'FAIL C27-guard-signals' && grepq "$out" 'cannot be read'; then pass "C27 -> FAIL (neutral dir is a file)"; else fail "C27 neutral-file -> $out"; fi
rm -rf "$t"

echo "== C27: a locked parent of the neutral dir and no old dir -> FAIL, never skipped =="
t="$(c27_fixture)" || exit 1; rm -rf "$t/home/.config/claude-glm"; rmdir "$t/home/.config/himmel/phi"
if chmod 000 "$t/home/.config/himmel" 2>/dev/null && [ ! -x "$t/home/.config/himmel" ]; then
    out="$(c27_row "$t")"
    if grepq "$out" 'FAIL C27-guard-signals' && grepq "$out" 'cannot be read'; then pass "C27 -> FAIL (locked parent of the neutral dir)"; else fail "C27 locked-parent -> $out"; fi
else
    echo "  SKIP  C27 locked-parent case (chmod 000 did not deny access on this fs/user)"
fi
chmod 755 "$t/home/.config/himmel" 2>/dev/null
rm -rf "$t"

echo "== C6: bare-interpreter MCP server -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "obsidian-vault": { "command": "uvx", "args": ["mcp-obsidian"] } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C6-mcp' && grepq "$out" 'obsidian-vault(uvx)'; then pass "C6 -> WARN (uvx)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
rm -rf "$t"

echo "== C6: absolute-command MCP server -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "x": { "command": "/usr/local/bin/foo" } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C6-mcp'; then pass "C6 -> OK (absolute)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
rm -rf "$t"

# C6-hooks: a hook command leading with a bare interpreter that is
# absent on THIS host. Use $TOOLS_PATH (real coreutils dirs) which excludes deno;
# guard the WARN assertion in case a host genuinely has deno on that path.
echo "== C6-hooks: bare deno hook on a host without deno -> WARN =="
if PATH="$TOOLS_PATH" bash -c '! command -v deno >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"; mkdir -p "$t/claude"
    cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "deno run \"/x/end-session-wiki.ts\"", "shell": "bash" } ] } ] } }
EOF
    out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'WARN C6-hooks' && grepq "$out" 'deno'; then pass "C6-hooks -> WARN (deno absent)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
    rm -rf "$t"
else
    pass "C6-hooks -> WARN (skipped: deno present under TOOLS_PATH on this host)"
fi

echo "== C6-hooks: wrapper-routed hook (leading bash) -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "bash \"/x/scripts/lib/run-node.sh\" \"/x/end-session-wiki.js\"", "shell": "bash" } ] } ] } }
EOF
out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C6-hooks'; then pass "C6-hooks -> OK (wrapper-routed)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
rm -rf "$t"

# ── C7: merged-PR worktree detective check ───────────────────────────────────
# Build a real temp git repo with real worktrees; stub the forge via GH_CMD.

# make_wt_repo <dir> — init a minimal git repo + first commit so worktrees work.
make_wt_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'init\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
}

# make_gh_stub <dir> <merged_branch> — creates a gh stub that echoes 1 merged PR for
# the given branch and 0 for everything else.  If merged_branch is "FAIL", the stub
# exits 1 for every call.
# The real call shape from forge-github.sh gh_forge_pr_has_merged is:
#   gh pr list --head <branch> --state merged --json number --jq 'length'
# So args: $1=pr $2=list $3=--head $4=BRANCH $5=--state $6=merged $7=--json $8=number $9=--jq $10=length
make_gh_stub() {
    local d="$1" merged_branch="$2"
    mkdir -p "$d"
    if [ "$merged_branch" = "FAIL" ]; then
        printf '#!/bin/sh\nexit 1\n' > "$d/gh"
    else
        cat > "$d/gh" <<EOF
#!/bin/sh
# Stub for: gh pr list --head BRANCH --state merged --json number --jq length
if [ "\$4" = "$merged_branch" ]; then echo 1; else echo 0; fi
EOF
    fi
    chmod +x "$d/gh"
}

echo "== C7: merged-PR worktree -> WARN C7-shipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
# Capture default branch name before creating the feature branch.
_defbranch="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped
git -C "$t/repo" checkout -q "$_defbranch"
git -C "$t/repo" worktree add -q "$t/wt-shipped" "feat/shipped"
make_gh_stub "$t/stub" "feat/shipped"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped'; then
    pass "C7 -> WARN (merged branch flagged)"
else
    fail "C7 -> expected WARN C7-shipped feat/shipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: untracked-only merged-PR worktree -> WARN C7-shipped with the UNTRACKED remediation =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch1c="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped-untracked
git -C "$t/repo" checkout -q "$_defbranch1c"
git -C "$t/repo" worktree add -q "$t/wt-shipped-untracked" "feat/shipped-untracked"
# The headline shape: nothing tracked is modified, but a forgotten
# untracked file (the real incident was a 502-line spec) sits in a merged
# worktree. A tracked-only probe would call this clean and hand back the flat
# "prune with /clean", which clean-garden may well refuse as forgotten work.
printf 'a forgotten spec\n' > "$t/wt-shipped-untracked/FORGOTTEN-SPEC.md"
make_gh_stub "$t/stub" "feat/shipped-untracked"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped-untracked' \
    && grepq "$out" 'has UNTRACKED files' && grepq "$out" 'dry-run'; then
    pass "C7 -> WARN (untracked-only merged branch gets the UNTRACKED remediation)"
else
    fail "C7 -> expected the UNTRACKED remediation for feat/shipped-untracked; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: dirty merged-PR worktree -> WARN C7-shipped with 'will refuse' remediation =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch1b="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped-dirty
git -C "$t/repo" checkout -q "$_defbranch1b"
git -C "$t/repo" worktree add -q "$t/wt-shipped-dirty" "feat/shipped-dirty"
# Dirty the worktree: /clean will refuse to prune this one, so
# the C7 remediation must say so instead of pointing at /clean as if it works.
printf 'uncommitted\n' >> "$t/wt-shipped-dirty/README.md"
make_gh_stub "$t/stub" "feat/shipped-dirty"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped-dirty' \
    && grepq "$out" 'refuses to prune it' && grepq "$out" 'do NOT just commit in place'; then
    pass "C7 -> WARN (dirty merged branch gets the 'will refuse' remediation)"
else
    fail "C7 -> expected WARN C7-shipped feat/shipped-dirty with dirty-worktree remediation; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: no merged worktrees -> OK C7-shipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch2="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/not-merged
git -C "$t/repo" checkout -q "$_defbranch2"
git -C "$t/repo" worktree add -q "$t/wt-live" "feat/not-merged"
make_gh_stub "$t/stub" "__no_match__"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C7-shipped'; then
    pass "C7 -> OK (no merged worktrees)"
else
    fail "C7 -> expected OK C7-shipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: forge-error -> INFO C7-shipped skipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch3="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/unreachable
git -C "$t/repo" checkout -q "$_defbranch3"
git -C "$t/repo" worktree add -q "$t/wt-unreachable" "feat/unreachable"
make_gh_stub "$t/stub" "FAIL"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO' && grepq "$out" 'C7-shipped' && grepq "$out" 'skipped'; then
    pass "C7 -> INFO (forge unreachable)"
else
    fail "C7 -> expected INFO C7-shipped skipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: locked worktree with merged branch -> NOT flagged =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch4="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/locked-merged
git -C "$t/repo" checkout -q "$_defbranch4"
git -C "$t/repo" worktree add -q "$t/wt-locked" "feat/locked-merged"
git -C "$t/repo" worktree lock "$t/wt-locked" 2>/dev/null || true
make_gh_stub "$t/stub" "feat/locked-merged"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
# Locked worktree must NOT produce a WARN for feat/locked-merged.
if grepq "$(printf '%s' "$out" | grep 'WARN')" 'C7-shipped'; then
    fail "C7 -> locked worktree must not be flagged; got WARN"
else
    pass "C7 -> locked worktree not flagged"
fi
rm -rf "$t"

echo "== C7 STATIC: check_c7 body must not contain destructive git verbs =="
# Extract only the check_c7 function body from himmel-doctor.sh and assert
# none of the forbidden verbs appear.  Mechanically checkable without shimming git.
_c7_body="$(awk '/^check_c7\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_static_fail=0
for _verb in "worktree remove" "branch -D" " push " " reset " " checkout " "rm " "git clean" "clean -"; do
    if grepq "$_c7_body" -F "$_verb"; then
        fail "C7 STATIC: found forbidden verb '$_verb' in check_c7 body"
        _static_fail=1
    fi
done
if [ "$_static_fail" -eq 0 ]; then
    pass "C7 STATIC: no destructive verbs in check_c7 body"
fi

# ── C8: stale cadence runner detection ───────────────
echo "== C8: no armed cadence runners -> OK C8-cadence =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C8-cadence: no armed cadence runners (skipped)'; then pass "C8 -> OK (no runners)"; else fail "C8 -> $(printf '%s' "$out" | grep C8)"; fi
rm -rf "$t"

echo "== C8: stale graphmap runner -> WARN + graphmap re-arm hint =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/graphmap"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old graphmap\n' "$STALE_CADENCE_VER" > "$t/graphmap/graphmap-luna.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    GRAPHMAP_BAT_DIR="$t/graphmap" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --root "$REPO_ROOT" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: graphmap-cadence runners are stale' \
    && grepq "$out" 'bash scripts/luna/graphmap-cadence.sh arm --rewrite-armed'; then
    pass "C8 -> WARN (stale graphmap runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: stale qmd runner -> WARN + qmd re-arm hint =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/qmd"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old qmd\n' "$STALE_CADENCE_VER" > "$t/qmd/qmd-reindex.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    QMD_CADENCE_BAT_DIR="$t/qmd" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --root "$REPO_ROOT" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: qmd-cadence runners are stale' \
    && grepq "$out" 'bash scripts/luna/qmd-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale qmd runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: stale upstream-watch runner -> WARN + upstream-watch re-arm hint =="
t="$(mktemp -d)" || exit 1; mkdir -p "$t/claude" "$t/uw"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old upstream-watch\n' "$STALE_CADENCE_VER" > "$t/uw/upstream-watch.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    QMD_CADENCE_BAT_DIR="$t/qmd-empty" UPSTREAMWATCH_BAT_DIR="$t/uw" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --root "$REPO_ROOT" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: upstream-watch-cadence runners are stale' \
    && grepq "$out" 'bash scripts/upstreams/upstream-watch-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale upstream-watch runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: stale graph-choices runner -> WARN + graph-choices re-arm hint =="
t="$(mktemp -d "${TMPDIR:-/tmp}/doctor-c8.XXXXXX")" || exit 1; mkdir -p "$t/claude" "$t/gc"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old graph-choices\n' "$STALE_CADENCE_VER" > "$t/gc/graph-choices.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    GRAPHMAP_BAT_DIR="$t/graphmap-empty" QMD_CADENCE_BAT_DIR="$t/qmd-empty" GRAPH_CHOICES_BAT_DIR="$t/gc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --root "$REPO_ROOT" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: graph-choices-cadence runners are stale' \
    && grepq "$out" 'bash scripts/graphify/graph-choices-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale graph-choices runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: pipeline-only current runner -> OK, no false nudges =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/pipeline"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho current runner\n' "$CADENCE_VER" > "$t/pipeline/pipeline-harvest.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline" \
    GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C8-cadence: pipeline-cadence runners current' \
    && ! grepq "$out" 'WARN C8-cadence'; then
    pass "C8 -> OK (pipeline-only current runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C9 linux at+atd live -> OK =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=1 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C9-scheduler'; then pass "C9 linux ok"; else fail "C9 linux ok: $(printf '%s' "$out" | grep C9)"; fi
rm -rf "$t"

echo "== C9 linux at+atd dead -> WARN + remediation =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=0 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C9-scheduler'; then pass "C9 linux disabled WARN"; else fail "C9 disabled: $(printf '%s' "$out" | grep C9)"; fi
if grepq "$out" 'systemctl enable --now atd'; then pass "C9 remediation shown"; else fail "C9 remediation missing"; fi
rm -rf "$t"

echo "== C9 macos crontab -> WARN ok-cron, NOT 'install at' =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/crontab"; chmod +x "$b/crontab"
out="$(SCHEDULER_BACKEND_OS=macos PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C9-scheduler'; then pass "C9 macos warn"; else fail "C9 macos: $(printf '%s' "$out" | grep C9)"; fi
if grepq "$out" 'apt install'; then fail "C9 macos wrongly suggests apt"; else pass "C9 macos no apt advice"; fi
rm -rf "$t"

# ── C10 removed: its mirror tooling is gone ──────────────────────────────────
echo "== C10: private→public propagation check is gone =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || ! grepq "$out" 'C9-scheduler' || ! grepq "$out" 'C12-codex'; then fail "C10 -> doctor did not run its neighbouring checks (rc=$rc)"
elif grepq "$out" 'C10-propagation'; then fail "C10 -> still emitted: $(printf '%s' "$out" | grep C10)"; else pass "C10 -> not emitted"; fi
rm -rf "$t"

# ── C11 retired: the glm lane is dropped, no glm-seed row may appear ─────────
echo "== C11: glm-seed check is retired =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c11.XXXXXX")" || exit 1; mkdir -p "$t/claude" "$t/home/.claude-glm"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'C11-glm-seed'; then fail "C11 -> still emitted: $(printf '%s' "$out" | grep C11)"; else pass "C11 -> not emitted"; fi
rm -rf "$t"

echo "== C13: himmel-ops hooks.json target missing -> WARN C13-plugin-hooks =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/plugin-hooks"; write_settings "$t/claude" "$WRAPPER"
cat > "$t/plugin-hooks/hooks.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash -c 'h=\"$CLAUDE_PROJECT_DIR/scripts/hooks/no-such-hook.sh\"; if [ -f \"$h\" ]; then exec bash \"$h\"; fi'" } ] } ] } } }
EOF
out="$(DOCTOR_HIMMEL_OPS_HOOKS_JSON="$t/plugin-hooks/hooks.json" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'scripts/hooks/no-such-hook.sh'; then pass "C13 -> WARN (missing hook target)"; else fail "C13 -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

echo "== C13: shipped himmel-ops hooks.json targets exist -> OK C13-plugin-hooks =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C13-plugin-hooks'; then pass "C13 -> OK (shipped hook targets exist)"; else fail "C13 -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

echo "== C13: stale UNPINNED plugin-cache version is ignored, a PINNED one still warns =="
t="$(mktemp -d -t c13pin.XXXXXX)" || exit 1; mkdir -p "$t/claude/plugins/cache/himmel/himmel-ops/0.1.0/hooks" "$t/claude/plugins/cache/himmel/himmel-ops/0.2.0/hooks"; write_settings "$t/claude" "$WRAPPER"
cat > "$t/claude/plugins/cache/himmel/himmel-ops/0.1.0/hooks/hooks.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash -c 'h=\"$CLAUDE_PROJECT_DIR/scripts/hooks/stale-gone-hook.sh\"; [ -f \"$h\" ] && exec bash \"$h\"'" } ] } ] } }
EOF
echo '{ "hooks": {} }' > "$t/claude/plugins/cache/himmel/himmel-ops/0.2.0/hooks/hooks.json"
echo "{ \"version\": 2, \"plugins\": { \"himmel-ops@himmel\": [ { \"scope\": \"user\", \"installPath\": \"$t/claude/plugins/cache/himmel/himmel-ops/0.2.0\" } ] } }" > "$t/claude/plugins/installed_plugins.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C13-plugin-hooks' && ! grepq "$out" 'WARN C13-plugin-hooks'; then pass "C13 -> OK (unpinned stale cache version ignored)"; else fail "C13 unpinned -> $(printf '%s' "$out" | grep C13)"; fi
echo "{ \"version\": 2, \"plugins\": { \"himmel-ops@himmel\": [ { \"scope\": \"user\", \"installPath\": \"$t/claude/plugins/cache/himmel/himmel-ops/0.2.0\" }, \"garbage\" ] } }" > "$t/claude/plugins/installed_plugins.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'stale-gone-hook.sh'; then pass "C13 -> WARN (malformed registry falls back to the whole cache)"; else fail "C13 malformed registry -> $(printf '%s' "$out" | grep C13)"; fi
echo "{ \"version\": 2, \"plugins\": { \"himmel-ops@himmel\": [ { \"scope\": \"user\", \"installPath\": \"$t/claude/plugins/cache/himmel/himmel-ops/9.9.9\" } ] } }" > "$t/claude/plugins/installed_plugins.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" '9.9.9'; then pass "C13 -> WARN (pinned install has no hooks.json)"; else fail "C13 pinned no manifest -> $(printf '%s' "$out" | grep C13)"; fi
echo "{ \"version\": 2, \"plugins\": { \"himmel-ops@himmel\": [ { \"scope\": \"project\", \"installPath\": \"$t/claude/plugins/cache/himmel/himmel-ops/0.1.0\" } ] } }" > "$t/claude/plugins/installed_plugins.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'stale-gone-hook.sh'; then pass "C13 -> WARN (pinned stale version)"; else fail "C13 pinned -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

echo "== C13: stale project pin vs directory-sourced served himmel-ops -> INFO, a missing served hook still WARNs =="
t="$(mktemp -d -t c13dir.XXXXXX)" || exit 1
cp="$t/claude/plugins/cache/himmel/himmel-ops"; sv="$t/mkt/plugins/himmel-ops"
mkdir -p "$cp/0.4.8/hooks" "$cp/0.4.112/hooks" "$sv/.claude-plugin" "$sv/hooks"; write_settings "$t/claude" "$WRAPPER"
cat > "$cp/0.4.8/hooks/hooks.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash -c 'h=\"$CLAUDE_PROJECT_DIR/scripts/hooks/block-rogue-codex-wsl.sh\"; [ -f \"$h\" ] && exec bash \"$h\"'" } ] } ] } }
EOF
echo '{ "hooks": {} }' > "$cp/0.4.112/hooks/hooks.json"
echo '{ "hooks": {} }' > "$sv/hooks/hooks.json"
echo '{ "name": "himmel-ops", "version": "0.4.112" }' > "$sv/.claude-plugin/plugin.json"
cat > "$t/claude/plugins/known_marketplaces.json" <<EOF
{ "himmel": { "source": { "source": "directory", "path": "$t/mkt" }, "installLocation": "$t/mkt", "autoUpdate": true } }
EOF
cat > "$t/claude/plugins/installed_plugins.json" <<EOF
{ "version": 2, "plugins": { "himmel-ops@himmel": [
  { "scope": "user", "projectPath": null, "installPath": "$cp/0.4.112", "version": "0.4.112", "installedAt": "2026-09-04T12:17:57.732Z", "lastUpdated": "2026-10-19T00:08:11.517Z" },
  { "scope": "project", "projectPath": "$t/proj", "installPath": "$cp/0.4.8", "version": "0.4.8", "installedAt": "2026-09-09T21:32:31.522Z", "lastUpdated": "2026-09-09T21:32:31.522Z", "gitCommitSha": "585394f96703279b0f227a70d37f10ca829bb728" } ] } }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C13-plugin-hooks' && ! grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" '0.4.8' && grepq "$out" 'claude plugin uninstall himmel-ops@himmel --scope project'; then pass "C13 -> INFO (stale project pin skipped, cleanup command given)"; else fail "C13 stale pin -> $(printf '%s' "$out" | grep -A1 C13)"; fi
cat > "$sv/hooks/hooks.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash -c 'h=\"$CLAUDE_PROJECT_DIR/scripts/hooks/served-gone-hook.sh\"; [ -f \"$h\" ] && exec bash \"$h\"'" } ] } ] } }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'served-gone-hook.sh'; then pass "C13 -> WARN (missing hook in the served hooks.json)"; else fail "C13 served missing -> $(printf '%s' "$out" | grep C13)"; fi
rm "$sv/hooks/hooks.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'block-rogue-codex-wsl.sh'; then pass "C13 -> WARN (served plugin has no hooks.json, stale pins are not skipped)"; else fail "C13 served no hooks.json -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

# ── C14: ollama zero-egress defense-in-depth pin (OLLAMA_NO_CLOUD) ────────────
FAKEOLLAMA="$FAKEROOT/ollamabin"; mkdir -p "$FAKEOLLAMA"
printf '#!/bin/sh\necho ollama version fake\n' > "$FAKEOLLAMA/ollama"; chmod +x "$FAKEOLLAMA/ollama"

# Scope DOCTOR_WORKTREE_ROOT at a plain (non-git) empty dir so C7's `git
# worktree list` finds nothing and short-circuits to OK immediately, instead
# of scanning this checkout's real worktrees/branches — a real worktree
# branch forces a live gh/forge call that can hang well past its own timeout
# on some hosts, unrelated to
# C14 itself.
C14_WT_ROOT="$FAKEROOT/c14-empty"; mkdir -p "$C14_WT_ROOT"

echo "== C14: ollama not on PATH -> OK C14-ollama-no-cloud (skipped) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$TOOLS_PATH" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C14-ollama-no-cloud' && grepq "$out" 'not on PATH'; then pass "C14 -> OK (ollama absent, skipped)"; else fail "C14 absent -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

echo "== C14: ollama present, OLLAMA_NO_CLOUD unset -> WARN C14-ollama-no-cloud =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$FAKEOLLAMA:$TOOLS_PATH" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" env -u OLLAMA_NO_CLOUD bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C14-ollama-no-cloud' && grepq "$out" 'pin unset'; then pass "C14 -> WARN (ollama present, pin unset)"; else fail "C14 unset -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

echo "== C14: ollama present, OLLAMA_NO_CLOUD=1 -> OK C14-ollama-no-cloud =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$FAKEOLLAMA:$TOOLS_PATH" OLLAMA_NO_CLOUD=1 DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C14-ollama-no-cloud' && grepq "$out" 'pin is set'; then pass "C14 -> OK (pin set)"; else fail "C14 set -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

# ── C16: delegate to `himmelctl status --json` for install/wiring truth ──
# winpath <path> — MSYS/cygwin path -> Windows form (node.exe misresolves
# MSYS /tmp-style paths for HIMMELCTL_REPO_ROOT/HIMMELCTL_CACHE_DIR), mirrors
# scripts/himmelctl/test/test-wizard-status-cmd.sh's own helper.
winpath() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

echo "== C16: no himmelctl install profile -> INFO graceful skip, exit 0 =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
EMPTYCACHE="$t/cache-empty"; mkdir -p "$EMPTYCACHE"
out="$(HIMMELCTL_CACHE_DIR="$(winpath "$EMPTYCACHE")" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C16-status' && grepq "$out" 'no himmelctl install profile found' && [ "$rc" -eq 0 ]; then
    pass "C16 -> INFO (no profile, graceful skip, rc0)"
else
    fail "C16 no-profile -> rc=$rc; $(printf '%s' "$out" | grep C16)"
fi
rm -rf "$t"

if command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "== C16: himmelctl status reports a red item -> WARN C16-status surfaces it =="
    t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"

    # A minimal himmelctl fixture repo (real manifest.json + the repoRoot-
    # relative files its file-exists probes read), mirroring
    # test-wizard-status-cmd.sh's fixtureRepo.
    fixtureRepo="$t/fixture-repo"
    mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/jira/dist" "$fixtureRepo/scripts/bitbucket/dist" "$fixtureRepo/scripts/lib"
    cp "$REPO_ROOT/scripts/install/manifest.json" "$fixtureRepo/scripts/install/manifest.json"
    : > "$fixtureRepo/scripts/jira/dist/index.js"
    : > "$fixtureRepo/scripts/bitbucket/dist/index.js"
    : > "$fixtureRepo/scripts/lib/doc-guard-map.sh"

    targetC16="$t/target"
    mkdir -p "$targetC16/.claude" "$targetC16/scripts/guardrails"
    : > "$targetC16/scripts/guardrails/lib.sh"
    # Deliberately NO .pre-commit-config.yaml — the known-red item this case
    # asserts gets surfaced (mirrors test-wizard-status-cmd.sh case b).
    cat > "$targetC16/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true}}
JSON
    cacheC16="$t/cache"; mkdir -p "$cacheC16"
    cat > "$cacheC16/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON

    out="$(cd "$targetC16" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC16")" \
        DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
        CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    # Assert both within the SAME C16 block: capture from the WARN C16-status
    # line up to (but not including) the next severity-prefixed check line, and
    # require pre-commit-hooks to appear as one of its detail rows (rather than
    # matching the two strings independently anywhere in the full doctor output,
    # or slurping trailing lines past the C16 block — robust even if a check is
    # ever added after C16).
    c16block="$(printf '%s\n' "$out" | awk '
        /WARN[[:space:]]+C16-status/ { capture = 1; next }
        capture && /^(FAIL|WARN|INFO|OK)[[:space:]]/ { exit }
        capture { print }
    ')"
    if [ -n "$c16block" ] && grepq "$c16block" 'pre-commit-hooks'; then
        pass "C16 -> WARN (delegated red item surfaced)"
    else
        fail "C16 red-item -> $(printf '%s' "$out" | grep -A6 C16-status)"
    fi
    rm -rf "$t"
else
    pass "C16 -> WARN (skipped: node/jq not both available on this host)"
fi

# ── C16 severity discrimination ──────────────────────────────────
# Every path on which C16's himmelctl delegation does NOT happen used to emit
# INFO, so "the install validator is broken" read as "nothing to do". The split
#  (same n/a vs degraded line draws in status-report.js): a clean
# absence of the opt-in (no install profile / no node AND no profile) stays INFO;
# "this should have worked and did not" (bin.js missing, status exits non-zero,
# unparsable/wrong-schema output, jq missing, no node WITH a profile) is WARN
# naming the lost coverage. Each case runs in a FAKE repo (scripts/lib a symlink
# to the real one, himmelctl/bin.js a stub) and is compared against a healthy
# baseline run of the SAME fixture, so the doctor's Summary counters are
# asserted to move by exactly one in the expected direction.
c16_setup() {
    c16_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c16.XXXXXX")" || { fail "C16 setup: mktemp -d failed"; exit 1; }
    mkdir -p "$c16_t/scripts/himmelctl" "$c16_t/home" "$c16_t/claude" "$c16_t/cache"
    ln -s "$REPO_ROOT/scripts/lib" "$c16_t/scripts/lib"
    printf '{"role":"adopter"}' > "$c16_t/cache/install-profile.json"
    # A policy file, so C74-policy (FAIL without one on an installed station) does not move with the profile.
    mkdir -p "$c16_t/home/.himmel"; printf '{"policy":{}}' > "$c16_t/home/.himmel/config.json"
    # Stub status: like the real one, rc=2 when there is no install profile.
    cat > "$c16_t/scripts/himmelctl/bin.js" <<'JS'
const fs = require('fs'), path = require('path');
if (!fs.existsSync(path.join(process.env.HIMMELCTL_CACHE_DIR, 'install-profile.json'))) process.exit(2);
process.stdout.write(JSON.stringify({ items: [] }));
JS
}
c16_run() {  # c16_run [extra env assignments...] -> the doctor's stdout
    (cd "$c16_t" && env HIMMEL_REPO="$c16_t" HIMMEL_DOCTOR_ROOT="$c16_t" HIMMELCTL_CACHE_DIR="$c16_t/cache" CLAUDE_DIR="$c16_t/claude" HOME="$c16_t/home" \
        DOCTOR_OBSERVABILITY_SKIP=1 "$@" "$BASH" "$DOC" --no-color 2>/dev/null)
}
c16_warn() { printf '%s\n' "$1" | sed -n 's/^Summary: .* \([0-9][0-9]*\) WARN .*/\1/p'; }
c16_info() { printf '%s\n' "$1" | sed -n 's/^Summary: .* \([0-9][0-9]*\) INFO.*/\1/p'; }
# c16_expect <label> <baseline-out> <out> <WARN|INFO> <needle> [want_dw want_di]:
# the one C16 line has the severity, names the needle, and the Summary counters
# moved vs the baseline run of the same env by want_dw/want_di (default vs the
# healthy OK baseline: WARN = +1 warn/+0 info, INFO = +0 warn/+1 info).
c16_expect() {
    local label="$1" base="$2" out="$3" sev="$4" needle="$5" dw di line want_dw="${6:-}" want_di="${7:-}"
    dw=$(( $(c16_warn "$out") - $(c16_warn "$base") )); di=$(( $(c16_info "$out") - $(c16_info "$base") ))
    if [ -z "$want_dw" ]; then if [ "$sev" = WARN ]; then want_dw=1 want_di=0; else want_dw=0 want_di=1; fi; fi
    line="$(printf '%s\n' "$out" | grep 'C16-status')"
    if [ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ] && grepq "$line" "^$sev C16-status" && grepq "$line" -F "$needle" \
       && [ "$dw" -eq "$want_dw" ] && [ "$di" -eq "$want_di" ]; then
        pass "C16 $label -> $sev (n_warn +$dw, n_info +$di vs baseline)"
    else
        fail "C16 $label -> want $sev +${want_dw}w/+${want_di}i, got +${dw}w/+${di}i; ${line}"
    fi
}

if command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "== C16 severity: healthy install (profile, status --json ok, 0 items) -> OK, no WARN (false-positive control) =="
    c16_setup
    c16_base="$(c16_run)"
    if grepq "$c16_base" '^OK *C16-status' && ! grepq "$c16_base" '^WARN *C16-status' \
       && ! grepq "$c16_base" '^INFO *C16-status'; then
        pass "C16 healthy -> OK C16-status only"
    else
        fail "C16 healthy baseline -> $(printf '%s' "$c16_base" | grep C16-status)"
    fi
    rm -rf "$c16_t"

    echo "== C16 severity: rc=2 no install profile -> INFO (not applicable, never opted in) =="
    c16_setup; rm -f "$c16_t/cache/install-profile.json"
    c16_expect "no profile (rc=2)" "$c16_base" "$(c16_run)" INFO 'no himmelctl install profile'
    rm -rf "$c16_t"

    echo "== C16 severity: himmelctl/bin.js missing -> WARN naming the lost coverage =="
    c16_setup; rm -f "$c16_t/scripts/himmelctl/bin.js"
    c16_expect "bin.js missing" "$c16_base" "$(c16_run)" WARN 'NOT being checked'
    rm -rf "$c16_t"

    echo "== C16 severity: status --json exits non-zero -> WARN naming the lost coverage =="
    c16_setup
    printf 'process.exit(1);\n' > "$c16_t/scripts/himmelctl/bin.js"
    c16_expect "status exits 1" "$c16_base" "$(c16_run)" WARN 'NOT being checked'
    rm -rf "$c16_t"

    echo "== C16 severity: status --json prints non-JSON -> WARN naming the lost coverage =="
    c16_setup
    printf 'process.stdout.write("not json at all");\n' > "$c16_t/scripts/himmelctl/bin.js"
    c16_expect "unparsable output" "$c16_base" "$(c16_run)" WARN 'NOT being checked'
    rm -rf "$c16_t"

    echo "== C16 severity: status --json prints valid JSON of the wrong schema ({}) -> WARN, never a false OK =="
    c16_setup
    printf 'process.stdout.write("{}");\n' > "$c16_t/scripts/himmelctl/bin.js"
    c16_expect "wrong schema" "$c16_base" "$(c16_run)" WARN 'NOT being checked'
    rm -rf "$c16_t"

    echo "== C16 severity: jq missing on a machine with an install profile -> WARN naming the lost coverage =="
    c16_setup
    C16_NOJQ="$c16_t/nojq"; mkdir -p "$C16_NOJQ"
    for _tool in bash sh git node sort tail sed cat date mktemp mkdir dirname uname wc tr head cp rm mv chmod grep basename; do
        _p="$(command -v "$_tool" 2>/dev/null)" && ln -sf "$_p" "$C16_NOJQ/$_tool" 2>/dev/null
    done
    if PATH="$C16_NOJQ" bash -c 'command -v jq >/dev/null 2>&1'; then fail "C16 no-jq: precondition -- jq is on the curated PATH"; else
        # Baseline = the SAME curated env with no profile (INFO), so only C16 differs.
        mv "$c16_t/cache/install-profile.json" "$c16_t/profile.bak"; c16_nojq_base="$(c16_run PATH="$C16_NOJQ")"
        mv "$c16_t/profile.bak" "$c16_t/cache/install-profile.json"
        c16_expect "jq missing" "$c16_nojq_base" "$(c16_run PATH="$C16_NOJQ")" WARN 'NOT being checked' 1 -1
    fi
    rm -rf "$c16_t"

    echo "== C16 severity: no node resolvable, NO install profile -> INFO; with a profile (install ran once) -> WARN =="
    c16_setup
    if PATH="$NOGH" bash -c 'command -v node >/dev/null 2>&1'; then fail "C16 no-node: precondition -- node is on the curated PATH"; else
        c16_nonode() { c16_run PATH="$NOGH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$c16_t/none" FNM_DIR="$c16_t/none"; }
        mv "$c16_t/cache/install-profile.json" "$c16_t/profile.bak"; c16_nonode_np="$(c16_nonode)"
        mv "$c16_t/profile.bak" "$c16_t/cache/install-profile.json"; c16_nonode_p="$(c16_nonode)"
        # The two runs differ ONLY in the profile, so the counters are compared
        # pairwise (the curated PATH adds unrelated WARNs a healthy baseline lacks).
        c16_expect "no node, no profile" "$c16_nonode_p" "$c16_nonode_np" INFO 'no node found' -1 1
        c16_expect "no node, profile present" "$c16_nonode_np" "$c16_nonode_p" WARN 'NOT being checked' 1 -1
    fi
    rm -rf "$c16_t"
else
    pass "C16 severity discrimination -> (skipped: node/jq not both available on this host)"
fi

# ── C17: dependency readiness -- enabled skill vs required API key ──
echo "== C17: skill not enabled -> OK (nothing to check, no false-positive) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C17-dep-readiness' && [ "$rc" -eq 0 ]; then
    pass "C17 -> OK (no declared skill enabled)"
else
    fail "C17 not-enabled -> rc=$rc; $(printf '%s' "$out" | grep C17)"
fi
rm -rf "$t"

echo "== C17: enabled + keyed + doc clean -> OK C17-dep-readiness =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=abc123\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C17-dep-readiness' && [ "$rc" -eq 0 ]; then
    pass "C17 -> OK (enabled, keyed, doc clean)"
else
    fail "C17 clean -> rc=$rc; $(printf '%s' "$out" | grep C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key absent -> WARN C17-dep-readiness (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'SOME_OTHER_KEY=x\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (key-missing, never-fatal)"
else
    fail "C17 key-missing -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled + keyed but catalog still says disabled -> WARN (doc-disabled) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=abc123\n' > "$t/home/.config/obsidian-second-brain/.env"
printf '**Research toolkit:** disabled (needs XAI + Perplexity API keys)\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled+keyed but a doc still marks its toolkit disabled' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (doc-disabled, never-fatal)"
else
    fail "C17 doc-disabled -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key is quoted-empty (KEY=\"\") -> WARN (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=""\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (quoted-empty value treated as missing)"
else
    fail "C17 quoted-empty -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key is quoted whitespace-only (KEY=\"   \") -> WARN (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY="   "\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (quoted whitespace-only value treated as missing)"
else
    fail "C17 quoted-whitespace -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

# ── C19: installed observability drift + local endpoint readiness ──────────────
# The rule-group assertions below depend on check_c19 successfully parsing the
# stub Prometheus response with jq — on a
# jq-less host check_c19 takes its own "jq unavailable" fallback path instead,
# so both C19 cases branch their expectation on the SAME probe check_c19 itself
# uses, rather than assuming jq is present.
have_jq_c19=0
command -v jq >/dev/null 2>&1 && have_jq_c19=1

echo "== C19: stale assets + empty rules + dead exporter -> WARNs, rc0 =="
t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)" || exit 1; mkdir -p "$t/claude" "$t/install/dashboards" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
printf 'stale prometheus\n' > "$t/install/prometheus.yml"
printf 'stale rules\n' > "$t/install/alerts.rules.yml"
printf 'stale dashboard\n' > "$t/install/dashboards/stale.json"
cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[]}}' ;;
  *:9877/metrics) exit 7 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$t/bin/curl"
out="$(DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_DESIRED=1 DOCTOR_OBSERVABILITY_GRAFANA=1 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$have_jq_c19" -eq 1 ]; then
    rules_expect='Prometheus has zero rule groups'
else
    rules_expect='jq unavailable'
fi
if [ "$rc" -eq 0 ] \
    && grepq "$out" 'observability stack stale — re-run install-grafana.sh' \
    && grepq "$out" "$rules_expect" \
    && grepq "$out" 'flow exporter on http://127.0.0.1:9877/metrics is not answering' \
    && grepq "$out" 'Grafana on http://127.0.0.1:3000/api/health is not answering'; then
    pass "C19 -> all four observability drift/readiness WARNs, never-fatal"
else
    fail "C19 unhealthy -> rc=$rc; $(printf '%s' "$out" | grep C19)"
fi
rm -rf "$t"

echo "== C19: matching assets + nonempty rules + live exporter -> all OK =="
t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)" || exit 1; mkdir -p "$t/claude" "$t/install/dashboards" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
cp "$REPO_ROOT/scripts/observability/prometheus.yml" "$t/install/prometheus.yml"
cp "$REPO_ROOT/scripts/observability/alerts.rules.yml" "$t/install/alerts.rules.yml"
cp "$REPO_ROOT/scripts/observability/dashboards/"*.json "$t/install/dashboards/"
cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[{"name":"himmel-observability"}]}}' ;;
  *:9877/metrics) printf '%s\n' 'flow_run_outcome_total 1' ;;
  *:3000/api/health) printf '%s\n' '{"database":"ok","version":"test"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$t/bin/curl"
# the assets were seeded from THIS tree, so judge this tree — the
# doctor otherwise compares against the primary checkout, which
# drifts from a worker worktree whose base predates the primary's head.
out="$(HIMMEL_DOCTOR_ROOT="$REPO_ROOT" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_DESIRED=1 DOCTOR_OBSERVABILITY_GRAFANA=1 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$have_jq_c19" -eq 1 ]; then
    rules_expect='Prometheus reports 1 rule group(s)'
else
    rules_expect='jq unavailable'
fi
if [ "$rc" -eq 0 ] \
    && ! grepq "$out" 'WARN C19-observability' \
    && grepq "$out" 'installed observability assets match the repo copies' \
    && grepq "$out" "$rules_expect" \
    && grepq "$out" 'flow exporter answers on http://127.0.0.1:9877/metrics' \
    && grepq "$out" 'Grafana answers on http://127.0.0.1:3000/api/health'; then
    pass "C19 -> matching stack and live endpoints report OK"
else
    fail "C19 healthy -> rc=$rc; $(printf '%s' "$out" | grep C19)"
fi
rm -rf "$t"

echo "== C19: cmp/diff unavailable -> INFO, never claims assets match (HIMMEL-1676 regression) =="
# The normal PATH stays; a BASH_ENV file sourced by the doctor child overrides
# command() so `command -v cmp|diff` fails and everything else delegates to the
# builtin. No per-host PATH construction, so no host can skip this case.
NOCMPDIFF_ENV="$FAKEROOT/nocmpdiff.env"
cat > "$NOCMPDIFF_ENV" <<'EOF'
command() {
    if [ "$1" = "-v" ]; then
        case "$2" in cmp|diff) return 1 ;; esac
    fi
    builtin command "$@"
}
EOF
if BASH_ENV="$NOCMPDIFF_ENV" bash -c '! command -v cmp >/dev/null 2>&1 && ! command -v diff >/dev/null 2>&1 && command -v git >/dev/null 2>&1'; then
    pass "C19 cmp/diff fixture -> BASH_ENV command() override hides cmp/diff, keeps the rest"
else
    fail "C19 cmp/diff fixture -> BASH_ENV command() override did not take effect"
fi
t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)" || exit 1; mkdir -p "$t/claude" "$t/install/dashboards" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
cp "$REPO_ROOT/scripts/observability/prometheus.yml" "$t/install/prometheus.yml"
cp "$REPO_ROOT/scripts/observability/alerts.rules.yml" "$t/install/alerts.rules.yml"
cp "$REPO_ROOT/scripts/observability/dashboards/"*.json "$t/install/dashboards/"
cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[{"name":"himmel-observability"}]}}' ;;
  *:9877/metrics) printf '%s\n' 'flow_run_outcome_total 1' ;;
  *:3000/api/health) printf '%s\n' '{"database":"ok","version":"test"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$t/bin/curl"
out="$(BASH_ENV="$NOCMPDIFF_ENV" HIMMEL_DOCTOR_ROOT="$REPO_ROOT" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_DESIRED=1 DOCTOR_OBSERVABILITY_GRAFANA=1 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
    && grepq "$out" 'cmp/diff unavailable — installed observability assets not compared' \
    && ! grepq "$out" 'installed observability assets match the repo copies'; then
    pass "C19 -> cmp/diff unavailable emits INFO, never claims a match it never checked"
else
    fail "C19 cmp/diff-unavailable -> rc=$rc; $(printf '%s' "$out" | grep C19)"
fi
rm -rf "$t"

# ── C20: running node major vs .nvmrc ─────────────
# The drift is a FAIL now — the doctor still never edits .nvmrc or
# switches a runtime, it just refuses to let the two disagree silently. CI and
# NODE_MAJOR_DRIFT_OK=1 keep it visible as a non-fatal WARN.
C20_NODE="$FAKEROOT/c20node"; mkdir -p "$C20_NODE"
# Baked per case, not read from the env at run time: an env-expanding stub body
# has to be single-quoted, which shellcheck reads as SC2016.
c20_node_stub() { printf '#!/bin/sh\necho %s\n' "$1" > "$C20_NODE/node"; chmod +x "$C20_NODE/node"; }

echo "== C20: node major != .nvmrc -> FAIL C20-node, fatal =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf '24\n' > "$t/nvmrc"; c20_node_stub v26.7.0
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=0 CI="" GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'FAIL C20-node' && grepq "$out" 'v26.7.0' && grepq "$out" 'pins 24' && [ "$rc" -eq 1 ]; then
    pass "C20 -> FAIL (running major != pin, exit 1)"
else
    fail "C20 drift -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
# The bypass and CI both downgrade the same finding to a non-fatal WARN.
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=1 CI="" GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C20-node' && grepq "$out" 'NODE_MAJOR_DRIFT_OK=1' && [ "$rc" -eq 0 ]; then
    pass "C20 -> WARN under NODE_MAJOR_DRIFT_OK=1 (bypass honoured, exit 0)"
else
    fail "C20 bypass -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=0 CI=true GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C20-node' && grepq "$out" -F 'CI — advisory here' && [ "$rc" -eq 0 ]; then
    pass "C20 -> WARN under \$CI (a runner's node is not this operator's to fix)"
else
    fail "C20 under CI -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
# ...and it never edits the pin it complains about.
if [ "$(cat "$t/nvmrc")" = "24" ]; then
    pass "C20 left .nvmrc untouched (the bump is an operator decision)"
else
    fail "C20 rewrote .nvmrc to '$(cat "$t/nvmrc")'"
fi
rm -rf "$t"

echo "== C20: node major == .nvmrc -> OK (negative control) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf 'v24\n' > "$t/nvmrc"; c20_node_stub v24.9.0
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C20-node' && ! grepq "$out" 'WARN C20-node' && [ "$rc" -eq 0 ]; then
    pass "C20 -> OK (aligned major, no false drift)"
else
    fail "C20 aligned -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
rm -rf "$t"

echo "== C20: a version-shaped-but-unreadable node is never reported as aligned =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf '24\n' > "$t/nvmrc"; c20_node_stub v24-corrupt
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C20-node' && ! grepq "$out" 'matches the .nvmrc pin' && [ "$rc" -eq 0 ]; then
    pass "C20 -> INFO (unreadable version, never a false 'aligned')"
else
    fail "C20 unreadable -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
rm -rf "$t"

# ── C21: hermes himmel_agent profile default vs lanes.json record ─────────────
LANES_JSON="$REPO_ROOT/scripts/lanes/lanes.json"
EXPECTED_MODEL="$(jq -r '.lanes[] | select(.id=="hermes-oneshot") | .profileDefaultModel // empty' "$LANES_JSON" 2>/dev/null)"

# CRLF, like the operator's real %LOCALAPPDATA%/hermes files, to prove the
# parser survives the only line ending the real fixture actually has.
echo "== C21: hermes profile default matches lanes.json (CRLF fixture) -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\r\n' > "$h/active_profile"
printf 'model:\r\n  default: %s\r\nother:\r\n  key: val\r\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (profile default matches lanes.json, CRLF fixture)"
else
    fail "C21 match -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# Quoted + commented scalar (a YAML dumper's cosmetic re-write of the same
# value) must not read as drift — an advisory check false-WARNing on a
# no-op re-dump is the exact noise this check exists to avoid.
echo "== C21: quoted + commented model.default (same value) -> OK, not a false WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: "%s"  # pinned\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (quoted + commented value parses to the same model)"
else
    fail "C21 quoted -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: SINGLE-quoted model.default (same value) -> OK, not a false WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf "model:\n  default: '%s'\n" "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (single-quoted value parses to the same model)"
else
    fail "C21 single-quoted -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: hermes profile default drifted from lanes.json -> WARN (never FAIL) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: some/other-model\n' > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C21-hermes-profile' && grepq "$out" -F 'some/other-model' && [ "$rc" -eq 0 ]; then
    pass "C21 -> WARN on drift, advisory only (exit 0)"
else
    fail "C21 drift -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# with NO DOCTOR_HERMES_HOME/HERMES_HOME/LOCALAPPDATA override at
# all, check_c21's own default-root resolution must land on $HOME/.hermes —
# NEVER $HOME/AppData/Local/hermes (a Windows layout under a POSIX $HOME) and
# never $HOME/.local/share/hermes (the old non-hermes-upstream fallback). The
# suite's own global DOCTOR_HERMES_HOME hermeticity export is unset for this
# ONE invocation via `env -u`; no hermes install exists under the scratch
# HOME, so this stays the cheap "no hermes install found" INFO path while
# still proving the RESOLVED default path.
echo "== C21: no HERMES_HOME/LOCALAPPDATA override -> default root is \$HOME/.hermes =="
t="$(mktemp -d "${TMPDIR:-/tmp}/doctor-c21.XXXXXX")" || { echo "FAIL - mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(env -u DOCTOR_HERMES_HOME -u HERMES_HOME -u LOCALAPPDATA \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" -F "no hermes install found ($t/home/.hermes)" && [ "$rc" -eq 0 ]; then
    pass "C21 -> default root resolves to \$HOME/.hermes when nothing overrides it, not a Windows AppData path"
else
    fail "C21 default-root -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# codex-1 (round-2 /pr-check finding): a lanes.json where only ONE of the two
# hermes rows declares profileDefaultModel must WARN, not silently validate
# against the one row that happens to have it (the undeclared row's model
# would otherwise never be checked).
echo "== C21: only ONE hermes row declares profileDefaultModel -> WARN, not a silent OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
lanes_one_missing="$t/lanes-one-missing.json"
printf '{"lanes":[{"id":"hermes-oneshot","profileDefaultModel":"%s"},{"id":"hermes-critics"}]}\n' "$EXPECTED_MODEL" > "$lanes_one_missing"
write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: %s\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" DOCTOR_LANES_JSON="$lanes_one_missing" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C21-hermes-profile' && grepq "$out" -F 'only one of' && [ "$rc" -eq 0 ]; then
    pass "C21 -> WARN (one row missing profileDefaultModel is never a silent OK)"
else
    fail "C21 one-missing -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: no hermes install -> INFO, never a false OK/WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_HERMES_HOME="$t/no-such-hermes-dir" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C21-hermes-profile' && ! grepq "$out" 'OK   C21-hermes-profile' && ! grepq "$out" 'WARN C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> INFO (no hermes install, no false verdict)"
else
    fail "C21 no-install -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# ── C23: unlanded local work ───────────────────────────────────
# make_c23_repo <dir> — a base "main" with an origin/main ref pointed at it
# (no real remote needed; unlanded-work.sh's default --base is origin/main).
make_c23_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'base\n' > "$d/base.md"
    git -C "$d" add base.md
    git -C "$d" commit -q -m init
    git -C "$d" branch -M main
    git -C "$d" update-ref refs/remotes/origin/main refs/heads/main
}

echo "== C23: no unlanded work -> OK C23-unlanded =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C23-unlanded'; then pass "C23 -> OK (no unlanded branches)"; else fail "C23 -> $(printf '%s' "$out" | grep C23)"; fi
rm -rf "$t"

echo "== C23: fresh UNLANDED-LIVE branch, no PR -> INFO (not aged) =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/fresh-unlanded
printf 'work\n' > "$t/repo/work.md"; git -C "$t/repo" add work.md
# "@<unix-ts> +0000" — the one date form every git build parses unconditionally
# (this git build's GIT_AUTHOR_DATE rejects the approxidate keyword "now" outright:
# `fatal: invalid date format: now`).
GIT_AUTHOR_DATE="@$(date +%s) +0000" GIT_COMMITTER_DATE="@$(date +%s) +0000" git -C "$t/repo" commit -q -m "feat: add work"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'none aged' && ! grepq "$out" 'WARN C23-unlanded'; then
    pass "C23 -> INFO (fresh unlanded, not aged)"
else
    fail "C23 fresh -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

echo "== C23: AGED UNLANDED-LIVE branch, no PR -> WARN C23-unlanded =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/aged-unlanded
printf 'work\n' > "$t/repo/work.md"; git -C "$t/repo" add work.md
GIT_AUTHOR_DATE="@$(( $(date +%s) - 50*3600 )) +0000" GIT_COMMITTER_DATE="@$(( $(date +%s) - 50*3600 )) +0000" git -C "$t/repo" commit -q -m "feat: add old work"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C23-unlanded' && grepq "$out" -F 'aged unlanded'; then
    pass "C23 -> WARN (aged unlanded branch)"
else
    fail "C23 aged -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

echo "== C23: only a LANDED-ELSEWHERE branch (empty delta), no UNLANDED-LIVE -> INFO =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/already-landed
printf 'extra\n' > "$t/repo/extra.md"; git -C "$t/repo" add extra.md; git -C "$t/repo" commit -q -m "add extra"
rm -f "$t/repo/extra.md"; git -C "$t/repo" add -A; git -C "$t/repo" commit -q -m "revert extra"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'landed-elsewhere' && ! grepq "$out" 'WARN C23-unlanded'; then
    pass "C23 -> INFO (landed-elsewhere only, no unlanded live work)"
else
    fail "C23 landed-elsewhere -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# an unresolvable --base (or any scan
# failure) must not read as the same "no unlanded work" OK a genuinely clean
# repo gets — unlanded-work.sh always exits 0 by contract, writing its
# diagnostic to stderr instead, so a discarded stderr made an operational
# failure indistinguishable from "nothing to report" here.
echo "== C23: unresolvable base (no origin/main ref at all) -> INFO, not a false-clean OK =="
t="$(mktemp -d)"; make_wt_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'scan produced no data' && ! grepq "$out" 'OK   C23-unlanded'; then
    pass "C23 -> INFO (unresolvable base, never a false-clean OK)"
else
    fail "C23 unresolvable-base -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# `cd` into a nonexistent scan_dir
# short-circuits before unlanded-work.sh ever runs, so nothing lands on
# stderr — the empty-TSV/empty-stderr combination must still read INFO, not
# a false-clean OK, driven by the cd's own exit status.
echo "== C23: DOCTOR_UNLANDED_DIR points at a nonexistent directory -> INFO, not a false-clean OK =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/no-such-dir" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'scan produced no data' && ! grepq "$out" 'OK   C23-unlanded'; then
    pass "C23 -> INFO (cd-into-scan_dir failure, never a false-clean OK)"
else
    fail "C23 cd-failure -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# ── C24: expected-but-absent cadence tasks ─────────────────────
# fake_task_probe <dir> <existing-task-names...> — a crontab stub. Only the
# "does <name> exist" shape is faked — good enough for check_c24, which only
# ever asks that question.
# shellcheck disable=SC2016  # single-quoted $1/$2/$3 are emitted literally for the fake binary's own /bin/sh
fake_task_probe() {
    local dir="$1"; shift
    mkdir -p "$dir"
    {
        printf '#!/bin/sh\n'
        printf 'if [ "$1" = "-l" ]; then\n'
        # The leading `:` is LOAD-BEARING when $@ is empty (the "no task
        # names -> empty crontab" shape every C24-absent case relies on):
        # a bare "if COND; then\nfi" with nothing between them is a shell
        # SYNTAX ERROR (empty compound-command body), not an empty
        # then-branch -- this crashed `crontab -l` with rc=2 on every
        # POSIX host and was misread by check_c24's sched_unavailable
        # probe as "the scheduler itself is unreachable", masking the
        # intended WARN under a false INFO.
        printf '    :\n'
        for n in "$@"; do printf '    printf "%%s\\n" "0 0 * * * true # %s"\n' "$n"; done
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$dir/crontab"
    chmod +x "$dir/crontab"
}

echo "== C24: no observability registry -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'no cadence observability registry yet'; then
    pass "C24 -> OK (no registry)"
else
    fail "C24 no-registry -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: registry present, empty expected_tasks -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":[]}\n' > "$t/home/.himmel/observability.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'no cadence tasks expected'; then
    pass "C24 -> OK (empty expected_tasks)"
else
    fail "C24 empty-expected -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: malformed registry (invalid JSON) -> INFO, not a false-clean OK (codex-3) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel"; write_settings "$t/claude" "$WRAPPER"
printf '{not valid json\n' > "$t/home/.himmel/observability.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'could not be parsed' && ! grepq "$out" 'OK   C24-cadence-registry'; then
    pass "C24 -> INFO (malformed registry, never a false-clean OK)"
else
    fail "C24 malformed -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: expected task present on the live scheduler -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"qmd","cadence_seconds":14400}],"expected_tasks":["HIMMEL-Qmd-Reindex"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe" "HIMMEL-Qmd-Reindex"
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'expected cadence task(s) present' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (expected task present)"
else
    fail "C24 present -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: expected task ABSENT from the live scheduler -> WARN C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"qmd","cadence_seconds":14400}],"expected_tasks":["HIMMEL-Qmd-Reindex"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'expected-but-absent cadence task(s): HIMMEL-Qmd-Reindex'; then
    pass "C24 -> WARN (expected task absent)"
else
    fail "C24 absent -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# ── C24: a himmel cron line whose runner or the script the runner calls is gone ──
# fake_cron_lines <dir> <crontab-line...> — a crontab stub that prints the given lines verbatim.
# shellcheck disable=SC2016  # $1 is emitted literally for the fake binary's own /bin/sh
fake_cron_lines() {
    local dir="$1" n; shift
    mkdir -p "$dir"
    : > "$dir/crontab.txt"
    for n in "$@"; do printf '%s\n' "$n" >> "$dir/crontab.txt"; done
    printf '#!/bin/sh\nif [ "$1" = "-l" ]; then cat "%s/crontab.txt"; fi\nexit 0\n' "$dir" > "$dir/crontab"
    chmod +x "$dir/crontab"
}
c24_run() { # <tmp>
    PATH="$1/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$1/none/*.mcp.json" CLAUDE_DIR="$1/claude" HOME="$1/home" bash "$DOC" --no-color 2>&1
}

echo "== C24 (HIMMEL-8640): runner exists but calls a missing script -> FAIL naming the script =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 dead script: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/runner"; write_settings "$t/claude" "$WRAPPER"
printf '#!/usr/bin/env bash\nbash %s/scripts/eval/leg-digest/failure-review-cadence.sh run --vault %s/vault\n' "$t" "$t" > "$t/runner/failure-review-cadence.sh"
chmod +x "$t/runner/failure-review-cadence.sh"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/failure-review-cadence.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if grepq "$out" 'FAIL C24-cadence-registry' && grepq "$out" -F "$t/scripts/eval/leg-digest/failure-review-cadence.sh" && grepq "$out" -F 'arm --force'; then
    pass "C24 -> FAIL (runner calls a missing script; path and re-arm remedy named)"
else
    fail "C24 dead script -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-8640): the runner itself is missing -> FAIL naming the runner =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 dead runner: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/failure-review-cadence.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if grepq "$out" 'FAIL C24-cadence-registry' && grepq "$out" -F "$t/runner/failure-review-cadence.sh"; then
    pass "C24 -> FAIL (runner missing; path named)"
else
    fail "C24 dead runner -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-8640): runner and script both exist, plus a bare-command cron line -> no FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 live runner: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/runner" "$t/scripts/eval/worker-digest"; write_settings "$t/claude" "$WRAPPER"
: > "$t/scripts/eval/worker-digest/failure-review-cadence.sh"
printf '#!/usr/bin/env bash\nbash %s/scripts/eval/worker-digest/failure-review-cadence.sh run --vault %s/vault\n' "$t" "$t" > "$t/runner/failure-review-cadence.sh"
chmod +x "$t/runner/failure-review-cadence.sh"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/failure-review-cadence.sh\" # HIMMEL-FailureReview" "0 0 * * * true # HIMMEL-Qmd-Reindex"
out="$(c24_run "$t")"
if ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (live runner and script; a non-path command is skipped)"
else
    fail "C24 live runner -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: the suite reads an empty stub crontab, never the real one =="
if [ "$(command -v crontab)" = "$DOCTOR_CRON_STUB_DIR/crontab" ] && [ -z "$(crontab -l)" ]; then
    pass "C24 -> the default crontab on PATH is the empty suite stub"
else
    fail "C24 hermetic crontab -> $(command -v crontab)"
fi

echo "== C24: a quoted runner path with a space is not resolved -> no false FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 quoted space: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/no such dir/runner.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (unterminated quote word is skipped, not printed as a dead path)"
else
    fail "C24 quoted space -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: a backslash-escaped runner path with a space is not resolved -> no false FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 escaped space: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "15 06 * * * $t/no\\ such\\ dir/runner.sh # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (trailing-backslash word is skipped)"
else
    fail "C24 escaped space -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: a commented-out HIMMEL row is not a cron row -> no FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 commented row: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "# 15 06 * * * \"$t/runner/gone.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (commented-out row is ignored)"
else
    fail "C24 commented row -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# c24_runner_case <label> <fail|ok> <needle> <runner line...> — a cron row calls a #! runner holding the lines
# (@T@ stands for the scratch dir); fail expects a C24 FAIL naming <needle>, ok expects a C24 line and no FAIL.
c24_runner_case() {
    local label="$1" expect="$2" needle="$3" t out l; shift 3
    t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 $label: mktemp -d failed"; exit 1; }
    mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/runner" "$t/scripts/lib"; write_settings "$t/claude" "$WRAPPER"
    : > "$t/scripts/lib/usage-preflight.sh"
    { printf '#!/usr/bin/env bash\n'; for l in "$@"; do printf '%s\n' "${l//@T@/$t}"; done; } > "$t/runner/r.sh"
    chmod +x "$t/runner/r.sh"
    fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/r.sh\" # HIMMEL-FailureReview"
    out="$(c24_run "$t")"
    if [ "$expect" = fail ]; then
        if grepq "$out" 'FAIL C24-cadence-registry' && grepq "$out" -F "${needle//@T@/$t}"; then pass "C24 $label -> FAIL naming the script"; else fail "C24 $label -> $(printf '%s' "$out" | grep C24)"; fi
    else
        if grepq "$out" 'C24-cadence-registry' && ! grepq "$out" 'FAIL C24-cadence-registry'; then pass "C24 $label -> no FAIL"; else fail "C24 $label -> $(printf '%s' "$out" | grep C24)"; fi
    fi
    rm -rf "$t"
}
echo "== C24: runner shapes the cadence generators write =="
# shellcheck disable=SC2016  # the runner lines keep their $ literal
c24_runner_case 'a $( ) capture whose assignment opens the command' ok '' \
    '_bank=$(CADENCE_USAGE_WORKER=x @T@/scripts/lib/usage-preflight.sh) || _bank='
# shellcheck disable=SC2016
c24_runner_case 'a brace group around a script' ok '' \
    '{ [ "$_o" = complete ] && @T@/scripts/lib/usage-preflight.sh --stamp .; } || true'
# shellcheck disable=SC2016
c24_runner_case 'a missing script after an opening parenthesis' fail '@T@/missing/q.sh' \
    '_rc=0; ( /usr/bin/bash @T@/missing/q.sh --qmd-bin x; _m=$?; exit $_m )'
# shellcheck disable=SC2016
c24_runner_case 'a missing script after unset' fail '@T@/missing/a.sh' \
    '_rc=0; unset X; /usr/bin/bash @T@/missing/a.sh'

echo "== C24: the runners the real pipeline-cadence.sh arm writes walk clean =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 real arm: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/pc" "$t/vault" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\nexit 0\n' > "$t/bin/claude"; chmod +x "$t/bin/claude"
# shellcheck disable=SC2016  # the stub's own $1 stays literal
printf '#!/bin/sh\ncase "$1" in -l) cat "%s/state" 2>/dev/null || exit 1 ;; -) cat > "%s/state" ;; esac\n' "$t" "$t" > "$t/armcron"
chmod +x "$t/armcron"
if env OSTYPE=linux-gnu HOME="$t/home" PATH="$t/bin:$PATH" PIPELINE_CRONTAB="$t/armcron" PIPELINE_BAT_DIR="$t/pc" \
    bash "$REPO_ROOT/scripts/luna/pipeline-cadence.sh" arm --vault "$t/vault" > /dev/null 2>&1 && [ -s "$t/state" ]; then
    cp "$t/state" "$t/probe/crontab.txt"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = "-l" ]; then cat "%s/probe/crontab.txt"; fi\n' "$t" > "$t/probe/crontab"; chmod +x "$t/probe/crontab"
    out="$(c24_run "$t")"
    if [ "$(grep -c 'HIMMEL-Pipeline' "$t/probe/crontab.txt")" -eq 4 ] && grepq "$out" 'C24-cadence-registry' && ! grepq "$out" 'FAIL C24-cadence-registry'; then
        pass "C24 -> no FAIL over the four runners pipeline-cadence.sh arm writes"
    else
        fail "C24 real arm -> $(printf '%s' "$out" | grep C24)"
    fi
else
    fail "C24 real arm: pipeline-cadence.sh arm did not install the runners"
fi
rm -rf "$t"

echo "== C24: an indented commented-out HIMMEL row is not a cron row -> no FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 indented comment: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "  # 15 06 * * * \"$t/runner/gone.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if grepq "$out" 'C24-cadence-registry' && ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (an indented commented-out row is ignored)"
else
    fail "C24 indented comment -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: an absolute data path after an option flag is not a script -> no false FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 option operand: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/runner"; write_settings "$t/claude" "$WRAPPER"
: > "$t/runner/r.sh"; chmod +x "$t/runner/r.sh"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/r.sh\" --output $t/out/generated.js # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if PATH="$t/probe:$PATH" crontab -l 2>/dev/null | grep -qF '# HIMMEL-FailureReview' && grepq "$out" 'C24-cadence-registry' && ! grepq "$out" 'FAIL C24-cadence-registry'; then
    pass "C24 -> no FAIL (the operand of an option flag is data, not a script)"
else
    fail "C24 option operand -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: an interpreter flag before a missing script on the cron row -> FAIL naming the script =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 interpreter flag row: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_cron_lines "$t/probe" "15 06 * * * bash -e $t/missing/s.sh # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if grepq "$out" 'FAIL C24-cadence-registry' && grepq "$out" -F "$t/missing/s.sh"; then
    pass "C24 -> FAIL (a boolean interpreter flag does not hide the missing script)"
else
    fail "C24 interpreter flag row -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: an interpreter flag before a missing script inside the runner -> FAIL naming the script =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-dead.XXXXXX")" || { fail "C24 interpreter flag runner: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home" "$t/probe" "$t/runner"; write_settings "$t/claude" "$WRAPPER"
printf '#!/usr/bin/env bash\nbash -e %s/missing/s.sh run\n' "$t" > "$t/runner/r.sh"
chmod +x "$t/runner/r.sh"
fake_cron_lines "$t/probe" "15 06 * * * \"$t/runner/r.sh\" # HIMMEL-FailureReview"
out="$(c24_run "$t")"
if grepq "$out" 'FAIL C24-cadence-registry' && grepq "$out" -F "$t/missing/s.sh"; then
    pass "C24 -> FAIL (a boolean interpreter flag inside the runner does not hide the missing script)"
else
    fail "C24 interpreter flag runner -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: scheduler probe itself fails (access-denied/transient) -> INFO, not a false-mass-WARN (codex-1, CR round 3) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"qmd","cadence_seconds":14400}],"expected_tasks":["HIMMEL-Qmd-Reindex"]}\n' > "$t/home/.himmel/observability.json"
printf '#!/bin/sh\necho "crontab: permission denied" >&2\nexit 1\n' > "$t/probe/crontab"; chmod +x "$t/probe/crontab"
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'unreachable' && ! grepq "$out" 'WARN C24-cadence-registry' && ! grepq "$out" 'OK   C24-cadence-registry'; then
    pass "C24 -> INFO (scheduler probe unavailable, never a false mass-WARN)"
else
    fail "C24 scheduler-unavailable -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# ── C24: HimmelTelegramBridge's systemd probe ──────────────────
# Every row below puts $FAKEBIN (the "echo Linux" uname stub) FIRST on PATH,
# ahead of $t/probe, so the systemd probe these rows exist to test is what
# actually runs, deterministically, on every host.
echo "== C24 (HIMMEL-2515): HimmelTelegramBridge armed via systemd, no crontab row -> present, OK (the ticket's bug: pre-fix this WARNs) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 systemd-present: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
fake_systemctl "$t/probe" enabled 424242 0
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'expected cadence task(s) present' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (HimmelTelegramBridge present via systemd)"
else
    fail "C24 systemd-present -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515, CR round 1 E1): HimmelTelegramBridge enabled-runtime (not permanent 'enabled') -> STILL present, OK -- a narrower repeat of this ticket's own bug if misclassified =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 systemd-enabled-runtime: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
fake_systemctl "$t/probe" enabledruntime 424242 0
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'expected cadence task(s) present' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (enabled-runtime counts as present, same as enabled)"
else
    fail "C24 systemd-enabled-runtime -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515): HimmelTelegramBridge NOT enabled via systemd, no crontab row -> still absent, WARN (fix must not blanket-excuse the task) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 systemd-disabled: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
fake_systemctl "$t/probe" disabled
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'HimmelTelegramBridge'; then
    pass "C24 -> WARN (systemd reports NOT enabled, still counted absent)"
else
    fail "C24 systemd-disabled -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: HimmelTelegramBridge expected, NO systemctl at all -> falls back to crontab probe, unchanged pre-fix behavior =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 no-systemctl: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/no-such-systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'HimmelTelegramBridge'; then
    pass "C24 -> WARN (no systemctl on PATH, crontab-only fallback unchanged)"
else
    fail "C24 no-systemctl -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515): a NON-bridge task expected, systemctl reports enabled -> the systemd probe must NOT leak to other tasks (still WARN) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 no-leak: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"qmd","cadence_seconds":14400}],"expected_tasks":["HIMMEL-Qmd-Reindex"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
fake_systemctl "$t/probe" enabled 424242 0
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'HIMMEL-Qmd-Reindex'; then
    pass "C24 -> WARN (a non-bridge task stays crontab-only, systemd probe did not leak)"
else
    fail "C24 no-leak -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515): systemctl present but the user bus is unreachable -> falls back to crontab (crontab HAS the row -> OK, proves it was NOT read as absent) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 bus-unreachable: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe" "HimmelTelegramBridge"
fake_systemctl "$t/probe" busfail
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (bus-unreachable fell back to crontab instead of being read as absent)"
else
    fail "C24 bus-unreachable -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (CR round 1 E5): same, but the OLDER systemd bus-failure wording ('Failed to connect to bus: ...') -> also falls back to crontab, not read as absent =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 bus-unreachable-old: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe" "HimmelTelegramBridge"
fake_systemctl "$t/probe" busfailold
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (older bus-unreachable wording also falls back to crontab, not read as absent)"
else
    fail "C24 bus-unreachable-old -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515, CR round 1 finding 2): unrecognized/permission-error is-enabled output falls back to crontab like bus-unreachable (crontab HAS the row -> OK, not misread as 'disabled') =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 finding-2: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe" "HimmelTelegramBridge"
fake_systemctl "$t/probe" permdenied
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (unrecognized/permission-error output falls back to crontab instead of being misread as 'disabled')"
else
    fail "C24 finding-2 -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C30 (HIMMEL-2515, CR round 1 finding 2): unrecognized/permission-error is-enabled output -> INFO, must NEVER claim 'installed but not enabled' (the probe proved nothing) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c30.XXXXXX")" || { fail "C30 finding-2: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
fake_systemctl "$t/probe" permdenied
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c30_line="$(printf '%s' "$out" | grep 'INFO C30-bridge-liveness')"
if grepq "$c30_line" -F 'probe output unrecognised' && grepq "$c30_line" -F 'Failed to get unit file state for telegram-bridge.service: Permission denied' && ! grepq "$c30_line" -F 'bus unreachable' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'installed but not enabled'; then
    pass "C30 -> INFO (unrecognized probe output reported without claiming the bus is unreachable)"
else
    fail "C30 permission-denied cause -> $(printf '%s' "$out" | grep C30)"
fi
fake_systemctl "$t/probe" unrecognised
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
c30_line="$(printf '%s' "$out" | grep 'INFO C30-bridge-liveness')"
if grepq "$c30_line" -F 'probe output unrecognised (invented future state)' && ! grepq "$c30_line" -F 'bus unreachable' && ! grepq "$out" -F 'second diagnostic line' && ! grepq "$out" 'WARN C30-bridge-liveness' && ! grepq "$out" -F 'installed but not enabled'; then
    pass "C30 -> INFO (unrecognised output reports only its first line, without inventing a bus failure)"
else
    fail "C30 unrecognised-output cause -> $(printf '%s' "$out" | grep -A1 C30)"
fi
rm -rf "$t"

echo "== C77 (HIMMEL-7849): bridge poller started before the newest commit to scripts/telegram, scripts/lanes or scripts/lib -> WARN C77-bridge-stale =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c77.XXXXXX")" || { fail "C77: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/probe" "$t/repo/scripts/telegram" "$t/repo/scripts/lib"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" init -q
printf 'x\n' > "$t/repo/scripts/lib/a.sh"
git -C "$t/repo" add -A
GIT_AUTHOR_DATE='2026-10-27T10:00:00Z' GIT_COMMITTER_DATE='2026-10-27T10:00:00Z' git -C "$t/repo" -c user.name=t -c user.email=t@t commit -q -m 'fix: lib change'
fake_systemctl "$t/probe" enabled 424242 0 '@1792000000'
# 1792000000 = 2026-10-14: the poller started well before the 10-27 commit
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if grepq "$out" 'WARN C77-bridge-stale' && grepq "$out" -F 'fix: lib change'; then
    pass "C77 -> WARN (poller started before the newest commit touching the bridge's import graph)"
else
    fail "C77 stale poller -> $(printf '%s' "$out" | grep -A1 C77)"
fi
mkdir -p "$t/home/.himmel/state"
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if grepq "$out" -F 'automatic after station-sync' && grepq "$out" -F 'last restart: never'; then
    pass "C77 fix line says the restart is automatic and that none has run yet"
else
    fail "C77 fix line (no stamp) -> $(printf '%s' "$out" | grep -A1 C77)"
fi
printf '1792000000\n' > "$t/home/.himmel/state/bridge-restart.ts"
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if grepq "$out" -F 'automatic after station-sync' && grepq "$out" -F "last restart: $(date -d @1792000000 '+%F %H:%M' 2>/dev/null || date -r 1792000000 '+%F %H:%M')"; then  # gnu-ok: BSD date -r follows on this same line
    pass "C77 fix line names when station-sync last restarted the bridge"
else
    fail "C77 fix line (stamp) -> $(printf '%s' "$out" | grep -A1 C77)"
fi
fake_systemctl "$t/probe" enabled 424242 0 '@1893000000'
# 1893000000 = 2029: the poller started after the newest commit
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if grepq "$out" 'OK   C77-bridge-stale' && ! grepq "$out" 'WARN C77-bridge-stale'; then
    pass "C77 -> OK (poller started after the newest bridge commit)"
else
    fail "C77 fresh poller -> $(printf '%s' "$out" | grep -A1 C77)"
fi
fake_systemctl "$t/probe" enabled 424242 0 'garbage'
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if grepq "$out" 'INFO C77-bridge-stale' && grepq "$out" -F 'unreadable' && ! grepq "$out" 'OK   C77-bridge-stale'; then
    pass "C77 -> INFO unreadable when the start time cannot be parsed"
else
    fail "C77 unreadable start time -> $(printf '%s' "$out" | grep -A1 C77)"
fi
fake_systemctl "$t/probe" notfound
out="$(HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C77 --root "$t/repo" 2>&1)"
if ! grepq "$out" 'WARN C77-bridge-stale' && ! grepq "$out" 'FAIL C77-bridge-stale'; then
    pass "C77 -> no finding when no bridge unit is installed (most adopters have none)"
else
    fail "C77 no unit -> $(printf '%s' "$out" | grep -A1 C77)"
fi
rm -rf "$t"

echo "== C103 (HIMMEL-11369): the doctor shows the bypass launcher's state, one row per state, running only 'status' =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c103.XXXXXX")" || { fail "C103: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home"; write_settings "$t/claude" "$WRAPPER"
cat > "$t/status" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$t/argv"
[ -f "$t/nap" ] && sleep 3
cat "$t/block"
exit "\$(cat "$t/rc")"
STUB
chmod +x "$t/status"
: > "$t/argv"; : > "$t/all"
c103_block() {
    printf '%s' "$1" > "$t/rc"; shift
    local line kv
    for line in 'bucket: /b' 'enabled: yes' 'active: yes' 'pid: 4242' 'since: Fri 2026-11-27 10:00:00 UTC' 'linger: yes' 'unit: current' 'code: current' 'stop file: no' 'heartbeat: 7s ago'; do
        for kv in "$@"; do [ "${line%%:*}" = "${kv%%=*}" ] && line="${kv%%=*}: ${kv#*=}"; done
        printf '%s\n' "$line"
    done > "$t/block"
}
c103_run() {
    out="$(env BYPASSD_SERVICE_OS=Linux HIMMEL_DOCTOR_BYPASS_STATUS="$t/status" CLAUDE_DIR="$t/claude" HOME="$t/home" "$@" bash "$DOC" --no-color --only C103 2>&1)"
    c103="$(printf '%s' "$out" | grep -A1 'C103-bypass-launcher')"
    printf '%s\n' "$c103" >> "$t/all"
}
c103_expect() {
    if grepq "$c103" "^$(printf '%-4s' "$2") C103-bypass-launcher" && grepq "$c103" -F -- "$3"; then pass "C103 $1 -> $2"; else fail "C103 $1: wanted $2 naming '$3', got: ${c103:-no C103 line}"; fi
}

c103_block 0; c103_run HIMMEL_DOCTOR_TIMEOUT_BINS=none-such
c103_expect "(0) no timeout binary" INFO 'launcher state not read: no timeout or gtimeout to bound the call'
if [ ! -s "$t/argv" ]; then pass "C103 (0) status is not run unbounded"; else fail "C103 (0) status ran: $(cat "$t/argv")"; fi
: > "$t/nap"; c103_run HIMMEL_DOCTOR_BYPASS_TIMEOUT=1; rm -f "$t/nap"
c103_expect "(1) status hangs" INFO 'launcher state unreadable: timeout'
printf '2' > "$t/rc"; printf 'bypass-service: boom\n' > "$t/block"; c103_run
c103_expect "(1) rc 2 and no enabled: line" INFO 'launcher state unreadable: rc 2: bypass-service: boom'
printf '0' > "$t/rc"; : > "$t/block"; c103_run
c103_expect "(1) empty output" INFO 'launcher state unreadable: rc 0'
c103_block 3; c103_run
c103_expect "(1) an unknown rc is not parsed" INFO 'launcher state unreadable: rc 3'
c103_block 1 bucket=none enabled=no active=no; c103_run
c103_expect "(2) not installed" INFO 'not installed as a service (optional)'
if ! grepq "$c103" -F 'himmelctl bypass'; then pass "C103 (2) names no command"; else fail "C103 (2) recommends a command: $c103"; fi
c103_block 1 enabled=no active=no 'stop file=yes'; c103_run
c103_expect "(3) turned off" INFO 'off; from your own shell: himmelctl bypass on'
c103_block 0 'stop file=yes'; c103_run
c103_expect "(3) enabled with a stop file, ahead of every later row" WARN 'himmelctl bypass on'
c103_block 1 active=no; c103_run
c103_expect "(4) enabled but not running, rc 1" WARN 'enabled but not running (failed or stopped); from your own shell: himmelctl bypass restart'
c103_block 1 'unit=STALE (run: himmelctl bypass on)' code=STALE; c103_run
c103_expect "(5) stale unit file, ahead of stale code" WARN 'STALE (run: himmelctl bypass on)'
c103_block 1 code=STALE; c103_run
c103_expect "(6) older code" WARN '/scripts/himmel-update.sh --only bypass_daemon; on a Linux chief station'
c103_block 0 linger=no; c103_run
c103_expect "(7) lingering off" WARN 'loginctl enable-linger'
c103_block 0 linger=no; c103_run BYPASSD_SERVICE_OS=Darwin
c103_expect "(7b) macOS has no lingering" OK 'pid 4242'
c103_block 0; c103_run
c103_expect "(8) healthy" OK 'pid 4242, since Fri 2026-11-27 10:00:00 UTC, heartbeat 7s ago'
if ! grepq "$c103" '^WARN'; then pass "C103 (8) no WARN on a healthy launcher"; else fail "C103 (8) WARNs: $c103"; fi
if [ -s "$t/argv" ] && ! grep -qv '^status$' "$t/argv"; then pass "C103 (9) the only argv ever passed is 'status'"; else fail "C103 (9) argv: $(sort "$t/argv" | uniq -c)"; fi
c103_verbs="$(grep -o 'himmelctl bypass [a-z]*' "$t/all" | sort -u)"
c103_missing=""
while IFS= read -r v; do [ -z "$v" ] || grep -qF -- "$v" "$REPO_ROOT/scripts/station-ops/bypass-service.sh" || c103_missing="$c103_missing [$v]"; done <<< "$c103_verbs"
if grepq "$c103_verbs" -x 'himmelctl bypass on' && grepq "$c103_verbs" -x 'himmelctl bypass restart' && [ -z "$c103_missing" ]; then
    pass "C103 (10) every himmelctl bypass verb the doctor names is one bypass-service.sh names"
else
    fail "C103 (10) verbs '$c103_verbs', unknown to bypass-service.sh: $c103_missing"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515, CR round 1 finding 3): systemd bus unreachable AND no crontab row -> INDETERMINATE, never a false expected-but-absent WARN, never silently dropped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-sysd.XXXXXX")" || { fail "C24 finding-3: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"          # no crontab row -- neither probe can confirm presence
fake_systemctl "$t/probe" busfail
out="$(PATH="$FAKEBIN:$t/probe:$PATH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if ! grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'UNDETERMINED' && grepq "$out" -F 'HimmelTelegramBridge'; then
    pass "C24 -> INFO indeterminate (bus-unreachable + no crontab row is UNDETERMINED, never a false expected-but-absent WARN, never silently dropped)"
else
    fail "C24 finding-3 -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# ── C24: crontab availability must be PER-BACKEND,
# not a whole-function early return ──────────────────────────────────────────
# finding: check_c24 probed the scheduler ONCE before its per-task
# loop and early-returned when it was unavailable -- so on a systemd-only
# Linux host with no `crontab` on PATH at all, that return fired BEFORE the
# per-task loop ever ran, and the systemd probe for HimmelTelegramBridge
# added earlier in this ticket never executed. $NOGH (defined near the top of
# this file) is the curated PATH used here instead of fake_task_probe's
# crontab stub: it symlinks only a fixed tool list that does NOT include
# crontab, so `command -v crontab` genuinely fails and this station's real
# crontab is never touched -- distinct from every fake_task_probe row above,
# which stubs a *working* crontab binary that merely reports no rows.
echo "== C24 (HIMMEL-2515 CR round 4): HimmelTelegramBridge armed via systemd, crontab NOT ON PATH AT ALL -> present, OK (this is the finding: crontab-unavailable must not skip the whole check) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-nocron.XXXXXX")" || { fail "C24 nocron-present: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_systemctl "$t/probe" enabled 424242 0
out="$(PATH="$FAKEBIN:$t/probe:$NOGH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'expected cadence task(s) present' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (HimmelTelegramBridge present via systemd even with no crontab reachable on PATH at all)"
else
    fail "C24 nocron-present -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515 CR round 4): HimmelTelegramBridge NOT enabled via systemd, crontab NOT on PATH at all -> still absent, WARN (proves the fix does not blanket-excuse the bridge) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-nocron.XXXXXX")" || { fail "C24 nocron-absent: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_systemctl "$t/probe" disabled
out="$(PATH="$FAKEBIN:$t/probe:$NOGH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'HimmelTelegramBridge'; then
    pass "C24 -> WARN (systemd reports NOT enabled -- genuinely absent even with crontab unreachable entirely)"
else
    fail "C24 nocron-absent -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515 CR round 4): mixed registry -- bridge armed via systemd + a crontab-ONLY sibling task, crontab NOT on PATH at all -> bridge PRESENT, sibling task INDETERMINATE (never joins the WARN, never silently dropped) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-nocron.XXXXXX")" || { fail "C24 nocron-mixed: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"qmd","cadence_seconds":14400}],"expected_tasks":["HimmelTelegramBridge","HIMMEL-Qmd-Reindex"]}\n' > "$t/home/.himmel/observability.json"
fake_systemctl "$t/probe" enabled 424242 0
out="$(PATH="$FAKEBIN:$t/probe:$NOGH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
# pre-fix, this INDETERMINATE line hardcoded the bridge's cause
# (systemd bus unreachable) and remedy (check telegram-bridge.service) even
# though HIMMEL-Qmd-Reindex is a crontab-ONLY sibling -- crontab, not
# systemd, is what's unreachable here. Assert the corrected per-task
# attribution: names crontab, recommends `crontab -l`, and never sends this
# sibling's operator to check the bridge's unit. Scoped to just this
# INDETERMINATE line's own remedy (via grep -A1, not a pipe -- see this
# file's pipefail note near grepq's definition) rather than the whole $out,
# because C30 legitimately prints 'telegram-bridge.service' elsewhere in its
# own unrelated MainPID remedy.
c24_indet_ctx="$(grep -A1 -F 'UNDETERMINED enablement (crontab itself is unreachable, and these tasks have no other backend): HIMMEL-Qmd-Reindex' <<< "$out")"
if ! grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" 'INFO C24-cadence-registry' && [ -n "$c24_indet_ctx" ] && grepq "$c24_indet_ctx" -F 'crontab -l' && ! grepq "$c24_indet_ctx" 'telegram-bridge.service'; then
    pass "C24 -> bridge present via systemd, crontab-only sibling task INDETERMINATE naming CRONTAB (not systemd) as its cause, recommending crontab -l (not systemctl)"
else
    fail "C24 nocron-mixed -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24 (HIMMEL-2515 CR round 5): HimmelTelegramBridge indeterminate for BOTH reasons -- systemd bus unreachable AND crontab itself unreachable -- must say so honestly, not pick one =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c24-nocron.XXXXXX")" || { fail "C24 both-causes: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":["HimmelTelegramBridge"]}\n' > "$t/home/.himmel/observability.json"
fake_systemctl "$t/probe" busfail
out="$(PATH="$FAKEBIN:$t/probe:$NOGH" HIMMEL_DOCTOR_SYSTEMCTL="$t/probe/systemctl" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if ! grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'HimmelTelegramBridge has UNDETERMINED enablement — neither backend could answer' && grepq "$out" -F 'systemctl --user is-enabled telegram-bridge.service, and crontab -l'; then
    pass "C24 -> HimmelTelegramBridge INDETERMINATE names BOTH backends (systemd unknown + crontab unreachable), recommends both remedies"
else
    fail "C24 both-causes -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# ── C25: orphaned scratchpad watcher sweep ──────────────────────
# The shim seam replaces the platform producer (PowerShell CIM / ps) with a
# fixture emitter of pid|ppid|cmdline lines, so the bash-side detection --
# scratchpad-pattern match, parent-liveness, dead-parent naming -- runs for
# real, identically on every host. No fixture row uses ppid 1: the
# reparented-to-init heuristic is POSIX-only and must stay deterministic here.
C25DIR="$FAKEROOT/c25"; mkdir -p "$C25DIR"
cat > "$C25DIR/fixture-orphans" <<'EOF'
100|99|bash /c/Users/x/.claude/projects/sess-1/watch-branches.sh
99|98|bash --live-session
4242|9999|bash /c/Users/x/.claude-glm/projects/sess-2/poll.sh
5150|4242|sleep 5
6200|6100|bash run.sh | tee C:\Users\x\.claude\projects\sess-3\watch.log
EOF
printf '#!/bin/sh\ncat "%s"\n' "$C25DIR/fixture-orphans" > "$C25DIR/shim-orphans"
chmod +x "$C25DIR/shim-orphans"

echo "== C25: scratchpad watcher with a dead parent -> WARN naming the dead parent =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-orphans" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'WARN C25-orphans' \
    && grepq "$out" 'pid 4242 (parent pid 9999 is dead)' \
    && grepq "$out" 'pid 6200 (parent pid 6100 is dead)' \
    && grepq "$out" 'sess-2/poll.sh'; then
    pass "C25 -> WARN names each dead parent (9999, 6100), never-fatal"
else
    fail "C25 orphan -> rc=$rc; $(printf '%s' "$out" | grep C25)"
fi
if grepq "$out" 'watch-branches.sh'; then
    fail "C25 flagged pid 100 whose parent (99) is alive"
else
    pass "C25 -> live-parent watcher (pid 100) not flagged"
fi
rm -rf "$t"

echo "== C25: a | inside the command line survives the field split =="
# Row 6200 above only MATCHES the scratchpad pattern after its first | -- if
# the pid|ppid|cmd split truncated the command at an embedded pipe, that row
# would silently vanish from the findings.
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-orphans" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'pid 6200' && grepq "$out" 'watch.log'; then
    pass "C25 -> text after an embedded | in a command line is still scanned"
else
    fail "C25 -> command line truncated at an embedded |: $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: no scratchpad watchers -> OK =="
cat > "$C25DIR/fixture-clean" <<'EOF'
100|99|bash /usr/bin/top
200|199|node /opt/app/server.js
300|299|bash /c/Users/x/projects/himmel/scripts/lib/watch-loop.sh
EOF
printf '#!/bin/sh\ncat "%s"\n' "$C25DIR/fixture-clean" > "$C25DIR/shim-clean"
chmod +x "$C25DIR/shim-clean"
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-clean" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C25-orphans' && ! grepq "$out" 'WARN C25-orphans' && [ "$rc" -eq 0 ]; then
    pass "C25 -> OK (no scratchpad references at all)"
else
    fail "C25 clean -> rc=$rc; $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: scan failure -> loud WARN, never a false clean =="
printf '#!/bin/sh\nexit 3\n' > "$C25DIR/shim-fail"; chmod +x "$C25DIR/shim-fail"
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-fail" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C25-orphans' && grepq "$out" 'cannot evaluate'; then
    pass "C25 -> scan failure emits a loud cannot-evaluate WARN"
else
    fail "C25 scan-failure -> $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: skip seam -> OK skipped =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=1 \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C25-orphans' && grepq "$out" 'skipped by test seam'; then
    pass "C25 -> skip seam reports OK skipped"
else
    fail "C25 skip -> $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25 STATIC: check_c25 body must not terminate processes itself =="
_c25_body="$(awk '/^check_c25\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_static25=0
for _verb in "Stop-Process" "kill -"; do
    if grepq "$_c25_body" -F "$_verb"; then
        fail "C25 STATIC: found forbidden verb '$_verb' in check_c25 body"
        _static25=1
    fi
done
if [ "$_static25" -eq 0 ]; then
    pass "C25 STATIC: no self-terminate verbs in check_c25 body"
fi

# c29_mkproc <root> <pid> <session-name> <comm> [environ-entries...] -- writes
# a fake /proc/<pid>/comm, /proc/<pid>/cmdline (a claude invocation naming
# <session-name> via `-n`, NUL-separated argv like the real kernel file), and
# /proc/<pid>/environ (NUL-separated KEY=VALUE entries, same shape
# context-fill.sh's own mkproc()/launched_as_child_session() test fixture
# uses). <comm> lets a case impersonate the konsole LAUNCHER (comm=konsole)
# whose cmdline also quotes `claude ... -n HIMMEL-...`
# (that launcher process is not claude, and must never be flagged).
# the WARN must read THIS file, never the doctor's own
# environment.
c29_mkproc() {
    local root="$1" pid="$2" name="$3" comm="$4"; shift 4
    mkdir -p "$root/$pid"
    printf '%s\n' "$comm" > "$root/$pid/comm"
    printf 'claude\0--model\0claude-fable-5-1\0-n\0%s\0load doc.md and continue\0' "$name" > "$root/$pid/cmdline"
    : > "$root/$pid/environ"
    local v
    for v in "$@"; do printf '%s\0' "$v" >> "$root/$pid/environ"; done
}

echo "== C29: child-session marker with no persistence flag -> WARN, names the pid =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 positive: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5001 "HIMMEL-2545-worker" claude 'CLAUDE_CODE_CHILD_SESSION=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5001' && grepq "$out" 'HIMMEL-2545-worker'; then
    pass "C29 -> WARN names pid 5001 and the session"
else
    fail "C29 positive -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: same marker WITH persistence forced -> no WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-persistence: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5002 "HIMMEL-2545-worker" claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (persistence already forced, no nag)"
else
    fail "C29 control-persistence -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: claude process with NEITHER var -> no WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-neither: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5003 "HIMMEL-2545-worker" claude
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (a plain human-launched session, neither var set)"
else
    fail "C29 control-neither -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: absent proc root and no ps -E -> clean skip, never a false WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-absent: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/no-such-proc" HIMMEL_DOCTOR_PS="$t/no-such-ps" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (no procfs on this platform, clean skip)"
else
    fail "C29 control-absent -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: konsole LAUNCHER (not claude) whose cmdline quotes claude -n HIMMEL-... -> no WARN =="
# Live false positive: headed-arm.sh's konsole
# process has a cmdline naming `claude ... -n HIMMEL-...` (that is the
# command it was told to run) and ALSO inherits CLAUDE_CODE_CHILD_SESSION=1
# from whatever armed it, with no persistence flag of its own -- identical
# environ shape to the genuinely-broken case above, differing ONLY in comm.
# Without the comm==claude gate this fires on every correctly-launched
# headed session via its own launcher.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-launcher: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5004 "HIMMEL-2545-worker" konsole 'CLAUDE_CODE_CHILD_SESSION=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (konsole launcher, not claude, never flagged)"
else
    fail "C29 control-launcher -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29: EMPTY persistence value is absent, not present -> still WARN (HIMMEL-2545 r3-codex-4) =="
# Aligns C29 with context-fill.sh's launched_as_child_session() contract:
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE= with nothing after the = is
# meaningless (no launcher in this diff ever sets it that way) and must be
# treated as absent - the WARN must still fire, not be suppressed by a
# bare existence match.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 empty-persistence: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5005 "HIMMEL-2545-worker" claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5005'; then
    pass "C29 -> WARN fires on an empty persistence value"
else
    fail "C29 empty-persistence -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 (r11-codex-3): a DECOY -n name inside prompt text, positioned BEFORE the genuine -n option -> WARN names the REAL session, never the decoy =="
# The old extraction (grep -Eo against the FLATTENED cmdline) would match
# "-n HIMMEL-decoy" the instant that substring appears anywhere in the
# space-joined text, including inside an earlier PROMPT argument that is
# not an option at all. The fixture below writes the decoy as ONE combined
# argv element (a prompt-shaped string containing "-n HIMMEL-decoy"),
# positioned BEFORE the genuine, POSITIONAL "-n" / "HIMMEL-real" pair - a
# fix that is still reading the flattened string would report the decoy;
# the positional NUL-separated walk must report the real session.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 decoy-name: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
mkdir -p "$t/proc/5006"
printf '%s\n' claude > "$t/proc/5006/comm"
printf 'claude\0--model\0claude-fable-5-1\0load context for -n HIMMEL-decoy and continue\0-n\0HIMMEL-real\0' > "$t/proc/5006/cmdline"
printf 'CLAUDE_CODE_CHILD_SESSION=1\0' > "$t/proc/5006/environ"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5006' && grepq "$out" 'HIMMEL-real' && ! grepq "$out" 'HIMMEL-decoy'; then
    pass "C29 -> WARN names the genuine session (HIMMEL-real), never the decoy prompt text"
else
    fail "C29 decoy-name -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29: UNNAMED session and an adopter's ticket key are both flagged (no HIMMEL- gate) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 any-key: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5007 "ACME-7-worker" claude 'CLAUDE_CODE_CHILD_SESSION=1'
mkdir -p "$t/proc/5008"
printf '%s\n' claude > "$t/proc/5008/comm"
printf 'claude\0' > "$t/proc/5008/cmdline"
printf 'CLAUDE_CODE_CHILD_SESSION=1\0' > "$t/proc/5008/environ"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session: 2 running' && grepq "$out" 'pid 5007 (ACME-7-worker)' && grepq "$out" 'pid 5008 (unnamed)'; then
    pass "C29 -> WARN names the ACME- session and the unnamed one"
else
    fail "C29 any-key -> $(printf '%s' "$out" | grep -A3 C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: a genuine child (a claude ANCESTOR via stat ppid) -> no WARN =="
# claude 6001 -> bash 6002 -> claude 6003: 6003 is a Bash-tool print-mode claude,
# meant to be a throwaway, so its marker is correct. stat's comm holds ") "
# to prove ppid is read after the LAST paren.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-child: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 6001 "parent" claude
printf '6001 (claude) S 1 6001\n' > "$t/proc/6001/stat"
mkdir -p "$t/proc/6002"
printf '%s\n' 'b) S 9 (x' > "$t/proc/6002/comm"
printf '6002 (b) S 9 (x) S 6001 6002\n' > "$t/proc/6002/stat"
c29_mkproc "$t/proc" 6003 "child" claude 'CLAUDE_CODE_CHILD_SESSION=1'
printf '6003 (claude) S 6002 6003\n' > "$t/proc/6003/stat"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (a claude under a claude is a real child session)"
else
    fail "C29 control-child -> $(printf '%s' "$out" | grep -A3 C29)"
fi
rm -rf "$t"

echo "== C29: an orphaned headless claude (-p / --print) or a daemon service with the marker -> no WARN =="
# Neither is a human-launched interactive session: a stub or print-mode claude
# started from a session (at/setsid) and `claude daemon run` carry the marker by
# inheritance and have no transcript to lose.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 headless: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5101 "p-mode" claude 'CLAUDE_CODE_CHILD_SESSION=1'
printf 'claude\0-p\0hello\0' > "$t/proc/5101/cmdline"
c29_mkproc "$t/proc" 5102 "print-mode" claude 'CLAUDE_CODE_CHILD_SESSION=1'
printf 'claude\0--print\0hello\0' > "$t/proc/5102/cmdline"
c29_mkproc "$t/proc" 5103 "daemon" claude 'CLAUDE_CODE_CHILD_SESSION=1'
printf 'claude\0daemon\0run\0' > "$t/proc/5103/cmdline"
c29_mkproc "$t/proc" 5104 "npm-daemon" claude 'CLAUDE_CODE_CHILD_SESSION=1'
printf 'node\0/x/cli.js\0daemon\0run\0' > "$t/proc/5104/cmdline"
c29_mkproc "$t/proc" 5105 "interactive" claude 'CLAUDE_CODE_CHILD_SESSION=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session: 1 running' && grepq "$out" 'pid 5105 (interactive)' \
    && ! grepq "$out" 'pid 5101' && ! grepq "$out" 'pid 5102' && ! grepq "$out" 'pid 5103' && ! grepq "$out" 'pid 5104'; then
    pass "C29 -> headless and daemon roots skipped, the interactive one still flagged"
else
    fail "C29 headless -> $(printf '%s' "$out" | grep -A6 C29)"
fi
rm -rf "$t"

echo "== C29 (macOS route): no procfs -> ps -axo tree + ps -E environ; only the marked ROOT claude is flagged =="
# Fake ps answering the four shapes check_c29 issues, from $fix. -E prints
# the command line then the env, space-joined, like the real macOS ps.
#   200 claude in a terminal tab, marked             -> WARN
#   300 claude under claude 200 (Bash-tool child)    -> skipped
#   400 claude whose PROMPT holds the marker text    -> skipped (args stripped)
#   500 claude by full path, marker, no persistence  -> WARN (comm path stripped)
#   700 claude -p, 800 claude daemon run, both marked -> skipped
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 ps-route: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
fix="$t/fix"; mkdir -p "$fix"
cat > "$fix/table" <<'TABLE'
    1     0 /sbin/launchd
  100     1 /Applications/iTerm.app/Contents/MacOS/iTerm2
  150   100 -zsh
  200   150 claude
  250   200 /bin/zsh
  300   250 claude
  400     1 claude
  500     1 /Users/x/.local/bin/claude
  600     1 /Applications/Obsidian.app/Contents/MacOS/Obsidian Helper (GPU)
  700     1 claude
  800     1 claude
TABLE
printf 'claude' > "$fix/200.args"; printf 'TERM=xterm CLAUDE_PID=89183 CLAUDE_CODE_CHILD_SESSION=1' > "$fix/200.env"
printf 'claude --model m hi' > "$fix/300.args"; printf 'CLAUDE_CODE_CHILD_SESSION=1' > "$fix/300.env"
printf 'claude say CLAUDE_CODE_CHILD_SESSION=1 here' > "$fix/400.args"; printf 'HOME=/x' > "$fix/400.env"
printf 'claude' > "$fix/500.args"; printf 'CLAUDE_CODE_CHILD_SESSION=1' > "$fix/500.env"
printf 'claude -p hello' > "$fix/700.args"; printf 'CLAUDE_CODE_CHILD_SESSION=1' > "$fix/700.env"
printf 'claude daemon run' > "$fix/800.args"; printf 'CLAUDE_CODE_CHILD_SESSION=1' > "$fix/800.env"
cat > "$t/ps" <<PS
#!/usr/bin/env bash
fix="$fix"
a="\$*"; p="\${a##* }"
case "\$*" in
    "-ww -axo pid=,ppid=,comm=") cat "\$fix/table" ;;
    "-E -ww -o command= -p "*) [ -f "\$fix/\$p.args" ] || exit 0
        printf '%s %s\n' "\$(cat "\$fix/\$p.args")" "\$(cat "\$fix/\$p.env")" ;;
    "-ww -o command= -p "*) [ -f "\$fix/\$p.args" ] || exit 1; cat "\$fix/\$p.args"; echo ;;
    "-o tty= -p "*) printf 'ttys%03d \n' "\$p" ;;
    *) exit 1 ;;
esac
PS
chmod +x "$t/ps"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/no-such-proc" HIMMEL_DOCTOR_PS="$t/ps" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session: 2 running' && grepq "$out" 'pid 200 (tty ttys200)' && grepq "$out" 'pid 500 (tty ttys500)' \
    && ! grepq "$out" 'pid 300' && ! grepq "$out" 'pid 400' && ! grepq "$out" 'pid 700' && ! grepq "$out" 'pid 800'; then
    pass "C29 -> WARN on macOS names only the marked interactive root claudes, by tty"
else
    fail "C29 ps-route -> $(printf '%s' "$out" | grep -A6 C29)"
fi
rm -rf "$t"

echo "== C29 (macOS route): a Mac app still carrying a DEAD claude's marker is named; a live one and a shell are not (SCRUM-2) =="
#   100 Raycast, marker of dead claude 89183          -> WARN names Raycast once
#   110 Raycast helper, same marker                   -> folded into Raycast
#   120 iTerm2, marker of live claude 300             -> skipped (a running claude's child)
#   130 zsh, marker of dead claude                    -> skipped (not an app)
#   140 Obsidian, dead marker + persistence override  -> skipped (its claudes save transcripts)
#   300 claude, unmarked                              -> no session WARN
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 ps-carrier: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
fix="$t/fix"; mkdir -p "$fix"
cat > "$fix/table" <<'TABLE'
    1     0 /sbin/launchd
  100     1 /Applications/Raycast.app/Contents/MacOS/Raycast
  110   100 /Applications/Raycast.app/Contents/Frameworks/Raycast Helper (GPU)
  120     1 /Applications/iTerm.app/Contents/MacOS/iTerm2
  130   120 -zsh
  140     1 /Applications/Obsidian.app/Contents/MacOS/Obsidian
  300   130 claude
TABLE
printf '/Applications/Raycast.app/Contents/MacOS/Raycast' > "$fix/100.args"; printf 'CLAUDE_PID=89183 CLAUDE_CODE_CHILD_SESSION=1' > "$fix/100.env"
printf 'helper' > "$fix/110.args"; printf 'CLAUDE_PID=89183 CLAUDE_CODE_CHILD_SESSION=1' > "$fix/110.env"
printf 'iTerm2' > "$fix/120.args"; printf 'CLAUDE_PID=300 CLAUDE_CODE_CHILD_SESSION=1' > "$fix/120.env"
printf -- '-zsh' > "$fix/130.args"; printf 'CLAUDE_PID=89183 CLAUDE_CODE_CHILD_SESSION=1' > "$fix/130.env"
printf 'Obsidian' > "$fix/140.args"; printf 'CLAUDE_PID=89183 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1' > "$fix/140.env"
printf 'claude' > "$fix/300.args"; printf 'HOME=/x' > "$fix/300.env"
cat > "$t/ps" <<PS
#!/usr/bin/env bash
fix="$fix"
a="\$*"; p="\${a##* }"
case "\$*" in
    "-ww -axo pid=,ppid=,comm=") cat "\$fix/table" ;;
    "-E -ww -o command= -p "*) [ -f "\$fix/\$p.args" ] || exit 0
        printf '%s %s\n' "\$(cat "\$fix/\$p.args")" "\$(cat "\$fix/\$p.env")" ;;
    "-ww -o command= -p "*) [ -f "\$fix/\$p.args" ] || exit 1; cat "\$fix/\$p.args"; echo ;;
    "-o tty= -p "*) printf 'ttys%03d \n' "\$p" ;;
    *) exit 1 ;;
esac
PS
chmod +x "$t/ps"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/no-such-proc" HIMMEL_DOCTOR_PS="$t/ps" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session: 1 Mac app' && grepq "$out" 'pid 100 (Raycast)' \
    && grepq "$out" 'saves no transcript: Raycast ' && ! grepq "$out" 'pid 110' && ! grepq "$out" 'iTerm' && ! grepq "$out" 'pid 130' && ! grepq "$out" 'Obsidian' && ! grepq "$out" 'running claude session'; then
    pass "C29 -> WARN names the Mac app carrying a dead claude's marker, once per app"
else
    fail "C29 ps-carrier -> $(printf '%s' "$out" | grep -A6 C29)"
fi
rm -rf "$t"

echo "== C84: a station with neither USER_SLUG nor HIMMEL_RELEASE_STATE_DIR gets one note =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c84root.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; write_settings "$t/claude" "$WRAPPER"; mkdir -p "$t/repo" "$t/home"
out="$(USER_SLUG='' HIMMEL_RELEASE_STATE_DIR='' HANDOVER_DIR="$t/handover" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C84 --root "$t/repo" 2>&1)"
if [ "$(grep -c 'INFO C84-release-queue: neither USER_SLUG nor HIMMEL_RELEASE_STATE_DIR' <<< "$out")" = 1 ]; then pass "C84 -> one note line naming USER_SLUG when neither variable is set"; else fail "C84 neither -> $(printf '%s' "$out" | grep C84)"; fi
out="$(USER_SLUG=someone HIMMEL_RELEASE_STATE_DIR='' HANDOVER_DIR="$t/handover" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color --only C84 --root "$t/repo" 2>&1)"
if ! grepq "$out" 'neither USER_SLUG nor HIMMEL_RELEASE_STATE_DIR'; then pass "C84 -> no note when USER_SLUG is set"; else fail "C84 USER_SLUG set -> $(printf '%s' "$out" | grep C84)"; fi
rm -rf "$t"

echo "== C84: the new-only unplaced WARN (S4): new tickets warn; legacy, pending and serious-later alone stay quiet =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-unp.XXXXXX")" || { fail "C84 unplaced: mktemp -d failed"; exit 1; }
mkdir -p "$t/home" "$t/claude" "$t/h/release/R1" "$t/mirror/ACME" "$t/git/scripts/jira/src/release"
printf '{"name":"R1"}\n' > "$t/h/release/R1/release.json"
printf '# chief\n## Live state\nrelease: R1\n' > "$t/h/X-chief.md"
printf 'v1.1.3\tfalse\t\tfalse\n' > "$t/mirror/ACME.versions.tsv"
unp_ticket() {
    printf -- '---\nkey: "ACME-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "To Do"\npriority: "%s"\nlabels: []\nfixVersions: %s\nparent: null\ncreated: "%sT10:00:00.000+0100"\nsector: "S"\n---\n\n# ACME-%s: t\n' "$1" "$2" "$3" "$4" "$1" > "$t/mirror/ACME/ACME-$1.md"
}
cat > "$t/probe" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"OK","current":"v1.1.3","versions":["v1.1.3","v1.1.4"],"requests":{"open":[],"claimed":[],"oldest_open":null,"pending_keys":%s}}\n' "${UNP_PENDING:-[]}"
EOF
git -C "$t/git" init -q . && git -C "$t/git" config user.email t@t && git -C "$t/git" config user.name t
: > "$t/git/scripts/jira/src/release/door.ts"; git -C "$t/git" add -A
GIT_AUTHOR_DATE="2026-11-23T12:00:00" GIT_COMMITTER_DATE="2026-11-23T12:00:00" git -C "$t/git" commit -q -m door
unp_run() { HIMMEL_DOOR_REPO="$t/git" NEXT_DISPATCH_MIRROR="$t/mirror/ACME" JIRA_PROJECT_KEY=ACME HIMMEL_DOCTOR_RM_STATE_PROBE="$t/probe" HIMMEL_RELEASE_STATE_DIR="$t/h/release" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --only C84 --no-color 2>&1; }
rm -f "$t/mirror/ACME/"*.md
unp_ticket 1 Medium '[]' 2026-11-24
out="$(unp_run)"
if grepq "$out" 'WARN C84-release-queue: 1 open ticket(s) filed since the door shipped'; then pass "C84 one new unplaced ticket -> WARN"; else fail "C84 new unplaced -> $(printf '%s' "$out" | grep C84)"; fi
rm -f "$t/mirror/ACME/"*.md
unp_ticket 2 Medium '[]' 2026-11-01
out="$(unp_run)"
if ! grepq "$out" 'filed since the door shipped'; then pass "C84 a legacy unplaced ticket alone -> no unplaced WARN"; else fail "C84 legacy only -> $(printf '%s' "$out" | grep C84)"; fi
rm -f "$t/mirror/ACME/"*.md
unp_ticket 3 Medium '[]' 2026-11-24
out="$(UNP_PENDING='["ACME-3"]' unp_run)"
if ! grepq "$out" 'filed since the door shipped'; then pass "C84 a pending unplaced ticket alone -> no unplaced WARN"; else fail "C84 pending only -> $(printf '%s' "$out" | grep C84)"; fi
rm -f "$t/mirror/ACME/"*.md
unp_ticket 4 High '["v1.1.4"]' 2026-11-24
out="$(unp_run)"
if ! grepq "$out" 'filed since the door shipped'; then pass "C84 a serious-later ticket alone -> no unplaced WARN"; else fail "C84 serious-later only -> $(printf '%s' "$out" | grep C84)"; fi
if [ "$(sed -n '/^_c84_unplaced()/,/^}/p' "$DOC" | grep -c 'git ')" = 0 ]; then pass "C84 the doctor runs no git read of its own for the date"; else fail "C84 the doctor reads git itself"; fi
rm -rf "$t"

echo "== C95: the repo-gone probes run inside the holds read budget =="
# shellcheck disable=SC1091
{ . "$REPO_ROOT/scripts/lib/timeout-bin.sh"; } 2>/dev/null || _TIMEOUT_BIN=""
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    t="$(mktemp -d "${TMPDIR:-/tmp}/c95-probe.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
    mkdir -p "$t/root/scripts/handover/chief-kit" "$t/claude" "$t/r1" "$t/r2"
    ln -s "$REPO_ROOT/scripts/lib" "$t/root/scripts/lib"
    cat > "$t/root/scripts/handover/chief-kit/holds.py" <<'EOF'
import os, sys, time
if sys.argv[1] == 'repo-gone':
    repo = sys.argv[sys.argv.index('--repo') + 1]
    open(os.environ['C95_STUB_LOG'], 'a').write(repo + '\n')
    time.sleep(12)
    sys.exit(1 if os.path.lexists(repo) else 0)
sys.exit(0)
EOF
    for r in "$t/r1" "$t/r2" "$t/r3"; do e="${r//%/%25}"; mkdir -p "$t/home/.himmel/state/holds/${e//\//%2F}"; done
    : > "$t/probes.log"
    SECONDS=0
    out="$(env CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_DOCTOR_HOLDS_T=4 C95_STUB_LOG="$t/probes.log" "$_TIMEOUT_BIN" -k 2 40 bash "$DOC" --root "$t/root" --only C95 --no-color 2>&1 < /dev/null)"
    if grep -Fxq -- "$t/r1" "$t/probes.log" && ! grep -Fxq -- "$t/r3" "$t/probes.log"; then pass "C95 no repo-gone probe starts once the budget is spent"; else fail "C95 a probe started after the budget ($(tr '\n' ' ' < "$t/probes.log"))"; fi
    if grepq "$out" -E "WARN C95-barrier-off.*NOT ATTEMPTED for $t/r3"; then pass "C95 the register no probe had time for is reported NOT ATTEMPTED, not skipped as gone"; else fail "C95 unprobed register -> $(printf '%s' "$out" | head -4)"; fi
    if [ "$SECONDS" -lt 8 ]; then pass "C95 a probe sleeping past the budget is cut by what is left of it (${SECONDS}s)"; else fail "C95 probes ran past the budget (${SECONDS}s)"; fi
    rm -rf "$t"
else
    echo "  SKIP: C95 probe budget — no timeout binary"
fi

echo "== C101: a guard refusal class with no owning open ticket -> WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c101.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
mkdir -p "$t/claude" "$t/mirror" "$t/home/.himmel/state"
c101_row() {
    jq -cn --arg rule "$1" --arg instance "$2" --arg title "${3:-}" \
        '{v:1, ts:"2026-11-25T10:00:00Z", host:"h", source:"guard-t3-thread-tools", kind:"refusal", guard:"guard-t3-thread-tools", rule:$rule, instance:$instance, title:$title}' >> "$t/rows.jsonl"
}
c101_ticket() {
    printf -- '---\nkey: "HIMMEL-%s"\nstatusCategory: "%s"\n---\n\n%s\n' "$1" "$2" "$3" > "$t/mirror/HIMMEL-$1.md"
}
c101_run() {
    env CLAUDE_DIR="$t/claude" HOME="$t/home" HIMMEL_JIRA_MIRROR="$t/mirror" HIMMEL_GUARD_REFUSALS_LOG="${1-$t/rows.jsonl}" bash "$DOC" --only C101 --no-color 2>&1
}
out="$(c101_run)"
if grepq "$out" 'OK   C101-guard-refusals'; then pass "C101 a missing row file passes"; else fail "C101 missing file -> $out"; fi
: > "$t/rows.jsonl"
out="$(c101_run)"
if grepq "$out" 'OK   C101-guard-refusals'; then pass "C101 an empty row file passes"; else fail "C101 empty file -> $out"; fi
c101_row off-narrow antigravity "Orchestrator (Neon) sk-SETTINGSVALUE"
c101_row off-narrow antigravity "Orchestrator (Carbon)"
c101_ticket 1 "To Do" 'guard-t3-thread-tools refuses something else (rule off-narrow-extra)'
c101_ticket 2 "Done" 'guard-t3-thread-tools rule off-narrow, fixed'
c101_ticket 4 "To Do" 'guard-t3-thread-tools rules off-narrow.extra and off-narrow:v2 and x.off-narrow'
out="$(c101_run)"
if grepq "$out" -F 'WARN C101-guard-refusals: guard refusal class with no owning open ticket: guard=guard-t3-thread-tools rule=off-narrow instance=antigravity count=2'; then pass "C101 an unowned class WARNs with guard, rule, instance and count (a Done ticket and a longer rule name do not own it)"; else fail "C101 unowned -> $out"; fi
if ! grepq "$out" -E 'Orchestrator|SETTINGSVALUE'; then pass "C101 no thread title or row text is printed"; else fail "C101 leaked row text -> $out"; fi
c101_ticket 3 "In Progress" 'The guard guard-t3-thread-tools refuses with rule off-narrow.'
out="$(c101_run)"
if grepq "$out" 'OK   C101-guard-refusals' && ! grepq "$out" 'WARN C101'; then pass "C101 a class an open ticket names does not WARN"; else fail "C101 owned -> $out"; fi
chmod 000 "$t/mirror/HIMMEL-1.md"
if [ -r "$t/mirror/HIMMEL-1.md" ]; then
    echo "  SKIP: C101 unreadable mirror file — this user can read a mode-000 file"
else
    out="$(c101_run)"
    if grepq "$out" 'INFO C101-guard-refusals: the Jira mirror' && ! grepq "$out" 'OK   C101'; then pass "C101 a mirror that cannot be fully read -> INFO, not judged"; else fail "C101 partial mirror -> $out"; fi
fi
chmod 644 "$t/mirror/HIMMEL-1.md"
out="$(HIMMEL_LEDGERS_JSON="$t/no-ledgers.json" c101_run "")"
if grepq "$out" 'INFO C101-guard-refusals: ledger registry unreadable' && ! grepq "$out" 'OK   C101'; then pass "C101 an unreadable ledger registry -> INFO, not OK"; else fail "C101 no registry -> $out"; fi
c101_row bypass-instance,off-narrow codex
out="$(c101_run)"
if grepq "$out" -F 'rule=bypass-instance,off-narrow instance=codex count=1' && ! grepq "$out" -F 'instance=antigravity'; then pass "C101 a joined rule list needs every rule named; the owned class stays quiet"; else fail "C101 joined rules -> $out"; fi
rm -f "$t/rows.jsonl"; c101_row non-string-instance '{"apiKey": "hunter2 value"}'
out="$(c101_run)"
if grepq "$out" -F 'rule=non-string-instance instance=non-token count=1' && ! grepq "$out" hunter2; then pass "C101 a field that is not a plain token prints as non-token"; else fail "C101 non-token -> $out"; fi
cp "$t/rows.jsonl" "$t/home/.himmel/state/guard-refusals.jsonl"
out="$(c101_run "")"
if grepq "$out" -F 'instance=non-token count=1'; then pass "C101 with no override the path comes from the ledger registry"; else fail "C101 default path -> $out"; fi
mv "$t/mirror" "$t/mirror.gone"
out="$(c101_run)"
if grepq "$out" 'INFO C101-guard-refusals' && ! grepq "$out" 'WARN C101'; then pass "C101 no ticket mirror -> INFO, ownership not judged"; else fail "C101 no mirror -> $out"; fi
mkdir "$t/rows.dir"
out="$(c101_run "$t/rows.dir")"
if grepq "$out" 'INFO C101-guard-refusals'; then pass "C101 a path that is no readable file is not judged"; else fail "C101 unreadable -> $out"; fi
rm -rf "$t"

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
