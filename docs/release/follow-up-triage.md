# Follow-up triage

Every version spawns follow-ups: CR suggestions deferred, judge RESCOPEs,
residual gaps. This is the rule for where each one goes, so a version ships on
time without chasing perfection and without letting bad bugs or friction
through. The terms are defined in the [glossary](../glossary.md#follow-ups-and-intake).
The rule is measured, not final; the numbers below tune it.

## In plain words

Every leftover from a review, every "we should also…", is one of three kinds.
The kind says how soon it matters.

**Escape: something is broken now.**
- **For a user of himmel:** a flow they rely on does not work today. The chief
  cannot file a ticket, a guard blocks ordinary work, or data is lost.
- **Everyday example:** the front-door lock is jammed and you cannot get into the house.
- **What it means for the version:** it is fixed now, in the version in progress.
  The version is not done while it is open.

**Hardening: it works today, but nothing would tell us if it stopped.**
- **For a user of himmel:** the feature does its job, but if it broke or slowly
  drifted, no alarm would go off. No test goes red, the board shows nothing, and
  the chief is not told. People find out late, usually from the damage.
- **Everyday example:** the smoke detector has no battery. The house is fine
  today; the risk is that a fire goes unnoticed.
- **What it means for the version:** hardening is what turns "it worked when we
  tried it" into "it keeps working". It is planned into a version next to the
  feature it protects, and competes for a limited number of places.

**Polish: it works, and we would notice if it broke. It just could be nicer.**
- **For a user of himmel:** wording, tidier code, a cleaner screen, an extra
  figure on the board, or a guard closed against a trick nobody types by accident.
- **Everyday example:** a squeaky hinge, or a chipped paint corner.
- **What it means for the version:** polish never holds a version back. It waits
  in the backlog and gets done when it is convenient or batched.

"Hardening" here means the maturity-ladder step from Proven to Hardened
([glossary](../glossary.md)): the feature is monitored and wired into the checks
that keep it working (decision 112). It is never software-security hardening;
the threat model is a trusted machine (decision 109).

**Why the split matters.**
- Without the split, every review leftover lands in the current version as if it
  were urgent. The version fills with squeaky hinges and never ships.
- If everything is called polish, the smoke-detector gaps sit in the backlog
  until the fire.

The split lets a version ship with its escapes fixed and its important features
watched, and leaves the rest for later on purpose, not by accident.

## The three classes, as questions asked in order

The class is the answer to three questions, asked in order; the first yes wins.
Each question can be checked against a real flow or a real diff, so the reviewer
and the release manager can verify the class. The class is a Jira label
(`fu-escape`, `fu-hardening`, `fu-polish`).

**Q1. Escape: is a real flow broken today?** The answer is yes when:
- an operator, chief or worker flow on the station gives a wrong result, loses or
  corrupts data, or cannot complete; or
- a guard refuses, or fails open on, an ordinary command that someone actually typed.

Example: HIMMEL-6893. Under jq 1.7, every bash-AST guard failed closed on the station.

**Q2. Hardening: can a feature that has already shipped break or decay without
anything turning red?** The answer is yes when exactly one of these five reason
codes fits; the code is part of the class.

| Code | The gap |
|---|---|
| `unseen-failure` | A failure exits 0, is swallowed, or never reaches the board, the tick or the chief. |
| `no-check` | No automated check goes red if the feature breaks: no test row, rows not run in CI, or a suite missing from the tiers. |
| `vacuous-check` | A check exists but cannot fail: an unanchored assert, an ignored exit status, or a fixture that never reaches the code. |
| `no-recovery` | A failure has no bounded recovery: no timeout, a non-atomic write, no retry, or a lock that can strand. |
| `silent-rot` | State or data degrades over time with no signal: a cap that drops rows silently, staleness nobody sees, or drift from main. |

**Q3. Polish: everything else.** The feature works, and if it broke, an existing
check would already catch it. Polish covers:
- wording and docs;
- cosmetics and dead UI;
- code shape;
- extra metrics;
- guard-evasion spellings that only a contrived command reaches. Under decision
  109 these are polish, in line with the "features over guard spiral" standing decision.

**The test at the fix.** A hardening follow-up's fix must do one of two things:
- add or repair a check that goes RED without the fix (its RED row is the evidence); or
- turn a silent failure into a visible one (a non-zero exit, a WARN, a board signal).

A fix that does neither was polish, whatever class it was filed under. The judge
or reviewer of that PR says so, and the release manager reclasses it with a
REVERSION. The rule needs no new tool: the RED-first rule already requires the row.

An Important CR finding that matches `escape` is fixed in the PR, not deferred.
Anything else may be deferred, with a class.

## Where a follow-up goes

The follow-up verb (`jira create --residual-of`) puts each follow-up in exactly
one place when it is filed. It decides from fields it already has: `--fu-class`,
depth, priority, `--gate`, and the parent or `--blocks` link. The first matching
row wins. "Next" means the earliest unreleased version after the current one.

| # | Condition | Lands in |
|---|---|---|
| a | depth ≥ 2 | backlog |
| b | `--fu-class polish` | backlog |
| c | `--gate critical\|regression\|must:<ref>\|receipt` is given | current. The intake gate records the admission. |
| d | `--fu-class escape` | current if current is not frozen; **next** if it is frozen |
| e | `--fu-class hardening` with a chain: the parent, or the `--blocks` target, is open in version V | V if V is unfrozen; **next** if V is the frozen current |
| f | `--fu-class hardening` with no chain, priority High or above | next |
| g | anything else | backlog |

- **Row d.** An escape that is a must under ruling 104 (Critical, data loss, a
  broken operator flow, a regression in the frozen set) is filed with `--gate`
  and lands by row c. Row d's "next" covers only escapes that are not musts.
- **Row e.** The `--residual-of` parent forms a chain only while it is open. A
  follow-up filed after its parent's PR merged chains only through `--blocks`.
- A frozen version admits only through row c, so the frozen set stays fixed.
- The release manager can override any placement later with a REVERSION. The
  verb's class is a default, not a gate.
- **Pending change.** Until R1' (HIMMEL-6919) merges, the verb throws on a frozen
  current version instead of placing by rows d and e. Over the follow-up budget,
  R6' (HIMMEL-6924) makes a version's lowest-ranked To Do follow-up step down to
  make room for a higher-ranked newcomer; see the glossary's Cap gate entry.

## Recording the class

The verb stamps `fu-<class>` on every follow-up. For hardening it also stamps
`fu-why-<code>`. `--fu-class hardening` without `--fu-why <code>` is a usage
error, exactly like a missing `--fu-class`; it is not a placement refusal. This
lands with R1' (HIMMEL-6919).

## The class is required on a deferral

The CR ledger refuses a deferral without a class (nothing is written):

```bash
scripts/cr/ledger-append.sh finding ... --verdict deferred --deferred-to <TICKET> --fu-class <escape|hardening|polish> --reason "<why>"
scripts/cr/ledger-append.sh amend ... --set verdict=deferred --set deferred_to=<TICKET> --set fu_class=<escape|hardening|polish> --set "reason=<why>" --reason "<why>"
```

The amend also needs a finding class: it is attributed from the known-findings
catalog, and when no class claims the finding the amend is refused until it
carries `--set class=<id>` or `--set class=new:<slug>`. A fixed amend stays
auto-only (`unattributed` when nothing claims it).

`review-round.sh defer` (the three-round cap path) records `polish`: it only
defers Suggestions. Deferring an Important always needs an explicit class.
Panel batch rows (`--batch-file`) are not enforced; they are not deferrals a
person classifies. The same class goes on the follow-up ticket as its label
(`fu-escape`, `fu-hardening` or `fu-polish`), and in the summary when filing.

## The per-version report

```bash
bash scripts/release/followup-report.sh --version v1.0.1c
```

Read-only. Prints, per fixVersion:

- follow-ups created and done per class, and follow-ups with no class yet
  (`unclassified-followups`, the backfill's input). **This count is an
  estimate:** an unlabelled ticket counts as a follow-up only when its summary
  contains `follow-up`, `followup`, `deferred` or `residual`, so a follow-up
  without those words is missed and an ordinary ticket with one is counted. An
  explicit marker (label or link type) is left to a planned backfill;
- the hardening share of the version's load (`ok` / `OVER` against
  `--cap-pct`). It is a monitor only: it does not cap or refuse any filing.
  Load is the version's tickets that are neither labelled nor keyword-matched
  as follow-ups, so the share is an estimate for the same reason;
- **claim B, "deferral lets bad bugs through"**: `deferred-escapes`, the count
  of tickets labelled `deferred-escape`. `scripts/cr/mark-deferred-escape.sh`
  puts the label on a fix whose root cause was a deferred follow-up and links
  the follow-up it came from;
- **claim A, "perfection is too expensive"**: mean CR rounds and token sums per
  ticket, from the usage records (`scripts/usage/usage-read.sh`,
  [usage-records](../internals/usage-records.md)). It prints `claim-A
  unavailable` when no store exists yet; run `scripts/usage/usage-compute.sh`
  first.

Run it at tag time and paste the output on the version's release ticket. The
class definitions above are tuned from those numbers.

## How the classes are refined

The classes are judgement calls, so we watch whether the calls hold up. At each
version close (decision 23), the release manager looks at:
- **Escapes a parked follow-up predicted.** A hardening or polish ticket was
  waiting, and then that exact failure happened (a deferred escape). Each one
  means a class was set too low. If it happens repeatedly, tighten the definition.
- **Hardening fixes that added no alarm.** The fix added no test that can go red
  and made nothing visible. That follow-up was polish. A high share means
  hardening is being over-used.
- **Polish that never mattered.** Polish closed untouched after three versions
  confirms the call. Polish that later became an escape is a miss and is counted
  like the first point.
- **Reclasses.** How often the release manager moves a follow-up from one class
  to another. Many moves mean the definitions are unclear to the people filing.
- **The mix per version.** How many follow-ups each class adds, and how many
  were displaced from a version for lack of room.

A definition changes only by an operator ruling, never silently.

## Not done here

Classifying the open follow-ups already in Jira (the one-shot backfill) is a
separate ticket; until it runs, `unclassified-followups` is the size of that
job.
