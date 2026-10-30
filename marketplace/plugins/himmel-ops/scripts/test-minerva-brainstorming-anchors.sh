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

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
