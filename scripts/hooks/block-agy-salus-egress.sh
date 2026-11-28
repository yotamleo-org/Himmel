#!/usr/bin/env bash
# PreToolUse gate for Antigravity (agy) sessions: the network egress floor in a salus (patient-data) vault.
# A security fence: it fails closed, and a scope it cannot decide counts as salus.
#
# No bypass variable, unlike the single-run bypass scripts/hooks/CLAUDE.md asks of a deny: egress-matrix.json
# rules salus x * x * a hard deny ("No override exists"), and the adapter unsets every *_OK name anyway.
#
# Exit: 0 allow, 2 refuse (reason on stderr).
set -u
# shellcheck disable=SC2154  # rc is assigned by rc=$? inside the same trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)" || exit 2 ;;
    *) SCRIPT_DIR="$(pwd -P)" || exit 2 ;;
esac

refuse() {
    printf "block-agy-salus-egress: '%s' refused: this Antigravity session is in a salus (patient-data) vault (%s), and egress-matrix.json rules salus x * x * a hard deny for anything but inference. No bypass exists.\n" "$1" "$2" >&2
    exit 2
}

input=""
IFS= read -r -d '' input || true # swallow-ok: read -d '' returns 1 at end of input after reading all of it; an empty payload fails the jq read below

# shellcheck disable=SC2016
meta="$(printf '%s' "$input" | jq -r '
    def str: if type == "string" then . else "" end;
    (if has("workspace_paths") then .workspace_paths else [] end) as $ws
    | ($ws | type == "array" and all(.[]; type == "string")) as $ws_ok
    | @sh "TOOL=\(.tool_name | str) CMD=\(.tool_input | if type == "object" then .command else null end | str) CWD=\(.cwd | str) CWD_VALID=\(if (.cwd | type) == "string" then 1 else 0 end) WS_VALID=\(if $ws_ok then 1 else 0 end) WS_N=\(if ($ws | type) == "array" then ($ws | length) else 0 end)",
      "WS=(\(if $ws_ok then ($ws | @sh) else "" end))"
' 2>/dev/null)" || {
    printf 'block-agy-salus-egress: unparseable hook payload — refused fail-closed\n' >&2
    exit 2
}
TOOL="" CMD="" CWD="" CWD_VALID=0 WS_VALID=0 WS_N=0
WS=()
eval "$meta"

if [ "$TOOL" = "Bash" ]; then
    case "$CMD" in
        *"git push"*|*"git remote add"*|*"git remote set-url"*|*"curl "*|*"curl.exe"*|*"wget "*|*"Invoke-WebRequest"*|*"Invoke-RestMethod"*|*"scp "*|*"rclone "*) CLASS="network/push command" ;;
        *) exit 0 ;;
    esac
else
    CLASS="${TOOL:-unnamed tool}"
fi

[ "$CWD_VALID" = 1 ] || refuse "$CLASS" "scope undecidable: cwd is missing or not a string, counted as salus"
case "$CWD" in
    /*) ;;
    *) refuse "$CLASS" "scope undecidable: cwd '$CWD' is empty or relative, counted as salus" ;;
esac
[ "$WS_VALID" = 1 ] || refuse "$CLASS" "scope undecidable: workspace_paths is not an array of strings, counted as salus"
[ "$WS_N" -le 8 ] || refuse "$CLASS" "scope undecidable: $WS_N workspace paths, more than 8, counted as salus"
for w in ${WS[@]+"${WS[@]}"}; do
    case "$w" in
        /*) ;;
        *) refuse "$CLASS" "scope undecidable: workspace path '$w' is empty or relative, counted as salus" ;;
    esac
done

python3 -I "$SCRIPT_DIR/../handover/chief-kit/salus_marked.py" salus "$CWD" ${WS[@]+"${WS[@]}"} </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" -eq 10 ] && exit 0
where="$CWD"
[ "$WS_N" -gt 0 ] && where="$CWD, or one of its $WS_N workspace paths"
[ "$rc" -eq 0 ] || where="$where; the salus classifier failed (rc=$rc), counted as salus"
refuse "$CLASS" "$where"
