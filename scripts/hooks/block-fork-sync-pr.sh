#!/usr/bin/env bash
# PreToolUse hook for Bash.
#
# Syncing one of our forks with its upstream is upkeep, never a PR.
# yotamleo-org/core#3 (100 upstream commits
# into our `dev`), graphify#19 and home-assistant.io#1 were each a
# `gh pr create` whose base was our fork and whose head was the upstream
# branch: a PR that asked the judge and CodeRabbit to review upstream code.
#
# REFUSED: a `gh pr create` whose base repo is a registered fork (a row of
# scripts/guardrails/himmel-adapters.json with a non-null `upstream`) and
#   R1 whose head names another owner (`--head home-assistant:dev`,
#      `--head home-assistant/core:dev`), or
#   R2 whose head is a branch of ours that mostly carries upstream commits
#      (fewer than half of the PR's commits are ahead of the upstream default
#      branch) — a sync PR from a branch we pushed.
# ALLOWED: a PR of our own carried delta, any repo that is not a registered
# fork (himmel itself, first-party repos), every other command.
#
# The base repo is `--repo`/`-R`, else `GH_REPO`, else the `origin` of the
# clone the command runs in (after any `cd`). R2 counts the PR's commits
# against `--base`, else the fork's default branch, with the GitHub compare
# API (`gh api`); a deny names the replacement,
# `bash scripts/upstreams/resync-fork.sh --sync <fork>`.
#
# A workflow guard, not a security fence: it fails OPEN on its own
# infrastructure errors (no python3, unparseable input, gh unreachable) and
# denies only on a positive match (scripts/hooks/CLAUDE.md, failure direction).
# ponytail: sees `gh pr create` only; a raw `gh api .../pulls` POST is not
# parsed, upgrade path = parse gh api POST bodies if one is ever seen.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set FORK_SYNC_PR_OK=1 in the shell that launched the agent.
set -uo pipefail

[ "${FORK_SYNC_PR_OK:-0}" = "1" ] && exit 0

input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read hits EOF on every payload; an empty one misses the prefilter and is allowed

# Cheap prefilter: nothing to do unless the text could hold `gh pr create`.
case "$input" in
    *gh*pr*create*) ;;
    *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

# The cwd's origin is read with git; a redirecting GIT_* var must not steer it.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="${HIMMEL_REPO:-$HOOK_DIR/../..}/scripts/guardrails/himmel-adapters.json"
[ -r "$REGISTRY" ] || exit 0

python3 -I - "$REGISTRY" "$input" <<'PY'
import json, os, re, shlex, subprocess, sys

registry_path, raw = sys.argv[1], sys.argv[2]

def allow():
    sys.exit(0)

try:
    payload = json.loads(raw)
    cmd = payload.get("tool_input", {}).get("command", "")
    cwd = payload.get("cwd") or "."
    rows = json.load(open(registry_path))
except Exception:
    allow()
if not isinstance(cmd, str) or not cmd:
    allow()

forks = {}
for r in rows if isinstance(rows, list) else []:
    if isinstance(r, dict) and r.get("upstream") and r.get("nwo"):
        forks[r["nwo"].lower()] = r

def segments(text):
    """Word lists of each simple command, split on ; & | and newlines."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok and set(tok) <= set(";&|\n"):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg

def pr_create_args(words):
    for i in range(len(words) - 2):
        if words[i].rsplit("/", 1)[-1] == "gh" and words[i + 1] == "pr" and words[i + 2] == "create":
            return words[i + 3:]
    return None

def flags(args):
    out = {}
    names = {"--repo": "repo", "-R": "repo", "--head": "head", "-H": "head",
             "--base": "base", "-B": "base"}
    i = 0
    while i < len(args):
        a = args[i]
        key = val = None
        if "=" in a and a.split("=", 1)[0] in names:
            key, val = names[a.split("=", 1)[0]], a.split("=", 1)[1]
        elif a in names and i + 1 < len(args):
            key, val = names[a], args[i + 1]
            i += 1
        if key:
            out[key] = val
        i += 1
    return out

def git(*a):
    try:
        return subprocess.run(["git", "-C", cwd, *a], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except Exception:
        return ""

def nwo_of_url(url):
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else ""

# At most four gh calls per PR; 4 x 8 s stays inside the Bash chain's 61 s.
GH_TIMEOUT = 8

def gh_ahead(repo, spec):
    try:
        p = subprocess.run(["gh", "api", f"repos/{repo}/compare/{spec}",
                            "--jq", ".ahead_by"], capture_output=True,
                           text=True, timeout=GH_TIMEOUT)
        return int(p.stdout.strip()) if p.returncode == 0 else None
    except Exception:
        return None

def gh_default(repo):
    try:
        p = subprocess.run(["gh", "api", f"repos/{repo}", "--jq",
                            ".default_branch"], capture_output=True,
                           text=True, timeout=GH_TIMEOUT)
        return p.stdout.strip() if p.returncode == 0 else ""
    except Exception:
        return ""

def deny(fork, why):
    sys.stderr.write(
        f"block-fork-sync-pr: refused — {why}.\n"
        f"Syncing {fork['nwo']} with {fork['upstream']} is upkeep, never a PR, a judge "
        "or a CodeRabbit review of upstream code.\n"
        f"  carried commits  → bash scripts/upstreams/resync-fork.sh --sync {fork['nwo']}\n"
        f"  no carried commits → use-upstream: point pins and installs at {fork['upstream']}\n"
        "A PR to a fork carries only our own authored delta. "
        "Bypass: FORK_SYNC_PR_OK=1 in the launching shell.\n")
    sys.exit(2)

try:
    segs = list(segments(cmd))
except ValueError:
    allow()

gh_repo = os.environ.get("GH_REPO", "")
for words in segs:
    # A `cd`/`pushd` earlier in the command moves where origin is read.
    if len(words) >= 2 and words[0] in ("cd", "pushd"):
        cwd = os.path.join(cwd, os.path.expanduser(words[1]))
        continue
    # gh reads its default repo from GH_REPO (a prefix or an earlier export).
    for w in words:
        if w.startswith("GH_REPO="):
            gh_repo = w.split("=", 1)[1]
    args = pr_create_args(words)
    if args is None:
        continue
    f = flags(args)
    base = f.get("repo") or gh_repo or nwo_of_url(git("remote", "get-url", "origin"))
    fork = forks.get(base.lower())
    if not fork:
        continue
    head = f.get("head") or git("rev-parse", "--abbrev-ref", "HEAD")
    if not head or head == "HEAD":
        continue
    owner, branch = "", head
    if ":" in head:
        owner, branch = head.split(":", 1)
        owner = owner.split("/", 1)[0]
    base_owner = fork["nwo"].split("/", 1)[0]
    if owner and owner.lower() != base_owner.lower():
        deny(fork, f"head {head} is another owner's branch into our fork {fork['nwo']}")
    # R2: our own branch — how much of the PR is upstream-authored?
    up = fork["upstream"]
    up_default = gh_default(up)
    if not up_default:
        continue
    ours = gh_ahead(up, f"{up_default}...{base_owner}:{branch}")
    # gh pr create without --base targets the fork's default branch.
    pr_base = f.get("base") or gh_default(fork["nwo"]) or fork["himmel_branch"]
    total = gh_ahead(fork["nwo"], f"{pr_base}...{branch}")
    if ours is None or total is None or total <= 0:
        continue
    if ours * 2 < total:
        deny(fork, f"{total - ours} of {total} commits on {branch} are upstream-authored")
allow()
PY
rc=$?
[ "$rc" = 2 ] && exit 2
exit 0
