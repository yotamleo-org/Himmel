# luna-ingest — Phase 1.5 — Safety pre-filter (LUNA-43)

Moved verbatim out of `SKILL.md`.

Before continuing to Phase 2, scan the metadata captured in Phase 1 (`name`, `description`, `topics[]`) plus the decoded README for red-flag keywords.

**Matching algorithm (single canonical form — pin this exactly, no variants):**

1. **Normalize the searched field first.** For each of `name`, `description`, joined `topics[]`, and the first 8 KB of decoded README (interpret 8 KB as 8192 *bytes* of the UTF-8-encoded slice — truncate at a byte boundary, do not split a multibyte rune), lowercase the text and replace any run of one-or-more `[-_\s]+` characters with a single hyphen (`-`). This canonicalises `red_team`, `red team`, `red--team`, and `Red-Team` all to `red-team`.
2. **Apply each rule below as a case-insensitive substring search** against the normalized text. Whichever rule's substring (or AND-pair) appears first → set `safety_flag: <matched-term>` (use the first-listed canonical form from the rule). Word-boundary regex (`\b`) is NOT used — substring after normalization is the only form.
3. **AND-pair rules require both substrings to appear within 80 normalized characters** of each other in the same field (e.g. `red-team .{0,80} agent` or `agent .{0,80} red-team`).

**Single-term rules (substring matches alone trigger):**

- `abliteration` (also catches `abliterated`, `abliterationist`)
- `censorship-removal`
- `uncensored-model`
- `autonomous-hacking`
- `auto-hack`
- `exploit-kit`
- `malware-as-a-service`
- `maas-toolkit`

**AND-pair rules (BOTH substrings must appear in the same field within 80 chars):**

- `red-team` AND (`agent` OR `framework`) — avoids false-positives on legit security-research repos that mention red-team work
- `jailbreak` AND (`model` OR `llm` OR `bypass-safety`) — avoids false-positives on iOS jailbreak tooling

Match rule: if ANY of the rules above (or operator-curated additions, see below) trigger against `name` OR `description` OR `topics[]` OR the first 8 KB of decoded README → set `safety_flag: <matched-term>` (use the first-listed canonical form of the matched rule, e.g. `red-team+agent` for the AND-pair) and one of:

- Without `--allow-unsafe`: exit rc=6 with message `ERR luna-ingest: safety pre-filter matched <term> in <field>. Pass --allow-unsafe to ingest with safety_flag annotation, or skip this repo.` — no synthesis written.
- With `--allow-unsafe`: continue to Phase 2 but propagate `safety_flag` into the synthesis frontmatter so downstream readers (and `/synthesize-clips`) know to treat the page as `unknown-risk` regardless of license / star count.

**Operator customisation:** the keyword list above is the LUNA-43 default. Operators can extend it by setting `LUNA_INGEST_SAFETY_KEYWORDS=<comma-separated terms>` in their shell — additions ONLY (no removal of defaults). Removed defaults require an explicit SKILL.md edit + PR review, by design.

Log line: `[safety] matched=<term> field=<name|description|topics|readme> action=<refused|annotated>` to stderr regardless of action.
