# Vendored files in pstack@himmel

Inventory for pstack@himmel (HIMMEL-5803). Source: `cursor/plugins`, path
`pstack/`, pinned at `99743e9c151c8537cbbf1f98bb38f34ef3368453` (pstack 0.15.25),
MIT, (c) 2026 Lauren Tan. Never installed from the `michael-denyer/pstack-claude`
fork.

Each `SKILL.md` is the upstream file plus one HTML-comment line under the
frontmatter naming source, sha and deviations. The reference files are verbatim except `feature-map-example/search.md` (see the table).

| path | upstream path | deviation |
|---|---|---|
| `skills/correct/SKILL.md` | `pstack/skills/correct/SKILL.md` | none |
| `skills/blast-radius/SKILL.md` | `pstack/skills/blast-radius/SKILL.md` | references to unshipped how, why, arena, unslop replaced by standalone sentences (HIMMEL-5815) |
| `skills/create-verification-skill/SKILL.md` | `pstack/skills/create-verification-skill/SKILL.md` | `.cursor/skills/` paths are `.claude/skills/` |
| `skills/create-verification-skill/references/**` | `pstack/skills/create-verification-skill/references/**` | `feature-map-example/search.md` Proof bullet reruns the title-match query before capturing (HIMMEL-5815); every other reference file verbatim |
| `skills/maintain-verification-skill/SKILL.md` | `pstack/skills/maintain-verification-skill/SKILL.md` | `.cursor/skills/` path is `.claude/skills/` |
| `skills/benchmark-checklist/SKILL.md` | `pstack/skills/benchmark-checklist/SKILL.md` | none |
| `skills/principle-explain-the-number/SKILL.md` | `pstack/skills/principle-explain-the-number/SKILL.md` | link to unshipped `principle-prove-it-works` made plain text |
| `skills/in-your-own-words/SKILL.md` | `pstack/skills/in-your-own-words/SKILL.md` | none |
| `LICENSE` | `pstack/LICENSE` | none (verbatim) |

`disable-model-invocation: true` is upstream's own frontmatter on all seven and
stays. The profile, README and manifest files are himmel's own.

Re-sync: re-copy the files above at a new commit, update the sha here, in each
header line, in `docs/third-party-licenses.md` and in
`scripts/lanes/tests/pstack-plugin.test.mjs`. Do not add the fork's hooks,
`poteto-mode`, `setup-pstack`, `shipping`, `autopilot-*`, `orchestrate` or
`autonomous-run`.
