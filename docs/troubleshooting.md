# Troubleshooting

Audience: a user on a starter install who saw a message and wants to know
what it means.

**How to use this page:** search it for the message you saw. Each row starts
with the message as himmel prints it, where `<branch>` or `<n>` stands for a
value from your project. The row says why you see it and what to do.

**Refused by a guardrail?** A hook or git gate that stops an edit, a commit on
main or a push to main is covered on
[When a guardrail stops you](internals/stuck-playbook.md). This page does not
repeat those refusals.

**Want a health check?** Run `/himmel-doctor` in Claude Code. It prints a
report grouped by severity, and each finding names its own fix. The findings a
starter install can show are in [Checking the install](#checking-the-install).

## While installing

| What you see | Why | The fix |
| --- | --- | --- |
| `WARN: 'bun' not found — qmd search will be skipped;` | qmd, the local notes search, runs on bun. A starter install does not use it. | Nothing to do. To add notes search later, install bun from <https://bun.sh> and run the install again. |
| `The install is uncommitted on <branch>, which the git gates now refuse commits on.` | The install did not commit itself: you answered no, or it ran without a terminal and could not ask. The git gates it just installed refuse commits on main, apart from this one. | Run the command printed on the next line, `Commit it once with: …`. It makes the one allowed commit on main. |

## Starting a worktree

| What you see | Why | The fix |
| --- | --- | --- |
| `WARN new-worktree: no 'origin' remote - branching from local '<branch>'` | The project has no `origin` remote, so the new worktree branches from your local main. | Nothing to do for a local project. Once the project has a remote that holds its main, run `git remote add origin <url>` and `git fetch origin`; later worktrees branch from `origin/main`. |
| `WARN new-worktree: uniqueness-vs-merged-PR check skipped (forge unreachable)` | Before it creates a branch, `scripts/worktree.sh` checks that no merged pull request already used the name. It needs a GitHub `origin` and a signed-in `gh` for that, and found neither. | Nothing to do: the worktree was still created. The check runs again once the project has a GitHub remote and `gh auth status` shows you signed in. |

## Committing

| What you see | Why | The fix |
| --- | --- | --- |
| `COMMIT REJECTED: no ticket reference matched:` | Every commit message needs a ticket reference by default. Unless you set your own pattern or a Jira project key, the reference is `#` and a number, such as `#1`. The lines under the message show which pattern applies. | Add the reference: `git commit -m "feat: add hello #1"`. To drop the rule for every project on this machine, run `himmelctl config set commit.tracker none`. |
| `COMMIT REJECTED: message does not match conventional commit format.` | Commit messages follow the conventional format `type(scope): message`, with a type such as `feat`, `fix`, `docs` or `chore`. | Reword the message, for example `git commit -m "docs: explain the setup #1"`. The refusal lists every type it accepts. |

## Checking the install

`himmelctl status` lists every item the install manages. Each row is `green`,
`degraded`, `red` or `n/a`.

| What you see | Why | The fix |
| --- | --- | --- |
| `of them desired but not set up: see the n/a rows above` | Your install profile asks for these items, but they are not set up yet. On a starter install most are opt-in, such as the Jira keys, or appear on first use, such as the handover folder. | Read the `n/a` rows: each names what turns it green. An opt-in item you do not use can stay `n/a`. |
| `<n> himmelctl install/wiring finding(s) (delegated from 'himmelctl status --json')` | `/himmel-doctor` found items that `himmelctl status` reports `red` or `degraded`. | Run `himmelctl status` to see them, then `himmelctl ensure`, which installs or rewires each one. |
| `hook(s) wired to a bare interpreter not installed on this host:` | A hook in your settings starts with a program this machine lacks, so every session prints `<interp>: command not found` and the hook never runs. | Install the program it names, or run the install again so it rewires the hook. |
| `plugin(s) enabled but not installed:` | Your settings turn on a plugin that Claude Code has not installed. | Install it with `claude plugin install <id>`, or set it to `false` in the settings file the finding names. |
