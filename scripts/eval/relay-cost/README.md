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

Run 2026-11-02: 18 billed calls (Sonnet 9, Haiku 9) plus the two unbilled arms; fixtures are synthetic.

| option | messages | pass rate | cost-eq cold/msg | cost-eq warm/msg | USD/msg | warm vs sonnet | USD vs sonnet |
|---|---|---|---|---|---|---|---|
| sonnet | 9 | 100% | 6810 | 2023 | 0.01986 | 100% | 100% |
| haiku | 9 | 100% | 9198 | 4386 | 0.00123 | 217% | 6% |
| script | 9 | 100% | 0 | 0 | 0.00000 | 0% | 0% |
| path | 9 | 100% | 0 | 0 | 0.00000 | 0% | 0% |

Per kind (succession, GO, ruling): every option passed 3 of 3 in each. The path option is free on the sender
side but costs the receiver one extra `Read` turn, median 16,728 cost-eq (median cache read 167,280 over
5,118 worker turns, `relay_cost.py turn-price`). That is about 8 times the warm Sonnet relay per message, so
`path` is not cheaper end to end; an inline message is only about 115 to 290 tokens.

Haiku is 6% of Sonnet in USD but 217% in warm cost-eq, because a cold Haiku call reads its whole prefix
uncached; priced in dollars it is cheaper, and it held 9 of 9.

**Decision: `script`, no model.** It is the cheapest option that holds (100%, zero model cost). A succession
relay is the real `relay-batch.sh`; a GO or ruling is the chief's own text sent verbatim, which needs no
relaying session at all. The negative control that proves the check can fail: a stub model that paraphrases
fails all 9 through `run.sh`, and a wrong target, a changed word, a truncated message, appended text and
another worker's token each FAIL in `test-relay-cost.sh`.

Limit: the fixtures test delivery fidelity of text the chief already wrote. They do not test the judgment a
relay session adds (classifying an event as an escalation, polling a leg doc), so this result covers the
delivery step only.
