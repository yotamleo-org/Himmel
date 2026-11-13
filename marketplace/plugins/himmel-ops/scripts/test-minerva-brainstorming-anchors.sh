#!/usr/bin/env bash
# shellcheck disable=SC2016  # the backticks in the needles below are literal characters, not command substitutions
# test-minerva-brainstorming-anchors.sh — minerva Stage 1b drives
# the vendored lean-skills brainstorming skill and halts it at named steps. Each
# step minerva relies on is written in its SKILL.md as
#   brainstorming step "<text>"
# and every such <text> must still exist in the vendored brainstorming/SKILL.md.
# A superpowers re-vendor that drops or renames a step (v7 dropped "Spec
# Self-Review" for a builder check) turns this RED until minerva is updated, so
# the critic loop never anchors on a checkpoint that no longer happens.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
skill="$here/../skills/minerva/SKILL.md"
brain="$here/../../lean-skills/skills/brainstorming/SKILL.md"
[ -f "$skill" ] || { echo "FATAL: $skill not found"; exit 2; }
[ -f "$brain" ] || { echo "FATAL: $brain not found"; exit 2; }
fails=0

# Stage 1b only: from its heading up to the next H2.
stage="$(awk '/^### 1b\./{f=1} f&&/^## /{exit} f{print}' "$skill")"
[ -n "$stage" ] || { echo "FAIL - minerva SKILL.md has no '### 1b.' section"; exit 1; }

anchors="$(printf '%s\n' "$stage" | tr '\n' ' ' | grep -o 'brainstorming step "[^"]*"' | sed 's/^brainstorming step "//; s/"$//')"
if [ -z "$anchors" ]; then
  echo "FAIL - Stage 1b names no brainstorming step \"<text>\" anchor"; fails=$((fails+1))
fi
while IFS= read -r a; do
  [ -n "$a" ] || continue
  # A step is defined, not merely mentioned: a heading, a bold lead-in or a
  # table row's first cell. A prose mention of a removed step does not count.
  if awk -v a="$a" '
    /^#+ / { h=$0; sub(/^#+ /,"",h); if (h==a) f=1 }
    index($0,"**" a "**")==1 || index($0,"**" a ":**")==1 || index($0,"| " a " |")==1 { f=1 }
    END { exit !f }' "$brain"; then echo "ok - brainstorming step \"$a\" exists"
  else echo "FAIL - brainstorming step \"$a\" is not in the vendored brainstorming/SKILL.md"; fails=$((fails+1)); fi
done <<EOF
$anchors
EOF

# Stage 1a asks an eighth grill question after the seven sizing questions: the
# class of each follow-up. A re-word that drops it turns this RED.
grill="$(awk '/^### 1a\./{f=1} f&&/^### 1b\./{exit} f{print}' "$skill" | tr '\n' ' ')"
case "$grill" in
  *"Is each follow-up an escape, hardening or polish, and why?"*) echo "ok - Stage 1a asks the follow-up class question" ;;
  *) echo "FAIL - Stage 1a has no 'Is each follow-up an escape, hardening or polish, and why?' question"; fails=$((fails+1)) ;;
esac

# Stage 3 halts writing-plans at a named step, the same way Stage 1b halts
# brainstorming; the step must still be a heading in the vendored writing-plans.
plans="$here/../../lean-skills/skills/writing-plans/SKILL.md"
stage3="$(awk '/^## Stage 3/{f=1;next} f&&/^## /{exit} f{print}' "$skill" | tr '\n' ' ')"
case "$stage3" in
  *'HALT it before its writing-plans step "Execution Handoff"'*)
    if grep -qx '## Execution Handoff' "$plans"; then echo "ok - Stage 3 halts writing-plans before \"Execution Handoff\""
    else echo "FAIL - writing-plans step \"Execution Handoff\" is not a heading in the vendored writing-plans/SKILL.md"; fails=$((fails+1)); fi ;;
  *) echo "FAIL - Stage 3 does not HALT writing-plans before its \"Execution Handoff\""; fails=$((fails+1)) ;;
esac

# The text minerva adds on top of superpowers 7.x. A re-word that
# drops one turns this RED.
flat="$(tr '\n' ' ' <"$skill")"
stage2="$(awk '/^## Stage 2/{f=1;next} f&&/^## /{exit} f{print}' "$skill" | tr '\n' ' ')"
stage4="$(awk '/^## Stage 4/{f=1;next} f&&/^## /{exit} f{print}' "$skill" | tr '\n' ' ')"
want(){ # <label> <haystack> <needle>
  case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: no '$3'"; fails=$((fails+1)) ;; esac
}
want "spec goes to the state repo" "$flat" 'state repo `specs/<type>/`'
want "plan goes to the state repo" "$flat" '`specs/plans/`'
want "autonomous rulings use the Ruling format" "$flat" '`<decision> — <why> — <cost if wrong>`'
want "Stage 2 critic names its model" "$stage2" '`model: opus` at high effort'
want "Stage 4 critic names its model" "$stage4" '`model: sonnet` at high effort'

want "Stage 1a invokes the vendored grilling skill" "$grill" 'Invoke `lean-skills:grilling` (unless it is already running)'
want "Stage 1a puts the himmel rules first" "$grill" 'himmel rules below taking precedence'
want "Stage 1a continues past a shared understanding" "$grill" 'When the stop condition below and its confirmation are met, go on to 1b; never end at a shared understanding.'
case "$grill" in
  *'❓'*|*'➡'*|*[Ww][Hh][Oo][Ll][Ee]' '[Ff][Rr][Oo][Nn][Tt][Ii][Ee][Rr]*) echo "FAIL - Stage 1a restates the grilling round format"; fails=$((fails+1)) ;;
  *) echo "ok - Stage 1a leaves the round format to grilling" ;;
esac
want "Stage 1a asks why in round 1" "$grill" '**Round 1 asks why.**'
want "Stage 1a feeds effort-assess" "$grill" 'Save its JSON next to the spec.'
want "Stage 1a looks facts up inline" "$grill" 'it up inline when a handful of tool calls settles it'
want "Stage 1a has a stop condition" "$grill" '**Stop condition:** the frontier is empty'
want "Stage 1a self-answers in autonomous mode" "$grill" 'explicit ASSUMPTIONS section'
want "the front door finishes a grilling run as Stage 1a" "$flat" 'finish its rounds as Stage 1a'
want "Stage 1a waits for the operator's confirmation" "$grill" 'Do not advance to 1b until the operator confirms you have reached a shared understanding.'
want "Stage 1a has the eight standing questions" "$grill" '**The eight standing questions.**'
want "standing question 1" "$grill" '**Smallest shippable slice and its size**'
want "standing question 2" "$grill" '**What pushes it to the high end**'
want "standing question 3" "$grill" '**Does it touch guards, hooks or permissions**'
want "standing question 4" "$grill" '**Can a RED be written now, or is it plan-first?**'
want "standing question 5" "$grill" '**Is any unknown wide enough to span two steps?**'
want "standing question 6" "$grill" '**Which open PRs or single-writer groups does it collide with?**'
want "standing question 7" "$grill" '**Which version does it land in, and does that version still pass P90 <= 0.8?**'
want "autonomous mode auto-advances past the confirmation" "$flat" 'do NOT pause; the critics are the gate'
lic="$here/../../../../docs/third-party-licenses.md"
[ -f "$lic" ] || { echo "FATAL: $lic not found"; exit 2; }
if grep -F '99743e9c151c8537cbbf1f98bb38f34ef3368453/pstack/skills/arena' "$lic" | grep -qF '| Lauren Tan | MIT | inspired by | marketplace/plugins/himmel-ops/skills/minerva/SKILL.md |'; then echo "ok - the arena credit row names minerva"
else echo "FAIL - docs/third-party-licenses.md has no arena passage row for minerva SKILL.md"; fails=$((fails+1)); fi

gflat="$(tr '\n' ' ' <"$here/../../lean-skills/skills/grilling/SKILL.md")"
want "grilling maps a design tree" "$gflat" 'Map this as a **design tree**'
want "grilling defines the frontier" "$gflat" 'The **frontier** is every decision whose prerequisites are already settled'
want "grilling asks the whole frontier with a recommended answer" "$gflat" 'Ask the whole frontier in one round: number each question and give your recommended answer.'
want "grilling waits between rounds" "$gflat" "Then wait for the user's answers before the next round."
want "grilling has the question format" "$gflat" '❓ **Q1**'
want "grilling has the answer format" "$gflat" '➡️ <your recommended answer>'
want "grilling recomputes the frontier" "$gflat" 'Recompute the frontier and ask the next round.'
want "grilling defers a dependent question" "$gflat" 'belongs to a _later_ round'
want "grilling never asks for a fact it can look up" "$gflat" "don't ask the user for anything you could look up yourself"
want "grilling does not block on a lookup" "$gflat" 'ask the rest of the frontier now'
want "grilling leaves the decisions to the user" "$gflat" 'put each to them and wait'

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
