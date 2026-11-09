#!/usr/bin/env bash
# setup-statechart.sh — the opt-in installer for the pstack statechart check.
#
#   --check    (default) read-only: no network, no writes. Reports the Java and
#              the TLC jar it finds and exits 0 only when both verify and the
#              env file names them.
#   --install  verifies Java (never installs it), reuses an already-correct jar
#              or fetches the pinned jar over https into a temp file in the
#              same directory, verifies its sha256, and only then moves it into
#              place. A failed download or a checksum mismatch keeps any
#              previous jar and exits non-zero. Then writes the verified
#              absolute JAVA and TLA2TOOLS paths to the env file.
#
# Data (outside the checkout, never ~/.himmel/himmel.conf):
#   ${XDG_DATA_HOME:-$HOME/.local/share}/himmel/statechart/<version>/tla2tools.jar
#   ${XDG_DATA_HOME:-$HOME/.local/share}/himmel/statechart/env
#     (JAVA='<abs path>' and TLA2TOOLS='<abs path>' lines, for non-interactive runners)
#
# Java: $JAVA if set, else `java` on PATH; must be Java 11+. Pins: installer-pins.sh.
#
# usage: bash scripts/machine-setup/setup-statechart.sh [--check|--install]
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=installer-pins.sh
. "$here/installer-pins.sh"

TLA2TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA2TOOLS_VERSION}/tla2tools.jar"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/himmel/statechart"
JAR_DIR="$DATA_ROOT/$TLA2TOOLS_VERSION"
JAR="$JAR_DIR/tla2tools.jar"
ENV_FILE="$DATA_ROOT/env"
TMP_JAR=""
JAVA_PATH=""
JAVA_VERSION=""
trap 'if [ -n "$TMP_JAR" ]; then rm -f "$TMP_JAR"; fi' EXIT

usage() { echo "usage: setup-statechart.sh [--check|--install]" >&2; }

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

platform_check() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux|Darwin) return 0 ;;
    *) echo "statechart: unsupported platform '$os'; this setup supports Linux and macOS" >&2; return 1 ;;
  esac
}

java_resolve() {
  local resolved ver major
  resolved="$(command -v "${JAVA:-java}" 2>/dev/null)" || resolved=""
  if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
    echo "statechart: unmet prerequisite: no Java executable (JAVA='${JAVA:-}', none on PATH). Install Java 11+, OpenJDK 21 recommended: Ubuntu 'sudo apt install openjdk-21-jre-headless'; Arch 'sudo pacman -S jre21-openjdk'; macOS 'brew install openjdk@21'. This setup never installs Java." >&2
    return 1
  fi
  case "$resolved" in
    /*) ;;
    *) echo "statechart: JAVA must resolve to an absolute path (got '$resolved')" >&2; return 1 ;;
  esac
  ver="$("$resolved" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1)"
  case "$ver" in 1.*) major="${ver#1.}" ;; *) major="$ver" ;; esac
  major="${major%%[!0-9]*}"
  if [ -z "$major" ]; then
    echo "statechart: cannot read the Java version from $resolved" >&2
    return 1
  fi
  if [ "$major" -lt 11 ]; then
    echo "statechart: Java 11+ is required; $resolved is Java '$ver'" >&2
    return 1
  fi
  JAVA_PATH="$resolved"
  JAVA_VERSION="$ver"
}

env_value() {
  sed -n "s/^$1='\(.*\)'\$/\1/p" "$ENV_FILE" | head -1
}

check_all() {
  local ok=0 jar_good=0 jar_sha env_java env_jar
  if java_resolve; then
    echo "java: $JAVA_PATH (version $JAVA_VERSION)"
  else
    ok=1
  fi
  if [ ! -f "$JAR" ]; then
    echo "jar: not installed at $JAR (run: bash scripts/machine-setup/setup-statechart.sh --install)"
    ok=1
  elif [ ! -r "$JAR" ]; then
    echo "jar: unreadable at $JAR"
    ok=1
  else
    jar_sha="$(sha_of "$JAR")"
    if [ "$jar_sha" = "$TLA2TOOLS_SHA256" ]; then
      echo "jar: $JAR (tla2tools $TLA2TOOLS_VERSION) sha256 $jar_sha"
      jar_good=1
    else
      echo "jar: $JAR sha256 mismatch (expected $TLA2TOOLS_SHA256, got ${jar_sha:-unreadable})"
      ok=1
    fi
  fi
  if [ ! -e "$ENV_FILE" ]; then
    echo "env: not written ($ENV_FILE)"
    ok=1
  elif [ ! -r "$ENV_FILE" ]; then
    echo "env: unreadable ($ENV_FILE)"
    ok=1
  else
    env_java="$(env_value JAVA)"
    env_jar="$(env_value TLA2TOOLS)"
    if [ -n "$JAVA_PATH" ] && [ "$jar_good" -eq 1 ] && [ "$env_java" = "$JAVA_PATH" ] && [ "$env_jar" = "$JAR" ]; then
      echo "env: $ENV_FILE names the verified JAVA and TLA2TOOLS"
    else
      echo "env: $ENV_FILE does not name the verified JAVA and TLA2TOOLS paths"
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    echo "statechart: ready"
  fi
  return "$ok"
}

fetch_jar() {
  local got
  TMP_JAR="$(mktemp "$JAR_DIR/.tla2tools.XXXXXX")" || {
    echo "statechart: cannot create a temp file in $JAR_DIR" >&2
    return 1
  }
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$TMP_JAR" "$TLA2TOOLS_URL"; then
    echo "statechart: download failed: $TLA2TOOLS_URL (a previous jar, if any, is kept)" >&2
    return 1
  fi
  got="$(sha_of "$TMP_JAR")"
  if [ "$got" != "$TLA2TOOLS_SHA256" ]; then
    echo "statechart: tla2tools.jar sha256 mismatch (expected $TLA2TOOLS_SHA256, got ${got:-unreadable}); refusing to install, a previous jar, if any, is kept" >&2
    return 1
  fi
  chmod 0644 "$TMP_JAR" || return 1
  mv "$TMP_JAR" "$JAR" || { # prim-ok: same-directory rename after the sha256 check, so a failed download keeps the old jar

    echo "statechart: cannot move the verified jar to $JAR" >&2
    return 1
  }
  TMP_JAR=""
}

write_env() {
  local tmp
  case "$JAVA_PATH$JAR" in
    *\'*) echo "statechart: refusing to write env: a path contains a single quote" >&2; return 1 ;;
  esac
  tmp="$(mktemp "$DATA_ROOT/.env.XXXXXX")" || return 1
  if ! { printf "JAVA='%s'\n" "$JAVA_PATH"; printf "TLA2TOOLS='%s'\n" "$JAR"; } > "$tmp" \
    || ! mv "$tmp" "$ENV_FILE"; then # prim-ok: same-directory rename of a fully written temp file
    rm -f "$tmp"
    echo "statechart: cannot write $ENV_FILE" >&2
    return 1
  fi
}

install_all() {
  java_resolve || return 1
  mkdir -p "$JAR_DIR" || {
    echo "statechart: cannot create $JAR_DIR" >&2
    return 1
  }
  if [ -f "$JAR" ] && [ "$(sha_of "$JAR")" = "$TLA2TOOLS_SHA256" ]; then
    echo "jar: $JAR already verified; reusing it (no download)"
  else
    fetch_jar || return 1
  fi
  write_env || return 1
  check_all
}

case "${1:---check}" in
  --check|--install) [ $# -le 1 ] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac

platform_check || exit 1
if [ "${1:---check}" = "--install" ]; then
  install_all
else
  check_all
fi
