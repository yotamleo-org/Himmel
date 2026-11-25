# The go-code launch route for billed and bypass flags

`scripts/station-ops/bypass-launchd.sh` launches a worker with the hook guard
flags the operator approves, only after the operator replies with a one-time
code on Telegram. With the operator away from the station, this is the only way
a session can get `HIMMEL_BILLED_OK=1` (a paid eval),
`HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1` (a worker that edits `scripts/hooks/`) or any
other grantable guard flag, for example `DESTRUCTIVE_OK=1`.

## Why a session cannot set the flag itself

- **The auto-mode classifier refuses it.** Since 2026-11-12 the classifier
  denies `HIMMEL_BILLED_OK=1` as `[Safety Bypass Flag]`, both as a per-call
  prefix and inside a launch script a chief runs. Chiefs ran the same shapes
  on 11-03 and 11-04 without a denial, and the denials ledger has no
  `HIMMEL_BILLED_OK` row before 11-12. The billing gate in `run.sh` is older
  (2026-10-24). What changed is the classifier. Any env flag that
  turns a guard off looks like self-escalation to the classifier, so a
  session cannot set it, whatever the brief says.
- **afk-sudo cannot carry it.** The root floor (`never_remote.py`, rule
  `guards-off`) refuses any `HIMMEL_*_OK=1` request, and afk-sudo runs as root
  with cwd `/`, which is the wrong context for a worker launch.

So the flag has to come from a process the operator started outside any
session, and it is set only on the operator's own reply.

## What it replaces

Earlier, the chief ran the reviewer eval sweep itself
(`HIMMEL_BILLED_OK=1 bash scripts/eval/review-panel/run.sh ...`), or exported
the flag in a worker's launch script. Both shapes are now refused. Instead:

1. The chief writes the sweep worker's brief in the handover bucket.
2. The chief writes a request into `<bucket>/bypass-queue/<name>.req`:

   ```text
   brief=<absolute brief path, directly in the bucket>
   model=claude-sonnet-5-5
   chief=<chief session name>
   flags=HIMMEL_BILLED_OK
   effort=high
   decision=<operator decision number>
   api_account=<A, B, C, D or auto>   # optional; launches with the API lane on for that account
   blocks=#5700 #5699                 # optional; the pull requests the work blocks, "#<n>" tokens, single spaces
   recommend=go                       # required: go, no, or no:<reason of at most 60 characters>
   ```

3. The daemon sends the operator a short ask on Telegram, the code first:

   ```text
   go IQF5ED → launch · no IQF5ED → refuse
   <ticket> <worker> on opus-5-5 high
   flag HIMMEL_HOOK_INTEGRITY_BYPASS_OK (skips block-worker-write-fence)
   Chief: GO
   Expires 6 h · brief sha d7a113226fde
   ```

   Line 1 is the code and the reply to send. Line 2 is the ticket, the worker,
   the model and the effort. Line 3 names every granted flag, and the hook it
   skips when the registry names one. The hook names are dropped when the line
   would pass 200 characters. Decision, paid and API grants and `blocks=` add one
   line before the chief's word, such as
   `DECISION 921 · PAID RUN · API account A · Blocks PRs: #5700 #5699`. The
   chief's word is `Chief: GO`, or `Chief: NO — <reason>` when the chief thinks
   the operator should refuse. The brief's description is not in the ask.
   The request therefore needs a `recommend=` line: `recommend=go`, `recommend=no`, or
   `recommend=no:<reason of at most 60 characters>`. A request without one is refused as
   `malformed: recommend`. A `blocks=` that is not `#<n>` tokens separated by
   single spaces is refused `malformed: blocks`.
4. The operator replies `go <code>` and the daemon launches the worker with
   `headed-arm-worker.sh`. A reply of `no <code>` launches nothing, and so do
   6 h with no reply.

No CI check requires a reviewer eval sweep: the critic-eval merge gate was
removed (decisions 1251 and 1252, `scripts/eval/review-panel/README.md`). A
paid sweep runs only on an operator decision, and its go code authorises the
flag for that one launch.

## How the flag list is built

The list of hook flags is `scripts/himmelctl/lib/bypass-flags.json`, the
registry the config UI also reads. A second file,
`scripts/station-ops/bypass-flag-tiers.tsv`, gives every name a tier, and it
decides what a go code may grant. A registry entry with no `grant` or `decision`
row in the tier file cannot be granted, so a registry edit alone never widens a
grant. Each row is `flag`, `tier`, `source` and `why`, tab separated.

| Tier | What `flags=` does with it |
|---|---|
| `grant` | One go is enough. |
| `decision` | The request needs `decision=<operator decision number>`; the ask says `OPERATOR DECISION <n>`, and for the billed flag `PAID RUN (decision <n>)`. |
| `floor` | Refused before any ask: `flag X is floor: launch it from your own shell`. |
| `none` | Refused before any ask: `flag X is not a switch`. |

A name that is in neither list is refused `flag X is not in bypass-flags.json`,
and a request names at most 5 flags (`more than 5 flags`).

The daemon reads both files once, at start, from `HEAD` of the checkout it runs
from, with the inherited `GIT_DIR` and the other git location variables unset.
It refuses to start (exit 2) when the daemon script, the tier file or the
registry has uncommitted changes, staged or not, and says which. To pick up a
new flag: commit it, run `himmel-update` on the station, then replace the running
instance. The `start` line of `daemon.log` carries `head=`, `registry=`,
`tiers=` (the blob ids at `HEAD`) and `grantable=` (how many names a go can
grant), so the operator can see what a running daemon holds.

**Floor, never granted by a go code** (the operator launches these from their own
shell): `EDIT_LIVE_SETTINGS_OK` (a live settings edit outlives the launch),
`ENV_PREFIX_GUARD_OK` (one go would grant any seam variable unnamed),
`BUS_STORE_GUARD_OK` (a worker could bind itself as its own chief),
`SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE` (a subagent could write an
operator-chain row), `MAIN_REF_TRANSACTION_OK` (a commit on local main),
`DOCKER_PRIVESC_OK` (root-equivalent), `READ_SECRETS_OK`, `ROGUE_SCHEDULE_OK`
(arms a scheduler entry whose launch outlives this one), `HOOKSPATH_OK` (a wrong
`core.hooksPath` silently skips every git hook) and `EDIT_ON_MAIN_OK` (edits the
primary checkout, which holds the daemon and the live hooks). Six more floor rows
name switches outside the registry: `GH_ADMIN_MERGE_OK`,
`GRAPHIFY_SALUS_LOCAL_OK` and the four offline-mode switches
`SECURITY_REVIEW_NO_FETCH`, `PLATFORMS_TESTED_NO_FETCH`,
`TEMPLATE_VERSION_NO_FETCH` and `DOC_GUARD_NO_FETCH`, which skip a push gate when
no base ref resolves. They are not registered, so a request naming one is refused
`not in bypass-flags.json`; the rows keep them stripped and floor if they are
registered later.

**Decision, needs `decision=`:** `CI_MERGE_GATE_OK`, `CR_MERGE_GATE_OK`,
`SKIP_PR_MERGEABLE`, `PUSH_FOREIGN_REF_OK`, `SKIP_CR`, `SKIP_SECURITY_REVIEW`,
`CODEX_EXEC_RAW_OK`, `WRITE_HOLD_OK`, `INFRADESTROYOK`, `FLEET_CAP_OK` and
`HIMMEL_BILLED_OK` (source `eval`: read by the eval runner, not a hook).

**None, refused as not a switch:** `HOOK_OK`, `INPLACE_OK`, `BWIMC_ENGINE`
(registered, but an internal variable, an argument name and an engine picker),
and `GLM_EXTERNAL_WRITES_OK`, `HIMMEL_CONSOLE_LEG`, `CLAUDE_CODE_CHILD_SESSION`
(entries of the test-scrub lists with no reader, or markers a launcher sets).

Every other registry name is `grant`. A completeness row in the suite fails when
a registry name or a name of the two lists in `scripts/lib/override-env.sh` has
no tier row.

**The strip set.** Before the granted flags are set, the launch clears every
name the registry holds, every name the tier file holds and every other
inherited name ending in `_OK` or containing `_BYPASS`.

## A guarded housekeeping command

The daemon runs no command of its own; it launches a worker. To run one command
that a hook guard blocks while the operator is away, the chief writes a tiny
brief in the bucket, named `<TICKET>-<n>-N<n>-<slug>.md` with a real ticket
key, whose only step is the literal command and "then wrap". Then it writes a
request with `flags=DESTRUCTIVE_OK` (or the flag that guard reads) and
`model=claude-haiku-5-5`. The ask shows the brief's description and sha, and the
go launches that one session with the flag. The auto-mode classifier is separate
from the hook, so it may still refuse an `rm -rf` with the flag set; when it
does, the command waits for the operator.

## What the daemon guarantees

- **Only a granted flag, only on a go.** `flags=` may name only a name the
  registry holds with a `grant` or `decision` tier row (or the eval row); a
  floor, `none`, unknown or sixth flag refuses the request before any ask. A
  decision flag, the billed one included, without a numeric `decision=` is
  refused the same way.
- **Only the operator's reply counts.** The go must come from the operator's
  own chat (`from` and `chat_id` both equal `allowFrom[0]` of the bridge's
  `access.json`) and must not be forwarded.
- **The approval is bound to what was asked.** After the go, the daemon
  launches only if the brief still has the sha the ask named. It appends
  `granted_at=`, `go=` and `sha=` to the request, which ends as `.done`, and
  writes `GRANT <brief> env=<flags> decision=<n> go=<code>` to `daemon.log`.
- **Nothing inherited leaks through.** The launch clears the strip set above
  (so `SKIP_FORCE_PUSH_GATE`, `IMPL_GUARD_DISABLE` and the `*_NO_FETCH` names
  do not pass through either) and any inherited effort, then sets only the
  granted flags. A station opt-in such as `HIMMEL_DEEPSEEK_INFERENCE_OK`
  therefore does not reach a worker launched this way.
- **It never reads or launches a request on code older than its checkout; it
  holds and tells the operator instead.** At start it records the blob ids of
  its own script, the tier file and the flag registry from the commit it read
  (the `start` line prints them as `self=`, `tiers=` and `registry=`). Before
  it reads a request, and again after the operator's go, it compares them with
  HEAD. When one differs, or HEAD cannot be read, it logs
  `STALE hold loaded=<ids> checkout=<ids> (<cause>)`, writes
  `bypass-queue/.hold`, reads no request and launches nothing until it is
  restarted, even if HEAD later returns to the loaded ids. It sends one
  `bypass-failed` card naming the cause and the restart steps, and one more for
  each waiting request (`bypass request <name> waits: the daemon needs a
  restart`), once per request. A go given while the code moved is not used:
  the log says `STALE after go <brief>: go not used, re-queued`, a
  outcome stays in the station log and no card is sent, and the request goes
  back to `<name>.req`, to be asked again after the restart. The daemon does one thing at a time, so a
  change that lands while it waits on a go is found when that wait ends: the
  hold and its cards can come up to one ask wait (6 h) after the change.
- **A go code is asked only for a launch that can start.** Before it sends the
  ask, the daemon runs the launcher's own `headed-arm-worker.sh --dry-run` with
  the request's brief, model, chief and fleet manifest, in the launch's
  environment: the same admission a real launch makes (fleet manifest rows, a
  paused fleet, the fleet cap, the bank). Nothing is claimed or started. On a
  refusal it logs `REFUSED-PREFLIGHT <brief> rc=<n> <reason>`, appends the
  same line to the chief's console inbox
  (`<bridge root>/consoles/<chief>.md`, when that file exists), sends the
  operator nothing, and the request ends `<name>.req.refused`; the chief fixes
  the cause and files a new request. After the go, the daemon runs the dry-run
  again, because the fleet can fill while the ask waits. A refusal there does
  not spend the go: the log says `REFUSED-PREFLIGHT after go <brief> ...`, the
  chief is told, the request stays `<name>.req.pending`, and no `GRANT` line is
  written. The held go lives only in the daemon's memory, never in a file the
  requester can write: the daemon keeps the minted code, the brief sha, the
  request file's hash and the ask time, and leaves an empty marker
  `<name>.req.held` beside the request. When the chief has fixed the cause it
  touches `<name>.req.pending`; the daemon then logs `RETRY`, runs the dry-run
  again and, if it passes, launches on the same go code without a second ask.
  The marker carries no authority: a `.held` file the daemon did not record in
  its own memory is refused (`REFUSED held go not recorded in memory <name>`)
  and its request ends `.refused`. A held go is bound to what was asked: a
  request edited while its go is held is refused (`REFUSED after go <brief> (the
  request changed since the ask)`), a go held past the 6 h window is refused
  (`REFUSED after go <brief> (the go expired)`, the request ends `.expired`),
  and a go held while the code on disk moved holds the daemon exactly as an
  unheld go does. A restart drops every held go: the new daemon moves each
  held request back to `<name>.req` (`REQUEUE <name> (a held go does not
  survive a restart)`) and asks the operator again. The daemon reads a request
  once into memory and hashes and parses that same buffer, with no snapshot
  file; a request that is not a regular file (a FIFO or a symlink) is refused,
  and a held go whose ask time is in the future (the clock moved back) counts as
  expired. A passing dry-run changes
  nothing in the ask and the grant, and the request still needs the operator's
  go code.
- **Failures are reported.** A launcher that exits non-zero within the settle
  window logs `LAUNCH-FAILED <brief> rc=<n>`, and the request ends `.failed`.
- **It is bounded.** `--until <YYYY-MM-DD>` is required and may be at most 7
  days ahead; only the service unit may use `--until forever` (see "Run it as a
  service"). `<bucket>/bypass-queue/stop` stops the daemon. It refuses to
  start inside a Claude session (`CLAUDECODE` set) and holds one instance per
  queue (a pid lock in `bypass-queue/.lock.pid`, so it needs no `flock`).

## Starting and stopping it

The operator starts it from their own shell, never from a session:

```bash
nohup bash <repo>/scripts/station-ops/bypass-launchd.sh --bucket <bucket> --until <YYYY-MM-DD> >/dev/null 2>&1 &
```

On Linux put `setsid` before `nohup` to detach the daemon from your shell's session. On macOS start it from a
LaunchAgent (the worker window needs your GUI session); the daemon detaches each worker itself, with `setsid`
when present and perl's `POSIX::setsid` otherwise.

To replace a running instance, `touch <bucket>/bypass-queue/stop`, wait for
`stop file` in `daemon.log`, remove the stop file, then start it again. bash
holds the loop it parsed, and the daemon holds the registry and tiers it read at
start, so a new flag or tier reaches a running instance only after a restart.

A merged change to the daemon script, the tier file or the flag registry puts a
running daemon on hold. Telegram tells you at once with a `bypass-failed` card:
"bypass-launchd runs older code than its checkout (<cause>). It reads no request
until you restart it: touch <queue>/stop, wait for `stop file` in daemon.log,
remove stop, start it again." Each waiting request gets one more card. Until you
restart it, no queued request is read or launched; the new instance removes
`.hold` at start and asks each waiting request. A hold that begins while the
daemon waits on a go is written and told when that wait ends, at most 6 h later.

`bypass-launchd.sh --check --bucket <bucket> [--request <file>]` reports without
starting anything. It runs the start checks (not the Claude-session refusal, the
lock, `--until` or the operator id) and, with `--request`, the same request check
the loop runs. It prints `accepted` or `refused: <reason>`, then `daemon: none`,
`daemon: live pid=<p>` or `daemon: live pid=<p>, holding (<cause>)`, and exits 0
(accepted), 1 (refused) or 2 (a start check failed). It takes no lock, reads no
operator id, sends nothing and exits before the loop, so it may run inside a
Claude session: it cannot start, stop or steer the daemon.

## Run it as a service

`himmelctl bypass on` installs the daemon as a service unit and starts it: a systemd user unit
(`himmel-bypass-launchd.service`) on Linux, a LaunchAgent (`com.himmel.bypass-launchd`) on macOS. Under the unit it
runs forever (`--until forever`, accepted only for the service manager's own main process, so a hand start keeps the
7-day cap), is restarted when it dies or hangs, and is back after a reboot.

| command | what it does |
|---|---|
| `himmelctl bypass on [--bucket <dir>]` | writes the unit, enables and starts it, enables lingering; the bucket (the directory holding `bypass-queue/`) is remembered |
| `himmelctl bypass off` | writes the stop file, disables and stops the unit, so a reboot does not bring it back |
| `himmelctl bypass restart` | clears a failed state and restarts it now; it needs an enabled service with no stop file, so after `off` it exits 2 and names `himmelctl bypass on` |
| `himmelctl bypass status` | read only: enabled, active, pid, linger, `unit: current\|STALE`, `code: current\|STALE`, heartbeat age |

`on`, `off` and `restart` refuse inside a Claude session. `on` exits 1 without enabling when a hand-started daemon
holds the bucket (stop it with the stop file, then run `on` again). If lingering cannot be enabled (polkit may refuse
it) `on` still succeeds and prints the one command to run, `loginctl enable-linger <user>`; until then the daemon
starts at your next login instead of at boot. A template change shows as `unit: STALE` in `status`; run `on` again.

**Hang and crash recovery.** The unit is `Type=notify` with `WatchdogSec=300`: the daemon sends `WATCHDOG=1` on every
loop pass and around every call that can block, each of which is time-bounded (60 s send, 60 s fleet manifest, 120 s
preflight). A hung daemon is killed and restarted; so is a crash. On Linux the unit has `Restart=on-failure`, so a
clean exit (the stop file, or an expiry) and exit 3 ("already running") are not restarted, and after 5 failed starts
within 600 s systemd stops retrying; `himmelctl bypass restart` clears that failed state while the service is still
enabled. On macOS `KeepAlive` with `SuccessfulExit` false restarts after any unsuccessful exit, exit 3 included, every
10 s (`ThrottleInterval`), because launchd cannot exclude one exit status: a hand-started duplicate owner makes the
agent relaunch and exit 3 in a loop until the duplicate stops.
`NotifyAccess=all` is needed because `systemd-notify` is a child of the main process. launchd has no watchdog, so on
macOS the daemon starts a small watcher (`bypass-launchd.sh --watch`) that kills it when `bypass-queue/.heartbeat`
goes stale. On macOS the agent loads at your login, so a reboot only brings it back once the station logs in; the plist
and the watcher were tested on Linux and `launchctl` has not been run on a Mac.

**An update restarts it.** himmel-update runs `bypass-service.sh restart-if-changed`: when the unit is enabled and
running and the daemon's recorded code ids (`bypass-queue/.loaded`) differ from the checkout, it `try-restart`s it
through the service manager and checks it came back on the new code. On Linux it only issues `is-enabled`,
`is-active`, `show` and `try-restart`; on macOS it checks the job with `launchctl print` and restarts it with
`launchctl kickstart -k`. It never writes a unit, never enables or starts one, never clears a failed state, so it is
safe from a Claude-run update, and the manager starts the process with the unit's own environment, so the
`CLAUDECODE` refusal in the script is untouched. An off or stopped unit is left alone and the update names the
command to run (`himmelctl bypass on` or `himmelctl bypass restart`). A request that was waiting for your go when the
daemon restarts is asked again with a new code; one that already carried your go is moved to `.failed` and not re-run.

**The manager's environment is not trusted.** Any process of your user can change the user manager's environment
(`systemctl --user set-environment`, `launchctl setenv`) and a restart makes it live. So the unit starts bash as
`-p` (which ignores `BASH_ENV`, `SHELLOPTS`, `BASHOPTS` and the like; the script refuses to run under the manager
without it), pins `HOME`, `PATH` (system directories only), the operator id file and the bridge root, and unsets the
test seams. The script takes `HOME` from the passwd entry and refuses a different one, ignores its own test seams, and
runs every child (launcher, preflight, fleet manifest, sender) from an empty environment plus an allowlist: `HOME`,
`USER`, `LOGNAME`, `PATH` (system directories, then your `~/.local/bin` and `~/.bun/bin`), a shaped `LANG`,
the runtime dir, `HANDOVER_DIR` when pinned, the two bridge paths, a pinned bus address, the granted flags and the
worker effort and API names. The session names a headed terminal needs (`DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`,
`XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`) are read by name as data and checked (`DISPLAY` must equal logind's;
the Wayland socket must exist; `XAUTHORITY` must be a file you own); a failed check, or no graphical session at all,
refuses the request before you are asked (`REFUSED-PREFLIGHT session env: <name> failed its check`).

**What this does not stop.** A Claude session can still start, kill, restart or `set-environment` the unit with plain
`systemctl`/`launchctl` calls, and the manager then starts the daemon without `CLAUDECODE`. That is no worse than
before (any process of your user could already start the script with `CLAUDECODE` unset); a Bash guard is a separate
follow-up ticket. Other ceilings: a process of your user can run a fake Wayland compositor with a socket in the
runtime dir; a worker the launcher starts without a `systemd-run` scope stays in the unit's cgroup, which
`NotifyAccess=all` admits (liveness only); `.heartbeat` and `.loaded` sit in the bucket, which any process of your user
can write (a forged heartbeat keeps a hung daemon alive, a forged `.loaded` only holds back an update restart, and
the daemon's own stale-code hold reads git, not the file); a name a worker needs later (`SSH_AUTH_SOCK`, proxy
settings) is not on the allowlist, so a launched worker runs without it.

Exit codes: 0 stopped or expired, 1 any other failure, 2 refused to start, 3 already running.

## Limits

A process running as the operator's user can append a forged `go <code>` line
to the bridge's `inbound.jsonl` if it can read the code from the bridge's
outgoing queue. The per-request code, the own-chat check, the fixed launch
shape, the flag and model allowlists and the 7-day bound limit the damage.
They do not prevent it. With the full flag list, a forged go can grant any
grant-tier flag, or a decision-tier flag with a made-up decision number; for
`CODEX_EXEC_RAW_OK` that lets the launched session start raw `codex exec`,
which runs under no Claude hook. What runs otherwise is still a Claude session
under every other hook and the classifier. The daemon's check for uncommitted
changes runs inside the script it checks, so it stops an accidental edit or a
half-applied update, not a deliberate edit that removes the check; the floor
rows for `EDIT_ON_MAIN_OK`, `MAIN_REF_TRANSACTION_OK` and `DOCKER_PRIVESC_OK`
keep a go-launched worker out of the primary checkout. A switch no list holds
and no `_OK` or `_BYPASS` pattern matches, a role marker such as
`HIMMEL_RELEASE_MANAGER` and a path seam such as `HIMMEL_HOOK_INTEGRITY_DIR`
still pass through from the daemon's environment. A direct command or a named
station op on a go code, and a launch that runs only the approved brief, are
tracked in the backlog ticket on the approved brief, not built here. The same user can also swap or edit the brief after
the post-go sha check, before the launcher and the worker read it, so the
worker runs instructions the operator never saw, with the granted flag; the
fix is a launch from a root-held snapshot of the approved brief. Closing both
needs a root-owned station op that afk-sudo approves.

Tests: `scripts/station-ops/test-bypass-launchd.sh` runs the daemon with a
stub sender and a stub launcher on a temp bucket; `scripts/station-ops/test-bypass-service.sh` runs
the service script against a stub service manager.
