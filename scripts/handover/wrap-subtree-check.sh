#!/usr/bin/env bash
# wrap-subtree-check.sh — the structural wrap/halt gate.
#
# A leg (or judge) that declares itself closable must first prove its own
# process subtree is empty. TaskStop on an agent does NOT reap the background
# shell that agent spawned (fleet halt 2026-09-07: leg N35 reported WRAPPED with
# a poll loop still alive 2h10m later), and the console cannot kill it — so the
# closable-window banner is this script's output, never hand-typed:
#   CLOSABLE: no non-harness process under claude pid <pid>     rc 0
#     [ (<n> harness-owned children ignored) + one `ignored pid=…` row each ]
#   WITHHELD: <n> process(es) still alive under claude pid <pid>   rc 1
#     pid=<pid> ppid=<ppid> etime=<etime> cmd=<first 100 chars of argv>
#   WITHHELD: cannot …                                             rc 2
# rc 2 is fail-CLOSED: an unreadable process table, or no claude session to
# anchor on, never prints CLOSABLE. On WITHHELD, TaskStop EVERY background task
# and every agent you spawned, then re-run until it prints CLOSABLE.
#
# usage: wrap-subtree-check.sh [--queue-doc <handover-path>] [<claude-pid>]
# --queue-doc: once the subtree is clean, also require that
# `queue-lock.sh status <handover-path>` answers `free`; a still-held lock
# (status rc 11/12) is `WITHHELD: queue lock still held for <doc>` rc 1, any
# other answer or a status error is `WITHHELD: cannot read the queue lock` rc 2
# (fail-closed). Without the flag nothing about the queue lock is read.
# Without a pid the session is the nearest ancestor of this script whose argv0
# is `claude`. The subtree is every descendant of that session EXCEPT this
# script's own chain (its tool-call wrapper, itself, and its own children) and
# harness processes: a non-shell-wrapper process whose full argv matches
# WRAP_SUBTREE_HARNESS_RE (ERE; default: an `mcp-server*` path/word, a
# `…qmd[.ext] mcp` invocation, or the session's `caffeinate` keep-awake —
# a descendant of a name-matched process inherits the ignore by walking up
# to that match, the same rule that already carries an MCP launcher's ignore
# down to its children), or a
# DIRECT child of the session that is not a shell-tool wrapper and forked
# within WRAP_SUBTREE_START_WINDOW seconds
# (default 10; 0 turns the rule off) of the session itself — the servers a
# session starts with it (`uv tool uvx … mcp-obsidian`, `graphify-mcp`,
# `uv run … server.py`) share no name but all fork ~1s after `claude`
# — plus anything beneath one. Each ignored child is listed as an
# `ignored pid=…` row with why=, never hidden. A shell-tool wrapper
# (`<shell> -c source …/shell-snapshots/snapshot-…`) is never harness, whatever
# its command text says or however early it started: every command a leg runs
# is in one, so leg-spawned work is always counted. The session pid must itself be a `claude` process: an
# arbitrary live pid (a leaf, another tool) is refused, never called CLOSABLE.
# ponytail: only DESCENDANTS of the session are seen. A shell reparented to
# init/systemd (an intermediate process died first) is not attributed to the
# session and does not withhold CLOSABLE; attributing it would mean reading
# /proc/<pid>/environ, which is credential-adjacent, so it is deliberately not
# done. Tool-call shells are direct children of the session (the N35 leak
# class), so they stay visible; the complementary check is tick's orphans=
# field (console-kit/orphan-loops.sh), which lists such shells as owner `orphan`.
# ponytail: the start-time rule is a conjunction (direct child AND non-wrapper
# AND forked inside the window, from etime at 1s resolution). Its errors fall
# toward WITHHELD: an MCP server started lazily or after a `/mcp` reconnect is
# outside the window and withholds (the WITHHELD text says not to stop it). A
# cold `uv` cache makes that the COMMON case, not an exotic one: `uvx`/`uv run`
# may download and build for well over the window before the server forks.
# Observed delta on real sessions is 0-1s; the 10s default is chosen slack.
# The unsafe direction needs a leg-spawned process that is a non-wrapper direct
# child forked inside the window — i.e. a Bash tool call with no shell-snapshot
# wrapper AND a first tool call within seconds of session start; not observed.
# The same hole opens if a shell wrapper exec()s its command inside the window:
# pid, ppid and etime stay put but argv stops matching iswrap, so the replacement
# process and everything beneath it would read as harness (false CLOSABLE). Real
# wrappers keep the shell as parent of the command (a `source … && eval …` list
# is not exec-optimised), so it was not observed either; nothing here detects it.
# The launcher's own argv (the configured MCP commands) or the supervisor were
# not used: claude spawns MCP servers itself (ppid = the session, no
# supervisor), and the config that names them (~/.claude.json) holds tokens.
# ponytail: the default harness match is a heuristic over argv, so a leaked
# process literally named like an MCP server (`node …/mcp-server-x/y.js`) would
# be exempt; the leak class this gate exists for is a tool-call shell, which
# is never exempt. `caffeinate` is anchored more tightly than
# mcp-server/qmd: it only matches as the PROGRAM itself (optionally
# path-prefixed) followed by nothing but flags, never a job argument — so
# `caffeinate ./long-job.sh` and `sleep 999 caffeinate` withhold (a regression
# the word-anywhere match let through, caught by an Opus judge on this
# ticket's own PR before merge) where the original match exempted them. The
# same tradeoff as mcp-server remains at the narrower anchor: a genuine
# `caffeinate` binary invoked with no job is still exempt by name alone, no
# new mechanism to fix it here.
# GH #1337 also reported a `claude-hud` statusline tree false WITHHELD. A loose
# by-path exemption (`^([^ ]*/)?(node|bun) [^ ]*/claude-hud/[^ ]*`) was rejected
# on that PR's re-judge: it exempted ANY node/bun script under any directory
# merely named claude-hud. It was fixed with a tight anchor on the real
# statusLine launch shape, widened to the whole per-render chain
# (see chain_re below).
#
# READ-ONLY: this script never signals a process. Bash 3.2-compatible.
# WRAP_SUBTREE_SELF overrides the pid treated as "this script" (test seam).
# WRAP_SUBTREE_HOME overrides the home whose .claude/plugins anchors the refresh cwd (test seam; default $HOME).
# WRAP_SUBTREE_START_WINDOW: seconds after the session start within which a
# direct child counts as session-started (non-negative integer; default 10).
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only (procps ps).
set -uo pipefail

usage='usage: wrap-subtree-check.sh [--queue-doc <handover-path>] [<claude-pid>]'
case "${1:-}" in
    -h|--help)
        printf '%s\n' "$usage"
        exit 0 ;;
esac
root=""
qdoc=""
have_root=0
have_qdoc=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --queue-doc)
            [ "$have_qdoc" -eq 0 ] && [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' "$usage" >&2; exit 2; }
            qdoc="$2"; have_qdoc=1; shift 2 ;;
        *)
            [ "$have_root" -eq 0 ] || { printf '%s\n' "$usage" >&2; exit 2; }
            root="$1"; have_root=1; shift ;;
    esac
done
case "$root" in
    '') ;;
    *[!0-9]*) printf '%s\n' "$usage" >&2; exit 2 ;;
esac

self="${WRAP_SUBTREE_SELF:-$$}"
# No backslashes: the value crosses awk -v, which processes escape sequences.
window="${WRAP_SUBTREE_START_WINDOW:-10}"
case "$window" in
    ''|*[!0-9]*)
        printf 'WITHHELD: WRAP_SUBTREE_START_WINDOW must be a non-negative integer (got %s) — not declaring CLOSABLE\n' "$window"
        exit 2 ;;
esac
harness_re="${WRAP_SUBTREE_HARNESS_RE:-(^|[ /])(mcp-server[^ ]*|[^ ]*qmd([.][a-z]+)? mcp)( |\$)|^([^ ]*/)?caffeinate( -[a-z]+( [0-9]+)?)*\$}"

# the per-render statusline chain. claude-hud's real
# launch is `sh -c [ -f P ] && exec node P || true`, so argv is exactly `node
# <abs>/marketplace/plugins/claude-hud/dist/index.js`; it runs `bash <abs>/scripts/
# statusline/hud-custom-lines.sh`, which runs `[timeout N] bash <abs>/scripts/
# where-are-we/statusline-segment.sh --cwd <dir>`, which runs `[timeout N] node
# <abs>/scripts/where-are-we/provision.mjs slice …` — all re-spawned each render
# at etime 00:00 (a bash `$(…)` subshell shares its parent's argv). A process is
# chain-exempt only when it AND every ancestor up to the session match one of
# these four anchored shapes (awk ischain), so a non-chain child, or a chain
# member beneath a non-chain parent, still withholds. A directory merely named
# claude-hud, or a script merely named statusline-segment.sh elsewhere, is NOT
# exempt, and a `/..` anywhere in the argv disqualifies.
# every DESCENDANT of a chain-shaped direct child of the session is
# exempt too (via= names that top), so claude-hud's own `git status --porcelain`
# child does not withhold; a leg-owned git hangs under a tool-call wrapper or the
# session, never under a chain top, and still withholds.
# No backslashes: the value crosses awk -v.
chain_re='^([^ ]*/)?node /[^ ]*/marketplace/plugins/claude-hud/dist/index[.]js$|^([^ ]*/)?(bash|sh) /[^ ]*/scripts/statusline/hud-custom-lines[.]sh$|^(timeout [0-9]+ )?([^ ]*/)?(bash|sh) /[^ ]*/scripts/where-are-we/statusline-segment[.]sh( --cwd [^ ].*)?$|^(timeout [0-9]+ )?([^ ]*/)?node /[^ ]*/scripts/where-are-we/provision[.]mjs slice( .*)?$'

# Claude Code's own plugin refresh: a hardened `git -c core.fsmonitor= -c
# core.hooksPath=/dev/null -c core.askPass= … <clone|fetch|ls-remote|read-tree>` that
# is a DIRECT child of the session, whose cwd (read from /proc/<pid>/cwd) is the plugin
# cache or marketplace dir under <home>/.claude/plugins/ (or its /tmp/claude-lsremote-*
# probe dir), plus its git descendants (`git remote-https`, `index-pack`, `fetch`),
# each also running in such a cwd. New pids at etime 00:00 on every run. Matched by
# shape, cwd and parentage (no marketplace registry read); every argv may name only
# https://github.com remotes (an ssh, scp-style or other-host remote withholds), and a
# wrapper, a `/..` argv or cwd, or a non-refresh verb still withholds. Claude Code 2.1.303
# puts ~40 more `-c key=value` flags between core.askPass and the verb, a `-C <dir>`, and a
# `-c core.sshCommand=ssh -o BatchMode=yes …` value that holds spaces; the sshCommand value
# and -C are stripped before the verb is read, and the three core.* flags may sit in any order.
# A git whose cwd cannot be read (exited between ps and the read, or not ours) withholds;
# the next run sees a fresh table.
# ponytail: a leg that types a hardened git with this cwd as a DIRECT child of the session
# (not under a shell-tool wrapper) would be exempt; legs run git inside a wrapper, so not
# observed; tighten with the marketplace registry if it ever happens.
# No backslashes: the value crosses awk -v.
mkt_top_re='^([^ ]*/)?git (-c [A-Za-z0-9_.-]+=[^ ]* )*(clone|fetch|ls-remote|read-tree)( |$)'
mkt_cwd_re='^(marketplaces|cache)(/[^ ]*)?$|^/tmp/claude-lsremote-[A-Za-z0-9]+$'
# the plugins dir itself is read from $HOME (WRAP_SUBTREE_HOME is the test seam); an empty home matches nothing
mkt_home="${WRAP_SUBTREE_HOME:-${HOME:-}}"
mkt_home="${mkt_home%/}"

# -ww: a COLUMNS in the environment would otherwise cut every argv the harness test reads
ps_out="$(ps -ww -eo pid=,ppid=,etime=,args= 2>/dev/null)" || ps_out="$(ps -eo pid=,ppid=,etime=,args= 2>/dev/null)" || ps_out=""
if [ -z "$ps_out" ]; then
    printf 'WITHHELD: cannot read the process table (ps failed) — not declaring CLOSABLE\n'
    exit 2
fi

# cwd of every git / git-remote-https row, one `<pid> <cwd>` line each (WRAP_SUBTREE_PROC is the test seam).
procdir="${WRAP_SUBTREE_PROC:-/proc}"
cwds=""
for gp in $(printf '%s\n' "$ps_out" | awk '$4 ~ /(^|\/)git(-remote-https)?$/ { print $1 }'); do
    # swallow-ok: an unreadable cwd is recorded UNKNOWN, which is never exempt, so the row withholds
    gc="$(readlink "$procdir/$gp/cwd" 2>/dev/null)"
    cwds="$cwds$gp ${gc:-UNKNOWN}"$'\n'
done

result="$(printf '%s\n' "$ps_out" | WRAP_SUBTREE_CWDS="$cwds" WRAP_SUBTREE_HOME_DIR="$mkt_home" awk -v root="$root" -v self="$self" -v hre="$harness_re" -v chainpat="$chain_re" -v mkttop="$mkt_top_re" -v mktcwd="$mkt_cwd_re" -v win="$window" '
function iswrap(a) {
    return a ~ /^[^ ]*(bash|zsh|sh) -c (source|\.) [^ ]*shell-snapshots\/snapshot-(bash|zsh)-/
}
function isclaude(a,   t, n, b) {
    split(a, t, " ")
    n = split(t[1], b, "/")
    return b[n] == "claude"
}
function isharness(p) {
    if (iswrap(arg[p])) return 0
    return arg[p] ~ hre
}
function isgit(p,   t, n, b) {
    split(arg[p], t, " ")
    n = split(t[1], b, "/")
    return b[n] == "git" || b[n] == "git-remote-https"
}
# every remote in the argv is an https://github.com one
function githubonly(p,   a) {
    a = arg[p]
    gsub(/https:\/\/github[.]com\/[A-Za-z0-9_.\/-]+/, "", a)
    return a !~ /:\/\// && a !~ /(^| )[A-Za-z0-9_.@-]+:[^ ]/ && a !~ /(^| )\[[^ ]*\]:/
}
# the harness'"'"'s hardened refresh git: the three core.* flags in any order, a clone/fetch/
# ls-remote/read-tree verb once the sshCommand value (it holds spaces) and -C are stripped
function ishardened(p,   a) {
    a = arg[p]
    gsub(/ -c core[.]sshCommand=ssh( -o [A-Za-z]+=[A-Za-z]+)+/, "", a)
    gsub(/ -C [^ ]+/, "", a)
    if (index(a, " -c core.hooksPath=/dev/null ") == 0 || index(a, " -c core.fsmonitor= ") == 0 || index(a, " -c core.askPass= ") == 0) return 0
    return a ~ mkttop
}
function ismkt(p, d,   c) {
    if (d > 8 || iswrap(arg[p]) || index(arg[p], "/..") != 0 || !isgit(p) || !githubonly(p)) return 0
    c = cwd[p]
    if (index(c, "/..") != 0) return 0
    if (home != "" && index(c, home "/.claude/plugins/") == 1) c = substr(c, length(home "/.claude/plugins/") + 1)
    if (c !~ mktcwd) return 0
    if (ppid[p] == root) return ishardened(p)
    return (ppid[p] in ppid) && ismkt(ppid[p], d + 1)
}
function ischain(p) {
    return arg[p] ~ chainpat && index(arg[p], "/..") == 0
}
# [[DD-]HH:]MM:SS -> seconds; -1 for anything else (fails closed in isearly)
function secs(e,   x, t, n, s, k, d) {
    if (e !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) return -1
    d = 0
    if (index(e, "-")) { split(e, x, "-"); d = x[1]; e = x[2] }
    n = split(e, t, ":"); s = 0
    for (k = 1; k <= n; k++) s = s * 60 + t[k]
    return d * 86400 + s
}
# A direct child of the session (the caller checks that), not a tool-call
# wrapper, forked within win seconds of the session itself.
function isearly(p,   a, b, d) {
    if (win + 0 == 0 || iswrap(arg[p])) return 0
    a = secs(et[root]); b = secs(et[p])
    if (a < 0 || b < 0) return 0
    d = a - b
    return d >= 0 && d <= win + 0
}
BEGIN {
    maxh = 4096
    home = ENVIRON["WRAP_SUBTREE_HOME_DIR"]
    nc = split(ENVIRON["WRAP_SUBTREE_CWDS"], cl, "\n")
    for (k = 1; k <= nc; k++) { sp = index(cl[k], " "); if (sp > 0) cwd[substr(cl[k], 1, sp - 1)] = substr(cl[k], sp + 1) }
}
{
    pid = $1; ppid[pid] = $2; et[pid] = $3
    a = $0
    for (i = 0; i < 3; i++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", a)
    arg[pid] = a
    order[++np] = pid
}
END {
    if (root == "") {
        p = self
        for (h = 0; h < maxh; h++) {
            p = ppid[p]
            if (p == "" || p == 0) break
            if (isclaude(arg[p])) { root = p; break }
        }
    }
    if (root == "" || !(root in ppid)) { print "NOROOT"; exit }
    if (!isclaude(arg[root])) { print "NOTCLAUDE"; exit }
    # This script'"'"'s own chain: itself and every ancestor below the session.
    p = self
    for (h = 0; h < maxh && p != "" && p != 0 && p != root; h++) { chain[p] = 1; p = ppid[p] }
    n = 0
    for (i = 1; i <= np; i++) {
        pid = order[i]
        if (pid == root) continue
        p = pid; under = 0; skip = (pid in chain); harness = 0; why = ""; via = ""; allchain = 1; top = ""
        for (h = 0; h < maxh; h++) {
            if (p == self) skip = 1
            if (!ischain(p)) allchain = 0
            if (!harness && isharness(p)) { harness = 1; why = "name-match"; via = p }
            q = ppid[p]
            if (q == root && !harness && isearly(p)) { harness = 1; why = "session-start"; via = p }
            if (q == root) { under = 1; top = p; break }
            if (q == "" || q == 0) break
            p = q
        }
        # Ran out of hops without reaching the session or init: cannot prove this
        # process is outside the subtree, so count it (fail closed).
        if (h >= maxh) under = 1
        if (!under || skip) continue
        if (!harness && ismkt(pid, 0)) { harness = 1; why = "marketplace-refresh"; via = pid }
        if (!harness && allchain) { harness = 1; why = "statusline-chain"; via = pid }
        # a descendant of a chain node that is itself the session'"'"'s direct
        # child (claude-hud'"'"'s `git status --porcelain`) inherits the ignore by its
        # parent chain; a leg-owned process hangs under a tool-call wrapper or the
        # session, never under a chain top, so it is not reached.
        if (!harness && top != "" && ischain(top)) { harness = 1; why = "statusline-chain"; via = top }
        cmd = substr(arg[pid], 1, 100)
        if (harness) {
            m++
            irows = irows sprintf("  ignored pid=%s ppid=%s etime=%s why=%s%s cmd=%s\n", pid, ppid[pid], et[pid], why, (via == pid ? "" : " via=" via), cmd)
            continue
        }
        n++
        rows = rows sprintf("  pid=%s ppid=%s etime=%s cmd=%s\n", pid, ppid[pid], et[pid], cmd)
    }
    printf "ROOT %s\nCOUNT %d\nIGNORED %d\n%s%s", root, n, m, rows, irows
}')"

case "$result" in
    NOROOT*)
        if [ -n "$root" ]; then
            printf 'WITHHELD: claude pid %s is not in the process table — not declaring CLOSABLE\n' "$root"
        else
            printf 'WITHHELD: no claude session found above this script — pass the session pid; not declaring CLOSABLE\n'
        fi
        exit 2 ;;
    NOTCLAUDE*)
        printf 'WITHHELD: pid %s is not a claude session — pass the session pid; not declaring CLOSABLE\n' "$root"
        exit 2 ;;
esac

found="$(printf '%s\n' "$result" | sed -n 's/^ROOT //p')"
count="$(printf '%s\n' "$result" | sed -n 's/^COUNT //p')"
ignored="$(printf '%s\n' "$result" | sed -n 's/^IGNORED //p')"
if [ -z "$found" ] || [ -z "$count" ] || [ -z "$ignored" ]; then
    printf 'WITHHELD: cannot parse the process table — not declaring CLOSABLE\n'
    exit 2
fi
if [ "$count" -eq 0 ] && [ -n "$qdoc" ]; then
    ql="${WRAP_SUBTREE_QUEUE_LOCK:-$(dirname "${BASH_SOURCE[0]}")/queue-lock.sh}"
    # swallow-ok: qrc is captured and any status other than rc 0 + "free" withholds
    qout="$(bash "$ql" status "$qdoc" 2>/dev/null)"; qrc=$?
    if [ "$qrc" -eq 0 ] && [ "$qout" = "free" ]; then
        :
    elif [ "$qrc" -ge 11 ] && [ "$qrc" -le 12 ]; then
        printf 'WITHHELD: queue lock still held for %s — release it with queue-lock.sh release <doc> <token>, then re-run; not declaring CLOSABLE\n' "$qdoc"
        exit 1
    else
        printf 'WITHHELD: cannot read the queue lock for %s (status rc=%s) — not declaring CLOSABLE\n' "$qdoc" "$qrc"
        exit 2
    fi
fi
if [ "$count" -eq 0 ]; then
    if [ "$ignored" -eq 0 ]; then
        printf 'CLOSABLE: no non-harness process under claude pid %s\n' "$found"
    else
        printf 'CLOSABLE: no non-harness process under claude pid %s (%s harness-owned children ignored)\n' "$found" "$ignored"
        printf '%s\n' "$result" | sed -n '/^  ignored pid=/p'
    fi
    exit 0
fi
printf 'WITHHELD: %s process(es) still alive under claude pid %s — TaskStop only what you started (background tasks, agents you spawned), then re-run; never stop a process you did not start, e.g. a session MCP server or the statusline refresh: report it to the console instead\n' "$count" "$found"
printf '%s\n' "$result" | sed -n '/^  pid=/p'
printf '%s\n' "$result" | sed -n '/^  ignored pid=/p'
exit 1
