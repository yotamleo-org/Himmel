#!/usr/bin/env bash
# ensure-qmd-daemon.sh - bring up the shared qmd HTTP MCP daemon if it is not
# already serving on localhost:8181.
#
# Lives INSIDE the qmd plugin (wired via hooks/hooks.json SessionStart with
# ${CLAUDE_PLUGIN_ROOT}) so it runs from ANY session in ANY repo where the
# plugin is enabled - not just himmel checkouts. The plugin declares an HTTP
# MCP endpoint shared by every Claude session instead of a per-session stdio
# process; this script is that endpoint's startup path. It probes the
# endpoint, exits 0 silently when a qmd daemon already answers, and otherwise
# starts one (idempotent) and waits for it to come alive. Cheap on the healthy
# path (one local curl); loud on failure (clear remediation, never a silent
# empty index).
#
# Foreign-listener safety: a non-qmd process holding port 8181 must NOT count
# as "alive" - the probe validates the MCP initialize reply is qmd-shaped
# (serverInfo.name == "qmd") and fails loudly on a port collision.
#
# Bounded start: the daemon start is wrapped in timeout(1) when available so
# a hung qmd/bun start cannot stall every new session at SessionStart.
# Worst case ~44s common / ~59s pathological (QMD_START_TIMEOUT 20 + kill
# grace 5 + port-release wait 15, or 30 if every connect attempt itself
# stalls to its own 1s timeout(1) bound + post-start wait loop ~4), under
# Claude Code's default 60s hook timeout - do
# not raise the defaults past that budget. Note: a malformed QMD_MCP_URL
# override looks identical to daemon-dead (curl stderr is discarded by
# design).
#
# qmd resolution is inlined (bun + the bun-global qmd.js FIRST, then the bun
# bin shim, then PATH; .exe variant on Windows) - self-contained mirror of the
# essentials of himmel's scripts/lib/qmd-bin.sh, which this plugin copy cannot
# source because the plugin must work outside a himmel checkout.
# bash 3.2-safe, shellcheck clean, ASCII-only.
#
# Test seams (used only by scripts/qmd/test-ensure-qmd-daemon.sh in the
# himmel repo; default to production):
#   QMD_MCP_URL         probe URL AND raw-TCP-probe host:port (default
#                        http://localhost:8181/mcp)
#   QMD_CURL            curl binary         (default curl)
#   QMD_START_TIMEOUT   daemon-start bound  (default 20 seconds)
#   QMD_PS              ps binary           (default ps)
# Operator knobs:
#   QMD_RSS_CEILING_MB        recycle the daemon above this RSS (default 4096;
#                              0 disables)
#   QMD_RECYCLE_COOLDOWN_MIN  minimum minutes between recycles (default 30)
#   QMD_WAIT_TRIES            one-second probes after a start before giving up
#                              (default 5; digits only)
#   QMD_SWAP_WAIT             seconds a start waits for another index's start to free the
#                              shared embed-swap lock before it gives up (default 30)
#   QMD_INDEX_NAME            a named index (qmd --index <name>): its own pidfile
#                              mcp-<name>.pid, recycle-<name>.{lock,stamp,log},
#                              starting-<name> and boot unit qmd-daemon-<name>.service,
#                              and a pid whose argv does not name that index is never ours
#
# --recycle-if-stale <stamp>: himmel-update runs this, in the foreground, after it
# installs a new qmd build (<stamp> is the build-success file). The running server
# is stale iff its pidfile is OLDER than <stamp>. It is recycled only when the
# pidfile's pid is that server: an HTTP argv (mcp and --http, so a per-session
# stdio server never matches) AND a process start no later than the pidfile's
# mtime (a pid reused after the pidfile was written is never ours). Identity is
# checked again right before any SIGKILL. A missing or unusable pidfile means
# "cannot verify": non-zero, nothing signalled, and no process-list search.
# Unlike the RSS recycle it takes the lock with a bounded retry and ignores the
# cooldown (a fresh stamp from an RSS recycle must not keep a stale build alive).
# Exit 0 only when the pidfile is newer than <stamp>, its pid passes the
# identity check and the server ACCEPTS an MCP initialize: a 401 is up-but-refusing
# the token, which prints one reason line and exits non-zero. Exit 10 means the
# recycle was skipped because qmd is switched OFF (the operator opt-out below):
# nothing was checked or restarted. Exit codes in this mode: 0 a server newer than
# the stamp is serving, 10 skipped because qmd is off, 2 no stamp path, other non-zero
# cannot verify or the server is not serving. Worst case ~150s:
# lock wait 20 + SIGTERM wait 30 + SIGKILL wait 5 + the ~59s start path + verify
# 10 tries of (2s probe + 1s sleep) + the 4s reason probes.
#   QMD_STALE_LOCK_WAIT  seconds to wait for the recycle lock (default 20)
#   QMD_STALE_TERM_WAIT  seconds to wait after SIGTERM before SIGKILL (default 30)
set -u

# localhost, NOT 127.0.0.1: the daemon binds qmd's own advertised address,
# which resolves to ::1 (IPv6-only) on Windows - an IPv4 probe gets
# connection-refused against a healthy daemon (round-3 CR, reproduced live).
# .mcp.json + the ps1 twin use the same URL; keep all three aligned.
unit_url="${QMD_MCP_URL:-}"
QMD_MCP_URL="${QMD_MCP_URL:-http://localhost:8181/mcp}"
QMD_CURL="${QMD_CURL:-curl}"
QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}"
QMD_PS="${QMD_PS:-ps}"
QMD_RSS_CEILING_MB="${QMD_RSS_CEILING_MB:-4096}"
QMD_RECYCLE_COOLDOWN_MIN="${QMD_RECYCLE_COOLDOWN_MIN:-30}"
case "$QMD_RECYCLE_COOLDOWN_MIN" in ''|*[!0-9]*) QMD_RECYCLE_COOLDOWN_MIN=30 ;; esac
# Force base 10: a leading zero (`08`) is octal to Bash arithmetic and aborts.
# A non-numeric ceiling disables it.
case "$QMD_RSS_CEILING_MB" in ''|*[!0-9]*) QMD_RSS_CEILING_MB=0 ;; esac
QMD_RSS_CEILING_MB=$((10#$QMD_RSS_CEILING_MB))
QMD_RECYCLE_COOLDOWN_MIN=$((10#$QMD_RECYCLE_COOLDOWN_MIN))

QMD_SYSTEMCTL="${QMD_SYSTEMCTL:-systemctl}"
QMD_UNIT_DIR="${QMD_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"

QMD_INDEX_NAME="${QMD_INDEX_NAME:-index}"
case "$QMD_INDEX_NAME" in
  *[!A-Za-z0-9._-]*|'')
    echo "ensure-qmd-daemon: ERROR - QMD_INDEX_NAME must match [A-Za-z0-9._-]+, got '$QMD_INDEX_NAME'." >&2 # t13b-ok: message text only, starts nothing
    exit 1 ;;
esac
if [ "$QMD_INDEX_NAME" = index ]; then
  idx_sfx=""
  boot_unit="qmd-daemon.service"  # t13b-ok: the boot unit's name only, starts nothing
else
  idx_sfx="-$QMD_INDEX_NAME"
  boot_unit="qmd-daemon-$QMD_INDEX_NAME.service"  # t13b-ok: the boot unit's name only, starts nothing
fi
mcp_stem="mcp$idx_sfx"
shared_port=8181
url_port() {
  local h="${1#*://}" p
  h="${h%%[/?#]*}"
  h="${h##*@}"
  case "$h" in \[*) h="${h#*]}" ;; esac
  case "$h" in *:*) p="${h##*:}" ;; *) return 1 ;; esac
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  p="${p#"${p%%[!0]*}"}"
  [ -n "$p" ] && [ "${#p}" -le 5 ] && [ "$p" -le 65535 ] || return 1
  echo "$p"
}
url_port_n=""
if [ "$QMD_INDEX_NAME" != index ]; then
  if [ -z "$unit_url" ]; then
    echo "ensure-qmd-daemon: ERROR - the named index '$QMD_INDEX_NAME' needs its own QMD_MCP_URL (its own port, e.g. http://localhost:8183/mcp); the default URL is the shared server's." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  fi
  url_port_n="$(url_port "$QMD_MCP_URL")" || {
    echo "ensure-qmd-daemon: ERROR - QMD_MCP_URL '$QMD_MCP_URL' must name a numeric port 1-65535 for the named index '$QMD_INDEX_NAME'." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  }
  if [ "$url_port_n" -eq "$shared_port" ]; then
    echo "ensure-qmd-daemon: ERROR - the named index '$QMD_INDEX_NAME' cannot use port $shared_port, the shared server's; set QMD_MCP_URL to the index's own port." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  fi
fi
boot_before="himmel-recover.service"

unit_env_line() {
  local v="$2"
  case "$v" in *[[:cntrl:]]*) echo "ensure-qmd-daemon: $1 holds a control character; not writing the boot unit" >&2; return 1 ;; esac  # t13b-ok: message text only, starts nothing
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//%/%%}"
  printf 'Environment="%s=%s"\n' "$1" "$v"
}

unit_env_lines() {
  local f
  [ "$QMD_INDEX_NAME" = index ] || unit_env_line QMD_INDEX_NAME "$QMD_INDEX_NAME" || return 1
  [ -z "$unit_url" ] || unit_env_line QMD_MCP_URL "$unit_url" || return 1
  for f in QMD_HTTP_TOKEN_FILE QMD_HTTP_AUTH_FILE; do
    [ -n "${!f:-}" ] || continue
    case "${!f}" in
      /*) ;;
      *) echo "ensure-qmd-daemon: $f must be an absolute path to go into the boot unit" >&2; return 1 ;;  # t13b-ok: message text only, starts nothing
    esac
    unit_env_line "$f" "${!f}" || return 1
  done
  [ -z "${QMD_WAIT_TRIES:-}" ] || case "$QMD_WAIT_TRIES" in
    *[!0-9]*) echo "ensure-qmd-daemon: QMD_WAIT_TRIES must be digits to go into the boot unit" >&2; return 1 ;;  # t13b-ok: message text only, starts nothing
    *) unit_env_line QMD_WAIT_TRIES "$QMD_WAIT_TRIES" ;;
  esac
}

install_boot_unit() {
  local self unit env_lines desc
  self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ensure-qmd-daemon.sh" || return 1  # t13b-ok: this script's own path, starts nothing
  unit="$QMD_UNIT_DIR/$boot_unit"
  env_lines="$(unit_env_lines)" || return 1
  desc="Himmel qmd search server (starts before the chief and workers)"
  [ "$QMD_INDEX_NAME" = index ] || desc="Himmel qmd search server, $QMD_INDEX_NAME index"
  mkdir -p "$QMD_UNIT_DIR" || return 1
  # PATH names the bun root: a user manager's default PATH has no ~/.bun/bin, and
  # without bun the start would fall to the node-shebang shim (see resolve_qmd).
  {
    printf '[Unit]\n'
    printf 'Description=%s\n' "$desc"
    [ "$QMD_INDEX_NAME" != index ] || printf 'Before=%s\n' "$boot_before"
    printf '\n[Service]\n'
    printf 'Type=oneshot\n'
    printf 'RemainAfterExit=yes\n'
    printf 'TimeoutStartSec=120\n'
    printf 'Environment=PATH=%%h/.bun/bin:/usr/local/bin:/usr/bin:/bin\n'
    [ -z "$env_lines" ] || printf '%s\n' "$env_lines"
    printf 'ExecStart=/usr/bin/env bash "%s"\n' "${self//%/%%}"
    printf '\n[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$unit.tmp" || { echo "ensure-qmd-daemon: cannot write $unit" >&2; return 1; }  # t13b-ok: message text only, starts nothing
  mv "$unit.tmp" "$unit" || { echo "ensure-qmd-daemon: cannot write $unit" >&2; return 1; }  # t13b-ok: message text only, starts nothing
  "$QMD_SYSTEMCTL" --user daemon-reload || { echo "ensure-qmd-daemon: systemctl --user daemon-reload failed" >&2; return 1; }  # t13b-ok: reloads unit files, starts nothing
  "$QMD_SYSTEMCTL" --user enable "$boot_unit" || { echo "ensure-qmd-daemon: systemctl --user enable $boot_unit failed" >&2; return 1; }  # t13b-ok: enables the boot unit this mode exists to install
  echo "ensure-qmd-daemon: installed and enabled $unit (runs $self at login$([ "$QMD_INDEX_NAME" = index ] && echo ", before $boot_before")); re-run after the plugin path changes"  # t13b-ok: message text only, starts nothing
}

boot_show() { "$QMD_SYSTEMCTL" --user show -p "$1" --value "$2" 2>/dev/null; }
boot_mono() {
  local t
  t="$(boot_show "$2" "$1")" || return 1
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  echo "$((10#$t))"
}

boot_order_check() {
  local before q c
  before="$(boot_show Before "$boot_unit")"
  case " $before " in
    *" $boot_before "*) ;;
    *) echo "boot-order: $boot_unit does not order before $boot_before (Before=${before:-none}); run --install-boot-unit"; return 1 ;;
  esac
  q="$(boot_mono "$boot_unit" ActiveEnterTimestampMonotonic)" || { echo "boot-order: cannot read the start time of $boot_unit"; return 1; }
  c="$(boot_mono "$boot_before" ExecMainStartTimestampMonotonic)" || { echo "boot-order: cannot read the start time of $boot_before"; return 1; }
  if [ "$q" -eq 0 ]; then
    echo "boot-order: $boot_unit did not start this boot"
    return 1
  fi
  if [ "$c" -eq 0 ]; then
    echo "boot-order: $boot_before did not start this boot (nothing to order against); $boot_unit started at ${q}us since boot"
    return 0
  fi
  if [ "$q" -le "$c" ]; then
    echo "boot-order: $boot_unit started before $boot_before (${q}us < ${c}us since boot)"
    return 0
  fi
  echo "boot-order: $boot_unit started AFTER $boot_before (${q}us > ${c}us since boot)"
  return 1
}

case "${1:-}" in
  --install-boot-unit) install_boot_unit; exit $? ;;
  --boot-order-check) boot_order_check; exit $? ;;
esac

# ---- Operator opt-out ------------------------------------------
# The flag file (cross-session, no relaunched shells) or QMD_DAEMON_DISABLED=1
# (one shell) keeps the shared daemon OFF on purpose, e.g. while gaming (its
# embed/expand/rerank models contend for the GPU). Checked before ANY probe or
# launch: exit 0, one INFO line, nothing started. qmd-daemon-switch.sh off|on
# is the operator's one-liner. Under --recycle-if-stale the same check exits 10
# instead of 0, so a caller can tell a skipped recycle from a completed one.
QMD_DAEMON_OFF_FLAG="${QMD_DAEMON_OFF_FLAG:-$HOME/.himmel/state/qmd-daemon.off}"
if [ "${QMD_DAEMON_DISABLED:-}" = "1" ] || [ -e "$QMD_DAEMON_OFF_FLAG" ]; then
  echo "ensure-qmd-daemon: INFO - qmd is OFF by operator choice; not launching. Turn it back on: bash \"$(dirname -- "${BASH_SOURCE[0]}")/qmd-daemon-switch.sh\" on (or remove $QMD_DAEMON_OFF_FLAG / unset QMD_DAEMON_DISABLED)"
  [ "${1:-}" = "--recycle-if-stale" ] && exit 10  # t13b-ok: exit code only, starts nothing
  exit 0
fi

PROBE_TIMEOUT=2
WAIT_TRIES="${QMD_WAIT_TRIES:-5}"
case "$WAIT_TRIES" in ''|*[!0-9]*) WAIT_TRIES=5 ;; esac
WAIT_TRIES=$((10#$WAIT_TRIES))
[ "$WAIT_TRIES" -gt 0 ] || WAIT_TRIES=5
PORT_WAIT_TRIES=15
swap_wait="${QMD_SWAP_WAIT:-30}"
case "$swap_wait" in ''|*[!0-9]*) swap_wait=30 ;; esac
swap_wait=$((10#$swap_wait))

INIT_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ensure-qmd-daemon","version":"1"}}}'

# Echo the raw probe response body (empty on connection failure).
probe_body() {
  # The daemon requires a bearer token; read it per probe so the
  # file the daemon creates on first start is picked up. The header goes via a
  # curl config on stdin, never argv (visible in ps).
  local tok
  tok="$(bash "$(dirname "${BASH_SOURCE[0]}")/qmd-auth-headers.sh" --token-for "$QMD_MCP_URL" 2>/dev/null)"
  if [ -n "$tok" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$tok" | "$QMD_CURL" -q -s -m "$PROBE_TIMEOUT" --noproxy '*' -g -X POST \
      -K - \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "$INIT_PAYLOAD" \
      "$QMD_MCP_URL" 2>/dev/null
    return
  fi
  "$QMD_CURL" -s -m "$PROBE_TIMEOUT" -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$INIT_PAYLOAD" \
    "$QMD_MCP_URL" 2>/dev/null
}

# Echo the HTTP status of a bounded request (000 when nothing answers).
http_code() {
  "$QMD_CURL" -s -m "$PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' "$@" 2>/dev/null
}

# True when the daemon is up but refuses this probe's token (none readable, or
# a stale one): the MCP route answers 401 while the unauthenticated /health on
# the same host:port answers with qmd's own {"status":"ok","uptime":N} body.
# Alive, auth required - never dead. The body is matched, not just a 200, so a
# foreign auth-gated service on the port still reaches the not-qmd error.
alive_auth_required() {
  local hostport="${QMD_MCP_URL#*://}" health
  hostport="${hostport%%/*}"
  [ "$(http_code -X POST -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$INIT_PAYLOAD" "$QMD_MCP_URL")" = 401 ] || return 1
  health="$("$QMD_CURL" -s -m "$PROBE_TIMEOUT" "${QMD_MCP_URL%%://*}://$hostport/health" 2>/dev/null)"
  case "$health" in
    *'"status":"ok"'*'"uptime":'*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the body carries a qmd-shaped MCP initialize reply: the match is
# scoped to the serverInfo object (serverInfo.name == "qmd"), so a foreign
# server whose reply merely CONTAINS a name:qmd pair elsewhere (tool list,
# echoed fragment) does not falsely validate.
is_qmd_shaped() {
  printf '%s' "$1" | grep -Eq '"serverInfo"[[:space:]]*:[[:space:]]*\{[^}]*"name"[[:space:]]*:[[:space:]]*"qmd"'
}

# Resolve how to invoke qmd. Sets QMD_BIN (argv0) and QMD_BIN_ARG1 (optional
# first arg). Preference order:
#   1. bun + the bun-global @tobilu/qmd dist/cli/qmd.js -> `bun <qmd.js>`
#   2. bun global bin shim ($HOME/.bun/bin/qmd, .exe variant on Windows)
#   3. PATH
# bun-js FIRST is load-bearing, not just parity with qmd_cmd in himmel's
# scripts/lib/qmd-bin.sh: the bin shim honors the CLI's node shebang and runs
# qmd under NODE, and the --daemon child is spawned via process.execPath - so
# a shim-started daemon runs under whatever node is installed. Under bun qmd
# uses bun:sqlite; under node it needs the better-sqlite3 native binding,
# which bun's install blocks by default and which breaks again on every node
# ABI bump (reproduced live: absent binding + node 26 killed the daemon at
# startup). `bun <qmd.js>` makes process.execPath = bun and the
# daemon child inherits it. Bun-before-PATH:
# a broken Windows qmd stub can shadow PATH, so the known-good
# bun install wins when present. Provenance: minimal inline mirror of
# qmd-bin.sh - see header.
resolve_qmd() {
  # One bun root for BOTH the js and the shim fallbacks: a relocated
  # BUN_INSTALL must not resolve the js from one root and the shim from
  # $HOME/.bun (CodeRabbit, PR #1134).
  bun_root="${BUN_INSTALL:-$HOME/.bun}"
  bun_js="$bun_root/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
  if [ -f "$bun_js" ] && command -v bun >/dev/null 2>&1; then
    QMD_BIN="bun"
    QMD_BIN_ARG1="$bun_js"
    return 0
  fi
  QMD_BIN_ARG1=""
  if [ -x "$bun_root/bin/qmd" ]; then
    QMD_BIN="$bun_root/bin/qmd"
    return 0
  fi
  if [ -f "$bun_root/bin/qmd.exe" ]; then
    QMD_BIN="$bun_root/bin/qmd.exe"
    return 0
  fi
  if command -v qmd >/dev/null 2>&1; then
    QMD_BIN="qmd"
    return 0
  fi
  return 1
}

# ---- Memory ceiling + detached self-recycle --------------------
# A long-lived daemon has been seen to grow to 6.8 GB RSS / 37% idle CPU over
# ~4.5h, at which point vec queries time out while lex keeps answering. Bound
# it: on the healthy path, read the RSS of the pid in qmd's own pidfile (ONE ps
# call, no network - this runs at every SessionStart) and, over
# QMD_RSS_CEILING_MB, hand the recycle to a DETACHED copy of this script
# (--recycle) so the SIGTERM + ~15s unwind + restart never spends the hook's
# budget. Fleets start many sessions at once, so a mkdir lock admits one
# recycler and a stamp holds off another for QMD_RECYCLE_COOLDOWN_MIN.
qmd_state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/qmd"
pidfile="$qmd_state_dir/$mcp_stem.pid"
recycle_lock="$qmd_state_dir/recycle$idx_sfx.lock"
recycle_stamp="$qmd_state_dir/recycle$idx_sfx.stamp"
recycle_log="$qmd_state_dir/recycle$idx_sfx.log"

args_name_index() {
  local -a words
  local w prev="" got=index
  read -r -a words <<EOF
$1
EOF
  for w in "${words[@]:-}"; do
    [ "$prev" != --index ] || got="$w"
    case "$w" in --index=*) got="${w#--index=}" ;; esac
    prev="$w"
  done
  [ "$got" = "$QMD_INDEX_NAME" ]
}

qmd_rss() {
  local row rss etime args
  row="$("$QMD_PS" -o rss= -o etime= -o args= -p "$1" 2>/dev/null)" || return 1
  case "$row" in *qmd*mcp*) ;; *) return 1 ;; esac
  read -r rss etime args <<EOF
$row
EOF
  case "$rss" in ''|*[!0-9]*) return 1 ;; esac
  args_name_index "$args" || return 1
  last_args="$args"
  echo "$rss $etime"
}

args_port() {
  local -a words
  local w prev="" got=""
  read -r -a words <<EOF
$1
EOF
  for w in "${words[@]:-}"; do
    [ "$prev" != --port ] || got="$w"
    case "$w" in --port=*) got="${w#--port=}" ;; esac
    prev="$w"
  done
  case "$got" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#got}" -le 9 ] && echo "$((10#$got))"
}

index_serves() {
  local pid
  [ "$QMD_INDEX_NAME" = index ] && return 0
  pid="$(head -n1 "$pidfile" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  qmd_rss "$pid" >/dev/null || return 1
  [ "$(args_port "$last_args")" = "$url_port_n" ]
}

check_ceiling() {
  local pid row rss_kb etime now last ceiling_kb
  [ "$QMD_RSS_CEILING_MB" -gt 0 ] || return 0
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  row="$(qmd_rss "$pid")" || return 0
  rss_kb="${row%% *}"
  etime="${row#* }"
  ceiling_kb=$((QMD_RSS_CEILING_MB * 1024))
  [ "$rss_kb" -gt "$ceiling_kb" ] || return 0
  now="$(date +%s)"
  last="$(cat "$recycle_stamp" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt $((QMD_RECYCLE_COOLDOWN_MIN * 60)) ]; then
    echo "ensure-qmd-daemon: qmd daemon (PID $pid) RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB, but it was recycled under ${QMD_RECYCLE_COOLDOWN_MIN} min ago - cooldown, not recycling again" >&2  # t13b-ok: log text only, starts nothing
    return 0
  fi
  # A crashed recycler must not wedge the ceiling forever: a lock older than
  # its worst case (~90s: 30s kill wait + the ~59s start path) is cleared. The
  # stamp re-check after mkdir stops a session that read the stamp before the
  # winner wrote it.
  # prim-ok: the plugin installs without scripts/lib, so prim.sh is absent; this is a non-blocking mkdir try-lock with its own stale clear, and with_lock would wait instead of yielding
  if ! mkdir "$recycle_lock" 2>/dev/null; then
    last="$(cat "$recycle_lock/at" 2>/dev/null)"
    case "$last" in
      # No 'at' yet: its holder may sit between mkdir and the write, so judge
      # staleness by the lock directory's own age instead.
      ''|*[!0-9]*) [ -n "$(find "$recycle_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 0 ;; # gnu-ok: BSD find has -maxdepth and -mmin too
      *) [ $((now - last)) -gt 120 ] || return 0 ;;
    esac
    # Clear it, never take it over here: two sessions that both judged it
    # stale could each remove the other's fresh lock and both recycle. The
    # next session start takes the lock through a plain mkdir.
    rm -rf "$recycle_lock"
    echo "ensure-qmd-daemon: cleared a stale recycle lock; the next session start recycles the daemon (RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB)" >&2  # t13b-ok: log text only, starts nothing
    return 0
  fi
  last="$(cat "$recycle_stamp" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt $((QMD_RECYCLE_COOLDOWN_MIN * 60)) ]; then
    rm -rf "$recycle_lock"
    return 0
  fi
  echo "$now" > "$recycle_lock/at"
  echo "$now" > "$recycle_stamp"
  echo "ensure-qmd-daemon: qmd daemon (PID $pid, up $etime) RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB - recycling it in the background (log: $recycle_log)" >&2  # t13b-ok: log text; the recycler restarts the existing qmd server through the normal start path, bounded
  # Every fd redirected: a child holding the hook's stdout/stderr would make
  # Claude Code wait on it. setsid (when present) survives the session's exit.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" --recycle "$pid" </dev/null >>"$recycle_log" 2>&1 &
  else
    bash "$0" --recycle "$pid" </dev/null >>"$recycle_log" 2>&1 &
  fi
}

# Detached recycler: stop the old daemon, wait for it to exit, then run the
# normal start path (probe dead -> port-release wait -> start -> verify).
if [ "${1:-}" = "--recycle" ]; then
  pid="${2:-}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') recycle: SIGTERM qmd daemon PID $pid"  # t13b-ok: log text only, starts nothing
  if qmd_rss "$pid" >/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    w=0
    while [ "$w" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
      w=$((w + 1))
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "recycle: PID $pid still alive after 30s - SIGKILL"
      kill -KILL "$pid" 2>/dev/null
    fi
  else
    echo "recycle: PID $pid is no longer a qmd mcp process - skipping the kill"
  fi
  bash "$0"
  rc=$?
  echo "$(date '+%Y-%m-%d %H:%M:%S') recycle: restart rc=$rc"
  rm -rf "$recycle_lock"
  exit "$rc"
fi

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# [[dd-]hh:]mm:ss -> seconds
etime_secs() {
  local t="$1" d=0 h=0 a b c m s
  case "$t" in *-*) d="${t%%-*}"; t="${t#*-}" ;; esac
  IFS=: read -r a b c <<EOF
$t
EOF
  if [ -n "$c" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  case "$d$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( (10#$d * 24 + 10#$h) * 3600 + 10#$m * 60 + 10#$s ))
}

# True iff <pid> is the HTTP server whose start wrote the pidfile of mtime <mtime>.
# One second of slack each way: etime and the mtime are both truncated to seconds.
pid_is_ours() {
  local row etime args secs
  row="$("$QMD_PS" -o etime= -o args= -p "$1" 2>/dev/null)" || return 1
  read -r etime args <<EOF
$row
EOF
  case "$args" in *qmd*mcp*--http*) ;; *) return 1 ;; esac
  args_name_index "$args" || return 1
  secs="$(etime_secs "$etime")" || return 1
  [ $(( $(date +%s) - secs )) -le $(($2 + 2)) ]
}

recycle_lock_stale() {
  local at
  at="$(cat "$recycle_lock/at" 2>/dev/null)"
  case "$at" in
    ''|*[!0-9]*) [ -n "$(find "$recycle_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] ;; # gnu-ok: BSD find has -maxdepth and -mmin too
    *) [ $(( $(date +%s) - at )) -gt 120 ] ;;
  esac
}

answers_mcp() {
  local reply
  reply="$(probe_body)"
  [ -n "$reply" ] && is_qmd_shaped "$reply"
}

unserved_reason() {
  if alive_auth_required; then
    echo "$1: server is up but rejected the MCP token - not reporting it as serving" >&2
  else
    echo "$1: the qmd server is running but answers no MCP initialize - not reporting it as serving" >&2
  fi
}

stale_recycle() {
  local stamp="$1" who="ensure-qmd-daemon" # t13b-ok: message prefix text only, starts nothing
  local stamp_m pf_m pid lock_wait term_wait w took=0 verdict=1
  case "$stamp" in '') echo "$who: --recycle-if-stale needs the build stamp path" >&2; return 2 ;; esac
  stamp_m="$(file_mtime "$stamp")"
  case "$stamp_m" in ''|*[!0-9]*) echo "$who: cannot read the build stamp $stamp - not recycling" >&2; return 1 ;; esac
  lock_wait="${QMD_STALE_LOCK_WAIT:-20}"; term_wait="${QMD_STALE_TERM_WAIT:-30}"
  case "$lock_wait" in ''|*[!0-9]*) lock_wait=20 ;; esac
  case "$term_wait" in ''|*[!0-9]*) term_wait=30 ;; esac

  read_pidfile() {
    pid="$(head -n1 "$pidfile" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    pf_m="$(file_mtime "$pidfile")"
    case "$pf_m" in ''|*[!0-9]*) return 1 ;; esac
  }

  read_pidfile || { echo "$who: no usable pidfile ($pidfile) - cannot tell which process is the qmd server; not signalling anything" >&2; return 1; }
  if [ "$pf_m" -ge "$stamp_m" ]; then
    if pid_is_ours "$pid" "$pf_m"; then
      answers_mcp && index_serves && return 0
      unserved_reason "$who"
      return 1
    fi
    echo "$who: the pidfile is newer than $stamp but PID $pid is not the qmd HTTP server that wrote it - cannot verify" >&2
    return 1
  fi

  mkdir -p "$qmd_state_dir" 2>/dev/null
  w=0
  # prim-ok: the plugin installs without scripts/lib, so with_lock is absent; a bounded mkdir retry that clears a stale lock itself
  while ! mkdir "$recycle_lock" 2>/dev/null; do
    if recycle_lock_stale; then
      rm -rf "$recycle_lock"
      echo "$who: cleared a stale recycle lock - not restarting now; run --recycle-if-stale again" >&2
      return 1
    fi
    w=$((w + 1))
    if [ "$w" -gt "$lock_wait" ]; then
      echo "$who: another recycler holds $recycle_lock - not restarting the qmd server now" >&2
      return 1
    fi
    sleep 1
  done
  echo "$$" > "$recycle_lock/owner"
  # shellcheck disable=SC2064 # expand now: the lock path and our pid are fixed for this run
  trap "[ \"\$(cat '$recycle_lock/owner' 2>/dev/null)\" = '$$' ] && rm -rf '$recycle_lock'" EXIT
  date +%s > "$recycle_lock/at"

  read_pidfile || { echo "$who: the pidfile vanished while waiting for the lock - cannot verify" >&2; return 1; }
  if [ "$pf_m" -lt "$stamp_m" ] && pid_is_ours "$pid" "$pf_m"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') recycle-if-stale: SIGTERM qmd server PID $pid (older than $stamp)"
    kill -TERM "$pid" 2>/dev/null
    took=0
    while [ "$took" -lt "$term_wait" ] && kill -0 "$pid" 2>/dev/null; do
      took=$((took + 1))
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      if pid_is_ours "$pid" "$pf_m"; then
        echo "recycle-if-stale: PID $pid still alive after ${term_wait}s - SIGKILL"
        kill -KILL "$pid" 2>/dev/null
        took=0
        while [ "$took" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do took=$((took + 1)); sleep 1; done
      else
        echo "recycle-if-stale: PID $pid no longer passes the identity check - not sending SIGKILL"
      fi
    fi
  fi

  bash "$0" || echo "$who: the start path failed" >&2
  w=0
  while [ "$w" -lt 10 ]; do
    if read_pidfile && [ "$pf_m" -ge "$stamp_m" ] && pid_is_ours "$pid" "$pf_m" && answers_mcp && index_serves; then verdict=0; break; fi
    w=$((w + 1))
    sleep 1
  done
  if [ "$verdict" -ne 0 ]; then
    echo "$who: no qmd server newer than $stamp is serving after the recycle" >&2
    unserved_reason "$who"
  fi
  return "$verdict"
}

if [ "${1:-}" = "--recycle-if-stale" ]; then
  stale_recycle "${2:-}"
  exit $?
fi

# ---- Healthy path: something already answers -------------------------------
body="$(probe_body)"
if { [ -n "$body" ] && is_qmd_shaped "$body"; } || alive_auth_required; then
  if ! index_serves; then
    echo "ensure-qmd-daemon: ERROR - $QMD_MCP_URL answers, but it is not the '$QMD_INDEX_NAME' index's server (no live $pidfile naming --index $QMD_INDEX_NAME); set QMD_MCP_URL to that index's own port." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  fi
  check_ceiling
  exit 0
fi
if [ -n "$body" ]; then
  echo "ensure-qmd-daemon: ERROR - a process is listening on $QMD_MCP_URL but it is NOT qmd" >&2
  echo "  (the MCP initialize reply has no qmd serverInfo). Port 8181 is taken by another service." >&2
  echo "  Free the port or stop that service, then start a fresh session." >&2
  exit 1
fi

# ---- Remote-model egress gate -----------------------------------------------
# qmd's models are per INDEX, so a denied corpus (salus) must live in its own
# index (QMD_INDEX_NAME=salus -> qmd --index salus, <name>.yml) on local models.
# When this index's config (or the QMD_*_MODEL env) names a remote `openai:`
# model, scripts/qmd/qmd-jina-gate.mjs must allow every collection in it via the
# egress matrix; a missing gate script or node fails closed. A local-only config
# never needs the gate, so the plugin still works outside a himmel checkout.
qmd_cfg="${QMD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd}/$QMD_INDEX_NAME.yml"
remote_models=0
# The provider key is the DAEMON's, never a session's: drop whatever the launching session carries, and
# take the key only from the daemon env file (mode 0600), handed to the daemon start below and nowhere else.
unset QMD_OPENAI_API_KEY JINA_API_KEY JINA_API
provider_key=""
tune_provider="" tune_batch="" tune_conc="" tune_queue=""
# Case-insensitive: OpenAI: / OPENAI: model strings must reach the gate too.
env_models="$(printf '%s' "${QMD_EMBED_MODEL:-}${QMD_RERANK_MODEL:-}${QMD_GENERATE_MODEL:-}" | tr '[:upper:]' '[:lower:]')"
case "$env_models" in *openai:*) remote_models=1 ;; esac
if [ "$remote_models" -eq 0 ] && grep -Eqis '^[^#]*(openai:|\\)' "$qmd_cfg"; then
  remote_models=1
fi
if [ "$remote_models" -eq 1 ]; then
  key_env_file="${QMD_DAEMON_ENV_FILE:-$HOME/.himmel/state/qmd-daemon.env}" # t13b-ok: variable assignment of a file path, starts nothing
  if [ -f "$key_env_file" ]; then
    # shellcheck disable=SC2012  # the mode string is the point; the path is fixed
    case "$(ls -ld "$key_env_file" 2>/dev/null | cut -c1-10)" in
      -rw-------|-r--------) ;;
      *)
        echo "ensure-qmd-daemon: ERROR - $key_env_file holds the provider key but is readable by others - NOT starting qmd (chmod 600 it)." >&2 # t13b-ok: message text only, starts nothing
        exit 1 ;;
    esac
    # Read the one line; never source the file.
    provider_key="$(sed -n 's/^QMD_OPENAI_API_KEY=//p' "$key_env_file" | head -n 1)"
    # The non-secret tuning names, also by line: an allowlist, each value validated before it is exported.
    tune_provider="$(sed -n 's/^QMD_OPENAI_PROVIDER=//p' "$key_env_file" | head -n 1)"
    tune_batch="$(sed -n 's/^QMD_OPENAI_EMBED_BATCH_SIZE=//p' "$key_env_file" | head -n 1)"
    tune_conc="$(sed -n 's/^QMD_OPENAI_EMBED_CONCURRENCY=//p' "$key_env_file" | head -n 1)"
    tune_queue="$(sed -n 's/^QMD_QUERY_MAX_QUEUED=//p' "$key_env_file" | head -n 1)"
  fi
  qmd_gate="${QMD_JINA_GATE:-$(dirname -- "${BASH_SOURCE[0]}")/../../../../scripts/qmd/qmd-jina-gate.mjs}"
  if [ ! -f "$qmd_gate" ] || ! command -v node >/dev/null 2>&1; then
    echo "ensure-qmd-daemon: ERROR - $qmd_cfg names a remote model but the egress gate ($qmd_gate) or node is missing - NOT starting qmd." >&2 # t13b-ok: message text only, starts nothing
    echo "  Run from a himmel checkout (scripts/qmd/qmd-jina-gate.mjs) or switch the models back to local hf: URIs." >&2
    exit 1
  fi
  qmd_db="${INDEX_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/$QMD_INDEX_NAME.sqlite}"
  if ! QMD_GATE_REQUIRE_KEY=1 QMD_OPENAI_API_KEY="$provider_key" node "$qmd_gate" "$qmd_cfg" "$qmd_db" >&2; then
    echo "ensure-qmd-daemon: ERROR - the egress matrix refuses this index's remote model - NOT starting qmd." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  fi
fi

# ---- Embed-model swap in progress: do NOT start --------------
# scripts/luna/qmd-embed-model.sh swap holds this mkdir lock (holder pid inside)
# from its liveness check to its commit or rollback. A daemon started in that
# window serves the OLD model's query embeddings against the NEW vectors (a
# dimension mismatch, or silent garbage when the dimensions match). A lock whose
# pid is dead is stale: clear it and carry on; with no pid file it is stale once
# a minute old. Same path and rule as swap_lock_* in qmd-embed-model.sh, which
# this plugin copy cannot source.
# The start TAKES the lock (released on exit) rather than only checking it: a
# check-then-start leaves a window in which a swap could take the lock and pass
# its own liveness checks. Holding it makes the two mutually exclusive; a swap
# that starts meanwhile is refused, and its final re-check sees a started daemon.
swap_lock="$qmd_state_dir/embed-swap.lock"
swap_lock_stale() {
  local p
  p="$(cat "$1/pid" 2>/dev/null)"
  case "$p" in
    ''|*[!0-9]*) [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] ;;
    *) ! kill -0 "$p" 2>/dev/null ;;
  esac
}
# Clearing a stale lock is itself serialized (a second mkdir lock, "<lock>.reclaim"),
# and staleness is re-checked inside it: two contenders that both saw a dead holder
# must not let the slower one delete the faster one's freshly taken lock. A guard
# a minute old belongs to a reclaimer that died and is cleared.
swap_lock_reclaim() {
  if [ -n "$(find "$swap_lock.reclaim" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$swap_lock.reclaim" 2>/dev/null
  fi
  # prim-ok: the plugin installs without scripts/lib; a one-shot mkdir try-lock serializing the stale clear, a loser just returns
  mkdir "$swap_lock.reclaim" 2>/dev/null || return 0
  if swap_lock_stale "$swap_lock"; then
    rm -rf "$swap_lock"
  fi
  rmdir "$swap_lock.reclaim" 2>/dev/null
  return 0
}
mkdir -p "$qmd_state_dir" 2>/dev/null
# prim-ok: the plugin installs without scripts/lib; the swap lock is held across processes with a role file; a contended start of the same index or an off start exits at once, any other start retries it
if ! mkdir "$swap_lock" 2>/dev/null; then
  swap_pid="$(cat "$swap_lock/pid" 2>/dev/null)"
  if swap_lock_stale "$swap_lock"; then
    swap_lock_reclaim
  fi
  # Contended. WHO holds it decides: role=ensure for this index is another session's start already on
  # it, so this one exits quietly; for another index it is waited out (swap_wait s); role=swap refuses.
  # The index and role files are written before the pid, so a holder with neither is brand new:
  # poll briefly (SessionStart must stay fast); one that never names a role is treated as a swap.
  swap_role=""
  swap_i=0
  swap_max=8
  swap_step=0.25
  while :; do
    swap_role="$(cat "$swap_lock/role" 2>/dev/null)"
    case "$swap_role" in
      ensure)
        swap_holder="$(cat "$swap_lock/index" 2>/dev/null)"
        [ "${swap_holder:-index}" != "$QMD_INDEX_NAME" ] || exit 0
        swap_max="$swap_wait"
        swap_step=1 ;;
      off) exit 0 ;;
      swap) break ;;
    esac
    if swap_lock_stale "$swap_lock"; then swap_lock_reclaim; fi
    # prim-ok: the plugin installs without scripts/lib; a bounded retry of the same swap lock above
    if mkdir "$swap_lock" 2>/dev/null; then swap_role=mine; break; fi
    swap_i=$((swap_i + 1))
    if [ "$swap_i" -ge "$swap_max" ]; then break; fi
    sleep "$swap_step"
  done
  if [ "$swap_role" = ensure ]; then
    echo "ensure-qmd-daemon: ERROR - another index's start has held $swap_lock for ${swap_wait}s; NOT starting the '$QMD_INDEX_NAME' index." >&2 # t13b-ok: message text only, starts nothing
    exit 1
  fi
  if [ "$swap_role" != mine ]; then
    echo "ensure-qmd-daemon: an embed-model swap is in progress (pid ${swap_pid:-unknown}, $swap_lock) - NOT starting the qmd daemon." >&2 # t13b-ok: refusal message text, starts nothing
    echo "  Starting it now would serve queries against a half-swapped index. Retry once the swap finishes;" >&2
    echo "  if that pid is gone, remove the lock directory." >&2
    exit 1
  fi
fi
echo "$QMD_INDEX_NAME" > "$swap_lock/index"
echo ensure > "$swap_lock/role"
echo "$$" > "$swap_lock/pid"
# shellcheck disable=SC2064 # expand now: the lock path is fixed for this run
trap "[ \"\$(cat '$swap_lock/pid' 2>/dev/null)\" = \"$$\" ] && rm -rf '$swap_lock'" EXIT

# ---- Dead: start the daemon ------------------------------------------------
if ! resolve_qmd; then
  echo "ensure-qmd-daemon: ERROR - qmd is not installed / not on PATH." >&2
  echo "  Install it: bash <himmel-repo>/scripts/lib/qmd-bin.sh install" >&2
  exit 1
fi

# A killed daemon can take ~15s to unwind (bun stops 46 threads) before it
# actually releases the port. If the MCP probe above found the endpoint dead
# but a previous daemon is still mid-unwind, racing straight to start here
# would launch a second daemon contending with the first for the same port
# Poll a raw TCP connect - distinct from the qmd-shaped MCP
# probe above, this only asks "is anything listening", not "is it qmd" - and
# wait for the port to fully free before starting. PORT_WAIT_TRIES=15 matches
# the documented ~15s unwind time (common case: each connect attempt below
# resolves near-instantly against a still-held port, so the wait is
# PORT_WAIT_TRIES * 1s of sleeping); a port still held past that still falls
# through to the normal start attempt rather than hanging forever. Each
# connect attempt is itself bounded with timeout(1) when available
# (degrading to an unbounded connect otherwise) so a stalled connect - not
# just a held port - cannot blow the bound either; this only adds to the
# total in the pathological case where every single attempt actually stalls
# (see the worst-case budget in the file header). On a bash build without
# /dev/tcp support, the connect always "fails" and this loop is a silent
# no-op - same behavior as before this fix.
port_host="${QMD_MCP_URL#*://}"
port_host="${port_host%%/*}"
port_num="${port_host##*:}"
port_host="${port_host%%:*}"
[ -z "$url_port_n" ] || port_num="$url_port_n"
port_held() {
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # $1/$2 are the inner bash -c's OWN positional
    # params (bound below), not this shell's - must stay single-quoted.
    timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$port_host" "$port_num" 2>/dev/null
  else
    (exec 3<>"/dev/tcp/$port_host/$port_num") 2>/dev/null
  fi
}
p=0
while [ "$p" -lt "$PORT_WAIT_TRIES" ] && port_held; do
  p=$((p + 1))
  sleep 1
done

# qmd mcp --http --daemon is idempotent: already-running prints
# "Already running (PID N)" and exits 0. Bound the start with timeout(1)
# so a hung qmd/bun start cannot stall SessionStart; when timeout(1) is
# absent (rare platform), degrade to an unbounded start.
# ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} expands to the quoted qmd.js path on the
# bun-js resolution and to NOTHING (no empty argv slot) otherwise.
# The daemon outlives this session, so start it from $HOME: a
# daemon that inherits a worktree cwd pins that worktree ("in use") long after
# its PR merges. A failed cd falls back to the filesystem root, never the
# caller's cwd.
cd "$HOME" 2>/dev/null || cd / || exit 1
# Only a gate-approved remote-model daemon is handed the key.
[ -n "$provider_key" ] && export QMD_OPENAI_API_KEY="$provider_key"
# The daemon env file's tuning follows the same rule; an invalid value is dropped, not exported.
case "$tune_provider" in ''|*[!A-Za-z0-9._-]*) ;; *) export QMD_OPENAI_PROVIDER="$tune_provider" ;; esac
case "$tune_batch" in ''|*[!0-9]*|0*) ;; *) export QMD_OPENAI_EMBED_BATCH_SIZE="$tune_batch" ;; esac
case "$tune_conc" in ''|*[!0-9]*|0*) ;; *) export QMD_OPENAI_EMBED_CONCURRENCY="$tune_conc" ;; esac
case "$tune_queue" in ''|*[!0-9]*|0*) ;; *) export QMD_QUERY_MAX_QUEUED="$tune_queue" ;; esac
start_rc=0
start_marker="$qmd_state_dir/starting$idx_sfx"
# Recheck the opt-out under the held lock, right before the launch: an `off` that
# landed after the early check has set the flag by now, and an `off` after this
# point waits on the lock (qmd-daemon-switch.sh) and then stops what was started.
if [ "${QMD_DAEMON_DISABLED:-}" = "1" ] || [ -e "$QMD_DAEMON_OFF_FLAG" ]; then
  echo "ensure-qmd-daemon: INFO - qmd was turned OFF while this start was in progress; not launching."
  exit 0
fi
# A named index starts its own daemon on the port in QMD_MCP_URL.
idx_flag=""
[ "$QMD_INDEX_NAME" = index ] || idx_flag="$QMD_INDEX_NAME"
date +%s > "$start_marker" 2>/dev/null
if command -v timeout >/dev/null 2>&1; then
  start_out="$(timeout -k 5 "$QMD_START_TIMEOUT" "$QMD_BIN" ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} ${idx_flag:+--index "$idx_flag" --port "$port_num"} mcp --http --daemon 2>&1)" || start_rc=$? # t13b-ok: the idempotent qmd daemon start this script exists for
else
  start_out="$("$QMD_BIN" ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} ${idx_flag:+--index "$idx_flag" --port "$port_num"} mcp --http --daemon 2>&1)" || start_rc=$? # t13b-ok: the idempotent qmd daemon start this script exists for
fi
if [ "$start_rc" -eq 124 ] || [ "$start_rc" -eq 137 ]; then
  echo "ensure-qmd-daemon: ERROR - 'qmd mcp --http --daemon' timed out after ${QMD_START_TIMEOUT}s (killed)." >&2
  echo "  A hung start would stall every new session, so it was bounded and aborted." >&2
  echo "  Check the daemon log: ~/.cache/qmd/$mcp_stem.log" >&2  # t13b-ok: message text only, starts nothing
  rm -f "$start_marker"
  exit 1
fi

i=0
while [ "$i" -lt "$WAIT_TRIES" ]; do
  body="$(probe_body)"
  if { { [ -n "$body" ] && is_qmd_shaped "$body"; } || alive_auth_required; } && index_serves; then
    rm -f "$start_marker"
    exit 0
  fi
  i=$((i + 1))
  if [ "$i" -lt "$WAIT_TRIES" ]; then
    sleep 1
  fi
done

echo "ensure-qmd-daemon: ERROR - started 'qmd mcp --http --daemon' but nothing came alive on $QMD_MCP_URL." >&2
echo "  qmd output was:" >&2
printf '%s\n' "$start_out" | sed 's/^/    /' >&2
if [ -z "${QMD_BIN_ARG1:-}" ]; then
  # Non-bun-js resolution: the daemon was started via '$QMD_BIN' - a
  # node-shebang shim/PATH path, the exact fragile worker a prior fix addressed.
  # Most likely cause: the node-side better-sqlite3 binding is missing.
  echo "  (daemon was started via '$QMD_BIN', not 'bun <qmd.js>' - if node's" >&2
  echo "  better-sqlite3 binding is missing, fix with:" >&2
  echo "  bash <himmel-repo>/scripts/lib/qmd-bin.sh install)" >&2
fi
echo "  Check the daemon log: ~/.cache/qmd/$mcp_stem.log" >&2  # t13b-ok: message text only, starts nothing
exit 1
