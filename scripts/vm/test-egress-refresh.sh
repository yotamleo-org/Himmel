#!/usr/bin/env bash
# test-egress-refresh.sh — hermetic suite for scripts/vm/ci-runner/egress-refresh.sh:
# the allow-list the himmel-vm guest loads covers the hosts the shell-unit-shard
# job reaches. getent, curl and nft are stubs; the jq filter is real.
#
# Fixture: hosts and addresses were resolved on 2026-10-18 and the CIDRs copied
# from api.github.com/meta that cover them (web/api/git, same entries in each).
#
# Platform guard (linux-only): the SUT drives nft.
# shellcheck disable=SC2015  # `check && ok || bad` is the suite's assertion idiom
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/scripts/vm/ci-runner/egress-refresh.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-egress-refresh.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
case "$2" in
    api.github.com) echo "140.82.121.5 STREAM $2" ;;
    github.com) echo "140.82.121.3 STREAM $2" ;;
    codeload.github.com) echo "140.82.121.10 STREAM $2" ;;
    objects.githubusercontent.com|release-assets.githubusercontent.com) echo "185.199.108.133 STREAM $2" ;;
    results-receiver.actions.githubusercontent.com) echo "140.82.114.21 STREAM $2" ;;
    archive.ubuntu.com|security.ubuntu.com|pypi.org|files.pythonhosted.org|registry.npmjs.org) echo "203.0.113.9 STREAM $2" ;;
    *) echo "getent stub: unexpected host $2" >&2; exit 2 ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" https://api.github.com/meta "*) cat "$STUB/meta.json" ;;
    *) echo "curl stub: unexpected URL $*" >&2; exit 22 ;;
esac
EOF
cat > "$TMP/bin/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/nft.argv"
EOF
chmod +x "$TMP/bin/"*
cat > "$TMP/meta.json" <<'EOF'
{"web":["140.82.112.0/20","185.199.108.0/22"],"api":["140.82.112.0/20","185.199.108.0/22"],"git":["140.82.112.0/20","185.199.108.0/22"],"packages":[],"actions":["140.82.112.0/20"],"hooks":["192.30.252.0/22"]}
EOF

# run <sut> — loads the allow-list through the stubs; the nft calls land in nft.argv.
run() {
    export STUB="$TMP"
    : > "$TMP/nft.argv"
    PATH="$TMP/bin:$PATH" bash "$1" > "$TMP/out" 2>&1
}
loaded() { awk -v c="$1" 'index($0, "add element inet himmel_egress allowed4 {") == 1 && index($0, c) { f = 1 } END { exit !f }' "$TMP/nft.argv"; }

echo "T1 the loaded allow-list covers every host the shard job reaches"
run "$SUT"; rc=$?
[ "$rc" -eq 0 ] && ok "egress-refresh exits 0 on a good /meta" || bad "egress-refresh rc=$rc: $(cat "$TMP/out")"
# host -> the /meta CIDR that holds its address
for pair in github.com=140.82.112.0/20 codeload.github.com=140.82.112.0/20 api.github.com=140.82.112.0/20 \
            results-receiver.actions.githubusercontent.com=140.82.112.0/20 \
            objects.githubusercontent.com=185.199.108.0/22 release-assets.githubusercontent.com=185.199.108.0/22; do
    host="${pair%%=*}"; cidr="${pair#*=}"
    loaded "$cidr" && ok "$host is covered ($cidr loaded)" || bad "$host is not covered: $cidr never loaded"
done
loaded "203.0.113.9" && ok "the package mirrors are loaded" || bad "no package mirror address loaded"

echo "T2 mutation: a filter that drops web/api/git/actions leaves the hosts uncovered"
sed 's#\[\.web, \.api, \.git, \.packages, \.actions\]#[.hooks]#' "$SUT" > "$TMP/egress-refresh-mut.sh"
cmp -s "$SUT" "$TMP/egress-refresh-mut.sh" && bad "the mutation changed nothing"
run "$TMP/egress-refresh-mut.sh"
if loaded "140.82.112.0/20"; then bad "mutated SUT still loaded the GitHub range (the coverage rows are vacuous)"; else ok "mutated SUT no longer covers github.com (the T1 rows go RED)"; fi

echo "T3 an empty /meta fails closed"
echo '{}' > "$TMP/meta.json"
run "$SUT"; rc=$?
[ "$rc" -ne 0 ] && ok "no ranges -> non-zero (the host loop refuses to serve)" || bad "empty /meta exited 0"

echo
echo "egress-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
