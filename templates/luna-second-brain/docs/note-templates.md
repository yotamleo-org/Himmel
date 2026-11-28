# Note templates and decision frontmatter

Reference for `_CLAUDE.md` ("Frontmatter Requirements"): which note template to
instantiate, and the extra fields a decision note carries.

## Templates available

| Template | Use for |
|----------|---------|
| `[[_Templates/Daily-Note]]` | Daily journaling and focus |
| `[[_Templates/Weekly-Review]]` | Weekly reflection and planning |
| `[[_Templates/Project]]` | New active project |
| `[[_Templates/Resource]]` | Reference material, concepts, articles |
| `[[_Templates/Decision]]` | Decision record with claim/assumption premise frontmatter |

## Decision-shaped notes: premise frontmatter

Standalone `type: decision` notes MUST carry, in addition to the base fields:

```yaml
claim: "<what the note asserts, one line>"
assumption: "<what must be true for the claim to hold, one line>"
```

Both values MUST be quoted YAML strings (unquoted, a claim like `Adopt storage: use SQLite` breaks
the frontmatter parse and a `#` preceded by a space silently truncates the value). Duplicate
`claim:`/`assumption:` keys within one note are malformed — reject/repair the note before any
contradiction pass consumes it (last-wins parsing would compare an unintended value).

The body section `## The Critical Assumption` stays (nuance, confidence, recency); the frontmatter
is the machine-tractable index that contradiction passes compare across notes. The producing layer
is `[[_Templates/Decision]]` — instantiate the template, never freeform a decision note. Some
external commands do not emit these fields, so a Claude session authoring a decision note directly
must apply this contract itself.
