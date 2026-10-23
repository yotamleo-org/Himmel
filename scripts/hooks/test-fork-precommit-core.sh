#!/usr/bin/env bash
# Drives real `git commit`s through the portable fork pre-commit
# core (templates/fork-precommit/) installed the way a fork adopts it:
# `pre-commit install -c .himmel/pre-commit-config.yaml`.
#
# Arms: a fake secret is refused, a commit with no ticket ID is refused, a
# commit on the default branch is refused, a normal ticketed commit passes, a
# 64-hex digest (a sha256) and a bare 40-hex pin are not mistaken for a secret,
# a secret merely containing a 40-hex run is still refused (allowlist anchors),
# and only git-generated Merge/Revert subjects skip the ticket check.
#
# Skips (exit 0, loud) where pre-commit is absent; read the `== Summary ==`
# block, not the rc. gitleaks needs no PATH binary: pre-commit builds it
# (language: golang), so a missing toolchain fails the install arm instead.
#
# Platform guard (gitbash-only): POSIX bash fixture, no .ps1 twin (project
# convention).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="${FORK_PRECOMMIT_TEMPLATE:-$REPO_ROOT/templates/fork-precommit}"

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "SKIP: pre-commit not installed - nothing was tested"
  echo "== Summary =="
  echo "0 passed, 0 failed, SKIPPED"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
FORK="$WORK/fork"
mkdir -p "$FORK/.himmel"
git -C "$FORK" init -q -b main
git -C "$FORK" config user.email t@example.invalid
git -C "$FORK" config user.name t
git -C "$FORK" config commit.gpgsign false

cp "$TEMPLATE/pre-commit-config.yaml" "$FORK/.himmel/pre-commit-config.yaml" 2>/dev/null
cp "$TEMPLATE/gitleaks.toml" "$FORK/.himmel/gitleaks.toml" 2>/dev/null
echo "upstream code" > "$FORK/app.txt"
git -C "$FORK" add -A

if ! (cd "$FORK" && pre-commit install -c .himmel/pre-commit-config.yaml -t pre-commit -t commit-msg >"$WORK/install" 2>&1); then
  bad "pre-commit install -c .himmel/pre-commit-config.yaml succeeds"
  sed 's/^/  | /' "$WORK/install"
  echo "== Summary =="
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
ok "pre-commit install -c .himmel/pre-commit-config.yaml succeeds"

N=0
commit() { # commit <msg> -> rc; stages a fresh file so "nothing to commit" can never pass for a refusal
  N=$((N + 1))
  echo "change $N" > "$FORK/change-$N.txt"
  git -C "$FORK" add "change-$N.txt"
  if [ -n "${2:-}" ]; then
    (cd "$FORK" && git commit -q -m "$1" -m "$2" >"$WORK/out" 2>&1)
  else
    (cd "$FORK" && git commit -q -m "$1" >"$WORK/out" 2>&1)
  fi
}

# 1. default branch refused (the first commit also carries .himmel itself)
if commit "chore(hooks): [HIMMEL-5978] add core"; then
  bad "commit on main is refused"
else
  ok "commit on main is refused"
fi

git -C "$FORK" checkout -q -b himmel/test

# 2. no ticket ID refused
if commit "chore(hooks): add core"; then
  bad "commit without a ticket ID is refused"
else
  ok "commit without a ticket ID is refused"
fi

# 3. non-conventional refused
if commit "[HIMMEL-5978] add core"; then
  bad "non-conventional subject is refused"
else
  ok "non-conventional subject is refused"
fi

# 3b. a ticketed line in the BODY must not satisfy the check for the subject
if commit "update things" "chore(hooks): [HIMMEL-5978] add core"; then
  bad "ticketed body line does not excuse an unticketed subject"
else
  ok "ticketed body line does not excuse an unticketed subject"
fi

# 4. normal ticketed commit passes
if commit "chore(hooks): [HIMMEL-5978] add core"; then
  ok "ticketed conventional commit on a branch passes"
else
  bad "ticketed conventional commit on a branch passes"; sed 's/^/  | /' "$WORK/out"
fi

# 5. fake secret refused (assembled at runtime; fixtures carry the marker)
printf 'token = ghp_%s\n' "aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5" > "$FORK/leak.txt" # gitleaks:allow
git -C "$FORK" add leak.txt
if commit "fix(app): [HIMMEL-5978] add leaky file"; then
  bad "commit carrying a fake secret is refused"
else
  ok "commit carrying a fake secret is refused"
fi
git -C "$FORK" reset -q HEAD leak.txt
rm -f "$FORK/leak.txt"

# 6. a sha256 digest is not a secret
printf 'sha256: %s\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$FORK/pin.txt"
git -C "$FORK" add pin.txt
if commit "chore(app): [HIMMEL-5978] pin digest"; then
  ok "64-hex digest passes the anchored allowlist"
else
  bad "64-hex digest passes the anchored allowlist"; sed 's/^/  | /' "$WORK/out"
fi

# 7. a bare 40-hex pin (a git sha) passes; the same run inside a longer secret
# is still refused (the allowlist is anchored ^...$ on the matched secret)
PIN="a3f9c1d27b6e84f05d1c9a7e2b4f8063d5e1a9c7"
printf 'api_key = "%s"\n' "$PIN" > "$FORK/pin40.txt"
git -C "$FORK" add pin40.txt
if commit "chore(app): [HIMMEL-5978] pin sha"; then
  ok "bare 40-hex pin passes the anchored allowlist"
else
  bad "bare 40-hex pin passes the anchored allowlist"; sed 's/^/  | /' "$WORK/out"
fi

printf 'api_key = "%szq9Xw"\n' "$PIN" > "$FORK/embedded.txt"
git -C "$FORK" add embedded.txt
if commit "fix(app): [HIMMEL-5978] add embedded secret"; then
  bad "secret containing a 40-hex run is refused"
else
  ok "secret containing a 40-hex run is refused"
fi
git -C "$FORK" reset -q HEAD embedded.txt
rm -f "$FORK/embedded.txt"

# 8. only the subjects git itself generates skip the ticket check
for subj in \
  "Merge branch 'feature/x' into main" \
  "Merge pull request #12 from org/feature-x" \
  "Merge remote-tracking branch 'origin/main'" \
  "Merge branch 'main' of https://example.invalid/r" \
  'Revert "feat(app): [HIMMEL-5978] add thing"'; do
  if commit "$subj"; then
    ok "git-generated subject passes: $subj"
  else
    bad "git-generated subject passes: $subj"; sed 's/^/  | /' "$WORK/out"
  fi
done
for subj in "Merge unrelated change" "Merge branches by hand" "Revert the thing" "Merge pull request without a number" \
  "Merge pull request #garbage" "Merge branch '" "Merge remote-tracking branch ''" 'Revert "' \
  "Merge branch 'x'garbage" "Merge branch 'x' garbage" \
  "Merge remote-tracking branch 'o/x'garbage" "Merge remote-tracking branch 'o/x' garbage" \
  'Revert "x"garbage'; do
  if commit "$subj"; then
    bad "lookalike subject is refused: $subj"
  else
    ok "lookalike subject is refused: $subj"
  fi
done
# the closing quote must be on the subject line, not in the body
if commit "Merge branch 'x" "y' z"; then
  bad "unclosed subject quote closed only in the body is refused"
else
  ok "unclosed subject quote closed only in the body is refused"
fi
if commit "Merge pull request #12 from "; then
  bad "pull request subject without a source is refused"
else
  ok "pull request subject without a source is refused"
fi

echo "== Summary =="
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
