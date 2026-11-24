#!/usr/bin/env bash
# scripts/eval/review-panel/run.sh - one review-panel recall sweep.
# Lints the fixture set, feeds each frozen diff to critic-panel.sh on stdin from
# an empty scratch dir outside any git checkout (the critic sees the diff and
# nothing else: never the key, never this repo), then scores the outputs with
# score.py and appends one eval-runs row.
#
# usage: run.sh --out <dir> [--fixtures <dir>] [--key <file>] [--tiers <t>]
#               [--critics a,b] [--only case-01,...] [--meta-json <json>]
#               [--ledger <path> | --no-ledger] [--model <m>] [--delta] [--allow-claude-api]
#   --allow-claude-api  the explicit opt-in to run a claude-api critic (billed per API token,
#              operator decision 525); without it a sweep whose roster holds one refuses before
#              the first case.
#   --delta    sweep only the delta cases (a subset sweep, like --only; exclusive with it).
#              A delta case (key "delta": true, files <id>.patch + <id>.delta.patch) is fed as
#              diff = the fix delta, with --context-file = the round-1 diff then the delta; any
#              sweep feeds delta cases that way, with or without --delta.
#   --tiers   CRITIC_PANEL_TIERS for the panel (default paid: the paid rows of the registry; a
#              claude-api row an overlay adds is billed per token, so that sweep refuses without --allow-claude-api).
#   --model    the critic model, recorded on the row and in its config.
#   --critics  the critics the sweep runs and reports (default: the registry rows in --tiers).
#              The registry is the swept tree's critics.json with critics.local.json merged over it
#              (scripts/lib/critics-config.sh); the panel roster is it cut to these slugs, so
#              "--critics codex" never calls a claude row and a slug the overlay drops never runs.
#
#   --src      the repo real cases' base and fix commits live in (default this checkout).
#
#        run.sh --paired <snapshot> [--head <rev>] [--repeats N] [--results <file>] --out <dir> [sweep flags]
#   One run, one pinned commit: sweeps <snapshot> (base) and <head> (default HEAD) concurrently, each in its
#   own scratch tree, N times each, and appends their rows (fields snapshot and side) to --results (default
#   results.jsonl) only when every sweep exported. Refused unless <snapshot> is an ancestor of <head> and both
#   carry the same fixtures and key; takes no --fixtures or --key. README: Paired snapshot sweeps.
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
out=""; tiers="paid"; critics=""; only=""; meta="{}"; ledger_args=(); model=""; case_repo=""; src=""; delta_only=0; allow_claude=0
paired=""; head_rev=""; repeats=1; results="$HERE/results.jsonl"; inputs_given=0; fwd=()

while [ $# -gt 0 ]; do
    case "$1" in
        --out|--fixtures|--key|--tiers|--critics|--only|--meta-json|--ledger|--model|--case-repo|--src|--paired|--head|--repeats|--results)
            if [ $# -lt 2 ]; then echo "run.sh: $1 needs a value" >&2; exit 2; fi ;;
    esac
    case "$1" in
        --case-repo) case_repo="${2:-}"; shift 2 ;;
        --src) src="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --fixtures) fixtures="${2:-}"; inputs_given=1; shift 2 ;;
        --key) key="${2:-}"; inputs_given=1; shift 2 ;;
        --tiers) tiers="${2:-}"; fwd+=("$1" "$tiers"); shift 2 ;;
        --critics) critics="${2:-}"; fwd+=("$1" "$critics"); shift 2 ;;
        --only) only="${2:-}"; fwd+=("$1" "$only"); shift 2 ;;
        --meta-json) meta="${2:-}"; fwd+=("$1" "$meta"); shift 2 ;;
        --ledger) ledger_args=(--ledger "${2:-}"); fwd+=("$1" "${2:-}"); shift 2 ;;
        --no-ledger) ledger_args=(--no-ledger); fwd+=("$1"); shift ;;
        --delta) delta_only=1; fwd+=("$1"); shift ;;
        --allow-claude-api) allow_claude=1; fwd+=("$1"); shift ;;
        --model) model="${2:-}"; fwd+=("$1" "$model"); shift 2 ;;
        --paired) paired="${2:-}"; shift 2 ;;
        --head) head_rev="${2:-}"; shift 2 ;;
        --repeats) repeats="${2:-}"; shift 2 ;;
        --results) results="${2:-}"; shift 2 ;;
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

if [ -n "$paired" ]; then
    [ "$inputs_given" = 0 ] || { echo "run.sh: --paired reads each side's own fixtures and key: drop --fixtures and --key" >&2; exit 2; }
    case "$repeats" in ''|*[!0-9]*) repeats=0 ;; *) repeats=$((10#$repeats)) ;; esac
    [ "$repeats" -ge 1 ] || { echo "run.sh: --repeats needs a positive integer" >&2; exit 2; }
    top="$(git -C "$HERE" rev-parse --show-toplevel)" || exit 2
    rel="$(git -C "$HERE" rev-parse --show-prefix)" || exit 2
    snap="$(git -C "$top" rev-parse --verify "$paired^{commit}" 2>/dev/null)" \
        || { echo "run.sh: --paired $paired is not a commit - no panel call made" >&2; exit 2; }
    head_sha="$(git -C "$top" rev-parse --verify "${head_rev:-HEAD}^{commit}" 2>/dev/null)" \
        || { echo "run.sh: --head ${head_rev:-HEAD} is not a commit - no panel call made" >&2; exit 2; }
    git -C "$top" merge-base --is-ancestor "$snap" "$head_sha" \
        || { echo "run.sh: snapshot $snap is not an ancestor of head $head_sha - no panel call made" >&2; exit 2; }
    git -C "$top" diff --quiet "$snap" "$head_sha" -- "${rel}fixtures" "${rel}key" \
        || { echo "run.sh: the case set (fixtures, key) differs between snapshot and head: a paired sweep measures both sides on one case set - no panel call made" >&2; exit 2; }
    mkdir -p "$out" || exit 2
    out="$(cd "$out" && pwd)"
    pscratch="${REVIEW_PANEL_SCRATCH:-}"
    if [ -z "$pscratch" ]; then
        # shellcheck source=../../lib/prim.sh
        . "$HERE/../../lib/prim.sh" || { echo "run.sh: cannot load scripts/lib/prim.sh" >&2; exit 2; }
        pscratch="$(tmpdir)" || exit 2
    fi
    prun="$pscratch/paired-$$"
    mkdir -p "$prun/trees" || exit 2
    trap 'git -C "$top" worktree remove --force "$prun/trees/base" >/dev/null 2>&1; git -C "$top" worktree remove --force "$prun/trees/head" >/dev/null 2>&1; git -C "$top" worktree prune' EXIT
    git -C "$top" worktree add -q --detach "$prun/trees/base" "$snap" || exit 2
    git -C "$top" worktree add -q --detach "$prun/trees/head" "$head_sha" || exit 2
    sweep_side() {
        local side="$1" n="$2" tree="$prun/trees/$1" o="$out/$1-$2"
        rm -f "$o.row.jsonl" || return 2
        REVIEW_PANEL_SCRATCH="$prun/work/$side-$n" PYTHONDONTWRITEBYTECODE=1 \
            bash "$tree/${rel}run.sh" --out "$o" ${fwd[@]+"${fwd[@]}"} || return $?
        python3 "$HERE/score.py" export-row "$o" --repo "$tree" --snapshot "$snap" --side "$side" --results "$o.row.jsonl"
    }
    rc=0; n=1
    while [ "$n" -le "$repeats" ] && [ "$rc" = 0 ]; do
        sweep_side base "$n" & pid_base=$!
        sweep_side head "$n" & pid_head=$!
        wait "$pid_base" || rc=$?
        wait "$pid_head" || rc=$?
        n=$((n + 1))
    done
    [ "$rc" = 0 ] || { echo "run.sh: a paired sweep failed (exit $rc): no row written" >&2; exit "$rc"; }
    n=1
    while [ "$n" -le "$repeats" ]; do
        cat "$out/base-$n.row.jsonl" "$out/head-$n.row.jsonl" >> "$results" || exit 2
        n=$((n + 1))
    done
    echo "run.sh: paired sweep of snapshot $snap: base $snap and head $head_sha x$repeats -> $results"
    exit 0
fi

if [ ! -d "$fixtures" ] || [ ! -f "$key" ]; then
    echo "run.sh: no fixtures dir or key" >&2
    exit 2
fi

if ! python3 "$HERE/score.py" lint --fixtures "$fixtures" --key "$key" ${src:+--src "$src"}; then
    echo "run.sh: fixture lint failed - no panel call made" >&2
    exit 2
fi

# The registry: the swept tree's critics.json (A27; CRITICS_BASE_JSON is the test seam) with the
# operator's critics.local.json merged over it by scripts/lib/critics-config.sh, the resolver
# critic-panel.sh and review-merge-gate.sh read, so an overlay drop reaches the eval too (decision 1085).
registry="$(mktemp -t review-panel-registry.XXXXXX)" || exit 2
trap 'rm -f "$registry"' EXIT
# shellcheck source=../../lib/critics-config.sh
base_json="${CRITICS_BASE_JSON:-$HERE/../../cr/critics.json}"
if ! { . "$HERE/../../lib/critics-config.sh" &&
       CRITICS_BASE_JSON="$base_json" critics_config_resolve "$HERE/../../cr" > "$registry"; }; then
    echo "run.sh: the critics registry does not resolve - no panel call made" >&2
    exit 2
fi

if [ -z "$critics" ]; then
    critics="$(python3 -c 'import json,sys
tiers=set(sys.argv[2].split(","))
print(",".join(r["slug"] for r in json.load(open(sys.argv[1]))["panel"] if r.get("tier") in tiers))' \
        "$registry" "$tiers")" || critics=""
fi

# The key marks delta cases; a sweep feeds each as its fix delta, whether or not --delta is given.
deltas="$(python3 -c 'import json,sys
print(",".join(sorted(c for c, v in json.load(open(sys.argv[1]))["cases"].items() if v.get("delta") is True)))' "$key")" || exit 2
if [ "$delta_only" = 1 ]; then
    [ -z "$only" ] || { echo "run.sh: --delta and --only are exclusive - no panel call made" >&2; exit 2; }
    [ -n "$deltas" ] || { echo "run.sh: --delta but the key marks no delta case - no panel call made" >&2; exit 2; }
    only="$deltas"
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

# The roster the panel runs: the merged registry above cut to the --critics slugs, so a slug the
# overlay drops never runs. A claude-api critic left in it needs --allow-claude-api (decision 525).
roster="$out/critics.run.json"
python3 -c 'import json,sys
src,dst,critics,tiers,allow,base=sys.argv[1:7]
reg=json.load(open(src)); keep=set(critics.split(","))
base=json.load(open(base)); floor=base.get("claude_floor")
local=(reg.get("files") or {}).get("local")
if local:
    over=json.load(open(local))
    if isinstance(over, dict) and "claude_floor" in over: floor=over["claude_floor"]
slug=(floor.get("slug") or "claude") if isinstance(floor, dict) else None
if slug in keep and floor.get("model") and not any(r.get("slug") == slug for r in reg["panel"] + base.get("panel", [])):
    row={"slug": slug, "model": floor["model"], "provider": "claude-api", "route_provider": "claude-api",
         "tier": "paid", "mode": "advisory"}
    row.update({k: floor[k] for k in ("effort", "perspective") if floor.get(k)})
    reg["panel"].append(row)
reg["panel"]=[r for r in reg["panel"] if r["slug"] in keep]
claude_like=lambda p: str(p or "").startswith("claude") or p in ("api", "subscription")
bill=[r["slug"] for r in reg["panel"] if r.get("tier") in set(tiers.split(",")) and (claude_like(r.get("provider")) or claude_like(r.get("route_provider")))]
if bill and allow != "1":
    sys.exit("run.sh: the roster holds a billed claude-api critic (%s) - pass --allow-claude-api or drop it from --critics - no panel call made" % ",".join(bill))
json.dump(reg, open(dst, "w"))' "$registry" "$roster" "$critics" "$tiers" "$allow_claude" "$base_json" || exit 2

python3 "$HERE/score.py" stamp "$out" --fixtures "$fixtures" --key "$key" --panel "$PANEL" --tiers "$tiers" --only "$only" \
    --critics "$critics" ${model:+--model "$model"} || exit 2

for patch in "$fixtures"/case-*.patch "$fixtures"/real-*.patch "$fixtures"/delta-*.patch; do
    [ -e "$patch" ] || continue
    case "$patch" in *.delta.patch) continue ;; esac
    cid="$(basename "$patch" .patch)"
    if [ -n "$only" ]; then
        case ",$only," in *",$cid,"*) ;; *) continue ;; esac
    fi
    dir="$scratch/$cid"
    rm -rf "$dir" && mkdir -p "$dir" || exit 2
    ctx_args=()
    case ",$deltas," in
        *",$cid,"*)
            # A delta case: the critic reviews the fix delta, with the round-1 diff then the delta as context.
            cp "$fixtures/$cid.delta.patch" "$dir/diff.patch" || exit 2
            cat "$patch" "$fixtures/$cid.delta.patch" > "$dir/context.patch" || exit 2
            ctx_args=(--context-file context.patch) ;;
        *) cp "$patch" "$dir/diff.patch" || exit 2 ;;
    esac
    echo "run.sh: $cid" >&2
    # The panel reads its tier set from CRITIC_PANEL_TIERS only when CR_PROFILE
    # is unset; the triviality gate would skip the paid tier on a small diff,
    # and known-findings would inject himmel's own dispositions into the prompt.
    # CRITICS_JSON pins the roster to the swept tree's critics.json cut to --critics (A27): the panel
    # run from a scratch dir would otherwise read a local overlay, and the whole tier.
    (cd "$dir" && env -u CR_PROFILE -u CRITIC_FIRST_PASS -u CRITIC_INVOKE CRITIC_PANEL_TIERS="$tiers" CR_TRIVIALITY_OVERRIDE=full \
        CRITIC_KNOWN_FINDINGS=0 CRITICS_JSON="$roster" \
        bash "$PANEL" ${ctx_args[@]+"${ctx_args[@]}"} < diff.patch > "$out/$cid.md" 2> "$out/$cid.err")
    echo "$?" > "$out/$cid.rc"
done

python3 "$HERE/score.py" stamp "$out" --recheck --fixtures "$fixtures" --key "$key" --panel "$PANEL" --tiers "$tiers" --only "$only" || exit 2

python3 "$HERE/score.py" score --outputs "$out" --fixtures "$fixtures" --key "$key" \
    --critics "$critics" ${only:+--only "$only"} ${model:+--model "$model"} --meta-json "$meta" \
    --json "$out/scores.json" ${ledger_args[@]+"${ledger_args[@]}"}
