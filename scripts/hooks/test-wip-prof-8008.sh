#!/usr/bin/env bash
# Temporary line-level timing of the write guard on row 228f of the evaldata suite.
# Dispatched once through macos-cadence, then deleted before the final head.
# Always exits 1 so the runner prints this suite's whole log.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/p8008.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

echo "== env =="
echo "BASH_VERSION=$BASH_VERSION uname=$(uname -sr) arch=$(uname -m) LANG=${LANG:-} LC_ALL=${LC_ALL:-}"

export LC_NUMERIC=C
TIMEFORMAT='%3R'

echo "== micro: one whole-string op on n chars, seconds =="
cat >"$T/mb.sh" <<'EOF'
TIMEFORMAT='%3R'
P=$'\002'
for n in 1000 2000 4000; do
    s=$(printf '%*s' "$n" '' | tr ' ' a)
    v=": $s"
    echo "-- n=$n"
    printf 'A subst [!\\001]      '; time { x="${s//[!$'\001']/}"; }
    printf 'B subst \\003 literal  '; time { x="${s//$'\003'/_}"; }
    printf 'C case *$(*|*`*       '; time { case "$s" in *'$('*|*'`'*) x=1 ;; *) x=0 ;; esac; }
    printf 'D regex is_colon     '; time { [[ $v =~ ^[[:space:]]*:[[:space:]]*$ ]]; }
    printf 'E strip prefix #P    '; time { x="${s#"$P"}"; }
    printf 'F case *\\001* guard   '; time { case "$s" in *$'\001'*) x=1 ;; *) x=0 ;; esac; }
    printf 'G read from procsub  '; time { read -r x < <(printf '%s\n' "$s"); }
    printf 'H length             '; time { x=${#s}; }
    printf 'I glob nonblank      '; time { [[ $s == *[![:space:]]* ]]; }
done
EOF
for loc in default C; do
    echo "-- /bin/bash ($loc)"
    if [ "$loc" = C ]; then LC_ALL=C /bin/bash "$T/mb.sh" 2>&1; else /bin/bash "$T/mb.sh" 2>&1; fi
done

echo "== line-level xtrace, original hook, row 228f, pad=8200, /bin/bash =="
PAD=$(printf '%8200s' '' | tr ' ' a)
jq -n --arg c ": ${PAD}; x=\$(date); echo \"\$x\"" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c,cwd:$d}}' >"$T/p.json"
export PS4='@ $SECONDS $BASH_SUBSHELL ${BASH_SOURCE##*/}:${FUNCNAME[0]:-main}:$LINENO '
{ time /bin/bash -x "$HOOKS/block-write-into-main-checkout.sh" <"$T/p.json" >/dev/null 2>"$T/xt.raw"; } 2>&1
unset PS4
echo "trace lines: $(grep -c '^@' "$T/xt.raw")"
echo "-- cost by location, whole seconds between consecutive trace lines of one subshell level (location: seconds)"
awk '
/^@+ [0-9]+ [0-9]+ [^ ]+ / {
    sec = $2 + 0; lvl = $3; where = lvl " " $4
    if (lvl in ps) {
        d = sec - ps[lvl]
        if (d > 0) {
            cost[pw[lvl]] += d
            if (d >= 2) print "GAP " d "s at " pw[lvl] " :: " pt[lvl]
        }
    }
    ps[lvl] = sec; pw[lvl] = where
    cmd = substr($0, index($0, $4) + length($4) + 1, 110)
    pt[lvl] = cmd
}
END { for (k in cost) printf "%6d  %s\n", cost[k], k }
' "$T/xt.raw" | sort -rn | head -40

echo "WIP profiling suite: failing on purpose so the log is kept"
exit 1
