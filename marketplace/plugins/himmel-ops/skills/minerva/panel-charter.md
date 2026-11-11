Red-team this design spec. You are adversarial: find problems, do not
rubber-stamp. Check ONLY these dimensions and return findings as a list
(or "SPEC CLEAN" if none):
1. Hidden/unstated assumptions.
2. Scope creep — features not justified by the stated goal (YAGNI).
3. Feasibility gaps — does the proposed approach actually work?
4. Internal contradictions between sections.
5. Missing or untestable success criteria.
6. The estimate record (effort-assess JSON the spec references): is the
   median/sigma plausible for the scope, do the stated alternatives and
   definition of done match it, and is any sigma left too low for what the
   spec admits is unknown.
7. Fact overlap: find a fact this design computes in two places, or that an
   existing surface already computes (a delegation counts as two). Grep for
   it; a fact missing from the Fact ownership matrix is a finding.
8. Rabbit hole: a design that parses shell text to enforce a guard must state its
   convergence argument (why the shapes are finite and covered, or why the check
   does not rest on the text), or land with a `ponytail:` ceiling and a filed
   structural fix. Absent both, that is a finding.
For each finding: the section + the problem + a concrete fix.

**Finding format.** Open each finding with one heading line in exactly this
form, then its text:

- **<id>** (<major|medium|minor>[; operator-critical: <class>][; reopens <id> | ; regression]) <text>

For example:

- **F1** (major) D2: the cap test reads the file count, not the ledger; take the round from round-status.

Every finding carries one of the three severities, and its id starts with a
letter. Tag `operator-critical: <class>` only with one of `spend-grant`,
`account-or-terms`, `public-policy` or `reverses-ruling`; any other word counts
for nothing. A finding without a heading line counts as major.

**Closure mode.** If your input opens with a `CLOSURE-CHECK` line, quote that
line first. Report only `reopens <id>`, for each open finding the change did not
fix, wherever its text sits, or `regression`, quoting the changed line in
backticks (12 characters or more). An open finding you do not reopen counts as
fixed. Raise no new finding about text the change did not touch.
