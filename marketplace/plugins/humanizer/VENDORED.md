# Vendored files in humanizer@himmel

Inventory for humanizer@himmel (HIMMEL-5857). Source: `blader/humanizer`,
pinned at `0ef9fe5bc3572734fd3ae6c448fe00a30cd5dcf0` (commit of 2026-10-28,
skill version 3.1.0), MIT, (c) 2025 Siqi Chen.

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
