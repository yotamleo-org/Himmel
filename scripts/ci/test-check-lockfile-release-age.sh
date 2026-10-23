#!/usr/bin/env bash
# Test for scripts/ci/check-lockfile-release-age.mjs.
#
# Runs against two lockfiles copied from the live tree (an npm package-lock.json
# and a bun.lock with a scoped package) and a --times file, so no registry is
# touched. The times file is built from the lint's own UNKNOWN output: every
# entry of the real lockfiles gets a publish time, then one is planted too new.
#
# Usage: bash scripts/ci/test-check-lockfile-release-age.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/check-lockfile-release-age.mjs"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
NPM_LOCK="$REPO_ROOT/scripts/himmel-run/package-lock.json"
BUN_LOCK="$REPO_ROOT/scripts/luna-vitals/bun.lock"
NOW="2026-10-23T00:00:00Z"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h7173a.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

run() { # <label> <want-rc> <lint args...>
  local label="$1" want="$2"; shift 2
  node "$LINT" --now "$NOW" "$@" >"$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label -> exit $want"; else fail "$label -> expected $want got $rc"; sed -n '1,6p' "$tmp/out"; fi
}
says() { # <label> <fixed string the last run must have printed>
  if grep -qF -- "$2" "$tmp/out"; then pass "$1"; else fail "$1 (missing: $2)"; sed -n '1,6p' "$tmp/out"; fi
}

echo '{}' > "$tmp/empty.json"
printf '# no entries\n' > "$tmp/noallow.txt"

echo "== no publish times (the lookup failed) =="
run "an entry without a publish time is UNKNOWN" 2 --times "$tmp/empty.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"
says "npm entry is named" "UNKNOWN: scripts/himmel-run/package-lock.json: "
says "scoped bun entry is named" "@types/bun@"

# Every entry of both lockfiles, published long ago.
ids=$(sed -n 's/^UNKNOWN: [^:]*: \(.*\) has no publish time$/\1/p' "$tmp/out" | sort -u)
[ -n "$ids" ] || { fail "no entries parsed from the real lockfiles"; exit 1; }
printf '%s\n' "$ids" | awk 'BEGIN { printf "{" } { printf "%s\"%s\":\"2020-01-01T00:00:00Z\"", (NR > 1 ? "," : ""), $0 } END { print "}" }' > "$tmp/old.json"

echo "== every entry old enough =="
run "all-old lockfiles pass" 0 --times "$tmp/old.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"
says "summary counts no young entry" "0 young"

echo "== a planted too-new entry =="
victim=$(printf '%s\n' "$ids" | grep '^@types/bun@' | head -1)
mk() { sed "s|\"$victim\":\"[^\"]*\"|\"$victim\":\"$1\"|" "$tmp/old.json" > "$tmp/planted.json"; }
mk "2026-10-22T00:00:00Z"
run "a 1-day-old release is refused" 1 --times "$tmp/planted.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"
says "the young entry is named with its age" "YOUNG: scripts/luna-vitals/bun.lock: $victim published 2026-10-22T00:00:00Z (1.0 days old"

mk "2026-10-20T00:00:00Z"
run "a release exactly 3 days old passes" 0 --times "$tmp/planted.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"

mk "2026-10-20T00:00:01Z"
run "a release 1 second short of 3 days is refused" 1 --times "$tmp/planted.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"

mk "2026-10-22T00:00:00Z"
run "--days 1 accepts a 1-day-old release" 0 --days 1 --times "$tmp/planted.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"

echo "== allowlist =="
printf '# GHSA-test security fix\n%s  GHSA-test\n' "$victim" > "$tmp/allow.txt"
mk "2026-10-22T00:00:00Z"
run "an allowlisted security fix passes" 0 --times "$tmp/planted.json" --allow "$tmp/allow.txt" "$NPM_LOCK" "$BUN_LOCK"
says "summary counts it as allowlisted" "1 allowlisted"

printf '%s\n' "other-pkg@9.9.9  some other fix" > "$tmp/allow-other.txt"
run "an allowlist for another entry does not help" 1 --times "$tmp/planted.json" --allow "$tmp/allow-other.txt" "$NPM_LOCK" "$BUN_LOCK"

echo "== young plus unknown =="
sed 's|,"@types/node@[^"]*":"[^"]*"||; s|"@types/node@[^"]*":"[^"]*",||' "$tmp/planted.json" > "$tmp/partial.json"
run "a young entry wins over an unknown one" 1 --times "$tmp/partial.json" --allow "$tmp/noallow.txt" "$NPM_LOCK" "$BUN_LOCK"
says "the unknown entry is still reported" "UNKNOWN:"

echo "== default discovery =="
run "tracked lockfiles are found under --root" 2 --times "$tmp/empty.json" --allow "$tmp/noallow.txt" --root "$REPO_ROOT"
says "a real lockfile is scanned" "scripts/jira/package-lock.json"
if grep -q 'lanes/bench/fixtures' "$tmp/out"; then fail "benchmark fixture lockfiles must be skipped"; else pass "benchmark fixture lockfiles are skipped"; fi

echo "== --base: only what this change adds =="
repo="$tmp/repo"
mkdir -p "$repo/pkg"
cp "$NPM_LOCK" "$repo/pkg/package-lock.json"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
if ! { g init -q -b main && g add -A && g commit -q -m base; }; then fail "could not build the base repo"; exit 1; fi
base=$(g rev-parse HEAD)
oldid=$(printf '%s\n' "$ids" | grep -v '^@types/' | head -1)

run "no change since the base has nothing to check" 0 --root "$repo" --base "$base" --times "$tmp/empty.json" --allow "$tmp/noallow.txt"
says "no entry is examined" "0 unique entries in 1 lockfile(s)"

# One new registry entry, added the way npm writes it.
node -e '
  const fs = require("fs"); const f = process.argv[1];
  const lock = JSON.parse(fs.readFileSync(f, "utf8"));
  lock.packages["node_modules/freshpkg"] = { version: "9.9.9", resolved: "https://registry.npmjs.org/freshpkg/-/freshpkg-9.9.9.tgz", integrity: "sha512-x" };
  fs.writeFileSync(f, JSON.stringify(lock, null, 2) + "\n");
' "$repo/pkg/package-lock.json"

printf '{"freshpkg@9.9.9":"2026-10-22T12:00:00Z"}\n' > "$tmp/fresh.json"
run "a new entry published 12 hours ago is refused" 1 --root "$repo" --base "$base" --times "$tmp/fresh.json" --allow "$tmp/noallow.txt"
says "the new entry is named" "YOUNG: pkg/package-lock.json: freshpkg@9.9.9 published 2026-10-22T12:00:00Z (0.5 days old"
says "only the new entry is examined" "1 unique entry in 1 lockfile(s)"

printf '{"freshpkg@9.9.9":"2026-10-01T00:00:00Z"}\n' > "$tmp/aged.json"
run "a new entry that is 22 days old passes" 0 --root "$repo" --base "$base" --times "$tmp/aged.json" --allow "$tmp/noallow.txt"

printf 'freshpkg@9.9.9  GHSA-test\n' > "$tmp/allow-fresh.txt"
run "a new allowlisted security fix passes" 0 --root "$repo" --base "$base" --times "$tmp/fresh.json" --allow "$tmp/allow-fresh.txt"

# An entry already on the base is not this change's to answer for, however young.
printf '{"freshpkg@9.9.9":"2026-10-01T00:00:00Z","%s":"2026-10-22T12:00:00Z"}\n' "$oldid" > "$tmp/base-young.json"
run "an entry already on the base is not checked" 0 --root "$repo" --base "$base" --times "$tmp/base-young.json" --allow "$tmp/noallow.txt"

# An npm alias is looked up under the package it installs, not its install name.
node -e '
  const fs = require("fs"); const f = process.argv[1];
  const lock = JSON.parse(fs.readFileSync(f, "utf8"));
  lock.packages["node_modules/compat"] = { name: "actualpkg", version: "1.2.3", resolved: "https://registry.npmjs.org/actualpkg/-/actualpkg-1.2.3.tgz", integrity: "sha512-x" };
  fs.writeFileSync(f, JSON.stringify(lock, null, 2) + "\n");
' "$repo/pkg/package-lock.json"
printf '{"freshpkg@9.9.9":"2026-10-01T00:00:00Z","actualpkg@1.2.3":"2026-10-22T12:00:00Z"}\n' > "$tmp/alias.json"
run "an aliased entry is checked under its real package name" 1 --root "$repo" --base "$base" --times "$tmp/alias.json" --allow "$tmp/noallow.txt"
says "the real name is reported" "actualpkg@1.2.3 published 2026-10-22T12:00:00Z"

# A lockfile the base does not have: every entry is new.
mkdir -p "$repo/other" && cp "$BUN_LOCK" "$repo/other/bun.lock"
run "a lockfile new since the base is checked whole" 2 --root "$repo" --base "$base" --times "$tmp/aged.json" --allow "$tmp/noallow.txt" "$repo/other/bun.lock"
says "its entries are examined" "UNKNOWN: other/bun.lock: "

echo "== lockfile shapes =="
# A registry entry without `resolved` (omit-lockfile-registry-resolved) is still checked.
nores="$tmp/nores"; mkdir -p "$nores"
printf '{"lockfileVersion":3,"packages":{"":{},"node_modules/noresolved":{"version":"2.0.0"},"node_modules/gitdep":{"version":"1.0.0","resolved":"git+ssh://git@github.com/x/y.git#abc"},"node_modules/bundled":{"version":"3.0.0","inBundle":true}}}\n' > "$nores/package-lock.json"
printf '{"noresolved@2.0.0":"2026-10-22T12:00:00Z"}\n' > "$tmp/nores-times.json"
run "an entry without resolved is checked" 1 --times "$tmp/nores-times.json" --allow "$tmp/noallow.txt" "$nores/package-lock.json"
says "only the registry entry is examined" "1 unique entry in 1 lockfile(s)"

# A version-1 lockfile (entries under `dependencies`) is refused, not read as empty.
v1="$tmp/v1"; mkdir -p "$v1"
printf '{"lockfileVersion":1,"dependencies":{"foo":{"version":"1.0.0"}}}\n' > "$v1/package-lock.json"
run "a version-1 lockfile is a usage error" 2 --times "$tmp/empty.json" --allow "$tmp/noallow.txt" "$v1/package-lock.json"
says "the version is named" "lockfileVersion 1 has no \"packages\" map"

bunempty="$tmp/bunempty"; mkdir -p "$bunempty"
printf '{"lockfileVersion":1,"workspaces":{}}\n' > "$bunempty/bun.lock"
run "a bun.lock without packages is a usage error" 2 --times "$tmp/empty.json" --allow "$tmp/noallow.txt" "$bunempty/bun.lock"
says "bun.lock is named" 'bun.lock has no "packages" map'

echo "== usage errors =="
run "a bad --days is a usage error" 2 --days 0 --times "$tmp/empty.json" "$NPM_LOCK"

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures FAILED"
exit 1
