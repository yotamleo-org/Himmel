#!/usr/bin/env bash
# suggest-allowlist — turn the AFK approval ledger into candidate allowlist classes.
#
# Slice 3 of the AFK sudo approvals design (spec section 10). Read-only: it reads the world-readable
# ledger and prints to stdout; it writes no file. The operator pastes the
# classes they want into /etc/himmel/afk-sudo.json (sudoedit) and flips `mode`
# back to `allowlist`.
#
# Usage: suggest-allowlist.sh [--since 30d|<N>h]
# Env:   AFK_SUDO_LEDGER  ledger path (default /var/log/himmel/afk-sudo.jsonl; a test seam)
#
# It keeps rows with event=run, kind=run, result=ran and groups them by
# (run_as, argv[0] realpath, argv shape). The shape keeps flags and fixed words;
# a decimal integer becomes <int> and a path under $HOME becomes <path under $HOME>.
# A group seen twice or more is a suggestion (with count, last use, exit codes);
# a group seen once is listed as "seen once, not suggested".
# ponytail: only <int> and <path under $HOME> fold into slots, a varying plain word
#   stays its own group (an allowlist must not widen on a word), upgrade path is a
#   <word> slot once the 8066 class matcher can express one.
set -uo pipefail

since="30d"
while [ $# -gt 0 ]; do
    case "$1" in
        --since) [ $# -ge 2 ] || { echo "ERR suggest-allowlist: --since needs a value" >&2; exit 2; }; since="$2"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "ERR suggest-allowlist: unknown argument '$1' (usage: [--since 30d|12h])" >&2; exit 2 ;;
    esac
done
if ! [[ "$since" =~ ^[0-9]+[dh]$ ]]; then
    echo "ERR suggest-allowlist: --since must look like 30d or 12h, got '$since'" >&2; exit 2
fi
n="${since%[dh]}"
if [ "${since: -1}" = d ]; then secs=$(( 10#$n * 86400 )); else secs=$(( 10#$n * 3600 )); fi

ledger="${AFK_SUDO_LEDGER:-/var/log/himmel/afk-sudo.jsonl}"
if [ ! -e "$ledger" ]; then
    echo "suggest-allowlist: no ledger at $ledger (the afk-sudo helper is not installed here)"
    exit 0
fi

# shellcheck disable=SC2016  # a python program
python3 -I -c '
import calendar, json, os, re, sys, time
ledger, secs, home = sys.argv[1], int(sys.argv[2]), sys.argv[3]
FIXED_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
since = time.time() - secs

def resolve(argv0):
    if "/" in argv0:
        return os.path.realpath(argv0)
    for d in FIXED_PATH.split(":"):
        c = os.path.join(d, argv0)
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.realpath(c)
    return argv0

def slot(a):
    if re.fullmatch(r"[0-9]+", a):
        return "<int>"
    if a == home or a.startswith(home.rstrip("/") + "/"):
        return "<path under $HOME>"
    return a

groups, n = {}, 0
try:
    fh = open(ledger)
except OSError:
    print("suggest-allowlist: ledger unreadable at %s" % ledger)
    sys.exit(0)
for line in fh:
    try:
        r = json.loads(line)
        if (r.get("event"), r.get("kind"), r.get("result")) != ("run", "run", "ran"):
            continue
        argv, run_as = r["argv"], r["run_as"]
        if not (isinstance(argv, list) and argv and all(isinstance(a, str) for a in argv) and isinstance(run_as, str)):
            continue
        if calendar.timegm(time.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ")) < since:
            continue
    except (ValueError, KeyError, TypeError, AttributeError):
        continue
    n += 1
    shaped = [resolve(argv[0])] + [slot(a) for a in argv[1:]]
    g = groups.setdefault((run_as, tuple(shaped)), {"count": 0, "last": "", "exits": set()})
    g["count"] += 1
    g["last"] = max(g["last"], r["ts"])
    if isinstance(r.get("exit"), int):
        g["exits"].add(r["exit"])

print("suggest-allowlist: %s, %d run(s) read in the window; nothing is written" % (ledger, n))
if not n:
    print("no run in the window")
    sys.exit(0)
many = sorted(((k, g) for k, g in groups.items() if g["count"] >= 2), key=lambda kg: (-kg[1]["count"], kg[0]))
once = sorted(((k, g) for k, g in groups.items() if g["count"] == 1), key=lambda kg: kg[0])
print()
print("suggested (seen 2+ times; paste what you want into classes in /etc/himmel/afk-sudo.json with sudoedit, then set mode back to allowlist):")
if not many:
    print("(none)")
for (run_as, shaped), g in many:
    words = [w for w in shaped if not w.startswith("<")]
    name = re.sub(r"[^a-z0-9]+", "-", " ".join([os.path.basename(shaped[0])] + words[1:3]).lower()).strip("-")
    print(json.dumps({"class": name, "def": {"argv": list(shaped), "run_as": run_as}, "count": g["count"],
                      "last": g["last"], "exits": sorted(g["exits"])}))
print()
print("seen once, not suggested:")
if not once:
    print("(none)")
for (run_as, shaped), g in once:
    print("- %s %s (last %s, exit %s)" % (run_as, " ".join(shaped), g["last"], ",".join(map(str, sorted(g["exits"]))) or "?"))
' "$ledger" "$secs" "${HOME:-/}"
