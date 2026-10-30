# AFK sudo and the `run` kind

`scripts/lib/afk-sudo/` is the root helper that runs one privileged command after
the operator approves it with a TOTP code (HIMMEL-8066). Slice 1a of HIMMEL-8067
adds a second kind, `run`, which freezes one argv, shows it to the operator and
runs exactly that once. It changes nothing on the station until slice 1b flips
the compiled switch below.

Files: `afk_sudo.py` (the helper, installed as `/usr/local/libexec/himmel/afk-sudo`),
`approval_broker.py` (the pending slot, TOTP, ledger), `never_remote.py` (the floor),
`install.sh`, and the session-side CLI `scripts/lib/afk-run`. Tests:
`scripts/lib/test-afk-sudo.sh`.

## Off until a release says so

`RUN_KIND_SHIPPED = False` is a constant in `afk_sudo.py`. While it is false every
`run-request` answers `result=run-not-shipped`, whatever the config says, and an
approved record that somehow exists re-checks it at exec time. A config edit cannot
flip it: only a himmel release plus a re-install does. Slice 1a ships it `False`.

The unit tests need the run kind on without editing the constant. The helper
therefore also honours `AFK_SUDO_RUN=1`, but only inside the test seam
(`AFK_SUDO_ROOT` set and euid != 0), which an installed helper never is. This
refines the plan's wording: the plan says "compiled constant only"; the seam
variable exists so RED 10 can run in-suite, and the VM proof flips the constant
itself on the disposable VM's installed copy.

Check order for a run: `disabled` (top-level `enabled`), `run-not-shipped`,
`run-disabled` (`run.enabled` is not `true`).

## Mode switch

Config `mode` is `"allowlist"` (default; any other or absent value reads as this) or `"all"`.

| | `allowlist` | `all` |
|---|---|---|
| Which argv | one a class names (`not-in-class` otherwise) | any |
| Runs as | the class's `run_as` (default root; root or `operator_user` only, any other user is `bad-user`); `--as` is ignored | `operator_user`, or root with `--as root`; any other user is `bad-user` |

The never-remote floor applies in both modes, at request and again at exec. At request in
`allowlist` mode an argv no class names is refused as `not-in-class` before the floor runs (it
never reaches the operator either way); an argv a class names goes through the floor.

## The frozen record

A `run-request` writes a root-owned record `STATE/records/<id>.json` (0600, dirs 0700,
created lazily): argv, `run_as` and its uid/gid, the absolute path of argv[0] and the
sha256 of its realpath, every argv element that resolves to a regular file (the resolved
path, sha256, size, whether its body was kept), what every argv element resolved to (`targets`:
one `file:<path>`, `dir:<path>` or empty entry per element), cwd and its device/inode, the env names, the stdin
size and sha256, session, ticket, `blocked_by`, why, created and expires. Its
canonical-JSON hash (sorted keys, no spaces, all fields except `id`) is stored in the
broker's pending payload, not next to the record.

- argv[0] resolves in the fixed PATH `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, or as
  given when it holds a `/`. The path is kept as written, not normalised: `link/../x` is
  hashed and exec'd as the kernel opens it (links resolved before `..`), never as `x`.
- An argv element is read as the kernel opens it: joined to the cwd, links resolved before
  `..` (`realpath`). One that resolves to a regular file is hashed. A directory, or a name
  that is no file, is not hashed. An element under `/proc`, `/sys` or `/dev` (only `/dev/null`
  passes), a FIFO, socket or device, and an existing file that cannot be opened and hashed
  are refused at request (`result=bad-file`, exit 5, no ledger row), never skipped. At exec
  every element, argv[0] included, must resolve to the same target as at request, so a
  link relinked to another file, a directory or nothing, two links swapped between their
  files, a directory link retargeted, and a name that now names a file all report `changed`.
- The run is of the file in place, not of the copy, and a file a command loads itself (a
  script it sources, an interpreter's imports, a config it reads) is not bound. The instant
  between the exec-time check and the exec is an accepted residual (HIMMEL-8250).
- Files up to 64 KiB are copied to `STATE/files/<id>/` so the floor scans their text; a
  larger file is hashed only (`shown: false`). A file the operator could not read
  themselves (not world-readable, not theirs) is hashed and never copied. File bodies
  therefore live in root-only state, never in the ledger.
- Stdin is read from the helper's stdin, at most 64 KiB (`stdin-too-large`).
- Root runs use cwd `/`. Env values are computed by the executor (HOME from passwd,
  USER, LOGNAME, the fixed PATH, `LANG=C.UTF-8`, `XDG_RUNTIME_DIR`,
  `DBUS_SESSION_BUS_ADDRESS`), never taken from the caller.
- At most the last 20 finished ids keep their record, copies and result.

## What runs after the code is accepted

The executor re-checks, in this order, and writes a ledger row on the first mismatch:
record hash (`hash-mismatch`); argv[0] sha256, each file sha256, the cwd identity and that
every argv element resolves to the same file, directory or nothing as at request
(`changed`, also when one is gone or no longer a regular file); `run-not-shipped`;
`run-disabled`; that the run-as user and `operator_user` both resolve (`bad-user`; a missing
or unknown `operator_user` never falls back to root's home); the floor again with the
current config (`never-remote`); that the run-as user is still root or the operator
(`bad-user`); the class match in `allowlist` mode (`not-in-class`). A non-root run
goes through `setpriv --reuid --regid --init-groups --no-new-privs --inh-caps=-all`
(`no-setpriv` at request time and again at exec when it is missing); a root run executes
directly. `--no-new-privs` also means a setuid or setgid tool (`crontab`, `sudo`) fails
closed in an operator-mode run.
Output is captured to 256 KiB per stream (the rest is counted and hashed), the
timeout is `run.timeout_s` (default 300, max 1800; exit 124), and the result lands in
`STATE/results/<id>.json` for `run-result`.

The code is spent whatever happens next: a refusal after the code still consumed it.

## Never-remote floor

`never_remote.py` is installed root-owned beside the helper, so a config cannot remove
it. Five rules, each a membership test on one word set built from every argv element,
the whitespace-split words of each element, the file copies and the stdin (each word also
in its trimmed, `key=value`, normalised, realpath and basename forms; links resolve before
`..`). A word that derives more than 64 forms is refused as `rule=oversize`:

| rule | refuses |
|---|---|
| `disk-wipe` | mkfs/wipefs/blkdiscard/partitioners, block devices, `rm` of `/`, a top-level directory or home (or a `/*` glob of one), btrfs subvolume delete of `/` |
| `secret-read` | `/etc/shadow`, ssh and gpg keys, the Claude credentials and channel `.env`, `.env`, `totp.seed`, secret-tool/gh token/himmel-secrets reads |
| `main-history` | a force push or delete naming main/master, deleting `refs/heads/main`, `gh repo delete` |
| `approval-system` | `/etc/himmel`, the libexec dir, state and ledger dirs, sudoers, visudo, this installer |
| `guards-off` | settings files and `scripts/hooks` outside a worktree, `hooks.json`, `--dangerously-skip-permissions`, `HIMMEL_*_OK=1` and `*_BYPASS*=1`, stopping the telegram bridge |

Config `never_remote_extra` only adds fnmatch patterns. A match answers
`result=never-remote rule=<name>` (exit 5), is ledgered, and gives the operator no
notice. It runs at request time and again at exec time.

It is word-set membership, not a semantic policy (`ponytail:` in the module): blind to
computed paths, text a command fetches or assembles, a word split across quotes, and files
over 64 KiB. Co-occurrence over-blocks (an unrelated `main` beside `git push -f`, `rm` of a
top-level glob such as `/tmp/*`); that cost is accepted.

Honest limits: the floor is a seatbelt against mistakes and against an injected request
that names its target. It is not a complete policy: a script can compute a path the floor
never sees. In `all` mode one approved root run that computes its paths can change the
approval system itself (the config and `mode`, the floor, the helper, sudoers); the floor
only stops a request that names them. The operator's read of the notice (mode, run-as,
argv, script text, hash) stays the main control; the ledger and the morning report make
every run visible afterwards.

## Ledger

`/var/log/himmel/afk-sudo.jsonl` rows gain `kind`, `run_as`, `hash`, `blocked_by`,
`why` (cleaned, 200 chars), `mode`, `argv` (elements over 120 characters cut to 100),
`argv0_sha256`, `frozen` (files, stdin size and hash, cwd), `stdout_bytes`,
`stderr_bytes`, `stdout_sha256`, `duration_ms`. A refusal at request writes a row for
`never-remote` and `not-in-class` (the helper) and for `locked`, `busy` and `rate-limited` (the
broker) only. The other request refusals (`run-not-shipped`,
`run-disabled`, `bad-user`, `bad-cwd`, `bad-file`, `no-such-command`, `no-setpriv`,
`stdin-too-large`) answer on stdout and write none. After the code, the executor's result
(`hash-mismatch`, `changed`, `run-not-shipped`, `run-disabled`, `never-remote`, `bad-user`,
`not-in-class`, `no-setpriv`, or the run itself) is the row. The ledger never holds the code, the
seed, any output or a stdin body. A `busy` refusal writes one row per session per 10
minutes.

## Spent steps (HIMMEL-8078 part 2)

A code valid for request A is refused (`replay`) for request B when A ended without
running in the same 30-second step. Deny, burn and a failed code check spend the
current step; an expiry spends the step the request ran out in (not the lazy detection
time). All writes keep the maximum step.

## Config keys

`mode`, `operator_user`, `max_per_hour` (default 6, max 30), `run.enabled` (default
false), `run.ttl_s` (default 900, max 3600), `run.timeout_s` (default 300, max 1800),
`never_remote_extra`. `install.sh` writes them with the safe defaults on first
install and never rewrites an existing config.

## Turning it off

Narrowest first. Each is a root edit of `/etc/himmel/afk-sudo.json` (`sudoedit`), read
again by the helper on every call, so it takes effect on the next verb:

1. `"mode": "allowlist"`: only the argv a class names runs. A pending free-form request
   answers `not-in-class` when it is approved.
2. `"run": {"enabled": false}`: no run request is filed, and a pending one answers
   `run-disabled` when it is approved. The sudo-class kind is unaffected.
3. `"enabled": false`: every verb except `mode` answers `result=disabled`, `approve` and
   `deny` included, so a pending request can no longer be approved and runs out its expiry.
4. `sudo bash scripts/lib/afk-sudo/install.sh --uninstall`: removes the helper, the floor
   module and the sudoers rule. The config, the seed, the state and the ledger stay.

A session cannot do any of these: the config, the helper and the sudoers rule are root-owned.
The narrowing-only `/afk-lockdown` Telegram verb is slice S4, not built.

## Verbs

`request` (sudo kind, allowlist), `run-request`, `approve`, `deny`, `status`
(`run-status` is an alias), `run-result ID [--stream stdout|stderr]` and `mode`
(`result=mode mode=… enabled=… run_enabled=…`, the effective flag; answered before the
`enabled` check).

## afk-run

```text
afk-run --session S --ticket T --blocked-by classifier|hook:<guard>|prompt|operator-step \
        [--as root] [--cwd DIR] [--stdin-file F] [--why W] -- ARGV...
afk-run wait <id>
```

Files the request, polls `run-status` (first poll before any sleep), prints the captured
stdout and stderr and exits with the command's status. Other exits: 3 denied or burned,
4 expired, 5 refused (`refused:<result>`), 75 still pending (re-attach with
`afk-run wait <id>`), 76 the helper stayed busy and nothing was filed. The last stderr
line is `afk-run: status=ran:<exit>|denied|expired|refused:<result>|pending|busy …`,
with ` id=<id>` when one exists. Timing: `AFK_RUN_WAIT_S` (540), `AFK_RUN_POLL_S` (3),
`AFK_RUN_BUSY_EVERY_S` (15); they are also the test seams.

Not in slice 1a: the Telegram notice for a run request, the user-writable-argv0 marker
in it, and enabling anything. Slice 1b adds those and flips the constant.
