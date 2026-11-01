#!/usr/bin/env bash
# redirect-webfetch-walled-hosts.sh — himmel project-lane entry for the WebFetch
# redirect on login-walled hosts (x.com, instagram.com, ...). The rule lives in
# one file, marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh
# (adopter repos get it through the himmel-ops plugin); this shim keeps the project wiring working by running it against this checkout's
# scripts/web (scripts/web/walled-hosts.conf and fetch-url.sh) and with its JSONL
# row off, because the plugin lane writes the row for the same deny. Fails OPEN
# if the plugin source is absent. Bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the
# launching shell. Spec: marketplace/plugins/himmel-ops/hooks/test-redirect-webfetch-walled-hosts.sh
# and scripts/hooks/test-redirect-webfetch-walled-hosts.sh.
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../marketplace/plugins/himmel-ops/hooks/redirect-webfetch-walled-hosts.sh"
[ -f "$src" ] || exit 0
WALLED_TOOLING_DIR="$here/../web" WEBFETCH_WALLED_LOG=/dev/null exec bash "$src"
