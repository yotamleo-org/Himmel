# shellcheck shell=sh
# scripts/lib/clear-stale-claude-marker.sh -- source from ~/.zshrc / ~/.bashrc.
#
# WHY: claude exports CLAUDE_CODE_CHILD_SESSION=1 and CLAUDE_PID=<its pid> into
# every process it spawns, and a claude that inherits the marker runs with
# transcript saving OFF. On macOS `open -a` hands the caller's whole environment
# to an app it launches (probed 2026-10-31, SCRUM-2), so an app first opened
# from a claude Bash tool (iTerm, Raycast, Obsidian) carries that marker for its
# whole life: every tab it opens, and every claude started there, saves no
# transcript and the claude-hud has nothing to read.
#
# The marker is genuine only while the claude that set it is an ancestor of
# this shell. Anything else (that claude has exited, or the shell descends from
# a long-lived app that merely inherited it) is stale, so drop it. A shell a
# live claude spawned keeps it: its CLAUDE_PID is always an ancestor, because
# claude overwrites CLAUDE_PID with its own pid for its children.
#
# Usage:  [ -f /path/to/himmel/scripts/lib/clear-stale-claude-marker.sh ] && \
#           . /path/to/himmel/scripts/lib/clear-stale-claude-marker.sh
# POSIX sh, so bash and zsh can both source it. Silent; a no-op without markers.

_himmel_claude_marker_live() {
    [ -n "${CLAUDE_PID:-}" ] || return 1
    _hcm_p=$$
    while [ -n "$_hcm_p" ] && [ "$_hcm_p" -gt 1 ] 2>/dev/null; do
        [ "$_hcm_p" = "$CLAUDE_PID" ] && return 0
        _hcm_p=$(ps -o ppid= -p "$_hcm_p" 2>/dev/null | tr -d ' ')
    done
    return 1
}

if [ -n "${CLAUDE_CODE_CHILD_SESSION:-}${CLAUDE_PID:-}" ] && ! _himmel_claude_marker_live; then
    # Same list headed-arm.sh / arm-resume.sh clear for a fresh session, plus
    # CLAUDECODE.
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDECODE CLAUDE_CODE_SESSION_ID \
        CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_JOB_DIR
fi
unset _hcm_p
unset -f _himmel_claude_marker_live
