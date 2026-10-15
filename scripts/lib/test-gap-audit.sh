#!/usr/bin/env bash
# test-gap-audit.sh — hermetic cases for scripts/lib/gap-audit.sh:
# the read-only gap-audit offer that himmel-update prints at the end of a run.
# Every check is driven through an env seam (doctor json, qmd status text,
# graphify-out dir, Jira mirror, RESUME detector, clock) — no real qmd, Jira,
# doctor or network. Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/gap-audit.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" "$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1 (unexpected '$3')" "$2" ;; *) ok "$1" ;; esac; }

[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gap-audit.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
NOW=1760000000
DAY=86400

# --- green fixtures ---------------------------------------------------------
mkdir -p "$TMP/repo" "$TMP/go" "$TMP/mirror"
git -C "$TMP/repo" init -q 2>/dev/null
printf '# fine\n' > "$TMP/repo/a.sh"
git -C "$TMP/repo" add a.sh
printf '{"sev":"OK","id":"C50-qmd-fork-stamp","msg":"all pin","remedy":""}\n' > "$TMP/doctor-green.json"
cat > "$TMP/doctor-green.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/doctor-green.json"
EOF
printf 'Pending:  0 need embedding\n  luna (qmd://luna/)\n    Files:    9 (updated 5m ago)\n' > "$TMP/qmd-green.txt"
printf '{}' > "$TMP/go/graph.json"
printf '{}' > "$TMP/go/semantic-manifest.json"
touch -d "@$((NOW - 2 * DAY))" "$TMP/go/semantic-manifest.json"

run() { # run <extra env assignments...> ; prints gap_audit_offer
    env GAP_AUDIT_ROOT="$TMP/repo" GAP_AUDIT_NOW="$NOW" \
        GAP_AUDIT_DOCTOR_CMD="bash $TMP/doctor-green.sh" \
        GAP_AUDIT_QMD_STATUS_FILE="$TMP/qmd-green.txt" \
        GAP_AUDIT_GRAPH_OUT="$TMP/go" \
        GAP_AUDIT_MIRROR="$TMP/mirror" \
        GAP_AUDIT_RESUME_CMD="" JIRA_PROJECT_KEY="" \
        "$@" bash -c ". \"$LIB\"; gap_audit_offer" 2>&1
}

out="$(run)"
has "green: reports all clear" "$out" "all clear"
lacks "green: no audit offer" "$out" "Run the full audit"

# --- non-green: doctor WARN rows (qmd pin, graph stale) --------------------
printf '%s\n' \
  '{"sev":"WARN","id":"C50-qmd-fork-stamp","msg":"qmd fork stale build","remedy":"re-run himmel-update"}' \
  '{"sev":"OK","id":"C56-qmd-orphans","msg":"none","remedy":""}' \
  '{"sev":"WARN","id":"C33-graph-stale","msg":"graph stale: 40 commits behind","remedy":"bash scripts/graphify/ast-update.sh"}' > "$TMP/doctor-red.json"
sed "s#doctor-green.json#doctor-red.json#" "$TMP/doctor-green.sh" > "$TMP/doctor-red.sh"
out="$(run GAP_AUDIT_DOCTOR_CMD="bash $TMP/doctor-red.sh")"
has "doctor WARN qmd row surfaced" "$out" "C50-qmd-fork-stamp"
has "doctor WARN graph row surfaced" "$out" "C33-graph-stale"
has "doctor remedy printed" "$out" "re-run himmel-update"
lacks "doctor OK row not listed" "$out" "C56-qmd-orphans"
has "offer printed" "$out" "Run the full audit"
lacks "non-green is not all clear" "$out" "all clear"

# --- qmd: needsEmbedding backlog + stale collection -------------------------
printf 'Pending:  2454 need embedding (run qmd embed)\n  luna (qmd://luna/)\n    Files:    9 (updated 4d ago)\n  himmel (qmd://himmel/)\n    Files:    9 (updated 29m ago)\n' > "$TMP/qmd-red.txt"
out="$(run GAP_AUDIT_QMD_STATUS_FILE="$TMP/qmd-red.txt")"
has "qmd embed backlog" "$out" "2454"
has "qmd stale collection named" "$out" "luna"
lacks "qmd fresh collection not named" "$out" "himmel (qmd"

# --- graphify: semantic manifest missing / old ------------------------------
rm -f "$TMP/go/semantic-manifest.json"
out="$(run)"
has "no semantic manifest flagged" "$out" "semantic manifest"
printf '{}' > "$TMP/go/semantic-manifest.json"
touch -d "@$((NOW - 40 * DAY))" "$TMP/go/semantic-manifest.json"
out="$(run)"
has "old semantic manifest flagged" "$out" "40d"
mkdir -p "$TMP/nogo"
out="$(run GAP_AUDIT_GRAPH_OUT="$TMP/nogo")"
lacks "no graph at all: graphify check skipped" "$out" "semantic manifest"
touch -d "@$((NOW - 2 * DAY))" "$TMP/go/semantic-manifest.json"

# --- orphaned in-work tickets: RESUME detector ------------------------------
cat > "$TMP/resume.sh" <<'EOF'
#!/usr/bin/env bash
printf '# next-dispatchable: 1 RESUME\n'
printf 'RESUME\tHIMMEL-4242\tHigh\t-\tdropped work\tfiles=-\tstatus=In Progress\tlast=2d\n'
EOF
out="$(run GAP_AUDIT_RESUME_CMD="bash $TMP/resume.sh" JIRA_PROJECT_KEY=HIMMEL)"
has "orphaned ticket surfaced" "$out" "HIMMEL-4242"
out="$(run GAP_AUDIT_RESUME_CMD="bash $TMP/resume.sh" JIRA_PROJECT_KEY=)"
lacks "Jira not configured: orphan check skipped" "$out" "HIMMEL-4242"
has "Jira not configured: reported as not checked" "$out" "not checked: in-work tickets"
lacks "skipped check is not a bare all clear" "$out" "all clear"
out="$(run GAP_AUDIT_RESUME_CMD="bash $TMP/nonexistent.sh" JIRA_PROJECT_KEY=HIMMEL)"
has "detector absent: skipped cleanly" "$out" "all clear"

# --- ponytail markers whose named ticket is already Done --------------------
printf '# ponytail: first pass only, upgrade: HIMMEL-7001 adds the rest\n' > "$TMP/repo/b.sh"
printf '# ponytail: other, upgrade: HIMMEL-7002\n' > "$TMP/repo/c.sh"
git -C "$TMP/repo" add b.sh c.sh
printf -- '---\nkey: "HIMMEL-7001"\nstatus: "Done"\n---\n' > "$TMP/mirror/HIMMEL-7001.md"
printf -- '---\nkey: "HIMMEL-7002"\nstatus: "To Do"\n---\n' > "$TMP/mirror/HIMMEL-7002.md"
out="$(run)"
has "ponytail with Done ticket flagged" "$out" "b.sh"
lacks "ponytail with open ticket not flagged" "$out" "c.sh"

# --- default doctor command survives a checkout path with spaces -------------
mkdir -p "$TMP/sp ace/scripts"
printf '#!/usr/bin/env bash\nprintf '"'"'{"sev":"WARN","id":"C40-spaced","msg":"ran from spaced path","remedy":"x"}\\n'"'"'\n' > "$TMP/sp ace/scripts/himmel-doctor.sh"
out="$(env GAP_AUDIT_ROOT="$TMP/sp ace" GAP_AUDIT_NOW="$NOW" GAP_AUDIT_QMD_STATUS_FILE="$TMP/qmd-green.txt" \
    GAP_AUDIT_GRAPH_OUT="$TMP/nogo" GAP_AUDIT_MIRROR="$TMP/mirror" GAP_AUDIT_RESUME_CMD="" \
    bash -c ". \"$LIB\"; gap_audit_offer" 2>&1)"
has "default doctor runs from a path with spaces" "$out" "C40-spaced"

# --- read-only + never fatal ------------------------------------------------
out="$(run GAP_AUDIT_DOCTOR_CMD="bash $TMP/missing.sh")"
has "broken doctor never aborts the offer" "$out" "gap audit"

# --- wiring: himmel-update.sh ends both exit paths with the offer ------------
UPD="$HERE/../himmel-update.sh"
n_calls="$(grep -c '^ *gap_audit_offer_safe$' "$UPD")"
if [ "$n_calls" = 2 ]; then ok "himmel-update.sh calls the offer on the failure and success paths"; else bad "himmel-update.sh offer call count is $n_calls, want 2"; fi
if grep -q 'scripts/lib/gap-audit.sh' "$UPD"; then ok "himmel-update.sh sources the lib"; else bad "himmel-update.sh does not source the lib"; fi

echo "gap-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
