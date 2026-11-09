#!/usr/bin/env bash
# test-tasks.sh -- B8 of the RAG pilot: the 40-task schema/seal check and the local question
# miner, on a synthetic fixture world (fixtures/tasks/build.py). No real task, no real
# transcript, no search.
#
# Platform guard: any bash with python3 and git.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TS="$HERE/task-schema.py"
MQ="$HERE/mine-questions.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-tasks.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }

python3 -I "$HERE/fixtures/tasks/build.py" "$W/fx"
M=(--manifest himmel="$W/fx/himmel.json" --manifest luna="$W/fx/luna.json")

python3 -I "$TS" seal "$W/fx/bank.jsonl" "${M[@]}" --out "$W/seal.json" > "$W/seal.out" 2>&1
eq "seal: the valid 40-task fixture bank seals" 0 "$?"
eq "seal: all 40 ids are sealed" 40 "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["ids"]))' "$W/seal.json")"
has "seal: the public summary prints kind counts" '"luna_lookup": 6' "$(cat "$W/seal.out")"
has "seal: the public summary prints discovery-method counts" '"discovery"' "$(cat "$W/seal.out")"
eq "seal: the public summary prints no question text" 0 "$(grep -c 'Fixture question' "$W/seal.out")"
eq "seal: the seal file is private (mode 600)" 600 "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$W/seal.json")"

bad() { # <label> <expected reason fragment> <python mutation of list `b`>
  python3 -I - "$W/fx/bank.jsonl" "$W/bad.jsonl" "$3" <<'EOF'
import json, sys
b = [json.loads(l) for l in open(sys.argv[1])]
exec(sys.argv[3])
open(sys.argv[2], "w").write("".join(json.dumps(t) + "\n" for t in b))
EOF
  local out rc
  out=$(python3 -I "$TS" validate "$W/bad.jsonl" "${M[@]}" 2>&1); rc=$?
  eq "validate: $1 fails" 3 "$rc"
  has "validate: $1 names the reason" "$2" "$out"
}
bad "an unknown kind" "kind" 'b[0]["kind"] = "luna_trivia"'
bad "a wrong kind count" "kind counts" 'b[0]["kind"] = "luna_meaning"'
bad "an unknown half" "half" 'b[0]["half"] = "medium"'
bad "an unbalanced 21/19 split" "halves" 'b[1]["half"] = "real"; b[1]["provenance"]["method"] = "transcript"; b[1]["provenance"]["sampling_rule"] = "x"'
bad "a fact with four variants" "variants" 'b[0]["facts"][0]["variants"] = ["a", "b", "c", "d"]'
bad "four required facts" "facts" 'b[0]["facts"] = [dict(b[0]["facts"][0]) for _ in range(4)]'
bad "a reused source file" "reused source" 'b[1]["files"] = b[0]["files"]; b[1]["facts"][0]["files"] = b[0]["facts"][0]["files"]'
bad "a source missing at the pin" "not at the pin" 'b[0]["files"][0]["path"] = "notes/gone.md"; b[0]["facts"][0]["files"] = ["notes/gone.md"]'
bad "a handovers source" "excluded" 'b[0]["files"][0]["path"] = "handovers/x.md"; b[0]["facts"][0]["files"] = ["handovers/x.md"]'
bad "a pilot-dir source" "excluded" 'b[20]["files"][0]["path"] = "scripts/eval/retrieval-eval/pilot/x.md"; b[20]["facts"][0]["files"] = ["scripts/eval/retrieval-eval/pilot/x.md"]'
bad "a source stratum that does not match the files" "stratum" 'b[14]["stratum"] = "code"'
bad "a missing provenance" "provenance" 'del b[0]["provenance"]'
bad "a real task without its sampling rule" "sampling_rule" 'del b[0]["provenance"]["sampling_rule"]'
bad "a fact file that is not one of the task files" "fact file" 'b[0]["facts"][0]["files"] = ["notes/other.md"]'
bad "a two-file task with one file" "two_files" 'b[28]["files"] = b[28]["files"][:1]; b[28]["facts"][0]["files"] = [b[28]["files"][0]["path"]]; b[28]["stratum"] = "doc"'
bad "an answerable not-there task" "not_there" 'b[39]["answerability"] = "answerable"'
bad "a duplicate id" "duplicate id" 'b[1]["id"] = b[0]["id"]'
bad "a 41st task" "40 tasks" 'b.append(dict(b[0], id="t99"))'

# the local miner
python3 -I "$MQ" "$W/fx/sessions" --out "$W/mined.jsonl" --seed 7 --sample 2 > "$W/mine.out" 2>&1
eq "miner: mines the fixture sessions" 0 "$?"
eq "miner: keeps only distinct question-shaped user turns" 3 "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidates"])' "$W/mined.jsonl.summary.json")"
eq "miner: the seeded sample has the requested size" 2 "$(wc -l < "$W/mined.jsonl" | tr -d ' ')"
has "miner: each candidate keeps its transcript provenance" '"transcript_sha256"' "$(head -1 "$W/mined.jsonl")"
python3 -I "$MQ" "$W/fx/sessions" --out "$W/mined2.jsonl" --seed 7 --sample 2 >/dev/null 2>&1
eq "miner: the same seed draws the same sample" same "$(cmp -s "$W/mined.jsonl" "$W/mined2.jsonl" && echo same || echo differ)"
has "miner: the summary records the sampling rule" '"sampling_rule"' "$(cat "$W/mined.jsonl.summary.json")"
printf 'old\n' > "$W/wide.jsonl"; chmod 644 "$W/wide.jsonl"
python3 -I "$MQ" "$W/fx/sessions" --out "$W/wide.jsonl" --seed 7 --sample 2 >/dev/null 2>&1
eq "miner: an existing wider-moded output file is narrowed to 600" 600 "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$W/wide.jsonl")"
git -C "$W" init -q "$W/repo"
python3 -I "$MQ" "$W/fx/sessions" --out "$W/repo/mined.jsonl" --seed 7 --sample 2 >/dev/null 2>&1
eq "miner: refuses to write candidates into a git work tree" 3 "$?"
eq "miner: never imports a search tool" 0 "$(grep -c -E 'qmd|graphify|s-qmd' "$MQ")"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all task rows passed\n'
