# The himmel UI surfaces

himmel has no hosted UI. Three surfaces exist, all local, all read-only, and
each is started by a command you run yourself. If a user asks "the himmel UI",
they almost always mean the first one.

| Surface | What it is | Start it | Needs |
|---|---|---|---|
| Config console | One local web app: Config, Health, Tool health, Fleet, Roadmap pages and the AG-UI run view | `node scripts/himmelctl/bin.js ui` | `bun`, a terminal outside Claude |
| Console board | One generated HTML page: the fleet, each worker session's phase, what needs the supervisor session | `node scripts/handover/console-kit/board.mjs --doc <console doc> --changed` | a running himmel supervisor session |
| Roadmap tracker | One generated HTML page: release panels and a kanban by version | `python3 scripts/handover/console-kit/tracker.py --plan-dir <dir> --out <file>` | `python3`, the Jira mirror |

## The config console (`himmelctl ui`)

Serves on `127.0.0.1` only (loopback), behind a per-launch token. It reads the
same data as `himmelctl report --json`; it never writes your configuration.

```bash
node scripts/himmelctl/bin.js ui              # prints ONE URL carrying the token
node scripts/himmelctl/bin.js ui --port 0     # pick a free port
node scripts/himmelctl/bin.js ui --agui latest   # URL of the newest session's run page
node scripts/himmelctl/bin.js ui --agui <session-id>
```

- **Run it yourself, from a terminal outside Claude.** It refuses to start
  inside a Claude session; an agent cannot open it for you. The server runs in
  the foreground and exits on Ctrl-C or after 30 minutes idle.
- **The token** rides the URL fragment (`#t=<hex>`), so it is never sent in a
  request line. Open the printed URL as is; a new launch means a new token.
- **Always on.** `himmelctl ui --service install` installs `himmel-ui.service`, a systemd
  user unit that serves the same pages on a fixed `127.0.0.1` port (47391, or `--port N`)
  with no idle exit, restarts on failure and rebuilds `agui-web/dist` at start when its
  sources are newer. The token is a mode-600 file, `~/.himmel/state/ui-token`, created once,
  so the URL survives restarts: `--service url` prints the bookmark, `status` and
  `uninstall` do what they say (uninstall also deletes the token file). It needs
  `HANDOVER_DIR` in the shell that runs `install`. The board on the Fleet page is read from
  `<console doc>.board.json`, which every `board.mjs` render rewrites beside the doc, and
  reaches the page within about 5 s; with no such file the server builds it as before.
- **Pages** (the left rail): `#/config` (install items, doctor checks, scheduled
  jobs, lanes, flags and secrets by presence), `#/health` (one verdict:
  All clear / Needs a look / Act now), `#/toolhealth` (tool-call failure and
  denial rates by model and lane), `#/roadmap` (releases, drift, sync and
  librarian, live from the Jira mirror; click a version for its kanban at
  `#/roadmap/<version>`), `#/kanban` (one board across all versions, Done
  hideable), and **Fleet** at `/agui/`.
- **Fleet and run view (AG-UI).** `/agui/` lists every live Claude session
  with its ticket, PR and state; clicking one opens its run page: assistant
  text, tool-call cards, subagents, failures. The page needs a one-time build
  (`cd scripts/config-ui/agui-web && bun install && bun run build`); without it
  `himmelctl ui` prints the config page instead.
- **Console board on the Fleet page.** Start `himmelctl ui` with `HANDOVER_DIR` set and open
  `/agui/#t=<token>&console=<console doc name>`. The page then shows the supervisor
  session's board (the `board.mjs --json` output, served read-only and redacted at the
  token-gated `GET /api/agui/board?console=<name>`; built from the board JSON file when present, else cached 30 s). **Fleet** tab: verb-led
  rows for what needs you, and on each running row its goal, six stage dots (dispatch,
  live, PR, ready, go, merged) and a state chip. **Trends** tab (`&tab=trends`): four cards
  (Fleet velocity, Fleet health, Tool health, Roadmap reality), each with a recommendation
  line and a colour legend; a milestone is a Jira fixVersion, console cost sits beside
  fleet cost, and Tool health carries the console-succession row. A card opens its table in
  the side drawer. Clicking a stage dot opens that leg's drill-in in the drawer (run header,
  stage strip, transcript, the needs-you finding with its exact `go.sh` command). Keys: left
  and right move between stages, up and down between legs, Backspace goes back, Esc closes.
  Deep link: `&k=s.<leg>.<stage>`. `GET /api/agui/brief?leg=<doc name>` returns that
  leg's handover doc as redacted text. Both routes look a doc up by name under
  `HANDOVER_DIR`, never by a path from the request.

Full reference, endpoints and environment overrides:
[scripts/config-ui/README.md](../scripts/config-ui/README.md).

## The console board and roadmap tracker

Both belong to the himmel **supervisor session**, the long-running session that
dispatches and watches worker sessions ([glossary](glossary.md)). They are static HTML
files the supervisor session renders from its own state and republishes as artifacts, not
servers.

- **Board** (`board.mjs`): fleet size against the cap, each worker session's phase from
  LIVE to WRAPPED, what needs the supervisor session, epic progress and open decisions.
  `--changed` prints `CHANGED <path>` or `UNCHANGED <path>`.
- **Tracker** (`tracker.py`): release panels and a kanban by Jira version and
  theme. Run `node scripts/jira/dist/index.js mirror` first; without a mirror
  it has nothing to show. The same view also lives live at `#/roadmap` in the
  config console.

Both are Linux-only supervisor session tooling; an install without a supervisor session does not
have them in use.

## Keeping this page current

Adding a user-facing page or verb means updating this page, `llms.txt` and the
v1 release checklist step ([release/v1-checklist.md](release/v1-checklist.md)).
`bash scripts/docs/test-check-llms-links.sh` fails when a page id in
`scripts/config-ui/public/nav.js` is missing here.
