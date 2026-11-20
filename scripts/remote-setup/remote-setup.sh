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
cmd_status() { rs_later "status"; }

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
