#!/usr/bin/env bash
# vm-7147: the himmel-secrets resolver trial (fake keys, private bus and keyring) passes at 08df7fef.
source "$(dirname "$0")/_lib.sh"
SHA=08df7fef56d84d0a0929220d95b41fbbc623d794
vm_fresh
out="$(stage "$SHA" /tmp/h7147)"; expect head "$out" "$SHA"
cp "$(dirname "$0")/_7147-trial.sh" "$WORK/7147-trial.sh"
push_file "$WORK/7147-trial.sh" /tmp/7147-trial.sh trial
t="$(g 300 'bash /tmp/7147-trial.sh /tmp/h7147')"; rc=$?
echo "$t"
check trial-rc "$rc" "rc=$rc"
expect trial-all-pass "$t" "trial done: ALL PASS"
final
