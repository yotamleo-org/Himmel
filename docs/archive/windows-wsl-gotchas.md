# Windows and WSL gotchas (archive)

> **Archived.** Windows is not a supported platform: himmel runs on Linux and
> macOS. These notes came from the Windows, WSL, Git Bash (MSYS) and PowerShell
> setups himmel used to run on. They are kept for reference only and are not
> maintained. Current gotchas live in
> [`environment-gotchas.md`](../internals/environment-gotchas.md).

## MINGW: `grep -iF` aborts on the `-i` + `-F` combination

Under MINGW (Git Bash), `grep -iF` aborts (SIGABRT, rc 134) on the `-i`+`-F`
combination even on pure ASCII input. Use `-F` alone.

## Windows WSL / Docker resource budget

WSL2 and Docker Desktop share the Windows host's CPU, memory, disk IO, and page
cache. They are isolation boundaries, not extra machines. On a multi-agent run,
an unbounded WSL distro plus unbounded Docker containers can starve the host,
Claude/Hermes, editors, browsers, and VirtualBox/e2e VMs.

Operational default for himmel on Windows:

1. **Use Git Bash for the control plane.** Run himmel scripts, Jira, handover,
   PR/check orchestration, and Hermes/Claude launchers from native Git Bash unless
   the task specifically needs Linux kernel semantics or a container.
2. **Cap WSL globally.** Put a conservative `%UserProfile%\.wslconfig` in place
   before using WSL for agents:

   ```ini
   [wsl2]
   memory=16GB
   processors=8
   swap=4GB
   localhostForwarding=true
   ```

   Tune the numbers to the host, but keep real Windows headroom. On a 48 GB / 32
   logical-core workstation, start around 16 GB and 8 processors for WSL; raise
   only after measuring. Apply changes with `wsl --shutdown`.
3. **Cap Docker separately.** Docker Desktop can run through WSL2 and still needs
   its own budget. Prefer Docker Desktop resource limits when available, and add
   per-container caps for agent/build jobs: `--cpus`, `--memory`, Compose
   `deploy.resources`/service limits where supported. Do not run unbounded
   `docker compose up` stacks while also fanning out agents.
4. **One heavy substrate at a time.** For parallel agents, pick the substrate:
   native Git Bash worktrees OR WSL shells OR Docker containers. Mixing all three
   is allowed only with explicit caps and a lower fan-out.
5. **Reserve non-negotiable lanes first.** VirtualBox/e2e VMs, the Windows host,
   the editor/browser, and MCP servers get headroom before agent workers. This is
   the same reservation model as the machine-aware concurrency ADR.
6. **Make profile selection explicit.** Hermes invocations launched from this repo
   should pass the intended profile (`--profile himmel_agent` on the operator's
   current machine; adopters use their own profile) so a WSL shell, Docker shell,
   or native Git Bash shell cannot silently select a different default profile.

Rule of thumb: if CPU stays above ~85%, free RAM drops below ~8 GB, or the host UI
starts lagging, stop spawning and shrink the substrate cap before retrying. Do not
solve host pressure by adding more agents.

## WSL: `wsl.exe` invoked from Git Bash mangles `/mnt` args

Calling `wsl.exe` from a Git Bash session puts every argument through MSYS path
conversion first: `/mnt/c/...` looks like a POSIX absolute path, so MSYS
rewrites it to `C:\msys64\mnt\c\...`-style Windows paths before `wsl.exe` ever
sees it — the command then fails inside the distro on a path that doesn't
exist. Measured live during an eval on a second Windows station
(2026-07-12).

Prefix the call with `MSYS_NO_PATHCONV=1`:

```bash
MSYS_NO_PATHCONV=1 wsl.exe -e bash -c 'ls /mnt/c/Users'
```

For `/`-prefixed argument *fragments* that are not standalone paths (flags like
`/tmp/x:/y` mappings, or args where only part is a path), `MSYS_NO_PATHCONV=1`
alone may not cover it — add `MSYS2_ARG_CONV_EXCL='*'` to exclude everything
from conversion. The in-repo precedent used to be the CodeRabbit WSL lane in
`scripts/cr/coderabbit-review.sh`; that script has since been deleted,
so the rule now stands on its own.

## WSL: the /mnt/c performance cliff

WSL processes operating on a Windows checkout through `/mnt/c` are not "a bit
slower" — they are the **worst possible configuration**, slower than Git Bash
itself. Measured on the himmel repo (a second Windows station, 2026-07-12):

| operation | Git Bash (C:\ checkout) | WSL on `/mnt/c` | WSL on ext4 clone |
|---|---|---|---|
| `git status` | 89–142 ms | **4,290–18,839 ms** | 27 ms (warm) |
| `grep -r` over `scripts/` | 397–480 ms | 4,438–4,472 ms | 24–26 ms |

That is a 30–130× `git status` penalty vs Git Bash, and up to ~700× vs a
WSL-native clone. The 9P filesystem bridge pays per-file round-trip costs that file-heavy
tools (git, grep, build systems) multiply by thousands. The rule, from the
Microsoft filesystem guidance and confirmed by these numbers: **work must live
on the filesystem native to the executing side.** WSL work ⇒ ext4 clone
(`~/...` inside the distro); never route file-heavy WSL commands at `/mnt/c`.
Fork-heavy-but-file-light work (subshell/pipeline benchmarks) is fine either
side — the cliff is filesystem IO, not process spawn.

## WSL: himmel hooks fail closed when the distro lacks the toolchain

himmel's Claude hooks parse their JSON stdin with `jq` and **fail closed** —
a missing `jq` reads as "cannot verify, refuse". In a bare WSL Ubuntu (no
toolchain provisioned), `block-destructive-commands.sh` refused in 240 ms
during that eval: fast, silent, and every guarded operation is
blocked, which presents as "hooks are broken under WSL" when the actual
problem is a missing binary.

A WSL lane or WSL station therefore needs the toolchain **provisioned
in-distro** (`jq`, `node`, `gh`, `bun`, … — `scripts/machine-setup/ubuntu.sh`
is the base), not just bash. The Windows-side installs are invisible to the
distro; Windows interop only exposes `.exe` binaries, and the hooks invoke
plain `jq`/`node`.

## Windows: `python3` / `python` may be the WindowsApps Store stub

On a box with no classic CPython install, `python3` and `python` resolve to the
Microsoft Store WindowsApps stub (`PythonSoftwareFoundation.PythonManager`). The
stub can **wedge machine-wide**: it ignores `SIGTERM` (so GNU `timeout` without
`-k` waits forever, and its orphan child holds inherited stdout pipes so `$(…)`
command substitution blocks even after a kill), and has been observed to then
fail with "The specified disk or diskette cannot be accessed (os error 26)".

Mitigations for scripts that must call `python3`:

- Install a real interpreter (e.g. `uv python install 3.12`) and shim a wrapper
  dir onto `PATH` for test runs.
- Always wrap with `timeout -k 5 10` (the `-k` is mandatory) **and** redirect
  stdout to a file, never command substitution.

## Windows: `graphify install` writes a backslash exe path that dies under Git Bash (Claude hooks)

`graphify install` (graphifyy ≤ 0.9.18) writes hook commands whose executable is
an absolute **Windows path with backslashes** — e.g.
`C:\Users\<you>\.local\bin\graphify.EXE hook-guard search` — into the harness hook
configs. Whether that breaks depends on the shell each harness runs hook commands
through on Windows, which **differs by harness** — so "fix it everywhere the same
way" is wrong:

- **Claude Code runs hook commands through bash** (Git Bash). Bash consumes the
  backslashes, so the command collapses to `C:Usersyou.localbingraphify.EXE` →
  `command not found`, and the hook fails on **every** Bash/Read/Glob call. It is
  *non-blocking*, so the only symptom is a repeated `PreToolUse hook error …
  command not found` line and the graph-context injection silently never firing.
  **This is the breakage you actually observe.**
- **codex runs hook commands through cmd.exe**, not bash — via its
  `.codex/run-hook.cmd` cmd wrapper (removed, HIMMEL-5729; whose own comments note "bare `bash` via
  cmd.exe hits the WSL System32 stub"). cmd.exe does **not** eat backslashes, so
  `C:\Users\…\graphify.EXE …` runs there unchanged — the codex graphify hooks
  are **not** broken by the backslash path. Do **not** "fix" them by copying Claude's MSYS `/c/…` form: see
  the verification below.

Root cause is upstream: `graphify/install.py::_resolve_graphify_exe()` returns
`shutil.which("graphify")` (a backslash path) and the hook builders interpolate it
**unquoted** (`f"{exe} hook-guard search"`). The in-code "#522 fix" comment ("parses under sh, cmd.exe
and PowerShell alike") does not hold for Windows + a POSIX hook shell.

**Fix — use the forward-slash Windows path, the one form that works in every
executor:** `C:/Users/<you>/.local/bin/graphify.exe hook-guard search`. Verified on
this host: in **bash** both `/c/Users/…` (MSYS) and `C:/Users/…` run; in **cmd.exe**
only `C:/Users/…` runs — the MSYS `/c/…` form returns "the system cannot find the
path specified". So the MSYS `/c/…` form fixes Claude but **breaks** a cmd.exe
harness (codex); the forward-slash `C:/…` form is universal. Affected
configs: `.claude/settings.json`, `.codex/hooks.json`
(and `~/.claude/settings.json` if installed globally).

**Quote the exe if its path contains a space.** Removing backslashes is not enough
when the path itself has a space — e.g. `C:/Users/Jane Doe/.local/bin/graphify.exe` <!-- leak-allow: home-path doc example -->
— because the command runs through a shell that word-splits an unquoted string
(bash splits on the space; cmd.exe treats `C:/Users/Jane` as the program). <!-- leak-allow: home-path doc example --> Wrap the
executable in quotes inside the command value (JSON-escaped, e.g.
`"\"C:/Users/Jane Doe/.local/bin/graphify.exe\" hook-guard search"`), or install <!-- leak-allow: home-path doc example -->
graphify to a space-free path.

Re-install caveat: 0.9.18 `graphify install` (claude) no longer writes
settings.json hooks (skill + CLAUDE.md + version-stamp refresh only), so a fixed
Claude hook survives re-install — but `graphify codex install`
still re-emits the backslash path (harmless under cmd.exe, but re-normalize
to the `C:/…` form for consistency + space-safety). A durable himmel-owned
post-install path-normalizer is a known gap.

Upgrade gotcha: `uv tool upgrade graphifyy` from **inside** a live session running
the graphify MCP server + hooks can leave the `graphify` CLI shim unwritten — a
Windows file-lock on the venv `Scripts\` dir (`Access is denied`) — while `uv tool
list` still reports the new version. Repair from a context where `graphify-mcp` is
not running: stop those processes, then `uv tool install "graphifyy[all,ollama]" --force`.

## Windows: `schtasks /create /xml` rejects a UTF-8 prolog

`schtasks /create /xml` rejects an `encoding="UTF-8"` XML prolog with
`"(1,40):: unable to switch the encoding"`. Declaring `encoding="UTF-16"` over
plain-ASCII bytes is accepted. So: write the task XML ASCII-only and declare
UTF-16 (a genuinely non-ASCII value would need a real UTF-16LE+BOM file). The
reason to use `/xml` at all is that `schtasks /create` has no flag for
`StartWhenAvailable` (run a missed scheduled start when next available) — the only
CLI route to that setting is `/create /xml`.

## Windows: pre-commit auto-fixers crash on non-ASCII filenames (and mangle the file first)

The pre-commit-hooks `trailing-whitespace` and `end-of-file-fixer` fixers print
the path of each file they touch (e.g. trailing-whitespace's
`print(f'Fixing {filename}')`). On Windows that
`print` goes to a cp1252-encoded stdout, so a filename containing non-ASCII
characters — Hebrew/CJK/accented source notes, common in luna / Salus medical
vaults — raises `UnicodeEncodeError: 'charmap' codec can't encode…` and the hook
exits non-zero. **Worse: the fixer rewrites the file (strips trailing whitespace
across the whole file) *before* it prints, so the abort leaves a silent
whitespace-only diff** — a 217-page verbatim extraction once produced a 20k-line
diff that had to be manually restored.

Two independent mitigations:

- **Repo-config (preferred, inherited):** don't let the auto-fixers run on
  non-code files at all. In a content repo (a vault), notes and ingested sources
  are user data — pre-commit should validate them (gitleaks/check-*) but never
  rewrite them. Constrain both fixers to an ASCII-named code/config **allowlist**
  rather than a denylist (a denylist can't enumerate every non-ASCII name a vault
  might hold):

  ```yaml
  - id: trailing-whitespace
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  - id: end-of-file-fixer
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  ```

  This is what the luna-second-brain template ships. pre-commit has
  **no per-hook `env:` key**, so encoding can't be forced from the config itself.
- **Machine env (defense-in-depth, for code repos where the fixers must run on
  arbitrary paths):** export `PYTHONUTF8=1` (or `PYTHONIOENCODING=utf-8`) in the
  shell that runs `git commit`, which forces every Python hook to a UTF-8 stdout
  and stops the crash. Note this only prevents the *crash* — the fixer still
  rewrites the matched file, so it's not a substitute for the allowlist when the
  rewrite itself is unwanted.

## Windows: `schtasks /create /sd` parses the date in the MACHINE's regional format

The same arm command lands months away on a machine with different locale
settings — a same-day `/sd` date written as MM/DD parses as DD/MM on a
DD/MM-locale machine (observed: a 03:20 same-day task landing three months
out; the task sits `State=Ready`, `LastRun=never`, result `267011` /
`SCHED_S_TASK_HAS_NOT_RUN` — a silent no-launch). After ANY scheduled-task
creation on a machine not yet proven, verify
`(Get-ScheduledTaskInfo <name>).NextRunTime` is the intended datetime — never
trust the creation SUCCESS message.

`arm-resume.sh` is now structurally guarded against this: its
Windows path reads `HKCU\Control Panel\International\sShortDate` and renders
`/sd` in the machine's own pattern (falling back to the old hardcoded
`MM/dd/yyyy` on any registry-read failure), then runs the
`Get-ScheduledTaskInfo` check above after every create — a mismatch beyond a
120s tolerance (or a missing/null `NextRunTime`) deletes the just-created task and refuses
(rc=2) instead of leaving a silent months-out arm. Any OTHER hand-rolled
`schtasks /create /sd` call outside `arm-resume.sh` remains exposed to this
trap (and remains forbidden — go through `arm-resume.sh`).

## MSYS `/tmp` is the Windows user temp dir — temp cleaners delete it under you

In Git Bash, `/tmp` maps to `%LOCALAPPDATA%\Temp`, which Windows Storage Sense
(and other temp cleaners) prune on their own schedule. Anything long-lived
placed there — a git worktree, a patch you plan to apply later — can vanish
mid-flow, leaving `git -C` failing "No such file or directory" plus a dangling
worktree record. Keep work products in the session scratchpad or a home-dir
path, finish flows that stage in `/tmp` in the same sitting, and remember
PowerShell and Windows-native node cannot see MSYS paths — `cygpath -m`
first, or parse JSON files under `/tmp` with `jq` rather than a node
one-liner in Git-Bash pipelines. (`git worktree prune` cleans up the
dangling record afterward.)

## MSYS mangles `git show "rev:.dotfile"` — read dotfiles by blob SHA

Paths starting with `.` in a `rev:path` spec get MSYS path-mangled and the
command SILENTLY returns empty — a grep pipeline over it false-negatives.
Read the blob directly instead: `git ls-tree <rev> -- <path>` →
`git cat-file -p <sha>`; for drift detection compare `ls-tree` blob SHAs.
`MSYS_NO_PATHCONV=1` is unreliable inside `<(…)` substitutions.

## Git-Bash `timeout` does not reap grandchildren holding a `$()` pipe

Under Git Bash, `timeout` kills its direct child, but a grandchild (a `sleep`,
a `curl`) inheriting the command-substitution pipe keeps `$(…)` blocked past
the timeout — the caller hangs and the process leaks. In test stubs, `exec`
the long-running command (`exec sleep 30`) so the timeout target IS the
process holding the pipe; in scripts, avoid `$(timeout … cmd-that-spawns)`
shapes.

## Windows: the 1Password SSH agent breaks unattended runs

With 1Password's SSH agent enabled, it hijacks the `\\.\pipe\openssh-ssh-agent`
named pipe and pops a GUI authorization prompt on every signature — fatal to
any unattended/scheduled session that shells out over SSH. Fix: 1Password →
Settings → Developer → untick "Use the SSH agent" (the setting is
integrity-signed; GUI-only), then re-enable the stock agent elevated:
`Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`.
Only native Windows `ssh.exe` hits the pipe — paramiko-based tooling and git
SSH signing via `ssh-keygen.exe` are agent-free. Verify with the native
`ssh-add -l`, not the MSYS one.

## Windows: `ssh` into a Windows host lands in cmd — multi-line PowerShell needs `-EncodedCommand`

OpenSSH on a Windows target defaults the remote shell to `cmd`. Wrap
one-liners in `powershell -NoProfile -Command "…"`. For MULTI-LINE scripts,
do NOT pipe stdin into `powershell -Command -` — its stdin reader can
silently stop after the first line of multi-line ForEach/try-catch blocks,
with no error. Use `-EncodedCommand` with a UTF-16LE, base64-encoded payload
instead — robust across every quoting layer. Never add
`-ExecutionPolicy Bypass`: the flag sets the policy for the whole
`powershell.exe` session (it is not `-File`-only), an inline
`-Command`/`-EncodedCommand` payload doesn't need it, and it reads as a
security bypass to auto-mode classifiers.

Nested hops multiply the quoting problem: `ssh → cmd → wsl → bash` mangles
inline `$` (a `$HOME` arrives literal). Base64 the bash payload and run
`echo <b64> | base64 -d | bash`. Detach long remote jobs with explicit
stream redirection — `setsid … </dev/null >job.log 2>&1 &`. Bare
`nohup … &` only auto-redirects when attached to a TTY, so over ssh's
non-TTY pipes those streams stay wired to the channel and a drop can still
kill or hang the job; redirect all three explicitly.

## Windows: a scheduled-task-hosted service can be DOWN while its task reads "Ready"

Services hosted as scheduled tasks (a Grafana under an `-AtLogOn` task, a
metrics exporter) fail in ways task state doesn't show:

- **"Ready" means idle, not running.** A stopped `-AtLogOn` Grafana looks
  fine in `Get-ScheduledTask`. Before any API call, `Start-ScheduledTask`
  explicitly, then POLL `/api/health` until it returns `database: ok` or a
  bounded deadline (~30s) expires — don't rely on a fixed sleep, since start
  time varies (first start also initializes its sqlite DB) so a fixed wait is
  either too short or wasteful. On timeout, report the task's current
  `Get-ScheduledTask` state alongside the failure. The failure when skipped is
  connection-refused ("Unable to connect to the remote server") — do NOT
  misdiagnose it as an auth/credentials problem.
- **Restart ≠ new code, and task success ≠ serving.** A restart picks up
  whatever code is ON DISK — update the checkout to the target commit
  BEFORE `Stop-ScheduledTask; Start-Sleep 2; Start-ScheduledTask` — and
  verify by the live endpoint
  (`curl -s http://127.0.0.1:<port>/metrics | findstr <new-field>`), never
  by task state: the task can report success while serving stale code.
- **Never string-interpolate a JSON API body.** A PowerShell double-quoted
  string silently blanks literal `${VAR}`-style tokens that dashboard JSON
  legitimately contains (e.g. `${DS_PROMETHEUS}`). Build request bodies
  with `ConvertFrom-Json` → edit → `ConvertTo-Json -Depth 100`.

## WSL git cannot read a Windows-created worktree

A worktree created on the Windows side stores a Windows-style path in its
`.git` pointer file, which WSL-side git cannot resolve — WSL git commands
against that worktree fail (plain file reads still work). Cross-environment
flows that need git on the WSL side (a WSL review lane over a Windows
worktree) need an explicit temp-clone/copy step; never aim WSL git tooling
directly at a Windows-created worktree.

## WSL: boot-time bind mounts belong in `/etc/wsl.conf` `[boot]`, not `/etc/fstab`

A bind mount a WSL-hosted service needs at distro start is not reliably up
when declared in `/etc/fstab` (WSL's boot mount-ordering is not what fstab
implies). Put the mount under `[boot]` in `/etc/wsl.conf`
(`command = mount --bind …`) so it runs at distro init.

## Windows PowerShell: embedded double-quotes in native-command args get STRIPPED — and a non-atomic write then blanks the file

Do not pipe a jq filter containing embedded `"` (e.g.
`jq '.enabledPlugins["a@b"]=true' file`) through PowerShell: PowerShell
re-parses native-command arguments and strips the inner double-quotes, so
jq receives `.enabledPlugins[a@b]` → syntax error → **empty stdout**. If
the caller then writes that output non-atomically
(`[IO.File]::WriteAllText($file, $out)`), the config file is blanked —
this live-corrupted a machine's `~/.claude/settings.local.json`.

Three rules:

- **No jq-with-quotes from PowerShell.** Write the literal JSON string
  directly, or do the jq work from Git Bash (jq-in-bash is fine).
- **Config rewrites are temp-file + atomic move, never in-place.** Write
  the temp file on the SAME volume as the target, validate the output
  (non-empty, parses) before the move, and use an atomic rename — under
  those preconditions a mid-pipeline failure cannot blank the live file.
- **Remote multi-shell exec (`ssh → cmd → powershell`/`wsl`): base64 the
  whole script** (`powershell -EncodedCommand <utf16le-b64>`;
  `wsl bash -lc "echo <b64> | base64 -d | bash"`). This kills every layer
  of nested-quote escaping at once — see the `ssh` section above; `\$HOME`
  through ssh'd single-quotes arrives literal, another reason to base64.

## WSL2 cannot reach host `127.0.0.1`-bound services via the gateway IP — use mirrored networking

Services that bind loopback only (Obsidian Local REST API, a local
CLIProxyAPI gateway, most dev servers) are unreachable from WSL2 through
the often-documented NAT gateway IP (`ip route show default`): the request
returns HTTP 000 because the listener is `127.0.0.1:<port>`, not
`0.0.0.0` — and `localhostForwarding` does NOT bridge the WSL→host
direction either. The fix is mirrored networking. In
`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored

[experimental]
hostAddressLoopback=true
```

then `wsl --shutdown` and restart the distro. Per Microsoft's WSL docs,
mirrored mode itself is what lets WSL reach Windows-host listeners via
`127.0.0.1`; `hostAddressLoopback=true` additionally allows reaching the
host through its assigned IPv4 addresses. The pair above is the
live-verified working config. WSL `127.0.0.1:<port>` then reaches the
host service directly, and because the client connects via `127.0.0.1`,
a self-signed cert bound to `127.0.0.1` keeps its SAN match. Requires
Windows 11 22H2+ (build 22621+). It is a global change
(all distros; can interact with Docker Desktop/VPNs), so gate the
`wsl --shutdown` on the operator — but it solves the whole loopback class
at once, which is why it beats per-service `netsh portproxy` rules.

## Windows: native `jq` writes CRLF, poisoning every `$(jq -r ...)` capture

The native Windows `jq` (winget `jqlang.jq`) writes stdout in **text mode**:
`jq -r` emits `value\r\n`, not `value\n`. Command substitution strips only the
trailing *newline*, so every value captured via `$(jq -r ...)` carries an
invisible trailing `\r` — silently turning a `jq --arg k "$k" '.[$k]'` lookup
into `null` (the key never matches) and poisoning any such value that ends up
in a URL or path. Fix at the single chokepoint, not per-call-site: see the
`jq()` shim in `scripts/upstreams/upstream-watch.sh`, which
wraps every `jq` call in the script with `| tr -d '\r'` rather than patching
each capture site individually.

- **`grep` cannot answer a line-ending question in Git Bash at all — it reads
  in TEXT mode and strips the CR before matching.** Measured on GNU grep 3.0 /
  bash 5.3.15 against a pure-LF file and a real CRLF file, both written by
  `printf` and confirmed by `od -c`:

  | form | pure-LF file | real CRLF file | verdict |
  |---|---|---|---|
  | `grep -c $'\r' f` (bare) | 0 | **0** | false NEGATIVE |
  | `grep -c $'\r$' f` (bare) | 0 | **0** | false NEGATIVE |
  | `n=$(grep -c $'\r' f)` | **3** | 3 | false POSITIVE (`= wc -l`) |
  | `n=$(grep -c $'\r$' f)` | **3** | 3 | false POSITIVE (`= wc -l`) |
  | `grep -Uc $'\r' f` | 0 | 3 | correct |
  | `tr -cd '\r' < f \| wc -c` | 0 | 3 | correct |

  `-U` (binary, no CR stripping) flipping the CRLF column from 0 to 3 is what
  identifies text-mode reading as the mechanism — the bare form fails on a file
  that genuinely IS CRLF, so it is not "correct when run directly". The nested
  `$( )` column reads exactly `wc -l` on a file with no CR in it at all, which
  is how a worker once talked itself into converting three pure-LF `.sh` files to
  CRLF (shellcheck SC1017 was what stopped it). **Do not theorise about which
  form is safe — measure with `tr -cd '\r' | wc -c`, or `grep -Uc`.** For a
  committed file read the bytes filter-free: `git cat-file -p <ref>:<path> |
  tr -cd '\r' | wc -c` (`git show <ref>:<path>` is byte-identical here, so
  either works — the "git show normalizes" claim this entry used to carry was
  false and is corrected).

  And run BOTH controls, every time: a known-CRLF file must read non-zero and a
  known-LF file must read 0. A 100%-match count needs a negative control
  exactly as a zero needs a positive one, and corroborating evidence that
  contradicts a headline count is signal, not noise to explain away.
