# shellcheck shell=bash
# scripts/lib/user-claude-md.sh
#
# wire_user_claude_md — append himmel's "working principles" block to a
# user-scope rule file. Those four defaults (think before coding
# / simplicity first / surgical changes / goal-driven execution) used to live
# in himmel's always-on project CLAUDE.md; they are general engineering
# defaults, not himmel invariants, so adopters get them once at user scope
# instead of paying for them in every himmel session.
#
# One TARGET per call, by design: the function is agent-agnostic, so the
# caller invokes it once per harness whose user-scope rule file it wants
# populated -- adopt.sh's do_core() call it twice, once for Claude
# Code's ~/.claude/CLAUDE.md and once for Codex's ~/.codex/AGENTS.md. Hermes
# is not a target: its himmel_agent profile SOUL already states the same four.
#
# The payload is extracted at RUN TIME from the marker range in
# docs/setup/user-scope-claude-md-template.md (the single source of truth),
# never duplicated into this file.
#
# Idempotent / never destructive:
#   - target holds the BEGIN and END marker lines -> the text between them is
#     replaced with the template's block (a no-op when already equal), so a
#     new template line reaches an existing user; text outside is untouched.
#   - target holds a BEGIN marker but no END -> unchanged.
#   - target exists, no marker, but looks like it already states the
#     principles by hand (heuristic phrase match) -> skip, unchanged, with one
#     advisory naming the template path.
#   - target exists, no marker, no heuristic match -> APPEND (blank line +
#     payload), never truncate/overwrite.
#   - target absent -> create it with just the payload.
#
# Provenance: when scripts/lib/provenance.sh is sourced, a
# real append/create records a `block` unit (see _ucm_record_block) so uninstall
# can strip exactly himmel's block. A skip or a dry run records nothing; a
# recording failure only warns -- it never fails the install.
#
# Usage: wire_user_claude_md <template-md-path> <target-claude-md-path>
# Honors $DRY_RUN (0/1, default 0), matching adopt.sh's run()/DRY_RUN
# convention, without depending on adopt.sh's own run() helper (this file is
# also sourced standalone by its test).

# Marker + heuristic phrase are shared between the extractor and the skip
# checks below, so keep them declared once.
_HIMMEL_USER_CLAUDE_MD_MARKER="HIMMEL:working-principles"
_UCM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ponytail: distinctive-phrase heuristic, not a real "did the operator already
# say this" detector -- a hand-written CLAUDE.md that phrases the same idea
# without ever using these two words together would still get appended to.
# Upgrade path: none planned, the cost of a rare double-append (operator just
# deletes the duplicate block) is lower than the cost of a stricter matcher.
_HIMMEL_USER_CLAUDE_MD_HEURISTIC="simplicity first"

# _ucm_record_block <target> <payload> <file_created true|false>
# One provenance `block` row for the block just written, so uninstall can
# tell himmel's block from the operator's own text (its sha is the BEGIN..END
# text, the .ours snapshot holds the same bytes). Best-effort like adopt.sh's
# other recorders: the block is in place whether or not the row lands, and a
# standalone source (this file's own test) without provenance.sh records nothing.
_ucm_record_block() {
  local target="$1" payload="$2" created="$3" op="${4:-insert}" old="${5:-}" row=user-claude-md
  local -a pre=()
  command -v prov_record >/dev/null 2>&1 || return 0
  case "${target##*/}" in AGENTS.md) row=user-agents-md ;; esac
  [ "$op" = replace ] && pre=(--pre-text "$old")
  prov_record "$op" block "$target" --unit himmel-working-principles --scope user --class code \
    --row "$row" --writer adopt.sh --field "marker=\"${_HIMMEL_USER_CLAUDE_MD_MARKER}\"" \
    --field "file_created=$created" ${pre[@]+"${pre[@]}"} --post-text "$payload" \
    || echo "  warning: provenance record failed for $target (uninstall falls back to the template check)" >&2
  return 0
}

wire_user_claude_md() {
  local template="$1" target="$2"

  if [ ! -f "$template" ]; then
    echo "  user CLAUDE.md: template not found at $template — skipping." >&2
    return 0
  fi

  local payload
  payload="$(sed -n "/<!-- BEGIN ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->/,/<!-- END ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->/p" "$template")"
  if [ -z "$payload" ]; then
    echo "  user CLAUDE.md: markers not found in $template — skipping." >&2
    return 0
  fi
  # A sed range whose END address never matches prints through EOF, so a
  # template with BEGIN but no END yields a "payload" of the whole rest of the
  # file — which would then be appended to the user's CLAUDE.md. Refuse unless
  # the extract actually ends on the END marker.
  case "$payload" in
    *"<!-- END ${_HIMMEL_USER_CLAUDE_MD_MARKER} -->") ;;
    *)
      echo "  user CLAUDE.md: $template has a BEGIN marker with no END marker — skipping (refusing to append an unbounded extract)." >&2
      return 0
      ;;
  esac

  if [ -f "$target" ]; then
    # Which lines are himmel's block is decided by the SAME scan the uninstall
    # side runs (unwire-user-claude-md.sh --extract / _ucm_scan): exact marker
    # lines outside code fences, one BEGIN above one END, no CRLF. Anything it
    # refuses (duplicate or open-fence markers, CRLF, BEGIN without END) is left
    # byte-identical with one advisory; rc 3 = no marker line, so the heuristic
    # and append paths below apply as before.
    local unwire="$_UCM_LIB_DIR/unwire-user-claude-md.sh" ext ext_rc=0 scan begin_ln end_ln
    if [ ! -f "$unwire" ]; then
      echo "  user CLAUDE.md: $unwire not found — leaving $target unchanged" >&2
      return 0
    fi
    ext="$(bash "$unwire" --extract "$target" 2>/dev/null)" || ext_rc=$?
    case "$ext_rc" in
      0)
        scan="$(bash -c '. "$1"; _ucm_scan "$2"' _ "$unwire" "$target" 2>/dev/null)" || scan=""
        read -r _ _ begin_ln end_ln _ <<< "$scan"
        case "${begin_ln:-x}${end_ln:-x}" in
          *[!0-9]*)
            echo "  user CLAUDE.md: could not locate the himmel block in $target — leaving it unchanged" >&2
            return 0
            ;;
        esac
        if [ "$ext" = "$payload" ]; then
          echo "  user CLAUDE.md: working-principles block already present — skipping ($target)"
          return 0
        fi
        if [ "${DRY_RUN:-0}" = "1" ]; then
          echo "DRY: refresh working-principles block → $target"
          return 0
        fi
        # Write the finished text next to the file the target resolves to, with
        # that file's mode, then rename it over: a failure at any point leaves the
        # target exactly as it was, and a symlinked target keeps its link.
        local real tmp
        real="$(readlink -f -- "$target" 2>/dev/null)" || real="$target" # gnu-ok: falls back to the unresolved path where readlink -f is absent # prim-ok: canon_path resolves directories, not a file symlink
        if [ ! -w "$real" ]; then
          echo "  user CLAUDE.md: $real is read-only — leaving it unchanged" >&2
          return 1
        fi
        tmp="$(mktemp "$(dirname "$real")/.ucm.XXXXXX")" || {
          echo "  user CLAUDE.md: cannot create a temp file next to $real — leaving it unchanged" >&2
          return 1
        }
        if ! cp -p -- "$real" "$tmp" \
          || ! { head -n "$((begin_ln - 1))" "$real" && printf '%s\n' "$payload" && tail -n "+$((end_ln + 1))" "$real"; } > "$tmp" \
          || ! mv -f -- "$tmp" "$real"; then
          rm -f "$tmp"
          echo "  user CLAUDE.md: could not write $real — leaving it unchanged" >&2
          return 1
        fi
        _ucm_record_block "$target" "$payload" false replace "$ext"
        echo "  user CLAUDE.md: refreshed working-principles block in place → $target"
        return 0
        ;;
      3) ;;
      *)
        echo "  user CLAUDE.md: the himmel marker lines in $target cannot be told apart from text (duplicate, inside an open code fence, CRLF, or BEGIN without END) — leaving it unchanged" >&2
        return 0
        ;;
    esac
    if grep -qi "$_HIMMEL_USER_CLAUDE_MD_HEURISTIC" "$target"; then
      echo "  user CLAUDE.md: no marker, but looks like working principles are already stated by hand (heuristic match on '$_HIMMEL_USER_CLAUDE_MD_HEURISTIC') — skipping, not appending; the current block is in $template ($target)"
      return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "DRY: append working-principles block → $target"
      return 0
    fi
    { printf '\n'; printf '%s\n' "$payload"; } >> "$target" || return 1
    _ucm_record_block "$target" "$payload" false
    echo "  user CLAUDE.md: appended working-principles block → $target"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY: create $target with working-principles block"
    return 0
  fi
  mkdir -p "$(dirname "$target")" || return 1
  printf '%s\n' "$payload" > "$target" || return 1
  _ucm_record_block "$target" "$payload" true
  echo "  user CLAUDE.md: created $target with working-principles block"
}
