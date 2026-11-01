feat: [HIMMEL-6415] managed clones get the CR pre-push gate without hand-wiring

install-cr-gate.sh already installed the pre-push CR gate idempotently. A managed clone still had to hand-wire the implementer-family record that turns on review gate 3c. `--impl-family <family>` installs the gate and records the target's current branch as implemented by <family>, through set-impl-family.sh, so its own validation applies. A re-run is a no-op on the hook and on the record. The option is install-only: it exits 2 with `--status` or `--remove`, with no value and with an empty value.
