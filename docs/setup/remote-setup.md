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
| [4](#part-4) | **Bot-to-bot**: two stations talk through a shared group | ready |

## Before you start

You need:

- the Telegram app on your phone, signed in;
- a Terminal window of your own: a separate window, **not** Claude and **not** a `!` command
  inside Claude (the helper handles secrets and refuses to run there);
- about 5 minutes for part 1, and about 15 minutes for part 4 (which needs part 1 first).

Step 0: in your Terminal window, go to your himmel folder. This guide assumes it is `~/himmel`:

```bash
cd ~/himmel
```

If you cloned himmel somewhere else, type `cd` and a space, drag that folder from your file
manager into the Terminal window, and press Enter. Every command on this page runs from that
folder, and every command works unchanged in bash, zsh and fish.

Step 1, once per machine: install himmel, if you have not done so here yet. The helpers read
your station through the installed himmel, so without the install every part shows `could not
read this part's status`. The install asks nothing. More in [install.md](install.md).

```bash
node scripts/himmelctl/bin.js install --scope user
```

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
| `must hold exactly one Telegram id` | The file `~/.claude/channels/telegram/access.json` is not in the expected shape. Fix it or move it away, then run the command again. |
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

Prefer one page with copy buttons? [The bot-to-bot guide](../guide/remote-setup-bot-to-bot.html) walks this part step by step.

### What it is

Two himmel stations talk to each other through one Telegram group. The two stations can be yours
and another person's, or **two machines of your own**. Each station has its own **bridge bot**, and
the two bridge bots share the group. Nothing here needs the two machines to reach each other:
everything goes through Telegram, so it works over the internet with no shared network, no SSH
and no shared folder.

Do part 1 first. Then keep the two kinds of bot apart:

| Bot | What it does | In the group? |
|---|---|---|
| Your **main bot** (part 1) | Private: only you talk to it. | **Never.** It must not join the group. |
| Your **bridge bot** (this part) | Talks to the other station's bridge bot. | Yes, as an administrator with every right switched off. |

Only the two bridge bots talk across the group. No person's Telegram id is put on the list of who
may talk to your station.

Who talks to whom:

- **You talk only to your own main bot**, in your private chat with it.
- **The two bridge bots talk to each other in the group.**
- **People who post in the group are ignored**, you and the other person too. Nobody gets a reply
  there, and typing a message in the group does not send it to the other station.

### In the Telegram app: the bridge bots (each side)

1. Open a chat with **@BotFather**, send `/newbot`, and give the bot a name and a username that
   ends in `bot`. This is a **new** bot, not your main bot. If both stations are yours, make two
   bridge bots, one per machine.
2. Send `/mybots`, pick the new bot, open **Bot Settings** and turn **Bot-to-Bot mode** on. Leave
   **Group Privacy** on (it is on by default).
3. Keep BotFather's token line for the Terminal step, and send the other station's operator the
   username of your bridge bot.

### In the Telegram app: the group (the group owner, once)

Do these in this order. The order matters:

1. Press **New Group**. Add **only your own bridge bot**, or, if another person runs the other
   station, only that person. Name the group anything.
2. Open the group, press its name, then **Edit** → **Group type** → **Public** → set any link →
   **Save**. Then **Edit** → **Group type** → **Private** → **Save**. This turns it into a
   supergroup.
3. **Edit** → **Permissions** → turn off **Change group info** and **Pin messages**.
4. Press **Add Members** and add the other station's bridge bot **by its username**. If another
   person runs it and you did not add your own bridge bot at step 1, add that one too. Invite
   links do not work for bots.
5. **Edit** → **Administrators** → pick each bridge bot (press **Add Admin** first if it is not
   listed) → switch **every** right off → **Save**.
6. Send the word `hello` in the group yourself.
7. Never post "as the group" (the switch that makes an administrator anonymous). The bridge
   ignores those messages.

### In your Terminal

```bash
bash scripts/remote-setup/remote-setup.sh peer
```

On the first run it asks for your bridge bot's token: paste it and press Enter (nothing shows on
screen while you paste). After that, every run just asks you to press Enter at that prompt. You
type no bot id, no username and no chat id: the helper finds them.

What it does, in order:

1. It checks the token and that this bot is not one of your other bots, and saves the token.
2. It finds your group. If it asks you to send the word `hello` in the group, do that.
3. It posts one short line, `himmel peer hello`, in the group, then waits up to 10 minutes for the
   other station's bridge bot to do the same. This is how it learns the other bot. When only one
   bot says hello, it shows that bot's `@username` and asks one question: type `1` if that is the
   other station's bridge bot (check the name with the other operator), `2` if it is not. Nothing is
   paired unless you type `1`.
4. It checks the group (a supergroup, members cannot change info or pin, both bridge bots are
   administrators with every right off), then adds and confirms the peer and starts a small
   program, the poller, that keeps the connection going.

**One person, two machines:** start the command on the first machine. While it shows "Waiting for
the other station's hello", run the same command on the second machine. If the first machine gave
up while you were setting up the second, just run the command on the first machine once more:
nothing breaks.

**The other station finished before you:** your run still ends in `DONE:`. Ask the other operator to
run the same command once. It changes no setting on their side, and it makes their station post its
hello for you to find.

On a Mac: the poller is a LaunchAgent (`com.himmel.peer-bridge`) in `~/Library/LaunchAgents`. A Mac
that sleeps stops the poller, and Telegram keeps the messages for you for only 24 hours. In
System Settings → Battery (or Energy), turn on "Prevent automatic sleeping when the display is
off".

### You should see

```text
DONE: peer example — group confirmed, poller running
```

The name after `peer` is the other station's name, taken from its bridge bot's username (here
`example_bot`). Running the command again is safe: it changes no setting, and posts the hello once.

### If you see FIX

| The line says | What to do |
|---|---|
| `do part 1 first` | Finish part 1, then run the command again. |
| `this bot is already your ... bot` | Each role needs its own bot. Make a new one with @BotFather (`/newbot`) for the bridge bot. |
| `a different bridge bot is already set up` | If you do want to switch your bridge bot, run the command with `--replace` (below). |
| `no hello arrived from the group` | Run the command again, wait until it asks you to send the word `hello` in the group ("Waiting up to 10 minutes..."), then send `hello`. A `hello` sent before the command started is not seen. |
| `no hello came from the other station` | Ask the other operator to run the same command once, then run it here again. |
| `so nothing was paired` | You said the bot that said hello is not the other station's bridge bot, or gave no answer. Ask the other operator for the name of their bridge bot, make sure only that bot is in the group, then run the command again and type `1` only if the name matches. |
| `too many queued messages` | Wait a minute, ask the other operator to run the same command once more, then run it here again. |
| `and bridge bots need a supergroup` | Edit → Group type → Public → set any link → Save, then Private → Save (group step 2). |
| `group members are allowed to use` | Edit → Permissions → turn off Change group info and Pin messages (group step 3). |
| `is not in the group` | Press Add Members and add the bot by its username. Invite links do not work for bots. |
| `is not an administrator of the group` | Edit → Administrators → Add Admin → pick the bot, switch every right off, Save. |
| `has the admin right` | Edit → Administrators → the bot → switch that right off → Save. If the line names a raw field such as `can_manage_tags`, switch off the toggle with the matching name. |
| `is not set up as a plain administrator` | The bot is posting anonymously or is not a normal administrator. Open Edit → Administrators → the bot, switch every right and "Remain anonymous" off, and Save. |
| `your main bot is in the group` | Remove your main bot from the group. Only the bridge bots belong in it. |
| `another program is already reading this bot's messages` | Something else is using this bridge bot's token. Stop it (or the old poller), then run the command again. |
| `this bot has a webhook set` | The bot is set to push its messages to a web address, and Telegram then refuses to hand them out by polling. Remove the webhook (Telegram's `deleteWebhook` method), or use another bot, then run the command again. |
| `not a usable Telegram username` | Ask the other operator to check their bridge bot's username, then run the command again. |
| `setup.ts did not` | The line carries setup.ts's reason, usually one of the group rules above. Fix that, then run the command again. |
| `the peer poller did not start` | The line names a command that shows the poller's log. Read it, fix what it says, then run the command again; your setup is kept. |
| `the old poller could not be stopped` | On a Mac, the running poller would not stop, so the updated one was not applied and nothing was changed. Run the stop command the line gives, then run the command again. |
| `unit file could not be deleted` | Delete the file the line names, then run the command with `--remove` again. |
| `the peer poller did not restart` | Read the poller's log (the line names the command), fix what it says, then run the command with `--remove` again: it finishes that restart and does not offer another peer. The peer you removed stays removed. |
| `the peer poller could not be stopped` | Run the stop command the line gives, then run the command with `--remove` again. The peer itself is already removed. |
| `the peer bridge is not running yet` | Wait a minute, read the poller's log (the line names the command), then run the command again. |

If a person other than the group owner runs a station, the group lines tell them to ask the group
owner to make the change.

To switch to a different bridge bot on purpose, or to find the other station again after it changed
its bridge bot:

```bash
bash scripts/remote-setup/remote-setup.sh peer --replace
```

### Optional: enable chief-to-chief jobs

This is not part of the `DONE:` above, and the check does not need it. Your chiefs can exchange
signed job requests once each station has a name and a key, and each operator has trusted the
other's key. Trusting a key needs you to read its fingerprint to the other operator by voice or
another messenger, and to type it back: that cannot be automated, so there is no helper for it. The
steps are the `station-name`, `keygen` and `trust` verbs of `bun scripts/peer-bridge/setup.ts`, run
by you in your own Terminal; to take a key away or change it use `untrust`, and `keygen --rotate`.
The exact steps are in [the peer bridge reference](../internals/peer-bridge.md).

### Undo

To remove a peer, stop its poller and delete the poller's unit when it was the last one:

```bash
bash scripts/remote-setup/remote-setup.sh peer --remove
```

`setup.ts` asks you to type `yes` before it removes the peer. If the command is interrupted half way,
run it again: it finishes the job. To delete the bridge bot itself, send `/deletebot` to @BotFather;
to leave the group, remove the bot there.

## Check everything

To see every part and what to do next:

```bash
bash scripts/remote-setup/remote-setup.sh status
```

```text
DONE: status — all shipped parts ok
```

If a part is not ready, the last line is a `FIX:` that names the part and its command. This
command only reads, so it is safe to run at any time and it changes nothing. Like every command
on this page it runs from your himmel folder (step 0).
