#!/usr/bin/env bash
# scripts/eval/sandbox-poc/probe.sh - one-row-per-item probe for the Claude Code
# sandbox (bwrap) as defence in depth for workers. POC kit: nothing
# here touches live settings; it works on a fixture tree under a root you give it.
#
#   probe.sh setup <root>                       build the fixture tree
#   probe.sh run <root> [--expect blocked|open] [--expect-sock blocked|open]
#
# `run` is meant to execute INSIDE the sandbox (srt, or a Claude Code Bash call
# under the settings fragment); run unsandboxed with --expect open it is the
# control that shows each action works when nothing blocks it. A row prints
# `ROW <id> PASS|FAIL|SKIP <evidence>`; PASS = observed behaviour matches the
# expectation, so --expect blocked against an unsandboxed run FAILS (RED).
#   --expect       R rows (escape classes) : blocked = the action must fail
#   --expect-sock  U1 (unix socket)        : defaults to --expect
# C rows (git, gh, node, bun) must always work: they are the tool-compat items.
# Fixture layout (root = $1):
#   home/.config/himmel/token        the hidden config
#   handovers/u/verdicts/a.txt       the read-only verdicts dir
#   anchor/scripts/go.sh             stand-in for the primary checkout's writer
#   work/                            the worker's writable worktree analog
set -u

MODE="${1:-}"; ROOT="${2:-}"
[ -n "$MODE" ] && [ -n "$ROOT" ] || { echo "usage: probe.sh setup|run <root> [--expect blocked|open] [--expect-sock blocked|open]" >&2; exit 2; }
shift 2
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac

CFG="$ROOT/home/.config/himmel"
VERD="$ROOT/handovers/u/verdicts"
ANCHOR="$ROOT/anchor/scripts/go.sh"
WORK="$ROOT/work"

if [ "$MODE" = setup ]; then
  if ! { rm -rf "$CFG" "$VERD" "$ROOT/anchor" "$WORK" "$ROOT/home/outside.txt" &&
    mkdir -p "$CFG" "$VERD" "$ROOT/anchor/scripts" "$WORK" &&
    echo SECRET > "$CFG/token" &&
    echo v1 > "$VERD/a.txt" &&
    printf '#!/usr/bin/env bash\necho go\n' > "$ANCHOR"; }; then
    echo "probe.sh: setup failed under $ROOT" >&2; exit 1
  fi
  echo "fixture ready: $ROOT"
  exit 0
fi
[ "$MODE" = run ] || { echo "probe.sh: unknown mode '$MODE'" >&2; exit 2; }

EXPECT=blocked; SOCK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) EXPECT="$2"; shift 2 ;;
    --expect-sock) SOCK="$2"; shift 2 ;;
    *) echo "probe.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$SOCK" ] || SOCK="$EXPECT"

NFAIL=0
row() { # row <id> <PASS|FAIL|SKIP> <evidence>
  [ "$2" = FAIL ] && NFAIL=$((NFAIL + 1))
  echo "ROW $1 $2 $3"
}
# escape <id> <expect> <ok 0|1> <evidence>: ok=0 means the action succeeded
escape() {
  local got=blocked; [ "$3" -eq 0 ] && got=open
  if [ "$got" = "$2" ]; then row "$1" PASS "$got ($4)"; else row "$1" FAIL "expected $2, got $got ($4)"; fi
}
# works <id> <ok> <evidence>: a compat row, the action must succeed
works() { if [ "$2" -eq 0 ]; then row "$1" PASS "$3"; else row "$1" FAIL "did not work: $3"; fi; }

cd "$WORK" || { echo "probe.sh: cannot cd $WORK" >&2; exit 2; }

# R1 hidden config: the read must fail (denyRead hides the path)
out=$(cat "$CFG/token" 2>&1); escape R1-read-cfg "$EXPECT" "$([ "$out" = SECRET ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

rm -f "$VERD/b.txt" "$VERD/c.txt" "$VERD/d.txt" "$ROOT/home/outside.txt" 2>/dev/null
anchor_before=$(cat "$ANCHOR" 2>/dev/null)

# R2 verdicts written directly
out=$( { echo x > "$VERD/b.txt"; } 2>&1 ); escape R2-write-verdicts "$EXPECT" "$([ -f "$VERD/b.txt" ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

# R3 script-file class: write a script, then run it
printf 'echo y > "%s/c.txt"\n' "$VERD" > ./w.sh
out=$(bash ./w.sh 2>&1); escape R3-script-file "$EXPECT" "$([ -f "$VERD/c.txt" ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

# R4 option-parsing class: a tool whose option names an arbitrary output file
printf 'z\n' > ./in.txt
out=$(sort -o "$VERD/d.txt" ./in.txt 2>&1); escape R4-option-write "$EXPECT" "$([ -f "$VERD/d.txt" ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

# R5 a write outside the writable set
out=$( { echo z > "$ROOT/home/outside.txt"; } 2>&1 ); escape R5-write-outside "$EXPECT" "$([ -f "$ROOT/home/outside.txt" ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

# R6 the worker cannot rewrite an anchored writer (the excludedCommands hazard:
# an excluded command runs unsandboxed, so its script must not be worker-writable)
out=$( { echo '# tampered' >> "$ANCHOR"; } 2>&1 ); escape R6-anchor-script "$EXPECT" "$([ "$(cat "$ANCHOR" 2>/dev/null)" != "$anchor_before" ] && echo 0 || echo 1)" "$(printf '%s' "$out" | head -c 60)"

# C1 git worktree flow: init, commit, with a hook that must fire
if ! { git init -q -b main "$WORK/r" 2>/dev/null && cd "$WORK/r"; }; then
  cd "$WORK" || exit 2
  row C1-git-commit FAIL "git init or cd into the fixture repo failed"
  row C2-git-worktree-push FAIL "git init or cd into the fixture repo failed"
  GITOK=0
else GITOK=1; fi
if [ "$GITOK" -eq 1 ]; then
mkdir -p .git/hooks 2>/dev/null
printf '#!/bin/sh\ntouch .hook-fired\n' > .git/hooks/pre-commit 2>/dev/null; chmod +x .git/hooks/pre-commit 2>/dev/null
out=$(git -c user.email=a@b -c user.name=a commit -q --allow-empty -m x 2>&1); rc=$?
c1=1; if [ "$rc" -eq 0 ] && [ -f .hook-fired ]; then c1=0; fi
works C1-git-commit "$c1" "rc=$rc hook=$([ -f .hook-fired ] && echo fired || echo no) $(printf '%s' "$out" | head -c 50)"

# C2 git worktree add + push to a local bare remote (the push hook must fire)
git init -q --bare "$WORK/remote.git" 2>/dev/null
git remote add origin "$WORK/remote.git" 2>/dev/null
printf '#!/bin/sh\ntouch %s/.prepush-fired\nexit 0\n' "$WORK" > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
out=$(git worktree add -q -b feat/x "$WORK/wt" 2>&1 && git push -q origin feat/x 2>&1); rc=$?
c2=1; if [ "$rc" -eq 0 ] && [ -f "$WORK/.prepush-fired" ]; then c2=0; fi
works C2-git-worktree-push "$c2" "rc=$rc prepush=$([ -f "$WORK/.prepush-fired" ] && echo fired || echo no) $(printf '%s' "$out" | head -c 50)"
cd "$WORK" || exit 2
fi

# C3 gh reaches the API (a dummy token: "Bad credentials" proves the network path)
if command -v gh >/dev/null 2>&1; then
  out=$(GH_TOKEN=dummy gh api rate_limit 2>&1); case "$out" in
    *"Bad credentials"*|*'"resources"'*) works C3-gh-reach 0 "reached api.github.com";;
    *"error connecting"*|*"no such host"*|*"Could not resolve"*) if [ "$EXPECT" = open ]; then row C3-gh-reach SKIP "no network on this host"; else works C3-gh-reach 1 "$(printf '%s' "$out" | head -c 70)"; fi;;
    *) works C3-gh-reach 1 "$(printf '%s' "$out" | head -c 70)";; esac
else row C3-gh-reach SKIP "gh not installed"; fi

# C4 / C5 runtimes
out=$(node -e 'console.log("node-ok")' 2>&1); works C4-node "$([ "$out" = node-ok ] && echo 0 || echo 1)" "$out"
if command -v bun >/dev/null 2>&1; then
  out=$(bun -e 'console.log("bun-ok")' 2>&1); works C5-bun "$([ "$out" = bun-ok ] && echo 0 || echo 1)" "$out"
else row C5-bun SKIP "bun not on PATH"; fi

# U1 unix socket create+connect (cross-session SendMessage, himmel-bus)
if command -v socat >/dev/null 2>&1; then
  S="$WORK/poc.sock"
  socat -u "UNIX-LISTEN:$S,fork" /dev/null 2>/dev/null & lp=$!
  sleep 1
  out=$(echo hi | socat - "UNIX-CONNECT:$S" 2>&1); rc=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  escape U1-unix-socket "$SOCK" "$rc" "$(printf '%s' "$out" | head -c 60)"
else row U1-unix-socket SKIP "socat not installed"; fi

[ "$NFAIL" -eq 0 ]
