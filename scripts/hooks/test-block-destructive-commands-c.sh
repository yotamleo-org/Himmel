#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-destructive-commands.sh, part c of 4.
# The four parts are case ranges of the former single suite; setup is shared
# in lib-test-block-destructive.sh and every case runs through sandbox-run.sh.
#
# Usage: bash scripts/hooks/test-block-destructive-commands-c.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail
# shellcheck source=lib-test-block-destructive.sh
. "$(cd "$(dirname "$0")" && pwd)/lib-test-block-destructive.sh"

# The find-family deletes the parity_guard.py twin denies too.
# A launcher that runs its argument as a command (busybox, command, eval, a
# shell's -c) keeps find at command position.
assert_rc 'busybox find -delete'         2 "$(run_case "$(j_bash 'busybox find d -delete')")"
assert_rc '/bin/busybox find -delete'    2 "$(run_case "$(j_bash '/bin/busybox find d -delete')")"
assert_rc 'command find -delete'         2 "$(run_case "$(j_bash 'command find d -delete')")"
assert_rc 'command -p find -delete'      2 "$(run_case "$(j_bash 'command -p find d -delete')")"
assert_rc 'command -- find -delete'      2 "$(run_case "$(j_bash 'command -- find d -delete')")"
assert_rc "bash -c 'find -delete'"       2 "$(run_case "$(j_bash "bash -c 'find d -delete'")")"
assert_rc "sh -c 'find -delete'"         2 "$(run_case "$(j_bash "sh -c 'find d -delete'")")"
assert_rc 'zsh -c "find -delete"'        2 "$(run_case "$(j_bash 'zsh -c "find d -delete"')")"
assert_rc "dash -c 'find -delete'"       2 "$(run_case "$(j_bash "dash -c 'find d -delete'")")"
assert_rc "bash -lc 'find -delete'"      2 "$(run_case "$(j_bash "bash -lc 'find d -delete'")")"
assert_rc "bash -o pipefail -c 'find'"   2 "$(run_case "$(j_bash "bash -o pipefail -c 'find d -delete'")")"
assert_rc "/bin/bash -c 'find -delete'"  2 "$(run_case "$(j_bash "/bin/bash -c 'find d -delete'")")"
assert_rc 'eval find -delete'            2 "$(run_case "$(j_bash 'eval find d -delete')")"
assert_rc 'eval "find -delete"'          2 "$(run_case "$(j_bash 'eval "find d -delete"')")"
assert_rc 'find -exec rm {} +'           2 "$(run_case "$(j_bash 'find d -exec rm {} +')")"
assert_rc 'find -exec rm {} \;'          2 "$(run_case "$(j_bash 'find d -exec rm {} \;')")"
assert_rc 'find -execdir rm {} +'        2 "$(run_case "$(j_bash 'find d -execdir rm {} +')")"
assert_rc 'find -execdir rm {} \;'       2 "$(run_case "$(j_bash 'find d -execdir rm {} \;')")"
assert_rc 'find -ok rm {} \;'            2 "$(run_case "$(j_bash 'find d -ok rm {} \;')")"
assert_rc 'find -okdir rm {} \;'         2 "$(run_case "$(j_bash 'find d -okdir rm {} \;')")"
assert_rc 'find -exec /bin/rm {} +'      2 "$(run_case "$(j_bash 'find d -exec /bin/rm {} +')")"
assert_rc 'find -exec /usr/bin/rm {} \;' 2 "$(run_case "$(j_bash 'find d -exec /usr/bin/rm {} \;')")"
assert_rc 'find -okdir /usr/bin/rm {} +' 2 "$(run_case "$(j_bash 'find d -okdir /usr/bin/rm {} +')")"
assert_rc "find -exec 'rm' {} +"         2 "$(run_case "$(j_bash "find d -exec 'rm' {} +")")"
assert_rc 'find -exec sudo rm {} +'      2 "$(run_case "$(j_bash 'find d -exec sudo rm {} +')")"
assert_rc 'find -exec busybox rm {} +'   2 "$(run_case "$(j_bash 'find d -exec busybox rm {} +')")"
assert_rc "find -exec sh -c 'rm' {} +"   2 "$(run_case "$(j_bash "find d -exec sh -c 'rm \"\$@\"' _ {} +")")"
assert_rc 'fd -X rm'                     2 "$(run_case "$(j_bash 'fd x -X rm')")"
assert_rc 'fd -x rm'                     2 "$(run_case "$(j_bash 'fd x -x rm')")"
assert_rc 'fd --exec rm'                 2 "$(run_case "$(j_bash 'fd x --exec rm')")"
assert_rc 'fd --exec-batch rm'           2 "$(run_case "$(j_bash 'fd x --exec-batch rm')")"
assert_rc 'fd -X /bin/rm'                2 "$(run_case "$(j_bash 'fd x -X /bin/rm')")"
assert_rc 'xargs rm'                     2 "$(run_case "$(j_bash 'ls | xargs rm')")"
assert_rc 'xargs -0 rm'                  2 "$(run_case "$(j_bash 'ls | xargs -0 rm')")"
assert_rc 'xargs -0 -n 1 rm'             2 "$(run_case "$(j_bash 'ls | xargs -0 -n 1 rm')")"
assert_rc 'xargs -r -P4 rm'              2 "$(run_case "$(j_bash 'ls | xargs -r -P4 rm')")"
assert_rc 'xargs -I {} rm {}'            2 "$(run_case "$(j_bash 'ls | xargs -I {} rm {}')")"
assert_rc 'xargs --null rm'              2 "$(run_case "$(j_bash 'ls | xargs --null rm')")"
assert_rc 'xargs -0 /bin/rm'             2 "$(run_case "$(j_bash 'ls | xargs -0 /bin/rm')")"
assert_rc 'xargs < list rm'              2 "$(run_case "$(j_bash 'xargs rm < list')")"
# The same forms behind the wrappers CMDPOS already models.
assert_rc 'sudo busybox find -delete'    2 "$(run_case "$(j_bash 'sudo busybox find d -delete')")"
assert_rc 'env busybox find -delete'     2 "$(run_case "$(j_bash 'env busybox find d -delete')")"
assert_rc 'nice command find -delete'    2 "$(run_case "$(j_bash 'nice command find d -delete')")"
assert_rc 'nohup busybox find -delete'   2 "$(run_case "$(j_bash 'nohup busybox find d -delete')")"
assert_rc 'timeout 5 busybox find'       2 "$(run_case "$(j_bash 'timeout 5 busybox find d -delete')")"
assert_rc 'time eval find -delete'       2 "$(run_case "$(j_bash 'time eval find d -delete')")"
assert_rc 'exec busybox find -delete'    2 "$(run_case "$(j_bash 'exec busybox find d -delete')")"
assert_rc "sudo bash -c 'find -delete'"  2 "$(run_case "$(j_bash "sudo bash -c 'find d -delete'")")"
assert_rc "env sh -c 'find -delete'"     2 "$(run_case "$(j_bash "env sh -c 'find d -delete'")")"
assert_rc "nohup sh -c 'find -delete'"   2 "$(run_case "$(j_bash "nohup sh -c 'find d -delete'")")"
assert_rc "timeout 5 sh -c 'find'"       2 "$(run_case "$(j_bash "timeout 5 sh -c 'find d -delete'")")"
assert_rc "bash -c 'sudo find -delete'"  2 "$(run_case "$(j_bash "bash -c 'sudo find d -delete'")")"
assert_rc 'command busybox find'         2 "$(run_case "$(j_bash 'command busybox find d -delete')")"
assert_rc 'sudo find -exec rm {} +'      2 "$(run_case "$(j_bash 'sudo find d -exec rm {} +')")"
assert_rc 'busybox find -exec rm {} +'   2 "$(run_case "$(j_bash 'busybox find d -exec rm {} +')")"
assert_rc "bash -c 'find -exec rm'"      2 "$(run_case "$(j_bash "bash -c 'find d -exec rm {} +'")")"
assert_rc 'nice fd -X rm'                2 "$(run_case "$(j_bash 'nice fd x -X rm')")"
assert_rc 'sudo xargs rm'                2 "$(run_case "$(j_bash 'ls | sudo xargs rm')")"
assert_rc 'nice xargs rm'                2 "$(run_case "$(j_bash 'ls | nice xargs rm')")"
assert_rc 'env xargs rm'                 2 "$(run_case "$(j_bash 'ls | env xargs rm')")"
assert_rc 'busybox xargs rm'             2 "$(run_case "$(j_bash 'ls | busybox xargs rm')")"
assert_rc 'xargs sudo rm'                2 "$(run_case "$(j_bash 'ls | xargs sudo rm')")"
assert_rc 'xargs nice rm'                2 "$(run_case "$(j_bash 'ls | xargs nice rm')")"
assert_rc 'xargs busybox rm'             2 "$(run_case "$(j_bash 'ls | xargs busybox rm')")"
assert_rc "xargs sh -c 'rm'"             2 "$(run_case "$(j_bash "ls | xargs sh -c 'rm \"\$@\"' _")")"
assert_rc "bash -c 'ls | xargs rm'"      2 "$(run_case "$(j_bash "bash -c 'ls | xargs rm'")")"
# PR 1799 CR (codex-1): every head word the mass-delete patterns match takes
# an optional .exe and a path prefix, xargs included.
assert_rc 'ls | xargs.exe rm' 2 "$(run_case "$(j_bash 'ls | xargs.exe rm')")"
assert_rc 'ls | /usr/bin/xargs rm' 2 "$(run_case "$(j_bash 'ls | /usr/bin/xargs rm')")"
assert_rc 'ls | /usr/bin/xargs.exe -0 rm' 2 "$(run_case "$(j_bash 'ls | /usr/bin/xargs.exe -0 rm')")"
assert_rc 'ls | xargs.exe -0 -n 1 rm' 2 "$(run_case "$(j_bash 'ls | xargs.exe -0 -n 1 rm')")"
assert_rc 'ls | sudo xargs.exe rm' 2 "$(run_case "$(j_bash 'ls | sudo xargs.exe rm')")"
assert_rc 'ls | xargs.exe busybox.exe rm' 2 "$(run_case "$(j_bash 'ls | xargs.exe busybox.exe rm')")"
assert_rc 'ls | xargs.exe find d -delete' 2 "$(run_case "$(j_bash 'ls | xargs.exe find d -delete')")"
assert_rc 'busybox.exe find d -delete' 2 "$(run_case "$(j_bash 'busybox.exe find d -delete')")"
assert_rc '/bin/busybox.exe find d -delete' 2 "$(run_case "$(j_bash '/bin/busybox.exe find d -delete')")"
assert_rc 'command.exe find d -delete' 2 "$(run_case "$(j_bash 'command.exe find d -delete')")"
assert_rc 'eval.exe find d -delete' 2 "$(run_case "$(j_bash 'eval.exe find d -delete')")"
assert_rc 'find d -exec busybox.exe rm {} +' 2 "$(run_case "$(j_bash 'find d -exec busybox.exe rm {} +')")"
assert_rc 'ls | busybox.exe xargs rm' 2 "$(run_case "$(j_bash 'ls | busybox.exe xargs rm')")"
assert_rc 'ls | command.exe xargs rm' 2 "$(run_case "$(j_bash 'ls | command.exe xargs rm')")"
assert_rc 'find.exe d -delete' 2 "$(run_case "$(j_bash 'find.exe d -delete')")"
assert_rc 'fd.exe x -X rm' 2 "$(run_case "$(j_bash 'fd.exe x -X rm')")"
assert_rc 'find d -exec rm.exe {} +' 2 "$(run_case "$(j_bash 'find d -exec rm.exe {} +')")"
assert_rc 'ls | xargs.exe rmdir' 0 "$(run_case "$(j_bash 'ls | xargs.exe rmdir')")"
assert_rc 'ls | xargs.exe grep rm' 0 "$(run_case "$(j_bash 'ls | xargs.exe grep rm')")"
assert_rc 'echo xargs.exe rm' 0 "$(run_case "$(j_bash 'echo xargs.exe rm')")"
# Lookalikes stay allowed: no find/xargs at command position, no rm word.
assert_rc 'echo busybox find -delete ok' 0 "$(run_case "$(j_bash 'echo busybox find d -delete')")"
assert_rc 'commit "bash -c find" ok'     0 "$(run_case "$(j_bash "git commit -m \"use bash -c 'find d -delete'\"")")"
assert_rc 'command -v find ok'           0 "$(run_case "$(j_bash 'command -v find')")"
assert_rc "bash -c 'find -name' ok"      0 "$(run_case "$(j_bash "bash -c 'find d -name x'")")"
assert_rc 'eval ls ok'                   0 "$(run_case "$(j_bash 'eval ls -la')")"
assert_rc 'busybox ls ok'                0 "$(run_case "$(j_bash 'busybox ls d')")"
assert_rc 'find -exec ls {} + ok'        0 "$(run_case "$(j_bash 'find d -exec ls {} +')")"
assert_rc 'find -exec rmdir {} + ok'     0 "$(run_case "$(j_bash 'find d -exec rmdir {} +')")"
assert_rc 'fd -x rmate ok'               0 "$(run_case "$(j_bash 'fd x -x rmate')")"
assert_rc 'xargs rmdir ok'               0 "$(run_case "$(j_bash 'ls | xargs rmdir')")"
assert_rc 'xargs grep rm ok'             0 "$(run_case "$(j_bash 'ls | xargs grep rm')")"
assert_rc 'echo x -exec rm y ok'         0 "$(run_case "$(j_bash 'echo x -exec rm y')")"
assert_rc 'commit "a xargs rm b" ok'     0 "$(run_case "$(j_bash 'git commit -m "a xargs rm b"')")"
# The find -delete scan is linear. 12,500 `find` anchors with no
# -delete (100 KB) took 21.8s at base (26s under suite load), quadratic;
# then a late shutdown. Head: 0.7-0.8s under suite load, so the budget is 4s.
# The pad is built before the clock starts (a concat loop takes 3s itself).
# shellcheck disable=SC2046 # one word per repeat is the point
printf -v pad '; find x%.0s' $(seq 1 12500)
t0=$SECONDS
assert_rc 'find anchors x12500 then shutdown (linear)' 2 "$(run_case "$(j_bash "echo hi$pad; shutdown now")")"
if [ $((SECONDS - t0)) -gt 4 ]; then
    echo "FAIL find anchors x12500 took $((SECONDS - t0))s (budget 4s)"; FAILED=$((FAILED + 1)); fi
# The CMDPOS path prefix stops at `(`, so a 10 KB run of open parens is
# scanned once per anchor, not to the run's end from every one (quadratic: ~20s at
# base). Budget 4s; the pad is built before the clock starts.
# shellcheck disable=SC2046 # one word per repeat is the point
printf -v pad '(%.0s' $(seq 1 10000)
t0=$SECONDS
assert_rc 'open-paren run x10000 then shutdown (linear)' 2 "$(run_case "$(j_bash "echo hi$pad; shutdown now")")"
if [ $((SECONDS - t0)) -gt 4 ]; then
    echo "FAIL open-paren run x10000 took $((SECONDS - t0))s (budget 4s)"; FAILED=$((FAILED + 1)); fi
# A `()` pair run was the other quadratic shape (`)` then a consumed `(`).
pad=$(awk 'BEGIN{for(i=0;i<5000;i++) printf "()"}')
t0=$SECONDS
assert_rc 'paren-pair run x5000 then shutdown (linear)' 2 "$(run_case "$(j_bash "echo hi$pad; shutdown now")")"
if [ $((SECONDS - t0)) -gt 4 ]; then
    echo "FAIL paren-pair run x5000 took $((SECONDS - t0))s (budget 4s)"; FAILED=$((FAILED + 1)); fi
# A `(` or `)` inside a path prefix must not hide the program name
# (the first EXEPFX cut consumed the `/` terminator after a `)`).
assert_rc 'quoted path with (b) then shutdown'   2 "$(run_case "$(j_bash '"/tmp/a(b)/shutdown" now')")"
assert_rc 'path with (b) then shutdown'          2 "$(run_case "$(j_bash '/tmp/a(b)/shutdown now')")"
assert_rc 'quoted path with ) then shutdown'     2 "$(run_case "$(j_bash '"/tmp/a)/shutdown" now')")"
assert_rc 'path with ) then shutdown'            2 "$(run_case "$(j_bash '/tmp/a)/shutdown now')")"
assert_rc 'path with )) then shutdown'           2 "$(run_case "$(j_bash '/tmp/a))/shutdown now')")"
assert_rc 'path with )/b/ then shutdown'         2 "$(run_case "$(j_bash '/tmp/a)/b/shutdown now')")"
# The stop-at-paren EXEPFX is sound only behind a `(` or `){` CMDPOS
# anchor. Four prefixes have none behind them and keep the class that crosses
# `(` and `){` inside a program path (CMDPOS_PFX_X): the -exec/-x flag of
# _rmpos_flag, FIND_RM_PAT, the tail of XARGS_RM_PAT, and the launcher tail of
# MASS_CMDPOS. One group of rows per consumer; each was rc 0 behind the shared stop.
assert_rc '_rmpos_flag: watch -x path with ){ rm'   2 "$(run_case "$(j_bash 'watch -x /tmp/a){/rm -rf d')")"
assert_rc '_rmpos_flag: watch -x path with (b) rm'  2 "$(run_case "$(j_bash 'watch -x /tmp/a(b)/rm -rf d')")"
assert_rc '_rmpos_flag: watch -x quoted ){ rm'      2 "$(run_case "$(j_bash 'watch -x "/tmp/a){/rm" -rf d')")"
assert_rc 'FIND_RM_PAT: find -exec path with ){ rm' 2 "$(run_case "$(j_bash 'find . -exec /tmp/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -execdir ){ rm'        2 "$(run_case "$(j_bash 'find . -execdir /tmp/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -ok ){ rm'             2 "$(run_case "$(j_bash 'find . -ok /tmp/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -exec quoted ){ rm'    2 "$(run_case "$(j_bash 'find . -exec "/tmp/a){/rm" {} +')")"
assert_rc 'FIND_RM_PAT: find -exec sudo ){ rm'      2 "$(run_case "$(j_bash 'find . -exec sudo /tmp/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -exec env ){ rm'       2 "$(run_case "$(j_bash 'find . -exec env /tmp/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -exec c: drive ){ rm'  2 "$(run_case "$(j_bash 'find . -exec c:/a){/rm {} +')")"
assert_rc 'FIND_RM_PAT: find -exec path with (b) rm' 2 "$(run_case "$(j_bash 'find . -exec /tmp/a(b)/rm {} +')")"
assert_rc 'FIND_RM_PAT: fd -x path with ){ rm'      2 "$(run_case "$(j_bash 'fd x -x /tmp/a){/rm')")"
assert_rc 'FIND_RM_PAT: fd --exec path with ){ rm'  2 "$(run_case "$(j_bash 'fd x --exec /tmp/a){/rm')")"
assert_rc 'FIND_RM_PAT: fd -x path with (b) rm'     2 "$(run_case "$(j_bash 'fd x -x /tmp/a(b)/rm')")"
assert_rc 'XARGS_RM_PAT: xargs path with ){ rm'     2 "$(run_case "$(j_bash 'ls | xargs /tmp/a){/rm')")"
assert_rc 'XARGS_RM_PAT: xargs -0 path ){ rm'       2 "$(run_case "$(j_bash 'ls | xargs -0 /tmp/a){/rm')")"
assert_rc 'XARGS_RM_PAT: xargs quoted ){ rm'        2 "$(run_case "$(j_bash 'ls | xargs "/tmp/a){/rm"')")"
assert_rc 'XARGS_RM_PAT: xargs sudo ){ rm'          2 "$(run_case "$(j_bash 'ls | xargs sudo /tmp/a){/rm')")"
assert_rc 'XARGS_RM_PAT: xargs busybox ){ rm'       2 "$(run_case "$(j_bash 'ls | xargs busybox /tmp/a){/rm')")"
assert_rc 'XARGS_RM_PAT: xargs path with (b) rm'    2 "$(run_case "$(j_bash 'ls | xargs /tmp/a(b)/rm')")"
assert_rc 'XARGS_RM_PAT: xargs -0 c:/p(x86)/rm'     2 "$(run_case "$(j_bash 'ls | xargs -0 c:/p(x86)/rm')")"
assert_rc 'MASS_CMDPOS tail: busybox (b) find -delete' 2 "$(run_case "$(j_bash 'busybox /tmp/a(b)/find . -delete')")"
assert_rc 'MASS_CMDPOS tail: busybox ){ find -delete'  2 "$(run_case "$(j_bash 'busybox /tmp/a){/find . -delete')")"
assert_rc 'MASS_CMDPOS tail: busybox (b) xargs rm'     2 "$(run_case "$(j_bash 'ls | busybox /tmp/a(b)/xargs rm')")"
# Each of those prefixes stays linear on a 10 KB run of `(` and of `){` in the
# program path (budget 4s, pad built before the clock starts).
# shellcheck disable=SC2046 # one word per repeat is the point
printf -v pad_o '(%.0s' $(seq 1 10000)
pad_b=$(awk 'BEGIN{for(i=0;i<5000;i++) printf "){"}')
for pad_name in o b; do
    if [ "$pad_name" = o ]; then pad=$pad_o; else pad=$pad_b; fi
    for shape in '_rmpos_flag|watch -x PAD/rm -rf d' 'FIND_RM_PAT|find . -exec PAD/rm {} +' \
                 'XARGS_RM_PAT|ls | xargs PAD/rm' 'MASS_CMDPOS tail|busybox PAD/find . -delete'; do
        label=${shape%%|*}; body=${shape#*|}
        t0=$SECONDS
        assert_rc "$label 10KB pad_$pad_name path run (linear, denied)" 2 "$(run_case "$(j_bash "${body//PAD/$pad}")")"
        if [ $((SECONDS - t0)) -gt 4 ]; then
            echo "FAIL $label pad_$pad_name took $((SECONDS - t0))s (budget 4s)"; FAILED=$((FAILED + 1)); fi
    done
done
# A value word may be built from quoted ('…', "…", $'…'),
# escaped and bare segments; a flag word may carry a quoted value too.
assert_rc "sudo -u 'a b'c rm -rf"        2 "$(run_case "$(j_bash "sudo -u 'a b'c rm -rf /x")")"
assert_rc "sudo -u a' b' rm -rf"         2 "$(run_case "$(j_bash "sudo -u a' b' rm -rf /x")")"
assert_rc "exec -a 'a b'c shutdown"      2 "$(run_case "$(j_bash "exec -a 'a b'c shutdown")")"
assert_rc "nice -n 'a b'c reboot"        2 "$(run_case "$(j_bash "nice -n 'a b'c reboot")")"
assert_rc "sudo -u \$'a b' rm -rf"       2 "$(run_case "$(j_bash "sudo -u \$'a b' rm -rf /x")")"
assert_rc "sudo -u \$'a\\' b' shutdown"  2 "$(run_case "$(j_bash "sudo -u \$'a\\' b' shutdown")")"
assert_rc 'sudo -u "a\" b" shutdown'     2 "$(run_case "$(j_bash 'sudo -u "a\" b" shutdown')")"
assert_rc 'sudo -u a\ b shutdown'        2 "$(run_case "$(j_bash 'sudo -u a\ b shutdown')")"
assert_rc "sudo -u'a b c' shutdown"      2 "$(run_case "$(j_bash "sudo -u'a b c' shutdown")")"
assert_rc 'sudo -u "a b\" shutdown'      2 "$(run_case "$(j_bash 'sudo -u "a b\" shutdown')")"
assert_rc "env --chdir='x y z' reboot"   2 "$(run_case "$(j_bash "env --chdir='x y z' reboot")")"
assert_rc "sudo -u 'a b'c ls allowed"    0 "$(run_case "$(j_bash "sudo -u 'a b'c ls -r d")")"
assert_rc "nice -n '1 0' find allowed"   0 "$(run_case "$(j_bash "nice -n '1 0' find d -name x")")"
assert_rc "exec -a 'a b' format c:"      2 "$(run_case "$(j_bash "exec -a 'a b' format c:")")"
assert_rc "exec -a 'a b' ls -r allowed"  0 "$(run_case "$(j_bash "exec -a 'a b' ls -r d")")"
assert_rc 'nice -n "1 0" make allowed'   0 "$(run_case "$(j_bash 'nice -n "1 0" make -r')")"
assert_rc "timeout '5 s' rm -f allowed"  0 "$(run_case "$(j_bash "timeout '5 s' rm -f x")")"
assert_rc 'echo x; watch -x rm denied'   2 "$(run_case "$(j_bash 'echo x; watch -x rm -rf d')")"
assert_rc 'echo x | watch -x rm denied'  2 "$(run_case "$(j_bash 'echo x | watch -x rm -rf d')")"
assert_rc 'echo "x" -exec rm denied'     2 "$(run_case "$(j_bash 'echo "x" -exec rm -rf y')")"
# shellcheck disable=SC2016  # literal $(...) is the point of this case
assert_rc 'echo $(x -exec rm) denied'    2 "$(run_case "$(j_bash 'echo $(watch -x rm -rf d)')")"
assert_rc 'echo x && strace -x rm denied' 2 "$(run_case "$(j_bash 'echo x && strace -x rm -rf d')")"
# A wrapper CMDPOS does not model still runs the rm (J1675 reproducers).
assert_rc 'watch -x rm -rf'              2 "$(run_case "$(j_bash 'watch -x rm -rf d')")"
assert_rc 'watch --exec rm -rf'          2 "$(run_case "$(j_bash 'watch --exec rm -rf d')")"
assert_rc 'watch -exec rm -rf'           2 "$(run_case "$(j_bash 'watch -exec rm -rf d')")"
assert_rc 'watch -n1 -x rm -rf'          2 "$(run_case "$(j_bash 'watch -n1 -x rm -rf d')")"
assert_rc 'x=1 watch -x rm -rf'          2 "$(run_case "$(j_bash 'x=1 watch -x rm -rf d')")"
assert_rc '! watch -x rm -rf'            2 "$(run_case "$(j_bash '! watch -x rm -rf d')")"
assert_rc 'time watch -x rm -rf'         2 "$(run_case "$(j_bash 'time watch -x rm -rf d')")"
assert_rc 'timeout 5 watch -x rm -rf'    2 "$(run_case "$(j_bash 'timeout 5 watch -x rm -rf d')")"
assert_rc 'nohup watch -x rm -rf'        2 "$(run_case "$(j_bash 'nohup watch -x rm -rf d')")"
assert_rc 'nice watch -x rm -rf'         2 "$(run_case "$(j_bash 'nice watch -x rm -rf d')")"
assert_rc 'exec watch -x rm -rf'         2 "$(run_case "$(j_bash 'exec watch -x rm -rf d')")"
assert_rc 'env watch -x rm -rf'          2 "$(run_case "$(j_bash 'env watch -x rm -rf d')")"
assert_rc 'command watch -x rm -rf'      2 "$(run_case "$(j_bash 'command watch -x rm -rf d')")"
assert_rc 'stdbuf -o0 -ok rm -rf'        2 "$(run_case "$(j_bash 'stdbuf -o0 -ok rm -rf d')")"
assert_rc 'strace -x rm -rf'             2 "$(run_case "$(j_bash 'strace -x rm -rf d')")"
assert_rc 'setsid -x rm -rf'             2 "$(run_case "$(j_bash 'setsid -x rm -rf d')")"
# A real find/fd launch still denies, behind wrappers too.
assert_rc 'command find -exec rm -rf'    2 "$(run_case "$(j_bash 'command find . -exec rm -rf {} +')")"
assert_rc 'sudo find -exec rm -rf'       2 "$(run_case "$(j_bash 'sudo find . -exec rm -rf {} +')")"
assert_rc 'nohup find -exec rm -rf'      2 "$(run_case "$(j_bash 'nohup find . -exec rm -rf {} +')")"
assert_rc 'xargs find -exec rm -rf'      2 "$(run_case "$(j_bash 'ls | xargs find -exec rm -rf {} +')")"
assert_rc 'find -name "a;b" -exec rm -rf' 2 "$(run_case "$(j_bash 'find . -name "a;b" -exec rm -rf {} +')")"
assert_rc 'f""ind -exec rm -rf'          2 "$(run_case "$(j_bash 'f""ind . -exec rm -rf {} +')")"
assert_rc '\find -exec rm -rf'           2 "$(run_case "$(j_bash '\find . -exec rm -rf {} +')")"
# shellcheck disable=SC2016  # literal $F launcher is the point of this case
assert_rc '$F . -exec rm -rf'          2 "$(run_case "$(j_bash '$F . -exec rm -rf {} +')")"
assert_rc '/usr/bin/fi?d -exec rm -rf'   2 "$(run_case "$(j_bash '/usr/bin/fi?d . -exec rm -rf {} +')")"
assert_rc 'gfind -exec rm -rf'           2 "$(run_case "$(j_bash 'gfind . -exec rm -rf {} +')")"
assert_rc 'fdfind -x rm -rf'             2 "$(run_case "$(j_bash 'fdfind -x rm -rf')")"
assert_rc 'bfs -exec rm -rf'             2 "$(run_case "$(j_bash 'bfs . -exec rm -rf {} +')")"
assert_rc 'bash -exec rm (-e -x -e -c)'  2 "$(run_case "$(j_bash 'bash -exec rm -rf d')")"
assert_rc 'sh -x rm script on PATH'      2 "$(run_case "$(j_bash 'sh -x rm -rf d')")"
assert_rc 'parallel -X rm -rf'           2 "$(run_case "$(j_bash 'parallel -X rm -rf ::: d')")"
assert_rc 'xargs -x rm -rf'              2 "$(run_case "$(j_bash 'ls | xargs -x rm -rf')")"
# The quote-normalised scan strips the quote that keeps the flag live.
assert_rc "echo 'a -ok rm \\-r d"        2 "$(run_case "$(j_bash "echo 'a -ok rm \\-r d")")"
assert_rc 'commit "x -exec rm -"r" d'    2 "$(run_case "$(j_bash 'git commit -m "x -exec rm -"r" d')")"
# Quoted text that documents the hook: pinned as main decides it. A quoted
# `;` reads as a separator (deny); a quoted rm with no separator before it
# is text (allow), so the ticket's quoted-rm over-deny is not present on main.
assert_rc 'commit "rm -rf is blocked" allowed' 0 "$(run_case "$(j_bash 'git commit -m "doc: rm -rf is blocked"')")"
assert_rc 'commit "guard; then rm -rf" denied' 2 "$(run_case "$(j_bash 'git commit -m "fix: guard; then rm -rf is denied"')")"
assert_rc 'commit "x; then shutdown" denied' 2 "$(run_case "$(j_bash 'git commit -m "x; then shutdown later"')")"
assert_rc 'commit "echo x -exec rm -rf" denied' 2 "$(run_case "$(j_bash 'git commit -m "echo x -exec rm -rf y"')")"
assert_rc 'commit "find -delete" allowed' 0 "$(run_case "$(j_bash 'git commit -m "docs: find -delete is now refused"')")"
assert_rc 'commit "xargs rm -rf" allowed' 0 "$(run_case "$(j_bash 'git commit -m "a xargs rm -rf b"')")"
assert_rc 'xargs echo allowed'           0 "$(run_case "$(j_bash 'ls | xargs echo')")"
assert_rc 'xargs rm -f denied (HIMMEL-4255)' 2 "$(run_case "$(j_bash 'ls | xargs rm -f')")"
assert_rc 'for; do echo allowed'         0 "$(run_case "$(j_bash 'for f in x; do echo; done')")"
assert_rc 'for; do rm -f allowed'        0 "$(run_case "$(j_bash 'for f in x; do rm -f "x"; done')")"
assert_rc 'if; then echo rm -r allowed'  0 "$(run_case "$(j_bash 'if true; then echo rm -r d; fi')")"
assert_rc 'nohup ls -r allowed'          0 "$(run_case "$(j_bash 'nohup ls -r')")"
assert_rc 'time make allowed'            0 "$(run_case "$(j_bash 'time make -j4')")"
assert_rc 'nice -n 5 make allowed'       0 "$(run_case "$(j_bash 'nice -n 5 make -r')")"
assert_rc 'echo do rm -r allowed'        0 "$(run_case "$(j_bash 'echo do rm -r d')")"
assert_rc 'grep "{ rm -r" allowed'       0 "$(run_case "$(j_bash 'grep "{ rm -r" f')")"
assert_rc 'commit fix(x) shutdown allowed' 0 "$(run_case "$(j_bash 'git commit -m "fix(x) shutdown flow"')")"
assert_rc 'curl -d {"format"} allowed'   0 "$(run_case "$(j_bash 'curl -d '\''{"format":"json"}'\'' x')")"
assert_rc 'command -v shutdown allowed'  0 "$(run_case "$(j_bash 'command -v shutdown')")"
assert_rc 'commit -m "nohup rm -r" allowed' 0 "$(run_case "$(j_bash 'git commit -m "nohup rm -r d"')")"

# --- BYPASS case ---
assert_rc "DESTRUCTIVE_OK bypass"       0 "$(run_case "$(j_bash 'rm -rf /tmp/x')" "DESTRUCTIVE_OK=1")"


# --- The forms the shell runs, not the text it was given ---
assert_rc "4438 quote-split g'i't reset --hard" 2 "$(run_case "$(j_bash "g'i't reset --hard")")"
assert_rc "4438 quoted \"rm\" -rf"            2 "$(run_case "$(j_bash '"rm" -rf /tmp/x')")"
assert_rc "4438 backslash r\\m -rf"           2 "$(run_case "$(j_bash 'r\m -rf /tmp/x')")"
assert_rc "4438 bash -c 'rm -rf'"             2 "$(run_case "$(j_bash "bash -c 'rm -rf /tmp/x'")")"
assert_rc "4438 sh -ec 'rm -rf'"              2 "$(run_case "$(j_bash "sh -ec 'rm -rf /tmp/x'")")"
assert_rc "4438 zsh -c nested bash -c"        2 "$(run_case "$(j_bash "zsh -c \"bash -c 'rm -rf /tmp/x'\"")")"
assert_rc "4438 eval 'rm -rf'"                2 "$(run_case "$(j_bash "eval 'rm -rf /tmp/x'")")"
assert_rc "4438 env with a quoted assignment" 2 "$(run_case "$(j_bash "env 'FOO=a b'c rm -rf /tmp/x")")"
assert_rc "4438 exec -a name rm -rf"          2 "$(run_case "$(j_bash "exec -a 'x' rm -rf /tmp/x")")"
assert_rc "4438 allow: bash -c 'ls -la'"      0 "$(run_case "$(j_bash "bash -c 'ls -la'")")"
assert_rc "4438 allow: echo 'rm -rf /tmp/x'"  0 "$(run_case "$(j_bash "echo 'rm -rf /tmp/x'")")"
# Guard-corpus gen rows (seeds = this suite's own rows
# rm $'\x2dr' d and xargs rm < list) that base allowed.
# The decode needs bash 4.4+ in the hook's PATH; an older one keeps the raw
# body, as before.
# shellcheck disable=SC2016 # the hook's bash expands it, not this shell
if [ "$(bash -c 'echo $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))')" -ge 404 ]; then
    assert_rc "4576 r'm' \$'\\x2dr' d"             2 "$(run_case "$(j_bash "r'm' \$'\\x2dr' d")")"
    assert_rc "4576 r\"m\" \$'\\x2dr' d"           2 "$(run_case "$(j_bash "r\"m\" \$'\\x2dr' d")")"
    assert_rc "4576 r\\m \$'\\x2dr' d"             2 "$(run_case "$(j_bash "r\\m \$'\\x2dr' d")")"
else
    echo "SKIP 4576 \$'…' decode rows (bash in PATH is older than 4.4)"
fi
assert_rc "4577 env 'FOO=a b'c xargs rm < list" 2 "$(run_case "$(j_bash "env 'FOO=a b'c xargs rm < list")")"
nolib=$(mktemp -d "${TMPDIR:-/tmp}/guard-nolib.XXXXXX") || exit 1
cp "$HOOK" "$nolib/block-destructive-commands.sh"
assert_rc "4438 missing guard-unwrap lib denies" 2 "$(printf '%s' "$(j_bash 'ls')" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" --read-only "$nolib" -- bash "$nolib/block-destructive-commands.sh" >/dev/null 2>&1; echo $?)"
rm -rf "$nolib"

# Bash <= 4.3 treats an empty "${arr[@]}" as unbound under set -u, so a
# plain `git push` was denied. Needs a real 4.3 binary (BASH43, never installed on the
# station); skipped when absent.
BASH43="${BASH43:-$HOME/.cache/himmel/verdicts/J1946/oldbash/src/bash-4.3.30/bash}"
if [ -x "$BASH43" ]; then
    for c in "git push" "git push origin feat/x"; do
        rc=$(printf '%s' "$(j_bash "$c")" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" --read-only "$BASH43" -- "$BASH43" "$HOOK" >/dev/null 2>&1; echo $?)
        assert_rc "4626 bash4.3 '$c' not over-denied" 0 "$rc"
    done
    rc=$(printf '%s' "$(j_bash 'git push -f origin main')" | bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh" --read-only "$BASH43" -- "$BASH43" "$HOOK" >/dev/null 2>&1; echo $?)
    assert_rc "4626 bash4.3 force push to main still denied" 2 "$rc"
else
    echo "SKIP 4626 bash4.3 cases (no binary at $BASH43)"
fi

# Git global options between `git` and the subcommand must not
# hide push --force, reset --hard, clean -f or filter-branch.
for c in \
    'git -C x push --force' \
    'git -C x push -f origin main' \
    'git -C x push origin +main' \
    'git -c a=b reset --hard' \
    'git -c a=b -C x reset --hard HEAD~1' \
    'git --no-pager clean -fdx' \
    'git --git-dir=.git --work-tree=. reset --hard' \
    'git --git-dir .git --work-tree . reset --hard' \
    'git --namespace n filter-branch --tree-filter true' \
    'git.exe -C x push --force' \
    'git --no-pager -C x push --force-with-lease origin main' \
    'git -C other push --force-with-lease origin feat/x' \
    'ls; git -C x push --force' \
    'git -C "my repo" reset --hard' \
    "git -C 'my repo' push --force" \
    'git -c "a=b c" clean -fd' \
    'git -c user.name="a b" reset --hard' \
    'git --git-dir="my dir" reset --hard' \
    "git --work-tree='my dir' push --force" \
    'git -C x status && git -C y reset --hard' \
    'git -c "a.b=;" push --force' \
    'git -C "a&b" push origin +main' \
    "git -c 'x.y=a|b' push -f" \
    'git -C ../other push --force-with-lease origin trunk -o "git push"'; do
    assert_rc "5274 deny: $c" 2 "$(run_case "$(j_bash "$c")")"
done
for c in \
    'git -C x status' \
    'git -C "my repo" status' \
    'git -c a=b log --oneline' \
    'git --no-pager diff' \
    'git -C x push origin feat/x' \
    'git -C x reset --soft HEAD~1' \
    'git -C x commit -m "reset --hard"' \
    'git --no-pager log --grep "clean -f"' \
    'git -c "a.b=;" status'; do
    assert_rc "5274 allow: $c" 0 "$(run_case "$(j_bash "$c")")"
done

finish_suite c
