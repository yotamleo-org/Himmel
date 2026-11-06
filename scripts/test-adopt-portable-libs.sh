#!/usr/bin/env bash
# test-adopt-portable-libs.sh -- every library a portable hook sources is itself
# in adopt.sh's PORTABLE_FILES.
#
# A project-scope install copies PORTABLE_FILES into the target and nothing
# else. A hook that sources a lib outside that list fails closed in the
# installed tree (block-read-secrets: "cannot load .../lib/guard-unwrap.sh").
# The AUR container test (packaging/aur/test-pkgbuild.sh) only sees this inside
# a container; this check reads the hooks and the list, so it runs anywhere.
#
# Libs are found as `../lib/X.sh` / `../guardrails/X.sh` (relative to the hook)
# and `lib/X.sh` under the hook's own dir (the `${BASH_SOURCE[0]%/*}/lib/X.sh`
# shape), in non-comment lines. OPTIONAL libs are sourced inside an `if`/`||`
# that tolerates absence, so they need not ship.
#
# Env: ADOPT_SH overrides the adopt.sh read (the RED control points it at a copy
# with the lib removed).

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work and saved_path
set -uo pipefail

# The fixture assigns `adopt`, so it is sourced first and ADOPT_SH wins after it.
# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"

repo_root=$(git rev-parse --show-toplevel) || { echo "FAIL: not in a git repo" >&2; exit 1; }
adopt="${ADOPT_SH:-$repo_root/scripts/adopt.sh}"
OPTIONAL=''

fail=0
portable=$(awk '/^PORTABLE_FILES=\(/{f=1;next} f&&/^\)/{exit} f{print $1}' "$adopt")
[ -n "$portable" ] || { echo "FAIL: no PORTABLE_FILES parsed from $adopt" >&2; exit 1; }

checked=0
while IFS= read -r hook; do
  case "$hook" in scripts/hooks/*.sh) ;; *) continue ;; esac  # lib/*.sh too: a lib sourcing a sibling needs it shipped
  src="$repo_root/$hook"
  [ -f "$src" ] || { echo "FAIL: $hook is listed but missing" >&2; fail=1; continue; }
  code=$(grep -vE '^[[:space:]]*#' "$src")
  libs=$({ printf '%s\n' "$code" | grep -oE '\.\./(lib|guardrails)/[A-Za-z0-9_.-]+\.sh' | sed 's|^\.\./|scripts/|' || true
           printf '%s\n' "$code" | grep -oE '[%*}]/lib/[A-Za-z0-9_.-]+\.sh' | sed 's|^.*/lib/|scripts/hooks/lib/|' || true
           printf '%s\n' "$code" | grep -oE '_dir/[A-Za-z0-9_.-]+\.sh' | sed 's|^_dir/|scripts/hooks/lib/|' || true
         } | sort -u)
  for lib in $libs; do
    checked=$((checked + 1))
    case " $OPTIONAL " in *" $lib "*) continue ;; esac
    grep -qxF "$lib" <<< "$portable" \
      || { echo "FAIL: $hook sources $lib, which PORTABLE_FILES does not copy" >&2; fail=1; }
  done
done <<< "$portable"

[ "$checked" -gt 0 ] || { echo "FAIL: vacuous, no sourced lib found in any portable hook" >&2; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "ok: all $checked sourced libs of the portable hooks are in PORTABLE_FILES"

# /handover-resume and the storage setup run these from a project install.
for f in scripts/handover/resume.sh scripts/handover/resume-context.sh scripts/handover/bug.sh \
         scripts/handover/set-handover-dir.sh scripts/handover/register-state.sh \
         scripts/lib/env-append.sh .claude/commands/handover-resume.md; do
  grep -qxF "$f" <<< "$portable" || { echo "FAIL: $f is needed by /handover-resume and storage setup, which PORTABLE_FILES does not copy" >&2; fail=1; }
done
[ "$fail" -ne 0 ] || echo "ok: the seven handover files are in PORTABLE_FILES"

# The copied scripts need node (resume.sh:57, register-state.sh:71), which the fixture's PATH scrubs.
proj="$work/handover-proj"; hstate="$work/handover-state"; hhome="$work/handover-home"
mkdir -p "$proj" "$hstate/tester/proj" "$hhome"
git init -q "$proj"
install_proj() { HOME="$hhome" bash "$repo_root/scripts/adopt.sh" --profile core --scope project --target "$proj" >/dev/null 2>&1; }
install_proj || { echo "FAIL: adopt.sh --profile core --scope project failed on the handover fixture" >&2; exit 1; }
item="$hstate/tester/proj/standalones/PROJ-1-demo"; mkdir -p "$item"
printf '# Demo\n\n**Status:** in-progress\n' > "$item/brief.md"
bash "$repo_root/scripts/handover/bug.sh" add --bugs "$item/bugs.md" --symptom "portable resume must show this open bug" >/dev/null
printf '{"repos":{"proj":{"path":"%s","user":"tester","jira_project":"PROJ"}}}\n' "$proj" > "$hhome/registry.json"
resume_in_proj() { (cd "$proj" && PATH="$saved_path" HOME="$hhome" HANDOVER_DIR="$hstate" HANDOVER_REGISTRY="$hhome/registry.json" bash scripts/handover/resume.sh PROJ-1 2>&1); }

# portable_resume_runs_seeded: the copied resume.sh prints the cold start and the open bug.
if [ ! -f "$proj/scripts/handover/resume.sh" ]; then
  echo "FAIL: portable_resume_runs_seeded: scripts/handover/resume.sh was not copied into the project" >&2; fail=1
else
  out=$(resume_in_proj); rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q 'portable resume must show this open bug' <<< "$out"; then
    echo "FAIL: portable_resume_runs_seeded: rc=$rc, the open bug did not print: $out" >&2; fail=1
  else
    echo "ok: portable_resume_runs_seeded"
  fi
fi

# portable_rerun_restores: a re-run puts back a removed copy.
rm -f "$proj/scripts/handover/resume.sh"
install_proj
if [ -f "$proj/scripts/handover/resume.sh" ]; then echo "ok: portable_rerun_restores"
else echo "FAIL: portable_rerun_restores: a re-run did not restore scripts/handover/resume.sh" >&2; fail=1; fi
[ "$fail" -eq 0 ] || exit 1
