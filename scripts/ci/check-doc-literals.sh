#!/usr/bin/env bash
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+.
#
# check-doc-literals.sh [--root DIR] [--warn] | --list-accept
#
# A doc that shows a command must show one the command accepts.
# For each CLI in the accept table below, every `--flag` on a documented
# invocation (and every `--role` value) must be in that CLI's declared accept
# list. This is the gap PR 4288 opened: docs/himmel-bus.md named
# `--role worker|chief` and `--chief` while the bus parser took
# `leg|console` and `--console`.
#
# Scanned (tracked files under --root, default the repo): docs/**/*.md,
# marketplace/**/SKILL.md, .claude/commands/*.md. The worker preface and
# docs/handover/** sit under docs/. Skipped: docs/migration/ and docs/release/
# (history records), and any line carrying `old-term-ok` (a line that shows a
# refusal on purpose).
#
# A documented invocation runs from the CLI name to the first ` | `, `&&`, `||`,
# `;` or backtick on the line (a `\|` inside a table cell is not a separator).
# A flag is `--name` after whitespace, `[` or `(`; `--name=value` counts as
# `--name`; a `--role` value is the next word, split on `|`, and `<placeholder>`
# values are skipped.
#
# The accept table is the one line per CLI: name, source, command ERE, accepted
# flags, accepted --role values, flags the parser refuses on purpose. A `-`
# is an empty list. scripts/ci/test-check-doc-literals.sh pins every row to the
# CLI's own source, so editing a parser without its row fails that test; a
# rename batch that changes a parser edits its row here in the same PR
# (docs/internals/rename-procedure.md).
#
# ponytail: a declared list drifts from the parser when the test is skipped or
# a parser style the test cannot read is added, upgrade path: generate the
# list from the parser's option table.
#
# Exit: 0 clean (or --warn); 1 a doc literal the CLI refuses; 2 usage or git
# failure.
set -uo pipefail

accept_table() {
    local t="	"
    local bt='`'
    # `bus <verb>`, or a table cell opening with a verb only the bus has (adopt, status, send ... also name other tools' verbs)
    local cmd_bus="(((^|[^A-Za-z0-9_-])bus )(register|bind|rebind|adopt|succeed|status|peers|send|wait|unread|gc)|$bt(register|bind|rebind|succeed|unread))([^A-Za-z0-9_.-]|\$)"
    # name | source | command ERE | accepted flags | accepted roles | refused flags
    printf '%s\n' \
        "bus${t}marketplace/plugins/himmel-bus/bin/bus${t}${cmd_bus}${t}--role --console --pair --predecessor --re --summary --doc --for --timeout --unacked${t}leg console judge consult${t}-" \
        "tick.sh${t}scripts/handover/chief-kit/tick.sh${t}(^|[^A-Za-z0-9_-])tick\\.sh${t}--burn --doc --emit-fp --handover-dir --help --pool-dispositions --pool-stale --ready-dir --ready-mismatch --repo --token --verbose --workers --workers-from${t}-${t}-" \
        "board.mjs${t}scripts/handover/chief-kit/board.mjs${t}(^|[^A-Za-z0-9_-])board\\.mjs${t}--changed --doc --json --out --repo --view --workers${t}-${t}-" \
        "chief.sh${t}scripts/handover/chief/chief.sh${t}(^|[^A-Za-z0-9_-])chief\\.sh${t}--arm --bucket --context --date --deadline-min --doc --dry-run --help --model --name --no-relay-on-live --prefix --project --relay-on-live${t}-${t}-" \
        "headed-arm-worker.sh${t}scripts/handover/chief-kit/headed-arm-worker.sh${t}(^|[^A-Za-z0-9_-])headed-arm-worker\\.sh${t}--chief --consult --context-guard --dry-run --fleet --headless --ignore-denials --judge --lane --no-prior-art-check --no-profile --profile --relay --rm-release${t}-${t}--console" \
        "gen-briefs${t}scripts/handover/chief-kit/gen-briefs.py${t}(^|[^A-Za-z0-9_-])gen-briefs(\\.py)?([^A-Za-z0-9_-]|\$)${t}--also-live --base --bucket --chief --date --deadline --handover-root --help --letter --manifest --no-worktree --repo --work-dir${t}-${t}-" \
        "append-results.sh${t}scripts/handover/chief-kit/append-results.sh${t}(^|[^A-Za-z0-9_-])append-results\\.sh${t}-${t}-${t}-"
}

root=""
warn=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list-accept) accept_table; exit 0 ;;
        --root) [ $# -ge 2 ] || { echo "check-doc-literals: --root needs a directory" >&2; exit 2; }; root="$2"; shift 2 ;;
        --warn) warn=1; shift ;;
        *) echo "check-doc-literals: unknown option $1" >&2; exit 2 ;;
    esac
done
if [ -z "$root" ]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-doc-literals: not in a git work tree" >&2; exit 2; } # swallow-ok: the failure is reported and exits 2 right here
fi
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "check-doc-literals: $root is not a git work tree" >&2; exit 2; }

table="$(accept_table)"

rc=0
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose
git -C "$root" -c core.quotePath=false ls-files -z -- 'docs/*.md' ':(glob)marketplace/**/SKILL.md' '.claude/commands/*.md' \
    | { while IFS= read -r -d '' f; do
            case "$f" in docs/migration/*|docs/release/*) continue ;; esac
            [ -f "$root/$f" ] && printf '%s\0' "$f"
        done; } \
    | (cd "$root" && ACCEPT_TABLE="$table" xargs -0 awk '
BEGIN {
    # ENVIRON, not -v: -v would rewrite the backslashes in the command EREs
    n = split(ENVIRON["ACCEPT_TABLE"], rows, "\n")
    for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, "\t")
        k++; name[k] = f[1]; cre[k] = f[3]
        nf = split(f[4], fl, " "); for (j = 1; j <= nf; j++) if (fl[j] != "-") okflag[k, fl[j]] = 1
        nr = split(f[5], rl, " "); hasroles[k] = 0
        for (j = 1; j <= nr; j++) if (rl[j] != "-") { okrole[k, rl[j]] = 1; hasroles[k] = 1 }
        nx = split(f[6], xl, " "); for (j = 1; j <= nx; j++) if (xl[j] != "-") refused[k, xl[j]] = 1
    }
    ncli = k
}
index($0, "old-term-ok") > 0 { next }
{
    line = $0
    gsub(/\\\|/, "\001", line)
    for (c = 1; c <= ncli; c++) {
        rest = line
        # every occurrence of the command on the line starts its own invocation
        while (match(rest, cre[c])) {
            after = substr(rest, RSTART + RLENGTH)
            rest = after
            seg = after
            if (match(seg, / \| |&&|\|\||;|`/)) seg = substr(seg, 1, RSTART - 1)
            scan(c, seg)
        }
    }
}
function scan(c, seg,   t, flag, val, vals, nv, v, pre) {
    t = " " seg
    while (match(t, /[ \[(]--[A-Za-z][A-Za-z0-9-]*/)) {
        flag = substr(t, RSTART + 1, RLENGTH - 1)
        t = substr(t, RSTART + RLENGTH)
        if (!((c, flag) in okflag)) {
            printf "%s:%d: %s does not accept %s%s\n", FILENAME, FNR, name[c], flag, (((c, flag) in refused) ? " (refused on purpose)" : "")
            bad++
            continue
        }
        if (flag == "--role" && hasroles[c] && match(t, /^[ ]+[^ ]+/)) {
            val = substr(t, RSTART, RLENGTH); sub(/^[ ]+/, "", val)
            gsub(/\001/, "|", val)
            sub(/[]`,.)].*$/, "", val)
            if (val ~ /^</ || val == "") continue
            nv = split(val, vals, "|")
            for (v = 1; v <= nv; v++) {
                if (vals[v] == "") continue
                if (!((c, vals[v]) in okrole)) {
                    printf "%s:%d: %s does not accept role '"'"'%s'"'"' for --role\n", FILENAME, FNR, name[c], vals[v]
                    bad++
                }
            }
        }
    }
}
END { if (bad) exit 1 }') || rc=$?

# xargs reports an awk that exited 1-125 (a finding) as 123.
[ "$rc" -eq 123 ] && rc=1
case "$rc" in
    0) exit 0 ;;
    1)
        if [ "$warn" -eq 1 ]; then
            echo "check-doc-literals: doc literal(s) the CLI refuses (report mode, not failing). Fix the doc or the accept row; see docs/internals/rename-procedure.md." >&2
            exit 0
        fi
        echo "check-doc-literals: doc literal(s) the CLI refuses. Fix the doc, or update the accept row in this script with the parser; see docs/internals/rename-procedure.md." >&2
        exit 1
        ;;
    *) echo "check-doc-literals: scan failed (rc=$rc)" >&2; exit 2 ;;
esac
