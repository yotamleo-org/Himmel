# CLIProxyAPI codex lane (`cc-codex`) — per-host bring-up checksheet

The `cc-codex` lane runs Claude Code against the codex subscription through a
local **CLIProxyAPI** Anthropic-compatible proxy (`scripts/claude-codex`,
[tooling-catalog](../tooling-catalog.md)). This sheet stands the proxy up on a
host.

## Where it runs (read this first)

The proxy is a **HOST** process on `127.0.0.1:8317`. **One instance per host**
serves *all three* clients on that machine:

- the host bash launcher (`scripts/claude-codex`),
- that host's **WSL** (`cc-codex`) — which reaches it over `127.0.0.1` via
  mirrored networking.

So: install/run it **on each host, never inside WSL, never per-launcher**. On an
N-host fleet you run N proxies, not N×(hosts+WSLs).

> `cc-codex` needs the proxy. `cc-glm` does **not** — it goes direct to z.ai and
> only needs `ZAI_API_KEY` in `.env`.

## The script

`scripts/setup/cli-proxy-lane.sh` (bash, run on the host) installs the pinned
release, writes a loopback-bound `config.yaml` and guards every bounce. Run it
with no flag for a status report that names the next command:

```shell
bash scripts/setup/cli-proxy-lane.sh
```

| Flag | Does |
|---|---|
| `--install` | download the pinned CLIProxyAPI binary + write `~/.cli-proxy-api/config.yaml` (loopback-bound) if missing |
| `--login` | one-time codex OAuth via **device-code** flow (no local browser needed — works over SSH) |
| `--start` | start the proxy in the **foreground** (Ctrl-C to stop) — for debugging |
| `--register` | register a `systemctl --user` unit (`cli-proxy-api.service`, `Restart=on-failure`) + `loginctl enable-linger`, **and start it now** — so the proxy is up immediately and restarts at each boot/login |
| `--stop` / `--restart` | bounce-safe: refuses while a client is actively connected on port 8317 (`ss` ESTABLISHED check) unless `--force` |
| `--verify` / `--status` | one-line / multi-line reachability + readiness report |

**What to run — per host** (assumes `CLIPROXY_API_KEY` is set in `.env`):

```shell
bash scripts/setup/cli-proxy-lane.sh --install
bash scripts/setup/cli-proxy-lane.sh --login      # device-code OAuth, one time
bash scripts/setup/cli-proxy-lane.sh --register   # starts it now + persists across reboots
bash scripts/setup/cli-proxy-lane.sh --verify
```

A fresh host runs the four commands in order; `--roll` replaces the manual
stop/install/restart sequence on a host that already has a proxy.

## Verify the lane end-to-end

```shell
# host:
bash scripts/claude-codex -p "reply OK"
# WSL (reaches the host proxy via mirrored 127.0.0.1):
cc-codex -p "reply OK"
```

## Re-login when the codex token is invalidated

When the gateway's codex token goes stale, the lane fails with the proxy
error log showing `authentication_error: Your authentication token has been
invalidated. Please try signing in again`. This is a self-service re-login,
not a blocking outage — re-auth with the DEVICE flow (`-codex-login` plain
OAuth needs a localhost callback; the device flow does not):

```shell
cd ~/.cli-proxy-api && ./cli-proxy-api -config ./config.yaml -codex-device-login
```

After ~2–4 seconds it prints
`Codex device URL: https://auth.openai.com/codex/device` plus a 9-character
device code, then polls until authorized — leave it running in the
FOREGROUND of a dedicated terminal until authorization completes, and do
NOT kill it early (the URL + code only print after that short delay).
Authorize from a logged-in browser or a second terminal. Treat the device
URL + code as sensitive authorization material: surface them to the
operator directly and nowhere else — never into shared logs, chat
channels, screenshots, or CI output (anyone holding the active code can
authorize the login). On authorize the process writes
`~/.cli-proxy-api/codex-<email>.json` ("Codex authentication
successful") and exits 0; re-verify the lane end-to-end (section above).

Detection caveat: the gateway's `/v1/models` endpoint is registry-backed and
keeps returning 200 during an OAuth gap — probe a real completion
(`/v1/messages`) to detect an auth gap, never `/v1/models`.

## Transient 5xx: bounded retry and a second credential (HIMMEL-5391)

An upstream codex `502` ends a claudex worker session's turn, and the `503
auth_unavailable` that follows is the proxy cooling down the only codex
credential. `--install` (and `--roll`) write two keys to
`config.yaml`, and only when they are missing, so an operator-set value is
kept and a re-run changes nothing:

| Key | Written | Meaning (CLIProxyAPI `config.example.yaml`, v7.3.15) |
|---|---|---|
| `request-retry` | `3` | extra credential retry rounds on 403/408/429/500/502/503/504 |
| `max-retry-interval` | `30` | longest wait, in seconds, for a cooldown between rounds |

An existing install picks them up by re-running `--install`, then
`--restart` (the proxy reads `config.yaml` at start).

**A second codex credential** (optional) gives the cooldown another credential
to fall back to. CLIProxyAPI loads every `codex-*.json` in `auth-dir`, so add
one by logging a second account in with the same device flow
(`--login`, authorizing as the second account); it lands as its own
`codex-<email>.json`. Logging the same account in again replaces its file, it
does not add one. Two accounts mean two subscriptions' usage on one proxy.

## Notes

- `config.yaml` pins `host: "127.0.0.1"` on purpose — the CLIProxyAPI default
  (empty host) binds **all interfaces**, LAN-exposing the OAuth-wrapped
  subscription endpoint. Always start via the script / `-config`.
- `CLIPROXY_API_KEY` in `.env` must match the `api-keys` entry
  (`himmel-local-claudex`).
- This re-exposes a subscription via OAuth; the ToS posture is operator-accepted.
- The lane script is Linux-only; macOS has no lane script yet.
