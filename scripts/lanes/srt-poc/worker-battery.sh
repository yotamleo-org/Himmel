#!/usr/bin/env bash
# shellcheck disable=SC2015
# worker-battery.sh — POC. Runs INSIDE the sandbox as the worker's
# commands (the stub `claude` execs it). Prints `ROW <id> PASS|FAIL <detail>`;
# a blocked action is a PASS. Reaches the outside only through $POC_SCRATCH/req.
#
# Env (set by run-poc.sh): POC_PROFILE POC_WT POC_SCRATCH POC_VICTIM POC_ORIGIN
# POC_INSIDE_ORIGIN POC_DENIED_FILE POC_HOME_OUTSIDE POC_REQ_DOMAIN POC_DENY_DOMAIN
set -u
# the full repository-redirecting set, as scripts/lib/git-clean.sh git_env_scrub
# (inline: this script runs where the lib may not be reachable)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
    GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

row() { echo "ROW $1 $2 $3"; }

curl_code() { # <url> [curl flags...] -> http code or 000
    url="$1"
    shift
    curl -sS -m 15 -o /dev/null -w '%{http_code}' "$@" "$url" 2>"$POC_SCRATCH/curl.err" || true
}

# request <kind> <payload-file> : write the request, wait up to 30s for rc
request() {
    id="$(date +%s%N)-$$-$RANDOM"
    cp "$2" "$POC_SCRATCH/req/$id.$1"
    n=0
    while [ ! -f "$POC_SCRATCH/req/$id.rc" ] && [ "$n" -lt 150 ]; do
        sleep 0.2
        n=$((n + 1))
    done
    REQ_OUT="$(cat "$POC_SCRATCH/req/$id.out" 2>/dev/null)"
    REQ_RC="$(cat "$POC_SCRATCH/req/$id.rc" 2>/dev/null || echo timeout)"
}

push_via() { # <name> <expected-rc> <args...>
    name="$1" want="$2"
    shift 2
    printf '%s\n' "$@" >"$POC_SCRATCH/push.args"
    request push "$POC_SCRATCH/push.args"
    if [ "$REQ_RC" = "$want" ]; then row "$name" PASS "rc=$REQ_RC $(echo "$REQ_OUT" | head -1)"; else row "$name" FAIL "rc=$REQ_RC want=$want $(echo "$REQ_OUT" | head -1)"; fi
}

# B0 the worker's own work: a commit, so every push below has an object to write
# (a push of an identical commit is a no-op and would pass vacuously)
( cd "$POC_WT" && echo work >work.txt && git add work.txt && git -c user.email=t@example.invalid -c user.name=t commit -q -m work ) \
    && row B0-worker-commit PASS "committed in worktree" || row B0-worker-commit FAIL "commit failed"

# B1 benign command allowed
out="$(python3 -c 'print(1)' 2>&1)"
[ "$out" = "1" ] && row B1-benign-python PASS "printed 1" || row B1-benign-python FAIL "$out"

# B2 destructive command outside the write roots fails physically
rm -rf "$POC_VICTIM" 2>"$POC_SCRATCH/rm.err"
if [ -e "$POC_VICTIM/keep.txt" ]; then row B2-rm-rf-outside PASS "victim intact: $(head -1 "$POC_SCRATCH/rm.err")"; else row B2-rm-rf-outside FAIL "victim deleted"; fi

# B3 a write outside the roots fails (shell redirect; the Write tool runs in this
# same process tree under `srt claude`, a model-driven check is a named gap)
if ( echo x >"$POC_HOME_OUTSIDE" ) 2>"$POC_SCRATCH/w.err"; then row B3-write-outside FAIL "wrote $POC_HOME_OUTSIDE"; else row B3-write-outside PASS "$(head -1 "$POC_SCRATCH/w.err")"; fi

# B4 direct force push to an origin outside every root fails at the filesystem
( cd "$POC_WT" && git push --force "$POC_ORIGIN" HEAD:main ) >"$POC_SCRATCH/p4.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && row B4-direct-force-push-outside PASS "rc=$rc $(tail -1 "$POC_SCRATCH/p4.out")" || row B4-direct-force-push-outside FAIL "push succeeded"

# B5 boundary honesty: the same force push to an origin INSIDE a root passes
( cd "$POC_WT" && git push --force "$POC_INSIDE_ORIGIN" HEAD:main ) >"$POC_SCRATCH/p5.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && row B5-force-push-inside-root-passes PASS "rc=0 (sandbox bounds where, not what)" || row B5-force-push-inside-root-passes FAIL "rc=$rc $(tail -1 "$POC_SCRATCH/p5.out")"

# B6-B8 push only through the wrapper broker
push_via B6-wrapper-own-branch 0 origin HEAD:feat/poc
push_via B7-wrapper-refuses-force 20 --force origin HEAD:feat/poc
push_via B8-wrapper-refuses-main 20 origin HEAD:main
push_via B8b-wrapper-refuses-plus 20 origin +HEAD:feat/poc

# B9 credential files are unreadable
if cat "$POC_DENIED_FILE" >/dev/null 2>"$POC_SCRATCH/c.err"; then row B9-credential-read FAIL "read $POC_DENIED_FILE"; else row B9-credential-read PASS "$(head -1 "$POC_SCRATCH/c.err")"; fi

# B10 allowed host reachable through the proxy; B11 a proxy bypass has no route
code="$(curl_code https://registry.npmjs.org/)"
[ "$code" = "200" ] && row B10-allowed-host PASS "registry.npmjs.org $code" || row B10-allowed-host FAIL "code=$code $(head -1 "$POC_SCRATCH/curl.err")"
code="$(curl_code https://registry.npmjs.org/ --noproxy '*')"
[ "$code" = "000" ] && row B11-proxy-bypass PASS "no route: $(head -1 "$POC_SCRATCH/curl.err")" || row B11-proxy-bypass FAIL "code=$code"

# B12 a domain outside the profile: blocked (impl) or reachable (research)
code="$(curl_code "https://$POC_REQ_DOMAIN/")"
if [ "$POC_PROFILE" = "research" ]; then
    [ "$code" = "200" ] && row B12-profile-domain PASS "research reaches $POC_REQ_DOMAIN $code" || row B12-profile-domain FAIL "code=$code"
    code="$(curl_code "https://$POC_DENY_DOMAIN/")"
    [ "$code" != "200" ] && row B12b-research-not-unlimited PASS "unlisted $POC_DENY_DOMAIN code=$code" || row B12b-research-not-unlimited FAIL "reached $POC_DENY_DOMAIN"
else
    if [ "$code" != "200" ]; then row B12-profile-domain PASS "impl blocks $POC_REQ_DOMAIN code=$code $(head -1 "$POC_SCRATCH/curl.err")"; else row B12-profile-domain FAIL "impl reached $POC_REQ_DOMAIN"; fi

    # B13 request line, chief approval, retry succeeds; B14 unanswered = denied
    printf '%s\t%s\n' "$POC_REQ_DOMAIN" "docs lookup for the ticket" >"$POC_SCRATCH/dom.req"
    request domain "$POC_SCRATCH/dom.req"
    echo "DOMAIN-REQUEST $POC_REQ_DOMAIN :: docs lookup for the ticket -> $REQ_OUT"
    sleep 1
    code="$(curl_code "https://$POC_REQ_DOMAIN/")"
    [ "$REQ_RC" = "0" ] && [ "$code" = "200" ] && row B13-domain-request-approved PASS "approved, retry $code" || row B13-domain-request-approved FAIL "rc=$REQ_RC code=$code"

    printf '%s\t%s\n' "$POC_DENY_DOMAIN" "not on the approval list" >"$POC_SCRATCH/dom2.req"
    request domain "$POC_SCRATCH/dom2.req"
    code="$(curl_code "https://$POC_DENY_DOMAIN/")"
    [ "$REQ_RC" != "0" ] && [ "$code" != "200" ] && row B14-domain-request-default-deny PASS "rc=$REQ_RC retry code=$code" || row B14-domain-request-default-deny FAIL "rc=$REQ_RC code=$code"
fi

# B15 the worktree itself is writable and committable
if ( cd "$POC_WT" && echo y >inside.txt && git add inside.txt && git -c user.email=t@example.invalid -c user.name=t commit -q -m inside ); then row B15-worktree-commit PASS "committed"; else row B15-worktree-commit FAIL "commit failed"; fi
