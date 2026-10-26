# srt-poc — a claudex worker under sandbox-runtime (HIMMEL-5287)

VM-only proof of concept. Nothing here is wired into a launcher, hook, setting or
CI workflow. It answers one question: can a claudex worker run under Anthropic's
sandbox-runtime (`srt`) so that a destructive command outside the worktree fails
physically, a push only works through a himmel wrapper, and a blocked domain
produces a clear request line.

## Verdict: PROCEED, with changes

Adopt `srt` for claudex workers first (weak-classifier lane, where a physical limit
matters most). The mechanism works on the guest; the changes below are what the
build tickets carry.

| Change | Why | Ticket |
|---|---|---|
| Launcher wraps the worker in `srt claude` with rendered profile settings and asserts the settings loaded | srt starts on built-in defaults when no settings file exists (row F4) | HIMMEL-5397 |
| AppArmor `userns` profile for `/usr/bin/bwrap` on Ubuntu 24.04+; pin srt, bump VM-first | bwrap fails (`loopback: Failed RTM_NEWADDR`) until the profile is loaded | HIMMEL-5397 |
| Research profile is a curated domain list | srt rejects `*` and `*.com` as overly broad | HIMMEL-5397 |
| Push wrapper plus broker is the only push path; credential never in the box | a force push to an origin inside a writable root passes (row B5) | HIMMEL-5398 |
| Broker answers into a launcher-owned spool, not the worker-writable one | symlink checks on `<id>.out`/`.rc` do not stop a worker swapping the `req` directory between check and write (known POC limit) | HIMMEL-5398 |
| Chief-approved domain requests, default deny, logged | blocked domain returns a 403 and the box cannot widen itself (rows B12-B14) | HIMMEL-5399 |
| Real-model step (open POC item, below) | not run, needs an operator decision | HIMMEL-5400 |

## Open POC item: the real-model claudex step

Not run. The guest holds no codex credential and the chief did not authorise
host gateway reach from the guest, so every row below uses `srt` directly or
`srt claude` with a stub `claude`. What the step needs:

1. Host CLIProxyAPI reachable from the guest over VirtualBox NAT, at the NAT
   default gateway address (the host loopback gateway must listen where NAT reaches it, or be forwarded).
2. A throwaway CLIPROXY key, scoped, revoked after the run.
3. Egress note: the guest then holds a key that can spend the codex bank; never
   snapshot the VM with it (secret scan before snapshot).
4. Then run the claudex launcher under `srt claude` and add the rows this POC
   did not cover: a Write-tool write outside the roots, an MCP server touching
   `~/.ssh` (the HIMMEL-5269 gap), hooks inside the box, and worker plumbing
   (SendMessage, queue lock, `~/.himmel`, loopback gateway).

## Setup on the guest (Ubuntu 24.04)

```bash
sudo apt-get update && sudo apt-get install -y bubblewrap socat ripgrep
# AppArmor: allow bwrap to create user namespaces
printf 'abi <abi/4.0>,\ninclude <tunables/global>\nprofile bwrap /usr/bin/bwrap flags=(unconfined) {\n  userns,\n}\n' | sudo tee /etc/apparmor.d/bwrap-userns
sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns
npm install --prefix ~/srt @anthropic-ai/sandbox-runtime@0.0.79
```

Recorded against srt 0.0.79, bubblewrap 0.9.0, node 24.20.0, claude 2.1.263,
Ubuntu 24.04 guest `himmel-ar-3` (restored from `suite-ready-v4`).

## Files

| File | Role |
|---|---|
| `render-settings.sh` | renders the srt settings for the `impl` or `research` profile (writable roots: worktree, scratchpad, handover bucket; `denyRead` for `~/.ssh`, `~/.config/gh`, `~/.git-credentials`, `~/.netrc`) |
| `worker-battery.sh` | the rows B0-B15, run inside the sandbox |
| `launcher-broker.sh` | runs outside the sandbox: serves push and domain requests from a spool directory, default deny, widens the network list live through `--control-fd`, logs every decision |
| `push-wrapper.sh` | the only push path: refuses force flags, `+refspec`, delete, `main`/`master`, other branches, URL remotes, mirror (rc 20); the worker branch is set by the launcher |
| `run-poc.sh` | `impl`, `research` or `failure-modes` run on the guest |
| `test-push-wrapper.sh` | offline test of the wrapper's refusals (RED shown before the wrapper existed) |
| `test-recorded-run.sh` | asserts the recorded transcripts still say what the verdict claims |
| `recorded/` | the real VM transcripts |

Run on a guest after copying this directory to `~/srt-poc`:
`bash ~/srt-poc/run-poc.sh impl`, `... research`, `... failure-modes`.
Offline: `bash scripts/lanes/srt-poc/test-push-wrapper.sh`,
`bash scripts/lanes/srt-poc/test-recorded-run.sh`.

## Recorded results

Transcripts: `recorded/vm-run-impl.txt`, `vm-run-research.txt`,
`vm-run-failure-modes.txt` (the guest user's home directory is written
`<guest-home>`, the only edit made to them). All rows PASS in both profiles; origin `main` did
not move in either run.

| Row | Claim | Observed |
|---|---|---|
| B2 | `rm -rf` outside the roots | `Read-only file system`, victim intact |
| B3 | write outside the roots | `Read-only file system` |
| B4 | direct force push to an origin outside the roots | rc=1, `failed to push some refs` |
| B5 | force push to an origin **inside** a root | rc=0: the sandbox bounds where, not what |
| B6 | wrapper pushes the worker's own branch | rc=0 |
| B7 / B8 / B8b | wrapper refuses `--force`, `main`, `+refspec` | rc=20 each |
| B10 | allowed host | `registry.npmjs.org` 200 |
| B11 | bypass the proxy | no route, name does not resolve |
| B12 (impl) | domain outside the profile | `CONNECT tunnel failed, response 403` |
| B13 (impl) | request the domain, broker approves, retry | 200 |
| B14 (impl) | request left unanswered | stays denied, retry code 000 |
| B12 / B12b (research) | curated list reachable, not unlimited | `example.com` 200, `example.org` code 000 |
| F1-F3 | zero-byte settings, missing settings, missing bwrap | srt refuses (`is empty`, `does not exist`, `Sandbox dependencies not available`) |
| F4 | no settings file at all | srt RUNS on defaults: the launcher must assert |

## What this POC does not prove

- **No model.** Every row uses a stub `claude` or `srt` directly. Whether a real
  claudex worker's own plumbing works inside the box is the open item above.
- **B9 is weak.** The credential file was absent at read time, so it shows a
  denied read of a missing path, not a `denyRead` hit. Treat `denyRead` as
  specified by srt, not as proven here.
- **Credentials over the network.** The sandbox does not stop a credential that
  is present in the box from pushing over a permitted domain; only the wrapper
  with the credential kept outside does (row B5 is the file-system version).
- **Destruction inside a writable root** (the worktree) is not covered by srt.
- **Unix sockets** are all or nothing on Linux, and network filtering is by
  domain only (no path or method), per the srt spec.
- **Not run:** the Write tool and MCP servers inside the box, hooks inside the
  box, and the worker plumbing.
- Domain widening changes network lists only; filesystem rules cannot change in
  a running worker.
