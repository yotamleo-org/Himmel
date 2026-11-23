# Worker preface section — JUDGE-REQUEST

Read on demand: `worker-preface.md` names this file where the Ship line asks for `JUDGE-REQUEST <pr> <head>`.

## One channel per lane

Send the chief `JUDGE-REQUEST <pr> <head>` once per head:

- native lane: `SendMessage` to the chief.
- `HIMMEL_BUS_NAME` set (claudex, openrouter): the himmel-bus `send` tool.
- otherwise: send nothing; the chief dispatches the judge at READY.

A worker off the native lane also writes every request or question as a marker bullet carrying its word (`- HH:MM LIVE JUDGE-REQUEST <pr> <head>`, `LIVE PUSH-REQUEST …`, `LIVE QUESTION …`): the chief's waiter wakes once per such bullet, and a request in any other spelling wakes nothing.

Send it again for the same head only after a chief succession or when the chief asks.
A later push needs a fresh judge and GO.
