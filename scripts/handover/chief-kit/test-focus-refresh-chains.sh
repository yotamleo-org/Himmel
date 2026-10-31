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

unset GH_REPO HIMMEL_CONSOLE_DOC HANDOVER_DIR
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
echo '{"nodes":[],"edges":[]}'
EOS
cat >"$tmp/bin/dispo" <<'EOS'
#!/usr/bin/env bash
echo "dispo $*" >> "$FX/log"
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

# --- focus-plan set: the priority line comes from a hand-kept plan, not the registry
reset
printf 'focus-plan: %s/plan.md\n' "$tmp/doc" >> "$DOC"
printf 'priority: 9101 | rest of v1.1.3 | 9999\n' > "$tmp/doc/plan.md"
refresh
contains "a set focus-plan prints WARN priority-source plan-differs" "$(cat "$tmp/err")" "WARN priority-source plan-differs"
reset
refresh
lacks "no focus-plan, no priority-source warning" "$(cat "$tmp/err")" "priority-source"

printf '%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
