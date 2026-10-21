#!/usr/bin/env bash
# register-state.sh — the single writer of ~/.claude/handover/registry.json.
#
# Shared by the handover skill's `init` / `register` / `repos add` flows
# (marketplace/plugins/handover/skills/handover/references/init-register.md)
# and the himmelctl install wizard (external handover mode), so neither carries
# a parallel registry implementation.
#
# bash 3.2-safe; bash + node only.
#
# Usage:
#   register-state.sh --repo-path <abs git repo> --state-host <abs dir>
#                     [--name <kebab>] [--user <slug>] [--bucket-name <slug>]
#                     [--registry <file>] [--init] [--check]
#
#   --repo-path   the code repo being tracked (registry `path`)
#   --state-host  the handover state root host (HANDOVER_DIR, or <repo>/handovers);
#                 state lives in <state-host>/<user>/
#   --name        registry key (default: slugified basename of --repo-path)
#   --user        default: user_slug (scripts/lib/user-slug.sh)
#   --bucket-name default: slugified basename of --repo-path
#   --registry    default: ${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}
#   --init        also bootstrap <state-host>/<user>/ (dirs, _templates, status.md,
#                 backlog.md, counter.md); refused when it already holds .md files
#   --init-if-empty  like --init, but only when <state-host>/<user>/ holds no .md files
#   --check       read-only: exit 0 if --repo-path is already registered, else 3
#
# Idempotent: the same path under the same name is a no-op (rc 0).
#
# Exit codes:
#   0  registered (or already registered / --check hit)
#   1  usage / input error
#   2  refused (collision, missing templates, unreadable registry, non-empty init)
#   3  --check: not registered
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub

REPO_PATH=""; STATE_HOST=""; NAME=""; USER_ARG=""; BUCKET=""; REG=""; DO_INIT=0; DO_INIT_IF_EMPTY=0; DO_CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-path)    REPO_PATH="${2:-}"; shift 2 ;;
        --state-host)   STATE_HOST="${2:-}"; shift 2 ;;
        --name)         NAME="${2:-}"; shift 2 ;;
        --user)         USER_ARG="${2:-}"; shift 2 ;;
        --bucket-name)  BUCKET="${2:-}"; shift 2 ;;
        --registry)     REG="${2:-}"; shift 2 ;;
        --init)         DO_INIT=1; shift ;;
        --init-if-empty) DO_INIT_IF_EMPTY=1; shift ;;
        --check)        DO_CHECK=1; shift ;;
        *) echo "ERR register-state: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$REPO_PATH" ] || { echo "ERR register-state: --repo-path is required" >&2; exit 1; }
REG="${REG:-${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}}"

# shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not a quote escape
canon() { (cd "$1" && pwd | tr '\\' '/'); }
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }

[ -d "$REPO_PATH" ] || { echo "ERR register-state: repo path does not exist: $REPO_PATH" >&2; exit 1; }
REPO_PATH="$(canon "$REPO_PATH")"

# rc 0 = registered, 3 = not registered, 2 = registry unreadable.
reg_has_path() {
    [ -f "$REG" ] || return 3
    REG="$REG" RP="$REPO_PATH" node -e '
      const fs=require("fs"), e=process.env;
      let j; try{ j=JSON.parse(fs.readFileSync(e.REG,"utf8")); }catch(err){ console.error("ERR register-state: registry parse error: "+err.message); process.exit(2); }
      const n=(s)=>String(s||"").replace(/\\/g,"/").replace(/\/+$/,"").toLowerCase();
      for(const k of Object.keys((j&&j.repos)||{})) if(n(j.repos[k].path)===n(e.RP)) process.exit(0);
      process.exit(3);'
}

if [ "$DO_CHECK" -eq 1 ]; then
    rc=0; reg_has_path || rc=$?
    exit "$rc"
fi

[ -n "$STATE_HOST" ] || { echo "ERR register-state: --state-host is required" >&2; exit 1; }
[ -d "$STATE_HOST" ] || { echo "ERR register-state: state host does not exist: $STATE_HOST" >&2; exit 1; }
git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERR register-state: not a git repo: $REPO_PATH" >&2; exit 1; }
STATE_HOST="$(canon "$STATE_HOST")"

USER_ARG="${USER_ARG:-${USER_SLUG:-}}"  # user_slug's own first precedence; skips the forge lookup chain
if [ -z "$USER_ARG" ]; then
    # shellcheck source=../lib/user-slug.sh
    . "$SCRIPT_DIR/../lib/user-slug.sh"
    USER_ARG="$(user_slug)" || { echo "ERR register-state: cannot resolve user slug; pass --user or set USER_SLUG" >&2; exit 2; }
fi
case "$USER_ARG" in *[!A-Za-z0-9._-]*|.|..) echo "ERR register-state: user slug must be [A-Za-z0-9._-]: $USER_ARG" >&2; exit 1 ;; esac
NAME="${NAME:-$(slugify "$(basename "$REPO_PATH")")}"
BUCKET="${BUCKET:-$(slugify "$(basename "$REPO_PATH")")}"
case "$BUCKET" in ''|*[!a-z0-9-]*) echo "ERR register-state: bucket name must be kebab-case: $BUCKET" >&2; exit 1 ;; esac
case "$NAME" in ''|*[!a-z0-9-]*) echo "ERR register-state: name must be kebab-case: $NAME" >&2; exit 1 ;; esac
[ "${#NAME}" -le 30 ] || { echo "ERR register-state: name longer than 30 chars: $NAME" >&2; exit 1; }

STATE_ROOT="$STATE_HOST/$USER_ARG"

# Serialise validate + write across concurrent registrations (mkdir is atomic).
mkdir -p "$(dirname "$REG")"
LOCK="$REG.lock"
tries=0
# prim-ok: a 10 s bounded wait ending in an explicit busy error naming the lock; with_lock waits without limit
until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || { echo "ERR register-state: registry lock busy: $LOCK (remove it if no other registration is running)" >&2; exit 2; }
    sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Validate against the registry BEFORE any disk write (collisions leave no
# partial state). Prints "noop" when the same path+name is already registered.
verdict="$(REG="$REG" RP="$REPO_PATH" NAME="$NAME" BUCKET="$BUCKET" node -e '
  const fs=require("fs"), e=process.env;
  let j={repos:{}};
  if(fs.existsSync(e.REG)){ try{ j=JSON.parse(fs.readFileSync(e.REG,"utf8")); }catch(err){ console.error("ERR register-state: registry parse error: "+err.message); process.exit(2); } }
  const repos=(j&&j.repos)||{};
  const n=(s)=>String(s||"").replace(/\\/g,"/").replace(/\/+$/,"").toLowerCase();  // same fold as the registry readers (resolve-active-item.sh, resume.sh)
  for(const k of Object.keys(repos)){
    const samePath=n(repos[k].path)===n(e.RP);
    if(samePath&&k===e.NAME){ console.log("noop"); process.exit(0); }
    if(samePath){ console.error("ERR register-state: path already registered under name \x27"+k+"\x27"); process.exit(2); }
    if(k===e.NAME){ console.error("ERR register-state: name \x27"+k+"\x27 already registered for a different path"); process.exit(2); }
    const b=repos[k].bucket_name||String(n(repos[k].path).split("/").pop());
    if(b===e.BUCKET){ console.error("ERR register-state: bucket_name \x27"+e.BUCKET+"\x27 already used by repo \x27"+k+"\x27; pass --bucket-name=<unique> to disambiguate."); process.exit(2); }
  }
  console.log("ok");')" || exit $?

if [ "$verdict" = "noop" ]; then
    echo "OK register-state: '$NAME' already registered at $REPO_PATH"
    exit 0
fi

if [ "$DO_INIT_IF_EMPTY" -eq 1 ] && [ "$DO_INIT" -eq 0 ]; then
    if [ ! -d "$STATE_ROOT" ] || [ -z "$(find "$STATE_ROOT" -name '*.md' -type f -print -quit)" ]; then DO_INIT=1; fi
fi

if [ "$DO_INIT" -eq 1 ]; then
    if [ -d "$STATE_ROOT" ] && [ -n "$(find "$STATE_ROOT" -name '*.md' -type f -print -quit)" ]; then
        echo "ERR register-state: $STATE_ROOT already holds .md files; register the existing state without --init" >&2
        exit 2
    fi
    TPL="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/templates}"
    [ -d "${TPL:-}" ] || TPL="$SCRIPT_DIR/../../marketplace/plugins/handover/templates"
    [ -d "$TPL" ] || { echo "ERR register-state: handover templates not found ($TPL); reinstall the handover plugin" >&2; exit 2; }
    mkdir -p "$STATE_ROOT/epics" "$STATE_ROOT/standalones" "$STATE_ROOT/_templates"
    cp "$TPL"/*.md "$STATE_ROOT/_templates/"
    today="$(date +%F)"
    printf '# Handover Status — %s @ %s\n\n> Auto-regenerated by Claude. Do not edit manually.\n> Last updated: %s\n\n## Summary\n\n0 epic(s) | 0 standalone(s) | 0 open bugs | 0 blocked\n\n## Epics\n\n_none yet_\n\n## Standalones\n\n_none yet_\n' "$USER_ARG" "$NAME" "$today" > "$STATE_ROOT/status.md"
    printf '# Backlog — %s @ %s\n\n_Unprioritised future work. Promote to epic/standalone when ready._\n' "$USER_ARG" "$NAME" > "$STATE_ROOT/backlog.md"
    printf '# Counter — %s @ %s\n\nNext: 1\n' "$USER_ARG" "$NAME" > "$STATE_ROOT/counter.md"
fi

# Atomic registry write: temp file in the registry's own dir, then rename.
mkdir -p "$(dirname "$REG")"
REG="$REG" RP="$REPO_PATH" NAME="$NAME" BUCKET="$BUCKET" USR="$USER_ARG" node -e '
  const fs=require("fs"), e=process.env;
  let j={repos:{}};
  if(fs.existsSync(e.REG)) j=JSON.parse(fs.readFileSync(e.REG,"utf8"));
  if(!j.repos) j.repos={};
  j.repos[e.NAME]={path:e.RP,user:e.USR,aliases:[e.NAME],keywords:[],branch_prefix:"handover/",bucket_name:e.BUCKET,bucket_vocab:"time-horizon",defaults:{},stale_thresholds_days:{warming:30,stale:60,zombie:90}};
  const tmp=e.REG+".tmp."+process.pid;
  fs.writeFileSync(tmp,JSON.stringify(j,null,2)+"\n");
  fs.renameSync(tmp,e.REG);'
echo "OK register-state: registered '$NAME' at $REPO_PATH (state: $STATE_ROOT)"
