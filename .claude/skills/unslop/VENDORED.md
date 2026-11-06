# unslop: vendoring record

**Vendored, pinned to a commit.** Source: `cursor/plugins`
(pstack), commit `99743e9c151c8537cbbf1f98bb38f34ef3368453` (re-synced from
`e8d856f0`), path
`pstack/skills/unslop/SKILL.md`, fetched 2026-10-15. License: MIT, (c) 2026
Lauren Tan (`pstack/LICENSE` at that commit; full text in
[`docs/third-party-licenses.md`](../../../docs/third-party-licenses.md#vendored-skill-unslop-mit-lauren-tan)).
Decision record: `specs/adr/adr-unslop-skill.md` in the handover state repo.
Registry row: [`docs/tool-adoption/registry.md`](../../../docs/tool-adoption/registry.md).

**Deviations from upstream** (re-check each still holds before re-syncing a
future upstream revision against this file):
1. Kept `disable-model-invocation: true`. Verified against Claude Code's own
   docs (code.claude.com/docs/en/skills, checked 2026-09-17) that this is a
   real, functioning CLI frontmatter key, not a silently-ignored or
   error-raising one — it hides the skill from autonomous model invocation
   while leaving explicit `/unslop` invocation intact. This is exactly the
   lean-invoke shape the pilot requires (no himmel skill used this key
   before now, which reflects absence of need, not unsupported syntax; only
   claude.ai's stricter upload/distribution validator rejects it, and this
   skill is a local project skill, never uploaded there).
2. Rules 28 and 33 below are scoped to documents written for a human reader
   — PR bodies, ADRs, handovers, tickets — never routine interactive
   replies, which the operator's Concise output style already governs. A
   blanket application would fight that style directly.
3. Rule 13 (em-dash ban) is dropped — see the gap at that number. himmel's
   own docs use em-dashes as an established house-style device; the ban is
   a house-style call this repo is not adopting, not a correctness fix.

No other rule text, numbering, or wording differs from the pinned commit.
The pin dropped upstream's "Must always apply" description suffix and its
Process section; both are gone here too, so nothing local overrides them.
