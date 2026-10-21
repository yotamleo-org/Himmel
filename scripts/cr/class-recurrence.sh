#!/usr/bin/env bash
# scripts/cr/class-recurrence.sh — the restructure trigger: a finding class that
# keeps coming back gets ONE restructure ticket, not one more patch per PR.
#
# Usage: class-recurrence.sh [--days N] [--ledger FILE] [--merged-file FILE]
#                            [--members FILE] [--epic KEY] [--dry-run]
#
# A pair is (area, class). area = the finding's directory cut to its first three
# segments; class = the exact `class=` id an amend row carries
# (unattributed rows are never counted; `new:<slug>` counts as `new-<slug>`).
# In the rolling window (--days, default 14) a class fires when either holds:
#   - one pair appears in >= 5 distinct merged PRs and >= 2 of them deferred it;
#   - >= 3 open, not-yet-folded residuals carry its `class-<id>` label, or one
#     does beside an already folded sibling (a fold that failed half way is retried).
# Per fired class, in order:
#   1. a ticket labelled restructure-class-<id> exists  -> comment the evidence;
#   2. the class has a member of the structural-fix epic (--members) -> label the member, comment;
#   3. else file one ticket in the epic (at most 2 new per rolling week).
# Then every open residual of the class is folded into that ticket: a Relates
# link, the folded-into-<KEY> label, its fixVersion removed (backlog, freeing the
# budget slot) and a RED row in the ticket's Proof. A folded residual stays open.
#
# Env: JIRA_PROJECT_KEY (required); JIRA_CMD (Jira CLI override, word-split);
#      GH_CMD (default gh); CR_LEDGER (default <git-common-dir>/cr-critic-scores.jsonl).
# Merged PRs come from `gh pr list --state merged` unless --merged-file is given.
# Exit: 0 ok · 2 usage, no merged list or no project key · 3 a Jira write failed ·
#       4 a Jira lookup failed (nothing is filed on an unreadable tracker).
#
# ponytail: a PR is a distinct ledger branch and the area is not on a residual, so
# residuals match by class label only, upgrade path is a PR number on each ledger
# row and an area label from the residual writer (`jira create --residual-of
# <parent> --fu-class <c> --class <id>`), which also stamps the
# `residual` and `class-<id>` labels read here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$HERE/../lib/git-clean.sh"
git_env_scrub

DAYS=14
LEDGER=""
MERGED_FILE=""
MEMBERS_FILE=""
EPIC=""
DRY_RUN=0
WEEKLY_CAP=2
RESIDUAL_MIN=3
PR_MIN=5
DEFER_MIN=2

# Class -> existing structural-fix epic member that already owns the fix.
BUILTIN_MEMBERS="eval-tokenizer-split HIMMEL-5061
hook-adhoc-parse HIMMEL-5061
gnu-only-utility HIMMEL-5062
bash32-portability HIMMEL-5062
console-kit-lock-helper HIMMEL-5063"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2; }
die() { echo "class-recurrence: $*" >&2; exit 2; }

# shellcheck source=../lib/prim.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/prim.sh" || die "cannot load scripts/lib/prim.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --days)        [ $# -ge 2 ] || die "--days needs a value"; DAYS="$2"; shift 2 ;;
        --ledger)      [ $# -ge 2 ] || die "--ledger needs a file"; LEDGER="$2"; shift 2 ;;
        --merged-file) [ $# -ge 2 ] || die "--merged-file needs a file"; MERGED_FILE="$2"; shift 2 ;;
        --members)     [ $# -ge 2 ] || die "--members needs a file"; MEMBERS_FILE="$2"; shift 2 ;;
        --epic)        [ $# -ge 2 ] || die "--epic needs a key"; EPIC="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done
case "$DAYS" in ''|*[!0-9]*) die "--days must be a positive integer (got '$DAYS')" ;; esac
[ -n "${JIRA_PROJECT_KEY:-}" ] || die "JIRA_PROJECT_KEY is not set"
PROJECT="$JIRA_PROJECT_KEY"
[ -n "$EPIC" ] || EPIC="${PROJECT}-6176"
[ -n "$LEDGER" ] || LEDGER="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}" # swallow-ok: an unresolvable git dir leaves a path the next line refuses as unreadable
[ -r "$LEDGER" ] || die "ledger not readable: $LEDGER"

W="$(tmpdir)" || exit 2
trap 'rm -rf "$W"' EXIT

jira_run() {
    local common
    if [ -n "${JIRA_CMD:-}" ]; then
        # shellcheck disable=SC2086
        $JIRA_CMD "$@" </dev/null
        return $?
    fi
    common=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { # swallow-ok: the failure branch reports it and returns 1
        echo "cannot locate the Jira CLI (set JIRA_CMD)" >&2
        return 1
    }
    node "$(dirname "$common")/scripts/jira/dist/index.js" "$@" </dev/null
}

# ── merged PRs: fail closed, an unmerged branch must never count ────────────
if [ -n "$MERGED_FILE" ]; then
    [ -r "$MERGED_FILE" ] || die "merged list not readable: $MERGED_FILE"
    cp "$MERGED_FILE" "$W/merged.txt"
else
    since=$(node -e 'console.log(new Date(Date.now()-process.argv[1]*864e5).toISOString().slice(0,10))' "$DAYS")
    # shellcheck disable=SC2086
    ${GH_CMD:-gh} pr list --state merged --search "merged:>=${since}" --limit 1000 \
        --json headRefName --jq '.[].headRefName' >"$W/merged.txt" 2>"$W/gh.err" \
        || die "cannot list merged PRs (pass --merged-file): $(cat "$W/gh.err")"
fi

# ── ledger arm: pairs that recur in >= PR_MIN merged PRs, >= DEFER_MIN deferring ─
# out: class <TAB> area <TAB> n_prs <TAB> n_deferred <TAB> prs <TAB> deferred_prs
LEDGER="$LEDGER" MERGED="$W/merged.txt" DAYS="$DAYS" PR_MIN="$PR_MIN" DEFER_MIN="$DEFER_MIN" node -e '
const fs = require("fs");
const e = process.env;
const merged = new Set(fs.readFileSync(e.MERGED, "utf8").split("\n").map(s => s.trim()).filter(Boolean));
const cutoff = Date.now() - Number(e.DAYS) * 864e5;
const first = {}, amends = {};
for (const l of fs.readFileSync(e.LEDGER, "utf8").split("\n")) {
  if (!l.trim()) continue;
  let r; try { r = JSON.parse(l); } catch { continue; }
  if (r.kind === "finding") { const k = r.head + "\u0000" + r.finding_id; if (!first[k]) first[k] = r; }
  else if (r.kind === "amend" && r.set) { (amends[r.target_head + "\u0000" + r.finding_id] = amends[r.target_head + "\u0000" + r.finding_id] || []).push(r); }
}
const areaOf = (f) => { const d = String(f || "").split("/").slice(0, -1).slice(0, 3).join("/"); return d || "."; };
const pairs = {};
for (const k of Object.keys(first)) {
  const f = first[k];
  if (!(Date.parse(f.ts) >= cutoff) || !merged.has(f.branch)) continue;
  let cls = "", verdict = f.verdict || "", deferred = !!f.deferred_to || verdict === "deferred";
  for (const a of amends[k] || []) {
    if (a.set.class) cls = a.set.class;
    if (a.set.verdict) { verdict = a.set.verdict; deferred = verdict === "deferred"; }
    else if (a.set.deferred_to) deferred = true;
  }
  if (!cls || cls === "unattributed" || verdict === "disproved") continue;
  const id = cls.replace(/:/g, "-"), p = id + "\t" + areaOf(f.file);
  const e2 = pairs[p] = pairs[p] || { prs: new Set(), def: new Set() };
  e2.prs.add(f.branch); if (deferred) e2.def.add(f.branch);
}
for (const p of Object.keys(pairs).sort()) {
  const v = pairs[p];
  if (v.prs.size >= Number(e.PR_MIN) && v.def.size >= Number(e.DEFER_MIN))
    console.log([p, v.prs.size, v.def.size, [...v.prs].sort().join(","), [...v.def].sort().join(",")].join("\t"));
}' >"$W/pairs.tsv" || die "cannot read the ledger: $LEDGER"

# ── residual arm: open `residual` tickets not yet folded, by class-<id> label ──
# out: class <TAB> key <TAB> title
if ! jira_run list --project "$PROJECT" --limit 500 --labels \
        --jql "project = ${PROJECT} AND labels = residual AND statusCategory != Done" >"$W/residuals.raw" 2>"$W/err"; then
    echo "class-recurrence: residual lookup failed — fail-closed: $(cat "$W/err")" >&2
    exit 4
fi
[ "$(grep -c . "$W/residuals.raw")" -lt 500 ] || echo "WARN class-recurrence: the query hit its 500-row cap, the residual results below are partial" >&2
awk -F'\t' '
    NF >= 5 && $5 !~ /(^|,)folded-into-/ {
        n = split($5, L, ","); for (i = 1; i <= n; i++) if (L[i] ~ /^class-./) print substr(L[i], 7) "\t" $1 "\t" $4
    }' "$W/residuals.raw" >"$W/residuals.tsv"

{ cut -f1 "$W/pairs.tsv"
  awk -F'\t' -v m="$RESIDUAL_MIN" '
      NF >= 5 {
          folded = ($5 ~ /(^|,)folded-into-/); n = split($5, L, ",")
          for (i = 1; i <= n; i++) if (L[i] ~ /^class-./) { k = substr(L[i], 7); if (folded) f[k]++; else u[k]++ }
      }
      END { for (k in u) if (u[k] >= m || f[k] > 0) print k }' "$W/residuals.raw"; } \
    | sort -u >"$W/classes.txt"

if [ -n "$MEMBERS_FILE" ]; then
    [ -r "$MEMBERS_FILE" ] || die "members file not readable: $MEMBERS_FILE"
    cp "$MEMBERS_FILE" "$W/members.txt"
else
    printf '%s\n' "$BUILTIN_MEMBERS" >"$W/members.txt"
fi

# new tickets this rolling week, whatever their class: the cap is on the trigger, not on a class
if ! jira_run list --project "$PROJECT" --limit 50 \
        --jql "project = ${PROJECT} AND labels = \"restructure-trigger\" AND created >= -7d" >"$W/week.raw" 2>"$W/err"; then
    echo "class-recurrence: weekly count lookup failed — fail-closed: $(cat "$W/err")" >&2
    exit 4
fi
new_this_week=$(awk 'NF' "$W/week.raw" | wc -l | tr -d ' ')

filed=0 updated=0 labelled=0 folded=0 capped=0 failed=0

# evidence <class> -> markdown bullets on stdout: the recurring pairs, then a RED row per residual
evidence() {
    local id="$1"
    awk -F'\t' -v c="$id" '$1 == c { printf "- %s: %s merged PRs (%s), %s deferred (%s)\n", $2, $3, $5, $4, $6 }' "$W/pairs.tsv"
    awk -F'\t' -v c="$id" '$1 == c { printf "- RED: %s %s — shown impossible or covered by the restructure\n", $2, $3 }' "$W/residuals.tsv"
}

write_ticket_body() {  # <class> <file>
    local id="$1" out="$2" ev
    ev="$(evidence "$id")"
    printf '%s\n' \
        "## Impact" \
        "The finding class \`${id}\` keeps recurring across merged PRs and each one is patched in place. Nothing removes the class." \
        "" \
        "## What" \
        "Restructure so the class cannot occur, instead of patching one more instance. Filed by scripts/cr/class-recurrence.sh." \
        "" \
        "## Why" \
        "In the last ${DAYS} days the class crossed the restructure threshold: ${PR_MIN} or more merged PRs in one area with ${DEFER_MIN} or more deferring it, or ${RESIDUAL_MIN} or more open residuals." \
        "" \
        "## Plan" \
        "1. Read the evidence below and choose the structural fix: a shared helper, a lint, or a gate." \
        "2. Land it, then close each folded residual as Duplicate with the merge sha." \
        "" \
        "## DoD" \
        "- Every RED row under Proof is shown impossible or covered, and the class no longer recurs." \
        "" \
        "## Proof" \
        "$ev" \
        "" \
        "## Agent detail" \
        "Class label: restructure-class-${id}. Folded residuals stay open until this merges and proves them." >"$out"
}

fold_residual() {  # <residual key> <restructure key>
    local r="$1" t="$2" v
    if ! jira_run link "$r" "$t" >/dev/null 2>"$W/err"; then echo "  FAILED link $r $t: $(cat "$W/err")" >&2; failed=$((failed+1)); return; fi
    if ! jira_run get "$r" >"$W/get.txt" 2>"$W/err"; then echo "  FAILED read $r: $(cat "$W/err")" >&2; failed=$((failed+1)); return; fi
    sed -n 's/^Fix versions: //p' "$W/get.txt" | tr ',' '\n' | sed 's/^ *//;s/ *$//' >"$W/versions.txt"
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if ! jira_run fix-version "$r" --remove "$v" >/dev/null 2>"$W/err"; then
            echo "  FAILED backlog $r (fix-version --remove $v): $(cat "$W/err")" >&2; failed=$((failed+1)); return
        fi
    done <"$W/versions.txt"
    if ! jira_run edit "$r" --add-labels "folded-into-${t}" >/dev/null 2>"$W/err"; then echo "  FAILED label $r: $(cat "$W/err")" >&2; failed=$((failed+1)); return; fi
    folded=$((folded+1))
    echo "  folded $r into $t"
}

while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! jira_run list --project "$PROJECT" --limit 1 --jql "project = ${PROJECT} AND labels = \"restructure-class-${id}\" AND statusCategory != Done" >"$W/ticket.raw" 2>"$W/err"; then
        echo "class-recurrence: ticket lookup for ${id} failed — fail-closed: $(cat "$W/err")" >&2
        exit 4
    fi
    key=$(awk 'NF{print $1; exit}' "$W/ticket.raw")
    member=$(awk -v c="$id" '$1 == c {print $2; exit}' "$W/members.txt")
    prs=$(awk -F'\t' -v c="$id" '$1 == c {n += $3} END {print n + 0}' "$W/pairs.tsv")
    nres=$(awk -F'\t' -v c="$id" '$1 == c' "$W/residuals.tsv" | wc -l | tr -d ' ')
    if [ -z "$key" ] && [ -n "$member" ]; then
        if ! jira_run list --project "$PROJECT" --limit 1 --jql "key = ${member} AND statusCategory != Done" >"$W/member.raw" 2>"$W/err"; then
            echo "class-recurrence: member lookup for ${member} failed — fail-closed: $(cat "$W/err")" >&2
            exit 4
        fi
        [ -n "$(awk 'NF{print $1; exit}' "$W/member.raw")" ] || member=""
    fi
    new_ticket=0
    if [ -n "$key" ]; then
        action="updated"
    elif [ -n "$member" ]; then
        key="$member"; action="member"
    elif [ "$new_this_week" -ge "$WEEKLY_CAP" ]; then
        echo "class ${id}: prs=${prs} residuals=${nres} -> capped (${new_this_week} new restructure tickets this week, cap ${WEEKLY_CAP})"
        capped=$((capped+1)); continue
    else
        action="filed"; new_ticket=1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "class ${id}: prs=${prs} residuals=${nres} -> dry-run: would ${action}${key:+ $key}"
        [ "$new_ticket" -eq 1 ] && new_this_week=$((new_this_week+1))
        continue
    fi

    if [ "$new_ticket" -eq 1 ]; then
        write_ticket_body "$id" "$W/body.md"
        if ! created=$(jira_run create --type Task --title "Restructure finding class ${id}: remove the class, not one more instance" \
                --labels "restructure-class-${id},restructure-trigger,standalone" --sector 'Ship loop' --parent "$EPIC" \
                --project "$PROJECT" --desc-file "$W/body.md" 2>"$W/err"); then
            echo "FAILED create for ${id}: $(cat "$W/err")" >&2; failed=$((failed+1)); continue
        fi
        key=$(printf '%s\n' "$created" | sed -n 's/^Created \([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\).*/\1/p' | head -n1)
        [ -n "$key" ] || { echo "FAILED create for ${id}: no 'Created <KEY>' line in: $created" >&2; failed=$((failed+1)); continue; }
        new_this_week=$((new_this_week+1)); filed=$((filed+1))
    else
        if [ "$action" = member ]; then
            if ! jira_run edit "$key" --add-labels "restructure-class-${id}" >/dev/null 2>"$W/err"; then
                echo "FAILED label ${key}: $(cat "$W/err")" >&2; failed=$((failed+1)); continue
            fi
            labelled=$((labelled+1))
        else
            updated=$((updated+1))
        fi
        printf 'Recurrence run (rolling %s days) for class %s:\n\n%s\n' "$DAYS" "$id" "$(evidence "$id")" >"$W/comment.md"
        if ! jira_run comment "$key" --comment-file "$W/comment.md" >/dev/null 2>"$W/err"; then
            echo "FAILED comment ${key}: $(cat "$W/err")" >&2; failed=$((failed+1)); continue
        fi
    fi
    echo "class ${id}: prs=${prs} residuals=${nres} -> ${action} ${key}"
    awk -F'\t' -v c="$id" '$1 == c {print $2}' "$W/residuals.tsv" >"$W/fold.txt"
    while IFS= read -r r; do
        fold_residual "$r" "$key"
    done <"$W/fold.txt"
done <"$W/classes.txt"

echo "class-recurrence: summary — ${filed} filed, ${updated} updated, ${labelled} member-labelled, ${folded} residuals folded, ${capped} capped, ${failed} failed"
[ "$failed" -eq 0 ] || exit 3
exit 0
