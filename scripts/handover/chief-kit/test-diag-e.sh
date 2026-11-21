#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2015,SC2012,SC2329,SC2016,SC2153,SC2154
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go.sh"
unset HIMMEL_CONSOLE_LEG CHIEF_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
ROOT14="$tmp/root14"; ROOT15="$tmp/root15"; ROOT16="$tmp/root16"; ROOT18="$tmp/root18"
NOWHERE32="$tmp/nowhere32"; DECOY32="$tmp/decoy32"; ROOT32="$tmp/root32"
export HOME="$tmp/home"; mkdir -p "$HOME"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
case "$1 $2" in
    "repo view")
        json=""
        while [ $# -gt 0 ]; do
            case "$1" in --json) json="$2" ;; esac
            shift
        done
        case "$json" in
            nameWithOwner)
                [ "${STUB_GH_RL:-0}" = "1" ] && { echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1; }
                [ "${STUB_GH_REPO_VIEW_FAIL:-0}" = "1" ] && exit 1
                printf '%s' "${STUB_NWO:-o/r}" ;;
            *) exit 90 ;;
        esac ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export STUB_NWO="o/r"

# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"
export PATH="$tmp/ready-bin:$PATH"
READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
export HIMMEL_REPO="$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }

fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

verdict() {
  local vf="$1/$VSCOPE/verdicts/$2/${4:-HIMMEL-1-judge-$2}.md" vmac
  mkdir -p "$1/$VSCOPE/verdicts/$2"
  printf '# VERDICT %s - judge\n\n%s## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n%s' \
    "$2" "${VWRITTEN:+written-at: $VWRITTEN$'\n\n'}" "$3" "${VPR:-83}" "${VEXTRA:-}" > "$vf"
  [ "${VSIGN:-1}" = 1 ] || return 0
  vsign "$2" "$vf"
}
vsign() {
  local vmac
  mkdir -p "$HOME/.config/himmel"
  [ -s "$HOME/.config/himmel/go-hmac.key" ] || printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
  vmac="$(cat "$2" | bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$1" "$(basename "$2" .md)")" || { echo "FAIL: cannot sign $2" >&2; return 1; }
  printf 'mac: %s\n' "$vmac" >> "$2"
}

export USER_SLUG=u
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"

SHA=$(ready_pass_repo "$READY_REPO") || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
S31="$tmp/s31"; ROOT31="$tmp/root31"; Q31="$tmp/quota31"
rm -rf "$S31"; mkdir -p "$S31/scripts/handover/chief-kit" "$S31/scripts/cr"
git init -q "$S31"
cp "$SCRIPT" "$S31/scripts/handover/chief-kit/go.sh"
cp -R "$HERE/../../lib" "$S31/scripts/lib"
cp "$HERE/../../cr/anchor-handoff.sh" "$S31/scripts/cr/anchor-handoff.sh"
# shellcheck disable=SC2016  # the stub bodies must expand at run time, not here
{
printf '%s\n' '#!/usr/bin/env bash' 'sleep "${STUB_RC_SLEEP:-0}"' 'echo "stub ready-check output"' 'exit "${STUB_RC_READY:-0}"' > "$S31/scripts/handover/chief-kit/ready-check.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub cr-disposition output"' 'exit "${STUB_RC_DISP:-0}"' > "$S31/scripts/handover/chief-kit/cr-disposition.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep "${STUB_WV_SLEEP:-0}"' 'exit 0' > "$S31/scripts/handover/chief-kit/write-verdict.sh"
}
mkdir -p "$S31/bin"
# shellcheck disable=SC2016  # the stub body must expand at run time, not here
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *"/.locks/go/.go."*) [ -z "${STUB_MKTEMP_MARK:-}" ] || echo hit > "$STUB_MKTEMP_MARK"; [ -z "${STUB_MKTEMP_SLEEP:-}" ] || sleep "$STUB_MKTEMP_SLEEP" ;; esac' 'exec /usr/bin/mktemp "$@"' > "$S31/bin/mktemp"
chmod +x "$S31/bin/mktemp"
go31() {
    (cd "$S31" && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="${Q31_DIR:-$Q31}" bash "$S31/scripts/handover/chief-kit/go.sh" "$@" 2>&1)
}
fresh31() { rm -rf "$ROOT31" "$Q31"; mkdir -p "$ROOT31"; }
gofiles31() { find "$ROOT31/.locks/go" -type f ! -name '.go.*' 2>/dev/null | wc -l | tr -d ' '; }

echo "=== env"
uname -a
bash --version | head -1
type -a timeout gtimeout bash pgrep 2>&1
timeout --version 2>&1 | head -1
echo "ignored/caught of this suite shell:"
ps -o pid,ppid,pgid,stat,ignored,caught,command -p $$ 2>&1

snap() {
    echo "--- $1 (t=$((SECONDS - dg_t0)))"
    ps -axo pid,ppid,pgid,stat,ignored,caught,command 2>&1 | awk -v root="$$" '
        { line[NR] = $0; pid[NR] = $1; ppid[NR] = $2 }
        END {
            keep[root] = 1
            do { ch = 0; for (i = 1; i <= NR; i++) if ((ppid[i] in keep) && !(pid[i] in keep)) { keep[pid[i]] = 1; ch = 1 } } while (ch)
            for (i = 1; i <= NR; i++) if (pid[i] in keep) print substr(line[i], 1, 160)
        }'
}

dg_run() {
    local label="$1" sig="$2" ign="$3" tr="${4:-}" rc=0 xt=""
    [ -z "$tr" ] || xt="SHELLOPTS=xtrace"
    fresh31
    echo "=== $label sig=$sig ign=$ign"
    dg_t0=$SECONDS
    ( sleep 1; snap "$label before"; sleep 1; snap "$label t2"; sleep 2; snap "$label +after-signal"; sleep 2; snap "$label +5s-after" ) &
    dg_w=$!
    (cd "$S31" && { [ "$ign" = 0 ] || trap '' INT; } && PATH="$S31/bin:$PATH" HANDOVER_DIR="$ROOT31" HIMMEL_QUOTA_DIR="$Q31" STUB_RC_SLEEP=10 GO_DEADLINE=30 env ${xt:+"$xt"} PS4='+ $SECONDS ${BASH_SOURCE##*/}:$LINENO: ' timeout -s "$sig" -k 5 3 bash "$S31/scripts/handover/chief-kit/go.sh" 77 "$SHA" > "$tmp/dg.out" 2> "$tmp/dg.err") || rc=$?
    echo "$label rc=$rc took=$((SECONDS - dg_t0))s"
    wait "$dg_w"
    if [ -n "$tr" ]; then grep -n -E "_go_term|wait |kill |pgrep|exit|timeout" "$tmp/dg.err" | head -60; else head -5 "$tmp/dg.err"; fi
}
dg_run A-INT INT 0
dg_run B-INT-ign INT 1
dg_run C-TERM TERM 0
dg_run D-INT-trace INT 0 trace

echo "=== mimic"
cat > "$tmp/mimic.sh" <<'EOF'
if [ -z "${ARMED:-}" ]; then
    _term() {
        local pid="${gd_pid:-$!}"
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        exit 143
    }
    gd_pid=""
    trap '_term' TERM INT HUP
    ARMED=1 timeout -k 5 30 bash "$0" <&0 &
    gd_pid=$!
    rc=0; wait "$gd_pid" || rc=$?
    exit "$rc"
fi
sleep 10
EOF
for sig in INT TERM; do
    t0=$SECONDS; rc=0
    timeout -s "$sig" -k 5 3 bash "$tmp/mimic.sh" > /dev/null 2>&1 || rc=$?
    echo "mimic $sig rc=$rc took=$((SECONDS - t0))s"
done
echo "FAIL - diag (intentional, to keep the log)"; exit 1
