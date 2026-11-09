#!/usr/bin/env python3
"""auth-preflight.py -- the objective G0 auth-readiness checklist (design section 11).

  auth-preflight.py --readiness auth-readiness.json --lock tools.lock --card-sha256 HEX
                    [--stance eval-only-reachable|unreadable]

Computes readiness from the private, NON-SECRET record of the trusted provisioning and the
free R4 access probes; a bare passed:true proves nothing. Every item is mandatory:

  1 mechanism: the supported setup-token candidate, its official sources and retrieval date,
    the pinned CLI version/sha256 and the sandbox/settings hashes equal the lock;
  2 provisioning: an authentic operator record of the dedicated eval token/account, date,
    credential-root/path fingerprints, revocation procedure, and independence evidence that is
    more than unchanged local files;
  3 station non-mutation: before/after station credential path/inode/digest equal, no eval and
    station alias, nothing station-side mounted;
  4 stance: the operator's recorded choice, bound to design r18 and this card;
  5 R4: actual no-model probes ran in the locked session shape and every one of the four
    channels (with per-tool subresults) is a definite yes/no; unknown refuses under any
    stance, any readable channel refuses the unreadable stance, and station or other-account
    reachability refuses under every stance;
  6 scrub fixtures passed, revocation recorded, and every proof artifact still has its hash.

The record must be bound to the current tools.lock (a stale record refuses) and must hold no
credential material (any token-shaped value refuses). Prints READY or PAID RUN BLOCKED with
every reason. Exit 0 ready, 3 blocked. Fixtures prove the checklist logic, never live G0.
"""
import argparse, hashlib, json, os, re, sys

MECHANISM = "claude-setup-token/CLAUDE_CODE_OAUTH_TOKEN"
CHANNEL_KEYS = {"bash_env": None, "bash_proc_ancestors": None, "native_proc": ("Read", "Grep", "Glob"),
                "session_home": ("Read", "Grep", "Glob", "Bash")}
PREFIXED = re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}|sk-or-[A-Za-z0-9_-]{8,}")
LONGRUN = re.compile(r"[A-Za-z0-9+/_-]{40,}={0,2}")
HEXSHA = re.compile(r"^[0-9a-f]{64}$")


def secretish(s):
    """A provider-prefixed key, or a long mixed-case alphanumeric run (a bearer/OAuth token shape)."""
    if PREFIXED.search(s):
        return True
    for m in LONGRUN.finditer(s):
        t = m.group(0)
        if sum(c.isdigit() for c in t) >= 2 and any(c.islower() for c in t) and any(c.isupper() for c in t):
            return True
    return False


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def strings(v, path=""):
    if isinstance(v, dict):
        for k, x in v.items():
            yield from strings(x, path + "." + k)
    elif isinstance(v, list):
        for x in v:
            yield from strings(x, path)
    elif isinstance(v, str):
        yield path, v


def check(r, lock, lock_sha, card_sha, stance, base):
    bad = []
    for path, s in strings(r):
        if not HEXSHA.match(s) and not s.startswith("http") and secretish(s):
            bad.append("credential-shaped value at %s: the record must hold no token bytes" % path)
    if r.get("schema") != "rag-pilot-auth-readiness/1":
        bad.append("not an auth-readiness record (a bare pass flag proves nothing)")
        return bad
    if r.get("lock_sha256") != lock_sha:
        bad.append("stale: the record is bound to another tools.lock")
    m = r.get("mechanism") or {}
    if m.get("id") != MECHANISM:
        bad.append("1: mechanism %s is not the reviewed supported candidate" % m.get("id"))
    if not m.get("sources") or not all(str(u).startswith("https://code.claude.com/docs/") for u in m["sources"]) or not m.get("retrieved"):
        bad.append("1: official source URLs and retrieval date are missing")
    files = lock.get("files", {})
    for k, lk in (("cli_sha256", "claude"), ("sandbox_sha256", "sandbox"), ("settings_sha256", "settings")):
        if not m.get(k) or m.get(k) != (files.get(lk) or {}).get("sha256"):
            bad.append("1: %s does not match the locked %s" % (k, lk))
    if m.get("cli_version") != lock.get("constants", {}).get("claude_version"):
        bad.append("1: the CLI version is not the pinned one")
    p = r.get("provisioning") or {}
    for k in ("operator", "date", "eval_account", "credential_root_fingerprint", "path_fingerprint", "revocation_procedure"):
        if not p.get(k):
            bad.append("2: provisioning record lacks %s" % k)
    ind = p.get("independence") or {}
    if ind.get("kind") not in ("separate_eval_identity", "provider_evidence") or not ind.get("evidence"):
        bad.append("2: no independence evidence beyond unchanged local files")
    st = r.get("station_nonmutation") or {}
    if not st.get("before") or st.get("before") != st.get("after"):
        bad.append("3: station credential path/inode/digest changed or was not recorded")
    if st.get("eval_station_alias") is not False or st.get("station_mounted") is not False:
        bad.append("3: an eval/station alias or a station mount is not ruled out")
    s = r.get("stance") or {}
    if s.get("selected") != stance or s.get("design_revision") != "r18" or s.get("card_sha256") != card_sha or not s.get("decision"):
        bad.append("4: the stance is not the recorded %s choice bound to r18 and this card" % stance)
    r4 = r.get("r4") or {}
    if r4.get("ran") is not True or r4.get("shape_sha256") != (files.get("sandbox") or {}).get("sha256"):
        bad.append("5: R4 did not run in the locked session shape")
    ch = r4.get("channels") or {}
    for name, tools in CHANNEL_KEYS.items():
        vals = [ch.get(name)] if tools is None else [(ch.get(name) or {}).get(t) for t in tools]
        for v in vals:
            if v not in ("yes", "no"):
                bad.append("5: channel %s has no definite result (%s)" % (name, v))
            elif v == "yes" and stance == "unreadable":
                bad.append("5: channel %s is readable under the unreadable stance" % name)
    if r4.get("station_reachable") is not False or r4.get("other_account_reachable") is not False:
        bad.append("5: station or other-account reachability is not ruled out")
    sc = r.get("scrub") or {}
    if sc.get("fixtures_pass") is not True or sc.get("revocation_recorded") is not True:
        bad.append("6: scrub fixtures or the revocation procedure are not recorded as passed")
    arts = sc.get("artifacts") or {}
    if not arts:
        bad.append("6: no proof artifacts")
    for name, a in arts.items():
        path = os.path.join(base, a.get("path", ""))
        if not os.path.isfile(path) or sha(path) != a.get("sha256"):
            bad.append("6: proof artifact %s is missing or its hash changed" % name)
    return bad


def main(argv):
    ap = argparse.ArgumentParser(prog="auth-preflight.py")
    ap.add_argument("--readiness", required=True); ap.add_argument("--lock", required=True)
    ap.add_argument("--card-sha256", required=True)
    ap.add_argument("--stance", default="eval-only-reachable", choices=["eval-only-reachable", "unreadable"])
    a = ap.parse_args(argv)
    try:
        r = json.load(open(a.readiness))
        lock = json.load(open(a.lock))
    except (OSError, ValueError) as e:
        print("PAID RUN BLOCKED: readiness unreadable: %s" % e)
        return 3
    bad = check(r, lock, sha(a.lock), a.card_sha256, a.stance, os.path.dirname(os.path.abspath(a.readiness)))
    if bad:
        print("PAID RUN BLOCKED:")
        for b in bad:
            print("  - " + b)
        return 3
    print("READY: G0 auth readiness, stance %s (reachability disclosed, never called isolation)" % a.stance)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
