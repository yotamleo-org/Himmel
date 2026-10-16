#!/usr/bin/env bash
# Tests for parity-measure.py: the harness can tell MATCH, GAP and
# OVER-DENY apart, classifies without executing any payload, and runs the full
# corpus against the live hook chain. Hermetic: throwaway HOME and repos, no
# model call, no network.
# shellcheck disable=SC2015  # `cond && ok || fail`: ok() cannot fail
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${1:-$SCRIPT_DIR/parity-measure.py}"   # $1: a mutated copy, to prove the test goes RED
PY="$(command -v python3 || command -v python)" || { echo "SKIP: no python"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: no git"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/parity-measure.XXXXXX")" || exit 1; trap 'rm -rf "$TMP"' EXIT
fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
parity_of() {  # parity_of <json file> <row id> -> MATCH|GAP|OVER-DENY
  "$PY" -I -c 'import json,sys
rows = json.load(open(sys.argv[1]))
print(next((r["parity"] for r in rows if r["id"] == sys.argv[2]), "MISSING"))' "$1" "$2"
}

# Stub guards: one allows everything, one denies everything.
printf 'import sys\nsys.stdin.read()\nprint("{}")\n' > "$TMP/allow-guard.py"
printf 'import sys,json\nsys.stdin.read()\nprint(json.dumps({"decision":"block","reason":"stub"}))\n' > "$TMP/deny-guard.py"

# Fixture corpus: a secret read (the hook chain denies it) and a plain ls (it
# allows it). The third row would delete a sentinel if a payload were ever run.
SENT="$TMP/sentinel"; : > "$SENT"
"$PY" -I - "$TMP/corpus.json" "$SENT" <<'PY'
import json, sys
rows = [
    ["secret-read", "block-read-secrets", "secret-read", "Read", {"file_path": "{FEAT}/.env"}, "feat"],
    ["plain-ls", "benign", "benign", "Bash", {"command": "ls"}, "feat"],
    ["would-delete", "benign", "benign", "Bash", {"command": "rm -f " + sys.argv[2]}, "feat"],
]
json.dump(rows, open(sys.argv[1], "w"))
PY

echo "== classify(): the three verdicts =="
"$PY" -I -c 'import importlib.util,sys
s = importlib.util.spec_from_file_location("pm", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.exit(0 if (m.classify(True, True), m.classify(False, False), m.classify(True, False), m.classify(False, True)) == ("MATCH", "MATCH", "GAP", "OVER-DENY") else 1)' "$TOOL" \
  && ok "MATCH/GAP/OVER-DENY mapping" || fail "classify mapping"

echo "== known-GAP and known-MATCH fixture rows are told apart =="
"$PY" -I "$TOOL" --corpus "$TMP/corpus.json" --guard "$TMP/allow-guard.py" --format json > "$TMP/allow.json"
[ "$(parity_of "$TMP/allow.json" secret-read)" = GAP ]    && ok "allow-all guard: denied secret read is a GAP" || fail "secret-read not GAP under allow-all guard"
[ "$(parity_of "$TMP/allow.json" plain-ls)" = MATCH ]     && ok "allow-all guard: ls is a MATCH" || fail "plain-ls not MATCH under allow-all guard"
"$PY" -I "$TOOL" --corpus "$TMP/corpus.json" --guard "$TMP/deny-guard.py" --format json > "$TMP/deny.json"
[ "$(parity_of "$TMP/deny.json" secret-read)" = MATCH ]   && ok "deny-all guard: secret read is a MATCH" || fail "secret-read not MATCH under deny-all guard"
[ "$(parity_of "$TMP/deny.json" plain-ls)" = OVER-DENY ]  && ok "deny-all guard: ls is an OVER-DENY" || fail "plain-ls not OVER-DENY under deny-all guard"

echo "== classification never executes a payload =="
[ -f "$SENT" ] && ok "sentinel the fixture command would delete is intact" || fail "payload was executed (sentinel deleted)"

echo "== full corpus against the live chain and parity_guard.py =="
"$PY" -I "$TOOL" --format json > "$TMP/full.json" 2> "$TMP/full.err"
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || fail "full run exited $rc: $(head -c 300 "$TMP/full.err")"
"$PY" -I - "$TMP/full.json" <<'PY' && ok "corpus well-formed, no chain unwired, benign rows MATCH" || fail "full-corpus invariants"
import json, sys
rows = json.load(open(sys.argv[1]))
assert len(rows) >= 40, len(rows)
assert all(r["parity"] in ("MATCH", "GAP", "OVER-DENY") for r in rows)
assert not any(r["cc_by"] == "(no chain wired)" for r in rows), "a tool matched no settings.json chain"
assert not any(r["hermes_by"].startswith("guard error") for r in rows), "parity_guard errored"
benign = [r for r in rows if r["class"] == "benign"]
assert benign and all(r["parity"] == "MATCH" for r in benign), [r["id"] for r in benign if r["parity"] != "MATCH"]
byid = {r["id"]: r["parity"] for r in rows}
for rid in ("self-bash-claude-settings", "secret-env-dump", "secret-transcript-read"):
    assert byid.get(rid) == "MATCH", (rid, byid.get(rid))
# the harness must see both a CC deny and a hermes deny, or it measured nothing
assert any(r["cc"] == "deny" for r in rows) and any(r["hermes"] == "deny" for r in rows)
PY

if [ "$fails" -ne 0 ]; then echo "FAILED: $fails" >&2; exit 1; fi
echo "PASS"
