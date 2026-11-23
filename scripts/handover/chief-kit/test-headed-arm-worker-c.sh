#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2154  # SC2015: A && B || C is intentional in check()/contains()/ends_with()/not_contains(), as in scripts/handover/test-headed-arm.sh; the rest: assigned in the sourced testlib
# scripts/handover/chief-kit/test-headed-arm-worker-c.sh - the third part of the
# headed-arm-worker.sh suite (see test-headed-arm-worker.sh for the four parts and
# testlib-headed-arm-worker.sh for what they share): sections 42 to 51 and 17r - a resume_cwd that
# names a missing worktree, the session uuid, folder pre-trust, the himmel-bus register and env scrub,
# the bus-idle-waker, the per-worker memory cap, registered adopter repos, Remote Control, the
# single-writer barrier, the hook-loading guard, the launch-refusal ledger, and the readiness
# launcher's render.
#
# Asserts (the numbers are this file's own section labels):
#   42. a doc whose resume_cwd names a worker worktree path that is not
#       an existing git worktree is refused with exit 2 (dry-run and real) and
#       the refusal prints the clean-garden create command; an existing
#       worktree, judge scratch and a doc with no resume_cwd launch unchanged.
#   47. a doc whose resume_cwd is a worktree of a repo in the handover
#       registry launches with that worktree as its cwd; an unregistered repo
#       and an explicit WORKER_SESSION_REPO launch as before.
#
# Platform guard: POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/testlib-headed-arm-worker.sh
. "$HERE/tests/testlib-headed-arm-worker.sh" || { printf 'FAIL - %s (tests/testlib-headed-arm-worker.sh missing, unreadable or failing to load)\n' "$(basename "$0")"; exit 1; }

# Row 48f reads the konsole env-record of a --lane claudex launch. This is that launch, the one section 16 of
# test-headed-arm-worker.sh asserts on, run here so the record exists in this part; a launch that left no record fails the part.
d16="$tmp/c16"; mk_launch_stubs "$d16" "PROJ-5555-worker"; mkdir -p "$tmp/repo16"
IMPL_GUARD_OK='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
HEADED_ARM_WORKER_CLAUDEX_BIN="$claudex_stub" \
KONSOLE_CMD="$d16/konsole" PGREP_CMD="$d16/pgrep" \
WORKER_SESSION_REPO="$tmp/repo16" HEADED_ARM_LOCK_DIR="$d16/locks" HEADED_ARM_PROC="$d16/proc" \
  bash "$SCRIPT" --lane claudex --no-profile "PROJ-5555-worker" "some/doc.md" "$d16/signal-never" "$PAST" "$d16/log" >/dev/null 2>&1 || true
wait_record "$d16" || true
[ -s "$d16/env-record" ] || { echo "FAIL - the --lane claudex launch that row 48f reads left no env-record"; fails=$((fails+1)); }
# What the earlier parts leave behind for the rows below (their definitions are in testlib-headed-arm-worker.sh).
haw_ready26_env
haw_consult_env
haw_fx_38
haw_fx_39
# the consult repo section 41 of test-headed-arm-worker-b.sh builds: the --dry-run --consult launches of the memory-cap rows run against it
mkdir -p "$tmp/repo41c/.claude" "$tmp/repo41c/docs"; : > "$tmp/repo41c/docs/in-repo-consult.md"

# --- 42. A doc whose resume_cwd names a worker worktree path
# (.../.claude/worktrees/<type>+<slug>) that is not an existing git worktree is
# refused with exit 2, on --dry-run and a real launch alike, and the refusal
# prints the exact create command. An existing worktree launches; a doc with no
# resume_cwd and a non-worktree scratch path (judge scratch) are unaffected.
repo42="$tmp/repo42"; mkdir -p "$repo42/.claude/worktrees"
git -C "$repo42" init -q
git -C "$repo42" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repo42" worktree add -q -b feat/worker-42 "$repo42/.claude/worktrees/feat+worker-42"
mkdir -p "$repo42/.claude/worktrees/fix+plain-dir"
dry42() { # <resume_cwd> -> sets rc42/out42
  printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$1" > "$tmp/c42-doc.md"
  rc42=0
  out42="$(bash "$SCRIPT" --dry-run --no-profile PROJ-42-worker "$tmp/c42-doc.md" /tmp/nosig 99999999999 "$tmp/c42.log" claude-sonnet-5 2>&1)" || rc42=$?
}
dry42 "$repo42/.claude/worktrees/feat+missing-42"
check "42a resume_cwd names a worktree that does not exist -> exit 2" "$rc42" "2"
contains "42a the refusal prints the create command" "$out42" "bash scripts/worktree.sh new feat/missing-42 --no-prune"
dry42 "$repo42/.claude/worktrees/fix+plain-dir"
check "42b an existing dir that is not a git worktree -> exit 2" "$rc42" "2"
contains "42b the refusal names the slug derived from the path" "$out42" "worktree.sh new fix/plain-dir --no-prune"
dry42 "$repo42/.claude/worktrees/feat+worker-42"
check "42c an existing git worktree launches (rc 0)" "$rc42" "0"
dry42 "$tmp/home39/.cache/himmel/verdicts/q1/scratch"
check "42d a non-worktree scratch resume_cwd is unaffected (rc 0)" "$rc42" "0"
printf -- '---\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' > "$tmp/c42-doc.md"
rc42=0; out42="$(bash "$SCRIPT" --dry-run --no-profile PROJ-42-worker "$tmp/c42-doc.md" /tmp/nosig 99999999999 "$tmp/c42.log" claude-sonnet-5 2>&1)" || rc42=$?
check "42e a doc with no resume_cwd is unaffected (rc 0)" "$rc42" "0"

h_origin="$tmp/h-origin.git"; git init -q --bare "$h_origin"
repoH="$tmp/repoH"; git clone -q "$h_origin" "$repoH" 2>/dev/null
git -C "$repoH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$repoH/scripts"; cp -R "$HERE/../../." "$repoH/scripts/"
git -C "$repoH" branch -q -M main
git -C "$repoH" push -q origin main
git -C "$repoH" branch -q feat/h-only-origin; git -C "$repoH" push -q origin feat/h-only-origin; git -C "$repoH" branch -q -D feat/h-only-origin
repoA="$tmp/repoA"; mkdir -p "$repoA/.claude/worktrees"; git -C "$repoA" init -q
repoU="$tmp/repoU"; mkdir -p "$repoU/scripts" "$repoU/.claude/worktrees"; git -C "$repoU" init -q
h_marker="$tmp/h-marker"
printf '#!/usr/bin/env bash\n: > "%s"\necho origin\n' "$h_marker" > "$repoU/scripts/worktree.sh"
reg_h="$tmp/reg-h.json"; printf '{"repos":{"repoH":{"path":"%s"},"repoA":{"path":"%s"}}}\n' "$repoH" "$repoA" > "$reg_h"
HANDOVER_REGISTRY="$reg_h" dry42 "$repoH/.claude/worktrees/feat+h-only-origin"
check "H1 a branch only on origin: refused (rc 2)" "$rc42" "2"
contains "H1 the hint names worktree.sh resume" "$out42" "bash scripts/worktree.sh resume feat/h-only-origin"
HANDOVER_REGISTRY="$reg_h" dry42 "$repoH/.claude/worktrees/feat+h-nowhere"
contains "H1.none a branch nowhere: the hint still names new" "$out42" "bash scripts/worktree.sh new feat/h-nowhere --no-prune"
HANDOVER_REGISTRY="$reg_h" dry42 "$repoU/.claude/worktrees/feat+h-unreg"
check "H1.unreg an unregistered repo: refused (rc 2)" "$rc42" "2"
contains "H1.unreg the hint is the old one" "$out42" "bash scripts/worktree.sh new feat/h-unreg --no-prune"
check "H1.unreg the repo's own scripts/worktree.sh was never run" "$([ -e "$h_marker" ] && echo ran || echo not-run)" "not-run"
git -C "$repoH" remote set-url origin "$tmp/h-no-such-origin.git"
HANDOVER_REGISTRY="$reg_h" dry42 "$repoH/.claude/worktrees/feat+h-only-origin"
contains "H1.unk origin unreachable: the hint names resume" "$out42" "bash scripts/worktree.sh resume feat/h-only-origin"
contains "H1.unk and says origin could not be reached" "$out42" "origin could not be reached"
git -C "$repoA" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repoA" branch -q feat/h-adopt
HANDOVER_REGISTRY="$reg_h" dry42 "$repoA/.claude/worktrees/feat+h-adopt"
contains "H1.adopt an adopter repo: the hint names _new-worktree.sh --resume" "$out42" "_new-worktree.sh feat/h-adopt --resume --no-install"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$repo42/.claude/worktrees/feat+missing-42" > "$tmp/c42-doc.md"
d42="$tmp/c42"; mk_launch_stubs "$d42" "PROJ-42-real"
rc=0
some_doc="$tmp/c42-doc.md" RUN_WORKER_ARGS='--no-profile' run_worker "$d42" "$repo42" "PROJ-42-real" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
check "42f a REAL launch with a missing worktree is refused (rc 2)" "$rc" "2"
if [ -e "$d42/env-record" ]; then
  echo "FAIL - 42f a refused launch must not reach the launcher"; fails=$((fails+1))
else
  echo "ok - 42f a refused launch never reaches the launcher"
fi

# --- 43. each real launch mints a session uuid, records it in the
# doc's front matter (session_ids:, appended on a relaunch) and hands it to the
# shim, which passes it to claude as --session-id.
uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
doc43="$tmp/PROJ-43-N43-sid-2026-10-07.md"
printf -- '---\ntemplate_version: 3\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n\n# body\n\n## Results\n- 10:00 LIVE body line\n' > "$doc43"
mkdir -p "$tmp/repo43"
body43="$(sed '1,/^---$/d' "$doc43" | sed '1,/^---$/d')"
for i in 1 2; do
  d43="$tmp/c43-$i"; mk_launch_stubs "$d43" "PROJ-43-leg$i"
  some_doc="$doc43" run_worker "$d43" "$tmp/repo43" "PROJ-43-leg$i" "claude-sonnet-5" >/dev/null 2>&1 || true
  wait_record "$d43" || true
done
sids43="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$doc43" | sed -n 's/^session_ids: *//p')"
check "43a two launches record two session ids" "$(printf '%s' "$sids43" | grep -oE "$uuid_re" | sort -u | wc -l | tr -d ' ')" "2"
check "43b the doc body is untouched" "$(sed '1,/^---$/d' "$doc43" | sed '1,/^---$/d')" "$body43"
check "43c the front matter still opens on line 1" "$(head -n 1 "$doc43")" "---"
sid43_2="$(printf '%s' "$sids43" | grep -oE "$uuid_re" | tail -n 1)"
contains "43d the second launch hands its own uuid to the shim" "$(cat "$tmp/c43-2/record" 2>/dev/null)" "WORKER_SESSION_ID=$sid43_2"
rec43="$(ll_line PROJ-43-leg2)"
contains "43d2 the launch record carries the minted session id beside profile and lane" "$rec43" " session_id=$sid43_2 "
contains "43d3 the same record names the profile and lane" "$rec43" "headed-arm-worker: profile=worker-impl lane=native "
check "43d4 the record still ends with the launch time" "$(printf '%s\n' "$rec43" | grep -Ec ' launched=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
nodoc43="$tmp/PROJ-43-N44-nofm.md"
printf '# no front matter\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n\n## Results\n- 10:00 LIVE x\n' > "$nodoc43"
nodoc43_body="$(cat "$nodoc43")"
d43n="$tmp/c43-n"; mk_launch_stubs "$d43n" "PROJ-43-nofm"
WORKER_SESSION_ID=11111111-1111-1111-1111-111111111111 some_doc="$nodoc43" run_worker "$d43n" "$tmp/repo43" "PROJ-43-nofm" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d43n" || true
check "43e0 the no-front-matter launch reached the launcher" "$([ -s "$d43n/record" ] && echo yes)" "yes"
not_contains "43e a doc without front matter gets no id, and an inherited one is scrubbed" "$(cat "$d43n/record" 2>/dev/null)" "WORKER_SESSION_ID="
check "43f a doc without front matter is left byte-identical" "$(cat "$nodoc43")" "$nodoc43_body"
not_contains "43f2 a launch that minted no id records none" "$(ll_line PROJ-43-nofm)" "session_id="
shim43="$tmp/shim43-claude"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$shim43"; chmod 755 "$shim43"
check "43g the shim passes WORKER_SESSION_ID as --session-id" \
  "$(WORKER_SESSION_CLAUDE_BIN="$shim43" WORKER_SESSION_ID=22222222-2222-2222-2222-222222222222 bash "$HERE/../../lanes/worker-claude-launcher.sh" -n x | head -n 2 | tr '\n' ' ')" \
  "--session-id 22222222-2222-2222-2222-222222222222 "
check "43h the shim adds nothing without a session id" \
  "$(env -u WORKER_SESSION_ID WORKER_SESSION_CLAUDE_BIN="$shim43" bash "$HERE/../../lanes/worker-claude-launcher.sh" -n x | tr '\n' ' ')" "-n x "
# A symlinked doc is never replaced by the temp file's mv (the link would
# become a plain copy): no id is recorded and the link survives.
lnk43t="$tmp/PROJ-43-N45-target.md"
printf -- '---\ntemplate_version: 3\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n\n# body\n\n## Results\n- 10:00 LIVE x\n' > "$lnk43t"
lnk43="$tmp/PROJ-43-N45-link.md"; ln -s "$lnk43t" "$lnk43"
d43l="$tmp/c43-l"; mk_launch_stubs "$d43l" "PROJ-43-link"
some_doc="$lnk43" run_worker "$d43l" "$tmp/repo43" "PROJ-43-link" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d43l" || true
check "43i0 the symlinked-doc launch reached the launcher" "$([ -s "$d43l/record" ] && echo yes)" "yes"
check "43i a symlinked doc stays a symlink" "$([ -L "$lnk43" ] && echo link)" "link"
check "43j a symlinked doc's target is left untouched" "$(grep -c '^session_ids:' "$lnk43t")" "0"
# The rewrite keeps the doc's mode (the temp file would otherwise take the umask).
mode43="$tmp/PROJ-43-N46-mode.md"
printf -- '---\ntemplate_version: 3\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n\n# body\n\n## Results\n- 10:00 LIVE x\n' > "$mode43"; chmod 600 "$mode43"
d43m="$tmp/c43-m"; mk_launch_stubs "$d43m" "PROJ-43-mode"
some_doc="$mode43" run_worker "$d43m" "$tmp/repo43" "PROJ-43-mode" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d43m" || true
check "43k0 the mode-doc launch recorded an id" "$(grep -c '^session_ids:' "$mode43")" "1"
check "43k the rewrite keeps the doc's mode" "$(stat -c %a "$mode43" 2>/dev/null || stat -f %Lp "$mode43")" "600"  # gnu-ok: BSD stat -f fallback on the same line

# --- 44. a real launch pre-accepts folder/hooks trust ------------
# The cwd of a chief-created worktree is trusted before konsole starts, on the
# lane's own config; a cwd outside the allowlist is left alone and still launches.
pt_home="$tmp/pt-home"; pt_primary="$tmp/pt-primary"
mkdir -p "$pt_home"
git init -q "$pt_primary"
git -C "$pt_primary" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$pt_primary/.claude/worktrees"
git -C "$pt_primary" worktree add -q -b pt-wt "$pt_primary/.claude/worktrees/pt-wt"
pt_key() { jq -r --arg k "$2" '.projects[$k].hasTrustDialogAccepted // "absent"' "$1" 2>/dev/null || echo "nofile"; }
d44="$tmp/c44"; mk_launch_stubs "$d44" "PROJ-44-pretrust"
check "44a before launch: no trust entry" "$(pt_key "$pt_home/.claude.json" "$pt_primary/.claude/worktrees/pt-wt")" "nofile"
rc=0
WORKER_SESSION_PRETRUST_HOME="$pt_home" RUN_WORKER_ARGS=--no-profile run_worker "$d44" "$pt_primary/.claude/worktrees/pt-wt" "PROJ-44-pretrust" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d44" || true
check "44b worktree launch: exit 0" "$rc" "0"
check "44c worktree launch: trust accepted after" "$(pt_key "$pt_home/.claude.json" "$pt_primary/.claude/worktrees/pt-wt")" "true"
d44b="$tmp/c44b"; mk_launch_stubs "$d44b" "PROJ-44-nopretrust"; mkdir -p "$tmp/repo44b"
rc=0
WORKER_SESSION_PRETRUST_HOME="$pt_home" RUN_WORKER_ARGS=--no-profile run_worker "$d44b" "$tmp/repo44b" "PROJ-44-nopretrust" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d44b" || true
check "44d out-of-allowlist cwd: launch still exits 0" "$rc" "0"
check "44e out-of-allowlist cwd: not trusted" "$([ "$(pt_key "$pt_home/.claude.json" "$tmp/repo44b")" = true ] && echo trusted || echo untrusted)" "untrusted"
# --dry-run never writes
rm -f "$pt_home/.claude.json"
WORKER_SESSION_PRETRUST_HOME="$pt_home" WORKER_SESSION_REPO="$pt_primary/.claude/worktrees/pt-wt" bash "$SCRIPT" --dry-run --no-profile PROJ-44-dry "$some_doc" "$tmp/sig44" "$PAST" "$tmp/log44" claude-sonnet-5 >/dev/null 2>&1 || true
check "44f --dry-run writes no config" "$([ -e "$pt_home/.claude.json" ] && echo yes || echo no)" "no"

# --- 45. himmel-bus register + env scrub --------------------------
# An opted-in profile (mcpServers lists himmel-bus) registers the worker on the REAL
# bus CLI before launch (peer file 0600, no secret in it) and hands the launched
# env exactly HIMMEL_BUS_NAME, whatever HIMMEL_BUS_* the caller preset or left in
# its ambient env. An opted-out profile registers nothing and carries no
# HIMMEL_BUS_* either; a failed register refuses the launch.
bus45="$tmp/c45"; mkdir -p "$bus45"
cat > "$bus45/headed" <<'HEADED_EOF'
#!/usr/bin/env bash
{
  printf 'LAUNCHER_ENV=%s\n' "${HEADED_ARM_LAUNCHER_ENV:-}"
  printf 'BUS_FLAG=%s\n' "${HEADED_ARM_BUS:-<unset>}"
  printf 'BUS_CLI=%s\n' "${HEADED_ARM_BUS_CLI:-<unset>}"
  printf 'AMBIENT=%s\n' "${HIMMEL_BUS_NAME:-<unset>}"
  printf 'EXTRA=%s\n' "${HIMMEL_BUS_EXTRA:-<unset>}"
  printf 'OVERRIDE=%s\n' "${HIMMEL_LAUNCH_UNBOUND_OK:-<unset>}"
} > "$(dirname "$0")/seen"
HEADED_EOF
chmod 755 "$bus45/headed"
for bus45_variant in in out null; do
  case "$bus45_variant" in in) bus45_names='["qmd","himmel-bus"]' ;; out) bus45_names='["qmd"]' ;; null) bus45_names='null' ;; esac
  cat > "$bus45/profiles-$bus45_variant.mjs" <<PROFILE_EOF
switch (process.argv[3]) {
  case '--context': console.log('{"contextMode":"standard","autocompact":200000}'); break;
  case '--mcp-servers': console.log('$bus45_names'); break;
  case '--mcp-config': console.log('{"mcpServers":{"qmd":{"type":"http","url":"http://localhost:8181/mcp"}}}'); break;
  default: console.log('{"enabledPlugins":{},"permissions":{"allow":[]}}');
}
PROFILE_EOF
done
# run45 <variant> <name>: launches with HIMMEL_BUS_* preset both ways.
run45() {
  rm -f "$bus45/seen"
  XDG_STATE_HOME="$bus45/state" HIMMEL_BUS_NAME=ambient-name \
  HEADED_ARM_LAUNCHER_ENV="HIMMEL_BUS_NAME=preset-name HIMMEL_BUS_EXTRA=1" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-$1.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief "${3:-HIMMEL-chief-45}" "$2" "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 >/dev/null 2>&1
}
mkdir -p "$bus45/state" && chmod 700 "$bus45/state"
bus45_toks() { sed -n 's/^LAUNCHER_ENV=//p' "$bus45/seen" | tr ' ' '\n' | grep '^HIMMEL_BUS_' || true; }
rc=0; run45 in PROJ-45-in || rc=$?
check "45a opted-in launch: exit 0" "$rc" "0"
peer45="$bus45/state/himmel/bus/peers/PROJ-45-in.json"
check "45b opted-in: peer file written 0600" "$(stat -c %a "$peer45" 2>/dev/null || stat -f %Lp "$peer45" 2>/dev/null || echo none)" "600"
check "45c opted-in: peer is a worker of the chief, no secret field" \
  "$(jq -c '[.n, .role, .console, (keys | join(","))]' "$peer45" 2>/dev/null)" \
  '["PROJ-45-in","worker","HIMMEL-chief-45","console,launched,n,role"]'
check "45d opted-in: the only HIMMEL_BUS_* the launched env carries is HIMMEL_BUS_NAME=<name>" \
  "$(bus45_toks)" "HIMMEL_BUS_NAME=PROJ-45-in"
check "45e opted-in: headed-arm.sh is told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen")" "1"
check "45e2 opted-in: the CLI that registered is handed to headed-arm.sh to bind" "$(sed -n 's/^BUS_CLI=//p' "$bus45/seen")" "$HERE/../../../marketplace/plugins/himmel-bus/bin/bus"
check "45f opted-in: the launched process env carries the registered name, not the ambient one" "$(sed -n 's/^AMBIENT=//p' "$bus45/seen")" "PROJ-45-in"
rc=0; run45 out PROJ-45-out || rc=$?
check "45g opted-out launch: exit 0" "$rc" "0"
check "45h opted-out: no peer file" "$([ -e "$bus45/state/himmel/bus/peers/PROJ-45-out.json" ] && echo yes || echo no)" "no"
check "45i opted-out: no HIMMEL_BUS_* in the launched env" "$(bus45_toks)" ""
check "45j opted-out: headed-arm.sh is not told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen")" "<unset>"
check "45k opted-out: the ambient HIMMEL_BUS_NAME does not reach the target" "$(sed -n 's/^AMBIENT=//p' "$bus45/seen")" "<unset>"
# a profile with no mcpServers field (null: every user MCP server, himmel-bus
# among them, as the design profiles resolve) registers like an opted-in one.
rc=0; run45 null PROJ-45-null || rc=$?
check "45k1 null-mcpServers launch: exit 0" "$rc" "0"
check "45k2 null-mcpServers: the worker is registered under its chief" \
  "$(jq -r '.role + " " + .console' "$bus45/state/himmel/bus/peers/PROJ-45-null.json" 2>/dev/null || echo none)" "worker HIMMEL-chief-45"
check "45k3 null-mcpServers: the launched env carries HIMMEL_BUS_NAME=<name>" "$(bus45_toks)" "HIMMEL_BUS_NAME=PROJ-45-null"
check "45k4 null-mcpServers: headed-arm.sh is told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen")" "1"
# the worker role is the canonical name, so it registers with the legacy-names switch off.
rc=0; HIMMEL_LEGACY_NAMES=0 run45 in PROJ-45-nolegacy || rc=$?
check "45k5 legacy names off: a worker registers as role worker" \
  "$(jq -r '.role' "$bus45/state/himmel/bus/peers/PROJ-45-nolegacy.json" 2>/dev/null || echo none)" "worker"
# only a judge or consult takes --pair: a worker launched with a pair named records none,
# a judge launched with it records the pair.
rc=0; WORKER_SESSION_BUS_PAIR=PROJ-45-in run45 in PROJ-45-nopair || rc=$?
check "45k6 a worker launched with a pair named records no pair" \
  "$(jq -r '.pair // "none"' "$bus45/state/himmel/bus/peers/PROJ-45-nopair.json" 2>/dev/null || echo missing)" "none"
rc=0
XDG_STATE_HOME="$bus45/state" HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" WORKER_SESSION_BUS_PAIR=PROJ-45-in \
  bash "$SCRIPT" --judge --chief HIMMEL-chief-45 PROJ-45-judge "$doc_tier_judge" "$bus45/signal" "$PAST" "$bus45/log" claude-opus-5-5 >/dev/null 2>&1 || rc=$?
check "45k7 a judge launched with a pair named records the pair and its role" \
  "$(jq -r '.role + " " + (.pair // "none")' "$bus45/state/himmel/bus/peers/PROJ-45-judge.json" 2>/dev/null || echo missing)" "judge PROJ-45-in"
# a re-arm of a name that was registered but never bound (the first
# launch was refused later, or died before the bind) adopts the entry and binds.
rc=0; run45 in PROJ-45-in || rc=$?
check "45l re-arm of an unbound name: launch exits 0" "$rc" "0"
check "45m re-arm of an unbound name: the launched env carries HIMMEL_BUS_NAME" "$(bus45_toks)" "HIMMEL_BUS_NAME=PROJ-45-in"
check "45n re-arm of an unbound name: headed-arm.sh is told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen")" "1"
# the same name registered under another chief is refused: the launch is refused too
rc=0; run45 in PROJ-45-in HIMMEL-chief-45-other || rc=$?
check "45o refused register (changed chief): launch exits 2" "$rc" "2"
check "45q refused register: nothing launched" "$([ -e "$bus45/seen" ] && echo launched || echo none)" "none"
# the refused register is no longer log-only: it is on the launcher's
# stdout and a bus=FAIL: bullet sits in the worker doc, still not a status marker.
bus45_doc="$bus45/worker-doc.md"; fx_brief '# fixture doc' > "$bus45_doc"
printf '\n## Results\n\n- 00:00 LIVE - start\n' >> "$bus45_doc"
bus45_out="$(XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45-other2 PROJ-45-in "$bus45_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>/dev/null || true)"
check "45w failed register: bus=FAIL: on the launcher stdout" "$(printf '%s\n' "$bus45_out" | grep -c 'bus=FAIL:')" "1"
check "45x failed register: bus=FAIL: bullet in the worker doc" "$(grep -c '^- [0-9:]* bus=FAIL:' "$bus45_doc")" "1"
check "45y failed register: the doc's tail status (worker_tail_status) is still LIVE" "$(. "$HERE/../../lib/worker-tail-status.sh"; worker_tail_status "$bus45_doc")" "LIVE"
# A register error that contains WRAPPED must not turn the unmarked bus=FAIL:
# bullet into a wrap: the word is stripped before the bullet is written.
bus45_stub="$bus45/bus-wrapped-stub"
printf '#!/usr/bin/env bash\necho "register failed: WRAPPED state"\nexit 1\n' > "$bus45_stub"; chmod +x "$bus45_stub"
bus45_doc2="$bus45/worker-doc2.md"; fx_brief '# fixture doc' > "$bus45_doc2"
printf '\n## Results\n\n- 00:00 LIVE - start\n' >> "$bus45_doc2"
HEADED_ARM_BUS_CLI="$bus45_stub" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45-other3 PROJ-45-in3 "$bus45_doc2" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 >/dev/null 2>&1 || true
check "45z failed register naming WRAPPED: bullet written, word stripped" "$(grep -c '^- [0-9:]* bus=FAIL:.*WRAPPED' "$bus45_doc2"):$(grep -c '^- [0-9:]* bus=FAIL:' "$bus45_doc2")" "0:1"
check "45z2 failed register naming WRAPPED: tail status stays LIVE" "$(. "$HERE/../../lib/worker-tail-status.sh"; worker_tail_status "$bus45_doc2")" "LIVE"
# A relaunch of a bound name never launches unbound. Its previous
# holder dead (9071a), the name comes up registered again and a fresh pid binds
# it (a bus read answers live); its holder live (9071b), the launch is refused,
# nothing is launched and the refusal names the worker and the holder pid.
if [ -r /proc/self/stat ]; then
  bus9071_cli="$HERE/../../../marketplace/plugins/himmel-bus/bin/bus"
  rc=0; run45 in PROJ-9071-dead || rc=$?
  sleep 30 & bus9071_old=$!
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" bind PROJ-9071-dead "$bus9071_old" >/dev/null 2>&1
  kill "$bus9071_old" 2>/dev/null; wait "$bus9071_old" 2>/dev/null || true
  rc=0; run45 in PROJ-9071-dead || rc=$?
  check "9071a dead holder relaunch: launch exits 0" "$rc" "0"
  check "9071a dead holder relaunch: headed-arm.sh is told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen" 2>/dev/null)" "1"
  check "9071a dead holder relaunch: the launched env carries HIMMEL_BUS_NAME" "$(bus45_toks)" "HIMMEL_BUS_NAME=PROJ-9071-dead"
  check "9071a dead holder relaunch: no launching-unbound warning" "$(grep -c 'register failed for PROJ-9071-dead' "$bus45/log")" "0"
  sleep 30 & bus9071_new=$!
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" bind PROJ-9071-dead "$bus9071_new" >/dev/null 2>&1
  check "9071a dead holder relaunch: the new pid binds and a bus read answers live" \
    "$(XDG_STATE_HOME="$bus45/state" "$bus9071_cli" status PROJ-9071-dead 2>&1)" "live"
  kill "$bus9071_new" 2>/dev/null; wait "$bus9071_new" 2>/dev/null || true
  rc=0; run45 in PROJ-9071-live || rc=$?
  sleep 30 & bus9071_live=$!
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" bind PROJ-9071-live "$bus9071_live" >/dev/null 2>&1
  rm -f "$bus45/seen"
  rc=0
  bus9071_out="$(XDG_STATE_HOME="$bus45/state" \
    HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
    HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
      bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9071-live "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
  check "9071b live holder relaunch: launch refused (non-zero)" "$([ "$rc" -ne 0 ] && echo refused || echo "launched rc=$rc")" "refused"
  check "9071b live holder relaunch: nothing launched" "$([ -e "$bus45/seen" ] && echo launched || echo none)" "none"
  contains "9071b live holder relaunch: refusal names the worker" "$bus9071_out" "PROJ-9071-live"
  contains "9071b live holder relaunch: refusal names the holder pid" "$bus9071_out" "pid $bus9071_live"
  check "9071b live holder relaunch: the holder stays bound and live" \
    "$(XDG_STATE_HOME="$bus45/state" "$bus9071_cli" status PROJ-9071-live 2>&1)" "live"
  kill "$bus9071_live" 2>/dev/null; wait "$bus9071_live" 2>/dev/null || true
  # A successor chief re-arming a dead worker its predecessor registered: the
  # dead worker never adopted the successor, and the name still comes back.
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" register HIMMEL-chief-9071a --role chief >/dev/null 2>&1
  rc=0; run45 in PROJ-9071-succ HIMMEL-chief-9071a || rc=$?
  sleep 30 & bus9071_succ=$!
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" bind PROJ-9071-succ "$bus9071_succ" >/dev/null 2>&1
  kill "$bus9071_succ" 2>/dev/null; wait "$bus9071_succ" 2>/dev/null || true
  XDG_STATE_HOME="$bus45/state" "$bus9071_cli" register HIMMEL-chief-9071b --role chief --predecessor HIMMEL-chief-9071a >/dev/null 2>&1
  rc=0; run45 in PROJ-9071-succ HIMMEL-chief-9071b || rc=$?
  check "9071c successor chief re-arms a dead worker: launch exits 0" "$rc" "0"
  check "9071c successor chief re-arms a dead worker: headed-arm.sh is told to bind" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen" 2>/dev/null)" "1"
  check "9071c successor chief re-arms a dead worker: the name now belongs to the successor" \
    "$(jq -r '.console' "$bus45/state/himmel/bus/peers/PROJ-9071-succ.json" 2>/dev/null)" "HIMMEL-chief-9071b"
fi
# A broken bus: the refusal names the override, which launches unbound when set
# in the launching shell; a held name is never overridden; a hung bus is bounded.
bus45_broken="$bus45/bus-broken-stub"
printf '#!/usr/bin/env bash\necho "bus store unreadable"\nexit 1\n' > "$bus45_broken"; chmod +x "$bus45_broken"
rm -f "$bus45/seen"; rc=0
bus9071_out="$(HEADED_ARM_BUS_CLI="$bus45_broken" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9071-broken "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
check "9071d broken bus: launch exits 2" "$rc" "2"
contains "9071d broken bus: the refusal names the override" "$bus9071_out" "set HIMMEL_LAUNCH_UNBOUND_OK=1 in the launching shell"
rm -f "$bus45/seen"; rc=0
HIMMEL_LAUNCH_UNBOUND_OK=1 HEADED_ARM_BUS_CLI="$bus45_broken" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9071-broken "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
check "9071e broken bus with the override: launch exits 0, unbound" "$rc:$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen" 2>/dev/null)" "0:<unset>"
check "9071e broken bus with the override: the log says it launched unbound" "$(grep -c 'launching unbound (HIMMEL_LAUNCH_UNBOUND_OK=1)' "$bus45/log")" "1"
check "9071e the override is not passed on to the worker" "$(sed -n 's/^OVERRIDE=//p' "$bus45/seen" 2>/dev/null)" "<unset>"
mkdir -p "$bus45/nomktemp"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '#!/usr/bin/env bash\ncase "$*" in *headed-arm-bus*) exit 1 ;; esac\nPATH="${PATH#*:}" exec mktemp "$@"\n' > "$bus45/nomktemp/mktemp"
chmod +x "$bus45/nomktemp/mktemp"
rm -f "$bus45/seen"; rc=0
bus9071_out="$(HIMMEL_LAUNCH_UNBOUND_OK=1 PATH="$bus45/nomktemp:$PATH" HEADED_ARM_BUS_CLI="$bus45_broken" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9071-broken "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
check "9071h the override never launches when the bus output was lost" "$rc:$([ -e "$bus45/seen" ] && echo launched || echo none)" "2:none"
contains "9071h the refusal says the output was lost" "$bus9071_out" "output lost (mktemp failed)"
check "9071h the refusal does not advise the override" "$(printf '%s\n' "$bus9071_out" | grep -c 'set HIMMEL_LAUNCH_UNBOUND_OK=1')" "0"
rc=0; HIMMEL_LAUNCH_UNBOUND_OK=1 run45 in PROJ-45-in HIMMEL-chief-45-other || rc=$?
check "9071f the override never launches over a held name" "$rc:$([ -e "$bus45/seen" ] && echo launched || echo none)" "2:none"
bus45_hung="$bus45/bus-hung-stub"
printf '#!/usr/bin/env bash\nexec sleep 120\n' > "$bus45_hung"; chmod +x "$bus45_hung"
rm -f "$bus45/seen"; rc=0; bus9071_t0=$SECONDS
bus9071_out="$(BUS_EXEC_SECS=08 HEADED_ARM_BUS_CLI="$bus45_hung" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9071-hung "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
# the stub sleeps 120s and the bus times out after 8s; a macOS runner adds far more launch overhead than Linux does, so the bound
# sits well under the stub's sleep (an unbounded wait would take all 120s) rather than just above the 8s timeout
bus9071_secs=$((SECONDS - bus9071_t0))
check "9071g hung bus: refused within the bound" "$rc:$([ "$bus9071_secs" -lt 60 ] && echo bounded || echo "slow:${bus9071_secs}s")" "2:bounded"
contains "9071g hung bus: the refusal says it timed out, a leading zero read as decimal" "$bus9071_out" "timed out after 8s"
bus9537_stub="$bus45/bus-called-stub"
printf '#!/usr/bin/env bash\ntouch "%s/bus-called"\necho "bus: invalid session name"\nexit 1\n' "$bus45" > "$bus9537_stub"; chmod +x "$bus9537_stub"
bus9537_name="PROJ-9537-$(printf 'x%.0s' $(seq 1 120))"
for bus9537_ov in "" 1; do
  rm -f "$bus45/seen" "$bus45/bus-called"; rc=0
  bus9537_out="$(HIMMEL_LAUNCH_UNBOUND_OK="$bus9537_ov" HEADED_ARM_BUS_CLI="$bus9537_stub" XDG_STATE_HOME="$bus45/state" \
    HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
    HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
      bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 "$bus9537_name" "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
  check "9537a too-long name (override='$bus9537_ov'): launch exits 2, nothing launched, the bus not asked" "$rc:$([ -e "$bus45/seen" ] && echo launched || echo none):$([ -e "$bus45/bus-called" ] && echo asked || echo not-asked)" "2:none:not-asked"
  contains "9537a too-long name: the refusal names the length and the limit" "$bus9537_out" "session name is ${#bus9537_name} characters, over the bus limit of 128"
  not_contains "9537a too-long name: the refusal does not say the bus is broken" "$bus9537_out" "the bus is broken"
done
rm -f "$bus45/seen" "$bus45/bus-called"; rc=0
bus9537_out="$(HEADED_ARM_BUS_CLI="$bus9537_stub" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 "${bus9537_name%??}" "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
check "9537d a name of exactly the limit (128) is not refused as too long: the bus is asked" "$([ -e "$bus45/bus-called" ] && echo asked || echo not-asked)" "asked"
not_contains "9537d a name of exactly the limit is not called over the limit" "$bus9537_out" "over the bus limit"
check "9537c the launcher's name limit is the bus validator's" \
  "$(sed -n 's/^ *BUS_NAME_MAX=\([0-9]*\)$/\1/p' "$SCRIPT" | head -1)" \
  "$(sed -n 's/^export const SESSION_NAME = .*{0,\([0-9]*\)}\$\/;$/\1/p' "$HERE/../../../marketplace/plugins/himmel-bus/lib/store.mjs" | awk '{print $1+1}')"
rm -f "$bus45/seen"; rc=0
bus9537_out="$(HEADED_ARM_BUS_CLI="$bus45_broken" XDG_STATE_HOME="$bus45/state" \
  HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
    bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-9537-broken "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 2>&1)" || rc=$?
contains "9537b a real bus error keeps the broken-bus text" "$bus9537_out" "bus store unreadable - the bus is broken"
not_contains "9537b a real bus error is not called a name-length error" "$bus9537_out" "over the bus limit"
# an opted-out profile launched from a shell that carries a live
# bind flag and an extra HIMMEL_BUS_* leaks neither to the launched env.
rm -f "$bus45/seen"
rc=0
XDG_STATE_HOME="$bus45/state" HEADED_ARM_BUS=1 HEADED_ARM_BUS_CLI=/nonexistent-bus HIMMEL_BUS_EXTRA=ambient \
HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-out.mjs" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 PROJ-45-out2 "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
check "45r opted-out with ambient bind flag: launch exits 0" "$rc" "0"
check "45s opted-out: HEADED_ARM_BUS is absent from the target env" "$(sed -n 's/^BUS_FLAG=//p' "$bus45/seen")" "<unset>"
check "45u opted-out: an ambient HIMMEL_BUS_EXTRA is dropped" "$(sed -n 's/^EXTRA=//p' "$bus45/seen")" "<unset>"
check "45v opted-out: no bind flag or HIMMEL_BUS_* in the launched env" "$(sed -n 's/^LAUNCHER_ENV=//p' "$bus45/seen" | tr ' ' '\n' | grep -c '^HIMMEL_BUS_\|^HEADED_ARM_BUS' || true)" "0"

# --- worker-vm: the brief must name a registered, non-station test VM.
vm_json="$tmp/vms-fixture.json"
printf '%s\n' '{"ubuntu_new":{"os":"ubuntu","ssh_port":2222,"user":"himmel"},"win2":{"os":"windows","kind":"station","host":"win2"}}' > "$vm_json"
vm_novm="$tmp/vm-brief-none.md"; fx_brief '# fixture brief' 'no machine named here' > "$vm_novm"
vm_ok="$tmp/vm-brief-ok.md"; fx_brief '# fixture brief' 'Live proof on ubuntu_new.' > "$vm_ok"
vm_station="$tmp/vm-brief-station.md"; fx_brief '# fixture brief' 'Run it on win2.' > "$vm_station"
vm_sub="$tmp/vm-brief-sub.md"; fx_brief '# fixture brief' 'Run it on my_ubuntu_new_x.' > "$vm_sub"
for pair in "none:$vm_novm" "station:$vm_station" "substring:$vm_sub"; do
  rc=0; out="$(HEADED_ARM_WORKER_VMS_JSON="$vm_json" bash "$SCRIPT" --dry-run --profile worker-vm PROJ-9999-leg "${pair#*:}" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
  check "worker-vm brief naming ${pair%%:*} test VM: refused" "$rc" "2"
  contains "worker-vm brief naming ${pair%%:*} test VM: refusal text" "$out" "names no registered test VM"
done
rc=0; out="$(HEADED_ARM_WORKER_VMS_JSON="$vm_json" bash "$SCRIPT" --dry-run --profile worker-vm PROJ-9999-leg "$vm_ok" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "worker-vm brief naming ubuntu_new: accepted" "$rc" "0"
rc=0; out="$(HEADED_ARM_WORKER_VMS_JSON="$vm_json" bash "$SCRIPT" --dry-run --profile worker-impl PROJ-9999-leg "$vm_novm" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "worker-impl is not subject to the VM-name check" "$rc" "0"

# --- 46. one bus-idle-waker per headed worker, with that worker's --name, --service
# and --pid. The konsole stub records its own pid, which headed-arm.sh backgrounds
# as KPID; the waker stub records its argv.
d46="$tmp/c46"; mk_launch_stubs "$d46" "PROJ-46-worker"; mkdir -p "$tmp/repo46"
cat > "$d46/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
printf '%s' "$$" > "$(dirname "$0")/kpid"
{ echo "recorded"; env | grep -E '^HEADED_ARM_WAKER=' || true; } > "$(dirname "$0")/env-record"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
chmod 755 "$d46/konsole"
rc=0
# HEADED_ARM_UNAME=Linux pins the non-shim branch: on a real Darwin host headed-arm.sh skips the waker.
HEADED_ARM_UNAME=Linux WAKER_CALLS="$d46/waker-calls" run_worker "$d46" "$tmp/repo46" "PROJ-46-worker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
n=0; while [ ! -s "$d46/waker-calls" ] && [ "$n" -lt 60 ]; do sleep 0.05; n=$((n+1)); done
kpid46="$(cat "$d46/kpid" 2>/dev/null || true)"
check "46a headed launch: exit 0" "$rc" "0"
check "46b headed launch: exactly one waker started" "$(wc -l < "$d46/waker-calls" 2>/dev/null | tr -d '[:space:]')" "1"
check "46c waker carries the worker's --name, --service, --session and --pid" "$(cat "$d46/waker-calls" 2>/dev/null)" "--name PROJ-46-worker --service org.kde.konsole-$kpid46 --session /Sessions/1 --pid $kpid46"
contains "46d control: the konsole stub recorded its env" "$(cat "$d46/env-record" 2>/dev/null || true)" "recorded"
not_contains "46d the waker path never reaches the worker's env" "$(cat "$d46/env-record" 2>/dev/null || true)" "HEADED_ARM_WAKER"

# --- a worker runs under its own MemoryMax scope, so a runaway test
# is killed alone instead of taking the station and every other worker with it.
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "memcap: dry-run reports the default 12G cap" "$out" "memory-max=12G"
rc=0; out="$(HIMMEL_WORKER_SESSION_MEMORY_MAX=256M bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "memcap: dry-run reports an env-set cap" "$out" "memory-max=256M"
rc=0; out="$(HIMMEL_WORKER_SESSION_MEMORY_MAX='1G --evil' bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "memcap: a malformed cap is refused" "$rc" "2"
rc=0; out="$(HEADED_ARM_UNAME=Darwin bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "memcap: off Linux the launch is uncapped" "$out" "scope=no"
rc=0; out="$(HEADED_ARM_UNAME=Linux bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "memcap: on Linux the launch is scoped" "$out" "scope=yes"
rc=0; out="$(HIMMEL_WORKER_SESSION_MEMORY_MAX=12GG bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "memcap: a misplaced size suffix is refused" "$rc" "2"
printf '#!%s\nexit 1\n' "$(command -v bash)" > "$tmp/systemd-run-nobus"; chmod 755 "$tmp/systemd-run-nobus"
rc=0; out="$(HEADED_ARM_UNAME=Linux HEADED_ARM_WORKER_SYSTEMD_RUN="$tmp/systemd-run-nobus" bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "memcap: a systemd-run that cannot start a user scope falls back to uncapped" "$out" "scope=no"
d6119="$tmp/c6119"; mk_launch_stubs "$d6119" "PROJ-6119-worker"; mkdir -p "$tmp/repo6119"
rc=0
HEADED_ARM_UNAME=Linux SYSD_RECORD="$d6119/sysd" HIMMEL_WORKER_SESSION_MEMORY_MAX=256M RUN_WORKER_ARGS=--no-profile run_worker "$d6119" "$tmp/repo6119" "PROJ-6119-worker" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d6119" || true
sysd6119="$(grep MemoryMax "$d6119/sysd" 2>/dev/null || true)"
check "memcap: full launch exit 0" "$rc" "0"
contains "memcap: launch runs in a user scope" "$sysd6119" "--user --scope"
contains "memcap: launch carries MemoryMax" "$sysd6119" "MemoryMax=256M"
contains "memcap: launch carries MemorySwapMax" "$sysd6119" "MemorySwapMax=256M"
contains "memcap: konsole still launched inside the scope" "$(cat "$d6119/record" 2>/dev/null || true)" "--workdir $tmp/repo6119"
for badcap in 12g 0 00 01 1k; do
  rc=0; out="$(HIMMEL_WORKER_SESSION_MEMORY_MAX="$badcap" bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
  check "memcap: cap '$badcap' is refused" "$rc" "2"
done
# The uncapped fallback is visible: stdout, the launch log and a worker-doc bullet.
d6119w="$tmp/c6119w"; mk_launch_stubs "$d6119w" "PROJ-6119-warn"; mkdir -p "$tmp/repo6119w"
some_doc_6119="$some_doc"; some_doc="$tmp/memcap-doc.md"; cp "$some_doc_6119" "$some_doc"
printf '\n## Results\n\n- 00:00 LIVE - start\n' >> "$some_doc"
rc=0
HEADED_ARM_UNAME=Linux HEADED_ARM_WORKER_SYSTEMD_RUN="$tmp/systemd-run-nobus" RUN_WORKER_ARGS=--no-profile run_worker "$d6119w" "$tmp/repo6119w" "PROJ-6119-warn" "claude-sonnet-5" >"$d6119w/stdout" 2>&1 || rc=$?
wait_record "$d6119w" || true
check "memcap: fallback launch exit 0" "$rc" "0"
contains "memcap: fallback WARN on stdout" "$(cat "$d6119w/stdout")" "WARN memory cap NOT applied"
contains "memcap: fallback WARN in the launch log" "$(cat "$d6119w/log" 2>/dev/null || true)" "WARN memory cap NOT applied"
contains "memcap: fallback leaves a memcap=FAIL bullet in the worker doc" "$(cat "$tmp/memcap-doc.md")" "memcap=FAIL:systemd-run cannot start a user scope"
check "memcap: fallback bullet is not a status marker" "$(grep -c '^- [0-9:]* memcap=FAIL:' "$some_doc")" "1"
some_doc="$some_doc_6119"
contains "memcap: fallback still launches the konsole" "$(cat "$d6119w/record" 2>/dev/null || true)" "--workdir $tmp/repo6119w"
rc=0; out="$(HEADED_ARM_UNAME=Darwin bash "$SCRIPT" --dry-run --no-profile PROJ-6119-worker "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
not_contains "memcap: a dry-run writes no WARN" "$out" "WARN memory cap"
# --consult never honours the systemd-run seam and never execs a PATH systemd-run.
rc=0; out="$(HEADED_ARM_WORKER_SYSTEMD_RUN="$tmp/systemd-run-nobus" WORKER_SESSION_REPO="$tmp/repo41c" bash "$SCRIPT" --dry-run --consult --profile design-motion --chief PROJ-4014-chief PROJ-4014-c "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "memcap: --consult with the systemd-run seam set refuses" "$rc" "2"
contains "memcap: --consult seam refusal says why" "$out" "--consult refuses HEADED_ARM_WORKER_SYSTEMD_RUN"
mkdir -p "$tmp/shadow6119"
printf '#!%s\n: > "%s/shadow-ran"\nexit 0\n' "$(command -v bash)" "$tmp/shadow6119" > "$tmp/shadow6119/systemd-run"; chmod 755 "$tmp/shadow6119/systemd-run"
rc=0; out="$(PATH="$tmp/shadow6119:$PATH" HEADED_ARM_UNAME=Linux WORKER_SESSION_REPO="$tmp/repo41c" bash "$SCRIPT" --dry-run --consult --profile design-motion --chief PROJ-4014-chief PROJ-4014-c "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "memcap: --consult with a PATH-shadowed systemd-run still launches" "$rc" "0"
check "memcap: --consult never execs a PATH-shadowed systemd-run" "$([ -e "$tmp/shadow6119/shadow-ran" ] && echo ran || echo not-run)" "not-run"
# Real environment: the argv the wrapper built, run against the real
# systemd-run, must land the process in a cgroup whose memory.max is the cap.
real_xdg="/run/user/$(id -u)"  # the suite pins XDG_RUNTIME_DIR to a tmp dir; the real bus lives here
# real_scope_row RECORDING SYSD_BIN: an empty or user-less recording must never
# reach the system bus (a bare systemd-run prompts for a root password).
real_scope_row() {
  local recording="$1" sysd_bin="$2" sysd_argv sysd_cap_argv a real_cap
  case "$recording" in
    *"--user --scope"*) ;;
    *) echo "ok - memcap: real scope row skipped (no user-scope argv recorded)"; return 0 ;;
  esac
  if [ "$(uname -s)" = "Linux" ] && XDG_RUNTIME_DIR="$real_xdg" "$sysd_bin" --user --scope --quiet true >/dev/null 2>&1; then
    read -r -a sysd_argv <<< "$recording"
    sysd_cap_argv=()
    for a in "${sysd_argv[@]}"; do [ "$a" = "--" ] && break; sysd_cap_argv+=("$a"); done
    # shellcheck disable=SC2016  # the $(...) must expand inside the scope, not here
    real_cap="$(XDG_RUNTIME_DIR="$real_xdg" "$sysd_bin" "${sysd_cap_argv[@]}" -- bash -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max"' 2>/dev/null || true)"
    check "memcap: real scope enforces memory.max (256M)" "$real_cap" "268435456"
  else
    echo "ok - memcap: real scope row skipped (no systemd user bus)"
  fi
}
# RED control: an empty recording skips and never invokes systemd-run.
mkdir -p "$tmp/loud-sysd"
printf '#!%s\n: > "%s/loud-sysd/called"\nexit 99\n' "$(command -v bash)" "$tmp" > "$tmp/loud-sysd/systemd-run"; chmod 755 "$tmp/loud-sysd/systemd-run"
empty_row_out="$(real_scope_row "" "$tmp/loud-sysd/systemd-run")"
contains "memcap: an empty recording skips the real scope row" "$empty_row_out" "real scope row skipped (no user-scope argv recorded)"
check "memcap: an empty recording never invokes systemd-run" "$([ -e "$tmp/loud-sysd/called" ] && echo called || echo not-called)" "not-called"
real_scope_row "$sysd6119" /usr/bin/systemd-run

# --- 47. A doc whose resume_cwd is a worktree of a REGISTERED adopter repo (the
# handover registry lists the repo's primary checkout) launches with that worktree
# as its cwd, so a step never runs against the adopter's main. Fixture repos only.
# An unregistered repo and an explicit WORKER_SESSION_REPO are left as they were.
adopter47="$tmp/adopter47"; mkdir -p "$adopter47"
git -C "$adopter47" init -q
git -C "$adopter47" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$adopter47" worktree add -q -b fix/adopter-47 "$adopter47/.claude/worktrees/fix+adopter-47"
wt47="$adopter47/.claude/worktrees/fix+adopter-47"
reg47="$tmp/reg47.json"; printf '{"repos":{"adopter47":{"path":"%s"}}}\n' "$adopter47" > "$reg47"
reg47_none="$tmp/reg47-none.json"; printf '{"repos":{}}\n' > "$reg47_none"
doc47="$tmp/c47-doc.md"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$wt47" > "$doc47"
some_doc_47="$some_doc"; some_doc="$doc47"
d47="$tmp/c47"; mk_launch_stubs "$d47" "PROJ-47-adopter"
rc=0
HANDOVER_REGISTRY="$reg47" RUN_WORKER_ARGS=--no-profile run_worker "$d47" "" "PROJ-47-adopter" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d47" || true
check "47a a registered adopter worktree launch: exit 0" "$rc" "0"
contains "47a the session cwd is the adopter worktree, not its main" "$(cat "$d47/record" 2>/dev/null || true)" "--workdir $wt47"
d47b="$tmp/c47b"; mk_launch_stubs "$d47b" "PROJ-47-unreg"
rc=0
HANDOVER_REGISTRY="$reg47_none" RUN_WORKER_ARGS=--no-profile run_worker "$d47b" "" "PROJ-47-unreg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d47b" || true
check "47b an unregistered repo's worktree launch: exit 0" "$rc" "0"
contains "47b an unregistered repo's launch still recorded a session cwd" "$(cat "$d47b/record" 2>/dev/null || true)" "--workdir "
not_contains "47b an unregistered repo's worktree is not taken as the cwd" "$(cat "$d47b/record" 2>/dev/null || true)" "--workdir $wt47"
d47c="$tmp/c47c"; mk_launch_stubs "$d47c" "PROJ-47-explicit"; mkdir -p "$tmp/repo47c"
rc=0
HANDOVER_REGISTRY="$reg47" RUN_WORKER_ARGS=--no-profile run_worker "$d47c" "$tmp/repo47c" "PROJ-47-explicit" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d47c" || true
check "47c an explicit WORKER_SESSION_REPO launch: exit 0" "$rc" "0"
contains "47c an explicit WORKER_SESSION_REPO still wins" "$(cat "$d47c/record" 2>/dev/null || true)" "--workdir $tmp/repo47c"
# A same-repo worktree must not fall back to the launcher's primary checkout.
harness47="$tmp/harness47"; mkdir -p "$harness47"
git -C "$harness47" init -q
git -C "$harness47" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$harness47" worktree add -q -b fix/harness-47 "$harness47/.claude/worktrees/fix+harness-47"
wt47h="$harness47/.claude/worktrees/fix+harness-47"
mk_launcher_tree "$harness47"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$wt47h" > "$doc47"
d47h="$tmp/c47h"; mk_launch_stubs "$d47h" "PROJ-47-harness"
rc=0
HANDOVER_REGISTRY="$reg47_none" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" KONSOLE_CMD="$d47h/konsole" PGREP_CMD="$d47h/pgrep" \
  HEADED_ARM_PROC="$d47h/proc" HEADED_ARM_LOCK_DIR="$d47h/locks" \
  bash "$harness47/scripts/handover/chief-kit/headed-arm-worker.sh" --no-profile \
  PROJ-47-harness "$doc47" "$d47h/signal" "$PAST" "$d47h/log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
wait_record "$d47h" || true
check "47d same-repo worktree launch: exit 0" "$rc" "0"
contains "47d same-repo session starts in resume_cwd, not main" \
  "$(cat "$d47h/record" 2>/dev/null || true)" "--workdir $wt47h"
# Relative launch logs still yield profile files readable from the selected worktree.
for lane47 in native claudex; do
  name47="PROJ-47-relative-$lane47"
  d47r="$tmp/c47r-$lane47"; mk_launch_stubs "$d47r" "$name47"
  model47=claude-sonnet-5; [ "$lane47" != claudex ] || model47=gpt-6.1-sol
  rc=0
  (
    cd "$harness47" || exit 1
    HANDOVER_REGISTRY="$reg47_none" PLUGIN_PROFILES_REGISTRY="$mcpreg" \
      HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
      KONSOLE_CMD="$d47r/konsole" PGREP_CMD="$d47r/pgrep" \
      HEADED_ARM_PROC="$d47r/proc" HEADED_ARM_LOCK_DIR="$d47r/locks" \
      bash "$harness47/scripts/handover/chief-kit/headed-arm-worker.sh" --profile mcp-empty --lane "$lane47" \
      "$name47" "$doc47" "$d47r/signal" "$PAST" "../c47r-$lane47/log" "$model47"
  ) >"$d47r/worker-out" 2>&1 || rc=$?
  wait_record "$d47r" || true
  check "47e $lane47 relative-log launch exits 0" "$rc" "0"
  env47r="$(cat "$d47r/env-record" 2>/dev/null || true)"
  contains "47e $lane47 settings path is absolute" "$env47r" "WORKER_SESSION_PROFILE_SETTINGS=$d47r/$name47.leg-settings.json"
  contains "47e $lane47 preface path is absolute" "$env47r" "WORKER_SESSION_PROFILE_PREFACE=$d47r/$name47.worker-preface.md"
  contains "47e $lane47 MCP path is absolute" "$env47r" "WORKER_SESSION_PROFILE_MCP_CONFIG=$d47r/$name47.leg-mcp.json"
  rc=0
  (
    cd "$wt47h" || exit 1
    WORKER_SESSION_CLAUDE_BIN=true \
      WORKER_SESSION_PROFILE_SETTINGS="$(printf '%s\n' "$env47r" | sed -n 's/^WORKER_SESSION_PROFILE_SETTINGS=//p')" \
      WORKER_SESSION_PROFILE_PREFACE="$(printf '%s\n' "$env47r" | sed -n 's/^WORKER_SESSION_PROFILE_PREFACE=//p')" \
      WORKER_SESSION_PROFILE_MCP_CONFIG="$(printf '%s\n' "$env47r" | sed -n 's/^WORKER_SESSION_PROFILE_MCP_CONFIG=//p')" \
      bash "$HERE/../../lanes/worker-claude-launcher.sh" --version
  ) >"$d47r/shim-out" 2>&1 || rc=$?
  check "47e $lane47 real shim reads profile artifacts from worktree cwd" "$rc" "0"
done
some_doc="$some_doc_47"

# 48. A native worker is reachable by Remote Control. The shim turns
# WORKER_SESSION_REMOTE_CONTROL=<name> into `--remote-control <name>` PREPENDED
# (unset or empty = byte-identical argv); headed-arm-worker.sh sets it to the
# session name on a native, non-consult, non-headless profiled launch only.
rm -f "$tmp/shim-argv"
WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_REMOTE_CONTROL=PROJ-9999-leg \
  bash "$SHIM" --model claude-sonnet-5 -n PROJ-9999-leg "load doc" || true
check "48a shim: WORKER_SESSION_REMOTE_CONTROL prepends --remote-control <name>, rest of argv in order" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" \
  "[--remote-control][PROJ-9999-leg][--model][claude-sonnet-5][-n][PROJ-9999-leg][load doc]"
rm -f "$tmp/shim-argv"
WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_REMOTE_CONTROL='' \
  bash "$SHIM" --model claude-sonnet-5 "load doc" || true
check "48b shim: WORKER_SESSION_REMOTE_CONTROL empty -> argv byte-identical" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" "[--model][claude-sonnet-5][load doc]"
rm -f "$tmp/shim-argv"
(unset WORKER_SESSION_REMOTE_CONTROL; WORKER_SESSION_CLAUDE_BIN="$shim_argv" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' \
  bash "$SHIM" --model claude-sonnet-5 "load doc") || true
check "48c shim: WORKER_SESSION_REMOTE_CONTROL unset -> argv byte-identical" \
  "$(cat "$tmp/shim-argv" 2>/dev/null || true)" "[--model][claude-sonnet-5][load doc]"

d48="$tmp/c48"; mk_launch_stubs "$d48" "PROJ-8320-leg"; mkdir -p "$tmp/repo48"
rc=0
IMPL_GUARD_OK='' WORKER_SESSION_REMOTE_CONTROL='' \
HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d48/konsole" PGREP_CMD="$d48/pgrep" \
WORKER_SESSION_REPO="$tmp/repo48" HEADED_ARM_LOCK_DIR="$d48/locks" HEADED_ARM_PROC="$d48/proc" \
  bash "$SCRIPT" --profile worker-impl "PROJ-8320-leg" "$some_doc" "$d48/signal-never" "$PAST" "$d48/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d48" || true
check "48d full native --profile launch: exit 0" "$rc" "0"
contains "48e full native --profile launch: the session name reaches the launched env as WORKER_SESSION_REMOTE_CONTROL" \
  "$(cat "$d48/env-record" 2>/dev/null || true)" "WORKER_SESSION_REMOTE_CONTROL=PROJ-8320-leg"
not_contains "48f full --lane claudex launch carries no Remote Control" "$(cat "$d16/env-record" 2>/dev/null || true)" "WORKER_SESSION_REMOTE_CONTROL"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile worker-impl PROJ-8320-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
contains "48g dry-run native --profile: reports remote-control=<session name>" "$out" "remote-control=PROJ-8320-leg"
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex --profile worker-impl PROJ-8320-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
not_contains "48h dry-run --lane claudex --profile: no Remote Control" "$out" "remote-control="
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile PROJ-8320-leg some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
not_contains "48i dry-run --no-profile: no Remote Control (no shim carries it)" "$out" "remote-control="

# 48j-48k. An ambient WORKER_SESSION_REMOTE_CONTROL, plain or inside a preset
# HEADED_ARM_LAUNCHER_ENV token, never reaches a launch that is not a profiled native
# worker: the global sibling-arming scrub drops it before any branch, so a --no-profile
# launch (on either lane) carries neither the env var nor the token.
for lane48 in claudex native; do
  m48=""; [ "$lane48" = native ] && m48="claude-sonnet-5"
  d48x="$tmp/c48x-$lane48"; mk_launch_stubs "$d48x" "PROJ-8320-$lane48"; mkdir -p "$tmp/repo48x-$lane48"
  rc=0
  IMPL_GUARD_OK='' WORKER_SESSION_REMOTE_CONTROL=leaked-ambient \
  HEADED_ARM_LAUNCHER_ENV='WORKER_SESSION_REMOTE_CONTROL=leaked-token KEEP_ME=1' \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  HEADED_ARM_WORKER_CLAUDEX_BIN="$claudex_stub" \
  KONSOLE_CMD="$d48x/konsole" PGREP_CMD="$d48x/pgrep" \
  WORKER_SESSION_REPO="$tmp/repo48x-$lane48" HEADED_ARM_LOCK_DIR="$d48x/locks" HEADED_ARM_PROC="$d48x/proc" \
    bash "$SCRIPT" --lane "$lane48" --no-profile "PROJ-8320-$lane48" "$some_doc" "$d48x/signal-never" "$PAST" "$d48x/log" $m48 >/dev/null 2>&1 || rc=$?
  wait_record "$d48x" || true
  check "48j $lane48 --no-profile launch with an ambient Remote Control name: exit 0" "$rc" "0"
  not_contains "48j $lane48 --no-profile: the env var is absent from the launched env" "$(cat "$d48x/env-record" 2>/dev/null || true)" "WORKER_SESSION_REMOTE_CONTROL"
  not_contains "48k $lane48 --no-profile: neither var nor token is on the launched argv" "$(cat "$d48x/record" 2>/dev/null || true)" "leaked-"
done

# 48l. The shim refuses the flag on a non-native lane (the lane binary is a
# claude-codex / claude-openrouter / claude-deepseek launcher): nothing is exec'd.
for bin48 in claude-codex claude-openrouter claude-deepseek; do
  mkdir -p "$tmp/lanebin48"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "[%s]" "$@" > "'"$tmp"'/lane48-argv"' > "$tmp/lanebin48/$bin48"
  chmod 755 "$tmp/lanebin48/$bin48"
  rm -f "$tmp/lane48-argv"
  rc=0
  WORKER_SESSION_CLAUDE_BIN="$tmp/lanebin48/$bin48" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' WORKER_SESSION_REMOTE_CONTROL=PROJ-8320-leg \
    bash "$SHIM" --model m "load doc" >/dev/null 2>&1 || rc=$?
  check "48l shim: Remote Control on a $bin48 lane is refused (exit 2)" "$rc" "2"
  check "48l shim: $bin48 is never exec'd with the flag" "$([ -e "$tmp/lane48-argv" ] && echo ran || echo none)" "none"
  # without the variable the same lane binary launches as before
  rc=0
  (unset WORKER_SESSION_REMOTE_CONTROL; WORKER_SESSION_CLAUDE_BIN="$tmp/lanebin48/$bin48" WORKER_SESSION_PROFILE_SETTINGS='' WORKER_SESSION_PROFILE_PREFACE='' WORKER_SESSION_PROFILE_MCP_CONFIG='' \
    bash "$SHIM" --model m "load doc") >/dev/null 2>&1 || rc=$?
  check "48l shim: $bin48 without Remote Control still launches (exit 0)" "$rc" "0"
done

# 48m-48r. Only a plain worker is reachable: a judge, relay, release manager, consult and a
# headless session never carry the flag, and no dry-run report names remote-control=.
rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK bash "$SCRIPT" --dry-run --judge PROJ-8320-j "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "48m dry-run --judge: exit 0" "$rc" "0"
not_contains "48m dry-run --judge: no Remote Control" "$out" "remote-control="
rc=0; out="$(bash "$SCRIPT" --dry-run --relay PROJ-8320-r some/doc.md /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "48n dry-run --relay: exit 0" "$rc" "0"
not_contains "48n dry-run --relay: no Remote Control" "$out" "remote-control="
rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK -u HIMMEL_RM_EFFORT bash "$SCRIPT" --dry-run --profile release-manager --rm-release v1.1.3 PROJ-8320-rm "$doc_tier_rm" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "48o dry-run --profile release-manager: exit 0" "$rc" "0"
not_contains "48o dry-run --profile release-manager: no Remote Control" "$out" "remote-control="
mkdir -p "$tmp/repo48c"
rc=0; out="$(WORKER_SESSION_REPO="$tmp/repo48c" bash "$SCRIPT" --dry-run --consult --profile design-motion PROJ-8320-c "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "48p dry-run --consult: exit 0" "$rc" "0"
not_contains "48p dry-run --consult: no Remote Control" "$out" "remote-control="
rc=0; out="$(bash "$SCRIPT" --dry-run --headless --profile worker-impl PROJ-8320-h some/doc.md /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "48q dry-run --headless --profile: exit 0" "$rc" "0"
not_contains "48q dry-run --headless --profile: no Remote Control" "$out" "remote-control="

# --- 49. single-writer barrier: a worker launch carries its holder key, seeds its file holds and refuses an overlap ----
# The wrapper sets HIMMEL_HOLD_KEY/_DOC/_LABEL for a worker that implements; headed-arm.sh seeds them (its own suite
# proves the seed rows). Here: the env reaches the launched process, and a refusal or a pre-launch refusal leaves no row.
HOLDS49="$HERE/holds.py"
hold49() { HIMMEL_CONSOLE_LEG='' HANDOVER_DIR="$tmp/hroot49" python3 -I "$HOLDS49" "$@"; }
mkdir -p "$tmp/hroot49/u/r"
hrow49() { printf '%s/.himmel/state/holds/%s/%s' "$HOME" "${2//\//%2F}" "$(printf '%s' "$1" | sed 's#/#%2F#g')"; }
doc49a="$tmp/PROJ-9601-N1-holder.md"; fx_brief '# PROJ-9601 holder' > "$doc49a"
repo49="$tmp/repo49"; mkdir -p "$repo49"
hold49 claim --key PROJ-9601 --label N1 --doc "$doc49a" --repo "$repo49" scripts/w49.sh >/dev/null 2>&1
doc49b="$tmp/PROJ-9602-N2-rival.md"; fx_brief '# PROJ-9602 rival' '> **Writes:** scripts/w49a.sh scripts/w49.sh' > "$doc49b"
d49="$tmp/c49"; mk_launch_stubs "$d49" "PROJ-9602-N2-rival"
rc=0
out49="$(HANDOVER_DIR="$tmp/hroot49" some_doc="$doc49b" RUN_WORKER_ARGS=--no-profile run_worker "$d49" "$repo49" "PROJ-9602-N2-rival" "claude-sonnet-5" 2>&1)" || rc=$?
check "49a a brief naming a file another key holds is refused (exit 2)" "$rc" "2"
contains "49b the refusal names the holder" "$out49" "PROJ-9601"
contains "49c ... and prints the grant line to run" "$out49" "holds.py grant --key PROJ-9602 --repo $repo49 scripts/w49.sh"
check "49d the refused launch started no konsole" "$([ -e "$d49/record" ] && echo launched || echo none)" "none"
check "49e a refusal on a later file leaves no row of this seed" "$([ -e "$(hrow49 scripts/w49a.sh "$repo49")" ] && echo row || echo none)" "none"

# the launched process carries the three names; WRITE_HOLD_OK from the launching shell reaches it past the scrub
doc49c="$tmp/PROJ-9603-N3-plain.md"; fx_brief '# PROJ-9603 plain' '> **Writes:** scripts/w49c.sh' > "$doc49c"
d49c="$tmp/c49c"; mk_launch_stubs "$d49c" "PROJ-9603-N3-plain"; mkdir -p "$tmp/repo49c"
rc=0
WRITE_HOLD_OK=1 some_doc="$doc49c" RUN_WORKER_ARGS=--no-profile run_worker "$d49c" "$tmp/repo49c" "PROJ-9603-N3-plain" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d49c" || true
env49c="$(cat "$d49c/env-record" 2>/dev/null || true)"
check "49f a disjoint launch launches" "$rc" "0"
contains "49g HIMMEL_HOLD_KEY reaches the launched process" "$env49c" "HIMMEL_HOLD_KEY=PROJ-9603"
contains "49h HIMMEL_HOLD_DOC is the launch doc" "$env49c" "HIMMEL_HOLD_DOC=$doc49c"
contains "49i HIMMEL_HOLD_LABEL is the worker label" "$env49c" "HIMMEL_HOLD_LABEL=N3"
contains "49j WRITE_HOLD_OK=1 reaches the launched process" "$env49c" "WRITE_HOLD_OK=1"
check "49k the seed made the row, under the worker's key" "$(cut -f1,2 "$(hrow49 scripts/w49c.sh "$tmp/repo49c")" | tr '\t' ' ')" "PROJ-9603 N3"

# a launch refused before headed-arm.sh runs seeds nothing: the fleet cap, and a SKIPPED-BANK refusal
doc49d="$tmp/PROJ-9604-N1-capped.md"; fx_brief '# PROJ-9604 capped' '> **Writes:** scripts/w49d.sh' > "$doc49d"
d49d="$tmp/c49d"; mk_launch_stubs "$d49d" "PROJ-9604-N1-capped"; mkdir -p "$tmp/repo49d"
rc=0; some_doc="$doc49d" RUN_WORKER_ARGS=--no-profile run_worker "$d49d" "$tmp/repo49d" "PROJ-9604-N1-capped" "claude-sonnet-5" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
check "49l a fleet-cap refusal seeds nothing" "$([ "$rc" -ne 0 ] && echo refused)|$([ -e "$(hrow49 scripts/w49d.sh "$tmp/repo49d")" ] && echo row || echo none)" "refused|none"
rc=0; some_doc="$doc49d" RUN_WORKER_ARGS=--no-profile run_worker "$d49d" "$tmp/repo49d" "PROJ-9604-N1-capped" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
check "49m a SKIPPED-BANK refusal (exit 11) seeds nothing" "$rc|$([ -e "$(hrow49 scripts/w49d.sh "$tmp/repo49d")" ] && echo row || echo none)" "11|none"

# a judge and a release manager carry none, and a key inherited from the worker that armed them is dropped
out49j="$(HIMMEL_HOLD_KEY=PROJ-1 HIMMEL_HOLD_DOC=/x/y.md HIMMEL_HOLD_LABEL=N99 env -u IMPL_GUARD_OK -u INLINE_IMPL_OK bash "$SCRIPT" --dry-run --judge PROJ-9605-N1-j "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)"
contains "49n a --judge launch carries no key (an inherited one is dropped)" "$out49j" "HIMMEL_HOLD_KEY=<unset> HIMMEL_HOLD_DOC=<unset> HIMMEL_HOLD_LABEL=<unset>"
out49r="$(HIMMEL_HOLD_KEY=PROJ-1 env -u IMPL_GUARD_OK -u INLINE_IMPL_OK -u HIMMEL_RM_EFFORT bash "$SCRIPT" --dry-run --profile release-manager --rm-release v1.1.3 PROJ-9605-N1-rm "$doc_tier_rm" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)"
contains "49o a release-manager launch carries no key" "$out49r" "HIMMEL_HOLD_KEY=<unset> HIMMEL_HOLD_DOC=<unset> HIMMEL_HOLD_LABEL=<unset>"
# a before/after compare of the live register fails when a real worker writes during the run. This suite's rows live in
# the private register under the pinned HOME and name docs under $tmp, a path unique to this run: none may appear in the real one.
h49_priv="$(grep -rlF "$tmp" "$HOME/.himmel/state/holds" 2>/dev/null | grep -c . || true)"
h49_real="$(grep -rlF "$tmp" "$REAL_HOME/.himmel/state/holds" 2>/dev/null | grep -c . || true)"
check "49p the suite's rows are in the private register and none reached the real ~/.himmel/state/holds" "$([ "${h49_priv:-0}" -gt 0 ] && echo private || echo none)|${h49_real:-0}" "private|0"

# --- 50. A launch whose session folder would not load the guard hooks is refused (exit 18) before the
# dry-run report and before every side effect: no preflight/slot, no doc edit, no launch log, no pretrust
# write, no konsole. UNGUARDED_LAUNCH_OK=1 launches it with exactly one WARN. This suite opts in at its top,
# so every row below drops it from its own environment.
scratch50="$tmp/scratch50"; mkdir -p "$scratch50"
doc50="$tmp/PROJ-9026-N3-guard.md"; fx_brief '# guard fixture' > "$doc50"
doc50_sum="$(cksum < "$doc50")"
d50="$tmp/c50"; mk_launch_stubs "$d50" "PROJ-9026-N3-guard"
slots50_before="$(find "$HIMMEL_FLEET_SLOTS" -mindepth 1 2>/dev/null | sort | cksum)"
pre50_before="$(find "$WORKER_SESSION_PRETRUST_HOME" -mindepth 1 2>/dev/null | sort | cksum)"
rm -f "$tmp/rec-preflight50.env"
rc=0; out50="$(some_doc="$doc50" REC_PREFLIGHT_OUT="$tmp/rec-preflight50.env" RUN_WORKER_WRAP="env -u UNGUARDED_LAUNCH_OK" RUN_WORKER_ARGS=--no-profile run_worker "$d50" "$scratch50" "PROJ-9026-N3-guard" "claude-sonnet-5" "$REC_PREFLIGHT" 2>&1)" || rc=$?
sleep 0.3
check "guard_worker_refuses_scratch: exit 18" "$rc" "18"
contains "guard_worker_refuses_scratch: names the launcher and folder" "$out50" "headed-arm-worker: refusing to launch PROJ-9026-N3-guard: $scratch50 does not load the himmel guard hooks (not a git work tree)."
check "guard_worker_refuses_scratch: the launch preflight never ran" "$([ -e "$tmp/rec-preflight50.env" ] && echo ran || echo none)" "none"
check "guard_worker_refuses_scratch: no slot file written" "$(find "$HIMMEL_FLEET_SLOTS" -mindepth 1 2>/dev/null | sort | cksum)" "$slots50_before"
check "guard_worker_refuses_scratch: the doc bytes are unchanged" "$(cksum < "$doc50")" "$doc50_sum"
check "guard_worker_refuses_scratch: no pretrust write" "$(find "$WORKER_SESSION_PRETRUST_HOME" -mindepth 1 2>/dev/null | sort | cksum)" "$pre50_before"
check "guard_worker_refuses_scratch: no launch log" "$([ -e "$HIMMELCTL_CACHE_DIR/launch-logs/PROJ-9026-N3-guard.log" ] && echo log || echo none)" "none"
check "guard_worker_refuses_scratch: the launcher was never exec'd" "$([ -e "$d50/record" ] && echo konsole || echo none)" "none"

rc=0; out50d="$(env -u UNGUARDED_LAUNCH_OK WORKER_SESSION_REPO="$scratch50" bash "$SCRIPT" --dry-run --no-profile PROJ-9026-N3-guard "$doc50" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "guard_worker_dry_run: --dry-run exits 18 too" "$rc" "18"
not_contains "guard_worker_dry_run: no would-exec report" "$out50d" "would exec"

# a resume_cwd worktree of a registered repo folds into the session folder; the folded folder is judged
adopter50="$tmp/adopter50"; mkdir -p "$adopter50"
git -C "$adopter50" init -q
git -C "$adopter50" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$adopter50" worktree add -q -b fix/adopter-50 "$adopter50/.claude/worktrees/fix+adopter-50"
wt50="$adopter50/.claude/worktrees/fix+adopter-50"
reg50="$tmp/reg50.json"; printf '{"repos":{"adopter50":{"path":"%s"}}}\n' "$adopter50" > "$reg50"
fdoc50="$tmp/c50-fold-doc.md"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$wt50" > "$fdoc50"
rc=0; out50f="$(env -u UNGUARDED_LAUNCH_OK HANDOVER_REGISTRY="$reg50" bash "$SCRIPT" --dry-run --no-profile PROJ-9026-N3-fold "$fdoc50" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1)" || rc=$?
check "guard_worker_folded_worktree_checked: exit 18" "$rc" "18"
contains "guard_worker_folded_worktree_checked: the folded worktree is the folder judged" "$out50f" "$wt50 does not load the himmel guard hooks"
contains "guard_worker_folded_worktree_checked: the refusal reason is the check's" "$out50f" "does not load the himmel guard hooks (user guard layer incomplete (run himmelctl ensure))."

# opt-out through the real headed-arm.sh: exactly one WARN across stderr
d50o="$tmp/c50o"; mk_launch_stubs "$d50o" "PROJ-9026-N3-optout"
rc=0; out50o="$(UNGUARDED_LAUNCH_OK=1 some_doc="$doc50" RUN_WORKER_ARGS=--no-profile run_worker "$d50o" "$scratch50" "PROJ-9026-N3-optout" "claude-sonnet-5" 2>&1 >/dev/null)" || rc=$?
wait_record "$d50o" || true
check "optout_chain_single_warn: opted-out launch exits 0" "$rc" "0"
check "optout_chain_single_warn: exactly one WARN reaches stderr" "$(printf '%s\n' "$out50o" | grep -c '^WARN unguarded launch of PROJ-9026-N3-optout')" "1"
contains "optout_chain_single_warn: the WARN names the reason" "$out50o" "WARN unguarded launch of PROJ-9026-N3-optout in $scratch50 (not a git work tree; UNGUARDED_LAUNCH_OK=1)"

# control: the real, fully wired worktree under test launches with the opt-out dropped, and no WARN
gwt50="$(cd "$HERE/../../.." && pwd -P)"
d50g="$tmp/c50g"; mk_launch_stubs "$d50g" "PROJ-9026-N3-ctl"
rc=0; out50g="$(RUN_WORKER_WRAP="env -u UNGUARDED_LAUNCH_OK" some_doc="$doc50" RUN_WORKER_ARGS=--no-profile run_worker "$d50g" "$gwt50" "PROJ-9026-N3-ctl" "claude-sonnet-5" 2>&1 >/dev/null)" || rc=$?
wait_record "$d50g" || true
check "guard_control_worker_passes: guarded folder, opt-out dropped: exit 0, launcher reached" "$rc|$([ -s "$d50g/record" ] && echo konsole || echo none)" "0|konsole"
not_contains "guard_control_worker_passes: no WARN" "$out50g" "WARN unguarded launch"

# --consult is not exempt in code: a consult on an unguarded folder is refused like any launch (its usual
# folder, the chief checkout, passes; a test cannot stand in the checkout, since --consult refuses a worktree cwd)
rc=0; out50c="$(env -u UNGUARDED_LAUNCH_OK WORKER_SESSION_REPO="$scratch50" bash "$SCRIPT" --dry-run --consult --profile design-motion --chief PROJ-9026-chief PROJ-9026-N3-c "$some_doc" /tmp/nosig 99999999999 /tmp/worker.log 2>&1)" || rc=$?
check "consult_guard_applies: a --consult on an unguarded folder exits 18" "$rc" "18"
contains "consult_guard_applies: the refusal names the folder" "$out50c" "$scratch50 does not load the himmel guard hooks"

# --- 51. a launch refused AFTER its fleet slot is reserved releases the reservation it owns ---
# usage-preflight.sh reserves the slot before headed-arm.sh runs; headed-arm.sh can still refuse (a single-writer hold,
# a duplicate name, a ticket rival). Main left the reservation to lapse by TTL, so the chief's relaunch after a grant
# was refused as a duplicate and logged as the fleet cap. The preflight below stands in for the real reserve/duplicate
# shape (mkdir of the worker's slot, the pid file the releasers check, the duplicate refusal text).
RESV51="$tmp/resv51-preflight.sh"
cat > "$RESV51" <<'RESV51_EOF'
#!/usr/bin/env bash
slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"
if ! mkdir "$slots/$CADENCE_USAGE_WORKER" 2>/dev/null; then
  echo "bank-preflight: a fleet reservation for worker=$CADENCE_USAGE_WORKER already exists — refusing as a duplicate declared launch (held by pid ?, expires in 1s; the fleet itself has room)" >&2
  echo SKIPPED-FLEET
  exit 0
fi
printf '%s\n' "$CADENCE_USAGE_CALLER_PID" > "$slots/$CADENCE_USAGE_WORKER/pid"
echo PROCEED
RESV51_EOF
chmod 755 "$RESV51"
# the FLEET_CAP_OK shape: admitted without creating a reservation of its own
NOCREATE51="$tmp/nocreate51-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$NOCREATE51"
chmod 755 "$NOCREATE51"
slot51() { [ -d "$HIMMEL_FLEET_SLOTS/$1" ] && echo held || echo free; }

# 51a-f: the 2026-11-05 sequence through the real headed-arm.sh: refused on a hold, grant, relaunch the same worker
repo51="$tmp/repo51"; mkdir -p "$repo51" "$tmp/hroot49/u/r"
doc51h="$tmp/PROJ-9611-N1-holder.md"; fx_brief '# PROJ-9611 holder' > "$doc51h"
hold49 claim --key PROJ-9611 --label N1 --doc "$doc51h" --repo "$repo51" scripts/w51.sh >/dev/null 2>&1
n51="PROJ-9612-N1-regrant"
doc51="$tmp/$n51.md"; fx_brief "# $n51" '> **Writes:** scripts/w51.sh' > "$doc51"
d51="$tmp/c51"; mk_launch_stubs "$d51" "$n51"
rc=0
HANDOVER_DIR="$tmp/hroot49" some_doc="$doc51" RUN_WORKER_ARGS=--no-profile run_worker "$d51" "$repo51" "$n51" "claude-sonnet-5" "$RESV51" >/dev/null 2>&1 || rc=$?
check "51a a launch whose brief names a held file is refused (exit 2)" "$rc" "2"
check "51b the refused launch leaves no fleet reservation" "$(slot51 "$n51")" "free"
hold49 grant --key PROJ-9612 --repo "$repo51" scripts/w51.sh >/dev/null 2>&1
rc=0
out51b="$(HANDOVER_DIR="$tmp/hroot49" some_doc="$doc51" RUN_WORKER_ARGS=--no-profile run_worker "$d51" "$repo51" "$n51" "claude-sonnet-5" "$RESV51" 2>&1)" || rc=$?
wait_record "$d51" || true
check "51c after the grant the relaunch of the same worker is admitted and launches" "$rc|$([ -s "$d51/record" ] && echo konsole || echo none)" "0|konsole"
not_contains "51d ... and the relaunch is not refused as the fleet cap" "$out51b" "fleet-size cap reached"
not_contains "51e ... nor as a duplicate reservation" "$(cat "$d51/log" 2>/dev/null)" "already exists"
check "51f the admitted launch keeps its reservation (the census consumes it, not the launcher)" "$(slot51 "$n51")" "held"

# 51g: a duplicate-reservation refusal says what it is in the launcher log, and never the fleet cap
n51g="PROJ-9613-N1-dup"; doc51g="$tmp/$n51g.md"; fx_brief "# $n51g" > "$doc51g"
mkdir -p "$HIMMEL_FLEET_SLOTS/$n51g"; printf '%s\n' 424242 > "$HIMMEL_FLEET_SLOTS/$n51g/pid"
tgt51="$tmp/target51.sh"
cat > "$tgt51" <<'TGT51_EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "${HEADED_ARM_CONTEXT_PID:-unset}" > "${TGT51_PIDS:-/dev/null}"
[ -z "${TGT51_WORD:-}" ] || [ -z "${HEADED_ARM_OUTCOME_FILE:-}" ] || printf '%s\n' "$TGT51_WORD" > "$HEADED_ARM_OUTCOME_FILE"
case "${TGT51_MODE:-rc}" in
  hang) exec sleep 60 ;;
  *) exit "${TGT51_RC:-0}" ;;
esac
TGT51_EOF
chmod 755 "$tgt51"
t51() { # t51 <preflight> <name> <doc>
  HEADED_ARM_WORKER_TARGET="$tgt51" HEADED_ARM_WORKER_PREFLIGHT="$1" bash "$SCRIPT" --no-profile "$2" "$3" "$tmp/sig51" "$PAST" "$tmp/log51-$2" claude-sonnet-5-5
}
rc=0; t51 "$RESV51" "$n51g" "$doc51g" >/dev/null 2>&1 || rc=$?
log51g="$(cat "$tmp/log51-$n51g" 2>/dev/null)"
check "51g a duplicate-reservation refusal is exit 10" "$rc" "10"
contains "51h ... and the launcher log names it as a duplicate reservation" "$log51g" "a fleet reservation for this worker already exists"
not_contains "51i ... and does not say the fleet cap was reached" "$log51g" "fleet-size cap reached"
check "51j ... and the other launch's reservation (another pid) is untouched" "$(cat "$HIMMEL_FLEET_SLOTS/$n51g/pid" 2>/dev/null)" "424242"
rm -rf "${HIMMEL_FLEET_SLOTS:?}/$n51g"
# control: a genuine SKIPPED-FLEET with no duplicate text still reads as the fleet cap
rc=0; t51 "$SKIPPED_FLEET_PREFLIGHT" "$n51g" "$doc51g" >/dev/null 2>&1 || rc=$?
contains "51k control: a plain SKIPPED-FLEET still says fleet-size cap reached" "$(cat "$tmp/log51-$n51g" 2>/dev/null)" "fleet-size cap reached"

# 51l-o: the launcher returns headed-arm.sh's status; it releases what it owns on a pre-launch refusal and keeps it
# where a session may really be coming up (7: konsole alive, claude not yet seen; 9: the scan was indeterminate)
for rc51 in 2 16; do
  n51r="PROJ-9614-N1-rc$rc51"; doc51r="$tmp/$n51r.md"; fx_brief "# $n51r" > "$doc51r"
  rc=0; TGT51_RC=$rc51 t51 "$RESV51" "$n51r" "$doc51r" >/dev/null 2>&1 || rc=$?
  check "51l headed-arm.sh exit $rc51 is the launcher's exit, and the reservation is released" "$rc|$(slot51 "$n51r")" "$rc51|free"
done
for rc51 in 7 9; do
  n51r="PROJ-9615-N1-rc$rc51"; doc51r="$tmp/$n51r.md"; fx_brief "# $n51r" > "$doc51r"
  rc=0; TGT51_RC=$rc51 t51 "$RESV51" "$n51r" "$doc51r" >/dev/null 2>&1 || rc=$?
  check "51m headed-arm.sh exit $rc51 (a session may be coming up) is the launcher's exit, and the reservation stays (as on main)" "$rc|$(slot51 "$n51r")" "$rc51|held"
done
n51o="PROJ-9616-N1-ok"; doc51o="$tmp/$n51o.md"; fx_brief "# $n51o" > "$doc51o"
rc=0; t51 "$RESV51" "$n51o" "$doc51o" >/dev/null 2>&1 || rc=$?
check "51n an admitted launch (exit 0) keeps its reservation" "$rc|$(slot51 "$n51o")" "0|held"
# a reservation this launcher did not create (the FLEET_CAP_OK shape) is never released, even on a refusal
n51p="PROJ-9617-N1-foreign"; doc51p="$tmp/$n51p.md"; fx_brief "# $n51p" > "$doc51p"
mkdir -p "$HIMMEL_FLEET_SLOTS/$n51p"; printf '%s\n' 424242 > "$HIMMEL_FLEET_SLOTS/$n51p/pid"
rc=0; TGT51_RC=2 t51 "$NOCREATE51" "$n51p" "$doc51p" >/dev/null 2>&1 || rc=$?
check "51o a refusal leaves a reservation another process owns" "$rc|$(slot51 "$n51p")" "2|held"

# 51p: the --fleet hand-off releases on a refusal too
n51q="PROJ-9618-N1-fleetrel"; doc51q="$tmp/$n51q.md"; fx_brief "# $n51q" > "$doc51q"
rc=0; TGT51_RC=2 HEADED_ARM_WORKER_TARGET="$tgt51" HEADED_ARM_WORKER_PREFLIGHT="$RESV51" bash "$SCRIPT" --no-profile --fleet "$tmp/fleet51.json" "$n51q" "$doc51q" "$tmp/sig51" "$PAST" "$tmp/log51-$n51q" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
check "51p --fleet: an unbound managed launch refuses before reservation" "$rc|$(slot51 "$n51q")" "10|free"

# 51q: the process headed-arm.sh runs as is the process HEADED_ARM_CONTEXT_PID names (headed-arm.sh compares it to its own $$)
n51s="PROJ-9619-N1-pids"; doc51s="$tmp/$n51s.md"; fx_brief "# $n51s" > "$doc51s"
rm -f "$tmp/pids51"
TGT51_PIDS="$tmp/pids51" t51 "$RESV51" "$n51s" "$doc51s" >/dev/null 2>&1 || true
check "51q the launched process is the one HEADED_ARM_CONTEXT_PID names" "$(awk '{ print ($1 == $2) ? "same" : "differ" }' "$tmp/pids51" 2>/dev/null)" "same"

# 51r: TERM to the launcher while headed-arm.sh runs reaches headed-arm.sh, the launcher exits, the reservation is released
n51t="PROJ-9620-N1-term"; doc51t="$tmp/$n51t.md"; fx_brief "# $n51t" > "$doc51t"
rm -f "$tmp/pids51t"
# the launcher itself in the background (a function call would background a subshell, and $! would not be the launcher)
TGT51_MODE=hang TGT51_PIDS="$tmp/pids51t" HEADED_ARM_WORKER_TARGET="$tgt51" HEADED_ARM_WORKER_PREFLIGHT="$RESV51" \
  bash "$SCRIPT" --no-profile "$n51t" "$doc51t" "$tmp/sig51" "$PAST" "$tmp/log51-$n51t" claude-sonnet-5-5 >/dev/null 2>&1 &
lpid51=$!
n=0; while [ ! -s "$tmp/pids51t" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
cpid51="$(awk '{ print $1 }' "$tmp/pids51t" 2>/dev/null)"
kill -TERM "$lpid51" 2>/dev/null
rc=0; wait "$lpid51" 2>/dev/null || rc=$?
n=0; while [ -n "$cpid51" ] && kill -0 "$cpid51" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
check "51r TERM to the launcher: the launched process is gone, not orphaned" "$([ -n "$cpid51" ] && ! kill -0 "$cpid51" 2>/dev/null && echo gone || echo alive)" "gone"
check "51s ... the launcher exits non-zero with the signal status, and the reservation is released" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)|$(slot51 "$n51t")" "nonzero|free"
[ -z "$cpid51" ] || kill -KILL "$cpid51" 2>/dev/null || true

LR="$HOME/.himmel/launch-refusals.jsonl"
rm -f "$LR"
term() { jq -c 'select(.outcome != "attempt-started")' "$LR" 2>/dev/null; }
rc=0; run45 in PROJ-45-in HIMMEL-chief-45-other || rc=$?
check "9625a the refused launch still exits 2" "$rc" "2"
check "9625a one terminal row, whole: v, source, kind, name, outcome, phase, cause, rc" "$(term | jq -r '[.v, .source, .kind, .name, .outcome, .phase, .cause, .rc] | join(" ")' | tr '\n' '|')" "2 headed-arm-worker launch-attempt PROJ-45-in refused bus-registration bus-register 2|"
check "9625a the row carries the keys in order" "$(term | jq -c 'keys_unsorted' | head -1)" '["v","ts","host","source","kind","name","attempt_id","phase","outcome","cause","rc","line"]'
check "9625a ts is a UTC second stamp" "$(term | jq -r '.ts' | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
check "9625a the line holds the refusal reason" "$(term | jq -r '.line | type' | head -1)" "string"
check "9625a the attempt started before it was refused: two rows, one attempt_id" "$(jq -r '.outcome' "$LR" | tr '\n' ' ')|$(jq -r '.attempt_id' "$LR" | sort -u | wc -l | tr -d ' ')" "attempt-started refused |1"
n9625b="$(term | wc -l | tr -d ' ')"
rc=0; run45 in PROJ-45-in || rc=$?
check "9625-base control: the admitted launch exits 0" "$rc" "0"
check "9625-base an admitted launch whose child names no result is one indeterminate attempt, never launched" "$(( $(term | wc -l | tr -d ' ') - n9625b ))|$(term | tail -n 1 | jq -r '[.outcome, .phase, .rc] | join(" ")')" "1|indeterminate handoff 0"
check "9625-base two launches are two attempt ids" "$(jq -r '.attempt_id' "$LR" | sort -u | wc -l | tr -d ' ')" "2"

lr_n() { if [ -f "$LR" ]; then term | wc -l | tr -d ' '; else echo 0; fi; }
lr_last() { term | tail -n 1 | jq -r "$1" 2>/dev/null; }
lr_expect() {
  check "9625-cause $1: the launcher exits $3" "$4" "$3"
  check "9625-cause $1: one row, cause $2, rc $3" "$(( $(lr_n) - $5 ))|$(lr_last '[.cause,.rc]|join(" ")')" "1|$2 $3"
}
lr_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; fi; }  # read-sink-ok: counts lines of a scratch ledger this suite names
lr_none() { check "9625-skip $1: no row" "$(( $(lr_n) - $2 ))" "0"; }

doc9625_np="$tmp/PROJ-9625-np.md"; printf '%s\n' '---' 'description: no prior art' '---' '# no prior art line' > "$doc9625_np"
doc9625_ok="$tmp/PROJ-9625-ok.md"; fx_brief '# ok' > "$doc9625_ok"
b="$(lr_n)"; rc=0; t51 "$PROCEED_PREFLIGHT" PROJ-9625-N1-lint "$doc9625_np" >/dev/null 2>&1 || rc=$?
lr_expect brief-lint brief-lint 2 "$rc" "$b"
check "9625-cause brief-lint: the line is the lint's first line" "$(lr_last '.line|type')" "string"
b="$(lr_n)"; rc=0; t51 "$SKIPPED_FLEET_PREFLIGHT" PROJ-9625-N2-cap "$doc9625_ok" >/dev/null 2>&1 || rc=$?
lr_expect fleet-cap fleet-cap 10 "$rc" "$b"
n9625d="PROJ-9625-N3-dup"; mkdir -p "$HIMMEL_FLEET_SLOTS/$n9625d"; printf '%s\n' 424242 > "$HIMMEL_FLEET_SLOTS/$n9625d/pid"
b="$(lr_n)"; rc=0; t51 "$RESV51" "$n9625d" "$doc9625_ok" >/dev/null 2>&1 || rc=$?
lr_expect fleet-duplicate fleet-duplicate 10 "$rc" "$b"
rm -rf "${HIMMEL_FLEET_SLOTS:?}/$n9625d"
b="$(lr_n)"; rc=0; t51 "$SKIPPED_BANK_PREFLIGHT" PROJ-9625-N4-bank "$doc9625_ok" >/dev/null 2>&1 || rc=$?
lr_expect bank-exhausted bank-exhausted 11 "$rc" "$b"
rm -rf "${HIMMEL_FLEET_SLOTS:?}/PROJ-9625-N4-bank"
rm -rf "$acks38"; page38 feat+worker-38 SHIP-STEP "$(( $(date +%s) - 30 ))"
b="$(lr_n)"; rc=0; bash "$SCRIPT" --no-profile PROJ-38-worker "$doc38" /tmp/nosig 99999999999 "$tmp/c9625-38.log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
lr_expect denial-unacked denial-unacked 14 "$rc" "$b"
b="$(lr_n)"; rc=0; bash "$SCRIPT" --dry-run --no-profile PROJ-38-worker "$doc38" /tmp/nosig 99999999999 "$tmp/c9625-38.log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
check "9625-skip --dry-run: the same refusal exits 14" "$rc" "14"
lr_none "--dry-run on a refusal (the control is the denial-unacked row just above)" "$b"
rm -rf "$acks38"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$root39/u/himmel/scratch" > "$tmp/c9625-39-doc.md"
b="$(lr_n)"; rc=0; bash "$SCRIPT" --no-profile PROJ-39-worker "$tmp/c9625-39-doc.md" /tmp/nosig 99999999999 "$tmp/c9625-39.log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
lr_expect handover-root handover-root 15 "$rc" "$b"
b="$(lr_n)"; rc=0; some_doc="$doc50" REC_PREFLIGHT_OUT="$tmp/rec-preflight9625.env" RUN_WORKER_WRAP="env -u UNGUARDED_LAUNCH_OK" RUN_WORKER_ARGS=--no-profile run_worker "$d50" "$scratch50" "PROJ-9026-N3-guard" "claude-sonnet-5" "$REC_PREFLIGHT" >/dev/null 2>&1 || rc=$?
lr_expect unguarded-checkout unguarded-checkout 18 "$rc" "$b"
for pair in 3:headed-arm:refused 7:konsole-up-claude-unseen:indeterminate 9:dedup-indeterminate:refused 137:headed-arm:refused; do
  crc="${pair%%:*}"; rest="${pair#*:}"; ccause="${rest%%:*}"; cout="${rest#*:}"
  b="$(lr_n)"; rc=0; TGT51_RC=$crc t51 "$PROCEED_PREFLIGHT" "PROJ-9625-N6-child$crc" "$doc9625_ok" >/dev/null 2>&1 || rc=$?
  lr_expect "headed-arm child $crc" "$ccause" "$crc" "$rc" "$b"
  check "9625-cause headed-arm child $crc: outcome $cout in the handoff phase, no line" "$(lr_last '[.outcome, .phase, (.line|type)] | join(" ")')" "$cout handoff null"
done
for w in launched already-running; do
  b="$(lr_n)"; rc=0; TGT51_WORD=$w t51 "$PROCEED_PREFLIGHT" "PROJ-9696-N1-$w" "$doc9625_ok" >/dev/null 2>&1 || rc=$?
  check "9696-typed exit 0 with the child's word $w: one terminal row, outcome $w" "$rc|$(( $(lr_n) - b ))|$(lr_last '[.outcome, .phase, .rc] | join(" ")')" "0|1|$w handoff 0"
done
b="$(lr_n)"; rc=0; TGT51_WORD=launched TGT51_RC=3 t51 "$PROCEED_PREFLIGHT" "PROJ-9696-N2-word-rc3" "$doc9625_ok" >/dev/null 2>&1 || rc=$?
check "9696-typed a non-zero exit is never launched, whatever the child wrote" "$rc|$(lr_last '.outcome')" "3|refused"
bus9625_name="PROJ-9625-$(printf 'x%.0s' $(seq 1 130))"
rm -f "$bus45/seen" "$bus45/bus-called"
b="$(lr_n)"; rc=0; XDG_STATE_HOME="$bus45/state" HEADED_ARM_BUS_CLI="$bus9537_stub" HEADED_ARM_WORKER_TARGET="$bus45/headed" HEADED_ARM_WORKER_PROFILES="$bus45/profiles-in.mjs" \
  HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" bash "$SCRIPT" --profile worker-impl --chief HIMMEL-chief-45 "$bus9625_name" "$some_doc" "$bus45/signal" "$PAST" "$bus45/log" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
lr_expect bus-name-too-long bus-name-too-long 2 "$rc" "$b"
b="$(lr_n)"; rc=0; bash "$SCRIPT" --bogus-flag >/dev/null 2>&1 || rc=$?
lr_expect other other 2 "$rc" "$b"
check "9625-cause other: no name and no line are null" "$(lr_last '[(.name|type),(.line|type)]|join(" ")')" "null null"

b="$(lr_n)"; rc=0; bash "$SCRIPT" --bogus-flag --dry-run >/dev/null 2>&1 || rc=$?
check "9625-skip --dry-run after an in-loop argument error: the launcher exits 2" "$rc" "2"
lr_none "--dry-run after an in-loop argument error (the control is the other row above)" "$b"
if command -v flock >/dev/null 2>&1; then
  fleet9625() {
    FLEET_TEST_MANIFEST="$tmp/none-manifest" HEADED_ARM_WORKER_TARGET="$fleet_target" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
      bash "$SCRIPT" --no-profile --fleet "$1" "$2" "$doc9625_ok" "$tmp/fleet9625-sig" "$PAST" "$tmp/fleet9625-log" claude-sonnet-5-5
  }
  mkdir -p "$tmp/fleet9625-dir"
  b="$(lr_n)"; rc=0; out9625f="$(fleet9625 "$tmp/fleet9625-dir" worker-fleet-seven 2>&1)" || rc=$?
  check "9625-skip invalid --fleet reference refuses before handoff" "$rc|$(printf '%s\n' "$out9625f" | grep -c 'fleet-paused')" "10|1"
  check "9696-postlaunch invalid reference has one definite refusal receipt" "$(( $(lr_n) - b ))|$(lr_last '[.outcome, .phase, .cause] | join(" ")')" "1|refused usage-preflight fleet-paused"
  b="$(lr_n)"; rc=0; FLEET_TEST_RC=3 fleet9625 "$tmp/fleet9625-dir" PROJ-3748-N8-fleet >/dev/null 2>&1 || rc=$?
  lr_expect "--fleet missing control precedes child status" fleet-paused 10 "$rc" "$b"
else
  echo "SKIP - 9625-skip --fleet manifest failure (fleet-manifest.sh needs util-linux flock, absent here)"
fi
n9625t="PROJ-9625-N9-term"; doc9625t="$tmp/$n9625t.md"; fx_brief "# $n9625t" > "$doc9625t"; rm -f "$tmp/pids9625t"
b="$(lr_n)"
TGT51_MODE=hang TGT51_PIDS="$tmp/pids9625t" HEADED_ARM_WORKER_TARGET="$tgt51" HEADED_ARM_WORKER_PREFLIGHT="$RESV51" \
  bash "$SCRIPT" --no-profile "$n9625t" "$doc9625t" "$tmp/sig9625" "$PAST" "$tmp/log9625-$n9625t" claude-sonnet-5-5 >/dev/null 2>&1 &
lpid9625=$!
n=0; while [ ! -s "$tmp/pids9625t" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
cpid9625="$(awk '{ print $1 }' "$tmp/pids9625t" 2>/dev/null)"
kill -TERM "$lpid9625" 2>/dev/null
rc=0; wait "$lpid9625" 2>/dev/null || rc=$?
check "9625-skip forwarded TERM: the launcher exits non-zero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "9696-signal a forwarded TERM: one indeterminate attempt in the handoff phase, cause signal, never a refusal" "$(( $(lr_n) - b ))|$(lr_last '[.outcome, .phase, .cause] | join(" ")')" "1|indeterminate handoff signal"
# A launcher killed outright runs no EXIT trap: its attempt stays attempt-started, which a reader counts as unknown.
n9696k="PROJ-9696-N3-kill"; doc9696k="$tmp/$n9696k.md"; fx_brief "# $n9696k" > "$doc9696k"; rm -f "$tmp/pids9696k"
TGT51_MODE=hang TGT51_PIDS="$tmp/pids9696k" HEADED_ARM_WORKER_TARGET="$tgt51" HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT" \
  bash "$SCRIPT" --no-profile "$n9696k" "$doc9696k" "$tmp/sig9696k" "$PAST" "$tmp/log9696-$n9696k" claude-sonnet-5-5 >/dev/null 2>&1 &
lpid9696=$!
n=0; while [ ! -s "$tmp/pids9696k" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
cpid9696="$(awk '{ print $1 }' "$tmp/pids9696k" 2>/dev/null)"
kill -KILL "$lpid9696" 2>/dev/null; wait "$lpid9696" 2>/dev/null
check "9696-kill a killed launcher leaves its attempt started and nothing else" "$(jq -r --arg n "$n9696k" 'select(.name == $n) | .outcome' "$LR" | tr '\n' ' ')" "attempt-started "
[ -z "$cpid9696" ] || kill -KILL "$cpid9696" 2>/dev/null || true
[ -z "$cpid9625" ] || kill -KILL "$cpid9625" 2>/dev/null || true

b="$(lr_n)"; rc=0; HOSTNAME=$'h"o\\st\tx\xc3\xa9\nsecond' bash "$SCRIPT" --bogus-flag >/dev/null 2>&1 || rc=$?
check "9625-enc host with a quote, a backslash, a tab, non-ASCII and a newline: one valid row, first line only, ASCII" "$(( $(lr_n) - b ))|$(lr_last '.host')" '1|h"o\st?x??'
b="$(lr_n)"; rc=0; bash "$SCRIPT" --no-profile "PROJ-9625-\"q\\z" "$doc9625_np" "$tmp/sig9625" "$PAST" "$tmp/log9625-q" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
check "9625-enc name with a quote and a backslash: one valid row, name exact" "$(( $(lr_n) - b ))|$(lr_last '.name')" '1|PROJ-9625-"q\z'
b="$(lr_n)"; rc=0; bash "$SCRIPT" --no-profile "PROJ-9625-$(printf 'x%.0s' $(seq 1 300))" "$doc9625_np" "$tmp/sig9625" "$PAST" "$tmp/log9625-long" claude-sonnet-5-5 >/dev/null 2>&1 || rc=$?
check "9625-enc a 300-byte name is cut to 128 bytes" "$(( $(lr_n) - b ))|$(lr_last '.name|length')" "1|128"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 1\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$root39/u/himmel/$(printf 'a%.0s' $(seq 1 250))" > "$tmp/c9625-39b-doc.md"
b="$(lr_n)"; rc=0; HOSTNAME="$(printf 'h%.0s' $(seq 1 100))" bash "$SCRIPT" --no-profile PROJ-39-worker "$tmp/c9625-39b-doc.md" /tmp/nosig 99999999999 "$tmp/c9625-39b.log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
check "9625-enc a long refusal line is cut to 200 bytes and a long host to 64" "$(( $(lr_n) - b ))|$(lr_last '[(.line|length),(.host|length)]|join(" ")')" "1|200 64"
check "9625-enc the largest row is under 1,000 bytes" "$([ "$(tail -n 1 "$LR" | wc -c)" -lt 1000 ] && echo small || echo big)" "small"

okhome9625="$tmp/okhome9625"; mkdir -p "$okhome9625"
out_ok9625="$(HOME="$okhome9625" bash "$SCRIPT" --bogus-flag 2>&1)" || rc_ok9625=$?
check "9625-robust control: a good HOME gets the row, the refusal exits 2" "${rc_ok9625:-0}|$(lr_lines "$okhome9625/.himmel/launch-refusals.jsonl")" "2|1"
robust9625() {
  local label="$1"; shift; local rcx=0 outx
  outx="$(env "$@" bash "$SCRIPT" --bogus-flag 2>&1)" || rcx=$?
  check "9625-robust $label: the exit status is 2" "$rcx" "2"
  check "9625-robust $label: the output is the control's, byte for byte" "$outx" "$out_ok9625"
}
badhome9625="$tmp/badhome9625"; mkdir -p "$badhome9625"; : > "$badhome9625/.himmel"
robust9625 "a ledger directory that cannot be made (a file in its place)" HOME="$badhome9625"
robust9625 "an empty HOME" HOME=
roghome9625="$tmp/roghome9625"; mkdir -p "$roghome9625/.himmel"; : > "$roghome9625/.himmel/launch-refusals.jsonl"; chmod 444 "$roghome9625/.himmel/launch-refusals.jsonl"
if [ "$(id -u)" -ne 0 ]; then
  robust9625 "a read-only ledger" HOME="$roghome9625"
  check "9625-robust a read-only ledger stays empty" "$(wc -c < "$roghome9625/.himmel/launch-refusals.jsonl" | tr -d ' ')" "0"
else
  echo "SKIP - 9625-robust read-only ledger (root ignores the mode)"
fi
shim9625="$tmp/shim9625"; mkdir -p "$shim9625"
printf '#!/bin/sh\nexit 1\n' > "$shim9625/tr"; printf '#!/bin/sh\nexit 1\n' > "$shim9625/date"; chmod 755 "$shim9625/tr" "$shim9625/date"
bad9625="$tmp/bad9625"; mkdir -p "$bad9625"
robust9625 "a failing tr" HOME="$bad9625" PATH="$shim9625:$PATH"
check "9625-robust a failing tr writes no row" "$(lr_lines "$bad9625/.himmel/launch-refusals.jsonl")" ""
bad9625b="$tmp/bad9625b"; mkdir -p "$bad9625b"; rm -f "$shim9625/tr"
robust9625 "a failing date" HOME="$bad9625b" PATH="$shim9625:$PATH"
check "9625-robust a failing date (an empty ts) writes no row" "$(lr_lines "$bad9625b/.himmel/launch-refusals.jsonl")" ""

mkdir -p "$tmp/repo52"
s52() {
  local d="$1" nm="$2" sig="$3" pf="$4"; shift 4
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$pf" \
  KONSOLE_CMD="$d/konsole" PGREP_CMD="$d/pgrep" \
  WORKER_SESSION_REPO="$tmp/repo52" HEADED_ARM_LOCK_DIR="$d/locks" HEADED_ARM_PROC="$d/proc" \
    bash "$SCRIPT" --profile worker-impl "$@" "$nm" "$some_doc" "$sig" "$(( $(date +%s) + 3600 ))" "$d/log" claude-sonnet-5
}
log52() { cat "$1/log" 2>/dev/null || true; }

n52a="PROJ-10718-N1-signal"; d52a="$tmp/c52a"; mk_launch_stubs "$d52a" "$n52a"; mkdir -p "$d52a/sigdir"
rc=0; s52 "$d52a" "$n52a" "$d52a/sigdir/sig" "$PROCEED_PREFLIGHT" >/dev/null 2>&1 || rc=$?
wait_record "$d52a" || true
check "52a a launch nobody signals exits 0 (the launcher wrote the signal itself)" "$rc" "0"
contains "52a ... and the waiter saw the signal" "$(log52 "$d52a")" "signal seen"
not_contains "52a ... and did not wait for its deadline" "$(log52 "$d52a")" "deadline reached"
check "52a ... the konsole record exists and the signal file exists" "$([ -s "$d52a/record" ] && echo record || echo none)|$([ -e "$d52a/sigdir/sig" ] && echo sig || echo none)" "record|sig"
pkill -f -- "$d52a/log" 2>/dev/null || true

n52b="PROJ-10718-N2-nowrite"; d52b="$tmp/c52b"; mk_launch_stubs "$d52b" "$n52b"
b="$(lr_n)"; rc=0; s52 "$d52b" "$n52b" "$d52b/missing-dir/sig" "$RESV51" >/dev/null 2>&1 || rc=$?
check "52b a signal that cannot be written refuses the launch (exit 2)" "$rc" "2"
check "52b ... on a LAUNCH-REFUSED line that says so" "$(log52 "$d52b" | grep -c 'LAUNCH-REFUSED.*cannot write the start signal')" "1"
check "52b ... no konsole was started" "$([ -s "$d52b/record" ] && echo konsole || echo none)" "none"
check "52b ... the fleet reservation is released" "$(slot51 "$n52b")" "free"
check "52b ... one definite refusal receipt: cause start-signal, phase handoff, outcome refused, rc 2" "$(( $(lr_n) - b ))|$(lr_last '[.cause,.phase,.outcome,.rc]|join(" ")')" "1|start-signal handoff refused 2"
pkill -f -- "$d52b/log" 2>/dev/null || true
mkdir -p "$d52b/missing-dir"
rc=0; s52 "$d52b" "$n52b" "$d52b/missing-dir/sig" "$RESV51" >/dev/null 2>&1 || rc=$?
wait_record "$d52b" || true
check "52b the relaunch of the same name is admitted and launches" "$rc|$([ -s "$d52b/record" ] && echo konsole || echo none)" "0|konsole"
not_contains "52b ... and is not refused as a duplicate reservation" "$(log52 "$d52b")" "already exists"
pkill -f -- "$d52b/log" 2>/dev/null || true

n52c="PROJ-10718-N3-dry"; d52c="$tmp/c52c"; mk_launch_stubs "$d52c" "$n52c"; mkdir -p "$d52c/sigdir"
rc=0; s52 "$d52c" "$n52c" "$d52c/sigdir/sig" "$PROCEED_PREFLIGHT" --dry-run >/dev/null 2>&1 || rc=$?
check "52c --dry-run exits 0 and writes no signal file" "$rc|$([ -e "$d52c/sigdir/sig" ] && echo sig || echo none)" "0|none"
pkill -f -- "$d52c/log" 2>/dev/null || true

n52d="PROJ-10718-N4-capped"; d52d="$tmp/c52d"; mk_launch_stubs "$d52d" "$n52d"; mkdir -p "$d52d/sigdir"
rc=0; s52 "$d52d" "$n52d" "$d52d/sigdir/sig" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
check "52d a launch refused at admission (fleet cap) exits 10 and writes no signal file" "$rc|$([ -e "$d52d/sigdir/sig" ] && echo sig || echo none)" "10|none"
pkill -f -- "$d52d/log" 2>/dev/null || true

n52e="PROJ-10718-N5-present"; d52e="$tmp/c52e"; mk_launch_stubs "$d52e" "$n52e"; mkdir -p "$d52e/sigdir"
: > "$d52e/sigdir/sig"; chmod 444 "$d52e/sigdir/sig"
if [ "$(id -u)" -ne 0 ]; then
  rc=0; s52 "$d52e" "$n52e" "$d52e/sigdir/sig" "$PROCEED_PREFLIGHT" >/dev/null 2>&1 || rc=$?
  wait_record "$d52e" || true
  check "52e a signal file that already exists but is read-only is left alone and the launch goes on" "$rc" "0"
  contains "52e ... and the waiter saw the signal" "$(log52 "$d52e")" "signal seen"
  pkill -f -- "$d52e/log" 2>/dev/null || true
else
  echo "SKIP - 52e under root (an append to a mode-0444 file succeeds, so the row cannot fail)"
fi

mkdir -p "$tmp/needs-jira"
cat > "$tmp/needs-jira/index.js" <<'NNEOF'
const fs = require('fs');
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') process.stdout.write(fs.readFileSync(process.env.NEEDS_GOLDEN, 'utf8'));
else if (a[0] === 'release' && a[1] === 'bucket-check') for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NNEOF
fx_brief '# HIMMEL-9640 — a bypass fixture' > "$tmp/needs-doc.md"
rc=0; needs_out="$(NEEDS_GOLDEN="$HERE/../../jira/src/release/fixtures/bypass-needs-spec.line" BRIEF_LINT_JIRA_CLI="$tmp/needs-jira/index.js" door_run "$tmp/needs-doc.md")" || rc=$?
check "9564-a a BYPASS-NEEDS-SPEC brief is refused at launch (exit 2)" "$rc" "2"
contains "9564-b ... the refusal is relayed as 'refusing launch:'" "$needs_out" "refusing launch:"
contains "9564-c ... and names the missing record" "$needs_out" "no spec-review record"

# --- 17r. The readiness launcher (C0s cycle 1): worker-claude-launcher.sh is the ONE owner of the
# final claude argv for the readiness role. Its real exec and its validation-only render (an env
# switch that prints the same array NUL-terminated and execs nothing) come from one construction, so
# every case below drives the REAL shim against a recording stub: the stub is the seam, the shim and
# the profile wrapper are not stubbed. This section proves the argv owner alone (the wrapper's own use of it is
# 17s below). Each case runs under `env -i`, so no ambient role marker leaks in.
RL="$tmp/rl"; mkdir -p "$RL/home/.claude" "$RL/bin" "$RL/other"
rl_stub="$RL/bin/claude"
# shellcheck disable=SC2016 # literal $@ and $0 belong to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "[%s]" "$@" >> "$(dirname "$0")/argv-record"; echo >> "$(dirname "$0")/argv-record"' > "$rl_stub"
chmod 755 "$rl_stub"
rl_rec="$RL/bin/argv-record"
rl_settings="$RL/settings.json"
rl_grants='"mcp__readiness__inspect","mcp__readiness__act"'
rl_deny='"Agent","Artifact","Bash","Edit","Glob","Grep","NotebookEdit","Read","WebFetch","WebSearch","Write"'
printf '{"enabledPlugins":{},"permissions":{"allow":[%s],"deny":[%s]}}\n' "$rl_grants" "$rl_deny" > "$rl_settings"
rl_sid="11111111-2222-4333-8444-555555555555"
# the --session-id is bound to the trusted private startup config: the adapter starts against one private file
# (mode 0600, in a mode-0700 directory) whose session scope is the minted id
rl_att="$RL/attempt"; mkdir -p "$rl_att"; chmod 700 "$rl_att"
printf '{"schema":"readiness-startup-v1","lane":"native","session_scope":"%s"}\n' "$rl_sid" > "$rl_att/startup.json"; chmod 600 "$rl_att/startup.json"
rl_adapter="$(cd "$HERE" && pwd -P)/readiness-tools.mjs"
rl_mcp="$RL/mcp.json"
printf '{"mcpServers":{"readiness":{"command":"node","args":["%s","--startup-config","%s/startup.json"]}}}\n' "$rl_adapter" "$rl_att" > "$rl_mcp"
rl_caller_default=(--model claude-sonnet-5-5 --autocompact 200000 -n PROJ-9999-readiness "load doc and continue")
rl_tail_default='[--model][claude-sonnet-5-5][--autocompact][200000][-n][PROJ-9999-readiness][load doc and continue]'
# rl_run [ENV=val ...] [-- caller argv ...]: later ENV=val wins; an empty value reads as unset.
rl_run() {
  local envs=() caller=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  if [ "${1:-}" = -- ]; then shift; caller=("$@"); else caller=("${rl_caller_default[@]}"); fi
  env -i PATH="$PATH" HOME="$RL/home" WORKER_SESSION_CLAUDE_BIN="$rl_stub" WORKER_SESSION_PROFILE_READINESS=1 \
    WORKER_SESSION_PROFILE_SETTINGS="$rl_settings" WORKER_SESSION_PROFILE_MCP_CONFIG="$rl_mcp" WORKER_SESSION_ID="$rl_sid" \
    ${envs[@]+"${envs[@]}"} bash "$SHIM" ${caller[@]+"${caller[@]}"}
}
rl_decode() { local el; while IFS= read -r -d '' el; do printf '[%s]' "$el"; done; printf '\n'; }
rl_pre="[--settings][$rl_settings][--mcp-config][$rl_mcp][--strict-mcp-config][--tools][][--permission-mode][auto][--allowedTools][mcp__readiness__inspect][mcp__readiness__act][--session-id][$rl_sid]"

# the exec path: exactly the signed hard-boundary argv, then the caller's argv untouched and in order
rm -f "$rl_rec"; rc=0
rl_run >/dev/null 2>&1 || rc=$?
check "readiness exec: exit 0" "$rc" "0"
check "readiness exec: empty --tools, strict immutable MCP config, exactly the two grants, one explicit auto mode, then the caller argv in order" \
  "$(cat "$rl_rec" 2>/dev/null || true)" "$rl_pre$rl_tail_default"

# the render path: the SAME array, NUL-terminated (the empty --tools value survives), and nothing executed
rm -f "$rl_rec"; rc=0
rl_run WORKER_SESSION_RENDER_ARGV=1 > "$RL/render.out" 2>/dev/null || rc=$?
check "readiness render: exit 0" "$rc" "0"
check "readiness render: the stub was never executed" "$(cat "$rl_rec" 2>/dev/null || true)" ""
check "readiness render: the array is binary + the exact exec argv (one construction)" \
  "$(rl_decode < "$RL/render.out")" "[$rl_stub]$rl_pre$rl_tail_default"
check "readiness render: every element is NUL-terminated, the empty --tools value included (one NUL per element)" \
  "$(tr -dc '\0' < "$RL/render.out" | wc -c | tr -d ' ')" "$(( $(grep -o '\]\[' <<< "[$rl_stub]$rl_pre$rl_tail_default" | wc -l) + 1 ))"

# a caller that already carries exactly one auto mode keeps it in place; none is added
for mode_args in "--permission-mode auto" "--permission-mode=auto"; do
  rm -f "$rl_rec"; rc=0
  # shellcheck disable=SC2086 # the mode spelling splits into its flag and value on purpose
  rl_run -- --model claude-sonnet-5-5 $mode_args "load doc" >/dev/null 2>&1 || rc=$?
  want_mode="[--permission-mode][auto]"; case "$mode_args" in *=*) want_mode="[--permission-mode=auto]" ;; esac
  check "readiness '$mode_args': exit 0" "$rc" "0"
  check "readiness '$mode_args': the caller's one auto mode is preserved in place, nothing else adds a mode" \
    "$(cat "$rl_rec" 2>/dev/null || true)" "[--settings][$rl_settings][--mcp-config][$rl_mcp][--strict-mcp-config][--tools][][--allowedTools][mcp__readiness__inspect][mcp__readiness__act][--session-id][$rl_sid][--model][claude-sonnet-5-5]${want_mode}[load doc]"
done

# a bare positional prompt still never sits next to a variadic option's values: a flag always follows the grants
rm -f "$rl_rec"; rl_run -- "load doc" >/dev/null 2>&1 || true
check "readiness: a caller whose argv starts with a bare prompt keeps a flag between the grants and the prompt" \
  "$(cat "$rl_rec" 2>/dev/null || true)" "${rl_pre}[load doc]"

# the shipped profile, resolved by the REAL profile wrapper under a scratch HOME, drives the launcher unchanged
rl_real="$(env HOME="$RL/home" CLAUDE_CONFIG_DIR="$RL/home/.claude" HIMMEL_PROFILE_SETTINGS_DIR="$RL/prof" bash "$HERE/../../lanes/profile-settings.sh" readiness 2>/dev/null || true)"
rm -f "$rl_rec"; rc=0
rl_run WORKER_SESSION_PROFILE_SETTINGS="$rl_real" >/dev/null 2>&1 || rc=$?
check "readiness: the shipped profile's real resolved settings pass the launcher (exit 0)" "$rc" "0"
check "readiness: ... and the argv names that resolved settings file" \
  "$(cat "$rl_rec" 2>/dev/null || true)" "[--settings][$rl_real]${rl_pre#"[--settings][$rl_settings]"}$rl_tail_default"

# existing behavior is untouched: without the marker the same inputs give the old prepend-only argv
rm -f "$rl_rec"; rc=0
rl_run WORKER_SESSION_PROFILE_READINESS= >/dev/null 2>&1 || rc=$?
check "readiness off: exit 0" "$rc" "0"
check "readiness off: prepend-only, no --tools, no --permission-mode, no --allowedTools (old contract)" \
  "$(cat "$rl_rec" 2>/dev/null || true)" "[--settings][$rl_settings][--mcp-config][$rl_mcp][--strict-mcp-config][--session-id][$rl_sid]$rl_tail_default"
rm -f "$rl_rec"
env -i PATH="$PATH" WORKER_SESSION_CLAUDE_BIN="$rl_stub" bash "$SHIM" --model claude-sonnet-5-5 "load doc" >/dev/null 2>&1 || true
check "readiness off: no profile at all is still a byte-identical pass-through" "$(cat "$rl_rec" 2>/dev/null || true)" "[--model][claude-sonnet-5-5][load doc]"

# every refusal is exit 2, executes nothing and renders nothing
rl_refuse() { # rl_refuse <label> [ENV=val ...] [-- caller argv ...]
  local label="$1" rrc=0; shift
  rm -f "$rl_rec"; rl_run "$@" >/dev/null 2>&1 || rrc=$?
  check "readiness refuses $label (exec: exit 2)" "$rrc" "2"
  check "readiness refuses $label (exec: nothing ran)" "$(cat "$rl_rec" 2>/dev/null || true)" ""
  rrc=0; rl_run WORKER_SESSION_RENDER_ARGV=1 "$@" > "$RL/refused.out" 2>/dev/null || rrc=$?
  check "readiness refuses $label (render: exit 2)" "$rrc" "2"
  check "readiness refuses $label (render: no argv emitted)" "$(wc -c < "$RL/refused.out" | tr -d ' ')" "0"
}
for bad_mode in "--permission-mode default" "--permission-mode plan" "--permission-mode bypassPermissions" "--permission-mode acceptEdits" "--permission-mode" "--permission-mode=default" "--permission-mode auto --permission-mode auto" "--permission-mode=auto --permission-mode auto" "--dangerously-skip-permissions" "--allow-dangerously-skip-permissions"; do
  # shellcheck disable=SC2086 # the spelling splits into flag and value on purpose
  rl_refuse "a conflicting or duplicate mode ($bad_mode)" -- --model claude-sonnet-5-5 $bad_mode "load doc"
done
for override in "--tools Bash" "--tools=Bash" "--allowedTools Bash" "--allowed-tools Bash" "--disallowedTools X" "--disallowed-tools X" "--settings /x" "--setting-sources user" "--mcp-config /x" "--strict-mcp-config" "--session-id x" "--plugin-dir /x" "--agents {}" "-p" "--print" "--bg" "--resume old" "-r old" "--continue" "-c" "--fork-session" "--agent other" "--remote-control other" "--from-pr 5" "--add-dir /x" "--chrome" "--system-prompt other" "--bare" "--channels other" "--unknown-future-option"; do
  # shellcheck disable=SC2086 # the spelling splits into flag and value on purpose
  rl_refuse "a caller override ($override)" -- --model claude-sonnet-5-5 $override "load doc"
done
rl_refuse "lane claudex" WORKER_SESSION_LANE=claudex
rl_refuse "lane openrouter" WORKER_SESSION_LANE=openrouter
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$RL/other/claude-codex"; chmod 755 "$RL/other/claude-codex"
rl_refuse "a lane launcher binary (claude-codex)" WORKER_SESSION_CLAUDE_BIN="$RL/other/claude-codex"
rl_refuse "a missing binary" WORKER_SESSION_CLAUDE_BIN="$RL/other/no-such-claude"
rl_refuse "a relative binary" WORKER_SESSION_CLAUDE_BIN=bin/claude
for marker in HIMMEL_CONSOLE_JUDGE=1 HIMMEL_CONSOLE_RELAY=1 HIMMEL_RELEASE_MANAGER=1 CHIEF_CONTEXT=1m WORKER_SESSION_PROFILE_NO_SETTING_SOURCES=1 WORKER_SESSION_REMOTE_CONTROL=name; do
  rl_refuse "a mixed role (${marker%%=*})" "$marker"
done
rl_refuse "a marker that is not exactly 1 (yes)" WORKER_SESSION_PROFILE_READINESS=yes
rl_refuse "a marker that is not exactly 1 (0)" WORKER_SESSION_PROFILE_READINESS=0
rl_refuse "no settings file" WORKER_SESSION_PROFILE_SETTINGS=
rl_refuse "a missing settings file" WORKER_SESSION_PROFILE_SETTINGS="$RL/no-such-settings.json"
rl_refuse "no MCP config" WORKER_SESSION_PROFILE_MCP_CONFIG=
rl_refuse "a missing MCP config" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/no-such-mcp.json"
rl_refuse "no session id" WORKER_SESSION_ID=
printf '{"mcpServers":{"readiness":{"command":"node"},"qmd":{"command":"node"}}}\n' > "$RL/mcp-two.json"
rl_refuse "an MCP config with a second server" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-two.json"
printf '{"mcpServers":{"other":{"command":"node"}}}\n' > "$RL/mcp-other.json"
rl_refuse "an MCP config that is not the readiness adapter" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-other.json"
printf '{"mcpServers":{}}\n' > "$RL/mcp-empty.json"
rl_refuse "an empty MCP config (the profile's static one)" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-empty.json"
printf 'not json\n' > "$RL/mcp-bad.json"
rl_refuse "an unparseable MCP config" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-bad.json"
# the startup binding: the generated server args name exactly the adapter and ONE private startup config that holds the minted id
rl_bind() { # rl_bind <file> <jq filter over the MCP config>
  jq "$2" "$rl_mcp" > "$1"
}
rl_bind "$RL/mcp-noargs.json" 'del(.mcpServers.readiness.args)'
rl_refuse "an MCP server with no startup config argument" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-noargs.json"
rl_bind "$RL/mcp-extra-arg.json" '.mcpServers.readiness.args += ["--other"]'
rl_refuse "an MCP server with an extra argument" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-extra-arg.json"
rl_bind "$RL/mcp-flag.json" '.mcpServers.readiness.args[1] = "--config"'
rl_refuse "an MCP server whose flag is not --startup-config" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-flag.json"
rl_bind "$RL/mcp-adapter.json" '.mcpServers.readiness.args[0] = "/bin/other.mjs"'
rl_refuse "an MCP server that is not the readiness adapter" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-adapter.json"
rl_bind "$RL/mcp-rel.json" '.mcpServers.readiness.args[2] = "attempt/startup.json"'
rl_refuse "a relative startup config path" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-rel.json"
rl_bind "$RL/mcp-name.json" '.mcpServers.readiness.args[2] = "'"$rl_att"'/other.json"'
rl_refuse "a startup config not named startup.json" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-name.json"
rl_bind "$RL/mcp-missing.json" '.mcpServers.readiness.args[2] = "'"$RL"'/no-attempt/startup.json"'
rl_refuse "a missing private startup config" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-missing.json"
rl_refuse "a minted id that differs from the startup config's session scope" WORKER_SESSION_ID="99999999-2222-4333-8444-555555555555"
mkdir -p "$RL/attempt-open"; chmod 755 "$RL/attempt-open"; cp "$rl_att/startup.json" "$RL/attempt-open/startup.json"; chmod 600 "$RL/attempt-open/startup.json"
rl_bind "$RL/mcp-opendir.json" '.mcpServers.readiness.args[2] = "'"$RL"'/attempt-open/startup.json"'
rl_refuse "a startup config in a directory that is not mode 0700" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-opendir.json"
mkdir -p "$RL/attempt-mode"; chmod 700 "$RL/attempt-mode"; cp "$rl_att/startup.json" "$RL/attempt-mode/startup.json"; chmod 644 "$RL/attempt-mode/startup.json"
rl_bind "$RL/mcp-mode.json" '.mcpServers.readiness.args[2] = "'"$RL"'/attempt-mode/startup.json"'
rl_refuse "a startup config that is not mode 0600" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-mode.json"
mkdir -p "$RL/attempt-link"; chmod 700 "$RL/attempt-link"; ln -sf "$rl_att/startup.json" "$RL/attempt-link/startup.json"
rl_bind "$RL/mcp-link.json" '.mcpServers.readiness.args[2] = "'"$RL"'/attempt-link/startup.json"'
rl_refuse "a startup config that is a symlink" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-link.json"
mkdir -p "$RL/attempt-lane"; chmod 700 "$RL/attempt-lane"
printf '{"schema":"readiness-startup-v1","lane":"claudex","session_scope":"%s"}\n' "$rl_sid" > "$RL/attempt-lane/startup.json"; chmod 600 "$RL/attempt-lane/startup.json"
rl_bind "$RL/mcp-lane.json" '.mcpServers.readiness.args[2] = "'"$RL"'/attempt-lane/startup.json"'
rl_refuse "a startup config for another lane" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-lane.json"
mkdir -p "$RL/attempt-schema"; chmod 700 "$RL/attempt-schema"
printf '{"schema":"other","lane":"native","session_scope":"%s"}\n' "$rl_sid" > "$RL/attempt-schema/startup.json"; chmod 600 "$RL/attempt-schema/startup.json"
rl_bind "$RL/mcp-schema.json" '.mcpServers.readiness.args[2] = "'"$RL"'/attempt-schema/startup.json"'
rl_refuse "a startup config of another schema" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-schema.json"
printf 'not json\n' > "$RL/attempt-schema/startup.json"
rl_refuse "an unparseable startup config" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-schema.json"
printf '{"permissions":{"allow":[%s,"Bash(bash scripts/x.sh:*)"],"deny":[%s]}}\n' "$rl_grants" "$rl_deny" > "$RL/set-extra.json"
rl_refuse "settings with an extra allow rule (a gate rule)" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-extra.json"
printf '{"permissions":{"allow":["mcp__readiness__inspect"],"deny":[%s]}}\n' "$rl_deny" > "$RL/set-one.json"
rl_refuse "settings granting only one of the two tools" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-one.json"
printf '{"permissions":{"allow":[%s,"mcp__plugin_readiness_readiness__act"],"deny":[%s]}}\n' "$rl_grants" "$rl_deny" > "$RL/set-prefixed.json"
rl_refuse "settings with a plugin-prefixed third grant" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-prefixed.json"
printf '{"permissions":{"allow":[%s],"deny":["Artifact"]}}\n' "$rl_grants" > "$RL/set-nodeny.json"
rl_refuse "settings that do not deny the native tools" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-nodeny.json"
for unsafe_key in defaultMode ask additionalDirectories; do
  jq --arg key "$unsafe_key" '.permissions[$key] = "bypassPermissions"' "$rl_settings" > "$RL/set-unsafe.json"
  rl_refuse "settings with permission override $unsafe_key" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-unsafe.json"
done
jq '.hooks = {}' "$rl_settings" > "$RL/set-hooks.json"
rl_refuse "settings with caller hooks" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-hooks.json"
for unsafe_key in statusLine apiKeyHelper env enableAllProjectMcpServers disableAllHooks; do
  jq --arg key "$unsafe_key" '.[$key] = "fixture"' "$rl_settings" > "$RL/set-top-level.json"
  rl_refuse "an unknown settings key $unsafe_key" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-top-level.json"
done
for unsafe_key in env url type; do
  jq --arg key "$unsafe_key" '.mcpServers.readiness[$key] = "fixture"' "$rl_mcp" > "$RL/mcp-extra-key.json"
  rl_refuse "an unknown MCP server key $unsafe_key" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-extra-key.json"
done
printf '{"mcpServers":{"readiness":"not a server"}}\n' > "$RL/mcp-scalar.json"
rl_refuse "a malformed MCP server entry" WORKER_SESSION_PROFILE_MCP_CONFIG="$RL/mcp-scalar.json"
printf 'not json\n' > "$RL/set-bad.json"
rl_refuse "unparseable settings" WORKER_SESSION_PROFILE_SETTINGS="$RL/set-bad.json"
rl_refuse "a render request on a launch that is not the readiness role" WORKER_SESSION_PROFILE_READINESS= WORKER_SESSION_RENDER_ARGV=1
rl_refuse "a render switch that is not exactly 1" WORKER_SESSION_RENDER_ARGV=2

# the render never executes a native binary: with no seam and a PATH claude, render does not run it, exec does
rm -f "$rl_rec"; rc=0
env -i PATH="$RL/bin:$PATH" HOME="$RL/home" WORKER_SESSION_PROFILE_READINESS=1 WORKER_SESSION_RENDER_ARGV=1 \
  WORKER_SESSION_PROFILE_SETTINGS="$rl_settings" WORKER_SESSION_PROFILE_MCP_CONFIG="$rl_mcp" WORKER_SESSION_ID="$rl_sid" \
  bash "$SHIM" "${rl_caller_default[@]}" > "$RL/render-path.out" 2>/dev/null || rc=$?
check "readiness render with a PATH claude: exit 0" "$rc" "0"
check "readiness render with a PATH claude: the native binary is never executed" "$(cat "$rl_rec" 2>/dev/null || true)" ""
check "readiness render with a PATH claude: the binary element is the bare name, the rest is the same argv" \
  "$(rl_decode < "$RL/render-path.out")" "[claude]$rl_pre$rl_tail_default"
rm -f "$rl_rec"
env -i PATH="$RL/bin:$PATH" HOME="$RL/home" WORKER_SESSION_PROFILE_READINESS=1 \
  WORKER_SESSION_PROFILE_SETTINGS="$rl_settings" WORKER_SESSION_PROFILE_MCP_CONFIG="$rl_mcp" WORKER_SESSION_ID="$rl_sid" \
  bash "$SHIM" "${rl_caller_default[@]}" >/dev/null 2>&1 || true
check "readiness exec with a PATH claude: the same array reaches the binary" "$(cat "$rl_rec" 2>/dev/null || true)" "$rl_pre$rl_tail_default"


echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-headed-arm-worker-c.sh"
  exit 0
else
  echo "FAIL - test-headed-arm-worker-c.sh ($fails failure(s))"
  exit 1
fi
