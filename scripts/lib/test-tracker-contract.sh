#!/usr/bin/env bash
# Contract suite for the tracker seam (spec section 2,
# invariants I5 and I6): ONE case list run against three backends.
#   jira   replayed from scripts/lib/fixtures/tracker/jira/ through JIRA_CMD
#   local  a real temp store (TRACKER_STORE)
#   none   no tracker: rc 4 / no-ops, ids still mint in the local store (I4)
# Then the I5 cases (20 concurrent mints; dead-pid and live-pid lock) and the
# HIMMEL_ADAPTER_LEDGER one-line-per-op check.
# shellcheck disable=SC2015,SC2030,SC2031  # the ok/bad idiom and per-backend subshell counters are deliberate
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/tracker.sh"
FIX="$SCRIPT_DIR/fixtures/tracker/jira"
# shellcheck source=fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fixture-tempdir.sh"
T=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
eq() { # eq <label> <want> <got>
    if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi
}
has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}

[ -f "$LIB" ] || { bad "tracker.sh does not exist at $LIB"; echo "tracker contract: $PASS passed, $FAIL failed"; exit 1; }

# The JIRA_CMD stub: logs argv, replays the recorded read fixtures. A ticket's
# status lives in $STUB_STATE/status.<KEY> (default "To Do"); the get-child fixture
# key is the epic child, the 404 key does not exist.
STUB="$T/jira-stub.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_STATE/log"
op="$1"; shift
case "$op" in
    get)
        key="$1"
        # the CLI prints the raw Jira JSON body (get.ts + client.ts: `HTTP <status>: <body>`)
        [ "$key" != HIMMEL-404 ] || { echo "jira: get $key failed: HTTP 404: {\"errorMessages\":[\"Issue does not exist or you do not have permission to see it.\"],\"errors\":{}}" >&2; exit 1; }
        [ "$key" != HIMMEL-506 ] || { echo "jira: get $key failed: HTTP 404: {\"errorMessages\":[\"Issue Does Not Exist\"]}" >&2; exit 1; }
        [ "$key" != HIMMEL-502 ] || { echo "jira: get $key failed: HTTP 404: <html><body><h1>Not Found</h1>nginx</body></html>" >&2; exit 1; }
        [ "$key" != HIMMEL-507 ] || { echo "jira: get $key failed: HTTP 404: <html><body>Issue does not exist</body></html>" >&2; exit 1; }
        [ "$key" != HIMMEL-508 ] || { echo "jira: get $key failed: HTTP 404: {\"errorMessages\":[\"Upstream failure\"],\"errors\":{\"detail\":\"issue does not exist\"}}" >&2; exit 1; }
        [ "$key" != HIMMEL-503 ] || { echo "jira: get $key failed: HTTP 404:" >&2; exit 1; }
        [ "$key" != HIMMEL-505 ] || { echo "Issue Does Not Exist" >&2; exit 1; }
        [ "$key" != HIMMEL-500 ] || { echo "401 Unauthorized" >&2; exit 1; }
        st="To Do"
        [ ! -f "$STUB_STATE/status.$key" ] || st=$(cat "$STUB_STATE/status.$key")
        case "$st" in
            "In Progress") f=get-in-progress.json ;;
            Done) f=get-done.json ;;
            Backlog) f=get-backlog.json ;;
            *) f=get-todo.json ;;
        esac
        [ "$key" != HIMMEL-9002 ] || f=get-child.json
        sed -e "s/HIMMEL-4759/$key/g" -e "s/\"name\": \"To Do\"/\"name\": \"$st\"/" "$STUB_FIX/$f"
        ;;
    transition) printf '%s\n' "$2" > "$STUB_STATE/status.$1"; echo "$1 -> $2" ;;
    create) cat "$STUB_FIX/create.txt" ;;
    list) [ -z "${STUB_LIST_FAIL:-}" ] || { echo "list failed" >&2; exit 1; }; cat "$STUB_FIX/list.tsv" ;;
    comment|link) echo ok ;;
    *) echo "stub: unknown op $op" >&2; exit 2 ;;
esac
STUB_EOF
chmod +x "$STUB"

# fresh_env <kind> — a fresh repo + store + stub state, env scrubbed of the
# operator's own tracker settings.
fresh_env() {
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    unset TRACKER FORGE TICKET_ID_PATTERN TICKET_ID_REQUIRED HIMMEL_ADAPTER_LEDGER TRACKER_LOCK_TRIES
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    R=$(mktemp -d "$T/env.XXXXXX") || exit 1
    mkdir "$R/repo" "$R/state"
    git init -q "$R/repo"
    cd "$R/repo" || exit 1
    export TRACKER="$1" JIRA_PROJECT_KEY=HIMMEL
    export TRACKER_STORE="$R/store"
    export JIRA_CMD="$STUB" STUB_STATE="$R/state" STUB_FIX="$FIX"
    # shellcheck source=tracker.sh
    # shellcheck disable=SC1090
    . "$LIB"
}

stub_status() { cat "$STUB_STATE/status.$1" 2>/dev/null || echo "To Do"; }
status_of() { tracker_get "$1" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).status)'; }
json_field() { # json_field <field> — reads JSON on stdin
    node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const v=d[process.argv[1]];process.stdout.write(v===null||v===undefined?"":String(v))' "$1"
}

# ---- the one case list, run per backend -------------------------------------
run_cases() {
    local kind="$1" out rc id id2 pat st q
    fresh_env "$kind"

    # C1 id_pattern
    pat=$(tracker_id_pattern); rc=$?
    eq "$kind C1 rc" 0 "$rc"
    case "$kind" in
        jira) eq "$kind C1 pattern" 'HIMMEL-[0-9]+' "$pat" ;;
        local) has "$kind C1 pattern" 'LOCAL-' "$pat" ;;
        none) eq "$kind C1 pattern empty" '' "$pat" ;;
    esac

    # C2 id_new: two mints
    id=$(tracker_id_new Task "first item"); rc=$?
    eq "$kind C2 rc" 0 "$rc"
    id2=$(tracker_id_new Task "second item")
    case "$kind" in
        jira)
            eq "$kind C2 id" HIMMEL-9001 "$id"
            has "$kind C2 create argv" "create --type Task --title first item" "$(cat "$STUB_STATE/log")"
            ;;
        local|none)
            eq "$kind C2 first" LOCAL-1 "$id"
            eq "$kind C2 second" LOCAL-2 "$id2"
            ;;
    esac
    if [ "$kind" = none ]; then
        [ -f "$TRACKER_STORE/LOCAL-1.md" ] && ok || bad "none C2: mint did not land in the local store"
    fi

    # C3 get / title
    case "$kind" in
        jira) id=HIMMEL-4759 ;;
        local) id=LOCAL-1 ;;
        none) id=LOCAL-1 ;;
    esac
    out=$(tracker_get "$id"); rc=$?
    case "$kind" in
        none) eq "$kind C3 get rc" 4 "$rc" ;;
        *)
            eq "$kind C3 get rc" 0 "$rc"
            eq "$kind C3 id" "$id" "$(printf '%s' "$out" | json_field id)"
            eq "$kind C3 status" "To Do" "$(printf '%s' "$out" | json_field status)"
            eq "$kind C3 type" Task "$(printf '%s' "$out" | json_field type)"
            ;;
    esac
    out=$(tracker_title "$id"); rc=$?
    case "$kind" in
        jira) eq "$kind C3 title" "HIMMEL-4748 WP2: tracker seam with jira/local/none backends, JIRA_CMD seam, contract suite" "$out" ;;
        local) eq "$kind C3 title" "first item" "$out" ;;
        none) eq "$kind C3 title rc" 4 "$rc" ;;
    esac
    # C3b unknown id
    out=$(tracker_get HIMMEL-404 2>/dev/null); rc=$?
    case "$kind" in
        none) eq "$kind C3b rc" 4 "$rc" ;;
        local) out=$(tracker_get LOCAL-404 2>/dev/null); rc=$?; eq "$kind C3b rc" 3 "$rc" ;;
        jira) eq "$kind C3b rc" 3 "$rc" ;;
    esac

    # C4 transitions: forward-only over To Do < In Progress < In Review < IN CI < Done
    if [ "$kind" = none ]; then
        tracker_transition "$id" "In Progress"; eq "none C4 no-op rc" 0 "$?"
    else
        tracker_transition "$id" "In Progress"; eq "$kind C4 up rc" 0 "$?"
        eq "$kind C4 up" "In Progress" "$(status_of "$id")"
        tracker_transition "$id" "To Do"; eq "$kind C4 back rc (silent no-op)" 0 "$?"
        eq "$kind C4 back refused" "In Progress" "$(status_of "$id")"
        tracker_transition "$id" "In Progress"; eq "$kind C4 same rc" 0 "$?"
        for st in "In Review" "IN CI"; do
            tracker_transition "$id" "$st"; eq "$kind C4 -> $st rc" 0 "$?"
            eq "$kind C4 -> $st" "$st" "$(status_of "$id")"
        done
        tracker_transition "$id" "In Review" --allow-back; eq "$kind C4 allow-back rc" 0 "$?"
        eq "$kind C4 allow-back" "In Review" "$(status_of "$id")"
        tracker_transition "$id" "IN CI"
        tracker_transition "$id" Done; eq "$kind C4 -> Done rc" 0 "$?"
        eq "$kind C4 -> Done" Done "$(status_of "$id")"
        tracker_transition "$id" "In Progress" --allow-back
        eq "$kind C4 Done is terminal" Done "$(status_of "$id")"
        tracker_transition "$id" "Wontfix" 2>/dev/null; eq "$kind C4 unknown status rc" 2 "$?"
    fi

    # C5 comment / link
    printf 'a comment body\n' > "$R/c.md"
    tracker_comment "$id" "$R/c.md"; rc=$?
    eq "$kind C5 comment rc" 0 "$rc"
    case "$kind" in
        jira) has "$kind C5 comment argv" "comment $id --comment-file $R/c.md" "$(cat "$STUB_STATE/log")" ;;
        local) has "$kind C5 comment logged" "a comment body" "$(cat "$TRACKER_STORE/$id.md")" ;;
    esac
    tracker_link "$id" "https://example.invalid/pr/1"; eq "$kind C5 link rc" 0 "$?"
    case "$kind" in
        local) has "$kind C5 link stored" "https://example.invalid/pr/1" "$(cat "$TRACKER_STORE/$id.md")" ;;
    esac

    # C6 query
    q=$(tracker_query status="To Do"); rc=$?
    eq "$kind C6 rc" 0 "$rc"
    case "$kind" in
        jira) has "$kind C6 rows" "HIMMEL-5384" "$q"; has "$kind C6 jql" "status" "$(cat "$STUB_STATE/log")" ;;
        local) has "$kind C6 rows" "LOCAL-2" "$q" ;;
        none) eq "$kind C6 empty" '' "$q" ;;
    esac
    tracker_query 'status=bad"quote' 2>/dev/null; eq "$kind C6 unsafe value rc" 2 "$?"
}

for kind in jira local none; do
    ( PASS=0; FAIL=0; run_cases "$kind"; echo "$PASS $FAIL" > "$T/counts.$kind" ) 2>&1
    read -r p f < "$T/counts.$kind" 2>/dev/null || { f=1; p=0; bad "$kind: case list did not finish"; }
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
done

# ---- local backend specifics ------------------------------------------------
( PASS=0; FAIL=0 # L1 all five statuses are accepted, the store holds them verbatim
    fresh_env local
    id=$(tracker_id_new Task "walk")
    out=""
    for st in "In Progress" "In Review" "IN CI" Done; do
        tracker_transition "$id" "$st"
        out="$out|$(status_of "$id")"
    done
    eq "local L1 walk" "|In Progress|In Review|IN CI|Done" "$out"
    echo "$PASS $FAIL" > "$T/counts.L1"
) 2>&1
read -r p f < "$T/counts.L1" 2>/dev/null || { f=1; p=0; bad "local L1 did not finish"; }
PASS=$((PASS + p)); FAIL=$((FAIL + f))

# ---- I5: concurrent mint -----------------------------------------------------
fresh_env local
MINTS="$R/mints"; mkdir "$MINTS"
i=0
while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    ( cd "$R/repo" && bash -c ". '$LIB'; tracker_id_new Task \"item $i\" > '$MINTS/$i.out' 2>'$MINTS/$i.err'" ) &
done
wait
got=$(cat "$MINTS"/*.out 2>/dev/null | sed 's/^LOCAL-//' | sort -n | tr '\n' ' ')
want=$(i=0; while [ "$i" -lt 20 ]; do i=$((i + 1)); printf '%s ' "$i"; done)
eq "I5 20 concurrent mints are LOCAL-1..LOCAL-20, no gaps, no duplicates" "$want" "$got"
eq "I5 next-id after 20 mints" 21 "$(cat "$TRACKER_STORE/next-id")"
[ ! -e "$TRACKER_STORE/.lock" ] && ok || bad "I5 lock left behind after the mints"

# ---- I5: dead-pid lock reclaimed, live-pid lock blocks ----------------------
fresh_env local
mkdir -p "$TRACKER_STORE/.lock"
deadpid=$(bash -c 'echo $$')
printf '%s\n' "$deadpid" > "$TRACKER_STORE/.lock/owner"
out=$(tracker_id_new Task "after dead lock" 2>&1); rc=$?
eq "I5 dead-pid lock reclaimed rc" 0 "$rc"
eq "I5 dead-pid lock reclaimed mint" LOCAL-1 "$out"

fresh_env local
mkdir -p "$TRACKER_STORE/.lock"
sleep 60 &
livepid=$!
printf '%s\n' "$livepid" > "$TRACKER_STORE/.lock/owner"
TRACKER_LOCK_TRIES=4 tracker_id_new Task "blocked" >"$R/blocked.out" 2>"$R/blocked.err"; rc=$?
kill "$livepid" 2>/dev/null
wait "$livepid" 2>/dev/null
eq "I5 live-pid lock blocks rc" 1 "$rc"
has "I5 live-pid lock message names the owner" "$livepid" "$(cat "$R/blocked.err")"
[ ! -e "$TRACKER_STORE/LOCAL-1.md" ] && ok || bad "I5 a mint went through a live lock"

# ---- review fixes -------------------------------------------
# a failed next-id advance must fail the mint, drop the item and free the lock
fresh_env local
mkdir -p "$TRACKER_STORE/next-id.tmp"
out=$(tracker_id_new Task "no advance" 2>/dev/null); rc=$?
eq "next-id advance failure fails the mint" 1 "$rc"
[ ! -e "$TRACKER_STORE/LOCAL-1.md" ] && ok || bad "item left behind after a failed next-id advance"
[ ! -e "$TRACKER_STORE/.lock" ] && ok || bad "lock left behind after a failed next-id advance"

# concurrent edits of one item go through the store lock: no lost link
fresh_env local
id=$(tracker_id_new Task "edited")
i=0
while [ "$i" -lt 10 ]; do
    i=$((i + 1))
    ( cd "$R/repo" && bash -c ". '$LIB'; tracker_link '$id' 'LOCAL-$((i + 100))' 2>/dev/null; tracker_transition '$id' 'In Progress' 2>/dev/null" ) &
done
wait
eq "10 concurrent links all landed" 10 "$(grep -c '^  - "LOCAL-1' "$TRACKER_STORE/$id.md")"
eq "concurrent transition landed" "In Progress" "$(status_of "$id")"

# a title with YAML-significant characters survives write and read
fresh_env local
id=$(tracker_id_new Task 'fix: a "quoted" title # with \ slash')
eq "title round-trips through tracker_title" 'fix: a "quoted" title # with \ slash' "$(tracker_title "$id")"
eq "title round-trips through tracker_get" 'fix: a "quoted" title # with \ slash' "$(tracker_get "$id" | json_field title)"

# an existing item is never overwritten: a lost next-id skips to a free id
fresh_env local
a=$(tracker_id_new Task "first")
rm -f "$TRACKER_STORE/next-id"
b=$(tracker_id_new Task "second")
eq "lost next-id does not reuse an existing id" LOCAL-2 "$b"
eq "the first item survives" first "$(tracker_title "$a")"

# tabs and control characters in a title round-trip identically through both readers
fresh_env local
id=$(tracker_id_new Task "$(printf 'a\tb')")
eq "tab title is normalised to a space (title)" "a b" "$(tracker_title "$id")"
eq "tab title is normalised to a space (get)" "a b" "$(tracker_get "$id" | json_field title)"

# a link with a newline is refused; a link with YAML-significant text is stored verbatim
fresh_env local
id=$(tracker_id_new Task "linked")
tracker_link "$id" "$(printf 'x\ny: z')" 2>/dev/null; eq "multiline link refused" 2 "$?"
tracker_link "$id" 'https://e.invalid/?a: b #c'
has "link with YAML-significant text stored quoted" '  - "https://e.invalid/?a: b #c"' "$(cat "$TRACKER_STORE/$id.md")"

# an item type that is not a plain word is refused
fresh_env local
tracker_id_new "Task
status: Done" "bad type" >/dev/null 2>&1; eq "multiline type refused" 2 "$?"

# a missing body file refuses the mint; an auth failure is not "absent"
fresh_env local
tracker_id_new Task "no body" "$R/missing-body.md" >/dev/null 2>&1; eq "missing body file refused" 2 "$?"
[ ! -e "$TRACKER_STORE/LOCAL-1.md" ] && ok || bad "item written despite a missing body file"
# a body file that is a regular file yet unreadable. chmod 000 stays readable for root, so
# fall back to /proc/self/mem (a regular file whose read fails with EIO even for root)
mkdir -p "$TRACKER_STORE"; printf 'body\n' > "$R/unreadable.md"; chmod 000 "$R/unreadable.md"
unreadable="$R/unreadable.md"
if [ -r "$unreadable" ]; then
    unreadable=/proc/self/mem
    cat "$unreadable" >/dev/null 2>&1 && unreadable=""
fi
if [ -n "$unreadable" ] && [ -f "$unreadable" ]; then
    # an unreadable body returns from the mint (never exits the caller) and leaves nothing behind
    tracker_id_new Task "unreadable body" "$unreadable" >/dev/null 2>&1; rc=$?
    eq "unreadable body file fails the mint" 1 "$rc"
    [ ! -e "$TRACKER_STORE/LOCAL-1.md" ] && [ ! -e "$TRACKER_STORE/.lock" ] && ok || bad "item or lock left behind after an unreadable body"
else
    echo "SKIP: no unreadable-file fixture on this platform" >&2
fi
mkdir -p "$TRACKER_STORE"; printf '08\n' > "$TRACKER_STORE/next-id"
eq "leading-zero next-id is decimal" LOCAL-8 "$(tracker_id_new Task "zero")"
fresh_env jira
tracker_get HIMMEL-404 >/dev/null 2>&1; eq "jira absent issue is rc 3" 3 "$?"
tracker_get HIMMEL-500 >/dev/null 2>&1; eq "jira CLI failure is rc 1, not absent" 1 "$?"
tracker_get HIMMEL-503 >/dev/null 2>&1; eq "jira bare 404 with no not-found text is rc 1" 1 "$?"
tracker_get HIMMEL-502 >/dev/null 2>&1; eq "jira proxy HTML Not Found body is rc 1, not absent" 1 "$?"
tracker_get HIMMEL-506 >/dev/null 2>&1; eq "jira 404 JSON body naming Issue Does Not Exist in any case is rc 3" 3 "$?"
tracker_get HIMMEL-507 >/dev/null 2>&1; eq "jira 404 HTML body that says Issue does not exist is rc 1, not absent" 1 "$?"
tracker_get HIMMEL-508 >/dev/null 2>&1; eq "jira 404 JSON with the phrase outside errorMessages is rc 1, not absent" 1 "$?"
tracker_get HIMMEL-505 >/dev/null 2>&1; eq "jira not-found text outside the CLI's own line is rc 1" 1 "$?"

# the stderr capture file is mktemp-made: a planted predictable path is never written through,
# and nothing is left behind
mkdir "$R/tmp"; : > "$R/victim"
ln -s "$R/victim" "$R/tmp/tracker-jira-err.$$"
ln -s "$R/victim" "$R/tmp/tracker-jira-err"
TMPDIR="$R/tmp" tracker_get HIMMEL-500 >/dev/null 2>&1
eq "jira get stderr never goes through a predictable path" 0 "$(wc -c < "$R/victim" | tr -d ' ')"
eq "jira get leaves no stderr temp file" 2 "$(find "$R/tmp" -mindepth 1 | wc -l | tr -d ' ')"

# a failing jira list is a failed query, not an empty result (pipefail off)
fresh_env jira
( set +o pipefail; STUB_LIST_FAIL=1 tracker_query status="To Do" >/dev/null 2>&1; echo "$?" > "$R/qrc" )
[ "$(cat "$R/qrc")" != 0 ] && ok || bad "failing jira list read as success"

# ---- ledger: one JSONL line per op, nothing when unset ----------------------
fresh_env local
export HIMMEL_ADAPTER_LEDGER="$R/ledger.jsonl"
id=$(tracker_id_new Task "led")
tracker_get "$id" >/dev/null
tracker_transition "$id" "In Progress"
tracker_title "$id" >/dev/null
eq "ledger one line per op" 4 "$(wc -l < "$HIMMEL_ADAPTER_LEDGER" | tr -d ' ')"
ops=$(node -e '
    const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
    const need = ["ts", "tracker", "forge", "op", "id", "rc", "ms"];
    if (!l.every((r) => need.every((k) => k in r))) { process.stdout.write("MISSING-FIELD"); process.exit(0); }
    process.stdout.write(l.map((r) => r.op + ":" + r.tracker + ":" + r.id + ":" + r.rc).join(","));
' "$HIMMEL_ADAPTER_LEDGER")
eq "ledger rows" "id_new:local:LOCAL-1:0,get:local:LOCAL-1:0,transition:local:LOCAL-1:0,title:local:LOCAL-1:0" "$ops"
unset HIMMEL_ADAPTER_LEDGER
rm -f "$R/ledger.jsonl"
tracker_get "$id" >/dev/null
[ ! -e "$R/ledger.jsonl" ] && ok || bad "ledger file created with HIMMEL_ADAPTER_LEDGER unset"

echo "tracker contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
