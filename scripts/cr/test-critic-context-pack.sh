#!/usr/bin/env bash
# Suite for scripts/cr/critic-context-pack.sh and its wiring in
# scripts/eval/review-panel/run.sh (slice 1). No model call, no Jira:
# every `node` here is a shim on PATH, and the panel is a stub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$HERE/critic-context-pack.sh"
CFP="$HERE/critic-first-pass.sh"
RUN="$HERE/../eval/review-panel/run.sh"

fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { echo "FAIL: $1 - got '$2' want '$3'"; fail=1; }; }
has() { n=$((n + 1)); printf '%s' "$2" | grep -qF -e "$3" || { echo "FAIL: $1 - missing '$3'"; fail=1; }; }
hasnt() { n=$((n + 1)); ! printf '%s' "$2" | grep -qF -e "$3" || { echo "FAIL: $1 - unexpected '$3'"; fail=1; }; }

tmp="$(mktemp -d -t critic-context-pack.XXXXXX)" || exit 1; trap 'rm -rf "$tmp"' EXIT

# --- fixture repo: a.sh defines f, b.sh calls it, c.txt calls -dash, big.txt is over 16 KB ----------
S="$tmp/src"; git init -q "$S"
sg() { git -C "$S" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
printf '#!/usr/bin/env bash\nf() {\n    echo old\n}\n' > "$S/a.sh"
printf '#!/usr/bin/env bash\n. ./a.sh\nf\n' > "$S/b.sh"
printf -- '-dash() {\n    echo dold\n}\n' > "$S/d.dsh"
printf 'call -dash here\n' > "$S/c.txt"
printf '*.dsh diff=dsh\n' > "$S/.gitattributes"
sg config diff.dsh.xfuncname '^(-[a-z]+.*)$'
awk 'BEGIN { for (i = 1; i <= 600; i++) printf "line %d filler filler filler filler\n", i }' > "$S/big.txt"
sg add -A && sg commit -qm base; SB="$(sg rev-parse HEAD)"
# the two case diffs for run.sh (a.sh only): real-01 changes f, real-02 only appends a comment
printf '#!/usr/bin/env bash\nf() {\n    echo new\n    echo extra\n}\n' > "$S/a.sh"
RL="$tmp/real"; mkdir -p "$RL"; sg diff > "$RL/real-01.patch"; sg checkout -q -- .
printf '# end\n' >> "$S/a.sh"; sg diff > "$RL/real-02.patch"; sg checkout -q -- .
cp "$RL/real-01.patch" "$RL/real-03.patch"; cp "$RL/real-02.patch" "$RL/real-04.patch"
for c in 01 02 03; do printf 'Done: f prints new and extra. DONE-CRITERIA-MARKER-%s\n' "$c" > "$RL/real-$c.intent.md"; done
# the head: f changed, -dash changed, one line of big.txt changed
printf '#!/usr/bin/env bash\nf() {\n    echo new\n    echo extra\n}\n' > "$S/a.sh"
printf -- '-dash() {\n    echo dnew\n}\n' > "$S/d.dsh"
awk '{ if (NR == 300) sub(/^line 300 /, "line 300 CHANGED "); print }' "$S/big.txt" > "$tmp/big.new" && mv "$tmp/big.new" "$S/big.txt"
sg add -A && sg commit -qm head; SH="$(sg rev-parse HEAD)"
RK="$tmp/real-key.json"
python3 -c 'import json,sys
base, out = sys.argv[1:3]
defects = lambda pair: [{"id": pair + "1", "class": "cross-file", "file": "a.sh", "line": 3},
                        {"id": pair + "2", "class": "spec-miss", "file": "a.sh", "line": 4}]
seeded = lambda pair, split: {"kind": "seeded", "pair": pair, "split": split, "base": base, "defects": defects(pair)}
clean = lambda pair, split: {"kind": "clean", "pair": pair, "split": split, "base": base, "defects": []}
json.dump({"canary": "rpk-canary-real", "cases": {"real-01": seeded("r-a", "open"), "real-02": clean("r-a", "open"),
           "real-03": seeded("r-b", "sealed"), "real-04": clean("r-b", "sealed")}}, open(out, "w"))' "$SB" "$RK"

pack() { (cd "$S" && bash "$PACK" "$@" 2>&1); }
printf 'Done: f prints new and extra. DONE-CRITERIA-MARKER-FILE\n' > "$tmp/intent.md"

# shims: a failing node that records any call, and a Jira node that answers a ticket
mkdir -p "$tmp/failbin" "$tmp/jirabin"
# shellcheck disable=SC2016  # the shim's text is literal shell
printf '#!/bin/sh\necho "$JIRA_PROJECT_KEY $*" >> "%s/node-called"\nexit 1\n' "$tmp" > "$tmp/failbin/node"
cat > "$tmp/jirabin/node" <<EOF
#!/bin/sh
echo "\$JIRA_PROJECT_KEY \$*" >> "$tmp/jira-called"
printf 'HIMMEL-9: a title\nImpact\nJIRA-IMPACT-MARKER\nWhat\nJIRA-WHAT-MARKER\nWhy\nJIRA-WHY-MARKER\nDoD\nJIRA-DOD-MARKER\nProof\nJIRA-PROOF-MARKER\n'
EOF
chmod +x "$tmp/failbin/node" "$tmp/jirabin/node"
: > "$tmp/index.js"; export CRITIC_PACK_JIRA_JS="$tmp/index.js"

# --- RED row: the callers and the done-criteria text reach the pack ----------------------------------
out="$(pack "$SB" "$SH" --intent-file "$tmp/intent.md")"
has "pack: a caller of the changed f, from outside the diff" "$out" "3: f"
has "pack: the done-criteria text" "$out" "DONE-CRITERIA-MARKER-FILE"
eq "pack: the changed file is a block of its own, not a caller" "$(printf '%s\n' "$out" | grep -c '^{"range": \["a.sh"')" "1"
eq "pack: b.sh is cited as a caller" "$(printf '%s\n' "$out" | grep -c '^{"range": \["b.sh"')" "1"

# the pack is a context file the critic accepts
pp="$(git -C "$S" diff "$SB" "$SH" | bash "$CFP" --model x/y --slug s --print-prompt --context-file <(cd "$S" && bash "$PACK" "$SB" "$SH" --intent-file "$tmp/intent.md") 2>&1)"
has "critic: the pack lands in the prompt as context" "$pp" "<context>"
hasnt "critic: the pack is not refused" "$pp" "context file refused"

# --- intent tiers: an intent file, Jira, the PR body, none -------------------------------------------
rm -f "$tmp/jira-called" "$tmp/node-called"
out="$(PATH="$tmp/jirabin:$PATH" pack "$SB" "$SH" --intent-file "$tmp/intent.md" --ticket HIMMEL-9)"
has "tier 1: the intent file" "$out" "DONE-CRITERIA-MARKER-FILE"
eq "tier 1: Jira is not called when an intent file is given" "$([ -e "$tmp/jira-called" ] && echo called || echo none)" "none"
out="$(PATH="$tmp/jirabin:$PATH" pack "$SB" "$SH" --ticket HIMMEL-9)"
has "tier 2: Jira What" "$out" "JIRA-WHAT-MARKER"
has "tier 2: Jira DoD" "$out" "JIRA-DOD-MARKER"
hasnt "tier 2: not the Why" "$out" "JIRA-WHY-MARKER"
hasnt "tier 2: not the Proof" "$out" "JIRA-PROOF-MARKER"
eq "tier 2: the project key comes from the ticket key" "$(cat "$tmp/jira-called")" "HIMMEL $tmp/index.js get HIMMEL-9"
printf 'Intro\n\n## Ticket coverage\n- ask one: done PR-COVERAGE-MARKER\n\n## Other\nOTHER-MARKER\n' > "$tmp/body.md"
rm -f "$tmp/node-called"
out="$(PATH="$tmp/failbin:$PATH" pack "$SB" "$SH" --ticket HIMMEL-9 --pr-body-file "$tmp/body.md")"
has "tier 3: a failing Jira falls to the PR body" "$out" "PR-COVERAGE-MARKER"
hasnt "tier 3: only the Ticket coverage section" "$out" "OTHER-MARKER"
eq "tier 3: Jira was tried" "$([ -e "$tmp/node-called" ] && echo called || echo none)" "called"
out="$(pack "$SB" "$SH")"
has "tier 4: no intent anywhere" "$out" "no ticket intent available"

# --- the budget -------------------------------------------------------------------------------------
out="$(pack "$SB" "$SH" --intent-file "$tmp/intent.md")"
has "default budget: a large file arrives as its hunks, the changed line is there" "$out" "300: line 300 CHANGED"
hasnt "default budget: the large file is not whole" "$out" "100: line 100 "
out="$(pack "$SB" "$SH" --intent-file "$tmp/intent.md" --budget 1500)"
eq "budget 1500: the pack fits" "$([ "$(printf '%s\n' "$out" | wc -c)" -le 1500 ] && echo fits || echo over)" "fits"
has "budget 1500: the intent is kept" "$out" "DONE-CRITERIA-MARKER-FILE"
hasnt "budget 1500: the large file is dropped, not cut" "$out" "300: line 300 CHANGED"

# --- a function name that starts with a dash is a fixed string ---------------------------------------
out="$(pack "$SB" "$SH" --intent-file "$tmp/intent.md")"
has "dash name: git's hunk header names it" "$out" "-dash"
eq "dash name: its caller in c.txt is cited" "$(printf '%s\n' "$out" | grep -c '^{"range": \["c.txt"')" "1"
has "dash name: the caller line" "$out" "1: call -dash here"

# --- the eval: a case repo, base-tree paths only, Jira never called ----------------------------------
CR="$tmp/caserepo"
bash "$RUN" --case-repo real-01 --out "$CR" --src "$S" --fixtures "$RL" --key "$RK" >/dev/null 2>&1
rm -f "$tmp/node-called"
out="$(cd "$CR" && PATH="$tmp/failbin:$PATH" bash "$PACK" HEAD~1 HEAD --intent-file "$RL/real-01.intent.md" 2>&1)"
paths="$(printf '%s\n' "$out" | sed -n 's/^{"range": \["\([^"]*\)",.*/\1/p' | sort -u)"
bad=""
for p in $paths; do [ "$p" = INTENT ] || git -C "$CR" cat-file -e "HEAD~1:$p" 2>/dev/null || bad="$bad $p"; done
has "case repo: the caller b.sh is cited" "$paths" "b.sh"
eq "case repo: every cited path is in the base tree" "$bad" ""
eq "case repo: a failing Jira shim is never called" "$([ -e "$tmp/node-called" ] && echo called || echo none)" "none"

# --- run.sh builds the pack per case from the case's own intent note and passes it to the panel ------
cat > "$tmp/stub-panel.sh" <<'EOF'
#!/usr/bin/env bash
ctx=""; id="$(basename "$(pwd)")"
while [ $# -gt 0 ]; do
  case "$1" in
    --context-file) ctx="$2"; shift 2 ;;
    *) echo "stub panel: unknown option $1" >&2; exit 2 ;;
  esac
done
cat > "$STUB_LOG_DIR/$id.stdin"
[ -z "$ctx" ] || cp "$ctx" "$STUB_LOG_DIR/$id.ctx"
printf '%s\n' "$(ls -A | tr '\n' ' ')" > "$STUB_LOG_DIR/$id.cwd"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOF
SL="$tmp/stublog"; mkdir -p "$SL"; rm -f "$tmp/node-called"
PATH="$tmp/failbin:$PATH" HIMMEL_BILLED_OK=1 STUB_LOG_DIR="$SL" REVIEW_PANEL_CMD="$tmp/stub-panel.sh" REVIEW_PANEL_SCRATCH="$tmp/scratch" \
    bash "$RUN" --out "$tmp/sweep" --fixtures "$RL" --key "$RK" --src "$S" --no-ledger --critics codex --only real-01,real-04 >"$tmp/sweep.txt" 2>&1; rc=$?
eq "run.sh: a sweep over cases with a base exits 0" "$rc" "0"
[ "$rc" = 0 ] || cat "$tmp/sweep.txt"
ctx="$(cat "$SL/real-01.ctx" 2>/dev/null)"
has "run.sh: the panel gets the case's own intent note" "$ctx" "DONE-CRITERIA-MARKER-01"
has "run.sh: the panel gets a caller from the base tree" "$ctx" "3: f"
eq "run.sh: the critic's directory holds the diff and the context only" "$(cat "$SL/real-01.cwd" 2>/dev/null)" "context.patch diff.patch "
eq "run.sh: the diff on stdin is unchanged" "$(cmp -s "$SL/real-01.stdin" "$RL/real-01.patch" && echo same)" "same"
eq "run.sh: a case with no intent note gets no context" "$([ -e "$SL/real-04.ctx" ] && echo ctx || echo none)" "none"
eq "run.sh: the eval never calls Jira" "$([ -e "$tmp/node-called" ] && echo called || echo none)" "none"
eq "run.sh: no case repo is left in the scratch" "$(find "$tmp/scratch" -name .git -maxdepth 3 | wc -l | tr -d ' ')" "0"

if [ "$fail" = 0 ]; then echo "test-critic-context-pack: $n checks passed"; else echo "test-critic-context-pack: FAILED ($n checks)"; fi
exit "$fail"
