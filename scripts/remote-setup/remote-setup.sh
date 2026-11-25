#!/usr/bin/env bash
# shellcheck disable=SC2034  # the OPT_* flags are read by the part functions as they are built
# shellcheck disable=SC2016  # the jq programs are single-quoted on purpose: $name there is jq's, not the shell's
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
# ── part 1: the main bot ────────────────────────────────────────────────
# In order: every check that needs no write, the token (hidden prompt, getMe, role check), the token
# store (checkpoint 1), pairing (a pasted token, or a saved token with no allowlist yet), the access.json
# write (one id, the account that pressed Start, only when the file is absent), the bridge, and the final
# read. An Enter-only re-run that finds an allowlist never pairs.
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
    fi

    if [ "$pasted" = 1 ] || [ -z "$access_id" ]; then
        rs_pair
        lbl=$(printf '%s' "$RS_PAIR_LABEL" | LC_ALL=C tr -d '\000-\037\177')
        rs_step "paired with ${lbl:0:40} (Telegram id $RS_PAIR_ID)"
        [ -z "$access_id" ] && [ -e "$access" ] && access_id=$(rs_access_id "$access" || printf BAD)
        if [ -z "$access_id" ]; then
            rs_json_edit "$access" '{}' '.allowFrom = [$id]' --arg id "$RS_PAIR_ID" \
                || rs_fix "the allowlist could not be written to $(rs_tilde "$access"): check that the folder is writable, then run the same command again"
            rs_step "the allowlist lists only your Telegram id ($RS_PAIR_ID)"
        elif [ "$access_id" != "$RS_PAIR_ID" ]; then
            rs_fix "access.json already lists a different Telegram account than the one that pressed Start, and it was left unchanged: press Start from the account it lists, or have your chief fix access.json, then run the same command again"
        fi
    else
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

# ── part 4: bot-to-bot ──────────────────────────────────────────────────
# Order: every check that needs no write (part 1 is done, the bridge token, its bot and role), the token
# store with the bot id published first as pending (checkpoint 1), then one of two paths. A side whose peer
# is already confirmed only posts its hello. A side that is not (or one run with --replace) finds the group
# and the other bridge bot by hello, checks the group, and has setup.ts add and confirm the peer, writing
# the record of set-up peers right after confirm succeeds (checkpoint 2). Last come the poller unit and a
# status read. setup.ts is the only writer of the peer config.

PEER_UNIT=himmel-peer-bridge.service
PEER_LABEL=com.himmel.peer-bridge
PEER_HELLO="himmel peer hello"
# 1 once this run has stored a new bridge token: the poller reads it at start, so a running one is restarted.
PEER_TOKEN_CHANGED=0

# What a getUpdates answer is reduced to: only these facts are kept, never message text.
PEER_NORM='[.result[]? | . as $u | (
    ($u.my_chat_member // empty | select((.new_chat_member.user.id | tostring) == $me)
      | {u: $u.update_id, k: "mcm", chat: (.chat.id | tostring), type: (.chat.type // ""), title: ((.chat.title // "") | gsub("[\n\r\t]"; " ")), status: (.new_chat_member.status // "")}),
    ($u.message // empty | select(.migrate_to_chat_id != null)
      | {u: $u.update_id, k: "migrate", chat: (.chat.id | tostring), to: (.migrate_to_chat_id | tostring)}),
    ($u.message // empty | select((.text | type) == "string" and (.from.is_bot == false) and ((.text | ascii_downcase | gsub("^\\s+|\\s+$"; "")) == "hello"))
      | {u: $u.update_id, k: "hello", chat: (.chat.id | tostring), type: (.chat.type // ""), title: ((.chat.title // "") | gsub("[\n\r\t]"; " ")), date: (.date // 0)}),
    ($u.message // empty | select(.text == "himmel peer hello" and .from.is_bot == true and (.from.id | tostring) != $me)
      | {u: $u.update_id, k: "peer", chat: (.chat.id | tostring), from: (.from.id | tostring), user: (.from.username // ""), date: (.date // 0)})
  )]'

peer_cfg() { printf '%s' "$HOME/.config/himmel/peer-bridge"; }
peer_confirmed_file() { printf '%s' "$HOME/.himmel/remote-setup/peers-confirmed.json"; }
peer_bots_file() { printf '%s' "$HOME/.himmel/remote-setup/bots.json"; }
peer_unit_file() {
    if [ "$(uname)" = Darwin ]; then printf '%s' "$HOME/Library/LaunchAgents/$PEER_LABEL.plist"; else printf '%s' "$HOME/.config/systemd/user/$PEER_UNIT"; fi
}
peer_unit_active() {
    if [ "$(uname)" = Darwin ]; then
        launchctl print "gui/$(id -u)/$PEER_LABEL" > /dev/null 2>&1
    else
        systemctl --user is-active --quiet "$PEER_UNIT" > /dev/null 2>&1
    fi
}

peer_stored_token() {
    local f line
    f="$(peer_cfg)/env"
    [ -f "$f" ] || return 0
    line=$(sed -n 's/^PEER_BOT_TOKEN=//p' "$f" | head -n 1)
    line=${line#\"}
    line=${line%\"}
    line=${line#\'}
    line=${line%\'}
    printf '%s' "$line"
}

peer_store_token() {
    local d
    d=$(peer_cfg)
    (umask 077; mkdir -p "$d") 2> /dev/null || return 1
    printf 'PEER_BOT_TOKEN=%s\n' "$RS_TOKEN" | rs_atomic_write "$d/env" 2> /dev/null
}

# peer_peers_all: name|peerBotId|chatId per peer that setup.ts knows (chatId is null until confirm). Only
# rows of the shapes setup.ts writes come out, so the callers can split them on whitespace safely.
peer_peers_all() {
    local f
    f="$(peer_cfg)/peers.json"
    [ -f "$f" ] || return 0
    jq -r '.peers // {} | to_entries[]
      | select((.key | test("^[a-z0-9][a-z0-9-]{0,31}$")) and ((.value.peerBotId | tostring) | test("^[0-9]{1,15}$"))
               and (.value.chatId == null or ((.value.chatId | tostring) | test("^-[0-9]{1,15}$"))))
      | "\(.key)|\(.value.peerBotId)|\(.value.chatId // "null")"' "$f"
}
peer_confirmed_lines() { peer_peers_all | awk -F'|' '$3 != "null"'; }

peer_peers_check() {
    local f
    f="$(peer_cfg)/peers.json"
    [ -e "$f" ] || return 0
    jq -e '.peers | type == "object"' "$f" > /dev/null 2>&1 \
        || rs_fix "the peer list at $(rs_tilde "$f") cannot be read (is it valid, and is it yours?): fix that or move it away, then run the same command again"
}

peer_bots_state() {
    local f
    f=$(peer_bots_file)
    [ -f "$f" ] || return 0
    jq -r 'if (.bridge.id // null) == null then empty else "\(.bridge.id)|\(if .bridge.pending == true then 1 else 0 end)" end' "$f" 2> /dev/null
}

peer_publish_bridge() {
    local f rc
    f=$(peer_bots_file)
    if [ "$2" = 1 ]; then
        rs_json_edit "$f" '{}' '.bridge = {id: $id, pending: true}' --arg id "$1"
    else
        rs_json_edit "$f" '{}' '.bridge = {id: $id, publishedAt: $t}' --arg id "$1" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ]; then
        rs_fix "$(rs_tilde "$f") is not valid JSON, and it was left unchanged: move it away, then run the same command again"
    fi
    rs_fix "the bot record $(rs_tilde "$f") could not be written: check that you own that folder, then run the same command again"
}

peer_checkpoint() {
    local f cur
    f=$(peer_confirmed_file)
    if [ -f "$f" ]; then
        cur=$(jq -r --arg n "$1" --arg b "$2" --argjson c "$3" '[(.peers // [])[] | select(.name == $n and .peerBotId == $b and .chatId == $c)] | length' "$f" 2> /dev/null)
        [ "$cur" = 1 ] && return 0
    fi
    rs_json_edit "$f" '{"peers":[]}' '.peers = ([(.peers // [])[] | select(.name != $n)] + [{name: $n, peerBotId: $b, chatId: $c, confirmedAt: $t}])' \
        --arg n "$1" --arg b "$2" --argjson c "$3" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        || rs_fix "the record of set-up peers could not be written ($(rs_tilde "$f")): check that it is valid and yours, then run the same command again"
}

peer_checkpoint_drop() {
    local f
    f=$(peer_confirmed_file)
    [ -f "$f" ] || return 0
    rs_json_edit "$f" '{"peers":[]}' '.peers = [(.peers // [])[] | select(.name != $n)]' --arg n "$1" \
        || rs_fix "the record of set-up peers could not be changed ($(rs_tilde "$f")): check that it is valid and yours, then run the same command again"
    if [ "$(jq -r '(.peers // []) | length' "$f" 2> /dev/null)" = 0 ]; then rm -f "$f"; fi
}

# peer_reconcile: the record of set-up peers follows setup.ts. It is derived data: one that is not a list is
# deleted; a confirmed peer setup.ts holds is recorded (an old one set up before this helper existed is
# adopted); an entry setup.ts no longer holds, or that fails the name pattern, is dropped.
peer_reconcile() {
    local f line name rest bid chat keep stale
    f=$(peer_confirmed_file)
    if [ -f "$f" ] && ! jq -e '.peers | type == "array"' "$f" > /dev/null 2>&1; then rm -f "$f"; fi
    keep=$(peer_confirmed_lines | cut -d'|' -f1 | jq -R . | jq -sc .)
    for line in $(peer_confirmed_lines); do
        name=${line%%|*}
        rest=${line#*|}
        bid=${rest%%|*}
        chat=${rest#*|}
        peer_checkpoint "$name" "$bid" "$chat"
    done
    [ -f "$f" ] || return 0
    stale=$(jq -r --argjson keep "$keep" '[(.peers // [])[] | select((.name as $n | $keep | index($n)) | not)] | length' "$f" 2> /dev/null)
    if [ "$stale" != 0 ]; then
        rs_json_edit "$f" '{"peers":[]}' '.peers = [(.peers // [])[] | select(.name as $n | $keep | index($n))]' --argjson keep "$keep" \
            || rs_fix "the record of set-up peers could not be changed ($(rs_tilde "$f")): check that it is valid and yours, then run the same command again"
        if [ "$(jq -r '(.peers // []) | length' "$f" 2> /dev/null)" = 0 ]; then rm -f "$f"; fi
    fi
}

# peer_setup_run <verb> <args...>: setup.ts runs on the terminal (stdout stays a terminal; setup.ts insists on
# one) and its refusal is the FIX. Prompts of its own (remove asks for yes) reach the human on stderr.
peer_setup_run() {
    local verb=$1 err rc msg
    err=$(mktemp "${TMPDIR:-/tmp}/remote-setup-setup.XXXXXX") || rs_fix "could not make a temporary file: check that your temp folder is writable, then run the same command again"
    RS_TMP_FILE=$err
    if [ "$verb" = remove ]; then
        bun "$RS_ROOT/scripts/peer-bridge/setup.ts" "$@"
        rc=$?
    else
        bun "$RS_ROOT/scripts/peer-bridge/setup.ts" "$@" 2> "$err"
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        if [ "$verb" = remove ] && [ -n "${2:-}" ] && peer_peers_all | cut -d'|' -f1 | grep -qxF -- "$2"; then
            rm -f "$(peer_removing_file)"
            rs_fix "nothing was removed: $2 is still set up. Run the same command again to pick a peer to remove"
        fi
        msg=$(sed -n 's/^setup: //p' "$err" | head -n 1)
        msg=$(rs_clean "$msg")
        if [ -n "$msg" ]; then rs_fix "setup.ts did not $verb the peer: ${msg:0:200}. Fix that, then run the same command again"; fi
        rs_fix "setup.ts did not $verb the peer (it printed its reason just above): fix that, then run the same command again"
    fi
    rm -f "$err"
    RS_TMP_FILE=""
}


# peer_post_hello <chat id>: posts the hello; sets PEER_POSTED_CHAT to the group it went to, which is the
# supergroup id when Telegram answers that the group was upgraded to one.
peer_post_hello() {
    local body out mig
    [[ $1 =~ ^-[0-9]{1,15}$ ]] || rs_fix "Telegram gave a group id the helper does not trust: run the same command again"
    PEER_POSTED_CHAT=$1
    body=$(jq -nc --argjson c "$1" --arg t "$PEER_HELLO" '{chat_id: $c, text: $t}')
    if ! out=$(rs_tg sendMessage "$body"); then
        mig=$(printf '%s' "$out" | jq -r '.parameters.migrate_to_chat_id // empty' 2> /dev/null)
        [[ $mig =~ ^-[0-9]{1,15}$ ]] || rs_tg_fail "$out" "posting the hello in the group"
        PEER_POSTED_CHAT=$mig
        body=$(jq -nc --argjson c "$mig" --arg t "$PEER_HELLO" '{chat_id: $c, text: $t}')
        out=$(rs_tg sendMessage "$body") || rs_tg_fail "$out" "posting the hello in the group"
    fi
}

# peer_rehome <old chat> <new chat>: every confirmed peer in a group that became a supergroup is confirmed
# again in the new one, so setup.ts and the record of set-up peers keep the id the hello went to.
peer_rehome() {
    local line name rest bid chat
    for line in $(peer_confirmed_lines); do
        name=${line%%|*}
        rest=${line#*|}
        bid=${rest%%|*}
        chat=${rest#*|}
        [ "$chat" = "$1" ] || continue
        peer_setup_run confirm "$name" "$2"
        peer_checkpoint "$name" "$bid" "$2"
        rs_step "$name now lives in the supergroup $2"
    done
}

# peer_fetch <offset or empty> <long-poll seconds>: one getUpdates; its facts join the events in $RS_UPD_FILE.
peer_fetch() {
    local body out new
    body=$(jq -nc --arg off "$1" --argjson t "$2" '{limit: 100, timeout: $t} + (if $off == "" then {} else {offset: ($off | tonumber)} end)')
    out=$(rs_tg getUpdates "$body") || rs_tg_fail "$out" "reading the group's messages"
    PEER_LAST_COUNT=$(printf '%s' "$out" | jq -r '.result | length')
    PEER_LAST_ID=$(printf '%s' "$out" | jq -r '(.result | last | .update_id) // 0')
    new=$(printf '%s' "$out" | jq -c --arg me "$RS_BOT_ID" "$PEER_NORM") \
        || rs_fix "Telegram's list of messages could not be read: run the same command again"
    if ! printf '%s' "$new" | jq -c --slurpfile old "$RS_UPD_FILE" '$old[0] + . | unique_by([.u, .k])' > "$RS_UPD_FILE.new"; then
        rs_fix "Telegram's list of messages could not be kept: run the same command again"
    fi
    mv "$RS_UPD_FILE.new" "$RS_UPD_FILE" || rs_fix "Telegram's list of messages could not be kept: run the same command again"
}

peer_backlog_fix() {
    rs_fix "too many queued messages: let the bridge catch up for a minute, then ask the other operator to run the same command once more, then run it here again"
}

peer_page_on() {
    local pages=0
    while [ "$PEER_LAST_COUNT" -ge 100 ] && [ "$pages" -lt 50 ]; do
        pages=$((pages + 1))
        peer_fetch "$((PEER_LAST_ID + 1))" 0
    done
    [ "$PEER_LAST_COUNT" -lt 100 ] || peer_backlog_fix
}

# peer_read_all <1|0>: the first read. 1 (a side with no poller to protect) pages through the backlog and
# acknowledges as it goes; 0 reads once and never acknowledges, so the poller's own messages are not lost.
peer_read_all() {
    PEER_PAGE=$1
    peer_fetch "" 0
    [ "$PEER_PAGE" = 1 ] || return 0
    peer_page_on
}

# peer_chat_candidates: the groups this bridge bot is in: those its own membership updates name, else those
# where the human sent the word hello after this run started. Lines are chat|type|title.
peer_chat_candidates() {
    PEER_CANDS=$(jq -r --argjson start "$PEER_START" '
      (map(select(.k == "migrate") | {(.chat): .to}) | add // {}) as $mig
      | ([.[] | select(.k == "mcm")] | sort_by(.u) | group_by(.chat) | map(last) | map(select(.status == "member" or .status == "administrator"))) as $m
      | (if ($m | length) > 0 then $m
         else ([.[] | select(.k == "hello" and .date >= $start)] | sort_by(.u) | group_by(.chat) | map(last)) end)
      | map(. + {chat: ($mig[.chat] // .chat)}) | unique_by(.chat) | .[] | "\(.chat)|\(.type)|\(.title)"' "$RS_UPD_FILE")
}

peer_find_peer() {
    PEER_BOTS=$(jq -r --arg chat "$PEER_CHAT" '[.[] | select(.k == "peer" and .chat == $chat)] | sort_by(.u) | unique_by(.from) | .[] | "\(.from)|\(.user)"' "$RS_UPD_FILE")
}

peer_wait() {
    local what=$1 deadline
    deadline=$(($(date +%s) + 600))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
        peer_fetch "" 8
        if [ "$PEER_PAGE" = 1 ]; then peer_page_on; fi
        if [ "$what" = chat ]; then
            peer_chat_candidates
            [ -n "$PEER_CANDS" ] && return 0
        else
            peer_find_peer
            [ -n "$PEER_BOTS" ] && return 0
        fi
        if [ "$PEER_PAGE" = 0 ] && [ "$PEER_LAST_COUNT" -ge 100 ]; then peer_backlog_fix; fi
    done
    return 1
}

peer_choose() {
    local lines=$1 n i=1 label
    n=$(printf '%s\n' "$lines" | grep -c .)
    if [ "$n" -eq 1 ]; then PEER_CHOSEN=$lines; return 0; fi
    [ "$n" -le 9 ] || rs_fix "more than nine choices were found: ask the other operator to remove the extra bots from the group, then run the same command again"
    while [ "$i" -le "$n" ]; do
        label=$(printf '%s\n' "$lines" | sed -n "${i}p")
        label=$(printf '%s' "${label#*|}" | LC_ALL=C tr -d '\000-\037\177')
        rs_say "  $i) ${label:0:60}"
        i=$((i + 1))
    done
    rs_pick "$n" || rs_fix "no choice was made: run the same command again and type one of the numbers"
    PEER_CHOSEN=$(printf '%s\n' "$lines" | sed -n "${RS_PICK}p")
}

peer_discover() {
    local lines
    peer_read_all "$1"
    peer_chat_candidates
    if [ -z "$PEER_CANDS" ]; then
        if [ "$PEER_PAGE" = 0 ] && [ "$PEER_LAST_COUNT" -ge 100 ]; then peer_backlog_fix; fi
        rs_say "  In Telegram, open the group and send the word hello in it. Waiting up to 10 minutes..."
        peer_wait chat || rs_fix "no hello arrived from the group: run the same command again, wait until it asks you to send the word hello in the group (a hello sent earlier is not seen), then send it"
    fi
    lines=$(printf '%s\n' "$PEER_CANDS" | sed -E 's/^([^|]*)\|([^|]*)\|(.*)$/\1|\3 (\2)/')
    peer_choose "$lines"
    PEER_CHAT=${PEER_CHOSEN%%|*}
    [[ $PEER_CHAT =~ ^-[0-9]{1,15}$ ]] || rs_fix "Telegram gave a group id the helper does not trust: run the same command again"
    rs_step "found the group"

    peer_post_hello "$PEER_CHAT"
    PEER_CHAT=$PEER_POSTED_CHAT
    rs_step "posted the hello in the group"
    peer_find_peer
    if [ -z "$PEER_BOTS" ]; then
        if [ "$PEER_PAGE" = 0 ] && [ "$PEER_LAST_COUNT" -ge 100 ]; then peer_backlog_fix; fi
        rs_say "  Waiting for the other station's hello (up to 10 minutes)..."
        peer_wait peer || rs_fix "no hello came from the other station: ask the other operator to run the same command once, then run it here again"
    fi
    lines=$(printf '%s\n' "$PEER_BOTS" | awk -F'|' '{printf "%s|@%s (bot id %s)\n", $1, $2, $1}')
    peer_choose "$lines"
    PEER_BOT_ID=${PEER_CHOSEN%%|*}
    PEER_BOT_USER=$(printf '%s\n' "$PEER_BOTS" | awk -F'|' -v id="$PEER_BOT_ID" '$1 == id {print $2; exit}')
    [[ $PEER_BOT_ID =~ ^[0-9]{1,15}$ ]] || rs_fix "Telegram gave a bot id the helper does not trust: run the same command again"
    [[ $PEER_BOT_USER =~ ^[A-Za-z][A-Za-z0-9_]{2,31}$ ]] || rs_fix "the other station's bot name is not a usable Telegram username: ask the other operator to check their bridge bot, then run the same command again"
    [ "$PEER_BOT_ID" != "$PEER_MAIN_ID" ] || rs_fix "your main bot is in the group, and it must not be: remove it from the group (Edit → Administrators, then Members), and add only the bridge bots, then run the same command again"
    rs_step "found the other station's bridge bot (@$PEER_BOT_USER)"
    if [ "$(printf '%s\n' "$PEER_BOTS" | grep -c .)" -eq 1 ]; then peer_confirm_sole; fi
}

# peer_confirm_sole: a lone hello is not proof of whose bot it is. The operator confirms the name before
# anything is paired (setup.ts add writes it into allowFrom).
peer_confirm_sole() {
    rs_say "  Only one bot said hello in the group: @$PEER_BOT_USER (id masked)."
    rs_say "  Check with the other operator that this is the name of their bridge bot."
    rs_say "  1) yes, that is their bridge bot"
    rs_say "  2) no"
    rs_pick 2 || rs_fix "no answer was given about @$PEER_BOT_USER, so nothing was paired: ask the other operator for the name of their bridge bot, then run the same command again and type 1 only if it matches"
    [ "$RS_PICK" = 1 ] || rs_fix "you said @$PEER_BOT_USER is not their bridge bot, so nothing was paired: ask the other operator for the name of their bridge bot and have them leave only that bot in the group, then run the same command again"
    rs_step "you confirmed @$PEER_BOT_USER is the other station's bridge bot"
}


peer_right_button() {
    case "$1" in
        can_change_info) printf 'Change group info' ;;
        can_delete_messages) printf 'Delete messages' ;;
        can_restrict_members) printf 'Ban users' ;;
        can_invite_users) printf 'Add users' ;;
        can_pin_messages) printf 'Pin messages' ;;
        can_promote_members) printf 'Add new admins' ;;
        can_manage_video_chats | can_manage_voice_chats) printf 'Manage video chats' ;;
        can_manage_topics) printf 'Manage topics' ;;
        can_post_stories) printf 'Post stories' ;;
        can_edit_stories) printf 'Edit stories of others' ;;
        can_delete_stories) printf 'Delete stories of others' ;;
        can_post_messages) printf 'Post messages' ;;
        can_edit_messages) printf 'Edit messages of others' ;;
    esac
}

# peer_group_fix <what is wrong> <what to press>: the FIX for a group problem. Only the group owner can change
# the group, so anyone else is told to ask them (the operator is the owner when Telegram says so).
peer_group_fix() {
    local out st
    st=""
    out=$(rs_tg getChatMember "$(jq -nc --argjson c "$PEER_CHAT" --argjson u "$PEER_OPERATOR" '{chat_id: $c, user_id: $u}')") \
        && st=$(printf '%s' "$out" | jq -r '.result.status // ""')
    if [ "$st" = creator ]; then
        rs_fix "$1. In Telegram, $2, then run the same command again"
    fi
    rs_fix "$1: ask the group owner to $2, then run the same command again"
}

peer_check_group() {
    local out rc ty mig bad f btn who id user label problem field
    PEER_CHAT=$1
    out=$(rs_tg getChat "$(jq -nc --argjson c "$PEER_CHAT" '{chat_id: $c}')")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        mig=$(printf '%s' "$out" | jq -r '.parameters.migrate_to_chat_id // empty' 2> /dev/null)
        if [[ $mig =~ ^-[0-9]{1,15}$ ]]; then
            PEER_CHAT=$mig
            out=$(rs_tg getChat "$(jq -nc --argjson c "$PEER_CHAT" '{chat_id: $c}')") || rs_tg_fail "$out" "the group check"
        else
            rs_tg_fail "$out" "the group check"
        fi
    fi
    ty=$(printf '%s' "$out" | jq -r '.result.type // ""')
    case "$ty" in *[!a-z]* | '') ty=unknown ;; esac
    if [ "$ty" != supergroup ]; then
        [ "$ty" = group ] && ty="basic group"
        peer_group_fix "this is a $ty, and bridge bots need a supergroup" "open the group and press Edit → Group type → Public → set any link → Save, then Edit → Group type → Private → Save"
    fi
    bad=""
    for f in can_change_info can_pin_messages; do
        if [ "$(printf '%s' "$out" | jq -r --arg f "$f" '.result.permissions[$f] == true')" = true ]; then
            bad="${bad:+$bad and }$(peer_right_button "$f")"
        fi
    done
    if [ -n "$bad" ]; then
        peer_group_fix "group members are allowed to use $bad, which locks those rights on for the bots" "press Edit → Permissions, turn off $bad, and Save"
    fi

    for who in "your bridge bot|$RS_BOT_ID|$RS_BOT_USER" "the other station's bridge bot|$2|$3"; do
        label=${who%%|*}
        id=${who#*|}
        user=${id#*|}
        id=${id%%|*}
        out=$(rs_tg getChatMember "$(jq -nc --argjson c "$PEER_CHAT" --argjson u "$id" '{chat_id: $c, user_id: $u}')") \
            || peer_group_fix "$label (@$user) is not in the group" "open the group, press Add Members, and add @$user by username (invite links do not work for bots)"
        problem=$(printf '%s' "$out" | jq -r --arg id "$id" '
          if .result.status != "administrator" then "status:" + (.result.status // "none")
          elif .result.is_anonymous != false then "anonymous"
          elif ((.result.user.id | tostring) != $id) then "otherid"
          elif .result.user.is_bot != true then "notbot"
          else ([.result | to_entries[] | select((.key | startswith("can_")) and .key != "can_manage_chat" and .value != false and .value != null) | .key] | first // empty) | "right:" + . end')
        case "$problem" in
            '') ;;
            status:*)
                peer_group_fix "$label (@$user) is not an administrator of the group" "press Edit → Administrators → Add Admin, pick @$user, switch every right off, and Save"
                ;;
            right:*)
                field=${problem#right:}
                case "$field" in *[!a-z_]* | '') field="an unknown right" ;; esac
                btn=$(peer_right_button "$field")
                if [ -n "$btn" ]; then
                    peer_group_fix "$label (@$user) has the admin right \"$btn\" on" "press Edit → Administrators → @$user, switch $btn off, and Save"
                fi
                peer_group_fix "$label (@$user) has the admin right $field on" "press Edit → Administrators → @$user, switch $field off, and Save"
                ;;
            *)
                peer_group_fix "$label (@$user) is not set up as a plain administrator" "press Edit → Administrators → @$user, make it an administrator that is not anonymous, switch every right off, and Save"
                ;;
        esac
    done
    rs_step "the group is a supergroup and both bridge bots are administrators with every right off"
}


peer_register() {
    local line name rest bid chat names="" match_name="" match_chat="" chat_name="" old_bid=""
    for line in $(peer_peers_all); do
        name=${line%%|*}
        rest=${line#*|}
        bid=${rest%%|*}
        chat=${rest#*|}
        names="$names $name"
        if [ "$bid" = "$PEER_BOT_ID" ]; then
            match_name=$name
            match_chat=$chat
        elif [ "$chat" = "$PEER_CHAT" ]; then
            chat_name=$name
            old_bid=$bid
        fi
    done
    if [ -n "$match_name" ]; then
        PEER_NAME=$match_name
        if [ "$match_chat" = "$PEER_CHAT" ]; then
            rs_step "setup.ts already has this peer confirmed" skip
        else
            peer_setup_run confirm "$PEER_NAME" "$PEER_CHAT"
            rs_step "setup.ts confirmed the group"
        fi
    else
        if [ -n "$chat_name" ]; then
            PEER_NAME=$chat_name
            rs_say "  The other station is now using a different bot (bot id $PEER_BOT_ID) than before (bot id $old_bid). I will remove the old entry and add the new bot; setup.ts asks you to type yes to remove."
            peer_setup_run remove "$PEER_NAME"
            peer_checkpoint_drop "$PEER_NAME"
        else
            # shellcheck disable=SC2086
            PEER_NAME=$(rs_peer_name_for "$PEER_BOT_USER" $names) || rs_fix "no usable local name could be made for @$PEER_BOT_USER: ask your chief to add the peer by hand with setup.ts"
        fi
        peer_setup_run add "$PEER_NAME" --peer-bot-id "$PEER_BOT_ID" --peer-username "$PEER_BOT_USER" --operator-bot-id "$PEER_MAIN_ID"
        rs_step "setup.ts added the peer as $PEER_NAME"
        peer_setup_run confirm "$PEER_NAME" "$PEER_CHAT"
        rs_step "setup.ts confirmed the group"
    fi
    peer_checkpoint "$PEER_NAME" "$PEER_BOT_ID" "$PEER_CHAT"
}

peer_unit_ensure() {
    local tpl dest content cur changed=0 redo uid
    uid=$(id -u)
    if [ "$(uname)" = Darwin ]; then tpl="$RS_ROOT/scripts/peer-bridge/units/$PEER_LABEL.plist"; else tpl="$RS_ROOT/scripts/peer-bridge/units/$PEER_UNIT"; fi
    [ -f "$tpl" ] || rs_fix "the poller unit template is missing from your himmel folder: run /himmel-update, then run the same command again"
    if [ "$(uname)" != Darwin ]; then
        case "$RS_ROOT" in *[[:space:]]*) rs_fix "the poller cannot run from a folder with a space in its path ($RS_ROOT): move your himmel folder to a path without spaces, then run the same command again" ;; esac
    fi
    dest=$(peer_unit_file)
    content=$(cat "$tpl")
    content=${content//@HIMMEL_ROOT@/$RS_ROOT}
    content=${content//@HOME@/$HOME}
    cur=""
    [ -f "$dest" ] && cur=$(cat "$dest")
    [ "$cur" != "$content" ] && changed=1
    redo=$changed
    [ "$PEER_TOKEN_CHANGED" = 1 ] && redo=1
    if [ "$redo" = 1 ] && [ "$(uname)" = Darwin ] && peer_unit_active; then
        launchctl bootout "gui/$uid/$PEER_LABEL" > /dev/null 2>&1
        if peer_unit_active; then
            rs_fix "the old poller could not be stopped, so the updated one was not applied (nothing was changed): stop it yourself with launchctl bootout gui/$uid/$PEER_LABEL, then run the same command again"
        fi
    fi
    if [ "$changed" = 1 ]; then
        (umask 022; mkdir -p "$(dirname "$dest")") || rs_fix "the poller unit folder could not be made: check that you own your home folder, then run the same command again"
        printf '%s\n' "$content" | rs_atomic_write "$dest" \
            || rs_fix "the poller unit could not be written: check that you own your home folder, then run the same command again"
    fi
    if [ "$(uname)" != Darwin ]; then
        if [ "$changed" = 1 ]; then systemctl --user daemon-reload > /dev/null 2>&1 || rs_fix "systemd did not accept the poller unit: run systemctl --user daemon-reload yourself and read its error, then run the same command again"; fi # t13b-ok: reloads unit files after the operator-run peer setup wrote the poller unit; the FIX text only names that command
        if ! systemctl --user is-enabled --quiet "$PEER_UNIT" > /dev/null 2>&1; then
            systemctl --user enable "$PEER_UNIT" > /dev/null 2>&1 || rs_fix "the poller unit could not be enabled: run systemctl --user enable $PEER_UNIT yourself and read its error, then run the same command again" # t13b-ok: enables the peer poller unit that this operator-run peer setup just installed (Part 4 opt-in), nothing else
        fi
        if [ "$redo" = 1 ] && peer_unit_active; then
            systemctl --user restart "$PEER_UNIT" > /dev/null 2>&1 || rs_fix "the poller did not restart: look at why with: journalctl --user -u $PEER_UNIT -n 30, then run the same command again"
        fi
    fi
    if ! peer_unit_active; then
        rs_unit_start "$PEER_UNIT" "$PEER_LABEL" \
            || rs_fix "the peer poller did not start (your setup is kept, so the same command resumes here): look at why with: $(peer_log_hint), then run the same command again"
    fi
}

peer_log_hint() {
    if [ "$(uname)" = Darwin ]; then printf 'the last 30 lines of the poller log named in docs/internals/peer-bridge.md (Audit trail)'; else printf 'journalctl --user -u %s -n 30' "$PEER_UNIT"; fi
}

# peer_unit_teardown: stops, disables and deletes the poller unit (the way back for peer --remove). It returns
# 1 and sets PEER_TEARDOWN_FAILED to the step that did not happen (stop, delete or reload), so nothing reports
# a stop or a deletion that did not take place. The unit file stays while the poller still runs.
peer_unit_teardown() {
    local f
    f=$(peer_unit_file)
    PEER_TEARDOWN_FAILED=""
    if [ "$(uname)" = Darwin ]; then
        launchctl bootout "gui/$(id -u)/$PEER_LABEL" > /dev/null 2>&1
        if peer_unit_active; then PEER_TEARDOWN_FAILED=stop; return 1; fi
        if ! rm -f "$f" 2> /dev/null || [ -e "$f" ]; then PEER_TEARDOWN_FAILED=delete; return 1; fi
    else
        systemctl --user disable --now "$PEER_UNIT" > /dev/null 2>&1
        if peer_unit_active; then PEER_TEARDOWN_FAILED=stop; return 1; fi
        if ! rm -f "$f" 2> /dev/null || [ -e "$f" ]; then PEER_TEARDOWN_FAILED=delete; return 1; fi
        if ! systemctl --user daemon-reload > /dev/null 2>&1; then PEER_TEARDOWN_FAILED=reload; return 1; fi
    fi
    return 0
}

peer_teardown_fix() {
    local how="systemctl --user disable --now $PEER_UNIT" f
    f=$(peer_unit_file)
    if [ "$(uname)" = Darwin ]; then how="launchctl bootout gui/$(id -u)/$PEER_LABEL"; fi
    case "$PEER_TEARDOWN_FAILED" in
        delete) rs_fix "the peer poller is stopped, but its unit file could not be deleted (a peer that was removed stays removed, so the same command finishes the job): delete $(rs_tilde "$f") yourself, then run the same command again" ;;
        reload) rs_fix "the peer poller is stopped and its unit file is deleted, but systemd did not reload its unit list: run systemctl --user daemon-reload yourself, and nothing else is left to do" ;; # t13b-ok: remediation message text only, starts nothing
    esac
    rs_fix "the peer poller could not be stopped (a peer that was removed stays removed, so the same command finishes the job): stop it yourself with $how, then run the same command again"
}

peer_finish() {
    local names=$1 doc state detail
    peer_unit_ensure
    rs_step "the poller unit is installed and running"
    sleep 2
    doc=$("$BASH" "$RS_SELF_DIR/remote-setup.sh" status --json 2> /dev/null)
    state=$(printf '%s' "$doc" | jq -r '.parts[3].state // "error"' 2> /dev/null)
    if [ "$state" != ok ]; then
        detail=$(rs_clean "$(printf '%s' "$doc" | jq -r '.parts[3].detail // "no detail"' 2> /dev/null)")
        rs_fix "the peer bridge is not running yet (${detail:0:200}): wait a minute, look at $(peer_log_hint), then run the same command again"
    fi
    rs_step "the status check passes"
    rs_done "peer $names — group confirmed, poller running"
}

peer_restart_fix() {
    rs_fix "the peer poller did not restart (the peer you removed stays removed): look at why with: $(peer_log_hint), then run: bash scripts/remote-setup/remote-setup.sh peer --remove"
}

# The removal of one peer while others stay is recorded here until the poller has restarted, so an
# interrupted run finishes that removal and never offers a remaining peer in its place.
peer_removing_file() { printf '%s' "$HOME/.himmel/remote-setup/peer-removing.json"; }

peer_removing_read() {
    local f n
    f=$(peer_removing_file)
    [ -f "$f" ] || return 0
    n=$(jq -r '.name // empty' "$f" 2> /dev/null)
    if [[ $n =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then printf '%s' "$n"; fi
    return 0
}

peer_remove() {
    local names listed name lines known
    peer_peers_check
    name=$(peer_removing_read)
    if [ -n "$name" ] && peer_peers_all | cut -d'|' -f1 | grep -qxF -- "$name"; then
        peer_choose "finish|Finish removing $name, which was started before
cancel|Cancel that removal and pick again"
        if [ "${PEER_CHOSEN%%|*}" = cancel ]; then
            rm -f "$(peer_removing_file)"
            rs_step "the earlier removal of $name was cancelled"
            name=""
        fi
    fi
    if [ -n "$name" ]; then
        rs_step "finishing the removal of $name, which was started before"
    else
        names=$(peer_peers_all | cut -d'|' -f1)
        if [ -f "$(peer_confirmed_file)" ]; then
            listed=$(jq -r '(.peers // [])[]?.name | select(type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$"))' "$(peer_confirmed_file)" 2> /dev/null)
            names=$(printf '%s\n%s\n' "$names" "$listed" | grep . | sort -u)
        fi
        if [ -z "$names" ]; then
            if [ -z "$(peer_peers_all)" ] && [ -f "$(peer_unit_file)" ]; then
                peer_unit_teardown || peer_teardown_fix
                rs_done "peer — nothing to remove; the leftover poller was stopped and its unit deleted"
            fi
            rs_done "peer — nothing to remove"
        fi
        lines=$(printf '%s\n' "$names" | awk '{print $0 "|" $0}')
        peer_choose "$lines"
        name=${PEER_CHOSEN%%|*}
        if [ "$(printf '%s\n' "$names" | grep -c .)" -gt 1 ]; then
            rs_json_edit "$(peer_removing_file)" '{}' '.name = $n' --arg n "$name" \
                || rs_fix "the removal of $name could not be recorded ($(rs_tilde "$(peer_removing_file)")): check that you own your home folder, then run the same command again"
        fi
    fi
    known=$(peer_peers_all | cut -d'|' -f1)
    case "
$known
" in
        *"
$name
"*)
            peer_setup_run remove "$name"
            rs_step "setup.ts removed $name"
            ;;
        *) rs_step "setup.ts no longer has $name" skip ;;
    esac
    peer_checkpoint_drop "$name"
    rs_step "the record of set-up peers no longer lists $name"
    if [ -z "$(peer_peers_all)" ]; then
        peer_unit_teardown || peer_teardown_fix
        rm -f "$(peer_removing_file)"
        rs_done "peer — removed $name; the poller is stopped and its unit deleted"
    fi
    if peer_unit_active; then
        if [ "$(uname)" = Darwin ]; then
            launchctl bootout "gui/$(id -u)/$PEER_LABEL" > /dev/null 2>&1
            rs_unit_start "$PEER_UNIT" "$PEER_LABEL" || peer_restart_fix
        else
            systemctl --user restart "$PEER_UNIT" > /dev/null 2>&1 || peer_restart_fix
        fi
        rm -f "$(peer_removing_file)"
        rs_done "peer — removed $name; the poller was restarted"
    fi
    rm -f "$(peer_removing_file)"
    rs_done "peer — removed $name; the poller was not running, so there was nothing to restart"
}

cmd_peer() {
    rs_preflight curl jq node bun
    PEER_START=$(date +%s)
    if [ "$OPT_REMOVE" = 1 ]; then peer_remove; fi
    local main_tok op_id tok="" pasted=0 stored_tok cur_id conflict crc state fresh=1 names
    main_tok=$(rs_stored_token)
    op_id=$(rs_access_id "$HOME/.claude/channels/telegram/access.json") || op_id=""
    if [ -z "$main_tok" ] || [ -z "$op_id" ]; then
        rs_fix "do part 1 first: bash scripts/remote-setup/remote-setup.sh bot"
    fi
    PEER_MAIN_ID=${main_tok%%:*}
    PEER_OPERATOR=$op_id
    main_tok=""
    rs_step "part 1 is set up (main bot id $PEER_MAIN_ID)"
    peer_peers_check

    stored_tok=$(peer_stored_token)
    rs_secret tok "Paste the bridge bot token from @BotFather (or press Enter to keep the one already stored):" \
        || rs_fix "no token was entered: run the same command again and paste the token from @BotFather"
    if [ -n "$tok" ]; then
        rs_token_shape_ok "$tok" \
            || rs_fix "that is not a bot token: copy the whole token from @BotFather again, it looks like 123456789 then a colon then 35 letters and digits"
        pasted=1
    else
        [ -n "$stored_tok" ] || rs_fix "no bridge bot token is stored yet: run the same command again and paste the token from @BotFather"
        tok=$stored_tok
    fi
    RS_TOKEN=$tok
    tok=""
    rs_getme
    rs_step "the token works (@$RS_BOT_USER, bot id $RS_BOT_ID)"

    conflict=$(rs_role_check "$RS_BOT_ID" bridge)
    crc=$?
    if [ "$crc" -eq 2 ]; then
        rs_fix "the other bots' ids could not be checked: run the same command again, and if it repeats tell your chief"
    elif [ "$crc" -eq 1 ]; then
        rs_fix "this bot is already your ${conflict%%|*} bot: each role needs its own bot, so make a new one with @BotFather (send /newbot) for the bridge bot, then run the same command again"
    fi
    cur_id=""
    case "$stored_tok" in [0-9]*:*) cur_id=${stored_tok%%:*} ;; esac
    if [ -n "$cur_id" ] && [ "$cur_id" != "$RS_BOT_ID" ] && [ "$OPT_REPLACE" != 1 ]; then
        rs_fix "a different bridge bot is already set up (bot id $cur_id): to switch to @$RS_BOT_USER on purpose, run: bash scripts/remote-setup/remote-setup.sh peer --replace"
    fi

    state=$(peer_bots_state)
    if [ "$RS_TOKEN" = "$stored_tok" ]; then
        if [ "$state" != "$RS_BOT_ID|0" ]; then peer_publish_bridge "$RS_BOT_ID" 0; fi
        rs_step "the bridge token is already stored" skip
    else
        peer_publish_bridge "$RS_BOT_ID" 1
        peer_store_token \
            || rs_fix "the bridge token could not be saved in $(rs_tilde "$(peer_cfg)"): check that you own that folder and it is writable, then run the same command again"
        PEER_TOKEN_CHANGED=1
        peer_publish_bridge "$RS_BOT_ID" 0
        rs_step "the bridge token is saved"
    fi
    stored_tok=""
    peer_reconcile

    if [ -n "$(peer_confirmed_lines)" ] && [ "$OPT_REPLACE" != 1 ]; then
        fresh=0
    fi
    if [ "$fresh" = 0 ]; then
        local chat
        for chat in $(peer_confirmed_lines | cut -d'|' -f3 | sort -u); do
            peer_post_hello "$chat"
            if [ "$PEER_POSTED_CHAT" != "$chat" ]; then peer_rehome "$chat" "$PEER_POSTED_CHAT"; fi
        done
        rs_step "posted the hello; if the other station is not finished, ask its operator to run the same command once"
        names=$(peer_confirmed_lines | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        peer_finish "$names"
    fi

    local page=1
    [ -n "$(peer_confirmed_lines)" ] && page=0
    RS_UPD_FILE=$(mktemp "${TMPDIR:-/tmp}/remote-setup-updates.XXXXXX") || rs_fix "could not make a temporary file: check that your temp folder is writable, then run the same command again"
    printf '[]' > "$RS_UPD_FILE"
    if peer_unit_active; then
        rs_enter "The peer poller is running. I will pause it while I read Telegram's messages and start it again afterwards. Press Enter to continue:" \
            || rs_fix "no answer was given: run the same command again"
        rs_unit_stop "$PEER_UNIT" "$PEER_LABEL" \
            || rs_fix "the peer poller could not be paused: stop it yourself (systemctl --user stop $PEER_UNIT, or launchctl bootout it), then run the same command again"
    fi
    peer_discover "$page"
    peer_check_group "$PEER_CHAT" "$PEER_BOT_ID" "$PEER_BOT_USER"
    peer_register
    peer_finish "$PEER_NAME"
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
