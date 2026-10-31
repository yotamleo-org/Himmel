#!/usr/bin/env bash
# scripts/eval/review-panel/run.sh - one review-panel recall sweep.
# Lints the fixture set, feeds each frozen diff to critic-panel.sh on stdin from
# an empty scratch dir outside any git checkout (the critic sees the diff and
# nothing else: never the key, never this repo), then scores the outputs with
# score.py and appends one eval-runs row.
#
# usage: run.sh --out <dir> [--fixtures <dir>] [--key <file>] [--tiers <t>]
#               [--critics a,b] [--only case-01,...] [--meta-json <json>]
#               [--ledger <path> | --no-ledger] [--model <m>]
#   --tiers    CRITIC_PANEL_TIERS for the panel (default paid: the codex row).
#   --model    the critic model, recorded on the row and in its config.
#   --critics  critic slugs to report even when they file nothing (default:
#              the critics.json rows in --tiers).
#
#   --src      the repo real cases' base and fix commits live in (default this checkout).
#
#        run.sh --case-repo <case-id> --out <dest> [--src <repo>] [--fixtures <dir>] [--key <file>]
#   Builds the case's scratch repo, no panel call: the case's `base` tree from
#   <repo> (default this checkout) without scripts/eval/review-panel/, one commit,
#   then the case diff as a second commit. No later history, no CR ledger, no key (I9).
# Env: REVIEW_PANEL_CMD (default scripts/cr/critic-panel.sh; the test seam),
#      REVIEW_PANEL_SCRATCH (default a fresh mktemp -d).
# Exit: 0 scored; 2 usage, refused lint or bad dirs; else score.py's exit.
# Draws codex bank per fixture: the chief runs it, never a test (README).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="${REVIEW_PANEL_CMD:-$HERE/../../cr/critic-panel.sh}"
fixtures="$HERE/fixtures"; key="$HERE/key/seeds.json"
out=""; tiers="paid"; critics=""; only=""; meta="{}"; ledger_args=(); model=""; case_repo=""; src=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out|--fixtures|--key|--tiers|--critics|--only|--meta-json|--ledger|--model|--case-repo|--src)
            if [ $# -lt 2 ]; then echo "run.sh: $1 needs a value" >&2; exit 2; fi ;;
    esac
    case "$1" in
        --case-repo) case_repo="${2:-}"; shift 2 ;;
        --src) src="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --fixtures) fixtures="${2:-}"; shift 2 ;;
        --key) key="${2:-}"; shift 2 ;;
        --tiers) tiers="${2:-}"; shift 2 ;;
        --critics) critics="${2:-}"; shift 2 ;;
        --only) only="${2:-}"; shift 2 ;;
        --meta-json) meta="${2:-}"; shift 2 ;;
        --ledger) ledger_args=(--ledger "${2:-}"); shift 2 ;;
        --no-ledger) ledger_args=(--no-ledger); shift ;;
        --model) model="${2:-}"; shift 2 ;;
        *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$out" ] || { echo "run.sh: --out <dir> is required" >&2; exit 2; }

if [ -n "$case_repo" ]; then
    src="${src:-$(git -C "$HERE" rev-parse --show-toplevel)}" || exit 2
    patch="$fixtures/$case_repo.patch"
    [ -f "$patch" ] || { echo "run.sh: no fixture $patch" >&2; exit 2; }
    base="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"].get(sys.argv[2], {}).get("base") or "")' \
        "$key" "$case_repo")" || exit 2
    [ -n "$base" ] || { echo "run.sh: $case_repo has no base in $key" >&2; exit 2; }
    [ ! -e "$out" ] || { echo "run.sh: $out exists - refusing to build a case repo into it" >&2; exit 2; }
    patch="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"
    git init -q "$out" || exit 2
    gc=(git -C "$out" -c user.name=review-panel -c user.email=review-panel@example.invalid
        -c core.hooksPath=/dev/null -c commit.gpgsign=false)
    git -C "$src" archive "$base" -- . ':(exclude)scripts/eval/review-panel' | tar -x -C "$out" \
        || { echo "run.sh: cannot export $base from $src" >&2; exit 2; }
    "${gc[@]}" add -A && "${gc[@]}" commit -q -m "base $base" || exit 2
    "${gc[@]}" apply --index "$patch" || { echo "run.sh: $case_repo does not apply to $base" >&2; exit 2; }
    "${gc[@]}" commit -q -m "$case_repo" || exit 2
    exit 0
fi

# billed-opt-in: HIMMEL_BILLED_OK
[ "${HIMMEL_BILLED_OK:-}" = 1 ] || { echo "run.sh: draws codex bank per fixture; set HIMMEL_BILLED_OK=1 (on-demand only)" >&2; exit 2; }
if [ ! -d "$fixtures" ] || [ ! -f "$key" ]; then
    echo "run.sh: no fixtures dir or key" >&2
    exit 2
fi

if ! python3 "$HERE/score.py" lint --fixtures "$fixtures" --key "$key" ${src:+--src "$src"}; then
    echo "run.sh: fixture lint failed - no panel call made" >&2
    exit 2
fi

if [ -z "$critics" ]; then
    critics="$(python3 -c 'import json,sys
tiers=set(sys.argv[2].split(","))
print(",".join(r["slug"] for r in json.load(open(sys.argv[1]))["panel"] if r.get("tier") in tiers))' \
        "$HERE/../../cr/critics.json" "$tiers")" || critics=""
fi

if [ -n "$only" ] && ! python3 -c 'import json,sys
cases=json.load(open(sys.argv[1]))["cases"]
bad=sorted({c for c in sys.argv[2].split(",") if c} - set(cases))
if bad: sys.exit("run.sh: --only names cases the key lacks: %s - no panel call made" % ",".join(bad))' "$key" "$only"; then
    exit 2
fi
if [ -z "$critics" ]; then
    echo "run.sh: no critic roster (--critics, or critics.json rows in --tiers) - no panel call made" >&2
    exit 2
fi

mkdir -p "$out" || exit 2
out="$(cd "$out" && pwd)"
scratch="${REVIEW_PANEL_SCRATCH:-}"
if [ -z "$scratch" ]; then
    # shellcheck source=../../lib/prim.sh
    . "$HERE/../../lib/prim.sh" || { echo "run.sh: cannot load scripts/lib/prim.sh" >&2; exit 2; }
    scratch="$(tmpdir)" || exit 2
fi
mkdir -p "$scratch" || exit 2
# The critic must see the diff and nothing else: a scratch inside a checkout
# would hand it the repo (and its CR ledger).
if git -C "$scratch" rev-parse --git-dir >/dev/null 2>&1; then
    echo "run.sh: scratch $scratch is inside a git checkout - refusing" >&2
    exit 2
fi

python3 "$HERE/score.py" stamp "$out" --fixtures "$fixtures" --key "$key" --panel "$PANEL" --tiers "$tiers" --only "$only" || exit 2

for patch in "$fixtures"/case-*.patch "$fixtures"/real-*.patch; do
    [ -e "$patch" ] || continue
    cid="$(basename "$patch" .patch)"
    if [ -n "$only" ]; then
        case ",$only," in *",$cid,"*) ;; *) continue ;; esac
    fi
    dir="$scratch/$cid"
    rm -rf "$dir" && mkdir -p "$dir" || exit 2
    cp "$patch" "$dir/diff.patch" || exit 2
    echo "run.sh: $cid" >&2
    # The panel reads its tier set from CRITIC_PANEL_TIERS only when CR_PROFILE
    # is unset; the triviality gate would skip the paid tier on a small diff,
    # and known-findings would inject himmel's own dispositions into the prompt.
    # CRITICS_JSON pins the roster to the swept tree's critics.json (A27): the panel run from a
    # scratch dir would otherwise read a local overlay.
    (cd "$dir" && env -u CR_PROFILE CRITIC_PANEL_TIERS="$tiers" CR_TRIVIALITY_OVERRIDE=full \
        CRITIC_KNOWN_FINDINGS=0 CRITICS_JSON="$HERE/../../cr/critics.json" \
        bash "$PANEL" < diff.patch > "$out/$cid.md" 2> "$out/$cid.err")
    echo "$?" > "$out/$cid.rc"
done

python3 "$HERE/score.py" score --outputs "$out" --fixtures "$fixtures" --key "$key" \
    --critics "$critics" ${only:+--only "$only"} ${model:+--model "$model"} --meta-json "$meta" \
    --json "$out/scores.json" ${ledger_args[@]+"${ledger_args[@]}"}
