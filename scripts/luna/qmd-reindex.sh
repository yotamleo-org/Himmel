#!/usr/bin/env bash
# WHY A SECOND `qmd embed` (the completeness assert): `qmd embed` has a session
# cap (--timeout, default 30 minutes). A run that hits the cap exits having
# embedded only PART of the pending set, leaving vectors lagging the lex index.
#   - Checked first, as the ticket asked: qmd 2.6.3 offers NO machine-readable
#     mode to prefer. `--format json` is a SEARCH option; `qmd status --format
#     json` and `qmd collection list --json` are both silently IGNORED and print
#     the same prose.
# COLLECTION SCOPE: all configured collections. Both `qmd update` and `qmd embed`
# default to every collection and take `-c <name>` only to NARROW, so the bare
# calls below are the "everything qmd knows about" scope by construction. That is
set -euo pipefail

QMD_BIN=""
QMD_JS=""
DRY_RUN=0
QMD_INDEX_PATH="${QMD_INDEX_PATH:-$HOME/.cache/qmd/index.sqlite}"
QMD_REFRESH_STAMP="${QMD_REFRESH_STAMP:-$(dirname "$QMD_INDEX_PATH")/refresh-stamp}"

# complete : the no-op pass. Matched as a fixed ASCII substring only — the real
#            line is prefixed with a UTF-8 check mark, and this output is read
#            under the OEM codepage when the cadence fires from cmd.exe.
# did-work : the pass embedded something, i.e. work WAS pending. Regex, because
#            the counts vary.
QMD_SENTINEL_COMPLETE='All content hashes already have embeddings'
QMD_SENTINEL_DID_WORK='Embedded [0-9]+ chunks?'
QMD_SENTINEL_VERIFIED_AGAINST='qmd 2.6.3'

usage() {
    cat <<'EOF'
Usage: qmd-reindex.sh [--qmd-bin PATH] [--qmd-js PATH] [--dry-run]

Refresh the qmd index across ALL configured collections: `qmd update`
(re-index changed files) then `qmd embed` (generate missing vectors),
then assert the embed actually finished.

Flags:
  --qmd-bin <PATH>  Absolute path to the qmd executable (default: resolved via
                    scripts/lib/qmd-bin.sh's preference order). Schedulers fire
                    with a minimal PATH that lacks qmd's bin dir, so the cadence
                    always passes this explicitly.
  --qmd-js <PATH>   Optional absolute script path passed as the first argument
                    to --qmd-bin, making the invocation `<bin> <js> update`.
                    This is how a bun-served qmd is pinned (`bun .../qmd.js`).
                    Requires --qmd-bin.
  --dry-run         Print what would run; execute nothing.

Exit: 0 ok | 1 usage | 2 qmd unusable | 3 update failed | 4 embed failed
      5 embed incomplete (vectors still pending)
      6 completeness assert could not read its verifier (qmd output reworded)
      7 model mismatch (index vectors from another embed model; nothing run)
      8 qmd cleanup failed (vectors complete; orphaned chunks remain)
      9 embed BUSY (another process holds the lock after one retry)
EOF
}

run_qmd() {
    if [ -n "$QMD_JS" ]; then
        qmd_bounded "$(qmd_timeout_secs)" "$QMD_BIN" "$QMD_JS" "$@"
    else
        qmd_bounded "$(qmd_timeout_secs)" "$QMD_BIN" "$@"
    fi
}

# The upstream scan counts hashes, not pending chunks (HIMMEL-4897). Keep the
relabel_hash_count() {
    sed 's/unique hashes need vectors/unique hashes in qmd scan (not a pending chunk count)/g'
}

# qmd can report contention with either exit 0 or nonzero. Check its BUSY
# sentinel before exit status, on BOTH the initial and verification passes.
run_embed() {
    local out rc attempt
    for attempt in 1 2; do
        rc=0
        out=$(run_qmd embed 2>&1) || rc=$?
        if grep -qF -- 'Another embed process is already running' <<<"$out"; then
            if [ "$attempt" -eq 1 ]; then
                echo "qmd-reindex: embed lock held; retrying once" >&2
                continue
            fi
            echo "ERR qmd-reindex: embed BUSY — another embed process is already running after one retry; completeness NOT verified." >&2
            return 9
        fi
        relabel_hash_count <<<"$out"
        [ "$rc" -eq 0 ] || return 4
        return 0
    done
}

qmd_desc() { qmd_bin_desc; }

while [ $# -gt 0 ]; do
    case "$1" in
        --qmd-bin)
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR qmd-reindex: --qmd-bin requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            QMD_BIN="$2"; shift 2 ;;
        --qmd-bin=*)
            QMD_BIN="${1#--qmd-bin=}"
            if [ -z "$QMD_BIN" ]; then
                echo "ERR qmd-reindex: --qmd-bin requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            shift ;;
        --qmd-js)
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR qmd-reindex: --qmd-js requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            QMD_JS="$2"; shift 2 ;;
        --qmd-js=*)
            QMD_JS="${1#--qmd-js=}"
            if [ -z "$QMD_JS" ]; then
                echo "ERR qmd-reindex: --qmd-js requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "ERR qmd-reindex: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -n "$QMD_JS" ] && [ -z "$QMD_BIN" ]; then
    echo "ERR qmd-reindex: --qmd-js requires --qmd-bin (the invocation is '<qmd-bin> <qmd-js> …')" >&2
    usage >&2
    exit 1
fi

# shellcheck source=../lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-bin.sh"

if [ -z "$QMD_BIN" ]; then
    _resolved=""
    if ! _resolved=$(qmd_pinned_invocation 2>/dev/null); then
        {
            echo "ERR qmd-reindex: no usable qmd found and --qmd-bin was not given."
            echo "    Install qmd, or pass the absolute path: --qmd-bin /path/to/qmd"
        } >&2
        exit 2
    fi
    QMD_BIN=$(printf '%s\n' "$_resolved" | sed -n '1p')
    QMD_JS=$(printf '%s\n' "$_resolved" | sed -n '2p')
    unset _resolved
fi

# `command -v` also resolves shell FUNCTIONS and
# ALIASES (to their own name) and relative PATH entries (to a relative path);
# either would be meaningless once a scheduled runner has cd'd elsewhere under a
# different PATH. Windows note: `command -v qmd` yields an extensionless path
# that MSYS resolves to qmd.exe, and -f/-x accept it.
case "$QMD_BIN" in
    /*|[A-Za-z]:[/\\]*) : ;;
    *)
        echo "ERR qmd-reindex: qmd resolved to a non-absolute path ('$QMD_BIN') — a shell function/alias or relative PATH entry cannot be used from a scheduled runner." >&2
        exit 2
        ;;
esac
if [ ! -f "$QMD_BIN" ] || [ ! -x "$QMD_BIN" ]; then
    echo "ERR qmd-reindex: qmd path '$QMD_BIN' is not an executable file." >&2
    exit 2
fi
if [ -n "$QMD_JS" ]; then
    case "$QMD_JS" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *)
            echo "ERR qmd-reindex: --qmd-js is not an absolute path ('$QMD_JS') — it cannot be resolved from a scheduled runner that has cd'd elsewhere." >&2
            exit 2
            ;;
    esac
    if [ ! -f "$QMD_JS" ]; then
        echo "ERR qmd-reindex: --qmd-js path '$QMD_JS' is not a file." >&2
        exit 2
    fi
fi

stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?'; }

write_refresh_stamp() {
    local dir tmp
    dir=$(dirname "$QMD_REFRESH_STAMP")
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "WARN qmd-reindex: could not create $dir for the refresh stamp; qmd-staleness.sh will fall back to its proxy." >&2
        return 0
    fi
    tmp="$QMD_REFRESH_STAMP.tmp.$$"
    if ! printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%s')" >"$tmp" 2>/dev/null; then
        echo "WARN qmd-reindex: could not write the refresh stamp; qmd-staleness.sh will fall back to its proxy." >&2
        rm -f "$tmp" "$QMD_REFRESH_STAMP" 2>/dev/null || true
        return 0
    fi
    if ! mv -f "$tmp" "$QMD_REFRESH_STAMP" 2>/dev/null; then
        echo "WARN qmd-reindex: could not install the refresh stamp; qmd-staleness.sh will fall back to its proxy." >&2
        rm -f "$tmp" "$QMD_REFRESH_STAMP" 2>/dev/null || true
    fi
    return 0
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY qmd-reindex: would run: $(qmd_desc) update"
    echo "DRY qmd-reindex: would run: $(qmd_desc) embed"
    echo "DRY qmd-reindex: would re-run: $(qmd_desc) embed   (completeness assert, one retry if it did work)"
    echo "DRY qmd-reindex: would run: $(qmd_desc) cleanup"
    echo "qmd-reindex: dry-run complete (no changes made)"
    exit 0
fi

echo "qmd-reindex: start $(stamp) (qmd: $(qmd_desc))"

rm -f "$QMD_REFRESH_STAMP" 2>/dev/null || true

model_rc=0
bash "$(dirname "${BASH_SOURCE[0]}")/qmd-embed-model.sh" check --index "$QMD_INDEX_PATH" >&2 || model_rc=$?
case "$model_rc" in
    0) ;;
    3) echo "ERR qmd-reindex: MODEL MISMATCH — index NOT refreshed; see docs/internals/qmd-embed-model.md." >&2
       exit 7 ;;
    *) echo "WARN qmd-reindex: could not verify the index's embed model (rc $model_rc); continuing." >&2 ;;
esac

echo "qmd-reindex: [1/3] qmd update"
if ! run_qmd update 2>&1 | relabel_hash_count; then
    echo "ERR qmd-reindex: 'qmd update' failed — index NOT refreshed." >&2
    exit 3
fi

echo "qmd-reindex: [2/3] qmd embed"
EMBED_RC=0
run_embed || EMBED_RC=$?
if [ "$EMBED_RC" -eq 9 ]; then
    exit 9
elif [ "$EMBED_RC" -ne 0 ]; then
    echo "ERR qmd-reindex: 'qmd embed' failed — lex index is fresh but vectors are NOT." >&2
    exit 4
fi

echo "qmd-reindex: [3/3] verifying embed completeness"
VERIFY_OUT=""
for VERIFY_TRY in 1 2; do
    VERIFY_RC=0
    VERIFY_OUT=$(run_embed 2>&1) || VERIFY_RC=$?
    if [ "$VERIFY_RC" -eq 9 ]; then
        printf '%s\n' "$VERIFY_OUT" >&2
        exit 9
    fi
    if [ "$VERIFY_RC" -ne 0 ]; then
        echo "ERR qmd-reindex: completeness re-check ('qmd embed') failed (rc=$VERIFY_RC):" >&2
        printf '%s\n' "$VERIFY_OUT" >&2
        exit 4
    fi
    if grep -qF -- "$QMD_SENTINEL_COMPLETE" <<<"$VERIFY_OUT" || ! grep -qE -- "$QMD_SENTINEL_DID_WORK" <<<"$VERIFY_OUT"; then
        break
    fi
    [ "$VERIFY_TRY" -eq 1 ] && echo "qmd-reindex: verify pass embedded a tail; re-verifying once"
done
# Match with a HERE-STRING, not `printf … | grep -q`. Under `set -o pipefail`, grep -q
# exits early on a match, printf takes SIGPIPE (141), and pipefail surfaces 141
# as the pipeline status — so a SUCCESSFUL match reads as a failure once the
# output is large enough to not fit the pipe buffer.
if grep -qF -- "$QMD_SENTINEL_COMPLETE" <<<"$VERIFY_OUT"; then
    :
elif grep -qE -- "$QMD_SENTINEL_DID_WORK" <<<"$VERIFY_OUT"; then
    {
        echo "ERR qmd-reindex: embed INCOMPLETE — content hashes still need vectors after the embed pass."
        echo "    Vectors are lagging the lex index, which is the silently-stale state this"
        echo "    runner exists to prevent. Most likely cause: 'qmd embed' hit its session"
        echo "    cap (--timeout, default 30 min). Re-run this script, or embed by hand:"
        echo "        $(qmd_desc) embed --timeout 0"
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 5
else
    {
        echo "ERR qmd-reindex: completeness assert UNRECOGNIZED verifier output — cannot tell complete from incomplete."
        echo "    This is NOT 'the index is stale' — it is 'this script can no longer read qmd'."
        echo "    Neither known sentinel matched:"
        echo "        complete : $QMD_SENTINEL_COMPLETE"
        echo "        did-work : $QMD_SENTINEL_DID_WORK   (regex)"
        echo "    Most likely cause: a qmd release reworded 'qmd embed' output. Verify by hand"
        echo "    (${QMD_SENTINEL_VERIFIED_AGAINST} is the version these were checked against):"
        echo "        $(qmd_desc) embed"
        echo "    then update the sentinels at the top of this script."
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 6
fi

write_refresh_stamp

# `qmd update` cleans orphaned content hashes but not the vectors behind them;
# only `qmd cleanup` does.
echo "qmd-reindex: [4/4] qmd cleanup"
if ! run_qmd cleanup; then
    echo "ERR qmd-reindex: 'qmd cleanup' failed — vectors are complete but orphaned embedding chunks were NOT removed." >&2
    exit 8
fi
echo "qmd-reindex: OK $(stamp) — index refreshed, all content hashes embedded"
