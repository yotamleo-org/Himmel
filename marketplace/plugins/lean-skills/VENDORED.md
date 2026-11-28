# Vendored trees in lean-skills@himmel

Vendored-skill inventory for lean-skills@himmel (HIMMEL-3064).

NOT the check-plugin-drift.sh class-2 format (that parses ONE
upstream_repo/upstream_path/upstream_sha256 triple per plugin and would only
ever check one of the 14 files below). Upstream advance for this plugin is
detected at the RELEASE level instead, by two scripts/upstreams.json rows:

    superpowers-skills   obra/superpowers      synced_base 7.0.2
    mattpocock-skills    mattpocock/skills     synced_base 1.3.2

A release-level check is the right grain here because we vendor whole skill
DIRECTORIES (SKILL.md plus its companion prompts and scripts), not single
files: a per-file sha pin would need ~36 gh calls per run and would still
miss a companion file we had not enumerated. Neither row carries a
`version_pin`, so scripts/upstreams/apply-drift-bump.sh reports them SKIP
(manual) and never touches them — repair is a reviewed re-vendor, same
discipline as the luna-* bundled-asset rows. Bumping synced_base without
re-copying the trees would launder the signal this file exists to raise.

Everything below is copied VERBATIM except the `deviation=` rows at the end of
this file, each a small recorded local patch. Do not edit vendored prose
without a row there: a local edit makes the next re-vendor a merge instead of
a copy. himmel's own framing lives in its CLAUDE.md and hooks, never inside a
vendored SKILL.md.

vendored_from=obra/superpowers@7.0.2 path=skills/<name>

The 4 skills himmel actually invokes: brainstorming, writing-plans,
systematic-debugging, verification-before-completion — plus the 7 they hand
off to, pulled in to close the `superpowers:<name>` reference closure
(vendoring only the 4 leaves dangling cross-references): executing-plans,
finishing-a-development-branch, requesting-code-review,
subagent-driven-development, test-driven-development, using-git-worktrees,
writing-skills. Plus receiving-code-review (HIMMEL-7756), cited by the
review-finding step of docs/handover/worker-preface.md. DELIBERATELY NOT
vendored (3 of 15): using-superpowers (its SessionStart injection is the
~700 tok this change reclaims), dispatching-parallel-agents — nothing
vendored references it, diagnosing-superpowers — transcript analysis for
filing issues on superpowers itself (HIMMEL-8205).

vendored_from=mattpocock/skills@d1478fcb140db0b93c0c8df17bcfd311844749d0 path=skills/productivity/grilling

HIMMEL-8388 (2026-10-31): grilling re-vendored byte-for-byte at the commit of
release tag v1.3.2 (HIMMEL-4914 had taken a head commit ahead of 1.3.1). The
only change to the skill is one phrase in the facts paragraph (the sub-agent
gets "a fresh context window"). The release-level scripts/upstreams.json row
moves to 1.3.2.

grilling only. 0 of the plugin's 11 exposed skills were ever invoked in 1628
local transcripts; grilling reaches us through the minerva hook's
namespace-agnostic `*:grilling|grilling` matcher, which keeps routing the
bare vendored name. The upstream skill ships an agents/openai.yaml (Codex
interface metadata) that is dropped here as harness-specific.

local=hooks

himmel-authored, no upstream (HIMMEL-3100): the adaptation for the vendored
`superpowers:<name>` citations. NOT a vendored-prose edit — hooks/hooks.json +
hooks/note-superpowers-prefix.sh (a PostToolUse(Skill) hint that maps
`superpowers:<x>` to `lean-skills:<x>` when a citing skill loads), guarded by
hooks/test-note-superpowers-prefix.sh (which also asserts every cited
`superpowers:<name>` is vendored). A re-vendor replaces skills/ only and leaves
hooks/ alone; the suite tells you if the new copy cites something not shipped.

local=skills/context7-mcp

himmel-authored, no upstream. Lived in ~/.claude/skills (always-on, and
per-skill enable/disable does not exist in Claude Code settings) — moved
here so a plugin profile can scope it.

deviation=skills/systematic-debugging/SKILL.md,skills/writing-plans/SKILL.md marker=pstack-principles-digest.md

HIMMEL-5810 (0.2.8): one trailing `See also:` line appended to each of these two
otherwise-verbatim files, linking docs/tool-adoption/pstack-principles-digest.md.
A re-vendor copies the upstream file over it, so re-add the line. The
HIMMEL-7388 re-vendor dropped it unseen; since HIMMEL-8205,
hooks/test-note-superpowers-prefix.sh fails while a listed file lacks the
row's `marker=` text.

deviation=skills/finishing-a-development-branch/SKILL.md marker=PR-only

HIMMEL-11569: upstream offers "Merge back to <base-branch> locally" (option 1,
its Step 5 merge block, the Step 6 and quick-reference rows) and cleans up
worktrees under `.worktrees/`/`worktrees/`. Our rules land work by pull request
only and keep worktrees in `.claude/worktrees/`. The local-merge option and its
block are removed, the menu is two options (PR, keep), and the cleanup path is
`.claude/worktrees/`. A re-vendor copies upstream over it: redo all three.

deviation=skills/using-git-worktrees/SKILL.md marker=.claude/worktrees/

HIMMEL-11569: upstream prefers `.worktrees/` or `worktrees/` and says to add the
folder to `.gitignore` and commit. Our folder is `.claude/worktrees/<type>+<slug>`,
already ignored, and a commit to fix an ignore rule is never the step. The
Directory Selection, Safety Verification, Create the Worktree, quick-reference
and rationalization rows are rewritten to that. A re-vendor copies upstream over it.

deviation=skills/writing-skills/SKILL.md marker=(description

HIMMEL-11569: upstream's Personal-skills line links `codex-tools.md` and
`gemini-tools.md` under `../using-superpowers/references/`, which we do not
vendor, so both links were dead; the line now names `~/.agents/skills/` in
plain text. The name checklist row and the frontmatter row now state the
agent-skills limits (name: lowercase, at most 64 characters, equals the
directory; description: at most 1024). A re-vendor copies upstream over it.

deviation=skills/writing-skills/references/discovery.md marker=skill-name-with-hyphens

HIMMEL-11569: upstream's template teaches `name: Skill-Name-With-Hyphens` and
"Max 1024 characters total". Our skill lint requires the name to equal the
directory, and the standard allows lowercase only, name at most 64 characters
and description at most 1024. The template name is lowercase and the two limit
lines are split per field. A re-vendor copies upstream over it.
