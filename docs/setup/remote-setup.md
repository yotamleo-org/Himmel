# Remote setup: reach your himmel station from Telegram

This page sets up the remote pieces of a himmel station, one part at a time. Each part is one
helper command that discovers every id for you: you never type a bot id, a chat id or a
username. Each command ends in one line that starts with `DONE:` (it worked) or `FIX:` (it
tells you the one thing to do, then run the same command again). A command is safe to run
again.

| Part | What it gives you | Status |
|---|---|---|
| [1](#part-1) | Your **main bot**: the bot your chief talks to you through | ready |
| [2](#part-2) | **Away launches**: start workers from your phone while you are away | arrives in a later update |
| [3](#part-3) | **Sudo bot**: approve a sudo step from your phone | arrives in a later update |
| [4](#part-4) | **Bot-to-bot**: two stations talk through a shared group | arrives in a later update |

## Before you start

You need:

- the Telegram app on your phone, signed in;
- a Terminal window of your own: a separate window, **not** Claude and **not** a `!` command
  inside Claude (the helper handles secrets and refuses to run there);
- about 5 minutes for part 1.

Step 0: in your Terminal window, go to your himmel folder. This guide assumes it is `~/himmel`:

```bash
cd ~/himmel
```

If you cloned himmel somewhere else, type `cd` and a space, drag that folder from your file
manager into the Terminal window, and press Enter. Every command on this page runs from that
folder, and every command works unchanged in bash, zsh and fish.

<a id="part-1"></a>

## Part 1: your main bot

### What it is

The main bot is a Telegram bot that only you can talk to. Your chief reads your messages through
it and answers there. It stays private: it never joins a group. Your bot gets its own name.

### In the Telegram app

1. Open a chat with **@BotFather** (the official bot with a blue check mark).
2. Send `/newbot`.
3. When it asks for a name, send any name you like, for example `My himmel`.
4. When it asks for a username, send one that ends in `bot`, for example `my_himmel_bot`.
5. BotFather replies with a line that starts with "Use this token to access the HTTP API". The
   token is the long line below it: digits, a colon, then letters and digits. Leave this chat
   open, you copy the token in the next step.

### In your Terminal: run 1

```bash
bash scripts/remote-setup/remote-setup.sh bot
```

When it asks, paste the token and press Enter. Nothing shows on screen while you paste: that is
on purpose. Then:

1. The helper checks the token with Telegram and saves it.
2. It shows a link. **Open that link on your phone and press Start.** This is how it learns
   which Telegram account is you.
3. It ends with a `FIX:` line that carries one `printf` line, like this:

```text
remote-setup bot: set up your main bot, the one your chief talks to you through
  1. checked the tools and access.json ... ok
  2. the token works (@my_himmel_bot, bot id 123456789) ... ok
  3. the token is saved ... ok
  Open this link on your phone and press Start in Telegram:
    https://t.me/my_himmel_bot?start=onboard-1a2b3c4d
  4. paired with Your Name (Telegram id 987654321) ... ok
FIX: have your chief create the allowlist with this line, then run the same command again: printf '{"allowFrom":["987654321"]}\n' > ~/.claude/channels/telegram/access.json
```

The helper never writes the allowlist file (`access.json`) itself: it decides who may talk to
your station, so only your chief creates it. **Copy that `printf` line, paste it to your chief
in Claude, and ask them to run it.**

### In your Terminal: run 2

```bash
bash scripts/remote-setup/remote-setup.sh bot
```

This time press Enter at the token prompt: it keeps the token it already saved and does not pair
again. The helper turns the bridge on, makes it start again after a reboot, and checks that it is
healthy.

On a Mac: the same command installs a LaunchAgent in `~/Library/LaunchAgents`, so the bridge
comes back after a restart.

### You should see

```text
DONE: bot — @my_himmel_bot (id 123456789) reachable, bridge running, survives reboot
```

Send your bot a message from your phone to see it work.

### If you see FIX

Every `FIX:` line names one thing to do. The common ones:

| The line says | What to do |
|---|---|
| `run this from your himmel folder: cd ...` | Go back to your himmel folder (step 0), then run the command again. |
| `this step handles secrets and must run in a separate plain Terminal` | Open a Terminal window of your own, not Claude, and run the command there. |
| `that is not a bot token` | Copy the whole token from @BotFather again. It is digits, a colon, then letters and digits. |
| `the token was revoked` | Send `/mybots` to @BotFather, pick your bot, open API Token and revoke it, then paste the new token. |
| `can't reach api.telegram.org` | Check your internet connection, then run the command again. |
| `Telegram asked to wait N s` | Wait that many seconds, then run the command again. |
| `this bot is already your ... bot` | Each role needs its own bot. Send `/newbot` to @BotFather for the main bot, then run the command again. |
| `a different main bot is already set up` | If you do want to switch bots, run the command with `--replace` (below). |
| `access.json must hold exactly one Telegram id` | The file `~/.claude/channels/telegram/access.json` is not in the expected shape. Fix it or move it away, then run the command again. |
| `have your chief create the allowlist with this line` | Give the `printf` line to your chief to run, then run the command again (run 2). |
| `access.json already lists a different Telegram account` | Press Start from the account that file lists, or have your chief fix the file, then run the command again. |
| `the bridge is still running, so pairing cannot start` | Stop it (below), then run the command again. |
| `no Start press arrived in time` | Run the command again and press Start right after the link appears. |
| `the bridge is not healthy yet` | Wait a minute, then run the command again. |

To switch to a different main bot on purpose:

```bash
bash scripts/remote-setup/remote-setup.sh bot --replace
```

To stop a bridge that is still running before pairing:

```bash
bash scripts/telegram/restart-bridge.sh stop
```

### Undo

To turn the bridge off on Linux:

```bash
systemctl --user disable --now telegram-bridge.service
```

On a Mac: turn it off, then remove its file so it does not come back at the next login:

```bash
launchctl remove com.himmel.telegram-bridge
```

```bash
rm -f ~/Library/LaunchAgents/com.himmel.telegram-bridge.plist
```

To delete the bot itself, send `/deletebot` to @BotFather. To keep the bot but make its token
useless, revoke it there (see the `the token was revoked` row above).

<a id="part-2"></a>

## Part 2: away launches

This part arrives in a later update. Run `/himmel-update` from time to time; this page then gets
its steps.

<a id="part-3"></a>

## Part 3: sudo bot

This part arrives in a later update. Run `/himmel-update` from time to time; this page then gets
its steps.

<a id="part-4"></a>

## Part 4: bot-to-bot

This part arrives in a later update. Run `/himmel-update` from time to time; this page then gets
its steps.

## Check everything

To see every part and what to do next:

```bash
bash scripts/remote-setup/remote-setup.sh status
```

```text
DONE: status — all shipped parts ok
```

If a part is not ready, the last line is a `FIX:` that names the part and its command. This
command only reads: it is safe to run anywhere, and it changes nothing.
