#!/usr/bin/env bash
# shellcheck disable=SC2034  # the OPT_* flags are read by the part functions as they are built
# remote-setup.sh: set up the remote pieces of a himmel station from one entry.
#
#   bash scripts/remote-setup/remote-setup.sh bot [--replace]
#   bash scripts/remote-setup/remote-setup.sh away [--off]
#   bash scripts/remote-setup/remote-setup.sh sudo [--replace]
#   bash scripts/remote-setup/remote-setup.sh peer [--replace] [--remove]
#   bash scripts/remote-setup/remote-setup.sh status [--json]
#
# Run each writing part in a separate plain Terminal (not inside Claude, not with !), from your
# himmel folder. Every run ends with one `DONE: ...` (exit 0) or one `FIX: ...` (exit 3) line;
# a usage error exits 2. `status` only reads. See docs/setup/remote-setup.md.
#
# bash 3.2-safe.

RS_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
. "$RS_SELF_DIR/lib.sh"

rs_usage() {
    {
        case "${1:-}" in
            bot) echo "usage: remote-setup.sh bot [--replace]" ;;
            away) echo "usage: remote-setup.sh away [--off]" ;;
            sudo) echo "usage: remote-setup.sh sudo [--replace]" ;;
            peer) echo "usage: remote-setup.sh peer [--replace] [--remove]" ;;
            status) echo "usage: remote-setup.sh status [--json]" ;;
            *) echo "usage: remote-setup.sh {bot|away|sudo|peer|status} [--replace] [--json] [--off] [--remove]" ;;
        esac
    } >&2
    RS_FINISHED=1
    exit 2
}

# Which flags each subcommand accepts.
rs_flag_allowed() {
    case "$1:$2" in
        bot:--replace | sudo:--replace | peer:--replace | peer:--remove | away:--off | status:--json) return 0 ;;
    esac
    return 1
}

OPT_REPLACE=0
OPT_REMOVE=0
OPT_OFF=0
OPT_JSON=0

SUB=${1:-}
case "$SUB" in
    bot | away | sudo | peer | status) shift ;;
    *) rs_usage ;;
esac
for a in "$@"; do
    rs_flag_allowed "$SUB" "$a" || rs_usage "$SUB"
    case "$a" in
        --replace) OPT_REPLACE=1 ;;
        --remove) OPT_REMOVE=1 ;;
        --off) OPT_OFF=1 ;;
        --json) OPT_JSON=1 ;;
    esac
done

# Slice 1a builds `bot` and `status`; the other parts say so plainly.
rs_later() {
    rs_fix "$1 is not part of this himmel version yet: it arrives in a later update, so run /himmel-update now and then, and see docs/setup/remote-setup.md"
}

cmd_away() { rs_later "part 2 (away launches)"; }
cmd_sudo() { rs_later "part 3 (sudo bot)"; }
cmd_peer() { rs_later "part 4 (bot-to-bot)"; }
cmd_bot() { rs_later "part 1 (main bot)"; }

# ── status: the one aggregator ──────────────────────────────────────────
# Maps himmelctl status items to the four parts, their state and their next command. It computes no
# fact itself: every state comes from `himmelctl status --items <ids> --json`. This table is the only
# place the item-to-part mapping lives. A part whose items are not all in RS_ITEMS_SHIPPED is
# `skipped`: it neither fails status nor counts as not ok.
rs_part_table() {
    cat <<'EOF'
1|Main bot|bridge-health bridge-persistence distinct-tokens|bash scripts/remote-setup/remote-setup.sh bot|docs/setup/remote-setup.md#part-1
2|Away launches|remote-away|bash scripts/remote-setup/remote-setup.sh away|docs/setup/remote-setup.md#part-2
3|Sudo bot|remote-sudo|bash scripts/remote-setup/remote-setup.sh sudo|docs/setup/remote-setup.md#part-3
4|Bot-to-bot|remote-peer|bash scripts/remote-setup/remote-setup.sh peer|docs/setup/remote-setup.md#part-4
EOF
}

rs_items_shipped_all() { # rs_items_shipped_all <items...>
    local i
    for i in "$@"; do
        case " $RS_ITEMS_SHIPPED " in *" $i "*) ;; *) return 1 ;; esac
    done
    return 0
}

# rs_part_json <num> <name> <state> <detail> <command|""> <guide> [<error>]
rs_part_json() {
    jq -nc --argjson part "$1" --arg name "$2" --arg state "$3" --arg detail "$4" --arg command "$5" --arg guide "$6" --arg error "${7:-}" \
        '{part: $part, name: $name, state: $state, detail: $detail, command: (if $command == "" then null else $command end), guide: $guide}
         + (if $error == "" then {} else {error: $error} end)'
}

cmd_status() {
    rs_preflight node jq
    local num name items command guide ids="" csv raw="" qerr="" qrc
    while IFS='|' read -r num name items command guide; do
        # shellcheck disable=SC2086
        rs_items_shipped_all $items && ids="$ids $items"
    done <<EOF
$(rs_part_table)
EOF
    csv=$(printf '%s' "$ids" | tr -s ' ' ',' | sed 's/^,//')
    raw=$(node "$RS_ROOT/scripts/himmelctl/bin.js" status --items "$csv" --json 2>/dev/null)
    qrc=$?
    if [ "$qrc" -ne 0 ]; then
        qerr="himmelctl status failed (exit $qrc)"
    elif ! printf '%s' "$raw" | jq -e '.items | type == "array"' >/dev/null 2>&1; then
        qerr="himmelctl status gave no readable answer"
    fi

    local parts="" part1_state="" state detail cmdline err obj item row sev idetail greens nas others missing first_bad detail_ok
    while IFS='|' read -r num name items command guide; do
        err=""
        cmdline=""
        # shellcheck disable=SC2086
        if ! rs_items_shipped_all $items; then
            state=skipped
            detail="arrives in a later update"
        elif [ -n "$qerr" ]; then
            state=error
            detail="could not read this part's status"
            err=$qerr
        else
            greens=0 nas=0 others=0 missing="" first_bad="" detail_ok=""
            for item in $items; do
                row=$(printf '%s' "$raw" | jq -c --arg id "$item" '[.items[] | select(.id == $id)] | first // empty')
                if [ -z "$row" ]; then
                    missing="${missing:+$missing, }$item"
                    continue
                fi
                sev=$(printf '%s' "$row" | jq -r '.severity // "n/a"')
                idetail=$(rs_clean "$(printf '%s' "$row" | jq -r '.detail // ""')")
                case "$sev" in
                    green) greens=$((greens + 1)); [ -z "$detail_ok" ] && detail_ok=${idetail:0:160} ;;
                    n/a) nas=$((nas + 1)); [ -z "$first_bad" ] && first_bad="$item: ${idetail:0:160}" ;;
                    *) others=$((others + 1)); [ -z "$first_bad" ] && first_bad="$item: ${idetail:0:160}" ;;
                esac
            done
            if [ -n "$missing" ]; then
                state=error
                detail="could not read this part's status"
                err="himmelctl status had no answer for $missing"
            elif [ "$others" -eq 0 ] && [ "$nas" -eq 0 ]; then
                state=ok
                detail=${detail_ok:-ok}
                cmdline=""
            elif [ "$greens" -eq 0 ] && [ "$others" -eq 0 ]; then
                state="not set"
                detail="not set up yet"
                cmdline=$command
            else
                state=partial
                detail=$first_bad
                cmdline=$command
            fi
        fi
        [ "$num" = 1 ] && part1_state=$state
        # a part after part 1 that is not ok waits for part 1
        if [ "$num" != 1 ] && [ "$state" != ok ] && [ "$state" != skipped ] && [ "$state" != error ] && [ "$part1_state" != ok ]; then
            detail="do part 1 first"
            cmdline=""
        fi
        obj=$(rs_part_json "$num" "$name" "$state" "$detail" "$cmdline" "$guide" "$err")
        parts="${parts}${obj}"$'\n'
    done <<EOF
$(rs_part_table)
EOF

    local doc ok first_idx
    doc=$(printf '%s' "$parts" | jq -sc '{parts: ., ok: (all(.[]; .state == "ok" or .state == "skipped"))}')
    ok=$(printf '%s' "$doc" | jq -r '.ok')
    if [ "$OPT_JSON" = 1 ]; then
        printf '%s\n' "$doc"
    else
        printf '%s' "$doc" | jq -r '.parts[] | "  \(.part)  \(.name)  \(.state)  \(.detail)"'
    fi
    if [ "$ok" = true ]; then
        rs_done "status — all shipped parts ok"
    fi
    first_idx=$(printf '%s' "$doc" | jq -r '[.parts | to_entries[] | select(.value.state != "ok" and .value.state != "skipped")] | first | .key')
    local p_num p_name p_state p_detail p_cmd p_err
    p_num=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].part")
    p_name=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].name")
    p_state=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].state")
    p_detail=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].detail")
    p_cmd=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].command // empty")
    p_err=$(printf '%s' "$doc" | jq -r ".parts[$first_idx].error // empty")
    case "$p_state" in
        error) rs_fix "part $p_num ($p_name) could not be read: $p_err. Run the same command again" ;;
        "not set") rs_fix "part $p_num ($p_name) is not set up. Run: $p_cmd" ;;
        *)
            if [ -z "$p_cmd" ]; then
                rs_fix "part $p_num ($p_name) needs part 1 first. Run: bash scripts/remote-setup/remote-setup.sh bot"
            fi
            rs_fix "part $p_num ($p_name) is partly set up ($p_detail). Run: $p_cmd"
            ;;
    esac
}

case "$SUB" in
    status)
        [ "$OPT_JSON" = 1 ] && RS_JSON_MODE=1
        rs_begin status "show each remote part and its next step"
        ;;
    bot) rs_begin bot "set up your main bot, the one your chief talks to you through" ;;
    away) rs_begin away "arm away launches" ;;
    sudo) rs_begin sudo "set up the sudo bot" ;;
    peer) rs_begin peer "connect this station to another station's bot" ;;
esac

[ "$SUB" = status ] || rs_guard
rs_need_checkout

case "$SUB" in
    bot) cmd_bot ;;
    away) cmd_away ;;
    sudo) cmd_sudo ;;
    peer) cmd_peer ;;
    status) cmd_status ;;
esac
