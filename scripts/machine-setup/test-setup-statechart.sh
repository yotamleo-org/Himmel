#!/usr/bin/env bash
# test-setup-statechart.sh — hermetic suite for setup-statechart.sh.
#
# Every case gets its own fake HOME and XDG_DATA_HOME under mktemp, and a PATH
# holding only stubs (curl, sha256sum, uname, and java where the case wants
# one) plus symlinks to the few coreutils the script uses. The real HOME, the
# real network and any real Java are never reached. The sha256sum stub reports
# the pinned digest for the GOOD fixture bytes, since no real TLC jar is
# fetched here; the real download is verified by hand and by the pin test.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/setup-statechart.sh"
# shellcheck source=installer-pins.sh
. "$SCRIPT_DIR/installer-pins.sh"

BASH_BIN="$(command -v bash)"
REAL_SHA256SUM="$(command -v sha256sum)"
REAL_UNAME="$(command -v uname)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "missing: $needle" ;;
  esac
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$label" "unexpected: $needle" ;;
    *) pass "$label" ;;
  esac
}

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass "$label (rc=$got)"; else fail "$label" "expected rc=$want, got rc=$got"; fi
}

assert_nonzero() {
  local label="$1" got="$2"
  if [ "$got" -ne 0 ]; then pass "$label (rc=$got)"; else fail "$label" "expected non-zero rc, got 0"; fi
}

assert_same_file() {
  local label="$1" want="$2" got="$3"
  if [ -f "$got" ] && cmp -s "$want" "$got"; then pass "$label"; else fail "$label" "$got is not byte-identical to $want"; fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-statechart-test.XXXXXX")" || exit 1
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

# Fixtures: the GOOD bytes are the ones the stub sha256sum pins to the real digest.
FIX="$TMP_ROOT/fixtures"; mkdir -p "$FIX"
GOOD_JAR="$FIX/good.jar"; BAD_JAR="$FIX/bad.jar"; OLD_JAR="$FIX/old.jar"
printf 'pinned-tlc-fixture\n' > "$GOOD_JAR"
printf 'tampered-tlc-fixture\n' > "$BAD_JAR"
printf 'previous-tlc-fixture\n' > "$OLD_JAR"
export GOOD_JAR BAD_JAR REAL_SHA256SUM REAL_UNAME
PIN="$TLA2TOOLS_SHA256"
export PIN

# Shared coreutils the script may call. Java, curl, sha256sum, uname are not here:
# each case adds its own stubs (or omits java entirely).
TOOLS="$TMP_ROOT/tools"; mkdir -p "$TOOLS"
for t in cat chmod cmp cp cut dirname grep head ls mkdir mktemp mv rm sed; do
  p="$(command -v "$t")" && ln -s "$p" "$TOOLS/$t"
done
ln -s "$BASH_BIN" "$TOOLS/bash"

write_stubs() { # <bin dir>
  cat > "$1/curl" <<'EOF'
#!/bin/sh
# Records every call; fails the test when a no-network case reaches it.
printf '%s\n' "$*" >> "$STUB_LOG/curl-args"
: > "$STUB_LOG/curl-called"
case "${CURL_MODE:-fail}" in
  ok) src="$GOOD_JAR" ;;
  bad) src="$BAD_JAR" ;;
  never) exit 99 ;;
  *) exit 22 ;;
esac
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
cp "$src" "$out"
EOF
  cat > "$1/sha256sum" <<'EOF'
#!/bin/sh
# The GOOD fixture reports the pinned TLC digest; any other file gets the real hash.
if [ -n "${1:-}" ] && [ -f "$1" ] && cmp -s "$1" "$GOOD_JAR"; then
  printf '%s  %s\n' "$PIN" "$1"
  exit 0
fi
exec "$REAL_SHA256SUM" "$@"
EOF
  cat > "$1/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-s" ]; then echo "${STUB_UNAME:-Linux}"; exit 0; fi
exec "$REAL_UNAME" "$@"
EOF
  chmod +x "$1/curl" "$1/sha256sum" "$1/uname"
}

write_java() { # <bin dir>
  cat > "$1/java" <<'EOF'
#!/bin/sh
printf 'openjdk version "%s" 2026-08-18\n' "${STUB_JAVA_VERSION:-21.0.12}" >&2
EOF
  chmod +x "$1/java"
}

# new_case <name> <java:yes|no> — a fresh fake HOME, XDG tree, bin dir and log.
new_case() {
  CASE="$TMP_ROOT/$1"
  C_HOME="$CASE/home"; C_XDG="$CASE/xdg"; C_BIN="$CASE/bin"; C_LOG="$CASE/log"
  mkdir -p "$C_HOME" "$C_BIN" "$C_LOG"
  write_stubs "$C_BIN"
  if [ "$2" = yes ]; then write_java "$C_BIN"; fi
}

# invoke <mode> <curl-mode> [uname] [java-version] — runs the SUT with the case's
# fake HOME; JAVA and XDG_DATA_HOME are cleared unless the case sets XDG.
# Sets OUT (combined output) and RC.
invoke() {
  local mode="$1" curl_mode="$2" uname_s="${3:-Linux}" java_ver="${4:-21.0.12}"
  OUT="$(
    unset JAVA XDG_DATA_HOME
    if [ -n "${C_XDG_SET:-}" ]; then export XDG_DATA_HOME="$C_XDG"; fi
    export HOME="$C_HOME" PATH="$C_BIN:$TOOLS" CURL_MODE="$curl_mode"
    export STUB_LOG="$C_LOG" STUB_UNAME="$uname_s" STUB_JAVA_VERSION="$java_ver"
    "$BASH_BIN" "$SUT" "$mode" 2>&1
  )"
  RC=$?
}

JAR_OF() { printf '%s/himmel/statechart/%s/tla2tools.jar' "$1" "$TLA2TOOLS_VERSION"; }
ENV_OF() { printf '%s/himmel/statechart/env' "$1"; }

# only_jar_in <dir> — true when the dir holds the jar and no other entry, dotfiles
# included, so a leftover temp download fails the check.
only_jar_in() {
  local f n=0
  for f in "$1"/.[!.]* "$1"/*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in tla2tools.jar) ;; *) return 1 ;; esac
    n=$((n + 1))
  done
  [ "$n" -eq 1 ]
}

echo "setup-statechart: valid setup (XDG unset, default ~/.local/share)"
new_case valid yes
C_XDG_SET="" invoke --install ok
JAR_V="$(JAR_OF "$C_HOME/.local/share")"
assert_rc "--install succeeds on a valid host" 0 "$RC"
assert_contains "--install reports ready" "statechart: ready" "$OUT"
assert_same_file "the pinned jar lands under HOME/.local/share/himmel/statechart/1.7.4" "$GOOD_JAR" "$JAR_V"
assert_contains "the download is an https GitHub release URL" "https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar" "$(cat "$C_LOG/curl-args")"
assert_contains "curl is pinned to https for the request and every redirect" "--proto-redir =https" "$(cat "$C_LOG/curl-args")"
ENV_V="$(ENV_OF "$C_HOME/.local/share")"
assert_contains "env names the verified absolute JAVA" "JAVA='$C_BIN/java'" "$(cat "$ENV_V")"
assert_contains "env names the verified absolute TLA2TOOLS" "TLA2TOOLS='$JAR_V'" "$(cat "$ENV_V")"
if only_jar_in "$(dirname "$JAR_V")"; then
  pass "no temp file left beside the installed jar"
else
  fail "no temp file left beside the installed jar" "$(dirname "$JAR_V") holds more than the jar"
fi

echo "setup-statechart: --check after a valid install"
rm -f "$C_LOG/curl-called"
C_XDG_SET="" invoke --check never
assert_rc "--check passes after a valid install" 0 "$RC"
assert_contains "--check reports the java path and version" "java: $C_BIN/java (version 21.0.12)" "$OUT"
assert_contains "--check reports the jar sha256" "sha256 $PIN" "$OUT"
assert_contains "--check reports ready" "statechart: ready" "$OUT"
if [ ! -e "$C_LOG/curl-called" ]; then pass "--check after install performs no network"; else fail "--check after install performs no network"; fi

echo "setup-statechart: --check is non-mutating and performs no network"
new_case check-none yes
C_XDG_SET=yes invoke --check never
assert_nonzero "--check fails on an unconfigured host" "$RC"
assert_contains "--check says the jar is not installed" "jar: not installed" "$OUT"
assert_not_contains "--check does not claim ready when nothing is installed" "statechart: ready" "$OUT"
if [ ! -e "$C_LOG/curl-called" ]; then pass "--check performs no network (curl never called)"; else fail "--check performs no network (curl never called)"; fi
if [ ! -e "$C_XDG/himmel" ]; then pass "--check writes nothing (no data directory created)"; else fail "--check writes nothing (no data directory created)"; fi

echo "setup-statechart: missing java"
new_case no-java no
C_XDG_SET=yes invoke --install ok
assert_nonzero "--install refuses without Java" "$RC"
assert_contains "missing Java names the unmet prerequisite" "unmet prerequisite: no Java executable" "$OUT"
assert_contains "missing Java names the Ubuntu package" "openjdk-21-jre-headless" "$OUT"
assert_not_contains "missing Java never reports ready" "statechart: ready" "$OUT"
if [ ! -e "$C_LOG/curl-called" ]; then pass "missing Java downloads nothing"; else fail "missing Java downloads nothing"; fi
if [ ! -e "$(JAR_OF "$C_XDG")" ]; then pass "missing Java installs no jar"; else fail "missing Java installs no jar"; fi

echo "setup-statechart: Java below 11 is refused"
new_case old-java yes
C_XDG_SET=yes invoke --install ok "" 1.8.0_292
assert_nonzero "--install refuses Java 8" "$RC"
assert_contains "Java 8 is named as too old" "Java 11+ is required" "$OUT"

echo "setup-statechart: unsupported platform"
new_case unsupported yes
C_XDG_SET=yes invoke --install ok FreeBSD
assert_nonzero "--install refuses an unsupported platform" "$RC"
assert_contains "unsupported platform is named precisely" "unsupported platform 'FreeBSD'" "$OUT"
if [ ! -e "$C_LOG/curl-called" ]; then pass "unsupported platform downloads nothing"; else fail "unsupported platform downloads nothing"; fi
C_XDG_SET=yes invoke --check never FreeBSD
assert_nonzero "--check refuses an unsupported platform" "$RC"

echo "setup-statechart: failed download keeps the previous jar"
new_case dl-fail yes
JAR_F="$(JAR_OF "$C_XDG")"; mkdir -p "$(dirname "$JAR_F")"; cp "$OLD_JAR" "$JAR_F"
C_XDG_SET=yes invoke --install fail
assert_nonzero "--install fails when the download fails" "$RC"
assert_contains "failed download is named" "download failed" "$OUT"
assert_not_contains "failed download never reports ready" "statechart: ready" "$OUT"
assert_same_file "the previous jar survives a failed download" "$OLD_JAR" "$JAR_F"
if only_jar_in "$(dirname "$JAR_F")"; then
  pass "a failed download leaves no temp file"
else
  fail "a failed download leaves no temp file" "$(dirname "$JAR_F") holds more than the jar"
fi

echo "setup-statechart: wrong checksum keeps the previous jar"
new_case dl-bad yes
JAR_B="$(JAR_OF "$C_XDG")"; mkdir -p "$(dirname "$JAR_B")"; cp "$OLD_JAR" "$JAR_B"
C_XDG_SET=yes invoke --install bad
assert_nonzero "--install refuses a mismatched download" "$RC"
assert_contains "mismatch names the expected sha" "sha256 mismatch (expected $PIN" "$OUT"
assert_not_contains "a mismatch never reports ready" "statechart: ready" "$OUT"
assert_same_file "the previous jar survives a checksum mismatch" "$OLD_JAR" "$JAR_B"
if only_jar_in "$(dirname "$JAR_B")"; then
  pass "a checksum mismatch leaves no temp file"
else
  fail "a checksum mismatch leaves no temp file" "$(dirname "$JAR_B") holds more than the jar"
fi
if [ ! -e "$(ENV_OF "$C_XDG")" ]; then pass "a checksum mismatch writes no env file"; else fail "a checksum mismatch writes no env file"; fi

echo "setup-statechart: an already-correct jar is reused without curl"
new_case reuse yes
JAR_R="$(JAR_OF "$C_XDG")"; mkdir -p "$(dirname "$JAR_R")"; cp "$GOOD_JAR" "$JAR_R"
C_XDG_SET=yes invoke --install never
assert_rc "--install reuses a verified jar" 0 "$RC"
assert_contains "reuse is reported" "reusing it (no download)" "$OUT"
if [ ! -e "$C_LOG/curl-called" ]; then pass "a verified jar is reused without curl"; else fail "a verified jar is reused without curl"; fi
assert_contains "reuse still writes the env file" "statechart: ready" "$OUT"

echo "setup-statechart: unreadable env and paths"
new_case env-missing-path yes
mkdir -p "$C_XDG/himmel/statechart"
printf "JAVA='/nonexistent/java'\nTLA2TOOLS='/nonexistent/tla2tools.jar'\n" > "$(ENV_OF "$C_XDG")"
C_XDG_SET=yes invoke --check never
assert_nonzero "--check fails when env names missing paths" "$RC"
assert_contains "--check reports the env does not name the verified paths" "does not name the verified" "$OUT"
assert_not_contains "a stale env never reads ready" "statechart: ready" "$OUT"

new_case env-unreadable yes
mkdir -p "$C_XDG/himmel/statechart"
printf "JAVA='%s'\n" "$C_BIN/java" > "$(ENV_OF "$C_XDG")"
chmod 000 "$(ENV_OF "$C_XDG")"
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP: running as root, so chmod 000 does not make the env unreadable"
else
  C_XDG_SET=yes invoke --check never
  assert_nonzero "--check fails on an unreadable env file" "$RC"
  assert_contains "--check names the unreadable env file" "env: unreadable" "$OUT"
fi
chmod 600 "$(ENV_OF "$C_XDG")" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
