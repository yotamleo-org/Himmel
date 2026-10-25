---
key: "HIMMEL-6125"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6213"
created: "2026-10-17T16:09:30.678+0200"
updated: "2026-10-18T00:50:33.464+0200"
resolution: "Done"
resolved: "2026-10-18T00:48:05.804+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6125: qmd query expansion (generate) on OpenRouter for every non-salus collection, salus local-only, with a retrieval eval

## Description

OPERATOR ruling 2026-10-17 ~17:50: "allow generate on OpenRouter except salus, this should increase our retrieval score as well." Found by N2541 (HIMMEL-6123): the qmd fork already supports a remote generate (OpenAiLLM.generate via /chat/completions, expandQuery), but the egress gate refuses a gener
2. qmd gate (scripts/qmd/qmd-jina-gate.mjs or the gate that pins models): accept a generate role pinned to ONE chosen OpenRouter model; still refuse unpinned models, unknown hosts, keys in yaml.
3. Pick the model by eval: run scripts/eval/qmd-quality on the local GGUF (baseline) vs 2-3 OpenRouter candidates (e.g. google/gemini-2.5-flash-lite; paid only, EEA terms) on the same fixtures: recall@k, MRR, latency, cost per 1k queries.
Files: scripts/guardrails/egress-matrix.json + test-egress-matrix.mjs, the qmd model gate under scripts/qmd/, docs/internals/egress-matrix.md, scripts/eval/qmd-quality. Security-relevant (egress policy): adversarial judge before GO.
PR #3019 (yotamleo/Himmel) merged @ f6bf3be9f65a6969fcab895abe08489e3a22f1dc. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
