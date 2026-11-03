# Chief section — board and roadmap tracker (ACTION ZERO step 12)

Read on demand from `chief-template.md` step 12. `<kit>` is the kit path in step 7. Moved verbatim from the template.

12. **Render the chief board (local only)**. The board is a
    generated HTML page — fleet N/cap with idle slots, every worker's phase
    (LIVE → READY-TO-OPEN → PR open → READY → MERGED → WRAPPED, plus its own
    `WRAPPED, window still open` when a WRAPPED worker's claude window is still
    alive — derived from an independent process census, since tick.sh's `procs=`
    only counts HELD workers), what needs you, epic merged/total, the operator's
    open decisions — so the operator sees progress and convergence without
    asking. The page shows live work only: WRAPPED and MERGED workers
    and the merged PRs are written to `chief-board-archive.html` beside it
    (local, never published, one item per line — `grep` it for a ticket key,
    PR or last bullet), so a successor re-renders a small page. Render it with `node "<kit>/board.mjs" --doc "<this file>" --changed`: `--changed` re-renders and prints `CHANGED <path>` or
    `UNCHANGED <path>` instead of the bare path, so you know from one line
    whether the render moved after a dispatch, verdict, GO, MERGED or WRAPPED
    (nonces and lock tokens are redacted from the file either way). Rendering
    never publishes, and the board stays LOCAL (operator ruling 10-29): the
    chief profile denies the `Artifact` tool (HIMMEL-8201). Record the local
    file's path on the `board:` line of `## Live state`; `chief.sh next`
    carries it to your successor, who re-renders the same file.
    The tick's `board=` field is your reminder:
    `board=MISSING` (never rendered) or `board=STALE:<age>` (the state moved
    since the last render) means re-run it now; `board=ok` means the LOCAL
    file matches the current state.

    The live page stays under 15 KB at 25 live workers: one line per worker card,
    finished judges (last bullet `WRAPPED` or `VERDICT`) go to the archive with
    the other done work, and the exploration and failures tables show their top
    5 rows (the full tables are in the archive).

    **`--json <path>`** also writes the board model as JSON (schema
    `himmel.board/1`) for a richer UI (HIMMEL-5968) to render. It holds:
    - `needs_you`: each item has a verb (`go`, `unblock`, `decide` or `act`); a
      `go` item carries the `go.sh` command.
    - The worker list, under the key `board.mjs` writes for it: each worker's
      stage, state, PR, ticket and brief links, and a timeline of its marker
      bullets.
    - `ci`, `bank`, and `milestones` (Jira fixVersion done/total).
    - `red_main`: `{ days: 30, merges }`, the `red-main:` count of
      `scripts/insights/self-review.sh` over the last 30 days (`merges` is null
      when the script fails; the key is null in a checkout without it). The
      page shows the same count in its "Red main" panel.
    - `trends`:
      - `worker_time` and `cost`;
      - `chief_cost`: the chief's own Opus-eq spend, deduplicated by
        message id from its transcript, total and per hour, beside the fleet's
        `fleet_eq`;
      - `exploration` and `failures`;
      - `tools`: a `chief-succession` row (turns, eq and wall minutes from
        the successor's first message to its LIVE bullet, workers that quoted the
        token back versus silent ones, pass/fail against eq ≤ 457k and
        turns ≤ 20, and a recommendation).
    - `legend`: the meaning and theme colour of every colour-coded value.
    - `cards`: a recommendation each for velocity, health, tools and roadmap.

    Transcripts are read from `BOARD_TRANSCRIPTS`, by default
    `~/.claude/projects/<repo slug>`, and only files modified in the last
    48 h are read. Nonces and lock tokens never reach the JSON.

    **Keep the roadmap tracker current** (only when `## Live state`
    has a `tracker:` URL, else skip). The tracker is one page per version in
    the FOCUS design, and there is no all-versions page: `tracker:` is the
    current version's page and `tracker-<version>:` (for example
    `tracker-v1.1.4:`) each later version's. On every MERGED and WRAPPED, and whenever
    the tick reads `tracker=STALE:<age>` or `tracker=MISSING`: refresh the Jira
    mirror (`node <primary>/scripts/jira/dist/index.js mirror`) and the version
    release state (`node <primary>/scripts/jira/dist/index.js versions` redirected to
    `<mirror-dir>.versions.tsv`, i.e. `~/.himmel/state/jira-mirror/HIMMEL.versions.tsv`),
    then render the current version with
    `python3 "<kit>/tracker.py" --version <version> --priority-file <approved plan> --chains-file <handover bucket>/focus-chains.json --workers-dir ~/.himmel/state/workers --jira-base-url <site> --out <handover bucket>/roadmap-tracker.html --plan-dir <plan dir>`
    (`tracker.py --help` names every argument; `--out` and `--plan-dir` must be
    the paths the tick reads, because with `--plan-dir` the render also writes
    `<out>.fp`, the value `--emit-fp` prints, so the tick then reports `tracker=ok`).
    Render a later version the same way to its own file, without `--plan-dir`.
    The tracker stays local like the board: open each rendered file, never
    publish it. Delete a leftover `<out>.published` stamp from the old publish
    flow: with it, every render reads `tracker=REPUBLISH:<age>`; without it the
    tick reads plain `ok`.

    **What a version page shows.** Columns are the Jira statuses of the
    version's open tickets (To Do, In Progress, In Review, IN CI), except that a
    card with an open PR follows that PR's CI (red In Progress, running or green
    IN CI; green keeps a card Jira holds In Review) and names its Jira status;
    each column is split
    into the priority blocks of the plan's `priority:` line (a ticket on no
    block line sits in `rest of version`). A card carries its sector colour (the
    mirror's `sector:` frontmatter, written when `jira.sectorField` is set in
    `~/.himmel/config.json`), its open PRs with their CI state (one live
    `gh pr list`, or `--prs-file`; a started card with no open PR is flagged), its
    blockers (an open blocker is flagged; a link whose blocker's own text puts it
    after this ticket reads `direction?`), and its FAST-TRACK step when a dependency
    chain names it. The dependency chains and parallel waves of `--chains-file`
    (`[{name, steps: [{key}]}]`) render above the
    board, a merged step left out and a dependency chain with none left dropped (the header
    counts them); a page shows only the dependency chains with a step in its version.
    The file is hand input for dependency-chain names and step order only: a keyed step's row
    is its ticket's title, Jira status, open PRs with CI and the owning worker from
    the fleet record, read on every render (a hand `label`, `pr`, `owner`, `state`
    and a dependency chain's `note` are ignored for a keyed step and never printed). A keyless step keeps its
    label and state. `Waiting on you` is derived from the open tickets of the version
    carrying an operator label (`operator-decision`, `operator`, `operator-present`,
    `operator-gated`); a hand dependency chain named `Waiting on you` is not printed. The header names
    the age of `focus-chains.json` when it is older than the newest Jira update. Each column header carries a parity line
    against one live JQL count of the version's open tickets (`Jira n · ok`, or
    `DRIFT` naming each differing key with both statuses), and stdout prints the
    same per column; a DRIFT right after a render usually means Jira moved since
    the mirror refresh, so refresh and render again. When `gh` or Jira cannot be
    read the page says so and flags no card for a missing PR.

    **Which version the page shows.** `focus-version: auto`, or no
    `focus-version:` line beside a `release: <R>` line, follows the current version
    of the declared release: the first version of `jira release state <R> --json`
    (the project's own `JIRA_PROJECT_KEY` and release, so an adopted project needs
    nothing himmel-specific). A version cut and shipped moves the page on at the next
    refresh, with no edit. To pin a version, write `focus-version: v1.1.3`; the
    page then stays on it until you change the line. `focus-version: none` turns the
    page off, and no line with no `release:` line also reads `focus=skip`. When the
    release cannot be read (CLI failure, no `release:` line, no version), the refresh
    prints `focus=FAILED:release`, warns on stderr and keeps the published page; it
    never falls back to a stale version. `chief.sh next` carries the line forward.

    **Automatic refresh.** When the version rule above resolves to a page (it does
    unless it reads `focus=skip`),
    `wrap-merged.sh` runs `bash "<kit>/focus-refresh.sh" --doc <chief doc>` after
    every merge (it also reads `focus-plan:` and `<doc dir>/focus-chains.json`).
    It stages the mirror, versions, status sweep, open PRs, the page and
    `status-drift.sh` output. Only on full success does it publish `focus-drift.txt` and
    replace `roadmap-tracker.html` (and only when the page fingerprint moved); `focus-state`
    records every run, `FAILED:<stage>` included. The wrap prints
    `focus=ok|busy|FAILED:<stage>|skip` and never fails on it. `focus-refresh.sh --doc <doc> --status` prints the same state
    (`chief-wait.sh` wakes on `FAILED` or `DIRTY` for 10 min or more). The page stays
    local, as above. Each card also shows its worker (owner, PR, state).
    `status-drift.sh` is the report-only drift check (last line `sdrift=<n>:<sig8>`); its
    `VERSION-DRIFT` row lists a Done or started ticket held only in a later unreleased version than
    the current one, with the INTAKE request that folds it in (the wrap prints it as `drift:`);
    `ticket-hold.sh <KEY> --reason <r> --owner <o>` (or `--release`) sets and clears the `held` label.

    The bucket `render-focus.py` and the split focus, Done and future pages
    (`--out-done`, `--out-future`, `tracker-done:`, `tracker-future:`) are retired;
    drop those URLs from `## Live state` at the next handover.

- **Version-status audit:** `bash scripts/handover/chief-kit/version-status-audit.sh --workers-from <fleet manifest>`
  lists started tickets outside the active version, open tickets in a released
  version and versionless started Tasks, Stories and Bugs (OWNED = a live worker or
  open PR holds it, RESET = move it to To Do with a reason comment). Run it after
  a version cut; expect `vmismatch=0`. Without the manifest, or when `gh` cannot be
  read, ownership is unknown: unowned started rows print UNKNOWN and the run exits
  3, never RESET (released-version rows still print RESET). A mirror file missing
  its key or status, or a bad version, also exits 3; an unreadable mirror prints
  no rows and exits 3, an unreadable versions file exits 4. A `BLOCKER-NO-VERSION`
  row is an open versionless Task, Story or Bug that blocks an open ticket in the
  active version; give it that version (or the `backlog` label, which opts out).
