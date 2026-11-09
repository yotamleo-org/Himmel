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
touch_at() { TZ=UTC touch -t "$(TZ=UTC date -d "@$2" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC date -r "$2" +%Y%m%d%H%M.%S)" "$1"; }  # GNU date -d @N, BSD date -r N

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
touch_at "$TMP/go/semantic-manifest.json" "$((NOW - 2 * DAY))"

LEDGER="$TMP/no-ledger.tsv"
run() { # run <extra env assignments...> ; prints gap_audit_offer
    env GAP_AUDIT_ROOT="$TMP/repo" GAP_AUDIT_NOW="$NOW" HIMMEL_CEILINGS_LEDGER="$LEDGER" \
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
touch_at "$TMP/go/semantic-manifest.json" "$((NOW - 40 * DAY))"
out="$(run)"
has "old semantic manifest flagged" "$out" "40d"
mkdir -p "$TMP/nogo"
out="$(run GAP_AUDIT_GRAPH_OUT="$TMP/nogo")"
lacks "no graph at all: graphify check skipped" "$out" "semantic manifest"
touch_at "$TMP/go/semantic-manifest.json" "$((NOW - 2 * DAY))"

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
has "detector failing: reported as not checked" "$out" "not checked: in-work tickets (detector failed)"
lacks "detector failing is not a bare all clear" "$out" "all clear"

# --- ceilings ledger rows: Done ticket, missing file, stale anchor ----------
case "$LEDGER" in "$TMP"/*) ok "the ledger override points inside the work dir" ;; *) bad "the ledger override is outside the work dir: $LEDGER" ;; esac
out="$(run)"
lacks "no ledger: the ceilings check is silent" "$out" "· ceilings:"
mkdir -p "$TMP/repo/scripts/ledger"
cp "$HERE/../ledger/ceiling-lookup.sh" "$HERE/../ledger/ledger-lib.sh" "$TMP/repo/scripts/ledger/"
out="$(run)"
lacks "the lookup with no ledger file: silent" "$out" "· ceilings:"
has "the lookup with no ledger file: still all clear" "$out" "all clear"
printf 'fn_b() { :; }\n' > "$TMP/repo/b.sh"
printf 'fn_c() { :; }\n' > "$TMP/repo/c.sh"
git -C "$TMP/repo" add b.sh c.sh
printf -- '---\nkey: "HIMMEL-7001"\nstatus: "Done"\n---\n' > "$TMP/mirror/HIMMEL-7001.md"
printf -- '---\nkey: "HIMMEL-7002"\nstatus: "To Do"\n---\n' > "$TMP/mirror/HIMMEL-7002.md"
{
    printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote\n'
    printf 'C-0001\tb.sh\tfn_b\tSECRET-CEILING-ONE\tlater\tHIMMEL-7001\topen\t2026-11-09\t\t\n'
    printf 'C-0002\tc.sh\tfn_c\tSECRET-CEILING-TWO\tlater\tHIMMEL-7002\topen\t2026-11-09\t\t\n'
    printf 'C-0003\tgone.sh\tfn_gone\tSECRET-CEILING-THREE\tlater\t\topen\t2026-11-09\t\t\n'
    printf 'C-0004\tc.sh\tfn_renamed\tSECRET-CEILING-FOUR\tlater\t\topen\t2026-11-09\t\t\n'
    printf 'C-0005\tb.sh\tfn_b\tSECRET-CEILING-FIVE\tlater\tHIMMEL-7001\tlifted\t2026-11-09\t\tfixed\n'
} > "$TMP/ledger.tsv"
out="$(run HIMMEL_CEILINGS_LEDGER="$TMP/ledger.tsv")"
has "ceilings: an open row whose ticket is Done is flagged" "$out" "C-0001 b.sh [fn_b]"
lacks "ceilings: an open row whose ticket is open is not flagged" "$out" "C-0002"
has "ceilings: an open row whose file is gone is flagged" "$out" "C-0003 gone.sh [fn_gone]"
has "ceilings: an open row whose anchor is gone is flagged" "$out" "C-0004 c.sh [fn_renamed]"
lacks "ceilings: a lifted row is not flagged" "$out" "C-0005"
lacks "ceilings: no ceiling text is printed" "$out" "SECRET-CEILING"
has "ceilings: the finding key is ceilings" "$out" "· ceilings:"
out="$(run HIMMEL_CEILINGS_LEDGER="$TMP/ledger.tsv" GAP_AUDIT_MIRROR="$TMP/no-mirror")"
lacks "ceilings: no mirror skips only the Done check" "$out" "C-0001"
has "ceilings: no mirror still flags a missing file" "$out" "C-0003"
rm -rf "$TMP/repo/scripts" "$TMP/repo/b.sh" "$TMP/repo/c.sh"
git -C "$TMP/repo" rm -q --cached b.sh c.sh

# --- default doctor command survives a checkout path with spaces -------------
mkdir -p "$TMP/sp ace/scripts"
printf '#!/usr/bin/env bash\nprintf '"'"'{"sev":"WARN","id":"C40-spaced","msg":"ran from spaced path","remedy":"x"}\\n'"'"'\n' > "$TMP/sp ace/scripts/himmel-doctor.sh"
out="$(env GAP_AUDIT_ROOT="$TMP/sp ace" GAP_AUDIT_NOW="$NOW" GAP_AUDIT_QMD_STATUS_FILE="$TMP/qmd-green.txt" HIMMEL_CEILINGS_LEDGER="$LEDGER" \
    GAP_AUDIT_GRAPH_OUT="$TMP/nogo" GAP_AUDIT_MIRROR="$TMP/mirror" GAP_AUDIT_RESUME_CMD="" \
    bash -c ". \"$LIB\"; gap_audit_offer" 2>&1)"
has "default doctor runs from a path with spaces" "$out" "C40-spaced"

# --- read-only + never fatal ------------------------------------------------
out="$(run GAP_AUDIT_DOCTOR_CMD="bash $TMP/missing.sh")"
has "broken doctor never aborts the offer" "$out" "gap audit"
has "doctor with no output: reported as not checked" "$out" "not checked: doctor rows"
lacks "doctor with no output is not a bare all clear" "$out" "all clear"
printf '#!/usr/bin/env bash\ncat "%s"\nexit 1\n' "$TMP/doctor-red.json" > "$TMP/doctor-rc1.sh"
out="$(run GAP_AUDIT_DOCTOR_CMD="bash $TMP/doctor-rc1.sh")"
has "doctor exiting non-zero still has its WARN rows shown" "$out" "C50-qmd-fork-stamp"
printf '#!/usr/bin/env bash\nprintf "not json\\n"\n' > "$TMP/doctor-bad.sh"
out="$(run GAP_AUDIT_DOCTOR_CMD="bash $TMP/doctor-bad.sh")"
has "malformed doctor json: reported as not checked" "$out" "not checked: doctor rows (unreadable output)"
lacks "malformed doctor json is not a bare all clear" "$out" "all clear"

# --- wiring: himmel-update.sh ends both exit paths with the offer ------------
UPD="$HERE/../himmel-update.sh"
n_calls="$(grep -c '^ *gap_audit_offer_safe$' "$UPD")"
if [ "$n_calls" = 2 ]; then ok "himmel-update.sh calls the offer on the failure and success paths"; else bad "himmel-update.sh offer call count is $n_calls, want 2"; fi
if grep -q 'scripts/lib/gap-audit.sh' "$UPD"; then ok "himmel-update.sh sources the lib"; else bad "himmel-update.sh does not source the lib"; fi

echo "gap-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
