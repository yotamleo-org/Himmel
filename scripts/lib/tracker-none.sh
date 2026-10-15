#!/usr/bin/env bash
# tracker-none.sh — "no tracker" backend for the tracker seam.
# Sourced by tracker.sh; not run directly. No id is required, there is no
# status lifecycle and no panel, so reads are rc 4 ("no such thing", callers
# skip) and writes are no-ops. The one exception is id_new: a CR deferral still
# needs a durable follow-up (I4), so it mints silently in the local store.

_tracker_none_id_pattern() { :; }

_tracker_none_id_new() { _tracker_local_id_new "$@"; }

_tracker_none_get() { return 4; }
_tracker_none_title() { return 4; }
_tracker_none_transition() { return 0; }
_tracker_none_comment() { return 0; }
_tracker_none_link() { return 0; }
_tracker_none_query() { return 0; }
