# Evaluate the Claude Code sandbox (bwrap) for legs as defence in depth: hide ~/.config/himmel, verdicts/ read-only, unsandboxed fallback off (VM)

(no description)

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/eval/sandbox-poc/test-probe.sh`

The checks it must pass include:

- `scripts/eval/sandbox-poc/test-probe.sh`: setup: token fixture
- `scripts/eval/sandbox-poc/test-probe.sh`: setup: verdicts fixture
- `scripts/eval/sandbox-poc/test-probe.sh`: red control: rc nonzero
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R1 blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R2 blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R3 script-file blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R4 option-write blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R5 outside blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: R6 anchor script blocked
- `scripts/eval/sandbox-poc/test-probe.sh`: bwrap: C1 git still works

Run the tests you touch before you finish. Report what you changed and what you checked.
