#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in check(); backtick spans are literal
# scripts/handover/chief-kit/test-live-state.sh - suite for live-state.sh
# which renders a chief doc's `## Live state` `workers:` entries
# from its fleet manifest + the held worker locks:
#   1. a held manifest worker gets `<label>:<nonce>:<lock-token>:<pid>`, the lock
#      token read from the lock, the nonce from --nonce (a new worker)
#   2. a rerun with no flags keeps the chief-written nonce and pid
#   3. a manifest worker that holds no lock is left out; a worker off the manifest drops
#   4. a new worker with no --nonce is refused and the doc is untouched
#   5. prose on the workers: line survives; other fields and sections are untouched
#   6. --print writes nothing; the rendered line is what tick.sh's parser reads
#   7. a chief doc with neither a `workers:` nor a `legs:` line is refused
#  26. a pool-disposition `after <KEY>` line writes its Jira blocks link once (a stub Jira CLI)
#
# Hermetic: temp dir + its own HANDOVER_DIR. PLATFORM GUARD: Linux-only kit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${LIVE_STATE:-$HERE/live-state.sh}"
LOCK="$HERE/../queue-lock.sh"
FM="$HERE/fleet-manifest.sh"

if ! command -v flock >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip - test-live-state.sh: needs flock and jq (the chief kit is Linux-only)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/live-state-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HANDOVER_DIR="$tmp/root" HIMMEL_QUOTA_DIR="$tmp/quota"
mkdir -p "$HANDOVER_DIR/b"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

con="$HANDOVER_DIR/b/HIMMEL-nextleg-X-chief.md"
m="${con%.md}.fleet.json"
d1="$HANDOVER_DIR/b/HIMMEL-1-N61-a-2026-09-30-RESUME.md"
d2="$HANDOVER_DIR/b/HIMMEL-2-N65-b-2026-09-30-RESUME.md"
d3="$HANDOVER_DIR/b/HIMMEL-3-N66-c-2026-09-30-RESUME.md"
: > "$d1"; : > "$d2"; : > "$d3"
t1="$(bash "$LOCK" acquire "$d1" tok-one 2>/dev/null | sed -n 's/^release-token: `\(.*\)`$/\1/p')"
bash "$LOCK" acquire "$d2" tok-two >/dev/null 2>&1
bash "$FM" add "$m" --lane native "$d1" "$d2" "$d3" >/dev/null 2>&1   # d3 holds no lock

cat > "$con" <<'DOC'
# chief

## Live state

workers: `N99:old-nonce:old-lock:1` (N50 WRAPPED earlier)
queue: none
last GO: none

## Results
- workers: `N61:not:an:entry` in a bullet below the section
DOC

# 4. a new worker without --nonce is refused, doc untouched.
before="$(cat "$con")"
bash "$SCRIPT" "$con" >/dev/null 2>&1; rc=$?
check '4. a new worker with no nonce is refused' 1 "$rc"
check '4. the refused run leaves the doc untouched' "$before" "$(cat "$con")"

# 1. nonce supplied; token from the lock.
bash "$SCRIPT" "$con" --nonce N61=nonce-61 --nonce N65=nonce-65 --pid N61=111 --pid N65=222 >/dev/null 2>&1; rc=$?
check '1. render succeeds' 0 "$rc"
line="$(grep '^workers:' "$con")"
case "$line" in *'`N61:nonce-61:tok-one:111`'*) r=yes ;; *) r=no ;; esac
check '1. N61 entry carries its nonce, the lock token and pid' yes "$r"
case "$line" in *'`N65:nonce-65:tok-two:222`'*) r=yes ;; *) r=no ;; esac
check '1. N65 entry carries its own lock token' yes "$r"
case "$line" in *N66*) r=has ;; *) r=none ;; esac
check '3. a manifest worker holding no lock is left out' none "$r"
case "$line" in *N99*) r=has ;; *) r=none ;; esac
check '3. a worker off the manifest drops' none "$r"
case "$line" in *'(N50 WRAPPED earlier)'*) r=kept ;; *) r=lost ;; esac
check '5. prose on the workers: line survives' kept "$r"
check '5. the queue: field is untouched' 'queue: none' "$(grep '^queue:' "$con")"
check '5. a workers: bullet outside Live state is untouched' '- workers: `N61:not:an:entry` in a bullet below the section' "$(grep '^- workers:' "$con")"

# 2. rerun with no flags keeps nonce and pid.
cp "$con" "$tmp/after1"
bash "$SCRIPT" "$con" >/dev/null 2>&1; rc=$?
check '2. a rerun with no flags succeeds' 0 "$rc"
check '2. a rerun changes nothing' "$(cat "$tmp/after1")" "$(cat "$con")"

# 2b. a lock token that changed is picked up, the nonce stays.
bash "$LOCK" release "$d2" tok-two >/dev/null 2>&1
bash "$LOCK" acquire "$d2" tok-two-b >/dev/null 2>&1
bash "$SCRIPT" "$con" >/dev/null 2>&1
case "$(grep '^workers:' "$con")" in *'`N65:nonce-65:tok-two-b:222`'*) r=yes ;; *) r=no ;; esac
check '2b. a re-acquired lock updates the token, keeps nonce and pid' yes "$r"

# 3b. removing a worker from the manifest drops it.
bash "$FM" remove "$m" N65 >/dev/null 2>&1
bash "$SCRIPT" "$con" >/dev/null 2>&1
case "$(grep '^workers:' "$con")" in *N65*) r=has ;; *) r=none ;; esac
check '3b. a worker removed from the manifest drops' none "$r"

# 6. --print writes nothing.
cp "$con" "$tmp/after2"
out="$(bash "$SCRIPT" "$con" --print 2>/dev/null)"
check '6. --print leaves the doc untouched' "$(cat "$tmp/after2")" "$(cat "$con")"
case "$out" in 'workers: `N61:nonce-61:tok-one:111`'*) r=yes ;; *) r=no ;; esac
check '6. --print prints the workers: line' yes "$r"

# 7. no workers: line.
printf '# c\n\n## Live state\n\nqueue: none\n' > "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-chief.md"
bash "$FM" add "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-chief.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-chief.md" --nonce N61=x >/dev/null 2>&1; rc=$?
check '7. a doc with no workers: line is refused' 1 "$rc"

# 8. a backslash in a nonce is refused (awk -v would interpret it).
before8="$(cat "$con")"
bash "$SCRIPT" "$con" --nonce 'N61=a\nb' >/dev/null 2>&1; rc=$?
check '8. a backslash in --nonce is refused' 2 "$rc"
check '8. the refused run leaves the doc untouched' "$before8" "$(cat "$con")"

# 9. the `none` placeholder is not carried into a rendered line.
con9="$HANDOVER_DIR/b/HIMMEL-nextleg-Z-chief.md"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\n' > "$con9"
bash "$FM" add "${con9%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$con9" --nonce N61=n9 --pid N61=9 >/dev/null 2>&1
check '9. legs: none becomes the entries alone' 'workers: `N61:n9:tok-one:9`' "$(grep '^workers:' "$con9")"
bash "$FM" remove "${con9%.md}.fleet.json" N61 >/dev/null 2>&1
bash "$SCRIPT" "$con9" >/dev/null 2>&1
bash "$SCRIPT" "$con9" >/dev/null 2>&1
check '9. an empty render is a stable single none' 'workers: none' "$(grep '^workers:' "$con9")"

# 10. a backslash in the preserved prose survives the rewrite (not awk-interpreted).
con10="$HANDOVER_DIR/b/HIMMEL-nextleg-W-chief.md"
printf '# c\n\n## Live state\n\nlegs: `N61:n10:tok-one:10` note a\\nb \\t end\nqueue: none\n' > "$con10"
bash "$FM" add "${con10%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$con10" >/dev/null 2>&1
check '10. backslashes in prose are written verbatim' 'workers: `N61:n10:tok-one:10` note a\nb \t end' "$(grep '^workers:' "$con10")"
check '10. the doc keeps its line count' 6 "$(wc -l < "$con10" | tr -d ' ')"

# 11. a lock status failure (not "free") refuses and leaves the doc untouched.
con11="$HANDOVER_DIR/b/HIMMEL-nextleg-V-chief.md"
printf '# c\n\n## Live state\n\nlegs: `N61:n11:tok-one:11`\n' > "$con11"
bash "$FM" add "${con11%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
before11="$(cat "$con11")"
cp -R "$HERE/.." "$tmp/kitcopy" 2>/dev/null
mkdir -p "$tmp/lib" && cp "$HERE/../../lib/legacy-names.sh" "$tmp/lib/"   # live-state.sh sources ../../lib/legacy-names.sh
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/kitcopy/queue-lock.sh"
bash "$tmp/kitcopy/chief-kit/live-state.sh" "$con11" >/dev/null 2>&1; rc=$?
check '11. a lock status failure refuses' 1 "$rc"
check '11. the refused run leaves the doc untouched' "$before11" "$(cat "$con11")"

# 12. a held lock whose owner is unreadable refuses and leaves the doc untouched.
printf '#!/usr/bin/env bash\necho garbage\nexit 11\n' > "$tmp/kitcopy/queue-lock.sh"
bash "$tmp/kitcopy/chief-kit/live-state.sh" "$con11" >/dev/null 2>&1; rc=$?
check '12. an unreadable lock owner refuses' 1 "$rc"
check '12. the refused run leaves the doc untouched' "$before11" "$(cat "$con11")"

# 14. an owner session carrying a span delimiter (colon, backtick, whitespace) refuses and leaves the doc untouched.
for bad14 in 'a:b' 'a`b' 'a b'; do
    printf '{"session":"%s"}\n' "$bad14" > "$tmp/owner14.json"
    printf '#!/usr/bin/env bash\ncat "%s"\nexit 11\n' "$tmp/owner14.json" > "$tmp/kitcopy/queue-lock.sh"
    err14="$(bash "$tmp/kitcopy/chief-kit/live-state.sh" "$con11" 2>&1 >/dev/null)"; rc=$?
    check "14. owner session [$bad14] refuses" 1 "$rc"
    case "$err14" in *'span delimiter'*) r=guard ;; *) r="[$err14]" ;; esac
    check "14. owner session [$bad14] hits the delimiter guard" guard "$r"
    check "14. owner session [$bad14] leaves the doc untouched" "$before11" "$(cat "$con11")"
done

# 13. end to end: tick.sh reads the rendered doc as livestate=ok.
e2e="$HANDOVER_DIR/b/HIMMEL-nextleg-T-chief.md"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\nlast GO: none\nacked: none\n' > "$e2e"
bash "$FM" add "${e2e%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$e2e" --nonce N61=n13 --pid N61=13 >/dev/null 2>&1
mkdir -p "$tmp/tickstate"
tick_out="$(TICK_DOCTOR_TTL_MIN=0 TICK_WORKTREE_ORPHANS_PROBE="$tmp/no-wt-orphans-probe" TICK_STATE_DIR="$tmp/tickstate" TICK_TMPDIR="$tmp" TICK_LAUNCH_DIR="$tmp" bash "$HERE/tick.sh" --doc "$e2e" --token test-token --workers "$d1" 2>/dev/null)"
case "$tick_out" in *'livestate=ok'*) r=ok ;; *) r="[$tick_out]" ;; esac
check '13. tick.sh reads the rendered Live state as livestate=ok' ok "$r"

# 15. a lockless manifest row gets its own `lockless:` line, not a
# "holds no lock" omission, and a rerun replaces the line instead of stacking it.
lk="$HANDOVER_DIR/b/HIMMEL-nextleg-L-chief.md"
lkd="$HANDOVER_DIR/b/HIMMEL-4869-N90-pilot.md"
: > "$lkd"
printf '# c\n\n## Live state\n\nlegs: none\nlockless: stale (x) /old; \nqueue: none\n\n## Results\n' > "$lk"
bash "$FM" add "${lk%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$FM" add "${lk%.md}.fleet.json" --lane deepseek --lockless "$lkd" >/dev/null 2>&1
lk_err="$(bash "$SCRIPT" "$lk" --nonce N61=n14 --pid N61=14 2>&1 >/dev/null)"
check '15. the lockless row is listed with its lane and doc' "lockless: N90 (deepseek) $lkd" "$(grep '^lockless:' "$lk")"
check '15. the stale lockless line is replaced, not stacked' 1 "$(grep -c '^lockless:' "$lk")"
case "$lk_err" in *N90*) r=noise ;; *) r=quiet ;; esac
check '15. a lockless row is not reported as a worker that holds no lock' quiet "$r"
check '15. the workers: line carries only the locked worker' 'workers: `N61:n14:tok-one:14`' "$(grep '^workers:' "$lk")"
check '15. the queue: field is untouched' 'queue: none' "$(grep '^queue:' "$lk")"
bash "$FM" remove "${lk%.md}.fleet.json" N90 >/dev/null 2>&1
bash "$SCRIPT" "$lk" >/dev/null 2>&1
check '15. with no lockless row the line is dropped' 0 "$(grep -c '^lockless:' "$lk")"

# 16. an empty lane reads unknown (not the next field), and only the
# boolean true is lockless: the string "true" stays a locked, visible row.
lk2="$HANDOVER_DIR/b/HIMMEL-nextleg-M-chief.md"
lk2d="$HANDOVER_DIR/b/HIMMEL-4869-N91-pilot.md"; lk2s="$HANDOVER_DIR/b/HIMMEL-4869-N92-str.md"
: > "$lk2d"; : > "$lk2s"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$lk2"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N91","lane":"","lockless":true},{"doc":"%s","label":"N92","lane":"native","lockless":"true"}]}\n' "$lk2d" "$lk2s" > "${lk2%.md}.fleet.json"
lk2_err="$(bash "$SCRIPT" "$lk2" 2>&1 >/dev/null)"
check '16. an empty lane is listed as unknown' "lockless: N91 (unknown) $lk2d" "$(grep '^lockless:' "$lk2")"
case "$lk2_err" in *'N92 holds no lock'*) r=visible ;; *) r="[$lk2_err]" ;; esac
check '16. a string "true" lockless row is not hidden as lockless' visible "$r"

# --digest reads the existing state without a manifest or queue-lock access.
digest_doc="$tmp/digest.md"
cat > "$digest_doc" <<'DOC'
---
status: LIVE
---
# chief
## Live state
head: abc123
workers: `N61:nonce:held-lock:13`
  `N62:nonce-two:held-two:14`
queue: held.md
lock: own-lock

## Open rulings
- [ ] Next slice
  PRIVATE body
- [x] Resolved slice
### Lane choice
PRIVATE body
- PRIVATE body list
* PRIVATE second body list
+ PRIVATE third body list
1. PRIVATE numbered body list

## Results
workers: `N99:not:a:worker`
PRIVATE history
DOC
before_digest="$(cat "$digest_doc")"
digest_out="$(bash "$SCRIPT" "$digest_doc" --digest 2>/dev/null)"; rc=$?
check '17. digest works without a manifest' 0 "$rc"
want_digest='status: LIVE
head: abc123
workers: `N61:nonce:held-lock:13` `N62:nonce-two:held-two:14`
queue: held.md
lock: own-lock
open rulings: 2
- Next slice
- Lane choice'
check '17. digest keeps wrapped workers and only open ruling titles' "$want_digest" "$digest_out"
check '17. digest does not write the document' "$before_digest" "$(cat "$digest_doc")"
check '17. digest creates no sibling files' 1 "$(find "$tmp" -name 'digest*' | wc -l | tr -d ' ')"
awk '/^## Results$/ {for (i=1;i<=200;i++) print "- [ ] Ruling " i} {print}' "$digest_doc" > "$tmp/long.md"
long_digest="$(bash "$SCRIPT" "$tmp/long.md" --digest 2>/dev/null)"
case "$long_digest" in *'open rulings: 202'*'additional ruling titles omitted'*) r=yes ;; *) r=no ;; esac
check '18. digest counts all rulings but bounds displayed titles' yes "$r"
check '18. digest stays under 60 lines' yes "$([ "$(printf '%s\n' "$long_digest" | wc -l)" -lt 60 ] && echo yes || echo no)"
printf '# chief\n## Results\n' > "$tmp/no-state.md"
bash "$SCRIPT" "$tmp/no-state.md" --digest >/dev/null 2>&1; rc=$?
check '19. digest refuses a missing Live state block' 1 "$rc"
bash "$SCRIPT" "$tmp/absent.md" --digest >/dev/null 2>&1; rc=$?
check '19. digest refuses a missing document' 1 "$rc"
bash "$SCRIPT" "$digest_doc" --digest --nonce N61=changed >/dev/null 2>&1; rc=$?
check '19. digest cannot mix with render-only arguments' 2 "$rc"

# 20. the tick flags a Live state over LIVESTATE_BUDGET_BYTES, like decisions:.
budget_doc="$HANDOVER_DIR/b/HIMMEL-nextleg-BG-chief.md"
printf '# c\n\n## Live state\n\nlegs: none %s\nqueue: none\nlast GO: none\nacked: none\n\n## Results\n' "$(printf 'x%.0s' $(seq 1 300))" > "$budget_doc"
budget_tick() { TICK_DOCTOR_TTL_MIN=0 TICK_WORKTREE_ORPHANS_PROBE="$tmp/no-wt-orphans-probe" TICK_STATE_DIR="$tmp/tickstate" TICK_TMPDIR="$tmp" TICK_LAUNCH_DIR="$tmp" bash "$HERE/tick.sh" --doc "$budget_doc" --token test-token --workers "$d1" 2>/dev/null; }
case "$(LIVESTATE_BUDGET_BYTES=200 budget_tick)" in *'ACTION livestate-over-budget='*'/200:'*) r=flagged ;; *) r=silent ;; esac
check '20. a Live state over LIVESTATE_BUDGET_BYTES is flagged by the tick' flagged "$r"
{ printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\nlast GO: none\nacked: none\n'; seq 1 300 | sed 's/.*//'; printf '## Results\n'; } > "$budget_doc"
case "$(LIVESTATE_BUDGET_BYTES=200 budget_tick)" in *'ACTION livestate-over-budget='*'/200:'*) r=flagged ;; *) r=silent ;; esac
check '20. trailing blank lines of the Live state count toward the budget' flagged "$r"
case "$(LIVESTATE_BUDGET_BYTES=100000 budget_tick)" in *'livestate-over-budget'*) r=flagged ;; *) r=silent ;; esac
check '20. a Live state under the budget is not flagged' silent "$r"
# 20b. the whole doc is measured against the Read limit, not only the Live state.
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\nlast GO: none\nacked: none\n\n## Current direction\n\n%s\n\n## Results\n' "$(printf 'x%.0s' $(seq 1 600))" > "$budget_doc"
case "$(DOC_READ_BUDGET_BYTES=500 budget_tick)" in *'ACTION doc-over-read-limit='*'/500:'*) r=flagged ;; *) r=silent ;; esac
check '20b. a whole doc over DOC_READ_BUDGET_BYTES is flagged although its Live state is small' flagged "$r"
case "$(LIVESTATE_BUDGET_BYTES=100000 DOC_READ_BUDGET_BYTES=100000 budget_tick)" in *'doc-over-read-limit'*) r=flagged ;; *) r=silent ;; esac
check '20b. a whole doc under the budget is not flagged' silent "$r"

# 21. M1a: `workers:` first, the pre-rename `legs:` line and `.legs` array still read,
#     `workers:` wins when a doc carries both, and HIMMEL_LEGACY_NAMES=0 drops the old spelling.
wk="$HANDOVER_DIR/b/HIMMEL-nextleg-M1A-chief.md"
wm="${wk%.md}.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N61","added":"x"}]}\n' "$d1" > "$wm"
printf '# c\n\n## Live state\n\nworkers: `N61:nonce-61:tok-one:111` note\nqueue: none\n\n## Results\n' > "$wk"
cp "$wk" "$tmp/wk-before"
bash "$SCRIPT" "$wk" >/dev/null 2>&1; rc=$?
check '21. a workers: doc over a workers manifest renders' 0 "$rc"
check '21. the render keeps the workers: line and leaves no legs: line' "$(cat "$tmp/wk-before")" "$(cat "$wk")"
check '21. --digest reads the workers: line' 'workers: `N61:nonce-61:tok-one:111` note' "$(bash "$SCRIPT" "$wk" --digest 2>/dev/null | grep '^workers:')"
printf '# c\n\n## Live state\n\nlegs: `N61:nonce-61:tok-one:111`\nqueue: none\n\n## Results\n' > "$wk"
bash "$SCRIPT" "$wk" >/dev/null 2>&1; rc=$?
check '21. an old legs: doc over a workers manifest renders' 0 "$rc"
check '21. that render leaves exactly one worker line, a workers: one and no legs: one' '1 0' "$(grep -c '^workers:' "$wk") $(grep -c '^legs:' "$wk")"
printf '# c\n\n## Live state\n\nlegs: `N99:old:old:1`\nworkers: `N61:nonce-61:tok-one:111`\nqueue: none\n\n## Results\n' > "$wk"
out="$(bash "$SCRIPT" "$wk" --print 2>/dev/null)"
case "$out" in 'workers: `N61:nonce-61:tok-one:111`'*) r=workers ;; *) r="[$out]" ;; esac
check '21. a doc with both lines renders from workers: (it wins)' workers "$r"
check '21. a doc with both lines digests the workers: line' 'workers: `N61:nonce-61:tok-one:111`' "$(bash "$SCRIPT" "$wk" --digest 2>/dev/null | grep '^workers:')"
printf '# c\n\n## Live state\n\nlegs: `N61:nonce-61:tok-one:111`\nqueue: none\n\n## Results\n' > "$wk"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61","added":"x"}]}\n' "$d1" > "$wm"
HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" "$wk" --print >/dev/null 2>&1; rc=$?
check '21. with HIMMEL_LEGACY_NAMES=0 an old legs manifest is refused' 1 "$rc"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N61","added":"x"}]}\n' "$d1" > "$wm"
HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" "$wk" --print >/dev/null 2>&1; rc=$?
check '21. with HIMMEL_LEGACY_NAMES=0 an old legs: line is not read' 1 "$rc"

# 22. M1b: the render writes ONE `workers:` line and REPLACES an old `legs:` block in place
#     (wrapped continuation lines included), entries and prose unchanged, `lockless:` right after.
printf '{"schema":1,"workers":[{"doc":"%s","label":"N61","added":"x"}]}\n' "$d1" > "$wm"
printf '# c\n\n## Live state\n\nhead: abc\nlegs: `N61:nonce-61:tok-one:111` note a\n  wrapped prose b\nqueue: none\n\n## Results\n' > "$wk"
bash "$SCRIPT" "$wk" >/dev/null 2>&1; rc=$?
check '22. an old legs: block renders (rc 0)' 0 "$rc"
check '22. no legs: line is left' 0 "$(grep -c '^legs:' "$wk")"
check '22. exactly one workers: line' 1 "$(grep -c '^workers:' "$wk")"
check '22. its entries and prose are unchanged, the wrapped lines joined' 'workers: `N61:nonce-61:tok-one:111` note a wrapped prose b' "$(grep '^workers:' "$wk")"
check '22. it sits where the legs: block was, between head: and queue:' 'head: abc|workers: `N61:nonce-61:tok-one:111` note a wrapped prose b|queue: none' "$(sed -n '/^head:/,/^queue:/p' "$wk" | paste -sd'|')"
out="$(bash "$SCRIPT" "$wk" --print 2>/dev/null)"
check '22. --print on that doc says workers:' 'workers: `N61:nonce-61:tok-one:111` note a wrapped prose b' "$out"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$wk"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61","added":"x"}]}\n' "$d1" > "$wm"
bash "$SCRIPT" "$wk" --nonce N61=n22 --pid N61=22 >/dev/null 2>&1; rc=$?
check '22. an old legs: doc over an old legs manifest renders (rc 0)' 0 "$rc"
check '22. and writes workers:, not legs:' 'workers: `N61:n22:tok-one:22`|0' "$(grep '^workers:' "$wk")|$(grep -c '^legs:' "$wk")"

# 23. A render that picked `legs:` before another render replaced it with `workers:` re-reads the
#     key under the doc lock and still writes. The parent holds the doc lock, starts the render,
#     waits until it is blocked in flock (a bounded poll, so its key was picked), then writes the
#     first renderer's doc with a STALE token and a STALE lockless value: only the second render
#     can correct them, so a render that does nothing fails the exact assertions below.
# shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
. "$HERE/worker-doc-lock.sh"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N61","added":"x"},{"doc":"%s","label":"N70","lane":"eval","lockless":true,"added":"x"}]}\n' "$d1" "$d2" > "$wm"
want_workers='workers: `N61:nonce-61:tok-one:111` first'
want_lockless="lockless: N70 (eval) $d2"
printf '# c\n\n## Live state\n\nlegs: `N61:nonce-61:stale-tok:111` first\nqueue: none\n\n## Results\n' > "$wk"
lock_rc=0; doc_lock "$wk" test-live-state || lock_rc=$?
check '23. setup: the test holds the doc lock' 0 "$lock_rc"
bash "$SCRIPT" "$wk" 9>&- >/dev/null 2>&1 &
race_pid=$!
ready=no
for _ in $(seq 1 100); do
    if pgrep -P "$race_pid" -x flock >/dev/null 2>&1; then ready=yes; break; fi
    kill -0 "$race_pid" 2>/dev/null || break
    sleep 0.1
done
check '23. setup: the render is blocked on the doc lock before the doc changes' yes "$ready"
printf '# c\n\n## Live state\n\nworkers: `N61:nonce-61:stale-tok:111` first\nlockless: N70 (eval) stale-doc\nqueue: none\n\n## Results\n' > "$wk"
doc_unlock
wait "$race_pid"; rc=$?
check '23. the render that lost the legs: to workers: race exits 0' 0 "$rc"
check '23. it corrects the stale token on the workers: line' "$want_workers" "$(grep '^workers:' "$wk")"
check '23. it corrects the stale lockless: line' "$want_lockless" "$(grep '^lockless:' "$wk")"
check '23. it leaves no legs: line' 0 "$(grep -c '^legs:' "$wk")"

# 24. The key can also flip between the pick and the read of the block (a stub jq flips the doc on
#     the manifest read, which runs between the two): the render restarts instead of refusing an
#     empty block.
mkdir -p "$tmp/flipbin"
printf '# c\n\n## Live state\n\nworkers: `N61:nonce-61:stale-tok:111` first\nqueue: none\n\n## Results\n' > "$tmp/flip-src.md"
printf '#!/usr/bin/env bash\nif [ -f %q ]; then cp %q %q; rm -f %q; fi\nexec %q "$@"\n' "$tmp/flip-src.md" "$tmp/flip-src.md" "$wk" "$tmp/flip-src.md" "$(command -v jq)" > "$tmp/flipbin/jq"
chmod +x "$tmp/flipbin/jq"
printf '# c\n\n## Live state\n\nlegs: `N61:nonce-61:stale-tok:111` first\nqueue: none\n\n## Results\n' > "$wk"
PATH="$tmp/flipbin:$PATH" bash "$SCRIPT" "$wk" >/dev/null 2>"$tmp/flip-err"; rc=$?
check '24. a key that flips before the block is read does not refuse (rc 0)' 0 "$rc"
check '24. it renders the corrected workers: line' "$want_workers" "$(grep '^workers:' "$wk")"
check '24. it renders the lockless: line' "$want_lockless" "$(grep '^lockless:' "$wk")"
check '24. it leaves no legs: line and no refusal text' '0 0' "$(grep -c '^legs:' "$wk") $(grep -c 'no workers: line' "$tmp/flip-err")"

# 25. A hyphenated labelled Live state line directly under the workers: line stays its
#     own line. The pool-disposition text is the chief template's real seed (the backtick span in its
#     Standing rules), not a typed line; wrapped prose under workers: is still carried.
seed25="$(sed -n 's/.*`\(pool-disposition: <KEY>[^`]*\)`.*/\1/p' "$HERE/../../../docs/handover/chief-template.md" | head -1)"
check '25. setup: the template seeds a pool-disposition line' 'pool-disposition: <KEY> slice|close|question <named target>' "$seed25"
hy="$HANDOVER_DIR/b/HIMMEL-nextleg-HY-chief.md"
printf '# c\n\n## Live state\n\nworkers: `N61:nonce-61:tok-one:111` note a\n  wrapped prose b\n%s\ntracker-plan: some/dir\nqueue: none\n\n## Results\n' "$seed25" > "$hy"
bash "$FM" add "${hy%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$hy" >/dev/null 2>&1; rc=$?
check '25. the render succeeds' 0 "$rc"
check '25. the workers: line is the entries and the wrapped prose only' 'workers: `N61:nonce-61:tok-one:111` note a wrapped prose b' "$(grep '^workers:' "$hy")"
check '25. the pool-disposition line is still its own line, unchanged' "$seed25" "$(grep '^pool-disposition:' "$hy")"
check '25. the tracker-plan line is still its own line, unchanged' 'tracker-plan: some/dir' "$(grep '^tracker-plan:' "$hy")"
check '25. the lines keep their order' 'workers|pool-disposition|tracker-plan|queue' "$(sed -n '/^## Live state/,/^## Results/p' "$hy" | grep -oE '^(workers|pool-disposition|tracker-plan|queue)' | paste -sd'|')"
out25="$(bash "$SCRIPT" "$hy" --print 2>/dev/null)"
check '25. --print prints the workers: line without the next labelled line' 'workers: `N61:nonce-61:tok-one:111` note a wrapped prose b' "$out25"
check '25. --digest ends the workers line at the pool-disposition line' 'workers: `N61:nonce-61:tok-one:111` note a wrapped prose b' "$(bash "$SCRIPT" "$hy" --digest 2>/dev/null | grep '^workers:')"

# 26. A `pool-disposition: <KEY> question|slice after <KEY2>` line, both keys open, writes ONE
#     `link <KEY2> --blocks <KEY>` call when the link is absent; a second render makes none; a key
#     that is not open, a link already there or --print makes none. The Jira CLI is a stub
#     that records every call; a link it makes shows in its next `links` read.
js="$tmp/jira-stub"; jdb="$tmp/jira-db"; mkdir -p "$jdb"; : > "$jdb/calls"
cat > "$js" <<'STUB'
#!/usr/bin/env bash
db="${JIRA_STUB_DB:?}"
printf '%s\n' "$*" >> "$db/calls"
case "$1" in
    get) st="$(cat "$db/status-$2" 2>/dev/null)" || exit 1; printf '%s\tTask\t%s\ttitle of %s\n' "$2" "$st" "$2" ;;
    links) cat "$db/links" 2>/dev/null | grep -F "$2" || true ;;
    link) [ "$3" = --blocks ] || exit 2; printf '9%s\tBlocks\tinward=%s\toutward=%s\t%s blocks %s\n' "$RANDOM" "$2" "$4" "$2" "$4" >> "$db/links"; echo "Linked: $2 blocks $4" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$js"
mkdir -p "$tmp/t26"
export LIVE_STATE_JIRA_CMD="$js" JIRA_STUB_DB="$jdb" TMPDIR="$tmp/t26"
af="$HANDOVER_DIR/b/HIMMEL-nextleg-AF-chief.md"
af_doc() { { printf '# c\n\n## Live state\n\nworkers: `N61:nonce-61:tok-one:111`\n'; printf '%s\n' "$@"; printf 'queue: none\n\n## Results\n'; } > "$af"; }
link_calls() { grep -c '^link ' "$jdb/calls" 2>/dev/null || true; }
bash "$FM" add "${af%.md}.fleet.json" --lane native "$d1" >/dev/null 2>&1
echo 'To Do' > "$jdb/status-HIMMEL-1"; echo 'In Progress' > "$jdb/status-HIMMEL-2"
af_doc 'pool-disposition: HIMMEL-2 question after HIMMEL-1'
bash "$SCRIPT" "$af" --print >/dev/null 2>&1
check '26. --print makes no link call' 0 "$(link_calls)"
af_err="$(bash "$SCRIPT" "$af" 2>&1 >/dev/null)"; rc=$?
check '26. the render succeeds' 0 "$rc"
check '26. one link call, HIMMEL-1 blocks HIMMEL-2' 'link HIMMEL-1 --blocks HIMMEL-2' "$(grep '^link ' "$jdb/calls" 2>/dev/null)"
case "$af_err" in *'linked HIMMEL-1 blocks HIMMEL-2'*) r=logged ;; *) r="[$af_err]" ;; esac
check '26. the link is logged' logged "$r"
check '26. the pool-disposition line is unchanged' 'pool-disposition: HIMMEL-2 question after HIMMEL-1' "$(grep '^pool-disposition:' "$af")"
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a second render makes no second link call' 1 "$(link_calls)"
: > "$jdb/calls"; : > "$jdb/links"; rm -rf "$TMPDIR"/himmel-chain-links-*
echo 'Done' > "$jdb/status-HIMMEL-1"
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a blocker that is not open makes no link call' 0 "$(link_calls)"
echo 'To Do' > "$jdb/status-HIMMEL-1"; echo 'Closed' > "$jdb/status-HIMMEL-2"
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a waiting key that is not open makes no link call' 0 "$(link_calls)"
echo 'To Do' > "$jdb/status-HIMMEL-2"
printf '1\tBlocks\tinward=HIMMEL-1\toutward=HIMMEL-2\tHIMMEL-1 blocks HIMMEL-2\n' > "$jdb/links"
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a link already in Jira makes no link call' 0 "$(link_calls)"
: > "$jdb/links"; rm -rf "$TMPDIR"/himmel-chain-links-*
af_doc 'pool-disposition: HIMMEL-2 slice after HIMMEL-1 (its spec lands first)'
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a slice after line with a reason writes its link too' 'link HIMMEL-1 --blocks HIMMEL-2' "$(grep '^link ' "$jdb/calls" 2>/dev/null)"
: > "$jdb/calls"; : > "$jdb/links"; rm -rf "$TMPDIR"/himmel-chain-links-*
af_doc 'pool-disposition: HIMMEL-2 close after HIMMEL-1'
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. a close disposition makes no call at all' 0 "$(wc -l < "$jdb/calls" | tr -d ' ')"
echo 'To Do' > "$jdb/status-HIMMEL-3"
af_doc 'pool-disposition: HIMMEL-2 question after HIMMEL-1' 'pool-disposition: HIMMEL-3 slice after HIMMEL-1'
bash "$SCRIPT" "$af" >/dev/null 2>&1
check '26. two after lines write a link each' 'link HIMMEL-1 --blocks HIMMEL-2|link HIMMEL-1 --blocks HIMMEL-3' "$(grep '^link ' "$jdb/calls" | paste -sd'|')"
unset LIVE_STATE_JIRA_CMD JIRA_STUB_DB TMPDIR

[ "$t1" = tok-one ] || { echo "FAIL - setup: lock token [$t1]"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
