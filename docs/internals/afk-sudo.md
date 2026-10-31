# AFK sudo and the `run` kind

`scripts/lib/afk-sudo/` is the root helper that runs one privileged command after
the operator approves it with a TOTP code (HIMMEL-8066). Slice 1a of HIMMEL-8067
adds a second kind, `run`, which freezes one argv, shows it to the operator and
runs exactly that once. Slice 1b adds root's notice bot and a nonce bound to each request
(HIMMEL-8078 part 1) and turns the run kind on. The helper is Linux-only: safe file
validation needs `O_PATH`, `/proc/self/fd` and `fstatfs`.

Files: `afk_sudo.py` (the helper, installed as `/usr/local/libexec/himmel/afk-sudo`),
`approval_broker.py` (the pending slot, TOTP, ledger), `never_remote.py` (the floor),
`install.sh`, and the session-side CLI `scripts/lib/afk-run`. Tests:
`scripts/lib/test-afk-sudo.sh`.

## The compiled switch

`RUN_KIND_SHIPPED` is a constant in `afk_sudo.py`. While it is false every
`run-request` answers `result=run-not-shipped`, whatever the config says, and an
approved record that somehow exists re-checks it at exec time. A config edit cannot
flip it: only a himmel release plus a re-install does. Slice 1a shipped it `False`;
slice 1b ships it `True`, now that every request reaches the operator through root's
notice bot. The config still keeps the kind off until `run.enabled` is `true`.

The unit tests need the run kind on without editing the constant. The helper
therefore also honours `AFK_SUDO_RUN=1`, but only inside the test seam
(`AFK_SUDO_ROOT` set and euid != 0), which an installed helper never is. This
refines the plan's wording: the plan says "compiled constant only"; the seam
variable exists so RED 10 can run in-suite, and the VM proof flips the constant
itself on the disposable VM's installed copy.

Check order for a run: `disabled` (top-level `enabled`), `run-not-shipped`,
`run-disabled` (`run.enabled` is not `true`), `no-allow-missing` (a Python without
`os.path.ALLOW_MISSING`; see the binding below), then the request checks, the last of
which are `no-setpriv` and `no-notice-bot`.

## The notice bot and the nonce (slice 1b, HIMMEL-8078 part 1)

A session could put any text into the bridge bot's chat, so a look-alike request message
cannot be ruled out there. The facts therefore come from a second bot whose token only
root can read, `/etc/himmel/afk-sudo/notice-bot.env` (`TELEGRAM_BOT_TOKEN=<token>`, root
0600). `install.sh` creates it empty and prints the steps: `/newbot` at @BotFather, send the
new bot `/start`, then `sudoedit` the file. While the file is missing or holds no token,
every `request` and `run-request` answers `result=no-notice-bot` (exit 5, no ledger row). A
file another user can read is `unsafe-perms`.

When a request is filed, the broker draws a nonce: four Crockford base32 characters (no I,
L, O or U; typed in any case, O read as 0, I and L as 1). It lives only in the root state
file. Root sends the notice: the id, the expiry, the nonce, the mode (`ALL` or the class
name), run-as, session and ticket, the cwd, every argv element as written (argv[0] with
the first 8 hex of its sha256; a glued `key=/path` element or a directory is never
presented as bound), stdin, the text of a shell `-c` program or a shown script file (argv[0]
included when it is a `#!` script), the
`blocked_by` and `why` claims, and the record hash. argv[0] or a file argument that a
non-root user can change in place (not owned by root, or group- or world-writable) is
marked `user-writable`; a file argument whose body is not shown (over 64 KiB, or one the
operator could not read), and a user-writable argv[0] that is not a shown script, is marked
`NOT SHOWN`. Text is escaped and each element is
framed (`⟦…⟧`) with control and non-ASCII characters shown as escapes. When an element (the cwd included) or the message would
pass its limit it is cut, and the whole request goes first as a `<id>.json` document, so
the nonce is never sent while the attachment may still fail. If either send fails the request is withdrawn (`result=notice-failed`, a `notice` ledger
row, the step spent): the operator never approves what they were not shown.

The nonce applies to **both kinds**, sudo and run (the operator's default of 10-30, Q3).
The approve line is `approve <id> <nonce> <code>`; the helper reads `NONCE CODE` on stdin
(the two may also run together, the last six characters being the code). A wrong or
missing nonce is refused as `bad-nonce`: it counts as a wrong code towards the lockout, ends
the request, and spends the code's step, since the code was typed where a look-alike may
have read it. The nonce is never in curl's argv (root's command line is world-readable),
the ledger, the requester's output or the attached document. The token and every Bot API
parameter reach curl on stdin (`-K -`).

The bridge bot sends only the id and the Approve / Deny buttons: `afk-sudo-request` and
`afk-run` no longer forward any request text. An Approve tap asks for the nonce and the
code; a typed or replied `NONCE CODE` pair is held like a bare code, never forwarded to a
session (a session can call the helper's `approve` itself).

After an approve, root sends the result through the notice bot: `ran <id> exit <n>
(<s> s)`, and on a non-zero exit the last three stderr lines, redacted (the hook's
`redact()` patterns, ported line by line, plus PEM blocks); never stdout. A refusal after
the code says `not run: <result>`. The bridge acknowledges a ran approve without the argv.

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
one `file:<path>`, `dir:<path>` or `none:<path>` entry per element, `none:` holding the path a
name that does not exist yet would land on; an empty entry is an element that is no path: empty,
over 4096 characters, holding a NUL, or `/dev/null`), cwd and its device/inode, the env names, the stdin
size and sha256, session, ticket, `blocked_by`, why, created and expires. Its
canonical-JSON hash (sorted keys, no spaces, all fields except `id`) is stored in the
broker's pending payload, not next to the record.

- argv[0] resolves in the fixed PATH `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, or as
  given when it holds a `/`. The path is kept as written, not normalised: `link/../x` is
  hashed and exec'd as the kernel opens it (links resolved before `..`), never as `x`.
- An argv element is read as the kernel opens it: joined to the cwd, links resolved before
  `..` (`realpath`). One that resolves to a regular file is hashed. A directory, or a name
  that is no file, is not hashed. An element under `/proc`, `/sys` or `/dev` (only `/dev/null`
  passes), a FIFO, socket or device, an existing file that cannot be opened and hashed, and
  an element whose path the kernel cannot walk are refused, never skipped. Before reading or
  hashing, `open_regular` rejects a path already resolving into `/proc`, `/sys` or `/dev`
  without opening it (a device can have side effects on open). It then takes an
  `O_PATH | O_CLOEXEC` descriptor, which does not invoke a device driver's open operation.
  Before any read-open it resolves `/proc/self/fd/N`, rejects the same pseudo prefixes,
  requires a regular file with `fstat`, and checks the descriptor's filesystem type with
  `fstatfs`: procfs and sysfs are refused even when a private mount reached through another
  process's root gives the descriptor a non-pseudo path. An unresolved target or failed
  filesystem query is refused too. Only a validated descriptor is reopened through
  `/proc/self/fd/N` for reading, never through the caller's path. The path-only descriptor
  is always closed; failures during the read-open or stream wrapping close any read fd too.
  Thus a path swap cannot trigger a device/FIFO read-open; procfs and sysfs are refused
  even through private-mount aliases.
  "Cannot walk" is the helper's own walk, a name at a time with `lstat` and `readlink`, link
  targets included, failing for any reason but a missing name or a non-directory in the way, plus a `..` after a non-directory (the kernel gives `ENOTDIR`;
  plain `realpath` pops it lexically), a non-directory followed only by `/` or `.` (`f/` is not
  the file `f`) and a link whose target meets a non-directory: a walk past PATH_MAX in bytes, a name past 255 bytes
  that the walk reaches, a loop, a directory that cannot be searched. So a `python -c` program
  with a slash-bearing run that long is refused when every name before the run exists, and the
  same word in a file argument or stdin takes the same path, so moving it into a file does not
  help. Behind a missing name (`m/<300 bytes>`) the walk never reaches it: the element is bound
  `none` and the floor passes the word. `realpath` is not enough: plain, it keeps a link it cannot `lstat` as a plain
  name and a later `..` pops that name lexically, and before Python 3.13 strict and
  `ALLOW_MISSING` alike pop a `..` after a non-directory, so the string it returns is not where the
  kernel lands. A missing name walks on as the directory `install -D` creates, so a later `..`
  pops it and a later link is followed. A Python without `os.path.ALLOW_MISSING` (before 3.14,
  unless the tarfile CVE-2025-4517 fix was backported; Ubuntu's `python3.12` has it from
  3.12.3-1ubuntu0.7) predates those posixpath fixes, and the helper is tested only on one that
  has them, so there every run request is refused as
  `result=no-allow-missing` (exit 5, no ledger row). Through the CLI
  the floor reads the element first, so the answer is `result=never-remote rule=oversize` with
  a ledger row; `bad-file` (exit 5, no ledger row) is what a request the floor passes gets. At exec
  every element, argv[0] included, must resolve to the same target as at request, so a
  link relinked to another file, a directory or nothing, two links swapped between their
  files, a directory link retargeted, and a name that now names a file all report `changed`.
  A name that did not exist is held by the path it would land on, so a link above it that is
  retargeted, and an absent name that becomes a dangling link or a dangling link that is
  retargeted, report `changed` too: the command would write somewhere the operator never saw.
  A glued element such as `dd of=/path` is not read as a path: it is keyed by its lexical
  string, so a link above `/path` moved after the request is not seen. The slice 1b notice
  must show such an element as written, never as bound.
- A directory element is bound by the path it resolves to, not by its contents: a directory
  changed in place compares equal. The slice 1b notice must not present a directory argument
  as bound.
- The run is of the file in place, not of the copy, and a file a command loads itself (a
  script it sources, an interpreter's imports, a config it reads) is not bound. The executor
  opens argv[0] once (`open_regular`), compares the open file's `st_dev` and `st_ino` with the
  frozen record, hashes that open file, and starts the program from the same descriptor,
  named `/proc/self/fd/N` and passed through `pass_fds` as a path-only (`O_PATH`)
  descriptor made from the open file: a name swapped between the check and the start (a
  rename over it, a link retargeted) cannot change what runs, which is the file the operator
  saw. The descriptor is path-only because the open file was opened as root, and Linux checks
  access when a file is opened: a read descriptor passed on would let a program that starts
  first as the run-as user (a startup hook under its home) read a root-only script. The same
  is done for the script an interpreter runs: when argv[0] is a known interpreter (`sh`,
  `bash`, `python3`, `perl`, `ruby`, `php`, `lua` and kin; not `node`, whose loader resolves
  the main script's real path itself, so a renamed-away or planted `<path> (deleted)` name
  still runs other code) and no option before it supplies the program (`-c`, `-m`, `-e`, any `--` option),
  the first word that is no option and names a bound file is replaced by its held descriptor
  (a word that names no file, such as the `ignore` of `-W ignore`, is skipped; a file given
  as an option's value before the script is taken for the script).
  Other file arguments are hashed from an open file and compared by identity, but still
  opened by path by the command. What is left: a file edited **in place** (same inode)
  between the hash and the start, which the session can do when it can write the file; an
  interpreter outside the name list (`node` among them), or one given its script after
  `-e`-style options, re-opens the script by path; `sh` started as `/proc/self/fd/N` is not
  named `sh`, so where `/bin/sh` is bash it runs outside bash's POSIX mode; and the program sees `/proc/self/fd/N` as its argv[0], so a
  multi-call binary that picks its applet from argv[0] does not find it. A script run this
  way sees its own location as `/proc/self/fd/N` too: a shell script's `$0` and a Python
  script's `__file__` (a script that finds sibling files from either looks in the wrong
  place and fails); Python's `sys.path[0]` is still the real directory, because Python
  resolves the link. The operator's notice for such a script should say so. A same-bytes
  file with a new inode now reports `changed`.
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
record hash (`hash-mismatch`); argv[0] and each file by sha256 and `st_dev`/`st_ino`, taken
from one open file each (see above), the cwd identity and that
every argv element resolves to the same file, directory or not-yet-existing path as at request
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
`..`). The `key=value` form is the text after the first `=`; a word that starts with a run
of `=` derives the text after the whole run once, so a `====` banner is one word, not one
form per `=`. A word that derives more than 64 forms, or whose path the kernel cannot walk (the
same walk as the binding above), is refused as `rule=oversize`:

| rule | refuses |
|---|---|
| `disk-wipe` | mkfs/wipefs/blkdiscard/partitioners, block devices, `rm` of `/`, a top-level directory or home (or a `/*` glob of one), btrfs subvolume delete of `/` |
| `secret-read` | `/etc/shadow`, ssh and gpg keys, the Claude credentials and channel `.env`, `.env`, `totp.seed`, secret-tool/gh token/himmel-secrets reads |
| `main-history` | a force push or delete naming main/master (`--force*`, `--delete`, a `+` or `:` refspec, or a short-flag cluster carrying `f` or `d`: `-f`, `-d`, `-fu`, `-df`), deleting `refs/heads/main`, `gh repo delete` |
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

What the nonce does not close: anyone who reads the operator's notice-bot chat (a stolen,
unlocked phone) and also holds the authenticator can approve the request that notice
names. The nonce binds a code to the one request root described; it does not stop a
session from filing a misleading but truthful request (a script whose effect the operator
misreads), which is why the notice shows the script text and marks a shell.

## Ledger

`/var/log/himmel/afk-sudo.jsonl` rows gain `kind`, `run_as`, `hash`, `blocked_by`,
`why` (cleaned, 200 chars), `mode`, `argv` (elements over 120 characters cut to 100),
`argv0_sha256`, `frozen` (files, stdin size and hash, cwd), `stdout_bytes`,
`stderr_bytes`, `stdout_sha256`, `duration_ms`. A refusal at request writes a row for
`never-remote` and `not-in-class` (the helper) and for `locked`, `busy` and `rate-limited` (the
broker) only. The other request refusals (`run-not-shipped`,
`run-disabled`, `no-allow-missing`, `bad-user`, `bad-cwd`, `bad-file`, `no-such-command`, `no-setpriv`,
`stdin-too-large`, `no-notice-bot`) answer on stdout and write none. A notice that cannot be
sent writes a `notice` row (`notice-failed`). A wrong nonce writes a `code-check` row
(`bad-nonce`). After the code, the executor's result
(`hash-mismatch`, `changed`, `run-not-shipped`, `run-disabled`, `never-remote`, `bad-user`,
`not-in-class`, `no-setpriv`, or the run itself) is the row. The ledger never holds the code, the
nonce, the seed, any output or a stdin body. A `busy` refusal writes one row per session per 10
minutes.

## Spent steps (HIMMEL-8078 part 2)

A code valid for request A is refused (`replay`) for request B when A ended without
running in the same 30-second step. Deny, burn and a failed code check spend the
current step; an expiry spends the step the request ran out in (not the lazy detection
time). All writes keep the maximum step.

## The `grant` kind (HIMMEL-7686)

A grant lets one Bash call the permission classifier refused run once in the worker's own
session, after the operator approves it. Nothing runs as root: root only records the
approval, and the worker's retry passes the classifier for that one call.

1. The classifier refuses a Bash call. `scripts/hooks/approval-grant-request.sh`
   (`PermissionDenied`, matcher `Bash`) pipes the command's exact bytes to
   `sudo -n afk-sudo grant-request --session S --cwd D --why <reason>`. It prints nothing
   and exits 0 on every path.
2. Root refuses a secret read or another never-remote shape before any notice is sent.
   Otherwise it binds every file the command names (sha256 and dev/inode, as in the run
   kind), freezes the record and sends the operator the full command, the cwd, the bound
   files and the classifier's reason, labelled as a claim. The notice is built from root's
   record, never from the classifier-denial log.
3. The operator replies `NONCE CODE`. Root writes the grant
   `/var/lib/himmel/afk-sudo/grants/<id>.json` (root, 0600), with an expiry of now plus
   `grant.ttl_s`, and an empty marker `/var/lib/himmel/afk-grants/<sha256>.<id>` (root,
   0644, in a root 0755 directory).
4. The worker retries the same bytes. `scripts/hooks/approval-grant-check.sh`, the last
   member of the PreToolUse Bash chain, finds a marker for the hash and asks
   `sudo -n afk-sudo grant-spend --session S --sha256 H --cwd D`. Under a lock, root
   removes the grant before it checks anything, so the grant is spent whatever the answer.
   It then checks the session, the cwd's dev/inode, every bound file and the floor.
   Only `result=granted` gives an `allow`.

The marker is only a hint that saves a sudo call on every other Bash command. A marker
with no root grant behind it allows nothing, and a grant file that is not root-only
answers `unsafe-perms`. The guards in the chain still run: a deny from any of them wins
over the allow, and an ask from any of them still asks. `guard-identical-denied-retry.sh`
does not refuse a repeat while a marker exists for those bytes.

Residuals (ponytail: the grant binds the bytes and the files the command names, not what
it loads at run time, such as a package an `npx` call downloads; the upgrade path is the
run kind's frozen argv for anything that needs more):

- Files are found by splitting the command into shell words (operators such as `;` and
  `|` split too) and resolving each word against the request's cwd. A file the command
  reaches through a variable, a command substitution or a `cd` is not bound; the notice
  shows the full command for the operator to judge.
- The worker runs its own command after the spend checks the bound files, as the same
  user that can write them. A process of that user that rewrites a file between the check
  and the run is not caught: the binding catches changes made before the retry, not a
  worker racing its own call (layer decision: accept; the run kind, in which root
  executes the file it holds open, is the path for a command that needs more).
- An ask from another chain member on the retry still spends the grant.
- The worker learns of the approval from the operator or the chief, or by polling
  `sudo -n afk-sudo status <id>`. Nothing tells it directly.
- A request is filed only while `grant.enabled` is true. The helper keeps its own cap
  (one pending request, `max_per_hour`).

## Config keys

`mode`, `operator_user`, `max_per_hour` (default 6, max 30), `run.enabled` (default
false), `run.ttl_s` (default 900, max 3600), `run.timeout_s` (default 300, max 1800),
`grant.enabled` (default false), `grant.ttl_s` (default 900, 30 to 3600),
`never_remote_extra`. `install.sh` writes them with the safe defaults on first
install and never rewrites an existing config.

## Turning it off

Narrowest first. Each is a root edit of `/etc/himmel/afk-sudo.json` (`sudoedit`), read
again by the helper on every call, so it takes effect on the next verb:

1. `"mode": "allowlist"`: only the argv a class names runs. A pending free-form request
   answers `not-in-class` when it is approved.
2. `"run": {"enabled": false}`: no run request is filed, and a pending one answers
   `run-disabled` when it is approved. The sudo-class kind is unaffected.
   `"grant": {"enabled": false}` does the same for the grant kind, and every `grant-spend`
   then answers `grant-disabled`, so a live grant and its marker allow nothing.
3. `"enabled": false`: every verb except `mode` answers `result=disabled`, `approve` and
   `deny` included, so a pending request can no longer be approved and runs out its expiry.
4. Empty `/etc/himmel/afk-sudo/notice-bot.env` (`sudoedit`): no request of either kind is
   filed (`no-notice-bot`). A pending one can still be approved with the nonce already sent.
5. `sudo bash scripts/lib/afk-sudo/install.sh --uninstall`: removes the helper, the floor
   module and the sudoers rule. The config, the seed, `notice-bot.env`, the state and the
   ledger stay.

A session cannot do any of these: the config, the helper and the sudoers rule are root-owned.
The narrowing-only `/afk-lockdown` Telegram verb is slice S4, not built.

## Verbs

`request` (sudo kind, allowlist), `run-request`, `grant-request` (the command's bytes on
stdin), `grant-spend`, `approve`, `deny`, `status`
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

Once a request is filed, `afk-run` sends the bridge bot's id-only message with the Approve /
Deny buttons (token from `TELEGRAM_ENV`, default `~/.claude/channels/telegram/.env`, passed
to curl on stdin; skipped without a token; `AFK_TELEGRAM_API` overrides the Bot API base).
The facts and the nonce come only from root's notice bot.
