#!/usr/bin/env bash
# Temporary per-function timing of the write guard on row 228f of the evaldata suite.
# Dispatched once through macos-cadence, then deleted before the final head.
# Always exits 1 so the runner prints this suite's whole log.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/p8008.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

echo "== env =="
echo "BASH_VERSION=$BASH_VERSION uname=$(uname -sr) arch=$(uname -m)"
echo "LANG=${LANG:-} LC_ALL=${LC_ALL:-} LC_CTYPE=${LC_CTYPE:-}"
echo "command -v bash: $(command -v bash) -> $(bash --version | head -1)"
echo "/bin/bash: $(/bin/bash --version | head -1)"
echo "locales: $(locale -a 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
echo "nproc: $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null)"

export LC_NUMERIC=C
TIMEFORMAT='%3R'
mkpayload() { # <outfile> <padlen> <cwd>
    local pad cmd
    pad=$(printf '%*s' "$2" '' | tr ' ' a)
    cmd=": ${pad}; x=\$(date); echo \"\$x\""
    jq -n --arg c "$cmd" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c,cwd:$d}}' >"$1"
}

echo "== micro: 3000 reads of one char from an 8200-char string, at index i =="
cat >"$T/mb.sh" <<'EOF'
s=$(printf '%8200s' '' | tr ' ' a)
TIMEFORMAT='%3R'
for i in 0 2000 4000 8000; do
    printf 'idx=%-5s ' "$i"
    time { n=0; while [ "$n" -lt 3000 ]; do c="${s:$i:1}"; n=$((n+1)); done; }
done
printf 'windowed 264 ' ; w="${s:4000:264}"
time { n=0; while [ "$n" -lt 3000 ]; do c="${w:100:1}"; n=$((n+1)); done; }
printf 'empty loop   ' ; time { n=0; while [ "$n" -lt 3000 ]; do n=$((n+1)); done; }
printf 'wrapper-time overhead x3000 '
time { n=0; while [ "$n" -lt 3000 ]; do { time : ; } 2>>/dev/null; n=$((n+1)); done; }
EOF
for b in bash /bin/bash; do
    for loc in default C; do
        echo "-- $b ($loc)"
        if [ "$loc" = C ]; then LC_ALL=C "$b" "$T/mb.sh" 2>&1; else "$b" "$T/mb.sh" 2>&1; fi
    done
done

echo "== row 228f wall seconds by pad length (original hook, direct-exec) =="
HOOK="$HOOKS/block-write-into-main-checkout.sh"
for b in bash /bin/bash; do
    for cwd in /tmp "$REPO"; do
        for pad in 0 2000 4000 8200; do
            mkpayload "$T/p.json" "$pad" "$cwd"
            printf '%-10s cwd=%-28s pad=%-5s secs=' "$b" "$cwd" "$pad"
            { time "$b" "$HOOK" <"$T/p.json" >/dev/null 2>&1; } 2>&1 | tr '\n' ' '
            echo
        done
    done
done

echo "== per-function inclusive time, pad=8200 cwd=$REPO, /bin/bash =="
mkdir -p "$T/inst"
cp -R "$REPO/scripts" "$T/inst/scripts"
NAMES='_bwimc_plain_run|_bwimc_scan_step|_bwimc_split_clauses|_bwimc_subst_split|_bwimc_tokenize|_bwimc_text_untrusted|_bwimc_strip_assign|_bwimc_subst_paren_end|_bwimc_ecwd_track|_bwimc_unqv|_bwimc_redir_scan_text|_bwimc_git_clause|_bwimc_strip_prefix|_bwimc_gm|_bwimc_flat_mask|_bwimc_quote_run|_bwimc_space_before_redirects|_bwimc_simple|_bwimc_fsmut_note|_bwimc_verb_clauses|_bwimc_git_wrapped|_bwimc_drop_quotes|_bwimc_assign_flat|_bwimc_brace_end|_bwimc_arith_end|_bwimc_ambig_check|_bwimc_blank_heredocs|st_tokenize|st_expand|st_lower|_stx_walk|_stx_bodies|_stx_end'
for f in "$T/inst/scripts/hooks/block-write-into-main-checkout.sh" "$T/inst/scripts/hooks/lib/shell-tokenize.sh"; do
    # TIMEFORMAT is read when `time` reports, so a nested wrapper must put the caller's value back
    sed -E "s/^(${NAMES})\(\) \{[[:space:]]*(#.*)?\$/\1() { local __tf=\"\${TIMEFORMAT-}\" __rc=0; { TIMEFORMAT=\"\1 %3R\"; time __o_\1 \"\$@\"; } 2>>\"\${__PROF:-\/dev\/null}\"; __rc=\$?; TIMEFORMAT=\"\$__tf\"; return \$__rc; }; __o_\1() {/" "$f" >"$f.new" && mv "$f.new" "$f"
done
echo "wrapped definitions: $(grep -c '__o_' "$T/inst/scripts/hooks/block-write-into-main-checkout.sh") hook, $(grep -c '__o_' "$T/inst/scripts/hooks/lib/shell-tokenize.sh") lib"
mkpayload "$T/p.json" 8200 "$REPO"
export __PROF="$T/prof.log"
: >"$__PROF"
printf 'plain verdict: '; /bin/bash "$HOOKS/block-write-into-main-checkout.sh" <"$T/p.json" >/dev/null 2>&1; echo "rc=$?"
printf 'instrumented: '; { time /bin/bash "$T/inst/scripts/hooks/block-write-into-main-checkout.sh" <"$T/p.json" >/dev/null 2>&1; echo "rc=$?"; } 2>&1 | tr '\n' ' '
echo
echo "profile lines: $(wc -l <"$__PROF")"
echo "-- incl_s calls max_s function (inclusive, nested calls double-count)"
awk 'NF==2 && $2 ~ /^[0-9]+\.[0-9]+$/ { n[$1]++; s[$1]+=$2; if ($2+0>m[$1]) m[$1]=$2+0 }
     END { for (k in n) printf "%9.3f %6d %7.3f %s\n", s[k], n[k], m[k], k }' "$__PROF" | sort -rn | head -40
echo "-- calls taking 0.5s or more"
awk 'NF==2 && $2+0 >= 0.5 { print }' "$__PROF" | head -40

echo "WIP profiling suite: failing on purpose so the log is kept"
exit 1
