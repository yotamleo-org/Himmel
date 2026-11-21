#!/usr/bin/env bash
# e2e-linux.sh - the peer bridge typed path end to end, inside ONE VirtualBox
# test VM: station A (requester, temp HOME) asks station B (server, this VM
# user's HOME) to run two real suites; B's runner runs them in a nested job
# guest with no NIC and no PAT; A's `jobs.ts show` must list both outcomes.
# Then a probe in a fresh job guest must reach nothing on the network.
# It never runs on a station host.
#
# Inputs (environment, set by the VM driver):
#   PEER_BRIDGE_VM_TEST=1     required
#   E2E_BOTS_FILE             0600 file with TELEGRAM_TEST_A_BOT=<token> and
#                             TELEGRAM_TEST_B_BOT=<token> lines (never printed)
#   E2E_CHAT_FILE             file holding the test supergroup id; both bots are
#                             administrators there with every right off
#   E2E_A_USERNAME, E2E_B_USERNAME   bot usernames (default himmel_test_a_bot, _b_bot)
#   E2E_MAX_S                 wait for the job at most this long (default 3600)
# B's HOME must already hold the Task 11 fixture: `vmsdk-job.py
# golden-build-linux` wrote C/golden.guest and C/golden.digest and registered
# the golden VM. Everything else of B's peer bridge must be absent.
#
# Exit 0 and `E2E PASS`, else 1 with `E2E FAIL: <why>`.
set -uo pipefail

die() { echo "E2E FAIL: $*" >&2; exit 1; }
[ "${PEER_BRIDGE_VM_TEST:-}" = "1" ] || { echo "e2e-linux.sh runs only inside a test VM (PEER_BRIDGE_VM_TEST=1)" >&2; exit 2; }
[ "$(uname -s)" = "Linux" ] || die "Linux only"
for c in bun jq git python3 VBoxManage ip timeout; do command -v "$c" >/dev/null 2>&1 || die "missing $c"; done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
vmjob="$root/scripts/lib/vmsdk-job.py"
B="$HOME"
CB="$B/.config/himmel/peer-bridge"
SB="$B/.himmel/peer-bridge"
[ -r "${E2E_BOTS_FILE:-}" ] || die "E2E_BOTS_FILE is not readable"
[ -n "$(find "$E2E_BOTS_FILE" -maxdepth 0 -perm 600)" ] || die "E2E_BOTS_FILE must be mode 0600"
[ -r "${E2E_CHAT_FILE:-}" ] || die "E2E_CHAT_FILE is not readable"
chat="$(tr -d '[:space:]' < "$E2E_CHAT_FILE")"
case "$chat" in -[0-9]*) ;; *) die "E2E_CHAT_FILE holds no negative chat id" ;; esac
[ -s "$CB/golden.guest" ] && [ -s "$CB/golden.digest" ] || die "no Task 11 fixture: run vmsdk-job.py golden-build-linux first"
extra="$(find "$CB" -mindepth 1 -maxdepth 1 ! -name golden.guest ! -name golden.digest)"
[ ! -e "$SB" ] && [ -z "$extra" ] || die "B already has a peer bridge under $B; this run would mix with it"

tok_a="$(sed -n 's/^TELEGRAM_TEST_A_BOT=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' "$E2E_BOTS_FILE" | head -n 1)"
tok_b="$(sed -n 's/^TELEGRAM_TEST_B_BOT=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' "$E2E_BOTS_FILE" | head -n 1)"
[ -n "$tok_a" ] && [ -n "$tok_b" ] || die "E2E_BOTS_FILE lacks a TELEGRAM_TEST_A_BOT or TELEGRAM_TEST_B_BOT line"
id_a="${tok_a%%:*}"
id_b="${tok_b%%:*}"
user_a="${E2E_A_USERNAME:-himmel_test_a_bot}"
user_b="${E2E_B_USERNAME:-himmel_test_b_bot}"
max_s="${E2E_MAX_S:-3600}"

# shellcheck source=scripts/lib/prim.sh
. "$root/scripts/lib/prim.sh"
tmp="$(tmpdir)" || exit 1
A="$tmp/a"
mkdir -m 700 "$A"
pids=""
cleanup() {
    for p in $pids; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    python3 "$vmjob" vm-destroy e2e-probe >/dev/null 2>&1
    PEER_JOB_BACKEND=vbox python3 "$vmjob" vm-sweep >/dev/null 2>&1
    rm -rf "$SB"
    find "$CB" -mindepth 1 -maxdepth 1 ! -name golden.guest ! -name golden.digest -exec rm -rf {} + 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT
export PEER_JOB_BACKEND=vbox

cat > "$tmp/cfg.ts" <<'TS'
const root = process.env.E2E_ROOT!;
const setup = await import(`${root}/scripts/peer-bridge/setup.ts`);
const sign = await import(`${root}/scripts/peer-bridge/sign.ts`);
const [mode, ...a] = process.argv.slice(2);
const answers: string[] = [];
const deps = { env: process.env, tty: true, gitCwd: root, ask: async () => answers.shift() ?? "", out: (l: string) => console.error(l) };
if (mode === "init") {
  const [station, peer, peerBotId, peerUsername] = a;
  await setup.keygenCmd("new", deps);
  await setup.add(peer, { peerBotId, operatorBotId: "7000000001", peerUsername }, deps);
  await setup.stationName(station, deps);
} else if (mode === "confirm") {
  await setup.confirm(a[0], a[1], deps);
} else if (mode === "pub") {
  console.log(sign.publicKeyOf(sign.currentSigningKey().path));
} else if (mode === "trust") {
  const [peer, station, pub] = a;
  answers.push(sign.fingerprint(pub));
  await setup.trust(peer, station, pub, deps);
} else if (mode === "allow") {
  await setup.allowSuite(a[0], a[1], a[2], deps);
} else throw new Error(`cfg.ts: unknown mode ${mode}`);
TS
side() { local h="$1"; shift; HOME="$h" E2E_ROOT="$root" TELEGRAM_ACCESS_PATH="$tmp/access.json" BRIDGE_ROOT="$h/bridge" bun "$tmp/cfg.ts" "$@"; }
echo '{"allowFrom":["4242"]}' > "$tmp/access.json"

write_env() {
    mkdir -p "$1/.config/himmel/peer-bridge" && chmod 700 "$1/.config/himmel/peer-bridge"
    (umask 077; printf 'PEER_BOT_TOKEN=%s\n' "$2" > "$1/.config/himmel/peer-bridge/env")
}
patch_peers() {
    local f="$1/.config/himmel/peer-bridge/peers.json"
    if ! { jq "$2" "$f" > "$f.new" && chmod 600 "$f.new" && mv "$f.new" "$f"; }; then die "could not patch $f"; fi
}

echo "== configure A (requester) and B (server)"
write_env "$A" "$tok_a"
write_env "$B" "$tok_b"
side "$A" init e2ea b "$id_b" "$user_b" || die "setup A"
side "$B" init e2eb a "$id_a" "$user_a" || die "setup B"
side "$A" confirm b "$chat" || die "confirm A"
side "$B" confirm a "$chat" || die "confirm B"
pub_a="$(side "$A" pub)" || die "read A's key"
pub_b="$(side "$B" pub)" || die "read B's key"
side "$A" trust b e2eb "$pub_b" || die "A trusts B"
side "$B" trust a e2ea "$pub_a" || die "B trusts A"
suite1="scripts/hooks/test-block-jira-compound-write.sh"
suite2="scripts/hooks/test-peer-taint.sh"
side "$B" allow a jira "$suite1" || die "allow $suite1"
side "$B" allow a taint "$suite2" || die "allow $suite2"

sha="$(git -C "$root" rev-parse origin/main)" || die "no origin/main in $root"
git -C "$root" merge-base --is-ancestor "$(cat "$here/min-sha.txt")" "$sha" || die "origin/main does not descend from MIN_SHA"
git init -q --bare "$tmp/origin.git" || die "init the origin mirror"
git -C "$root" push -q "$tmp/origin.git" "$sha:refs/heads/main" || die "push to the origin mirror"
digest="$(tr -d '[:space:]' < "$CB/golden.digest")"
patch_peers "$B" ".peers.a.serves = [\"run-suite\"] | .peers.a.approve = {\"run-suite\": \"auto\"} | .peers.a.repoUrl = \"file://$tmp/origin.git\""
patch_peers "$A" ".peers.b.theirs.imageDigest = \"$digest\""

echo "== start both pollers and B's runner"
HOME="$A" bash "$here/run.sh" > "$tmp/poller-a.log" 2>&1 & pids="$pids $!"
HOME="$B" bash "$here/run.sh" > "$tmp/poller-b.log" 2>&1 & pids="$pids $!"
HOME="$B" bun "$here/runner.ts" > "$tmp/runner.log" 2>&1 & pids="$pids $!"
sleep 10
for p in $pids; do kill -0 "$p" 2>/dev/null || { tail -n 20 "$tmp"/*.log >&2; die "a bridge process exited at start"; }; done

echo "== request"
out="$(HOME="$A" bun "$here/jobs.ts" request b run-suite --sha "$sha" --suite "$suite1" --suite "$suite2")" || die "jobs.ts request: $out"
job="$(printf '%s\n' "$out" | sed -n 's/^\(J[0-9][0-9]*\) sent to b$/\1/p')"
[ -n "$job" ] || die "no job number in: $out"
echo "$out"

deadline=$(( $(date +%s) + max_s ))
shown=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    shown="$(HOME="$A" bun "$here/jobs.ts" show "$job" 2>&1)"
    case "$(printf '%s\n' "$shown" | head -n 1)" in
        *" sent DONE"|*" sent REFUSED"|*" sent EXPIRED"|*" sent CANCELLED"|*" sent LOST") break ;;
    esac
    sleep 15
done
echo "$shown"
case "${shown%%$'\n'*}" in *" sent DONE") ;; *) tail -n 30 "$tmp"/*.log >&2; die "$job did not end DONE" ;; esac
grep -qx "  $suite1: pass" <<< "$shown" || die "$suite1 did not pass"
grep -qx "  $suite2: pass" <<< "$shown" || die "$suite2 did not pass"
grep -qx "image: pinned" <<< "$shown" || die "the image is not pinned"
vms="$(VBoxManage list vms)" || die "VBoxManage list vms"
grep -q '"himmel-peerjob-' <<< "$vms" && die "a job VM outlived its job"

echo "== network probe from a job guest"
gw="$(ip route show default | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1)"
[ -n "$gw" ] || die "this VM has no default gateway to probe"
python3 "$vmjob" vm-clone e2e-probe || die "vm-clone for the probe"
# shellcheck disable=SC2016
probe='r=0; for t in 1.1.1.1/443 140.82.112.3/443 '"$gw"'/22 '"$gw"'/53; do if timeout 5 bash -c "exec 3<>/dev/tcp/$t" 2>/dev/null; then echo "REACHED $t"; r=3; fi; done; if getent hosts github.com >/dev/null 2>&1; then echo "RESOLVED github.com"; r=3; fi; exit $r'
python3 "$vmjob" vm-exec e2e-probe --timeout 120 -- bash -c "$probe"
rc=$?
python3 "$vmjob" vm-destroy e2e-probe
[ "$rc" -eq 0 ] || die "the job guest reached the network (probe rc $rc)"

echo "E2E PASS"
