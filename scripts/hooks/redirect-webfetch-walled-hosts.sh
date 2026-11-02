#!/usr/bin/env bash
# redirect-webfetch-walled-hosts.sh — himmel project-lane entry for the WebFetch
# redirect on login-walled hosts (x.com, instagram.com, ...). The rule lives in
# one file, marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh
# (adopter repos get it through the himmel-ops plugin); this shim keeps the
# project wiring working by running it against this checkout's scripts/web
# (scripts/web/walled-hosts.conf and fetch-url.sh). Its JSONL row stays ON, so a
# session where the plugin lane does not fire (plugin disabled or cached at an
# older version) still logs the deny; when both lanes fire, they claim the deny by
# its tool_use_id and one row is written. It SOURCES the plugin
# file rather than exec'ing it, so the launcher's sourced-file check verifies the
# bytes it runs against the integrity pins. Fails OPEN if the plugin source is
# absent. Bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the launching shell. Spec:
# scripts/hooks/test-redirect-webfetch-walled-hosts-plugin.sh
# and scripts/hooks/test-redirect-webfetch-walled-hosts.sh.
here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/../../marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh" ] && [ -r "$here/../../marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh" ] || exit 0
export WALLED_TOOLING_DIR="$here/../web"
. "$here/../../marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh"
