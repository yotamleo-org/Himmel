#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh (split, so each
# suite stays under its CI per-suite cap): the cd/cwd-tracking and
# install/rsync/dd/eval rows (and its CR rounds).
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh;
# the FIXTURE RULE lives in test-block-write-into-main-checkout.sh.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"

echo "== HIMMEL-3648: install/rsync/dd/cd-then-relative/eval-bash-c pre-existing gaps =="

# 13. install: last non-option operand is the destination.
check_both "13 install SRC into primary (last operand)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install $FIX/wt/src.txt $FIX/primary/dest.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "13b install SRC into wt (last operand) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install $FIX/wt/src.txt $FIX/wt/dest.txt\",\"cwd\":\"$FIX/wt\"}}"

# 14. install -t/--target-directory DIR.
check_both "14 install -t primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install -t $FIX/primary $FIX/wt/src.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "14b install -t wt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install -t $FIX/wt $FIX/wt/src.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "14c install --target-directory=primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install --target-directory=$FIX/primary $FIX/wt/src.txt\",\"cwd\":\"$FIX/wt\"}}"

# 15. rsync: destination operand (last non-option operand).
check_both "15 rsync SRC into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/primary/dest.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "15b rsync SRC into wt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/wt/dest.txt\",\"cwd\":\"$FIX/wt\"}}"

# 16. dd: of=PATH is a write destination.
check_both "16 dd of=primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"dd if=/dev/zero of=$FIX/primary/dd.img\",\"cwd\":\"$FIX/wt\"}}"
check_both "16b dd of=wt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"dd if=/dev/zero of=$FIX/wt/dd.img\",\"cwd\":\"$FIX/wt\"}}"

# 17. cd <primary> && <relative write> — the git-arm cd tracking never reached
# the redirect arm; a && segment after a cd into the primary must now deny.
check_both "17 cd primary && echo x > a.txt (relative write after cd)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "17b cd wt && echo x > a.txt (relative write after cd) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 18. Same shape with `;` instead of `&&`.
check_both "18 cd primary; echo x > a.txt (relative write after cd)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "18b cd wt; echo x > a.txt (relative write after cd) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 19. eval '<write-shaped body>' — a write-shaped token inside the eval string
# was never scanned at all.
check_both "19 eval redirect into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"eval \\\"echo hi > $FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "19b eval redirect into wt (provably scratch) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"eval \\\"echo hi > $FIX/wt/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

# 20. bash -c '<write-shaped body>'.
check_both "20 bash -c redirect into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c \\\"echo hi > $FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "20b bash -c redirect into wt (provably scratch) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c \\\"echo hi > $FIX/wt/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

# 21. sh -c '<write-shaped body>' (cp verb, not a redirect).
check_both "21 sh -c cp into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sh -c \\\"cp $FIX/wt/src.txt $FIX/primary/dest.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "21b sh -c cp into wt (provably scratch) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sh -c \\\"cp $FIX/wt/src.txt $FIX/wt/dest.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

# 22. zsh -c '<write-shaped body>' (rm verb).
check_both "22 zsh -c rm into primary" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"zsh -c \\\"rm $FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "22b zsh -c rm into wt (provably scratch) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"zsh -c \\\"rm $FIX/wt/wtfile.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR follow-up fixes (codex-1/2/3) =="

# 23 (codex-2): `install -d`/`--directory` puts install in directory-creation
# mode, where every operand is itself a destination to create, not a source
# followed by a trailing destination — the generic option-skip previously
# dropped -d's operand from consideration entirely.
check_both "23 install -d primary/newdir (directory-creation mode) denies (codex-2)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install -d $FIX/primary/newdir\",\"cwd\":\"$FIX/wt\"}}"
check_both "23b install -d wt/newdir (directory-creation mode) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install -d $FIX/wt/newdir\",\"cwd\":\"$FIX/wt\"}}"

# 24 (codex-1): an unresolvable cd (popd/`cd -`/a dynamic target) must leave
# _bwimc_ecwd_unres STICKY — a later RELATIVE cd resolving against the STALE
# base must not silently clear it and re-trust a subsequent relative write.
# Any relative write after popd denies regardless of where it actually
# points, per the ticket's fail-closed design; only an ABSOLUTE cd may
# re-establish trust (24b).
check_both "24 popd; cd ../elsewhere && echo x > a.txt (relative cd after popd stays unresolved) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"popd; cd ../elsewhere && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "24b popd; cd $FIX/wt && echo x > a.txt (absolute cd after popd re-resolves) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"popd; cd $FIX/wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 25 (codex-3): bash/sh/zsh accept a COMBINED short-option cluster (`-ce`,
# `-ec`, …) exactly as they accept a bare `-c` — a literal `-c` match let
# `bash -ce "..."` straight through unscanned.
check_both "25 bash -ce redirect into primary (combined short-flag cluster) denies (codex-3)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -ce \\\"echo hi > $FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "25b bash -ce redirect into wt (combined short-flag cluster) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -ce \\\"echo hi > $FIX/wt/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

# 26: an ATTACHED redirect
# target inside an eval/bash-c body (`>/primary/f`, no space, one token) was
# ignored — _bwimc_check_interp_body's redirect arm unconditionally advanced
# to the NEXT token and checked THAT, the same false-negative shape the main
# clause loop's own _bwimc_op_rest handling exists to close.
check_both "26 eval 'echo hi >primary/a.txt' (attached redirect target) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"eval 'echo hi >$FIX/primary/a.txt'\",\"cwd\":\"$FIX/wt\"}}"
check_both "26b eval 'echo hi >wt/a.txt' (attached redirect target) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"eval 'echo hi >$FIX/wt/a.txt'\",\"cwd\":\"$FIX/wt\"}}"
check_both "26c bash -c \"echo hi >primary/a.txt\" (attached redirect target) denies (codex-1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c \\\"echo hi >$FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 3 (codex-1/2 on the interp-body scan) =="

# 27: `git … commit` inside an eval/bash -c/sh -c/zsh -c
# body is a CWD predicate the redirect/token walk never checks (neither
# "git" nor "commit" is a token PATH) — the git-commit arm (g) is a separate,
# dedicated regex-anchored scan over OUTER clauses only, structurally
# unreachable from inside an interp-body string.
check_both "27 bash -c 'cd primary && git commit' denies (codex-1 round 3)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/primary && git commit --allow-empty -m x'\",\"cwd\":\"$FIX/wt\"}}"
check_both "27b bash -c 'cd wt && git commit' allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/wt && git commit --allow-empty -m x'\",\"cwd\":\"$FIX/wt\"}}"

# 28: an intra-body cd/pushd was never tracked at all —
# item 17/18 above cover a DIRECT `cd <primary> && <write>`, but the SAME
# shape wrapped in `bash -c '...'` bypassed both the outer cd-tracking (it
# only ever saw the literal string "bash", "-c", "'cd ... '" as its OWN
# clause, never descending into the quoted body) and the interp-body scan
# (which checked token PATHS but never modelled a cd inside the body).
check_both "28 bash -c 'cd primary; echo x > a.txt' denies (codex-2 round 3)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/primary; echo x > a.txt'\",\"cwd\":\"$FIX/wt\"}}"
check_both "28b bash -c 'cd wt; echo x > a.txt' allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/wt; echo x > a.txt'\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 4 (codex-1 on the interp-body scan) =="

# 29: the earlier fix tracked cwd across the WHOLE body
# first and only then checked every token against that FINAL cwd — correct
# when the body never cd's again after its last write, wrong when it does: a
# write that happens WHILE cd'd into the primary, followed by a LATER cd back
# out, was checked against the body's END state (the later cd's target) and
# allowed even though the write itself landed in the primary.
check_both "29 bash -c 'cd primary; echo x > a.txt; cd wt' denies (codex-1 round 4)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/primary; echo x > a.txt; cd $FIX/wt'\",\"cwd\":\"$FIX/wt\"}}"
check_both "29b bash -c 'cd wt; echo x > a.txt; cd wt' allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'cd $FIX/wt; echo x > a.txt; cd $FIX/wt'\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 5 (codex-1 on 'cd --' handling) =="

# 30: the cd/pushd flag-skip loop (both _bwimc_ecwd_track
# and _bwimc_git_clause) recognized -L/-P/-e/-@ but not the POSIX option
# terminator `--`. Given `cd -- <dir>`, the loop left its index pointing at
# the `--` token itself, which was then misread as the cd TARGET (a relative
# path fragment against the tracked cwd) — the real target after it was
# never consumed, so the tracked cwd went stale and a later relative write
# was checked against the wrong directory.
check_both "30 cd -- primary; echo x > a.txt' denies (codex-1 round 5)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd -- $FIX/primary; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "30b cd -- wt; echo x > a.txt' allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd -- $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 30c/30d: the same `--` gap in _bwimc_git_clause (arm g's own cd tracking,
# a separate code path from _bwimc_ecwd_track above) — direct top-level
# `cd -- <dir> && git commit`, no bash -c wrapper.
check_both "30c cd -- primary && git commit denies (codex-1 round 5, git-arm)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd -- $FIX/primary && git commit --allow-empty -m x\",\"cwd\":\"$FIX/wt\"}}"
check_both "30d cd -- wt && git commit allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd -- $FIX/wt && git commit --allow-empty -m x\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 6 (codex-3, rsync separated-value options) =="

# 31 (codex-3, round f688778c): rsync's own value-taking options
# (--exclude PATTERN, -e CMD, --temp-dir DIR, ...) were not skipped, so a
# SEPARATED option value after the real destination fell through the
# generic operand scan and was picked up as the "last operand" instead —
# `rsync SRC /primary/dest --exclude pattern` misread `pattern` as the
# destination, masking the real one and letting the write through.
check_both "31 rsync SRC primary/dest --exclude pattern denies (codex-3 round 6)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/ $FIX/primary/dest --exclude pattern\",\"cwd\":\"$FIX/wt\"}}"
check_both "31b rsync SRC wt/dest --exclude pattern allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/ $FIX/wt/dest --exclude pattern\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 7 (CodeRabbit review, PR #1307) =="

# 32/32b (CodeRabbit #1307): a bare `pushd` (no argument) swaps the top two
# directory-stack entries — or errors, leaving cwd UNCHANGED, if there is no
# second stack entry — it is not a `cd` to HOME. The tracker treated it as
# `cd $HOME`, which could silently clear a primary-rooted tracked cwd.
check_both "32 cd primary; pushd; echo x > a.txt denies (bare pushd not HOME, CodeRabbit #1307)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; pushd; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "32b cd wt; pushd; echo x > a.txt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt; pushd; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 33 (CodeRabbit #1307): `pushd +N`/`-N` rotates the directory stack — which
# this hook does not track — but the old code resolved "+N" as a literal
# relative path fragment against the tracked cwd instead of failing closed.
# No relative "33b": the fix deliberately fails closed for every later
# relative write after a `+N`/`-N` rotation regardless of where it really
# resolves, matching row 24/24b's precedent — only an ABSOLUTE re-anchor is
# trusted once the tracked cwd is unresolved.
check_both "33 pushd primary; pushd wt; pushd +1; echo x > a.txt denies (CodeRabbit #1307)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pushd $FIX/primary; pushd $FIX/wt; pushd +1; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "33b same, but absolute write target allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pushd $FIX/primary; pushd $FIX/wt; pushd +1; echo x > $FIX/wt/a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 34/34b (CodeRabbit #1307): a backtick command-substitution cd/pushd target
# is dynamic, but _bwimc_unq stripped backticks UNCONDITIONALLY before the
# target ever reached _bwimc_resolve_abs/_bwimc_expand_token — laundering a
# genuinely dynamic target into a bogus literal relative-path fragment
# instead of failing closed. Fixed by checking the RAW token first.
F34_CMD="cd \`echo $FIX/primary\`; echo x > a.txt"
F34_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F34_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "34 cd \`echo primary\`; echo x > a.txt denies (CodeRabbit #1307)" block "$F34_JSON"
# a fail-closed (shape) refusal names its literal retry.
check_both_reason "34 fail-closed deny names the one-literal-write retry" "$F34_JSON" \
    "one write per Bash call"
F34B_CMD="cd \`echo $FIX/primary\`; echo x > $FIX/wt/a.txt"
F34B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F34B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "34b same, but absolute write target allows" allow "$F34B_JSON"

# 35/35b (CodeRabbit #1307): the interpreter-body shell-name match anchored
# on the bare name (bash|sh|zsh) only, so a path-qualified invocation
# (`/bin/sh -c ...`) bypassed body scanning entirely — 35b is the genuine
# regression control: once the widened regex starts scanning a
# path-qualified invocation, it must still allow a non-primary body.
F35_CMD="/bin/sh -c \"echo hi > $FIX/primary/a.txt\""
F35_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F35_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "35 /bin/sh -c denies path-qualified shell body write (CodeRabbit #1307)" block "$F35_JSON"
F35B_CMD="/bin/sh -c \"echo hi > $FIX/wt/a.txt\""
F35B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F35B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "35b /bin/sh -c allows a worktree body write" allow "$F35B_JSON"

# 36/36b (CodeRabbit #1307): install's other separated-value options
# (-m/-o/-g/-S/--strip-program) were unhandled, so a value AFTER the real
# destination fell through to the generic operand scan and was picked up as
# the misread "last operand" — `install SRC /primary/dest -m 755` let "755"
# mask the real destination.
check_both "36 install SRC primary/dest -m 755 denies (CodeRabbit #1307)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install $FIX/wt/src.txt $FIX/primary/dest.txt -m 755\",\"cwd\":\"$FIX/wt\"}}"
check_both "36b install SRC wt/dest -m 755 allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"install $FIX/wt/src.txt $FIX/wt/dest.txt -m 755\",\"cwd\":\"$FIX/wt\"}}"

# 37/37b (CodeRabbit #1307): the same separated-value-option gap in rsync's
# own skip-list — -T/--temp-dir's short form, -B/--block-size,
# -M/--remote-option and --suffix were missing, so a value after the real
# destination masked it the same way as row 31.
check_both "37 rsync SRC primary/dest -T /tmp/foo denies (CodeRabbit #1307)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/primary/dest.txt -T /tmp/foo\",\"cwd\":\"$FIX/wt\"}}"
check_both "37b rsync SRC wt/dest -T /tmp/foo allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/wt/dest.txt -T /tmp/foo\",\"cwd\":\"$FIX/wt\"}}"

# 38/38b (CodeRabbit #1307): the interpreter-body scanner's generic
# non-flag-token check never isolated a `key=value`-shaped write
# destination — `dd if=... of=PATH` inside an eval/bash -c body checked the
# WHOLE "of=PATH" string as one relative-path fragment, never matching PATH
# itself.
F38_CMD="bash -c 'dd if=/dev/zero of=$FIX/primary/dd.img'"
F38_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F38_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "38 bash -c dd of=primary/dd.img denies (CodeRabbit #1307)" block "$F38_JSON"
F38B_CMD="bash -c 'dd if=/dev/zero of=$FIX/wt/dd.img'"
F38B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F38B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "38b bash -c dd of=wt/dd.img allows" allow "$F38B_JSON"

echo "== HIMMEL-3648 CR round 8 (CodeRabbit review threads, PR #1307) =="

# 39/39b (CodeRabbit #1307): the interpreter-body shell-name match added in
# row 35 covered a path-qualified bash/sh/zsh, but not dash/ksh — the most
# common alternate shells this same regex is meant to close off.
F39_CMD="dash -c \"echo hi > $FIX/primary/a.txt\""
F39_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F39_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "39 dash -c denies a primary body write (CodeRabbit #1307)" block "$F39_JSON"
F39B_CMD="dash -c \"echo hi > $FIX/wt/a.txt\""
F39B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F39B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "39b dash -c allows a worktree body write" allow "$F39B_JSON"

# 40/40b (CodeRabbit #1307): rows 31/37's rsync value-option skip-list was
# still missing several long-form value-taking options (--iconv among them)
# — a value after the real destination masked it the same way as row 31.
check_both "40 rsync SRC primary/dest --iconv utf8 denies (CodeRabbit #1307)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/primary/dest.txt --iconv utf8\",\"cwd\":\"$FIX/wt\"}}"
check_both "40b rsync SRC wt/dest --iconv utf8 allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/wt/dest.txt --iconv utf8\",\"cwd\":\"$FIX/wt\"}}"

# 41/41b (CodeRabbit #1307): a REMOTE rsync destination (`user@host:/path`)
# never writes into the LOCAL primary checkout, but the destination check
# resolved it as a local relative path against the tracked cwd and denied
# it — a false deny, not a security gap, but the finding's exact functional
# defect. 41b is the regression control: a genuinely LOCAL rsync
# destination inside the primary must still deny.
check_both "41 rsync ./ user@host:/srv/app from primary cwd allows (remote dest, CodeRabbit #1307)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a ./ user@host:/srv/app\",\"cwd\":\"$FIX/primary\"}}"
check_both "41b rsync SRC primary/dest (local) still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rsync -a $FIX/wt/src.txt $FIX/primary/dest.txt\",\"cwd\":\"$FIX/wt\"}}"

# 42/42b (CodeRabbit #1307, partial fix on the "Heavy lift" interp-body
# finding): a long option's value is ATTACHED with `=`
# (`--target-directory=PATH`) inside an eval/bash -c body — the bare `-*`
# skip in the interp-body scan dropped it unchecked, same "of=PATH" shape
# row 38 already fixed for a non-flag token, just not yet for a `-*` one.
F42_CMD="bash -c 'install --target-directory=$FIX/primary $FIX/wt/src.txt'"
F42_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F42_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "42 bash -c install --target-directory=primary denies (CodeRabbit #1307)" block "$F42_JSON"
F42B_CMD="bash -c 'install --target-directory=$FIX/wt $FIX/wt/src.txt'"
F42B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F42B_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "42b bash -c install --target-directory=wt allows" allow "$F42B_JSON"

echo "== HIMMEL-3648 CR round 9 (judge J1307O verdict — union fix: cd tracking may only ADD denies, C1) =="

# 43-54: from a PRIMARY payload cwd, _bwimc_ecwd_track treats
# every cd/pushd clause as though it ran in the CURRENT shell — it has no
# model of a nonexistent target, ||/&&-short-circuiting, a subshell, a
# pipeline, a background &, an if/while body that never runs, or a $(...)
# command substitution. Each shape below has the REAL cwd stay in the
# primary while the tracker's cd resolves to <wt>, so the relative write
# that follows is checked against <wt> and wrongly ALLOWED at the pre-fix
# head — while the write really lands in the primary. main DENIES every
# one of these; so must head, post-fix.
check_both "43 fromP: cd wt/nope; echo x > a.txt (nonexistent cd target, HIMMEL-3695 shape) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "44 fromP: cd wt/nope; touch b.txt (same shape, touch) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; touch b.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "45 fromP: cd wt/nope; cp wt/src.txt b.txt (same shape, cp dest) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; cp $FIX/wt/src.txt b.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "46 fromP: cd primary || cd wt; echo x > a.txt (HIMMEL-3685 primary-cwd half — first cd succeeds so the || never runs) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "47 fromP: (cd wt && true); echo x > a.txt (subshell cd never escapes) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"(cd $FIX/wt && true); echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "48 fromP: false && cd wt; echo x > a.txt (short-circuited cd never runs) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"false && cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "49 fromP: true || cd wt; echo x > a.txt (short-circuited cd never runs) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true || cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "50 fromP: cd wt | cat; echo x > a.txt (pipeline component runs in its own subshell) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "51 fromP: cd wt & echo x > a.txt (backgrounded cd runs in its own subshell) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt & echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "52 fromP: if false; then cd wt; fi; echo x > a.txt (never-entered if body) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"if false; then cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "53 fromP: while false; do cd wt; done; echo x > a.txt (never-entered while body) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"while false; do cd $FIX/wt; done; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "54 fromP: x=\$(cd wt); echo x > a.txt (cd inside a command substitution is its own subshell) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x=\$(cd $FIX/wt); echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"

# 55 (relaxation-loss control): base has no cd tracking at all,
# so it DENIES `cd <wt> && echo x > a.txt` from a primary cwd outright
# (documented in base's header as correct-by-policy), even though this ONE
# shape is a genuine, unconditional cd and runtime lands safely in wt. The
# strict superset rule (cd tracking may only ADD denies relative to a
# payload-cwd-only check, never remove one — except the cp/mv/ln
# destination-type class deferred to) takes this relaxation back:
# post-fix, the union check fires on every _bwimc_ecwd/_bwimc_cwd
# divergence unconditionally, so this row denies again too.
# (Relaxed ONLY for a cd target in no git repo at all — rows 97+.)
check_both "55 fromP: cd wt && echo x > a.txt (genuine, runtime-safe cd — still denies post-fix under the strict superset rule)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"

echo "== HIMMEL-3648 CR round 10 (codex-1 — _bwimc_cd_guard's fallback must use the CALLER's own mode) =="

# 56-58 (codex-1): the round-9 union fix's fallback (_bwimc_cd_guard, fires on
# _bwimc_ecwd/_bwimc_cwd divergence) always checked the real payload cwd with
# an implicit "follow" mode, regardless of what the calling arm's own main
# check actually uses. $FIX/primary/link-to-wt.txt is a symlink whose ENTRY
# lives in the primary but whose REFERENT ($FIX/wt/wtfile.txt) resolves
# outside it (fixture, set up above at "A symlink INSIDE the primary pointing
# OUT at a worktree file"). Combined with a nonexistent-cd-target divergence
# (row 43's shape) the main check (against the tracked, wrong cwd) never
# fires, leaving the fallback as the SOLE catcher — and a "follow" fallback
# wrongly resolves through the symlink to its worktree referent and ALLOWS
# deleting/overwriting a primary checkout ENTRY. rm and mv's source use ENTRY
# semantics (unlink/rename act on the entry, never the referent); a
# non-directory ln destination is the same. Fixed by threading each caller's
# own mode into _bwimc_cd_guard's $2 so the fallback runs byte-for-byte the
# same check the main call site uses.
check_both "56 fromP: cd wt/nope; rm link-to-wt.txt (rm on a primary symlink ENTRY, referent outside, via the fallback) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; rm link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "57 fromP: cd wt/nope; mv link-to-wt.txt $FIX/wt/dest-mv.txt (mv SOURCE is a primary symlink ENTRY via the fallback) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; mv link-to-wt.txt $FIX/wt/dest-mv.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "58 fromP: cd wt/nope; ln -sf $FIX/wt/z.txt link-to-wt.txt (ln DEST is a primary symlink ENTRY via the fallback) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/nope; ln -sf $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"

echo "== HIMMEL-3648 CR round 13 (J1307Q — the cp/mv POSITIONAL-destination arm never threaded its own mode into _bwimc_cd_guard) =="

# 60-65: rows 56-58 fixed the fallback's mode for rm/mv-source/ln,
# but the cp/mv POSITIONAL-destination arm (the branch computing entry/both
# for a symlink-entry destination via mv, `cp --remove-destination`, `cp -f`
# and `mv -T`) still called _bwimc_cd_guard BEFORE that mode was computed,
# with no $2 at all — an implicit "follow" default. Under a real cd/pushd
# divergence the main check (against the wrong tracked cwd) never fires,
# leaving that wrong "follow" fallback as the SOLE catcher: it resolves
# THROUGH link-to-wt.txt's referent (outside the primary) and wrongly
# ALLOWS replacing a primary checkout ENTRY. Fixed by moving the call to
# after $_bwimc_dest_mode is fully known and passing it as $2 (same shape
# as rows 56-58's fix, applied to the one arm they missed).
check_both "60 fromP: cd wt | cat; mv wt/z.txt link-to-wt.txt (mv DEST is a primary symlink ENTRY, cd diverges via a pipeline subshell) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; mv $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "61 fromP: (cd wt); mv wt/z.txt link-to-wt.txt (mv DEST entry, cd diverges via a subshell) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"(cd $FIX/wt); mv $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "62 fromP: cd primary || cd wt; mv wt/z.txt link-to-wt.txt (mv DEST entry, first cd succeeds so || never runs) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; mv $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "63 fromP: cd wt | cat; cp --remove-destination wt/z.txt link-to-wt.txt (cp --remove-destination DEST entry) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp --remove-destination $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "64 fromP: cd wt | cat; cp -f wt/z.txt link-to-wt.txt (cp -f DEST entry, BOTH mode) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp -f $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "65 fromP: cd wt | cat; mv -T wt/z.txt link-to-wt.txt (mv -T DEST entry) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; mv -T $FIX/wt/z.txt link-to-wt.txt\",\"cwd\":\"$FIX/primary\"}}"

# 66 (false-positive control): the SAME cd divergence, but the destination
# is an explicit absolute worktree path rather than the relative primary
# symlink name — resolution never depends on which cwd (tracked or real)
# is used, so this must still ALLOW post-fix. Proves the mode-threading fix
# does not turn into an over-deny.
check_both "66 control: cd wt | cat; mv wt/z.txt wt/dest-ctl.txt (explicit absolute wt destination) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; mv $FIX/wt/z.txt $FIX/wt/dest-ctl.txt\",\"cwd\":\"$FIX/primary\"}}"

# 59: the shc dispatch regex's middle group used to
# require every intervening token to itself start with "-" (a flag) — a
# flag that takes its own separate argument, e.g. `-o pipefail`, has a
# bare (non-dash) token in the middle ("pipefail"), which broke the match
# at the shell name and skipped the interp-body scan entirely, unlike the
# already-correct per-token walk inside _bwimc_is_shc_cflag (which finds
# -c/-ce/etc. anywhere in argv, flags-with-args included).
check_both "59 bash -o pipefail -c 'redirect into primary' (flag-with-arg before -c) denies (codex-2)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -o pipefail -c \\\"echo hi > $FIX/primary/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"
check_both "59b bash -o pipefail -c 'redirect into wt' (flag-with-arg before -c) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -o pipefail -c \\\"echo hi > $FIX/wt/a.txt\\\"\",\"cwd\":\"$FIX/wt\"}}"

echo "== HIMMEL-3648 CR round 16 (judge J1307A F1 — cp/mv/-t/ln destination type resolved against BOTH cwds, union) =="
# 67-77: the
# destination's TYPE (dir? existing entry?) was decided against the tracked
# cwd only. When a pipe, subshell or `||` makes the tracked cwd (wt) diverge
# from the real one (primary), a name that is a DIRECTORY in wt but a SYMLINK
# in primary picked child/allow from wt, while at runtime the write lands on
# the primary entry. Main denied every row; each must deny again.
# Fixture: <primary>/xlnk -> xother/src.txt (file symlink) while <wt>/xlnk is
# a real directory; <primary>/xlnkdir2 -> xother2 (dir symlink) whose child
# src.txt links back to <primary>/README.md, and wt has no xlnkdir2 at all.
mkdir -p "$FIX/xother" "$FIX/xother2" "$FIX/wt/xlnk"
printf 'src\n' > "$FIX/xother/src.txt"
printf 'src\n' > "$FIX/wt/src.txt"
ln -sf "$FIX/xother/src.txt" "$FIX/primary/xlnk"
ln -sf "$FIX/primary/README.md" "$FIX/xother2/src.txt"
ln -sfn "$FIX/xother2" "$FIX/primary/xlnkdir2"
check_both "67 fromP: cd wt | cat; mv wt/src.txt xlnk (dir in wt, symlink entry in primary) denies (x1)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; mv $FIX/wt/src.txt xlnk\",\"cwd\":\"$FIX/primary\"}}"
check_both "68 fromP: cd primary || cd wt; mv wt/src.txt xlnk denies (x1c)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; mv $FIX/wt/src.txt xlnk\",\"cwd\":\"$FIX/primary\"}}"
check_both "69 fromP: cd wt | cat; cp --remove-destination wt/src.txt xlnk denies (x2)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp --remove-destination $FIX/wt/src.txt xlnk\",\"cwd\":\"$FIX/primary\"}}"
check_both "70 fromP: cd wt | cat; cp -f wt/src.txt xlnk denies (x3)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp -f $FIX/wt/src.txt xlnk\",\"cwd\":\"$FIX/primary\"}}"
check_both "71 fromP: cd wt | cat; ln -sf wt/src.txt xlnk denies (x5)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; ln -sf $FIX/wt/src.txt xlnk\",\"cwd\":\"$FIX/primary\"}}"
check_both "72 fromP: cd wt | cat; cp wt/src.txt xlnkdir2 (child of a primary dir symlink) denies (x6)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp $FIX/wt/src.txt xlnkdir2\",\"cwd\":\"$FIX/primary\"}}"
check_both "73 fromP: (cd wt); cp wt/src.txt xlnkdir2 denies (x6b)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"(cd $FIX/wt); cp $FIX/wt/src.txt xlnkdir2\",\"cwd\":\"$FIX/primary\"}}"
check_both "74 fromP: cd primary || cd wt; cp wt/src.txt xlnkdir2 denies (x6c)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; cp $FIX/wt/src.txt xlnkdir2\",\"cwd\":\"$FIX/primary\"}}"
check_both "75 fromP: cd wt | cat; cp -t xlnkdir2 wt/src.txt denies (x8)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp -t xlnkdir2 $FIX/wt/src.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "76 fromP: (cd wt); cp -t xlnkdir2 wt/src.txt denies (x8b)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"(cd $FIX/wt); cp -t xlnkdir2 $FIX/wt/src.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "77 fromP: cd wt | cat; cp wt/src.txt xlnkdir2/ (trailing slash) denies (y8)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp $FIX/wt/src.txt xlnkdir2/\",\"cwd\":\"$FIX/primary\"}}"
# 78 (control): the same divergent cd with an explicit absolute wt directory
# destination still allows — the union only adds a second resolution, and an
# absolute operand resolves identically against either cwd.
check_both "78 control: cd wt | cat; cp wt/src.txt wt/xlnk (absolute wt dir) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; cp $FIX/wt/src.txt $FIX/wt/xlnk\",\"cwd\":\"$FIX/primary\"}}"

echo "== HIMMEL-3685 (a cd reached via | or || leaves the modelled cwd UNRESOLVED) =="

# 79-84: the WORKTREE-cwd half of 46. From a worktree payload cwd,
# `cd <primary> || cd <wt>` really ends in <primary> (the first cd succeeds, so
# the || arm never runs) but the tracker modelled the cwd as <wt> — equal to the
# payload cwd, so no divergence, so the relative write was checked against
# <wt> and ALLOWED. A cd/pushd reached across a | or || boundary now marks the
# cwd unresolved, which fails closed exactly like an unresolvable cd.
check_both "79 fromW: cd primary || cd wt; echo x > a.txt (first cd succeeds, || never runs) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "80 fromW: cd primary || cd wt; git commit -m wip (git-arm twin) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || cd $FIX/wt; git commit -m wip\",\"cwd\":\"$FIX/wt\"}}"
check_both "81 fromW: cd wt || cd primary; echo x > a.txt (the cd reached via || is the dangerous one) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || cd $FIX/primary; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 82 (control): the idiomatic guard — the cd is FIRST in its list, only `exit`
# follows the ||, so no cd is reached via a boundary and the cwd stays resolved.
check_both "82 control: cd wt || exit; echo x > a.txt (cwd=wt) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || exit; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 83/83b (decision, rd4): a cd left of a single `|` runs in a pipeline subshell,
# so the real cwd never moves while the model would move it. The sticky taint
# marks the cwd UNRESOLVED for both sides of a `|`; `cd <wt> | cat` from the
# wt cwd is therefore an accepted OVER-DENY (the write would have been safe).
check_both "83 fromW: cd wt | cat; echo x > a.txt denies (accepted over-deny: cd left of a pipe)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "83b fromW: echo | cd wt; echo x > a.txt denies (cd reached across a | boundary)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo | cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 84: the interp-body scan shares the splitter.
F84_CMD="bash -c 'cd $FIX/primary || cd $FIX/wt; echo x > a.txt'"
F84_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$F84_CMD" | jq -Rs .),\"cwd\":\"$FIX/wt\"}}"
check_both "84 fromW: bash -c 'cd primary || cd wt; echo x > a.txt' denies" block "$F84_JSON"
# 85 (codex-1): a { } group after the || — the flag must survive the group's own
# non-cd clauses, or `{ :` consumes it and the cd inside restores a false cwd.
check_both "85 fromW: cd primary || { :; cd wt; }; echo x > a.txt denies (flag survives the group)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || { :; cd $FIX/wt; }; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "85b fromW: cd primary || { echo a; echo b; cd wt; }; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || { echo a; echo b; cd $FIX/wt; }; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 85d: same for a ( ) subshell group.
check_both "85d fromW: cd primary || ( :; cd wt; ); echo x > a.txt denies (flag survives the subshell group)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || ( :; cd $FIX/wt; ); echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "85e fromW: cd primary || ( echo a; cd wt ); echo x > a.txt denies (no ; before the close paren)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || ( echo a; cd $FIX/wt ); echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "85f control: cd wt || ( echo no; exit 1 ); echo x > a.txt (cwd=wt) now denies (allowlist over-deny: parens)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || ( echo no; exit 1 ); echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 85g: if / for compound commands after the ||.
check_both "85g fromW: cd primary || if true; then :; cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || if true; then :; cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "85h fromW: cd primary || for i in 1; do :; cd wt; done; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || for i in 1; do :; cd $FIX/wt; done; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "85i control: cd wt || if true; then exit 1; fi; echo x > a.txt (cwd=wt) now denies (allowlist over-deny: reserved words)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || if true; then exit 1; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 85c: allowlist (AG rd8) distrusts any command containing braces, parens or reserved words, so this former control now fails closed.
check_both "85c control: cd wt || { echo no; exit 1; }; echo x > a.txt (cwd=wt) now denies (allowlist over-deny: braces)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || { echo no; exit 1; }; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 86 (codex-2 rd4): a pipeline-left cd runs in a subshell; after `cd primary` the
# real cwd is primary, but a tracker that models the left cd would say wt.
check_both "86 fromW: cd primary; cd wt | cat; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt | cat; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 87 (codex-1 rd4): case arms.
check_both "87 fromW: cd primary || case x in x) :; cd wt;; esac; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary || case x in x) :; cd $FIX/wt;; esac; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 88 (control): a plain && chain keeps the cwd resolved.
check_both "88 control: cd wt && echo x > a.txt (cwd=wt) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 89 (CR rd5): a leading `!` (repeatable) must not hide a compound opener from the taint.
check_both "89 fromW: cd primary; ! if false; then cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; ! if false; then cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "89b fromW: cd primary; ! ! if false; then cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; ! ! if false; then cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 90 (AG rd6, generic fail-closed): any reserved word in a cd's clause, or a cd that
# is not the first command word, leaves the cwd unresolved (no prefix enumeration).
check_both "90 fromW: cd primary; time if false; then cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; time if false; then cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "90b fromW: cd primary; coproc { cd wt; }; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; coproc { cd $FIX/wt; }; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "90c fromW: cd primary; time -p cd wt; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; time -p cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "90d control: cd wt || exit; echo x > a.txt (cwd=wt) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || exit; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "90e control: cd wt; echo x > a.txt (cwd=wt) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 91 (AG rd7): a prefixed opener (time/coproc/!/VAR=val, any order) sets the sticky
# taint like a bare one, so a LATER bare `cd wt` clause no longer restores the cwd.
check_both "91 fromW: cd primary; time if false; then :; cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; time if false; then :; cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "91b fromW: cd primary; coproc if false; then :; cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; coproc if false; then :; cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "91c fromW: cd primary; ! time -p if false; then :; cd wt; fi; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; ! time -p if false; then :; cd $FIX/wt; fi; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "91d fromW: cd primary; coproc N { :; }; cd wt; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; coproc N { :; }; cd $FIX/wt; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 92 (AG rd8, allowlist): a cd is trusted only in a command free of reserved words,
# braces, parens, a single `&` and a single `|`; anything else fails closed.
check_both "92 fromW: cd primary; cd wt & echo x > a.txt denies (backgrounded cd)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt & echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "92b fromW: cd primary; function f { :; cd wt; }; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; function f { :; cd $FIX/wt; }; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "92c fromW: cd wt || exit; echo x > a.txt still allows (control)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt || exit; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "92d fromW: cd wt; echo x 2>&1 > a.txt still allows (redirect & is not a background &)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt; echo x 2>&1 > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 93: a single `|` taints only the clause on its LEFT (a pipeline
# member runs its cd in a subshell) and everything after it; an earlier cd stays
# trusted, so `cd wt && git status | cat && write` is no longer a blanket deny.
check_both "93 fromW: cd wt && git status | cat && echo x > a.txt (cd precedes the pipe) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && git status | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93b fromW: cd wt | cat && echo x > a.txt (cd is the pipe's left member) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93c fromW: cd wt && ls | head && cd - && echo x > a (unresolved cd after a pipe) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && ls | head && cd - && echo x > a\",\"cwd\":\"$FIX/wt\"}}"
check_both "93d fromW: cd \$UNSET_VAR && git status | cat && echo x > a.txt (dynamic cd target) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd \\\"\$UNSET_VAR\\\" \\u0026\\u0026 git status | cat \\u0026\\u0026 echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93e fromW: cd primary && git status | cat && echo x > a.txt (cd into primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary \\u0026\\u0026 git status | cat \\u0026\\u0026 echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 93f-j: a redirect `&` on the pipe's left member is
# no boundary, so the whole member (`cd wt 2>&1`) is tainted, not just its tail.
check_both "93f fromW: cd wt 2>&1 | cat && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt 2>&1 | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93g fromW: cd wt &>/dev/null | cat && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt &>/dev/null | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93h fromW: cd wt >&2 | cat && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt >&2 | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93i fromW: cd wt 2>&- | cat && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt 2>&- | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93j fromW: cd wt; cd wt 2>&1 | cat && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt; cd $FIX/wt 2>&1 | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "93k fromW: cd wt && git status 2>&1 | cat && echo x > a.txt (cd precedes) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && git status 2>&1 | cat && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 94: a cd the shell would FAIL (missing dir, extra operands, zsh
# two-arg form, CDPATH) leaves the real cwd where it was, so the modelled cwd
# must not move to its target; a later relative write fails closed.
check_both "94 fromW: cd primary; cd wt/nonexist; echo x > a.txt (missing dir) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt/nonexist; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94b fromW: cd primary; cd wt extra; echo x > a.txt (extra operand) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt extra; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94c fromW: cd primary; cd wt primary && echo x > a.txt (zsh two-arg) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt $FIX/primary && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94d fromW: export CDPATH=primary; cd wt && echo x > a.txt (CDPATH) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"export CDPATH=$FIX/primary; cd wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94e fromW: cd primary; cd wt/nonexist | cat; echo x > a.txt (pipe form) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt/nonexist | cat; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94f fromW: cd primary; cd wt extra | cat; echo x > a.txt (pipe form) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt extra | cat; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94g fromW: CDPATH=primary; cd wt && echo x > a.txt (plain assign) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"CDPATH=$FIX/primary; cd wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94h fromW: cd wt (existing) && echo x > a.txt still allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94i fromW: cd wt 2>/dev/null && echo x > a.txt (redirect is no operand) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt 2>/dev/null && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94j fromW: cd wt/realsub (existing subdir) && echo x > a.txt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/realsub && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94k fromW: cd primary; cd wt 2>/nonexistent/err; echo x > a.txt (failing redirect) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt 2>/nonexistent/err; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94l fromW: cd primary; cd wt < /nonexistent; echo x > a.txt (failing input redirect) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt </nonexistent; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94m fromW: cd primary; cd wt 2>&9; echo x > a.txt (dup of a closed fd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt 2>&9; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "94n fromW: cd primary; cd wt 999999999999999999999>/dev/null; echo x > a.txt (out-of-range fd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary; cd $FIX/wt 999999999999999999999>/dev/null; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 95: four more cd forms the shell does NOT land where the hook
# models. Each deny row is paired with a REAL bash run (payload cwd = wt) that
# proves the write lands in the primary, so the deny is not a guess.
_real_lands() {  # _real_lands <label> <file-in-primary> <command>
    local label="$1" file="$2" cmd="$3" got
    printf 'orig\n' > "$file"
    ( cd "$FIX/wt" && timeout 20 bash -c "$cmd" ) >/dev/null 2>&1
    got=$(cat "$file" 2>/dev/null)
    if [ "$got" = x ]; then ok "$label (real bash writes into primary)"; else bad "$label — real bash did NOT write into primary (got: $got)"; fi
    printf 'orig\n' > "$file"
}
_deny_row() {  # _deny_row <label> <file-in-primary> <command>
    local json
    json=$(jq -cn --arg c "$3" --arg d "$FIX/wt" '{tool_name:"Bash",tool_input:{command:$c,cwd:$d}}')
    check_both "$1 denies" block "$json"
    _real_lands "$1" "$2" "$3"
}
mkdir -p "$FIX/primary/scripts" "$FIX/wt/scripts"

# 95a-b: cd +N / -N with a path suffix is no stack move; bash/zsh stay put.
_deny_row "95a cd +0/../../wt" "$FIX/primary/a.txt" "cd $FIX/primary; cd +0/../../wt; echo x > a.txt"
_deny_row "95b cd -1/../../wt" "$FIX/primary/a.txt" "cd $FIX/primary; cd -1/../../wt; echo x > a.txt"
# 95c-e: CDPATH set without an `=` (read, printf -v) or declared.
_deny_row "95c read CDPATH <<<" "$FIX/primary/scripts/a.txt" "read CDPATH <<< $FIX/primary; cd scripts && echo x > a.txt"
_deny_row "95d printf -v CDPATH" "$FIX/primary/scripts/a.txt" "printf -v CDPATH %s $FIX/primary; cd scripts && echo x > a.txt"
_deny_row "95e declare CDPATH" "$FIX/primary/scripts/a.txt" "declare -x CDPATH=$FIX/primary; cd scripts && echo x > a.txt"
# 95f: cd -P resolves physically, so a symlink component then .. lands in the link target's parent.
_deny_row "95f cd -P wt/dirlink/.." "$FIX/primary/a.txt" "cd -P $FIX/wt/dirlink/..; echo x > a.txt"
# 95g-i: the target is removed / made unsearchable / moved earlier in the same command.
mkdir -p "$FIX/wt/emptysub"
_deny_row "95g rmdir then cd" "$FIX/primary/a.txt" "cd $FIX/primary; rmdir $FIX/wt/emptysub; cd $FIX/wt/emptysub; echo x > a.txt"
mkdir -p "$FIX/wt/realsub2"
_deny_row "95h chmod 0 then cd" "$FIX/primary/a.txt" "cd $FIX/primary; chmod 0 $FIX/wt/realsub2; cd $FIX/wt/realsub2; echo x > a.txt"
chmod 755 "$FIX/wt/realsub2"
mkdir -p "$FIX/wt/realsub3"
_deny_row "95i mv then cd" "$FIX/primary/a.txt" "cd $FIX/primary; mv $FIX/wt/realsub3 $FIX/wt/r3; cd $FIX/wt/realsub3; echo x > a.txt"
rm -rf "$FIX/wt/r3"
# 95l: a dash-leading operand after `--` is still the mutated path.
mkdir -p "$FIX/wt/-victim"
_deny_row "95l rmdir -- -victim then cd" "$FIX/primary/a.txt" "cd $FIX/wt; rmdir -- -victim; cd $FIX/primary; cd $FIX/wt/-victim; echo x > a.txt"
# Controls that must stay allowed: a mutation of an UNRELATED path before the
# cd, and a physical cd with no symlink and no `..`.
check_both "95j cd wt/realsub after rm of an unrelated file allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -f $FIX/wt/unrelated; cd $FIX/wt/realsub && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "95k cd -P wt/realsub (no symlink, no ..) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd -P $FIX/wt/realsub && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"

# 96: a cd target that does not exist YET (a session scratchpad
# the harness creates after the hook runs, or `mkdir -p X && cd X`) lands on X
# or stays at the payload cwd; both are checked instead of failing closed.
check_both "96 fromW: cd wt/newscratch (not yet created) && echo x > a.txt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/newscratch && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "96b fromW: mkdir -p wt/newdir/logs && cd wt/newdir/logs && echo x > a.log allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mkdir -p $FIX/wt/newdir/logs && cd $FIX/wt/newdir/logs && echo x > a.log\",\"cwd\":\"$FIX/wt\"}}"
check_both "96c fromW: mkdir -p primary/newdir && cd primary/newdir && echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mkdir -p $FIX/primary/newdir && cd $FIX/primary/newdir && echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
check_both "96d fromP: cd wt/newscratch; echo x > a.txt (the cd fails, the write lands in the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/newscratch; echo x > a.txt\",\"cwd\":\"$FIX/primary\"}}"
# 96e: an earlier clause that is not mkdir/cd can make the missing target a
# symlink into the primary, so the cd keeps failing closed.
_deny_row "96e ln -s primary then cd the new link" "$FIX/primary/a.txt" "ln -s $FIX/primary $FIX/wt/plink; cd $FIX/wt/plink && echo x > a.txt"
rm -f "$FIX/wt/plink"
# 96f: an earlier cd may not have run (mkdir of an existing dir fails, so `&&`
# skips the cd back), so the real cwd is the primary, not the payload cwd.
check_both "96f fromW: cd primary && mkdir wt && cd wt; cd wt/newscratch; echo x > a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary && mkdir $FIX/wt && cd $FIX/wt; cd $FIX/wt/newscratch; echo x > a.txt\",\"cwd\":\"$FIX/wt\"}}"
# 96g/96h: a relative `env -C` operand after a cd that failed or never ran
# resolves against the primary, not the modelled cwd.
check_both "96g fromP: cd wt/missing; env -C scripts tee ../a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt/missing7130; env -C scripts tee ../a.txt </dev/null\",\"cwd\":\"$FIX/primary\"}}"
check_both "96h fromP: false && cd wt; env -C scripts tee ../a.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"false && cd $FIX/wt; env -C scripts tee ../a.txt </dev/null\",\"cwd\":\"$FIX/primary\"}}"

echo "== HIMMEL-8200 (a relative write after a plain cd into a scratch folder resolves against the cd target) =="

# 97: from a PRIMARY payload cwd, a cd that is the FIRST command of the line
# always runs (a failing one is caught by the exists check, or ends the && chain),
# so a plain relative write resolves in the cd target and nowhere else (a ~ or
# brace candidate is expanded by the shell, rows 99a-e). When that target lies in
# no git repo (a scratch folder), the union fallback of rows 43-54 must not
# re-check the write against the payload cwd.
mkdir -p "$FIX/scratch8200"
check_both "97 fromP: cd scratch && echo x > out.txt (cd target outside the primary) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "97b fromP: cd scratch; echo x > out.txt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
# 97c-d (control): the cd target itself is the primary, so the same write still denies.
check_both "97c fromP: cd primary && echo x > out.txt still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "97d fromW: cd primary && echo x > out.txt still denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/primary && echo x > out.txt\",\"cwd\":\"$FIX/wt\"}}"
# 97e-g (controls): a cd that is NOT the first command may not have run, a second
# cd re-opens the question, and an absolute write into the primary is untouched.
check_both "97e fromP: false && cd scratch; echo x > out.txt (cd may not run) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"false && cd $FIX/scratch8200; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "97f fromP: cd scratch && cd nope; echo x > out.txt (second cd fails) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && cd $FIX/scratch8200/nope; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "97g fromP: cd scratch && echo x > primary/out.txt (absolute primary target) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > $FIX/primary/out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 97h-i (controls): the cd target must lie in NO git repo once symlinks are
# resolved: a link inside scratch pointing at the primary, and a worktree
# target (row 55's shape, with a redirect), keep the payload-cwd re-check.
if ! { ln -sfn "$FIX/primary" "$FIX/scratch8200/lnk-to-primary" && [ -d "$FIX/scratch8200/lnk-to-primary" ]; }; then
    bad "97h setup: the lnk-to-primary symlink was not created"
fi
check_both "97h fromP: cd scratch/lnk-to-primary && echo x > out.txt (symlink into the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200/lnk-to-primary && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "97i fromP: cd wt && echo x > out.txt (worktree target) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/wt && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 98: the trust a sure cd earns lasts only while every later clause names a
# command from a closed set that cannot move the shell's cwd. A later clause that
# moves it in a way the tracker cannot see (brace expansion, eval, a variable
# holding `cd`, `.` reading stdin) must clear it, so the write is re-checked
# against the payload cwd and denies.
check_both "98a fromP: cd scratch; {cd,-}; echo x > out.txt (brace-expanded cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200; {cd,-}; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98b fromP: pushd scratch; eval ' popd'; echo x > out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pushd $FIX/scratch8200; eval ' popd'; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98c fromP: cd scratch; X=cd; \$X -; echo x > out.txt (variable cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200; X=cd; \$X -; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98d fromP: cd scratch; . /dev/stdin <<< 'cd -'; echo x > out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200; . /dev/stdin <<< 'cd -'; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
# 98e-j: the plain shapes around the first command of the line.
check_both "98e fromP: cd scratch | cat; echo x > out.txt (piped cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 | cat; echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98f fromP: cd scratch & echo x > out.txt (background cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 & echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98g fromP: cd scratch && (cd primary; echo x > out.txt) (subshell cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && (cd $FIX/primary; echo x > out.txt)\",\"cwd\":\"$FIX/primary\"}}"
check_both "98h fromP: cd scratch && pushd primary && echo x > out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && pushd $FIX/primary >/dev/null && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98i fromP: cd scratch && rm out.txt (rm is not in the closed set) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && rm out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98j fromP: cd scratch && touch out.txt allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "98k fromP: cd scratch && cd primary && echo x > out.txt (second cd) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && cd $FIX/primary && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 99: a candidate the shell expands at run time to a place the hook cannot see keeps
# the payload-cwd re-check even under a sure cd: `~-` and `~1` name the directory
# the cd (or pushd) just left, which here is the primary, and a brace list expands
# to several words. Unquoted ~ or a brace anywhere in the candidate triggers it, so
# a harmless brace write in the scratch folder is refused too (accepted over-deny).
check_both "99a fromP: cd scratch; echo x > ~-/out.txt (OLDPWD is the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200; echo x > ~-/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "99b fromP: cd scratch && touch ~-/out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch ~-/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "99c fromP: pushd scratch; echo x > ~1/out.txt (dir stack entry is the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pushd $FIX/scratch8200 >/dev/null; echo x > ~1/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "99d fromP: cd scratch && touch {~-/a,b} (brace holding ~-) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch {~-/a,b}\",\"cwd\":\"$FIX/primary\"}}"
check_both "99e fromP: cd scratch && touch {out,out2}.txt (any brace) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch {out,out2}.txt\",\"cwd\":\"$FIX/primary\"}}"
# 99f is a regression row for the symlink-resolved cd target: the typed cd path is a link
# to a scratch subfolder, so `..` climbs to $FIX lexically (no repo, allowed) but to
# scratch8200 physically, where lnk-to-primary leads into the primary. No shape was found
# where only the check against the canonical target decides: _bwimc_check_target resolves
# the symlinked target physically too.
mkdir -p "$FIX/scratch8200/a"
if ! { ln -sfn "$FIX/scratch8200/a" "$FIX/lnkscratch8200" && [ -d "$FIX/lnkscratch8200" ]; }; then
    bad "99f setup: the lnkscratch8200 symlink was not created"
fi
check_both "99f fromP: cd link-to-scratch && echo x > ../lnk-to-primary/out.txt (physical .. reaches the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/lnkscratch8200 && echo x > ../lnk-to-primary/out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 99g: a glob is expanded by the shell at run time, and the glob check reduces the operand to
# its directory prefix without resolving the matched entry, so `vic*` can name a symlink in the
# scratch folder that leads into the primary. A glob candidate keeps the payload-cwd re-check.
echo orig > "$FIX/primary/victim-target8200.txt"
if ! { ln -sfn "$FIX/primary/victim-target8200.txt" "$FIX/scratch8200/victim" && [ -L "$FIX/scratch8200/victim" ]; }; then
    bad "99g setup: the scratch8200/victim symlink was not created"
fi
check_both "99g fromP: cd scratch && touch vic* (glob matches a symlink into the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch vic*\",\"cwd\":\"$FIX/primary\"}}"
check_both "99h fromP: cd scratch && echo x > vic* denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > vic*\",\"cwd\":\"$FIX/primary\"}}"
check_both "99i fromP: cd scratch && echo x > vict?m (? glob) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > vict?m\",\"cwd\":\"$FIX/primary\"}}"
check_both "99j fromP: cd scratch && echo x > vic[t]im (bracket glob) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > vic[t]im\",\"cwd\":\"$FIX/primary\"}}"

# 100a: a `..` after a symlink component is resolved by the kernel at write time, so
# `lnk/../out.txt` lands in the parent of the link target (the primary), not in the scratch
# folder the typed path names. A candidate holding a `..` component keeps the payload-cwd re-check.
if ! { ln -sfn "$FIX/primary/scripts" "$FIX/scratch8200/lnk8200" && [ -d "$FIX/scratch8200/lnk8200" ]; }; then
    bad "100a setup: the scratch8200/lnk8200 symlink was not created"
fi
check_both "100a fromP: cd scratch && echo x > lnk/../out.txt (.. after a symlink into the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200/../out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "100b fromP: cd scratch && touch lnk/../out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch lnk8200/../out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "100c fromP: cd scratch && tee lnk/../out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && tee lnk8200/../out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 100d: a brace in the cd word is expanded by the shell, so `{1..1}` becomes `1`, a symlink into
# the primary, while the hook sees a literal directory of that name and finds it in no repo.
# A cd word holding `{` is never sure.
mkdir -p "$FIX/scratch8200/{1..1}"
if ! { ln -sfn "$FIX/primary" "$FIX/scratch8200/1" && [ -d "$FIX/scratch8200/1" ]; }; then
    bad "100d setup: the scratch8200/1 symlink was not created"
fi
check_both "100d fromP: cd scratch/{1..1} && echo x > out.txt (brace expands to a symlink into the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200/{1..1} && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "100e fromP: cd scratch/{1..1} && touch out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200/{1..1} && touch out.txt\",\"cwd\":\"$FIX/primary\"}}"

# 101a: the shell strips quotes before the kernel resolves the path, so a quoted `..` component
# (`lnk/".."/out.txt`, `lnk/'..'/out.txt`, `"lnk/.."/out.txt`) names the same parent as the bare
# spelling. The `..` test runs on the unquoted word; a quoted plain filename stays allowed.
check_both "101a fromP: cd scratch && echo x > lnk/\\\"..\\\"/out.txt (double-quoted ..) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200/\\\"..\\\"/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "101b fromP: cd scratch && echo x > lnk/'..'/out.txt (single-quoted ..) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200/'..'/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "101c fromP: cd scratch && echo x > \"lnk/..\"/out.txt (whole-word quoted) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \\\"lnk8200/..\\\"/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "101d fromP: cd scratch && touch lnk/\"..\"/out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch lnk8200/\\\"..\\\"/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "101e fromP: cd scratch && tee lnk/'..'/out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && tee lnk8200/'..'/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "101f fromP: cd scratch && echo x > \"out.txt\" (quoted plain filename) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \\\"out.txt\\\"\",\"cwd\":\"$FIX/primary\"}}"

# 102: after a sure cd the payload-cwd re-check is skipped ONLY for a candidate proven plain (a
# fixed allowlist of ordinary path characters, optionally in one whole-word quote pair, no `..`
# component). Any other word keeps main's re-check, so a mid-word quote or a backslash, which the
# shell strips but the later resolver does not, gets main's verdict by construction.
check_both "102a fromP: cd scratch && echo x > l\"n\"k/out.txt (mid-word double quote) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > l\\\"n\\\"k8200/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "102b fromP: cd scratch && echo x > l'n'k/out.txt (mid-word single quote) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > l'n'k8200/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "102c fromP: cd scratch && echo x > l\\nk/out.txt (backslash) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > l\\\\nk8200/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "102d fromP: cd scratch && echo x > vic\"t\"im (mid-word quote on the symlink itself) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > vic\\\"t\\\"im\",\"cwd\":\"$FIX/primary\"}}"
check_both "102e fromP: cd scratch && touch vic\"t\"im denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch vic\\\"t\\\"im\",\"cwd\":\"$FIX/primary\"}}"
check_both "102f fromP: cd scratch && tee vic\"t\"im denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && tee vic\\\"t\\\"im\",\"cwd\":\"$FIX/primary\"}}"
check_both "102g fromP: cd scratch && echo x > \"vic\"\"tim\" (two quote pairs in one word) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \\\"vic\\\"\\\"tim\\\"\",\"cwd\":\"$FIX/primary\"}}"
mkdir -p "$FIX/scratch8200/sub8200"
check_both "102h fromP: cd scratch && echo x > sub/out.txt (plain subfolder path) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > sub8200/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "102i fromP: cd scratch && echo x > ./my-file_1.txt (plain, dot slash) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > ./my-file_1.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "102j fromP: cd scratch && echo x > \"my file.txt\" (whole-word quoted, space) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \\\"my file.txt\\\"\",\"cwd\":\"$FIX/primary\"}}"
check_both "102k fromP: cd scratch && echo x > 'out.txt' (whole-word single-quoted) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > 'out.txt'\",\"cwd\":\"$FIX/primary\"}}"
check_both "102l fromP: cd scratch && touch \"sub/out.txt\" (quoted subfolder path) allows" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && touch \\\"sub8200/out.txt\\\"\",\"cwd\":\"$FIX/primary\"}}"

# 103: a command substitution in the operand is a stub that _bwimc_check_target reduces to its
# static prefix (`lnk$(true)/out.txt` becomes `./`) before it calls the guard. That derived word is
# plain, but it is not the word the shell sees, so it never takes the plain skip: it gets the
# payload-cwd re-check on its prefix, as on main.
mkdir -p "$FIX/scratch8200/sub8200"
if ! { ln -sfn "$FIX/primary/scripts" "$FIX/scratch8200/sub8200/lnk8200" && [ -d "$FIX/scratch8200/sub8200/lnk8200" ]; }; then
    bad "103 setup: the scratch8200/sub8200/lnk8200 symlink was not created"
fi
check_both "103a fromP: cd scratch && echo x > lnk\$(true)/out.txt (substitution after a symlink name) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200\$(true)/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "103b fromP: cd scratch && echo x > vic\$(true)tim denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > vic\$(true)tim\",\"cwd\":\"$FIX/primary\"}}"
check_both "103c fromP: cd scratch && tee lnk\$(true)/out.txt denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && tee lnk8200\$(true)/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "103d fromP: cd scratch && echo x > lnk\`true\`/out.txt (backtick form) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200\`true\`/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "103e fromP: cd scratch && echo x > \"lnk\$(true)/out.txt\" (quoted) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \\\"lnk8200\$(true)/out.txt\\\"\",\"cwd\":\"$FIX/primary\"}}"
check_both "103f fromP: cd scratch && echo x > sub/lnk\$(true)/x (symlink below a subfolder) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > sub8200/lnk8200\$(true)/x\",\"cwd\":\"$FIX/primary\"}}"
check_both "103g fromP: cd scratch && echo x > lnk/out.txt (plain symlink name into the primary) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "103h fromP: cd scratch && echo x > f\$(date) denies, as on main (accepted over-deny)" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > f\$(date)\",\"cwd\":\"$FIX/primary\"}}"
check_both "104a fromP: cd scratch && echo x > lnk\$((8))/out.txt (arithmetic flattened to a plain word) denies" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > lnk8200\$((8))/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "104b fromP: cd scratch && echo x > \$(pwd)/out.txt (pwd stub) denies, as on main" block \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > \$(pwd)/out.txt\",\"cwd\":\"$FIX/primary\"}}"
check_both "104c fromP: cd scratch && echo x > out.txt still allows (no dynamic text)" allow \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIX/scratch8200 && echo x > out.txt\",\"cwd\":\"$FIX/primary\"}}"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
