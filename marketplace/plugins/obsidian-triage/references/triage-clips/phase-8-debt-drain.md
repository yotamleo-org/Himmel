<!-- Moved verbatim out of triage-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Phase-8 debt drain (HIMMEL-1713)

Phase-8 debt is **recorded, never inferred**. Phase 7 writes
`evidence_pending: true` in the same edit that writes `processed: true`;
Phase 8 removes it only after the six-form link verify returns zero (its
step-3 commit point). So at any moment `evidence_pending: true` means exactly
"this clip owes a completed Phase 8" — whether the clip is still in the inbox
(the `ig_media_pending` hold applied at triage time, or Phase 8 was
interrupted before the move) or already in `_evidence/` (interrupted after the
move, links not yet rewritten/verified). The marker lives in the clip's own
frontmatter, so `mv` carries it across the move — there is no separate ledger
to desynchronise. `/ig-media-enrich` needs no re-trigger hook: it just clears
`ig_media_pending`, and this nightly drain picks the clip up by its marker.

Before the per-clip loop, drain the debt:

```bash
# ARG_MAX-safe: shell globs over _evidence/ (1284 files and growing) already
# exceed the argument-list limit on real vaults, and a glob-form grep dies
# with "Argument list too long" — which a 2>/dev/null would swallow into a
# silent no-op drain. Two scoped finds keep the exact scope; -print0/-0 keeps
# clip ids with spaces safe. The 2>/dev/null is on the second find ONLY
# (a fresh vault has no _evidence/ yet) — never on the grep.
#
# The inbox find mirrors the unprocessed-clip scan above EXACTLY — same
# -maxdepth 2, same four exclusions. Phase 7 marks date-subfolder clips
# (`Clippings/2026-05/foo.md`) too, so a -maxdepth 1 drain would leave one
# interrupted mid-Phase-8 carrying the marker forever, invisible to both
# scans: the debt scan cannot see a narrower slice of the vault than the
# scan that creates the debt.
{ find "<vault>/Clippings" -maxdepth 2 -type f -name '*.md' \
    -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
    -not -path '*/_evidence/*' -print0
  find "<vault>/Clippings/_evidence" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null
} | xargs -0 grep -l "^evidence_pending:[[:space:]]*true[[:space:]]*$" /dev/null
```

The trailing `/dev/null` is load-bearing, not decoration: with no marked clips
both finds print nothing, and GNU `xargs` still runs `grep` once with zero file
operands — which makes grep read STDIN and hang, or emit a bogus
`(standard input)` line the drain would treat as a candidate. A permanent
operand grep always has at least one file, never falls back to stdin, and never
matches, so the empty-vault case prints nothing and exits cleanly. (`xargs -r`
would also work but is GNU-only; `/dev/null` is portable.)

That grep is a **candidate prefilter, not the predicate** — it is line-anchored
over the WHOLE file, and a clip body is external, injection-suspect content.
Confirm every candidate against the frontmatter block before touching it:

```bash
# fm_true is defined ONCE, with the unprocessed-clip scan above. Same predicate,
# same reason: a control marker is only ever read from the leading --- block.
# A clip owes Phase 8 iff it is processed AND marked AND not on an active hold.
fm_true "$clip" processed && fm_true "$clip" evidence_pending \
  && ! fm_true "$clip" ig_media_pending
```

**Read the printed lines, never the pipeline's exit status** — `xargs`
returns 123 whenever any `grep -l` batch has no match, so a perfectly good
zero-debt scan "fails" by exit code. Same trap as the unprocessed-clip scan
above, for a different underlying reason: count the lines in both.

(The second find is the SOLE sanctioned exception to the `_evidence/` scan
exclusion — the drain must see debt on both sides of the move.) The pattern is
anchored at BOTH ends, so `evidence_pending: true-ish` is not a hit, and the
`fm_true` confirm above is what makes a hit MEAN the frontmatter key.
(`_deferred.md` is excluded by name above; its rendered `evidence_pending=true`
could not match either way — mid-line, `=` not `: `.)

**Why the frontmatter confirm is not paranoia.** A body-text hit makes the
drain resume Phase 8 on a clip that was never triaged — moving it to
`_evidence/` and rewriting its inbound links with Phases 1-7 skipped — and
because the commit point deletes a FRONTMATTER key it can never clear a BODY
occurrence, so the false debt recurs on every nightly run forever. Clip bodies
are harvested from external pages, which makes this a trust boundary rather
than a style question. Requiring `processed: true` in the frontmatter too is
the cheap second lock — a clip that was never processed cannot owe a Phase 8.

An earlier revision of this file argued that the sibling `^processed:…$` scan
could stay a bare whole-file grep because a false positive there merely SKIPS a
clip and is therefore self-correcting. **That was wrong, and it is worth
recording why**: the body text does not change between runs, so a wrongly
skipped clip is skipped again on every subsequent run — permanently, and
without ever receiving `evidence_pending`, so no debt line ever names it. The
asymmetry is real in direction (one over-acts, one under-acts) but not in
permanence: both are forever, and both are driven by untrusted content. That is
why `fm_true` guards BOTH scans and is defined once rather than duplicated.

An active `ig_media_pending: true` hold — read the same frontmatter-only way,
so untrusted body text cannot forge a hold either — is genuinely waiting on
`/ig-media-enrich`, not a stall, and is not drained. For each confirmed clip,
resume Phase 8 from wherever it stands — do NOT re-run Phases 1-7 (no
re-summarizing, re-tagging, or re-extracting actions; `processed: true`
already means that work is done and final) — with the same tool every Phase 8
goes through, and nothing else:

```bash
python3 "<plugin>/tools/triage-mark-processed.py" "<vault>" "$clip" --drain
# add --dry-run under DRY_RUN=1
```

`--drain` refuses (exit 4) a clip whose frontmatter lacks `processed: true` or
`evidence_pending: true`, so it cannot be used to move an untriaged clip around
the Phase 7 stale-read guard. Every Phase 8 step is idempotent: an existing
`evidence_kind:` is honoured, a clip already at `_evidence/<basename>.md` is not
moved again, and `<OLD>` is READ from `evidence_origin:` (authoritative wherever
the clip sits — a clip renamed in the inbox is swept under both identifiers),
never inferred. A marker-carrying clip in `_evidence/` with NO
`evidence_origin:` predates that record: the tool refuses with
`evidence_origin missing; needs a manual Phase 8` and leaves the marker set.
That clip is in `_evidence/`, NOT the inbox, so `/archive-clips` § Stuck in
inbox does NOT cover it; this command's own `K clips still owe Phase 8
(evidence_pending)` summary line does.

**`--limit N` is ONE budget shared with the per-clip loop, spent drain-first.**
The drain runs before that loop and mutates the vault exactly as much as a
triaged clip does — it moves files and rewrites inbound links — so letting it
run unbounded would make `--limit 1` sweep every pending clip before the loop
even starts. That breaks the documented promise ("stop after N clips") in the
one mode whose whole purpose is a small, inspectable first run.

**Consume one budget unit the moment a confirmed candidate is SELECTED**, before
Phase 8 is entered for it, and never re-credit it. Not on completion — a drain
that fails partway has already moved the file and rewritten some inbound links,
so it spent the budget whether or not it reached the commit point; and not only
on success, because a backlog of collisions or partial rewrites would otherwise
touch every pending clip under `--limit 1` while reporting it never got there.
Success, failure, collision, `ALIAS-STUCK`, and dry-run all consume equally:
the budget bounds how many clips the run may TOUCH, which is what the operator
is actually asking to bound. Stop before selecting another candidate once the
counter reaches zero, and hand whatever is left to the per-clip loop. Report the
untouched remainder in the `K clips still owe Phase 8` line rather than
silently — a limited run leaves debt on purpose, which is not the same as
having none.

On success, log `✓ <clip-filename.md> — Phase-8 debt drained → _evidence/, {L} links rewritten`
and count it toward `N processed`. On failure, log the forward-only `⊘` line
from step 3 and count toward `M skipped` — the marker stays set and the next
nightly run resumes from there. Under `DRY_RUN=1` the drain writes and moves
nothing; log the Phase-8 dry-run `⊘` line per pending clip.

**Migration cutover:** clips triaged before this marker existed carry no
`evidence_pending:` and are deliberately NOT drained — inferring debt from
ambient state is exactly what this design abolishes (a location-based sweep
consumed clips `/archive-clips` Phase 3 had deliberately dedup-parked for
operator review). Legacy stalls surface in `/archive-clips`' `_deferred.md`
§ Stuck in inbox for a manual Phase 8 instead. The stuck population is zero as
of luna commit e2081df60 (2026-08-17), so no backfill is needed.

**Exit condition — both sets, not just the first.** If there are zero
unprocessed clips AND zero drainable pending clips: exit 0 with
`triage-clips: 0 unprocessed clips in Clippings/ — nothing to do`.

**Even this exit reports outstanding debt.** Drainable and marked are not the
same set: on a pure-hold night every marked clip is blocked by an active
`ig_media_pending`, so the drainable count is zero while `K > 0` clips still
carry `evidence_pending: true`. Emitting a bare "nothing to do" there would be
the silent-skip this whole ticket exists to abolish — it is precisely the state
the operator needs told. So the summary contract applies to this path too:
append `triage-clips: K clips still owe Phase 8 (evidence_pending)` whenever
`K > 0`, counting marked clips wherever they live, held or not. "Nothing to do"
must mean nothing is owed, not merely nothing is actionable tonight.

If there is debt to drain but no unprocessed clips, **do not exit** — run the
drain. Phase 0's vault index serves Phase 4 (Related Notes), and a drain
resumes Phase 8 ONLY, so a drain-only pass does not need that index and may
skip Phase 0 entirely. Report drained clips in the normal
`N processed, M skipped` summary.
