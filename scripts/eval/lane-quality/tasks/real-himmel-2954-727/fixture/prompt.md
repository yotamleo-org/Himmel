# leak-classes: refine home-path ERE-metachar/ellipsis heuristics (dotted usernames, truncated real leaks)

Context
HIMMEL-2828's check_home_path() regression fix (PR #664, commit 0cbd3f6) excludes core ERE metacharacters ( [ . * + ? { } | ^ $ from the home-path username capture, and skips a captured name immediately followed by a doc-style ellipsis (... / …). Both changes were required to stop 6 regex-definition source files from self-flagging as leaks (verified: all 6 are actually stopped by the [/|/( exclusions, not by .).
The /pr-check critic panel round on that commit raised two genuine, narrower follow-on gaps in the same mechanism that are out of scope for the #664 regression fix itself:
Finding 1 (codex-1, panel round 2 on #664)
Excluding . from the name-capture class means a real dotted username (e.g. /home/<user>/Documents, a common corporate first.last shape) only captures user up to the dot. If that leading segment happens to be allowlisted, the full dotted identity is never flagged, and the rest of the line (smith/Documents) isn't rescanned because it no longer follows a /home/<user> prefix.
Needs a fix that stops swallowing real dotted usernames while still refusing to walk into a wildcard-style . right after a /home///Users/ prefix (e.g. /home/.*/) — a blanket un-exclude of . would likely reintroduce that class of false-positive on regex-definition lines using . as a wildcard.
Finding 2 (codex-2, panel round 2 on #664)
The ellipsis-skip suppresses ANY match immediately followed by .../…, not just Windows 8.3 short-name placeholders (e.g. RUNNER~1\...). A genuine leaked path that happens to be followed by a literal ... (e.g. truncated tool output) would be silently suppressed.
Consider narrowing the skip to only fire when the captured name itself looks like an 8.3 short name (e.g. matches ~[0-9] near the end) rather than any name at all.
Scope note
Both are refinements to the heuristic added in commit 0cbd3f6, not defects in the #664 regression fix's own correctness (verified clean via the RED/GREEN suite and a full --tree self-scan). Filed separately per CR-gate convention rather than expanding that follow-up commit further.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/guardrails/test-leak-classes.sh`

The checks it must pass include:

- `scripts/guardrails/test-leak-classes.sh`: T1x home-path: dotted username (user.smith) captured whole and flagged
- `scripts/guardrails/test-leak-classes.sh`: T1x2 home-path: /home/user.*/ wildcard-dot regex literal stays clean
- `scripts/guardrails/test-leak-classes.sh`: T1x3 home-path: /home/user./x stops at the trailing dot (captures 'user' only, allowlisted)
- `scripts/guardrails/test-leak-classes.sh`: T1y home-path: genuine leak truncated by ... is still flagged (not an 8.3 short name)
- `scripts/guardrails/test-leak-classes.sh`: T1y2 home-path: allowlisted-name doc-elision (/home/example/...) stays clean

Run the tests you touch before you finish. Report what you changed and what you checked.
