# HIMMEL-6478-N2806-dispatcher-false-collisions-2026-10-19.md

> **Scope / do not:** writes confined to writes confined to scripts/handover/console-kit/next-dispatchable.sh, scripts/handover/console-kit/console-wait.sh, scripts/handover/console-kit/test-next-dispatchable.sh, the console-wait test suite and new fixtures under scripts/handover/console-kit/fixtures/. Impacted suites: every suite referencing next-dispatchable.sh or console-wait.sh (grep), verdict per suite in READY. completes-ticket: yes. Other live legs and their files: . Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 17:46 LIVE — worktree fix/himmel-6478-dispatcher-false-collisions, head 96101f
