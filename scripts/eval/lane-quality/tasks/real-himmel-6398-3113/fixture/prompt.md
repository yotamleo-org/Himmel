# gen-briefs writes claudex launchers with the native sonnet model and no effort; a hand-fixed launcher is classifier-refused

Impact
A console cannot dispatch a claudex leg through gen-briefs as generated. The launcher passes --lane claudex with model claude-sonnet-5-5 and no effort, so the leg runs the wrong model at the default effort. Hand-editing the launcher breaks its recorded sha256, and the auto-mode classifier then refuses the launch (Logging/Audit Tampering). Hit on 2026-10-18 for N2673 (HIMMEL-6373).
What
gen-briefs honours the leg's lane for model and effort:
- with no model key on a non-native lane, it passes no model, so headed-arm-leg.sh's lane default (lanes.json) applies;
- an optional effort key exports LEG_EFFORT in the launcher;
- the brief header names the real model and lane.
Why
Operator 2026-10-18, verbatim: "this should've been already supported feature". HIMMEL-6063 added --lane to the generated launcher but left the model default and the brief header native-only. Decision (17) also asks for claudex legs at LEG_EFFORT high.
Plan
1. scripts/handover/console-kit/gen-briefs.py: on a non-native lane with no model key, omit the model argument; accept effort (low|medium|high|xhigh) and write export LEG_EFFORT=<v> in the launcher; refuse an opus or fable model on a non-native lane.
2. The brief header and the You are line use the lane's resolved model name (read the lanes.json default the same way headed-arm-leg.sh does) and the lane.
3. RED rows in scripts/handover/console-kit/test-gen-briefs.sh: a claudex leg with no model gets a launcher with no claude-sonnet argument and a header naming the lane model; effort: high gets the export.
DoD
- A generated claudex launcher, launched unmodified, starts on the lane-default model at the requested effort (live proof: re-dispatch N2673 HIMMEL-6373 from it).
Agent detail
- Files: scripts/handover/console-kit/gen-briefs.py, scripts/handover/console-kit/test-gen-briefs.sh, plus the gen-briefs docstring.
- Related: HIMMEL-6063 (Done), HIMMEL-5089.
- headed-arm-leg.sh is read-only reference: the lane-default model block is near line 1518, and the LEG_EFFORT claudex export is near line 104.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/handover/console-kit/test-gen-briefs.sh`

The checks it must pass include:

- `scripts/handover/console-kit/test-gen-briefs.sh`: a claudex leg with no model key passes no native model argument
- `scripts/handover/console-kit/test-gen-briefs.sh`: a claudex leg with no model key leaves the lane default to headed-arm-leg
- `scripts/handover/console-kit/test-gen-briefs.sh`: its brief header names the lane model and the lane
- `scripts/handover/console-kit/test-gen-briefs.sh`: an effort key exports LEG_EFFORT in the launcher

Run the tests you touch before you finish. Report what you changed and what you checked.
