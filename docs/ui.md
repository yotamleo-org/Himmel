# The himmel UI surfaces

himmel has no hosted UI. Three surfaces exist, all local, all read-only, and
each is started by a command you run yourself. If a user asks "the himmel UI",
they almost always mean the first one.

| Surface | What it is | Start it | Needs |
|---|---|---|---|
| Config console | One local web app: Config, Health, Tool health, Fleet, Roadmap pages and the AG-UI run view | `node scripts/himmelctl/bin.js ui` | `bun`, a terminal outside Claude |
| Console board | One generated HTML page: the fleet, each leg's phase, what needs the console | `node scripts/handover/console-kit/board.mjs --doc <console doc> --changed` | a running himmel console |
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
- **Pages** (the left rail): `#/config` (install items, doctor checks, scheduled
  jobs, lanes, flags and secrets by presence), `#/health` (one verdict:
  All clear / Needs a look / Act now), `#/toolhealth` (tool-call failure and
  denial rates by model and lane), `#/roadmap` (releases and the kanban,
  live from the Jira mirror), and **Fleet** at `/agui/`.
- **Fleet and run view (AG-UI).** `/agui/` lists every live Claude session
  with its ticket, PR and state; clicking one opens its run page: assistant
  text, tool-call cards, subagents, failures. The page needs a one-time build
  (`cd scripts/config-ui/agui-web && bun install && bun run build`); without it
  `himmelctl ui` prints the config page instead.

Full reference, endpoints and environment overrides:
[scripts/config-ui/README.md](../scripts/config-ui/README.md).

## The console board and roadmap tracker

Both belong to the himmel **console**, the long-running session that
dispatches and watches legs ([glossary](glossary.md)). They are static HTML
files the console renders from its own state and republishes as artifacts, not
servers.

- **Board** (`board.mjs`): fleet size against the cap, each leg's phase from
  LIVE to WRAPPED, what needs the console, epic progress and open decisions.
  `--changed` prints `CHANGED <path>` or `UNCHANGED <path>`.
- **Tracker** (`tracker.py`): release panels and a kanban by Jira version and
  theme. Run `node scripts/jira/dist/index.js mirror` first; without a mirror
  it has nothing to show. The same view also lives live at `#/roadmap` in the
  config console.

Both are Linux-only console tooling; an install without a console does not
have them in use.

## Keeping this page current

Adding a user-facing page or verb means updating this page, `llms.txt` and the
v1 release checklist step ([release/v1-checklist.md](release/v1-checklist.md)).
`bash scripts/docs/test-check-llms-links.sh` fails when a page id in
`scripts/config-ui/public/nav.js` is missing here.
