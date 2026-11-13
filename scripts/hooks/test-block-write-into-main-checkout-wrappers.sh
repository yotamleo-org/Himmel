#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh — the
# rows: path-qualified wrapper names and chroot readings.
# Platform guard: any POSIX bash 3.2+ (same as the guard). A sibling of
# test-block-write-into-main-checkout.sh,
# split out so the parent suite stays under the CI per-suite cap; the harness
# below is a trimmed copy of the parent's (same fixtures, same FIXTURE RULE).
#
# Every row runs BOTH entry modes via `check_both`: direct-exec
# (`bash block-write-into-main-checkout.sh` with the JSON payload on stdin)
# and sourced (`bash block-terminal-write-fence.sh`, the codex adapter).
#
# FIXTURE RULE (load-bearing): fixtures are rooted under a non-temp home
# (lib-fixture-root.sh), NOT
# a bare `mktemp -d`. `/tmp` paths are exempted by is_temp_or_devnull, so a
# DENY row rooted under mktemp -d would pass as ALLOW for the wrong reason.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=lib-fixture-root.sh
. "$HOOKS/lib-fixture-root.sh"
_FROOT=$(fixture_root) || exit 1
FIX=$(mktemp -d "$_FROOT/.himmel-4329-fencefix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email t@example.invalid
git config --global user.name t
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true
unset EDIT_ON_MAIN_OK 2>/dev/null || true

mkrepo_committed() {  # mkrepo_committed <dir> <branch>
    git init -q -b "$2" "$1" >/dev/null 2>&1
    mkdir -p "$1/scripts/hooks" "$1/handovers"
    : > "$1/README.md"
    git -C "$1" add README.md >/dev/null 2>&1
    git -C "$1" commit -q -m init >/dev/null 2>&1
}

# $FIX/primary — main; $FIX/wt — linked worktree off it, feat/x.
mkrepo_committed "$FIX/primary" main
git -C "$FIX/primary" worktree add -q -b feat/x "$FIX/wt" >/dev/null 2>&1
mkdir -p "$FIX/primary/somedir"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# _run <script> <json> [cwd-for-hook-process] -> echoes allow/block/?(rc=N)
_run() {
    local script="$1" json="$2" hookpwd="${3:-}" rc got
    if [ -n "$hookpwd" ]; then
        ( cd "$hookpwd" && printf '%s' "$json" | bash "$script" >/dev/null 2>&1 )
        rc=$?
    else
        printf '%s' "$json" | bash "$script" >/dev/null 2>&1
        rc=$?
    fi
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    # BWIMC_REPLAY=<log>: also log this payload under both engines
    [ -z "${BWIMC_REPLAY:-}" ] || ( cd "${hookpwd:-.}" && bwimc_replay_row "${0##*/}" "-" "$script" "$json" )
    printf '%s' "$got"
}
# shellcheck source=lib/bash-ast-replay-bwimc.sh
[ -z "${BWIMC_REPLAY:-}" ] || . "$HOOKS/lib/bash-ast-replay-bwimc.sh"

# check_both <label> <block|allow> <json> — both entry modes must agree.
check_both() {
    local label="$1" expect="$2" json="$3" got
    got=$(_run "$DIRECT" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (direct-exec)"; else bad "$label (direct-exec) — expected $expect got $got"; fi
    got=$(_run "$FENCE" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (sourced/codex)"; else bad "$label (sourced/codex) — expected $expect got $got"; fi
}

_subst_row() { # label verdict command [cwd]
    local j
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
    check_both "$1" "$2" "$j"
}
_PR="$FIX/primary"; _WR="$FIX/wt"

# _r4213 runs a row from cwd /tmp AND from the primary checkout.
_r4213() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1, cwd /tmp" "$2" "$c" /tmp
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
}

echo "== HIMMEL-4329 path-qualified wrapper names, chroot readings =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# A wrapper name matches on its basename, any case, `.exe` dropped (the
# interp-body treatment): `/usr/bin/nice` strips like `nice`.
# One row per wrapper _bwimc_strip_prefix knows, bare / path / .exe.
for _w4329 in 'command|' 'exec|' 'nohup|' 'chrt|5' 'taskset|-c 0' 'ionice|-c 3' 'nice|-n 5' \
    'timeout|5' 'stdbuf|-oL' 'env|FOO=1' 'sudo|-u root' 'chroot|/'; do
    _n4329="${_w4329%%|*}"; _a4329="${_w4329#*|}"
    for _f4329 in "$_n4329" "/usr/bin/$_n4329" "$_n4329.exe"; do
        _r4213 "101 $_f4329 $_a4329 touch primary" block "$_f4329 $_a4329 touch @P@/f"
    done
    _r4213 "101 /usr/bin/$_n4329 $_a4329 touch worktree (ALLOW)" allow "/usr/bin/$_n4329 $_a4329 touch @W@/f"
done
_r4213 "101a /usr/bin/env -C primary touch f"                          block '/usr/bin/env -C @P@ touch f'
_r4213 "101b /usr/bin/nice touch primary"                              block '/usr/bin/nice touch @P@/f'
_r4213 "101c /usr/bin/sudo -D primary touch f"                         block '/usr/bin/sudo -D @P@ touch f'
_r4213 "101d /USR/BIN/NICE.EXE touch primary"                          block '/USR/BIN/NICE.EXE touch @P@/f'
_r4213 "101e /usr/bin/nice /usr/bin/env -C primary rm f"               block '/usr/bin/nice /usr/bin/env -C @P@ rm f'
_subst_row "101f /usr/bin/env -C /tmp touch f (ALLOW), cwd /tmp"       allow "/usr/bin/env -C /tmp touch f" /tmp
_r4213 "101g /usr/bin/nice touch /tmp (ALLOW)"                         allow '/usr/bin/nice touch /tmp/himmel-4329-f'
_r4213 "101h /usr/bin/env FOO=1 ls (ALLOW)"                            allow '/usr/bin/env FOO=1 ls'
_subst_row "101i /usr/bin/env -C worktree touch f (ALLOW), cwd /tmp"   allow "/usr/bin/env -C $_WR touch f" /tmp
# chroot DIR / sudo -R DIR / sudo --chroot=DIR: the command's / is DIR, so a
# write target is also read as DIR + target; an unknown DIR fails closed.
_r4213 "102a sudo -R primary -D / touch /f"                            block 'sudo -R @P@ -D / touch /f'
_r4213 "102b sudo --chroot=primary touch /f"                           block 'sudo --chroot=@P@ touch /f'
_r4213 "102c chroot primary touch /f"                                  block 'chroot @P@ touch /f'
_r4213 "102d sudo --chroot primary touch /f"                           block 'sudo --chroot @P@ touch /f'
_r4213 "102e sudo -Rprimary touch /f"                                  block 'sudo -R@P@ touch /f'
_r4213 "102f /usr/sbin/chroot primary touch /f"                        block '/usr/sbin/chroot @P@ touch /f'
_r4213 "102g chroot --userspec=u:g primary rm /README.md"              block 'chroot --userspec=u:g @P@ rm /README.md'
# a root that IS the primary denies any write, even one the host would exempt
_r4213 "102h chroot primary touch /tmp/f (root is the primary)"        block 'chroot @P@ touch /tmp/f'
_subst_row "102i chroot primary touch f (relative: the chroot's /), cwd /tmp" block "chroot $_PR touch f" /tmp
_r4213 "102j chroot primary cp to /f"                                  block 'chroot @P@ cp /etc/hosts /f'
_r4213 "102k chroot \$X touch /f (unknown root)"                       block 'chroot $X touch /f'
_r4213 "102l chroot --bogus primary touch /f (unknown option)"         block 'chroot --bogus @P@ touch /f'
_subst_row "102m chroot fixture-root touch /primary/f (root above the primary), cwd /tmp" block "chroot $FIX touch /primary/f" /tmp
_subst_row "102n chroot rel-root touch /f (relative root), cwd the primary's parent" block "chroot primary touch /f" "$FIX"
_r4213 "102o chroot /srv/x touch /f (ALLOW)"                           allow 'chroot /srv/himmel-4329-x touch /f'
_r4213 "102p sudo -R /srv/x touch /f (ALLOW)"                          allow 'sudo -R /srv/himmel-4329-x touch /f'
_r4213 "102q chroot primary ls (no write, ALLOW)"                      allow 'chroot @P@ ls /'
_r4213 "102r chroot worktree touch /f (ALLOW)"                         allow 'chroot @W@ touch /f'
_r4213 "102s chroot / touch /tmp (ALLOW)"                              allow 'chroot / touch /tmp/himmel-4329-f'
# Inside the jail an absolute symlink restarts at the root
# and `..` stops there, so a root ABOVE the primary reaches it through a link
# the host resolves elsewhere. Fixture links live under $FIX only.
ln -sfn /primary "$FIX/jlnk"          # jail /jlnk -> jail /primary = $FIX/primary
ln -sfn ../../primary "$FIX/jrel"     # `..` clamps at the jail root -> $FIX/primary
mkdir -p "$FIX/jail"
ln -sfn /etc "$FIX/jail/jlnk"         # unrelated jail: its /etc, never the primary
_subst_row "102t chroot fixture-root touch /jlnk/f (absolute in-jail symlink), cwd /tmp" block "chroot $FIX touch /jlnk/f" /tmp
_subst_row "102u chroot fixture-root touch jlnk/f (relative target via the link), cwd /tmp" block "chroot $FIX touch jlnk/f" /tmp
_subst_row "102v chroot fixture-root touch /jrel/f (relative link, .. clamps at the root), cwd /tmp" block "chroot $FIX touch /jrel/f" /tmp
_subst_row "102w chroot fixture-root rm /jlnk/README.md, cwd /tmp" block "chroot $FIX rm /jlnk/README.md" /tmp
_subst_row "102x chroot primary/somedir touch /../../x (.. clamps at a root inside the primary), cwd /tmp" block "chroot $FIX/primary/somedir touch /../../x" /tmp
_subst_row "102y chroot fixture-root touch /../../../primary/f (.. clamps at an ancestor root), cwd /tmp" block "chroot $FIX touch /../../../primary/f" /tmp
_subst_row "102z chroot unrelated-jail touch /jlnk/f (ALLOW), cwd /tmp" allow "chroot $FIX/jail touch /jlnk/f" /tmp
# Tee behind a chroot (or any wrapper arm (a) does not
# anchor) and a git write behind a chroot escaped the root model.
_r4213 "103a chroot primary tee /f"                                    block 'echo x | chroot @P@ tee /f'
_r4213 "103b chroot primary tee -a /f"                                 block 'chroot @P@ tee -a /f'
_r4213 "103c sudo -R primary tee /f"                                   block 'echo x | sudo -R @P@ tee /f'
_r4213 "103d sudo --chroot=primary tee /f"                             block 'echo x | sudo --chroot=@P@ tee /f'
_r4213 "103e /usr/sbin/chroot primary tee /f"                          block 'echo x | /usr/sbin/chroot @P@ tee /f'
_r4213 "103f chroot primary nice tee /f"                               block 'echo x | chroot @P@ nice tee /f'
_r4213 "103g chroot primary timeout 5 tee /f"                          block 'echo x | chroot @P@ timeout 5 tee /f'
_r4213 "103h chroot primary /usr/bin/tee /f"                           block 'echo x | chroot @P@ /usr/bin/tee /f'
_subst_row "103i chroot fixture-root tee /primary/f, cwd /tmp"          block "echo x | chroot $FIX tee /primary/f" /tmp
_subst_row "103j sudo -R fixture-root tee -a /primary/f, cwd /tmp"      block "echo x | sudo -R $FIX tee -a /primary/f" /tmp
_r4213 "103k nice tee primary (host)"                                  block 'echo x | nice tee @P@/f'
_r4213 "103l /usr/bin/tee primary (host)"                              block 'echo x | /usr/bin/tee @P@/f'
_r4213 "103m chroot primary git -C / add ."                            block 'chroot @P@ git -C / add .'
_subst_row "103n chroot fixture-root git -C /primary add ., cwd /tmp"   block "chroot $FIX git -C /primary add ." /tmp
_r4213 "103o sudo -R primary git push"                                 block 'sudo -R @P@ git push origin x'
_r4213 "103p chroot worktree tee /f (ALLOW)"                           allow 'echo x | chroot @W@ tee /f'
_r4213 "103q chroot /srv/x tee /f (ALLOW)"                             allow 'echo x | chroot /srv/himmel-4329-x tee /f'
_r4213 "103r chroot primary git status (read, ALLOW)"                  allow 'chroot @P@ git status'
_r4213 "103s chroot / git status (ALLOW)"                              allow 'chroot / git status'
_r4213 "103t nice tee /tmp (ALLOW)"                                    allow 'echo x | nice tee /tmp/himmel-4329-f'
}

echo "== HIMMEL-9913: read-only git archive/bundle, guest-exec argv as data =="
{
_subst_row "106a git -C primary archive HEAD | wc -c, cwd the primary (ALLOW)" allow \
    "git -C $_PR archive HEAD | wc -c" "$_PR"
_subst_row "106b git archive HEAD | sha256sum, cwd the primary (ALLOW)" allow \
    "git archive HEAD | sha256sum" "$_PR"
_subst_row "106c git bundle list-heads, cwd the primary (ALLOW)" allow \
    "git bundle list-heads /tmp/himmel-9913.bundle" "$_PR"
_subst_row "106d git -C primary bundle verify (ALLOW)" allow \
    "git -C $_PR bundle verify /tmp/himmel-9913.bundle"
_subst_row "106e git -C primary archive -o primary/x.tgz HEAD denies" block \
    "git -C $_PR archive -o $_PR/x.tgz HEAD" "$_PR"
_subst_row "106f git archive HEAD | tar -x, cwd the primary denies" block \
    "git archive HEAD | tar -x" "$_PR"
_subst_row "106g git archive HEAD | wc -c | sh, cwd the primary denies" block \
    "git archive HEAD | wc -c | sh" "$_PR"
_subst_row "106h git archive HEAD | head -c 9 > x.tar, cwd the primary denies" block \
    "git archive HEAD | head -c 9 > x.tar" "$_PR"
_subst_row "106i git archive --format=zip HEAD | wc -c (runs a configured command) denies" block \
    "git archive --format=zip HEAD | wc -c" "$_PR"
_subst_row "106j git bundle create x.bundle HEAD, cwd the primary denies" block \
    "git bundle create x.bundle HEAD" "$_PR"
_subst_row "106k git bundle unbundle, cwd the primary denies" block \
    "git bundle unbundle /tmp/himmel-9913.bundle" "$_PR"
_subst_row "106l git rev-list | xargs -I{} git show {} (stdin words reach git's options) denies" block \
    "git -C $_PR rev-list -3 HEAD | xargs -I{} git -C $_PR show {} --stat"
}

unset HIMMEL_VMSDK HIMMEL_GUEST_EXEC_LOG 2>/dev/null || true
mkdir -p "$FIX/primary/scripts/vm" "$FIX/primary/scripts/lib" "$FIX/loose/scripts/vm" "$FIX/loose/scripts/lib"
cp "$HOOKS/../vm/guest-exec.sh" "$FIX/primary/scripts/vm/"
cp "$HOOKS/../lib/vmsdk.py" "$HOOKS/../lib/vbox.py" "$FIX/primary/scripts/lib/"
git -C "$FIX/primary" add scripts >/dev/null 2>&1
git -C "$FIX/primary" commit -q -m ge >/dev/null 2>&1
git -C "$FIX/primary" worktree add -q -b ge9913 "$FIX/wtge" >/dev/null 2>&1
git -C "$FIX/primary" worktree add -q -b ge9913b "$FIX/wtgeb" >/dev/null 2>&1
printf 'echo edited\n' >> "$FIX/wtgeb/scripts/vm/guest-exec.sh"
cp "$HOOKS/../vm/guest-exec.sh" "$FIX/loose/scripts/vm/"
cp "$HOOKS/../lib/vmsdk.py" "$FIX/loose/scripts/lib/"
printf '# other\n' > "$FIX/loose/scripts/lib/vbox.py"
[ -f "$FIX/wtge/scripts/lib/vbox.py" ] || bad "107 setup: the guest-exec fixture worktree was not created"
grep -q '^echo edited$' "$FIX/wtgeb/scripts/vm/guest-exec.sh" || bad "107 setup: the edited guest-exec worktree was not created"
_GW="$FIX/wtge"
{
_subst_row "107a guest-exec -- bash -c 'cd ~/himmel && git log -1' (ALLOW)" allow \
    "bash scripts/vm/guest-exec.sh vm -- bash -c 'cd ~/himmel && git log -1'" "$_GW"
_subst_row "107b guest-exec by absolute path, --sudo --timeout, body writes a guest path (ALLOW)" allow \
    "bash $_GW/scripts/vm/guest-exec.sh vm --sudo --timeout 60 -- bash -c 'cd /srv && make > build.log'" "$_GW"
_subst_row "107c guest-exec … > primary/f (host redirect) denies" block \
    "bash scripts/vm/guest-exec.sh vm -- bash -c 'echo x' > $_PR/f" "$_GW"
_subst_row "107d guest-exec … ; echo x > primary/f denies" block \
    "bash scripts/vm/guest-exec.sh vm -- ls; echo x > $_PR/f" "$_GW"
_subst_row "107e HIMMEL_VMSDK=… guest-exec (repointed program) denies" block \
    "HIMMEL_VMSDK=/tmp/x.py bash scripts/vm/guest-exec.sh vm -- bash -c 'echo x > $_PR/f'" "$_GW"
_subst_row "107f guest-exec with a double-quoted \$(…) the host expands denies" block \
    "bash scripts/vm/guest-exec.sh vm -- bash -c \"echo \$(cat $_PR/a > $_PR/b)\"" "$_GW"
_subst_row "107g guest-exec … | tee primary/f denies" block \
    "bash scripts/vm/guest-exec.sh vm -- bash -c 'cd ~/himmel' | tee $_PR/f" "$_GW"
_subst_row "107h a guest-exec.sh whose vbox.py differs from this checkout's denies" block \
    "bash $FIX/loose/scripts/vm/guest-exec.sh vm -- bash -c 'echo x > $_PR/f'" "$_GW"
_subst_row "107i a guest-exec.sh whose bytes differ from this checkout's denies" block \
    "bash $FIX/wtgeb/scripts/vm/guest-exec.sh vm -- bash -c 'echo x > $_PR/f'" "$_GW"
_subst_row "107j cd /tmp && guest-exec (not the whole command) denies" block \
    "cd /tmp && bash scripts/vm/guest-exec.sh vm -- bash -c 'echo x > $_PR/f'" "$_GW"
}

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
