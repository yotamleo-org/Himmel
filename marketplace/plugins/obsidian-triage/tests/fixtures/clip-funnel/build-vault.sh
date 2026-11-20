#!/usr/bin/env bash
set -uo pipefail

V="${1:?usage: build-vault.sh <dir> [--apply-ledger]}"
mkdir -p "$V/.obsidian" "$V/Clippings/_evidence/_rejected" "$V/Clippings/_synthesis" \
    "$V/Clippings/_done/2026-05" "$V/50-Journal/Daily"

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
clip "$E/_rejected/r1.md" 2026-06-28 "x_media_pending: true"
printf 'not a clip\n' > "$E/notes.txt"
clip "$V/Clippings/inbox-ig.md" 2026-06-28 "ig_media_pending: true"
clip "$V/Clippings/inbox-plain.md" 2026-06-28 "media_enriched_at: 2026-06-24"
clip "$V/Clippings/_done/2026-05/old.md" 2026-05-01 "ig_media_pending: true"
clip "$V/Clippings/_deferred.md" 2026-06-28 "ig_media_pending: true"
printf 'A note with no frontmatter.\n' > "$V/Clippings/inbox-nofm.md"

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
