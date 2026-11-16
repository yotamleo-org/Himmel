#!/usr/bin/env bash
# Real writer/reader consumers in scratch buckets; policy is read only.
# shellcheck disable=SC2016  # Generated fixture scripts expand variables when executed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../handover/chief-kit/fleet-manifest.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-control-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2] != [$3]"; fails=$((fails+1)); fi; }
run() { bash "$SCRIPT" "$@"; }
show() { run control show "$1"; }
mode() { show "$1" | jq -r '[.state,.mode] | join(":")'; }
refuse() { if run "$@"; then echo unexpected-success; else echo refused; fi; }
mkdir -p "$tmp/bucket"
m="$tmp/bucket/chief.fleet.json"
a="$tmp/bucket/fleet-control.json"
check 'missing manifest reads paused' missing:paused "$(mode "$m")"
run add "$m" /scratch/HIMMEL-1-N1-worker.md --lane api || exit 1
check 'legacy manifest is unbound and paused' unbound:paused "$(mode "$m")"
run control init "$m" --target 1; rc=$?
check 'init creates paused binding' 0 "$rc"
# Baseline RED stops at the missing command, avoiding cascading absent-file errors.
[ "$rc" -eq 0 ] || exit 1
check 'new anchor is paused generation one' 'ok:paused:1:1' "$(show "$m" | jq -r '[.state,.mode,.generation,.target] | join(":")')"
check 'environment mode and held flag confer no authority' ok:paused "$(HIMMEL_FLEET_MODE=active held=true mode "$m")"
before="$(jq -Sc . "$a")"
run control init "$m" --target 1
check 'init does not reset anchor or generation' "$before" "$(jq -Sc . "$a")"
check 'conflicting init target refuses' refused "$(refuse control init "$m" --target 3)"
successor="$tmp/bucket/successor.fleet.json"
cp "$m" "$successor"
run control set "$successor" --mode active --expect-gen 1
check 'copied successor reads same active anchor' ok:active "$(mode "$m")"
check 'reference contains no mutable control copies' '["anchor","family"]' "$(jq -c '.control | keys' "$successor")"
check 'environment cannot raise approved activation cap' refused "$(HIMMEL_FLEET_CAP=999999999 refuse control set "$m" --mode active --target 2147483647 --expect-gen 2)"
check 'stale writer refuses' refused "$(refuse control set "$m" --mode paused --expect-gen 1)"
run control set "$m" --mode shadow --expect-gen 2 > "$tmp/race1" 2>&1 & p1=$!
run control set "$successor" --mode paused --expect-gen 2 > "$tmp/race2" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check 'writers through distinct manifests have exactly one winner' 1 "$((r1+r2))"
check 'one coherent generation update' 3 "$(jq '.generation' "$a")"
printf '{"schema":1,"workers":[]}\n' > "$tmp/bucket/other.json"
run control init "$tmp/bucket/other.json" --target 1; rc=$?
check 'unbound successor adopts existing anchor' 0 "$rc"
check 'adoption preserves family' "$(jq -r '.control.family' "$m")" "$(jq -r '.control.family' "$tmp/bucket/other.json")"
cp "$a" "$tmp/anchor.saved"
cp "$m" "$tmp/manifest.saved"
rm "$a"
check 'missing anchor pauses' missing:paused "$(mode "$m")"
check 'init cannot reset a missing bound anchor' refused "$(refuse control init "$m" --target 1)"
for bad in 'null' '{}' '{"schema":1,"mode":"active"}' "$(jq '.generation = 0' "$tmp/anchor.saved")" "$(jq '.target = -1' "$tmp/anchor.saved")" "$(jq '.mode = "running"' "$tmp/anchor.saved")"; do
    printf '%s\n' "$bad" > "$a"
    check 'malformed anchor is invalid and paused' invalid:paused "$(mode "$m")"
    check 'set refuses invalid anchor' refused "$(refuse control set "$m" --mode paused --expect-gen 3)"
done
cat "$tmp/anchor.saved" "$tmp/anchor.saved" > "$a"
check 'concatenated anchor objects are invalid' invalid:paused "$(mode "$m")"
cp "$tmp/anchor.saved" "$a"
jq '.control.family = "other-family"' "$tmp/manifest.saved" > "$m"
check 'family mismatch pauses' mismatch:paused "$(mode "$m")"
check 'init refuses conflicting family' refused "$(refuse control init "$m" --target 1)"
for bad in /outside/fleet-control.json "$tmp/bucket/../bucket/fleet-control.json" 'relative.json'; do
    jq --arg a "$bad" '.control.anchor = $a' "$tmp/manifest.saved" > "$m"
    check 'outside or noncanonical reference pauses' mismatch:paused "$(mode "$m")"
done
jq '.control.family = "bad family"' "$tmp/manifest.saved" > "$m"
check 'malformed family pauses' invalid:paused "$(mode "$m")"
ln -s "$a" "$tmp/bucket/alias.json"
check 'symlink manifest cannot alias control state' invalid:paused "$(mode "$tmp/bucket/alias.json")"
cp "$tmp/manifest.saved" "$m"
for bad in 0 -1 1.5; do
    check 'invalid target refused' refused "$(refuse control init "$m" --target "$bad")"
done
check 'missing expected generation refuses' refused "$(refuse control set "$m" --mode active)"
check 'invalid generation refuses' refused "$(refuse control set "$m" --mode active --expect-gen NaN)"
printf 'bad\n' > "$tmp/bucket/bad.json"
check 'malformed manifest reads paused' invalid:paused "$(mode "$tmp/bucket/bad.json")"
check 'shared reader matches command interface' "$(show "$m")" "$(bash -c '. "$1/fleet-control.sh"; fleet_control_show "$2"' _ "$HERE" "$m")"
# A consumer must validate the same manifest bytes it reads, even across a
# concurrent replacement. This fixture publishes invalid input immediately
# after the real validator succeeds, before the consumer can open it again.
mkdir "$tmp/read-bin"
real_jq=$(command -v jq)
cat > "$tmp/read-bin/jq" <<'JQ'
#!/usr/bin/env bash
"$REAL_JQ" "$@"; rc=$?
if [ "$rc" -eq 0 ] && [ "${!#}" = "$SWAP_MANIFEST" ]; then
    printf 'invalid replacement\n' > "$SWAP_MANIFEST"
fi
exit "$rc"
JQ
chmod +x "$tmp/read-bin/jq"
# A valid snapshot can return ok, or the replacement can return paused; it
# cannot return a successful empty/malformed JSON response.
out=$(REAL_JQ="$real_jq" SWAP_MANIFEST="$m" PATH="$tmp/read-bin:$PATH" show "$m"); rc=$?
check 'concurrent manifest replacement yields one classified JSON snapshot' '0 true' "$rc $(printf '%s\n' "$out" | jq -se 'length == 1 and (.[0] | .state == "ok" or .mode == "paused")')"
cp "$tmp/manifest.saved" "$m"
# Fail at the existing atomic rename boundary after temp content exists.
mkdir "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 73\n' > "$tmp/bin/mv"
chmod +x "$tmp/bin/mv"
before="$(jq -Sc . "$a")"
PATH="$tmp/bin:$PATH" run control set "$m" --mode paused --expect-gen 3; rc=$?
check 'failed atomic replacement is visible' 1 "$rc"
check 'failed write preserves valid anchor' "$before" "$(jq -Sc . "$a")"
check 'failed write leaves no temporary file' 0 "$(find "$tmp/bucket" -name '.prim-write.*' | wc -l | tr -d ' ')"
# Partial init may leave a paused anchor; retry binds it without reset.
mkdir "$tmp/interrupted"
new="$tmp/interrupted/chief.json"
printf '{"schema":1,"workers":[]}\n' > "$new"
printf '#!/usr/bin/env bash\ncase "${!#}" in */chief.json) exit 73 ;; esac\nexec /bin/mv "$@"\n' > "$tmp/bin/mv"
PATH="$tmp/bin:$PATH" run control init "$new" --target 1; rc=$?
check 'failed reference replacement is visible' 1 "$rc"
check 'partial init anchor is paused' paused "$(jq -r .mode "$tmp/interrupted/fleet-control.json")"
run control init "$new" --target 1
check 'retry binds same paused anchor' ok:paused "$(mode "$new")"
# Distinct chief manifests initialized concurrently still share one family.
mkdir "$tmp/init-race"
run control init "$tmp/init-race/a.json" --target 1 > "$tmp/init1" 2>&1 & p1=$!
run control init "$tmp/init-race/b.json" --target 1 > "$tmp/init2" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check 'concurrent initializers both bind successfully' 0 "$((r1+r2))"
check 'concurrent init produces the same complete reference' "$(jq -Sc .control "$tmp/init-race/a.json")" "$(jq -Sc .control "$tmp/init-race/b.json")"
check 'concurrent initialization remains paused' 'ok:paused:1' "$(show "$tmp/init-race/a.json" | jq -r '[.state,.mode,.generation] | join(":")')"
# An actual signal before rename also leaves the old state and cleans scratch.
printf '#!/usr/bin/env bash\nkill -TERM "$PPID"\nexit 143\n' > "$tmp/bin/mv"
before="$(jq -Sc . "$a")"
PATH="$tmp/bin:$PATH" run control set "$m" --mode paused --expect-gen 3; rc=$?
check 'interrupted atomic replacement is visible' 1 "$rc"
check 'interruption preserves valid anchor' "$before" "$(jq -Sc . "$a")"
check 'interruption cleans temporary content' 0 "$(find "$tmp/bucket" -name '.prim-write.*' | wc -l | tr -d ' ')"
if [ "$fails" -eq 0 ]; then echo 'PASS - test-fleet-control.sh'; else echo "FAIL - $fails failures"; exit 1; fi
