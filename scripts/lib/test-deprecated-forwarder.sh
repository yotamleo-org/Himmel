#!/usr/bin/env bash
# scripts/lib/test-deprecated-forwarder.sh -- rows for the template
# scripts/lib/deprecated-forwarder.sh. The template is instantiated into a temp
# dir (__OLD__ and __NEW__ filled in, as a rename slice does) in front of a
# target that records its argv byte-for-byte and exits with a chosen status.
# Proves: argv, exit code, stdout and stdin pass through unchanged; stderr
# carries exactly one deprecation line naming both spellings.
#
# DEPRECATED_FORWARDER_TEMPLATE points the rows at another copy of the
# template, so a mutant (an argv-dropping forwarder) can be shown to turn a row red.
#
# Platform guard (gitbash-only): pure bash, no .ps1 twin needed.
# shellcheck disable=SC2016  # '$HOME' and backticks are literal argv on purpose
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${DEPRECATED_FORWARDER_TEMPLATE:-$HERE/deprecated-forwarder.sh}"
# shellcheck source=fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/fixture-tempdir.sh"
T=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$T"' EXIT

FAIL=0
PASS=0
check() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label -- want '$want' got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$T/sub"
sed -e 's|__OLD__|old-name.sh|g' -e 's|__NEW__|sub/new-name.sh|g' "$TEMPLATE" > "$T/old-name.sh"
cat > "$T/sub/new-name.sh" <<'TARGET'
#!/usr/bin/env bash
# records argv NUL-separated, copies stdin to stdout, exits FWD_RC
for a in "$@"; do printf '%s\0' "$a"; done > "$FWD_ARGV"
cat
exit "${FWD_RC:-0}"
TARGET

run() {  # run <rc> <args...>: prints nothing; fills ARGV_GOT, RC_GOT, OUT_GOT
  local rc="$1"; shift
  : > "$T/argv"
  FWD_RC="$rc" FWD_ARGV="$T/argv" bash "$T/old-name.sh" "$@" < "$T/stdin" > "$T/out" 2> "$T/err"
  RC_GOT=$?
  ARGV_GOT=$(od -An -c "$T/argv")
  OUT_GOT=$(cat "$T/out")
}
expect_argv() {  # expect_argv <args...>: the od -c of the NUL-joined args
  : > "$T/want"
  local a
  for a in "$@"; do printf '%s\0' "$a" >> "$T/want"; done
  od -An -c "$T/want"
}

printf 'piped input\n' > "$T/stdin"

run 0 plain two
check "argv plain" "$(expect_argv plain two)" "$ARGV_GOT"
check "rc 0 passes through" "0" "$RC_GOT"
check "stdin reaches the target and stdout comes back" "piped input" "$OUT_GOT"

run 0
check "no argv: the target sees none" "$(expect_argv)" "$ARGV_GOT"

run 0 "" "a b" "--" "-x" "*" 'q"uote' "it's" $'two\nlines' '$HOME' '`id`'
check "awkward argv is byte-identical" \
  "$(expect_argv "" "a b" "--" "-x" "*" 'q"uote' "it's" $'two\nlines' '$HOME' '`id`')" "$ARGV_GOT"

for rc in 1 2 3 75 127 255; do
  run "$rc" x
  check "exit code $rc passes through" "$rc" "$RC_GOT"
done

run 0 a
check "stderr is exactly one line" "1" "$(wc -l < "$T/err" | tr -d ' ')"
check "stderr says deprecated" "yes" "$(grep -q 'deprecated' "$T/err" && echo yes || echo no)"
check "stderr names the old spelling" "yes" "$(grep -q 'old-name.sh' "$T/err" && echo yes || echo no)"
check "stderr names the new spelling" "yes" "$(grep -q 'sub/new-name.sh' "$T/err" && echo yes || echo no)"
check "stdout carries no deprecation text" "piped input" "$OUT_GOT"

# the forwarder resolves the target next to ITSELF, whatever the caller's cwd is
mkdir -p "$T/elsewhere"
RC_GOT=$(cd "$T/elsewhere" && FWD_RC=4 FWD_ARGV="$T/argv" bash "$T/old-name.sh" y < "$T/stdin" > /dev/null 2>&1; echo $?)
check "runs from another cwd" "4" "$RC_GOT"

# sourced, it refuses before the exec, so the caller's shell survives
OUT_GOT=$(FWD_ARGV="$T/argv" bash -c '. "$1"; echo "rc=$?"' _ "$T/old-name.sh" 2> "$T/err")
check "sourcing refuses and runs nothing" "rc=2" "$OUT_GOT"
check "sourcing names the run spelling" "old-name.sh is deprecated: run 'sub/new-name.sh', do not source it" "$(cat "$T/err")"
# shellcheck disable=SC2016 # $0 is expanded by the inner bash, not here
OUT_GOT=$(FWD_ARGV="$T/argv" bash -c '. "$0"; echo "rc=$?"' "$T/old-name.sh" 2> "$T/err")
check "sourcing with the forwarder as \$0 refuses too" "rc=2" "$OUT_GOT"

check "template carries the __OLD__ placeholder" "yes" "$(grep -q '__OLD__' "$TEMPLATE" && echo yes || echo no)"
check "template carries the __NEW__ placeholder" "yes" "$(grep -q '__NEW__' "$TEMPLATE" && echo yes || echo no)"

if [ "$FAIL" -ne 0 ]; then
  echo "test-deprecated-forwarder: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-deprecated-forwarder: $PASS passed"
