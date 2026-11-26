#!/usr/bin/env bash
# trust-refusal-sample.sh - the refusal sampler of the 24-hour trust run (plan section 7 of the 24-hour trust run plan, sampler 3).
# READ-ONLY: it prints one JSON row per refusal in a window and writes nothing (no Jira, status, version,
# launch, ledger or doc).
#
#   trust-refusal-sample.sh [--projects DIR]... [--denials FILE] [--launch-refusals FILE] [--bucket DIR]
#                           [--friction PATH] [--since ISO] [--now ISO]
#
# Row: {ts, kind, source, reason, verdict}, in time order, window [--since, --now) (--since defaults to one hour
# before --now: the plan reads the event sources hourly).
#   kind     launch (a launch or a brief refused), merge (a refusal whose source or class names a merge),
#            command (every other hook, gate, classifier or permission refusal)
#   source   hook:<name>, gate:<name>, classifier, permission-prompt, ... as friction.py names it; launch:<cause>
#            for a `launch-refusals.jsonl` row with outcome refused; front-matter for a brief-lint front-matter refusal
#   reason   the reason tag: friction.py's class slug, a launch row's stated reason, or the front-matter line.
#            NEVER command text: the transcript snippet, input_head and the refused command are not read out.
#   verdict  real (friction.py true-positive), false (friction.py over-deny), unsorted (every other row, every
#            launch and merge refusal: sorted by hand in the record)
# Sources: friction.py's per-refusal scan of the transcripts of both lanes (hook, gate, classifier, prompts),
# classifier-denials.jsonl, launch-refusals.jsonl rows with outcome refused, and front-matter-refusals.jsonl in
# --bucket. A refusal found in two of them is ONE row: a classifier denial (same session, same reason tag, within
# 120 s) in a transcript and in the denial log; a brief-lint launch refusal and the front-matter refusal of the same
# brief within 120 s. Two refusals of one source stay two rows.
#
# An unreadable source prints `UNKNOWN <what>` (transcripts, classifier-denials, launch-refusals, bucket,
# front-matter-refusals) and exits 3 with no row, never a list that may have lost a refusal. A missing
# front-matter-refusals.jsonl is no refusal (brief-lint creates it on the first one); a missing denial log or
# launch record is unread. Exit 2 usage.
#
# Defaults: --projects ~/.claude/projects and ~/.claude-codex/projects (at least one must exist),
# --denials ~/.himmel/state/classifier-denials.jsonl (HIMMEL_CLASSIFIER_DENIALS_LOG), --launch-refusals
# ~/.himmel/launch-refusals.jsonl, --bucket the handover bucket (handover_root, user_slug and the primary checkout name), --friction the
# scripts/eval/friction/friction.py beside this repo's chief kit.
#
# PLATFORM GUARD: the chief kit is Linux-only. Needs python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf 'usage: trust-refusal-sample.sh [--projects DIR]... [--denials FILE] [--launch-refusals FILE] [--bucket DIR] [--friction PATH] [--since ISO] [--now ISO]\n' >&2
    exit 2
}

default_bucket() {
    # shellcheck source=../../lib/load-dotenv.sh
    . "$HERE/../../lib/load-dotenv.sh" || return 1
    # shellcheck source=../../lib/user-slug.sh
    . "$HERE/../../lib/user-slug.sh" || return 1
    # shellcheck source=../../lib/git-clean.sh
    . "$HERE/../../lib/git-clean.sh" || return 1
    # shellcheck source=../../lib/handover-path.sh
    . "$HERE/../../lib/handover-path.sh" || return 1
    local top primary common root slug
    top="$(cd "$HERE/../../.." && pwd)" || return 1
    primary="$(_load_dotenv_primary_for "$top")" || return 1
    load_dotenv --root "$primary" HANDOVER_DIR USER_SLUG || return 1
    root="$(handover_root)" || return 1
    slug="$(cd "$top" && user_slug)" || return 1
    common="$(cd "$top" && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir)" || return 1
    printf '%s/%s/%s\n' "$root" "$slug" "$(basename "$(dirname "$common")")"
}

projects=()
denials="${HIMMEL_CLASSIFIER_DENIALS_LOG:-$HOME/.himmel/state/classifier-denials.jsonl}"
launch="$HOME/.himmel/launch-refusals.jsonl"
bucket=""
friction="$HERE/../../eval/friction/friction.py"
since=""
now=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --projects) [ "$#" -ge 2 ] || usage; projects+=("$2"); shift 2 ;;
        --denials) [ "$#" -ge 2 ] || usage; denials="$2"; shift 2 ;;
        --launch-refusals) [ "$#" -ge 2 ] || usage; launch="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; bucket="$2"; shift 2 ;;
        --friction) [ "$#" -ge 2 ] || usage; friction="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || usage; since="$2"; shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ "${#projects[@]}" -gt 0 ] || projects=("$HOME/.claude/projects" "$HOME/.claude-codex/projects")
[ -n "$bucket" ] || bucket="$(default_bucket)" || bucket=""
[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # gnu-ok: chief kit is Linux-only

unknown=()
existing=""
for p in "${projects[@]}"; do
    if [ -d "$p" ] && [ -r "$p" ]; then existing="$existing$p
"; fi
done
[ -n "$existing" ] && [ -r "$friction" ] || unknown+=("transcripts")
{ [ -f "$denials" ] && [ -r "$denials" ]; } || unknown+=("classifier-denials")
{ [ -f "$launch" ] && [ -r "$launch" ]; } || unknown+=("launch-refusals")
{ [ -d "$bucket" ] && [ -r "$bucket" ]; } || unknown+=("bucket")
fm="$bucket/front-matter-refusals.jsonl"
if [ -e "$fm" ] && ! { [ -f "$fm" ] && [ -r "$fm" ]; }; then unknown+=("front-matter-refusals"); fi
if [ "${#unknown[@]}" -gt 0 ]; then
    for u in "${unknown[@]}"; do printf 'UNKNOWN %s\n' "$u"; done
    exit 3
fi

read -r -d '' PY <<'PYEOF' || true  # swallow-ok: read -d '' exits 1 at the end of the heredoc
import datetime, importlib.util, json, os, re, sys

DEDUP_S = 120
VERDICT = {'true-positive': 'real', 'over-deny': 'false'}


def utc(s):
    return datetime.datetime.fromisoformat(str(s).replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


def slug(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')


def stem(path):
    b = os.path.basename(str(path or ''))
    return b[:-3] if b.endswith('.md') else b


now = utc(os.environ['TR_NOW'])
since = utc(os.environ['TR_SINCE']) if os.environ['TR_SINCE'] else now - datetime.timedelta(hours=1)


def jsonl(path):
    with open(path, encoding='utf-8') as fh:
        for ln in fh:
            try:
                r = json.loads(ln)
                ts = utc(r['ts'])
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            if isinstance(r, dict) and since <= ts < now:
                yield r, ts


spec = importlib.util.spec_from_file_location('friction', os.environ['TR_FRICTION'])
fr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fr)
unread = []
tx = fr.scan_all([p for p in os.environ['TR_PROJECTS'].split('\n') if p], since, now, unread)
if unread:
    print('UNKNOWN transcripts')
    sys.exit(3)

rows = []
transcript_classifier = []
for r in tx:
    if r['source'] == 'ci-wait':
        continue
    ts = utc(r['ts'])
    kind = 'merge' if 'merge' in (r['source'] + r['class']).lower() else 'command'
    verdict = 'unsorted' if kind == 'merge' else VERDICT.get(r['verdict'], 'unsorted')
    row = dict(ts=ts, kind=kind, source=r['source'], reason=r['class'], verdict=verdict)
    rows.append(row)
    if r['source'] == 'classifier':
        transcript_classifier.append((r['session'], r['class'], ts, row))

used = set()
for r, ts in jsonl(os.environ['TR_DENIALS']):
    tag = re.sub(r'^\[|\]$', '', str(r.get('reason_tag') or 'unknown'))
    cls = 'classifier-' + slug(tag)
    twin = [t for t in transcript_classifier if id(t[3]) not in used and t[0] == r.get('session_id') and t[1] == cls
            and abs((t[2] - ts).total_seconds()) <= DEDUP_S]
    if twin:
        used.add(id(twin[0][3]))
        continue
    rows.append(dict(ts=ts, kind='command', source='classifier', reason=cls, verdict='unsorted'))

brief_lint = []
for r, ts in jsonl(os.environ['TR_LAUNCH']):
    if r.get('outcome') != 'refused':
        continue
    cause = str(r.get('cause') or 'unknown')
    row = dict(ts=ts, kind='launch', source='launch:' + cause, reason=str(r.get('reason') or cause), verdict='unsorted')
    rows.append(row)
    if cause == 'brief-lint':
        brief_lint.append([stem(r.get('name') or r.get('doc')), ts, False])

fm = os.environ['TR_FRONT_MATTER']
if os.path.isfile(fm):
    for r, ts in jsonl(fm):
        twin = [x for x in brief_lint if not x[2] and x[0] == stem(r.get('brief')) and abs((x[1] - ts).total_seconds()) <= DEDUP_S]
        if twin:
            twin[0][2] = True
            continue
        rows.append(dict(ts=ts, kind='launch', source='front-matter', verdict='unsorted',
                         reason='brief front matter did not parse (line %s)' % r.get('line', '?')))

for row in sorted(rows, key=lambda x: x['ts']):
    row['ts'] = row['ts'].strftime('%Y-%m-%dT%H:%M:%SZ')
    print(json.dumps(dict(ts=row['ts'], kind=row['kind'], source=row['source'], reason=row['reason'], verdict=row['verdict'])))
PYEOF

TR_NOW="$now" TR_SINCE="$since" TR_FRICTION="$friction" TR_PROJECTS="$existing" TR_DENIALS="$denials" TR_LAUNCH="$launch" \
    TR_FRONT_MATTER="$fm" python3 -I -c "$PY" || {
    rc=$?
    [ "$rc" -eq 3 ] || printf 'UNKNOWN sampler-error\n'
    exit 3
}
