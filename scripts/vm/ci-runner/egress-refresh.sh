#!/usr/bin/env bash
# egress-refresh.sh — installed in the CI runner guest as
# /usr/local/sbin/himmel-ci-egress-refresh and run as root by the host loop
# after every boot, BEFORE a runner is minted. It fills the
# himmel_egress allow-list sets (allowed4 / allowed6) that
# guest-provision.sh's nftables.conf leaves empty, so a freshly restored guest
# reaches nothing but the NAT DNS until this has run:
#   1. api.github.com, resolved, so /meta can be fetched;
#   2. GitHub's published ranges (api.github.com/meta: web, api, git, packages,
#      actions), which cover github.com, codeload, objects, ghcr and the
#      Actions runner service. The artifact/cache blob storage hosts are not in
#      /meta; whether jobs need them is settled by the live proof;
#   3. the package mirrors the shell-unit shards use, resolved.
# Any failure, or an empty /meta, exits non-zero: the host loop then refuses to
# serve a job. Nothing here widens the private-range rejects in nftables.conf.
#
# ponytail: the mirror hosts are resolved once per boot, so a CDN that rotates
# its address mid-job can make a later fetch fail closed (the shard goes red,
# nothing leaks), and DNS itself stays an open channel to the NAT resolver;
# upgrade is an allow-listing HTTP(S) proxy on the host.
set -euo pipefail

BOOTSTRAP_HOST=api.github.com
MIRROR_HOSTS="archive.ubuntu.com security.ubuntu.com pypi.org files.pythonhosted.org registry.npmjs.org"

v4=""
v6=""
collect() { # one address or CIDR per line on stdin
    local a
    while IFS= read -r a; do
        case "$a" in
            '') ;;
            *:*) v6="$v6${v6:+, }$a" ;;
            [0-9]*.*) v4="$v4${v4:+, }$a" ;;
        esac
    done
}
resolve() { getent ahosts "$1" | awk '{ print $1 }' | sort -u; }
load() {
    [ -z "$v4" ] || nft add element inet himmel_egress allowed4 "{ $v4 }"
    [ -z "$v6" ] || nft add element inet himmel_egress allowed6 "{ $v6 }"
    v4=""; v6=""
}

addrs="$(resolve "$BOOTSTRAP_HOST")" || addrs=""
collect <<<"$addrs"
[ -n "$v4$v6" ] || { echo "egress-refresh: $BOOTSTRAP_HOST did not resolve" >&2; exit 1; }
load

meta="$(curl -fsS --max-time 30 "https://$BOOTSTRAP_HOST/meta")" || { echo "egress-refresh: could not fetch $BOOTSTRAP_HOST/meta" >&2; exit 1; }
ranges="$(printf '%s' "$meta" | jq -r '[.web, .api, .git, .packages, .actions] | map(. // []) | add | .[]')" \
    || { echo "egress-refresh: could not parse $BOOTSTRAP_HOST/meta" >&2; exit 1; }
collect <<<"$ranges"
[ -n "$v4$v6" ] || { echo "egress-refresh: /meta carried no ranges" >&2; exit 1; }
load

for h in $MIRROR_HOSTS; do
    addrs="$(resolve "$h")" && [ -n "$addrs" ] || { echo "egress-refresh: mirror host $h did not resolve" >&2; exit 1; }
    collect <<<"$addrs"
done
load
echo "egress-refresh: allow-list loaded"
