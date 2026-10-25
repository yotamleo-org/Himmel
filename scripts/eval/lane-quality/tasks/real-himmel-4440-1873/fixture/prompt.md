# himmelctl: pre-commit item should be wanted for a core target with its own .pre-commit-config.yaml

Follow-up to HIMMEL-4435. itemMembership (scripts/himmelctl/lib/state.js) wants the pre-commit dep item only with a luna vault or the contributor overlay. A core target that ships its own .pre-commit-config.yaml with vault=none also needs the framework (adopt.sh already keeps the uv/pipx check for that case), but himmelctl status/ensure now reports the item n/a for it. Fix needs the target dir in membership (or a probe-time check for the config file); itemMembership has no target context today.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/himmelctl/test/test-wizard-state.sh`

Run the tests you touch before you finish. Report what you changed and what you checked.
