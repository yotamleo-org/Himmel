#!/usr/bin/env bash
# scripts/upstreams/test-protect-forks.sh — hermetic suite for protect-forks.sh
# A stub `gh` under a temp dir answers from fixtures and logs
# every call; the live API and the real HOME are never touched. The repo
# fixtures for qmd and himmel-voice are the real `gh api repos/<nwo>` answers
# of 2026-11-05 trimmed to the fields the script reads.
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROTECT="$SCRIPT_DIR/protect-forks.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 — '$2' not in: $1" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 — '$2' found in: $1" ;; *) pass "$3" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-protect-forks.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix"
LOG="$T/gh.log"

# The stub: logs "<METHOD> <endpoint>", answers a GET from fix/<endpoint with
# / ? & = turned into _>.json, answers any write with {"id":999}.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = api ] || { echo "stub gh: unexpected $*" >&2; exit 9; }
shift
method=GET; ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --input) cat >/dev/null; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) ep="$1"; shift ;;
  esac
done
echo "$method $ep" >> "$STUB_LOG"
if [ "$method" != GET ]; then echo '{"id":999}'; exit 0; fi
f="$STUB_FIX/$(printf '%s' "$ep" | tr '/?&=' '____').json"
if [ -f "$f" ]; then cat "$f"; else echo '{"message":"Not Found"}' >&2; exit 1; fi
STUB
chmod +x "$T/bin/gh"

cat > "$T/adapters.json" <<'EOF'
[
  {"nwo": "yotamleo-org/qmd", "upstream": "tobi/qmd", "himmel_branch": "main", "role": "runtime-dependency", "merge_allowed": true},
  {"nwo": "yotamleo-org/graphify", "upstream": "Graphify-Labs/graphify", "himmel_branch": "himmel-main", "role": "runtime-dependency", "merge_allowed": true},
  {"nwo": "yotamleo-org/core", "upstream": "home-assistant/core", "himmel_branch": "dev", "role": "upstream-contribution", "merge_allowed": false},
  {"nwo": "yotamleo-org/himmel-voice", "upstream": null, "himmel_branch": "main", "role": "first-party", "merge_allowed": true}
]
EOF
F="$T/fix"
echo '{"archived":false,"default_branch":"main","fork":true,"full_name":"yotamleo-org/qmd","parent":{"full_name":"tobi/qmd"},"pull_request_creation_policy":"all"}' > "$F/repos_yotamleo-org_qmd.json"
echo '{"archived":false,"default_branch":"v8","fork":true,"full_name":"yotamleo-org/graphify","parent":{"full_name":"Graphify-Labs/graphify"},"pull_request_creation_policy":"all"}' > "$F/repos_yotamleo-org_graphify.json"
echo '{"archived":true,"default_branch":"dev","fork":true,"full_name":"yotamleo-org/core","parent":{"full_name":"home-assistant/core"},"pull_request_creation_policy":"all"}' > "$F/repos_yotamleo-org_core.json"
echo '{"archived":false,"default_branch":"main","fork":false,"full_name":"yotamleo-org/himmel-voice","pull_request_creation_policy":"all"}' > "$F/repos_yotamleo-org_himmel-voice.json"
echo '[]' > "$F/repos_yotamleo-org_qmd_rulesets.json"
echo '[]' > "$F/repos_yotamleo-org_graphify_rulesets.json"
printf '%s\n' yotamleo-org/qmd yotamleo-org/graphify yotamleo-org/core > "$T/orgforks.txt"
echo '[{"full_name":"yotamleo-org/qmd"},{"full_name":"yotamleo-org/graphify"},{"full_name":"yotamleo-org/core"}]' > "$F/orgs_yotamleo-org_repos_type_forks_per_page_100.json"

run() { # run <extra env...> -- args : prints output, sets RC
  : > "$LOG"
  OUT=$(env -u HIMMEL_FORK_PROTECT_RULING STUB_LOG="$LOG" STUB_FIX="$F" GH="$T/bin/gh" PROTECT_FORKS_ORG=yotamleo-org PROTECT_FORKS_ADAPTERS="$T/adapters.json" "$@" 2>&1); RC=$?
}

echo "--- dry-run (default mode)"
run bash "$PROTECT"
if [ "$RC" -eq 0 ]; then pass "dry-run rc=0"; else fail "dry-run rc=$RC: $OUT"; fi
has "$OUT" "CALL POST repos/yotamleo-org/qmd/rulesets " "qmd: ruleset create call printed"
has "$OUT" '"include":["refs/heads/main"]' "qmd: default and himmel branch are the same ref, listed once"
has "$OUT" '"include":["refs/heads/v8","refs/heads/himmel-main"]' "graphify: default v8 and himmel-main both protected"
has "$OUT" '"bypass_mode":"always"' "admin bypass always (the sync actor)"
has "$OUT" '"required_approving_review_count":0' "pull request required with 0 approvals (ruling)"
has "$OUT" "CALL PATCH repos/yotamleo-org/qmd " "PR-creation policy call printed"
has "$OUT" '"pull_request_creation_policy":"collaborators_only"' "policy payload is collaborators_only"
has "$OUT" "READBACK GET repos/yotamleo-org/qmd/rulesets" "read-back printed"
has "$OUT" "SKIP yotamleo-org/core archived" "archived fork skipped"
has "$OUT" "SKIP yotamleo-org/himmel-voice not-a-fork" "first-party repo skipped"
writes=$(grep -vc '^GET ' "$LOG" || true)
if [ "$writes" = 0 ]; then pass "negative control: the stub saw only GETs"; else fail "stub saw $writes non-GET calls: $(cat "$LOG")"; fi

has "$OUT" "READBACK GET repos/yotamleo-org/graphify/rules/branches/himmel-main" "per-branch rules read-back printed"

echo "--- --only limits the run to one fork"
run bash "$PROTECT" --only yotamleo-org/graphify
has "$OUT" "CALL POST repos/yotamleo-org/graphify/rulesets " "--only: graphify planned"
hasnt "$OUT" "yotamleo-org/qmd" "--only: qmd not touched"
hasnt "$OUT" "UNREGISTERED" "--only: no org sweep"

echo "--- --apply without the ruling proof"
run bash "$PROTECT" --apply
if [ "$RC" -eq 3 ]; then pass "--apply refused rc=3"; else fail "--apply without proof rc=$RC: $OUT"; fi
if [ ! -s "$LOG" ]; then pass "refusal made no gh call at all"; else fail "refusal still called gh: $(cat "$LOG")"; fi
run env HIMMEL_FORK_PROTECT_RULING=x bash "$PROTECT" --apply
if [ "$RC" -eq 3 ]; then pass "a malformed proof (too short) is refused"; else fail "short proof rc=$RC"; fi

echo "--- --apply with a ruling writes, a re-run on the protected state is a no-op"
run env HIMMEL_FORK_PROTECT_RULING=RN-test-ruling bash "$PROTECT" --apply
# the stub keeps no state, so the post-write verification must NOT pass (rc 1): proves the verify step reads back
if [ "$RC" -eq 1 ]; then has "$OUT" "ERROR yotamleo-org/qmd read-back does not match" "--apply verifies by read-back (stub kept no state, so it fails)"; else fail "--apply rc=$RC: $OUT"; fi
has "$(cat "$LOG")" "POST repos/yotamleo-org/qmd/rulesets" "apply issued the POST"
has "$(cat "$LOG")" "PATCH repos/yotamleo-org/qmd" "apply issued the PATCH"
# turn the dry-run's own payload into the "already protected" fixture
run bash "$PROTECT"
payload=$(printf '%s\n' "$OUT" | grep '^CALL POST repos/yotamleo-org/qmd/rulesets ' | sed 's/^CALL POST [^ ]* //')
printf '[{"id":777,"name":"himmel-fork-protect"}]\n' > "$F/repos_yotamleo-org_qmd_rulesets.json"
printf '%s' "$payload" | jq '. + {id:777, source_type:"Repository", current_user_can_bypass:"always"}' > "$F/repos_yotamleo-org_qmd_rulesets_777.json"
echo '{"archived":false,"default_branch":"main","fork":true,"full_name":"yotamleo-org/qmd","parent":{"full_name":"tobi/qmd"},"pull_request_creation_policy":"collaborators_only"}' > "$F/repos_yotamleo-org_qmd.json"
run env HIMMEL_FORK_PROTECT_RULING=RN-test-ruling bash "$PROTECT" --apply
has "$OUT" "OK yotamleo-org/qmd already protected" "re-run: qmd reported already protected"
hasnt "$OUT" "CALL POST repos/yotamleo-org/qmd" "re-run: no qmd create call"
hasnt "$OUT" "CALL PUT repos/yotamleo-org/qmd" "re-run: no qmd update call"
hasnt "$OUT" "CALL PATCH repos/yotamleo-org/qmd" "re-run: no qmd policy call"
qw=$(grep -c -E '^(POST|PUT|PATCH) repos/yotamleo-org/qmd' "$LOG" || true)
if [ "$qw" = 0 ]; then pass "re-run: stub saw no write to qmd"; else fail "re-run wrote $qw time(s) to qmd"; fi

echo "--- a drifted ruleset is updated with PUT"
printf '%s' "$payload" | jq '. + {id:777} | (.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count) = 1' > "$F/repos_yotamleo-org_qmd_rulesets_777.json"
run bash "$PROTECT"
has "$OUT" "CALL PUT repos/yotamleo-org/qmd/rulesets/777 " "drift: PUT to the existing ruleset id"

echo "--- a ref that only contains ours as a substring is not the same ruleset"
printf '%s' "$payload" | jq '. + {id:777} | .conditions.ref_name.include = ["refs/heads/main-old"]' > "$F/repos_yotamleo-org_qmd_rulesets_777.json"
run bash "$PROTECT" --only yotamleo-org/qmd
has "$OUT" "CALL PUT repos/yotamleo-org/qmd/rulesets/777 " "substring ref: PUT, not already protected"
printf '%s' "$payload" | jq '. + {id:777}' > "$F/repos_yotamleo-org_qmd_rulesets_777.json"
run bash "$PROTECT" --only yotamleo-org/qmd
has "$OUT" "OK yotamleo-org/qmd already protected" "exact ref: already protected"

echo "--- registry and --only errors fail loudly"
echo '{"not":"an array"}' > "$T/bad.json"
run env PROTECT_FORKS_ADAPTERS="$T/bad.json" bash "$PROTECT"
if [ "$RC" -eq 2 ]; then pass "a registry that is not an array exits 2"; else fail "bad registry rc=$RC: $OUT"; fi
run bash "$PROTECT" --only yotamleo-org/nope
if [ "$RC" -eq 1 ]; then has "$OUT" "matches no registry row" "--only with no match exits 1 and says so"; else fail "--only nomatch rc=$RC: $OUT"; fi

echo "--- an org fork missing from the registry is reported"
echo '[{"full_name":"yotamleo-org/qmd"},{"full_name":"yotamleo-org/stray"}]' > "$F/orgs_yotamleo-org_repos_type_forks_per_page_100.json"
run bash "$PROTECT"
has "$OUT" "UNREGISTERED yotamleo-org/stray" "unregistered org fork named"

if [ "$fails" -eq 0 ]; then echo "test-protect-forks: all passed"; exit 0; fi
echo "test-protect-forks: $fails failed"; exit 1
