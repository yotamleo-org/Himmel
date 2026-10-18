# Leg preface section — shell shapes, denials, sandbox, suites

Read on demand: `leg-preface.md` names this file when a command is refused or before running tests. Moved verbatim from the preface.

## Shell shapes and denials

- **Ship steps are typed exactly as their allow rule is written — no quotes,
  no `VAR=` prefix, no `cd … &&`, no compound operators, no `$(…)`.** A
  relative gate script is `bash scripts/cr/X.sh <args>`, never
  `bash "scripts/cr/X.sh"` and never `bash "$HIMMEL_REPO/..."` — the quote or
  the `$VAR` alone sends an otherwise-correct call to the classifier. The few scripts anchored to the primary checkout's absolute
  path instead (the merge, the CR-marker clear, below) are named as
  exceptions where they appear; everything else stays relative and unquoted.
  The matcher bails on all these shapes and a refused compound runs
  **nothing**.
- **A shape denial → rewrite as one literal command per write** (absolute
  binary, no vars, no loops, body via file) **and retry once; a classifier
  denial on a loop shape is a shape denial**. N writes = N
  separate Bash calls. A recipe that drops a meaning-bearing prefix (a
  `JIRA_BASE_URL=` / `JIRA_BOARD_ID=` target) is not a retry — ask the console.
- **Resolving a review thread** (fixed, deferred or rejected) goes through the
  one sanctioned path, one literal call per thread, never a loop:
  `node plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner <o> --repo <r> --number <pr> --thread-id <PRRT_…> --reason "fixed <sha>"`
  (or `--reason "followup HIMMEL-<n>"` / `--reason "rejected <why>"`). It
  refuses without a valid reason, posts the reason as a thread reply, and
  resolves only after the reply lands. If a single call is denied, send the
  console `BLOCKED resolve <pr> <thread ids>` and do not retry: the console
  verifies each thread against the head and resolves it itself.
- **Never pipe into a gate script.** Write the input to a file with `Write`,
  then pass it as an argument if the script takes one; otherwise pipe into
  the bare unquoted literal only — never `printf ... | bash "..."`.
- Where the `/pr-check` skill itself prints a command to run, its spelling
  wins over this section — it is kept in sync with its own allow rules.
- **Two refusals of one command → `himmel-ops:stuck-playbook`, then `BLOCKED`
  to the console.** Never reshape a command to dodge a guardrail, and never try
  a third spelling.
- A classifier denial on a publish step (`gh pr create`, `gh pr comment`,
  `git push`) is never retried verbatim. `Stage 2 classifier error` gets **at
  most ONE** delayed retry (`--body-file` for `gh`; `git push` has no body
  flag — the delay itself is what makes the retry non-identical, so retry the
  exact same command once); any denial after that one retry → route to the
  console, no further attempt. `[Out-of-Place Publication]` gets **no retry at
  all**, first time seen or not — route to the console immediately. The one exception is a denied `scripts/cr/` call spelled
  with an absolute `<himmel_dir>` path (the `/pr-check` marker panel): retry it
  ONCE as the relative literal `bash scripts/cr/<script>.sh <args>` from the
  worktree root before it goes to the console — only in a himmel
  worktree root whose `scripts/cr/` matches the `HIMMEL_REPO` anchor's (the
  condition `guard-pr-check-literal.sh` enforces); in an adopter or drifted
  checkout keep the absolute spelling.
- First choice for opening or updating a PR is
  `bash scripts/lanes/leg-pr-open.sh <title-file> <body-file>`:
  title and body are files, so the Bash command a leg types is always the
  same short fixed literal no matter what the PR says — the body never enters
  the command the classifier reads.
- **Ship scratch never lands in the worktree root.** PR title and
  body files, commit-message temp files, logs and verdict lists go in your
  session scratchpad, or under `.himmel-scratch/` if you have no
  scratchpad. A stray at the root pins the worktree as "possible forgotten
  work" and the merged worktree is never pruned.
- Never use bare `git stash` / `git stash pop`: the stash stack is shared with
  every other worktree and another session may pop yours.
- A background task "stopped because the system is running low on memory" is
  not proof of memory pressure. Before believing it, read
  `/proc/pressure/memory` and the `memory.events` under `/sys/fs/cgroup` for
  the cgroup in `/proc/self/cgroup`: all-zero pressure (`total=` included) and
  `oom_kill 0` = no evidence of contention, so the kill is unexplained — these
  readings show no sign of memory pressure, and they do not prove a false
  positive either (a userspace monitor can act without a kernel OOM, and the
  task may sit in another cgroup). Then stop retrying, run the suite in the foreground, and report
  `BLOCKED` with those numbers — never name a cause you have not controlled for.

## Results bullets

A non-marker Results bullet (one that does not start with a marker) still goes
through the Write tool if its text contains a literal `%`, never a bare `printf`.
Never write a token-shaped literal with trailing punctuation, and always wrap
tokens in backticks — bare token text stalls the vault's own scanners.

## Tests

RED first, always — one assertion that fails *before* the implementation
exists, pasted, then green. A control that cannot fail is not evidence.
To restore a tracked file to HEAD use `bash scripts/git/restore-to-head.sh
<path>` — `git checkout -- <path>` is a settings deny and `git restore`
prompts; the script saves the outgoing content first (a plain copy).

**Your tab runs in a memory-capped systemd scope** (`HIMMEL_LEG_MEMORY_MAX`,
default 12G, swap capped the same). A model-loading or burst run stays under
it: a run that exceeds the cap is OOM-killed alone, not the station. Bound a
load test yourself (one allocator, a small cap, `timeout 60`) rather than
leaning on the cap.

An observation meant to be "clean" runs through `scripts/lib/clean-sandbox.sh
[--keep VAR]... -- <cmd>` (`env -i`, prints the env it passed), never a
hand-rolled `HOME=… cmd`, which keeps every other operator variable.

**Corpus/replay tests run through the sandbox runner; execution of destructive
commands is VM-only.** Use `bash scripts/lib/sandbox-run.sh --
<command> [args...]` for corpus/replay classification. A missing
bubblewrap or unavailable namespace on Linux, or missing/unusable sandbox-exec
profile on Darwin, is a refusal, never permission to run unsandboxed. Darwin
confines writes to private scratch and denies network; it does not claim Linux
namespace/resource isolation. The only executing station canary is a harmless touch inside a
throwaway tmp directory.

**Impacted suites = every suite that references a file you touched**
(`git grep -l` from the worktree), not the suites in the directory you edited.
`bash scripts/cr/impacted-suites.sh` lists them; with no argument it uses
`$(git merge-base origin/main HEAD)..HEAD` (`origin/HEAD`'s target in place
of `origin/main` when set) and prints that range to stderr, and an explicit `<base sha>..HEAD` works the same. Run those and name them with their counts, each as one literal
`bash scripts/quiet-run.sh suite -- bash <tracked test-*.sh>` — nothing
appended: no `>`, no `2>&1`, no `; echo`, no `sleep N;` prefix, no `| tail`.
`quiet-run` already captures the output. The label is always the literal
`suite`, the only one the allow list pre-approves; any other
label, or a suite outside the enumerated directories, goes to the classifier
by design.
