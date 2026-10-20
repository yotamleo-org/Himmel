#!/usr/bin/env bash
# qmd-reindex.sh — deterministic qmd index refresh: `qmd update` then
# `qmd embed`, then a completeness assert.
#
# WHY: the qmd index goes stale SILENTLY. Observed once —
# `qmd status` reported luna lastUpdated 2026-06-22 with needsEmbedding: 0 for
# five days, so notes written 2026-06-27 were simply not searchable, and every
# qmd-backed workflow (compounding, ingest, synthesis, recall) answered off a
# stale index without signalling anything. This script is the RUNNER that fixes
# that; scripts/luna/qmd-cadence.sh is the scheduler that fires it daily.
#
# The split is deliberate and mirrors the graphify precedent:
# refresh-graph-map.sh is the runner, graphmap-cadence.sh the arm layer. Keeping
# them separate is what lets a ship transport invoke the SAME build
# step on demand ("ship after a successful local reindex") without re-entering a
# scheduler.
#
# DESIGN: this is a DETERMINISTIC SCRIPT, not a claude session. `qmd update` and
# `qmd embed` are plain CLI calls, so there is no bounded-session shape here — no
# NUL stdin, no --settings auto-approve fragment, no claude invocation at all.
# Headless-claude billing therefore does not apply: nothing in this
# path shells `claude`, unlike refresh-graph-map.sh whose graphify backend does.
# `qmd embed` uses the machine's CONFIGURED embed model, which may be remote
# (OpenRouter on the station): read it with scripts/luna/qmd-embed-model.sh check;
# egress is governed by the egress matrix.
#
# WHY A SECOND `qmd embed` (the completeness assert): `qmd embed` has a session
# cap (--timeout, default 30 minutes). A run that hits the cap exits having
# embedded only PART of the pending set, leaving vectors lagging the lex index —
# which is the EXACT silently-wrong state this ticket exists to eliminate, just
# with a fresher timestamp on it. So after embedding we call `qmd embed` again:
# when the set is genuinely complete it is a no-op that prints
# "All content hashes already have embeddings" and costs ~1s. A pass that
# reports embedding work means vectors were still pending, and we fail LOUD
# (rc=5) instead of reporting success.
#
# WHY THIS STILL READS A STRING (decision recorded). There
# are two routes: query the index directly (contentvectors / vectorsvec), or
# accept the coupling with a pinned-version note. Taking the second, and the
# reasoning is not "cheaper":
#   - The SQL route swaps coupling to qmd's PUBLIC CLI output for coupling to
#     its PRIVATE schema. A renamed table or a changed vec0 layout is a tighter
#     break, not a looser one, and it breaks with a SQL error or — worse — a
#     silently wrong COUNT, where a reworded CLI line at least still prints.
#   - It puts a DB-driver dependency inside a cadence whose value is being
#     dependency-light. Under node that means better-sqlite3, whose native
#     binding is the exact thing scripts/lib/qmd-bin.sh carries ~60 lines of
#     recovery machinery for; a daily unattended job is the last
#     place that belongs.
#   - Checked first, as the ticket asked: qmd 2.6.3 offers NO machine-readable
#     mode to prefer. `--format json` is a SEARCH option; `qmd status --format
#     json` and `qmd collection list --json` are both silently IGNORED and print
#     the same prose.
# What the ticket is actually right about is the FAILURE MODE, and that is what
# changed: an unrecognized verifier used to report "embed INCOMPLETE" (rc 5) — a
# wrong diagnosis that would fire nightly after any reword and train the
# operator to disarm the cadence. It now reports rc 6, "cannot read the
# verifier", which is true and actionable. Still fail-closed either way.
# If the operator prefers the SQL route, this is the note to overrule.
#
# DAEMON SAFETY: a resident `qmd mcp` daemon (the qmd-mcp-daemon scheduled task,
# plus any MCP client holding the index) may be live while this runs. This runner
# does NOT fence (stop/start) the daemon.
#
# Be precise about the evidence for that, because "verified safe" is a bigger
# claim than what was actually measured. OBSERVED on 2026-07-25: with the daemon
# up (PID 26420 @ localhost:8181), a full `qmd update` + `qmd embed` completed
# without error, and the daemon was still serving on the SAME PID afterwards.
# That is process survival + no error — it is NOT a concurrency proof: nothing
# exercised MCP reads racing these writes, and SQLite-level read consistency
# under concurrent access was not tested. It is enough to justify not fencing by
# default; it is not enough to call the combination proven. If a fence is ever
# needed, it belongs HERE, in the runner — not in the scheduler.
#
# COLLECTION SCOPE: all configured collections. Both `qmd update` and `qmd embed`
# default to every collection and take `-c <name>` only to NARROW, so the bare
# calls below are the "everything qmd knows about" scope by construction. That is
# deliberately not a hardcoded list — a collection added later is picked up with
# no edit here. (Local carries 4 today: himmel, luna, salus, luna-curated.)
#
# CONCURRENCY: no lock. The scheduled task is registered with
# MultipleInstancesPolicy=IgnoreNew, so the cadence cannot overlap ITSELF; an
# on-demand run racing a scheduled one is left to qmd's own SQLite locking, the
# same bet graphmap-cadence makes. Cost basis for why overlap is unlikely: a full
# local refresh measured 2026-07-25 took 16s (update) + 24s (embed, 457 chunks /
# 81 docs) — a daily run has ~24h of headroom.
#
# Usage:
#   bash scripts/luna/qmd-reindex.sh [--qmd-bin PATH] [--qmd-js PATH] [--dry-run]
#
#   --qmd-bin PATH   Absolute path to the qmd EXECUTABLE. Default: resolved via
#                    scripts/lib/qmd-bin.sh's preference order,
#                    NOT a bare `command -v qmd`. The cadence passes this
#                    explicitly, because schtasks and cron fire with a MINIMAL
#                    PATH that does not carry the bun bin dir where qmd installs.
#   --qmd-js PATH    Optional absolute script path passed as the first argument
#                    to --qmd-bin, i.e. the invocation becomes
#                    `<qmd-bin> <qmd-js> update` instead of `<qmd-bin> update`.
#                    This is how the bun-served install is pinned: qmd's
#                    canonical invocation there is `bun <.../dist/cli/qmd.js>`,
#                    two tokens, and neither is a `qmd` executable. Requires
#                    --qmd-bin.
#   --dry-run        Print the two commands that would run, execute neither.
#
# On verified success (see the completeness assert below) this
# writes a refresh stamp to QMD_REFRESH_STAMP (default: alongside
# QMD_INDEX_PATH, default $HOME/.cache/qmd/index.sqlite) that qmd-staleness.sh
# prefers over its MAX(mtime) proxy. Never written on any failure path.
#
# Exit codes:
#   0  index refreshed and verified complete
#   1  usage / input error
#   2  qmd executable not found or not usable
#   3  `qmd update` failed (a SQLITE_BUSY lock is retried first, up to
#      QMD_REINDEX_BUSY_WAIT_SECS=180 at QMD_REINDEX_BUSY_RETRY_SECS=10)
#   4  `qmd embed` failed
#   5  embed INCOMPLETE — vectors still pending after the embed pass
#   6  completeness assert could not READ its verifier (qmd reworded its
#      output) — distinct from 5 on purpose; see the sentinel note below
#   7  MODEL MISMATCH — the index holds vectors from an embed model other
#      than the configured one; nothing was run
#   8  `qmd cleanup` failed — vectors ARE complete and the
#      refresh stamp is written; only the orphaned chunks remain
#  10  EGRESS REFUSED — a remote (openai:) model is configured and the egress
#      gate (scripts/qmd/qmd-jina-gate.mjs) denies a collection the config or
#      the index database holds, or an OpenRouter config has no provider key
#      in the daemon env file (absent or empty), or that file is readable by
#      others; nothing was run
#   9  BUSY — another embed process holds the lock after one retry;
#      completeness is not verified and no refresh stamp is written
set -euo pipefail

QMD_BIN=""
QMD_JS=""
DRY_RUN=0
NO_CLEANUP=0
# A durable timestamp written ONLY on the verified-success path
# below, next to the index data qmd-staleness.sh already reads.
QMD_INDEX_PATH="${QMD_INDEX_PATH:-${INDEX_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/index.sqlite}}"
# qmd opens INDEX_PATH, so the egress gate and qmd must read the same file.
export INDEX_PATH="$QMD_INDEX_PATH"
QMD_REFRESH_STAMP="${QMD_REFRESH_STAMP:-$(dirname "$QMD_INDEX_PATH")/refresh-stamp}"

# --- completeness-assert sentinels -----------------------------
#
# The assert reads `qmd embed` output. That is coupling to a human-readable
# string, and the decision NOT to replace it with a SQL check is deliberate —
# see the header note. What this pins down is the failure mode: keep the
# sentinels NAMED, in one place, with the version they were verified against,
# and recognise BOTH outcomes rather than treating "not complete" as
# "incomplete". A reword then reports itself instead of impersonating a stale
# index.
#
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
  --no-cleanup      Incremental run: skip the final `qmd cleanup` (the 2-hourly
                    cadence; the nightly full run keeps it).
  --dry-run         Print what would run; execute nothing.

Exit: 0 ok | 1 usage | 2 qmd unusable | 3 update failed | 4 embed failed
      5 embed incomplete (vectors still pending)
      6 completeness assert could not read its verifier (qmd output reworded)
      7 model mismatch (index vectors from another embed model; nothing run)
      8 qmd cleanup failed (vectors complete; orphaned chunks remain)
      9 embed BUSY (another process holds the lock after one retry)
EOF
}

# Invoke the resolved qmd. Two tokens when --qmd-js is in play (`bun <js> …`),
# one otherwise — each quoted separately so a space in either path (a Windows
# certainty) cannot split it. Group-bounded by qmd_bounded, from
# qmd-bin.sh; an embed cut short resumes on the next fire.
run_qmd() {
    if [ -n "$QMD_JS" ]; then
        qmd_bounded "$(qmd_timeout_secs)" "$QMD_BIN" "$QMD_JS" "$@"
    else
        qmd_bounded "$(qmd_timeout_secs)" "$QMD_BIN" "$@"
    fi
}

# The upstream scan counts hashes, not pending chunks. Keep the
# diagnostic number, but never present it as an embedding backlog.
relabel_hash_count() {
    sed 's/unique hashes need vectors/unique hashes in qmd scan (not a pending chunk count)/g'
}

# qmd can report contention with either exit 0 or nonzero. Check its BUSY
# sentinel before exit status, on BOTH the initial and verification passes.
# Retry once immediately: no scheduler delay or unbounded wait for another job.
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
        # Normalize ordinary failures so an upstream rc 9 cannot impersonate BUSY.
        [ "$rc" -eq 0 ] || return 4
        return 0
    done
}

# "pids: <pid> (<command>), ..." for a space-separated pid list: a bare pid is
# gone by the time anyone reads the cron log, which is the only evidence kept.
name_holders() {
    local pid cmd out=""
    for pid in $1; do
        cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-100 || true)
        out="${out:+$out, }$pid (${cmd:-gone})"
    done
    printf 'pids: %s' "$out"
}

# Best-effort: who has the index (or its WAL side files) open right now, for
# the busy log lines.
index_holders() {
    local h=""
    if command -v fuser >/dev/null 2>&1; then
        h=$(fuser "$QMD_INDEX_PATH" "$QMD_INDEX_PATH-wal" "$QMD_INDEX_PATH-shm" 2>/dev/null | tr -s ' \n' ' ' || true)
        h="${h# }"; h="${h% }"
        [ -z "$h" ] || { name_holders "$h"; return 0; }
    fi
    if command -v lsof >/dev/null 2>&1; then
        h=$(lsof -t -- "$QMD_INDEX_PATH" "$QMD_INDEX_PATH-wal" "$QMD_INDEX_PATH-shm" 2>/dev/null | sort -u | tr -s ' \n' ' ' || true)
        h="${h# }"; h="${h% }"
        [ -z "$h" ] || { name_holders "$h"; return 0; }
    fi
    printf 'unknown'
}

# A non-negative decimal integer of at most 9 digits, else the default (a bad
# env value must not turn the bounded wait into an endless loop, and a digit
# string past 64-bit range must not wrap to 0).
secs_or_default() {
    case "$1" in
        ''|*[!0-9]*|??????????*)
            [ -z "$1" ] || echo "WARN qmd-reindex: ignoring invalid seconds value '$1'; using $2." >&2
            printf '%s' "$2" ;;
        *) printf '%s' "$((10#$1))" ;;
    esac
}

# `qmd update` dies with SQLITE_BUSY ("database is locked") while another writer
# (an MCP daemon, a capture, a second cadence) holds the index write lock. Wait
# it out: retry on that signature only, every QMD_REINDEX_BUSY_RETRY_SECS up to
# QMD_REINDEX_BUSY_WAIT_SECS in total. Any other failure, and a lock held past
# the bound, return nonzero at once so the caller still exits 3.
run_update() {
    local wait_max step waited out rc nap t0="$SECONDS"
    wait_max=$(secs_or_default "${QMD_REINDEX_BUSY_WAIT_SECS:-}" 180)
    step=$(secs_or_default "${QMD_REINDEX_BUSY_RETRY_SECS:-}" 10)
    while :; do
        rc=0
        out=$(run_qmd update 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
            relabel_hash_count <<<"$out"
            return 0
        fi
        relabel_hash_count <<<"$out" >&2
        if ! grep -qE -- 'SQLITE_BUSY|database is locked' <<<"$out"; then
            return "$rc"
        fi
        waited=$((SECONDS - t0))
        if [ "$waited" -ge "$wait_max" ]; then
            echo "ERR qmd-reindex: index still busy after ${waited}s (SQLITE_BUSY); lock holder: $(index_holders)" >&2
            return "$rc"
        fi
        nap="$step"
        [ "$nap" -le $((wait_max - waited)) ] || nap=$((wait_max - waited))
        echo "qmd-reindex: index busy (SQLITE_BUSY; holder: $(index_holders)); retrying in ${nap}s (waited ${waited}s of ${wait_max}s)" >&2
        sleep "$nap"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --qmd-bin)
            # Demand a real operand. Without this, a trailing `--qmd-bin` makes
            # `shift 2` fail under set -e and the script dies with no message,
            # and `--qmd-bin --dry-run` silently swallows the next FLAG as the
            # path (surfacing later as a confusing "not an executable file").
            # An EXPLICITLY EMPTY operand is rejected too: `--qmd-bin ""` would
            # otherwise leave QMD_BIN empty and fall through to PATH resolution,
            # silently ignoring the flag the caller deliberately passed.
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
            # Same operand discipline as --qmd-bin above: reject a missing,
            # empty, or flag-shaped operand rather than swallowing the next arg.
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
        --no-cleanup) NO_CLEANUP=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "ERR qmd-reindex: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --qmd-js is meaningless without an executable to pass it to: on its own it
# would be silently ignored while the caller believes they pinned the bun-served
# install. Reject it explicitly.
if [ -n "$QMD_JS" ] && [ -z "$QMD_BIN" ]; then
    echo "ERR qmd-reindex: --qmd-js requires --qmd-bin (the invocation is '<qmd-bin> <qmd-js> …')" >&2
    usage >&2
    exit 1
fi

# Resolve qmd. An explicit --qmd-bin wins; otherwise fall back to the SHARED
# resolver's preference order, NOT a bare `command -v qmd`. The
# bare lookup finds the broken Claude-plugin stub that shadows the bun shim on
# Git Bash $PATH inside a Claude Code session — the exact context an operator
# runs this from by hand — and that stub dies with "Module not found …
# dist/cli/qmd.js". qmd_pinned_invocation prefers the bun-served install the
# same way qmd_cmd does, and returns absolute tokens.
# Sourced unconditionally: qmd_bin_desc runs on every path, including `--qmd-bin`.
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

# Demand a real, absolute, executable file — the same discipline graphmap-cadence
# applies to the `claude` it pins. `command -v` also resolves shell FUNCTIONS and
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
# The script arg gets the same absolute + real-file discipline. It is NOT
# required to be executable — it is a .js handed to an interpreter, not run
# directly.
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

# Durable refresh timestamp, written ONLY from the verified-success
# path below. Best-effort and non-fatal on purpose — a stamp-write failure means
# qmd-staleness.sh falls back to its existing proxy, not that a genuinely
# complete reindex should now report failure over a side-channel write.
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
    echo "DRY qmd-reindex: would run: $(qmd_bin_desc) update"
    echo "DRY qmd-reindex: would run: $(qmd_bin_desc) embed"
    echo "DRY qmd-reindex: would re-run: $(qmd_bin_desc) embed   (completeness assert, one retry if it did work)"
    [ "$NO_CLEANUP" -eq 1 ] || echo "DRY qmd-reindex: would run: $(qmd_bin_desc) cleanup"
    echo "qmd-reindex: dry-run complete (no changes made)"
    exit 0
fi

echo "qmd-reindex: start $(stamp) (qmd: $(qmd_bin_desc))"

# Invalidate any stamp from an earlier run BEFORE mutating the index:
# 'qmd update' below can re-index files even if this run later fails
# the embed or completeness steps, so a stamp certifying an EARLIER verified-complete
# state must not survive to be read as this run's freshness. write_refresh_stamp()
# re-installs it only once this run itself reaches verified-complete.
rm -f "$QMD_REFRESH_STAMP" 2>/dev/null || true

# --- 0. embed-model precheck ------------------------------------
# An embed pass with a configured model other than the index's would fail on a
# dimension change, or on the same dimension silently mix two vector spaces.
# Refuse BEFORE touching the index; an unreadable index only WARNs.
model_rc=0
bash "$(dirname "${BASH_SOURCE[0]}")/qmd-embed-model.sh" check --index "$QMD_INDEX_PATH" >&2 || model_rc=$?
case "$model_rc" in
    0) ;;
    3) echo "ERR qmd-reindex: MODEL MISMATCH — index NOT refreshed; see docs/internals/qmd-embed-model.md." >&2
       exit 7 ;;
    *) echo "WARN qmd-reindex: could not verify the index's embed model (rc $model_rc); continuing." >&2 ;;
esac

# --- 0b. egress gate ---------------------------------------------------------
# A bare `qmd embed` embeds every ACTIVE document in the database with the
# configured model. When that model is remote, every collection the config or
# the database holds must pass the egress matrix, or nothing runs.
QMD_CFG_FILE="${QMD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd}/index.yml"
remote_model=0
case "${QMD_EMBED_MODEL:-}${QMD_RERANK_MODEL:-}${QMD_GENERATE_MODEL:-}" in *openai:*) remote_model=1 ;; esac
if [ "$remote_model" -eq 0 ] && grep -Eqs '^[^#]*(openai:|\\)' "$QMD_CFG_FILE"; then remote_model=1; fi
if [ "$remote_model" -eq 1 ]; then
    GATE_JS="$(dirname "${BASH_SOURCE[0]}")/../qmd/qmd-jina-gate.mjs"
    if [ ! -f "$GATE_JS" ] || ! command -v node >/dev/null 2>&1; then
        echo "ERR qmd-reindex: a remote model is configured but the egress gate or node is missing — index NOT refreshed." >&2
        exit 10
    fi
    # The provider key is the daemon's, never a session's (scripts/lib/qmd-daemon-env.sh).
    # shellcheck source=../lib/qmd-daemon-env.sh
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-daemon-env.sh"  # t13b-ok: sources the key loader, starts nothing
    key_rc=0
    qmd_daemon_key_load "$QMD_CFG_FILE" || key_rc=$?  # t13b-ok: calls the key loader, starts nothing
    if [ "$key_rc" -eq 10 ]; then
        echo "ERR qmd-reindex: $QMD_KEY_FILE_PATH holds the provider key but is readable by others - index NOT refreshed (chmod 600 it)." >&2
        exit 10
    fi
    if [ "$key_rc" -eq 11 ]; then
        echo "ERR qmd-reindex: a remote model is configured but no provider key was found - index NOT refreshed." >&2
        echo "    Put a QMD_OPENAI_API_KEY=... line (mode 0600) in $QMD_KEY_FILE_PATH." >&2
        exit 10
    fi
    if ! node "$GATE_JS" "$QMD_CFG_FILE" "$QMD_INDEX_PATH" >&2; then
        echo "ERR qmd-reindex: EGRESS REFUSED — index NOT refreshed; see docs/internals/egress-matrix.md." >&2
        exit 10
    fi
fi

# --- 1. re-index changed files across every configured collection -----------
echo "qmd-reindex: [1/3] qmd update"
if ! run_update; then
    echo "ERR qmd-reindex: 'qmd update' failed — index NOT refreshed." >&2
    exit 3
fi

# --- 2. embed whatever the update left without vectors ----------------------
echo "qmd-reindex: [2/3] qmd embed"
EMBED_RC=0
run_embed || EMBED_RC=$?
if [ "$EMBED_RC" -eq 9 ]; then
    exit 9
elif [ "$EMBED_RC" -ne 0 ]; then
    echo "ERR qmd-reindex: 'qmd embed' failed — lex index is fresh but vectors are NOT." >&2
    exit 4
fi

# --- 3. completeness assert (see the header for why this is not optional) ---
# A no-op embed prints "All content hashes already have embeddings". Match the
# ASCII substring only: the real line is prefixed with a UTF-8 check mark, and
# this output is read under the OEM codepage when the cadence fires from cmd.exe.
echo "qmd-reindex: [3/3] verifying embed completeness"
# The first pass can leave a 1-2 document tail that the verify
# pass then embeds (observed with the daemon down, so not a concurrent writer);
# the nightly run exited 5 and nothing retried it until the next day. Retry the
# verify ONCE when it did work; a second did-work is still rc 5 below. Bounded
# on purpose: never an unbounded loop, never success with vectors pending.
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
# Match with a HERE-STRING, not `printf … | grep -q` (same class
# already fixed in check-security-reviewed.sh). Under `set -o pipefail`, grep -q
# exits early on a match, printf takes SIGPIPE (141), and pipefail surfaces 141
# as the pipeline status — so a SUCCESSFUL match reads as a failure once the
# output is large enough to not fit the pipe buffer. Here that inversion would
# report "embed INCOMPLETE" (rc=5) on a fully COMPLETE embed: a loud false alarm
# in the exact check that exists to prevent silent wrongness.
if grep -qF -- "$QMD_SENTINEL_COMPLETE" <<<"$VERIFY_OUT"; then
    :   # complete — fall through to the success line below
elif grep -qE -- "$QMD_SENTINEL_DID_WORK" <<<"$VERIFY_OUT"; then
    # POSITIVE evidence of incompleteness: the verify pass found work left to
    # do, so vectors really are lagging the lex index.
    {
        echo "ERR qmd-reindex: embed INCOMPLETE — content hashes still need vectors after the embed pass."
        echo "    Vectors are lagging the lex index, which is the silently-stale state this"
        echo "    runner exists to prevent. Most likely cause: 'qmd embed' hit its session"
        echo "    cap (--timeout, default 30 min). Re-run this script, or embed by hand:"
        echo "        $(qmd_bin_desc) embed --timeout 0"
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 5
else
    # NEITHER sentinel matched. Do not guess. Treating an
    # unrecognized verifier as "INCOMPLETE" (rc 5) would mean that the day qmd rewords
    # its output, a fully COMPLETE index reports a loud daily failure with a
    # diagnosis that is simply WRONG, and the operator's rational response to a
    # cadence that cries wolf every night is to disarm it, re-opening the very
    # staleness hole the cadence closed. Report what actually happened instead:
    # the assert can no longer read its verifier. Still FAIL-CLOSED (nonzero,
    # nothing is called complete) — the fix is to make the wrong answer
    # distinguishable from the right one, not to start trusting it.
    {
        echo "ERR qmd-reindex: completeness assert UNRECOGNIZED verifier output — cannot tell complete from incomplete."
        echo "    This is NOT 'the index is stale' — it is 'this script can no longer read qmd'."
        echo "    Neither known sentinel matched:"
        echo "        complete : $QMD_SENTINEL_COMPLETE"
        echo "        did-work : $QMD_SENTINEL_DID_WORK   (regex)"
        echo "    Most likely cause: a qmd release reworded 'qmd embed' output. Verify by hand"
        echo "    (${QMD_SENTINEL_VERIFIED_AGAINST} is the version these were checked against):"
        echo "        $(qmd_bin_desc) embed"
        echo "    then update the sentinels at the top of this script."
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 6
fi

# --- 4. stamp, then drop orphaned embedding chunks -----------
# `qmd update` cleans orphaned content hashes but not the vectors behind them;
# only `qmd cleanup` does. The stamp is written first so a cleanup failure (rc 8,
# its own code, never read as an embed problem) cannot make a complete index
# read as stale.
stamp_then_cleanup() {
    write_refresh_stamp
    echo "qmd-reindex: [4/4] qmd cleanup"
    if ! run_qmd cleanup; then
        echo "ERR qmd-reindex: 'qmd cleanup' failed — vectors are complete but orphaned embedding chunks were NOT removed." >&2
        exit 8
    fi
}
if [ "$NO_CLEANUP" -eq 1 ]; then write_refresh_stamp; else stamp_then_cleanup; fi
echo "qmd-reindex: OK $(stamp) — index refreshed, all content hashes embedded"
