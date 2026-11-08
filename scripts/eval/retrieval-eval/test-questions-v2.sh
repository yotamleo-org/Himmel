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

V1_SHA256="9cb6f6b51d941a0268a8eabc43b5e784de4ff6ffc230b077060f9b6b7339e7b4"
eq "v1 is byte-identical to the frozen bank" "$V1_SHA256" "$(sha256sum "$V1" | cut -d' ' -f1)"

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

has() {
    local id="$1" field="$2" path="$3"
    python3 -I - "$V2" "$id" "$field" "$path" <<'PY'
import json, sys
rows = {json.loads(l)["id"]: json.loads(l) for l in open(sys.argv[1]) if l.strip()}
print("yes" if sys.argv[4] in rows[sys.argv[2]].get(sys.argv[3], []) else "no")
PY
}
eq "q03 gold has docs/handover/running-a-chief.md" yes "$(has q03 gold docs/handover/running-a-chief.md)"
for p in docs/handover/worker-preface.md docs/architecture.md; do eq "q03 gold1 has $p" yes "$(has q03 gold1 "$p")"; done
eq "q08 gold has docs/internals/enforcement.md" yes "$(has q08 gold docs/internals/enforcement.md)"
eq "q08 gold1 no longer has the memory-staleness doc" no "$(has q08 gold1 docs/internals/context-architecture.md)"
for p in docs/internals/ponytail-convention.md AGENTS.md CLAUDE.md docs/glossary.md; do eq "q13 gold has $p" yes "$(has q13 gold "$p")"; done
eq "q25 gold has the consumer scripts/check-plugin-drift.sh" yes "$(has q25 gold scripts/check-plugin-drift.sh)"
for p in scripts/test-check-plugin-drift.sh scripts/lanes/tests/plugin-profiles.test.mjs; do eq "q25 gold1 has $p" yes "$(has q25 gold1 "$p")"; done
for p in scripts/handover/librarian-cadence.sh scripts/luna-vitals/connectors/pull-cadence.sh scripts/luna/graphmap-cadence.sh \
    scripts/luna/vault-stall-cadence.sh scripts/upstreams/upstream-watch-cadence.sh; do
    eq "q30 gold has the caller $p" yes "$(has q30 gold "$p")"
done

if [ "$fails" -ne 0 ]; then printf '%s row(s) failed\n' "$fails"; exit 1; fi
printf 'all rows passed\n'
