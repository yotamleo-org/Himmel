# Worker preface section — JUDGE-REQUEST

Read on demand: `worker-preface.md` names this file where the Ship line asks for `JUDGE-REQUEST <pr> <head>`.

## One channel per lane

Send the chief `JUDGE-REQUEST <pr> <head>` once per head:

- native lane: `SendMessage` to the chief.
- `HIMMEL_BUS_NAME` set (claudex, openrouter): the himmel-bus `send` tool.
- otherwise: send nothing; the chief dispatches the judge at READY.

Send it again for the same head only after a chief succession or when the chief asks.
A later push needs a fresh judge and GO.
