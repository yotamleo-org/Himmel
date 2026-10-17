#!/usr/bin/env bash
# bash-ast-replay-bwimc.sh — the engine equivalence tool for
# block-write-into-main-checkout.sh's two engines (BWIMC_ENGINE=regex|ast).
#
#   --sync            rewrite the guard's inlined jq program from
#                     lib/bash-ast.jq + lib/bash-ast-bwimc.jq
#   --check           exit 1 when the inlined copy differs from the lib files
#   --table LOG       summarise a replay log (see below): the agree /
#                     new-denies / new-allows / out-of-scope counts, each
#                     disagreeing row, and p50/p95 latency per engine
#   --corpus FILE     replay a corpus of hook payloads (one JSON object per
#                     line, each with .cwd) through both engines, appending
#                     rows to $BWIMC_REPLAY
#
# A replay log row is tab-separated: suite, label, script kind (direct |
# sourced), regex verdict, ast verdict, regex ms, ast ms, command (escaped).
# lib-test-write-fence.sh's _run writes one per direct-exec call when
# BWIMC_REPLAY names a log, so the fixture corpus replays inside its own
# fixtures; a sourced call has no ast engine and is logged out-of-scope.
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$HOOKS/block-write-into-main-checkout.sh"
BEGIN_MARK='# >>> BEGIN bash-ast (canonical: scripts/hooks/lib/bash-ast.jq + bash-ast-bwimc.jq) >>>'
END_MARK='# <<< END bash-ast <<<'

_block() {
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' "IFS= read -r -d '' _BWIMC_AST_PROG <<'BWIMC_AST_EOF' || true # swallow-ok: read -d '' returns 1 at the heredoc's end"
    cat "$HOOKS/lib/bash-ast.jq"
    sed -e '/^import "bash-ast" as ba;$/d' -e 's/ba:://g' "$HOOKS/lib/bash-ast-bwimc.jq"
    printf '%s\n' "BWIMC_AST_EOF" "$END_MARK"
}

_current() {
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b {on = 1} on {print} $0 == e {on = 0}' "$GUARD"
}

# ms since the epoch
_now() { date +%s%3N; }

# _verdict SCRIPT JSON ENGINE: allow | block | ?(rc=N)
_verdict() {
    local rc
    printf '%s' "$2" | BWIMC_ENGINE="$3" bash "$1" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) echo allow ;; 2) echo block ;; *) echo "?(rc=$rc)" ;; esac
}

# bwimc_replay_row SUITE LABEL SCRIPT JSON: time both engines on one payload
# and append the row to $BWIMC_REPLAY (run in the caller's cwd).
bwimc_replay_row() {
    local suite="$1" label="$2" script="$3" json="$4" kind=direct t0 t1 t2 rv av c
    case "$script" in *block-write-into-main-checkout.sh) ;; *) kind=sourced ;; esac
    c=$(printf '%s' "$json" | jq -r '.tool_input.command // ""' 2>/dev/null | head -c 400 | tr '\t\n' '  ') # swallow-ok: display text for the table only
    t0=$(_now); rv=$(_verdict "$script" "$json" regex); t1=$(_now)
    if [ "$kind" = direct ]; then
        av=$(_verdict "$script" "$json" ast); t2=$(_now)
    else
        av=out-of-scope; t2=$t1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$label" "$kind" "$rv" "$av" $((t1 - t0)) $((t2 - t1)) "$c" >> "$BWIMC_REPLAY"
}

_table() {
    awk -F'\t' '
        function pct(a, n, p,   i, j, t, k) {
            for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
            k = int((n - 1) * p + 0.5) + 1; return a[k]
        }
        {
            if ($3 != "direct" || $5 == "out-of-scope") cls = "out-of-scope"
            else if ($4 == $5) cls = "agree"
            else if ($5 == "block") cls = "new-denies"
            else if ($4 == "block") cls = "new-allows"
            else cls = "other"
            n[cls]++
            if (cls != "agree" && cls != "out-of-scope") rows = rows sprintf("%s\t%s | %s | regex=%s ast=%s | %s\n", cls, $1, $2, $4, $5, $8)
            if ($3 == "direct") { r[++nr] = $6; s[++ns] = $7 }
        }
        END {
            printf "| class | rows |\n|---|---|\n"
            split("agree new-denies new-allows out-of-scope other", o, " ")
            for (i = 1; i <= 5; i++) printf "| %s | %d |\n", o[i], n[o[i]] + 0
            printf "\nlatency per call (ms, direct rows, n=%d): regex p50 %d p95 %d; ast p50 %d p95 %d\n\n", nr, pct(r, nr, 0.5), pct(r, nr, 0.95), pct(s, ns, 0.5), pct(s, ns, 0.95)
            printf "%s", rows
        }' "$1"
}

# sourced by lib-test-write-fence.sh for bwimc_replay_row alone
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
    --sync)
        tmp=$(mktemp "${TMPDIR:-/tmp}/bash-ast-sync.XXXXXX") || exit 1
        _block > "$tmp.b" || exit 1
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$tmp.b" '
            $0 == "#@@BWIMC_AST_PROG@@" || $0 == b { while ((getline l < f) > 0) print l; skip = ($0 == b); next }
            skip { if ($0 == e) skip = 0; next }
            { print }' "$GUARD" > "$tmp" || exit 1
        cat "$tmp" > "$GUARD" || exit 1
        rm -f "$tmp" "$tmp.b" ;;
    --check)
        [ "$(_block)" = "$(_current)" ] || { echo "bash-ast-replay-bwimc: the guard's inlined bash-ast program differs from scripts/hooks/lib — run: bash scripts/hooks/lib/bash-ast-replay-bwimc.sh --sync" >&2; exit 1; } ;;
    --table)
        _table "$2" ;;
    --corpus)
        : "${BWIMC_REPLAY:?set BWIMC_REPLAY to the log to append to}"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            cwd=$(printf '%s' "$line" | jq -r '.cwd // empty')
            [ -d "$cwd" ] || cwd=/
            ( cd "$cwd" && bwimc_replay_row corpus "$(printf '%s' "$line" | jq -r '.label // "-"')" "$GUARD" "$line" )
        done < "$2" ;;
    *) echo "usage: bash-ast-replay-bwimc.sh --sync | --check | --table LOG | --corpus FILE" >&2; exit 64 ;;
esac
