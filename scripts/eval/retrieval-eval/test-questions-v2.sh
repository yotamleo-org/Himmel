#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
V1="$HERE/questions.jsonl"
V2="$HERE/questions-v2.jsonl"
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

V1_SHA256="adbc51f2a56fbd871aac16569b5ec7316e533d673226a1a23d02475a8ac46b4f"
v1_digest="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$V1")"
eq "v1 is byte-identical to the frozen bank" "$V1_SHA256" "$v1_digest"

if [ ! -f "$V2" ]; then
    fail "questions-v2.jsonl exists"
    printf '%s of the v2 rows failed\n' "$fails"
    exit 1
fi

n="$(python3 -I "$HERE/retrieval-eval.py" check --repo "$REPO_ROOT" --questions "$V2")"
eq "v2 checks clean: 75 rows, unique ids, every gold and gold1 file exists" "75 rc=0" "$n rc=$?"

out="$(python3 -I - "$V1" "$V2" <<'PY'
import json, sys

def load(p):
    return [(l, json.loads(l)) for l in open(p).read().splitlines() if l.strip()]

v1, v2 = load(sys.argv[1]), load(sys.argv[2])
changed = [b["id"] for (la, a), (lb, b) in zip(v1, v2) if la != lb]
ids_same = [a["id"] for _, a in v1] == [b["id"] for _, b in v2]
by2 = {b["id"]: b for _, b in v2}
kept = all(set(a["gold"]) <= set(by2[a["id"]]["gold"]) for _, a in v1)
fields = all({k: v for k, v in a.items() if k not in ("gold", "gold1")}
             == {k: v for k, v in by2[a["id"]].items() if k not in ("gold", "gold1")} for _, a in v1)
print(ids_same, sorted(changed), kept, fields)
PY
)"
eq "v2 changes exactly the five adjudicated rows, keeps every v1 gold path and every other field" \
    "True ['q03', 'q08', 'q13', 'q25', 'q30'] True True" "$out"

labels="$(python3 -I - "$V2" <<'PY'
import json, sys

expected = {
    "q03": (["docs/glossary.md", "docs/handover/running-a-chief.md"],
            ["docs/handover/worker-preface.md", "docs/architecture.md"]),
    "q08": (["CLAUDE.md", "AGENTS.md", "scripts/luna/qmd-staleness.sh", "docs/internals/enforcement.md"], []),
    "q13": (["docs/internals/code-comments.md", "CLAUDE.md", "AGENTS.md", "docs/glossary.md"], []),
    "q25": (["scripts/plugin-upstreams.json", "docs/tooling-catalog.md", "scripts/check-plugin-drift.sh"],
            ["scripts/test-check-plugin-drift.sh", "scripts/lanes/tests/plugin-profiles.test.mjs"]),
    "q30": (["scripts/lib/observability-registry.sh", "scripts/handover/librarian-cadence.sh",
             "scripts/luna-vitals/connectors/pull-cadence.sh", "scripts/luna/graphmap-cadence.sh",
             "scripts/luna/vault-stall-cadence.sh", "scripts/upstreams/upstream-watch-cadence.sh"], []),
}
rows = {json.loads(l)["id"]: json.loads(l) for l in open(sys.argv[1]) if l.strip()}
bad = [q for q, (gold, gold1) in expected.items()
       if (rows[q]["gold"], rows[q].get("gold1", [])) != (gold, gold1)]
print("ok" if not bad else "differs: " + ",".join(bad))
PY
)"
eq "the five adjudicated rows carry exactly the expected gold and gold1 lists" "ok" "$labels"

if [ "$fails" -ne 0 ]; then printf '%s row(s) failed\n' "$fails"; exit 1; fi
printf 'all rows passed\n'
