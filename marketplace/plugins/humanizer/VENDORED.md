# Vendored files in humanizer@himmel

Inventory for humanizer@himmel (HIMMEL-5857). Source: `blader/humanizer`,
pinned at `b48c832f0f809c1b5658edbb838c2521b72f2413` (commit of 2026-11-10,
skill version 4.0.0), MIT, (c) 2025 Siqi Chen.

| path | upstream path | deviation |
|---|---|---|
| `skills/humanizer/SKILL.md` | `SKILL.md` | one frontmatter line added (`disable-model-invocation: true`) and one HTML-comment header under the frontmatter naming source, sha and deviation; body byte-identical |
| `LICENSE` | `LICENSE` | none (verbatim) |

Not vendored: upstream's `README.md`, `CHANGELOG.md`, `AGENTS.md`,
`agents/openai.yaml`, `scripts/validate-package.py`, the Cursor and Claude
plugin manifests, and the GitHub templates and workflows. The manifest and
README here are himmel's own.

Re-sync: re-copy `SKILL.md` and `LICENSE` at a new commit, re-add the
frontmatter line and header, update the sha here, in the header, in
`docs/third-party-licenses.md` and in
`scripts/lanes/tests/humanizer-plugin.test.mjs`.
