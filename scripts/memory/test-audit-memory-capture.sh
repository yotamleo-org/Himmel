#!/usr/bin/env bash
# Tests for scripts/memory/audit-memory-capture.sh.
#
# Timestamps are generated at runtime — a hardcoded 2026-07-16/17 record falls
# outside the trailing window within a week and the tripwire/window cases then
# fail forever. MEMORY_AUDIT_SKIP_QMD=1 in run() keeps these cases hermetic
# (otherwise check 5 would query the real qmd index and go machine-dependent).
set -uo pipefail

AUDIT="$(cd "$(dirname "$0")" && pwd)/audit-memory-capture.sh"
[ -x "$AUDIT" ] || chmod +x "$AUDIT"

FAILED=0; SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"
MEM="$SB/memory"; mkdir -p "$MEM"; VAULT="$SB/vault"; mkdir -p "$VAULT"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

assert_rc() { if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 (want $2, got $3)"; FAILED=1; fi; }
# LUNA_VAULT_PATH -> the sandbox vault (substrate for the orphaned-deny grep).
# MEMORY_AUDIT_SKIP_QMD=1 -> skip the best-effort qmd collection check (hermetic).
# MEMORY_AUDIT_WINDOW_DAYS=7 is PINNED so the out-of-window case stays hermetic
# regardless of a caller's env (an inherited value would move the window).
run() { MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMDIR="$MEM" LUNA_VAULT_PATH="$VAULT" MEMORY_AUDIT_SKIP_QMD=1 MEMORY_AUDIT_WINDOW_DAYS=7 bash "$AUDIT" >/dev/null 2>&1; }

printf -- '- ok -> luna [[n]]\n' > "$MEM/MEMORY.md"

# 1: a deny whose fact never landed in the substrate = ORPHANED = finding.
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"abc123",excerpt:"rtk masks gitleaks blocks"}' > "$SB/capture.jsonl"
run; assert_rc "orphaned deny flagged" 1 "$?"

# 2: same deny, fact now present in the substrate = clean.
printf 'rtk masks gitleaks blocks — always confirm a sha.\n' > "$VAULT/himmel-harness-gotchas.md"
run; assert_rc "landed deny clean" 0 "$?"

# 3 (Rev2 INVERT): a topic file NOT referenced by any MEMORY.md routing line =
# ORPHAN = finding. (The base asserted the OLD '>2 topic files' drift check; the
# design now EXPECTS topic files, so accumulation alone is never a finding.)
: > "$SB/capture.jsonl"   # isolate: no denies so check 1 is trivially clean
printf -- '- [Routed fact](fact-1.md) — hook\n' > "$MEM/MEMORY.md"
printf 'body\n' > "$MEM/fact-1.md"   # routed -> not an orphan
printf 'body\n' > "$MEM/fact-2.md"   # orphan
printf 'body\n' > "$MEM/fact-3.md"   # orphan
run; assert_rc "orphan topic file flagged" 1 "$?"
rm -f "$MEM"/fact-*.md
printf -- '- ok -> luna [[n]]\n' > "$MEM/MEMORY.md"   # reset for the remaining cases

# 4: weekly pointer-line growth >1 = tripwire finding (runtime ts, always in-window).
{ jq -nc --arg ts "$NOW" '{ts:$ts,event:"write",lines_delta:3}'
  jq -nc --arg ts "$NOW" '{ts:$ts,event:"write",lines_delta:4}'; } > "$SB/capture.jsonl"
run; assert_rc "line-growth tripwire flagged" 1 "$?"

# 5: an excerpt containing regex metachars must match literally, not as a pattern.
printf 'the pruned-worktree ../../ trap — capture the patch first.\n' > "$VAULT/t.md"
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"d1",excerpt:"pruned-worktree ../../ trap"}' > "$SB/capture.jsonl"
run; assert_rc "regex-metachar excerpt matched literally" 0 "$?"

# 6 (P2-13): denies exist but substrate genuinely unresolvable -> WARN, NOT a
# silent 'clean'. Unset every substrate source so resolve_substrate returns "".
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"x",excerpt:"unresolvable substrate fact"}' > "$SB/capture.jsonl"
HOME="" USERPROFILE="" LUNA_VAULT_PATH="" MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMDIR="$MEM" MEMORY_AUDIT_SKIP_QMD=1 \
    bash "$AUDIT" >/dev/null 2>&1
assert_rc "substrate-unresolvable WARN flagged" 1 "$?"

# 7 (P2-14): an out-of-window deny does NOT ring once aged past the trailing
# window, even though the fact is genuinely absent. (jq gmtime/strftime instead
# of `date -d`, which is Git-Bash-unreliable.)
old_ts="$(jq -r '(now - 30*24*3600)|gmtime|strftime("%Y-%m-%dT%H:%M:%SZ")')"
jq -nc --arg ts "$old_ts" '{ts:$ts,event:"deny",hash:"o",excerpt:"ancient un-landed fact"}' > "$SB/capture.jsonl"
run; assert_rc "out-of-window deny aged out (clean)" 0 "$?"

# 8: MEMORY.md deleted while a topic file remains = nothing routes
# anything = every topic is an orphan. The check must NOT skip (false-clean) when
# the index is absent.
: > "$SB/capture.jsonl"
rm -f "$MEM/MEMORY.md"
printf 'body\n' > "$MEM/orphan-when-no-index.md"
run; assert_rc "missing index + topic file = orphan flagged" 1 "$?"

# 9: outside any git repo and MEMDIR unset, the
# script must fail loudly instead of deriving a "." slug and silently auditing
# $HOME/.claude/projects/./memory. $SB (mktemp -d) is itself outside any git
# work tree, so cd there + no MEMDIR reproduces the bug's precondition exactly.
noncmd_err="$SB/noncmd.err"
( cd "$SB" && env -u MEMDIR MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" >/dev/null 2>"$noncmd_err" )
noncmd_rc=$?
assert_rc "non-repo cwd fails loudly (no MEMDIR)" 1 "$noncmd_rc"
if grep -q 'not inside a git repo' "$noncmd_err"; then
    echo "PASS non-repo cwd diagnostic present"
else
    echo "FAIL non-repo cwd diagnostic present (stderr: $(cat "$noncmd_err"))"
    FAILED=1
fi

# 10: git < 2.31 lacks --path-format, so `git rev-parse
# --path-format=absolute --git-common-dir` returns nothing there; the script
# must fall back to plain `--git-common-dir` and still derive MEMDIR. A stub
# `git` on PATH that rejects --path-format (delegating everything else to the
# real git) simulates that shape cheaply, without needing an actual old git
# binary. Real git's plain form returns a RELATIVE ".git" from a repo's
# toplevel (verified empirically) — exactly the case the normalization step
# exists for; without it MEMDIR would derive from an unresolved relative path.
fb_repo="$SB/fb-repo"; git init -q "$fb_repo"
fb_bin="$SB/fb-bin"; mkdir -p "$fb_bin"
real_git="$(command -v git)"
cat > "$fb_bin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *" --path-format=absolute "*) exit 1 ;;
esac
exec "$real_git" "\$@"
STUBEOF
chmod +x "$fb_bin/git"
fb_err="$SB/fb.err"
# A missing memory dir exits 2 now, so the derived store must exist.
mkdir -p "$SB/.claude/projects/$(cd "$fb_repo" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')/memory"
( cd "$fb_repo" && PATH="$fb_bin:$PATH" env -u MEMDIR MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" >/dev/null 2>"$fb_err" )
fb_rc=$?
if grep -q 'not inside a git repo' "$fb_err"; then
    echo "FAIL git<2.31 fallback derives MEMDIR (stderr: $(cat "$fb_err"))"
    FAILED=1
else
    assert_rc "git<2.31 fallback derives MEMDIR (clean run)" 0 "$fb_rc"
fi

# ---- --structure, --lost-lines, shared slug, pinned defaults ----
HERE="$(cd "$(dirname "$0")" && pwd)"
NOTICE="$HERE/../hooks/memory-index-state-notice.sh"
GUARD="$HERE/../hooks/guard-memory-capture.sh"
LIB="$HERE/../lib/memory-slug.sh"

assert_has() { if printf '%s\n' "$3" | grep -qF -- "$2"; then echo "PASS $1"; else echo "FAIL $1 (missing: $2)"; FAILED=1; fi; }
assert_lacks() { if printf '%s\n' "$3" | grep -qF -- "$2"; then echo "FAIL $1 (unexpected: $2)"; FAILED=1; else echo "PASS $1"; fi; }
# st <memdir> [audit args...] -> ST_OUT (stdout+stderr), ST_RC. ST_VAULT overrides the vault ("" = unresolvable).
st() {
    local d="$1"; shift
    ST_OUT="$(MEMORY_CAPTURE_LOG="$SB/none.jsonl" MEMDIR="$d" LUNA_VAULT_PATH="${ST_VAULT-$VAULT}" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" "$@" 2>&1)"; ST_RC=$?
}
ms() { rm -rf "$SB/s-$1"; mkdir -p "$SB/s-$1"; printf '%s' "$SB/s-$1"; }
fill() { head -c "$1" /dev/zero | tr '\0' a; }

# A0: a clean fixture is GREEN under --structure.
D="$(ms a0)"; printf -- '- [a](a.md) — h\n' > "$D/MEMORY.md"; printf 'body\n' > "$D/a.md"
st "$D" --structure; assert_rc "A0 clean fixture exits 0" 0 "$ST_RC"

# A1: 8193-byte topic file flagged, 8192-byte one not.
D="$(ms a1)"; printf -- '- [big](big.md) — h\n- [edge](edge.md) — h\n' > "$D/MEMORY.md"
fill 8193 > "$D/big.md"; fill 8192 > "$D/edge.md"
st "$D" --structure
assert_rc "A1 over-cap exits 1" 1 "$ST_RC"
assert_has "A1 8193B flagged" "TOPIC CAP: big.md" "$ST_OUT"
assert_lacks "A1 8192B not flagged" "TOPIC CAP: edge.md" "$ST_OUT"

# A2: reachable through a hub (md link) or a [[wikilink]]; a file no link reaches is flagged.
D="$(ms a2)"
printf -- '- [hub](hub.md) — h\n- [[wl]]\n' > "$D/MEMORY.md"
printf 'see [sub](sub.md)\n' > "$D/hub.md"; printf 'body\n' > "$D/sub.md"; printf 'body\n' > "$D/wl.md"; printf 'body\n' > "$D/lone.md"
st "$D" --structure
assert_has "A2 unreachable file flagged" "UNREACHABLE: lone.md" "$ST_OUT"
assert_lacks "A2 hub sub-file not flagged" "UNREACHABLE: sub.md" "$ST_OUT"
assert_lacks "A2 wikilink-reached file not flagged" "UNREACHABLE: wl.md" "$ST_OUT"
assert_lacks "A2 hub itself not flagged" "UNREACHABLE: hub.md" "$ST_OUT"

# A3: dead links; code spans and fences ignored; vault notes resolve a [[wikilink]].
D="$(ms a3)"
# shellcheck disable=SC2016  # backticks are literal fixture text
{ printf -- '- [hub](hub.md) — h\n'
  printf -- '- inline `[x](ticked.md)` and `[[ticked-wiki]]` ignored\n'
  printf -- '- [dead](gone.md) — h\n'
  printf -- '- [[nowhere]] [[vaultnote]] [[hub#sec|alias]]\n'
  printf '```\n[f](fenced-gone.md) [[fenced-nowhere]]\n```\n'; } > "$D/MEMORY.md"
printf 'body\n' > "$D/hub.md"; printf 'v\n' > "$VAULT/vaultnote.md"
st "$D" --structure
assert_rc "A3 dead links exit 1" 1 "$ST_RC"
assert_has "A3 dead markdown link flagged" "DEAD LINK: MEMORY.md -> gone.md" "$ST_OUT"
assert_has "A3 dead wikilink flagged" "DEAD WIKILINK: MEMORY.md [[nowhere]]" "$ST_OUT"
assert_lacks "A3 vault note resolves a wikilink" "[[vaultnote]]" "$ST_OUT"
assert_lacks "A3 heading/alias wikilink to a store file resolves" "[[hub" "$ST_OUT"
assert_lacks "A3 backticked link ignored" "ticked" "$ST_OUT"
assert_lacks "A3 fenced link ignored" "fenced" "$ST_OUT"
ST_VAULT="" st "$D" --structure
assert_rc "A3 --structure with no resolvable vault exits 2" 2 "$ST_RC"
ST_VAULT="" st "$D"
assert_has "A3 plain audit WARNs without a vault" "WARN" "$ST_OUT"
assert_rc "A3 plain audit WARN is not a finding" 0 "$ST_RC"

# A4: an old modified WARNs (exit code unchanged); a missing one prints "unknown".
D="$(ms a4)"; printf -- '- [old](old.md) — h\n- [new](new.md) — h\n- [none](none.md) — h\n' > "$D/MEMORY.md"
printf -- '---\nname: old\nmetadata:\n  type: user\n  modified: 2020-01-01\n---\nbody\n' > "$D/old.md"
printf -- '---\nname: new\nmetadata:\n  type: user\n  modified: %s\n---\nbody\n' "$(date -u +%Y-%m-%d)" > "$D/new.md"
printf 'body\n' > "$D/none.md"
st "$D" --structure
assert_rc "A4 stale/unknown never change the exit code" 0 "$ST_RC"
assert_has "A4 old modified WARNs" "STALE: old.md" "$ST_OUT"
assert_lacks "A4 fresh modified silent" "STALE: new.md" "$ST_OUT"
assert_has "A4 missing modified prints unknown" "unknown" "$ST_OUT"

# A5: invalid UTF-8 is sized and scanned.
D="$(ms a5)"; printf -- '- [inv](inv.md) — h\n' > "$D/MEMORY.md"
{ printf '\377\376 [d](dead-inv.md)\n'; fill 9000; } > "$D/inv.md"
st "$D" --structure
assert_has "A5 invalid UTF-8 file sized" "TOPIC CAP: inv.md" "$ST_OUT"
assert_has "A5 invalid UTF-8 file scanned" "DEAD LINK: inv.md -> dead-inv.md" "$ST_OUT"

# A6: 61 pointer lines and 201 lines are flagged; 60 and 200 are not.
D="$(ms a6a)"; i=0; while [ "$i" -lt 61 ]; do printf -- '- directive %s\n' "$i"; i=$((i+1)); done > "$D/MEMORY.md"
st "$D" --structure; assert_has "A6 61 pointer lines flagged" "LOAD LIMIT" "$ST_OUT"
D="$(ms a6b)"; i=0; while [ "$i" -lt 60 ]; do printf -- '- directive %s\n' "$i"; i=$((i+1)); done > "$D/MEMORY.md"
st "$D" --structure; assert_rc "A6 60 pointer lines pass" 0 "$ST_RC"
D="$(ms a6c)"; i=0; while [ "$i" -lt 201 ]; do printf 'line %s\n' "$i"; i=$((i+1)); done > "$D/MEMORY.md"
st "$D" --structure; assert_has "A6 201 lines flagged" "LOAD LIMIT" "$ST_OUT"
D="$(ms a6d)"; i=0; while [ "$i" -lt 200 ]; do printf 'line %s\n' "$i"; i=$((i+1)); done > "$D/MEMORY.md"
st "$D" --structure; assert_rc "A6 200 lines pass" 0 "$ST_RC"

# A7: length counts characters: 200 em dashes (over 200 bytes) pass, 201 are flagged.
em=""; i=0; while [ "$i" -lt 198 ]; do em="$em—"; i=$((i+1)); done
D="$(ms a7a)"; printf -- '- %s\n' "$em" > "$D/MEMORY.md"
st "$D" --structure; assert_rc "A7 200-char em-dash line passes" 0 "$ST_RC"
D="$(ms a7b)"; printf -- '- %s—\n' "$em" > "$D/MEMORY.md"
st "$D" --structure; assert_has "A7 201-char line flagged" "LINE DISCIPLINE" "$ST_OUT"

# A8: a missing memory dir exits 2, never clean.
st "$SB/no-such-store" --structure; assert_rc "A8 --structure on a missing dir exits 2" 2 "$ST_RC"
st "$SB/no-such-store"; assert_rc "A8 plain audit on a missing dir exits 2" 2 "$ST_RC"

# A9: a path holding . and _ gives ONE slug in the notice, the audit and the lib.
R="$SB/a.b_c/repo"; mkdir -p "$R"; git init -q "$R"; R="$(cd "$R" && pwd -P)"
exp="$SB/.claude/projects/$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')/memory"; mkdir -p "$exp"
i=0; while [ "$i" -lt 61 ]; do printf -- '- directive %s\n' "$i"; i=$((i+1)); done > "$exp/MEMORY.md"
n_out="$(cd "$R" && env -u MEMDIR -u CLAUDE_CONFIG_DIR -u CLAUDE_PROJECT_DIR bash "$NOTICE" </dev/null 2>&1)"
a_out="$(cd "$R" && env -u MEMDIR -u CLAUDE_CONFIG_DIR MEMORY_AUDIT_SKIP_QMD=1 LUNA_VAULT_PATH="$VAULT" bash "$AUDIT" --structure 2>&1)"
assert_has "A9 notice slug" "file: $exp/MEMORY.md" "$n_out"
assert_has "A9 audit slug" "store: $exp" "$a_out"
lib_slug="$(bash -c '. "$1" && memory_slug "$2"' _ "$LIB" "$R" 2>/dev/null)"
assert_rc "A9 lib slug equals the notice slug" 0 "$([ "$lib_slug" = "$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')" ] && echo 0 || echo 1)"

# A10: the notice, guard and audit share one default per knob.
pin() { grep -oE '\$\{'"$2"':-[0-9]+\}' "$1" | head -1 | sed -E 's/.*:-([0-9]+)\}/\1/'; }
for kv in MEMORY_LINE_CEIL=60 MEMORY_TOPIC_MAX=8192 MEMORY_LINE_MAX=200 MEMORY_BUDGET_BYTES=24400; do
    k="${kv%=*}"; want="${kv#*=}"
    for f in "$GUARD" "$NOTICE" "$AUDIT"; do
        got="$(pin "$f" "$k")"
        case "$f" in
            "$GUARD") [ -z "$got" ] && continue ;;
        esac
        assert_rc "A10 pin $k default $want in $(basename "$f")" 0 "$([ "$got" = "$want" ] && echo 0 || echo 1)"
    done
done

# Lost-lines: whole-line, count-aware multiset against every current file.
ll() { LL_OUT="$(MEMDIR="$1" LUNA_VAULT_PATH="$VAULT" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" --lost-lines "$2" 2>/dev/null)"; LL_RC=$?; }
SN="$SB/ll-snap"; LV="$SB/ll-live"
mk() { rm -rf "$SN" "$LV"; mkdir -p "$SN" "$LV"; }
mk
printf -- '---\nname: a\n---\nkeep\n\ndrop me\n' > "$SN/a.md"; printf -- '---\nname: other\n---\nkeep\n' > "$LV/a.md"
ll "$LV" "$SN"
assert_rc "L1 a dropped line exits 1" 1 "$LL_RC"
assert_rc "L1 prints exactly the dropped line" 0 "$([ "$LL_OUT" = "drop me" ] && echo 0 || echo 1)"
mk; printf 'dup\n' > "$SN/f1.md"; printf 'dup\n' > "$SN/f2.md"; printf 'dup\n' > "$LV/f1.md"
ll "$LV" "$SN"
assert_rc "L2 one dropped copy prints once" 0 "$([ "$LL_OUT" = "dup" ] && echo 0 || echo 1)"
mk; printf 'moved line\n' > "$SN/a.md"; printf 'moved line\n' > "$LV/b.md"
ll "$LV" "$SN"
assert_rc "L3 a moved line exits 0" 0 "$LL_RC"
assert_rc "L3 a moved line prints nothing" 0 "$([ -z "$LL_OUT" ] && echo 0 || echo 1)"
mk; printf 'the old whole line\n' > "$SN/a.md"; printf 'the old whole line edited\n' > "$LV/a.md"
ll "$LV" "$SN"
assert_rc "L4 a partial edit prints the whole old line" 0 "$([ "$LL_OUT" = "the old whole line" ] && echo 0 || echo 1)"
ll "$LV" "$SB/no-such-snap"; assert_rc "L5 missing snapshot dir exits 2" 2 "$LL_RC"

exit "$FAILED"
