#!/usr/bin/env bash
# test-librarian.sh — hermetic: a scratch handover root that is its own git repo,
# a scratch Jira mirror and a scratch sessions dir. Never touches the live vault.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/handover/librarian.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t librarian.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# age <days> <file...>: set mtime N days back (portable: touch -t from python)
age() {
  local d="$1" stamp; shift
  stamp="$(python3 -I -c 'import sys,time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time()-int(sys.argv[1])*86400)))' "$d")"
  touch -t "$stamp" "$@"
}
ym() { python3 -I -c 'import sys,time; print(time.strftime("%Y-%m", time.localtime(time.time()-int(sys.argv[1])*86400)))' "$1"; }
here() { [ -e "$1" ] && echo yes || echo no; }

R="$W/handovers"; B="$R/u/himmel"; MIR="$W/mirror"; SES="$W/sessions"
mkdir -p "$B/specs/plans" "$R/.locks/queue" "$MIR" "$SES/_archive"
mirror() { printf -- '---\nkey: "%s"\nstatus: "%s"\nstatusCategory: "%s"\n---\n' "$1" "$2" "$3" > "$MIR/$1.md"; }
mirror HIMMEL-1 Done Done; mirror HIMMEL-2 Done Done; mirror HIMMEL-3 Done Done
mirror HIMMEL-4 Done Done; mirror HIMMEL-5 "In Progress" "In Progress"; mirror HIMMEL-6 "Won't Do" Done
leg() {  # leg <file> <tail marker> <age days>
  printf '# t\n\n## Results\n\n- 10:00 LIVE — x\n- 10:05 %s — y\n' "$2" > "$B/$1"; age "$3" "$B/$1"
}

leg HIMMEL-1-old-wrapped-2026-01-01.md WRAPPED 60
printf '# resume\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md"
printf '# j\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md"
printf 'log\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01.launch.log"; age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01.launch.log"
leg HIMMEL-2-locked-2026-01-01.md WRAPPED 60
mkdir -p "$R/.locks/queue/u__himmel__HIMMEL-2-locked-2026-01-01.lock"
printf '# resume\n' > "$B/HIMMEL-2-locked-2026-01-01-RESUME.md"; age 60 "$B/HIMMEL-2-locked-2026-01-01-RESUME.md"
leg HIMMEL-3-young-2026-10-20.md WRAPPED 3
leg HIMMEL-4-done-no-wrapped-2026-01-01.md LIVE 60
leg HIMMEL-5-open-no-wrapped-2026-01-01.md LIVE 60
leg HIMMEL-6-wontdo-no-wrapped-2026-01-01.md BLOCKED 60
leg HIMMEL-7-mid-aged-2026-01-01.md WRAPPED 20
leg HIMMEL-8-halted-2026-01-01.md HALTED 60
leg HIMMEL-nextleg-2026-01-01-console.md WRAPPED 60
printf '# plan\n' > "$B/specs/plans/p.md"; age 90 "$B/specs/plans/p.md"
printf '{}\n' > "$R/arms.jsonl"; age 90 "$R/arms.jsonl"
printf '{}\n' > "$R/admissions-ledger.jsonl"; age 90 "$R/admissions-ledger.jsonl"
printf '# s\n' > "$R/auto-arm-status-old.md"; age 30 "$R/auto-arm-status-old.md"
printf '# s\n' > "$R/auto-arm-status-new.md"; age 2 "$R/auto-arm-status-new.md"
printf '# s\n' > "$SES/old-session.md"; age 60 "$SES/old-session.md"
printf '# s\n' > "$SES/new-session.md"; age 5 "$SES/new-session.md"
printf '# s\n' > "$SES/_archive/already.md"; age 400 "$SES/_archive/already.md"
printf '# live\n' > "$B/HIMMEL-9-live-2026-10-22.md"; age 1 "$B/HIMMEL-9-live-2026-10-22.md"
# links: the old doc points at a live doc and at its own RESUME; a live doc points back at the old doc
printf '# t\n\n- 10:05 WRAPPED — [live](HIMMEL-9-live-2026-10-22.md) [r](HIMMEL-1-old-wrapped-2026-01-01-RESUME.md) [web](https://x.test/a.md) [wiki]([[n]])\n' > "$B/HIMMEL-1-old-wrapped-2026-01-01.md"
age 60 "$B/HIMMEL-1-old-wrapped-2026-01-01.md"
printf '# live\n\nsee [old](HIMMEL-1-old-wrapped-2026-01-01.md) and [q](HIMMEL-1-old-wrapped-2026-01-01.md?plain=1#top)\n' > "$B/HIMMEL-9-live-2026-10-22.md"; age 1 "$B/HIMMEL-9-live-2026-10-22.md"

git -C "$R" init -q . && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SES" init -q . && git -C "$SES" add -A && git -C "$SES" -c user.email=t@t -c user.name=t commit -q -m seed
HEAD0="$(git -C "$R" rev-parse HEAD)"

run() { bash "$SUT" --root "$R" --bucket "$B" --sessions-dir "$SES" --mirror "$MIR" "$@"; }
M60="$(ym 60)"; M30="$(ym 30)"; A="$B/archive/$M60"

# --- RED: today nothing moves (the script does not exist yet) ----------------
[ -f "$SUT" ] || { check "RED: librarian.sh exists" yes no; echo "pass=$PASS fail=$FAIL"; exit 1; }

# --- dry run is the default and changes nothing -------------------------------
out="$(run 2>&1)"; check "default run exits 0" 0 "$?"
check "default run is a dry run" yes "$(grep -q 'dry-run' <<< "$out" && echo yes || echo no)"
check "dry run lists the wrapped doc as a move" yes "$(grep -q '^MOVE .*HIMMEL-1-old-wrapped' <<< "$out" && echo yes || echo no)"
check "dry run names the locked doc as skipped" yes "$(grep -q '^SKIP locked .*HIMMEL-2-locked' <<< "$out" && echo yes || echo no)"
check "dry run moves nothing" "$HEAD0" "$(git -C "$R" rev-parse HEAD)"
check "dry run leaves the tree clean" "" "$(git -C "$R" status --porcelain)"
check "dry run creates no archive dir" no "$(here "$B/archive")"
out2="$(run --dry-run 2>&1)"; check "explicit --dry-run matches the default" "$out" "$out2"

# --- apply --------------------------------------------------------------------
run --apply >/dev/null 2>&1; check "apply exits 0" 0 "$?"
check "wrapped old doc moved" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01.md")"
check "wrapped old doc left the bucket root" no "$(here "$B/HIMMEL-1-old-wrapped-2026-01-01.md")"
check "RESUME sibling travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01-RESUME.md")"
check "judge sibling travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01-judge-J1.md")"
check "side file (launch.log) travelled" yes "$(here "$A/HIMMEL-1-old-wrapped-2026-01-01.launch.log")"
check "HALTED old doc moved" yes "$(here "$A/HIMMEL-8-halted-2026-01-01.md")"
check "Done ticket without WRAPPED moved" yes "$(here "$A/HIMMEL-4-done-no-wrapped-2026-01-01.md")"
check "locked doc stayed" yes "$(here "$B/HIMMEL-2-locked-2026-01-01.md")"
check "an old RESUME of a locked doc stayed with its parent" yes "$(here "$B/HIMMEL-2-locked-2026-01-01-RESUME.md")"
check "young doc stayed" yes "$(here "$B/HIMMEL-3-young-2026-10-20.md")"
check "doc 20 days old stayed under the 30 day default" yes "$(here "$B/HIMMEL-7-mid-aged-2026-01-01.md")"
check "open ticket without WRAPPED stayed" yes "$(here "$B/HIMMEL-5-open-no-wrapped-2026-01-01.md")"
check "BLOCKED tail with a Won't Do ticket moved" yes "$(here "$A/HIMMEL-6-wontdo-no-wrapped-2026-01-01.md")"
check "console doc stayed" yes "$(here "$B/HIMMEL-nextleg-2026-01-01-console.md")"
check "specs tree untouched" yes "$(here "$B/specs/plans/p.md")"
check "arms.jsonl untouched" yes "$(here "$R/arms.jsonl")"
check "admissions-ledger.jsonl untouched" yes "$(here "$R/admissions-ledger.jsonl")"
check "old auto-arm-status moved" yes "$(here "$R/archive/auto-arm-status/$M30/auto-arm-status-old.md")"
check "young auto-arm-status stayed" yes "$(here "$R/auto-arm-status-new.md")"
check "old session moved" yes "$(here "$SES/_archive/$M60/old-session.md")"
check "young session stayed" yes "$(here "$SES/new-session.md")"
check "old _archive session untouched" yes "$(here "$SES/_archive/already.md")"

# --- index: one line per moved doc --------------------------------------------
IDX="$A/_index.md"
check "index file written" yes "$(here "$IDX")"
check "one index line per moved doc in the month (5 files of HIMMEL-1 group + 8, 4, 6 = 7)" 7 "$(grep -c '^- ' "$IDX")"
check "index line names the doc" yes "$(grep -q 'HIMMEL-1-old-wrapped-2026-01-01.md' "$IDX" && echo yes || echo no)"
check "index line carries the ticket" yes "$(grep -q 'HIMMEL-4' "$IDX" && echo yes || echo no)"

# --- git mv, not rm -----------------------------------------------------------
check "moves are staged renames (7 bucket + 1 auto-arm)" 8 "$(git -C "$R" status --porcelain | grep -c '^R')"
check "no deletion" 0 "$(git -C "$R" status --porcelain | grep -c '^ \?D')"
check "session move is a staged rename" 1 "$(git -C "$SES" status --porcelain | grep -c '^R')"

# --- links --------------------------------------------------------------------
check "moved doc's link to a live doc rewritten" yes "$(grep -q '](../../HIMMEL-9-live-2026-10-22.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "moved doc's link to its moved sibling kept" yes "$(grep -q '](HIMMEL-1-old-wrapped-2026-01-01-RESUME.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "web link left alone" yes "$(grep -q '](https://x.test/a.md)' "$A/HIMMEL-1-old-wrapped-2026-01-01.md" && echo yes || echo no)"
check "live doc's link to the moved doc rewritten" yes "$(grep -q "](archive/$M60/HIMMEL-1-old-wrapped-2026-01-01.md)" "$B/HIMMEL-9-live-2026-10-22.md" && echo yes || echo no)"
check "a link with a query and fragment keeps both" yes "$(grep -q "](archive/$M60/HIMMEL-1-old-wrapped-2026-01-01.md?plain=1#top)" "$B/HIMMEL-9-live-2026-10-22.md" && echo yes || echo no)"

# --- idempotence --------------------------------------------------------------
before="$(git -C "$R" status --porcelain | sort | tr '\n' ' ')"
out3="$(run --apply 2>&1)"; check "second apply exits 0" 0 "$?"
check "second apply moves nothing" "$before" "$(git -C "$R" status --porcelain | sort | tr '\n' ' ')"
check "second apply adds no index line" 7 "$(grep -c '^- ' "$IDX")"
check "second apply reports zero moves" yes "$(grep -q 'moved=0' <<< "$out3" && echo yes || echo no)"

# --- an existing destination is never overwritten -----------------------------
leg HIMMEL-1-clash-2026-01-01.md WRAPPED 60; mkdir -p "$A"; printf 'keep\n' > "$A/HIMMEL-1-clash-2026-01-01.md"
git -C "$R" add -A; run --apply >/dev/null 2>&1
check "clash: destination kept" keep "$(head -1 "$A/HIMMEL-1-clash-2026-01-01.md")"
check "clash: source stayed" yes "$(here "$B/HIMMEL-1-clash-2026-01-01.md")"

# --- a failed move leaves every link pointing where the doc still is ----------
NOROOT=0; [ "$(id -u)" -ne 0 ] && NOROOT=1   # root ignores directory permission bits, so the chmod cases need a normal user
if [ "$NOROOT" = 1 ]; then
leg HIMMEL-1-failmv-2026-01-01.md WRAPPED 60
printf 'see [f](HIMMEL-1-failmv-2026-01-01.md)\n' >> "$B/HIMMEL-9-live-2026-10-22.md"
git -C "$R" add -A; chmod 555 "$A"
run --apply >/dev/null 2>&1; check "failed move exits 1" 1 "$?"
chmod 755 "$A"
check "failed move: doc stayed" yes "$(here "$B/HIMMEL-1-failmv-2026-01-01.md")"
check "failed move: referrer link untouched" yes "$(grep -q '](HIMMEL-1-failmv-2026-01-01.md)' "$B/HIMMEL-9-live-2026-10-22.md" && echo yes || echo no)"
fi

# --- a held lock also protects an aged auto-arm-status note --------------------
printf '# s\n' > "$R/auto-arm-status-held.md"; age 30 "$R/auto-arm-status-held.md"
mkdir -p "$R/.locks/queue/auto-arm-status-held.lock"; git -C "$R" add -A
out5="$(run --apply 2>&1)"
check "a locked auto-arm-status note stayed" yes "$(here "$R/auto-arm-status-held.md")"
check "and was reported as locked" yes "$(grep -q '^SKIP locked .*auto-arm-status-held' <<< "$out5" && echo yes || echo no)"

# --- a failed move of one member puts the group's earlier members back ---------
leg HIMMEL-1-grp-2026-01-01.md WRAPPED 60
printf '# r\n' > "$B/HIMMEL-1-grp-2026-01-01-RESUME.md"; age 60 "$B/HIMMEL-1-grp-2026-01-01-RESUME.md"
git -C "$R" add -A
mkdir -p "$W/stubbin"; REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\ncase "$*" in *"mv -- HIMMEL-1-grp-2026-01-01.md "*) echo "stub: refused" >&2; exit 1 ;; esac\nexec %q "$@"\n' "$REAL_GIT" > "$W/stubbin/git"
chmod +x "$W/stubbin/git"
PATH="$W/stubbin:$PATH" run --apply >/dev/null 2>&1; check "a failed group member exits 1" 1 "$?"
check "the group's primary stayed" yes "$(here "$B/HIMMEL-1-grp-2026-01-01.md")"
check "its already-moved RESUME is back in the bucket" yes "$(here "$B/HIMMEL-1-grp-2026-01-01-RESUME.md")"
check "nothing of the group sits in the archive or the index" 0 "$(grep -rc 'HIMMEL-1-grp' "$A" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
check "and git shows no rename for the group" 0 "$(git -C "$R" status --porcelain | grep -c 'grp.*->')"
run --apply >/dev/null 2>&1; check "the next clean run moves the group whole" 2 "$(find "$A" -name 'HIMMEL-1-grp*' | wc -l | tr -d ' ')"

# --- a doc whose own move failed still has its links to moved docs rewritten ---
A100="$B/archive/$(ym 100)"; printf 'not a dir\n' > "$A100"   # a file where the month directory belongs: mkdir fails for any user
leg HIMMEL-1-lnkB-2026-01-01.md WRAPPED 60
leg HIMMEL-1-lnkA-2026-01-01.md WRAPPED 100
printf 'see [b](HIMMEL-1-lnkB-2026-01-01.md)\n' >> "$B/HIMMEL-1-lnkA-2026-01-01.md"; age 100 "$B/HIMMEL-1-lnkA-2026-01-01.md"
git -C "$R" add -A
out6="$(run --apply 2>&1)"; check "a split batch exits 1" 1 "$?"
check "a failed mkdir is reported, not a traceback" 0 "$(grep -c 'Traceback' <<< "$out6")"
check "and named as a mkdir failure" yes "$(grep -q '^FAIL mkdir ' <<< "$out6" && echo yes || echo no)"
rm -f "$A100"
check "the failed doc stayed" yes "$(here "$B/HIMMEL-1-lnkA-2026-01-01.md")"
check "its sibling in the writable month moved" yes "$(here "$A/HIMMEL-1-lnkB-2026-01-01.md")"
check "and the stayer now links to the moved doc's new place" yes \
  "$(grep -q "](archive/$M60/HIMMEL-1-lnkB-2026-01-01.md)" "$B/HIMMEL-1-lnkA-2026-01-01.md" && echo yes || echo no)"

# --- a dot-suffixed sibling follows its parent group; console docs and encoded links ---
leg HIMMEL-2-locked-2026-01-01.extra.md WRAPPED 60
leg HIMMEL-1-cref-2026-01-01.md WRAPPED 60
printf 'see [c](HIMMEL-1-cref-2026-01-01.md)\n' >> "$B/HIMMEL-nextleg-2026-01-01-console.md"; age 60 "$B/HIMMEL-nextleg-2026-01-01-console.md"
leg "HIMMEL-1-sp ace-2026-01-01.md" WRAPPED 60
printf 'see [s](HIMMEL-1-sp%%20ace-2026-01-01.md)\n' >> "$B/HIMMEL-9-live-2026-10-22.md"
git -C "$R" add -A; run --apply >/dev/null 2>&1
check "a sibling of a locked parent stayed" yes "$(here "$B/HIMMEL-2-locked-2026-01-01.extra.md")"
check "a console doc's links are not rewritten" yes "$(grep -q '](HIMMEL-1-cref-2026-01-01.md)' "$B/HIMMEL-nextleg-2026-01-01-console.md" && echo yes || echo no)"
check "the doc moved" yes "$(here "$A/HIMMEL-1-cref-2026-01-01.md")"
check "a percent-encoded link to a moved doc is rewritten, encoding kept" yes \
  "$(grep -q "](archive/$M60/HIMMEL-1-sp%20ace-2026-01-01.md)" "$B/HIMMEL-9-live-2026-10-22.md" && echo yes || echo no)"

# --- a lock taken after planning is honoured at move time ----------------------
leg HIMMEL-1-race1-2026-01-01.md WRAPPED 60
leg HIMMEL-1-race2-2026-01-01.md WRAPPED 60
git -C "$R" add -A
# shellcheck disable=SC2016  # the stub keeps its $rc literal
printf '#!/usr/bin/env bash\n%q "$@"; rc=$?\ncase "$*" in *"mv -- HIMMEL-1-race1-2026-01-01.md "*) mkdir -p "%s/u__himmel__HIMMEL-1-race2-2026-01-01.lock" ;; esac\nexit $rc\n' "$REAL_GIT" "$R/.locks/queue" > "$W/stubbin/git"
PATH="$W/stubbin:$PATH" run --apply >/dev/null 2>&1; check "a late lock is a skip, not a failure (exit 0)" 0 "$?"
check "the doc planned first moved" yes "$(here "$A/HIMMEL-1-race1-2026-01-01.md")"
check "the doc locked after planning stayed" yes "$(here "$B/HIMMEL-1-race2-2026-01-01.md")"

# --- untracked doc is skipped, never plain-mv'd -------------------------------
leg HIMMEL-1-untracked-2026-01-01.md WRAPPED 60
out4="$(run --apply 2>&1)"
check "untracked doc stayed" yes "$(here "$B/HIMMEL-1-untracked-2026-01-01.md")"
check "untracked doc reported" yes "$(grep -q '^SKIP untracked .*HIMMEL-1-untracked' <<< "$out4" && echo yes || echo no)"

# --- the opt-in cited-key gate --------------------------------------------------
leg HIMMEL-31-cited-2026-01-01.md WRAPPED 60
leg HIMMEL-32-uncited-2026-01-01.md WRAPPED 60
leg HIMMEL-33-nearmiss-2026-01-01.md WRAPPED 60
leg HIMMEL-34-suffixed-2026-01-01.md WRAPPED 60
leg HIMMEL-35-prefixed-2026-01-01.md WRAPPED 60
CIT="$W/compounded"; mkdir -p "$CIT/themes"
printf '# week\n\n## HIMMEL-31\n- outcome: merged\n\nalso HIMMEL-331 and HIMMEL-3 and HIMMEL-34suffix and foo_HIMMEL-35\n' > "$CIT/2026-W43.md"
git -C "$R" add -A
out7="$(run 2>&1)"
check "gate off by default: an uncited doc is a move" yes "$(grep -q '^MOVE .*HIMMEL-32-uncited' <<< "$out7" && echo yes || echo no)"
out8="$(run --require-cited "$CIT" 2>&1)"; check "gated dry run exits 0" 0 "$?"
check "gated: a cited key's doc is a move" yes "$(grep -q '^MOVE .*HIMMEL-31-cited' <<< "$out8" && echo yes || echo no)"
check "gated: an uncited key's doc is skipped and named" yes "$(grep -q '^SKIP uncited .*HIMMEL-32-uncited' <<< "$out8" && echo yes || echo no)"
check "gated: a key that is only a prefix of a cited one (HIMMEL-33 vs HIMMEL-331) is uncited" yes "$(grep -q '^SKIP uncited .*HIMMEL-33-nearmiss' <<< "$out8" && echo yes || echo no)"
check "gated: a key followed by letters (HIMMEL-34suffix) is not a citation of HIMMEL-34" yes "$(grep -q '^SKIP uncited .*HIMMEL-34-suffixed' <<< "$out8" && echo yes || echo no)"
check "gated: a key after an underscore (foo_HIMMEL-35) is not a citation of HIMMEL-35" yes "$(grep -q '^SKIP uncited .*HIMMEL-35-prefixed' <<< "$out8" && echo yes || echo no)"
check "gated: the summary counts the uncited docs it skipped" yes "$(grep -q "uncited=$(grep -c '^SKIP uncited' <<< "$out8")[) ]" <<< "$out8" && echo yes || echo no)"
check "gated: the summary has no uncited field when the gate is off" no "$(grep -q 'uncited=' <<< "$out7" && echo yes || echo no)"
run --apply --require-cited "$CIT" >/dev/null 2>&1; check "gated apply exits 0" 0 "$?"
check "gated apply: the cited doc moved" yes "$(here "$A/HIMMEL-31-cited-2026-01-01.md")"
check "gated apply: the uncited doc stayed" yes "$(here "$B/HIMMEL-32-uncited-2026-01-01.md")"
printf '# theme\n\n- a lesson (HIMMEL-32)\n' > "$CIT/themes/t.md"
run --apply --require-cited "$CIT" >/dev/null 2>&1
check "once a theme note cites the key, the doc moves" yes "$(here "$A/HIMMEL-32-uncited-2026-01-01.md")"
check "a near-miss key still stays" yes "$(here "$B/HIMMEL-33-nearmiss-2026-01-01.md")"
bash "$SUT" --root "$R" --bucket "$B" --sessions-dir "$SES" --mirror "$MIR" --require-cited "$W/no-such-dir" >/dev/null 2>&1
check "a missing --require-cited dir exits 2" 2 "$?"

# --- usage --------------------------------------------------------------------
bash "$SUT" --root "$W/nope" --bucket "$B" >/dev/null 2>&1; check "missing root exits 2" 2 "$?"
bash "$SUT" --bogus >/dev/null 2>&1; check "unknown flag exits 2" 2 "$?"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
