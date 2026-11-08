#!/usr/bin/env bash
# test-message-classes.sh - the lint of scripts/telegram/message-classes.json.
#
# The table is the one owner of every message kind's class. This suite fails when a control kind is reclassified, when a
# control kind's pinned call leaves its sender, when a cadence worker or a Grafana rule has no row, when a family row is
# too wide, and when an escalate sample does not fit the cap after the plain-words rule. It names each control kind's
# sender file so scripts/cr/impacted-suites.sh also lists it for a PR on that sender:
#   scripts/lib/merge-block-alert.sh   scripts/hooks/detect-token-in-output.sh   scripts/lib/config-audit.sh
#   scripts/handover/chief-kit/chief-wait.sh   scripts/telegram/poller.ts   scripts/station-ops/recover.sh
#   scripts/security/security-audit-cadence.sh   scripts/security/snyk-scan-cadence.sh   docs/handover/running-a-chief.md
#
# ponytail: the pin check is a text match on the sender file, not a data-flow proof, so a non-trust PR could pass another kind beside the pinned call; upgrade path = a trust-path helper per control kind, filed as its own ticket (a ponytail line may not carry the key)
# shellcheck disable=SC2016  # the emitter fixtures are literal single-quoted lines that must not expand
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TABLE="$REPO/scripts/telegram/message-classes.json"
T="$(mktemp -d "${TMPDIR:-/tmp}/message-classes.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
cd "$REPO" || exit 1
PASS=0; FAILN=0

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAILN=$((FAILN + 1)); echo "not ok - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; return 0; }

# the lint: every check but the samples, in python so a table copy and a sender overlay are plain arguments
cat > "$T/lint.py" <<'PY'
import json, os, re, subprocess, sys, tempfile

CONTROL = ["merge-blocked", "token-in-output", "hold-ask-operator", "hold-ask-stuck", "denial-stuck", "config-audit",
           "monitor-chat-down", "chief-reply", "recover-failed", "cadence:security-audit", "cadence:snyk-scan"]
METHOD3 = ["vault-stall", "vm-maintain-cadence", "graph-channel-publish", "librarian"]
FAMILY = re.compile(r"^cadence:[a-z0-9]+-[a-z0-9]+-")
CALL = re.compile(r"(?:cadence-alert\.sh|\$ALERT|\$alert)[\"']?\s+fail\s+(\S+)")
EMIT = re.compile(r"cadence-alert\.sh[\"']?\s+fail\s+(\S+)")
slug = lambda w: re.sub(r"[^A-Za-z0-9_-]", "_", w)

a = sys.argv[1:]
opt = {"--table": None, "--repo": None, "--overlay": None, "--emitters-file": None, "--only": None}
while a:
    k = a.pop(0)
    opt[k] = a.pop(0)
table, repo = json.load(open(opt["--table"])), opt["--repo"]
only = set(opt["--only"].split(",")) if opt["--only"] else None
rows = table["kinds"]
errs = []
want = lambda c: only is None or c in only
err = lambda c, m: errs.append("LINT %s: %s" % (c, m))


def find(rel):
    for base in (opt["--overlay"], repo):
        if base and os.path.isfile(os.path.join(base, rel)):
            return os.path.join(base, rel)
    return None


def resolve(kind):
    for r in rows:
        if r["kind"] == kind:
            return r
    for r in rows:
        k = r["kind"]
        if k.endswith("*") and k.count("*") == 1 and FAMILY.match(k) and kind.startswith(k[:-1]):
            return r
    return None


def code_text(path):
    return "\n".join(l for l in open(path, encoding="utf-8", errors="replace").read().split("\n") if not l.lstrip().startswith(("#", "//")))


by = {}
for r in rows:
    by.setdefault(r["kind"], []).append(r)
for k, v in by.items():
    if len(v) > 1:
        err("rows", "kind %s appears %d times" % (k, len(v)))

if want("control"):
    for k in CONTROL:
        r = by.get(k, [None])[0]
        if r is None or r["class"] != "escalate":
            err("control", "%s must be an escalate row (it is %s)" % (k, r["class"] if r else "missing"))

if want("pins"):
    for r in rows:
        if "pin" in r:
            p = find(r["sender"])
            if p is None:
                err("pins", "%s: sender %s not found" % (r["kind"], r["sender"]))
            elif r["pin"] not in code_text(p):
                err("pins", "%s: pin %r is not in %s as code" % (r["kind"], r["pin"], r["sender"]))

if want("cadence-silent"):
    for r in rows:
        if r["kind"].startswith("cadence:") and r["class"] == "silent":
            err("cadence-silent", "%s is silent" % r["kind"])

if want("family"):
    for r in rows:
        k = r["kind"]
        if "*" in k and not (k.count("*") == 1 and k.endswith("*") and FAMILY.match(k)):
            err("family", "%s is not a family row of at least cadence:<word>-<word>-*" % k)

known = []
if want("workers1"):
    files = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True, text=True).stdout.split("\n")
    for rel in files:
        if not rel.endswith((".sh", ".py", ".ts", ".mjs", ".js", ".bash")):
            continue
        base = os.path.basename(rel)
        if base.startswith("test-") or ".test." in base or "/tests/" in "/" + rel or "/fixtures/" in "/" + rel:
            continue
        p = os.path.join(repo, rel)
        if not os.path.isfile(p):
            continue
        for line in open(p, encoding="utf-8", errors="replace"):
            if line.lstrip().startswith(("#", "//")):
                continue
            m = CALL.search(line)
            if not m:
                continue
            w = m.group(1).strip("\"'")
            if not w or any(c in w for c in "<$…"):
                continue
            if resolve("cadence:" + slug(w)) is None:
                err("workers1", "cadence worker %s (%s) has no row cadence:%s" % (w, rel, slug(w)))

if want("workers2"):
    home, vault = tempfile.mkdtemp(), tempfile.mkdtemp()
    env = dict(os.environ, HOME=home, LINT_VAULT=vault, PATH=os.environ["LINT_STUB_PATH"])
    for cmd in [l for l in open(opt["--emitters-file"]).read().split("\n") if l.strip()]:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, env=env, cwd=repo)
        if p.returncode != 0:
            err("workers2", "emitter exited %d: %s :: %s" % (p.returncode, cmd, p.stderr.strip().split("\n")[0][:120]))
            continue
        ws = EMIT.findall(p.stdout)
        if not ws:
            err("workers2", "emitter printed no fail line: " + cmd)
        for w in ws:
            w = w.strip("\"'")
            if resolve("cadence:" + slug(w)) is None:
                err("workers2", "cadence worker %s (runner printed by %s) has no row cadence:%s" % (w, cmd, slug(w)))

if want("method3"):
    for w in METHOD3:
        r = resolve("cadence:" + w)
        if r is None:
            err("method3", "worker %s has no row" % w)
            continue
        p = find(r["sender"])
        if p is None or not re.search(r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % re.escape(w), open(p, encoding="utf-8", errors="replace").read()):
            err("method3", "worker %s: its literal is not in %s" % (w, r["sender"]))

if want("grafana"):
    text = open(os.path.join(repo, "scripts/observability/provisioning/alerting/rules.yaml")).read()
    titles = re.findall(r'^\s+title: "(.*)"$', text, re.M)
    if not titles:
        err("grafana", "no rule title found in rules.yaml")
    for t in titles:
        k = "cadence:" + slug("grafana-" + re.sub(r"[^A-Za-z0-9_.-]", "_", t)[:64])
        if k not in by:
            err("grafana", "rule %r has no exact row %s" % (t, k))
    if "cadence:grafana-DatasourceNoData" not in by:
        err("grafana", "cadence:grafana-DatasourceNoData has no row")

if want("senders"):
    for r in rows:
        if find(r["sender"]) is None:
            err("senders", "%s: sender %s does not exist" % (r["kind"], r["sender"]))
    chief = by.get("chief-reply", [{}])[0]
    if chief.get("sender") != "docs/handover/running-a-chief.md":
        err("senders", "chief-reply's sender must be docs/handover/running-a-chief.md")

print("\n".join(errs))
sys.exit(1 if errs else 0)
PY

# the samples: each escalate row's sample fits the cap after the plain-words rule and names no bare label or number
cat > "$T/samples.ts" <<'TS'
import { readFileSync } from "node:fs";
import { briefText } from "/__REPO__/scripts/telegram/key-brief";
const [table, mirror] = process.argv.slice(2);
const t = JSON.parse(readFileSync(table, "utf8"));
const errs: string[] = [];
for (const r of t.kinds) {
  if (r.class !== "escalate") continue;
  if (r.sample === undefined) { if (r.cap !== "none") errs.push(`LINT samples: ${r.kind} is an escalate row with no sample`); continue; }
  const s = briefText(r.sample, mirror, r["ref-word"] ?? "PR");
  if (s.length > t.cap) errs.push(`LINT samples: ${r.kind}: sample is ${s.length} characters after the plain-words rule, the cap is ${t.cap}`);
  if (/(?<!worker )(?<![A-Za-z0-9-])N[0-9]+[a-z]*(?![A-Za-z0-9])/i.test(s)) errs.push(`LINT samples: ${r.kind}: sample names a bare worker label`);
  if (/(^|[ (])#[0-9]+/.test(s)) errs.push(`LINT samples: ${r.kind}: sample names a bare #number`);
}
console.log(errs.join("\n"));
process.exit(errs.length ? 1 : 0);
TS
sed "s#/__REPO__#$REPO#" "$T/samples.ts" > "$T/samples-run.ts" && mv "$T/samples-run.ts" "$T/samples.ts"

# stubs the four emitters need to render their runner under a temp HOME, and the emitters themselves
mkdir -p "$T/stub" "$T/fx"
for s in crontab qmd claude graphify; do printf '#!/bin/sh\nexit 0\n' > "$T/stub/$s"; chmod +x "$T/stub/$s"; done
export LINT_STUB_PATH="$T/stub:/usr/bin:/bin"
cat > "$T/emitters" <<'EM'
bash scripts/luna/qmd-cadence.sh arm --dry-run
bash scripts/luna/graphmap-cadence.sh arm --with-publish --vault "$LINT_VAULT" --dry-run
bash scripts/luna/graphmap-cadence.sh arm --luna-only --with-luna-semantic --api-account A --vault "$LINT_VAULT" --dry-run
bash scripts/luna/pipeline-cadence.sh arm --vault "$LINT_VAULT" --dry-run
bash scripts/upstreams/upstream-watch-cadence.sh arm --dry-run
EM

lint_clean() { # <name> <args...>: the lint must pass
  local name="$1"; shift
  local out
  if out="$(python3 -I "$T/lint.py" --repo "$REPO" "$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi
}
lint_dirty() { # <name> <substring of the expected error> <args...>: the lint must fail, for that reason
  local name="$1" want="$2"; shift 2
  local out; if out="$(python3 -I "$T/lint.py" --repo "$REPO" "$@" 2>&1)"; then fail "$name (the lint passed)"; elif [[ "$out" == *"$want"* ]]; then pass "$name"; else fail "$name (wrong reason)" "$out"; fi
}
mut() { # <out.json> <python statements over t>: a copy of the table, changed
  python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(t,open(sys.argv[2],"w"))' "$TABLE" "$1" "$2"
}
emitter() { printf '%s\n' "$1" > "$T/emitters-one"; }

command -v bun >/dev/null 2>&1 || { fail "bun is on PATH"; echo "1..$((PASS + FAILN))"; exit 1; }

# 1. every escalate row's sample fits the cap after the rule and names no bare label or number
if out="$(bun run "$T/samples.ts" "$TABLE" "$REPO/scripts/telegram/fixtures/jira-mirror" 2>&1)"; then pass "every escalate sample fits the cap and names no bare label"; else fail "every escalate sample fits the cap and names no bare label" "$out"; fi
mut "$T/long-sample.json" 'for r in t["kinds"]:
    if r["kind"]=="merge-blocked": r["sample"]="Merge refused. Blocks: x. "+"word "*120+"Do: y"'
if bun run "$T/samples.ts" "$T/long-sample.json" "$REPO/scripts/telegram/fixtures/jira-mirror" >/dev/null 2>&1; then fail "a sample over the cap fails the lint"; else pass "a sample over the cap fails the lint"; fi
mut "$T/bare-num.json" 'for r in t["kinds"]:
    if r["kind"]=="merge-blocked": r["sample"]="Merge refused: #4882. Blocks: x. Do: y"'
if bun run "$T/samples.ts" "$T/bare-num.json" "$REPO/scripts/telegram/fixtures/jira-mirror" >/dev/null 2>&1; then fail "a bare #number in a sample fails the lint"; else pass "a bare #number in a sample fails the lint"; fi

# 2. the control kinds are escalate
lint_clean "control kinds are escalate" --table "$TABLE" --only control
mut "$T/token-silent.json" '[r.update({"class":"silent"}) for r in t["kinds"] if r["kind"]=="token-in-output"]'
lint_dirty "token-in-output set to silent fails the lint" "token-in-output must be an escalate row" --table "$T/token-silent.json" --only control
mut "$T/reply-silent.json" '[r.update({"class":"silent"}) for r in t["kinds"] if r["kind"]=="chief-reply"]'
lint_dirty "chief-reply set to silent fails the lint" "chief-reply must be an escalate row" --table "$T/reply-silent.json" --only control

# 3. each pin is in its sender file as code
lint_clean "each control row's pin is in its sender file" --table "$TABLE" --only pins
mkdir -p "$T/ov1/scripts/security" "$T/ov2/scripts/security"
sed 's/fail snyk-scan/fail snyk-renamed/g' "$REPO/scripts/security/snyk-scan-cadence.sh" > "$T/ov1/scripts/security/snyk-scan-cadence.sh"
lint_dirty "a sender copy with the pinned call renamed fails the lint" "cadence:snyk-scan: pin" --table "$TABLE" --only pins --overlay "$T/ov1"
printf '#!/usr/bin/env bash\n# fail snyk-scan is only a comment here\necho snyk-scan\n' > "$T/ov2/scripts/security/snyk-scan-cadence.sh"
lint_dirty "a sender whose only snyk-scan is a comment fails the lint" "cadence:snyk-scan: pin" --table "$TABLE" --only pins --overlay "$T/ov2"

# 4. no cadence row is silent
lint_clean "no cadence row is silent" --table "$TABLE" --only cadence-silent
mut "$T/vault-silent.json" '[r.update({"class":"silent"}) for r in t["kinds"] if r["kind"]=="cadence:vault-stall"]'
lint_dirty "cadence:vault-stall set to silent fails the lint" "cadence:vault-stall is silent" --table "$T/vault-silent.json" --only cadence-silent

# 5. the family floor
lint_clean "the two family rows are long enough" --table "$TABLE" --only family
for bad in 'cadence:*' 'cadence:grafana-*' 'cadence:graphmap-*'; do
  mut "$T/fam.json" "t['kinds'].append({'kind':'$bad','class':'monitor','sender':'scripts/luna/graphmap-cadence.sh'})"
  lint_dirty "a family row $bad fails the lint" "is not a family row" --table "$T/fam.json" --only family
done

# 6. every cadence worker has a row: method 1 (literal call sites), method 2 (runner bodies), method 3 (variable-held)
lint_clean "every cadence worker found at a call site has a row" --table "$TABLE" --only workers1
mut "$T/no-doctor.json" 't["kinds"]=[r for r in t["kinds"] if r["kind"]!="cadence:himmel-doctor"]'
lint_dirty "a call-site worker with no row fails the lint" "cadence worker himmel-doctor" --table "$T/no-doctor.json" --only workers1
lint_clean "every worker in the four emitters' runner bodies has a row" --table "$TABLE" --only workers2 --emitters-file "$T/emitters"
emitter 'printf "%s\n" "x/cadence-alert.sh fail graphmap-new \"rc-\$_rc\" \"\$log\""'
lint_dirty "a fixture runner printing fail graphmap-new with no row fails the lint" "graphmap-new" --table "$TABLE" --only workers2 --emitters-file "$T/emitters-one"
emitter 'printf "%s\n" "x/cadence-alert.sh fail fetch-new probe-bad \"\$log\""'
lint_dirty "a fixture runner printing fail fetch-new probe-bad with no row fails the lint" "fetch-new" --table "$TABLE" --only workers2 --emitters-file "$T/emitters-one"
emitter 'echo nothing to see'
lint_dirty "an emitter whose dry run prints no fail line fails the lint" "printed no fail line" --table "$TABLE" --only workers2 --emitters-file "$T/emitters-one"
emitter 'echo broken >&2; exit 2'
lint_dirty "an emitter that exits 2 fails the lint" "emitter exited 2" --table "$TABLE" --only workers2 --emitters-file "$T/emitters-one"
emitter 'printf "%s\n" "x/cadence-alert.sh fail qmd-reindex \"rc-\$_rc\""'
lint_clean "a fixture runner printing a worker that has a row passes" --table "$TABLE" --only workers2 --emitters-file "$T/emitters-one"
lint_clean "every variable-held worker has its literal in its sender" --table "$TABLE" --only method3

# 7. every rules.yaml rule has an exact grafana row, and DatasourceNoData has one
lint_clean "every rules.yaml rule has an exact row" --table "$TABLE" --only grafana
mut "$T/no-watcher.json" 't["kinds"]=[r for r in t["kinds"] if r["kind"]!="cadence:grafana-Watcher_down"]'
lint_dirty "a rule with no row fails the lint" "Watcher down" --table "$T/no-watcher.json" --only grafana
mut "$T/no-nodata.json" 't["kinds"]=[r for r in t["kinds"] if r["kind"]!="cadence:grafana-DatasourceNoData"]'
lint_dirty "cadence:grafana-DatasourceNoData without a row fails the lint" "DatasourceNoData" --table "$T/no-nodata.json" --only grafana

# 8. every row's sender exists, and chief-reply's is the chief doc
lint_clean "every row's sender exists" --table "$TABLE" --only senders
mut "$T/bad-sender.json" '[r.update({"sender":"scripts/no/such-sender.sh"}) for r in t["kinds"] if r["kind"]=="worker-silent"]'
lint_dirty "a row whose sender is missing fails the lint" "does not exist" --table "$T/bad-sender.json" --only senders

# 9. the whole lint on the real table
lint_clean "the whole lint passes on the real table" --table "$TABLE" --emitters-file "$T/emitters"

echo "1..$((PASS + FAILN)) pass=$PASS fail=$FAILN"
[ "$FAILN" -eq 0 ]
