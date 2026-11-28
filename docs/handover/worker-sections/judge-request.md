# Worker preface section — JUDGE-REQUEST

Read on demand: `worker-preface.md` names this file where the Ship line asks for `JUDGE-REQUEST <pr> <head>`.

## One channel per lane

Send the chief `JUDGE-REQUEST <pr> <head>` once per head:

- native lane: `SendMessage` to the chief, and write `JUDGE-REQUEST <pr> <head>` in the bullet that records the request (`- HH:MM LIVE — … JUDGE-REQUEST <pr> <head> sent …`, the full 40-hex head): the judge desk's queue (`judge-queue.sh`) reads only that pair.
- `HIMMEL_BUS_NAME` set (claudex, openrouter): the himmel-bus `send` tool.
- a T3 thread (a `t3` row in the chief's fleet manifest): send no message; write the marker bullet only, with the `append-results.sh` command your brief or bind notice gave you.
- otherwise: send nothing; the chief dispatches the judge at READY.

A worker off the native lane also writes every request or question as a marker bullet carrying its word (`- HH:MM LIVE JUDGE-REQUEST <pr> <head>`, `LIVE PUSH-REQUEST …`, `LIVE QUESTION …`). The chief's waiter reads only your newest marker bullet, so it wakes once for the request only while that bullet is still your newest. Write no other marker bullet until the chief answers. A request in any other spelling wakes nothing.

Send it again for the same head only after a chief succession or when the chief asks.
A later push needs a fresh judge and GO.

The judge desk's own loop (`wait`, `next`, `claim`, `record`, `draft-go`) is `scripts/handover/chief-kit/judge-desk.sh`, which reads the queue `judge-queue.sh` fills; a worker never calls it.
