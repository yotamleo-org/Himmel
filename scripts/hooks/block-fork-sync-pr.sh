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
# The base repo is `--repo`/`-R` (OWNER/REPO, HOST/OWNER/REPO or a URL), else
# `GH_REPO`, else the clone the command runs in (after any `cd`): its
# `gh repo set-default` remote, else `origin`. scripts/lanes/worker-pr-open.sh,
# which calls gh itself, runs this hook in-script. R2 counts the PR's commits
# against `--base`, else the fork's default branch, with the GitHub compare
# API (`gh api`); a deny names the replacement,
# `bash scripts/upstreams/resync-fork.sh --sync <fork>`.
#
# A workflow guard, not a security fence: it fails OPEN on its own
# infrastructure errors (no python3, unparseable hook JSON, gh unreachable) and
# denies only on a positive match (scripts/hooks/CLAUDE.md, failure direction).
# A command that names `gh pr create` and cannot be parsed is the exception:
# it is refused, since its base repo cannot be read. `bash -c`, `sh -c` and
# `eval` scripts are unwrapped (three levels); heredoc bodies are skipped as data
# unless a shell reads them as its script (`bash <<EOF`, `cat <<EOF | bash`).
# ponytail: sees `gh pr create` only; a raw `gh api .../pulls` POST is not
# parsed, upgrade path = parse gh api POST bodies if one is ever seen.
# ponytail: one unwrap round; xargs, `$(...)` substitution and `python -c` are
# not unwrapped, upgrade path = unwrap that wrapper if one is ever seen.
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
import json, os, re, shlex, subprocess, sys, time

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

HEREDOC = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SHELL_C = re.compile(r"-[a-z]*c[a-z]*")

def feeds_shell(line):
    """True when a shell with no -c word reads the heredoc this line opens as
    its script: `bash <<EOF`, `bash -s <<EOF`, `cat <<EOF | bash`. A line that
    will not parse keeps its body, so the guard still sees it."""
    try:
        for words in segments(line):
            rest = [w for w in words if not re.fullmatch(r"\w+=.*", w)]
            if (rest and rest[0].rsplit("/", 1)[-1] in SHELLS
                    and not any(SHELL_C.fullmatch(w) for w in rest[1:])):
                return True
    except ValueError:
        return True
    return False

def strip_heredocs(text):
    """Drop heredoc bodies (data, not shell) unless a shell reads the body as
    its script: keep each opener line and the commands after its terminator. A
    `<<` with no terminator is not a heredoc, so the text is returned whole."""
    out, pending = [], []
    for line in text.split("\n"):
        if pending:
            tabs, delim, keep = pending[0]
            if (line.lstrip("\t") if tabs else line) == delim:
                pending.pop(0)
            if keep:
                out.append(line)
            continue
        out.append(line)
        keep = bool(HEREDOC.search(line)) and feeds_shell(line)
        pending = [(m.group(1) == "-", m.group(3), keep) for m in HEREDOC.finditer(line)]
    return text if pending else "\n".join(out)

def wrapped_scripts(words):
    """Script texts a wrapper runs as one word: `bash -c '<s>'`, `sh -c`,
    `eval '<s>'`, after any VAR=value prefix."""
    i = 0
    while i < len(words) and re.fullmatch(r"\w+=.*", words[i]):
        i += 1
    rest = words[i:]
    if not rest:
        return
    name = rest[0].rsplit("/", 1)[-1]
    if name == "eval" and len(rest) == 2:
        yield rest[1]
    elif name in SHELLS:
        for j in range(1, len(rest) - 1):
            if SHELL_C.fullmatch(rest[j]):
                yield rest[j + 1]
                break

def commands(text, depth=0):
    """Each simple command in text, then those inside any shell wrapper."""
    for words in segments(text):
        yield words
        if depth < 3:
            for script in wrapped_scripts(words):
                yield from commands(script, depth + 1)

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
        elif a[:2] in ("-R", "-H", "-B") and len(a) > 2:
            # Attached short flag: -Rowner/name (pflag also takes -R=owner/name).
            key, val = names[a[:2]], a[3:] if a[2] == "=" else a[2:]
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

def repo_arg(v):
    """owner/name from gh's repo forms: OWNER/REPO, github.com/OWNER/REPO, a URL."""
    v = v.strip()
    if v.count("/") == 1 and ":" not in v:
        return v
    return nwo_of_url(v)

def default_remote_repo():
    """The repo gh resolves with no --repo: a `gh repo set-default` remote
    (remote.<r>.gh-resolved) wins over origin."""
    for line in git("config", "--get-regexp", r"^remote\..*\.gh-resolved$").splitlines():
        key, _, val = line.partition(" ")
        remote = key[len("remote."):-len(".gh-resolved")]
        if val.strip() == "base":
            return nwo_of_url(git("remote", "get-url", remote))
        return repo_arg(val)
    return nwo_of_url(git("remote", "get-url", "origin"))

# Up to five gh calls share one 12 s budget, inside the 15 s each chain
# member gets (run-hook-with-bash.js DEFAULT_MEMBER_TIMEOUT_MS).
DEADLINE = time.monotonic() + 12

def gh(*a):
    left = DEADLINE - time.monotonic()
    if left <= 0:
        return None
    try:
        return subprocess.run(["gh", *a], capture_output=True, text=True,
                              timeout=left)
    except Exception:
        return None

def gh_compare(repo, spec, jq=".ahead_by"):
    p = gh("api", f"repos/{repo}/compare/{spec}", "--jq", jq)
    return p.stdout.split() if p and p.returncode == 0 else []

def gh_ahead(repo, spec):
    out = gh_compare(repo, spec)
    return int(out[0]) if len(out) == 1 and out[0].isdigit() else None

def gh_default(repo):
    p = gh("api", f"repos/{repo}", "--jq", ".default_branch")
    return p.stdout.strip() if p and p.returncode == 0 else ""

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
    segs = list(commands(strip_heredocs(cmd)))
except ValueError:
    # Cannot be parsed: a command that names gh pr create cannot be checked,
    # so it is refused; anything else is none of this guard's business.
    if not re.search(r"gh\s+pr\s+create", cmd):
        allow()
    sys.stderr.write(
        "block-fork-sync-pr: refused — the command names `gh pr create` but cannot be "
        "parsed, so its base repo cannot be checked against the fork registry.\n"
        "Rewrite it as one plain command (a long body goes in --body-file, not a "
        "quoted argument). Bypass: FORK_SYNC_PR_OK=1 in the launching shell.\n")
    sys.exit(2)

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
    named = f.get("repo") or gh_repo
    base = repo_arg(named) if named else default_remote_repo()
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
    # gh pr create without --base targets the fork's default branch.
    pr_base = f.get("base") or gh_default(fork["nwo"]) or fork["himmel_branch"]
    pr = gh_compare(fork["nwo"], f"{pr_base}...{branch}",
                    "[.ahead_by, .merge_base_commit.sha] | @tsv")
    if len(pr) != 2 or not pr[0].isdigit():
        continue
    total, mb = int(pr[0]), pr[1]
    # Ours in the PR = our commits on the branch minus those already at the
    # merge-base, so carried commits the base holds do not count.
    up_ref = f"{up.split('/', 1)[0]}:{up_default}"
    ours_head = gh_ahead(fork["nwo"], f"{up_ref}...{branch}")
    ours_base = gh_ahead(fork["nwo"], f"{up_ref}...{mb}")
    if ours_head is None or ours_base is None or total <= 0:
        continue
    ours = max(ours_head - ours_base, 0)
    if ours * 2 < total:
        deny(fork, f"{total - ours} of {total} commits on {branch} are upstream-authored")
allow()
PY
rc=$?
[ "$rc" = 2 ] && exit 2
exit 0
