#!/usr/bin/env bash
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

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
