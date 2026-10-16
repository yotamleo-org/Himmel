# Console section — board and roadmap tracker (ACTION ZERO step 12)

Read on demand from `console-template.md` step 12. `<kit>` is the kit path in step 7. Moved verbatim from the template.

12. **Render and publish the console board**. The board is a
    generated HTML page — fleet N/cap with idle slots, every leg's phase
    (LIVE → READY-TO-OPEN → PR open → READY → MERGED → WRAPPED, plus its own
    `WRAPPED, window still open` when a WRAPPED leg's claude window is still
    alive — derived from an independent process census, since tick.sh's `procs=`
    only counts HELD legs), what needs you, epic merged/total, the operator's
    open decisions — so the operator sees progress and convergence without
    asking. The published page shows live work only: WRAPPED and MERGED legs
    and the merged PRs are written to `console-board-archive.html` beside it
    (local, never published, one item per line — `grep` it for a ticket key,
    PR or last bullet), so a successor republishes a small page. Render it with `node "<kit>/board.mjs" --doc "<this file>" --changed`: `--changed` re-renders and prints `CHANGED <path>` or
    `UNCHANGED <path>` instead of the bare path, so you know from one line
    whether the render moved after a dispatch, verdict, GO, MERGED or WRAPPED
    (nonces and lock tokens are redacted from the file either way). Rendering
    never publishes — on `CHANGED`, publish that file with the `Artifact` tool
    yourself and record the artifact URL on the `board:` line of `## Live
    state` — `console.sh next` carries it to your successor, who updates the
    same artifact instead of minting a new one. **A successor's FIRST publish
    to a carried `board:` URL must `Artifact read` it before it `Artifact
    publish`es** — the tool refuses a publish to an artifact this session
    has not viewed. The tick's `board=` field is your reminder:
    `board=MISSING` (never rendered) or `board=STALE:<age>` (the state moved
    since the last render) means re-run it now. `board=ok` proves only that the
    LOCAL file matches the current state; republishing the artifact stays your
    step.

    **Keep the roadmap tracker current** (only when `## Live state`
    has a `tracker:` URL, else skip). On every MERGED and WRAPPED, and whenever
    the tick reads `tracker=STALE:<age>` or `tracker=MISSING`: refresh the Jira
    mirror (`node <primary>/scripts/jira/dist/index.js mirror`) and the version
    release state (`node <primary>/scripts/jira/dist/index.js versions` redirected to
    `<mirror-dir>.versions.tsv`, i.e. `~/.himmel/state/jira-mirror/HIMMEL.versions.tsv`;
    without it the page says "release state unknown"), re-render with
    `python3 "<kit>/tracker.py" --plan-dir <plan dir> --out <handover bucket>/roadmap-tracker.html`
    plus the vault-map cache argument (`tracker.py --help` names every
    argument; `--out` and `--plan-dir` must be the paths the tick reads, so the
    render then reports `tracker=ok`), and republish that file to the `tracker:` URL with the `Artifact` tool. A
    successor's FIRST publish to a carried `tracker:` URL must `Artifact read`
    it first, exactly as for `board:`. The vault-map cache refreshes
    incrementally (only keys that are missing or older than 7 days), so a render
    is cheap.
