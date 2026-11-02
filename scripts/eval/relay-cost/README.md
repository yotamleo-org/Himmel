# relay-cost eval

What does one relayed message cost, and does a cheaper way deliver it as correctly? (HIMMEL-6992,
operator decision 158.) Four options over the same fixtures:

| option | what it is | model calls |
|---|---|---|
| `sonnet` | today's relay: a Sonnet 5.5 session returns `{"to","message"}` for the command it is handed | 9 |
| `haiku` | the same prompt on Haiku 5.5 | 9 |
| `script` | no model. A succession relay is the real `relay-batch.sh` (its `SENDMESSAGE` line); a GO or ruling is a verbatim `bus send` of the chief's text | 0 |
| `path` | no model. The chief's text is a file; the delivery is only `Read <path>` | 0 |

| path | what |
|---|---|
| `fixtures/messages.json` | 9 synthetic fixtures: succession relay, GO and ruling, three sizes each. `relay_cost.py gen` rewrites it |
| `relay_cost.py` | `gen`, `check`, `price`, `report`, `turn-price` (stdlib, no model call) |
| `run.sh` | runs the arms; one result file per (arm, fixture), so a stopped run resumes |
| `test-relay-cost.sh` | the suite: stub `claude`, stub preflight, negative controls; no model call |

## Fixtures

Synthetic. They are sized around a survey of real chief to worker traffic (38,972 `SendMessage` calls in
600 chief sessions): succession relays 21% of messages (median 462 chars), GO 8% (median 365), rulings 5%
(median 580). Only those counts were kept; no transcript text is read into or committed to this repo.
A succession fixture expects the exact text `relay-batch.sh` prints; GO and ruling fixtures expect the
chief's text byte for byte.

## Correctness check

A delivery passes only if it went to the right session and its message equals the expected text
(trailing newlines ignored). The path arm instead needs a message that names the file and a file whose
bytes equal the expected text. Negative control: in `test-relay-cost.sh` a wrong target, a changed word,
a truncated message, appended text and another worker's token each FAIL, and through `run.sh` a stub
model that paraphrases fails all 9.

## Price

`claude -p --output-format stream-json` usage, priced with the table of `handover-cost.py` (input 1,
cache read 0.1, cache write 1.25, output 5 input-equivalent tokens) and `total_cost_usd` for the tier
difference. `cost_eq_cold` is the call as measured. `cost_eq_warm` prices the whole prefix as a cache read,
as in a long-lived relay session. `turn-price` gives the receiver-side cost of the path option: one extra
`Read` turn of a worker, priced from the median cache read of 5,118 recent worker turns.

## Running

```bash
python3 scripts/eval/relay-cost/relay_cost.py gen --out scripts/eval/relay-cost/fixtures/messages.json
bash scripts/eval/relay-cost/run.sh --out ~/.himmel/eval/relay-cost/<date> --arms script,path
HIMMEL_BILLED_OK=1 bash scripts/eval/relay-cost/run.sh --out ~/.himmel/eval/relay-cost/<date> --arms sonnet,haiku
python3 scripts/eval/relay-cost/relay_cost.py report --runs ~/.himmel/eval/relay-cost/<date> --fixtures scripts/eval/relay-cost/fixtures/messages.json
```

The model arms are billed: `HIMMEL_BILLED_OK=1`, `bank-preflight` must print `PROCEED` before each call, and
`--max-calls` (default 20) caps the run.

## Result

(filled in after the billed run)
