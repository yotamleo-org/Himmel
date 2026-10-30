# Model-check evidence for a judge

A chief commissions an isolated model-check worker/subagent to produce a
bounded TLC report and a Mermaid statechart for a PR that changes `scripts/handover/queue-lock.sh` or
`scripts/handover/chief-kit/succession-tracker.sh`. This is optional evidence,
not a new merge gate. A clean report never replaces the judge: the with-skill
arm of HIMMEL-8218 missed HIMMEL-8273, which the no-skill arm found.

## Optional prerequisites

Java is optional. Without it the step prints installation instructions, exits
3, and does not run a report or install anything. Install OpenJDK 21 if wanted:
Ubuntu `sudo apt install openjdk-21-jre-headless`, or Arch
`sudo pacman -S jre21-openjdk`. A VM with the same prerequisites also works.

The chief supplies these paths in the launching shell:

- `JAVA`: Java executable (defaults to `java` on PATH).
- `TLA2TOOLS`: absolute path to `tla2tools.jar` **outside the repository**.
  Use v1.7.4 from
  <https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar>.
  The script copies it into private temporary storage and checks sha256
  `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`
  before executing any Java. A mismatch exits 2. No automatic download or mise
  install is allowed by this entry point.
- `STATECHART`: the single executable path to the reviewed `/statechart`
  compiler: an external copy of `cursor/plugins` at
  `4dd1d05818d19792e7cd6e818f1667f95f7e1dbe`, path
  `pstack/skills/statechart/scripts/statechart`, or the same pinned tree at
  `marketplace/plugins/pstack/skills/statechart/scripts/statechart` when vendored.
  The wrapper snapshots the entire launcher directory (including reachable
  compiler modules), rejects symlinks, checks its tree SHA-256 against
  `569c34baed9a2b1e56029556aa04d6e4b2b2ca3c7211f5ac4ab8049d1319eb13`,
  and executes only that checked private snapshot. Any changed tree refuses
  before execution; the digest is recorded in complete and incomplete reports.
  The tree digest hashes each sorted relative UTF-8 path, NUL, then its raw
  SHA-256 file digest, including test/config files. A different reviewed vendor
  tree needs an explicit pin update, never a caller-provided expected hash.
  This change does not vendor or install that plugin.
  Its runtime needs Node 22.18–22.x or 23.6+, Bun 1.1.5+,
  or Deno 2; Python 3, GNU timeout, sha256sum, realpath, jq and authenticated gh
  are also required by the wrapper.

Do not install the separate `pele@1.9.0` render path. The docs site already
uses Pele 1.10.0; `chart.mmd` is the portable artifact.

## Prepare and run

The chief assigns this step to its own worker or subagent, never executes
statechart in the chief session. The chief and judge consume the report,
chart and retained `inputs/` as needed to check fidelity; they do not run the
compiler or ingest its execution transcript. The execution worker carries the
runtime cost/context, leaving the chief free to coordinate while TLC runs.

Read the PR's source at its full head SHA. In external scratch, write a
reviewed `Model.tla`, adjacent `Model.cfg`, and `view.mjs`. The view exports
only upstream's `state`, `step`, `group`, `colors`, and `title`; use plain
operator words for states and actions. It is executable, trusted chief-authored
code, not an attachment to run from an untrusted PR.

Use **fixed small constants**: two workers/sessions, two chief identities for
succession, at most four busy-loop iterations, and a finite operation bound.
These are model-review requirements, not something this wrapper can prove
about arbitrary TLA+. Separate every real read from its later write/delete.
Name assumptions, exclusions and source-line mapping in the model. Never turn
an invariant failure into an atomic check-and-act merely to make it green.

With the prerequisite variables set:

```bash
bash scripts/handover/chief-kit/model-check-report.sh 123 queue-lock /absolute/scratch/Model.tla /absolute/scratch/view.mjs
bash scripts/handover/chief-kit/model-check-report.sh 124 succession-tracker /absolute/scratch/Succession.tla /absolute/scratch/view.mjs
```

The PR must touch the chosen target. Its head object must already be locally
available; the chief handles that separately. The step never fetches, checks
out, or executes PR code. It reads the target with `git show <head>:<path>`,
copies it and the three model inputs, then checks the live PR head again before
returning. A changed head makes the report stale and exits 2.

Output is a new, non-overwriting directory under
`<handover_root>/<user_slug>/himmel/model-check/pr-<number>-<full-head>-<target>.*`:

- `report.md`: starts with one sentence naming the broken rule and its shortest
  path, using the state/action words already produced by this run's view. A
  clean or incomplete run instead states explicitly that no path was found or
  that no conclusion is possible. Then come PR/head/target and the upstream
  report, including every unchecked rule.
- `chart.mmd`, when upstream can draw it. Above 500 states, upstream draws only
  counterexample paths; a clean large run may produce **no chart**, reported as
  `chart=none`, not a fabricated diagram.
- `inputs/`: model, config, view and source snapshot; `output/`: raw compiler
  artifacts, including TLC traces; `runner.log`: diagnostics even on failure.

Every Java process (SANY, TLC reruns and chart drawing) has a **60-second hard
wall-clock limit**, 512 MiB heap and two active processors. The whole compiler
has a 300-second limit. Timeout sends TERM, then KILL after 5 seconds per JVM
or 10 seconds for the whole command. The compiler's 100,000-state rerun cap
is not an exhaustive pass. No automatic retry or widening of constants occurs.

Exit 0 means bounded checks hold; 1 means a counterexample; 2 means an error,
stale head or an incomplete check (including an unchecked rule); 3 means Java
is absent and the feature stayed off. An exit 2 can still include a useful bug
trace: do not mistake partial evidence for a clean result.

## Judge hand-off and replay

Name the report's absolute path and full head in the judge brief. The judge
cites that path in their verdict, checks the bounds/exclusions the execution
worker reports, and checks that the current PR head still matches. The chief
and judge may read the report, chart and `inputs/` model/config/view/source
snapshot for fidelity review and replay/audit, not the compiler execution transcript. Missing,
stale, timed-out or unchecked evidence cannot support a safety claim. The
report is not signed merge authorization and does not change GO/trust gates.

Replay each counterexample against the actual script in an isolated fixture;
a destructive lock replay is VM-only. If replay disagrees, assume the model
is wrong until investigated. A live-code finding goes to the chief, not into
an unrelated fix in the report PR. Put a `FINDINGS.md` alongside the succession
run, stating whether anything real was found, replay evidence, model limits
and the report path. `succession-tracker.sh` reports quote-backs; it does not
itself release the predecessor's lock. Model the relay-before-release rule
from `running-a-chief.md` separately from the tracker tally. Delivery is enough
before release; quote-back is not required before the predecessor exits.

No third target is selected here. Next candidates, in order: the
ci-orchestrator lease (expiry/renewal ownership), then RETASK nonce/single-writer
handoff (authorization identity across succession). Each needs its own model
and fidelity/replay evidence before adoption.
