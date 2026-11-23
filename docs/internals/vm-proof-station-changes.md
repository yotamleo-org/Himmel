# Station changes that need a VM proof

A test VM is scarce, so a proof runs on one only when the change would alter a
station. Every other proof runs in CI, or as a read-only run on the station.
This page lists the station-change classes that need a VM. The open tickets in
each class are listed in the chief's proof audit in the state bucket, not here.
The VM itself is set up as described in [vms.md](../setup/vms.md) and
[vm-mode.md](../setup/vm-mode.md).

## The classes

| Class | What it changes on a station |
|---|---|
| install | adds or rewires files, hooks, plugins or tools: `setup.sh`, adopt, a plugin or tool install |
| update | moves a pinned tool or the harness to a new version: `himmel-update.sh`, a dependency bump, a channel switch |
| arming | starts a long-lived unit or session: a service, a daemon, a waiter, a desk |
| migration | moves existing station state into a new shape: config off `.env`, scopes from user to project |
| settings | rewrites a settings, hook, token, allowlist or guard-config file |

A change to the VM tooling itself also needs a VM, though it changes no station.

## How to rule a new proof

Read the ticket's DoD and Proof, not its Impact.

- **VM**: the proof makes an install, update, arming, migration or settings
  change. Name the class on the ticket. If a throwaway sandbox or a temporary
  HOME would hold the change just as well, use that and rule the proof CI.
- **Live spend**: the proof needs a model or paid API call that fleet work
  would not make anyway. Name what it draws (subscription, paid API, or another
  provider's plan) and give a cost range with its basis.
- **CI**: everything else. That includes a read-only run on the station, a free
  Telegram or test-project run, and a proof that observes a session or PR the
  fleet produces anyway.
- **UNRULED**: the text is too thin to rule. Write down the one question that
  would settle it; never guess.

What counts as a live proof row is defined in [live-proof-test.md](live-proof-test.md).
