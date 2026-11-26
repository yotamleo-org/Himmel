#!/usr/bin/env bash
# build.sh <dir> - writes the fixture tree test-trust-owner-sample.sh samples, under <dir> (a scratch dir).
# Ten tickets in the mirror; which owner source holds each:
#   FIX-1  In Progress  none                                   -> UNOWNED
#   FIX-2  In Progress  worker doc, session id, pid proven     -> worker
#   FIX-3  In Review    fleet row bound to T3 thread thr-3     -> t3
#   FIX-4  IN CI        cloud-sessions.tsv row, 3 h old        -> cloud
#   FIX-5  In Progress  READY bullet in a chief doc            -> chief-go
#   FIX-6  To Do, FIX-7 Done                                -> no row
#   FIX-8  In Progress  worker doc, pid recycled (start differs) -> UNOWNED
#   FIX-9  In Progress  cloud row 6 days old                   -> UNOWNED
#   FIX-10 In Progress  fleet row of lane peer                 -> peer
set -uo pipefail
d="${1:?usage: build.sh <dir>}"
mkdir -p "$d/mirror-root/HIMMEL" "$d/bucket" "$d/config/sessions" "$d/proc/4242" "$d/proc/4343"

mk_ticket() {
    printf -- '---\nkey: "FIX-%s"\ntype: "Task"\nstatus: "%s"\nlabels: []\n---\n\n# FIX-%s: fixture ticket\n' \
        "$1" "$2" "$1" > "$d/mirror-root/HIMMEL/FIX-$1.md"
}
mk_ticket 1 'In Progress'
mk_ticket 2 'In Progress'
mk_ticket 3 'In Review'
mk_ticket 4 'IN CI'
mk_ticket 5 'In Progress'
mk_ticket 6 'To Do'
mk_ticket 7 'Done'
mk_ticket 8 'In Progress'
mk_ticket 9 'In Progress'
mk_ticket 10 'In Progress'
printf '{"lastSync":"2026-11-26T00:50:00.000Z","total":10,"project":"HIMMEL"}\n' > "$d/mirror-root/.cursor.json"

mk_doc() { # <file> <session id or empty>
    printf -- '---\nresume_cwd: /tmp/x\ndescription: "fixture"\nsession_ids: %s\n---\n\n# fixture worker\n' "$2" > "$d/bucket/$1"
}
sid_live=11111111-1111-1111-1111-111111111111
sid_recycled=22222222-2222-2222-2222-222222222222
mk_doc FIX-2-N2-live.md "$sid_live"
mk_doc FIX-8-N8-recycled.md "$sid_recycled"
mk_doc FIX-3-N3-t3.md ''
mk_doc FIX-10-N10-peer.md ''

printf '# chief fixture\n\n## Results\n\n- 00:10 LIVE - nothing\n- 00:20 READY FIX-5 #123 0123456789abcdef0123456789abcdef01234567 GREEN\n' \
    > "$d/bucket/FIX-nextleg-2026-11-26A-fixture-chief.md"
printf '2026-11-25T22:00\tFIX-4\tsession_fresh\tclaude --teleport session_fresh\n2026-11-20T00:00\tFIX-9\tsession_old\tclaude --teleport session_old\n' \
    > "$d/bucket/cloud-sessions.tsv"

cat > "$d/bucket/FIX-nextleg-2026-11-26A-fixture-chief.fleet.json" <<JSON
{"schema":1,"workers":[
 {"doc":"$d/bucket/FIX-2-N2-live.md","label":"N2","lane":"native"},
 {"doc":"$d/bucket/FIX-8-N8-recycled.md","label":"N8","lane":"native"},
 {"doc":"$d/bucket/FIX-3-N3-t3.md","label":"N3","lane":"t3","t3_thread":"thr-3","t3_kind":"task"},
 {"doc":"$d/bucket/FIX-10-N10-peer.md","label":"N10","lane":"peer"}
]}
JSON

# an older manifest keeps its rows under `legs`; it is read the same way (its doc holds no live session)
# (its second row names a doc that is gone: grep exits 2 on it, and the live docs still have to be found)
printf '{"schema":1,"legs":[{"doc":"%s/bucket/FIX-9-N9-legacy.md","label":"N9"},{"doc":"%s/bucket/FIX-11-N11-gone.md","label":"N11"}]}\n' "$d" "$d" > "$d/bucket/FIX-nextleg-2026-10-01A-old-console.fleet.json"
mk_doc FIX-9-N9-legacy.md ''

printf '{"sessionId":"%s","procStart":"5555"}\n' "$sid_live" > "$d/config/sessions/4242.json"
printf '{"sessionId":"%s","procStart":"6666"}\n' "$sid_recycled" > "$d/config/sessions/4343.json"
# /proc/<pid>/stat: field 22 (start time) is the 20th token after the closing paren
printf '4242 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5555 0 0\n' > "$d/proc/4242/stat"
printf '4343 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 7777 0 0\n' > "$d/proc/4343/stat"
