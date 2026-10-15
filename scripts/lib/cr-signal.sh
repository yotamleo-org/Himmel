#!/usr/bin/env bash
# cr-signal.sh — the ONE reader for "what did CodeRabbit say about this SHA?"
#
# WHY THIS EXISTS — the shape nobody checked:
# CodeRabbit publishes its verdict as a COMMIT STATUS, not a check-run.
# Verified live on 5 consecutive PRs (#1249/#1247/#1246/#1238/#1243):
#
#   gh api repos/OWNER/NAME/commits/<sha>/check-runs -> CodeRabbit count = 0
#   gh api repos/OWNER/NAME/commits/<sha>/statuses   -> CodeRabbit count = 3..5
#
# Every `select(.name=="CodeRabbit")` over `.check_runs[]` therefore matched
# NOTHING: cr-merge-gate's in-flight block and check-ci's zombie override were
# dead code that had never once fired. The test fixtures mocked CodeRabbit as a
# check-run, so the suite stayed green against a shape production never emits.
# `statusCheckRollup` (what `gh pr checks` reads) merges check-runs AND statuses,
# which is why the rollup showed CodeRabbit while the check-runs API did not.
#
# ENDPOINT CHOICE (this is the load-bearing detail):
# wants the bot matched by IDENTITY, not display name. Only the
# /statuses LIST endpoint carries one:
#   /commits/<sha>/status   (combined) -> creator is NULL. No identity. Unusable.
#   /commits/<sha>/statuses (list)     -> creator{id,login,type}. Usable.
#   statusCheckRollup                  -> StatusContext{context,state}. No identity.
# A commit status has no .app.id/.app.slug (only check-runs do), so the identity
# is the CREATOR: id 136622811 = coderabbitai[bot]. Match on the ID — logins are
# mutable, display names are spoofable.
#
# ORDERING: GitHub returns statuses in reverse-chronological order and CodeRabbit
# posts several per head (queued -> in progress -> completed), so the FIRST match
# is the current verdict — the same one the combined endpoint dedupes to.
#
# SKIPPED IS NOT SUCCESS — the second shape nobody checked:
# when a repo disables automatic reviews (the standing posture since
# made the App the reviewer, and permanent since deleted the CLI),
# CodeRabbit still posts a status on every untriggered PR — and posts it as
#   state=success  description="Review skipped: automatic reviews are disabled"
# This reader used to project ONLY .state, so a refusal to review and a clean
# review were the same byte to every caller. check-ci then certified exit 0 on a
# PR nobody had reviewed, and merge-on-green (which gates solely on check-ci:0)
# would squash-merge it. Reproduced on PR #1429, 2026-07-27.
# The fix is to read the field that carries the meaning: a `success` whose
# description says it skipped becomes its own state, which callers fail CLOSED on
# exactly like `absent`.
#
# WHY WE MATCH "skipped" AND DO NOT REQUIRE "completed": requiring a known-good
# description makes the gate an enumeration of CodeRabbit's wording, and an
# enumeration rots — the day the App renames "Review completed" every PR in the
# repo goes uncertifiable at once (rot-to-RED, a self-inflicted outage). Matching
# the skip vocabulary degrades the other way: an unrecognised NEW skip phrasing
# reads as success, i.e. exactly today's behaviour, no worse. Asymmetric on
# purpose. If CodeRabbit adds a skip phrasing, extend _CRS_SKIP_RE.
#
# cr_signal_state <owner> <name> <sha>
#   stdout: success | pending | failure | error | absent | paged | skipped
#           "absent" = CodeRabbit has posted NOTHING for this SHA. It is NOT a
# pass. Callers gate on it (absent must never read green).
#           "paged" = page one was FULL and held no CodeRabbit status, so its
#           verdict may sit on an unread page — indeterminate, never "absent".
#           Callers must fail CLOSED on it (coderabbit-2).
#           "skipped" = CodeRabbit posted success but SAID it did not review
#           (auto-reviews disabled). A declined review, never a pass — callers
# fail CLOSED on it. Clear it with `@coderabbitai review`.
#   rc 0 = state determined (incl. "absent"); rc 1 = cannot evaluate (query or
#           parse failure) — the caller decides open/closed, this reader does not.
#
# cr_signal_probe <owner> <name> <sha>
#   Same query, but stdout is "<state> <created_at>" (created_at empty when
#   absent) so a caller can age a stuck `pending` without a second API call.
#   Both values ride stdout on purpose: every caller reads this via `$(...)`,
#   which forks a subshell — a global set inside could never reach them.
#   cr_signal_state is the thin wrapper for callers that only need the state.
#
# cr_signal_description <owner> <name> <sha>
#   stdout: the CodeRabbit status DESCRIPTION on this SHA (empty when it carries
#           none, or no CodeRabbit status exists). rc 0 = read ok (incl. empty);
#           rc 1 = cannot evaluate. Same identity-matched query as the probe, so
#           the description belongs to the status cr_signal_state classified.
# Added for when only a rate-limited skip was panel-
#           carriable and the gates needed the description to tell it from an
#           auto-reviews-disabled one (both project to `skipped`). Since
# BOTH gates carry every skip wording on a clean
#           exact-head panel, so the description now only labels the audit line.
#
#   A SHA that does not exist returns `[]` with HTTP 200 on this endpoint, so it
#   is indistinguishable from "no CodeRabbit status" and reports "absent". That
#   conflation is safe in one direction only — every caller fails CLOSED on
#   absent — and callers pass a headRefOid that by construction exists.
#
# Env:
#   CR_BOT_USER_ID     creator.id to trust (default 136622811 = coderabbitai[bot])
#   CR_STATUS_CONTEXT  status context to read (default "CodeRabbit")
#   GH_CMD             gh override (test seam, matches the forge backends)
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does not
# toggle set -e. bash 3.2-safe.

_crs_gh() { "${GH_CMD:-gh}" "$@"; }

# The identity, in ONE place. ci-green-gate needs the same pair to EXCLUDE
# CodeRabbit's status from the CI aggregate it owns, so both gates agree on
# what "a CodeRabbit status" is by construction rather than by coincidence.
cr_signal_bot_id()  { printf '%s\n' "${CR_BOT_USER_ID:-136622811}"; }
cr_signal_context() { printf '%s\n' "${CR_STATUS_CONTEXT:-CodeRabbit}"; }

# Descriptions that mean "I did not review this". Case-insensitive,
# applied ONLY to a `success` status — a skip vocabulary on failure/error changes
# nothing, those already fail closed. Kept as one regex in one place so the skip
# vocabulary has a single owner; see the header for why this matches the skip
# words rather than requiring the success words.
#
# Every alternative here must be UNAMBIGUOUS, because the two error directions
# are not symmetric. A false NEGATIVE degrades to the pre-
# behaviour — a missed skip reads as success, no worse than yesterday. A false
# POSITIVE blocks a genuinely clean review and cannot be cleared by re-running,
# which is the rot-to-RED outage this design exists to avoid. So loose substrings
# are excluded even when they read as skip-ish: a bare `no review` matches
# "No review changes requested" — a COMPLETED review — and would have blocked
# that merge. Verified against the real string and that hazard:
#   "Review skipped: automatic reviews are disabled" -> match
#   "No review changes requested"                    -> NO match
#   "Review completed"                               -> NO match
_CRS_SKIP_RE="${CR_SKIP_DESC_RE:-skipped|reviews? (are|is) disabled|review disabled|rate.?limit}"

# — the deny-list above is now a SECOND line of defence, not the
# first. The reasoning in the block above ("a missed skip reads as success, no
# worse than yesterday") was measured against reality on 2026-07-28 and is
# WRONG in its cost estimate, so the default is inverted here.
#
# What happened: CodeRabbit declined a review for rate limiting and posted
#   state=success  description="Review rate limited"
# on PR #1456 @ 46358386. That wording matched none of the deny-list
# alternatives, so it classified as a clean success; `gh pr checks` bucketed it
# `pass`; and check-ci printed "all checks green" + "verdict exit=0" on a head
# that — by its own cr-body-findings line, one line earlier — had NO CodeRabbit
# review at all. A missed skip is therefore not "no worse than yesterday": it
# CERTIFIES UNREVIEWED CODE AS MERGE-READY, which is the exact failure this
# file exists to prevent. That is the second drift of this class
# (the first), and repo doctrine escalates to structural on the second.
#
# The corrected asymmetry, which is the whole argument for inverting:
#   false negative (unknown skip wording reads as success) -> merges unreviewed
#     code. Silent, and discovered only by the damage.
#   false positive (a genuine pass is not recognised)      -> blocks a clean PR.
#     Loud, immediate, and clearable in one command (see the override below).
# A loud recoverable stop beats a silent unrecoverable merge.
#
# So: state=success is green ONLY when the description affirmatively says the
# review completed. Anything else CodeRabbit may invent in future — a wording we
# have never seen — now fails CLOSED by construction instead of being a hole
# waiting for its own incident.
#
# Observed vocabulary (2026-07-28, verified across three reviewed heads):
#   success + "Review completed"                              -> success
#   success + "No review changes requested"                   -> success
#   success + "Review skipped: automatic reviews are disabled" -> skipped
#   success + "Review rate limited"                            -> skipped
#   pending + "Review in progress" / "Review queued"           -> pending
#
# "No review changes requested" is a GENUINE completed review with different
# wording — it is the `cr-nearmiss` fixture, and test 34d exists precisely to
# assert it does not block. An allow-list of "review completed" alone regresses
# it to RED. That fixture caught this while writing which is the
# concrete demonstration of the header's false-positive hazard: the allow-list
# MUST enumerate every genuine success wording, and the escape hatch below is
# what makes that enumeration survivable when CodeRabbit adds one.
#
# OUTAGE ESCAPE HATCH (this is what makes the inversion safe to ship): if
# CodeRabbit renames its success description, EVERY PR blocks at once. The
# operator clears that without touching code by widening the allow-list:
#   CR_OK_DESC_RE='^(review completed|no review changes requested|review finished)$' \
#       bash scripts/check-ci.sh <pr>
# Keep the ^(...)$ anchors: CR_OK_DESC_RE is matched the same unanchored way as
# the default (see the CR follow-up note below), so a copy-paste that drops
# them lets a decline description merely CONTAINING an allow-listed phrase
# (e.g. "No review completed") pass as clean again (R2) — exactly
# the hole this override exists to help close, not reopen.
# CR_OK_DESC_RE REPLACES the default rather than extending it, so the override
# MUST carry every default alternative it still wants honoured — an example that
# lists only the renamed wording NARROWS the allow-list and regresses the very
# test-34d `cr-nearmiss` case described above to RED.
# NO DESCRIPTION IS NOT AN AFFIRMATIVE: a state=success whose
# description is missing, null or empty is tested against the same allow-list as
# any wording, and the default list does not match "" — so it reads as skipped.
# (first scoped the list to a non-empty description; that left this
# shape certified green.) The valve for the day CodeRabbit really emits an
# empty description on a clean review is the same override, adding an empty
# alternative alongside every default one still wanted:
#   CR_OK_DESC_RE='^(|review completed|no review changes requested)$'
# Both knobs stay live: CR_SKIP_DESC_RE still force-classifies a wording as a
# skip even if it would otherwise pass the allow-list.
#
# CR follow-up (R2): consumed below as `test($ok; "i")`, which is
# jq's UNANCHORED search — a description that merely CONTAINS an allow-listed
# phrase (e.g. "No review completed" contains "review completed") would
# substring-match and read as a clean success, reopening the exact hole this
# file exists to close. The DEFAULT is anchored (^...$) so only an EXACT
# allow-listed description passes. CR_OK_DESC_RE itself is deliberately left
# UNANCHORED IN CODE — test 34g's escape-hatch widening intentionally matches a
# bare partial phrase against an unenumerated FULL sentence, not just an exact
# one, so forcing an anchor around whatever the operator supplies would break
# that already-shipped behaviour. The documented recipe above carries its own
# anchors instead; it is on the operator to keep them when copying it verbatim.
_CRS_OK_RE="${CR_OK_DESC_RE:-^(review completed|no review changes requested)$}"

cr_signal_state() {
    local probe
    probe=$(cr_signal_probe "$@") || return 1
    printf '%s\n' "${probe%% *}"
}

# cr_signal_description <owner> <name> <sha>
#   stdout: CodeRabbit's status DESCRIPTION for this SHA (empty when the status
#           carries no description, or no CodeRabbit status exists on the SHA).
#   rc 0 = read ok (incl. an empty description); rc 1 = cannot evaluate (query
#           or parse failure — the caller decides open/closed, this reader does
#           not).
#
#   Reuses the SAME identity-matched /statuses LIST query as cr_signal_probe
#   (first match = newest = current verdict), so the description this returns
#   is the one belonging to the very status cr_signal_state classified — the
#   ONE-reader invariant this file exists to hold.
#
# cr_signal_state collapses every decline wording to a single
# `skipped` state, so a caller cannot tell a RATE-LIMITED
#   skip ("Review rate limited", which a clean critic PANEL may carry) from an
#   auto-reviews-DISABLED skip ("Review skipped: ...", which nothing carries)
#   from the state alone. This reader exposes the description so the MERGE
#   gates can make that policy call themselves — it stays a NEUTRAL reader and
#   owns no panel-carriable vocabulary (the rate-limit discrimination lives in
#   check-ci.sh / cr-merge-gate.sh, where the merge verdict does).
cr_signal_description() {
    local owner="$1" name="$2" sha="$3"
    local uid ctx
    uid=$(cr_signal_bot_id)
    ctx=$(cr_signal_context)

    if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$sha" ]; then return 1; fi
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac

    local json
    json=$(_crs_gh api "repos/$owner/$name/commits/$sha/statuses?per_page=100" 2>/dev/null) || return 1

    # Same canary as cr_signal_probe: a valid payload is a JSON array (possibly
    # empty); anything else is a query/parse failure (rc 1), distinct from a
    # well-formed array whose CodeRabbit status simply carries no description.
    local kind
    kind=$(printf '%s' "$json" | jq -r 'if type=="array" then "array" else empty end' 2>/dev/null || true)
    [ "$kind" = "array" ] || return 1

    # First identity match (newest-first). An absent status yields "" — the
    # caller only reaches this on state=skipped, where a status provably exists.
    printf '%s\n' "$(printf '%s' "$json" | jq -r --arg ctx "$ctx" --argjson uid "$uid" '
        [ .[]?
          | select(.creator.id == $uid)
          | select(.creator.type == "Bot")
          | select(.context == $ctx)
        ] | first | (.description // "")' 2>/dev/null || true)"
    return 0
}

cr_signal_probe() {
    local owner="$1" name="$2" sha="$3"
    local uid ctx
    uid=$(cr_signal_bot_id)
    ctx=$(cr_signal_context)

    if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$sha" ]; then return 1; fi
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac

    local json
    json=$(_crs_gh api "repos/$owner/$name/commits/$sha/statuses?per_page=100" 2>/dev/null) || return 1

    # Canary FIRST: a valid payload is a JSON array (possibly empty). An error
    # object or a parse failure yields empty here -> cannot evaluate (rc 1),
    # which is distinct from a well-formed array that simply has no CodeRabbit
    # status in it ("absent"). Collapsing those two would recreate the bug this
    # file exists to kill.
    local kind
    kind=$(printf '%s' "$json" | jq -r 'if type=="array" then "array" else empty end' 2>/dev/null || true)
    [ "$kind" = "array" ] || return 1

    # Identity match on creator.id (+ type Bot), context as the secondary filter.
    # First match wins = newest = current verdict (see ORDERING above).
    # The `skip` remap happens HERE, inside the single projection, so every
    # caller of both cr_signal_state and cr_signal_probe gets it by construction
    # — the mistake this file exists to prevent is a second place that reads
    # CodeRabbit's verdict and disagrees with this one. Output contract is
    # unchanged ("<state> <created_at>"), so no caller has to be taught a new
    # shape; `skipped` simply joins the state vocabulary.
    local pair state created
    pair=$(printf '%s' "$json" | jq -r --arg ctx "$ctx" --argjson uid "$uid" --arg skip "$_CRS_SKIP_RE" --arg ok "$_CRS_OK_RE" '
        [ .[]?
          | select(.creator.id == $uid)
          | select(.creator.type == "Bot")
          | select(.context == $ctx)
        ] | first
          | if . == null then "absent "
            else
              # a success is green ONLY if the description
              # affirmatively matches the allow-list. The deny-list is kept as a
              # force-skip override (CR_SKIP_DESC_RE), so a wording can still be
              # condemned explicitly even if it would pass the allow-list.
              # a MISSING / null / EMPTY description is held to the
              # same allow-list as any other wording, so it reads as skipped
              # (fail closed). The form scoped the allow-list to a
              # non-empty description and left this shape green. CodeRabbit has
              # never been observed to emit it (24 sampled real payloads all
              # carried a description), so the fail-closed reading costs
              # nothing today; if the App ever drops the field, widen
              # CR_OK_DESC_RE as the release valve (recipe in the file header).
              # The test fixtures that model a real green carry the observed
              # wording "Review completed" for the same reason.
              ( if (.state == "success")
                   and ( (((.description // "") | test($skip; "i")))
                         or ((((.description // "") | test($ok; "i"))) | not) )
                then "skipped" else .state end ) as $s
              | "\($s) \(.created_at // "")"
            end' 2>/dev/null || true)

    state=${pair%% *}
    created=${pair#* }

    # Page-limit guard (coderabbit-2). This endpoint returns EVERY status for the
    # SHA — undeduped — so a repo with many CI contexts each posting several
    # updates can exceed one page (~20 contexts x 6 updates = 120). A "no match"
    # on a FULL page is therefore not proof of absence: CodeRabbit's verdict may
    # sit on page two, and reporting "absent" there would be a false BLOCK that
    # no amount of waiting clears.
    #
    # Only the no-match case is ambiguous. Because the API is newest-first, a
    # match ON page one IS the newest CodeRabbit status by construction — later
    # pages hold only older ones — so a found verdict needs no pagination.
    if [ "$state" = "absent" ]; then
        local count
        count=$(printf '%s' "$json" | jq -r 'length' 2>/dev/null || true)
        case "$count" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$count" -ge 100 ] 2>/dev/null; then
            printf 'paged \n'
            return 0
        fi
    fi

    case "$state" in
        success|pending|failure|error|absent|skipped)
            printf '%s %s\n' "$state" "$created"
            return 0 ;;
        *) return 1 ;;
    esac
}
