#!/usr/bin/env bash
# scripts/cr/test-outside-security-audit.sh - suite for scripts/cr/outside-security-audit.sh, the
# stage-2 audit of an unlisted outside author's PR (rows T3.1-T3.25 of the outside-PR plan; T3.5,
# T3.18 and T3.23 live in test-pr-check-outside.sh and test-check-ci.sh).
# Fixture: a bare "origin" whose refs/pull/7/head holds each row's PR, a "primary" clone the audit
# runs in, and a temp anchor holding a copy of the audit, the real ledger writer and libraries, and
# stubs for gh, ready-check.sh --outside, check-ci.sh, pr-check-outside.sh --fetch-only,
# trust_path_check and critic-first-pass.sh. No row calls a model or the network, and no PR file
# is executed (T3.12). Bash 3.2-safe apart from the gh stub; needs git, jq, node.
# shellcheck disable=SC2030,SC2031  # per-row env is set in subshells on purpose
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/outside-audit-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac; }
sha() { sha256sum < "$1" | cut -d' ' -f1; } # read-sink-ok: hashes the suite's own fixture files

A="$tmp/anchor"; LOG="$tmp/log"
mkdir -p "$A/scripts/cr/perspectives" "$A/scripts/lib" "$A/scripts/ci" "$A/scripts/handover/chief-kit" "$LOG" "$tmp/bin"
[ -f "$HERE/outside-security-audit.sh" ] && cp "$HERE/outside-security-audit.sh" "$A/scripts/cr/"
for f in ledger-append.sh anchor-handoff.sh ledger-amend-auth.js known-findings.json critics.json; do cp "$HERE/$f" "$A/scripts/cr/$f"; done
for f in outside-contributors.sh timeout-bin.sh git-clean.sh coderabbit-signal.sh prim.sh; do cp "$HERE/../lib/$f" "$A/scripts/lib/$f"; done
cp "$HERE/../ci/outside-lint-surface.txt" "$A/scripts/ci/"
AUDIT="$A/scripts/cr/outside-security-audit.sh"
PERSP="$A/scripts/cr/perspectives/outside-security.md"
printf '# fixture outside-security perspective\n' > "$PERSP"
cat > "$A/scripts/handover/chief-kit/ready-check.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = --outside ] || exit 2
printf 'outside-pr: %s\n' "${RC_ANSWER:-yes}"
STUB
cat > "$A/scripts/check-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LOG/checkci.argv"
r=""; for v in CR_APP CR_PROFILE CR_BOT_USER_ID CHECK_CI_DISTINCT_DEADLINE; do if [ -n "${!v+x}" ]; then r="$r $v=${!v}"; else r="$r $v=unset"; fi; done
printf '%s\n' "${r# }" > "$LOG/checkci.env"
exit "${STUB_CHECKCI_RC:-0}"
STUB
cat > "$A/scripts/cr/pr-check-outside.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LOG/pco.argv"; printf '%s\n' "${HIMMEL_REPO:-}" > "$LOG/pco.repo"
[ "$#" -eq 5 ] && [ "$1" = --pr ] && [ "$3" = --head ] && [ "$5" = --fetch-only ] || exit 2
[ "${STUB_PCO_RC:-0}" = 0 ] || exit "$STUB_PCO_RC"
git fetch -q --no-tags origin "+refs/pull/$2/head:refs/himmel/outside/$2" || exit 2
echo "outside-pr: yes $2 $4 ${STUB_BRANCH:-feat/outside-thing} base=main authorized=fetch-only"
STUB
cat > "$A/scripts/lib/go-gate.sh" <<'STUB'
trust_path_check() { printf '%s\n' "$*" > "$LOG/tp.argv"; if [ "${STUB_TP_RC:-0}" != 0 ]; then echo "list unreadable"; return "$STUB_TP_RC"; fi; echo "${STUB_TP_OUT:-none}"; }
STUB
cat > "$A/scripts/cr/critic-first-pass.sh" <<'STUB'
#!/usr/bin/env bash
touch "$LOG/critic.called"
printf '%s\n' "$*" > "$LOG/critic.argv"
r=""; for v in CR_TARGET_PR CR_TARGET_HEAD CR_TARGET_BRANCH CRITIC_KNOWN_FINDINGS CRITICS_BASE_JSON CR_LEDGER CRITIC_FIRST_PASS_CAP_BYTES CRITIC_PERSPECTIVES; do
    if [ -n "${!v+x}" ]; then r="$r $v=${!v}"; else r="$r $v=unset"; fi; done
printf '%s\n' "${r# }" > "$LOG/critic.env"
cat > "$LOG/critic.stdin"
sleep "${STUB_CRIT_SLEEP:-0}"
rc="${STUB_CRIT_RC:-0}"
case "$rc" in 0|4) ;; *) exit "$rc" ;; esac
[ -z "${STUB_CRIT_OUT:-}" ] || printf '%s\n' "$STUB_CRIT_OUT"
if [ "${STUB_CRIT_NOROW:-0}" != 1 ]; then
    bash "$(dirname "$0")/ledger-append.sh" score --branch "$CR_TARGET_BRANCH" --head "$CR_TARGET_HEAD" --model outside-security \
        --responding-model gpt-6.1-sol --critical "${STUB_CRIT_C:-0}" --important "${STUB_CRIT_I:-0}" --suggestions 0 \
        --dropped "${STUB_CRIT_D:-0}" --raw-path "$LOG/raw" >/dev/null 2>&1 || echo "stub: score append failed" >&2
fi
exit "$rc"
STUB
chmod +x "$A/scripts/handover/chief-kit/ready-check.sh" "$A/scripts/check-ci.sh" "$A/scripts/cr/pr-check-outside.sh" "$A/scripts/cr/critic-first-pass.sh"
# The anchor is a primary checkout, as the audit requires: a real repository with a .git directory.
{ git -c init.defaultBranch=main init -q "$A" && git -C "$A" add -A \
    && git -C "$A" -c user.email=t@t.test -c user.name=tester -c commit.gpgsign=false commit -q -m anchor; } \
    || { echo "FAIL: fixture anchor checkout" >&2; exit 1; }
cr_row() { printf '{"context":"%s","state":"%s","description":"%s","created_at":"2026-11-11T00:00:00Z","creator":{"id":%s,"login":"x[bot]","type":"Bot"}}' "$2" "$3" "$4" "$1"; }
CR_OK="[$(cr_row 136622811 CodeRabbit success 'Review completed')]"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "pr view") printf '{"author":{"login":"Stranger","id":"U_stranger"},"headRefName":"%s","headRefOid":"%s","baseRefName":"main","state":"%s"}\n' \
        "${STUB_BRANCH:-feat/outside-thing}" "$STUB_OID" "${STUB_STATE:-OPEN}" ;;
    "repo view") printf '{"owner":{"login":"acme"},"name":"widget","defaultBranchRef":{"name":"main"}}\n' ;;
    "api repos/acme/widget/commits/"*/statuses*) printf '%s\n' "$STUB_CR_STATUSES" ;;
    *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

O="$tmp/origin.git"; W="$tmp/work"; P="$tmp/primary"; CANARY="$tmp/canary"
git init -q --bare -b main "$O"
(
    git -c init.defaultBranch=main init -q "$W" && cd "$W" || exit 1
    git config user.email t@t.test; git config user.name tester; git config commit.gpgsign false
    mkdir -p docs scripts/ci pkg
    echo base > f.txt
    printf 'keep\nold \342\200\256line\n' > bidi.txt
    printf '{"name":"x","scripts":{"test":"echo t","postinstall":"echo a"}}\n' > package.json
    printf '{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/a":{"version":"1.0.0","resolved":"https://registry.npmjs.org/a/-/a-1.0.0.tgz"}}}\n' > package-lock.json
    echo doc > docs/a.md; echo lint > scripts/ci/lintme.sh; echo 'registry=https://registry.npmjs.org/' > pkg/.npmrc
    git add -A && git commit -q -m base && git remote add origin "$O" && git push -q origin main
) || { echo "FAIL: fixture setup" >&2; exit 1; }
git clone -q "$O" "$P"
for k in diff.evil.command diff.evil.textconv filter.evil.clean filter.evil.smudge; do git -C "$P" config "$k" "touch $CANARY"; done
GCD="$P/.git"; LEDGER="$GCD/cr-critic-scores.jsonl"

# newpr '<shell run in the work tree>': commits it on a branch off main and serves it as PR 7; sets H.
newpr() {
    (cd "$W" && git checkout -q -B prwork main && eval "$1" && git -c advice.addEmbeddedRepo=false add -A && git commit -q --allow-empty -m "pr $RANDOM") || { fail "fixture: $1"; return 1; }
    H=$(git -C "$W" rev-parse HEAD)
    git -C "$W" push -q -f origin HEAD:refs/pull/7/head
}
reset() { rm -f "$LEDGER" "$LOG"/* "$CANARY"; rm -rf "$GCD/outside-audits"; git -C "$P" update-ref -d refs/himmel/outside/7 2>/dev/null; return 0; }
# audit [VAR=value ...]: runs the anchor's copy from the primary, HIMMEL_REPO naming the anchor; sets out, err, rc.
audit() {
    out=$(cd "$P" && env HOME="$tmp/home" PATH="$tmp/bin:$PATH" LOG="$LOG" HIMMEL_REPO="$A" STUB_OID="${STUB_OID:-$H}" STUB_CR_STATUSES="${STUB_CR_STATUSES:-$CR_OK}" "$@" \
        bash "$AUDIT" --pr 7 --head "$H" 2>"$tmp/err"); rc=$?
    err=$(cat "$tmp/err")
}
audits() { [ -f "$LEDGER" ] && jq -c 'select(.kind == "security-audit")' "$LEDGER" | wc -l | tr -d ' ' || echo 0; }
last() { jq -sr --arg f "$1" '[.[] | select(.kind == "security-audit")] | last | .[$f] | if type == "array" then join(",") else tostring end' "$LEDGER" 2>/dev/null; }
called() { [ -e "$LOG/critic.called" ] && echo yes || echo no; }
expect_row() {
    eq "$rc" 0 "$1: exit 0"; eq "$(audits)" 1 "$1: one audit row"
    eq "$(last verdict)" "$2" "$1: verdict $2"; eq "$(last hard)" "$3" "$1: hard [$3]"
}
expect_none() { eq "$rc" "$2" "$1: exit $2"; eq "$(audits)" 0 "$1: no audit row"; }
mkdir -p "$tmp/home"

reset; newpr 'printf "hello \342\200\256evil\n" >> f.txt'
audit
expect_row "T3.1 a diff adding a U+202E line" fail H1
has "$out" "outside-audit: fail $GCD/outside-audits/7-$H-" "T3.1 prints the verdict and the report path"
reset; newpr 'echo clean >> f.txt'
audit
expect_row "T3.1 control: a clean diff for the same fixture" pass ""
rpt="$(last report)"
eq "$( [ -f "$rpt" ] && sha "$rpt")" "$(last report_sha256)" "T3.1 control: report_sha256 is the report's sha256"
eq "$(last perspective_sha256)" "$(sha "$PERSP")" "T3.1 control: the row carries the perspective's sha256"
eq "$(last base_sha)" "$(git -C "$W" rev-parse main)" "T3.1 control: base_sha is the merge base"
eq "$(last auditor)/$(last model)/$(last branch)/$(last pr)" "codex/gpt-6.1-sol/feat/outside-thing/7" "T3.1 control: auditor, model, branch and pr"
eq "$(cd "$P" && HOME="$tmp/home" bash -c '. "$1"; outside_audit_passed 7 "$2" feat/outside-thing && echo yes || echo no' _ "$A/scripts/lib/outside-contributors.sh" "$H")" yes \
    "T3.1 control: outside_audit_passed accepts the head once its pass row exists"
reset
eq "$(cd "$P" && HOME="$tmp/home" bash -c '. "$1"; outside_audit_passed 7 "$2" feat/outside-thing && echo yes || echo no' _ "$A/scripts/lib/outside-contributors.sh" "$H")" no \
    "T3.1 control: and refuses it with no row"
[ -f "$AUDIT" ] || { printf 'FAIL - outside-security-audit.sh is absent; %s row(s) failed\n' "$fails"; exit 1; }

reset; newpr 'echo two >> f.txt'
audit STUB_CR_STATUSES='[]'
expect_none "T3.2 no CodeRabbit status" 6
has "$err" "CodeRabbit" "T3.2 the refusal names CodeRabbit"
eq "$(called)" no "T3.2 no critic call"
# T1.59's four fixtures, each with its own one-variable mutation check (drop that -u; the row must turn).
# The mutant sits beside the audit in the anchor, so it loads the same libraries and stubs.
MUT="$A/scripts/cr/outside-security-audit-mut.sh"
mutate() {
    local label="$1" prog="$2" keep="$AUDIT"; shift 2
    sed "$prog" "$AUDIT" > "$MUT"
    if cmp -s "$AUDIT" "$MUT"; then fail "T3.2 $label: the mutation changed nothing"; rm -f "$MUT"; return; fi
    reset; AUDIT="$MUT"; audit "$@"; AUDIT="$keep"; rm -f "$MUT"
    eq "$rc/$(audits)" "0/1" "T3.2 $label: the mutant passes stage 1 and writes a row, so the row is not hollow"
}
cr_case() {
    local label="$1" leak="$2" statuses="$3" var="$4"
    reset; audit "$leak" STUB_CR_STATUSES="$statuses"
    expect_none "T3.2 $label" 6
    mutate "$label: mutation (drop -u $var)" "s/ -u $var / /" "$leak" STUB_CR_STATUSES="$statuses"
}
cp "$AUDIT" "$tmp/pristine.sh"
cr_case "an exported CR_OK_DESC_RE does not widen a Review in progress" CR_OK_DESC_RE=. "[$(cr_row 136622811 CodeRabbit success 'Review in progress')]" CR_OK_DESC_RE
cr_case "an exported CR_BOT_USER_ID does not pick a decoy status" CR_BOT_USER_ID=4242 "[$(cr_row 136622811 CodeRabbit pending 'Review in progress'),$(cr_row 4242 CodeRabbit success 'Review completed')]" CR_BOT_USER_ID
cr_case "an exported CR_STATUS_CONTEXT does not pick a decoy context" CR_STATUS_CONTEXT=Decoy "[$(cr_row 136622811 CodeRabbit pending 'Review in progress'),$(cr_row 136622811 Decoy success 'Review completed')]" CR_STATUS_CONTEXT
reset; audit CR_OK_DESC_RE=. CR_SKIP_DESC_RE=nomatch STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit success 'Review skipped: automatic reviews are disabled')]"
expect_none "T3.2 exported CR_OK_DESC_RE and CR_SKIP_DESC_RE do not pass a skip" 6
mutate "skip pair: mutation (drop both -u; a lone -u CR_SKIP_DESC_RE is not independently falsifiable)" \
    "s/ -u CR_OK_DESC_RE / /; s/ -u CR_SKIP_DESC_RE / /" \
    CR_OK_DESC_RE=. CR_SKIP_DESC_RE=nomatch STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit success 'Review skipped: automatic reviews are disabled')]"
eq "$(sha "$AUDIT")" "$(sha "$tmp/pristine.sh")" "T3.2 the mutation copies left the audit untouched"

reset; audit STUB_CHECKCI_RC=1; expect_none "T3.3 check-ci exit 1" 6; eq "$(called)" no "T3.3 no critic call"
reset; audit STUB_CHECKCI_RC=2; expect_none "T3.3 check-ci exit 2 (DEADLINE-PENDING)" 6
has "$err" "check-ci" "T3.3 the refusal names check-ci"
reset; audit CR_APP=0 CR_PROFILE=none CR_BOT_USER_ID=4242 CHECK_CI_DISTINCT_DEADLINE=1
eq "$(cat "$LOG/checkci.argv" 2>/dev/null)" "7 --max-wait 120 --except-context codeowner-review-gate" "T3.22 check-ci argv is exact"
eq "$(cat "$LOG/checkci.env" 2>/dev/null)" "CR_APP=unset CR_PROFILE=unset CR_BOT_USER_ID=unset CHECK_CI_DISTINCT_DEADLINE=unset" "T3.22 check-ci sees the four vars unset"
reset; newpr 'mkdir -p .github/workflows && echo x > .github/workflows/x.yml'
audit; expect_none "T3.3 a diff touching the lint surface" 6
has "$err" "16d" "T3.3 the lint-surface refusal names 16d"
reset; newpr 'git mv scripts/ci/lintme.sh docs/lintme.sh'
audit; expect_none "T3.3 a rename out of the lint surface (the old path counts)" 6

reset; newpr 'echo four >> f.txt'
audit STUB_OID=0123456789012345678901234567890123456789; expect_none "T3.4 headRefOid moved" 2
reset; audit STUB_STATE=CLOSED; expect_none "T3.4 a closed PR" 2
reset; audit RC_ANSWER=no; expect_none "T3.4 a PR that is not outside" 2
eq "$(called)" no "T3.4 no critic call"
reset; out=$(cd "$P" && bash "$AUDIT" --pr 7 --head abc 2>&1); rc=$?; eq "$rc" 2 "T3.4 a short head is a usage error"

# The audit runs only as the copy of the primary checkout HIMMEL_REPO names.
reset; newpr 'echo anchor >> f.txt'
AW="$tmp/anchor-wt"
git -C "$A" worktree add -q --detach "$AW" 2>/dev/null || fail "fixture: a linked worktree of the anchor"
keep="$AUDIT"; AUDIT="$AW/scripts/cr/outside-security-audit.sh"; audit HIMMEL_REPO="$AW"; AUDIT="$keep"
expect_none "a linked worktree's copy, with HIMMEL_REPO naming that worktree" 2
has "$err" "the anchor's primary checkout" "a linked worktree's copy: the refusal names the anchor's primary checkout"
reset
BC="$tmp/auditcopy"; cp -R "$A" "$BC"
# shellcheck disable=SC2016  # expands when the copy sources it
printf '\ntouch "$LOG/sourced"\n' >> "$BC/scripts/lib/timeout-bin.sh"
keep="$AUDIT"; AUDIT="$BC/scripts/cr/outside-security-audit.sh"; audit; AUDIT="$keep"
expect_none "a branch copy run by absolute path, with HIMMEL_REPO naming the primary checkout" 2
has "$err" "the anchor's primary checkout" "a branch copy: the refusal names the anchor's primary checkout"
if [ -e "$LOG/sourced" ]; then fail "a branch copy sourced its own timeout-bin.sh before the anchor check"; else pass "a branch copy is refused before any source"; fi
reset; ln -s "$A" "$tmp/anchor-link"
audit HIMMEL_REPO="$tmp/anchor-link"
eq "$rc/$(audits)" "0/1" "HIMMEL_REPO spelled through a symlink to the anchor writes the row"
eq "$(cat "$LOG/pco.repo" 2>/dev/null)" "$tmp/anchor-link" "the pr-check-outside.sh call receives the caller's HIMMEL_REPO, not the audit's own root"

for cp in 342200252 342200253 342200254 342200255 342200256 342201246 342201247 342201250 342201251 \
          342200213 342200214 342200215 342200216 342200217 357273277; do
    b="\\${cp:0:3}\\${cp:3:3}\\${cp:6:3}"
    reset; newpr "printf 'x${b}y\n' >> f.txt"
    audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H1" "T3.6 H1 on an added line carrying \\$cp"
done
reset; newpr 'printf "keep\n" > bidi.txt'
audit; expect_row "T3.6 a removed U+202E line is no hit" pass ""

h2() { reset; newpr "$1"; audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H2" "$2"; }
h2 'echo "* text" > .gitattributes' "T3.7 H2 adds .gitattributes"
h2 'printf "[submodule \"x\"]\n" > .gitmodules' "T3.7 H2 adds .gitmodules"
h2 'mkdir -p .githooks && echo x > .githooks/pre-commit' "T3.7 H2 adds a file under .githooks/"
h2 'mkdir -p .husky && echo x > .husky/pre-push' "T3.7 H2 adds a file under .husky/"
h2 'mkdir -p .husky && git mv docs/a.md .husky/a.md' "T3.7 H2 a rename into .husky/"
h2 'echo "x=1" >> pkg/.npmrc' "T3.7 H2 edits an .npmrc"
h2 'git rm -q pkg/.npmrc' "T3.7 H2 deletes an .npmrc"
h2 'echo "x=1" > .npmrc' "T3.15 H2 adds .npmrc"
h2 'echo "[test]" > bunfig.toml' "T3.15 H2 adds bunfig.toml"
h2 'mkdir -p plugins/p/hooks && echo "{}" > plugins/p/hooks/hooks.json' "T3.15 H2 adds hooks/hooks.json"
h2 'echo "{}" > .mcp.json' "T3.15 H2 adds .mcp.json"
h2 'mkdir -p .claude && echo "{}" > .claude/settings.json' "T3.15 H2 adds .claude/settings.json"
h2 'mkdir -p sub && echo "x: 1" > sub/.coderabbit.yaml' "T3.15 H2 adds a .coderabbit.yaml (nested; the root one is lint surface, 16d)"
h2 'mkdir -p sub && echo "x: 1" > sub/.coderabbit.yml' "T3.15 H2 adds a .coderabbit.yml (nested)"
# shellcheck disable=SC2016  # the snippet expands inside newpr's eval
h2 'd=$(printf "x\nq"); mkdir -p "$d" && echo "y=1" > "$d/.npmrc"' "T3.15 H2 an .npmrc under a directory whose name holds a newline"
reset; newpr 'echo .coderabbit.yaml >> docs/a.md'
audit; expect_row "T3.7 a file whose text names .coderabbit.yaml is no hit" pass ""

for k in preinstall install prepare prepack postpack prepublish preprepare postprepare; do
    reset; newpr "printf '{\"name\":\"x\",\"scripts\":{\"test\":\"echo t\",\"postinstall\":\"echo a\",\"$k\":\"echo b\"}}\n' > package.json"
    audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H3" "T3.8 H3 a package.json gains $k"
done
reset; newpr "mkdir -p sub && printf '{\"scripts\":{\"postinstall\":\"x\"}}\n' > sub/package.json"
audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H3" "T3.8 H3 a new package.json carrying postinstall"
reset; newpr "printf '{\n  \"scripts\": {\n    \"postinstall\": \"echo CHANGED\",\n    \"test\": \"echo t\"\n  },\n  \"name\": \"x\"\n}\n' > package.json"
audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H3" "T3.15 H3 a reformatted package.json whose postinstall changed in value"
reset; newpr "printf '{\n  \"scripts\": {\n    \"postinstall\": \"echo a\",\n    \"test\": \"echo t\"\n  },\n  \"name\": \"x\"\n}\n' > package.json"
audit; expect_row "T3.15 H3 a package.json that only reorders keys is no hit" pass ""
reset; newpr "printf '{\"name\":\"x\",\"scripts\":{\"test\":\"echo other\",\"postinstall\":\"echo a\"}}\n' > package.json"
audit; expect_row "T3.8 a changed non-lifecycle script is no hit" pass ""
reset; newpr "printf '{\"name\":' > package.json"
audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H3" "T3.15 H3 an unparsable package.json"

# shellcheck disable=SC2329  # called from the fixture snippets newpr evals
lock() { printf '{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/a":{"version":"1.0.0","resolved":"https://registry.npmjs.org/a/-/a-1.0.0.tgz"},"node_modules/b":{"version":"1.0.0",%s}}}\n' "$1"; }
h4() { reset; newpr "$1"; audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H4" "$2"; }
h4 "lock '\"resolved\":\"git+ssh://git@github.com/evil/b.git#abc\"' > package-lock.json" "T3.9 H4 a package-lock git source"
h4 "lock '\"resolved\":\"file:../b\"' > package-lock.json" "T3.9 H4 a package-lock file source"
h4 "lock '\"resolved\":\"../b\",\"link\":true' > package-lock.json" "T3.9 H4 a package-lock link entry"
h4 "lock '\"resolved\":\"https://evil.example/b-1.0.0.tgz\"' > package-lock.json" "T3.9 H4 a package-lock http source on another host"
h4 "printf '{\"lockfileVersion\":' > package-lock.json" "T3.15 H4 an unparsable package-lock.json"
h4 "printf '{\n  \"packages\": {\n    \"b\": [\"b@github:evil/b#abc\", \"\", {}, \"\"],\n  }\n}\n' > bun.lock" "T3.9 H4 a bun.lock git source"
h4 "d=\$(printf 'd\303\274'); mkdir -p \"\$d\" && printf '\"b\": [\"b@github:evil/b#abc\", \"\", {}, \"\"],\n' > \"\$d/bun.lock\"" "T3.9 H4 a bun.lock git source under a path git quotes"
h4 "printf '[[package]]\nname = \"b\"\nsource = { git = \"https://evil.example/b.git\" }\n' > uv.lock" "T3.9 H4 a uv.lock git source"
reset; newpr "lock '\"resolved\":\"https://registry.npmjs.org/b/-/b-1.0.0.tgz\"' > package-lock.json"
audit; expect_row "T3.9 a package-lock entry on the default registry is no hit" pass ""

h5() { reset; newpr "$1"; audit; eq "$rc/$(last verdict)/$(last hard)" "0/fail/H5" "$2"; }
h5 'ln -s /etc/passwd link' "T3.15 H5 a mode 120000 entry"
h5 'git init -q vendored && git -C vendored -c user.email=t@t.test -c user.name=t commit -q --allow-empty -m v' "T3.15 H5 a mode 160000 entry"
rm -rf "$W/vendored"

reset; newpr 'echo ten >> f.txt'
audit STUB_CRIT_C=1; expect_row "T3.10 a score row with critical 1" fail ""
eq "$(last critical_n)" 1 "T3.10 critical_n comes from the score row"
reset; audit STUB_CRIT_I=2; expect_row "T3.10 Important only" flagged ""
eq "$(last important_n)" 2 "T3.10 important_n comes from the score row"
reset; audit; expect_row "T3.10 no finding" pass ""
reset; audit STUB_CRIT_OUT='## Critical Issues (1 found)
- [outside-security-1] f.txt:1 a claim on stdout only'
expect_row "T3.10 stdout claiming a Critical with a zero-count row" pass ""
reset; audit STUB_CRIT_RC=1; expect_none "T3.11 critic exit 1" 7
reset; audit STUB_CRIT_RC=5; expect_none "T3.11 critic exit 5" 7
reset; audit STUB_CRIT_RC=2; expect_none "T3.11 critic exit 2" 7
reset; audit STUB_CRIT_RC=4 STUB_CRIT_D=1 STUB_CRIT_OUT='## Dropped Citations (1 dropped)
- [outside-security-1] DROPPED-BULLET-TEXT nowhere.sh:9'
expect_row "T3.11 critic exit 4" flagged ""
eq "$(last critic_exit)" 4 "T3.11 the row records critic_exit 4"
has "$(cat "$(last report)" 2>/dev/null)" "DROPPED-BULLET-TEXT" "T3.11 the report holds the dropped text"
reset; audit STUB_CRIT_NOROW=1; expect_none "T3.11 no score row" 7
reset; audit STUB_CRIT_D=1; expect_row "T3.16 dropped_n 1 and no other finding" flagged ""
eq "$(last dropped_n)" 1 "T3.16 dropped_n comes from the score row"

reset
(cd "$P" && bash "$A/scripts/cr/ledger-append.sh" score --branch feat/outside-thing --head "$H" --model outside-security --responding-model gpt-6.1-sol \
    --critical 0 --important 0 --suggestions 0 --dropped 0 --raw-path /x >/dev/null 2>&1)
audit STUB_CRIT_NOROW=1; expect_none "T3.24 a pre-existing zero-count score row and a critic that wrote none" 7

reset
newpr "mkdir -p .githooks scripts/cr && printf 'touch \"%s\"\n' '$CANARY' | tee test-evil.sh .githooks/pre-commit scripts/cr/pr-check-context.sh >/dev/null && printf '* diff=evil filter=evil\n' > .gitattributes && printf '{\"scripts\":{\"postinstall\":\"touch $CANARY\"}}\n' > package.json && chmod +x test-evil.sh"
fp() { (cd "$GCD" && cat HEAD index config; ls -lA hooks; cat hooks/* 2>/dev/null) | sha256sum | cut -d' ' -f1; }
before=$(fp)
audit
eq "$rc/$(last verdict)" "0/fail" "T3.12 the canary PR is audited (fail on H2, H3)"
if [ -e "$CANARY" ]; then fail "T3.12 a file from the PR ran"; else pass "T3.12 the canary is absent: no PR file ran"; fi
eq "$(fp)" "$before" "T3.12 the primary's HEAD, index, config and hooks are byte-identical"
has "$(cat "$LOG/critic.stdin" 2>/dev/null)" "diff --git" "T3.12 the critic got the diff as text on stdin"

reset; newpr 'echo thirteen >> f.txt'
audit STUB_CRIT_C=1; frpt="$(last report)"
rm -f "$LOG"/*; audit
eq "$rc" 8 "T3.13 a fail row at the head: exit 8"; eq "$(audits)" 1 "T3.13 no new row"; eq "$(called)" no "T3.13 no critic call"
has "$err" "$frpt" "T3.13 the refusal names the report"
printf '# edited perspective\n' > "$PERSP"; rm -f "$LOG"/*; audit
eq "$rc" 8 "T3.13 a fail stays sticky under a changed perspective"
printf '# fixture outside-security perspective\n' > "$PERSP"
for v in pass flagged; do
    reset; if [ "$v" = flagged ]; then audit STUB_CRIT_I=1; else audit; fi
    rm -f "$LOG"/*; audit
    eq "$rc/$(audits)/$(called)" "8/1/no" "T3.17 an ok $v row at the head: exit 8, no new row, no critic call"
done
printf '# a changed perspective\n' > "$PERSP"; rm -f "$LOG"/*; audit
eq "$rc/$(audits)/$(called)" "0/2/yes" "T3.17 under a changed perspective sha the audit runs"
printf '# fixture outside-security perspective\n' > "$PERSP"

reset; newpr 'echo locked >> f.txt'
race() { (cd "$P" && env HOME="$tmp/home" PATH="$tmp/bin:$PATH" LOG="$LOG" HIMMEL_REPO="$A" STUB_OID="$H" STUB_CR_STATUSES="$CR_OK" STUB_CRIT_SLEEP=2 STUB_CRIT_I="$1" \
    bash "$AUDIT" --pr 7 --head "$H" >/dev/null 2>&1; echo "$?" > "$tmp/race.$1"); }
race 0 & r0=$!; race 1 & r1=$!; wait "$r0" "$r1"
eq "$(sort "$tmp/race.0" "$tmp/race.1" | tr '\n' ' ')" "0 8 " "two concurrent runs at one head: one writes, the other finds its row (exit 8)"
eq "$(audits)" 1 "two concurrent runs at one head: one row"
eq "$(jq -c 'select(.kind == "score")' "$LEDGER" | wc -l | tr -d ' ')" 1 "two concurrent runs at one head: one critic call"

reset; newpr 'echo twentyone >> f.txt'
audit STUB_CRIT_I=1; r1="$(last report)"; s1="$(sha "$r1")"
printf '# perspective, edited again\n' > "$PERSP"
audit STUB_CRIT_RC=1
eq "$rc/$(audits)" "7/1" "T3.21 a run under a changed perspective that exits 7 writes no row"
eq "$(sha "$r1")/$(last report_sha256)" "$s1/$s1" "T3.21 the earlier report's bytes and its row's report_sha256 are intact"
printf '# fixture outside-security perspective\n' > "$PERSP"

reset; newpr 'head -c 200000 /dev/zero | tr "\0" "a" | fold -w 100 > big.txt'
audit; expect_none "T3.14 a diff over 192 KiB" 7
has "$err" "bytes" "T3.14 the refusal names the size"
eq "$(called)" no "T3.14 no critic call"
reset; audit CRITIC_FIRST_PASS_CAP_BYTES=99999999 OUTSIDE_AUDIT_CAP_BYTES=99999999 AUDIT_CAP_BYTES=99999999
expect_none "T3.14 the cap ignores raised cap vars in the env" 7
reset; newpr 'echo small >> f.txt'
audit CRITIC_FIRST_PASS_CAP_BYTES=1000
cap=$(sed -n 's/.*CRITIC_FIRST_PASS_CAP_BYTES=\([0-9]*\).*/\1/p' "$LOG/critic.env" 2>/dev/null)
eq "$( [ "${cap:-0}" -gt 196608 ] && echo above || echo "not above ($cap)")" above "T3.14 the critic runs with CRITIC_FIRST_PASS_CAP_BYTES above 192 KiB"

reset; audit CRITICS_BASE_JSON="$tmp/elsewhere.json" CR_LEDGER="$tmp/elsewhere.jsonl" CRITIC_KNOWN_FINDINGS=1 CRITIC_PERSPECTIVES=0
eq "$(cat "$LOG/critic.argv" 2>/dev/null)" "--model gpt-6.1-sol --provider openai-codex --slug outside-security --perspective-file $PERSP" "T3.20 the critic argv"
eq "$(cat "$LOG/critic.env" 2>/dev/null | sed 's/ CRITIC_FIRST_PASS_CAP_BYTES=[0-9]*//')" \
    "CR_TARGET_PR=7 CR_TARGET_HEAD=$H CR_TARGET_BRANCH=feat/outside-thing CRITIC_KNOWN_FINDINGS=0 CRITICS_BASE_JSON=unset CR_LEDGER=unset CRITIC_PERSPECTIVES=1" \
    "T3.20 the critic env: the target seam, no known findings, no registry or ledger redirect"
eq "$rc/$(audits)" "0/1" "T3.20 the row lands in the ledger the audit reads"
if [ -e "$tmp/elsewhere.jsonl" ]; then fail "T3.20 a score row went to the exported CR_LEDGER"; else pass "T3.20 nothing was written to the exported CR_LEDGER"; fi
cp "$A/scripts/cr/critics.json" "$tmp/critics.keep"
jq '.panel |= map(select(.model != "gpt-6.1-sol"))' "$tmp/critics.keep" > "$A/scripts/cr/critics.json"
reset; audit; expect_none "T3.20 a registry with no gpt-6.1-sol row" 7
eq "$(called)" no "T3.20 no critic call without a registry row"
cp "$tmp/critics.keep" "$A/scripts/cr/critics.json"

reset; audit STUB_TP_RC=2; expect_none "T3.19 trust_path_check rc 2" 7
reset; audit STUB_TP_OUT='hit scripts/lib/x.sh'
expect_row "T3.19 a trust-path hit stays pass" pass ""
has "$(cat "$(last report)" 2>/dev/null)" "scripts/lib/x.sh" "T3.19 the hit is flagged in the report"
reset; audit STUB_BRANCH=fork-only-branch
eq "$rc/$(last branch)" "0/fork-only-branch" "T3.19 a fork branch absent from the base repo completes"
eq "$(cat "$LOG/tp.argv" 2>/dev/null)" "acme/widget 7 $H main $A" "T3.19 trust_path_check reads the default branch, never headRefName"
reset; newpr 'printf "\000\001bin" > blob.bin'
audit; expect_row "T3.19 a binary file stays pass" pass ""
has "$(cat "$(last report)" 2>/dev/null)" "blob.bin" "T3.19 the binary file is flagged in the report"

REAL="$HERE/perspectives/outside-security.md"
if [ -f "$REAL" ]; then
    cp "$REAL" "$PERSP"; reset; newpr 'echo twentyfive >> f.txt'; audit
    eq "$rc/$(last perspective_sha256)" "0/$(sha "$REAL")" "T3.25 a run with the real perspective records its sha256"
else
    fail "T3.25 scripts/cr/perspectives/outside-security.md is absent"
fi
for row in '^scripts/cr/outside-security-audit\.sh$' '^scripts/cr/perspectives/outside-security\.md$'; do
    if grep -qxF "$row" "$HERE/../ci/ci-trust-paths.txt"; then pass "T3.25 trust row $row"; else fail "T3.25 trust row $row is missing"; fi
done

if [ "$fails" -eq 0 ]; then echo "PASS test-outside-security-audit.sh"; exit 0; fi
echo "FAIL test-outside-security-audit.sh: $fails"; exit 1
