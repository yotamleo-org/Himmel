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

rs_later() {
    rs_fix "$1 is not part of this himmel version yet: it arrives in a later update, so run /himmel-update now and then, and see docs/setup/remote-setup.md"
}

cmd_away() { rs_later "part 2 (away launches)"; }
cmd_sudo() { rs_later "part 3 (sudo bot)"; }
cmd_peer() { rs_later "part 4 (bot-to-bot)"; }
# ── part 1: the main bot ────────────────────────────────────────────────
# In order: every check that needs no write, the token (hidden prompt, getMe, role check), the token
# store (checkpoint 1), pairing (only in a run where the token was pasted), the access.json line
# (printed, never written: only your chief writes the allowlist), the bridge, and the final read.
# A re-run with no token pasted never pairs.
cmd_bot() {
    rs_preflight curl jq node bun
    local access="$HOME/.claude/channels/telegram/access.json"
    local access_id tok="" pasted=0 stored_tok stored_id="" prev_tok="" conflict crc err out rc detail lbl doc state

    access_id=$(rs_access_id "$access") \
        || rs_fix "$(rs_tilde "$access") must hold exactly one Telegram id, like {\"allowFrom\":[\"123456789\"]}, and it does not: it was left unchanged. Fix it or move it away, then run the same command again"
    rs_step "checked the tools and access.json"

    rs_secret tok "Paste the bot token from @BotFather (or press Enter to keep the one already stored):" \
        || rs_fix "no token was entered: run the same command again and paste the token from @BotFather"
    stored_tok=$(rs_stored_token)
    if [ -n "$tok" ]; then
        rs_token_shape_ok "$tok" \
            || rs_fix "that is not a bot token: copy the whole token from @BotFather again, it looks like 123456789 then a colon then 35 letters and digits"
        pasted=1
    else
        [ -n "$stored_tok" ] || rs_fix "no bot token is stored yet: run the same command again and paste the token from @BotFather"
        tok=$stored_tok
    fi
    RS_TOKEN=$tok
    tok=""
    rs_getme
    rs_step "the token works (@$RS_BOT_USER, bot id $RS_BOT_ID)"

    if [ "$pasted" = 1 ]; then
        conflict=$(rs_role_check "$RS_BOT_ID" main)
        crc=$?
        if [ "$crc" -eq 2 ]; then
            rs_fix "the other bots' ids could not be checked: run the same command again, and if it repeats tell your chief"
        elif [ "$crc" -eq 1 ]; then
            rs_fix "this bot is already your ${conflict%%|*} bot: each role needs its own bot, so make a new one with @BotFather (send /newbot) for the main bot, then run the same command again"
        fi
        case "$stored_tok" in [0-9]*:*) stored_id=${stored_tok%%:*} ;; esac
        if [ -n "$stored_id" ] && [ "$stored_id" != "$RS_BOT_ID" ] && [ "$OPT_REPLACE" != 1 ]; then
            rs_fix "a different main bot is already set up (bot id $stored_id): to switch to @$RS_BOT_USER on purpose, run: bash scripts/remote-setup/remote-setup.sh bot --replace"
        fi

        if [ "$RS_TOKEN" = "$stored_tok" ]; then
            rs_step "the token is already stored" skip
        else
            prev_tok=$stored_tok
            err=$(printf '%s\n' "$RS_TOKEN" | rs_store_token 2>&1) \
                || rs_fix "the token could not be saved (${err#store refused: }): fix that, then run the same command again"
            out=$(node "$RS_ROOT/scripts/himmelctl/bin.js" status --items distinct-tokens --json 2> /dev/null)
            rc=$?
            state=$(printf '%s' "$out" | jq -r '[.items[]? | select(.id == "distinct-tokens")] | first | .severity // ""' 2> /dev/null)
            if [ "$rc" -ne 0 ] || [ -z "$state" ]; then
                rs_fix "the new token is saved, but it could not be checked against your other bots because himmelctl status gave no answer: run the same command again, and if it repeats tell your chief"
            fi
            case "$state" in
                degraded | red)
                    detail=$(rs_clean "$(printf '%s' "$out" | jq -r '[.items[] | select(.id == "distinct-tokens")] | first | .detail // ""' 2> /dev/null)")
                    if [ -n "$prev_tok" ]; then
                        if printf '%s\n' "$prev_tok" | rs_store_token > /dev/null 2>&1; then
                            rs_fix "the new token collides with another bot (${detail:0:160}), so the previous token was restored: make a new bot with @BotFather (send /newbot), then run the same command again"
                        fi
                        rs_fix "the new token collides with another bot (${detail:0:160}) and the previous token could NOT be put back, so the new token is still saved: put your previous token back into $(rs_tilde "$HOME")/.claude/channels/telegram/.env by hand, then run the same command again"
                    fi
                    if rs_store_remove > /dev/null 2>&1; then
                        rs_fix "the new token collides with another bot (${detail:0:160}), so it was removed again: make a new bot with @BotFather (send /newbot), then run the same command again"
                    fi
                    rs_fix "the new token collides with another bot (${detail:0:160}) and could NOT be removed again: delete the TELEGRAM_BOT_TOKEN line in $(rs_tilde "$HOME")/.claude/channels/telegram/.env by hand, then run the same command again"
                    ;;
            esac
            rs_step "the token is saved"
        fi
        prev_tok=""
        stored_tok=""

        rs_pair
        lbl=$(printf '%s' "$RS_PAIR_LABEL" | LC_ALL=C tr -d '\000-\037\177')
        rs_step "paired with ${lbl:0:40} (Telegram id $RS_PAIR_ID)"
        if [ -z "$access_id" ]; then
            rs_fix "have your chief create the allowlist with this line, then run the same command again: printf '{\"allowFrom\":[\"$RS_PAIR_ID\"]}\\n' > ~/.claude/channels/telegram/access.json"
        elif [ "$access_id" != "$RS_PAIR_ID" ]; then
            rs_fix "access.json already lists a different Telegram account than the one that pressed Start, and it was left unchanged: press Start from the account it lists, or have your chief fix access.json, then run the same command again"
        fi
    else
        [ -n "$access_id" ] || rs_fix "this bot is not paired yet: run the same command again, paste the token, and press Start in Telegram when the link appears"
        rs_step "pairing" skip
    fi

    out=$(node "$RS_ROOT/scripts/himmelctl/bin.js" bridge enable 2> /dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok == true' 2> /dev/null)" != true ]; then
        detail=$(rs_clean "$(printf '%s' "$out" | jq -r '.detail // "no detail"' 2> /dev/null)")
        rs_fix "the bridge could not be turned on (${detail:0:200}): fix that, then run the same command again"
    fi
    rs_step "the bridge is on and set to start again after a reboot"

    doc=$("$BASH" "$RS_SELF_DIR/remote-setup.sh" status --json 2> /dev/null)
    if [ "$(printf '%s' "$doc" | jq -r '.parts[0].state // "error"' 2> /dev/null)" != ok ]; then
        detail=$(rs_clean "$(printf '%s' "$doc" | jq -r '.parts[0].detail // "no detail"' 2> /dev/null)")
        rs_fix "the bridge is not healthy yet (${detail:0:200}): wait a minute, then run the same command again"
    fi
    rs_step "the status check passes"
    rs_done "bot — @$RS_BOT_USER (id $RS_BOT_ID) reachable, bridge running, survives reboot"
}

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
