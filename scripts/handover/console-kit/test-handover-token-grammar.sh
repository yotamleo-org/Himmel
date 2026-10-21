#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C pass/fail as in test-append-results.sh; backticks are literal bucket text
# test-handover-token-grammar.sh — every site that mints a token written into
# the handover bucket emits a token of the ONE grammar
# (docs/internals/handover-token-grammar.md), and the vault template's
# .gitleaks.toml passes a bucket file quoting it. Real secret shapes in a
# bucket file still fail. A new token shape fails here, not in the vault.
#   1. queue-lock.sh acquire (real hostname, plus stubbed odd hostnames)
#   2. gen-briefs.py leg nonces (derived letters and --letter)
#   3. gen-judge-brief.py judge nonces (qids the validator accepts)
#   4. git shas and sha256 digests (base/head shas, GO mac= lines)
#   5. RED rows: AWS key, GitHub PAT, generic api key, grammar-prefixed secrets
#   6. one grammar: the toml rule, vault-stall CLOSED_SHAPES and the doc agree
# Needs gitleaks; CI shards put the pinned binary on PATH. Run:
#   bash scripts/handover/console-kit/test-handover-token-grammar.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/templates/luna-second-brain/.gitleaks.toml"
DOC="$ROOT/docs/internals/handover-token-grammar.md"
STALL="$ROOT/scripts/luna/vault-stall-cadence.sh"
command -v gitleaks >/dev/null 2>&1 || { echo "SKIP: gitleaks not installed"; exit 0; }

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/token-grammar-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# The grammar is the line after the `handover-token grammar` marker comment.
GRAMMAR="$(awk '/# handover-token grammar/ { getline; print; exit }' "$CONFIG" \
    | sed -e "s/^[[:space:]]*'''//" -e "s/''',[[:space:]]*\$//")"
[ -n "$GRAMMAR" ] && pass "the template carries the handover-token grammar rule" \
    || fail "no handover-token grammar rule in $CONFIG"

fullmatch() { python3 -I -c 'import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$GRAMMAR" "$1"; }

# scan <file> -> gitleaks rc (0 clean, 42 finding)
scan() { gitleaks dir "$1" --config "$CONFIG" --no-banner --redact --exit-code 42 >/dev/null 2>&1; }

# allowed <site> <token>: the token is in the grammar and a bucket file
# quoting it the ways legs and consoles write it scans clean.
allowed() {
    local f="$WORK/bucket.md"
    if [ -n "$GRAMMAR" ] && fullmatch "$2"; then pass "$1: $2 is in the grammar"
    else fail "$1: $2 is outside the grammar"; fi
    printf -- '- 17:35 LIVE — release-token: `%s`\nRETASK token is `%s`\ntoken=%s.\nnonce: %s\n' "$2" "$2" "$2" "$2" > "$f"
    scan "$f"; local rc=$?
    [ "$rc" -eq 0 ] && pass "$1: a bucket file quoting $2 scans clean" || fail "$1: gitleaks rc=$rc on a bucket file quoting $2"
}

# caught <name> <line>: a bucket file holding the line still fails.
caught() {
    printf '%s\n' "$2" > "$WORK/secret.md"
    scan "$WORK/secret.md"; local rc=$?
    [ "$rc" -eq 42 ] && pass "RED $1 is still caught" || fail "RED $1: gitleaks rc=$rc, expected 42"
}

# --- 1. queue-lock.sh release tokens ---------------------------------------
mint_lock() {
    local h="$WORK/h$1"; mkdir -p "$h/u"; printf '# d\n' > "$h/u/doc.md"
    local out; out="$(HANDOVER_DIR="$h" XDG_RUNTIME_DIR="$WORK/run" PATH="$2" \
        bash "$ROOT/scripts/handover/queue-lock.sh" acquire "$h/u/doc.md" 2>/dev/null)"
    printf '%s\n' "$out" | sed -n 's/^release-token: `\(.*\)`$/\1/p'
}
mkdir -p "$WORK/run" && chmod 700 "$WORK/run"
tok="$(mint_lock real "$PATH")"
[ -n "$tok" ] && allowed "queue-lock (this host: $(hostname 2>/dev/null))" "$tok" || fail "queue-lock minted no token"
n=0
for host in fv-az123-456 DESKTOP-7F3K2LQ Ubuntu_VM.local runner--x; do
    n=$((n + 1)); mkdir -p "$WORK/bin$n"
    printf '#!/bin/sh\necho %s\n' "$host" > "$WORK/bin$n/hostname"; chmod +x "$WORK/bin$n/hostname"
    tok="$(mint_lock "$n" "$WORK/bin$n:$PATH")"
    [ -n "$tok" ] && allowed "queue-lock (hostname $host)" "$tok" || fail "queue-lock minted no token for hostname $host"
done

# --- 2. gen-briefs.py leg nonces --------------------------------------------
printf '#!/usr/bin/env bash\necho "created worktree $1"\n' > "$WORK/wt.sh"; chmod +x "$WORK/wt.sh"
printf '%s\n' '[{"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"}]' > "$WORK/legs.json"
n=0
for letter in "" ABC; do
    n=$((n + 1)); mkdir -p "$WORK/repo$n"
    out="$(GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$HERE/gen-briefs.py" "$WORK/legs.json" \
        --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --console HIMMEL-nextleg-2026-10-08BZ-roadmap-console \
        --bucket "$WORK/briefs$n" --date 2026-10-08 --repo "$WORK/repo$n" --handover-root "$WORK/handovers" \
        --work-dir "$WORK/w$n" --deadline 1791475000 ${letter:+--letter "$letter"} 2>/dev/null)"
    tok="$(printf '%s\n' "$out" | awk '$1 == "N901" && $2 != "worktree:" { print $2 }')"
    [ -n "$tok" ] && allowed "gen-briefs (letter ${letter:-derived})" "$tok" || fail "gen-briefs minted no nonce (letter ${letter:-derived})"
done

# --- 3. gen-judge-brief.py judge nonces -------------------------------------
n=0
for qid_letter in j2599a: HIMMEL-4999: J12_tune: jX3206m: J12A: legN9b: j2599a:ABC; do
    n=$((n + 1)); qid="${qid_letter%%:*}"; letter="${qid_letter#*:}"
    printf '{"qid": "%s", "ticket": "HIMMEL-3746", "pr": 2599, "head": "0123456789abcdef0123456789abcdef01234567", "question": "Is it?", "reason": "a dispute", "prior": "HIMMEL-3254. Source: qmd.", "tier": {"category": "design", "reason": "a design call"}}\n' "$qid" > "$WORK/spec$n.json"
    out="$(python3 "$HERE/gen-judge-brief.py" "$WORK/spec$n.json" --console HIMMEL-nextleg-2026-10-13Z-roadmap-console \
        --bucket "$WORK/judge$n" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" \
        ${letter:+--letter "$letter"} 2>/dev/null)"
    tok="$(printf '%s\n' "$out" | awk -v q="$qid" '$1 == q { print $2 }')"
    [ -n "$tok" ] && allowed "gen-judge-brief (qid $qid, letter ${letter:-derived})" "$tok" || fail "gen-judge-brief minted no nonce for qid $qid"
done

# --- 4. shas and digests ------------------------------------------------------
allowed "git commit sha" "$(git -C "$ROOT" rev-parse HEAD)"
allowed "sha256 digest (GO mac= line)" "$(printf 'go' | sha256sum | cut -d' ' -f1)"
allowed "legacy 6-hex RETASK nonce" "Y-N204-a68d71"
allowed "fresh-leg recovery nonce" "V-N236b-1d281f74"
# Copied from the live handover corpus (yotamleo/himmel/resume-himmelctl-A-close-5.md):
# a one-segment station hostname, which the old two-segment lock-token rule missed.
allowed "release token from the yotamasus station" "yotamasus-pid11439"

# --- 5. RED: real secret shapes in a bucket file still fail ------------------
# Each value is assembled at run time so the repo's own gitleaks scan of this
# file sees no secret.
aws="AKIA""Z4X7Q2M3KDLPW3NB"
pat="ghp_""8fK2mQ9xLr4TzW7vNb3Hc6Jd1Ys5Pg0AeU2i"
gen="Zx8qL2vN7pR4tY6wK9""mB3cF5hJ1sD0gQ"
short="qK7xL2mP""9vR4tW"
caught "AWS access key" "aws_access_key_id = $aws"
caught "GitHub PAT" "export GITHUB_TOKEN=$pat"
caught "generic api key" "api_key = \"$gen\""
caught "nonce-prefixed secret" "token=S-N2802-7023775e$gen"
caught "lock-token-prefixed secret" "token=cachyos-x8664-pid2124755$gen"
# A fixed value, not HEAD: whether an upper-cased sha trips the entropy rule depends on the sha.
low_entropy_sha="D0DA1B9A3E6A26FE42830EE3AFF8033321830E3F"
printf 'secret = %s\n' "$low_entropy_sha" > "$WORK/low-entropy.md"
scan "$WORK/low-entropy.md"; rc=$?
[ "$rc" -eq 0 ] && pass "RED control: an upper-cased sha can scan clean, so the row below pins its value" \
    || fail "RED control: gitleaks rc=$rc on the low-entropy upper-cased sha, expected 0"
upper_hex="3F9A7C2E5B8D1046AE""93C7F25D80B1E64A9C37D2"
caught "upper-case 40-char token" "secret = $upper_hex"
caught "secret in the label slot" "token=S-$gen-abcd"
caught "short secret in the label slot" "token=Z-$short-1a2b3c4d"
n=0
for t in "S-N2802-7023775e$gen" "ab-$gen-pid1" "$aws" "$pat" "S-$gen-abcd" "Z-$short-1a2b3c4d" "S-N2802_${gen}-abcd"; do
    n=$((n + 1))
    if [ -n "$GRAMMAR" ] && fullmatch "$t"; then fail "RED grammar admits secret-shaped token #$n"; else pass "RED grammar refuses a secret-shaped token"; fi
done
# the judge-brief qid validator refuses the same label-slot secret
printf '{"qid": "%s", "ticket": "HIMMEL-3746", "pr": 2599, "head": "0123456789abcdef0123456789abcdef01234567", "question": "Is it?", "reason": "a dispute", "prior": "HIMMEL-3254. Source: qmd.", "tier": {"category": "design", "reason": "a design call"}}\n' "$gen" > "$WORK/spec-secret.json"
err="$(python3 "$HERE/gen-judge-brief.py" "$WORK/spec-secret.json" --console HIMMEL-nextleg-2026-10-13Z-roadmap-console \
    --bucket "$WORK/judge-secret" --date 2026-10-13 --handover-root "$WORK/handovers" --scratch-root "$WORK/verdicts" 2>&1 >/dev/null)"
case "$err" in *"qid '$gen' must be"*) pass "RED gen-judge-brief refuses a high-entropy qid" ;;
    *) fail "RED gen-judge-brief did not refuse the high-entropy qid (stderr: ${err:-none})" ;; esac

# --- 6. one grammar everywhere -------------------------------------------------
shapes="$(sed -n "/^CLOSED_SHAPES=/,/'\$/p" "$STALL")"
case "$shapes" in *"	$GRAMMAR'"*) pass "vault-stall CLOSED_SHAPES carries the grammar verbatim" ;;
    *) fail "vault-stall CLOSED_SHAPES does not carry the grammar verbatim" ;; esac
[ -f "$DOC" ] && grep -qF -- "$GRAMMAR" "$DOC" && pass "the grammar doc states the rule verbatim" \
    || fail "$DOC does not state the rule verbatim"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
