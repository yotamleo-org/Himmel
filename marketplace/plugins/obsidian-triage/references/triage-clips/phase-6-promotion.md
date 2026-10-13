<!-- Moved verbatim out of triage-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

**Phase 6 — Promotion candidate annotation.**

- Pick a promotion target based on `type:` + inferred tags. Use Phase 0 Folder Map if present, else fall back to Luna defaults:
  - `youtube` → Folder Map `youtube`/`video` entry, else `<vault>/30-Resources/Books/`
  - `research` / `article` → Folder Map `concept`/`resource` entry, else `<vault>/30-Resources/Concepts/` (mental models) or `<vault>/30-Resources/Tech/` (tools)
  - `tweet` → Folder Map `idea` entry, else `<vault>/Ideas/` if it exists, else `<vault>/00-Inbox/`. Cross-suggest a `<vault>/20-Areas/<author>.md` link target if the author has a known person note.
  - `reddit` → Folder Map `discussion`/`resource` entry, else `<vault>/30-Resources/`
  - `newsletter` → Folder Map `newsletter`/`resource` entry, else `<vault>/30-Resources/`
  - **Any other `type:` (default — terminal; never halts).** No type-specific mapping. Resolve the promotion target to the Folder Map `resource` entry if present, else `<vault>/30-Resources/` (the same generic bucket `reddit`/`newsletter` fall back to). Annotate the `## Promotion candidate` exactly like a mapped type, with the **Rationale** noting it is a generic default the operator should re-route on promotion (e.g. `no type-specific mapping for "<type>"; generic default — re-route on promotion`). Then continue to Phase 7 + Phase 8 like any mapped type — including the Phase 8 step-0 `ig_media_pending` hold, which still applies to un-enriched instagram clips. This is the closed-mapping guard: no `type:` value falls through to a silent skip, so a newly-introduced type (e.g. `instagram`, `note`) reaches `_evidence/` instead of re-running phases 1–5 forever.

- Write a `## Promotion candidate` section at the end of the clip body (append, do not replace any user content above it):
  ```markdown
  ## Promotion candidate
  <!-- triage TODAY — do NOT auto-promote; user must explicitly accept -->
  - **Suggested target:** `<absolute or vault-relative folder path>`
  - **Rationale:** {1 sentence — why this folder fits}
  - **Bi-temporal anchor:** when promoted, the new note should carry `derived_from: "[[Clippings/<clip-relative-path>]]"` (quoted — unquoted wikilinks parse as nested YAML flow sequences) and its own fresh `date:` field.
  - **Template:** promotion = instantiate the matching vault template, NOT freeform writing (HIMMEL-259) — `[[_Templates/Concept]]` for `30-Resources/Concepts/` targets, `[[_Templates/Tech]]` for `30-Resources/Tech/` targets. Per-type required frontmatter: vault `_CLAUDE.md` → Frontmatter Requirements.
  ```
  (Substitute `TODAY` per the Date substitution rule. Only emit the **Template:** line when the suggested target resolves to `30-Resources/Concepts/` or `30-Resources/Tech/` (suffix/path-component match, so absolute paths qualify too) — other targets have no typed template yet.)

- **Never** auto-move the clip. Promotion is always a deliberate user act. The clip's role from now on is the raw record.
