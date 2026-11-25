#!/usr/bin/env bash
# shellcheck disable=SC2154  # failures is set by the sourced testlib
# Usage: bash scripts/test-himmel-doctor-c.sh
set -uo pipefail
# shellcheck source=tests/testlib-himmel-doctor.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-himmel-doctor.sh"

echo "== C44: skills collection missing -> FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c44-missing.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
printf '{"items":[{"id":"qmd-index","desired":true,"severity":"red"}]}' > "$t/status-qmd-on.json"
cat > "$t/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    printf 'Collections (1):\n\nhimmel (qmd://himmel/)\n  Files:    527\n'
    exit 0
fi
exit 2
STUB
chmod 755 "$t/qmd"
out="$(DOCTOR_STATUS_JSON="$t/status-qmd-on.json" HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/qmd" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'FAIL C44-skill-index' && grepq "$out" -F 'ensure-skill-index.sh'; then
    pass "C44 missing collection -> FAIL"
else
    fail "C44 missing collection -> $(printf '%s' "$out" | grep -A1 C44)"
fi
rm -rf "$t"

echo "== C44: skills collection empty (0 files) -> FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c44-empty.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
printf '{"items":[{"id":"qmd-index","desired":true,"severity":"red"}]}' > "$t/status-qmd-on.json"
cat > "$t/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    printf 'Collections (2):\n\nhimmel (qmd://himmel/)\n  Files:    527\n\nskills (qmd://skills/)\n  Files:    0\n'
    exit 0
fi
exit 2
STUB
chmod 755 "$t/qmd"
out="$(DOCTOR_STATUS_JSON="$t/status-qmd-on.json" HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/qmd" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'FAIL C44-skill-index'; then
    pass "C44 empty collection -> FAIL"
else
    fail "C44 empty collection -> $(printf '%s' "$out" | grep -A1 C44)"
fi
rm -rf "$t"

echo "== C44: skills collection populated -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c44-ok.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
cat > "$t/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    printf 'Collections (2):\n\nhimmel (qmd://himmel/)\n  Files:    527\n\nskills (qmd://skills/)\n  Files:    42\n'
    exit 0
fi
exit 2
STUB
chmod 755 "$t/qmd"
out="$(HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/qmd" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C44-skill-index' && ! grepq "$out" 'FAIL C44-skill-index'; then
    pass "C44 populated collection -> OK"
else
    fail "C44 populated collection -> $(printf '%s' "$out" | grep -A1 C44)"
fi
rm -rf "$t"

echo "== C44: qmd item not wanted (starter install) -> INFO, no FAIL =="
t="$(mktemp -d "${TMPDIR:-/tmp}/c44-off.XXXXXX")" && [ -n "$t" ] || exit 1
cat > "$t/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    printf 'Collections (1):\n\nhimmel (qmd://himmel/)\n  Files:    527\n'
    exit 0
fi
exit 2
STUB
chmod 755 "$t/qmd"
printf '{"items":[{"id":"qmd-index","desired":false,"severity":"n/a"}]}' > "$t/status-qmd-off.json"
out="$(DOCTOR_STATUS_JSON="$t/status-qmd-off.json" HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/qmd" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C44-skill-index' && ! grepq "$out" 'FAIL C44-skill-index'; then
    pass "C44 qmd not wanted -> INFO, no FAIL"
else
    fail "C44 qmd not wanted -> $(printf '%s' "$out" | grep -A1 C44)"
fi
printf '{"items":[{"id":"qmd-index","severity":"n/a"}]}' > "$t/status-qmd-unk.json"
out="$(DOCTOR_STATUS_JSON="$t/status-qmd-unk.json" HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/qmd" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'FAIL C44-skill-index'; then
    pass "C44 desired missing from status -> stays FAIL"
else
    fail "C44 desired missing from status -> $(printf '%s' "$out" | grep -A1 C44)"
fi
rm -rf "$t"

echo "== C44: qmd not resolvable -> INFO skip, no FAIL =="
out="$(HIMMEL_DOCTOR_SKILL_INDEX_QMD="$t/no-such-qmd-anywhere" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C44-skill-index' && ! grepq "$out" 'FAIL C44-skill-index'; then
    pass "C44 qmd absent -> INFO skip"
else
    fail "C44 qmd absent -> $(printf '%s' "$out" | grep -A1 C44)"
fi

# --- C47-runaway-procs: long-lived himmel-shaped process pegging a core --
# WARN (report only, never kill) on a current-user process older than
# HIMMEL_DOCTOR_RUNAWAY_MIN_AGE_MIN (default 30) whose ps CPU is >=
# HIMMEL_DOCTOR_RUNAWAY_CPU_PCT (default 90) and whose cmdline is himmel-shaped
# (qmd, hook.sh, bash scripts/). Seam: HIMMEL_DOCTOR_RUNAWAY_PS (the ps binary;
# the stub prints C47_ROWS, lines of `pid etime pcpu args`).
c47_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c47.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c47_t/home" "$c47_t/claude"
# shellcheck disable=SC2016 # the stub expands C47_ROWS at ITS run time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${C47_ROWS:-}"\n' > "$c47_t/ps"
chmod +x "$c47_t/ps"
c47_run() { # <rows>; threshold overrides are inherited from the caller's env
    PATH="$FAKEBIN:$PATH" C47_ROWS="$1" HIMMEL_DOCTOR_RUNAWAY_PS="$c47_t/ps" \
        CLAUDE_DIR="$c47_t/claude" HOME="$c47_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C47: old + hot + himmel-shaped -> WARN naming pid, etime, %CPU, cmdline (RED) =="
out="$(c47_run '  4242 02:10:05 99.7 bun /x/qmd/dist/cli.js query foo')"
if grepq "$out" 'WARN C47-runaway-procs' && grepq "$out" -F 'pid 4242' && grepq "$out" -F '02:10:05' && grepq "$out" -F '99.7' && grepq "$out" -F 'qmd/dist/cli.js query foo'; then
    pass "C47 runaway qmd -> WARN with pid/etime/%CPU/cmdline"
else
    fail "C47 runaway qmd -> $(printf '%s' "$out" | grep -A1 C47)"
fi

echo "== C47: young, cool, or foreign cmdlines are skipped; a hook.sh runaway is kept =="
out="$(c47_run '  1 00:05:00 99.0 bun qmd query
  2 3-01:00:00 12.0 bun qmd query
  3 05:00:00 99.0 /usr/bin/firefox
  4 05:00:00 95.0 bash /x/hook.sh')"
if ! grepq "$out" -F 'pid 1 ' && ! grepq "$out" -F 'pid 2 ' && ! grepq "$out" -F 'pid 3 ' && grepq "$out" -F 'pid 4 '; then
    pass "C47 filters young/cool/foreign rows, keeps the hook.sh runaway"
else
    fail "C47 filtering -> $(printf '%s' "$out" | grep -A3 C47)"
fi
out="$(c47_run '  2 3-01:00:00 12.0 bun qmd query')"
if grepq "$out" 'OK   C47-runaway-procs' && ! grepq "$out" 'WARN C47'; then
    pass "C47 nothing runaway -> OK"
else
    fail "C47 clean -> $(printf '%s' "$out" | grep -A1 C47)"
fi

echo "== C47: thresholds are env-overridable =="
out="$(HIMMEL_DOCTOR_RUNAWAY_MIN_AGE_MIN=1 c47_run '  1 00:05:00 99.0 bun qmd query')"
out_cpu="$(HIMMEL_DOCTOR_RUNAWAY_CPU_PCT=10 c47_run '  2 3-01:00:00 12.0 bun qmd query')"
if grepq "$out" 'WARN C47-runaway-procs' && grepq "$out_cpu" 'WARN C47-runaway-procs'; then
    pass "C47 age and CPU thresholds honour their env overrides"
else
    fail "C47 overrides -> age=[$(printf '%s' "$out" | grep C47)] cpu=[$(printf '%s' "$out_cpu" | grep C47)]"
fi

echo "== C47: a real busy loop (self-terminating after 40 s, killed by the test) is reported and left running =="
# shellcheck disable=SC2016 # $SECONDS expands in the child shell
bash -c 'while [ "$SECONDS" -lt 40 ]; do :; done' hook.sh-c47-fixture &
c47_pid=$!
sleep 2
out="$(HIMMEL_DOCTOR_RUNAWAY_MIN_AGE_MIN=0 HIMMEL_DOCTOR_RUNAWAY_CPU_PCT=50 HIMMEL_DOCTOR_RUNAWAY_PS=ps CLAUDE_DIR="$c47_t/claude" HOME="$c47_t/home" bash "$DOC" --no-color 2>&1)"
c47_alive=no; kill -0 "$c47_pid" 2>/dev/null && c47_alive=yes
kill "$c47_pid" 2>/dev/null; wait "$c47_pid" 2>/dev/null
if grepq "$out" 'WARN C47-runaway-procs' && grepq "$out" -F "pid $c47_pid" && [ "$c47_alive" = yes ]; then
    pass "C47 reports a live busy loop and leaves it running"
else
    fail "C47 real loop -> alive=$c47_alive $(printf '%s' "$out" | grep -A1 C47)"
fi
rm -rf "$c47_t"

# --- C54-hook-copy-reaper: orphaned hook copies, report-only ---
# Runs hook-copy-reaper.sh WITHOUT --kill: rc 0 -> OK, rc 1 -> WARN with each
# pid=/age=/cpu=/script= row, any other rc -> WARN naming the failure.
# Seam: HIMMEL_DOCTOR_HOOK_REAPER (a stub; it logs its argv to C54_ARGV).
c54_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c54.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c54_t/home" "$c54_t/claude"
cat > "$c54_t/reaper" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$C54_ARGV"
printf '%s\n' "${C54_OUT:-}"
exit "${C54_RC:-0}"
STUB
chmod +x "$c54_t/reaper"
c54_run() { # <rc> <stdout>
    : > "$c54_t/argv"
    PATH="$FAKEBIN:$PATH" C54_RC="$1" C54_OUT="$2" C54_ARGV="$c54_t/argv" HIMMEL_DOCTOR_HOOK_REAPER="$c54_t/reaper" \
        CLAUDE_DIR="$c54_t/claude" HOME="$c54_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C54: rc 0 (none) -> OK, reaper run without --kill =="
out="$(c54_run 0 'hook-copies=none')"
if grepq "$out" 'OK   C54-hook-copy-reaper' && ! grepq "$out" 'WARN C54' && ! grep -q -- '--kill' "$c54_t/argv"; then
    pass "C54 rc 0 -> OK, no --kill"
else
    fail "C54 rc 0 -> $(printf '%s' "$out" | grep -A1 C54) argv=$(cat "$c54_t/argv")"
fi

echo "== C54: rc 1 (found) -> WARN surfacing each pid/age/cpu/script row =="
out="$(c54_run 1 'pid=4242 age=95m cpu=89.0 script=/tmp/claude-1000/x/hook.sh
pid=4343 age=61m cpu=75.5 script=/tmp/claude-1000/y/guard.sh
hook-copies=2')"
if grepq "$out" 'WARN C54-hook-copy-reaper' && grepq "$out" -F 'pid=4242 age=95m cpu=89.0 script=/tmp/claude-1000/x/hook.sh' && grepq "$out" -F 'pid=4343' && ! grep -q -- '--kill' "$c54_t/argv"; then
    pass "C54 rc 1 -> WARN with each row, no --kill"
else
    fail "C54 rc 1 -> $(printf '%s' "$out" | grep -A3 C54) argv=$(cat "$c54_t/argv")"
fi

echo "== C54: any other rc -> WARN naming the failure, never a silent OK =="
for c54_rc in 2 3 127; do
    out="$(c54_run "$c54_rc" 'hook-copies=?')"
    if grepq "$out" 'WARN C54-hook-copy-reaper' && grepq "$out" -F "rc=$c54_rc" && ! grepq "$out" 'OK   C54'; then
        pass "C54 rc $c54_rc -> WARN naming rc=$c54_rc"
    else
        fail "C54 rc $c54_rc -> $(printf '%s' "$out" | grep -A1 C54)"
    fi
done
rm -rf "$c54_t"

# --- C48-tmp-usage: /tmp at 80 % or more -> WARN naming tmp-reap.sh ---
c48_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c48.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c48_t/home" "$c48_t/claude"
# shellcheck disable=SC2016 # the stub expands C48_PCT at ITS run time
printf '#!/usr/bin/env bash\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\ntmpfs 100 %%s 20 %%s%%%% /tmp\\n" "${C48_PCT:-0}" "${C48_PCT:-0}"\n' > "$c48_t/df"
chmod +x "$c48_t/df"
c48_run() { # <pct>
PATH="$FAKEBIN:$PATH" C48_PCT="$1" HIMMEL_DOCTOR_TMP_DF="$c48_t/df" \
CLAUDE_DIR="$c48_t/claude" HOME="$c48_t/home" bash "$DOC" --no-color 2>&1
}
echo "== C48: /tmp at 80 % or more -> WARN naming scripts/tmp-reap.sh =="
for c48_pct in 80 93; do
out="$(c48_run "$c48_pct")"
if grepq "$out" "WARN C48-tmp-usage" && grepq "$out" -F "${c48_pct}% full" && grepq "$out" -F 'scripts/tmp-reap.sh'; then
    pass "C48 ${c48_pct}% -> WARN with the tmp-reap.sh remedy"
else
    fail "C48 ${c48_pct}% -> $(printf '%s' "$out" | grep -A1 C48)"
fi
done
echo "== C48: /tmp below 80 % -> OK, no WARN =="
out="$(c48_run 79)"
if grepq "$out" 'OK   C48-tmp-usage' && ! grepq "$out" 'WARN C48'; then
    pass "C48 79% -> OK"
else
    fail "C48 79% -> $(printf '%s' "$out" | grep -A1 C48)"
fi
out="$(PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_TMP_DF="$c48_t/no-such-df" CLAUDE_DIR="$c48_t/claude" HOME="$c48_t/home" bash "$DOC" --no-color 2>&1)"
if ! grepq "$out" 'C48-tmp-usage'; then
    pass "C48 absent df seam -> silent"
else
    fail "C48 absent df -> $(printf '%s' "$out" | grep C48)"
fi
rm -rf "$c48_t"
# --- C49-qmd-embed-model: index vectors vs the configured model --
# A configured embed model that differs from the model the index's vectors came
# from returns garbage on vec search (or fails on a dimension change). The row
# WARNs; qmd-reindex.sh refuses. Seam: HIMMEL_DOCTOR_QMD_INDEX (the index file);
# the configured model comes from the fixture HOME's ~/.config/qmd/index.yml.
if command -v sqlite3 >/dev/null 2>&1; then
    c49_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c49.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
    mkdir -p "$c49_t/home/.config/qmd" "$c49_t/claude"
    sqlite3 "$c49_t/index.sqlite" "CREATE TABLE content_vectors(hash TEXT, seq INT, model TEXT); INSERT INTO content_vectors VALUES('h',0,'hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf');"
    c49_run() { # <configured embed uri, empty = default>
        if [ -n "$1" ]; then printf 'models:\n  embed: %s\n' "$1" > "$c49_t/home/.config/qmd/index.yml"
        else rm -f "$c49_t/home/.config/qmd/index.yml"; fi
        # CI runners export XDG_CONFIG_HOME, which would point past the fixture HOME.
        env -u QMD_CONFIG_DIR -u XDG_CONFIG_HOME -u QMD_EMBED_MODEL \
            PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_QMD_INDEX="$c49_t/index.sqlite" \
            CLAUDE_DIR="$c49_t/claude" HOME="$c49_t/home" bash "$DOC" --no-color 2>&1
    }

    echo "== C49-qmd-embed-model: index model matches the default -> OK (RED) =="
    out="$(c49_run '')"
    if grepq "$out" 'OK   C49-qmd-embed-model' && grepq "$out" -F 'embeddinggemma'; then
        pass "C49 matching model -> OK naming the model"
    else
        fail "C49 match -> $(printf '%s' "$out" | grep -A1 C49)"
    fi

    echo "== C49-qmd-embed-model: configured qwen over a gemma index -> WARN =="
    out="$(c49_run 'hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf')"
    if grepq "$out" 'WARN C49-qmd-embed-model' && grepq "$out" -F 'qmd-embed-model.sh'; then
        pass "C49 mismatch -> WARN naming the fix script"
    else
        fail "C49 mismatch -> $(printf '%s' "$out" | grep -A1 C49)"
    fi

    echo "== C49-qmd-embed-model: no index -> silent =="
    out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c49_t/claude" HOME="$c49_t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'C49-qmd-embed-model'; then
        fail "C49 no index -> $(printf '%s' "$out" | grep -A1 C49)"
    else
        pass "C49 no index -> silent"
    fi
    rm -rf "$c49_t"
else
    pass "C49 skipped: sqlite3 not installed"
fi

# --- C56-qmd-orphans: orphaned embedding chunks ------------------
# Orphans are vectors whose content hash no longer exists. They bloat the index
# and slow vec scans but never hide a document, so the row is separate from
# C40 (pending docs). Seams: HIMMEL_DOCTOR_QMD_INDEX gates the row (silent when
# absent, like C49); HIMMEL_DOCTOR_QMD_STATUS names a command whose stdout is
# `qmd status` output (default: the resolved qmd).
c56_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c56.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c56_t/home" "$c56_t/claude"; : > "$c56_t/index.sqlite"
c56_run() { # <orphaned line or empty>
    if [ -n "$1" ]; then printf 'QMD Status\n\nDocuments\n  Total:    33783 files indexed\n  Vectors:  168567 embedded\n%s\n  Pending:  0 need embedding\n' "$1" > "$c56_t/status.txt"
    else printf 'QMD Status\n\nDocuments\n  Total:    10 files indexed\n  Vectors:  100 embedded\n' > "$c56_t/status.txt"; fi
    printf '#!/bin/sh\ncat "%s"\n' "$c56_t/status.txt" > "$c56_t/qmd-status"; chmod +x "$c56_t/qmd-status"
    PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_QMD_INDEX="$c56_t/index.sqlite" HIMMEL_DOCTOR_QMD_STATUS="$c56_t/qmd-status" \
        CLAUDE_DIR="$c56_t/claude" HOME="$c56_t/home" bash "$DOC" --no-color 2>&1
}
echo "== C56-qmd-orphans: 6 % orphaned -> WARN with count, percent and fix =="
out="$(c56_run "  Orphaned: 10618 embedding chunks (6%) — run 'qmd cleanup'")"
if grepq "$out" 'WARN C56-qmd-orphans' && grepq "$out" -F '10618 orphaned embedding chunks (6 %), cleanup missed' && grepq "$out" -F 'qmd cleanup'; then
    pass "C56 6 % -> WARN naming count, percent and fix"
else
    fail "C56 6 % -> $(printf '%s' "$out" | grep -A1 C56)"
fi
echo "== C56-qmd-orphans: exactly 5 % -> WARN; 4 % -> INFO =="
out="$(c56_run "  Orphaned: 500 embedding chunks (5%) — run 'qmd cleanup'")"
if grepq "$out" 'WARN C56-qmd-orphans'; then pass "C56 5 % -> WARN"; else fail "C56 5 % -> $(printf '%s' "$out" | grep -A1 C56)"; fi
out="$(c56_run "  Orphaned: 400 embedding chunks (4%) — run 'qmd cleanup'")"
if grepq "$out" 'INFO C56-qmd-orphans' && ! grepq "$out" 'WARN C56-qmd-orphans'; then pass "C56 4 % -> INFO only"; else fail "C56 4 % -> $(printf '%s' "$out" | grep -A1 C56)"; fi
echo "== C56-qmd-orphans: no Orphaned line -> OK =="
out="$(c56_run '')"
if grepq "$out" 'OK   C56-qmd-orphans'; then pass "C56 no orphans -> OK"; else fail "C56 none -> $(printf '%s' "$out" | grep -A1 C56)"; fi
echo "== C56-qmd-orphans: no index -> silent =="
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c56_t/claude" HOME="$c56_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'C56-qmd-orphans'; then fail "C56 no index -> $(printf '%s' "$out" | grep -A1 C56)"; else pass "C56 no index -> silent"; fi
rm -rf "$c56_t"

# --- C83-qmd-embed-backlog: the last reindex's remaining hashes + provider error ---
# qmd-reindex.sh writes `reindex-state` beside the index (key=value
# lines); the fixture below is the file a stubbed incomplete embed leaves (the
# error line is the fork's real per-attempt log line). Seam: HIMMEL_DOCTOR_QMD_REINDEX_STATE.
c83_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c83.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c83_t/home" "$c83_t/claude"
c83_run() { PATH="$FAKEBIN:$PATH" HIMMEL_DOCTOR_QMD_REINDEX_STATE="$c83_t/reindex-state" CLAUDE_DIR="$c83_t/claude" HOME="$c83_t/home" bash "$DOC" --only C83 --no-color 2>&1; }
echo "== C83-qmd-embed-backlog: incomplete embed -> WARN with remaining count and last provider error =="
printf 'ts=2026-10-31T01:05:00Z\nrc=5\nremaining=370\nlast_error=embed: request failed status=503 provider=DeepInfra\nsummary=370 unique hashes still need vectors; last provider error: embed: request failed status=503 provider=DeepInfra\n' > "$c83_t/reindex-state"
out="$(c83_run)"
if grepq "$out" 'WARN C83-qmd-embed-backlog' && grepq "$out" -F '370 unique hashes still lack vectors' && grepq "$out" -F 'status=503 provider=DeepInfra' && grepq "$out" -F 'qmd-reindex.sh'; then
    pass "C83 incomplete embed -> WARN naming the count, the provider error and the fix"
else
    fail "C83 incomplete embed -> $(printf '%s' "$out" | grep -A1 C83)"
fi
echo "== C83-qmd-embed-backlog: unknown count and no provider error -> WARN =="
printf 'rc=5\nremaining=unknown\nlast_error=none\n' > "$c83_t/reindex-state"
out="$(c83_run)"
if grepq "$out" 'WARN C83-qmd-embed-backlog' && grepq "$out" -F 'remaining hash count unknown' && grepq "$out" -F 'last provider error: none'; then
    pass "C83 unknown count -> WARN"
else
    fail "C83 unknown count -> $(printf '%s' "$out" | grep -A1 C83)"
fi
echo "== C83-qmd-embed-backlog: complete run -> OK; no state file -> silent =="
printf 'rc=0\nremaining=0\nlast_error=none\n' > "$c83_t/reindex-state"
out="$(c83_run)"
if grepq "$out" 'OK   C83-qmd-embed-backlog'; then pass "C83 complete -> OK"; else fail "C83 complete -> $(printf '%s' "$out" | grep -A1 C83)"; fi
echo "== C83-qmd-embed-backlog: QMD_INDEX_PATH alone locates the state, as the writer does =="
mkdir -p "$c83_t/idx"
printf 'rc=5\nremaining=7\nlast_error=none\n' > "$c83_t/idx/reindex-state"
# env -u: the suite exports HIMMEL_DOCTOR_QMD_INDEX, which C83 reads first and would mask the QMD_INDEX_PATH fallback
out="$(env -u HIMMEL_DOCTOR_QMD_INDEX PATH="$FAKEBIN:$PATH" QMD_INDEX_PATH="$c83_t/idx/index.sqlite" CLAUDE_DIR="$c83_t/claude" HOME="$c83_t/home" bash "$DOC" --only C83 --no-color 2>&1)"
if grepq "$out" 'WARN C83-qmd-embed-backlog' && grepq "$out" -F '7 unique hashes still lack vectors'; then
    pass "C83 QMD_INDEX_PATH -> state found"
else
    fail "C83 QMD_INDEX_PATH -> $(printf '%s' "$out" | grep -A1 C83)"
fi
rm -f "$c83_t/reindex-state"
out="$(c83_run)"
if grepq "$out" 'C83-qmd-embed-backlog'; then fail "C83 no state -> $(printf '%s' "$out" | grep -A1 C83)"; else pass "C83 no state -> silent"; fi
rm -rf "$c83_t"

# --- C84-release-queue: a declared release the chief doc does not name ---
# Fixture: <t>/h/release/<R>/release.json is the declaration (the CLI's layout) and the
# newest <t>/h/*-chief.md is the chief doc whose `release:` line the tick reads.
# Seam: HIMMEL_RELEASE_STATE_DIR (the same override the tick and chief.sh honour).
c84_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c84.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c84_t/home" "$c84_t/claude" "$c84_t/h/release/R1"
# The probe stands in for `jira release state <R> --json`, whose status is OK only when release.json verifies.
cat > "$c84_t/probe" <<'EOF'
#!/usr/bin/env bash
[ -z "${C84_RC:-}" ] || exit "$C84_RC"
[ -z "${C84_EMPTY:-}" ] || exit 0  # ran, exited 0, printed nothing
printf '{"status":"%s","integrity":["release.json for %s is missing or does not verify"]}\n' "${C84_STATUS:-OK}" "$1"
[ "${C84_STATUS:-OK}" = OK ] || exit 3
EOF
c84_run() { HIMMEL_DOCTOR_RM_STATE_PROBE="$c84_t/probe" HIMMEL_RELEASE_STATE_DIR="$c84_t/h/release" CLAUDE_DIR="$c84_t/claude" HOME="$c84_t/home" bash "$DOC" --only C84 --no-color 2>&1; }
c84_doc() { rm -f "$c84_t/h/"*-chief.md; [ "$#" -eq 0 ] || printf '# chief\n## Live state\n%s\n' "$1" > "$c84_t/h/X-chief.md"; }
printf '{"name":"R1"}\n' > "$c84_t/h/release/R1/release.json"
echo "== C84-release-queue: a declared release and a chief doc with no release: line -> WARN =="
c84_doc "epics: none"
out="$(c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'R1' && grepq "$out" -F 'rm-queue=off' && grepq "$out" -F "release: <R>"; then
    pass "C84 declared release, no release: line -> WARN naming the release, rm-queue=off and the fix"
else
    fail "C84 no release: line -> $(printf '%s' "$out" | head -4)"
fi
echo "== C84-release-queue: the line names a release with no declaration -> WARN =="
c84_doc "release: R9"
out="$(c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'R9'; then pass "C84 line names an undeclared release -> WARN"; else fail "C84 undeclared R9 -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: the declaration is empty -> WARN =="
c84_doc "release: R1"
: > "$c84_t/h/release/R1/release.json"
out="$(c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'R1'; then pass "C84 empty release.json -> WARN"; else fail "C84 empty state -> $(printf '%s' "$out" | head -4)"; fi
printf '{"name":"R1"}\n' > "$c84_t/h/release/R1/release.json"
echo "== C84-release-queue: a declared release and no chief doc -> WARN =="
c84_doc
out="$(c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'no chief doc'; then pass "C84 no chief doc -> WARN"; else fail "C84 no chief doc -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: healthy control (line names the declared release) -> OK =="
c84_doc "release: R1"
out="$(c84_run)"
if grepq "$out" 'OK   C84-release-queue' && ! grepq "$out" 'WARN C84-release-queue'; then pass "C84 healthy -> OK"; else fail "C84 healthy -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: the declaration does not verify (release state is not OK) -> WARN =="
c84_doc "release: R1"
out="$(C84_STATUS=UNKNOWN c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'UNKNOWN' && grepq "$out" -F 'does not verify'; then pass "C84 unverifiable declaration -> WARN naming the state and the integrity reason"; else fail "C84 unverified -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: the state read fails outright (exit 1, then a timeout's 124) -> WARN, never OK =="
for c84_rc in 1 124; do
    out="$(C84_RC=$c84_rc c84_run)"
    if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F "exited $c84_rc" && ! grepq "$out" 'OK   C84-release-queue'; then pass "C84 state read exit $c84_rc -> WARN naming the exit status"; else fail "C84 state read exit $c84_rc -> $(printf '%s' "$out" | head -4)"; fi
done
echo "== C84-release-queue: an unused release's empty declaration is not the chief doc's problem (R1 valid, R2 empty) =="
mkdir -p "$c84_t/h/release/R2"
: > "$c84_t/h/release/R2/release.json"
c84_doc "release: R1"
out="$(c84_run)"
if grepq "$out" 'OK   C84-release-queue' && ! grepq "$out" 'WARN C84-release-queue' && ! grepq "$out" -F 'R2'; then pass "C84 chief doc names healthy R1, empty R2 unused -> OK"; else fail "C84 R2 empty, R1 named -> $(printf '%s' "$out" | head -4)"; fi
c84_doc "release: none"
out="$(c84_run)"
if grepq "$out" 'INFO C84-release-queue' && ! grepq "$out" 'WARN C84-release-queue'; then pass "C84 release: none, R2 empty -> INFO"; else fail "C84 R2 empty, none -> $(printf '%s' "$out" | head -4)"; fi
c84_doc "release: R2"
out="$(c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'R2'; then pass "C84 chief doc names the empty R2 -> WARN"; else fail "C84 R2 named -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c84_t/h/release/R2"
echo "== C84-release-queue: a state probe that ran (exit 0) and printed nothing -> WARN UNREADABLE =="
c84_doc "release: R1"
out="$(C84_EMPTY=1 c84_run)"
if grepq "$out" 'WARN C84-release-queue' && grepq "$out" -F 'UNREADABLE' && ! grepq "$out" -F 'was not read'; then pass "C84 probe printed nothing -> WARN UNREADABLE"; else fail "C84 empty probe -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: control, jq missing (state cannot be judged) -> OK row with its note =="
c84_nojq="$c84_t/nojq-bin"; mkdir -p "$c84_nojq"
for c84_f in /usr/bin/*; do
    [ "${c84_f##*/}" = jq ] || { [ ! -x "$c84_f" ] || ln -s "$c84_f" "$c84_nojq/${c84_f##*/}" 2>/dev/null; }
done
if PATH="$c84_nojq" bash -c 'command -v bash >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1' 2>/dev/null; then
    out="$(PATH="$c84_nojq" c84_run)"
    if grepq "$out" 'OK   C84-release-queue' && grepq "$out" -F 'was not read'; then pass "C84 jq missing -> OK with the not-read note"; else fail "C84 jq missing -> $(printf '%s' "$out" | head -4)"; fi
else
    echo "  SKIP: C84 no-jq — the curated shadow PATH cannot run bash without jq here, so the fixture cannot be built"
fi
echo "== C84-release-queue: the default handover root comes from --root, not the working directory =="
c84_p="$c84_t/proj"; mkdir -p "$c84_p/handovers/u/himmel/release/R1" "$c84_t/elsewhere"
git init -q "$c84_p"
ln -s "$REPO_ROOT/scripts" "$c84_p/scripts"  # the doctor sources its libs from the --root checkout
printf '{"name":"R1"}\n' > "$c84_p/handovers/u/himmel/release/R1/release.json"
printf '# chief\n## Live state\nrelease: R1\n' > "$c84_p/handovers/u/himmel/X-chief.md"
out="$(cd "$c84_t/elsewhere" && env -u HANDOVER_DIR -u HIMMEL_RELEASE_STATE_DIR HIMMEL_DOCTOR_RM_STATE_PROBE="$c84_t/probe" CLAUDE_DIR="$c84_t/claude" HOME="$c84_t/home" bash "$DOC" --root "$c84_p" --only C84 --no-color 2>&1)"
if grepq "$out" 'OK   C84-release-queue'; then pass "C84 finds the --root checkout's declaration from a non-git working directory"; else fail "C84 --root default -> $(printf '%s' "$out" | head -4)"; fi
echo "== C84-release-queue: run from another repo's directory it reads the same as from the checkout =="
mkdir -p "$c84_t/away"; git init -q "$c84_t/away"
c84_from() { local o; o="$(cd "$1" && env -u HANDOVER_DIR -u HIMMEL_RELEASE_STATE_DIR -u HIMMEL_REPO HIMMEL_DOCTOR_RM_STATE_PROBE="$c84_t/probe" CLAUDE_DIR="$c84_t/claude" HOME="$c84_t/home" bash "$DOC" --root "$c84_p" --only C84 --no-color 2>&1)"; sed -n '/C84-release-queue/p' <<< "$o"; }
c84_home="$(c84_from "$c84_p")"; c84_away="$(c84_from "$c84_t/away")"
if grepq "$c84_home" 'OK   C84-release-queue' && [ "$c84_away" = "$c84_home" ]; then pass "C84 from another repo's directory reads the same OK row as from the checkout"; else fail "C84 away vs checkout -> away: $c84_away / checkout: $c84_home"; fi
echo "== C84-release-queue: disabled controls (release: none; nothing declared) -> INFO, never WARN =="
c84_doc "release: none"
out="$(c84_run)"
if grepq "$out" 'INFO C84-release-queue' && grepq "$out" -F 'none' && ! grepq "$out" 'WARN C84-release-queue'; then pass "C84 release: none -> INFO"; else fail "C84 none -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c84_t/h/release/R1"
c84_doc "epics: none"
out="$(c84_run)"
if grepq "$out" 'INFO C84-release-queue' && ! grepq "$out" 'WARN C84-release-queue'; then pass "C84 nothing declared -> INFO"; else fail "C84 nothing declared -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c84_t"

# --- C50-qmd-fork-stamp: build stamp vs deployed HEAD vs pin ------
# Fixture fork clone (a throwaway git repo: commit A older, B newer), a fixture
# stamp file and a fixture QMD_FORK_REF; the live station fork is never read.
c50_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c50.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c50_t/fork" "$c50_t/home" "$c50_t/claude"
git -C "$c50_t/fork" init -q
git -C "$c50_t/fork" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
c50_a="$(git -C "$c50_t/fork" rev-parse HEAD)"
git -C "$c50_t/fork" -c user.name=t -c user.email=t@t commit -q --allow-empty -m b
c50_b="$(git -C "$c50_t/fork" rev-parse HEAD)"
c50_run() { # <stamp content, empty = no stamp> <pin> [fork dir]
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$c50_t/fork/.himmel-build-ok"; else rm -f "$c50_t/fork/.himmel-build-ok"; fi
    QMD_FORK_DIR="${3:-$c50_t/fork}" QMD_FORK_REF="$2" PATH="$FAKEBIN:$PATH" \
        CLAUDE_DIR="$c50_t/claude" HOME="$c50_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C50-qmd-fork-stamp: stamp == HEAD == pin -> OK (RED) =="
out="$(c50_run "$c50_b" "$c50_b")"
if grepq "$out" 'OK   C50-qmd-fork-stamp'; then pass "C50 all three agree -> OK"; else fail "C50 agree -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: abbreviated pin naming HEAD -> OK, not drift =="
out="$(c50_run "$c50_b" "${c50_b:0:10}")"
if grepq "$out" 'OK   C50-qmd-fork-stamp'; then pass "C50 short pin == HEAD -> OK"; else fail "C50 short pin -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: stamp != HEAD -> WARN stale build =="
out="$(c50_run "$c50_a" "$c50_b")"
if grepq "$out" 'WARN C50-qmd-fork-stamp' && grepq "$out" -i 'stale build'; then pass "C50 stale build -> WARN"; else fail "C50 stale -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: HEAD ahead of the pin -> WARN names HEAD ahead =="
out="$(c50_run "$c50_b" "$c50_a")"
if grepq "$out" 'WARN C50-qmd-fork-stamp' && grepq "$out" -F 'HEAD is ahead of the pin'; then pass "C50 HEAD ahead -> WARN"; else fail "C50 head ahead -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: pin ahead of HEAD -> WARN names pin ahead =="
git -C "$c50_t/fork" checkout -q "$c50_a"
out="$(c50_run "$c50_a" "$c50_b")"
if grepq "$out" 'WARN C50-qmd-fork-stamp' && grepq "$out" -F 'pin is ahead of HEAD'; then pass "C50 pin ahead -> WARN"; else fail "C50 pin ahead -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: read-only (HEAD and stamp unchanged by the check) =="
if [ "$(git -C "$c50_t/fork" rev-parse HEAD)" = "$c50_a" ] && [ "$(cat "$c50_t/fork/.himmel-build-ok")" = "$c50_a" ]; then pass "C50 read-only"; else fail "C50 mutated the fork"; fi

echo "== C50-qmd-fork-stamp: no stamp -> WARN, no crash =="
out="$(c50_run '' "$c50_a")"
if grepq "$out" 'WARN C50-qmd-fork-stamp' && grepq "$out" -i 'no build stamp'; then pass "C50 missing stamp -> WARN"; else fail "C50 no stamp -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: no fork clone -> WARN, no crash =="
out="$(c50_run "$c50_b" "$c50_b" "$c50_t/absent")"
if grepq "$out" 'WARN C50-qmd-fork-stamp' && grepq "$out" -i 'no qmd fork'; then pass "C50 missing fork -> WARN"; else fail "C50 no fork -> $(printf '%s' "$out" | grep -A1 C50)"; fi

echo "== C50-qmd-fork-stamp: --json carries the row =="
c50_json="$(QMD_FORK_DIR="$c50_t/fork" QMD_FORK_REF="$c50_a" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c50_t/claude" HOME="$c50_t/home" bash "$DOC" --json 2>/dev/null)"
if grepq "$c50_json" 'C50-qmd-fork-stamp'; then pass "C50 in --json"; else fail "C50 not in --json"; fi
rm -rf "$c50_t"

# --- /: C41 operator ack, C22 fixture exclusion, C19 desired gate, C21 record ---
n_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-n1200.XXXXXX")" || { fail "N1200 setup: mktemp -d failed"; exit 1; }
mkdir -p "$n_t/home" "$n_t/root" "$n_t/claude"
cat > "$n_t/home/.claude.json" <<'EOF'
{"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp","--api-key","NOT-A-REAL-VALUE-zq81x"]},"other":{"command":"npm","args":["exec","x","--","--api-key","NOT-A-REAL-VALUE-q9"]}}}
EOF
printf '# operator acks\nC41-mcp-argv-key context7\n' > "$n_t/ack.txt"

echo "== C41 ack: acknowledged server reports INFO, an unacknowledged one still WARNs, value withheld =="
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_ACK_FILE="$n_t/ack.txt" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C41-mcp-argv-key.*context7.*acknowledged' && ! grepq "$out" "WARN C41-mcp-argv-key.*'context7'" \
    && grepq "$out" "WARN C41-mcp-argv-key.*'other'" && ! grepq "$out" -F 'NOT-A-REAL-VALUE'; then
    pass "C41 ack -> INFO for the acked server only"
else
    fail "C41 ack -> $(printf '%s' "$out" | grep C41)"
fi

echo "== C22: fixture-only chain members (hang/hog/flood) -> no WARN =="
cat > "$n_t/skips-fixture.jsonl" <<'EOF'
{"action":"skip","member":"hang.sh","reason":"ETIMEDOUT"}
{"action":"skip","member":"hang2.sh","reason":"ETIMEDOUT"}
{"action":"skip","member":"hog3.sh","reason":"ETIMEDOUT"}
{"action":"skip","member":"flood.sh","reason":"ENOBUFS"}
{"action":"skip","member":"/x/scripts/hooks/test/fixtures/slow.sh","reason":"ETIMEDOUT"}
EOF
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-fixture.jsonl" bash "$DOC" --no-color 2>&1)"
if ! grepq "$out" 'WARN C22-chain-skips' && grepq "$out" 'C22-chain-skips'; then pass "C22 fixture-only -> no WARN"; else fail "C22 fixture-only -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: fixtures + a real member -> WARN names only the real member =="
cp "$n_t/skips-fixture.jsonl" "$n_t/skips-mixed.jsonl"
printf '%s\n' '{"action":"skip","member":"block-read-secrets.sh","reason":"ETIMEDOUT"}' >> "$n_t/skips-mixed.jsonl"
printf '%s\n' '{"action":"skip","member":"/home/test/himmel/scripts/hooks/real-guard.sh","reason":"ETIMEDOUT"}' >> "$n_t/skips-mixed.jsonl"
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-mixed.jsonl" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C22-chain-skips.*block-read-secrets.sh' && grepq "$out" 'WARN C22-chain-skips.*real-guard.sh' && ! grepq "$out" -E 'WARN C22-chain-skips.*(hang|hog|flood)'; then pass "C22 mixed -> real member only"; else fail "C22 mixed -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: old-only log -> OK naming the window and the all-time count (HIMMEL-4721) =="
printf '%s\n' '{"ts":"2020-01-01T00:00:00.000Z","action":"skip","member":"block-read-secrets.sh","reason":"ETIMEDOUT"}' \
    '{"ts":"2020-01-02T00:00:00.000Z","action":"skip","member":"block-read-secrets.sh","reason":"ETIMEDOUT"}' > "$n_t/skips-old.jsonl"
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-old.jsonl" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK  *C22-chain-skips.*24 h.*2 older' && ! grepq "$out" 'WARN C22-chain-skips'; then pass "C22 old-only -> OK"; else fail "C22 old-only -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: a recent starved row -> WARN; an old row beside it is not counted =="
now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat "$n_t/skips-old.jsonl" > "$n_t/skips-recent.jsonl"
printf '{"ts":"%s","action":"skip","member":"recent-guard.sh","reason":"ETIMEDOUT"}\n' "$now_iso" >> "$n_t/skips-recent.jsonl"
out="$(PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-recent.jsonl" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C22-chain-skips.*recent-guard.sh' && ! grepq "$out" 'WARN C22-chain-skips.*block-read-secrets.sh'; then pass "C22 recent -> WARN (recent row only)"; else fail "C22 recent -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: default log path follows a moved ledgers.json default_path (HIMMEL-4338) =="
mkdir -p "$n_t/home/moved"
cp "$n_t/skips-recent.jsonl" "$n_t/home/moved/skips.jsonl"
jq '(.ledgers[] | select(.id == "hook-chain-skips") | .default_path) = "~/moved/skips.jsonl"' "$REPO_ROOT/scripts/observability/ledgers.json" > "$n_t/ledgers-moved.json"
out="$(env -u HIMMEL_DOCTOR_CHAIN_SKIPS_LOG PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_LEDGERS_JSON="$n_t/ledgers-moved.json" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C22-chain-skips.*recent-guard.sh'; then pass "C22 follows the registry path"; else fail "C22 registry path -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: window is env-overridable =="
out="$(HIMMEL_DOCTOR_CHAIN_SKIPS_WINDOW_H=999999 PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-old.jsonl" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C22-chain-skips.*block-read-secrets.sh'; then pass "C22 wide window -> old rows count again"; else fail "C22 wide window -> $(printf '%s' "$out" | grep C22)"; fi

echo "== C22: a leading-zero window (08) is decimal, not invalid octal (HIMMEL-4724) =="
out="$(HIMMEL_DOCTOR_CHAIN_SKIPS_WINDOW_H=08 PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" HIMMEL_DOCTOR_CHAIN_SKIPS_LOG="$n_t/skips-old.jsonl" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK  *C22-chain-skips.* 8 h.*2 older' && ! grepq "$out" -F 'value too great'; then pass "C22 window 08 -> 8 h"; else fail "C22 window 08 -> $(printf '%s' "$out" | grep -E 'C22|value too great')"; fi

echo "== C19: observability not desired on this host -> INFO, no WARN =="
printf '%s\n' '{"items":[{"id":"observability-stack","desired":true,"severity":"n/a"},{"id":"observability-grafana","desired":false,"severity":"n/a"}]}' > "$n_t/status-na.json"
out="$(DOCTOR_OBSERVABILITY_DESIRED="" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_STATUS_JSON="$n_t/status-na.json" DOCTOR_OBSERVABILITY_INSTALL_DIR="$n_t/none" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C19-observability.*not desired' && ! grepq "$out" 'WARN C19-observability'; then pass "C19 not desired -> INFO"; else fail "C19 not desired -> $(printf '%s' "$out" | grep C19)"; fi

echo "== C19: observability desired and applicable -> checks still run (WARN on missing install) =="
printf '%s\n' '{"items":[{"id":"observability-grafana","desired":true,"severity":"red"}]}' > "$n_t/status-on.json"
out="$(DOCTOR_OBSERVABILITY_DESIRED="" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_STATUS_JSON="$n_t/status-on.json" DOCTOR_OBSERVABILITY_INSTALL_DIR="$n_t/none" DOCTOR_CURL_BIN="$n_t/nocurl" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C19-observability.*stack stale'; then pass "C19 desired -> checks run"; else fail "C19 desired -> $(printf '%s' "$out" | grep C19)"; fi

echo "== C19: malformed status payload -> unreadable INFO, never 'not desired' =="
printf '%s\n' '{"items":"nope"}' > "$n_t/status-bad.json"
out="$(DOCTOR_OBSERVABILITY_DESIRED="" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_STATUS_JSON="$n_t/status-bad.json" DOCTOR_OBSERVABILITY_INSTALL_DIR="$n_t/none" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C19-observability.*unreadable' && ! grepq "$out" 'not desired on this host'; then pass "C19 malformed status -> unreadable INFO"; else fail "C19 malformed status -> $(printf '%s' "$out" | grep C19)"; fi

echo "== C19 (HIMMEL-4289): observability-grafana desired -> user-mode install dir, plain prometheus.yml copy, no Telegram check =="
printf '%s\n' '{"items":[{"id":"observability-grafana","desired":true,"severity":"red"}]}' > "$n_t/status-graf.json"
mkdir -p "$n_t/gi/dashboards" "$n_t/gbin" "$n_t/xdg-none" "$n_t/xdg-ok/himmel"
cp "$REPO_ROOT/scripts/observability/prometheus.yml" "$n_t/gi/prometheus.yml"
cp "$REPO_ROOT/scripts/observability/alerts.rules.yml" "$n_t/gi/alerts.rules.yml"
cp "$REPO_ROOT/scripts/observability/dashboards/"*.json "$n_t/gi/dashboards/"
cp -R "$n_t/gi" "$n_t/xdg-ok/himmel/observability"
cat > "$n_t/gbin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[{"name":"himmel-observability"}]}}' ;;
  *:9877/metrics) printf '%s\n' 'flow_run_outcome_total 1' ;;
  *:3000/api/health) printf '%s\n' '{"database":"ok"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$n_t/gbin/curl"
c19g() {
    HIMMEL_DOCTOR_ROOT="$REPO_ROOT" DOCTOR_OBSERVABILITY_DESIRED="" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_STATUS_JSON="$n_t/status-graf.json" XDG_DATA_HOME="$1" DOCTOR_CURL_BIN="$n_t/gbin/curl" \
        GRAFANA_TELEGRAM_BOT_TOKEN="" GRAFANA_TELEGRAM_CHAT_ID="" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$n_t/claude" HOME="$n_t/home" HIMMEL_DOCTOR_MCP_ROOT="$n_t/root" bash "$DOC" --no-color 2>&1
}
out="$(c19g "$n_t/xdg-none")"
if grepq "$out" 'WARN C19-observability.*install-grafana.sh' && ! grepq "$out" 'install-stack.ps1' && ! grepq "$out" 'Telegram delivery'; then
    pass "C19 grafana, not installed -> WARN names install-grafana.sh, no Telegram/ps1 text"
else
    fail "C19 grafana not installed -> $(printf '%s' "$out" | grep C19)"
fi
out="$(c19g "$n_t/xdg-ok")"
if grepq "$out" 'C19-observability.*installed observability assets match' && ! grepq "$out" 'WARN C19-observability' && ! grepq "$out" 'Telegram delivery'; then
    pass "C19 grafana, matching install under XDG_DATA_HOME -> all OK"
else
    fail "C19 grafana matching -> $(printf '%s' "$out" | grep C19)"
fi
printf 'drift\n' >> "$n_t/xdg-ok/himmel/observability/dashboards/himmel-health.json"
out="$(c19g "$n_t/xdg-ok")"
if grepq "$out" 'WARN C19-observability.*drift:.*dashboards/'; then pass "C19 grafana drifted dashboard -> WARN names dashboards/"; else fail "C19 grafana drift -> $(printf '%s' "$out" | grep C19)"; fi

echo "== C21 record: lanes.json hermes rows match the live hermes profile default =="
c21_rows="$(jq -r '[.lanes[] | select(.id=="hermes-oneshot" or .id=="hermes-critics") | .profileDefaultModel] | unique | join(",")' "$REPO_ROOT/scripts/lanes/lanes.json")"
if [ "$c21_rows" = "gpt-6.1-sol" ]; then pass "C21 rows record gpt-6.1-sol"; else fail "C21 rows -> '$c21_rows'"; fi
rm -rf "$n_t"

rm -rf "$HIMMEL_DOCTOR_NOOP_HANDOVER"

rm -rf "$FAKEROOT"
# r4-codex-4: HIMMEL_DOCTOR_PROC_BASE (the C29 procfs-absent hermeticity
# seam) was created near the top of this file and never removed, leaking a
# temp dir per run - cleaned up here alongside FAKEROOT, this file's own
# established end-of-run cleanup convention (it has no EXIT trap).
rm -rf "$HIMMEL_DOCTOR_PROC_BASE"
# Same reasoning for HIMMEL_DOCTOR_SYSTEMCTL_BASE:
# templated like HIMMEL_DOCTOR_PROC_BASE above, so it gets the same
# cleanup.
rm -rf "$HIMMEL_DOCTOR_SYSTEMCTL_BASE"
echo
# --- C51-firecrawl-parked: parked items + unavailable status ------
c51_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c51.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c51_t/home" "$c51_t/claude" "$c51_t/vault"
: > "$c51_t/vault/a.md"
c51_row() { printf '{"v":1,"ts":"2026-10-04T00:00:00Z","host":"h","source":"t","kind":"%s",%s}\n' "$1" "$2"; }
c51_run() { # <state file>
    HIMMEL_FIRECRAWL_PARKED="$1" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c51_t/claude" HOME="$c51_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C51-firecrawl-parked: no state file -> OK (RED) =="
out="$(c51_run "$c51_t/none.jsonl")"
if grepq "$out" 'OK   C51-firecrawl-parked'; then pass "C51 no state -> OK"; else fail "C51 no state -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: unavailable + parked item -> WARN naming count, reason, reset, remedy =="
{ c51_row unavailable '"call_site":"harvest-clip-body-batch","reason":"exhausted","reset":"2099-01-01T00:00:00Z"'
  c51_row parked "\"call_site\":\"harvest-clip-body-batch\",\"vault\":\"$c51_t/vault\",\"item\":\"a.md\",\"reason\":\"exhausted\""; } > "$c51_t/s1.jsonl"
out="$(c51_run "$c51_t/s1.jsonl")"
if grepq "$out" 'WARN C51-firecrawl-parked' && grepq "$out" -F '1 item' && grepq "$out" -F 'exhausted' \
   && grepq "$out" -F 'parked items retry automatically on the next harvest once credits return (reset 2099-01-01'; then
    pass "C51 parked -> WARN with remedy"
else fail "C51 parked -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: 429 without a reset -> WARN says reset unknown =="
{ c51_row unavailable '"call_site":"harvest-clip-body-batch","reason":"rate-limited","reset":null'
  c51_row parked "\"call_site\":\"harvest-clip-body-batch\",\"vault\":\"$c51_t/vault\",\"item\":\"a.md\",\"reason\":\"rate-limited\""; } > "$c51_t/s2.jsonl"
out="$(c51_run "$c51_t/s2.jsonl")"
if grepq "$out" 'WARN C51-firecrawl-parked' && grepq "$out" -F '(reset unknown)'; then pass "C51 no reset -> unknown"; else fail "C51 429 -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: resolved item -> OK =="
{ cat "$c51_t/s1.jsonl"
  c51_row resolved "\"call_site\":\"harvest-clip-body-batch\",\"vault\":\"$c51_t/vault\",\"item\":\"a.md\",\"via\":\"jina\""
  c51_row available '"call_site":"harvest-clip-body-batch"'; } > "$c51_t/s3.jsonl"
out="$(c51_run "$c51_t/s3.jsonl")"
if grepq "$out" 'OK   C51-firecrawl-parked'; then pass "C51 resolved -> OK"; else fail "C51 resolved -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: default state path follows a moved ledgers.json default_path (HIMMEL-4338) =="
mkdir -p "$c51_t/home/moved"
cp "$c51_t/s1.jsonl" "$c51_t/home/moved/parked.jsonl"
jq '(.ledgers[] | select(.id == "firecrawl-parked") | .default_path) = "~/moved/parked.jsonl"' "$REPO_ROOT/scripts/observability/ledgers.json" > "$c51_t/ledgers-moved.json"
out="$(env -u HIMMEL_FIRECRAWL_PARKED HIMMEL_LEDGERS_JSON="$c51_t/ledgers-moved.json" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c51_t/claude" HOME="$c51_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C51-firecrawl-parked'; then pass "C51 follows the registry path"; else fail "C51 registry path -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: unreadable registry -> INFO, not a healthy OK =="
out="$(env -u HIMMEL_FIRECRAWL_PARKED HIMMEL_LEDGERS_JSON="$c51_t/no-such-registry.json" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c51_t/claude" HOME="$c51_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C51-firecrawl-parked.*registry unreadable'; then pass "C51 unreadable registry -> INFO"; else fail "C51 unreadable registry -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: parked item whose file is gone -> not counted =="
{ c51_row parked "\"call_site\":\"harvest-clip-body-batch\",\"vault\":\"$c51_t/vault\",\"item\":\"gone.md\",\"reason\":\"exhausted\""; } > "$c51_t/s4.jsonl"
out="$(c51_run "$c51_t/s4.jsonl")"
if grepq "$out" 'OK   C51-firecrawl-parked'; then pass "C51 gone file -> OK"; else fail "C51 gone -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: unavailable only, reset date passed -> OK =="
c51_row unavailable '"call_site":"harvest-clip-body-batch","reason":"exhausted","reset":"2020-01-01T00:00:00Z"' > "$c51_t/s5.jsonl"
out="$(c51_run "$c51_t/s5.jsonl")"
if grepq "$out" 'OK   C51-firecrawl-parked'; then pass "C51 reset passed -> OK"; else fail "C51 passed reset -> $(printf '%s' "$out" | grep -A1 C51)"; fi

echo "== C51-firecrawl-parked: follow-web parked query -> WARN =="
{ c51_row unavailable '"call_site":"follow-web","reason":"exhausted","reset":null'
  c51_row parked '"call_site":"follow-web","vault":null,"item":"0123456789ab","reason":"exhausted"'; } > "$c51_t/s6.jsonl"
out="$(c51_run "$c51_t/s6.jsonl")"
if grepq "$out" 'WARN C51-firecrawl-parked'; then pass "C51 follow-web parked -> WARN"; else fail "C51 follow-web -> $(printf '%s' "$out" | grep -A1 C51)"; fi
rm -rf "$c51_t"

# --- C52-graphify-ollama: the uv graphifyy venv must import openai
# (the [ollama] extra graph-cadence's semantic step needs). Seam:
# HIMMEL_DOCTOR_GRAPHIFY_VENV points at a fixture venv whose bin/python exits 0/1.
c52_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c52.XXXXXX")" || { fail "C52 setup: mktemp -d failed"; exit 1; }
mkdir -p "$c52_t/ok/bin" "$c52_t/missing/bin"
printf '#!/bin/sh\nexit 0\n' > "$c52_t/ok/bin/python"
printf '#!/bin/sh\nexit 1\n' > "$c52_t/missing/bin/python"
chmod +x "$c52_t/ok/bin/python" "$c52_t/missing/bin/python"
c52_run() { # <venv dir>
    GRAPH_CADENCE_SEMANTIC_BACKEND="${C52_BACKEND:-ollama}" HIMMEL_DOCTOR_GRAPHIFY_VENV="$1" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c52_t/claude" HOME="$c52_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C52-graphify-ollama: default backend (claude-cli) + missing extra -> OK, never WARN (HIMMEL-5367) =="
out="$(C52_BACKEND=claude-cli c52_run "$c52_t/missing")"
if grepq "$out" 'OK   C52-graphify-ollama' && ! grepq "$out" 'WARN C52-graphify-ollama'; then pass "C52 claude-cli backend -> OK"; else fail "C52 claude-cli -> $(printf '%s' "$out" | grep -A1 C52)"; fi

echo "== C52-graphify-ollama: claude-api and its api alias -> OK skip (HIMMEL-7644), never the not-accepted WARN =="
for c52_b in claude-api api; do
    out="$(C52_BACKEND=$c52_b c52_run "$c52_t/missing")"
    if grepq "$out" 'OK   C52-graphify-ollama' && grepq "$out" -F 'claude-api' && ! grepq "$out" 'WARN C52-graphify-ollama'; then pass "C52 $c52_b backend -> OK skip"; else fail "C52 $c52_b -> $(printf '%s' "$out" | grep -A1 C52)"; fi
done

echo "== C52-graphify-ollama: unaccepted backend -> WARN naming the variable, remedy lists claude-api, not a claude-cli OK =="
out="$(C52_BACKEND=bogus c52_run "$c52_t/ok")"
if grepq "$out" 'WARN C52-graphify-ollama' && grepq "$out" -F "GRAPH_CADENCE_SEMANTIC_BACKEND='bogus'" && grepq "$out" -F 'claude-cli, claude-api or ollama' && ! grepq "$out" 'OK   C52-graphify-ollama'; then pass "C52 unaccepted backend -> WARN"; else fail "C52 bogus -> $(printf '%s' "$out" | grep -A1 C52)"; fi

echo "== C52-graphify-ollama: no graphifyy venv -> OK (skipped) =="
out="$(c52_run "$c52_t/absent")"
if grepq "$out" 'OK   C52-graphify-ollama' && ! grepq "$out" 'WARN C52-graphify-ollama'; then pass "C52 absent venv -> OK"; else fail "C52 absent -> $(printf '%s' "$out" | grep -A1 C52)"; fi

echo "== C52-graphify-ollama: venv cannot import openai -> WARN + update remedy =="
out="$(c52_run "$c52_t/missing")"
if grepq "$out" 'WARN C52-graphify-ollama' && grepq "$out" -F 'bash scripts/himmel-update.sh --only graphify'; then pass "C52 missing extra -> WARN with remedy"; else fail "C52 missing -> $(printf '%s' "$out" | grep -A1 C52)"; fi

echo "== C52-graphify-ollama: venv imports openai -> OK =="
out="$(c52_run "$c52_t/ok")"
if grepq "$out" 'OK   C52-graphify-ollama' && ! grepq "$out" 'WARN C52-graphify-ollama'; then pass "C52 extra present -> OK"; else fail "C52 present -> $(printf '%s' "$out" | grep -A1 C52)"; fi
rm -rf "$c52_t"

# --- C53-vm-mode: the mode, and a read-only reachability probe ----
c53_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c53.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c53_t/home/.himmel" "$c53_t/claude"
# shellcheck disable=SC2016  # $1 $2 expand in the probe stub
printf '#!/bin/sh\necho "$1 $2" >> "%s/probe.log"\nexit 0\n' "$c53_t" > "$c53_t/up"
# shellcheck disable=SC2016  # $1 $2 expand in the probe stub
printf '#!/bin/sh\necho "$1 $2" >> "%s/probe.log"\nexit 1\n' "$c53_t" > "$c53_t/down"
chmod +x "$c53_t/up" "$c53_t/down"
# A stub ssh: the operator's real ssh would read their real
# ~/.ssh/config. It answers only -G, from $c53_t/ssh-g.out when that is set,
# else as an empty config would; any other call is logged and fails, and -G
# itself fails while $c53_t/ssh-g.fail exists.
mkdir -p "$c53_t/bin"
cat > "$c53_t/bin/ssh" <<STUB
#!/bin/sh
echo "\$*" >> "$c53_t/ssh.log"
[ "\$1" = -G ] || exit 255
[ -e "$c53_t/ssh-g.fail" ] && exit 255
[ -s "$c53_t/ssh-g.out" ] && { cat "$c53_t/ssh-g.out"; exit 0; }
port=22
while [ \$# -gt 1 ]; do [ "\$1" = -p ] && { port=\$2; shift; }; shift; done
printf 'user x\nhostname %s\nport %s\n' "\${1#*@}" "\$port"
STUB
chmod +x "$c53_t/bin/ssh"
# A stub timeout: macOS ships none, and the alias rows must not depend on the
# host having coreutils. It drops the duration and runs the rest.
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$c53_t/bin/timeout"
chmod +x "$c53_t/bin/timeout"
c53_run() { # <config json> <probe>
    printf '%s\n' "$1" > "$c53_t/home/.himmel/config.json"; : > "$c53_t/probe.log"; : > "$c53_t/ssh.log"
    HIMMEL_DOCTOR_VM_PROBE="$2" PATH="$c53_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c53_t/claude" HOME="$c53_t/home" bash "$DOC" --no-color 2>&1
}

echo "== C53-vm-mode: unset -> local, probes localhost:2222, reachable -> OK (RED) =="
out="$(c53_run '{}' "$c53_t/up")"
if grepq "$out" 'OK   C53-vm-mode' && grepq "$out" -F 'vm.mode=local' && grepq "$(cat "$c53_t/probe.log")" -Fx 'localhost 2222' && [ ! -s "$c53_t/ssh.log" ]; then pass "C53 local reachable -> OK"; else fail "C53 local up -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log")"; fi

echo "== C53-vm-mode: local unreachable -> INFO (the local VM starts on demand) =="
out="$(c53_run '{"vm":{"mode":"local"}}' "$c53_t/down")"
if grepq "$out" 'INFO C53-vm-mode' && grepq "$out" -F 'not reachable'; then pass "C53 local down -> INFO"; else fail "C53 local down -> $(printf '%s' "$out" | grep -A1 C53)"; fi

echo "== C53-vm-mode: remote unreachable -> WARN naming the host, probe gets the bare host =="
out="$(c53_run '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example","port":2201}}}' "$c53_t/down")"
if grepq "$out" 'WARN C53-vm-mode' && grepq "$out" -F 'ops@vm.example:2201' && grepq "$(cat "$c53_t/probe.log")" -Fx 'vm.example 2201'; then pass "C53 remote down -> WARN"; else fail "C53 remote down -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log")"; fi

echo "== C53-vm-mode: an ssh config alias -> the probe gets ssh -G's HostName and port (HIMMEL-4599) =="
printf 'user ops\nhostname vm.internal.example\nport 2201\n' > "$c53_t/ssh-g.out"
out="$(c53_run '{"vm":{"mode":"remote","remote":{"ssh":"ops@vmalias","port":2201}}}' "$c53_t/up")"
if grepq "$out" 'OK   C53-vm-mode' && grepq "$(cat "$c53_t/probe.log")" -Fx 'vm.internal.example 2201' && grepq "$(cat "$c53_t/ssh.log")" -Fx -- '-G -p 2201 ops@vmalias' && [ "$(wc -l < "$c53_t/ssh.log")" -eq 1 ]; then pass "C53 alias -> probes the resolved HostName, ssh only ever -G"; else fail "C53 alias -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log") ssh=$(cat "$c53_t/ssh.log")"; fi

echo "== C53-vm-mode: no GNU 'timeout' (macOS) -> falls back to gtimeout, still resolves the alias (HIMMEL-4981) =="
printf '#!/bin/sh\necho used >> "%s/gtimeout.log"\nshift\nexec "$@"\n' "$c53_t" > "$c53_t/bin/gtimeout"
chmod +x "$c53_t/bin/gtimeout"
: > "$c53_t/gtimeout.log"
export HIMMEL_DOCTOR_TIMEOUT_BINS="no-such-timeout gtimeout"
out="$(c53_run '{"vm":{"mode":"remote","remote":{"ssh":"ops@vmalias","port":2201}}}' "$c53_t/up")"
unset HIMMEL_DOCTOR_TIMEOUT_BINS
if grepq "$out" 'OK   C53-vm-mode' && grepq "$(cat "$c53_t/probe.log")" -Fx 'vm.internal.example 2201' && [ -s "$c53_t/gtimeout.log" ]; then pass "C53 gtimeout fallback -> alias resolved"; else fail "C53 gtimeout fallback -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log") gt=$(cat "$c53_t/gtimeout.log")"; fi

echo "== C53-vm-mode: ProxyJump / ProxyCommand -> INFO, not an unreachable WARN, no TCP probe (HIMMEL-4599) =="
for proxy in 'proxyjump bastion' 'proxycommand ssh -W %h:%p bastion'; do
    printf 'user ops\nhostname vm.internal\nport 22\n%s\n' "$proxy" > "$c53_t/ssh-g.out"
    out="$(c53_run '{"vm":{"mode":"remote","remote":{"ssh":"ops@vmalias"}}}' "$c53_t/down")"
    if grepq "$out" 'INFO C53-vm-mode' && ! grepq "$out" 'WARN C53-vm-mode' && grepq "$out" -F "${proxy%% *}" && [ ! -s "$c53_t/probe.log" ]; then pass "C53 ${proxy%% *} -> INFO, no probe"; else fail "C53 ${proxy%% *} -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log")"; fi
done
rm -f "$c53_t/ssh-g.out"

echo "== C53-vm-mode: ssh -G fails -> INFO saying so, not an unreachable WARN, probe gets the host as written (HIMMEL-4631) =="
: > "$c53_t/ssh-g.fail"
out="$(c53_run '{"vm":{"mode":"remote","remote":{"ssh":"ops@vmalias","port":2201}}}' "$c53_t/down")"
if grepq "$out" 'INFO C53-vm-mode' && ! grepq "$out" 'WARN C53-vm-mode' && grepq "$out" -F 'ssh -G failed, probed the configured host as written' && grepq "$(cat "$c53_t/probe.log")" -Fx 'vmalias 2201'; then pass "C53 ssh -G fails -> INFO naming the failed lookup"; else fail "C53 ssh -G fails -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log")"; fi
rm -f "$c53_t/ssh-g.fail"

echo "== C53-vm-mode: none -> INFO, holds need an operator ack, no probe =="
out="$(c53_run '{"vm":{"mode":"none"}}' "$c53_t/up")"
if grepq "$out" 'INFO C53-vm-mode' && grepq "$out" -F 'operator ack' && [ ! -s "$c53_t/probe.log" ]; then pass "C53 none -> INFO, no probe"; else fail "C53 none -> $(printf '%s' "$out" | grep -A1 C53) probe=$(cat "$c53_t/probe.log")"; fi

echo "== C53-vm-mode: invalid config -> WARN with the resolver's note =="
out="$(c53_run '{"vm":{"mode":"cloud"}}' "$c53_t/up")"
if grepq "$out" 'WARN C53-vm-mode' && grepq "$out" -F 'is not local|remote|none'; then pass "C53 invalid -> WARN"; else fail "C53 invalid -> $(printf '%s' "$out" | grep -A1 C53)"; fi
rm -rf "$c53_t"

# --- C55-project-mode: the resolver's tracker/forge ---
# The row reads scripts/lib/project-mode.sh in the judged checkout; it never
# re-derives the mode. A fixture repo carries a copy of the resolver.
c55_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c55.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c55_t/repo/scripts/lib" "$c55_t/home"
cp "$REPO_ROOT/scripts/lib/project-mode.sh" "$c55_t/repo/scripts/lib/project-mode.sh"
git -C "$c55_t/repo" init -q
git -C "$c55_t/repo" config himmel.tracker local
c55_run() { (cd "$c55_t/repo" && env -u TRACKER -u FORGE -u JIRA_PROJECT_KEY -u TICKET_ID_REQUIRED -u TICKET_ID_PATTERN "$@" HIMMEL_REPO="$c55_t/repo" HIMMEL_DOCTOR_ROOT="$c55_t/repo" CLAUDE_DIR="$c55_t/home/claude" HOME="$c55_t/home" DOCTOR_OBSERVABILITY_SKIP=1 bash "$DOC" --no-color 2>/dev/null); }

echo "== C55-project-mode: himmel.tracker=local, no origin -> OK tracker=local forge=local-git (RED) =="
out="$(c55_run)"
if grepq "$out" -F 'OK   C55-project-mode: tracker=local forge=local-git'; then pass "C55 local/local-git -> OK"; else fail "C55 local/local-git -> $(printf '%s' "$out" | grep -A1 C55)"; fi

echo "== C55-project-mode: tracker=none -> OK, says no ticket ID is required =="
out="$(c55_run TRACKER=none)"
if grepq "$out" -F 'OK   C55-project-mode: tracker=none forge=local-git' && grepq "$out" -F 'ticket ID not required'; then pass "C55 none -> OK, ID not required"; else fail "C55 none -> $(printf '%s' "$out" | grep -A1 C55)"; fi

echo "== C55-project-mode: an invalid setting -> WARN carrying the resolver's message =="
out="$(c55_run TRACKER=bogus)"
if grepq "$out" -F 'WARN C55-project-mode' && grepq "$out" -F "invalid TRACKER='bogus'" && grepq "$out" -F 'docs/configuration.md'; then pass "C55 invalid -> WARN"; else fail "C55 invalid -> $(printf '%s' "$out" | grep -A1 C55)"; fi

echo "== C55-project-mode: a checkout without the resolver -> no row =="
rm -f "$c55_t/repo/scripts/lib/project-mode.sh"
out="$(c55_run)"
if ! grepq "$out" -F 'C55-project-mode'; then pass "C55 no resolver -> silent"; else fail "C55 no resolver -> $(printf '%s' "$out" | grep -A1 C55)"; fi
rm -rf "$c55_t"

# --- C58-mcp-sdk-v1: the v1 MCP SDK gate row ---
c58_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c58.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c58_t/repo/scripts/lint" "$c58_t/home"
cp "$REPO_ROOT/scripts/lint/check-mcp-sdk-v1.sh" "$c58_t/repo/scripts/lint/check-mcp-sdk-v1.sh"
git -C "$c58_t/repo" init -q
c58_run() { (cd "$c58_t/repo" && env HIMMEL_REPO="$c58_t/repo" HIMMEL_DOCTOR_ROOT="$c58_t/repo" CLAUDE_DIR="$c58_t/home/claude" HOME="$c58_t/home" DOCTOR_OBSERVABILITY_SKIP=1 bash "$DOC" --no-color 2>/dev/null); }

echo "== C58-mcp-sdk-v1: a v1 dependency -> WARN naming the file (RED) =="
printf '%s\n' '{"dependencies":{"@modelcontextprotocol/sdk":"^1.32.1"}}' > "$c58_t/repo/package.json"
git -C "$c58_t/repo" add package.json
out="$(c58_run)"
if grepq "$out" -F 'WARN C58-mcp-sdk-v1' && grepq "$out" -F 'package.json:1'; then pass "C58 v1 dependency -> WARN"; else fail "C58 v1 dependency -> $(printf '%s' "$out" | grep -A1 C57)"; fi

echo "== C58-mcp-sdk-v1: v2 dependency -> OK =="
printf '%s\n' '{"dependencies":{"@modelcontextprotocol/server":"2.3.1"}}' > "$c58_t/repo/package.json"
git -C "$c58_t/repo" add package.json
out="$(c58_run)"
if grepq "$out" -F 'OK   C58-mcp-sdk-v1'; then pass "C58 v2 -> OK"; else fail "C58 v2 -> $(printf '%s' "$out" | grep -A1 C57)"; fi

echo "== C58-mcp-sdk-v1: a checkout without the gate -> no row =="
rm -f "$c58_t/repo/scripts/lint/check-mcp-sdk-v1.sh"
out="$(c58_run)"
if ! grepq "$out" -F 'C58-mcp-sdk-v1'; then pass "C58 no gate -> silent"; else fail "C58 no gate -> $(printf '%s' "$out" | grep -A1 C57)"; fi
rm -rf "$c58_t"

# --- C59-codex-bank-cache: a codex cache older than its TTL ---
c59_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c59.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c59_t/home"
c59_write() { # <age seconds>
    local at; at="$(date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z)"
    printf '{"limits":[],"planType":"prolite","capturedAt":"%s"}\n' "$at" > "$c59_t/codex-bank.json"
}
c59_run() { CLAUDE_DIR="$c59_t/home/claude" HOME="$c59_t/home" bash "$DOC" --no-color 2>&1; }

echo "== C59-codex-bank-cache: cache older than the TTL -> WARN naming the refresh command (RED) =="
c59_write 172800
out="$(CODEX_USAGE_CACHE="$c59_t/codex-bank.json" c59_run)"
if grepq "$out" -F 'WARN C59-codex-bank-cache' && grepq "$out" -F 'codex-usage-probe.ts'; then pass "C59 stale -> WARN"; else fail "C59 stale -> $(printf '%s' "$out" | grep -A1 C59)"; fi

echo "== C59-codex-bank-cache: fresh cache -> OK =="
c59_write 60
out="$(CODEX_USAGE_CACHE="$c59_t/codex-bank.json" c59_run)"
if grepq "$out" -F 'OK   C59-codex-bank-cache'; then pass "C59 fresh -> OK"; else fail "C59 fresh -> $(printf '%s' "$out" | grep -A1 C59)"; fi

echo "== C59-codex-bank-cache: a leading-zero TTL is read as decimal, not octal =="
c59_write 60
out="$(CODEX_USAGE_CACHE="$c59_t/codex-bank.json" CODEX_USAGE_CACHE_TTL_SECONDS=0099999 c59_run)"
if grepq "$out" -F 'OK   C59-codex-bank-cache' && ! grepq "$out" -F 'value too great'; then pass "C59 TTL 0099999 -> decimal"; else fail "C59 TTL 0099999 -> $(printf '%s' "$out" | grep -A1 C59)"; fi

echo "== C59-codex-bank-cache: the retired cache and TTL names are ignored =="
c59_write 172800
mv "$c59_t/codex-bank.json" "$c59_t/codex-usage.json"
c59_write 60
out="$(CODEX_USAGE_CACHE="$c59_t/codex-usage.json" c59_run)"
if grepq "$out" -F 'WARN C59-codex-bank-cache'; then pass "C59 reads CODEX_USAGE_CACHE"; else fail "C59 CODEX_USAGE_CACHE -> $(printf '%s' "$out" | grep -A1 C59)"; fi
out="$(CODEX_USAGE_CACHE='' CODEX_BANK_CACHE="$c59_t/codex-bank.json" c59_run)" # old-term-ok
if grepq "$out" -F 'no codex bank cache at'; then pass "C59 ignores the retired CODEX_BANK_CACHE"; else fail "C59 read the retired CODEX_BANK_CACHE -> $(printf '%s' "$out" | grep -A1 C59)"; fi # old-term-ok
out="$(CODEX_USAGE_CACHE="$c59_t/codex-usage.json" CODEX_USAGE_CACHE_TTL_SECONDS=999999 c59_run)"
if grepq "$out" -F 'OK   C59-codex-bank-cache'; then pass "C59 reads CODEX_USAGE_CACHE_TTL_SECONDS"; else fail "C59 CODEX_USAGE_CACHE_TTL_SECONDS -> $(printf '%s' "$out" | grep -A1 C59)"; fi
for c59_new in 0 -5 junk; do
  out="$(CODEX_USAGE_CACHE="$c59_t/codex-usage.json" CODEX_USAGE_CACHE_TTL_SECONDS="$c59_new" CODEX_BANK_CACHE_TTL_SECONDS=999999 c59_run)" # old-term-ok
  if grepq "$out" -F 'WARN C59-codex-bank-cache'; then pass "C59 new TTL '$c59_new' falls back to the 6 h default, not the retired TTL"; else fail "C59 new TTL '$c59_new' -> $(printf '%s' "$out" | grep -A1 C59)"; fi
done
rm -f "$c59_t/codex-usage.json"

echo "== C59-codex-bank-cache: no cache file -> INFO, not a WARN =="
rm -f "$c59_t/codex-bank.json"
out="$(c59_run)"
if grepq "$out" -F 'INFO C59-codex-bank-cache' && ! grepq "$out" -F 'WARN C59-codex-bank-cache'; then pass "C59 missing -> INFO"; else fail "C59 missing -> $(printf '%s' "$out" | grep -A1 C59)"; fi
rm -rf "$c59_t"

# --- C60-hermes-origin / C61-codex-cli ---
c60_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c60.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c60_t/home"
c60_run() { DOCTOR_HERMES_CHECKOUT="$c60_t/hermes" CLAUDE_DIR="$c60_t/home/claude" HOME="$c60_t/home" bash "$DOC" --no-color 2>&1; }
git init -q "$c60_t/hermes"

echo "== C60-hermes-origin: ssh origin -> WARN naming the https remedy (RED) =="
git -C "$c60_t/hermes" remote add origin git@github.com:NousResearch/hermes-agent.git
out="$(c60_run)"
if grepq "$out" -F 'WARN C60-hermes-origin' && grepq "$out" -F 'remote set-url origin https://github.com/NousResearch/hermes-agent.git'; then pass "C60 ssh -> WARN"; else fail "C60 ssh -> $(printf '%s' "$out" | grep -A1 C60)"; fi

echo "== C60-hermes-origin: global insteadOf must not hide an ssh origin =="
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$c60_t/global.gitconfig"
out="$(GIT_CONFIG_GLOBAL="$c60_t/global.gitconfig" c60_run)"
if grepq "$out" -F 'WARN C60-hermes-origin'; then pass "C60 rewritten ssh -> WARN"; else fail "C60 rewritten ssh -> $(printf '%s' "$out" | grep -A1 C60)"; fi

echo "== C60-hermes-origin: https origin -> OK =="
git -C "$c60_t/hermes" remote set-url origin https://github.com/NousResearch/hermes-agent.git
out="$(c60_run)"
if grepq "$out" -F 'OK   C60-hermes-origin'; then pass "C60 https -> OK"; else fail "C60 https -> $(printf '%s' "$out" | grep -A1 C60)"; fi

echo "== C60-hermes-origin: no checkout -> INFO, not a WARN =="
out="$(DOCTOR_HERMES_CHECKOUT="$c60_t/none" CLAUDE_DIR="$c60_t/home/claude" HOME="$c60_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" -F 'INFO C60-hermes-origin' && ! grepq "$out" -F 'WARN C60-hermes-origin'; then pass "C60 missing -> INFO"; else fail "C60 missing -> $(printf '%s' "$out" | grep -A1 C60)"; fi

printf '#!/usr/bin/env bash\necho "codex-cli 0.150.0"\n' > "$c60_t/codex"; chmod +x "$c60_t/codex"
c61_run() { DOCTOR_CODEX_BIN="$c60_t/codex" DOCTOR_CODEX_LATEST="$1" CLAUDE_DIR="$c60_t/home/claude" HOME="$c60_t/home" bash "$DOC" --no-color 2>&1; }

echo "== C61-codex-cli: installed older than latest -> WARN with the upgrade command (RED) =="
out="$(c61_run 0.162.1)"
if grepq "$out" -F 'WARN C61-codex-cli' && grepq "$out" -F 'npm install -g @openai/codex@latest'; then pass "C61 older -> WARN"; else fail "C61 older -> $(printf '%s' "$out" | grep -A1 C61)"; fi

echo "== C61-codex-cli: installed equals latest -> OK =="
out="$(c61_run 0.150.0)"
if grepq "$out" -F 'OK   C61-codex-cli'; then pass "C61 current -> OK"; else fail "C61 current -> $(printf '%s' "$out" | grep -A1 C61)"; fi

echo "== C61-codex-cli: installed newer than latest -> OK (never a downgrade WARN) =="
out="$(c61_run 0.100.0)"
if grepq "$out" -F 'OK   C61-codex-cli'; then pass "C61 newer -> OK"; else fail "C61 newer -> $(printf '%s' "$out" | grep -A1 C61)"; fi

echo "== C61-codex-cli: codex absent -> INFO =="
out="$(DOCTOR_CODEX_BIN="$c60_t/none" DOCTOR_CODEX_LATEST=0.162.1 CLAUDE_DIR="$c60_t/home/claude" HOME="$c60_t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" -F 'INFO C61-codex-cli' && ! grepq "$out" -F 'WARN C61-codex-cli'; then pass "C61 absent -> INFO"; else fail "C61 absent -> $(printf '%s' "$out" | grep -A1 C61)"; fi

# --- C63-claude-cli: installed claude below the chief-launch floor ---
# Fixture shape copied from this station's real `claude --version` output.
printf '#!/usr/bin/env bash\necho "2.1.296 (Claude Code)"\n' > "$c60_t/claude-new"; chmod +x "$c60_t/claude-new"
printf '#!/usr/bin/env bash\necho "2.1.200 (Claude Code)"\n' > "$c60_t/claude-old"; chmod +x "$c60_t/claude-old"
c62_run() { DOCTOR_CLAUDE_BIN="$1" CLAUDE_DIR="$c60_t/home/claude" HOME="$c60_t/home" bash "$DOC" --no-color 2>&1; }

echo "== C63-claude-cli: below the floor -> WARN naming claude update (RED) =="
out="$(c62_run "$c60_t/claude-old")"
if grepq "$out" -F 'WARN C63-claude-cli' && grepq "$out" -F 'claude update'; then pass "C63 below -> WARN"; else fail "C63 below -> $(printf '%s' "$out" | grep -A1 C63)"; fi

echo "== C63-claude-cli: at/above the floor -> OK =="
out="$(c62_run "$c60_t/claude-new")"
if grepq "$out" -F 'OK   C63-claude-cli'; then pass "C63 current -> OK"; else fail "C63 current -> $(printf '%s' "$out" | grep -A1 C63)"; fi

echo "== C63-claude-cli: absent -> INFO, not a WARN =="
out="$(c62_run "$c60_t/none")"
if grepq "$out" -F 'INFO C63-claude-cli' && ! grepq "$out" -F 'WARN C63-claude-cli'; then pass "C63 absent -> INFO"; else fail "C63 absent -> $(printf '%s' "$out" | grep -A1 C63)"; fi
rm -rf "$c60_t"

# --- C64-vm-runner: rows come from vm-runner.sh doctor ---
c64_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c64.XXXXXX")" || exit 1
printf '%s\n' '#!/usr/bin/env bash' 'printf "OK\tC64-vm-runner\tsnapshot ci-runner-v1 present\n"' 'printf "FAIL\tC64-vm-runner\trunner DEAD: variable on, no unit up\n"' > "$c64_t/runner-fail.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "OK\tC64-vm-runner\tfork-approval policy all_external_contributors\n"' > "$c64_t/runner-ok.sh"
c64_run() { DOCTOR_VM_RUNNER="$1" CLAUDE_DIR="$c64_t/claude" HOME="$c64_t/home" bash "$DOC" --no-color 2>&1; }

echo "== C64-vm-runner: a FAIL row from vm-runner.sh doctor surfaces as FAIL =="
out="$(c64_run "$c64_t/runner-fail.sh")"
if grepq "$out" -F 'FAIL C64-vm-runner: runner DEAD' && grepq "$out" -F 'OK   C64-vm-runner: snapshot ci-runner-v1 present'; then pass "C64 FAIL row -> FAIL"; else fail "C64 FAIL row -> $(printf '%s' "$out" | grep C64)"; fi

echo "== C64-vm-runner: healthy rows -> OK, no FAIL =="
out="$(c64_run "$c64_t/runner-ok.sh")"
if grepq "$out" -F 'OK   C64-vm-runner: fork-approval' && ! grepq "$out" -F 'FAIL C64-vm-runner'; then pass "C64 ok -> OK"; else fail "C64 ok -> $(printf '%s' "$out" | grep C64)"; fi

echo "== C64-vm-runner: runner script absent -> INFO =="
out="$(c64_run "$c64_t/none.sh")"
if grepq "$out" -F 'INFO C64-vm-runner' && ! grepq "$out" -F 'FAIL C64-vm-runner'; then pass "C64 absent -> INFO"; else fail "C64 absent -> $(printf '%s' "$out" | grep C64)"; fi
printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$c64_t/runner-hang.sh"
echo "== C64-vm-runner: a hung vm-runner.sh doctor is cut off (HIMMEL-5641) =="
c64_start=$SECONDS
out="$(DOCTOR_VM_RUNNER_TIMEOUT=2 c64_run "$c64_t/runner-hang.sh")"
c64_took=$((SECONDS - c64_start))
if ! command -v timeout >/dev/null 2>&1; then pass "C64 hang -> skipped (no timeout binary: the check runs unbounded by design)"
elif [ "$c64_took" -lt 20 ] && grepq "$out" -F 'C64-vm-runner'; then pass "C64 hang -> bounded (${c64_took}s)"; else fail "C64 hang -> ${c64_took}s $(printf '%s' "$out" | grep C64)"; fi
rm -rf "$c64_t"

# --- C62-oxlint-runner: can the oxlint commit gates run? ---
c62_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c62.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c62_t/home"
printf '#!/bin/sh\nexit 0\n' > "$c62_t/bun"; chmod +x "$c62_t/bun"
c62_run() { HIMMEL_DOCTOR_BUNX="$1" HIMMEL_DOCTOR_BUN="$2" CLAUDE_DIR="$c62_t/home/claude" HOME="$c62_t/home" bash "$DOC" --no-color 2>&1; }

echo "== C62-oxlint-runner: neither bunx nor bun -> WARN naming the fail-open + install remedy (RED) =="
out="$(c62_run "$c62_t/no-bunx" "$c62_t/no-bun")"
if grepq "$out" -F 'WARN C62-oxlint-runner' && grepq "$out" -F 'fail open' && grepq "$out" -F 'bun.sh/install'; then pass "C62 neither -> WARN"; else fail "C62 neither -> $(printf '%s' "$out" | grep -A1 C62)"; fi

echo "== C62-oxlint-runner: bun without bunx -> OK via bun x (the station layout) =="
out="$(c62_run "$c62_t/no-bunx" "$c62_t/bun")"
if grepq "$out" -F 'OK   C62-oxlint-runner' && grepq "$out" -F 'bun x'; then pass "C62 bun only -> OK"; else fail "C62 bun only -> $(printf '%s' "$out" | grep -A1 C62)"; fi

echo "== C62-oxlint-runner: bunx present -> OK =="
out="$(c62_run "$c62_t/bun" "$c62_t/no-bun")"
if grepq "$out" -F 'OK   C62-oxlint-runner' && grepq "$out" -F 'via bunx'; then pass "C62 bunx -> OK"; else fail "C62 bunx -> $(printf '%s' "$out" | grep -A1 C62)"; fi
rm -rf "$c62_t"

# --- C65-git-gates: git hooks installed + main protected, FAIL when not ---
c65_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c65.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c65_t/home"
c65_repo() { rm -rf "$c65_t/r"; git init -q "$c65_t/r" && git -C "$c65_t/r" remote add origin https://github.com/example/Repo.git; }
# c65_hook installs a hook shaped like the pre-commit framework's own (marker + --hook-type); c65_stub an `exit 0` stub.
c65_hook() { mkdir -p "$c65_t/r/.git/hooks"; printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\nARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=%s)\nexit 0\n' "$1" > "$c65_t/r/.git/hooks/$1"; chmod +x "$c65_t/r/.git/hooks/$1"; }
c65_stub() { mkdir -p "$c65_t/r/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$c65_t/r/.git/hooks/$1"; chmod +x "$c65_t/r/.git/hooks/$1"; }
# shellcheck disable=SC2016  # the stub's $-expressions must stay literal
# gh stub: the protection endpoint prints $C65_PROT (or fails with $C65_PROT_ERR), the rules endpoint prints $C65_RULES.
printf '%s\n' '#!/bin/sh' 'case "$*" in' \
  '  *branches/main/protection*) [ -n "$C65_PROT_ERR" ] && { echo "$C65_PROT_ERR" >&2; exit 1; }; echo "${C65_PROT:-}"; exit 0 ;;' \
  '  *rules/branches/main*) echo "${C65_RULES:-0}"; exit 0 ;;' 'esac' 'exit 1' > "$c65_t/gh"
chmod +x "$c65_t/gh"
c65_run() { env -u CI -u DOCTOR_C65_SKIP CLAUDE_DIR="$c65_t/home/claude" HOME="$c65_t/home" HIMMEL_DOCTOR_GH="$c65_t/gh" "$@" bash "$DOC" --no-color --root "$c65_t/r" --only C65 2>&1; }

echo "== C65: no git gate installed -> FAIL naming all three hook types (RED) =="
c65_repo
out="$(c65_run C65_PROT=1)"
if grepq "$out" -E 'FAIL C65-git-hooks.*pre-commit.*commit-msg.*pre-push'; then pass "C65 no hooks -> FAIL"; else fail "C65 no hooks -> $(printf '%s' "$out" | grep -A1 C65)"; fi

echo "== C65: all three hooks executable -> OK =="
for h in pre-commit commit-msg pre-push; do c65_hook "$h"; done
out="$(c65_run C65_PROT=1)"
if grepq "$out" -F 'OK   C65-git-hooks'; then pass "C65 all hooks -> OK"; else fail "C65 all hooks -> $(printf '%s' "$out" | grep -A1 C65)"; fi

echo "== C65: a non-executable hook is not installed (git ignores it) -> FAIL =="
chmod -x "$c65_t/r/.git/hooks/commit-msg"
out="$(c65_run C65_PROT=1)"
if grepq "$out" -E 'FAIL C65-git-hooks.*commit-msg' && ! grepq "$out" -E 'FAIL C65-git-hooks.*pre-push'; then pass "C65 non-exec commit-msg -> FAIL naming only it"; else fail "C65 non-exec -> $(printf '%s' "$out" | grep -A1 C65)"; fi
chmod +x "$c65_t/r/.git/hooks/commit-msg"

echo "== C65: an executable exit-0 stub is not a gate -> FAIL naming only it (RED) =="
c65_stub pre-push
out="$(c65_run C65_PROT=1)"
if grepq "$out" -E 'FAIL C65-git-hooks.*foreign/stub.*type\): pre-push — ' && ! grepq "$out" -F 'OK   C65-git-hooks'; then pass "C65 stub pre-push -> FAIL"; else fail "C65 stub -> $(printf '%s' "$out" | grep -A1 C65)"; fi
c65_hook pre-push

echo "== C65: core.hooksPath pointing outside the repo -> FAIL =="
mkdir -p "$c65_t/elsewhere"; git -C "$c65_t/r" config core.hooksPath "$c65_t/elsewhere"
out="$(c65_run C65_PROT=1)"
if grepq "$out" -E 'FAIL C65-git-hooks.*core\.hooksPath'; then pass "C65 hooksPath elsewhere -> FAIL"; else fail "C65 hooksPath -> $(printf '%s' "$out" | grep -A1 C65)"; fi
git -C "$c65_t/r" config --unset core.hooksPath

echo "== C65: a CI checkout has no dev hooks -> INFO, not FAIL =="
c65_repo
out="$(env CI=true CLAUDE_DIR="$c65_t/home/claude" HOME="$c65_t/home" HIMMEL_DOCTOR_GH="$c65_t/gh" bash "$DOC" --no-color --root "$c65_t/r" --only C65 2>&1)"
if grepq "$out" -F 'INFO C65-git-hooks' && ! grepq "$out" -F 'FAIL C65'; then pass "C65 CI -> INFO"; else fail "C65 CI -> $(printf '%s' "$out" | grep -A1 C65)"; fi

echo "== C65: branch protection readable and absent -> FAIL =="
c65_repo
out="$(c65_run C65_PROT_ERR='gh: Branch not protected (HTTP 404)')"
if grepq "$out" -E 'FAIL C65-branch-protection.*main'; then pass "C65 unprotected -> FAIL"; else fail "C65 unprotected -> $(printf '%s' "$out" | grep C65-branch)"; fi

echo "== C65: classic protection with required checks -> OK =="
out="$(c65_run C65_PROT=3)"
if grepq "$out" -F 'OK   C65-branch-protection'; then pass "C65 classic -> OK"; else fail "C65 classic -> $(printf '%s' "$out" | grep C65-branch)"; fi

echo "== C65: no classic protection but a ruleset requires checks -> OK =="
out="$(c65_run C65_PROT_ERR='gh: Branch not protected (HTTP 404)' C65_RULES=2)"
if grepq "$out" -F 'OK   C65-branch-protection'; then pass "C65 ruleset -> OK"; else fail "C65 ruleset -> $(printf '%s' "$out" | grep C65-branch)"; fi

echo "== C65: plan does not offer protection (HTTP 403 Upgrade) -> INFO, not FAIL =="
out="$(c65_run C65_PROT_ERR='gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)')"
if grepq "$out" -F 'INFO C65-branch-protection' && ! grepq "$out" -F 'FAIL C65-branch'; then pass "C65 403 -> INFO"; else fail "C65 403 -> $(printf '%s' "$out" | grep C65-branch)"; fi

echo "== C65: gh unreadable (auth/network) -> WARN unverified, never a false OK =="
out="$(c65_run C65_PROT_ERR='gh: HTTP 401 Bad credentials')"
if grepq "$out" -F 'WARN C65-branch-protection' && ! grepq "$out" -F 'OK   C65-branch'; then pass "C65 unreadable -> WARN"; else fail "C65 unreadable -> $(printf '%s' "$out" | grep C65-branch)"; fi
echo "== C65: ruleset answer is not a number -> WARN unverified, never FAIL =="
out="$(c65_run C65_PROT_ERR='gh: Branch not protected (HTTP 404)' C65_RULES=garbage)"
if grepq "$out" -F 'WARN C65-branch-protection' && ! grepq "$out" -F 'FAIL C65-branch'; then pass "C65 garbage ruleset -> WARN"; else fail "C65 garbage ruleset -> $(printf '%s' "$out" | grep C65-branch)"; fi

echo "== C65: jq missing -> WARN naming the gates that then exit 0 =="
out="$(c65_run C65_PROT=1 HIMMEL_DOCTOR_JQ="$c65_t/no-jq")"
if grepq "$out" -F 'WARN C65-gate-deps' && grepq "$out" -F 'template-version'; then pass "C65 no jq -> WARN"; else fail "C65 no jq -> $(printf '%s' "$out" | grep C65-gate)"; fi
rm -rf "$c65_t"

# --- --only selector + bounded parallel heavy checks ---
c68_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c68.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c68_t/home"
printf '#!/bin/sh\nexit 0\n' > "$c68_t/bun"; chmod +x "$c68_t/bun"
c68_env() { HIMMEL_DOCTOR_BUNX="$c68_t/no-bunx" HIMMEL_DOCTOR_BUN="$c68_t/bun" HIMMEL_DOCTOR_STATE_DIR="$c68_t/state" CLAUDE_DIR="$c68_t/home/claude" HOME="$c68_t/home" "$@"; }

echo "== --only C62: prints just that check's real station row (fixture copied from a live OVERLORD8 run), exits 0 =="
out="$(c68_env bash "$DOC" --no-color --only C62 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -F "OK   C62-oxlint-runner: oxlint gates run via 'bun x' (bunx not on PATH)" && ! grepq "$out" -E 'C(2|3|20|63)-'; then pass "--only C62 -> only the C62 row"; else fail "--only C62 -> rc=$rc: $out"; fi

echo "== --only accepts a comma list, case-insensitive =="
out="$(c68_env bash "$DOC" --no-color --only c62,C63 2>&1)"
if grepq "$out" -F 'C62-oxlint-runner' && grepq "$out" -F 'C63-claude-cli' && ! grepq "$out" -F 'C61-'; then pass "--only c62,C63 -> both rows"; else fail "--only list -> $out"; fi

echo "== --only is a subset run: it never publishes the statusline state =="
c68_env bash "$DOC" --no-color --only C62 >/dev/null 2>&1
if [ ! -e "$c68_t/state" ] || [ -z "$(ls -A "$c68_t/state" 2>/dev/null)" ]; then pass "--only publishes no state"; else fail "--only published state: $(ls "$c68_t/state")"; fi

echo "== --only with no value -> exit 2 =="
c68_env bash "$DOC" --no-color --only >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "--only needs a value"; else fail "--only without a value -> rc=$rc"; fi

echo "== a hung heavy check is bounded: TIMEOUT for itself, the rest of the sweep still reports =="
printf '#!/bin/sh\nsleep 60\n' > "$c68_t/hung-sweep.sh"
c68_start=$SECONDS
out="$(c68_env env DOCTOR_SWEEP_HEALTH_SCRIPT="$c68_t/hung-sweep.sh" HIMMEL_DOCTOR_HEAVY_TIMEOUT=3 bash "$DOC" --no-color 2>&1)"
c68_took=$((SECONDS - c68_start))
if grepq "$out" -E 'INFO C42-sweep-health: TIMEOUT after 3s' && grepq "$out" -F 'C43-rtk-hook' && grepq "$out" -F 'Summary:' && [ "$c68_took" -lt 40 ]; then pass "hung C42 -> TIMEOUT row, sweep finished in ${c68_took}s"; else fail "hung C42 -> took ${c68_took}s: $(printf '%s' "$out" | grep -E 'C42|Summary')"; fi

echo "== a heavy check's WARN survives the parallel replay into the Summary count =="
printf '#!/bin/sh\necho "LOST-COMMITS feat/x 1 commit(s)"\nexit 1\n' > "$c68_t/lost-sweep.sh"
out="$(c68_env env DOCTOR_SWEEP_HEALTH_SCRIPT="$c68_t/lost-sweep.sh" bash "$DOC" --no-color 2>&1)"
if grepq "$out" -E 'WARN C42-sweep-health: LOST-COMMITS feat/x' && grepq "$out" -E 'Summary: .*[1-9][0-9]* WARN'; then pass "heavy WARN replayed and counted"; else fail "heavy WARN replay -> $(printf '%s' "$out" | grep -E 'C42|Summary')"; fi
echo "== a TMPDIR containing a space still replays heavy rows =="
mkdir -p "$c68_t/tmp dir"
out="$(c68_env env TMPDIR="$c68_t/tmp dir" DOCTOR_SWEEP_HEALTH_SCRIPT="$c68_t/lost-sweep.sh" bash "$DOC" --no-color 2>&1)"
if grepq "$out" -E 'WARN C42-sweep-health: LOST-COMMITS feat/x'; then pass "space in TMPDIR -> heavy WARN replayed"; else fail "space in TMPDIR -> $(printf '%s' "$out" | grep -E 'C42|Summary')"; fi

echo "== --only rejects a following option or a non-id value -> exit 2 =="
c68_env bash "$DOC" --no-color --only --json >/dev/null 2>&1; rc1=$?
c68_env bash "$DOC" --no-color --only C999 >/dev/null 2>&1; rc2=$?; c68_env bash "$DOC" --no-color --only "C.*" >/dev/null 2>&1; rc3=$?
if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ] && [ "$rc3" -eq 2 ]; then pass "--only validates its value"; else fail "--only validation -> rc=$rc1/$rc2/$rc3"; fi
rm -rf "$c68_t"

# --- C66-hermes-cron-hooks: the external cron worker registers config hooks ---
# Fixtures are the real upstream function before and after 946eafdf2fe (scripts/hermes/fixtures/).
c66_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c66.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c66_t/home" "$c66_t/hermes/.git" "$c66_t/hermes/cron"
c66_run() { DOCTOR_HERMES_GATEWAY_START="${DOCTOR_HERMES_GATEWAY_START:-4000000000}" DOCTOR_HERMES_CHECKOUT="$c66_t/hermes" CLAUDE_DIR="$c66_t/home/claude" HOME="$c66_t/home" bash "$DOC" --no-color --only C66 2>&1; }

echo "== C66: worker without hook registration (pre-946eafdf2fe) -> FAIL (RED) =="
cp "$REPO_ROOT/scripts/hermes/fixtures/cron-worker-unfenced.py" "$c66_t/hermes/cron/scheduler.py"
out="$(c66_run)"
if grepq "$out" -F 'FAIL C66-hermes-cron-hooks'; then pass "C66 unfenced -> FAIL"; else fail "C66 unfenced -> $(printf '%s' "$out" | grep -A1 C66)"; fi

echo "== C66: a comment naming register_from_config is not a registration -> FAIL =="
awk '{ print } /^def _run_external_worker_payload/ { print "    # register_from_config(load_config(), accept_hooks=False)" }' \
    "$REPO_ROOT/scripts/hermes/fixtures/cron-worker-unfenced.py" > "$c66_t/hermes/cron/scheduler.py"
out="$(c66_run)"
if grepq "$out" -F 'FAIL C66-hermes-cron-hooks'; then pass "C66 comment-only -> FAIL"; else fail "C66 comment-only -> $(printf '%s' "$out" | grep -A1 C66)"; fi

echo "== C66: worker registers the config hooks (521f4dc) -> OK =="
cp "$REPO_ROOT/scripts/hermes/fixtures/cron-worker-fenced.py" "$c66_t/hermes/cron/scheduler.py"
out="$(c66_run)"
if grepq "$out" -F 'OK   C66-hermes-cron-hooks'; then pass "C66 fenced -> OK"; else fail "C66 fenced -> $(printf '%s' "$out" | grep -A1 C66)"; fi

echo "== C66: scheduler exists but the worker entrypoint is gone (upstream rename) -> WARN, not INFO =="
printf 'def run_job():\n    pass\n' > "$c66_t/hermes/cron/scheduler.py"
out="$(c66_run)"
if grepq "$out" -F 'WARN C66-hermes-cron-hooks' && ! grepq "$out" -F 'INFO C66-hermes-cron-hooks'; then pass "C66 entrypoint gone -> WARN"; else fail "C66 entrypoint gone -> $(printf '%s' "$out" | grep -A1 C66)"; fi

echo "== C66: fenced worker older than the running gateway -> OK; newer than it -> WARN stale gateway =="
cp "$REPO_ROOT/scripts/hermes/fixtures/cron-worker-fenced.py" "$c66_t/hermes/cron/scheduler.py"
TZ=UTC touch -t 200109090146.40 "$c66_t/hermes/cron/scheduler.py" || fail "C66 could not backdate scheduler.py"
out="$(DOCTOR_HERMES_GATEWAY_START=1000000100 c66_run)"
if grepq "$out" -F 'OK   C66-hermes-cron-hooks'; then pass "C66 gateway newer than scheduler -> OK"; else fail "C66 gateway newer -> $(printf '%s' "$out" | grep -A1 C66)"; fi
out="$(DOCTOR_HERMES_GATEWAY_START=999999900 c66_run)"
if grepq "$out" -F 'WARN C66-hermes-cron-hooks' && grepq "$out" -F 'gateway'; then pass "C66 gateway older than scheduler -> WARN"; else fail "C66 gateway older -> $(printf '%s' "$out" | grep -A1 C66)"; fi

echo "== C66: no hermes checkout -> INFO =="
out="$(DOCTOR_HERMES_CHECKOUT="$c66_t/none" CLAUDE_DIR="$c66_t/home/claude" HOME="$c66_t/home" bash "$DOC" --no-color --only C66 2>&1)"
if grepq "$out" -F 'INFO C66-hermes-cron-hooks' && ! grepq "$out" -F 'FAIL C66-hermes-cron-hooks'; then pass "C66 missing -> INFO"; else fail "C66 missing -> $(printf '%s' "$out" | grep -A1 C66)"; fi
rm -rf "$c66_t"

# --- C67-hermes-fail-open: a parity_guard hook registered fail-open ---
# Fixture: a live station profile's hooks block (scripts/hermes/fixtures/).
c67_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c67.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c67_t/home" "$c67_t/hermes/profiles/station"
c67_run() { DOCTOR_HERMES_HOME="$c67_t/hermes" CLAUDE_DIR="$c67_t/home/claude" HOME="$c67_t/home" bash "$DOC" --no-color --only C67 2>&1; }

echo "== C67: a station profile wired fail-open -> WARN naming it =="
cp "$REPO_ROOT/scripts/hermes/fixtures/profile-hooks-fail-open.yaml" "$c67_t/hermes/profiles/station/config.yaml"
printf 'model:\n  default: gpt-5.5\n' > "$c67_t/hermes/config.yaml"
out="$(c67_run)"
if grepq "$out" -F 'WARN C67-hermes-fail-open' && grepq "$out" -F 'fail-open in: profiles/station/config.yaml — '; then pass "C67 fail-open -> WARN names only the station profile"; else fail "C67 fail-open -> $(printf '%s' "$out" | grep -A1 C67)"; fi

echo "== C67: the same profile after the installer's ensure pass -> OK =="
python3 "$REPO_ROOT/scripts/hermes/assets/wire_parity_guard.py" ensure "$c67_t/hermes/profiles/station/config.yaml" /x/parity_guard.py python3 >/dev/null
out="$(c67_run)"
if grepq "$out" -F 'OK   C67-hermes-fail-open'; then pass "C67 re-wired -> OK"; else fail "C67 re-wired -> $(printf '%s' "$out" | grep -A1 C67)"; fi

echo "== C67: parity_guard behind a nested secret_env mapping, no fail_closed -> WARN =="
cp "$REPO_ROOT/scripts/hermes/fixtures/profile-hooks-nested-key-fail-open.yaml" "$c67_t/hermes/profiles/station/config.yaml"
out="$(c67_run)"
if grepq "$out" -F 'WARN C67-hermes-fail-open'; then pass "C67 nested key then command -> WARN"; else fail "C67 nested key then command -> $(printf '%s' "$out" | grep -A1 C67)"; fi

echo "== C67: fail_closed: true after a nested secret_env mapping -> OK =="
cp "$REPO_ROOT/scripts/hermes/fixtures/profile-hooks-nested-key-fail-closed.yaml" "$c67_t/hermes/profiles/station/config.yaml"
out="$(c67_run)"
if grepq "$out" -F 'OK   C67-hermes-fail-open'; then pass "C67 fail_closed after nested key -> OK"; else fail "C67 fail_closed after nested key -> $(printf '%s' "$out" | grep -A1 C67)"; fi

echo "== C67: a fail_closed: true inside a nested mapping does not fence the entry -> WARN =="
cp "$REPO_ROOT/scripts/hermes/fixtures/profile-hooks-nested-fail-closed-fail-open.yaml" "$c67_t/hermes/profiles/station/config.yaml"
out="$(c67_run)"
if grepq "$out" -F 'WARN C67-hermes-fail-open'; then pass "C67 nested fail_closed -> WARN"; else fail "C67 nested fail_closed -> $(printf '%s' "$out" | grep -A1 C67)"; fi

echo "== C67: no hermes install -> INFO =="
out="$(DOCTOR_HERMES_HOME="$c67_t/none" CLAUDE_DIR="$c67_t/home/claude" HOME="$c67_t/home" bash "$DOC" --no-color --only C67 2>&1)"
if grepq "$out" -F 'INFO C67-hermes-fail-open'; then pass "C67 missing -> INFO"; else fail "C67 missing -> $(printf '%s' "$out" | grep -A1 C67)"; fi
rm -rf "$c67_t"

# --- C68-konsole-dbus: konsolerc must set EnableSecuritySensitiveDBusAPI=true ---
# Fixtures are copies of the real ~/.config/konsolerc (with and without line 5).
echo "== C68: konsolerc lacks EnableSecuritySensitiveDBusAPI=true -> WARN =="
c68_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c68.XXXXXX")" || { fail "C68: mktemp -d failed"; exit 1; }
mkdir -p "$c68_t/home/.config" "$c68_t/bin"
printf '#!/bin/sh\nexit 0\n' > "$c68_t/bin/konsole"; chmod +x "$c68_t/bin/konsole"
c68_run() { env -u XDG_CONFIG_HOME PATH="$c68_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c68_t/home/claude" HOME="$c68_t/home" bash "$DOC" --no-color --only C68 2>&1; }
cp "$REPO_ROOT/scripts/fixtures/doctor/konsolerc-dbus-missing" "$c68_t/home/.config/konsolerc"
out="$(c68_run)"
if grepq "$out" -F 'WARN C68-konsole-dbus'; then pass "C68 missing setting -> WARN"; else fail "C68 missing setting -> $(printf '%s' "$out" | grep -A1 C68)"; fi

echo "== C68: konsolerc sets EnableSecuritySensitiveDBusAPI=true -> OK =="
cp "$REPO_ROOT/scripts/fixtures/doctor/konsolerc-dbus-enabled" "$c68_t/home/.config/konsolerc"
out="$(c68_run)"
if grepq "$out" -F 'OK   C68-konsole-dbus'; then pass "C68 setting present -> OK"; else fail "C68 setting present -> $(printf '%s' "$out" | grep -A1 C68)"; fi

echo "== C68: setting under another section -> WARN =="
cp "$REPO_ROOT/scripts/fixtures/doctor/konsolerc-dbus-missing" "$c68_t/home/.config/konsolerc"
printf 'EnableSecuritySensitiveDBusAPI=true\n' >> "$c68_t/home/.config/konsolerc"
out="$(c68_run)"
if grepq "$out" -F 'WARN C68-konsole-dbus'; then pass "C68 setting outside [KonsoleWindow] -> WARN"; else fail "C68 setting outside [KonsoleWindow] -> $(printf '%s' "$out" | grep -A1 C68)"; fi

echo "== C68: later assignment sets it false -> WARN =="
awk '{ print } NR == 5 { print "EnableSecuritySensitiveDBusAPI=false" }' "$REPO_ROOT/scripts/fixtures/doctor/konsolerc-dbus-enabled" > "$c68_t/home/.config/konsolerc"
out="$(c68_run)"
if grepq "$out" -F 'WARN C68-konsole-dbus'; then pass "C68 last assignment false -> WARN"; else fail "C68 last assignment false -> $(printf '%s' "$out" | grep -A1 C68)"; fi

echo "== C68: no konsolerc at all -> WARN =="
rm -f "$c68_t/home/.config/konsolerc"
out="$(c68_run)"
if grepq "$out" -F 'WARN C68-konsole-dbus'; then pass "C68 no konsolerc -> WARN"; else fail "C68 no konsolerc -> $(printf '%s' "$out" | grep -A1 C68)"; fi

echo "== C68: konsole not installed -> INFO =="
out="$(env -u XDG_CONFIG_HOME DOCTOR_KONSOLE=konsole-not-installed CLAUDE_DIR="$c68_t/home/claude" HOME="$c68_t/home" bash "$DOC" --no-color --only C68 2>&1)"
if grepq "$out" -F 'INFO C68-konsole-dbus'; then pass "C68 no konsole -> INFO"; else fail "C68 no konsole -> $(printf '%s' "$out" | grep -A1 C68)"; fi
rm -rf "$c68_t"

# --- C69-qmd-cli-key: the qmd CLI's OpenRouter key is present and accepted ---
# Seams: HIMMEL_DOCTOR_QMD_CURL (the stub answers C69_CODE and ignores the key on stdin), HOME (config + key file).
echo "== C69: OpenRouter config, key file present and accepted -> OK =="
c69_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c69.XXXXXX")" || { fail "C69: mktemp -d failed"; exit 1; }
mkdir -p "$c69_t/home/.config/qmd" "$c69_t/home/.himmel/state"
printf 'models:\n  embed: openai:qwen/qwen3-embedding-8b\n  openai_base_url: https://openrouter.ai/api/v1\n' > "$c69_t/home/.config/qmd/index.yml"
C69_SENTINEL=sk-test-sentinel-c69
# the stub answers C69_CODE only when the key arrives as an Authorization header on stdin, else 403
printf "#!/bin/sh\nin=\"\$(cat)\"\ncase \"\$in\" in *'Authorization: Bearer $C69_SENTINEL\"'*) printf \"%%s\" \"\${C69_CODE:-200}\" ;; *) printf 403 ;; esac\n" > "$c69_t/curl"; chmod +x "$c69_t/curl"
printf 'QMD_OPENAI_API_KEY=%s\n' "$C69_SENTINEL" > "$c69_t/home/.himmel/state/qmd-daemon.env"; chmod 600 "$c69_t/home/.himmel/state/qmd-daemon.env"
cat > "$c69_t/qmd" <<'STUB'
#!/bin/sh
case "$C69_CLI" in
  hang) sleep 30 ;;
  okmatch) echo 'a hit whose text says answered 401 No cookie auth credentials found'; echo 'warn: answered 401 No cookie auth credentials found' >&2 ;;
  nokey) [ -n "$QMD_OPENAI_API_KEY" ] || { echo 'https://openrouter.ai/api/v1/embeddings answered 401 {"message":"No cookie auth credentials found"}' >&2; exit 1; } ;;
esac
echo hit
STUB
chmod +x "$c69_t/qmd"
c69_run() { env -u XDG_CONFIG_HOME -u QMD_CONFIG_DIR -u QMD_DAEMON_ENV_FILE -u QMD_OPENAI_API_KEY -u QMD_OPENAI_BASE_URL -u C69_CLI HIMMEL_DOCTOR_QMD_CURL="$c69_t/curl" HIMMEL_DOCTOR_QMD_BIN="$c69_t/qmd" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c69_t/home/claude" HOME="$c69_t/home" "$@" bash "$DOC" --no-color --only C69 2>&1; }
c69_run_x() { env -u XDG_CONFIG_HOME -u QMD_CONFIG_DIR -u QMD_DAEMON_ENV_FILE -u QMD_OPENAI_API_KEY -u QMD_OPENAI_BASE_URL -u C69_CLI HIMMEL_DOCTOR_QMD_CURL="$c69_t/curl" HIMMEL_DOCTOR_QMD_BIN="$c69_t/qmd" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c69_t/home/claude" HOME="$c69_t/home" "$@" bash -x "$DOC" --no-color --only C69 2>&1; }
out="$(c69_run C69_CODE=200)"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 key accepted -> OK"; else fail "C69 key accepted -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 printed the key"; else pass "C69 never prints the key"; fi

echo "== C69: provider answers 401 -> FAIL =="
out="$(c69_run C69_CODE=401)"
if grepq "$out" -F 'FAIL C69-qmd-cli-key'; then pass "C69 key rejected -> FAIL"; else fail "C69 key rejected -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: provider unreachable (000) -> INFO, not a credential verdict =="
out="$(c69_run C69_CODE=000)"
if grepq "$out" -F 'INFO C69-qmd-cli-key'; then pass "C69 unreachable -> INFO"; else fail "C69 unreachable -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: no key file -> FAIL =="
rm -f "$c69_t/home/.himmel/state/qmd-daemon.env"
out="$(c69_run C69_CODE=200)"
if grepq "$out" -F 'FAIL C69-qmd-cli-key'; then pass "C69 missing key -> FAIL"; else fail "C69 missing key -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: no key file but a session key, as the CLI accepts -> OK =="
out="$(c69_run C69_CODE=200 QMD_OPENAI_API_KEY="$C69_SENTINEL")"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 session key without a file -> OK"; else fail "C69 session key without a file -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 printed the session key"; else pass "C69 session key never printed"; fi

echo "== C69: a traced doctor run never prints the key =="
out="$(c69_run_x C69_CODE=200 QMD_OPENAI_API_KEY="$C69_SENTINEL")"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 traced, session key -> OK"; else fail "C69 traced, session key -> $(printf '%s' "$out" | grep -F C69 | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 trace printed the session key"; else pass "C69 trace never prints the session key"; fi
printf 'QMD_OPENAI_API_KEY=%s\n' "$C69_SENTINEL" > "$c69_t/home/.himmel/state/qmd-daemon.env"; chmod 600 "$c69_t/home/.himmel/state/qmd-daemon.env"
out="$(c69_run_x C69_CODE=200)"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 traced, file key -> OK"; else fail "C69 traced, file key -> $(printf '%s' "$out" | grep -F C69 | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 trace printed the file key"; else pass "C69 trace never prints the file key"; fi

echo "== C69: provider answers 403 -> FAIL =="
out="$(c69_run C69_CODE=403)"
if grepq "$out" -F 'FAIL C69-qmd-cli-key'; then pass "C69 key forbidden -> FAIL"; else fail "C69 key forbidden -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: the bare qmd CLI answers 401 while the key file is valid -> WARN naming the CLI path =="
out="$(c69_run C69_CODE=200 C69_CLI=nokey)"
if grepq "$out" -F 'WARN C69-qmd-cli-key'; then pass "C69 bare CLI 401 -> WARN"; else fail "C69 bare CLI 401 -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F 'bare qmd'; then pass "C69 CLI WARN names the bare qmd path"; else fail "C69 CLI WARN names the bare qmd path -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 CLI WARN printed the key"; else pass "C69 CLI WARN never prints the key"; fi

echo "== C69: a session key in the doctor's own environment does not hide a key-less bare CLI -> WARN =="
out="$(c69_run C69_CODE=200 C69_CLI=nokey QMD_OPENAI_API_KEY="$C69_SENTINEL")"
if grepq "$out" -F 'WARN C69-qmd-cli-key'; then pass "C69 session key scrubbed for the CLI probe -> WARN"; else fail "C69 session key scrubbed for the CLI probe -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: the bare qmd CLI answers -> OK =="
out="$(c69_run C69_CODE=200)"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 bare CLI answers -> OK"; else fail "C69 bare CLI answers -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: a working bare qmd CLI whose output carries the 401 strings -> OK, only a failed call is a 401 =="
out="$(c69_run C69_CODE=200 C69_CLI=okmatch)"
if grepq "$out" -F 'OK   C69-qmd-cli-key'; then pass "C69 successful CLI output naming a 401 -> OK"; else fail "C69 successful CLI output naming a 401 -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: the bare qmd CLI hangs past the bound -> INFO, not a credential verdict =="
out="$(c69_run C69_CODE=200 C69_CLI=hang HIMMEL_DOCTOR_QMD_CLI_SECS=1 QMD_KILL_GRACE_SECS=1)"
if grepq "$out" -F 'INFO C69-qmd-cli-key'; then pass "C69 bare CLI timeout -> INFO"; else fail "C69 bare CLI timeout -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: qmd absent -> INFO =="
out="$(c69_run C69_CODE=200 HIMMEL_DOCTOR_QMD_BIN="$c69_t/no-such-qmd")"
if grepq "$out" -F 'INFO C69-qmd-cli-key'; then pass "C69 qmd absent -> INFO"; else fail "C69 qmd absent -> $(printf '%s' "$out" | head -3)"; fi

echo "== C69: OpenRouter named only by QMD_OPENAI_BASE_URL, no key anywhere -> FAIL =="
printf 'models:\n  embed: hf:x/y.gguf\n' > "$c69_t/home/.config/qmd/index.yml"
rm -f "$c69_t/home/.himmel/state/qmd-daemon.env"
out="$(c69_run C69_CODE=200 QMD_OPENAI_BASE_URL=https://openrouter.ai/api/v1)"
if grepq "$out" -F 'FAIL C69-qmd-cli-key'; then pass "C69 env base URL -> FAIL"; else fail "C69 env base URL -> $(printf '%s' "$out" | head -3)"; fi
printf 'models:\n  embed: openai:qwen/qwen3-embedding-8b\n  openai_base_url: https://openrouter.ai/api/v1\n' > "$c69_t/home/.config/qmd/index.yml"

echo "== C69: key file readable by others -> FAIL =="
printf 'QMD_OPENAI_API_KEY=%s\n' "$C69_SENTINEL" > "$c69_t/home/.himmel/state/qmd-daemon.env"; chmod 644 "$c69_t/home/.himmel/state/qmd-daemon.env"
out="$(c69_run C69_CODE=200)"
if grepq "$out" -F 'FAIL C69-qmd-cli-key'; then pass "C69 group-readable key file -> FAIL"; else fail "C69 group-readable key file -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "$C69_SENTINEL"; then fail "C69 printed the key (refused file)"; else pass "C69 refused file never prints the key"; fi

echo "== C69: local-model config -> silent =="
printf 'models:\n  embed: hf:x/y.gguf\n' > "$c69_t/home/.config/qmd/index.yml"
out="$(c69_run C69_CODE=401)"
if grepq "$out" -F 'C69-qmd-cli-key'; then fail "C69 local config should be silent -> $(printf '%s' "$out" | head -3)"; else pass "C69 local config -> silent"; fi
rm -rf "$c69_t"

echo "== C69: the key check has no multi-line command substitution (bash 3.2 cannot parse a case inside one) =="
c69_body="$(sed -n -e '/^check_c69_qmd_cli_key() {/,/^}/p' -e '/^_c69_probe_key() {/,/^}/p' "$DOC")"
if [ -n "$c69_body" ] && ! grep -qE '\$\([^)]*$' <<< "$c69_body"; then pass "C69 no unclosed command substitution in the key check or probe"; else fail "C69 unclosed command substitution in the key check or probe"; fi

echo "== C70: graphify semantic freshness =="
c70_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c70.XXXXXX")" || { fail "C70 mktemp -d failed"; exit 1; }
c70_t="$(cd "$c70_t" && pwd)" || { fail "C70 cd into the temp dir failed"; exit 1; }  # the doctor prints --root through cd+pwd; a TMPDIR with a trailing slash (macOS) would leave "T//" here
c70_out="$c70_t/home/.claude/graph-cadence/himmel/graphify-out"; c70_corpus="$c70_t/corpus"
mkdir -p "$c70_out" "$c70_corpus" "$c70_t/home/.himmel"
printf '{"graphify":{"semantic_api_ok":true}}\n' > "$c70_t/home/.himmel/config.json"
printf '{"real.md": {"mtime": 0}}\n' > "$c70_out/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$c70_out/graph.json"
printf '# real\n' > "$c70_corpus/real.md"
printf '%s\n' "$c70_corpus" > "$c70_out/.graphify_root"
# c70_rows <failed files>...: one merge row per argument, each a comma list, dated today (UTC) inside the semantic age bound
c70_day="$(date -u +%Y-%m-%d)"
c70_rows() { python3 - "$c70_out/semantic-runs.jsonl" "$c70_day" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i, spec in enumerate(sys.argv[3:]):
        failed = [s for s in spec.split(",") if s]
        f.write(json.dumps({"ts": "%sT0%d:00:00Z" % (sys.argv[2], i), "name": "t", "batch": 3, "failed": len(failed), "shrink_refused": 0,
                            "failed_files": failed, "refused_files": [], "backed_off_files": []}) + "\n")
PY
}
c70_run() { env HOME="$c70_t/home" CLAUDE_DIR="$c70_t/home/claude" HIMMEL_DOCTOR_GRAPH_OUT="$c70_out" HIMMEL_DOCTOR_GRAPH_CHECK= "$@" bash "$DOC" --no-color --only C70 2>&1; }

c70_rows "x.md" "x.md" "x.md"
out="$(c70_run)"
if grepq "$out" -F 'WARN C70-graph-semantic'; then pass "C70 a file stuck across 3 runs -> WARN"; else fail "C70 stuck -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "graph-freshness: semantic last=${c70_day}T02:00:00Z failed=1 refused=0"; then pass "C70 prints the semantic line verbatim"; else fail "C70 stuck line -> $(printf '%s' "$out" | head -3)"; fi

c70_rows "x.md" "y.md" ""
out="$(c70_run)"
if grepq "$out" -F 'OK   C70-graph-semantic' && grepq "$out" -F "graph-freshness: semantic last=${c70_day}T02:00:00Z failed=0"; then pass "C70 draining failures -> OK with the line"; else fail "C70 draining -> $(printf '%s' "$out" | head -3)"; fi
# c70_row_at <ts> <failed csv>: a single merge row at an explicit ts
c70_row_at() { python3 - "$c70_out/semantic-runs.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
failed = [s for s in sys.argv[3].split(",") if s]
open(sys.argv[1], "w").write(json.dumps({"ts": sys.argv[2], "name": "t", "batch": 3, "failed": len(failed), "shrink_refused": 0,
                                         "failed_files": failed, "refused_files": [], "backed_off_files": []}) + "\n")
PY
}
c70_ago() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-float(sys.argv[1])*3600)))' "$1"; }
c70_row_at "$(c70_ago 72)" ""
out="$(c70_run)"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'SEMANTIC' && grepq "$out" -F 'last semantic merge 3d ago' && ! grepq "$out" -F 'bash ~/.claude/graphmap-cadence/graphmap-himmel.sh'; then pass "C70 semantic layer 3 days old on a fresh AST graph -> WARN naming the age and the semantic pass"; else fail "C70 semantic 3d old -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F 'bash scripts/handover/chief-kit/graph-pass-detached.sh start' && grepq "$out" -F 'bash scripts/handover/chief-kit/graph-pass-detached.sh status' && ! grepq "$(printf '%s\n' "$out" | grep -F '→')" -F 'graphmap-himmel.sh'; then pass "C70 SEMANTIC-STALE remedy names the detached wrapper start and status, not a by-hand pass"; else fail "C70 stale remedy -> $(printf '%s' "$out" | head -4)"; fi
c70_rem="$(printf '%s\n' "$out" | grep -F '→' | grep -F 'graph-pass-detached.sh' | head -1)"
c70_pre="${c70_rem%%graph-pass-detached.sh start*}"
if grepq "$c70_pre" -F 'graph-pass-detached.sh status' && grepq "$c70_rem" -F 'resumable, continuing' && grepq "$c70_rem" -F 'no second start'; then pass "C70 stale remedy reads status before start and says a resumable, continuing series needs no second start"; else fail "C70 status-first remedy -> $c70_rem"; fi
c70_row_at "$(c70_ago 1)" ""
out="$(c70_run)"
if grepq "$out" -F 'OK   C70-graph-semantic'; then pass "C70 semantic layer 1h old -> OK"; else fail "C70 semantic fresh -> $(printf '%s' "$out" | head -3)"; fi
if ! grepq "$out" -F 'graph-pass-detached'; then pass "C70 the OK output carries no wrapper remedy"; else fail "C70 OK output names the wrapper -> $(printf '%s' "$out" | head -3)"; fi
c70_row_at "$(c70_ago 1)" "docs/a1.md,docs/a2.md,docs/a3.md,docs/a4.md,docs/a5.md,docs/a6.md,docs/a7.md,docs/a8.md,docs/a9.md,docs/a10.md,docs/a11.md"
out="$(c70_run)"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'content failed=11'; then pass "C70 11 content failures (bound 10) -> WARN with the count"; else fail "C70 content failed -> $(printf '%s' "$out" | head -3)"; fi
mkdir -p "$c70_corpus/marketplace/plugins/vend"; printf '# v\n' > "$c70_corpus/marketplace/plugins/vend/VENDORED.md"
c70_row_at "$(c70_ago 1)" "marketplace/plugins/vend/skills/a.md,marketplace/plugins/vend/b.md,templates/t/c.md,templates/d.md,plugins/p/templates/e.md,scripts/ci/test-x-fixtures/f.md,scripts/ci/test-x-fixtures/g.md,scripts/hooks/testdata/h.md,plugins/q/evals/c/graders/i.md,plugins/q/evals/c/graders/j.md,fixtures/k.md"
out="$(c70_run)"
if grepq "$out" -F 'OK   C70-graph-semantic' && grepq "$out" -F 'non_content_failed=11'; then pass "C70 11 vendored/template/fixture failures -> not counted, OK"; else fail "C70 non-content failed -> $(printf '%s' "$out" | head -3)"; fi

rm -f "$c70_out/semantic-runs.jsonl"
out="$(c70_run)"
if grepq "$out" -F 'OK   C70-graph-semantic' && grepq "$out" -F 'no semantic-runs.jsonl'; then pass "C70 no semantic-runs.jsonl -> OK skip"; else fail "C70 no runs -> $(printf '%s' "$out" | head -3)"; fi

out="$(c70_run HIMMEL_DOCTOR_GRAPH_OUT="$c70_t/no-such-out")"
if grepq "$out" -F 'OK   C70-graph-semantic' && grepq "$out" -F 'no graphify-out at'; then pass "C70 no graphify-out -> OK skip"; else fail "C70 no corpus -> $(printf '%s' "$out" | head -3)"; fi
c70_rows "x.md" "x.md" "x.md"
printf '#!/bin/sh\nexit 127\n' > "$c70_t/missing-check.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_CHECK="$c70_t/missing-check.sh")"
if grepq "$out" -F 'INFO C70-graph-semantic' && grepq "$out" -F 'exited 127'; then pass "C70 checker exits 127 -> INFO, not a healthy OK"; else fail "C70 rc 127 -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F "bash scripts/graphify/check-graph-freshness.sh --out $c70_out" && ! grepq "$out" -F 'graph-pass-detached'; then pass "C70 the INFO output keeps its own remedy and carries no wrapper remedy"; else fail "C70 INFO remedy -> $(printf '%s' "$out" | head -4)"; fi
printf '#!/bin/sh\necho "graph-freshness: FAIL corpus orphaned: gone" >&2\nexit 2\n' > "$c70_t/orphan-check.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_CHECK="$c70_t/orphan-check.sh")"
if grepq "$out" -F 'INFO C70-graph-semantic' && grepq "$out" -F 'corpus orphaned'; then pass "C70 other rc 2 -> INFO with the reason"; else fail "C70 rc 2 -> $(printf '%s' "$out" | head -3)"; fi
out="$(c70_run)"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F "semantic-merge.py unstick --out $c70_out"; then pass "C70 the WARN names the unstick command for the judged graph"; else fail "C70 unstick hint -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F 'bash scripts/handover/chief-kit/graph-pass-detached.sh start' && grepq "$out" -F 'bash scripts/handover/chief-kit/graph-pass-detached.sh status'; then pass "C70 the stuck WARN's semantic batch hint names the detached wrapper start and status"; else fail "C70 stuck wrapper hint -> $(printf '%s' "$out" | head -4)"; fi
printf '#!/bin/sh\necho "graph-freshness: STUCK semantic refresh stuck: x.md failed" >&2\nexit 3\n' > "$c70_t/stuck-check.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_CHECK="$c70_t/stuck-check.sh")"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'semantic refresh stuck: x.md'; then pass "C70 checker rc 3 (stuck) -> WARN naming the file"; else fail "C70 rc 3 -> $(printf '%s' "$out" | head -3)"; fi
printf '#!/bin/sh\necho "graph-freshness: STUCK semantic refresh stuck: x.md failed" >&2\necho "graph-freshness: WARN graph is 9d old" >&2\nexit 1\n' > "$c70_t/stale-stuck-check.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_CHECK="$c70_t/stale-stuck-check.sh")"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'semantic refresh stuck: x.md'; then pass "C70 stuck on a stale graph (rc 1) still names the stuck file"; else fail "C70 rc 1 stuck -> $(printf '%s' "$out" | head -3)"; fi
printf '#!/bin/sh\nexit 3\n' > "$c70_t/bare3-check.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_CHECK="$c70_t/bare3-check.sh")"
if grepq "$out" -F 'INFO C70-graph-semantic' && grepq "$out" -F 'exited 3'; then pass "C70 rc 3 without a stuck message -> INFO, not a healthy OK"; else fail "C70 bare rc 3 -> $(printf '%s' "$out" | head -3)"; fi
# the default graph is the station checkout's graphify-out, never a graph under HOME
mkdir -p "$c70_t/root"; cp -R "$c70_out" "$c70_t/root/graphify-out"
out="$(env HOME="$c70_t/home" CLAUDE_DIR="$c70_t/home/claude" HIMMEL_DOCTOR_ROOT="$c70_t/root" HIMMEL_DOCTOR_GRAPH_OUT= HIMMEL_DOCTOR_GRAPH_CHECK= bash "$DOC" --no-color --only C70 2>&1)"
if grepq "$out" -F "unstick --out $c70_t/root/graphify-out" && ! grepq "$out" -F "unstick --out $c70_out"; then pass "C70 default judges the root's graphify-out, not a graph under HOME"; else fail "C70 default root -> $(printf '%s' "$out" | head -3)"; fi
# the cadence merges into its own worktree graph; a station graph whose semantic layer is older is a divergence
c70_rows "" "" ""
printf '{"ts": "2026-10-17T00:00:00Z", "name": "t", "batch": 3, "failed": 0, "shrink_refused": 0, "failed_files": [], "refused_files": [], "backed_off_files": []}\n' > "$c70_t/root/graphify-out/semantic-runs.jsonl"
c70_div() { env HOME="$c70_t/home" CLAUDE_DIR="$c70_t/home/claude" HIMMEL_DOCTOR_ROOT="$c70_t/root" HIMMEL_DOCTOR_GRAPH_OUT= HIMMEL_DOCTOR_GRAPH_CHECK= HIMMEL_DOCTOR_CADENCE_OUT="$c70_out" "$@" bash "$DOC" --no-color --only C70 2>&1; }
out="$(c70_div)"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'cadence graph' && grepq "$out" -F "last=${c70_day}T02:00:00Z" && grepq "$out" -F 'until the cadence promotes its graph'; then pass "C70 station semantic layer older than the cadence graph -> WARN naming both"; else fail "C70 divergence -> $(printf '%s' "$out" | head -4)"; fi
cp "$c70_out/semantic-runs.jsonl" "$c70_t/root/graphify-out/semantic-runs.jsonl"
out="$(c70_div)"
if grepq "$out" -F 'C70-graph-semantic' && ! grepq "$out" -F 'cadence graph'; then pass "C70 station and cadence graph at the same semantic run -> no divergence row"; else fail "C70 equal -> $(printf '%s' "$out" | head -4)"; fi
out="$(c70_div HIMMEL_DOCTOR_CADENCE_OUT="$c70_t/no-such-cadence")"
if grepq "$out" -F 'C70-graph-semantic' && ! grepq "$out" -F 'cadence graph'; then pass "C70 no cadence graph -> no divergence row"; else fail "C70 no cadence -> $(printf '%s' "$out" | head -4)"; fi
printf '{"name": "t", "batch": 3, "failed": 0, "shrink_refused": 0, "failed_files": [], "refused_files": [], "backed_off_files": []}\n' > "$c70_out/semantic-runs.jsonl"
printf '{"ts": "2026-10-17T00:00:00Z", "name": "t", "batch": 3, "failed": 0, "shrink_refused": 0, "failed_files": [], "refused_files": [], "backed_off_files": []}\n' > "$c70_t/root/graphify-out/semantic-runs.jsonl"
out="$(c70_div LC_ALL=C)"
if grepq "$out" -F 'C70-graph-semantic' && ! grepq "$out" -F 'cadence graph'; then pass "C70 cadence last batch without a ts -> no divergence row"; else fail "C70 no ts -> $(printf '%s' "$out" | head -4)"; fi
c70_rows "x.md" "x.md" "x.md"
mkdir -p "$c70_t/adopter-home"
out="$(env HOME="$c70_t/adopter-home" HIMMEL_CONFIG_DIR= CLAUDE_DIR="$c70_t/adopter-home/claude" HIMMEL_DOCTOR_GRAPH_OUT="$c70_out" HIMMEL_DOCTOR_GRAPH_CHECK= bash "$DOC" --no-color --only C70 2>&1)"
if grepq "$out" -F 'OK   C70-graph-semantic' && grepq "$out" -F 'comes from us' && ! grepq "$out" -F 'refresh-graph-map.sh' && ! grepq "$out" 'WARN C70'; then pass "C70 an adopter with an old, stuck semantic-runs.jsonl -> OK naming the pull"; else fail "C70 adopter -> $(printf '%s' "$out" | head -3)"; fi
printf '#!/bin/sh\necho "graph-data: LAG the graph-data tip (built at abc1234) is 3d 4h old (bound 2d) while the live graph is built at def5678 (semantic layer: yes); cause: the cadence has not published it (read the cadence log)"\nexit 1\n' > "$c70_t/gds-lag.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_DATA_STATUS="$c70_t/gds-lag.sh")"
if grepq "$out" -F 'WARN C70-graph-data' && grepq "$out" -F 'graph-data: LAG the graph-data tip (built at abc1234) is 3d 4h old' && grepq "$out" -F 'bash scripts/graphify/graph-cadence.sh'; then pass "C70 a lagging graph-data tip -> WARN with the status line and the cadence remedy"; else fail "C70 graph-data LAG -> $(printf '%s' "$out" | head -4)"; fi
printf '#!/bin/sh\necho "graph-data: OK tip built at abc1234, 5h old; live graph built at abc1234"\nexit 0\n' > "$c70_t/gds-ok.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_DATA_STATUS="$c70_t/gds-ok.sh")"
if grepq "$out" -F 'OK   C70-graph-data' && grepq "$out" -F 'graph-data: OK tip built at abc1234'; then pass "C70 a current graph-data tip -> OK with the line"; else fail "C70 graph-data OK -> $(printf '%s' "$out" | head -4)"; fi
printf '#!/bin/sh\necho "graph-data: NEWER live graph built at def5678 is newer than the graph-data tip (built at abc1234, 2h old); semantic layer: yes"\nexit 4\n' > "$c70_t/gds-newer.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_DATA_STATUS="$c70_t/gds-newer.sh")"
if grepq "$out" -F 'OK   C70-graph-data' && ! grepq "$out" -F 'WARN C70-graph-data'; then pass "C70 a newer live graph inside the bound -> OK, not a WARN"; else fail "C70 graph-data NEWER -> $(printf '%s' "$out" | head -4)"; fi
printf '#!/bin/sh\necho "graph-data: UNKNOWN no live graph at /nowhere"\nexit 2\n' > "$c70_t/gds-unknown.sh"
out="$(c70_run HIMMEL_DOCTOR_GRAPH_DATA_STATUS="$c70_t/gds-unknown.sh")"
if grepq "$out" -F 'INFO C70-graph-data' && grepq "$out" -F 'no live graph at /nowhere'; then pass "C70 an unjudgeable graph-data status -> INFO"; else fail "C70 graph-data UNKNOWN -> $(printf '%s' "$out" | head -4)"; fi
out="$(env HOME="$c70_t/adopter-home" HIMMEL_CONFIG_DIR= CLAUDE_DIR="$c70_t/adopter-home/claude" HIMMEL_DOCTOR_GRAPH_OUT="$c70_out" HIMMEL_DOCTOR_GRAPH_CHECK= HIMMEL_DOCTOR_GRAPH_DATA_STATUS="$c70_t/gds-lag.sh" bash "$DOC" --no-color --only C70 2>&1)"
if ! grepq "$out" -F 'C70-graph-data'; then pass "C70 an adopter gets no graph-data row"; else fail "C70 adopter graph-data -> $(printf '%s' "$out" | head -4)"; fi
python3 - "$c70_out/semantic-manifest.json" "$c70_corpus/real.md" <<'PY'
import json, os, sys, time
json.dump({"version": 1, "files": {}, "stuck": {"real.md": {"hash": "h", "attempts": 1,
    "reason": "shrink guard: new 12 vs old 25 semantic nodes", "new_nodes": 12, "old_nodes": 25}}}, open(sys.argv[1], "w"))
t = time.time() - 8 * 86400
os.utime(sys.argv[2], (t, t))
PY
c70_row_at "$(c70_ago 1)" ""
out="$(c70_run)"
if grepq "$out" -F 'WARN C70-graph-semantic' && grepq "$out" -F 'real.md held by the shrink guard (new 12 vs old 25 semantic nodes)'; then pass "C70 a SEMANTIC-STALE WARN names the file the shrink guard holds, with its counts"; else fail "C70 held by the shrink guard -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c70_t"

echo "== C71: judge scratch cache size =="
c71_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c71.XXXXXX")" || { fail "C71 mktemp -d failed"; exit 1; }
mkdir -p "$c71_t/cache/q1" "$c71_t/home" "$c71_t/claude"
head -c 3072 /dev/zero > "$c71_t/cache/q1/blob"
c71_run() { env HOME="$c71_t/home" CLAUDE_DIR="$c71_t/claude" HIMMEL_DOCTOR_VERDICT_CACHE="$c71_t/cache" "$@" bash "$DOC" --no-color --only C71 2>&1; }
out="$(c71_run HIMMEL_DOCTOR_VERDICT_CACHE_KB=1)"
if grepq "$out" -F 'WARN C71-verdict-scratch' && grepq "$out" -F 'verdict-retention.sh prune'; then pass "C71 cache above the threshold -> WARN naming the pruner"; else fail "C71 over -> $(printf '%s' "$out" | head -3)"; fi
if grepq "$out" -F 'prune --unproven-older-than 14'; then pass "C71 hint names the flag that frees unprovable scratch"; else fail "C71 hint lacks --unproven-older-than 14 (plain prune frees nothing when no PR is provable): $(printf '%s' "$out" | head -3)"; fi
out="$(c71_run HIMMEL_DOCTOR_VERDICT_CACHE_KB=1024)"
if grepq "$out" -F 'OK   C71-verdict-scratch' && ! grepq "$out" -F 'WARN C71'; then pass "C71 cache below the threshold -> OK"; else fail "C71 under -> $(printf '%s' "$out" | head -3)"; fi
out="$(c71_run HIMMEL_DOCTOR_VERDICT_CACHE_KB=08)"
if grepq "$out" -F 'C71-verdict-scratch' && ! grepq "$out" -F 'did not complete'; then pass "C71 a leading-zero limit is decimal, not an octal abort"; else fail "C71 08 -> $(printf '%s' "$out" | head -3)"; fi
out="$(c71_run HIMMEL_DOCTOR_VERDICT_CACHE_KB=abc)"
if grepq "$out" -F 'OK   C71-verdict-scratch' && grepq "$out" -F 'warn above 5120 MB'; then pass "C71 a non-numeric limit falls back to the 5 GB default"; else fail "C71 abc -> $(printf '%s' "$out" | head -3)"; fi
out="$(c71_run HIMMEL_DOCTOR_VERDICT_CACHE="$c71_t/no-such-cache")"
if grepq "$out" -F 'OK   C71-verdict-scratch' && grepq "$out" -F 'no judge scratch cache'; then pass "C71 absent cache -> OK skip"; else fail "C71 absent -> $(printf '%s' "$out" | head -3)"; fi
rm -rf "$c71_t"

# --- C72-design-mcp-auth: design profile MCP logins ---------------
# Reads $CLAUDE_DIR/.credentials.json mcpOAuth (server names only, never token
# values); silent when the file is absent (keychain platforms). A plugin's server
# is stored as plugin:<plugin>:<server>, with serverName equal to the key prefix.
c72_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c72.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c72_t/home" "$c72_t/claude"
c72_run() { PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c72_t/claude" HOME="$c72_t/home" bash "$DOC" --no-color 2>&1; }
echo "== C72-design-mcp-auth: credentials file without either login -> WARN naming both =="
printf '{"mcpOAuth":{"plugin:atlassian:atlassian|x":{"serverName":"plugin:atlassian:atlassian","accessToken":"t"}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'WARN C72-design-mcp-auth' && grepq "$out" -F 'context7' && grepq "$out" -F 'agent-native-dispatch' && grepq "$out" -F '/mcp'; then pass "C72 neither login -> WARN naming both and /mcp"; else fail "C72 none -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: only context7 logged in -> WARN names agent-native-dispatch only =="
printf '{"mcpOAuth":{"plugin:context7:context7|x":{"serverName":"plugin:context7:context7","accessToken":"t"}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'WARN C72-design-mcp-auth' && grepq "$out" -F 'agent-native-dispatch' && ! grepq "$out" -F 'missing: context7'; then pass "C72 partial -> WARN for the missing one only"; else fail "C72 partial -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: an entry with no accessToken counts as missing =="
printf '{"mcpOAuth":{"plugin:context7:context7|x":{"serverName":"plugin:context7:context7","accessToken":"t"},"plugin:builder-visual:agent-native-dispatch|y":{"serverName":"plugin:builder-visual:agent-native-dispatch"}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'WARN C72-design-mcp-auth' && grepq "$out" -F 'agent-native-dispatch'; then pass "C72 tokenless entry -> WARN"; else fail "C72 tokenless -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: an empty accessToken counts as missing =="
printf '{"mcpOAuth":{"plugin:context7:context7|x":{"serverName":"plugin:context7:context7","accessToken":"t"},"plugin:builder-visual:agent-native-dispatch|y":{"serverName":"plugin:builder-visual:agent-native-dispatch","accessToken":""}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'WARN C72-design-mcp-auth' && grepq "$out" -F 'agent-native-dispatch'; then pass "C72 empty accessToken -> WARN"; else fail "C72 empty token -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: both logged in under plugin-scoped names -> OK, no warning =="
printf '{"mcpOAuth":{"plugin:context7:context7|x":{"serverName":"plugin:context7:context7","accessToken":"t"},"plugin:builder-visual:agent-native-dispatch|y":{"serverName":"plugin:builder-visual:agent-native-dispatch","accessToken":"t"}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'OK   C72-design-mcp-auth' && ! grepq "$out" 'WARN C72'; then pass "C72 both -> OK"; else fail "C72 both -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: bare (user-level) server names also count -> OK =="
printf '{"mcpOAuth":{"context7|x":{"serverName":"context7","accessToken":"t"},"agent-native-dispatch|y":{"serverName":"agent-native-dispatch","accessToken":"t"}}}' > "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'OK   C72-design-mcp-auth' && ! grepq "$out" 'WARN C72'; then pass "C72 bare names -> OK"; else fail "C72 bare -> $(printf '%s' "$out" | grep -A1 C72)"; fi
echo "== C72-design-mcp-auth: no credentials file -> silent =="
rm -f "$c72_t/claude/.credentials.json"
out="$(c72_run)"
if grepq "$out" 'C72-design-mcp-auth'; then fail "C72 no file -> $(printf '%s' "$out" | grep -A1 C72)"; else pass "C72 no credentials file -> silent"; fi
rm -rf "$c72_t"

# --- C73-bun-compiled: a bun build --compile binary embedding a Bun older than .bun-version ---
# The stub carries the string a real compiled binary holds: the URL form below is
# copied from the station's coderabbit 0.9.0 (grep -ao around the first match).
echo "== C73-bun-compiled: embedded Bun older than the pin / equal / newer / not executable / too deep =="
c73_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c73.XXXXXX")" || { fail "C73 mktemp -d failed"; exit 1; }
mkdir -p "$c73_t/home" "$c73_t/claude" "$c73_t/bin" "$c73_t/deep/a/b/c"
printf '1.4.4\n' > "$c73_t/.bun-version"
c73_stub() { printf 'en\0N\0\0\0\0\0\0\0https://github.com/oven-sh/bun/releases/download/bun-v%s/bun-linux-x64.zip\0\0\0\0.js.tsvm\n' "$2" > "$1"; chmod +x "$1"; }
c73_run() { env HOME="$c73_t/home" CLAUDE_DIR="$c73_t/claude" HIMMEL_DOCTOR_BUN_VERSION_FILE="$c73_t/.bun-version" HIMMEL_DOCTOR_BUN_MIN_KB=0 HIMMEL_DOCTOR_ACK_FILE="$c73_t/ack.txt" HIMMEL_DOCTOR_BUN_SCAN_DIRS="$1" bash "$DOC" --no-color --only C73 2>&1; }
c73_stub "$c73_t/bin/stale-tool" 1.4.2
out="$(c73_run "$c73_t/bin")"
if grepq "$out" -F 'WARN C73-bun-compiled' && grepq "$out" -F "$c73_t/bin/stale-tool" && grepq "$out" -F 'Bun 1.4.2' && grepq "$out" -F '1.4.4'; then pass "C73 bun-v1.4.2 vs pin 1.4.4 -> WARN naming the binary and both versions"; else fail "C73 stale -> $(printf '%s' "$out" | head -3)"; fi
rm -f "$c73_t/bin/stale-tool"
c73_stub "$c73_t/bin/ok-tool" 1.4.4
out="$(c73_run "$c73_t/bin")"
if grepq "$out" -F 'OK   C73-bun-compiled' && ! grepq "$out" -F 'WARN C73'; then pass "C73 bun-v1.4.4 equals the pin -> OK"; else fail "C73 equal -> $(printf '%s' "$out" | head -3)"; fi
c73_stub "$c73_t/bin/ok-tool" 1.4.10
out="$(c73_run "$c73_t/bin")"
if grepq "$out" -F 'OK   C73-bun-compiled' && ! grepq "$out" -F 'WARN C73'; then pass "C73 bun-v1.4.10 is newer than 1.4.4 (numeric, not lexical) -> OK"; else fail "C73 newer -> $(printf '%s' "$out" | head -3)"; fi
rm -f "$c73_t/bin/ok-tool"
c73_stub "$c73_t/bin/not-exec" 1.4.2; chmod -x "$c73_t/bin/not-exec"
out="$(c73_run "$c73_t/bin")"
if grepq "$out" -F 'OK   C73-bun-compiled' && ! grepq "$out" -F 'WARN C73'; then pass "C73 a non-executable file with a stale string is not a binary -> OK"; else fail "C73 non-exec -> $(printf '%s' "$out" | head -3)"; fi
c73_stub "$c73_t/deep/a/b/c/stale-tool" 1.4.2
out="$(c73_run "$c73_t/deep")"
if grepq "$out" -F 'OK   C73-bun-compiled' && ! grepq "$out" -F 'WARN C73'; then pass "C73 a binary below maxdepth 3 is out of scope -> OK"; else fail "C73 depth -> $(printf '%s' "$out" | head -3)"; fi
mkdir -p "$c73_t/real" "$c73_t/links"
c73_stub "$c73_t/real/stale-tool" 1.4.2
ln -s "$c73_t/real/stale-tool" "$c73_t/links/stale-link"
out="$(c73_run "$c73_t/links")"
if grepq "$out" -F 'WARN C73-bun-compiled' && grepq "$out" -F "$c73_t/links/stale-link"; then pass "C73 an executable symlink is followed to its stale target -> WARN"; else fail "C73 symlink -> $(printf '%s' "$out" | head -3)"; fi
out="$(c73_run "$c73_t/no-such-dir")"
if grepq "$out" -F 'OK   C73-bun-compiled'; then pass "C73 absent scan dir -> OK"; else fail "C73 absent -> $(printf '%s' "$out" | head -3)"; fi
mkdir -p "$c73_t/snz"
c73_stub "$c73_t/snz/cr" 1.4.2
out="$(c73_run "$c73_t/snz")"
if grepq "$out" -F 'WARN C73-bun-compiled' && grepq "$out" -F 'C73-bun-compiled' && grepq "$out" -F "$c73_t/ack.txt"; then pass "C73 no ack line -> WARN, remedy names the ack file"; else fail "C73 no ack -> $(printf '%s' "$out" | head -3)"; fi
printf 'C73-bun-compiled %s 1.4.2\n' "$c73_t/snz/cr" > "$c73_t/ack.txt"
out="$(c73_run "$c73_t/snz")"
if grepq "$out" -F 'INFO C73-bun-compiled' && grepq "$out" -F "$c73_t/snz/cr" && ! grepq "$out" -F 'WARN C73'; then pass "C73 ack line matching path and embedded version -> INFO, no WARN"; else fail "C73 ack match -> $(printf '%s' "$out" | head -3)"; fi
printf 'C73-bun-compiled %s 1.4.1\n' "$c73_t/snz/cr" > "$c73_t/ack.txt"
out="$(c73_run "$c73_t/snz")"
if grepq "$out" -F 'WARN C73-bun-compiled' && ! grepq "$out" -F 'INFO C73-bun-compiled'; then pass "C73 ack line for an older embedded version -> still WARN"; else fail "C73 ack older -> $(printf '%s' "$out" | head -3)"; fi
printf 'C73-bun-compiled %s/other 1.4.2\n' "$c73_t/snz" > "$c73_t/ack.txt"
out="$(c73_run "$c73_t/snz")"
if grepq "$out" -F 'WARN C73-bun-compiled'; then pass "C73 ack line for a different path -> still WARN"; else fail "C73 ack other path -> $(printf '%s' "$out" | head -3)"; fi
rm -rf "$c73_t"

# --- C74-config-split: himmel.conf, config keys left in .env, the policy file ---
# Reads KEY NAMES only (never values); HIMMEL_DOCTOR_ENV_FILE is the .env seam.
# Fixture values are planted dummies.
c74_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c74.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c74_t/home/.himmel" "$c74_t/claude"
c74_pol="$c74_t/home/.himmel/config.json"
c74_conf="$c74_t/home/.himmel/himmel.conf"
c74_run() { PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c74_t/claude" HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_DIR="" HIMMEL_DOCTOR_ENV_FILE="$c74_t/env" bash "$DOC" --root "$REPO_ROOT" --no-color --only C74 2>&1; }
c74_reset() { rm -f "$c74_t/env" "$c74_conf" "$c74_conf.local" "$c74_pol"; }
echo "== C74-config-split: a config-class key still in .env -> WARN naming the key, never the value =="
c74_reset
printf 'JIRA_EMAIL=planted-dummy-value-74\nOPERATOR_SCRATCH_NOTE=planted-note-74\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-env-keys' && grepq "$out" -F 'JIRA_EMAIL' && grepq "$out" -F 'migrate-env-config.sh' && ! grepq "$out" -F 'OPERATOR_SCRATCH_NOTE' && ! grepq "$out" -F 'planted-'; then pass "C74 config key in .env -> WARN naming JIRA_EMAIL only, no values"; else fail "C74 env key -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: the env-keys remedy names the update's migration with the real .env and no hand edit =="
if grepq "$out" -F "scripts/setup/migrate-env.sh --env $c74_t/env" && grepq "$out" -F 'ENV_MIGRATION_CONSENT' && ! grepq "$out" -F 'by hand'; then pass "C74 env-keys remedy -> migrate-env.sh --env <real .env>, consent key named, no hand delete"; else fail "C74 env-keys remedy -> $(printf '%s' "$out" | head -6)"; fi
echo "== C74-config-split: the policy remedies name the same migration with the real .env =="
c74_reset
printf 'ARMAUTOMERGE=1\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F "scripts/setup/migrate-env.sh --env $c74_t/env"; then pass "C74 policy remedy (no config.json) -> migrate-env.sh --env <real .env>"; else fail "C74 policy remedy -> $(printf '%s' "$out" | head -6)"; fi
printf '{"policy":{"CR_FLOOR_FALLBACK":"claude-only"}}' > "$c74_pol"
printf 'ARMAUTOMERGE=1\nCR_FLOOR_FALLBACK=claude-only\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F "scripts/setup/migrate-env.sh --env $c74_t/env"; then pass "C74 policy remedy (key missing from .policy) -> migrate-env.sh --env <real .env>"; else fail "C74 policy remedy 2 -> $(printf '%s' "$out" | head -6)"; fi
echo "== C74-config-split: migrated (secrets-only .env, himmel.conf, policy file) -> OK =="
c74_reset
printf 'OPERATOR_SCRATCH_NOTE=planted-note-74\n' > "$c74_t/env"
printf 'JIRA_EMAIL=moved@example.invalid\n' > "$c74_conf"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1"}}' > "$c74_pol"
out="$(c74_run)"
if grepq "$out" -F 'OK   C74-himmel-conf' && grepq "$out" -F 'OK   C74-env-keys' && grepq "$out" -F 'OK   C74-policy' && ! grepq "$out" -E '(WARN|INFO) C74'; then pass "C74 migrated station -> three OK rows"; else fail "C74 migrated -> $(printf '%s' "$out" | head -6)"; fi
echo "== C74-config-split: himmel.conf absent on a never-migrated install -> INFO =="
c74_reset
printf 'OPERATOR_SCRATCH_NOTE=planted-note-74\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'INFO C74-himmel-conf' && ! grepq "$out" -F 'WARN C74'; then pass "C74 no himmel.conf, nothing to migrate -> INFO only"; else fail "C74 absent conf -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: JIRA_BASE_URL in .env warns until migrated (HIMMEL-8244) =="
c74_reset
printf 'JIRA_BASE_URL=https://planted.example\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-env-keys' && grepq "$out" -F 'JIRA_BASE_URL' && ! grepq "$out" -F 'planted.example'; then pass "C74 JIRA_BASE_URL in .env -> WARN naming key only"; else fail "C74 JIRA_BASE_URL -> $(printf '%s' "$out" | head -4)"; fi
printf 'JIRA_BASE_URL=https://planted.example\n' > "$c74_conf"
printf 'JIRA_API_TOKEN=dummy-token\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'OK   C74-env-keys' && ! grepq "$out" -F 'JIRA_BASE_URL' && ! grepq "$out" -F 'planted.example'; then pass "C74 migrated JIRA_BASE_URL removed from .env -> OK, no URL warning or value"; else fail "C74 migrated JIRA_BASE_URL -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: himmel.conf with a line that is not KEY=value -> WARN =="
c74_reset
printf 'HANDOVER_DIR=/x\nthis line is not a setting\n' > "$c74_conf"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-himmel-conf' && grepq "$out" -F 'line 2'; then pass "C74 unparseable himmel.conf -> WARN naming the line"; else fail "C74 bad conf -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: himmel.conf as a dangling link -> WARN =="
c74_reset
ln -s "$c74_t/no-such-vault/himmel.conf" "$c74_conf"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-himmel-conf'; then pass "C74 dangling himmel.conf link -> WARN"; else fail "C74 dangling -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: a directory at the himmel.conf path -> WARN, never OK =="
c74_reset
mkdir -p "$c74_conf"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-himmel-conf' && ! grepq "$out" -F 'OK   C74-himmel-conf'; then pass "C74 himmel.conf is a directory -> WARN"; else fail "C74 conf dir -> $(printf '%s' "$out" | head -4)"; fi
rmdir "$c74_conf"
echo "== C74-config-split: a policy key still in .env, no policy file -> WARN naming the key =="
c74_reset
printf 'ARMAUTOMERGE=1\n' > "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-policy' && grepq "$out" -F 'ARMAUTOMERGE' && grepq "$out" -F 'config.json'; then pass "C74 policy key in .env without config.json -> WARN"; else fail "C74 env policy -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: a policy key in .env missing from .policy -> WARN naming only it =="
c74_reset
printf 'ARMAUTOMERGE=1\nCR_FLOOR_FALLBACK=claude-only\n' > "$c74_t/env"
printf '{"policy":{"CR_FLOOR_FALLBACK":"claude-only"}}' > "$c74_pol"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-policy' && grepq "$out" -F 'ARMAUTOMERGE' && ! grepq "$out" -F 'CR_FLOOR_FALLBACK'; then pass "C74 only the unmoved policy key is named"; else fail "C74 partial policy -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: the policy file is not valid JSON -> WARN =="
c74_reset
printf '{not json' > "$c74_pol"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-policy' && grepq "$out" -F 'fails closed'; then pass "C74 unparseable policy file -> WARN (gates fail closed)"; else fail "C74 bad json -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: no policy file and no policy key in .env -> INFO =="
c74_reset
out="$(c74_run)"
if grepq "$out" -F 'INFO C74-policy' && ! grepq "$out" -F 'WARN C74'; then pass "C74 no policy file, nothing relies on it -> INFO"; else fail "C74 no policy -> $(printf '%s' "$out" | head -4)"; fi
echo "== C74-config-split: an unreadable .env path -> WARN unchecked, never OK or safe defaults =="
c74_reset
mkdir -p "$c74_t/env"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-env-keys' && grepq "$out" -F 'not checked' && ! grepq "$out" -F 'OK   C74-env-keys' && ! grepq "$out" -F 'safe default'; then pass "C74 unreadable .env -> WARN unchecked"; else fail "C74 unreadable env -> $(printf '%s' "$out" | head -4)"; fi
rmdir "$c74_t/env"
echo "== C74-config-split: config.json gone on an installed station -> FAIL =="
c74_reset
mkdir -p "$c74_t/home/.claude/himmel"
printf '{}\n' > "$c74_t/home/.claude/himmel/install-profile.json"
# A no-op install never creates config.json: with no sign it ever existed, INFO.
out="$(c74_run)"
if grepq "$out" -F 'INFO C74-policy' && ! grepq "$out" -F 'FAIL C74-policy'; then pass "C74 installed station that never had config.json -> INFO"; else fail "C74 installed never-had policy -> $(printf '%s' "$out" | head -6)"; fi
mkdir -p "$c74_t/home/.himmel/state/config-audit/backups/20261031T120000Z-ab12"
printf '{}\n' > "$c74_t/home/.himmel/state/config-audit/backups/20261031T120000Z-ab12/config.json"
out="$(c74_run)"
if grepq "$out" -F 'FAIL C74-policy' && grepq "$out" -F 'installed station' && grepq "$out" -F 'config-audit.sh list'; then pass "C74 installed station without config.json -> FAIL naming the restore"; else fail "C74 installed no policy -> $(printf '%s' "$out" | head -6)"; fi
# No backup, but the last snapshot recorded config.json: it existed, so FAIL.
rm -rf "$c74_t/home/.himmel/state/config-audit/backups"
printf '{"config.json":{"present":true,"keys":["policy"]}}\n' > "$c74_t/home/.himmel/state/config-audit/watch.json"
out="$(c74_run)"
if grepq "$out" -F 'FAIL C74-policy' && grepq "$out" -F 'installed station'; then pass "C74 installed station whose snapshot recorded config.json -> FAIL"; else fail "C74 watch-recorded policy -> $(printf '%s' "$out" | head -6)"; fi
rm -rf "$c74_t/home/.claude/himmel" "$c74_t/home/.himmel/state"
echo "== C74-config-keys: a key lost since the snapshot -> WARN naming the key, never the value (HIMMEL-8401) =="
c74_reset
printf 'OPERATOR_SCRATCH_NOTE=planted-note-74\n' > "$c74_t/env"
printf 'JIRA_EMAIL=planted-dummy-value-74\nHANDOVER_DIR=/planted-74\n' > "$c74_conf"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1"}}' > "$c74_pol"
out="$(c74_run)"
if grepq "$out" -F 'OK   C74-config-keys'; then pass "C74-config-keys with no loss -> OK"; else fail "C74-config-keys no loss -> $(printf '%s' "$out" | head -6)"; fi
HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_ENV_FILE="$c74_t/env" bash "$REPO_ROOT/scripts/lib/config-audit.sh" accept >/dev/null 2>&1
printf 'HANDOVER_DIR=/planted-74\n' > "$c74_conf"
out="$(c74_run)"
if grepq "$out" -F 'WARN C74-config-keys' && grepq "$out" -F 'JIRA_EMAIL' && ! grepq "$out" -F 'planted-'; then pass "C74-config-keys lost JIRA_EMAIL -> WARN naming the key only"; else fail "C74-config-keys lost key -> $(printf '%s' "$out" | head -8)"; fi
echo "== C74-config-keys: a deleted empty file keeps its row's fields in place (HIMMEL-8401) =="
printf 'JIRA_EMAIL=planted-dummy-value-74\nHANDOVER_DIR=/planted-74\n' > "$c74_conf"
: > "$c74_conf.local"
HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_ENV_FILE="$c74_t/env" bash "$REPO_ROOT/scripts/lib/config-audit.sh" accept >/dev/null 2>&1
rm -f "$c74_conf.local"
out="$(c74_run)"
if grepq "$out" -E '^WARN C74-config-keys: (.*; )?himmel\.conf\.local: deleted; newest good backup: -$' && ! grepq "$out" -F "backup: $c74_conf.local"; then pass "C74-config-keys deleted empty file -> WARN with its fields in place"; else fail "C74-config-keys empty loss -> $(printf '%s' "$out" | head -8)"; fi
echo "== C74 run from another repo's directory reads the checkout's .env, never the caller's =="
c74_reset; rm -rf "$c74_t/home/.himmel/state"
c74_p="$c74_t/proj"; c74_away="$c74_t/away"; mkdir -p "$c74_p" "$c74_away"
git init -q "$c74_p"; git init -q "$c74_away"
ln -s "$REPO_ROOT/scripts" "$c74_p/scripts"
printf 'JIRA_EMAIL=planted-dummy-value-74\nOPERATOR_SCRATCH_NOTE=planted-note-74\n' > "$c74_p/.env"
printf '{"policy":{"CR_REQUIRE_CROSS_MODEL":"1"}}' > "$c74_pol"
HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_ENV_FILE="$c74_p/.env" bash "$REPO_ROOT/scripts/lib/config-audit.sh" accept >/dev/null 2>&1
c74_away_run() { (cd "$c74_away" && env -u HIMMEL_DOCTOR_ENV_FILE -u HIMMEL_REPO -u HIMMEL_CONFIG_AUDIT_ENV_FILE PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c74_t/claude" HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_DIR="" "$@" bash "$DOC" --root "$c74_p" --no-color --only C74 2>&1); }
out="$(c74_away_run)"
if grepq "$out" -F 'WARN C74-env-keys' && grepq "$out" -F 'JIRA_EMAIL' && grepq "$out" -F 'OK   C74-config-keys' && ! grepq "$out" -F 'deleted' && ! grepq "$out" -F 'planted-'; then pass "C74 from another repo's directory reads the checkout .env: env-keys names JIRA_EMAIL, config-keys OK"; else fail "C74 from another repo's directory -> $(printf '%s' "$out" | head -6)"; fi
echo "== C74-config-keys: a .env that is not the recorded one -> INFO, never OK and never deleted =="
out="$(c74_away_run HIMMEL_REPO="$c74_away")"
if grepq "$out" -F 'INFO C74-config-keys' && ! grepq "$out" -F 'OK   C74-config-keys' && ! grepq "$out" -F 'deleted'; then pass "C74-config-keys with the .env read elsewhere than recorded -> INFO"; else fail "C74-config-keys unrecorded .env -> $(printf '%s' "$out" | head -6)"; fi
echo "== config-audit accept from another repo's directory, with no recorded .env there -> exit 1, watch.json unchanged =="
c74_w="$c74_t/home/.himmel/state/config-audit/watch.json"; cp "$c74_w" "$c74_t/watch.before"
c74_rc=0; (cd "$c74_away" && env -u HIMMEL_CONFIG_AUDIT_ENV_FILE HOME="$c74_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_CONFIG_AUDIT_DIR="" HIMMEL_REPO="$c74_away" bash "$c74_p/scripts/lib/config-audit.sh" accept >/dev/null 2>&1) || c74_rc=$?
if [ "$c74_rc" -eq 1 ] && cmp -s "$c74_w" "$c74_t/watch.before"; then pass "accept from another repo's directory -> exit 1, watch.json bytes unchanged"; else fail "accept from another repo's directory -> rc=$c74_rc, watch.json changed: $(cmp "$c74_w" "$c74_t/watch.before" 2>&1)"; fi
rm -rf "$c74_t"

# --- C75-keyring: keyring state and the layer serving each manifest secret ---
# A stub secret-tool and busctl stand in for the keyring; values are planted
# dummies and must never appear in the output.
c75_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c75.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c75_t/bin" "$c75_t/home" "$c75_t/claude"
cat > "$c75_t/bin/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$C75_LOG"
[ "$1" = lookup ] || exit 1
shift
q=""
while [ "$#" -ge 2 ]; do q="$q $1=$2"; shift 2; done
while IFS="$(printf '\t')" read -r attrs val; do
    m=1
    for p in $q; do case " $attrs " in *" $p "*) ;; *) m=0 ;; esac; done
    if [ "$m" = 1 ]; then printf '%s' "$val"; exit 0; fi
done <"$C75_STORE"
exit 1
STUB
cat > "$c75_t/bin/busctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *" Locked") echo "b ${C75_LOCKED:-false}" ;; esac
STUB
chmod +x "$c75_t/bin/secret-tool" "$c75_t/bin/busctl"
c75_run() { env -u JIRA_BASE_URL -u JIRA_API_TOKEN -u TELEGRAM_BOT_TOKEN -u CREDENTIALS_DIRECTORY PATH="$c75_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c75_t/claude" HOME="$c75_t/home" \
    HIMMEL_DOCTOR_ENV_FILE="$c75_t/env" C75_STORE="$c75_t/store" C75_LOG="$c75_t/log" DBUS_SESSION_BUS_ADDRESS="unix:path=$c75_t/bus" \
    HIMMEL_CONFIG_DIR="" HIMMEL_SECRETS_KEYRING="${C75_KEYRING:-}" bash "$DOC" --root "$REPO_ROOT" --no-color --only C75 2>&1; }
c75_reset() { rm -f "$c75_t/env" "$c75_t/log"; : > "$c75_t/store"; }
# The resolver reports no keyring backend on Darwin, so only the off case runs there.
if [ "$(uname -s)" = Darwin ]; then
    echo "SKIP C75 unlocked/locked cases: no keyring backend on Darwin"
else
echo "== C75-keyring: unlocked keyring, one secret still in .env -> WARN naming it, never a value =="
c75_reset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tplanted-keyring-value\n' > "$c75_t/store"
printf 'TELEGRAM_BOT_TOKEN=planted-dotenv-value\nJIRA_EMAIL=planted@example.com\n' > "$c75_t/env"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-keyring' && grepq "$out" -F 'WARN C75-secrets' && grepq "$out" -F 'TELEGRAM_BOT_TOKEN' && grepq "$out" -F 'migrate-env.sh --env' && ! grepq "$out" -F 'import-env' \
    && ! grepq "$out" -F 'JIRA_EMAIL' && ! grepq "$out" -F 'planted'; then pass "C75 secret in .env with an unlocked keyring -> WARN naming TELEGRAM_BOT_TOKEN only, no values"; else fail "C75 dotenv secret -> $(printf '%s' "$out" | head -4)"; fi
echo "== C75-keyring: every secret from the keyring, no .env -> OK =="
c75_reset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tplanted-keyring-value\n' > "$c75_t/store"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-keyring' && grepq "$out" -F 'OK   C75-secrets' && grepq "$out" -F '1 from the keyring' && ! grepq "$out" -F 'planted'; then pass "C75 keyring-served station -> two OK rows"; else fail "C75 keyring -> $(printf '%s' "$out" | head -4)"; fi
echo "== C75-config-keys: a served credential whose paired setting resolves nowhere -> WARN naming the setting =="
c75_reset
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tplanted-keyring-value\n' > "$c75_t/store"
out="$(c75_run)"
if grepq "$out" -F 'WARN C75-config-keys' && grepq "$out" -F 'JIRA_BASE_URL' && ! grepq "$out" -F 'planted'; then pass "C75 token without JIRA_BASE_URL -> WARN naming it"; else fail "C75 missing config key -> $(printf '%s' "$out" | head -5)"; fi
printf 'JIRA_BASE_URL=https://planted.example\n' > "$c75_t/env"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-config-keys' && ! grepq "$out" -F 'planted.example'; then pass "C75 JIRA_BASE_URL in .env -> OK"; else fail "C75 config key present -> $(printf '%s' "$out" | head -5)"; fi
mkdir -p "$c75_t/home/.himmel"
printf 'JIRA_BASE_URL=https://planted.example\n' > "$c75_t/home/.himmel/himmel.conf"
rm -f "$c75_t/env"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-config-keys' && ! grepq "$out" -F 'planted.example'; then pass "C75 JIRA_BASE_URL in himmel.conf without .env -> OK"; else fail "C75 URL in config -> $(printf '%s' "$out" | head -5)"; fi
rm -f "$c75_t/home/.himmel/himmel.conf"
echo "== C75-config-keys: the Telegram pair names both chat ids; himmel.conf and a profile layer resolve them =="
c75_reset
printf 'TELEGRAM_BOT_TOKEN=planted-bot\n' > "$c75_t/env"
out="$(c75_run)"
if grepq "$out" -F 'WARN C75-config-keys' && grepq "$out" -F 'TELEGRAM_CHAT_ID' && grepq "$out" -F 'TELEGRAM_GROUP_CHAT_ID' && ! grepq "$out" -F 'planted'; then pass "C75 bot token without chat ids -> WARN naming both"; else fail "C75 telegram pair -> $(printf '%s' "$out" | head -5)"; fi
mkdir -p "$c75_t/home/.himmel"
printf 'TELEGRAM_CHAT_ID=1\nTELEGRAM_GROUP_CHAT_ID=2\n' > "$c75_t/home/.himmel/himmel.conf"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-config-keys'; then pass "C75 chat ids in himmel.conf -> OK"; else fail "C75 chat ids in himmel.conf -> $(printf '%s' "$out" | head -5)"; fi
rm -f "$c75_t/home/.himmel/himmel.conf"
mkdir -p "$c75_t/vault/.himmel/profiles"
printf 'TELEGRAM_CHAT_ID=1\nTELEGRAM_GROUP_CHAT_ID=2\n' > "$c75_t/vault/.himmel/profiles/p.conf"
: > "$c75_t/vault/.himmel/himmel.conf"
ln -sf "$c75_t/vault/.himmel/himmel.conf" "$c75_t/home/.himmel/himmel.conf"
out="$(HIMMEL_PROFILE=p c75_run)"
if grepq "$out" -F 'OK   C75-config-keys'; then pass "C75 chat ids in the active profile layer -> OK"; else fail "C75 chat ids in a profile -> $(printf '%s' "$out" | head -5)"; fi
rm -f "$c75_t/home/.himmel/himmel.conf"
echo "== C75-config-keys: an optional defaulted key resolving nowhere is not reported =="
c75_reset
printf 'JIRA_BASE_URL=https://planted.example\n' > "$c75_t/env"
printf 'service=himmel key=JIRA_API_TOKEN scope=user\tplanted-keyring-value\n' > "$c75_t/store"
out="$(c75_run)"
if grepq "$out" -F 'OK   C75-config-keys' && ! grepq "$out" -F 'WHISPER_MODEL' && ! grepq "$out" -F 'FIRECRAWL_BASE_URL'; then pass "C75 unset WHISPER_MODEL/FIRECRAWL_BASE_URL -> not reported"; else fail "C75 optional keys -> $(printf '%s' "$out" | head -5)"; fi
echo "== C75-keyring: a locked keyring -> WARN, no lookup =="
c75_reset
out="$(C75_LOCKED=true c75_run)"
if grepq "$out" -F 'WARN C75-keyring' && grepq "$out" -F 'locked' && [ ! -s "$c75_t/log" ]; then pass "C75 locked keyring -> WARN with no secret-tool call"; else fail "C75 locked -> $(printf '%s' "$out" | head -4)"; fi
fi
echo "== C75-keyring: HIMMEL_SECRETS_KEYRING=off -> INFO, no lookup, a .env secret is INFO =="
c75_reset
printf 'TELEGRAM_BOT_TOKEN=planted-dotenv-value\n' > "$c75_t/env"
out="$(C75_KEYRING=off c75_run)"
if grepq "$out" -F 'INFO C75-keyring' && grepq "$out" -F 'INFO C75-secrets' && [ ! -s "$c75_t/log" ] && ! grepq "$out" -F 'planted'; then pass "C75 keyring off -> INFO rows, no secret-tool call"; else fail "C75 off -> $(printf '%s' "$out" | head -4)"; fi
# The secret key set is the resolver's `names --class secret` (one owner), not a list derived here.
# A copy of the doctor beside a logging wrapper over the real resolver shows what C75 asks it.
echo "== C75: the secret key set comes from himmel-secrets names =="
c75_x="$c75_t/scripts"
mkdir -p "$c75_x/lib" "$c75_x/himmelctl/lib"
cp "$REPO_ROOT/scripts/himmel-doctor.sh" "$c75_x/"
cp -R "$REPO_ROOT/scripts/lib/." "$c75_x/lib/"
cp "$REPO_ROOT/scripts/himmelctl/lib/secrets-manifest.json" "$c75_x/himmelctl/lib/"
mv "$c75_x/lib/himmel-secrets" "$c75_x/lib/himmel-secrets.real"
# shellcheck disable=SC2016 # the wrapper expands its own variables
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$C75_NAMES_LOG"\nexec bash "${BASH_SOURCE[0]}.real" "$@"\n' > "$c75_x/lib/himmel-secrets"
chmod +x "$c75_x/lib/himmel-secrets"
c75_reset
printf 'TELEGRAM_BOT_TOKEN=planted-dotenv-value\n' > "$c75_t/env"
: > "$c75_t/names.log"
out="$(C75_NAMES_LOG="$c75_t/names.log" C75_KEYRING=off env -u TELEGRAM_BOT_TOKEN HIMMEL_DOCTOR_ENV_FILE="$c75_t/env" PATH="$c75_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c75_t/claude" HOME="$c75_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_SECRETS_KEYRING=off C75_NAMES_LOG="$c75_t/names.log" bash "$c75_x/himmel-doctor.sh" --root "$REPO_ROOT" --no-color --only C75 2>&1)"
if grepq "$out" -F 'INFO C75-secrets' && grepq "$out" -F 'TELEGRAM_BOT_TOKEN' && grep -qx 'names --class secret' "$c75_t/names.log"; then pass "C75 asks himmel-secrets names --class secret for its key set"; else fail "C75 names -> log '$(cat "$c75_t/names.log")', $(printf '%s' "$out" | head -4)"; fi
echo "== C75: a failing himmel-secrets names is not reported as OK =="
# shellcheck disable=SC2016 # the wrapper expands its own variables
printf '#!/usr/bin/env bash\ncase "$1" in names) exit 1 ;; esac\nexec bash "${BASH_SOURCE[0]}.real" "$@"\n' > "$c75_x/lib/himmel-secrets"
c75_reset
out="$(env PATH="$c75_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c75_t/claude" HOME="$c75_t/home" HIMMEL_DOCTOR_ENV_FILE="$c75_t/env" HIMMEL_CONFIG_DIR="" HIMMEL_SECRETS_KEYRING=off bash "$c75_x/himmel-doctor.sh" --root "$REPO_ROOT" --no-color --only C75 2>&1)"
if grepq "$out" -F 'INFO C75-secrets' && grepq "$out" -F 'could not be read' && ! grepq "$out" -F 'OK   C75-secrets'; then pass "C75 names failure -> INFO, not OK C75-secrets"; else fail "C75 names failure -> $(printf '%s' "$out" | head -4)"; fi
if grepq "$out" -F 'INFO C75-config-keys' && ! grepq "$out" -F 'OK   C75-config-keys'; then pass "C75 names failure -> the paired-setting check reports it did not run"; else fail "C75 names failure, config keys -> $(printf '%s' "$out" | head -4)"; fi
if grepq "$out" -F 'its manifest is missing or damaged'; then pass "C75 names failure -> the INFO says a damaged manifest is one cause"; else fail "C75 names failure, wording -> $(printf '%s' "$out" | head -4)"; fi
echo "== C75: a failing himmel-secrets status is not read as no keyring and no secret =="
# shellcheck disable=SC2016 # the wrapper expands its own variables
printf '#!/usr/bin/env bash\ncase "$1" in status) exit 1 ;; esac\nexec bash "${BASH_SOURCE[0]}.real" "$@"\n' > "$c75_x/lib/himmel-secrets"
c75_reset
out="$(env PATH="$c75_t/bin:$FAKEBIN:$PATH" CLAUDE_DIR="$c75_t/claude" HOME="$c75_t/home" HIMMEL_DOCTOR_ENV_FILE="$c75_t/env" HIMMEL_CONFIG_DIR="" HIMMEL_SECRETS_KEYRING=off bash "$c75_x/himmel-doctor.sh" --root "$REPO_ROOT" --no-color --only C75 2>&1)"
if grepq "$out" -F 'WARN C75-keyring' && grepq "$out" -F 'himmel-secrets status failed' && ! grepq "$out" -F 'OK   C75-secrets' && ! grepq "$out" -F 'OK   C75-config-keys'; then pass "C75 status failure -> WARN, and no OK row built on it"; else fail "C75 status failure -> $(printf '%s' "$out" | head -4)"; fi
echo "== C75 run from another repo's directory or from outside any repo reads the same as from the checkout =="
c75_p="$c75_t/proj"; mkdir -p "$c75_p" "$c75_t/away" "$c75_t/norepo"
git init -q "$c75_p"; git init -q "$c75_t/away"
ln -s "$REPO_ROOT/scripts" "$c75_p/scripts"
printf 'TELEGRAM_BOT_TOKEN=planted-dotenv-value\n' > "$c75_p/.env"
printf 'JIRA_API_TOKEN=planted-away-value\n' > "$c75_t/away/.env"
c75_from() { local o; o="$(cd "$1" && env -u HIMMEL_DOCTOR_ENV_FILE -u HIMMEL_REPO -u HIMMELCTL_CACHE_DIR -u JIRA_BASE_URL -u JIRA_API_TOKEN -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID -u TELEGRAM_GROUP_CHAT_ID -u CREDENTIALS_DIRECTORY PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$c75_t/claude" HOME="$c75_t/home" HIMMEL_CONFIG_DIR="" HIMMEL_SECRETS_KEYRING=off bash "$DOC" --root "$c75_p" --only C75 --no-color 2>&1)"; sed -n '/C75-/p' <<< "$o"; }
c75_home="$(c75_from "$c75_p")"; c75_away="$(c75_from "$c75_t/away")"; c75_out="$(c75_from "$c75_t/norepo")"
if grepq "$c75_home" -F 'INFO C75-secrets' && grepq "$c75_home" -F 'TELEGRAM_BOT_TOKEN' && ! grepq "$c75_home" -F 'JIRA' && ! grepq "$c75_home" -F 'planted' \
    && [ "$c75_away" = "$c75_home" ] && [ "$c75_out" = "$c75_home" ]; then pass "C75 from another repo's directory and from outside any repo reads the checkout .env, as from the checkout"; else fail "C75 away vs checkout -> checkout: $c75_home / away: $c75_away / outside: $c75_out"; fi
rm -rf "$c75_t"

# --- C76-duplicate-plugin-installs: one plugin installed more than 3 times ---
c76_t="$(mktemp -d "${TMPDIR:-/tmp}/c76.XXXXXX")" || { echo "FATAL: C76 setup mktemp failed" >&2; exit 1; }; mkdir -p "$c76_t/claude" "$c76_t/home"
cat > "$c76_t/claude-stub" <<'EOF'
#!/usr/bin/env bash
if [ "${C76_DUP:-0}" = 1 ]; then
    echo '[{"id":"atlassian@claude-plugins-official","scope":"user"},{"id":"atlassian@claude-plugins-official","scope":"local","projectPath":"/a"},{"id":"atlassian@claude-plugins-official","scope":"local","projectPath":"/b"},{"id":"atlassian@claude-plugins-official","scope":"local","projectPath":"/c"},{"id":"kept@himmel","scope":"user"}]'
else
    echo '[{"id":"atlassian@claude-plugins-official","scope":"user"},{"id":"kept@himmel","scope":"user"},{"id":"kept@himmel","scope":"local","projectPath":"/a"}]'
fi
EOF
chmod +x "$c76_t/claude-stub"
c76_run() { HIMMEL_DOCTOR_CLAUDE_BIN="$c76_t/claude-stub" DOCTOR_MCP_PLUGINS_GLOB="$c76_t/none/*.mcp.json" CLAUDE_DIR="$c76_t/claude" HOME="$c76_t/home" bash "$DOC" --no-color 2>&1; }
echo "== C76: a plugin installed more than 3 times -> WARN naming it, its count and the cleanup =="
out="$(C76_DUP=1 c76_run)"
c76_line="$(printf '%s' "$out" | grep -F 'C76-duplicate-plugin-installs')"
if grepq "$out" 'WARN C76-duplicate-plugin-installs' && grepq "$out" -F 'atlassian@claude-plugins-official x4' && grepq "$out" -F 'dedupe-plugin-installs.sh" --plugin atlassian@claude-plugins-official' && [[ "$c76_line" != *kept@himmel* ]]; then pass "C76 duplicate installs -> WARN"; else fail "C76 duplicate -> $(printf '%s' "$out" | grep -A1 C76)"; fi
echo "== C76: no plugin over the limit -> OK =="
out="$(C76_DUP=0 c76_run)"
if grepq "$out" 'OK   C76-duplicate-plugin-installs'; then pass "C76 within the limit -> OK"; else fail "C76 within limit -> $(printf '%s' "$out" | grep -A1 C76)"; fi
rm -rf "$c76_t"

# --- C88-graph-api-optin: the graph cadence's billed API lane needs a station opt-in ---
c88_t="$(mktemp -d "${TMPDIR:-/tmp}/c88.XXXXXX")" || { echo "FATAL: C88 setup mktemp failed" >&2; exit 1; }
mkdir -p "$c88_t/claude" "$c88_t/home/.himmel" "$c88_t/bat"
c88_key="dummy-not-a-real-key-c88"
c88_run() { CLAUDE_DIR="$c88_t/claude" HOME="$c88_t/home" HIMMEL_CONFIG_DIR='' HIMMEL_API_CREDIT_CONFIG="$c88_t/roster.json" GRAPHMAP_BAT_DIR="$c88_t/bat" HIMMEL_DOCTOR_ENV_FILE="$c88_t/env" bash "$DOC" --only C88 --no-color 2>&1; }
c88_reset() { rm -rf "$c88_t/home/.himmel" "$c88_t/home/.claude" "$c88_t/bat" "$c88_t/env" "$c88_t/roster.json"; mkdir -p "$c88_t/home/.himmel" "$c88_t/bat"; }
c88_optin() { printf '{"graphify":{"semantic_api_ok":true}}\n' > "$c88_t/home/.himmel/config.json"; }
c88_key_in_env() { printf '# himmel .env\nANTHROPIC_ORG_A_KEY=%s\n' "$c88_key" > "$c88_t/env"; }
c88_lane_runner() { printf '#!/bin/sh\n_rc=0; HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api graph-cadence.sh --semantic || _rc=$?\n' > "$c88_t/bat/graphmap-publish-himmel.sh"; }
c88_skip_runner() { printf '#!/bin/sh\n_rc=0; echo "[semantic skipped: API lane not opted in]"; graph-cadence.sh || _rc=$?\n' > "$c88_t/bat/graphmap-publish-himmel.sh"; }
echo "== C88: no opt-in, a key in .env and an armed runner that bakes the lane -> WARN naming the runner and the re-render =="
c88_reset; c88_key_in_env; c88_lane_runner
out="$(c88_run)"
if grepq "$out" 'WARN C88-graph-api-optin' && grepq "$out" -F 'graphmap-publish-himmel.sh' && grepq "$out" -F 'ANTHROPIC_ORG_A_KEY' && grepq "$out" -F 'graphmap-cadence.sh arm --rewrite-armed' && ! grepq "$out" -F "$c88_key"; then pass "C88 key + baked lane + no opt-in -> WARN, no key value"; else fail "C88 key + baked lane + no opt-in -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: opted in -> OK reporting the state, even with a key and a lane runner =="
c88_reset; c88_key_in_env; c88_lane_runner; c88_optin
out="$(c88_run)"
if grepq "$out" 'OK   C88-graph-api-optin' && grepq "$out" -F 'opted in' && ! grepq "$out" -F 'not opted in'; then pass "C88 opted in -> OK"; else fail "C88 opted in -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: no opt-in and the armed runner carries the skip line, not the lane -> OK reporting the state =="
c88_reset; c88_key_in_env; c88_skip_runner
out="$(c88_run)"
if grepq "$out" 'OK   C88-graph-api-optin' && grepq "$out" -F 'not opted in' && ! grepq "$out" 'WARN C88'; then pass "C88 skip-line runner + key -> OK"; else fail "C88 skip-line runner + key -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: no opt-in, no key in .env, nothing armed -> OK =="
c88_reset
out="$(c88_run)"
if grepq "$out" 'OK   C88-graph-api-optin' && grepq "$out" -F 'not opted in'; then pass "C88 nothing to draw -> OK"; else fail "C88 nothing to draw -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: a baked lane with no key in .env draws nothing -> INFO, never a WARN =="
c88_reset; c88_lane_runner; printf 'ANTHROPIC_ORG_A_KEY=\nJIRA_EMAIL=a@example.com\n' > "$c88_t/env"
out="$(c88_run)"
if grepq "$out" 'INFO C88-graph-api-optin' && ! grepq "$out" 'WARN C88'; then pass "C88 baked lane, empty key -> INFO"; else fail "C88 baked lane, empty key -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: only the JSON literal true opts in: a symlinked config.json and a string value do not =="
c88_reset; c88_key_in_env; c88_lane_runner
printf '{"graphify":{"semantic_api_ok":true}}\n' > "$c88_t/real-config.json"; ln -s "$c88_t/real-config.json" "$c88_t/home/.himmel/config.json"
out="$(c88_run)"
if grepq "$out" 'WARN C88-graph-api-optin'; then pass "C88 symlinked config.json is no opt-in"; else fail "C88 symlinked config.json -> $(printf '%s' "$out" | head -4)"; fi
c88_reset; c88_key_in_env; c88_lane_runner; printf '{"graphify":{"semantic_api_ok":"true"}}\n' > "$c88_t/home/.himmel/config.json"
out="$(c88_run)"
if grepq "$out" 'WARN C88-graph-api-optin'; then pass "C88 string \"true\" is no opt-in"; else fail "C88 string true -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88 run from another repo's directory or from outside any repo reads the same as from the checkout =="
c88_reset; c88_lane_runner
c88_p="$c88_t/proj"; mkdir -p "$c88_p" "$c88_t/away" "$c88_t/norepo"
git init -q "$c88_p"; git init -q "$c88_t/away"
ln -s "$REPO_ROOT/scripts" "$c88_p/scripts"
printf 'ANTHROPIC_ORG_A_KEY=%s\n' "$c88_key" > "$c88_p/.env"
printf 'ANTHROPIC_ORG_B_KEY=%s\n' "$c88_key" > "$c88_t/away/.env"
c88_from() { local o; o="$(cd "$1" && env -u HIMMEL_DOCTOR_ENV_FILE -u HIMMEL_REPO -u HIMMELCTL_CACHE_DIR CLAUDE_DIR="$c88_t/claude" HOME="$c88_t/home" GRAPHMAP_BAT_DIR="$c88_t/bat" bash "$DOC" --root "$c88_p" --only C88 --no-color 2>&1)"; sed -n '/C88-graph-api-optin/p' <<< "$o"; }
c88_home="$(c88_from "$c88_p")"; c88_away="$(c88_from "$c88_t/away")"; c88_out="$(c88_from "$c88_t/norepo")"
if grepq "$c88_home" 'WARN C88-graph-api-optin' && grepq "$c88_home" -F 'ANTHROPIC_ORG_A_KEY' && ! grepq "$c88_home" -F 'ANTHROPIC_ORG_B_KEY' && ! grepq "$c88_home" -F "$c88_key" \
    && [ "$c88_away" = "$c88_home" ] && [ "$c88_out" = "$c88_home" ]; then pass "C88 from another repo's directory and from outside any repo reads the checkout .env, as from the checkout"; else fail "C88 away vs checkout -> checkout: $c88_home / away: $c88_away / outside: $c88_out"; fi
echo "== C88: an adopter with no graph choice prints the no-choice line =="
c88_reset; printf '{}\n' > "$c88_t/home/.himmel/config.json"
out="$(c88_run)"
if grepq "$out" 'OK   C88-graph-api-optin' && grepq "$out" -F "no graph choice: a semantic pass on a repo other than himmel uses this machine's Claude subscription after the usage check, never an API key" && ! grepq "$out" -F 'sets graphify.semantic_api_ok to true'; then pass "C88 adopter, no graph choice -> the no-choice line"; else fail "C88 no choice -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: an unreadable config prints check's cause word and fixed line =="
c88_reset; printf 'this is not json\n' > "$c88_t/home/.himmel/config.json"
out="$(c88_run)"
if grepq "$out" 'WARN C88-graph-api-optin' && grepq "$out" -F 'cause=not-json' && grepq "$out" -F 'graph config unreadable (cause=not-json): ~/.himmel/config.json is not a JSON object'; then pass "C88 unreadable -> WARN with the cause word and its fixed line"; else fail "C88 unreadable -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: over a pass log, the last word, the consecutive refusals and the open alert =="
c88_reset; printf '{}\n' > "$c88_t/home/.himmel/config.json"; mkdir -p "$c88_t/home/.claude/graph-choices-cadence"
printf '[fired 2026-11-08T04:40:00Z]\n2026-11-08T04:40:05Z acme ok\n2026-11-09T04:40:05Z acme bank-refused\n[exit rc=0]\n2026-11-10T04:40:05Z acme bank-refused\n2026-11-11T04:40:05Z acme bank-refused\n2026-11-11T04:40:06Z acme ALERT key-rejected the A key was rejected\n' > "$c88_t/home/.claude/graph-choices-cadence/graph-choices.log"
out="$(c88_run)"
if grepq "$out" -F 'pass: acme bank-refused' && grepq "$out" -F 'bank-refused in a row: 3' && grepq "$out" -F 'alert: acme key-rejected'; then pass "C88 pass log -> word, count and open alert"; else fail "C88 pass log -> $(printf '%s' "$out" | head -4)"; fi
echo "== C88: an E-row roster prints invalid-account-config's line; no roster file prints unreadable-state's =="
c88_reset; printf '{}\n' > "$c88_t/home/.himmel/config.json"
printf '{"version":1,"ledger_path":"/tmp/c88-ledger.json","accounts":{"E":{"organization_id":"o","cycle_id":"c","cap_usd":"1"}}}\n' > "$c88_t/roster.json"
out="$(c88_run)"
if grepq "$out" -F 'a row in the API roster names a letter outside A, B, C, D'; then pass "C88 E-row roster -> invalid-account-config's line"; else fail "C88 E roster -> $(printf '%s' "$out" | head -4)"; fi
rm -f "$c88_t/roster.json"
out="$(c88_run)"
if grepq "$out" -F 'no API account is set up here, or its roster cannot be read; none is offered'; then pass "C88 no roster file -> unreadable-state's line"; else fail "C88 no roster -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c88_t"

# --- C87-stub-handover-state: files under <repo>/handovers newer than the operator's baseline marker ---
c87_t="$(mktemp -d "${TMPDIR:-/tmp}/c87.XXXXXX")" || { echo "FATAL: C87 setup mktemp failed" >&2; exit 1; }
c87_t="$(cd "$c87_t" && pwd)" || { echo "FATAL: C87 setup cd failed" >&2; exit 1; }  # a TMPDIR with a trailing slash (macOS) would leave "T//" where the doctor prints "T/"
c87_x="$c87_t/repo"
mkdir -p "$c87_x/scripts/lib" "$c87_t/home" "$c87_t/claude" "$c87_t/root"
cp "$REPO_ROOT/scripts/himmel-doctor.sh" "$c87_x/scripts/"
cp -R "$REPO_ROOT/scripts/lib/." "$c87_x/scripts/lib/"
c87_age() { python3 -I -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
c87_base="$c87_t/home/baseline"
# C87_HD, when set, is the root exported to the doctor's environment; a .env in the fixture repo configures one too.
c87_run() { env -u HANDOVER_DIR ${C87_HD:+HANDOVER_DIR="$C87_HD"} HOME="$c87_t/home" CLAUDE_DIR="$c87_t/claude" HIMMEL_CONFIG_DIR="" HIMMEL_DOCTOR_STUB_BASELINE="$c87_base" bash "$c87_x/scripts/himmel-doctor.sh" --root "$c87_x" --no-color --only C87 2>&1; }
c87_reset() { rm -rf "$c87_x/handovers" "$c87_x/.env" "$c87_base" "$c87_t/elsewhere"; unset C87_HD; }

echo "== C87: HANDOVER_DIR unset and no .env -> the stub folder is the root: INFO, never WARN =="
c87_reset
mkdir -p "$c87_x/handovers/himmel"; : > "$c87_x/handovers/himmel/new.md"
out="$(c87_run)"
if grepq "$out" -F 'INFO C87-stub-handover-state' && ! grepq "$out" -F 'WARN C87'; then pass "C87 no split root -> INFO"; else fail "C87 no split root -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: .env configures a root elsewhere and a stub file older than that .env is still reported (no baseline marker) =="
c87_reset
printf 'HANDOVER_DIR=%s\n' "$c87_t/root" > "$c87_x/.env"
mkdir -p "$c87_x/handovers/himmel"; : > "$c87_x/handovers/himmel/.judge-ladder"; c87_age "$c87_x/handovers/himmel/.judge-ladder" 7200
out="$(c87_run)"
if grepq "$out" -F 'WARN C87-stub-handover-state' && grepq "$out" -F 'himmel/.judge-ladder' && grepq "$out" -F "$c87_t/root"; then pass "C87 .env root, old stub file, no marker -> WARN"; else fail "C87 .env root, old stub file -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: a root exported in the environment (no .env) is checked the same way =="
c87_reset
mkdir -p "$c87_x/handovers/.locks"; : > "$c87_x/handovers/.locks/arms.jsonl"
C87_HD="$c87_t/root" out="$(c87_run)"
if grepq "$out" -F 'WARN C87-stub-handover-state' && grepq "$out" -F '.locks/arms.jsonl'; then pass "C87 exported root -> WARN"; else fail "C87 exported root -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: a root served by ~/.himmel/himmel.conf (no .env) is checked the same way =="
c87_reset
mkdir -p "$c87_t/home/.himmel" "$c87_x/handovers/himmel"; printf 'HANDOVER_DIR=%s\n' "$c87_t/root" > "$c87_t/home/.himmel/himmel.conf"
: > "$c87_x/handovers/himmel/.judge-ladder"
out="$(c87_run)"
rm -rf "$c87_t/home/.himmel"
if grepq "$out" -F 'WARN C87-stub-handover-state' && grepq "$out" -F "$c87_t/root"; then pass "C87 himmel.conf root -> WARN"; else fail "C87 himmel.conf root -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: the baseline marker decides: newer than the stub file -> OK, older -> WARN =="
c87_reset
mkdir -p "$c87_x/handovers/himmel"; : > "$c87_x/handovers/himmel/.judge-ladder"; c87_age "$c87_x/handovers/himmel/.judge-ladder" 7200
: > "$c87_base"; c87_age "$c87_base" 3600
C87_HD="$c87_t/root" out="$(c87_run)"
if grepq "$out" -F 'OK   C87-stub-handover-state' && ! grepq "$out" -F 'WARN C87'; then pass "C87 stub file older than the marker -> OK"; else fail "C87 older than marker -> $(printf '%s' "$out" | head -4)"; fi
c87_age "$c87_base" 10800
C87_HD="$c87_t/root" out="$(c87_run)"
if grepq "$out" -F 'WARN C87-stub-handover-state'; then pass "C87 stub file newer than the marker -> WARN"; else fail "C87 newer than marker -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: control: no stub folder at all -> no WARN =="
c87_reset
C87_HD="$c87_t/root" out="$(c87_run)"
if grepq "$out" -F 'OK   C87-stub-handover-state' && ! grepq "$out" -F 'WARN C87'; then pass "C87 no stub folder -> OK"; else fail "C87 no stub folder -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: a stub that is a symlink to another folder is scanned =="
c87_reset
mkdir -p "$c87_t/elsewhere"; : > "$c87_t/elsewhere/new.md"; ln -s "$c87_t/elsewhere" "$c87_x/handovers"
C87_HD="$c87_t/root" out="$(c87_run)"
if grepq "$out" -F 'WARN C87-stub-handover-state' && grepq "$out" -F 'new.md'; then pass "C87 symlinked stub -> WARN"; else fail "C87 symlinked stub -> $(printf '%s' "$out" | head -4)"; fi

echo "== C87: an unreadable folder under the stub is never reported OK =="
c87_reset
mkdir -p "$c87_x/handovers/himmel/locked"; chmod 000 "$c87_x/handovers/himmel/locked"
: > "$c87_base"
C87_HD="$c87_t/root" out="$(c87_run)"
chmod 755 "$c87_x/handovers/himmel/locked"
if [ "$(id -u)" = 0 ]; then pass "C87 unreadable folder -> skipped as root (chmod does not block root)"
elif grepq "$out" -F 'INFO C87-stub-handover-state' && ! grepq "$out" -F 'OK   C87'; then pass "C87 unreadable folder -> INFO, not OK"; else fail "C87 unreadable folder -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c87_t"

# --- C89-qmd-rerank: a qmd that runs without its reranker ---
# Fixtures copied from the real station: the model cache file name under ~/.cache/qmd/models and the
# `models:` block of ~/.config/qmd/index.yml (remote reranker).
c89_t="$(mktemp -d "${TMPDIR:-/tmp}/c89.XXXXXX")" || { echo "FATAL: C89 setup mktemp failed" >&2; exit 1; }
c89_reset() { rm -rf "${c89_t:?}/home" "${c89_t:?}/models" "${c89_t:?}/cfg"; mkdir -p "$c89_t/home" "$c89_t/models" "$c89_t/cfg"; printf '#!/bin/sh\nexit 0\n' > "$c89_t/qmd"; chmod +x "$c89_t/qmd"; }
c89_gguf() { : > "$c89_t/models/hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf"; }
c89_remote_cfg() { printf 'models:\n  embed: openai:qwen/qwen3-embedding-8b\n  generate: openai:google/gemini-2.5-flash-lite\n  rerank: openai:cohere/rerank-4-fast\n  openai_base_url: https://openrouter.ai/api/v1\n' > "$c89_t/cfg/index.yml"; }
c89_run() { env -u QMD_RERANK -u QMD_RERANK_MODEL -u QMD_DAEMON_DISABLED HOME="$c89_t/home" QMD_CONFIG_DIR="$c89_t/cfg" HIMMEL_DOCTOR_QMD_BIN="$c89_t/qmd" HIMMEL_DOCTOR_QMD_MODELS_DIR="$c89_t/models" QMD_DAEMON_OFF_FLAG="$c89_t/no-such-flag" "$@" bash "$DOC" --only C89 --no-color 2>&1; }
echo "== C89: QMD_RERANK=off -> WARN naming the variable and the remedy =="
c89_reset; c89_gguf
out="$(c89_run QMD_RERANK=off)"
if grepq "$out" 'WARN C89-qmd-rerank' && grepq "$out" -F 'QMD_RERANK=off' && grepq "$out" -F 'unset QMD_RERANK'; then pass "C89 QMD_RERANK=off -> WARN"; else fail "C89 QMD_RERANK=off -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: control, local reranker model present and QMD_RERANK unset -> OK, no WARN =="
c89_reset; c89_gguf
out="$(c89_run)"
if grepq "$out" 'OK   C89-qmd-rerank' && grepq "$out" -F 'local reranker' && ! grepq "$out" 'WARN C89'; then pass "C89 local reranker present -> OK"; else fail "C89 local reranker present -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: local route and no reranker model in the cache -> WARN with qmd pull =="
c89_reset
out="$(c89_run)"
if grepq "$out" 'WARN C89-qmd-rerank' && grepq "$out" -F 'qmd pull'; then pass "C89 no reranker model -> WARN"; else fail "C89 no reranker model -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: remote reranker configured -> OK without a local model =="
c89_reset; c89_remote_cfg
out="$(c89_run)"
if grepq "$out" 'OK   C89-qmd-rerank' && grepq "$out" -F 'remote reranker' && ! grepq "$out" 'WARN C89'; then pass "C89 remote reranker -> OK"; else fail "C89 remote reranker -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: a quoted remote reranker value in the config counts as remote =="
c89_reset; printf 'models:\n  rerank: "openai:cohere/rerank-4-fast"\n' > "$c89_t/cfg/index.yml"
out="$(c89_run)"
if grepq "$out" 'OK   C89-qmd-rerank' && grepq "$out" -F 'remote reranker' && ! grepq "$out" 'WARN C89'; then pass "C89 quoted remote reranker -> OK"; else fail "C89 quoted remote reranker -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: an adopter's qmd is the bun-global script with no qmd on PATH -> still checked =="
c89_reset; c89_gguf
mkdir -p "$c89_t/bun/install/global/node_modules/@tobilu/qmd/dist/cli" "$c89_t/stubbin"
: > "$c89_t/bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
printf '#!/bin/sh\nexit 0\n' > "$c89_t/stubbin/bun"; chmod +x "$c89_t/stubbin/bun"
c89_path="$c89_t/stubbin"; c89_ifs="$IFS"; IFS=:
for c89_d in $PATH; do [ -e "$c89_d/qmd" ] || c89_path="$c89_path:$c89_d"; done
IFS="$c89_ifs"
if PATH="$c89_path" command -v qmd >/dev/null 2>&1; then fail "C89 bun-global qmd: a qmd is still on the scrubbed PATH"; fi
out="$(env -u QMD_RERANK -u QMD_RERANK_MODEL -u QMD_DAEMON_DISABLED -u HIMMEL_DOCTOR_QMD_BIN HOME="$c89_t/home" BUN_INSTALL="$c89_t/bun" PATH="$c89_path" QMD_CONFIG_DIR="$c89_t/cfg" HIMMEL_DOCTOR_QMD_MODELS_DIR="$c89_t/models" QMD_DAEMON_OFF_FLAG="$c89_t/no-such-flag" QMD_RERANK=off bash "$DOC" --only C89 --no-color 2>&1)"
if grepq "$out" 'WARN C89-qmd-rerank' && ! grepq "$out" -F 'not installed'; then pass "C89 bun-global qmd -> checked, WARN"; else fail "C89 bun-global qmd -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: QMD_RERANK=0 and QMD_RERANK=FALSE also warn =="
c89_reset; c89_gguf
out="$(c89_run QMD_RERANK=0)"; out2="$(c89_run QMD_RERANK=FALSE)"
if grepq "$out" 'WARN C89-qmd-rerank' && grepq "$out2" 'WARN C89-qmd-rerank'; then pass "C89 0 and FALSE -> WARN"; else fail "C89 0/FALSE -> $(printf '%s' "$out$out2" | head -4)"; fi
echo "== C89: qmd not installed -> INFO skip =="
c89_reset; rm -f "$c89_t/qmd"
out="$(c89_run)"
if grepq "$out" 'INFO C89-qmd-rerank' && grepq "$out" -F 'qmd is not installed' && ! grepq "$out" 'WARN C89'; then pass "C89 no qmd -> INFO"; else fail "C89 no qmd -> $(printf '%s' "$out" | head -4)"; fi
echo "== C89: qmd switched off by the operator -> INFO skip, even with QMD_RERANK=off =="
c89_reset; : > "$c89_t/off-flag"
out="$(c89_run QMD_RERANK=off QMD_DAEMON_OFF_FLAG="$c89_t/off-flag")"
if grepq "$out" 'INFO C89-qmd-rerank' && grepq "$out" -F 'off by operator' && ! grepq "$out" 'WARN C89'; then pass "C89 operator off -> INFO"; else fail "C89 operator off -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c89_t"

# --- C90-effort-pin: a settings env block pins CLAUDE_CODE_EFFORT_LEVEL ---
# Probe on claude 2.1.319 (sandboxed HOME, mock API logging output_config.effort): with the pin
# set to high, `--effort medium` and a process-env medium both still sent high; without the pin
# both sent medium. So a pin overrides whatever the launcher asks for, and the doctor names it.
c90_t="$(mktemp -d "${TMPDIR:-/tmp}/c90.XXXXXX")" || { echo "FATAL: C90 setup mktemp failed" >&2; exit 1; }
c90_reset() { rm -rf "${c90_t:?}/claude" "${c90_t:?}/root"; mkdir -p "$c90_t/claude" "$c90_t/root/.claude"; ln -s "$REPO_ROOT/scripts" "$c90_t/root/scripts"; }
c90_run() { env -u CLAUDE_CODE_EFFORT_LEVEL CLAUDE_DIR="$c90_t/claude" HOME="$c90_t/home" bash "$DOC" --root "$c90_t/root" --only C90 --no-color 2>&1; }
echo "== C90: user settings env pins CLAUDE_CODE_EFFORT_LEVEL -> WARN naming the variable, the value and the file =="
c90_reset; printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}\n' > "$c90_t/claude/settings.json"
out="$(c90_run)"
if grepq "$out" 'WARN C90-effort-pin' && grepq "$out" -F 'CLAUDE_CODE_EFFORT_LEVEL' && grepq "$out" -F "$c90_t/claude/settings.json" && grepq "$out" -F 'high'; then pass "C90 user pin -> WARN"; else fail "C90 user pin -> $(printf '%s' "$out" | head -4)"; fi
echo "== C90: control, settings without the pin -> OK, no WARN =="
c90_reset; printf '{"env":{"OTHER":"1"}}\n' > "$c90_t/claude/settings.json"
out="$(c90_run)"
if grepq "$out" 'OK   C90-effort-pin' && ! grepq "$out" 'WARN C90'; then pass "C90 no pin -> OK"; else fail "C90 no pin -> $(printf '%s' "$out" | head -4)"; fi
echo "== C90: no settings file at all -> OK =="
c90_reset
out="$(c90_run)"
if grepq "$out" 'OK   C90-effort-pin' && ! grepq "$out" 'WARN C90'; then pass "C90 no settings -> OK"; else fail "C90 no settings -> $(printf '%s' "$out" | head -4)"; fi
echo "== C90: project settings.json and settings.local.json pins also warn =="
c90_reset; printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max"}}\n' > "$c90_t/root/.claude/settings.json"
out="$(c90_run)"
c90_reset; printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"low"}}\n' > "$c90_t/root/.claude/settings.local.json"
out2="$(c90_run)"
if grepq "$out" 'WARN C90-effort-pin' && grepq "$out" -F "$c90_t/root/.claude/settings.json" && grepq "$out2" 'WARN C90-effort-pin' && grepq "$out2" -F "$c90_t/root/.claude/settings.local.json"; then pass "C90 project pins -> WARN"; else fail "C90 project pins -> $(printf '%s' "$out$out2" | head -6)"; fi
rm -rf "$c90_t"

c91_t="$(mktemp -d "${TMPDIR:-/tmp}/c91.XXXXXX")" || { echo "FATAL: C91 setup mktemp failed" >&2; exit 1; }
git init -q "$c91_t/repo"
c91_repo="$(cd "$c91_t/repo" && pwd -P)"
printf '#!/bin/sh\nexit 0\n' > "$c91_t/alert-stub"; chmod 700 "$c91_t/alert-stub"
c91_rec="$c91_t/home/.himmel/state/api-lane-alerts/policy-refusals.jsonl"
c91_reset() { rm -rf "${c91_t:?}/home" "${c91_t:?}/claude"; mkdir -p "$c91_t/home" "$c91_t/claude"; }
c91_refuse() { (cd "${2:-$c91_t/repo}" && env -i PATH="$PATH" HOME="$c91_t/home" HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto HIMMEL_API_KIND="$1" \
    HIMMEL_API_ALERT_CMD="$c91_t/alert-stub" HIMMEL_API_JOB_ID=job-c91 bash "$REPO_ROOT/scripts/api-lane/claude-api.sh" \
    -p 'say hi' --model claude-haiku-5-5 --permission-mode plan --max-budget-usd 0.10 >/dev/null 2>&1); }
c91_run() { env -u HIMMEL_API_ALERT_DIR CLAUDE_DIR="$c91_t/claude" HOME="$c91_t/home" bash "$DOC" --only C91 --no-color 2>&1; }
c91_age() { local _ts; _ts=$(( $(date +%s) - $1 * 3600 )); jq -c --argjson ts "$_ts" '.ts = $ts' "$c91_rec" > "$c91_rec.new" && mv "$c91_rec.new" "$c91_rec"; }
echo "== C91: a real launcher policy refusal (kind critic) -> one WARN naming critic and its repo =="
c91_reset; c91_refuse critic
out="$(c91_run)"
if [ "$(wc -l < "$c91_rec" 2>/dev/null)" -eq 1 ] && [ "$(printf '%s\n' "$out" | grep -c 'WARN C91-api-policy-refusals')" -eq 1 ] && grepq "$out" -F 'critic' && grepq "$out" -F "$c91_repo"; then pass "C91 writer-fed critic refusal -> one WARN with kind and repo"; else fail "C91 writer-fed critic refusal -> record=$(cat "$c91_rec" 2>/dev/null) out=$(printf '%s' "$out" | head -4)"; fi
echo "== C91: two kinds -> two WARN lines under one ID, each with its count =="
c91_reset; c91_refuse critic; c91_refuse critic; c91_refuse judge
out="$(c91_run)"
if [ "$(printf '%s\n' "$out" | grep -c 'WARN C91-api-policy-refusals')" -eq 2 ] && grepq "$out" 'WARN C91-api-policy-refusals.*critic: 2 refused' && grepq "$out" 'WARN C91-api-policy-refusals.*judge: 1 refused'; then pass "C91 two kinds -> two WARN lines with counts"; else fail "C91 two kinds -> $(printf '%s' "$out" | head -4)"; fi
echo "== C91: one kind refused in two repos -> two WARN lines, each with its own repo and count =="
git init -q "$c91_t/repo2"
c91_repo2="$(cd "$c91_t/repo2" && pwd -P)"
c91_reset; c91_refuse critic; c91_refuse critic "$c91_t/repo2"
out="$(c91_run)"
if [ "$(printf '%s\n' "$out" | grep -c 'WARN C91-api-policy-refusals')" -eq 2 ] && [ "$(printf '%s\n' "$out" | grep -c 'critic: 1 refused')" -eq 2 ] \
    && grepq "$out" "critic: 1 refused.*repo $c91_repo/" && grepq "$out" "critic: 1 refused.*repo $c91_repo2/"; then pass "C91 one kind in two repos -> two WARN lines, each with its repo"; else fail "C91 two repos -> $(printf '%s' "$out" | head -4)"; fi
echo "== C91: the window is 48 hours: a record 47 h old warns, one 49 h old does not =="
c91_reset; c91_refuse critic; c91_age 47
out="$(c91_run)"
c91_reset; c91_refuse critic; c91_age 49
out2="$(c91_run)"
if grepq "$out" 'WARN C91-api-policy-refusals' && ! grepq "$out2" 'WARN C91' && grepq "$out2" 'OK   C91-api-policy-refusals'; then pass "C91 47 h warns, 49 h does not"; else fail "C91 window -> 47h: $(printf '%s' "$out" | head -3) 49h: $(printf '%s' "$out2" | head -3)"; fi
echo "== C91: no record file -> no WARN =="
c91_reset
out="$(c91_run)"
if grepq "$out" 'OK   C91-api-policy-refusals' && ! grepq "$out" 'WARN C91'; then pass "C91 no file -> OK"; else fail "C91 no file -> $(printf '%s' "$out" | head -3)"; fi
echo "== C91: an unparseable line beside a good one -> one WARN =="
c91_reset; c91_refuse critic; printf 'not json {\n' >> "$c91_rec"
out="$(c91_run)"
if [ "$(printf '%s\n' "$out" | grep -c 'WARN C91-api-policy-refusals')" -eq 1 ] && grepq "$out" 'critic: 1 refused'; then pass "C91 bad line skipped, good line warns once"; else fail "C91 bad line -> $(printf '%s' "$out" | head -4)"; fi
echo "== C91: jq not on PATH -> one INFO line =="
c91_reset; c91_refuse critic
C91_NOJQ="$c91_t/nojq-bin"; mkdir -p "$C91_NOJQ"
for f in /usr/bin/*; do b="${f##*/}"; [ "$b" = jq ] && continue; [ -x "$f" ] && ln -s "$f" "$C91_NOJQ/$b" 2>/dev/null; done
if PATH="$C91_NOJQ" bash -c 'command -v bash >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1' 2>/dev/null; then
    out="$(env -u HIMMEL_API_ALERT_DIR CLAUDE_DIR="$c91_t/claude" HOME="$c91_t/home" PATH="$C91_NOJQ" bash "$DOC" --only C91 --no-color 2>&1)"
    if [ "$(printf '%s\n' "$out" | grep -c 'INFO C91-api-policy-refusals')" -eq 1 ] && ! grepq "$out" 'WARN C91' && grepq "$out" -F 'jq not on PATH'; then pass "C91 no jq -> one INFO"; else fail "C91 no jq -> $(printf '%s' "$out" | head -4)"; fi
else
    echo "  SKIP: C91 no-jq — the curated shadow PATH cannot run bash without jq here"
fi
echo "== C91: a record that cannot be read, or that jq fails on, is INFO, never a silent OK =="
c91_reset; mkdir -p "$c91_rec"
out="$(c91_run)"
c91_reset; c91_refuse critic
mkdir -p "$c91_t/failjq"; printf '#!/bin/sh\nexit 5\n' > "$c91_t/failjq/jq"; chmod 700 "$c91_t/failjq/jq"
out2="$(env -u HIMMEL_API_ALERT_DIR CLAUDE_DIR="$c91_t/claude" HOME="$c91_t/home" PATH="$c91_t/failjq:$PATH" bash "$DOC" --only C91 --no-color 2>&1)"
if grepq "$out" 'INFO C91-api-policy-refusals' && ! grepq "$out" 'OK   C91' && ! grepq "$out" 'WARN C91' \
    && grepq "$out2" 'INFO C91-api-policy-refusals' && ! grepq "$out2" 'OK   C91' && ! grepq "$out2" 'WARN C91'; then pass "C91 unreadable record and failing jq -> INFO"; else fail "C91 unreadable -> $(printf '%s' "$out" | head -3) failing jq -> $(printf '%s' "$out2" | head -3)"; fi
rm -rf "$c91_t"

c92_t="$(mktemp -d "${TMPDIR:-/tmp}/c92.XXXXXX")" || { echo "FATAL: C92 setup mktemp failed" >&2; exit 1; }
c92_key="sk-ant-planted-not-a-real-key-c92"
c92_reset() {
    rm -rf "${c92_t:?}/home" "${c92_t:?}/credit" "${c92_t:?}/bat" "${c92_t:?}/env"; mkdir -p "$c92_t/home/.himmel" "$c92_t/claude" "$c92_t/credit" "$c92_t/bat"
    printf '{"version":1,"ledger_path":"%s","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00"},"B":{"organization_id":"org-b","cycle_id":"cycle-b","cap_usd":"50.00"},"C":{"organization_id":"org-c","cycle_id":"cycle-c","cap_usd":"50.00"}}}' \
        "$c92_t/credit/ledger.json" > "$c92_t/credit/config.json"
    printf '{"graphify":{"semantic_api_ok":true}}\n' > "$c92_t/home/.himmel/config.json"
    for l in A B C; do printf 'ANTHROPIC_API_KEY=%s\n' "$c92_key" > "$c92_t/credit/key-$l.env"; chmod 000 "$c92_t/credit/key-$l.env"; done
}
c92_tag() {
    local l rows=""
    for l in "$@"; do rows="${rows:+$rows,}\"$l\":{\"organization_id\":\"org-$(echo "$l" | tr A-D a-d)\",\"cycle_id\":\"cycle-$(echo "$l" | tr A-D a-d)\",\"discrepancy\":false,\"jobs\":{},\"key_rejected_at\":1700000000}"; done
    printf '{"version":1,"accounts":{%s}}' "$rows" > "$c92_t/credit/ledger.json"
}
c92_roles() { printf '%s' "$1" > "$c92_t/credit/roles.json"; }
c92_env() { env CLAUDE_DIR="$c92_t/claude" HOME="$c92_t/home" HIMMEL_CONFIG_DIR='' HIMMEL_API_CREDIT_CONFIG="$c92_t/credit/config.json" \
    HIMMEL_API_CREDIT_SNAPSHOT="$c92_t/credit/no-snapshot.json" GRAPHMAP_BAT_DIR="$c92_t/bat" HIMMEL_DOCTOR_ENV_FILE="$c92_t/env" "$@"; }
c92_run() { c92_env bash "$DOC" --only "${1:-C92}" --no-color 2>&1; }
c92_ids() { c92_env bash "$DOC" --only "${1:-C92}" --json --no-color 2>/dev/null | jq -r 'select(.sev == "WARN" or .sev == "FAIL") | .id' | sort | paste -sd, -; }
c92_fix='rotate ~/.himmel/state/api-credit/key-A.env, or remove A from the route or the graphify role'
c92_secret_free() { ! grepq "$1" -F "$c92_key"; }
c92_mode000_probe() { [ ! -r "$c92_t/credit/key-A.env" ]; }

echo "== C92: A carries the key-rejected tag and the station's walk reaches A -> WARN C92-graph-key-A naming A and the fix =="
c92_reset; c92_tag A
out="$(c92_run)"
if grepq "$out" 'WARN C92-graph-key-A' && grepq "$out" -F "$c92_fix" && c92_secret_free "$out"; then pass "C92 a tagged letter in the walk -> WARN with the fix line"; else fail "C92 tagged in the walk -> $out"; fi
if c92_mode000_probe; then
    chmod 600 "$c92_t/credit/key-A.env"; out_r="$(c92_run)"; chmod 000 "$c92_t/credit/key-A.env"
    if grepq "$out" -F "account A's API key (key: none)" && grepq "$out_r" -F "account A's API key (key ...-c92)" \
        && c92_secret_free "$out_r" && ! grepq "$out_r" -F 'y-c92'; then pass "C92 an unreadable key file says key: none; a readable one shows its last 4 characters only"
    else fail "C92 key tail: 000 -> $out / 600 -> $out_r"; fi
else
    echo "  SKIP  C92 mode-000 row: this user can read a mode-000 file (root), so the row would pass vacuously"
fi

echo "== C92: D carries the key-rejected tag and the walk reaches D -> WARN C92-graph-key-D naming its key by the last 4 characters =="
c92_dkey="sk-ant-planted-not-a-real-key-0000^Dk4w"
c92_reset
printf '{"version":1,"ledger_path":"%s","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00"},"D":{"organization_id":"org-d","cycle_id":"cycle-d","cap_usd":"50.00"}}}' \
    "$c92_t/credit/ledger.json" > "$c92_t/credit/config.json"
printf 'ANTHROPIC_API_KEY=%s\n' "$c92_dkey" > "$c92_t/credit/key-D.env"; chmod 600 "$c92_t/credit/key-D.env"
c92_tag D
out="$(c92_run)"
if grepq "$out" 'WARN C92-graph-key-D' && grepq "$out" -F "account D's API key (key ...Dk4w)" && grepq "$out" -F 'rotate ~/.himmel/state/api-credit/key-D.env' \
    && ! grepq "$out" -F '^' && ! grepq "$out" -F "${c92_dkey%????}"; then pass "C92 a tagged D in the walk -> WARN with the last 4 characters of its key only"; else fail "C92 tagged D -> $out"; fi

echo "== C92: A tagged, but the map walks C alone -> OK with a note; no tag -> OK =="
c92_reset; c92_tag A; c92_roles '{"version":1,"roles":{"graphify":["C"]}}'
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key-A' && grepq "$out" -F 'no graph walk reaches it' && ! grepq "$out" 'WARN C92'; then pass "C92 a tagged letter outside the walk -> OK with a note"; else fail "C92 outside the walk -> $out"; fi
c92_reset
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key' && ! grepq "$out" 'WARN C92'; then pass "C92 no tag -> OK"; else fail "C92 no tag -> $out"; fi

echo "== C92: a roster or ledger that cannot be read is INFO, never a clean OK; no roster at all is OK =="
c92_reset; printf '{not json' > "$c92_t/credit/config.json"
out="$(c92_run)"
if grepq "$out" 'INFO C92-graph-key' && ! grepq "$out" 'OK   C92'; then pass "C92 unreadable roster -> INFO"; else fail "C92 unreadable roster -> $out"; fi
c92_reset; printf '{' > "$c92_t/credit/ledger.json"
out="$(c92_run)"
if grepq "$out" 'INFO C92-graph-key' && grepq "$out" -F 'A B C' && ! grepq "$out" 'OK   C92'; then pass "C92 unreadable ledger -> INFO naming the letters"; else fail "C92 unreadable ledger -> $out"; fi
c92_reset; rm -f "$c92_t/credit/config.json"
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key' && grepq "$out" -F 'no API account is configured'; then pass "C92 no roster -> OK"; else fail "C92 no roster -> $out"; fi

echo "== C92: A tagged and the map invalid -> OK with a note that the pass refuses =="
c92_reset; c92_tag A; c92_roles '{not json'
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key-A' && grepq "$out" -F 'the graph pass refuses' && ! grepq "$out" 'WARN C92'; then pass "C92 an invalid map -> OK, the pass refuses"; else fail "C92 invalid map -> $out"; fi

echo "== C92: an adopter whose route is C, with A tagged -> OK; an unreadable config reads the station walk -> WARN =="
c92_reset; c92_tag A; printf '{"graphify":{"choices":{"version":1,"primary":"C","max_usd_per_pass":5}}}\n' > "$c92_t/home/.himmel/config.json"
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key-A' && ! grepq "$out" 'WARN C92'; then pass "C92 adopter route C, A tagged -> OK"; else fail "C92 adopter route C -> $out"; fi
c92_lane_runner() { printf '#!/bin/sh\n_rc=0; HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api graph-cadence.sh --semantic || _rc=$?\n' > "$c92_t/bat/graphmap-publish-himmel.sh"; }
c92_reset; c92_tag A; printf '{not json' > "$c92_t/home/.himmel/config.json"
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key-A' && ! grepq "$out" 'WARN C92'; then pass "C92 an unreadable config with no armed publish runner has no auto walk -> OK"; else fail "C92 unreadable config, no runner -> $out"; fi
c92_reset; c92_tag A; printf '{not json' > "$c92_t/home/.himmel/config.json"; c92_lane_runner
out="$(c92_run)"
if grepq "$out" 'WARN C92-graph-key-A'; then pass "C92 an unreadable config with footprint (a) reads the station walk -> WARN"; else fail "C92 unreadable config with footprint (a) -> $out"; fi
c92_reset; c92_tag A; rm -f "$c92_t/home/.himmel/config.json"; c92_lane_runner
out="$(c92_run)"
if grepq "$out" 'WARN C92-graph-key-A'; then pass "C92 a missing config with footprint (a) reads the station walk -> WARN"; else fail "C92 missing config with footprint (a) -> $out"; fi
echo "== C92: a pinned luna semantic runner reaches its letter even when the walk does not =="
c92_reset; c92_tag A; c92_roles '{"version":1,"roles":{"graphify":["C"]}}'
printf '#!/bin/sh\nif [ -e x ]; then :; else HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A GRAPHIFY_OUT=/o bash semantic-update.sh --name luna; fi\n' > "$c92_t/bat/graphmap-semantic-luna.sh"
out="$(c92_run)"
if grepq "$out" 'WARN C92-graph-key-A' && grepq "$out" -F "$c92_fix"; then pass "C92 a pinned runner's letter outside the walk -> WARN"; else fail "C92 pinned runner -> $out"; fi
c92_reset; c92_tag A; c92_roles '{"version":1,"roles":{"graphify":["C"]}}'
out="$(c92_run)"
if grepq "$out" 'OK   C92-graph-key-A' && ! grepq "$out" 'WARN C92'; then pass "C92 the same tag with no pinned runner -> OK"; else fail "C92 no pinned runner -> $out"; fi

echo "== C92: A tagged, then A and B tagged -> the doctor's own --json WARN ids, each passing tick.sh's doctor= filter =="
c92_reset; c92_tag A
ids1="$(c92_ids)"
c92_tag A B
ids2="$(c92_ids)"
case "$ids2" in ""|*[!0-9A-Za-z_,?.-]*) ids2_ok=0 ;; *) ids2_ok=1 ;; esac
if [ "$ids1" = "C92-graph-key-A" ] && [ "$ids2" = "C92-graph-key-A,C92-graph-key-B" ] && [ "$ids2_ok" = 1 ]; then pass "C92 one id per letter: [$ids1] then [$ids2]"; else fail "C92 ids -> [$ids1] then [$ids2]"; fi

echo "== C93: an invalid map, a partial map and a graphify entry with no configured letter WARN; absent and valid are OK =="
c92_reset; c92_roles '{not json'; out="$(c92_run C93)"
if grepq "$out" 'WARN C93-graph-role' && grepq "$out" -F 'the graph pass refuses'; then pass "C93 invalid map -> WARN, the pass refuses"; else fail "C93 invalid -> $out"; fi
c92_reset; c92_roles '{"version":1,"roles":{"graphify":["E"]}}'; out="$(c92_run C93)"
if grepq "$out" 'WARN C93-graph-role' && grepq "$out" -F 'the graph pass refuses'; then pass "C93 empty graphify entry -> WARN, the pass refuses"; else fail "C93 empty-role -> $out"; fi
c92_reset; c92_roles '{"version":1,"roles":{"graphify":["C","E"]}}'; out="$(c92_run C93)"
if grepq "$out" 'WARN C93-graph-role' && ! grepq "$out" -F 'the graph pass refuses'; then pass "C93 partial map -> WARN, the pass still runs"; else fail "C93 partial -> $out"; fi
c92_reset; c92_roles '{"version":1,"roles":{"graphify":["B"]}}'
printf '{"version":1,"ledger_path":"%s","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00"}}}' "$c92_t/credit/ledger.json" > "$c92_t/credit/config.json"
out="$(c92_run C93)"
if grepq "$out" 'WARN C93-graph-role' && grepq "$out" -F 'no-configured-account:graphify'; then pass "C93 a graphify entry with no configured letter -> WARN"; else fail "C93 no configured letter -> $out"; fi
c92_reset; out="$(c92_run C93)"
if grepq "$out" 'OK   C93-graph-role'; then pass "C93 absent map -> OK"; else fail "C93 absent -> $out"; fi
c92_reset; c92_roles '{"version":1,"roles":{"graphify":["A","B","C"]}}'; out="$(c92_run C93)"
if grepq "$out" 'OK   C93-graph-role'; then pass "C93 valid map -> OK"; else fail "C93 valid -> $out"; fi

echo "== C94: an unreadable graph config WARNs under its own id with the cause and the fix; a readable one is OK =="
c94_check() {
    local label="$1" cause="$2"
    out="$(c92_run C94)"
    if grepq "$out" 'WARN C94-graph-config' && grepq "$out" -F "cause=$cause" && ! grepq "$out" 'sk-ant'; then pass "C94 $label -> WARN naming cause=$cause"; else fail "C94 $label -> $out"; fi
}
c92_reset; printf 'sk-ant-api03-c94-planted-key {\n' > "$c92_t/home/.himmel/config.json"; c94_check "a non-JSON file holding a key-shaped string" not-json
c92_reset; : > "$c92_t/home/.himmel/config.json"; c94_check "an empty file" empty
c92_reset; printf '{"graphify":"x"}\n' > "$c92_t/home/.himmel/config.json"; c94_check "a graphify string" graphify-shape
c92_reset; printf '{}\n' > "$c92_t/real-config.json"; rm -f "$c92_t/home/.himmel/config.json"; ln -s "$c92_t/real-config.json" "$c92_t/home/.himmel/config.json"; c94_check "a symlinked config.json" symlink
c92_reset; rm -f "$c92_t/home/.himmel/config.json"; mkdir "$c92_t/home/.himmel/config.json"; c94_check "a directory at config.json" not-a-file
c92_reset; printf '{}\n' > "$c92_t/home/.himmel/config.json"; chmod 000 "$c92_t/home/.himmel/config.json"
if [ -r "$c92_t/home/.himmel/config.json" ]; then echo "  SKIP  C94 mode row: this user reads mode 000"; else c94_check "a mode-000 file" mode; fi
chmod 600 "$c92_t/home/.himmel/config.json"
c92_reset; rm -f "$c92_t/home/.himmel/config.json"; c92_lane_runner; c94_check "a missing file with an armed publish runner" missing
c92_reset; printf '{}\n' > "$c92_t/home/.himmel/config.json"; c92_lane_runner; c94_check "a file lacking the key with an armed publish runner" publisher-key-lost
c92_reset; out="$(c92_run C94)"
if grepq "$out" 'OK   C94-graph-config' && ! grepq "$out" 'WARN C94'; then pass "C94 a readable file (a publisher) -> OK"; else fail "C94 readable -> $out"; fi
c92_reset; rm -f "$c92_t/home/.himmel/config.json"; out="$(c92_run C94)"
if grepq "$out" 'OK   C94-graph-config'; then pass "C94 no file and no footprint (an adopter) -> OK"; else fail "C94 adopter -> $out"; fi
c92_reset; printf 'sk-ant-api03-c19c-planted-key-in-a-short-file' > "$c92_t/home/.himmel/config.json"; out="$(c92_run C94)"
if ! grepq "$out" 'sk-ant'; then pass "C94 the C19c fixture's output holds no key-shaped string"; else fail "C94 leaked the planted key: $out"; fi

echo "== C88: the lane warning names the runners lane-runners prints; unreadable names C94's fix and --leave-publisher =="
c88_reset; c88_key_in_env; c88_lane_runner
printf '#!/bin/sh\nHIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A bash semantic-update.sh\n' > "$c88_t/bat/graphmap-semantic-luna.sh"
out="$(c88_run)"
if grepq "$out" -F 'graphmap-publish-himmel.sh, graphmap-semantic-luna.sh)'; then pass "C88 the lane list is lane-runners' list"; else fail "C88 lane list -> $(printf '%s' "$out" | head -4)"; fi
c88_reset; c88_key_in_env; printf '{}\n' > "$c88_t/home/.himmel/config.json"
printf '#!/bin/sh\nHIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A bash semantic-update.sh\n' > "$c88_t/bat/graphmap-semantic-luna.sh"
out="$(c88_run)"
if grepq "$out" -F '(drops the lane)' && ! grepq "$out" -F 'leave-publisher'; then pass "C88 an adopter's fix still says it drops the lane"; else fail "C88 adopter fix -> $(printf '%s' "$out" | head -4)"; fi
c88_reset; c88_key_in_env; c88_lane_runner; printf 'this is not json\n' > "$c88_t/home/.himmel/config.json"
out="$(c88_run)"
if grepq "$out" 'WARN C88-graph-api-optin' && grepq "$out" -F 'cause=not-json' && grepq "$out" -F 'arm --rewrite-armed --leave-publisher' && ! grepq "$out" -F '(drops the lane)'; then pass "C88 unreadable with a lane runner -> the leave-publisher fix, no drop-the-lane promise"; else fail "C88 unreadable + lane -> $(printf '%s' "$out" | head -4)"; fi
c88_reset; c88_optin
out="$(c88_run)"
if grepq "$out" -F 'arm --rewrite-armed --leave-publisher'; then pass "C88 a publisher's leave-the-role text ends in --leave-publisher"; else fail "C88 publisher text -> $(printf '%s' "$out" | head -4)"; fi

echo "== C88 and C94 both WARN: the doctor's own --json ids carry both, each passing the chief wait's doctor= filter =="
c92_reset; printf 'this is not json\n' > "$c92_t/home/.himmel/config.json"; c92_lane_runner; printf 'ANTHROPIC_ORG_A_KEY=dummy-not-a-real-key-c94\n' > "$c92_t/env"
ids="$(c92_ids C88,C94)"
case "$ids" in ""|*[!0-9A-Za-z_,?.-]*) ids_ok=0 ;; *) ids_ok=1 ;; esac
if [ "$ids" = "C88-graph-api-optin,C94-graph-config" ] && [ "$ids_ok" = 1 ]; then pass "C94 sits beside a WARN C88: [$ids]"; else fail "C94 masking -> [$ids]"; fi

echo "== C92 and C93 with C88 already WARN: both ids still reach doctor= =="
c92_reset; c92_tag A; c92_roles '{"version":1,"roles":{"graphify":["A","E"]}}'; printf '{not json' > "$c92_t/home/.himmel/config.json"
c92_lane_runner; printf 'ANTHROPIC_ORG_A_KEY=dummy-not-a-real-key-c92\n' > "$c92_t/env"
ids="$(c92_ids C88,C92,C93)"
if [ "$ids" = "C88-graph-api-optin,C92-graph-key-A,C93-graph-role" ]; then pass "C92 and C93 sit beside a WARN C88: [$ids]"; else fail "C88 masking -> [$ids]"; fi
chmod -R u+rw "$c92_t" 2>/dev/null
rm -rf "$c92_t"

# shellcheck source=lib/timeout-bin.sh
# shellcheck disable=SC1091
{ . "$REPO_ROOT/scripts/lib/timeout-bin.sh"; } 2>/dev/null || _TIMEOUT_BIN=""
c95_t="$(mktemp -d "${TMPDIR:-/tmp}/c95.XXXXXX")" || { echo "FATAL: C95 setup mktemp failed" >&2; exit 1; }
git init -q "$c95_t/repo"
c95_repo="$(cd "$c95_t/repo" && pwd -P)"
c95_esc="${c95_repo//%/%25}"; c95_esc="${c95_esc//\//%2F}"
c95_holds="$c95_t/home/.himmel/state/holds"
c95_esc_of() { local s="${1//%/%25}"; printf '%s' "${s//\//%2F}"; }
c95_reset() { rm -rf "${c95_t:?}/home" "${c95_t:?}/claude" "$c95_repo/.single-writer"; mkdir -p "$c95_holds/$c95_esc" "$c95_t/claude"; }
c95_row() { printf '%b' "$2" > "$c95_holds/$c95_esc/$1"; }
c95_live() { c95_row 'scripts%2Fa.sh' 'HIMMEL-8725\tN1\t\tclaim\t\n'; }
c95_make_register_unreadable() { rmdir "$c95_holds/$c95_esc"; : > "$c95_holds/$c95_esc"; }
c95_run() { env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" bash "$DOC" --root "$REPO_ROOT" --only C95 --no-color 2>&1; }
c95_run_bounded() { env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" "${_TIMEOUT_BIN:-timeout}" -k 2 20 bash "$DOC" --root "$REPO_ROOT" --only C95 --no-color 2>&1 < /dev/null; }
echo "== C95: a .single-writer marker at the primary plus a live worker row -> WARN naming the repo and the marker age =="
c95_reset; c95_live; : > "$c95_repo/.single-writer"
out="$(c95_run)"
if grepq "$out" -E "WARN C95-barrier-off.*$c95_repo.*marker age [0-9]+"; then pass "C95 marker + live row -> WARN with repo and marker age"; else fail "C95 marker + live row -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: the marker alone (no live row) -> no WARN, an OK line =="
c95_reset; : > "$c95_repo/.single-writer"
out="$(c95_run)"
if grepq "$out" 'OK   C95-barrier-off' && ! grepq "$out" 'WARN C95'; then pass "C95 marker alone -> OK, no WARN"; else fail "C95 marker alone -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: a live row with no marker -> no WARN =="
c95_reset; c95_live
out="$(c95_run)"
if grepq "$out" 'OK   C95-barrier-off' && ! grepq "$out" 'WARN C95'; then pass "C95 live row, no marker -> OK, no WARN"; else fail "C95 live row, no marker -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: a corrupt register row -> WARN =="
c95_reset; c95_row 'scripts%2Fb.sh' 'not a row\n'
out="$(c95_run)"
if grepq "$out" -E "WARN C95-barrier-off.*$c95_repo.*unparseable"; then pass "C95 corrupt row -> WARN naming the repo"; else fail "C95 corrupt row -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: an unreadable register directory -> WARN =="
c95_reset; c95_make_register_unreadable
out="$(c95_run)"
if grepq "$out" -E "WARN C95-barrier-off.*cannot read.*$c95_repo"; then pass "C95 unreadable register -> WARN naming the repo"; else fail "C95 unreadable register -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: the OFF sentinel (a ruled, standing state) -> INFO with its reason, no WARN =="
c95_reset; printf '2026-11-08T10:00:00Z\tdecision 796 test reason\n' > "$c95_holds/OFF"
out="$(c95_run)"
if grepq "$out" -E "INFO C95-barrier-off.*OFF.*decision 796 test reason" && ! grepq "$out" 'WARN C95' && ! grepq "$out" 'OK   C95'; then pass "C95 OFF sentinel -> INFO with the reason"; else fail "C95 OFF sentinel -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: an OFF file that is not a holds.py off sentinel -> WARN =="
c95_reset; printf 'stray\n' > "$c95_holds/OFF"
out="$(c95_run)"
if grepq "$out" -E "WARN C95-barrier-off.*OFF.*not a holds.py off sentinel"; then pass "C95 stray OFF file -> WARN"; else fail "C95 stray OFF file -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: no marker and a clean register -> OK =="
c95_reset
out="$(c95_run)"
if grepq "$out" 'OK   C95-barrier-off' && ! grepq "$out" 'WARN C95'; then pass "C95 clean register -> OK"; else fail "C95 clean register -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: no register at all -> OK =="
rm -rf "${c95_t:?}/home" "$c95_repo/.single-writer"; mkdir -p "$c95_t/home"
out="$(c95_run)"
if grepq "$out" 'OK   C95-barrier-off' && ! grepq "$out" 'WARN C95'; then pass "C95 no register -> OK"; else fail "C95 no register -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: a holds root that cannot be listed -> WARN, never a silent OK =="
if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP: C95 unlistable holds root — root reads any directory"
else
    c95_reset; chmod 000 "$c95_holds"
    out="$(c95_run)"
    chmod 700 "$c95_holds"
    if grepq "$out" -E 'WARN C95-barrier-off.*cannot list'; then pass "C95 unlistable holds root -> WARN"; else fail "C95 unlistable holds root -> $(printf '%s' "$out" | head -4)"; fi
fi
echo "== C95: an OFF entry that is a FIFO -> WARN and the doctor does not hang =="
if command -v mkfifo >/dev/null 2>&1 && [ -n "${_TIMEOUT_BIN:-}" ]; then
    c95_reset; mkfifo "$c95_holds/OFF"
    out="$(c95_run_bounded)"
    if grepq "$out" -E 'WARN C95-barrier-off.*OFF.*not a regular file'; then pass "C95 FIFO OFF -> WARN, no hang"; else fail "C95 FIFO OFF -> $(printf '%s' "$out" | head -4)"; fi
else
    echo "  SKIP: C95 FIFO OFF — no mkfifo or no timeout binary"
fi
echo "== C95: a holds.py that never returns -> WARN 'cannot read ... exit 124' inside the HIMMEL_DOCTOR_HOLDS_T bound =="
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    c95_reset; mkdir -p "$c95_t/slow/scripts/handover/chief-kit"; ln -s "$REPO_ROOT/scripts/lib" "$c95_t/slow/scripts/lib"
    printf 'import os, sys, time\nif sys.argv[1] == "repo-gone":\n    sys.exit(1 if os.path.lexists(sys.argv[sys.argv.index("--repo") + 1]) else 0)\ntime.sleep(60)\n' > "$c95_t/slow/scripts/handover/chief-kit/holds.py"
    SECONDS=0
    out="$(env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" HIMMEL_DOCTOR_HOLDS_T=2 "$_TIMEOUT_BIN" -k 2 40 bash "$DOC" --root "$c95_t/slow" --only C95 --no-color 2>&1 < /dev/null)"
    if grepq "$out" -E "WARN C95-barrier-off.*holds read TIMED OUT after [0-9]+s for $c95_repo.*UNKNOWN.*not a barrier-off finding" && ! grepq "$out" 'single-writer barrier is OFF' && [ "$SECONDS" -lt 15 ]; then pass "C95 holds.py that sleeps -> its own TIMED OUT line, not barrier-off, in ${SECONDS}s"; else fail "C95 sleeping holds.py (${SECONDS}s) -> $(printf '%s' "$out" | head -4)"; fi
    echo "== C95: the bound covers every register together, so a second repo cannot extend it =="
    mkdir -p "$c95_t/second-repo" "$c95_holds/$(c95_esc_of "$c95_t/second-repo")"
    SECONDS=0
    out="$(env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" HIMMEL_DOCTOR_HOLDS_T=3 "$_TIMEOUT_BIN" -k 2 40 bash "$DOC" --root "$c95_t/slow" --only C95 --no-color 2>&1 < /dev/null)"
    if [ "$(printf '%s\n' "$out" | grep -c 'WARN C95-barrier-off')" -eq 2 ] && grepq "$out" -E "WARN C95-barrier-off.*TIMED OUT.*$c95_repo" && grepq "$out" -E "WARN C95-barrier-off.*holds read NOT ATTEMPTED for $c95_t/second-repo.*budget.*UNKNOWN.*not a barrier-off finding" && ! grepq "$out" 'single-writer barrier is OFF' && ! grepq "$out" 'raise HIMMEL_DOCTOR_HOLDS_T' && [ "$SECONDS" -lt 12 ]; then pass "C95 two registers share one bound (${SECONDS}s)"; else fail "C95 two registers (${SECONDS}s) -> $(printf '%s' "$out" | head -5)"; fi
    echo "== C95: a register whose repo is gone is skipped, so it cannot spend the budget of a live repo =="
    rm -rf "${c95_t:?}/second-repo" "${c95_holds:?}/$(c95_esc_of "$c95_t/second-repo")"
    mkdir -p "$c95_holds/$(c95_esc_of "$c95_t/aa-gone-repo")"
    SECONDS=0
    out="$(env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" HIMMEL_DOCTOR_HOLDS_T=3 "$_TIMEOUT_BIN" -k 2 40 bash "$DOC" --root "$c95_t/slow" --only C95 --no-color 2>&1 < /dev/null)"
    if grepq "$out" -E "WARN C95-barrier-off.*TIMED OUT after [0-9]+s for $c95_repo" && ! grepq "$out" 'aa-gone-repo' && ! grepq "$out" 'NOT ATTEMPTED' && [ "$SECONDS" -lt 10 ]; then pass "C95 gone repo spends no budget: the live repo is read with all of it (${SECONDS}s)"; else fail "C95 gone repo first (${SECONDS}s) -> $(printf '%s' "$out" | head -5)"; fi
    echo "== C95: the main checkout is read first, a timeout is its own line, a true barrier-off still shows =="
    c95_mf="$c95_t/mf"
    mkdir -p "$c95_mf/scripts/handover/chief-kit" "$c95_t/aa-other" "$c95_t/zz-sleepy" "$c95_holds/$(c95_esc_of "$c95_mf")" "$c95_holds/$(c95_esc_of "$c95_t/aa-other")" "$c95_holds/$(c95_esc_of "$c95_t/zz-sleepy")"
    ln -s "$REPO_ROOT/scripts/lib" "$c95_mf/scripts/lib"
    cat > "$c95_mf/scripts/handover/chief-kit/holds.py" <<'PY'
import os, sys, time
repo = sys.argv[sys.argv.index('--repo') + 1]
if sys.argv[1] == 'repo-gone':
    sys.exit(1)
open(os.environ['C95_STUB_LOG'], 'a').write(repo + '\n')
if repo.endswith('zz-sleepy'):
    time.sleep(60)
print('scripts/a.sh\tHIMMEL-1\tN1\tclaim\t\talive')
PY
    : > "$c95_mf/.single-writer"; : > "$c95_t/mf-read.log"
    SECONDS=0
    out="$(env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" HIMMEL_DOCTOR_HOLDS_T=4 C95_STUB_LOG="$c95_t/mf-read.log" "$_TIMEOUT_BIN" -k 2 40 bash "$DOC" --root "$c95_mf" --only C95 --no-color 2>&1 < /dev/null)"
    if [ "$(head -n 1 "$c95_t/mf-read.log")" = "$c95_mf" ]; then pass "C95 reads the main checkout's register first, whatever the name order"; else fail "C95 read order -> $(tr '\n' ' ' < "$c95_t/mf-read.log")"; fi
    if grepq "$out" -E "WARN C95-barrier-off.*single-writer barrier is OFF for $c95_mf.*1 live worker row"; then pass "C95 still reports a true barrier-off with a live row beside a timed-out repo"; else fail "C95 barrier-off control -> $(printf '%s' "$out" | head -5)"; fi
    if grepq "$out" -E "WARN C95-barrier-off.*TIMED OUT after [0-9]+s for $c95_t/zz-sleepy.*UNKNOWN" && ! grepq "$out" -E "barrier is OFF for $c95_t/zz-sleepy" && ! grepq "$out" -E "barrier is OFF for $c95_t/aa-other"; then pass "C95 the timed-out repo gets its own line and is never called barrier-off"; else fail "C95 timeout vs barrier-off -> $(printf '%s' "$out" | head -5)"; fi
else
    echo "  SKIP: C95 sleeping holds.py — no timeout binary"
fi
echo "== C95: whether a repo is gone is holds.py's answer (repo-gone), the question the cadence asks too =="
c95_sp="$c95_t/sp"
rm -rf "${c95_t:?}/home" "$c95_t/claude"; mkdir -p "$c95_t/claude" "$c95_sp/scripts/handover/chief-kit" "$c95_t/aa-live" "$c95_t/zz-gone-by-verb"
ln -s "$REPO_ROOT/scripts/lib" "$c95_sp/scripts/lib"
mkdir -p "$c95_holds/$(c95_esc_of "$c95_t/aa-live")" "$c95_holds/$(c95_esc_of "$c95_t/bb-missing")" "$c95_holds/$(c95_esc_of "$c95_t/zz-gone-by-verb")"
cat > "$c95_sp/scripts/handover/chief-kit/holds.py" <<'PY'
import os, sys
repo = sys.argv[sys.argv.index('--repo') + 1]
if sys.argv[1] == 'repo-gone':
    sys.exit(0 if os.path.basename(repo) == 'zz-gone-by-verb' else 1)
open(os.environ['C95_STUB_LOG'], 'a').write(repo + '\n')
PY
: > "$c95_t/sp-read.log"
out="$(env CLAUDE_DIR="$c95_t/claude" HOME="$c95_t/home" C95_STUB_LOG="$c95_t/sp-read.log" bash "$DOC" --root "$c95_sp" --only C95 --no-color 2>&1 < /dev/null)"
if [ "$(cat "$c95_t/sp-read.log")" = "$c95_t/aa-live
$c95_t/bb-missing" ] && grepq "$out" -E 'OK   C95-barrier-off.*1 register of a removed repo not read'; then pass "C95 skips the repo holds.py calls gone (though it exists) and reads the one it does not (though it is missing)"; else fail "C95 repo-gone verb -> log [$(tr '\n' ' ' < "$c95_t/sp-read.log")] $(printf '%s' "$out" | head -3)"; fi
echo "== C95: a register of a removed repo is skipped, and the OK line counts it =="
c95_reset; mkdir -p "$c95_holds/$(c95_esc_of "$c95_t/gone-repo")"; printf 'not a row\n' > "$c95_holds/$(c95_esc_of "$c95_t/gone-repo")/scripts%2Fb.sh"
out="$(c95_run)"
if grepq "$out" -E 'OK   C95-barrier-off.*1 register of a removed repo not read' && ! grepq "$out" 'WARN C95' && ! grepq "$out" 'gone-repo'; then pass "C95 removed repo's corrupt register is skipped and counted"; else fail "C95 removed repo -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: a repo that exists is never called gone, even a live one with a corrupt register (control) =="
c95_reset; c95_row 'scripts%2Fb.sh' 'not a row\n'
out="$(c95_run)"
if grepq "$out" -E "WARN C95-barrier-off.*$c95_repo.*unparseable" && ! grepq "$out" 'removed repo'; then pass "C95 live repo with a corrupt register still WARNs and is not counted as removed"; else fail "C95 live corrupt control -> $(printf '%s' "$out" | head -4)"; fi
echo "== C95: a repo path behind a directory this user cannot search is unknown, not gone =="
if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP: C95 unsearchable parent — root searches any directory"
else
    c95_reset; mkdir -p "$c95_t/locked/under-repo"; mkdir -p "$c95_holds/$(c95_esc_of "$c95_t/locked/under-repo")"
    printf 'not a row\n' > "$c95_holds/$(c95_esc_of "$c95_t/locked/under-repo")/scripts%2Fb.sh"; chmod 000 "$c95_t/locked"
    out="$(c95_run)"
    chmod 700 "$c95_t/locked"
    if grepq "$out" -E "WARN C95-barrier-off.*$c95_t/locked/under-repo.*unparseable" && ! grepq "$out" 'removed repo'; then pass "C95 unsearchable parent -> still read, not skipped as gone"; else fail "C95 unsearchable parent -> $(printf '%s' "$out" | head -4)"; fi
    rm -rf "$c95_t/locked"
fi
rm -rf "$c95_t"

c96_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c96.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c96_t/home/.himmel" "$c96_t/claude"
c96_fx="$REPO_ROOT/scripts/jira/src/fixtures"
# shellcheck disable=SC2016  # the probe expands C96_JSON itself
printf '#!/usr/bin/env bash\ncat "$C96_JSON"\n' > "$c96_t/probe"
c96_run() { C96_JSON="$1" TRACKER="${C96_TRACKER:-jira}" JIRA_PROJECT_KEY=HIMMEL HIMMEL_DOCTOR_LIVE_TEST_PROBE="$c96_t/probe" \
    CLAUDE_DIR="$c96_t/claude" HOME="$c96_t/home" HIMMEL_CONFIG_DIR="" bash "$DOC" --root "$REPO_ROOT" --no-color --only C96 "${@:2}" 2>&1; }
echo "== C96-jira-test-project: Jira is the tracker and no JIRA_TEST_PROJECT -> WARN =="
out="$(c96_run "$c96_fx/live-test-none.json")"
if grepq "$out" -F 'WARN C96-jira-test-project' && grepq "$out" -F 'himmelctl config set jira.testProject'; then pass "WARN C96 when Jira is the tracker and no JIRA_TEST_PROJECT"; else fail "C96 none -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: JIRA_TEST_PROJECT=HIMMEL is a work project -> WARN with the problem =="
out="$(c96_run "$c96_fx/live-test-work.json")"
if grepq "$out" -F 'WARN C96-jira-test-project' && grepq "$out" -F 'HIMMEL is a work project (JIRA_PROJECTS)' && grepq "$out" -F 'himmelctl config set jira.testProject'; then pass "WARN with the problem for JIRA_TEST_PROJECT=HIMMEL"; else fail "C96 work -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: JIRA_TEST_PROJECT=HTEST -> OK =="
out="$(c96_run "$c96_fx/live-test-ok.json")"
if grepq "$out" -F 'OK   C96-jira-test-project' && grepq "$out" -F 'JIRA_TEST_PROJECT=HTEST' && ! grepq "$out" -E '(WARN|INFO) C96'; then pass "OK for HTEST"; else fail "C96 ok -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: the tracker is not Jira -> INFO (negative control) =="
out="$(C96_TRACKER=local c96_run "$c96_fx/live-test-none.json")"
if grepq "$out" -F 'INFO C96-jira-test-project' && grepq "$out" -F 'the tracker is local' && ! grepq "$out" -F 'WARN C96'; then pass "INFO when the tracker is not jira"; else fail "C96 tracker local -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: the probe prints no readable JSON -> INFO, not checked =="
out="$(c96_run "$c96_t/no-such-file.json")"
if grepq "$out" -F 'INFO C96-jira-test-project' && grepq "$out" -F 'not checked' && ! grepq "$out" -F 'WARN C96'; then pass "INFO when the live-test read fails"; else fail "C96 unreadable -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: the --json row carries scope shared =="
out="$(c96_run "$c96_fx/live-test-ok.json" --json)"
if [ "$(printf '%s\n' "$out" | grep '^{' | jq -r 'select(.id == "C96-jira-test-project") | .scope' 2>/dev/null)" = shared ]; then pass "C96 is a shared check"; else fail "C96 --json scope -> $(printf '%s' "$out" | head -4)"; fi
echo "== C96-jira-test-project: no probe and no jira CLI build -> INFO =="
c96_x="$c96_t/repo"
mkdir -p "$c96_x/scripts/lib"
cp "$REPO_ROOT/scripts/himmel-doctor.sh" "$c96_x/scripts/"
cp -R "$REPO_ROOT/scripts/lib/." "$c96_x/scripts/lib/"
out="$(cd "$c96_x" && env -u HIMMEL_DOCTOR_LIVE_TEST_PROBE -u HIMMEL_REPO -u HIMMEL_DOCTOR_ROOT TRACKER=jira JIRA_PROJECT_KEY=HIMMEL CLAUDE_DIR="$c96_t/claude" HOME="$c96_t/home" HIMMEL_CONFIG_DIR="" \
    bash "$c96_x/scripts/himmel-doctor.sh" --root "$c96_x" --no-color --only C96 2>&1)"
if grepq "$out" -F 'INFO C96-jira-test-project' && grepq "$out" -F 'scripts/jira/dist/index.js' && ! grepq "$out" -F 'WARN C96'; then pass "INFO when the CLI build is missing"; else fail "C96 no CLI build -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c96_t"

c97_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c97.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
mkdir -p "$c97_t/claude" "$c97_t/home" "$c97_t/codex"
c97_dummy="FIXTURE-DUMMY-9f3a"
c97_run() { CODEX_HOME="$c97_t/codex" CLAUDE_DIR="$c97_t/claude" HOME="$c97_t/home" bash "$DOC" --root "$REPO_ROOT" --no-color --only C97 "$@" 2>&1; }
c97_cfg() { printf '%s\n' "$1" > "$c97_t/codex/config.toml" || fail "C97 fixture write failed"; }
c97_base='[mcp_servers.obsidian-vault]
command = "node"
args = ["/x/server.js"]
'
echo "== C97: a literal OBSIDIAN_API_KEY in [mcp_servers.obsidian-vault.env] -> WARN naming server + variable, never the value =="
c97_cfg "$c97_base
[mcp_servers.obsidian-vault.env]
OBSIDIAN_API_KEY = \"$c97_dummy\"
OBSIDIAN_HOST = \"127.0.0.1\""
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'obsidian-vault' && grepq "$out" -F 'OBSIDIAN_API_KEY' \
   && grepq "$out" -F "$c97_t/codex/config.toml" && grepq "$out" -F 'scripts/mcp/secret-launch.mjs' && grepq "$out" -F 'mcp-secrets' \
   && grepq "$out" -F 'does not edit' && ! grepq "$out" -F "$c97_dummy" && ! grepq "$out" -F 'OBSIDIAN_HOST'; then
    pass "C97 WARN names the server and variable, carries the remedy, and never the value"
else
    fail "C97 literal key -> $(printf '%s' "$out" | head -5)"
fi
echo "== C97: the --json row carries scope shared and no value =="
out="$(c97_run --json)"
if [ "$(printf '%s\n' "$out" | grep '^{' | jq -r 'select(.id == "C97-codex-mcp-literal-key") | .scope' 2>/dev/null)" = shared ] && ! grepq "$out" -F "$c97_dummy"; then pass "C97 is a shared check"; else fail "C97 --json -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: the same file with the key line removed -> OK (control) =="
c97_cfg "$c97_base
[mcp_servers.obsidian-vault.env]
OBSIDIAN_HOST = \"127.0.0.1\"
OBSIDIAN_PORT = \"27124\""
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && ! grepq "$out" -E '(WARN|INFO) C97'; then pass "C97 OK without a secret-named variable (HOST/PORT are not secrets)"; else fail "C97 control -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: the inline form env = { SOME_TOKEN = \"...\" } -> WARN =="
c97_cfg "[mcp_servers.x]
command = \"node\"
env = { SOME_TOKEN = \"$c97_dummy-inline\", PLAIN = \"1\" }"
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'SOME_TOKEN' && grepq "$out" -F 'mcp_servers.x' && ! grepq "$out" -F "$c97_dummy" && ! grepq "$out" -F 'PLAIN'; then pass "C97 WARN for the inline env table"; else fail "C97 inline -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: header spellings (quoted segments, spaces, trailing comment) and a _SECRET name -> WARN =="
c97_cfg "[ \"mcp_servers\" . 'my-srv' . \"env\" ]  # local
MY_API_SECRET = \"$c97_dummy\""
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'my-srv' && grepq "$out" -F 'MY_API_SECRET' && ! grepq "$out" -F "$c97_dummy"; then pass "C97 WARN for a quoted, spaced, commented header"; else fail "C97 header spelling -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: env_vars = [names] (no value) -> OK =="
c97_cfg "$c97_base
env_vars = [\"OBSIDIAN_API_KEY\"]"
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && ! grepq "$out" -E '(WARN|INFO) C97'; then pass "C97 OK for an env_vars name list"; else fail "C97 env_vars -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: an empty value and a commented-out line -> OK =="
c97_cfg "$c97_base
[mcp_servers.obsidian-vault.env]
OBSIDIAN_API_KEY = \"\"
OTHER_TOKEN = ''
# OBSIDIAN_SECRET = \"$c97_dummy\""
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && ! grepq "$out" -E '(WARN|INFO) C97'; then pass "C97 OK for an empty value and a comment"; else fail "C97 empty/comment -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: an empty value followed by a TOML comment -> OK; a literal followed by a comment -> WARN =="
c97_cfg "$c97_base
[mcp_servers.obsidian-vault.env]
OBSIDIAN_API_KEY = \"\" # unused
OTHER_TOKEN = '' # unused
EMPTY_KEY = \"\"\"\"\"\"
EMPTY_TOKEN = '''''' # unused"
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && ! grepq "$out" -E '(WARN|INFO) C97'; then pass "C97 OK for an empty value with a trailing comment"; else fail "C97 empty+comment -> $(printf '%s' "$out" | head -4)"; fi
c97_cfg "[mcp_servers.obsidian-vault.env]
OBSIDIAN_API_KEY = \"$c97_dummy\" # local
BARE_TOKEN = 12345 # local
TRIPLE_SECRET = \"\"\"$c97_dummy\"\"\"
LITERAL_KEY = '''$c97_dummy'''"
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'OBSIDIAN_API_KEY' && grepq "$out" -F 'BARE_TOKEN' && grepq "$out" -F 'TRIPLE_SECRET' && grepq "$out" -F 'LITERAL_KEY' && ! grepq "$out" -F "$c97_dummy" && ! grepq "$out" -F '12345'; then pass "C97 WARN for a literal with a trailing comment"; else fail "C97 literal+comment -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: an escaped quote inside an inline basic-string value still commits the pair -> WARN =="
c97_cfg '[mcp_servers.x]
command = "node"
env = { SOME_API_KEY = "FIXTURE-DUMMY-9f3a\"tail", PLAIN = "1" }'
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'SOME_API_KEY' && ! grepq "$out" -F 'FIXTURE-DUMMY-9f3a'; then pass "C97 WARN for an escaped quote in an inline value"; else fail "C97 escaped quote -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: a CRLF config reads like an LF one -> WARN =="
printf '[mcp_servers.a.env]\r\nA_API_KEY = "%s"\r\n' "$c97_dummy" > "$c97_t/codex/config.toml"
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'A_API_KEY' && ! grepq "$out" -F "$c97_dummy"; then pass "C97 WARN for a CRLF config"; else fail "C97 CRLF -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: the scan itself fails -> INFO, never OK =="
mkdir -p "$c97_t/badawk"
printf '#!/bin/sh\nexit 2\n' > "$c97_t/badawk/awk"; chmod +x "$c97_t/badawk/awk"
c97_cfg "[mcp_servers.a.env]
A_API_KEY = \"$c97_dummy\""
out="$(PATH="$c97_t/badawk:$PATH" c97_run)"
if grepq "$out" -F 'INFO C97-codex-mcp-literal-key' && grepq "$out" -F 'scan failed' && ! grepq "$out" -E '(OK  |WARN) C97'; then pass "C97 INFO when the scan fails"; else fail "C97 scan failure -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: a secret-named key outside any mcp_servers env table -> OK =="
c97_cfg "[projects.\"/x\"]
trust_level = \"trusted\"
SOME_API_KEY = \"$c97_dummy\"
[mcp_servers.obsidian-vault.tools.search]
approval_mode = \"approve\"
TOOL_TOKEN = \"$c97_dummy\""
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && ! grepq "$out" -E '(WARN|INFO) C97'; then pass "C97 OK for a key outside an mcp_servers env table"; else fail "C97 outside -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: a disabled server (enabled = false) with a literal key -> still WARN =="
c97_cfg "[mcp_servers.obsidian-vault]
command = \"node\"
enabled = false
[mcp_servers.obsidian-vault.env]
OBSIDIAN_API_KEY = \"$c97_dummy\""
out="$(c97_run)"
if grepq "$out" -F 'WARN C97-codex-mcp-literal-key' && grepq "$out" -F 'OBSIDIAN_API_KEY' && ! grepq "$out" -F "$c97_dummy"; then pass "C97 WARN for a disabled server (the key is still on disk)"; else fail "C97 disabled -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: two servers, two variables -> one WARN names each pair =="
c97_cfg "[mcp_servers.a.env]
A_API_KEY = \"$c97_dummy\"
[mcp_servers.b.env]
B_TOKEN = \"$c97_dummy\""
out="$(c97_run)"
if [ "$(printf '%s\n' "$out" | grep -c 'WARN C97-codex-mcp-literal-key')" -eq 1 ] && grepq "$out" -F '[mcp_servers.a] A_API_KEY, [mcp_servers.b] B_TOKEN' && ! grepq "$out" -F "$c97_dummy"; then pass "C97 names every offending pair"; else fail "C97 two servers -> $(printf '%s' "$out" | head -4)"; fi
echo "== C97: no Codex config at CODEX_HOME -> OK =="
rm -f "$c97_t/codex/config.toml"
out="$(c97_run)"
if grepq "$out" -F 'OK   C97-codex-mcp-literal-key' && grepq "$out" -F 'no codex config'; then pass "C97 OK when there is no Codex config"; else fail "C97 no config -> $(printf '%s' "$out" | head -4)"; fi
if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then
    echo "== C97: unreadable config -> SKIPPED (running as root: mode 000 is still readable) =="
else
    echo "== C97: an unreadable config -> INFO, never OK =="
    c97_cfg "[mcp_servers.a.env]
A_API_KEY = \"$c97_dummy\""
    chmod 000 "$c97_t/codex/config.toml"
    out="$(c97_run)"
    if grepq "$out" -F 'INFO C97-codex-mcp-literal-key' && grepq "$out" -F 'not readable' && ! grepq "$out" -E '(OK  |WARN) C97'; then pass "C97 INFO for an unreadable config"; else fail "C97 unreadable -> $(printf '%s' "$out" | head -4)"; fi
    chmod 600 "$c97_t/codex/config.toml"
fi
rm -rf "$c97_t"

c98_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c98.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
c98_b="$c98_t/root/u/himmel"
mkdir -p "$c98_b" "$c98_t/home" "$c98_t/claude" "$c98_t/proc"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nls "$CLAUDE_SESSIONS_PROC"\n' > "$c98_t/pgrep"; chmod +x "$c98_t/pgrep"
c98_session() { mkdir -p "$c98_t/proc/$1"; printf 'claude\0-n\0%s\0' "$2" > "$c98_t/proc/$1/cmdline"; }
c98_doc() {
    local e
    e=$(( $(date +%s) - $4 * 60 ))
    printf '%s\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE x\n- 09:30 %s x\n' "$2" "$3" > "$c98_b/$1.md"
    touch -t "$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$e" +%Y%m%d%H%M.%S)" "$c98_b/$1.md"
}
c98_run() { HIMMEL_DOCTOR_WRAPPED_MIN=15 HANDOVER_DIR="$c98_t/root" HIMMEL_BUCKET_DIR="$c98_b" HOME="$c98_t/home" CLAUDE_DIR="$c98_t/claude" \
    CLAUDE_SESSIONS_PROC="$c98_t/proc" CLAUDE_SESSIONS_PGREP="$c98_t/pgrep" bash "$DOC" --root "$REPO_ROOT" --no-color --only C98 2>&1; }
echo "== C98: a wrapped, lock-free worker and chief still open 20 min later -> WARN naming each =="
c98_doc W1 '# T-1 — a wrapped worker — worker W1' WRAPPED 20
c98_doc AR '# AR — CHIEF — successor to AQ.md (fill signal 45 %)' WRAPPED 20
c98_doc T-5-N5-task-2026-11-20 '# T-5 — a dated doc run under its undated session name — worker N5' WRAPPED 20
c98_session 301 W1-r2; c98_session 302 AR; c98_session 303 T-5-N5-task
out="$(c98_run)"
if grepq "$out" -F 'WARN C98-wrapped-window' && grepq "$out" -F 'W1 (worker)' && grepq "$out" -F 'AR (chief)' && grepq "$out" -F 'T-5-N5-task-2026-11-20 (worker)' && grepq "$out" -F 'close-wrapped-worker.sh --check'; then pass "C98 WARN names each lingering wrapped window, a dated doc under its undated session name too"; else fail "C98 lingering -> $(printf '%s' "$out" | head -4)"; fi
echo "== C98: control: working, freshly wrapped and session-less docs -> OK =="
rm -f "$c98_b/T-5-N5-task-2026-11-20.md"
c98_doc W1 '# T-1 — a working worker — worker W1' LIVE 20
c98_doc AR '# AR — CHIEF — successor to AQ.md (fill signal 45 %)' WRAPPED 5
c98_doc Z1 '# T-3 — a wrapped worker whose window is gone — worker Z1' WRAPPED 20
out="$(c98_run)"
if grepq "$out" -F 'OK   C98-wrapped-window' && ! grepq "$out" -E '(WARN|INFO) C98'; then pass "C98 OK with no lingering wrapped window"; else fail "C98 control -> $(printf '%s' "$out" | head -4)"; fi
echo "== C98: an aged doc of a live session that cannot be read is INFO, never OK =="
c98_doc U1 '# T-6 — an unreadable wrapped worker — worker U1' WRAPPED 20
c98_session 304 U1; chmod 000 "$c98_b/U1.md"
out="$(c98_run)"
chmod 644 "$c98_b/U1.md"; rm -rf "$c98_t/proc/304"
if [ "$(id -u)" = 0 ]; then pass "C98 unreadable doc -> skipped as root (chmod does not block root)"
elif grepq "$out" -F 'INFO C98-wrapped-window' && grepq "$out" -F 'U1' && ! grepq "$out" -E '(OK  |WARN) C98'; then pass "C98 INFO names an unreadable doc"; else fail "C98 unreadable doc -> $(printf '%s' "$out" | head -4)"; fi
echo "== C98: a census that exits 3 with no rows is INFO, never OK =="
printf '#!/usr/bin/env bash\nexit 3\n' > "$c98_t/pgrep3"; chmod +x "$c98_t/pgrep3"
out="$(HIMMEL_DOCTOR_WRAPPED_MIN=15 HANDOVER_DIR="$c98_t/root" HIMMEL_BUCKET_DIR="$c98_b" HOME="$c98_t/home" CLAUDE_DIR="$c98_t/claude" \
    CLAUDE_SESSIONS_PROC="$c98_t/proc" CLAUDE_SESSIONS_PGREP="$c98_t/pgrep3" bash "$DOC" --root "$REPO_ROOT" --no-color --only C98 2>&1)"
if grepq "$out" -F 'INFO C98-wrapped-window' && ! grepq "$out" -E '(OK  |WARN) C98'; then pass "C98 INFO on a failed census"; else fail "C98 census rc 3 -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c98_t"

printed_keys() {
    awk '/^[[:space:]]*#/ { next }
    {
        s = ""; q = ""; n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (q == "") {
                if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[[:space:]]/)) break
                if (c == "\"" || c == "\047") q = c
            } else if (c == q) { q = "" }
            else { if (c == "\\" && q == "\"") { i++; c = c substr($0, i, 1) } s = s c }
        }
        if (s ~ /HIMMEL-[0-9]/) print FNR ": " $0
    }' "$1"
}
echo "== printed text: the planted control is caught, comments are not =="
pk_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-pk.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
pk_k="HIMMEL"
{
    printf '# a comment may name %s-1\n' "$pk_k"
    # shellcheck disable=SC2016  # literal fixture text, no expansion intended
    printf 'x=$((10#$y))  # so may a trailing one: %s-2\n' "$pk_k"
    printf '%s\n' 'emit OK C99-clean "clean text with # inside quotes"'
    printf 'emit WARN C99-planted "a planted row (%s-1234)" "do the thing"\n' "$pk_k"
    printf "    \"fix: see '%s-77'\"\n" "$pk_k"
} > "$pk_t/doctor.sh"
out="$(printed_keys "$pk_t/doctor.sh")"
if [ "$out" = "$(printf '4: emit WARN C99-planted "a planted row (%s-1234)" "do the thing"\n5:     "fix: see '\''%s-77'\''"' "$pk_k" "$pk_k")" ]; then pass "printed-key scan flags the two planted printed lines only"; else fail "printed-key scan on the planted fixture -> $out"; fi
echo "== printed text: no line the doctor prints carries a ticket key =="
out="$(printed_keys "$DOC")"
if [ -z "$out" ]; then pass "the doctor prints no ticket key"; else fail "the doctor prints ticket keys: $out"; fi
rm -rf "$pk_t"

c99_t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c99.XXXXXX")" || exit 1
mkdir -p "$c99_t/repo/.agents/rules" "$c99_t/repo/.gemini" "$c99_t/home" "$c99_t/claude"
ln -s "$REPO_ROOT/scripts" "$c99_t/repo/scripts"
git -C "$c99_t/repo" init -q
c99_run() { HOME="$c99_t/home" CLAUDE_DIR="$c99_t/claude" bash "$DOC" --root "$c99_t/repo" --only C99 --no-color 2>&1; }
out="$(c99_run)"
if grepq "$out" 'OK   C99-gemini-local'; then pass "C99 clean tree -> OK"; else fail "C99 clean tree -> $out"; fi
printf '%s\n' "Use \`graphify query lanes\` for structure." > "$c99_t/repo/.agents/rules/graphify.md"
out="$(c99_run)"
if grepq "$out" 'WARN C99-gemini-local' && grepq "$out" -F '.agents/rules/graphify.md'; then pass "C99 stale bare graphify rule -> WARN"; else fail "C99 stale rule -> $out"; fi
if grep -qF 'graphify query lanes' "$c99_t/repo/.agents/rules/graphify.md"; then pass "C99 leaves stale rule unchanged"; else fail "C99 rewrote stale rule"; fi
printf '%s\n' "Use \`bash scripts/graphify/worker-graph.sh query lanes\`." > "$c99_t/repo/.agents/rules/graphify.md"
printf '{"hooks":{"BeforeTool":[{"command":"graphify.EXE query lanes"}]}}\n' > "$c99_t/repo/.gemini/settings.json"
out="$(c99_run)"
if grepq "$out" 'WARN C99-gemini-local' && grepq "$out" -F '.gemini/settings.json'; then pass "C99 untracked graphify.EXE settings -> WARN"; else fail "C99 stale settings -> $out"; fi
if grep -qF 'graphify.EXE' "$c99_t/repo/.gemini/settings.json"; then pass "C99 leaves settings unchanged"; else fail "C99 rewrote settings"; fi
git -C "$c99_t/repo" add .gemini/settings.json
out="$(c99_run)"
if grepq "$out" 'OK   C99-gemini-local'; then pass "C99 tracked settings and wrapper rule -> OK"; else fail "C99 tracked settings -> $out"; fi
git -C "$c99_t/repo" rm --cached -q .gemini/settings.json
printf '{"hooks":{"BeforeTool":[{"command":"/missing/graphify query lanes"}]}}\n' > "$c99_t/repo/.gemini/settings.json"
out="$(c99_run)"
if grepq "$out" 'WARN C99-gemini-local'; then pass "C99 missing absolute executable -> WARN"; else fail "C99 missing path -> $out"; fi
printf '{"hooks":{"BeforeTool":[{"command":"bash scripts/graphify/worker-graph.sh query lanes"}]}}\n' > "$c99_t/repo/.gemini/settings.json"
out="$(c99_run)"
if grepq "$out" 'OK   C99-gemini-local' && ! grepq "$out" 'WARN C99'; then pass "C99 current settings and wrapper rule -> OK"; else fail "C99 current settings -> $out"; fi
rm -rf "$c99_t"

c100_t="$(mktemp -d "${TMPDIR:-/tmp}/c100.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
cat > "$c100_t/ack" <<'STUB'
#!/usr/bin/env bash
[ -z "${C100_SLEEP:-}" ] || sleep "$C100_SLEEP"
[ -z "${C100_ARGS_OUT:-}" ] || printf '%s\n' "$*" > "$C100_ARGS_OUT"
cat "$C100_JSON"
exit "${C100_RC:-0}"
STUB
chmod 755 "$c100_t/ack"
c100_fleet() {
    local b="$c100_t/root/$1" attempts="${2:-}"
    [ -n "$attempts" ] || attempts='{}'
    mkdir -p "$b"
    printf '{}\n' > "$b/chief.fleet.json"
    printf '{"family":"f","attempts":%s}\n' "$attempts" > "$b/fleet-control.json"
}
c100_run() { HANDOVER_DIR="$c100_t/root" HIMMEL_DOCTOR_FLEET_ACK="$c100_t/ack" HIMMEL_DOCTOR_FLEET_TIMEOUT="${C100_TIMEOUT:-10}" \
    C100_JSON="$c100_t/answer.json" bash "$DOC" --root "$REPO_ROOT" --no-color --only C100 2>&1; }
c100_attempts='{"a1":{"attempt_id":"a1","manifest":"'"$c100_t"'/root/u/r/chief.fleet.json"}}'
c100_clean='{"managed":true,"in_flight":[],"unknown":[],"legacy_unknown":[],"launched":[],"quiescent":false}'

echo "== C100: no fleet-control.json under the handover root -> INFO, never OK =="
mkdir -p "$c100_t/root"
printf '%s' "$c100_clean" > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'INFO C100-fleet' && ! grepq "$out" -E '(OK  |WARN) C100'; then pass "C100 no fleet -> INFO"; else fail "C100 no fleet -> $(printf '%s' "$out" | head -3)"; fi

echo "== C100: a clean fleet -> OK =="
c100_fleet u/r "$c100_attempts"
out="$(c100_run)"
if grepq "$out" 'OK   C100-fleet' && ! grepq "$out" -E '(WARN|INFO) C100'; then pass "C100 clean fleet -> OK"; else fail "C100 clean fleet -> $(printf '%s' "$out" | head -3)"; fi

echo "== C100: each unknown attempt -> one WARN naming its id, worker, doc and the settle hint; the run is read-only ack =="
printf '%s' '{"managed":true,"unknown":[{"attempt_id":"a1","name":"W1","doc":"/h/W1.md","settle_hint":{"settleable":true,"text":"settleable now: type settle --attempt-id a1"}},{"attempt_id":"a2","name":"W2","doc":"/h/W2.md","settle_hint":{"settleable":false,"text":"not settleable now: a session may exist"}}],"legacy_unknown":[],"launched":[]}' > "$c100_t/answer.json"
out="$(C100_ARGS_OUT="$c100_t/args" c100_run)"
if [ "$(grep -c 'WARN C100-fleet' <<< "$out")" = 2 ] && grepq "$out" -F 'a1 (W1, /h/W1.md) is unknown: settleable now: type settle --attempt-id a1' \
    && grepq "$out" -F 'a2 (W2, /h/W2.md) is unknown: not settleable now: a session may exist'; then pass "C100 one WARN per unknown attempt with its hint"; else fail "C100 unknown -> $(printf '%s' "$out" | head -5)"; fi
if grep -qF -- 'ack --read-only --manifest' "$c100_t/args"; then pass "C100 asks ack --read-only, never the plain writing ack"; else fail "C100 ack args -> $(cat "$c100_t/args" 2>/dev/null)"; fi

echo "== C100: a legacy-unknown row and a launched attempt whose doc cannot be read -> WARN each =="
printf '%s' '{"managed":true,"unknown":[],"legacy_unknown":[{"doc":"/h/L1.md","label":"L1","phase":"legacy-unknown"}],"launched":[{"attempt_id":"a3","name":"W3","doc":"/no/such/doc.md"}]}' > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" -F '/h/L1.md' && grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'a3' && grepq "$out" -F '/no/such/doc.md' && ! grepq "$out" 'OK   C100'; then pass "C100 legacy row and unreadable launched doc -> WARN"; else fail "C100 legacy/unreadable -> $(printf '%s' "$out" | head -5)"; fi
printf '%s' '{"managed":true,"unknown":[],"legacy_unknown":[],"launched":[{"attempt_id":"a4","name":"W4","doc":"/h/nul\u0000doc.md"}]}' > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'a4' && ! grepq "$out" 'OK   C100'; then pass "C100 NUL byte in a launched doc path -> WARN"; else fail "C100 NUL doc -> $(printf '%s' "$out" | head -4)"; fi
if grepq "$out" -F 'fleet-manifest.sh attempt end' && grepq "$out" -F "$c100_t/root/u/r/chief.fleet.json --attempt-id a4 --reason"; then pass "C100 launched attempt with a damaged doc path -> hint prints the release command"; else fail "C100 release hint -> $(printf '%s' "$out" | head -6)"; fi
c100_doc="$c100_t/real-doc.md"; printf '# real\n' > "$c100_doc"
printf '{"managed":true,"unknown":[],"legacy_unknown":[],"launched":[{"attempt_id":"a5","name":"W5","doc":"%s"}]}' "$c100_doc" > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'OK   C100-fleet' && ! grepq "$out" -E 'WARN C100'; then pass "C100 control: a launched attempt with a readable doc -> OK"; else fail "C100 readable launched doc -> $(printf '%s' "$out" | head -4)"; fi
chmod 000 "$c100_doc"
out="$(c100_run)"
if [ "$(id -u)" = 0 ]; then pass "C100 unreadable launched doc -> skipped as root (chmod does not block root)"
elif grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'a5' && ! grepq "$out" 'OK   C100'; then pass "C100 launched doc that exists but cannot be read -> WARN"; else fail "C100 unreadable launched doc -> $(printf '%s' "$out" | head -4)"; fi
chmod 644 "$c100_doc"

echo "== C100: an ack that fails, times out, is not JSON or says unmanaged is a WARN, never OK =="
printf '%s' "$c100_clean" > "$c100_t/answer.json"
out="$(C100_RC=1 c100_run)"
if grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'cannot read fleet attempts for' && ! grepq "$out" 'OK   C100'; then pass "C100 ack exit 1 -> WARN"; else fail "C100 exit 1 -> $(printf '%s' "$out" | head -3)"; fi
start=$(date +%s)
out="$(C100_SLEEP=30 C100_TIMEOUT=1 c100_run)"
if grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'cannot read fleet attempts for' && [ $(( $(date +%s) - start )) -lt 15 ] && ! grepq "$out" 'OK   C100'; then pass "C100 ack past the deadline -> WARN within the bound"; else fail "C100 timeout -> $(printf '%s' "$out" | head -3)"; fi
printf '%s' '{"managed":false}' > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'WARN C100-fleet' && ! grepq "$out" 'OK   C100'; then pass "C100 managed false -> WARN"; else fail "C100 managed false -> $(printf '%s' "$out" | head -3)"; fi
printf '%s' 'Traceback (most recent call last)' > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'WARN C100-fleet' && ! grepq "$out" 'OK   C100'; then pass "C100 non-JSON -> WARN"; else fail "C100 non-JSON -> $(printf '%s' "$out" | head -3)"; fi
printf '%s' '{"managed":true,"unknown":"none","legacy_unknown":[],"launched":[]}' > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'WARN C100-fleet' && ! grepq "$out" 'OK   C100'; then pass "C100 unknown that is not a list -> WARN"; else fail "C100 unknown not a list -> $(printf '%s' "$out" | head -3)"; fi

echo "== C100: an anchor with attempts and no manifest to ask -> WARN; a fleet two levels deeper is not walked =="
rm -rf "$c100_t/root"
c100_fleet u/r '{"a1":{"attempt_id":"a1","manifest":"/no/such/manifest.fleet.json"}}'
rm -f "$c100_t/root/u/r/chief.fleet.json"
printf '%s' "$c100_clean" > "$c100_t/answer.json"
out="$(c100_run)"
if grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'manifest' && ! grepq "$out" 'OK   C100'; then pass "C100 no resolvable manifest -> WARN"; else fail "C100 no manifest -> $(printf '%s' "$out" | head -3)"; fi
rm -rf "$c100_t/root"
c100_fleet u/r/deeper "$c100_attempts"
out="$(c100_run)"
if grepq "$out" 'INFO C100-fleet' && ! grepq "$out" -E '(OK  |WARN) C100'; then pass "C100 only <root>/<user>/<repo> anchors are walked"; else fail "C100 depth -> $(printf '%s' "$out" | head -3)"; fi
rm -rf "$c100_t/root"
c100_fleet u/r "$c100_attempts"
echo "== C100: the real read-only ack on a fleet it cannot read is a WARN, never OK =="
out="$(HANDOVER_DIR="$c100_t/root" HIMMEL_DOCTOR_FLEET_TIMEOUT=20 bash "$DOC" --root "$REPO_ROOT" --no-color --only C100 2>&1)"
if grepq "$out" 'WARN C100-fleet' && grepq "$out" -F 'cannot read fleet attempts for' && ! grepq "$out" 'OK   C100'; then pass "C100 real runtime on a damaged fleet -> WARN"; else fail "C100 real runtime -> $(printf '%s' "$out" | head -4)"; fi
rm -rf "$c100_t"

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
