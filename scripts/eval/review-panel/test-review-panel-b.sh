#!/usr/bin/env bash
# scripts/eval/review-panel/test-review-panel-b.sh - the shipped real-escape corpus: lint --min-real.
# Setup and helpers are shared in test_review_panel_lib.sh. No model call, no codex, no live ledger.
# shellcheck disable=SC2034,SC2153,SC2154  # state and helpers are shared through the sourced lib
set -u
# shellcheck source=test_review_panel_lib.sh
. "$(cd "$(dirname "$0")" && pwd)/test_review_panel_lib.sh"

# --- the shipped real-escape corpus -----------------------------------------------------------
# Thirty review escapes frozen from merged history, each with a clean twin and an intent file.
n_seeded=$(find "$FIX_ALL" -name 'real-*.patch' ! -name 'real-*-clean.patch' | wc -l | tr -d ' ')
n_clean=$(find "$FIX_ALL" -name 'real-*-clean.patch' | wc -l | tr -d ' ')
eq "real corpus: 30 escapes and 30 clean twins" "$n_seeded:$n_clean" "30:30"
eq "real corpus: every case carries an intent file" "$(find "$FIX_ALL" -name 'real-*.intent.md' | wc -l | tr -d ' ')" "60"
# --min-real counts case files, so 30 pairs are 60 real-* cases.
out=$(python3 "$SCORE" lint --fixtures "$FIX_ALL" --key "$KEY_ALL" --min-real 60 2>&1); rc=$?
eq "real corpus: lint --min-real 60 (30 pairs) passes on the shipped set" "$rc" "0"
[ "$rc" = 0 ] || echo "$out"
eq "real corpus: classes of the escapes, at least 4 cross-file and 4 spec-miss" \
  "$(python3 -c 'import collections, json, sys
n = collections.Counter(d["class"] for k, v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("real-") for d in v["defects"])
print(" ".join("%s:%d" % kv for kv in sorted(n.items())))' "$KEY_ALL")" \
  "cross-file:4 fail-open:5 logic:8 quoting:2 spec-miss:4 test-cannot-fail:5 toctou:2"
eq "real corpus: an open and a sealed half of 15 pairs each" \
  "$(python3 -c 'import collections, json, sys
n = collections.Counter(v["split"] for k, v in json.load(open(sys.argv[1]))["cases"].items() if k.startswith("real-") and v["kind"] == "seeded")
print(" ".join("%s:%d" % kv for kv in sorted(n.items())))' "$KEY_ALL")" "open:15 sealed:15"
eq "real corpus: each class has an open and a sealed pair" \
  "$(python3 -c 'import collections, json, sys
h = collections.defaultdict(set)
for k, v in json.load(open(sys.argv[1]))["cases"].items():
    if k.startswith("real-") and v["kind"] == "seeded":
        h[v["defects"][0]["class"]].add(v["split"])
print(" ".join("%s:%s" % (c, "+".join(sorted(s))) for c, s in sorted(h.items())))' "$KEY_ALL")" \
  "cross-file:open+sealed fail-open:open+sealed logic:open+sealed quoting:open+sealed spec-miss:open+sealed test-cannot-fail:open+sealed toctou:open+sealed"
# real-007 is the LT-j4386-1 escape: a bus reader and its writers changed in one diff.
eq "real corpus: real-007 changes the bus reader and the chief writers together" \
  "$(grep -cE '^diff --git a/(marketplace/plugins/himmel-bus/lib/identity\.mjs|scripts/handover/chief/chief\.sh) ' "$FIX_ALL/real-007.patch")" "2"

echo
echo "test-review-panel-b: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
