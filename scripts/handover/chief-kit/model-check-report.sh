#!/usr/bin/env bash
# Worker-run, optional evidence for a lock/succession PR; never a GO or a substitute for review.
# Prepared models and the pinned upstream /statechart compiler stay outside this repo.
# Exit: 0 bounded checks hold; 1 counterexample; 2 error/incomplete; 3 Java absent (off).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
usage() {
    echo 'usage: model-check-report.sh <pr> <queue-lock|succession-tracker> <spec.tla> <view.mjs>' >&2
    exit 2
}
error() { printf 'model-check-report: %s\n' "$*" >&2; exit 2; }
# Bind both gh lookups and the git source read to this checkout, not caller scratch.
cd "$REPO" || error 'cannot enter repository'
# prim-ok: canon_path handles directories, not existing file leaves or Java symlinks.
existing_file() { realpath -e "$1"; }
# shellcheck source=../../lib/prim.sh
[ -r "$HERE/../../lib/prim.sh" ] || error 'missing primitives'
. "$HERE/../../lib/prim.sh" || error 'cannot load primitives'
# shellcheck source=../../lib/git-clean.sh
[ -r "$HERE/../../lib/git-clean.sh" ] || error 'missing git environment scrubber'
. "$HERE/../../lib/git-clean.sh" || error 'cannot load git environment scrubber'
git_env_scrub
[ "$#" -eq 4 ] || usage
pr="$1"; target="$2"; spec="$3"; view="$4"
case "$pr" in ''|0|*[!0-9]*) usage ;; esac
case "$target" in
    queue-lock) source_path=scripts/handover/queue-lock.sh ;;
    succession-tracker) source_path=scripts/handover/chief-kit/succession-tracker.sh ;;
    *) usage ;;
esac
java="$(command -v "${JAVA:-java}")" || java=""
if [ -z "$java" ] || [ ! -x "$java" ]; then
    echo 'model-check-report: not run; optional Java is absent. Install OpenJDK 21 (Ubuntu: sudo apt install openjdk-21-jre-headless; Arch: sudo pacman -S jre21-openjdk), then retry. No automatic install.' >&2
    exit 3
fi
# Verify bytes BEFORE invoking either Java or the compiler. No download/install fallback.
jar="${TLA2TOOLS:-}"
[ -f "$jar" ] || error 'set TLA2TOOLS to an external tla2tools.jar v1.7.4 (sha256-checked)'
work="$(tmpdir)" || error 'cannot create private tool directory'
trap 'rm -rf "$work"' EXIT
cp "$jar" "$work/tla2tools.jar" || error 'cannot snapshot TLC jar'
sha=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
actual="$(sha256sum "$work/tla2tools.jar")" || error 'cannot hash TLC jar'
[ "${actual%% *}" = "$sha" ] || error 'tla2tools.jar sha256 mismatch; expected v1.7.4, nothing executed'
runner="$(existing_file "${STATECHART:-}")" || error 'set STATECHART to the pinned statechart executable (cursor/plugins 4dd1d058)'
[ -x "$runner" ] || error 'STATECHART is not executable'
jar="$(existing_file "$jar")" || error 'missing TLC jar'
case "$jar" in "$REPO"/*) error 'TLC must stay outside the repo' ;; esac
spec="$(existing_file "$spec")" || error 'missing model'
view="$(existing_file "$view")" || error 'missing view'
case "$spec" in *.tla) ;; *) error 'model must end in .tla' ;; esac
cfg="${spec%.tla}.cfg"
[ -f "$cfg" ] || error 'model needs an adjacent .cfg with fixed small constants (at most 4 busy-loop steps)'
for input in "$spec" "$view"; do
    case "$input" in "$REPO"/*) error 'write the model and view in external scratch, not the repo' ;; esac
done
for cmd in timeout python3 jq gh; do command -v "$cmd" >/dev/null || error "missing $cmd"; done
# Resolve the normal state bucket, never a cwd-relative handovers directory.
# shellcheck source=../../lib/load-dotenv.sh
[ -r "$HERE/../../lib/load-dotenv.sh" ] || error 'missing dotenv resolver'
. "$HERE/../../lib/load-dotenv.sh" || error 'cannot load dotenv resolver'
# shellcheck source=../../lib/handover-path.sh
[ -r "$HERE/../../lib/handover-path.sh" ] || error 'missing handover resolver'
. "$HERE/../../lib/handover-path.sh" || error 'cannot load handover resolver'
# shellcheck source=../../lib/user-slug.sh
[ -r "$HERE/../../lib/user-slug.sh" ] || error 'missing user resolver'
. "$HERE/../../lib/user-slug.sh" || error 'cannot load user resolver'
load_dotenv --root "$(_load_dotenv_primary_for "$REPO")" HANDOVER_DIR USER_SLUG || error 'cannot resolve state environment'
root="$(handover_root)" || error 'cannot resolve handover root'
slug="$(user_slug)" || error 'cannot resolve user slug'
case "$slug" in ''|.|..|*[!A-Za-z0-9_.-]*) error 'unsafe user slug' ;; esac
metadata="$(timeout -k 5s 30s gh pr view "$pr" --json headRefOid,files)" || error 'cannot read PR head and files'
head="$(printf '%s' "$metadata" | jq -er '.headRefOid | select(test("^[0-9a-f]{40}$"))')" || error 'invalid PR head'
printf '%s' "$metadata" | jq -e --arg p "$source_path" '.files | any(.path == $p)' >/dev/null || error "PR does not touch $source_path"
# The chief ensures this commit is locally available; this step never fetches a ref.
git show "$head:$source_path" > "$work/source.sh" || error 'PR head object unavailable; chief must make it available first'
bucket="$root/$slug/himmel/model-check"
# Refuse a symlink in any existing output component before mkdir or write.
p="$bucket"
while [ "$p" != / ]; do [ ! -L "$p" ] || error "symlink output component: $p"; p="$(dirname "$p")"; done
mkdir -p "$bucket" || error 'cannot create report bucket'
# prim-ok: durable evidence needs a PR/head-prefixed name in its bucket, not a generic scratch tmpdir.
run="$(mktemp -d "$bucket/pr-$pr-$head-$target.XXXXXX")" || error 'cannot create report directory'
mkdir "$run/inputs" || error 'cannot create input directory'
cp "$spec" "$run/inputs/$(basename "$spec")" || error 'cannot snapshot model'
cp "$cfg" "$run/inputs/$(basename "$cfg")" || error 'cannot snapshot config'
cp "$view" "$run/inputs/view.mjs" || error 'cannot snapshot view'
cp "$work/source.sh" "$run/inputs/source.sh" || error 'cannot snapshot source'
# Every SANY/TLC JVM gets its own wall-clock and heap limit, including reruns and drawing.
# A separate whole-command limit bounds the upstream rerun loop; no mise fallback is possible.
java="$(existing_file "$java")" || error 'cannot resolve Java executable'
limit="$(command -v timeout)" || error 'missing timeout'
{
    printf '#!/usr/bin/env bash\nexec %q -k 5s 60s %q -Xmx512m -XX:ActiveProcessorCount=2 "$@"\n' "$limit" "$java"
} > "$work/java" || error 'cannot write bounded Java wrapper'
chmod +x "$work/java" || error 'cannot prepare bounded Java wrapper'
rc=0
JAVA="$work/java" TLA2TOOLS="$work/tla2tools.jar" timeout -k 10s 300s "$runner" \
    "$run/inputs/$(basename "$spec")" --config "$run/inputs/$(basename "$cfg")" \
    --view "$run/inputs/view.mjs" --out "$run/output" > "$run/runner.log" 2>&1 || rc=$?
# Never label a killed/errored run clean, and retain its log for the judge.
if [ "$rc" -gt 1 ] || [ ! -s "$run/output/report.md" ]; then
    printf 'Model checking did not complete; no bug or shortest path can be ruled out.\n\nPR: #%s\nHead: %s\nTarget: %s\nRunner exit: %s\nSee runner.log.\n' "$pr" "$head" "$source_path" "$rc" > "$run/report.md"
    printf 'model-check-report: incomplete: %s\n' "$run/report.md" >&2
    exit 2
fi
# State/step text already came from this run's view, not a canned bug description.
if ! python3 -I - "$run" "$pr" "$head" "$source_path" <<'PY'
import pathlib, re, sys
run, pr, head, target = sys.argv[1:]
p = pathlib.Path(run)
text = (p / 'output/report.md').read_text()
bugs = list(re.finditer(r'^## ([^\n]+) breaks\n(.*?)(?=^## |\Z)', text, re.M | re.S))
if bugs:
    bug = bugs[0]
    steps = re.findall(r'^\d+\. (.+)$', bug[2], re.M)
    if steps and 'The shortest path has ' in bug[2]:
        sentence = f'{bug[1]} breaks; the shortest path is ' + ' → '.join(steps) + '.'
    else:
        sentence = f'{bug[1]} breaks; the shortest path is unavailable, so read the TLC counterexample before ruling.'
elif '## Rules not checked' in text or '## TLC stopped' in text:
    sentence = 'Model checking is incomplete; no bug or shortest path can be ruled out.'
else:
    sentence = 'No bug was found in this bounded model; there is no counterexample path.'
header = (f'{sentence}\n\nPR: #{pr}\nHead: {head}\nTarget: `{target}`\n'
          'Evidence only: a clean report never replaces the judge (HIMMEL-8273).\n'
          'Limits: 512 MiB heap, 60 seconds per JVM, 300 seconds total; '
          'model constants and fidelity require judge review.\n\n')
config = next((p / 'inputs').glob('*.cfg')).read_text()
(p / 'report.md').write_text(header + '## Model configuration\n\n```\n' + config + '```\n\n' + text)
PY
then
    error "cannot format report; inspect $run/runner.log"
fi
chart=none
if [ -s "$run/output/chart.mmd" ]; then
    cp "$run/output/chart.mmd" "$run/chart.mmd" || error 'cannot retain chart'
    chart="$run/chart.mmd"
fi
latest="$(timeout -k 5s 30s gh pr view "$pr" --json headRefOid --jq .headRefOid)" || error "cannot recheck PR head; report is not current: $run/report.md"
[ "$latest" = "$head" ] || error "PR head changed; discard this stale report: $run/report.md"
printf 'model-check-report: report=%s chart=%s head=%s exit=%s\n' "$run/report.md" "$chart" "$head" "$rc"
if grep -Eq '^## (Rules not checked|TLC stopped)' "$run/report.md"; then exit 2; fi
exit "$rc"
