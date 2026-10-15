# memory-compound — extra inventory (step 0)

Moved verbatim out of `SKILL.md`.

Also inventory, in the same pass:

- **Stale backups** — `ls -1 "$MEMDIR"/*.bak 2>/dev/null`. A `MEMORY.md.bak`
  left by a PRIOR completed pass is delete-eligible once the current index
  loads cleanly. If a `.bak` diverges from everything mined (entries today's
  index and topic files no longer carry), diff it and recover the missing
  durable items through the same pipeline before deleting it.
- **Orphaned sibling stores** — `ls -d ~/.claude/projects/*/memory/`. Stores
  under project slugs whose root was renamed or deprecated (a renamed vault
  dir, a deprecated state repo) never load in any session; their durable
  facts are stranded. Mine them through this same pass (or fold the few live
  facts into the current store), then delete the orphaned store.
- **Remote stations** (D5, HIMMEL-570). Memory is per-host: a fact captured on
  another machine never loads here. Read the station registry — the luna note
  `[[himmel-remote-stations]]` — and **skip cleanly if it is absent** (adopters
  have no remote stations; this is not an error). For each listed host, inventory
  its store over ssh and record index bytes + topic-file count/names. An
  **unreachable / timed-out / auth-failed host is a WARN that does NOT silently
  pass** — a silently skipped host *is* the multi-host bug recurring. Fold any
  remote durable item through the same propagation review + qmd gate below;
  delete the remote topic file only after its landed line is qmd-findable. Keep
  station specifics (hostnames, shells) in the registry note, not here — memory
  and the vault do not propagate to other users, so the skill text stays
  adopter-generic.
