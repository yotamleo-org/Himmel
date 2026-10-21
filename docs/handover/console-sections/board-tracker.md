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
    to a carried `board:` URL goes to a haiku subagent, never your own
    context.** The tool refuses a publish to an artifact this session has not
    viewed and the refusal returns the whole live page (about 23k tokens for a
    46 KB page, paid on every later call), and `Artifact read` costs the same.
    Dispatch `Agent` with `model: haiku`, effort medium: "`Artifact` `read` `<url>`
    (no `path`), then `Artifact` `publish` `<url>` from `<local file>`; reply with
    one line: `PUBLISHED <url>`, or the first 200 characters of the error. Never
    paste page content." It returns one line, not the page; if a later publish
    of your own is refused, send that to the subagent too and never read the URL
    yourself. A `path` read or `overwrite_unread` does not count as viewing.
    <!-- ponytail: subagent cost absorption is not yet measured (HIMMEL-6756), the first console publish that uses it records the parent-context delta on that ticket; old-term-ok: this section is the console's own runbook -->
    The tick's `board=` field is your reminder:
    `board=MISSING` (never rendered) or `board=STALE:<age>` (the state moved
    since the last render) means re-run it now. `board=ok` proves only that the
    LOCAL file matches the current state; republishing the artifact stays your
    step.

    The live page stays under 15 KB at 25 live legs: one line per leg card,
    finished judges (last bullet `WRAPPED` or `VERDICT`) go to the archive with
    the other done work, and the exploration and failures tables show their top
    5 rows (the full tables are in the archive).

    **`--json <path>`** also writes the board model as JSON (schema
    `himmel.board/1`) for a richer UI (HIMMEL-5968) to render. It holds:
    - `needs_you`: each item has a verb (`go`, `unblock`, `decide` or `act`); a
      `go` item carries the `go.sh` command.
    - `legs`: each leg's stage, state, PR, ticket and brief links, and a
      timeline of its marker bullets.
    - `ci`, `bank`, and `milestones` (Jira fixVersion done/total).
    - `trends`:
      - `leg_time` and `cost`;
      - `console_cost`: the console's own Opus-eq spend, deduplicated by
        message id from its transcript, total and per hour, beside the fleet's
        `fleet_eq`;
      - `exploration` and `failures`;
      - `tools`: a `console-succession` row (turns, eq and wall minutes from
        the successor's first message to its LIVE bullet, legs that quoted the
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
    `python3 "<kit>/tracker.py" --version <version> --priority-file <approved plan> --chains-file <handover bucket>/focus-chains.json --jira-base-url <site> --out <handover bucket>/roadmap-tracker.html --plan-dir <plan dir>`
    (`tracker.py --help` names every argument; `--out` and `--plan-dir` must be
    the paths the tick reads, because with `--plan-dir` the render also writes
    `<out>.fp`, the value `--emit-fp` prints, so the tick then reports `tracker=ok`).
    Render a later version the same way to its own file, without `--plan-dir`.
    Republish each file to its URL with the `Artifact` tool. A
    successor's FIRST publish to a carried tracker URL goes to the same haiku
    subagent as for `board:` (FOCUS and tracker pages are the 46 KB ones);
    update each URL in place, never a new URL. After each publish of the current page, `touch <handover bucket>/roadmap-tracker.html.published`:
    a page newer than that stamp reads `tracker=REPUBLISH:<age>` (rendered, not yet
    republished); without the stamp file the tick keeps reading plain `ok`.

    **What a version page shows.** Columns are the Jira statuses of the
    version's open tickets (To Do, In Progress, In Review, IN CI), each split
    into the priority blocks of the plan's `priority:` line (a ticket on no
    block line sits in `rest of version`). A card carries its sector colour (the
    mirror's `sector:` frontmatter, written when `jira.sectorField` is set in
    `~/.himmel/config.json`), its open PRs with their CI state (one live
    `gh pr list`, or `--prs-file`; a started card with no open PR is flagged), its
    blockers (an open blocker is flagged; a link whose blocker's own text puts it
    after this ticket reads `direction?`), and its FAST-TRACK step when a merge
    chain names it. The merge chains and parallel waves of `--chains-file`
    (`[{name, note, steps: [{key, pr, label, state, owner}]}]`) render above the
    board, a step whose ticket is Done reading merged; a page shows only the
    chains with a step in its version. Each column header carries a parity line
    against one live JQL count of the version's open tickets (`Jira n · ok`, or
    `DRIFT` naming each differing key with both statuses), and stdout prints the
    same per column; a DRIFT right after a render usually means Jira moved since
    the mirror refresh, so refresh and render again. When `gh` or Jira cannot be
    read the page says so and flags no card for a missing PR.

    **Automatic refresh.** When the handover doc has a `focus-version:` line,
    `wrap-merged.sh` runs `bash "<kit>/focus-refresh.sh" --doc <console doc>` after
    every merge (it also reads `focus-plan:` and `<doc dir>/focus-chains.json`).
    It stages the mirror, versions, status sweep, open PRs, the page and
    `status-drift.sh` output. Only on full success does it publish `focus-drift.txt` and
    replace `roadmap-tracker.html` (and only when the page fingerprint moved); `focus-state`
    records every run, `FAILED:<stage>` included. The wrap prints
    `focus=ok|busy|FAILED:<stage>|skip` and never fails on it. `focus-refresh.sh --doc <doc> --status` prints the same state
    (`console-wait.sh` wakes on `FAILED` or `DIRTY` for 10 min or more). Republish the page
    with the `Artifact` tool as above. Each card also shows its worker (owner, PR, state).
    `status-drift.sh` is the report-only drift check (last line `sdrift=<n>:<sig8>`);
    `ticket-hold.sh <KEY> --reason <r> --owner <o>` (or `--release`) sets and clears the `held` label.

    The bucket `render-focus.py` and the split focus, Done and future pages
    (`--out-done`, `--out-future`, `tracker-done:`, `tracker-future:`) are retired;
    drop those URLs from `## Live state` at the next handover.

- **Version-status audit:** `bash scripts/handover/console-kit/version-status-audit.sh --legs-from <fleet manifest>`
  lists started tickets outside the active version, open tickets in a released
  version and versionless started Tasks, Stories and Bugs (OWNED = a live leg or
  open PR holds it, RESET = move it to To Do with a reason comment). Run it after
  a version cut; expect `vmismatch=0`. Without the manifest, or when `gh` cannot be
  read, ownership is unknown: unowned started rows print UNKNOWN and the run exits
  3, never RESET (released-version rows still print RESET). A mirror file missing
  its key or status, or a bad version, also exits 3; an unreadable mirror prints
  no rows and exits 3, an unreadable versions file exits 4.
