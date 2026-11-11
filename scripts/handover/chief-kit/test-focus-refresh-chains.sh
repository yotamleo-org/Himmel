#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-status-drift.sh
# scripts/handover/chief-kit/test-focus-refresh-chains.sh - the chains stage of focus-refresh.sh:
# every refresh regenerates focus-chains.json from the chain registry, publishes it only on success, and keeps the
# last good file when the registry, the graph or the render fails. The Jira CLI, the sweep, the tracker, the drift
# pass, the graph read and the dispositions read are stubs; the registry reader and chain-render.py are real.
#
# Platform guard: the chief kit is Linux-only; this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FOCUS="$HERE/focus-refresh.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/focus-refresh-chains-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails + 1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails + 1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] has [$3]"; fails=$((fails + 1)) ;; *) echo "ok - $1" ;; esac; }
if ! command -v node >/dev/null 2>&1; then echo "SKIP - test-focus-refresh-chains.sh (node not installed)"; exit 0; fi

unset GH_REPO HIMMEL_CONSOLE_DOC HANDOVER_DIR HIMMEL_CONFIG_DIR
export HOME="$tmp/home"; mkdir -p "$HOME"   # no row reads the operator's own config
export FX="$tmp/fx" TICKET_STATUS_STATE_DIR="$tmp/state" JIRA_PROJECT_KEY=HIMMEL USER_SLUG=fxuser
export HANDOVER_DIR="$tmp/handover"
export FOCUS_REFRESH_BUDGET=60
mkdir -p "$tmp/bin" "$FX" "$tmp/state"

cat >"$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] && echo '[]'
exit 0
EOS
cat >"$tmp/bin/jira" <<'EOS'
#!/usr/bin/env bash
[ "$1" = versions ] && printf 'v1.1.3\tfalse\t-\n'
exit 0
EOS
cat >"$tmp/bin/sweep" <<'EOS'
#!/usr/bin/env bash
echo "status-sweep: keys=2 served=2 moved=0 miss=0 funnel=1 sig=abc wake=1"
EOS
cat >"$tmp/bin/tracker" <<'EOS'
#!/usr/bin/env bash
echo tracker >> "$FX/log"
out=""; chains=""; prev=""
for a in "$@"; do [ "$prev" = --out ] && out="$a"; [ "$prev" = --chains-file ] && chains="$a"; prev="$a"; done
printf 'page\n<meta name="himmel-focus" content="v1.1.3 vfp%s">\n' "$(cat "$FX/vfp" 2>/dev/null)" > "$out"
echo "vfp$(cat "$FX/vfp" 2>/dev/null)" > "$out.vfp"
echo "$chains" > "$FX/tracker-chains-path"
echo "$*" > "$FX/tracker-args"
[ -z "$chains" ] || cp "$chains" "$FX/tracker-chains.json"
EOS
cat >"$tmp/bin/drift" <<'EOS'
#!/usr/bin/env bash
echo "sdrift=0:00000000"
EOS
cat >"$tmp/bin/ksync" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat >"$tmp/bin/graph" <<'EOS'
#!/usr/bin/env bash
echo "graph $*" >> "$FX/log"
[ -e "$FX/graph.fail" ] && { echo "graph: boom" >&2; exit 2; }
[ -e "$FX/graph.bad" ] && { echo 'not json'; exit 0; }
echo '{"nodes":[],"edges":[]}'
EOS
cat >"$tmp/bin/dispo" <<'EOS'
#!/usr/bin/env bash
echo "dispo $*" >> "$FX/log"
[ -e "$FX/dispo.pause" ] && { cat "$FX/dispo.pause"; exit 0; }
printf '# disposition HIMMEL-9101 listed LOCAL\n# disposition HIMMEL-9102 collision scripts/x.sh held by open PR 5\n'
EOS
chmod +x "$tmp"/bin/*
export PATH="$tmp/bin:$PATH"
export FR_JIRA="$tmp/bin/jira" FR_SWEEP="$tmp/bin/sweep" FR_TRACKER="$tmp/bin/tracker" FR_DRIFT="$tmp/bin/drift" FR_KNOWN_SYNC="$tmp/bin/ksync"
export FR_CHAIN_GRAPH="$tmp/bin/graph" FR_DISPOSITIONS="$tmp/bin/dispo"
export TICK_TRACKER_MIRROR_DIR="$tmp/mir/HIMMEL"

DOC="$tmp/doc/chief.md"
REGISTRY="$HANDOVER_DIR/fxuser/himmel/chains.json"
mir() { # <n> <labels json>: an open v1.1.3 ticket
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "To Do"\nlabels: %s\nfixVersions: ["v1.1.3"]\nresolution: null\n---\n\n# HIMMEL-%s: t\n' "$1" "$2" "$1" > "$tmp/mir/HIMMEL/HIMMEL-$1.md"
}
reset() { # fresh doc dir, mirror, registry and logs
    rm -rf "$tmp/doc" "$tmp/mir" "$HANDOVER_DIR" "${FX:?}"/*
    mkdir -p "$tmp/doc" "$tmp/mir/HIMMEL" "$HANDOVER_DIR/fxuser/himmel"
    printf '# chief\n\n## Live state\nfocus-version: v1.1.3\n' > "$DOC"
    mir 9101 '[]'; mir 9102 '[]'; mir 9103 '["standalone"]'
    printf '{"schema":"himmel.chain-registry/1","chains":[{"id":"stage-test","goal":"The stage test chain","members":["HIMMEL-9101"]}]}\n' > "$REGISTRY"
}
refresh() { bash "$FOCUS" --doc "$DOC" --repo example-org/example-repo "$@" >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }
out() { cat "$tmp/out"; }
st() { sed -n "s/^$1=//p" "$tmp/doc/focus-state" | head -n 1; }
CH="$tmp/doc/focus-chains.json"
# drain_of <file>: the drain line of focus-chains.json
drain_of() { python3 -I -c 'import json, sys
print(" ".join(c["drain"] for c in json.load(open(sys.argv[1])) if "drain" in c))' "$1"; }

# --- a valid registry: the file is regenerated, the tracker reads it, the drain line holds the invariant
reset
refresh
check "a refresh with a registry prints ok" "$(out)" "focus=ok"
check "and exits 0" "$(cat "$tmp/rc")" 0
check "focus-chains.json is written beside the chief doc" "$([ -f "$CH" ] && echo yes)" yes
contains "it holds the registry's chain, named by its goal" "$(cat "$CH" 2>/dev/null)" '"name": "The stage test chain"'
check "the graph is read for the registry's members only" "$(grep '^graph' "$FX/log" | head -n 1)" "graph --keys HIMMEL-9101 --json"
check "the tracker read the regenerated file, with its drain row" "$(drain_of "$FX/tracker-chains.json")" \
    "v1.1.3 drain: open 3 · in-chain 1 · standalone 1 · unchained 1 HIMMEL-9102 · dispatchable 1 · dropped {collision 1}"
check "the published file is the one the tracker read" "$(cmp -s "$CH" "$FX/tracker-chains.json" && echo same)" same
contains "the tracker is handed the bucket and the chief doc its Waiting on you reads" "$(cat "$FX/tracker-args")" "--owed-dir $tmp/doc --chief-doc $DOC"
check "the state shows drain-unchained=1" "$(st drain-unchained)" 1
contains "the unchained count is a WARN on stderr" "$(cat "$tmp/err")" "WARN drain-unchained=1"
stage_left=""
for f in "$tmp"/doc/.focus-stage.*; do [ -e "$f" ] && stage_left=yes; done
check "the stage left no staged file behind" "$stage_left" ""

# --- the registry path comes from handover_root, not from the doc dir
reset
mv "$REGISTRY" "$tmp/doc/chains.json"
refresh
check "a registry beside the doc but not in the bucket is not read" "$(out)" "focus=ok"
check "so no focus-chains.json is written" "$([ -e "$CH" ] && echo yes || echo no)" no
graph_calls="$(grep -c '^graph' "$FX/log" 2>/dev/null)"
check "and the graph is not read" "${graph_calls:-0}" 0

# --- no registry at all: the stage is skipped and a hand-kept file stays
reset
rm -f "$REGISTRY"
printf '[{"name":"hand kept","steps":[]}]\n' > "$CH"
cp "$CH" "$tmp/hand.json"
refresh
check "no registry prints ok" "$(out)" "focus=ok"
check "a hand-kept focus-chains.json is left as it is" "$(cmp -s "$CH" "$tmp/hand.json" && echo same)" same

# --- a malformed registry: WARN, the last good file byte-identical, the page still published
reset
refresh
cp "$CH" "$tmp/good.json"
printf '{"schema":"himmel.chain-registry/1","chains":[{"id":"x","goal":"bad","members":["nope"]}]}\n' > "$REGISTRY"
echo 2 > "$FX/vfp"
refresh
contains "a malformed registry prints focus=WARN:chains with the reason" "$(out)" "focus=WARN:chains registry"
check "and exits 0" "$(cat "$tmp/rc")" 0
check "the last good focus-chains.json is byte-identical" "$(cmp -s "$CH" "$tmp/good.json" && echo same)" same
check "the tracker read the last good file" "$(cat "$FX/tracker-chains-path")" "$CH"
check "the page was still published" "$(grep -c 'vfp2' "$tmp/doc/roadmap-tracker.html")" 1
check "the state is ok with the warning recorded" "$(st status):$(st warn)" "ok:chains registry"
refresh --status
contains "--status reports the warning" "$(out)" "focus=WARN:chains registry"

# --- a failing graph read is a WARN too, and the file stays
reset
refresh
cp "$CH" "$tmp/good.json"
touch "$FX/graph.fail"
refresh
contains "a failed graph read prints focus=WARN:chains graph" "$(out)" "focus=WARN:chains graph"
check "and the last good focus-chains.json is byte-identical" "$(cmp -s "$CH" "$tmp/good.json" && echo same)" same
rm -f "$FX/graph.fail"
refresh
check "the next refresh recovers" "$(out)" "focus=ok"
check "and clears the warning" "$(st warn)" ""

# --- a registry with no chains is valid: the old chains go and the drain row stays
reset
refresh
printf '{"schema":"himmel.chain-registry/1","chains":[]}\n' > "$REGISTRY"
refresh
check "an empty registry prints ok" "$(out)" "focus=ok"
check "and the file holds no chain row" "$(python3 -I -c 'import json, sys
print(sum(1 for c in json.load(open(sys.argv[1])) if "steps" in c))' "$CH")" 0
contains "and the drain row stays" "$(drain_of "$CH")" "drain: open 3"

# --- a graph the renderer cannot read is a render WARN, and the file stays
reset
refresh
cp "$CH" "$tmp/good.json"
touch "$FX/graph.bad"
refresh
contains "an unreadable graph prints focus=WARN:chains render" "$(out)" "focus=WARN:chains render"
check "and the last good focus-chains.json is byte-identical" "$(cmp -s "$CH" "$tmp/good.json" && echo same)" same
rm -f "$FX/graph.bad"

# --- (9479 T6) a dispatcher paused on GitHub quota: the dispositions are unknown, so the last good file stays
for pause in '# quota-pause QUOTA-PAUSE github graphql token=main remaining=0 floor=500 reset=unknown caller=next-dispatchable nothing-was-judged' \
    '# gh-stall GH-STALL github read timed out after 400s token=main caller=next-dispatchable nothing-was-judged'; do
    pw="${pause#\# }"; pw="${pw%% *}"
    reset
    refresh
    cp "$CH" "$tmp/good.json"
    printf '%s\n' "$pause" > "$FX/dispo.pause"
    refresh
    check "a paused dispositions read ($pw) still prints ok, no new token" "$(out)" "focus=ok"
    check "and the last good focus-chains.json is byte-identical ($pw)" "$(cmp -s "$CH" "$tmp/good.json" && echo same)" same
    check "the tracker read the last good file ($pw)" "$(cat "$FX/tracker-chains-path")" "$CH"
    contains "stderr names the pause ($pw)" "$(cat "$tmp/err")" "${pause#\# }; focus-chains.json is as it was"
    rm -f "$FX/dispo.pause"
done

# --- focus-plan set: the priority line comes from a hand-kept plan, not the registry
reset
printf 'focus-plan: %s/plan.md\n' "$tmp/doc" >> "$DOC"
printf 'priority: 9101 | rest of v1.1.3 | 9999\n' > "$tmp/doc/plan.md"
refresh
contains "a set focus-plan prints WARN priority-source plan-differs" "$(cat "$tmp/err")" "WARN priority-source plan-differs"
reset
refresh
lacks "no focus-plan, no priority-source warning" "$(cat "$tmp/err")" "priority-source"

# --- a shell with no HANDOVER_DIR still finds the root the repo's .env configures
# A fixture repo (its scripts copied from FR_FIXTURE_SCRIPTS, default this tree) whose .env names a root elsewhere.
SRC="${FR_FIXTURE_SCRIPTS:-$(cd "$HERE/../.." && pwd)}"
FXR="$tmp/fxrepo"; CFG="$tmp/cfgroot"
rm -rf "$FXR" "$CFG" "${tmp:?}/home"
mkdir -p "$tmp/home" "$FXR/scripts/handover" "$FXR/handovers" "$CFG/fxuser/himmel"
git -C "$FXR" init -q -b main
cp -R "$SRC/lib" "$FXR/scripts/lib"; cp -R "$SRC/handover/chief-kit" "$FXR/scripts/handover/chief-kit"
printf 'HANDOVER_DIR=%s\n' "$CFG" > "$FXR/.env"
reset
cp "$REGISTRY" "$CFG/fxuser/himmel/chains.json"
rm -rf "$HANDOVER_DIR"
fx_refresh() { (cd "$FXR" && env -u HANDOVER_DIR HOME="$tmp/home" "$@" bash "$FXR/scripts/handover/chief-kit/focus-refresh.sh" --doc "$DOC" --repo example-org/example-repo >"$tmp/out" 2>"$tmp/err"); }
fx_refresh
check "no HANDOVER_DIR: the refresh prints ok" "$(out)" "focus=ok"
check "no HANDOVER_DIR: focus-chains.json is regenerated from the configured root's registry" "$([ -f "$CH" ] && echo yes)" yes
contains "no HANDOVER_DIR: it holds the registry's chain" "$(cat "$CH" 2>/dev/null)" '"name": "The stage test chain"'
rm -f "$CH"
mkdir -p "$tmp/wrongroot"
fx_refresh HANDOVER_DIR="$tmp/wrongroot"
contains "a wrong root: the skip is a WARN on stdout" "$(out)" "focus=WARN:chains root"
contains "a wrong root: the skip is named on stderr" "$(cat "$tmp/err")" "chains root"
(cd "$FXR" && env -u HANDOVER_DIR -u JUDGE_LADDER_STATE HOME="$tmp/home" JUDGE_LADDER_NOW=1000 bash "$FXR/scripts/handover/chief-kit/judge-ladder.sh" convene seat1 opus >/dev/null 2>&1)
check "no HANDOVER_DIR: the judge ladder is written under the configured root" "$([ -f "$CFG/.judge-ladder" ] && echo yes)" yes
check "no HANDOVER_DIR: nothing is written under the stub folder" "$([ -e "$FXR/handovers/.judge-ladder" ] && echo yes || echo no)" no

# --- run from a linked worktree (no .env of its own), the primary-env lookup leaves no advisory on stderr
PRIM="$tmp/primrepo"; WTR="$tmp/primwt"
rm -rf "$PRIM" "$WTR"
mkdir -p "$PRIM/scripts/handover" "$PRIM/handovers" "$CFG/fxuser/himmel"
git -C "$PRIM" init -q -b main
cp -R "$SRC/lib" "$PRIM/scripts/lib"; cp -R "$SRC/handover/chief-kit" "$PRIM/scripts/handover/chief-kit"
printf 'HANDOVER_DIR=%s\n' "$CFG" > "$PRIM/.env"
printf '.env\n' > "$PRIM/.gitignore"
git -C "$PRIM" add -A
git -C "$PRIM" -c user.email=t@test.local -c user.name=t -c commit.gpgsign=false commit -q -m fixture
git -C "$PRIM" worktree add -q "$WTR" -b wtbranch
reset
cp "$REGISTRY" "$CFG/fxuser/himmel/chains.json"
rm -f "$CFG/.judge-ladder"
frrc=0; (cd "$WTR" && env -u HANDOVER_DIR -u HIMMEL_CONFIG_DIR HOME="$tmp/home" bash "$WTR/scripts/handover/chief-kit/focus-refresh.sh" --doc "$DOC" --repo example-org/example-repo >"$tmp/out" 2>"$tmp/err") || frrc=$?
check "a linked worktree: focus-refresh succeeds with the primary env's root" "$frrc $(out)" "0 focus=ok"
lacks "a linked worktree: focus-refresh prints no load-dotenv advisory" "$(cat "$tmp/err")" "load-dotenv: .env absent under worktree"
jlrc=0; (cd "$WTR" && env -u HANDOVER_DIR -u HIMMEL_CONFIG_DIR -u JUDGE_LADDER_STATE HOME="$tmp/home" JUDGE_LADDER_NOW=1000 bash "$WTR/scripts/handover/chief-kit/judge-ladder.sh" convene seat1 opus >/dev/null 2>"$tmp/err") || jlrc=$?
check "a linked worktree: judge-ladder writes under the primary env's root" "$jlrc $([ -f "$CFG/.judge-ladder" ] && echo yes)" "0 yes"
lacks "a linked worktree: judge-ladder prints no load-dotenv advisory" "$(cat "$tmp/err")" "load-dotenv: .env absent under worktree"

# --- no exit leaves a .focus-stage.* folder in the doc dir (the vault sync stages whatever sits there)
stages_left() { local f n=0; for f in "$tmp"/doc/.focus-stage.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
cat >"$tmp/bin/sweep-fail" <<'EOS'
#!/usr/bin/env bash
prev=""; for a in "$@"; do [ "$prev" = --snapshot-out ] && mkdir -p "$a" && echo '{}' > "$a/graphql.json"; prev="$a"; done
echo "status-sweep: boom" >&2
exit 3
EOS
cat >"$tmp/bin/sweep-hang" <<'EOS'
#!/usr/bin/env bash
trap '' TERM
prev=""; for a in "$@"; do [ "$prev" = --snapshot-out ] && mkdir -p "$a" && echo '{}' > "$a/graphql.json"; prev="$a"; done
sleep 20
EOS
chmod +x "$tmp"/bin/sweep-fail "$tmp"/bin/sweep-hang
reset
FR_SWEEP="$tmp/bin/sweep-fail" refresh
check "a sweep that fails after the stage holds a snapshot ends the run FAILED" "$(out)" "focus=FAILED:sweep:rc3"
check "and no stage folder is left" "$(stages_left)" 0
reset
FR_SWEEP="$tmp/bin/sweep-hang" FOCUS_REFRESH_BUDGET=3 refresh
check "a refresh killed on its budget ends FAILED:timeout" "$(out)" "focus=FAILED:timeout"
check "and no stage folder is left (SIGTERM runs the EXIT trap)" "$(stages_left)" 0
# a run killed outright (SIGKILL, OOM, a closed session) cannot run its trap: the next run sweeps what it left
reset
mkdir -p "$tmp/doc/.focus-stage.dead" "$tmp/doc/.focus-stage.live"
touch -d '2 hours ago' "$tmp/doc/.focus-stage.dead"
refresh
check "a refresh sweeps a stage folder left by a killed run" "$([ -e "$tmp/doc/.focus-stage.dead" ] && echo left || echo gone)" gone
check "and leaves a recent stage folder alone (it may belong to a live run)" "$([ -e "$tmp/doc/.focus-stage.live" ] && echo kept || echo gone)" kept
check "and leaves nothing of its own behind" "$(stages_left)" 1

# --- the drift stage is report-only: its failure is a WARN, the page still publishes
cat >"$tmp/bin/drift-budget" <<'EOS'
#!/usr/bin/env bash
echo "HEALTH - drift: the pass was cut off after 90s | writer=- | fix=bash scripts/handover/chief-kit/status-drift.sh"
echo "sdrift=unknown"
EOS
cat >"$tmp/bin/drift-rc3" <<'EOS'
#!/usr/bin/env bash
echo "boom" >&2
exit 3
EOS
cat >"$tmp/bin/drift-timeout" <<'EOS'
#!/usr/bin/env bash
exit 124
EOS
cat >"$tmp/bin/drift-silent" <<'EOS'
#!/usr/bin/env bash
echo "HEALTH - nothing useful"
EOS
chmod +x "$tmp"/bin/drift-*
drift_case() { # <name> <stub> <warn detail> <sdrift in state>
    reset
    echo "$1" > "$FX/vfp"
    FR_DRIFT="$tmp/bin/$2" refresh
    check "drift $2: the run ends focus=WARN:drift $3" "$(out)" "focus=WARN:drift $3"
    check "drift $2: and exits 0" "$(cat "$tmp/rc")" 0
    check "drift $2: the page was published" "$(grep -c "vfp$1" "$tmp/doc/roadmap-tracker.html" 2>/dev/null)" 1
    check "drift $2: the state is ok with the warning and sdrift recorded" "$(st status):$(st warn):$(st sdrift)" "ok:drift $3:$4"
    refresh --status
    check "drift $2: --status reports the warning, not FAILED" "$(out)" "focus=WARN:drift $3"
}
drift_case d1 drift-budget budget unknown
drift_case d2 drift-rc3 rc3 unknown
drift_case d3 drift-timeout timeout unknown
drift_case d4 drift-silent no-sdrift unknown
reset
FR_DRIFT="$tmp/bin/drift-budget" refresh
check "a drift that reports its own HEALTH row publishes the file" "$(grep -c '^HEALTH - drift:' "$tmp/doc/focus-drift.txt")" 1
FR_DRIFT="$tmp/bin/drift-timeout" refresh
check "a later drift failure with no report leaves the last drift file as it was" "$(grep -c '^HEALTH - drift:' "$tmp/doc/focus-drift.txt")" 1
refresh
check "the next refresh with a working drift pass recovers" "$(out)" "focus=ok"
check "and clears the warning" "$(st warn)" ""

printf '%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
