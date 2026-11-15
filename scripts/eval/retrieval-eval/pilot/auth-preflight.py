#!/usr/bin/env python3
"""auth-preflight.py -- the objective G0 auth-readiness checklist (design section 11).

  auth-preflight.py --readiness auth-readiness.json --lock tools.lock --card-sha256 HEX
                    [--stance shared-credentials|eval-only-reachable|unreadable]
                    [--answer-file PATH --search-key-file PATH]

Computes readiness from the private, NON-SECRET record of the trusted provisioning and the
free R4 access probes; a bare passed:true proves nothing.

The default stance is shared-credentials (design r20, decision 946): the eval runs on the
fleet's shared credentials, so items 1 to 3 below are replaced by item S, a statement of which
shared credential each channel uses (answer: shared-subscription, the one-line token file;
search: regular-openrouter-key, the qmd key env file and the key-only file derived from it),
with no credential material. The answer source is checked by lstat only (regular, not a
symlink, non-empty, mode 0600/0400, one hard link, never the interactive login file). The
configured --answer-file / --search-key-file must equal the stated source_path / derived_path.
Item 6 needs a rotation-on-leak procedure (path and sha256) per channel. Item S proves which
credential is used, never isolation from the fleet.

The legacy stances (eval-only-reachable, unreadable) are selected only by an explicit --stance
and keep every item below:

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
import argparse, hashlib, json, os, re, stat, sys

MECHANISM = "claude-setup-token/CLAUDE_CODE_OAUTH_TOKEN"
CHANNEL_KEYS = {"bash_env": None, "bash_proc_ancestors": None, "native_proc": ("Read", "Grep", "Glob"),
                "session_home": ("Read", "Grep", "Glob", "Bash")}
PREFIXED = re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}|sk-or-[A-Za-z0-9_-]{8,}")
LONGRUN = re.compile(r"[A-Za-z0-9+/_-]{40,}={0,2}")
HEXSHA = re.compile(r"^[0-9a-f]{64}$")
CHANNELS = {"answer": ("shared-subscription", ("source_path",)), "search": ("regular-openrouter-key", ("source_path", "derived_path"))}
PATH_FIELDS = {".credentials.answer.source_path", ".credentials.search.source_path", ".credentials.search.derived_path"}


def secretish(s):
    """A provider-prefixed key, or a long mixed-case alphanumeric run (a bearer/OAuth token shape)."""
    if PREFIXED.search(s):
        return True
    for m in LONGRUN.finditer(s):
        t = m.group(0)
        if sum(c.isdigit() for c in t) >= 2 and any(c.islower() for c in t) and any(c.isupper() for c in t):
            return True
    return False


def shown(v):
    return "[redacted]" if secretish(str(v)) else v


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


def same_path(a, b):
    return isinstance(a, str) and isinstance(b, str) and os.path.abspath(a) == os.path.abspath(b)


def answer_source_problems(p):
    if not isinstance(p, str) or not p:
        return ["S: the answer channel states no source_path"]
    real = os.path.realpath(p)
    login_dir = os.path.join(os.path.realpath(os.path.expanduser("~")), ".claude")
    if real.endswith(".credentials.json") or real == login_dir or real.startswith(login_dir + os.sep):
        return ["S: the answer source is the interactive login file or lies under ~/.claude"]
    try:
        st = os.lstat(p)
    except OSError:
        return ["S: the answer source does not exist"]
    if stat.S_ISLNK(st.st_mode):
        return ["S: the answer source is a symlink"]
    bad = []
    if not stat.S_ISREG(st.st_mode):
        return ["S: the answer source is not a regular file"]
    if st.st_size == 0:
        bad.append("S: the answer source is empty")
    if stat.S_IMODE(st.st_mode) not in (0o600, 0o400):
        bad.append("S: the answer source has mode %04o, not 0600 or 0400" % stat.S_IMODE(st.st_mode))
    if st.st_nlink != 1:
        bad.append("S: the answer source has %d hard links" % st.st_nlink)
    return bad


def check_shared(r, card_sha, base, answer_file, search_key_file):
    bad = []
    creds = r.get("credentials")
    creds = creds if isinstance(creds, dict) else {}
    for name in sorted(set(creds) - set(CHANNELS)):
        bad.append("S: unknown channel %s" % shown(name))
    for name, (kind, fields) in sorted(CHANNELS.items()):
        c = creds.get(name)
        if not isinstance(c, dict):
            bad.append("S: missing channel %s" % name)
            continue
        if c.get("kind") != kind:
            bad.append("S: unknown kind %s for %s" % (shown(c.get("kind")), name))
        for k in sorted(set(c) - {"kind"} - set(fields)):
            bad.append("S: %s carries a field that is not a path or kind (%s)" % (name, shown(k)))
        for k in fields:
            if not isinstance(c.get(k), str) or not c[k]:
                bad.append("S: %s states no %s" % (name, k))
    if isinstance(creds.get("answer"), dict):
        bad += answer_source_problems(creds["answer"].get("source_path"))
        if answer_file is not None and not same_path(answer_file, creds["answer"].get("source_path")):
            bad.append("S: the configured answer file is not the stated answer source_path")
    if isinstance(creds.get("search"), dict) and search_key_file is not None and not same_path(search_key_file, creds["search"].get("derived_path")):
        bad.append("S: the configured S key file is not the stated search derived_path")
    s = r.get("stance") or {}
    if (s.get("selected") != "shared-credentials" or s.get("design_revision") != "r20" or s.get("card_sha256") != card_sha
            or not re.search(r"(?<![0-9])946(?![0-9])", str(s.get("decision") or ""))):
        bad.append("4: the stance is not the recorded shared-credentials choice bound to decision 946, r20 and this card")
    rot = r.get("rotation")
    rot = rot if isinstance(rot, dict) else {}
    for name in sorted(CHANNELS):
        e = rot.get(name) if isinstance(rot.get(name), dict) else {}
        path = os.path.join(base, e.get("path", "")) if isinstance(e.get("path"), str) and e.get("path") else ""
        if not path or not os.path.isfile(path) or sha(path) != e.get("sha256"):
            bad.append("6: the rotation procedure for %s is missing or its hash changed" % name)
    return bad


def check(r, lock, lock_sha, card_sha, stance, base, answer_file=None, search_key_file=None):
    bad = []
    for path, s in strings(r):
        parts = s.split("/") if path in PATH_FIELDS else [s]
        if not HEXSHA.match(s) and not s.startswith("http") and any(secretish(x) for x in parts):
            bad.append("credential-shaped value at %s: the record must hold no token bytes" % shown(path))
    if r.get("schema") != "rag-pilot-auth-readiness/1":
        bad.append("not an auth-readiness record (a bare pass flag proves nothing)")
        return bad
    if r.get("lock_sha256") != lock_sha:
        bad.append("stale: the record is bound to another tools.lock")
    files = lock.get("files", {})
    if stance == "shared-credentials":
        bad += check_shared(r, card_sha, base, answer_file, search_key_file)
        return bad + check_r4_scrub(r, files, stance, base, require_revocation_flag=False)
    m = r.get("mechanism") or {}
    if m.get("id") != MECHANISM:
        bad.append("1: mechanism %s is not the reviewed supported candidate" % shown(m.get("id")))
    if not m.get("sources") or not all(str(u).startswith("https://code.claude.com/docs/") for u in m["sources"]) or not m.get("retrieved"):
        bad.append("1: official source URLs and retrieval date are missing")
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
    return bad + check_r4_scrub(r, files, stance, base, require_revocation_flag=True)


def check_r4_scrub(r, files, stance, base, require_revocation_flag):
    bad = []
    r4 = r.get("r4") or {}
    if r4.get("ran") is not True or r4.get("shape_sha256") != (files.get("sandbox") or {}).get("sha256"):
        bad.append("5: R4 did not run in the locked session shape")
    ch = r4.get("channels") or {}
    for name, tools in CHANNEL_KEYS.items():
        vals = [ch.get(name)] if tools is None else [(ch.get(name) or {}).get(t) for t in tools]
        for v in vals:
            if v not in ("yes", "no"):
                bad.append("5: channel %s has no definite result (%s)" % (name, shown(v)))
            elif v == "yes" and stance == "unreadable":
                bad.append("5: channel %s is readable under the unreadable stance" % name)
    if r4.get("station_reachable") is not False or r4.get("other_account_reachable") is not False:
        bad.append("5: station or other-account reachability is not ruled out")
    sc = r.get("scrub") or {}
    if sc.get("fixtures_pass") is not True or (require_revocation_flag and sc.get("revocation_recorded") is not True):
        bad.append("6: scrub fixtures or the revocation procedure are not recorded as passed")
    arts = sc.get("artifacts") or {}
    if not arts:
        bad.append("6: no proof artifacts")
    for name, a in arts.items():
        path = os.path.join(base, a.get("path", ""))
        if not os.path.isfile(path) or sha(path) != a.get("sha256"):
            bad.append("6: proof artifact %s is missing or its hash changed" % shown(name))
    return bad


def main(argv):
    ap = argparse.ArgumentParser(prog="auth-preflight.py")
    ap.add_argument("--readiness", required=True); ap.add_argument("--lock", required=True)
    ap.add_argument("--card-sha256", required=True)
    ap.add_argument("--stance", default="shared-credentials", choices=["shared-credentials", "eval-only-reachable", "unreadable"])
    ap.add_argument("--answer-file"); ap.add_argument("--search-key-file")
    a = ap.parse_args(argv)
    try:
        r = json.load(open(a.readiness))
        lock = json.load(open(a.lock))
    except (OSError, ValueError) as e:
        print("PAID RUN BLOCKED: readiness unreadable: %s" % e)
        return 3
    bad = check(r, lock, sha(a.lock), a.card_sha256, a.stance, os.path.dirname(os.path.abspath(a.readiness)), a.answer_file, a.search_key_file)
    if bad:
        print("PAID RUN BLOCKED:")
        for b in bad:
            print("  - " + b)
        return 3
    shared = "; the credentials are shared with the fleet" if a.stance == "shared-credentials" else ""
    print("READY: G0 auth readiness, stance %s (reachability disclosed, never called isolation%s)" % (a.stance, shared))
    print("stance: %s" % a.stance)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
