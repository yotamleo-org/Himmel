#!/usr/bin/env bash
# scripts/handover/console-kit/test-station-sync.sh - suite for station-sync.sh,
# the post-merge step that brings the station back to main. Hermetic:
# himmel-update.sh, the template upgrader and the qmd clone are stubs (the
# SS_UPDATE / SS_UPGRADE / SS_QMD_CLONE seams); nothing here runs a real update.
#
# Cases:
#   1. usage: no source / both sources                        -> rc 2
#   2. a merged diff touching marketplace/                    -> --only marketplace, nothing else
#   3. jira / qmd pin / graphify pin / unrelated paths        -> the mapped steps only; --versions always
#   4. a behind row                                           -> STATION=BEHIND:<components> + state file
#   5. non-comment local template hunk                        -> luna_template NOT applied, hunk named
#   6. comment-only local template hunk                       -> luna_template applied
#   7. withheld edit with no diff (snapshot baseline)         -> refused, fail-closed
#   8. tracked edit in the qmd fork clone                     -> reported, never discarded
#
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/station-sync.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/ss-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

cat > "$W/update" <<'EOF2'
#!/usr/bin/env bash
echo "update $*" >> "$SS_CALLS"
if [ "$1" = "--versions" ]; then cat "$SS_T_VERSIONS"; grep -qw behind "$SS_T_VERSIONS" && exit 1; exit 0; fi
exit 0
EOF2
cat > "$W/upgrade" <<'EOF2'
#!/usr/bin/env bash
cat "$SS_T_DRYRUN"
EOF2
chmod +x "$W/update" "$W/upgrade"
cat > "$W/ver-current" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    luna_template  current  v0.4.73     v0.4.73
    0 behind, 0 undetermined.
EOF2
cat > "$W/ver-behind" <<'EOF2'
==> himmel ecosystem versions
    component      state    installed   available   note
    himmel         current  v1          v1
    luna_template  behind   v0.4.71     v0.4.73
    codex          behind   0.162.1     0.163.0     run /himmel-update to upgrade
    2 behind, 0 undetermined.
EOF2
: > "$W/dry-clean"
mkdir -p "$W/vault"
export SS_UPDATE="$W/update" SS_UPGRADE="$W/upgrade" SS_CALLS="$W/calls" SS_STATE="$W/state" \
       SS_PRIMARY="$W" SS_VAULT="$W/vault" SS_QMD_CLONE="$W/no-such-clone" SS_T_DRYRUN="$W/dry-clean"
run() {  # run <versions file> <path>...
    : > "$SS_CALLS"; rm -f "$SS_STATE"
    export SS_T_VERSIONS="$1"; shift
    printf '%s\n' "$@" > "$W/files"
    out="$(bash "$SCRIPT" --files "$W/files" 2>&1)"; rc=$?; calls="$(cat "$SS_CALLS" 2>/dev/null)"
}

bash "$SCRIPT" >/dev/null 2>&1; check "1 no source rc" "$?" 2
bash "$SCRIPT" --files "$W/x" --pr 5 >/dev/null 2>&1; check "1 two sources rc" "$?" 2

run "$W/ver-current" marketplace/plugins/foo/skill.md
check "2 rc" "$rc" 0
contains "2 marketplace step" "$calls" "update --only marketplace"
lacks "2 no jira step" "$calls" "--only jira_cli"
contains "2 versions run" "$calls" "update --versions"
contains "2 station ok" "$out" "STATION=OK"

run "$W/ver-current" scripts/jira/src/a.ts scripts/lib/qmd-bin.sh scripts/lib/graphify-bin.sh docs/x.md
contains "3 jira" "$calls" "update --only jira_cli"
contains "3 qmd" "$calls" "update --only qmd_fork"
contains "3 graphify" "$calls" "update --only graphify"
lacks "3 no marketplace" "$calls" "--only marketplace"
run "$W/ver-current" docs/x.md
lacks "3 docs only runs no step" "$calls" "--only"
contains "3 docs only still checks versions" "$calls" "update --versions"

run "$W/ver-behind" docs/x.md
check "4 rc" "$rc" 0
contains "4 behind" "$out" "STATION=BEHIND:luna_template,codex"
check "4 state file" "$(cat "$SS_STATE")" "BEHIND:luna_template,codex"
run "$W/ver-current" docs/x.md
check "4 state cleared" "$(cat "$SS_STATE")" "ok"

cat > "$W/dry-code" <<'EOF2'
  local edits withheld (not overwritten): scripts/foo.sh (backup: none) [baseline: git]
    --- a/foo
    +++ b/foo
    -# old comment
    +echo local-patch
EOF2
SS_T_DRYRUN="$W/dry-code" run "$W/ver-behind" templates/luna-second-brain/scripts/foo.sh
lacks "5 template not applied" "$calls" "--only luna_template"
contains "5 names the file" "$out" "LOCAL-DIFF luna_template scripts/foo.sh"
contains "5 names the hunk" "$out" "echo local-patch"
contains "5 reported behind" "$out" "BEHIND:luna_template"

cat > "$W/dry-comment" <<'EOF2'
  local edits withheld (not overwritten): scripts/foo.sh (backup: none) [baseline: git]
    --- a/foo
    +++ b/foo
    -# old comment
    +# new comment
EOF2
SS_T_DRYRUN="$W/dry-comment" run "$W/ver-current" templates/luna-second-brain/scripts/foo.sh
contains "6 template applied" "$calls" "update --only luna_template"
lacks "6 no local diff" "$out" "LOCAL-DIFF"

cat > "$W/dry-snap" <<'EOF2'
  local edits withheld (not overwritten): .obsidian/app.json (backup: none) [baseline: snapshot]
    recorded at the last upgrade: sha256:abc
EOF2
SS_T_DRYRUN="$W/dry-snap" run "$W/ver-behind" templates/luna-second-brain/.obsidian/app.json
lacks "7 snapshot edit not applied" "$calls" "--only luna_template"
contains "7 names the file" "$out" "LOCAL-DIFF luna_template .obsidian/app.json"

git init -q "$W/clone" && echo a > "$W/clone/f" && git -C "$W/clone" add f \
    && git -C "$W/clone" -c user.name=t -c user.email=t@t commit -qm init && echo b > "$W/clone/f"
SS_QMD_CLONE="$W/clone" run "$W/ver-current" docs/x.md
contains "8 clone edit reported" "$out" "LOCAL-DIFF qmd_fork f"
check "8 edit kept" "$(cat "$W/clone/f")" "b"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
