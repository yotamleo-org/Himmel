#!/usr/bin/env bash
# Build the synthetic funnel vault the clip-funnel and morning-report suites share.
#   build-vault.sh <dir> [--apply-ledger]
# The report day is 2026-06-28 and the window is the 7 days 2026-06-22..2026-06-28.
# Expected funnel, no apply ledger:
#   intake   10 clips, 6 in the window, last 2026-06-28
#   cited     4 clips (40%) by 2 synthesis pages, 0 pages in the window, last 2026-06-18
#   subjects  2 created, 2 extended, 2 touched in the window, last 2026-06-27
#   actions   3 open, 0 applied, last applied none
#   media     3 waiting, 1 enriched in the window, last 2026-06-26
#   stalled   cited, actions
# With --apply-ledger: actions 1 open, 2 applied (1 in the window, last 2026-06-27); stalled cited.
set -uo pipefail

V="${1:?usage: build-vault.sh <dir> [--apply-ledger]}"
mkdir -p "$V/.obsidian" "$V/Clippings/_evidence/_rejected" "$V/Clippings/_synthesis" \
    "$V/Clippings/_done/2026-05" "$V/50-Journal/Daily"

# clip <path> <triaged_at> [extra frontmatter line ...]
clip() {
    local path="$1" triaged="$2"; shift 2
    {
        printf -- '---\ntype: tweet\ntriaged_at: %s\n' "$triaged"
        for line in "$@"; do printf '%s\n' "$line"; done
        printf -- '---\n\nSynthetic clip body.\n'
    } > "$path"
}

E="$V/Clippings/_evidence"
clip "$E/e01.md" 2026-06-28
clip "$E/e02.md" 2026-06-28 "x_media_pending: true"
clip "$E/e03.md" 2026-06-28 "x_media_pending: true"
clip "$E/e04.md" 2026-06-28 "x_media_pending: false"
clip "$E/e05.md" 2026-06-25 "media_enriched_at: 2026-06-26"
clip "$E/e06.md" 2026-06-22
clip "$E/e07.md" 2026-06-21
clip "$E/e08.md" 2026-05-29 "media_enriched_at: 2026-06-08"
clip "$E/e09 – dash name.md" 2026-05-29
clip "$E/e10.md" 2026-05-29
# Not evidence: a rejected clip, a stray text file.
clip "$E/_rejected/r1.md" 2026-06-28 "x_media_pending: true"
printf 'not a clip\n' > "$E/notes.txt"
# The inbox holds the clips still on their way in; _done is history.
clip "$V/Clippings/inbox-ig.md" 2026-06-28 "ig_media_pending: true"
clip "$V/Clippings/inbox-plain.md" 2026-06-28
clip "$V/Clippings/_done/2026-05/old.md" 2026-05-01 "ig_media_pending: true"
# Neither is a clip: the rolling deferral table and a file with no frontmatter.
clip "$V/Clippings/_deferred.md" 2026-06-28 "ig_media_pending: true"
printf 'A note with no frontmatter.\n' > "$V/Clippings/inbox-nofm.md"

# synthesis pages: a link names its clip by name, so a stale folder still counts.
cat > "$V/Clippings/_synthesis/s1.md" <<'EOF'
---
date: 2026-05-19
type: synthesis
---

- [[Clippings/_evidence/e01]]
- [[Clippings/_done/2026-05/e02|second]]
- [[e03#heading]]
EOF
cat > "$V/Clippings/_synthesis/s2.md" <<'EOF'
---
date: 2026-06-18
type: synthesis
---

- [[Clippings/_evidence/e01.md]]
- [[Clippings/_evidence/e09 – dash name]]
- [[Clippings/_evidence/ghost]]
EOF

# the subject ledger: garbage lines are skipped, Alpha is extended twice.
cat > "$V/.synthesize-stubs.ledger.jsonl" <<'EOF'
{"ts":"2026-06-08T09:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Alpha.md"}
{"ts":"2026-06-27T10:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Beta.md"}
{"ts":"2026-06-26T10:00:00.000Z","action":"densify","subject":"30-Resources/Concepts/Alpha.md"}
{"ts":"2026-06-13T10:00:00.000Z","action":"densify","subject":"60-Maps/x-MOC.md"}
{"ts":"2026-06-13T11:00:00.000Z","action":"densify","subject":"30-Resources/Concepts/Alpha.md"}
this line is not json
42
{"ts":"2026-06-27T13:00:00.000Z","action":"densify"}
{"ts":"2026-06-27T12:00:00.000Z","action":"claim-deferred","subject":"30-Resources/Concepts/Beta.md"}
EOF

# the daily notes: a1 a2 a3 are suggested on 06-25; a3 is ticked and a5 dismissed on 06-27.
cat > "$V/50-Journal/Daily/2026-06-25.md" <<'EOF'
# 2026-06-25

## Daily report

- [ ] Fold e01 into [[60-Maps/x-MOC]] <!-- act:aaaaaaa1 since:2026-06-25 -->
- [ ] Archive e02 <!-- act:aaaaaaa2 since:2026-06-25 -->
- [ ] Evaluate tool Zed <!-- act:aaaaaaa3 since:2026-06-25 -->
EOF
cat > "$V/50-Journal/Daily/2026-06-27.md" <<'EOF'
# 2026-06-27

## Daily report

- [x] Evaluate tool Zed <!-- act:aaaaaaa3 since:2026-06-25 -->
- [ ] Archive e04 <!-- act:aaaaaaa4 since:2026-06-27 -->
- [-] Archive e06 <!-- act:aaaaaaa5 since:2026-06-27 -->

## Journal

- [ ] An unrelated task <!-- act:aaaaaaa9 since:2026-06-27 -->
EOF
# only a note named for its day is a daily note.
cat > "$V/50-Journal/Daily/not-a-date.md" <<'EOF'
## Daily report

- [ ] Archive e07 <!-- act:aaaaaaa8 since:2026-06-27 -->
EOF

if [ "${2:-}" = "--apply-ledger" ]; then
    cat > "$V/.apply-clip-actions.ledger.jsonl" <<'EOF'
{"ts":"2026-06-27T08:00:00.000Z","action":"fold","id":"aaaaaaa1","since":"2026-06-25"}
{"ts":"2026-06-27T09:00:00.000Z","action":"fold","id":"aaaaaaa1","since":"2026-06-25"}
{"ts":"2026-05-29T08:00:00.000Z","action":"archive","id":"aaaaaaa2","since":"2026-06-25"}
{"ts":"2026-06-27T09:30:00.000Z","action":"note","id":"aaaaaaa4"}
{"ts":"2026-06-27T09:40:00.000Z","action":"fold"}
EOF
fi
