#!/usr/bin/env bash
# scripts/handover/chief-kit/version-counts-check.sh - read-only side-by-side of live Jira and the
# Jira mirror's per-version counts.
#
# Usage: JIRA_PROJECT_KEY=<KEY> version-counts-check.sh [<version>...]
#   One line per unreleased version (the .versions.tsv rows not marked released), or per version named:
#     <version> open live=<n> mirror=<n> residual-regex live=<n> mirror=<n> SAME|DIFF
#   then `VERDICT SAME` or `VERDICT DIFF`. A line's verdict compares OPEN only: open is the version
#   size. residual-regex is the board/tick rule, a label matching (^|-)residual(-|$) on an open
#   ticket; it is shown beside, never reported as a version size, and does not move the verdict.
#   open = status not Done, Resolved, Closed, Wont Do or Won't Do.
# Exit: 0 SAME, 1 DIFF, 2 bad input or an unreadable source.
# Seams: VERSION_COUNTS_JIRA (the jira CLI command; default: node dist/index.js of the primary
#   checkout), VERSION_COUNTS_MIRROR (mirror root; default ~/.himmel/state/jira-mirror/<KEY>).
#
# Platform guard: Linux/macOS bash 3.2+, python3.
set -uo pipefail

fail2() { echo "version-counts-check: $*" >&2; exit 2; }

versions=()
while [ $# -gt 0 ]; do
    case "$1" in
        -*) fail2 "unknown option: $1" ;;
        *) versions+=("$1") ;;
    esac
    shift
done

project="${JIRA_PROJECT_KEY:-}"
[ -n "$project" ] || fail2 "JIRA_PROJECT_KEY is required"
mirror="${VERSION_COUNTS_MIRROR:-$HOME/.himmel/state/jira-mirror/$project}"
[ -d "$mirror" ] || fail2 "mirror root not readable: $mirror"
vfile="$mirror.versions.tsv"
[ -r "$vfile" ] || fail2 "versions file not readable: $vfile"

if [ -n "${VERSION_COUNTS_JIRA:-}" ]; then
    jira_cmd=("$VERSION_COUNTS_JIRA")
else
    HERE="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=../../lib/git-clean.sh
    . "$HERE/../../lib/git-clean.sh" && git_env_scrub
    anchor="$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir)" || anchor=""
    [ -n "$anchor" ] || fail2 "cannot find the primary checkout for the jira CLI (set VERSION_COUNTS_JIRA)"
    jira_cmd=(node "${anchor%/.git}/scripts/jira/dist/index.js")
fi

if [ "${#versions[@]}" -eq 0 ]; then
    while IFS=$'\t' read -r name released _; do
        [ -n "$name" ] || continue
        [ "$released" = "true" ] || versions+=("$name")
    done < "$vfile"
fi
[ "${#versions[@]}" -gt 0 ] || fail2 "no unreleased versions in $vfile"

mirror_counts="$(VC_MIRROR="$mirror" python3 -I -c '
import json, os, re, sys
d = os.environ["VC_MIRROR"]
gone = re.compile(r"^(done|resolved|closed|wont do|won\x27t do)$", re.I)
res = re.compile(r"(^|-)residual(-|$)")
open_n, res_n = {}, {}
for name in os.listdir(d):
    if not name.endswith(".md"):
        continue
    front = []
    with open(os.path.join(d, name), encoding="utf-8") as fh:
        if fh.readline().rstrip("\n") != "---":
            sys.exit(1)
        for line in fh:
            if line.rstrip("\n") == "---":
                break
            front.append(line)
        else:
            sys.exit(1)
    head = "".join(front)
    def val(k):
        m = re.search("^" + k + ": (.*)$", head, re.M)
        if not m:
            return None
        try:
            return json.loads(m.group(1))
        except ValueError:
            sys.exit(1)
    status, fixv, labels = val("status"), val("fixVersions"), val("labels")
    if not isinstance(status, str) or not isinstance(fixv, list) or not isinstance(labels, list):
        sys.exit(1)
    if not all(isinstance(x, str) for x in fixv + labels):
        sys.exit(1)
    if gone.match(status):
        continue
    isres = any(res.search(x) for x in labels)
    for v in fixv:
        open_n[v] = open_n.get(v, 0) + 1
        res_n[v] = res_n.get(v, 0) + (1 if isres else 0)
for v in open_n:
    print(v + "\t" + str(open_n[v]) + "\t" + str(res_n[v]))
')" || fail2 "mirror not readable: $mirror"

verdict=SAME
for v in "${versions[@]}"; do
    case "$v" in *\"*|*$'\n'*|*$'\t'*) fail2 "bad version name: $v" ;; esac
    jql="project = $project AND fixVersion = \"$v\" AND status NOT IN (Done, Resolved, Closed, \"Wont Do\", \"Won't Do\") ORDER BY key ASC"
    live_out="$(JIRA_PROJECT_KEY="$project" "${jira_cmd[@]}" list --labels --limit 5000 --jql "$jql")" || fail2 "jira list failed for $v"
    live_rows="$(printf '%s\n' "$live_out" | grep -c .)"
    [ "$live_rows" -lt 5000 ] || fail2 "live list for $v reached the 5000 row limit, so its count may be truncated"
    live="$(printf '%s\n' "$live_out" | python3 -I -c '
import re, sys
gone = re.compile(r"^(done|resolved|closed|wont do|won\x27t do)$", re.I)
res = re.compile(r"(^|-)residual(-|$)")
o = r = 0
for line in sys.stdin:
    if not line.strip():
        continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 3 or not re.match(r"^[A-Z][A-Z0-9_]*-[0-9]+$", f[0]):
        sys.exit(1)
    if gone.match(f[2]):
        continue
    o += 1
    if len(f) >= 5 and any(res.search(x) for x in f[-1].split(",")):
        r += 1
print(o, r)
')" || fail2 "cannot read the jira list output for $v"
    lo="${live% *}"; lr="${live#* }"
    mrow="$(printf '%s\n' "$mirror_counts" | awk -F'\t' -v v="$v" '$1 == v { print $2, $3 }')"
    [ -n "$mrow" ] || mrow="0 0"
    mo="${mrow% *}"; mr="${mrow#* }"
    if [ "$lo" = "$mo" ]; then s=SAME; else s=DIFF; verdict=DIFF; fi
    echo "$v open live=$lo mirror=$mo residual-regex live=$lr mirror=$mr $s"
done

echo "VERDICT $verdict"
[ "$verdict" = SAME ]
