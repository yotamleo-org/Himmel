# relay-cost eval

What does one relayed message cost, and does a cheaper way deliver it as correctly? (Operator
decision 158.) Four options over the same fixtures:

| option | what it is | model calls |
|---|---|---|
| `sonnet` | a stand-in for today's relay, not the relay session itself: one `claude -p` call (Sonnet 5.5, no tools, a short system prompt of the delivery rules) returns `{"to","message"}` for the command it is handed | 9 |
| `haiku` | the same call on Haiku 5.5 | 9 |
| `script` | no model. A succession relay runs the real `relay-batch.sh` with no bus identity, so it prints its `SENDMESSAGE` line; a GO or ruling goes through a recording stub of the bus send | 0 |
| `path` | no model. The chief's text is a file; the delivery is only `Read <path>` | 0 |

| path | what |
|---|---|
| `fixtures/messages.json` | 9 synthetic fixtures: succession relay, GO and ruling, three sizes each. `relay_cost.py gen` rewrites it |
| `relay_cost.py` | `gen`, `check`, `price`, `report`, `turn-price` (stdlib, no model call) |
| `run.sh` | runs the arms; one result file per (arm, fixture), so a stopped run resumes |
| `test-relay-cost.sh` | the suite: stub `claude`, stub preflight, negative controls; no model call |

## Fixtures

Synthetic. They are sized around a survey of what chief sessions send (38,972 `SendMessage` calls in
600 chief sessions, so chief sends, not the traffic a relay session carries): succession relays 21% of
messages (median 462 chars), GO 8% (median 365), rulings 5% (median 580). Only those counts were kept; no transcript text is read into or committed to this repo.
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
difference. `cost_eq_cold` is the call as measured. `cost_eq_warm` is derived, not measured: it re-prices the
cache-creation tokens of the same call as cache reads, to approximate a long-lived relay session that
already holds the prefix. `turn-price` gives the receiver-side cost of the path option: one extra
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

Run 2026-11-02: 18 billed calls (Sonnet 9, Haiku 9) plus the two arms that cost nothing, over synthetic
fixtures. The raw rows (36 result files and the 18 model streams) are kept in
`~/.himmel/eval/relay-cost/2026-11-02/`.

| option | messages | pass rate | cost-eq cold/msg | cost-eq warm/msg (derived) | USD/msg | warm vs sonnet | USD vs sonnet |
|---|---|---|---|---|---|---|---|
| sonnet (stand-in) | 9 | 100% | 6810 | 2023 | 0.01986 | 100% | 100% |
| haiku | 9 | 100% | 9198 | 4386 | 0.00123 | 217% | 6% |
| script | 9 | 100% | 0 | 0 | 0.00000 | 0% | 0% |
| path | 9 | 100% | 0 | 0 | 0.00000 | 0% | 0% |

Per kind (succession, GO, ruling): every option passed 3 of 3 in each, so the pass rate does not separate
the options on these fixtures.

What the numbers are and are not:

- The `sonnet` row is a stand-in: a one-shot `claude -p` call with a short system prompt, not a live relay
  session. A real relay session carries a larger context, so its per-message cost is not measured here.
- The fixtures are sized from what chiefs send, not from the traffic a relay carries.
- `cost-eq warm` is derived (cache-creation tokens re-priced as cache reads), not measured on a warm session.
- Haiku is 6% of Sonnet in USD and 217% in warm cost-eq. The cause is output tokens, not the prefix: both
  models wrote about 4,100 cache-creation tokens per call, but Haiku wrote a median of 690 output tokens
  against Sonnet's 255, and output is weighted 5.
- `script` and `path` cost no relay model call, but they do not remove the chief's own turn that writes the
  message, so "zero" is the relay's share only.
- The `path` option is free for the sender but costs the receiver one extra `Read` turn, median 16,728
  cost-eq (median cache read 167,280 over 5,118 worker turns, `relay_cost.py turn-price`), about 8 times a
  warm Sonnet message here. It is not cheaper end to end.

The `script` proof is partial:

- A GO or ruling goes through a recording stub of the bus send whose input equals the expected text, so it
  checks the harness, not the real `bus send`.
- A succession relay runs the real `relay-batch.sh` with no bus identity, so it takes the branch that prints
  its `SENDMESSAGE` line, not the bus-record branch.
- The `path` arm compares the expected text with itself, so it shows only that a file can carry the bytes.

**Decision: a scripted delivery is no worse than a Sonnet relay call on delivery fidelity for these
fixtures, and needs no relay model call, so it is the option to build.** It is not proven cheaper end to end,
and the real bus send to a fixture receiver is not exercised. That remaining proof, and the build, belong to
the follow-up ticket. Negative controls: a stub model that paraphrases fails all 9 through `run.sh`; a wrong
target, a changed word, a truncated message, appended text and another worker's token each FAIL in
`test-relay-cost.sh`, as do a path message that does not name the file, differing file bytes and an
unreadable file.
