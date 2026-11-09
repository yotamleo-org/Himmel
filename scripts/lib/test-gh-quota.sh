#!/usr/bin/env bash
# test-gh-quota.sh — scripts/lib/gh-quota.sh: the quota read, the scan gate, the
# one line, the blocked marker, the rate-limit rule and the bucket rule.
# Hermetic: a stub gh on PATH answers per token ($STUB_MAIN / $STUB_READ) and
# logs every call; HOME and HIMMEL_QUOTA_DIR are scratch.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; stub bodies expand at run time
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/gh-quota.sh"
FIX="$REPO/scripts/handover/chief-kit/testdata/quota"
W="$(mktemp -d "${TMPDIR:-/tmp}/gh-quota-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1 (found '$2' in '$3')" ;; *) pass "$1" ;; esac; }

READTOK=ghp_QUOTAREAD0123456789
mkdir -p "$W/bin" "$W/home" "$W/root" "$W/emptyroot" "$W/ghcfg"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$W/root/.env"
: > "$W/emptyroot/.env"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# mode per token: ok low out hung unreadable reset-past reset-absent reset-absurd secondary
if [ "${GH_TOKEN:-}" = ghp_QUOTAREAD0123456789 ]; then who=read; mode="${STUB_READ:-ok}"; else who=main; mode="${STUB_MAIN:-ok}"; fi
printf '%s %s\n' "$who" "$*" >> "$STUB_LOG"
now=$(date +%s)
rem=4000; reset=$((now + 1800)); extra=""
case "$mode" in
    hung) exec sleep 30 ;;
    unreadable) echo "gh: HTTP 502: Bad Gateway" >&2; exit 1 ;;
    low) rem=100 ;;
    out) rem=0 ;;
    reset-past) rem=0; reset=$((now - 3600)) ;;
    reset-absent) rem=0; reset="" ;;
    reset-absurd) rem=0; reset=4102444800 ;;
    secondary) rem=10; extra="Retry-After: 60" ;;
esac
case " $* " in
    *" -i "*)
        printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: %s\r\n' "$rem"
        [ -z "$reset" ] || printf 'X-Ratelimit-Reset: %s\r\n' "$reset"
        [ -z "$extra" ] || printf '%s\r\n' "$extra"
        printf '\r\n{}\n' ;;
esac
case "$mode" in
    out|reset-*) echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1 ;;
    secondary) echo "gh: You have exceeded a secondary rate limit." >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" HOME="$W/home" GH_CONFIG_DIR="$W/ghcfg" HIMMEL_SECRETS_KEYRING=off \
    STUB_LOG="$W/gh.log" GH_READ_ENV_ROOT="$W/root" GHQ_PROBE_TIMEOUT=2
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY GHQ_SCAN_FLOOR GHQ_GH_CMD
: > "$STUB_LOG"

# shellcheck source=scripts/lib/gh-quota.sh
. "$LIB"

fresh() { export HIMMEL_QUOTA_DIR="$W/q.$1"; rm -rf "$HIMMEL_QUOTA_DIR"; : > "$STUB_LOG"; }
row() { awk -F'\t' -v t="$1" -v b="$2" '$1 == t && $2 == b { print $3 " " $7 }' "$HIMMEL_QUOTA_DIR/quota.tsv" 2>/dev/null; }

# ---- refresh -----------------------------------------------------------------
fresh healthy
ghq_refresh
check "R1 four rows, one per token and bucket" "4" "$(grep -c . "$HIMMEL_QUOTA_DIR/quota.tsv" 2>/dev/null)"
check "R1b main graphql row" "4000 ok" "$(row main graphql)"
check "R1c read core row" "4000 ok" "$(row read core)"
check "R1d probes: GraphQL by rateLimit, core by a real api -i user" "main api -i graphql -f query={rateLimit{remaining}}|main api -i user|read api -i graphql -f query={rateLimit{remaining}}|read api -i user" "$(tr '\n' '|' < "$STUB_LOG" | sed 's/|$//')"
: > "$STUB_LOG"
ghq_refresh
check "R2 a refresh under 170 s old makes no call" "" "$(cat "$STUB_LOG")"
awk -F'\t' -v OFS='\t' '{ $6 = $6 - 200; print }' "$HIMMEL_QUOTA_DIR/quota.tsv" > "$W/t" && mv "$W/t" "$HIMMEL_QUOTA_DIR/quota.tsv"
ghq_refresh
check "R3 a stale file is probed again" "4" "$(grep -c . "$STUB_LOG")"
printf 'garbage\n' > "$HIMMEL_QUOTA_DIR/quota.tsv"; : > "$STUB_LOG"
ghq_refresh
check "R4 a corrupt file is probed again" "4" "$(grep -c . "$STUB_LOG")"

fresh readonly
STUB_READ=out ghq_refresh
check "R5 read token refused: its row says refused, not main's number" "0 refused" "$(row read graphql)"
check "R5b main row stays main's" "4000 ok" "$(row main graphql)"
check "R5c no probe went through the router's fallback: one main GraphQL probe" "1" "$(grep -c '^main api -i graphql' "$STUB_LOG")"

fresh notoken
GH_READ_ENV_ROOT="$W/emptyroot" ghq_refresh
check "R6 no read token: main's two rows only" "main main" "$(cut -f1 "$HIMMEL_QUOTA_DIR/quota.tsv" | tr '\n' ' ' | sed 's/ $//')"

fresh hung
t0=$SECONDS
STUB_MAIN=hung STUB_READ=hung ghq_refresh
el=$((SECONDS - t0))
check "R7 a timed-out probe stops the refresh: one call" "1" "$(grep -c . "$STUB_LOG")"
check "R7b the rest are marked timed-out" "4" "$(grep -c 'timed-out$' "$HIMMEL_QUOTA_DIR/quota.tsv")"
check "R7c bounded by one probe timeout" "yes" "$([ "$el" -le 4 ] && echo yes || echo "no:${el}s")"

fresh unwritable
mkdir -p "$W/ro" && chmod 500 "$W/ro"
HIMMEL_QUOTA_DIR="$W/ro/q" ghq_refresh
check "R8 an unwritable dir never fails the caller" "0" "$?"
chmod 700 "$W/ro"

# ---- the scan gate -------------------------------------------------------------
gate() { # <mode for main> -> "rc|line"
    local out rc
    fresh "gate.$1"
    out=$(STUB_MAIN="$1" ghq_scan_gate main graphql next-dispatchable); rc=$?
    printf '%s|%s' "$rc" "$out"
}
check "G1 healthy: proceed, no line" "0|" "$(gate ok)"
g=$(gate low)
check "G2 under the floor: rc 75" "75" "${g%%|*}"
has "G2b the line names the bucket, token, remaining, floor and caller" "QUOTA-PAUSE github graphql token=main remaining=100 floor=500 reset=" "$g"
has "G2c and says nothing was judged" "caller=next-dispatchable nothing-was-judged" "$g"
has "G2d a future reset is named with its distance" "Z (in " "$g"
for m in reset-past reset-absent reset-absurd; do
    g=$(gate "$m")
    has "G3 $m: paused with reset=unknown" "75|QUOTA-PAUSE github graphql token=main remaining=0 floor=500 reset=unknown" "$g"
done
g=$(gate secondary)
has "G4 Retry-After wins over the reset: about 60 s away" "75|" "$g"
check "G4b the Retry-After distance" "yes" "$(grep -qE '\(in (5[5-9]|60)s\)' <<< "$g" && echo yes || echo "no: $g")"
g=$(gate hung)
check "G5 a timed-out probe pauses with the stall line" "75|GH-STALL github read timed out after 2s token=main caller=next-dispatchable nothing-was-judged" "$g"
check "G6 a fast unreadable probe proceeds" "0|" "$(gate unreadable)"
fresh floor
check "G7 GHQ_SCAN_FLOOR moves the floor" "0" "$(STUB_MAIN=low GHQ_SCAN_FLOOR=50 ghq_scan_gate main graphql x >/dev/null; echo $?)"
fresh absentrow
GH_READ_ENV_ROOT="$W/emptyroot" ghq_scan_gate read graphql x >/dev/null
check "G8 no read row (no read token): proceed" "0" "$?"

# I9: no probe in any mode asks gh api rate_limit
asks_rate_limit() { grep -qE '(^| )api rate_limit( |$)|/rate_limit' "$1"; }
: > "$W/all.log"
for m in ok low out hung unreadable reset-past reset-absent reset-absurd secondary; do
    fresh "i9.$m"
    STUB_MAIN=$m STUB_READ=$m ghq_scan_gate main graphql x >/dev/null
    STUB_MAIN=$m STUB_READ=$m ghq_scan_gate read core x >/dev/null
    cat "$STUB_LOG" >> "$W/all.log"
done
check "I9 no mode ever calls gh api rate_limit" "no" "$(asks_rate_limit "$W/all.log" && echo yes || echo no)"
printf 'main api rate_limit --jq .resources\n' > "$W/bad.log"
check "I9b control: a caller that asks rate_limit is caught" "yes" "$(asks_rate_limit "$W/bad.log" && echo yes || echo no)"

# ---- the line --------------------------------------------------------------------
fresh line
STUB_MAIN=out ghq_refresh
check "L1 a gate's line omits a row older than its refusal, and any floor" "QUOTA-PAUSE github graphql token=main caller=go.sh nothing-was-judged" "$(ghq_line main graphql scripts/handover/chief-kit/go.sh rate-limit $(( $(date +%s) + 5 )))"
has "L2 a gate's line names a row observed after its refusal" "QUOTA-PAUSE github graphql token=main remaining=0 reset=" "$(ghq_line main graphql go.sh rate-limit 1)"
lacks "L2b and never a floor" "floor=" "$(ghq_line main graphql go.sh rate-limit 1)"
check "L3 the stall line" "GH-STALL github read timed out after 120s token=read caller=ready-check nothing-was-judged" "$(ghq_line read graphql ready-check stall)"

# ---- the rate-limit rule ------------------------------------------------------------
payload() { grep -v '^# ' "$1"; }
for f in 55498a23-F1 32a082f4-F2 c5d6911e-F3; do
    if [ -f "$FIX/$f.txt" ]; then
        check "C1 fixture $f reads as a rate limit" "yes" "$(ghq_is_rate_limited "$(payload "$FIX/$f.txt")" && echo yes || echo no)"
    else
        fail "C1 fixture $f is missing"
    fi
done
for s in "RATE_LIMITED" "You have exceeded a secondary rate limit" "abuse detection mechanism"; do
    check "C2 '$s' is a rate limit" "yes" "$(ghq_is_rate_limited "$s" && echo yes || echo no)"
done
# control: the phrase on stdout is a PR body, not a refusal; only stderr is read
out=$( { echo "body: fix the API rate limit exceeded false finding"; echo "gh: HTTP 404: Not Found" >&2; } 2>"$W/err")
check "C3 control: 'rate limit' on stdout with an unrelated stderr reads no" "no" "$(ghq_is_rate_limited "$(cat "$W/err")" && echo yes || echo no)"
has "C3b (the stdout did carry the phrase)" "rate limit" "$out"
check "C4 control: an unrelated failure reads no" "no" "$(ghq_is_rate_limited "gh: HTTP 502: Bad Gateway" && echo yes || echo no)"
check "C5 gh-graphql-budget.sh delegates" "yes no" "$(ghb_is_rate_limited "RATE_LIMITED" && echo yes || echo no) $(ghb_is_rate_limited "HTTP 502" && echo yes || echo no)"

# ---- bucket and routes ---------------------------------------------------------------
for c in "graphql:pr view 12 --json state" "core:pr diff 12" "core:run view 5 --log" "graphql:api graphql -f query=x" \
         "core:api repos/o/r/pulls" "graphql:repo view --json name" "graphql:issue list" "core:run list"; do
    want="${c%%:*}"; args="${c#*:}"
    # shellcheck disable=SC2086
    check "B1 '$args' spends $want" "$want" "$(ghq_bucket_of $args)"
done
check "B2 router callers ride read,main" "read,main read,main" "$(ghq_routes ready-check) $(ghq_routes scripts/check-ci.sh)"
check "B2b cr-disposition rides main" "main" "$(ghq_routes cr-disposition)"

# ---- the blocked marker ----------------------------------------------------------------
fresh mark
GHQ_REPO=o/r ghq_mark_blocked branch-docs/x unknown check-ci graphql rate-limit
mf="$HIMMEL_QUOTA_DIR/blocked/branch-docs%2Fx.unknown"
check "M1 a slashed branch is stored with %2F" "yes" "$([ -f "$mf" ] && echo yes || ls -R "$HIMMEL_QUOTA_DIR")"
has "M1b fields" "repo=o/r
caller=check-ci
buckets=graphql
routes=main,read
reason=rate-limit
first_epoch=" "$(cat "$mf" 2>/dev/null)"
sed 's/^first_epoch=.*/first_epoch=1000/' "$mf" > "$W/m" && cat "$W/m" > "$mf"
printf 'back_epoch=2000\n' >> "$mf"
ghq_mark_blocked branch-docs/x unknown cr-disposition core stall
has "M2 a second writer keeps first_epoch" "first_epoch=1000" "$(cat "$mf")"
has "M2b and unions buckets" "buckets=core,graphql" "$(cat "$mf")"
has "M2c a rate limit is not narrowed to a stall" "reason=rate-limit" "$(cat "$mf")"
lacks "M2d a new refusal drops back_epoch" "back_epoch" "$(cat "$mf")"
ghq_mark_blocked 42 abc123 ready-check graphql usage
check "M3 control: a reason that is not rate-limit or stall writes nothing" "no" "$([ -e "$HIMMEL_QUOTA_DIR/blocked/42.abc123" ] && echo yes || echo no)"
HIMMEL_QUOTA_DIR="$W/ro/q2" ghq_mark_blocked 42 abc123 ready-check graphql stall
rc=$?
chmod 500 "$W/ro"
HIMMEL_QUOTA_DIR="$W/ro/q3" ghq_mark_blocked 42 abc123 ready-check graphql stall
check "M4 an unwritable dir never fails the caller" "0 0" "$rc $?"
chmod 700 "$W/ro"

# ---- the live path and bash 3.2 ----------------------------------------------------------
check "H1 nothing was written under the scratch HOME's live quota path" "no" "$([ -e "$HOME/.himmel/state/quota" ] && echo yes || echo no)"
# the words are built from halves so this suite's own text is not a bash-4 form
K_MAP="map""file"; K_READ="read""array"; K_LOCK="f""lock"; K_ASSOC="declare"" -A"; K_DATE="date"" -d"
lint32() { # <file> -> names of bash-4 or GNU-only forms
    grep -vE '^[[:space:]]*#' "$1" | grep -oE "(^|[^[:alnum:]_])($K_MAP|$K_READ|$K_LOCK)([^[:alnum:]_]|\$)|$K_ASSOC|$K_DATE" \
        | sed -E 's/^[^[:alnum:]]+//; s/[^[:alnum:]]+$//' | sort -u | tr '\n' ' '
}
bad32=$(lint32 "$LIB")
# GNU date -d is allowed only beside its BSD date -r fallback
if grep -q "$K_DATE" "$LIB" && grep -q 'date -u -r' "$LIB"; then bad32=$(printf '%s' "$bad32" | sed "s/$K_DATE //"); fi
check "S1 gh-quota.sh uses no bash-4 or GNU-only form" "" "$bad32"
printf 'x() { %s -t a < f; %s m; }\n' "$K_MAP" "$K_ASSOC" > "$W/bad32.sh"
check "S1b control: the lint sees the two bash-4 forms" "$K_ASSOC $K_MAP " "$(lint32 "$W/bad32.sh")"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -S warning "$LIB" >"$W/sc" 2>&1 && pass "S2 shellcheck clean" || fail "S2 shellcheck: $(head -5 "$W/sc")"
else
    pass "S2 shellcheck absent here (CI runs it)"
fi

printf '%s fail\n' "$fails"
[ "$fails" -eq 0 ]
