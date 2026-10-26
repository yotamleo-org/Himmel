#!/usr/bin/env bash
# selector: tree-scan
# Platform guard (posix-bash): POSIX bash 3.2+, python3.
#
# gen-team-page.sh [--check] [--root <dir>] — build docs/team.md, the "Meet the
# team" page, from the files that define each role. Every card line is
# extracted from its source by an anchor (a sentence holding a phrase, a
# regex capture, an agent's frontmatter `model:`, the critics.json panel), so
# the page changes when the sources do and is never copied by hand.
#
#   (default)  write <root>/docs/team.md
#   --check    write nothing; exit 1 when the committed page differs from the
#              generated one
#   --root     the tree to read and write (default: this checkout)
#
# A role source is any .claude/agents/*.md and any docs/handover/*-preface.md
# that is not a symlink. Each one must be claimed by a card or listed in
# NOT_ROLES with its reason, and each card's claims and anchors must still
# resolve. Either failure means a role has no card, or a card names a role that
# no longer exists: the run exits 1 and names it.
#
# Exit: 0 written or up to date; 1 stale page, unclaimed source, missing
# source or anchor; 2 usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
mode='write'
while [ $# -gt 0 ]; do
    case "$1" in
        --check) mode=check; shift ;;
        --root) [ $# -ge 2 ] || { echo "gen-team-page: --root needs a directory" >&2; exit 2; }; root="$2"; shift 2 ;;
        *) echo "gen-team-page: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -d "$root" ] || { echo "gen-team-page: no such directory: $root" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "gen-team-page: python3 required" >&2; exit 2; }

python3 -I - "$root" "$mode" <<'PY'
import glob, json, os, re, sys

root, mode = sys.argv[1], sys.argv[2]
PAGE = "docs/team.md"

# Role sources that are not a seat in a shift.
NOT_ROLES = {
    ".claude/agents/comment-sicko.md":
        "a tool agent: any session may spawn it to delete comments; it holds no seat in a shift",
    "docs/handover/consult-preface.md":
        "a one-question helper the chief starts when a worker needs a skill its profile lacks; "
        "it answers that worker's question and stops, so it is part of the worker's ask, not a seat",
}

def s(path, anchor):
    return ("s", path, anchor)

def r(path, pattern):
    return ("r", path, pattern)

LANES = "docs/internals/lane-calibration.md"
GLOSSARY = "docs/glossary.md"

ROLES = [
    {
        "title": "The chief",
        "claims": ["docs/handover/chief-template.md"],
        "job": r(GLOSSARY, r"\| \*\*Chief\*\* \[[^\]]*\] \| (The operator's chief of staff: [^.]*\.)"),
        "tier": r(LANES, r"The Opus lane runs \*\*([^*]+)\*\* \(the chief and headed-arm default"),
        "may": [s(GLOSSARY, "It holds the queue lock on its own document"),
                s(GLOSSARY, "It dispatches workers, watches the fleet")],
        "never": [r(GLOSSARY, r"\((`orchestrator-inline-guard`: a top-tier parent must not implement inline)\)")],
        "runs": [r("docs/handover/chief-template.md", r"(you ship from and always run in \*\*`\{\{REPO\}\}`\*\*)")],
    },
    {
        "title": "Workers",
        "claims": ["docs/handover/worker-preface.md",
                   "docs/handover/worker-preface-claudex.md",
                   "docs/handover/worker-preface-openrouter.md"],
        "job": s("docs/handover/worker-preface.md", "You are a worker:"),
        "tier": r(LANES, r"\| (Sonnet [0-9.]+) \| [^|]*?(default implementor for [^|;]*?) \|"),
        "may": [s("docs/handover/worker-preface.md", "Order: commit"),
                s(GLOSSARY, "an implementing worker (implements and ships)")],
        "never": [s("docs/handover/worker-preface.md", "Merge only on the chief's"),
                  s("docs/handover/worker-preface.md", "Never call `AskUserQuestion`")],
        "runs": [r("docs/handover/running-a-chief.md", r"\| Children \| [^|]* \| (headed sessions with their own worktrees and PRs) \|")],
    },
    {
        "title": "The reviewers",
        "claims": ["docs/guide/second-model-review.md"],
        "job": s("docs/guide/second-model-review.md", "Every change is reviewed twice"),
        "tier": ("critics", "scripts/cr/critics.json"),
        "may": [s("docs/guide/second-model-review.md", "Critical and Important findings block"),
                s("docs/guide/second-model-review.md", "reviewer must pass at the pull request's head")],
        "never": [s("docs/guide/second-model-review.md", "zero responders is a missing review")],
        "runs": [s("docs/guide/second-model-review.md", "The install copies in the merge gate's reviewer check"),
                 s("docs/guide/second-model-review.md", "command ships with the himmel checkout")],
    },
    {
        "title": "The judge",
        "claims": [".claude/agents/judge.md", ".claude/agents/judge-ro.md",
                   "docs/handover/judge-preface.md"],
        "job": ("fm", ".claude/agents/judge.md", "description"),
        "tier": ("fm", [".claude/agents/judge.md", ".claude/agents/judge-ro.md"], "model"),
        "may": [s("docs/handover/judge-preface.md", "you read, you verify, you write one verdict, and you stop.")],
        "never": [s("docs/handover/judge-preface.md", "You do not implement, you do not open or push a PR")],
        "runs": [r(GLOSSARY, r"\| judge \*\*session\*\* \| (a judge worker with its own worktree[^|]*?) \|"),
                 r(GLOSSARY, r"\| judge \*\*subagent\*\* \[judge call\] \| (an in-process child) \(")],
    },
    {
        "title": "The release manager",
        "claims": ["docs/handover/rm-preface.md"],
        "job": s("docs/handover/rm-preface.md", "Your job: you rule every placement"),
        "tier": r("scripts/jira/src/commands/release.ts", r"'--model', '([a-z0-9-]+)'"),
        "may": [s("docs/handover/chief-sections/release-manager.md", "STATUS, BURN-DOWN and READY")],
        "never": [s("docs/handover/rm-preface.md", "You do not implement, open or push a PR")],
        "runs": [s("docs/handover/chief-sections/release-manager.md", "No release-manager session waits between batches")],
    },
]

PLACEHOLDERS = {"**`{{REPO}}`**": "the himmel clone"}
OLD_TERMS = [(r"\bconsoles\b", "[chiefs]"), (r"\bconsole\b", "[chief]"),
             (r"\bConsoles\b", "[Chiefs]"), (r"\bConsole\b", "[Chief]"),
             (r"\blegs\b", "[workers]"), (r"\bleg\b", "[worker]"),
             (r"\bLegs\b", "[Workers]"), (r"\bLeg\b", "[Worker]")]

problems = []
texts = {}

def read(path):
    if path not in texts:
        full = os.path.join(root, path)
        try:
            with open(full, encoding="utf-8") as fh:
                texts[path] = fh.read()
        except OSError:
            texts[path] = None
    return texts[path]

def flat(text):
    lines = [re.sub(r"^\s*>\s?", "", ln) for ln in text.splitlines()]
    return lines

def blocks(text):
    out, cur = [], []
    for ln in flat(text):
        if not ln.strip() or re.match(r"\s*(?:[-*]|\d+\.)\s", ln) or ln.startswith("#") or ln.startswith("|"):
            if cur:
                out.append(" ".join(cur))
            cur = [ln.strip()] if ln.strip() else []
        else:
            cur.append(ln.strip())
    if cur:
        out.append(" ".join(cur))
    return out

def sentence(path, anchor):
    text = read(path)
    if text is None:
        problems.append(f"missing source {path}")
        return None
    for block in blocks(text):
        block = re.sub(r"^(?:[-*]|\d+\.)\s+", "", block).replace("**", "")
        for sent in re.split(r"(?<=[.!?])\s+(?=[A-Z`*“\"\[])", block):
            if anchor in sent:
                return sent
    problems.append(f"anchor not found in {path}: {anchor}")
    return None

def capture(path, pattern):
    text = read(path)
    if text is None:
        problems.append(f"missing source {path}")
        return None
    m = re.search(pattern, " ".join(flat(text)))
    if not m:
        problems.append(f"pattern not found in {path}: {pattern}")
        return None
    return ", ".join(m.groups())

def frontmatter(path, key):
    text = read(path)
    if text is None:
        problems.append(f"missing source {path}")
        return None
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    v = m and re.search(rf"^{key}:\s*(.+)$", m.group(1), re.M)
    if not v:
        problems.append(f"no frontmatter {key}: in {path}")
        return None
    return v.group(1).strip()

def critics(path):
    text = read(path)
    if text is None:
        problems.append(f"missing source {path}")
        return None
    rows = []
    for row in json.loads(text).get("panel", []):
        if row.get("model"):
            model = f"`{row['model']}`"
        elif row.get("provider"):
            model = f"provider `{row['provider']}`"
        else:
            problems.append(f"panel row {row.get('slug')} has no model or provider in {path}")
            continue
        rows.append(f"{row['slug']}: {model} ({row.get('mode', 'hard')})")
    if not rows:
        problems.append(f"no panel rows in {path}")
        return None
    return "; ".join(rows)

def clean(text):
    for k, v in PLACEHOLDERS.items():
        text = text.replace(k, v)
    text = re.sub(r"\s*<!--.*?-->", "", text)
    text = re.sub(r"\s*\[(?:enforced: [^\]]*|prose)\]\s*$", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    parts = re.split(r"(`[^`]*`)", text)
    for i in range(0, len(parts), 2):
        p = parts[i].replace("**", "")
        p = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"\1", p)
        for pat, rep in OLD_TERMS:
            p = re.sub(pat, rep, p)
        parts[i] = p
    return "".join(parts).strip()

def extract(spec):
    kind = spec[0]
    if kind == "s":
        v = sentence(spec[1], spec[2])
    elif kind == "r":
        v = capture(spec[1], spec[2])
    elif kind == "fm":
        paths = spec[1] if isinstance(spec[1], list) else [spec[1]]
        vals = [frontmatter(p, spec[2]) for p in paths]
        if any(x is None for x in vals):
            return None
        seen = []
        for x in vals:
            if x not in seen:
                seen.append(x)
        v = ", ".join(seen)
        if spec[2] == "description":
            v = re.split(r"(?<=[.!?])\s+", v)[0]
    else:
        return critics(spec[1])
    return None if v is None else clean(v)

def sources(role):
    paths = list(role["claims"])
    for key in ("job", "tier", "may", "never", "runs"):
        specs = role[key] if isinstance(role[key], list) else [role[key]]
        for spec in specs:
            for p in (spec[1] if isinstance(spec[1], list) else [spec[1]]):
                if p not in paths:
                    paths.append(p)
    return paths

# Every role source is claimed by a card or named in NOT_ROLES.
claimed = {p for role in ROLES for p in role["claims"]}
found = sorted(
    p for p in
    [os.path.relpath(f, root) for f in glob.glob(os.path.join(root, ".claude/agents/*.md"))]
    + [os.path.relpath(f, root) for f in glob.glob(os.path.join(root, "docs/handover/*-preface.md"))]
    if not os.path.islink(os.path.join(root, p))
)
for p in found:
    if p not in claimed and p not in NOT_ROLES:
        problems.append(f"role source with no card: {p} (add a card, or a NOT_ROLES entry with its reason)")
for p in sorted(claimed):
    if not os.path.isfile(os.path.join(root, p)):
        problems.append(f"card names a role source that no longer exists: {p}")

def quote(v):
    return f"“{v}”"

out = [
    "# Meet the team",
    "",
    "Audience: anyone reading a shift board or a morning report who wants to know who made a decision, on which model, and what that role may do.",
    "",
    "You work with one Claude session in your project. When you hand himmel a list of tickets, a few more roles join it. Each card below is built by `scripts/docs/gen-team-page.sh` from the files that define the role, and quotes them; a word in square brackets replaces an older name. Open a card to read it.",
    "",
]
for role in ROLES:
    job = extract(role["job"])
    tier = extract(role["tier"])
    rows = {k: [x for x in (extract(spec) for spec in role[k])] for k in ("may", "never", "runs")}
    if job is None or tier is None or any(x is None for v in rows.values() for x in v):
        continue
    out += [
        "<details>",
        f"<summary>{role['title']}</summary>",
        "",
        f"- **Its job:** {quote(job)}",
        f"- **Model tier:** {tier}",
        f"- **What it may do:** {' '.join(quote(x) for x in rows['may'])}",
        f"- **What it never does:** {' '.join(quote(x) for x in rows['never'])}",
        f"- **Where it runs:** {' '.join(quote(x) for x in rows['runs'])}",
        f"- **Defined in:** {', '.join(f'`{p}`' for p in sources(role))}",
        "",
        "</details>",
        "",
    ]
out += [
    "Not on the team: "
    + "; ".join(f"`{p}` is {why}" for p, why in sorted(NOT_ROLES.items()))
    + ".",
    "",
]
page = "\n".join(out)

if problems:
    for p in problems:
        print(f"gen-team-page: {p}", file=sys.stderr)
    sys.exit(1)

target = os.path.join(root, PAGE)
if mode == "check":
    try:
        with open(target, encoding="utf-8") as fh:
            committed = fh.read()
    except OSError:
        committed = None
    if committed != page:
        print(f"gen-team-page: {PAGE} is {'missing' if committed is None else 'stale'}; run bash scripts/docs/gen-team-page.sh", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if os.path.islink(target):
    print(f"gen-team-page: {PAGE} is a symlink; refusing to write through it", file=sys.stderr)
    sys.exit(1)
with open(target, "w", encoding="utf-8") as fh:
    fh.write(page)
print(f"gen-team-page: wrote {PAGE}")
PY
