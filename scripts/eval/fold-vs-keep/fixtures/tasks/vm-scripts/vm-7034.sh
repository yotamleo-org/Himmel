#!/usr/bin/env bash
# vm-7034: vmsdk clone keeps the PAT out of every guest argv, leaves no temp dir, and
# writes a tokenless origin, on the fresh-clone path (either PAT var) and the fetch path.
# Runs the repo's current vmsdk.py, which contains the 44e906ba change. No token is printed.
source "$(dirname "$0")/_lib.sh"
vm_fresh
cat >"$WORK/watch.sh" <<'EOF'
# watch.sh git|window - sample guest argv for token patterns while git runs (git) or for 25 s (window)
n=0; hits=0
sample() {
    local a; a="$(ps -eo args)"
    printf '%s\n' "$a" | grep -q '^git ' || return 0
    n=$((n + 1)); printf '%s\n' "$a" | grep '^git ' | sort -u >>/tmp/fvk-argv
    hits=$((hits + $(printf '%s\n' "$a" | grep -E 'x-access-token|ghp_|github_pat_' | grep -vc grep)))
}
: >/tmp/fvk-argv
if [ "$1" = git ]; then
    for _ in $(seq 1 1200); do pgrep -x git >/dev/null && break; sleep 0.05; done
    while pgrep -x git >/dev/null; do sample; sleep 0.05; done
else
    end=$((SECONDS + 25)); while [ "$SECONDS" -lt "$end" ]; do sample; sleep 0.05; done
fi
echo "samples=$n hits=$hits"
sort -u /tmp/fvk-argv | sed -E 's/(ghp_|github_pat_)[A-Za-z0-9_]+/\1<redacted>/g; s#//[^/@ ]+@#//<redacted>@#g'
EOF
push_file "$WORK/watch.sh" /tmp/watch.sh watcher

# watched <mode> <label> <blank-var> - one clone under the watcher, its checks
watched() {
    g 150 "bash /tmp/watch.sh $1" >"$WORK/w.out" 2>&1 & local wp=$!
    sleep 3
    (export "$3="; sdk clone main) >"$WORK/c.out" 2>&1
    check "$2-clone-rc" $? "$(tail -2 "$WORK/c.out")"
    wait "$wp"; cat "$WORK/w.out"
    local s; s="$(head -1 "$WORK/w.out")"
    case "$s" in samples=0*|"") check "$2-watcher-saw-git" 1 "$s" ;; *) check "$2-watcher-saw-git" 0 ;; esac
    case "$s" in *" hits=0") check "$2-no-token-in-argv" 0 ;; *) check "$2-no-token-in-argv" 1 "$s" ;; esac
    o="$(g 30 'ls -d /tmp/tmp.* 2>/dev/null | wc -l; git -C ~/himmel remote get-url origin; git -C ~/himmel config --get-regexp "extraheader|credential" | wc -l; grep -cE "x-access-token|ghp_|github_pat_" ~/himmel/.git/config')"
    echo "$o"
    line() { printf '%s\n' "$o" | sed -n "$1p"; }
    same() { if [ "$1" = "$2" ]; then echo 0; else echo 1; fi; }
    check "$2-no-temp-dir-left" "$(same "$(line 1)" 0)"
    case "$(line 2)" in *@*) r=1 ;; https://github.com/*/*.git) r=0 ;; *) r=1 ;; esac
    check "$2-tokenless-origin" "$r" "$(line 2)"
    check "$2-no-credential-config" "$(same "$(line 3) $(line 4)" "0 0")"
}

g 30 'mv ~/himmel ~/himmel.baked'; check move-baked-aside $?
watched git fresh-vm himmel_github_token_vm2
g 30 'mv ~/himmel ~/himmel.step1'; check move-step1-aside $?
watched git fresh-vm2 himmel_github_token_vm
watched window fetch-path himmel_github_token_vm2
grep -q 'fetch --depth 1' "$WORK/w.out"; check fetch-path-ran-fetch $?

# red control: the watcher flags a fake token on a git argv
g 150 'bash /tmp/watch.sh git' >"$WORK/w.out" 2>&1 & wp=$!
sleep 3
g 60 'timeout 30 git ls-remote https://x-access-token:ghp_FAKE0000@github.com/octocat/Hello-World.git HEAD >/dev/null 2>&1; true'
wait "$wp"; s="$(head -1 "$WORK/w.out")"; echo "red control: $s"
case "$s" in *" hits=0"|samples=0*) check red-control-flags-fake-token 1 "$s" ;; *) check red-control-flags-fake-token 0 ;; esac
final
