#!/usr/bin/env bash
# ensure-workspace-trust.sh <dir>
#
# Pre-trust <dir> in Claude Code's config (~/.claude.json) so an autonomous
# `claude` launch with that dir as cwd does NOT stall on the interactive
# workspace-trust prompt ("Is this a project you created or one you trust?").
# Autonomous arms (handover resume via arm-resume.sh, clip-pipeline cadence
# via pipeline-cadence.sh) have no human to answer it and their stdin is
# absent or /dev/null, so an untrusted cwd silently wastes the whole run.
#
# Sets projects[<key>].hasTrustDialogAccepted = true via an atomic
# read-modify-write. <key> matches how Claude stores it (observed as of
# writing): on Windows the `cygpath -m` mixed form (C:/Users/...),
# elsewhere the absolute path from `cd "$dir" && pwd`.
#
# Config path: $WORKSPACE_TRUST_CONFIG, else $HOME/.claude.json.
#
# Concurrency: the read-modify-write commits via write-to-temp +
# atomic rename, so a coincident reader/writer never sees a half-written file.
# It is a compare-and-retry: after writing the temp file the helper re-reads
# the config and renames only if it still holds exactly the bytes it read;
# otherwise it drops the temp file and starts again from the read (up to 10
# attempts). So a parallel helper's trust entry, or a change Claude Code made
# meanwhile, is merged rather than overwritten. No lock is taken: Claude Code
# writes ~/.claude.json without one of ours, so only the compare protects its
# changes. A small randomized jitter (TRUST_WRITE_JITTER_MS, default 500,
# 0 disables) runs before the read to de-synchronize two launches that fire
# within ~1s, so fewer attempts are spent on retries.
#
# Test seam: TRUST_WRITE_PAUSE_MARKER=<path> (inert when unset) makes the
# helper create <path>.reached.<n> after the read of attempt <n> and wait for
# <path>.go.<n> before it writes, so a test can force the lost-update
# interleaving on any attempt.
#
# Exit codes:
#   0  flag is set (already-true is a no-op that also exits 0)
#   2  bad usage / dir does not exist / node missing
#   3  config exists but is unreadable, not parseable JSON, or not a JSON
#      object — REFUSES to overwrite (never clobber Claude's state on a
#      transient read or parse error)
#   4  the temp write, the re-read before the rename or the atomic rename
#      failed, or the config changed under every attempt — warns, leaves
#      any existing config untouched (rename never happened), and orphans no
#      temp file
#
# Callers MUST treat a non-zero exit as NON-FATAL (warn, then continue): a
# trust pre-seed problem must never block an arm. The exit codes exist so
# the test harness can assert behaviour, not so callers can abort on them.
set -uo pipefail

dir="${1:-}"
if [ -z "$dir" ]; then
    echo "ensure-workspace-trust: usage: ensure-workspace-trust.sh <dir>" >&2
    exit 2
fi
if [ ! -d "$dir" ]; then
    echo "ensure-workspace-trust: not a directory: $dir" >&2
    exit 2
fi
if ! command -v node >/dev/null 2>&1; then
    echo "ensure-workspace-trust: node not on PATH" >&2
    exit 2
fi

# Absolute path, then normalize to the key form Claude persists.
abs=$(cd "$dir" && pwd)
if [ -z "$abs" ]; then
    # cd succeeded the -d check but pwd came back empty (dir vanished mid-run);
    # never write an empty trust key.
    echo "ensure-workspace-trust: could not resolve absolute path for: $dir" >&2
    exit 2
fi
if command -v cygpath >/dev/null 2>&1; then
    key=$(cygpath -m "$abs")   # /c/Users/... -> C:/Users/...
else
    key="$abs"
fi

config="${WORKSPACE_TRUST_CONFIG:-$HOME/.claude.json}"

# Jitter the read-modify-write so two launches within ~1s rarely read the same
# old file (the compare-and-retry below handles it when they do, at the cost of
# an attempt). Default 500ms cap; 0 disables (test seam). Git Bash `sleep`
# accepts fractional secs.
jitter_ms="${TRUST_WRITE_JITTER_MS:-500}"
if [ "$jitter_ms" -gt 0 ] 2>/dev/null; then
    ms=$(( RANDOM % (jitter_ms + 1) ))          # 0..jitter_ms milliseconds
    sleep "$(printf '%d.%03d' "$(( ms / 1000 ))" "$(( ms % 1000 ))")" 2>/dev/null || true
fi

# node does the read-modify-write: tolerant of a missing file (fresh create),
# strict on a present-but-unparseable file (refuse to clobber), atomic via
# write-to-temp + rename. Key/config passed by env to avoid all shell quoting.
WT_KEY="$key" WT_CONFIG="$config" node -e '
const fs = require("fs");
const p = process.env.WT_CONFIG, key = process.env.WT_KEY;
const pause = process.env.TRUST_WRITE_PAUSE_MARKER;
const MAX_ATTEMPTS = 10;
const tmp = p + ".tmp-trust-" + process.pid;
function readRaw() {
    try {
        return fs.readFileSync(p, "utf8");
    } catch (e) {
        if (e.code === "ENOENT") return null;
        throw e;
    }
}
for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    let raw;
    try {
        raw = readRaw();
    } catch (e) {
        console.error("ensure-workspace-trust: cannot read " + p + ": " + e.message);
        process.exit(3);
    }
    let j = {};
    if (raw !== null) {
        try {
            j = JSON.parse(raw);
        } catch (e) {
            console.error("ensure-workspace-trust: " + p + " is not valid JSON - refusing to overwrite");
            process.exit(3);
        }
        if (typeof j !== "object" || j === null || Array.isArray(j)) {
            console.error("ensure-workspace-trust: " + p + " is not a JSON object - refusing to overwrite");
            process.exit(3);
        }
    }
    if (!j.projects || typeof j.projects !== "object" || Array.isArray(j.projects)) j.projects = {};
    if (!j.projects[key] || typeof j.projects[key] !== "object" || Array.isArray(j.projects[key])) j.projects[key] = {};
    if (j.projects[key].hasTrustDialogAccepted === true) process.exit(0);
    j.projects[key].hasTrustDialogAccepted = true;
    if (pause) {
        fs.writeFileSync(pause + ".reached." + attempt, "");
        const deadline = Date.now() + 30000;
        while (!fs.existsSync(pause + ".go." + attempt) && Date.now() < deadline) {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
        }
    }
    try {
        fs.writeFileSync(tmp, JSON.stringify(j, null, 2));
        if (readRaw() !== raw) {
            fs.unlinkSync(tmp);
            continue;
        }
        fs.renameSync(tmp, p);
        process.exit(0);
    } catch (e) {
        // Fail-open: warn, leave any existing config untouched
        // (the rename is the commit point and never ran), orphan no temp file.
        try { fs.unlinkSync(tmp); } catch (_) {}
        console.error("ensure-workspace-trust: could not write " + p + ": " + e.message);
        process.exit(4);
    }
}
console.error("ensure-workspace-trust: " + p + " changed under each of " + MAX_ATTEMPTS + " attempts - trust entry not written");
process.exit(4);
'
