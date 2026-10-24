#!/usr/bin/env bash
# scripts/ci/shard-manifest-verify.sh
#
# The shell-unit aggregator's proof that the fixed shards ran exactly what the
# base-sourced selection picked, at this head. Each shard's run-shell-tests.sh
# writes manifest-shard<k>.txt (SUITE_MANIFEST): the impacted-selection.sh
# header it acted on, a `shard k/n` line, then one line per suite it touched:
#   ran <rc> <path>   the suite ran on this shard with that exit code
#   skip <path>       filtered out (tier, platform, impacted, ...)
#   unrun <path>      assigned to this shard but never started (budget)
#   notfound <path>   selected, but the runner never discovered it
#
# Usage: shard-manifest-verify.sh --dir <d> --shards <n> --selection <file>
#                                 --discovered <list> [--absent-ok "<k> ..."]
#   <file> is impacted-selection.sh's output, computed by the aggregator itself.
#   <list> is the aggregator's own `run-shell-tests.sh --list .` output at the
#   same head, under the shards' tier and changed-since env but WITHOUT the
#   impacted filter: `[RUN ] <path>` is a suite every standing filter lets run
#   here, `[SKIP] <path> — <reason>` one a standing filter skips.
#
# Refuses (rc 1): a missing manifest; a manifest whose head, header or shard
# line differs from what this job computed (a manifest from another sha, or a
# shard that decided differently); any `unrun`; any `ran` with rc != 0 (except a
# suite scripts/ci/suite-tiers.tsv quarantines, a NOTE in every mode: the runner
# forgave it, it is uncovered and never counted as passed); a suite
# ran more than once; a suite <list> names to RUN that no shard ran (in
# impacted mode: a SELECTED one); and in impacted mode a suite ran that was not
# selected, or a selected suite no shard ran that <list> does not account for.
# So a shard's `skip` of a selected suite is a NOTE only when <list> skips it
# too, and its `notfound` only when <list> does not name it at all (a deleted
# suite, or one outside the scan roots) — a shard cannot drop a suite by
# filtering it or by claiming it never saw it. Prints OK and exits 0 otherwise;
# rc 2 on usage errors, including a missing, unreadable or empty <list>.
#
# SUITE_TIER_MODE=pr (env, the aggregator step's): the shards run the
# suite-tiers.tsv floor beside an impacted selection, and <list> is that floor.
# In impacted mode every suite <list> names to RUN may run and must run, as in
# full mode, and a selected suite <list> skips only for its local tier must run.
# In full mode a shard runs every tier, so a suite <list> skips only for its
# local tier must run too (<list> is asked without a selection).
# A pr-tier suite (scripts/ci/suite-tiers.tsv, SUITE_TIERS_TSV overrides the
# path) that <list> skips only for a missing tool (`capability: <tool> not on
# PATH`) is the same: the aggregator runner lacks tools the shards install, so
# the shards run it and must, as for any floor suite. An unreadable tiers file
# lists no pr suite, so no capability skip is excused.
#
# SUITE_TIERS_TSV (env) overrides the suite-tiers.tsv next to this script; an
# unreadable file quarantines nothing, so no failure is forgiven.
#
# --absent-ok "<k> ...": shards the plan job left out because they had no suite
# Only THEIR missing manifests are excused (one that exists is
# still verified). Nothing else is relaxed: the accounting below still demands
# every selected suite ran exactly once, so a shard wrongly left out is red.
#
# ponytail: <list> is taken on the aggregator's runner, so a capability skip
# of a non-pr-tier suite (a tool present on the shards but absent here) reads
# as SKIP and a shard's matching skip stays a NOTE; the shards and the
# aggregator share one image (ubuntu-latest). Revisit if they ever diverge.
#
# Platform guard: bash 3.2+ and POSIX awk; the aggregator runs on Linux.
set -uo pipefail

dir="" shards="" selection="" discovered="" absent_ok=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}"; shift 2 || break ;;
    --shards) shards="${2:-}"; shift 2 || break ;;
    --selection) selection="${2:-}"; shift 2 || break ;;
    --discovered) discovered="${2:-}"; shift 2 || break ;;
    --absent-ok) absent_ok="${2:-}"; shift 2 || break ;;
    *) echo "shard-manifest-verify: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$dir" ] || [ -z "$selection" ] || [ -z "$discovered" ] || ! [[ "$shards" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: shard-manifest-verify.sh --dir <d> --shards <n> --selection <file> --discovered <list> [--absent-ok \"<k> ...\"]" >&2
  exit 2
fi
for _a in $absent_ok; do
  case "$_a" in ''|*[!0-9]*) echo "shard-manifest-verify: --absent-ok wants shard numbers, got '$_a'" >&2; exit 2 ;; esac
done
if [ ! -r "$selection" ] || ! grep -qE '^mode (full|impacted)$' "$selection"; then
  echo "shard-manifest-verify: selection '$selection' is unreadable or has no mode line" >&2
  exit 2
fi
tiers_tsv="${SUITE_TIERS_TSV:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suite-tiers.tsv}"
quar_lines=""
[ -r "$tiers_tsv" ] && quar_lines=$(awk -F'\t' '!/^#/ && $2 == "quarantine" { print "quar " $1 }' "$tiers_tsv")
pr_lines=""
[ -r "$tiers_tsv" ] && pr_lines=$(awk -F'\t' '!/^#/ && $2 == "pr" { print "ptier " $1 }' "$tiers_tsv")
disc_lines=""
[ -r "$discovered" ] && disc_lines=$(sed -n -e 's/^\[RUN \] \([^ ]*\).*/drun \1/p' -e 's/^\[SKIP\] \([^ ]*\) — tier: local .*/dlocal \1/p' -e 's/^\[SKIP\] \([^ ]*\) — capability: .*/dcap \1/p' -e 's/^\[SKIP\] \([^ ]*\).*/dskip \1/p' "$discovered")
if [ -z "$disc_lines" ]; then
  echo "shard-manifest-verify: discovered list '$discovered' is unreadable or names no suite" >&2
  exit 2
fi

# Suite paths are carried as the space-delimited fields above, so one holding
# whitespace would be split and mis-accounted: refuse it, naming the path
#
# A `[SKIP]` line carries ` — <reason>` after its path, so the reason's own
# spaces must not read as path whitespace: past the first field only empty or a
# ` — ` reason is legal there. Byte-literal `case` matches, so the check does
# not depend on the runner's locale.
ws_bad=$(sed -n -e 's/^suite //p' "$selection" | grep -E '[[:space:]]' | sed 's/^/selection: /' || true)
while IFS= read -r l; do
  case "$l" in
    '[RUN ] '*)
      p=${l#'[RUN ] '}
      case "$p" in *[[:space:]]*) ws_bad="${ws_bad}${ws_bad:+$'\n'}discovered: $p" ;; esac ;;
    '[SKIP] '*)
      p=${l#'[SKIP] '}
      first=${p%% *}
      rest=${p#"$first"}
      case "$first" in
        *[[:space:]]*) ws_bad="${ws_bad}${ws_bad:+$'\n'}discovered: $p" ;;
        *) case "$rest" in
             ''|' — '*) ;;
             *) ws_bad="${ws_bad}${ws_bad:+$'\n'}discovered: $p" ;;
           esac ;;
      esac ;;
  esac
done < "$discovered"
if [ -n "$ws_bad" ]; then
  while IFS= read -r l; do echo "FAIL: suite path contains whitespace ($l)"; done <<< "$ws_bad"
  echo "shard-manifest-verify: REFUSED — a suite path with whitespace cannot be accounted"
  exit 1
fi

HDR_RE='^(mode|reason|base|head|selector|changed|suite) '
want_hdr=$(grep -E "$HDR_RE" "$selection")
want_head=$(grep -m1 '^head ' "$selection")
mode=$(grep -m1 '^mode ' "$selection"); mode="${mode#mode }"

bad=0
bodies=""
k=1
while [ "$k" -le "$shards" ]; do
  m="$dir/manifest-shard$k.txt"
  if [ ! -r "$m" ]; then
    case " $absent_ok " in *" $k "*) k=$((k + 1)); continue ;; esac
    echo "FAIL: missing manifest for shard$k: $m"
    bad=1; k=$((k + 1)); continue
  fi
  got_head=$(grep -m1 '^head ' "$m")
  got_shard=$(grep -m1 '^shard ' "$m")
  if [ "$got_head" != "$want_head" ]; then
    echo "FAIL: shard$k: manifest '${got_head:-no head line}' != selection '$want_head'"
    bad=1
  elif [ "$(grep -E "$HDR_RE" "$m")" != "$want_hdr" ]; then
    echo "FAIL: shard$k: manifest header differs from the selection this job computed"
    diff <(printf '%s\n' "$want_hdr") <(grep -E "$HDR_RE" "$m") | sed 's/^/    /'
    bad=1
  fi
  if [ "$got_shard" != "shard $k/$shards" ]; then
    echo "FAIL: shard$k: want 'shard $k/$shards', found '${got_shard:-no shard line}'"
    bad=1
  fi
  ws_m=$(sed -n -e 's/^ran [^ ]* //p' -e 's/^\(skip\|unrun\|notfound\) //p' "$m" | grep -E '[[:space:]]' || true)
  if [ -n "$ws_m" ]; then
    while IFS= read -r l; do echo "FAIL: shard$k: suite path contains whitespace ($l)"; done <<< "$ws_m"
    bad=1
  fi
  bodies="${bodies}$(grep -E '^(ran|skip|unrun|notfound) ' "$m" | sed "s/^/$k /")"$'\n'
  k=$((k + 1))
done

# Accounting across every shard. Input: "sel <path>", "drun <path>", "dlocal
# <path>" and "dskip <path>" lines, then "<k> <body>".
acct=$( { grep '^suite ' "$selection" | sed 's/^suite /sel /'
          [ -z "$pr_lines" ] || printf '%s\n' "$pr_lines"
          printf '%s\n' "$disc_lines"
          [ -z "$quar_lines" ] || printf '%s\n' "$quar_lines"
          printf '%s' "$bodies"; } | awk -v mode="$mode" -v tier="${SUITE_TIER_MODE:-}" '
  $1 == "sel"   { sel[$2] = 1; order[++nsel] = $2; next }
  $1 == "ptier" { ptier[$2] = 1; next }
  $1 == "drun"  { drun[$2] = 1; dorder[++ndisc] = $2; next }
  $1 == "dcap" && tier == "pr" && ($2 in ptier) { drun[$2] = 1; dorder[++ndisc] = $2; next }
  $1 == "dcap"  { dskip[$2] = 1; next }
  $1 == "dlocal" && tier == "pr" && mode == "full" { drun[$2] = 1; dorder[++ndisc] = $2; next }
  $1 == "dlocal" { if (tier == "pr") dlocal[$2] = 1; else dskip[$2] = 1; next }
  $1 == "dskip" { dskip[$2] = 1; next }
  $1 == "quar"  { quar[$2] = 1; next }
  NF < 3 { next }
  $2 == "ran"      { runs[$4]++; if ($3 == "0") nran++; else if ($4 in quar) printf "NOTE: %s ran on shard%s with rc %s, quarantined in suite-tiers.tsv (uncovered)\n", $4, $1, $3; else printf "FAIL: %s ran on shard%s with rc %s\n", $4, $1, $3; next }
  $2 == "unrun"    { printf "FAIL: %s was assigned to shard%s but left unrun\n", $3, $1; next }
  $2 == "skip"     { skipped[$3] = 1; next }
  $2 == "notfound" { missing[$3] = 1; next }
  END {
    for (p in runs) {
      if (runs[p] > 1) printf "FAIL: %s ran %d times across shards\n", p, runs[p]
      if (mode == "impacted" && !(p in sel) && !(tier == "pr" && (p in drun))) printf "FAIL: %s ran but was not selected\n", p
    }
    if (mode != "impacted" || tier == "pr") {
      for (i = 1; i <= ndisc; i++)
        if (!(dorder[i] in runs)) printf "FAIL: %s never ran on any shard, though discovery lists it to run here\n", dorder[i]
    }
    if (mode == "impacted") for (i = 1; i <= nsel; i++) {
      p = order[i]
      if (p in runs) continue
      if (p in drun) { if (tier != "pr") printf "FAIL: selected %s never ran on any shard, though discovery lists it to run here\n", p }
      else if ((p in missing) && ((p in dskip) || (p in dlocal))) printf "FAIL: selected %s was recorded notfound, but discovery finds it here\n", p
      else if (p in missing)               printf "NOTE: selected %s was not discovered by the runner or the discovered list\n", p
      else if ((p in skipped) && (p in dskip)) printf "NOTE: selected %s was skipped by a standing filter (discovery skips it too)\n", p
      else if (p in dlocal)                printf "FAIL: selected %s never ran; its local tier does not exempt an impacted suite\n", p
      else if (p in skipped)               printf "FAIL: selected %s was skipped by a shard, but discovery does not list it\n", p
      else                                 printf "FAIL: selected %s never ran on any shard\n", p
    }
    print "ACCOUNTED"
  }')
acct_rc=$?
# Fail closed: a crashed or truncated accounting pass (non-zero rc, or no
# closing sentinel line) must never read as OK.
if [ "$acct_rc" -ne 0 ] || [ "$(tail -n 1 <<< "$acct")" != ACCOUNTED ]; then
  echo "FAIL: suite accounting failed (rc $acct_rc) — coverage was not checked"
  echo "shard-manifest-verify: REFUSED — the shards did not run the selection ($mode mode)"
  exit 1
fi
acct=$(grep -v '^ACCOUNTED$' <<< "$acct")
[ -z "$acct" ] || printf '%s\n' "$acct"
grep -q '^FAIL' <<< "$acct" && bad=1

if [ "$bad" -ne 0 ]; then
  echo "shard-manifest-verify: REFUSED — the shards did not run the selection ($mode mode)"
  exit 1
fi
n_sel=$(grep -c '^suite ' "$selection")
echo "OK: $shards shard manifest(s) match the $mode selection at ${want_head#head } ($n_sel selected)"
exit 0
