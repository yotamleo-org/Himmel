#!/usr/bin/env bash
# Test for scripts/ci/rerun-head.sh.
# A fake gh serves canned `pr list` / `run list` / `run view` JSON and records
# every `run rerun`; the script's own jq filtering runs for real. No real run
# is ever rerun. The incident-replay rows use records copied verbatim from
# `gh run list --json ...` / `gh pr list --json ...` on the live repo
# (2026-10-19): the shapes (empty conclusion on a live run, attempt, status
# pending) are the real ones, not hand-written.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/ci/rerun-head.sh"
TMP="$(mktemp -d "/tmp/himmel-test-rerun-head.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
is()  { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2' got '$3'"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1: want exit $2 got $3"; fi; }
rc_nz() { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1: exit was 0"; fi; }

# The script under test runs from a throwaway repo whose origin is acme/widgets,
# beside a stub cancel-superseded-runs.sh that only records its argv.
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/ci" "$TMP/bin"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/acme/widgets.git
cp "$SRC" "$REPO/scripts/ci/rerun-head.sh" 2>/dev/null
cat > "$REPO/scripts/ci/cancel-superseded-runs.sh" <<'EOF'
#!/usr/bin/env bash
echo "cancel-superseded${*:+ $*}" >> "$FX/order"
[ "${FAKE_CANCEL_FAIL:-}" = 1 ] && { echo "stub: cancel-superseded failed" >&2; exit 1; }
exit 0
EOF
SCRIPT="$REPO/scripts/ci/rerun-head.sh"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh. Fixtures live in $FX; reruns are appended to $FX/reruns and, with
# every other call, to $FX/order. FAKE_GH_FAIL=prs|runs|view|rerun:<id> makes
# that call fail. A second `pr list` serves prs-after.json when it exists (a
# push landing between the reads and the write).
echo "gh $*" >> "$FX/calls"
id=""; for a in "${@:3}"; do case "$a" in ''|*[!0-9]*) ;; *) id="$a"; break ;; esac; done
case " $* " in *" -R acme/widgets "*|*" -R other/slug "*) ;; *) echo "fake-gh: no -R on: $*" >> "$FX/no-R" ;; esac
case "$1 $2" in
  "pr list")
    [ "${FAKE_GH_FAIL:-}" = prs ] && { echo "fake-gh: pr list failed" >&2; exit 1; }
    n=$(grep -c '^gh pr list' "$FX/calls")
    f="$FX/prs.json"; [ "$n" -ge 2 ] && [ -f "$FX/prs-after.json" ] && f="$FX/prs-after.json"
    head=""
    for a in "$@"; do [ "${prev:-}" = --head ] && head="$a"; prev="$a"; done
    jq -c --arg h "$head" 'map(select($h == "" or .headRefName == $h))' "$f" ;;
  "run list")
    [ "${FAKE_GH_FAIL:-}" = runs ] && { echo "fake-gh: run list failed" >&2; exit 1; }
    cat "$FX/runs.json" ;;
  "run view")
    [ "${FAKE_GH_FAIL:-}" = view ] && { echo "fake-gh: run view failed" >&2; exit 1; }
    jq -c --argjson id "${id:-0}" 'map(select(.databaseId == $id)) | .[0] // empty' "$FX/runs.json" | { read -r l || { echo "fake-gh: no run $id" >&2; exit 1; }; echo "$l"; } ;;
  "run rerun")
    [ "${FAKE_GH_FAIL:-}" = "rerun:$id" ] && { echo "fake-gh: rerun $id failed" >&2; exit 1; }
    echo "$id $*" >> "$FX/reruns"; echo "rerun $id" >> "$FX/order" ;;
  *) echo "fake-gh: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# run <id> <status> <conclusion> <branch> <sha> <attempt> -> one gh run list element
r() { printf '{"attempt":%s,"conclusion":"%s","databaseId":%s,"event":"pull_request","headBranch":"%s","headSha":"%s","status":"%s","workflowName":"CI"}' "$6" "$3" "$1" "$4" "$5" "$2"; }
# pr <number> <branch> <oid> -> one gh pr list element
p() { printf '{"headRefName":"%s","headRefOid":"%s","isCrossRepository":false,"number":%s}' "$2" "$3" "$1"; }
reset() { rm -rf "$TMP/fx"; mkdir -p "$TMP/fx"; echo '[]' > "$TMP/fx/prs.json"; echo '[]' > "$TMP/fx/runs.json"; : > "$TMP/fx/calls"; }
run() { FX="$TMP/fx" PATH="$TMP/bin:$PATH" GH_REPO="${GH_REPO-acme/widgets}" bash "$SCRIPT" "$@" 2>&1; }
reruns() { if [ -s "$TMP/fx/reruns" ]; then awk '{print $1}' "$TMP/fx/reruns" | sort | tr '\n' ' ' | sed 's/ $//'; else echo "none"; fi; }

if bash -n "$SRC"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# --- incident replay: records copied verbatim from the live repo -------------
# Branch feat/himmel-6476-leg-api-lane-switch: head 7fca3b1a has a live (pending)
# run; the older head f9caebf0 has a CANCELLED run. Rerunning the cancelled
# stale run is what held 34 of 61 slots and cancelled the head runs.
reset
cat > "$TMP/fx/prs.json" <<'EOF'
[{"headRefName":"feat/himmel-6476-leg-api-lane-switch","headRefOid":"7fca3b1a25e954a4d03f97a735247542f1fe3e61","isCrossRepository":false,"number":3213},
 {"headRefName":"fix/himmel-6502-merge-on-green-org-slug","headRefOid":"2b4bad1f47b58418f2f32d2f1dfb03b6c8ba779a","isCrossRepository":false,"number":3221}]
EOF
cat > "$TMP/fx/runs.json" <<'EOF'
[{"attempt":1,"conclusion":"","databaseId":39294318233,"event":"pull_request","headBranch":"feat/himmel-6476-leg-api-lane-switch","headSha":"7fca3b1a25e954a4d03f97a735247542f1fe3e61","status":"pending","workflowName":"CI"},
 {"attempt":1,"conclusion":"cancelled","databaseId":39293174291,"event":"pull_request","headBranch":"feat/himmel-6476-leg-api-lane-switch","headSha":"f9caebf069caad7436eb20038f914d45c5aec18e","status":"completed","workflowName":"CI"},
 {"attempt":1,"conclusion":"","databaseId":39294601937,"event":"pull_request","headBranch":"fix/himmel-6502-merge-on-green-org-slug","headSha":"2b4bad1f47b58418f2f32d2f1dfb03b6c8ba779a","status":"queued","workflowName":"CI"}]
EOF
out="$(run --run 39293174291)"; rc=$?
is "incident replay: --run <stale cancelled id> reruns nothing" "none" "$(reruns)"
rc_is "incident replay: --run <stale id> exits 1" 1 "$rc"
case "$out" in *stale*|*superseded*|*"not the current head"*) ok "  refusal says why" ;; *) bad "  refusal reason missing: $out" ;; esac
out="$(run 3213)"; rc=$?
is "incident replay: PR with a live head run is a no-op" "none" "$(reruns)"
rc_is "  exit 0" 0 "$rc"

# --- <pr> mode ---------------------------------------------------------------
H=aaaaaaaa11111111aaaaaaaa11111111aaaaaaaa; O=bbbbbbbb22222222bbbbbbbb22222222bbbbbbbb
setpr() { reset; echo "[$(p 10 feat/a $H)]" > "$TMP/fx/prs.json"; echo "[$1]" > "$TMP/fx/runs.json"; }

setpr "$(r 5 completed failure feat/a $H 1)"
out="$(run 10)"; rc=$?
is "failed head run: rerun" "5" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
case "$(cat "$TMP/fx/reruns")" in *"--failed"*) ok "  rerun uses --failed" ;; *) bad "  --failed missing: $(cat "$TMP/fx/reruns")" ;; esac
if [ ! -s "$TMP/fx/no-R" ] 2>/dev/null; then ok "  every gh call carries -R"; else bad "  gh call without -R: $(cat "$TMP/fx/no-R")"; fi
case " $(cat "$TMP/fx/calls") " in *" -R acme/widgets "*) ok "  -R is GH_REPO" ;; *) bad "  -R acme/widgets missing" ;; esac

setpr "$(r 5 completed cancelled feat/a $H 1)"
run 10 >/dev/null
is "cancelled head run: rerun" "5" "$(reruns)"
setpr "$(r 5 completed timed_out feat/a $H 1)"
run 10 >/dev/null
is "timed_out head run: rerun" "5" "$(reruns)"

for c in success skipped neutral; do
  setpr "$(r 5 completed $c feat/a $H 1)"
  run 10 >/dev/null
  is "green ($c) head run: no-op" "none" "$(reruns)"
done
for s in queued pending in_progress waiting requested; do
  setpr "$(r 5 $s '' feat/a $H 1)"
  run 10 >/dev/null
  is "live ($s) head run: no-op" "none" "$(reruns)"
done

setpr "$(r 5 completed failure feat/a $H 2)"
out="$(run 10)"; rc=$?
is "head run already rerun once (attempt 2): not rerun again" "none" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
setpr "$(r 5 completed startup_failure feat/a $H 1)"
run 10 >/dev/null
is "startup_failure head run: not rerun" "none" "$(reruns)"

setpr "$(r 7 completed failure feat/a $O 1)"
out="$(run 10)"; rc=$?
is "no run at the head (only a stale one, newer id): nothing rerun" "none" "$(reruns)"
rc_is "  exit 0" 0 "$rc"

setpr "$(r 5 completed failure feat/a $H 1),$(r 9 completed failure feat/a $O 1)"
run 10 >/dev/null
is "stale failed run with a newer id is ignored; the head run is rerun" "5" "$(reruns)"
# two open PRs whose heads sit at one commit: each is judged on its own branch's run
reset
echo "[$(p 10 feat/a $H),$(p 11 feat/b $H)]" > "$TMP/fx/prs.json"
echo "[$(r 5 completed failure feat/a $H 1),$(r 6 in_progress '' feat/b $H 1)]" > "$TMP/fx/runs.json"
run 11 >/dev/null
is "PR 11 shares its head sha with PR 10: PR 10's failed run is not PR 11's" "none" "$(reruns)"
run 10 >/dev/null
is "  PR 10 reruns its own failed run" "5" "$(reruns)"

setpr "$(r 5 completed failure feat/a $H 1),$(r 6 completed success feat/a $H 1)"
run 10 >/dev/null
is "newest run at the head decides (green newer than red): no-op" "none" "$(reruns)"
setpr "$(r 5 completed success feat/a $H 1),$(r 6 completed failure feat/a $H 1)"
run 10 >/dev/null
is "newest run at the head decides (red newer than green): rerun newest" "6" "$(reruns)"

setpr "$(r 5 completed failure feat/a $H 1)"
out="$(run 10 --dry-run)"; rc=$?
is "<pr> --dry-run: no rerun" "none" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
case "$out" in *"would-rerun 5 "*) ok "  names the run it would rerun" ;; *) bad "  would-rerun line missing: $out" ;; esac

# an unknown PR number
setpr "$(r 5 completed failure feat/a $H 1)"
out="$(run 99)"; rc=$?
rc_nz "PR not among the open PRs: non-zero exit" "$rc"
is "  nothing rerun" "none" "$(reruns)"

# --- --run <id> --------------------------------------------------------------
setpr "$(r 5 completed failure feat/a $H 1),$(r 6 completed failure feat/a $O 1)"
out="$(run --run 6)"; rc=$?
is "--run <stale id>: refused, nothing rerun" "none" "$(reruns)"
rc_is "  exit 1" 1 "$rc"
setpr "$(r 5 completed failure feat/a $H 1),$(r 6 completed failure feat/a $O 1)"
out="$(run --run 5)"; rc=$?
is "--run <head id>: rerun" "5" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
setpr "$(r 5 in_progress '' feat/a $H 1)"
run --run 5 >/dev/null
is "--run <live head id>: no-op" "none" "$(reruns)"

reset
echo "[$(p 10 feat/a $H)]" > "$TMP/fx/prs.json"
echo "[$(r 6 completed failure feat/orphan $O 1)]" > "$TMP/fx/runs.json"
out="$(run --run 6)"; rc=$?
is "--run on a branch with no open PR: refused" "none" "$(reruns)"
rc_is "  exit 1" 1 "$rc"

reset
echo "[$(p 10 feat/a $H),$(p 11 feat/a $O)]" > "$TMP/fx/prs.json"
echo "[$(r 6 completed failure feat/a $H 1)]" > "$TMP/fx/runs.json"
out="$(run --run 6)"; rc=$?
is "--run on a branch with two open PRs: refused" "none" "$(reruns)"
rc_is "  exit 1" 1 "$rc"

reset
echo '[{"headRefName":"feat/a","headRefOid":"'$H'","isCrossRepository":true,"number":10}]' > "$TMP/fx/prs.json"
echo "[$(r 6 completed failure feat/a $H 1)]" > "$TMP/fx/runs.json"
out="$(run --run 6)"; rc=$?
is "--run on a fork PR's branch: refused" "none" "$(reruns)"
rc_is "  exit 1" 1 "$rc"

reset
echo "[$(p 10 feat/a $H)]" > "$TMP/fx/prs.json"
echo "[$(r 6 completed failure feat/a $H 1 | sed 's/"pull_request"/"workflow_dispatch"/')]" > "$TMP/fx/runs.json"
out="$(run --run 6)"; rc=$?
is "--run <workflow_dispatch run>: refused" "none" "$(reruns)"
rc_is "  exit 1" 1 "$rc"

reset
out="$(run --run 404)"; rc=$?
rc_nz "--run <unknown id>: non-zero exit" "$rc"
is "  nothing rerun" "none" "$(reruns)"

# --- --fleet -----------------------------------------------------------------
setfleet() {
  reset
  echo "[$(p 10 feat/a $H),$(p 11 feat/b $O),$(p 12 feat/c cccccccc33333333cccccccc33333333cccccccc),$(p 13 feat/d dddddddd44444444dddddddd44444444dddddddd)]" > "$TMP/fx/prs.json"
  echo "[$(r 1 completed cancelled feat/a $H 1),$(r 2 in_progress '' feat/b $O 1),$(r 3 completed success feat/c cccccccc33333333cccccccc33333333cccccccc 1),$(r 4 completed failure feat/d dddddddd44444444dddddddd44444444dddddddd 1),$(r 8 completed failure feat/a eeeeeeee55555555eeeeeeee55555555eeeeeeee 1)]" > "$TMP/fx/runs.json"
}
setfleet
out="$(run --fleet --dry-run)"; rc=$?
is "--fleet --dry-run: no rerun" "none" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
case "$out" in *"would-rerun 1 "*) ok "  plan names run 1" ;; *) bad "  would-rerun 1 missing: $out" ;; esac
case "$out" in *"would-rerun 4 "*) ok "  plan names run 4" ;; *) bad "  would-rerun 4 missing: $out" ;; esac
case "$out" in *"would-rerun 2 "*|*"would-rerun 3 "*|*"would-rerun 8 "*) bad "  plan names a live, green or stale run: $out" ;; *) ok "  plan omits live, green and stale runs" ;; esac
is "  cancel-superseded ran with --dry-run" "cancel-superseded --dry-run" "$(cat "$TMP/fx/order")"

setfleet
out="$(run --fleet)"; rc=$?
is "--fleet: reruns exactly the red/cancelled head runs" "1 4" "$(reruns)"
rc_is "  exit 0" 0 "$rc"
is "  cancel-superseded ran first, then the reruns" "cancel-superseded|rerun 1|rerun 4" "$(paste -sd'|' "$TMP/fx/order")"
if [ ! -s "$TMP/fx/no-R" ] 2>/dev/null; then ok "  every gh call carries -R"; else bad "  gh call without -R"; fi

setfleet
out="$(FAKE_CANCEL_FAIL=1 run --fleet)"; rc=$?
is "--fleet, cancel-superseded fails: nothing rerun" "none" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# a read failing for ANY PR means no PR is rerun (reads before writes)
for f in prs runs; do
  setfleet
  out="$(FAKE_GH_FAIL=$f run --fleet)"; rc=$?
  is "--fleet, gh $f read fails: nothing rerun" "none" "$(reruns)"
  rc_nz "  non-zero exit" "$rc"
done
setfleet
echo "not json" > "$TMP/fx/runs.json"
out="$(run --fleet)"; rc=$?
is "--fleet, malformed run list: nothing rerun" "none" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# a possibly truncated PR page hides heads: refuse
setfleet
jq -n '[range(0;200) | {number:., headRefName:("feat/p\(.)"), headRefOid:"H\(.)", isCrossRepository:false}]' > "$TMP/fx/prs.json"
out="$(run --fleet)"; rc=$?
is "--fleet, 200 open PRs (possible truncation): nothing rerun" "none" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# a push between the reads and the writes: that PR's old head run is not rerun
setfleet
echo "[$(p 10 feat/a ffffffff66666666ffffffff66666666ffffffff),$(p 11 feat/b $O),$(p 12 feat/c cccccccc33333333cccccccc33333333cccccccc),$(p 13 feat/d dddddddd44444444dddddddd44444444dddddddd)]" > "$TMP/fx/prs-after.json"
out="$(run --fleet)"; rc=$?
is "--fleet, PR 10 head moved after the reads: its (now stale) run is not rerun" "4" "$(reruns)"
setpr "$(r 5 completed failure feat/a $H 1)"
echo "[$(p 10 feat/a ffffffff66666666ffffffff66666666ffffffff)]" > "$TMP/fx/prs-after.json"
out="$(run 10)"; rc=$?
is "<pr>, head moved after the reads: refused" "none" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# a failed rerun is reported, the rest still go, exit 1
setfleet
out="$(FAKE_GH_FAIL=rerun:1 run --fleet)"; rc=$?
is "--fleet, rerun 1 fails: run 4 still rerun" "4" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# --- single-PR read failures ---------------------------------------------------
for f in prs runs; do
  setpr "$(r 5 completed failure feat/a $H 1)"
  out="$(FAKE_GH_FAIL=$f run 10)"; rc=$?
  is "<pr>, gh $f read fails: nothing rerun" "none" "$(reruns)"
  rc_nz "  non-zero exit" "$rc"
done
setpr "$(r 5 completed failure feat/a $H 1)"
out="$(FAKE_GH_FAIL=view run --run 5)"; rc=$?
is "--run, gh view fails: nothing rerun" "none" "$(reruns)"
rc_nz "  non-zero exit" "$rc"

# --- repo resolution -----------------------------------------------------------
setpr "$(r 5 completed failure feat/a $H 1)"
out="$(GH_REPO='' run 10)"; rc=$?
case " $(cat "$TMP/fx/calls") " in *" -R acme/widgets "*) ok "no GH_REPO: -R from the https origin" ;; *) bad "origin slug not used: $(cat "$TMP/fx/calls")" ;; esac
git -C "$REPO" remote set-url origin git@github.com:other/slug.git
setpr "$(r 5 completed failure feat/a $H 1)"
out="$(GH_REPO='' run 10)"
case " $(cat "$TMP/fx/calls") " in *" -R other/slug "*) ok "no GH_REPO: -R from the ssh origin" ;; *) bad "ssh origin slug not used: $(cat "$TMP/fx/calls")" ;; esac
git -C "$REPO" remote remove origin
setpr "$(r 5 completed failure feat/a $H 1)"
out="$(GH_REPO='' run 10)"; rc=$?
rc_nz "no GH_REPO and no origin: non-zero exit" "$rc"
is "  nothing rerun" "none" "$(reruns)"
git -C "$REPO" remote add origin https://github.com/acme/widgets.git

# --- usage ---------------------------------------------------------------------
for args in "" "--bogus" "10 11" "--fleet 10" "--run" "--run abc" "--fleet --run 5" "abc"; do
  reset
  out="$(run $args)"; rc=$?
  rc_is "usage: '$args' exits 2" 2 "$rc"
done

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rerun-head"; exit 0; fi
echo "FAIL: $fails" >&2; exit 1
