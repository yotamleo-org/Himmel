# test-audit: vendoring record

**Vendored and adapted, pinned to a commit.** Source:
`openclaw/openclaw`, commit `1370643e394f956dfae2e42f43ee030b0072434b`,
path `.agents/skills/test-audit/SKILL.md` (sha256 of the upstream file
`01c421239797a8950fe1287f293d2e05f127e69ac457d1b9cdf9b296ac77eacd`),
fetched 2026-09-24. License: MIT, (c) 2026 OpenClaw Foundation (`LICENSE`
at that commit; full text in
[`docs/third-party-licenses.md`](../../../docs/third-party-licenses.md#vendored-skill-test-audit-mit-openclaw-foundation)).
[`CAMPAIGN.md`](CAMPAIGN.md) is copied **verbatim** from the same commit;
its Telegram/`extensions/` examples are upstream's own campaign, kept as
worked examples.

**Deviations from upstream** (re-check each still holds before re-syncing a
future upstream revision against this file):
1. The Authoring gate, Junk patterns, Value bar,
   Retention bar, Candidate evidence and Edit shape sections keep upstream's
   text, except that `AGENTS.md` reads `CLAUDE.md` (himmel's scoped rules
   files) and the Authoring gate gains the himmel RED-first paragraph.
2. Discovery lanes name himmel's trees (`scripts/`, `marketplace/plugins/`,
   `plugins/`, `templates/`) instead of openclaw's `src/`, `packages/`,
   `extensions/`.
3. Validation is rewritten for himmel's runners
   ([`docs/internals/testing.md`](../../../docs/internals/testing.md)): shell
   suites via `run-shell-tests.sh`, JS/TS suites via the CI-equivalent
   command `impacted-suites.sh --runner` prints, shellcheck, and /pr-check.
   Upstream's `run-vitest.mjs`, `check-changed.mjs`, `$openclaw-testing`,
   `$crabbox` and `$autoreview` do not exist here.
4. Landing and continuation points at himmel's ship flow (worktree branch,
   `/pr-check`, `check-ci`) instead of `$openclaw-pr-maintainer`.
5. A himmel section, "Scratch state", is added: tests never touch real
   operator state.
6. The frontmatter `description` is shortened to fit himmel's 120-char
   skill-description cap (`skill-description-cap` gate); upstream's reads
   "Invoke whenever writing, changing, reviewing, or sweeping tests.
   Authoring gate for new tests plus audit workflow for low-value,
   implementation-coupled, or duplicative tests and the test-only
   production seams they demand."
7. An "expired transition residue" item is added (from a transition-residue audit): one bullet at the end of Junk patterns and one
   paragraph at the end of the Authoring gate. The PR-time counterpart is
   `scripts/cr/residue-scan.sh` (/pr-check step 2.9, advisory).
8. The skill ends with a himmel line, on its own after the See also link:
   "Be thorough in your analysis and bold in your recommendations" (operator
   decision 730; `scripts/lint/test-audit-prompt-sentence.sh` fails without it).
   No evidence rule above it changes.

Apart from these eight deviations, no rule text differs from the pinned commit.
