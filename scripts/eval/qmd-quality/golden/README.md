# qmd golden set

`himmel.jsonl` is the repo-safe golden set for `qmd-quality.sh`: 200 queries
(h001-h200), each labelled with the himmel doc(s) that answer it. Only public
himmel docs are named; nothing from the luna vault, the Jira mirror or the
roadmap collection. A set that names private docs stays outside the repo and is
passed with `--golden` / `QMD_QUALITY_GOLDEN`.

Row shape: `{id, query, lex, collections, expect}`. `query` is what a person
asks (half are paraphrases that share few words with the doc); `lex` is the
keyword form the lex mode searches; `expect` is `himmel/<path>`, every label
checked against the file in the repo and the qmd index. A `lex` term never
starts with `-` (qmd reads it as a negation).

`qmd-quality.sh` refuses a set under 150 queries (`QMD_QUALITY_MIN_QUERIES`).
`fixtures/golden.jsonl` is the 3-row shape fixture the suite uses; it is not a
quality measure.

## Baseline (2026-10-23, scope golden, 200 queries)

Index: station index, embed `openai:qwen/qwen3-embedding-8b`, rerank
`openai:cohere/rerank-4-fast`. The index was INCOMPLETE (1242 documents still
awaiting embeddings), so a vec or hybrid miss is unverified, not proof the doc
is unreachable. 95% bootstrap CIs; one eval-runs ledger row per mode.

| mode | hit@1 | hit@5 | MRR |
|---|---|---|---|
| lex | 0.795 [0.740, 0.850] | 0.930 [0.895, 0.965] | 0.856 [0.816, 0.896] |
| vec | 0.790 [0.735, 0.845] | 0.925 [0.885, 0.960] | 0.848 [0.807, 0.889] |
| hybrid | 0.840 [0.790, 0.890] | 0.955 [0.925, 0.980] | 0.889 [0.852, 0.926] |
| hybrid-rerank | 0.840 [0.790, 0.890] | 0.965 [0.935, 0.985] | 0.898 [0.863, 0.932] |

The intervals overlap across modes, so these 200 queries cannot rank the modes
against each other; they catch a regression larger than the interval width.
