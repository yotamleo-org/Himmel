#!/bin/bash
# helper-update v1: re-install the afk-sudo helper, broker, floor and station ops from a CI-green main commit.
# Run by the afk-sudo helper as root from the root-owned copy in /usr/local/libexec/himmel/ops/: with --check at the
# request (metadata only, nothing fetched is written, sourced or run), and without it after the operator's NONCE CODE.
#
#   helper-update.sh [--check] --id ID --operator-user U --commit <40 hex>
#
# The commit must be on GitHub's main (by main's sha), have a passing ci.yml Actions run at that sha, not be older than
# the installed commit, and the station's checkout must hold the same files. After the code root fetches the commit's
# files itself, snapshots libexec, the sudoers files and the config, runs the commit's own install.sh from a root stage,
# self-checks, and restores the snapshot on any failure or after an interrupted run (not over a later install made more than 305 s after the run began).
# One python3 -I program does the work; this file sources nothing from the checkout or from GitHub.
# Last stdout line: op=helper-update id=ID result=changed|unchanged|would-change|bad-param|failed [name=P] detail=...
# Exit 0 ok, 3 bad-param, 1 failed.
# Test seam: HIMMEL_OPS_ROOT (a path prefix), HIMMEL_OPS_BIN (a PATH prefix), HIMMEL_OPS_NOW (the op's clock) and
# HIMMEL_OPS_KILL_AT (killed after step marker|installed|restore:N) are honoured only when euid != 0.
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=""
if [ "$(id -u)" != 0 ]; then
    ROOT=${HIMMEL_OPS_ROOT:-}
    [ -z "${HIMMEL_OPS_BIN:-}" ] || PATH="$HIMMEL_OPS_BIN:$PATH"
fi
export PATH

id=- check=0 commit='' ouser=''
say() { # result [name] detail
    if [ $# -eq 3 ]; then printf 'op=helper-update id=%s result=%s name=%s detail=%s\n' "$id" "$1" "$2" "$3"
    else printf 'op=helper-update id=%s result=%s detail=%s\n' "$id" "$1" "$2"; fi
}
bad() { say bad-param "$1" "$2"; exit 3; }
die() { say failed "$1"; exit 1; }

while [ $# -gt 0 ]; do
    if [ "$1" = --check ]; then check=1; shift; continue; fi
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in
        --id) id=$2 ;;
        --operator-user) ouser=$2 ;;
        --commit) commit=$2 ;;
        *) die "unknown argument $1" ;;
    esac
    shift 2
done

[[ $id =~ ^[A-Za-z0-9-]{1,32}$ ]] || die "no valid request id"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || bad commit "40 lowercase hex digits"
[[ $ouser =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "no valid operator user"

PY=$(cat <<'PYEOF'
import calendar, fcntl, glob, hashlib, json, os, pwd, re, shutil, signal, stat, subprocess, sys, tempfile, time

ROOT, RID, OPUSER, COMMIT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
CHECK = sys.argv[5] == "1"
SEAM = os.geteuid() != 0 and bool(ROOT)
ROOT = ROOT.rstrip("/") if SEAM else ""
OWNER = os.geteuid() if SEAM else 0

LX = "/usr/local/libexec/himmel"
CONFIG = "/etc/himmel/afk-sudo.json"
SEED = "/etc/himmel/afk-sudo/totp.seed"
NOTICE_ENV = "/etc/himmel/afk-sudo/notice-bot.env"
SUDOERS = "/etc/sudoers"
SUDOERS_D = "/etc/sudoers.d"
HIM_SUDOERS = SUDOERS_D + "/himmel-afk-sudo"
STATE = "/var/lib/himmel/afk-sudo"
LOCK, RATE, MARKER, RECORD = STATE + "/helper-update.lock", STATE + "/helper-update.rate", STATE + "/helper-update.pending", STATE + "/helper-commit"
STAGES = STATE + "/helper-update"
LEDGER = "/var/log/himmel/afk-sudo.jsonl"
LOGDIR = "/var/log/himmel/ops"
FIXED_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LIBP, OPSP = "scripts/lib/afk-sudo/", "scripts/station-ops/"
HEX40 = re.compile(r"[0-9a-f]{40}")
NAME_RE = re.compile(r"[A-Za-z0-9._+-]{1,80}")
MAX_FILE = 1 << 20
DEADLINE = time.monotonic() + (20 if CHECK else 280)


def P(p):
    return ROOT + p


def now():
    if SEAM and os.environ.get("HIMMEL_OPS_NOW"):
        return float(os.environ["HIMMEL_OPS_NOW"])
    return time.time()


def san(s, n=200):
    return "".join(c if (c.isascii() and c.isprintable() and c != "|") else "?" for c in str(s))[:n]


def sname(s, n=60):
    """A file name from the commit or the checkout, as it may appear in a notice: plain characters only."""
    return re.sub(r"[^A-Za-z0-9._+/-]", "?", str(s))[:n]


class Stop(Exception):
    def __init__(self, code):
        self.code = code


def say_raw(result, detail):
    d = "".join(c if (c.isascii() and c.isprintable()) else "?" for c in str(detail))
    print("op=helper-update id=%s result=%s detail=%s" % (RID, result, d), flush=True)


def fail(detail):
    say_raw("failed", detail)
    raise Stop(1)


def kill_point(name):
    if SEAM and os.environ.get("HIMMEL_OPS_KILL_AT") == name:
        os.kill(os.getpid(), signal.SIGKILL)


def tool(name):
    for d in (os.environ.get("PATH", FIXED_PATH) if SEAM else FIXED_PATH).split(":"):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    fail("missing tool " + name)


def base_env():
    env = {"PATH": os.environ.get("PATH", FIXED_PATH) if SEAM else FIXED_PATH, "LANG": "C.UTF-8", "HOME": "/"}
    if SEAM:
        env.update({k: v for k, v in os.environ.items() if k.startswith("HIMMEL_OPS_")})
    return env


def read_regular(path, cap=64 << 20):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
            return None
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            return f.read()
    except OSError:
        return None


def blobid(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def write_atomic(path, data, mode=0o600):
    if isinstance(data, str):
        data = data.encode()
    d, n = os.path.dirname(path), os.path.basename(path)
    tmp = os.path.join(d, ".helper-update.%s.tmp" % n)
    try:
        os.unlink(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fchmod(f.fileno(), mode)
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fsync_dir(d)


# ---- the config, the lock, the rate ----
def load_config():
    p = P(CONFIG)
    try:
        st = os.lstat(p)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != OWNER or st.st_mode & 0o022:
            fail("the config is not a root-owned regular file")
        cfg = json.loads(read_regular(p, 1 << 20).decode("utf-8"))
    except (OSError, ValueError, AttributeError):
        fail("cannot read the config")
    if not isinstance(cfg, dict):
        fail("the config is not a JSON object")
    return cfg


def helper_update_block(cfg):
    hu = cfg.get("helper_update")
    if not isinstance(hu, dict) or hu.get("enabled") is not True:
        fail("helper_update is not enabled in the config")
    co, repo = hu.get("checkout"), hu.get("repo")
    if not isinstance(co, str) or not co.startswith("/") or len(co) > 4096 or not co.isprintable():
        fail("helper_update.checkout is not an absolute path")
    if not isinstance(repo, str) or len(repo) > 30 or not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo) or any(x in (".", "..") for x in repo.split("/")):
        fail("helper_update.repo is not <owner>/<name>")
    return co, repo


def take_lock():
    if not os.path.isdir(P(STATE)):
        fail("no state directory")
    fd = os.open(P(LOCK), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    end = time.monotonic() + 5
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= end:
                fail("busy")
            time.sleep(0.1)


def rate_gate():
    t, times = now(), []
    try:
        times = [float(x) for x in read_regular(P(RATE), 65536).decode().split()]
    except (AttributeError, ValueError):
        times = []
    times = [x for x in times if t - 3600 < x]
    if len(times) >= 4:
        fail("rate: 4 an hour")
    times.append(t)
    write_atomic(P(RATE), "\n".join("%.0f" % x for x in times) + "\n")


# ---- GitHub ----
def curl_base(max_time):
    return [tool("curl"), "-q", "--proto", "=https", "--max-redirs", "0", "--fail", "--globoff", "--silent", "--show-error",
            "--max-time", str(max_time), "-A", "himmel-helper-update"]


def gh(path, what):
    if time.monotonic() > DEADLINE:
        fail("deadline passed before the %s call" % what)
    argv = curl_base(5) + ["--max-filesize", str(4 << 20), "-H", "Accept: application/vnd.github+json", "https://api.github.com" + path]
    try:
        r = subprocess.run(argv, capture_output=True, env=base_env(), timeout=8, stdin=subprocess.DEVNULL)
        if r.returncode != 0 or len(r.stdout) > (4 << 20):
            fail("github %s call failed" % what)
        j = json.loads(r.stdout.decode("utf-8"))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        fail("github %s call failed" % what)
    if not isinstance(j, (dict, list)):
        fail("github %s answer is not JSON" % what)
    return j


def good_run(r, repo):
    return (isinstance(r, dict) and r.get("path") == ".github/workflows/ci.yml" and r.get("event") in ("schedule", "workflow_dispatch")
            and r.get("conclusion") == "success" and isinstance(r.get("head_repository"), dict) and r["head_repository"].get("full_name") == repo)


def fetch_facts(repo, check):
    f = {}
    j = gh("/repos/%s/branches/main" % repo, "branch")
    main = (j.get("commit") or {}).get("sha") if isinstance(j, dict) else None
    if not isinstance(main, str) or not HEX40.fullmatch(main):
        fail("github branch answer has no sha")
    j = gh("/repos/%s/compare/%s...%s" % (repo, COMMIT, main), "compare")
    if not isinstance(j, dict) or j.get("status") not in ("identical", "ahead"):
        fail("not-on-main")
    f["message"] = (((j.get("base_commit") or {}).get("commit") or {}).get("message") or "")
    j = gh("/repos/%s/actions/runs?head_sha=%s&status=success&per_page=30" % (repo, COMMIT), "runs")
    runs = [r for r in (j.get("workflow_runs") or []) if good_run(r, repo) and r.get("head_sha") == COMMIT] if isinstance(j, dict) else []
    if not runs:
        fail("no passing ci.yml run at this commit")
    f["run"] = runs[0]
    if check:
        j = gh("/repos/%s/actions/workflows/ci.yml/runs?branch=main&status=success&per_page=30" % repo, "newest")
        newest = [r for r in (j.get("workflow_runs") or []) if good_run(r, repo)] if isinstance(j, dict) else []
        if not newest or newest[0].get("head_sha") != COMMIT:
            fail("not the newest green main commit (%s)" % san((newest[0].get("head_sha") if newest else "none"), 12))
    return f


def mapping(paths):
    ps, m = set(paths), {}
    for p in ps:
        if p == LIBP + "afk_sudo.py":
            m["afk-sudo"] = p
        elif p in (LIBP + "approval_broker.py", LIBP + "never_remote.py"):
            m[p[len(LIBP):]] = p
        elif p.startswith(OPSP) and p.endswith(".json") and "/" not in p[len(OPSP):]:
            op = p[len(OPSP):-5]
            if op != "manifest" and OPSP + op + ".sh" in ps:
                m["ops/%s.json" % op] = p
                m["ops/%s.sh" % op] = OPSP + op + ".sh"
    return m


def read_tree(repo):
    j = gh("/repos/%s/git/trees/%s?recursive=1" % (repo, COMMIT), "tree")
    if not isinstance(j, dict) or j.get("truncated") is not False or not isinstance(j.get("tree"), list):
        fail("the tree listing is truncated or unreadable")
    tree = {}
    for e in j["tree"]:
        p = e.get("path") if isinstance(e, dict) else None
        if not isinstance(p, str):
            fail("a tree entry has no path")
        if p in (LIBP[:-1], OPSP[:-1]):
            if e.get("type") != "tree" or e.get("mode") != "040000":
                fail("%s is not a directory in the tree" % sname(p, 40))
            continue
        pre = LIBP if p.startswith(LIBP) else OPSP if p.startswith(OPSP) else None
        if pre is None:
            continue
        name = p[len(pre):]
        if not NAME_RE.fullmatch(name):
            fail("a file name in %s is not plain: %s" % (pre.rstrip("/"), sname(name, 40)))
        if e.get("type") != "blob" or e.get("mode") not in ("100644", "100755"):
            fail("%s is not a plain file in the tree" % sname(p, 60))
        size = e.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size > MAX_FILE or not isinstance(e.get("sha"), str) or not HEX40.fullmatch(e["sha"]):
            fail("%s is over 1 MiB or has no blob id" % sname(p, 60))
        tree[p] = {"blob": e["sha"], "mode": e["mode"], "size": size}
    if len(tree) > 400:
        fail("the tree holds too many files")
    for need in (LIBP + "afk_sudo.py", LIBP + "approval_broker.py", LIBP + "never_remote.py", LIBP + "install.sh", OPSP + "build-manifest.py"):
        if need not in tree:
            fail("the tree has no %s" % need.rsplit("/", 1)[1])
    return tree


# ---- the installed files, the record, the checkout ----
def installed_blobs():
    out = {}
    for rel in ("afk-sudo", "approval_broker.py", "never_remote.py"):
        d = read_regular(P(LX + "/" + rel))
        out[rel] = blobid(d) if d is not None else None
    try:
        names = sorted(os.listdir(P(LX + "/ops")))
    except OSError:
        names = []
    for n in names:
        if n == "manifest.json" or not (n.endswith(".sh") or n.endswith(".json")):
            continue
        d = read_regular(P(LX + "/ops/" + n))
        out["ops/" + n] = blobid(d) if d is not None else None
    return out


def read_record():
    d = read_regular(P(RECORD), 2 << 20)
    if d is None:
        return None
    try:
        rec = json.loads(d.decode("utf-8"))
        if not isinstance(rec, dict) or not HEX40.fullmatch(rec.get("commit", "")) or not isinstance(rec.get("files"), dict):
            return None
        for v in rec["files"].values():
            if not isinstance(v, dict) or not isinstance(v.get("blob"), str):
                return None
        return rec
    except (ValueError, AttributeError):
        return None


def record_matches(rec, inst):
    m = mapping(rec["files"].keys())
    for rel, tp in m.items():
        if inst.get(rel) != rec["files"][tp]["blob"]:
            return False
    return all(rel in m for rel in inst if rel.startswith("ops/"))


READER = r'''
import hashlib, json, os, stat, sys
co = sys.argv[1]
files, diff = {}, []
for sub in ("scripts/lib/afk-sudo", "scripts/station-ops"):
    d = os.path.join(co, sub)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        diff.append(sub + "/")
        continue
    for n in names:
        rel = sub + "/" + n
        try:
            st = os.lstat(os.path.join(d, n))
        except OSError:
            diff.append(rel)
            continue
        if stat.S_ISDIR(st.st_mode) and n == "__pycache__":
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_size > 1048576:
            diff.append(rel)
            continue
        try:
            with open(os.path.join(d, n), "rb") as f:
                data = f.read(1048577)
        except OSError:
            diff.append(rel)
            continue
        files[rel] = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
print(json.dumps({"files": files, "diff": diff}))
'''


def checkout_must_match(checkout, tree):
    argv = [sys.executable, "-I", "-c", READER, checkout]
    env = base_env()
    if not SEAM:
        try:
            pw = pwd.getpwnam(OPUSER)
        except KeyError:
            fail("no such operator user")
        argv = [tool("setpriv"), "--reuid=%d" % pw.pw_uid, "--regid=%d" % pw.pw_gid, "--init-groups", "--no-new-privs", "--inh-caps=-all"] + argv
        env.update({"HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name})
    try:
        r = subprocess.run(argv, capture_output=True, env=env, timeout=8, stdin=subprocess.DEVNULL, cwd="/")
        got = json.loads(r.stdout.decode("utf-8"))
        files, diff = got["files"], list(got["diff"])
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        fail("the checkout reader failed")
    for p in sorted(tree):
        if files.get(p) != tree[p]["blob"]:
            diff.append(p)
    for p in sorted(files):
        if p not in tree:
            diff.append(p)
    if diff:
        names = []
        for d in diff:
            s = sname(d.rsplit("scripts/", 1)[-1], 60)
            if s not in names:
                names.append(s)
        fail("checkout differs from %s: %s" % (COMMIT[:12], ", ".join(names[:4]) + (" +%d more" % (len(names) - 4) if len(names) > 4 else "")))


def display(p):
    if p.startswith(LIBP):
        return "afk-sudo/" + p[len(LIBP):]
    return "station-ops/" + p[len(OPSP):] if p.startswith(OPSP) else p


def lists(tree, rec, inst):
    m = mapping(tree.keys())
    installed = sorted(rel for rel, tp in m.items() if inst.get(rel) != tree[tp]["blob"])
    installed += sorted(rel for rel in inst if rel not in m and rel.startswith("ops/"))
    source = None
    if rec is not None:
        rf, gone = rec["files"], []
        for p in sorted(set(tree) | set(rf)):
            if tree.get(p, {}).get("blob") != rf.get(p, {}).get("blob"):
                rel = next((r for r, tp in m.items() if tp == p), None)
                if rel is None or rel not in installed:
                    gone.append(display(p))
        source = gone
    return m, installed, source


def prio(n):
    b = n.rsplit("/", 1)[-1]
    return (0 if b == "install.sh" else 1 if b == "never_remote.py" else 2 if b in ("afk-sudo", "afk_sudo.py") else 3 if b == "approval_broker.py" else 4, n)


# ---- the --check line (D2: fixed budgets, at most 400 characters) ----
def login(s):
    s = s if isinstance(s, str) and re.fullmatch(r"[A-Za-z0-9-]{1,39}", s) else "?"
    return s if len(s) <= 16 else s[:15] + "~"


def line(repo, f, rec, rec_state, rng, installed, source, pr):
    names = sorted(installed + (source or []), key=prio)
    if rec is not None:
        ch = {x.get("filename") for x in rng["files"]} if rng else set()
        if len(rng["files"]) >= 300:
            warn = "WARN list cut"
        else:
            hit = [lab for lab, p in (("install.sh", LIBP + "install.sh"), ("ci.yml", ".github/workflows/ci.yml"), ("never_remote.py", LIBP + "never_remote.py")) if p in ch]
            warn = "WARN " + (",".join(hit) if hit else "none")
        link = "https://github.com/%s/compare/%s...%s" % (repo, rec["commit"][:12], COMMIT[:12])
        k = rng["count"]
        commits = "many commits" if k > 9999 else "%d commits" % k
        note = None
    else:
        warn = "WARN no baseline, install.sh unseen"
        link = "https://github.com/%s/tree/%s/scripts/lib/afk-sudo" % (repo, COMMIT[:12])
        commits = "? commits"
        note = "record stale, installed commit unknown" if rec_state == "stale" else "installed commit unknown"
    if pr:
        ap = pr["approved"]
        prf = "PR #%s by %s merged by %s approved by %s" % (pr["n"] if re.fullmatch(r"[0-9]{1,5}", pr["n"]) else "?", login(pr["by"]), login(pr["merger"]),
                                                          (login(ap[0]) + ("+%d" % (len(ap) - 1) if len(ap) > 1 else "")) if ap else "none")
    else:
        prf = "PR none"
    run = f["run"]
    date = str(run.get("run_started_at") or run.get("created_at") or "")[:10]
    ci = "ci.yml %s %s" % (run["event"] if run["event"] in ("schedule", "workflow_dispatch") else "?", date if re.fullmatch(r"\d{4}-\d\d-\d\d", date) else "?")
    subj = (f["message"].split("\n", 1)[0])[:30].replace('"', "'").replace("|", "/")
    subject = '"%s"' % "".join(c if (c.isascii() and c.isprintable()) else "?" for c in subj)
    fixed = [warn[:40], link[:88], commits] + ([note] if note else []) + [prf[:89], ci[:26], subject[:32]]
    budget = min(95, 400 - sum(len(x) for x in fixed) - 3 * len(fixed))
    n = len(names)
    shown, head = [], "%d files: " % n
    for i, nm in enumerate(names):
        trial = shown + [nm]
        rest = n - len(trial)
        if len(head + ", ".join(trial) + (", +%d more" % rest if rest else "")) <= budget:
            shown = trial
        else:
            break
    rest = n - len(shown)
    files = head + ", ".join(shown) + (", +%d more" % rest if rest else "") if shown else (head + "+%d more" % n if n else "0 files")
    fields = [fixed[0], fixed[1], fixed[2]] + ([fixed[3]] if note else []) + [files[:budget if budget > 0 else 0]] + fixed[-3:]
    return " | ".join(fields)[:400]


def who(repo):
    j = gh("/repos/%s/commits/%s/pulls" % (repo, COMMIT), "pulls")
    pull = next((p for p in j if isinstance(p, dict) and p.get("merge_commit_sha") == COMMIT), None) if isinstance(j, list) else None
    if pull is None:
        return None
    n = str(pull.get("number"))
    if not re.fullmatch(r"[0-9]{1,9}", n):
        return None
    pj = gh("/repos/%s/pulls/%s" % (repo, n), "pull")
    rv = gh("/repos/%s/pulls/%s/reviews" % (repo, n), "reviews")
    last = {}
    for r in rv if isinstance(rv, list) else []:
        u = (r.get("user") or {}).get("login") if isinstance(r, dict) else None
        if isinstance(u, str):
            last[u] = r.get("state")
    return {"n": n, "by": (pj.get("user") or {}).get("login"), "merger": (pj.get("merged_by") or {}).get("login"),
            "approved": [u for u, s in last.items() if s == "APPROVED"]}


# ---- the snapshot, the marker, the restore ----
def row_of(path):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    m = st.st_mode
    r = {"mode": m & 0o7777, "uid": st.st_uid, "gid": st.st_gid}
    if stat.S_ISDIR(m):
        r["t"] = "d"
    elif stat.S_ISLNK(m):
        r["t"], r["link"] = "l", os.readlink(path)
    elif stat.S_ISREG(m):
        d = read_regular(path)
        r["t"], r["sha"] = "f", (sha256(d) if d is not None else "?")
    else:
        r["t"] = "o"
    return r


def same_row(a, b):
    if a is None or b is None:
        return a is None and b is None
    return all(a.get(k) == b.get(k) for k in ("t", "mode", "uid", "gid", "sha", "link"))


def walk(top):
    real = P(top)
    if not os.path.lexists(real):
        return []
    out = [top]
    if os.path.isdir(real) and not os.path.islink(real):
        for dp, dn, fn in os.walk(real):
            for n in dn + fn:
                full = os.path.join(dp, n)
                out.append(full[len(ROOT):] if ROOT else full)
    return sorted(set(out))


def snapshot_paths():
    return walk(LX) + walk(SUDOERS) + walk(SUDOERS_D) + ([CONFIG] if os.path.lexists(P(CONFIG)) else [])


def save_snapshot(stage):
    root = os.path.join(stage, "prev", "root")
    os.makedirs(root, mode=0o700)
    rows = {}
    for p in snapshot_paths():
        r = row_of(P(p))
        if r is None:
            continue
        rows[p] = r
        if r["t"] == "f":
            dst = root + p
            os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
            shutil.copyfile(P(p), dst)
            fd = os.open(dst, os.O_RDONLY)
            os.fsync(fd)
            os.close(fd)
    data = json.dumps(rows, sort_keys=True).encode()
    mf = os.path.join(stage, "prev", "manifest")
    with open(mf, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    fsync_dir(os.path.join(stage, "prev"))
    return rows, sha256(data)


def load_marker():
    try:
        m = json.loads(read_regular(P(MARKER), 1 << 20).decode("utf-8"))
        stage = m["stage"]
        if not isinstance(stage, str) or os.path.dirname(stage) != P(STAGES) or not os.path.basename(stage).startswith("stage."):
            raise ValueError("stage")
        with open(os.path.join(stage, "prev", "manifest"), "rb") as f:
            data = f.read()
        if sha256(data) != m["manifest_sha"]:
            raise ValueError("manifest")
        return m, json.loads(data.decode("utf-8"))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        fail("the interrupted-run marker is unreadable; needs a terminal")


def ctime_of(path):
    while True:
        try:
            return os.lstat(path).st_ctime
        except OSError:
            parent = os.path.dirname(path)
            if parent == path:
                return 0
            path = parent


def superseded(m, rows):
    deadline = float(m["deadline"])
    paths = set(rows) | set(m["identity"]["paths"])
    paths.discard(CONFIG)
    for p in sorted(paths):
        live = row_of(P(p))
        if same_row(live, rows.get(p)):
            continue
        if ctime_of(P(p)) > deadline:
            return True
    return False


def unexpected(m, rows):
    ident, gone, out = m["identity"]["paths"], set(m["identity"].get("gone", [])), []
    for p in sorted(set(rows) | set(ident)):
        if p == CONFIG or p == LX + "/ops/manifest.json":
            continue
        live = row_of(P(p))
        if same_row(live, rows.get(p)):
            continue
        if live is not None and live["t"] == "f" and ident.get(p) == live.get("sha"):
            continue
        if live is None and p in gone:
            continue
        if live is not None and live["t"] == "d" and rows.get(p, {}).get("t") == "d":
            continue
        out.append(p)
    return out


def disp_path(p):
    if p.startswith(LX + "/"):
        return p[len(LX) + 1:]
    return p[len("/etc/"):] if p.startswith("/etc/") else p


def sudoers_leftovers(rows):
    out = []
    fixed = sha256(("%s ALL=(root) NOPASSWD: %s/afk-sudo\n" % (OPUSER, LX)).encode())
    for p in sorted(set(walk(SUDOERS)) | set(walk(SUDOERS_D)) | {q for q in rows if q == SUDOERS or q.startswith(SUDOERS_D)}):
        live = row_of(P(p))
        if same_row(live, rows.get(p)):
            continue
        if p == HIM_SUDOERS and live is not None and live.get("sha") == fixed:
            continue
        out.append(p)
    return out


def rm_any(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def chown_like(path, r, follow=True):
    try:
        st = os.lstat(path)
        if (st.st_uid, st.st_gid) != (r["uid"], r["gid"]):
            os.lchown(path, r["uid"], r["gid"])
    except OSError:
        pass


def restore(m, rows):
    stage = m["stage"]
    if not m.get("restoring"):
        m["restoring"] = True
        write_atomic(P(MARKER), json.dumps(m))
    prev = os.path.join(stage, "prev", "root")
    skip_cfg = False
    if CONFIG in rows:
        try:
            snap = json.loads(open(prev + CONFIG, "rb").read().decode("utf-8"))
            live = json.loads(read_regular(P(CONFIG), 1 << 20).decode("utf-8"))
            skip_cfg = live.get("enabled") != snap.get("enabled")
        except (OSError, ValueError, AttributeError):
            skip_cfg = False
    for p in sorted((q for q, r in rows.items() if r["t"] == "d"), key=len):
        r, live = rows[p], row_of(P(p))
        if live is None or live["t"] != "d":
            if live is not None:
                rm_any(P(p))
            os.mkdir(P(p), r["mode"])
        os.chmod(P(p), r["mode"])
        chown_like(P(p), r)
    n = 0
    for p in sorted(rows):
        r = rows[p]
        if r["t"] == "d" or (p == CONFIG and skip_cfg):
            continue
        if same_row(row_of(P(p)), r):
            continue
        dst = P(p)
        tmp = os.path.join(os.path.dirname(dst), ".helper-update.%s.tmp" % os.path.basename(dst))
        if os.path.lexists(tmp):
            rm_any(tmp)
        if os.path.isdir(dst) and not os.path.islink(dst):
            rm_any(dst)
        if r["t"] == "l":
            os.symlink(r["link"], tmp)
        else:
            with open(prev + p, "rb") as src, os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as f:
                shutil.copyfileobj(src, f)
                f.flush()
                os.fchmod(f.fileno(), r["mode"])
                os.fsync(f.fileno())
        chown_like(tmp, r)
        os.replace(tmp, dst)
        fsync_dir(os.path.dirname(dst))
        n += 1
        kill_point("restore:%d" % n)
    for top in (LX, SUDOERS_D):
        for dp, dn, fn in os.walk(P(top), topdown=False):
            for nm in dn + fn:
                full = os.path.join(dp, nm)
                if (full[len(ROOT):] if ROOT else full) not in rows:
                    rm_any(full)
    for d in {os.path.dirname(P(q)) for q in rows}:
        for t in glob.glob(os.path.join(glob.escape(d), ".helper-update.*.tmp")):
            rm_any(t)
    bad = [q for q, r in rows.items() if not (q == CONFIG and skip_cfg) and not same_row(row_of(P(q)), r)]
    for top in (LX, SUDOERS_D):
        for q in walk(top):
            if q not in rows:
                bad.append(q)
    return sorted(set(bad))


def retire_stage(stage):
    try:
        os.unlink(P(MARKER))
    except OSError:
        pass
    fsync_dir(P(STATE))
    shutil.rmtree(stage, ignore_errors=True)


def interrupted():
    m, rows = load_marker()
    rid = san(m.get("id", "?"), 32)
    if not m.get("restoring") and superseded(m, rows):
        left = sudoers_leftovers(rows)
        os.rename(P(MARKER), P(STATE) + "/helper-update.superseded." + rid)
        fsync_dir(P(STATE))
        fail("interrupted run %s superseded by a later install; nothing restored%s" % (
            rid, "; sudoers NOT rolled back: " + ", ".join(sname(x, 60) for x in left[:3]) if left else ""))
    odd = unexpected(m, rows)
    bad = restore(m, rows)
    if bad:
        fail("restore incomplete: %s; needs a terminal" % ", ".join(sname(disp_path(x), 50) for x in bad[:3]))
    retire_stage(m["stage"])
    fail("restored an interrupted run %s%s" % (rid, "; unexpected: " + ", ".join(sname(disp_path(x), 50) for x in odd[:4]) if odd else ""))


# ---- the run ----
def fixed_line():
    return "%s ALL=(root) NOPASSWD: %s/afk-sudo\n" % (OPUSER, LX)


def subset(a, b, top=False):
    for k, v in a.items():
        if top and k == "enabled":
            continue
        if k not in b:
            return False
        if isinstance(v, dict) and isinstance(b[k], dict):
            if not subset(v, b[k]):
                return False
        elif v != b[k]:
            return False
    return True


def self_check(stage, m, rows, tree):
    mp = mapping(tree.keys())
    for rel, tp in mp.items():
        if read_regular(P(LX + "/" + rel)) != read_regular(os.path.join(stage, tp)):
            return False
    try:
        if set(os.listdir(P(LX + "/ops"))) != {rel[4:] for rel in mp if rel.startswith("ops/")} | {"manifest.json"}:
            return False
    except OSError:
        return False
    for q in walk(LX):
        st = os.lstat(P(q))
        if st.st_uid != OWNER or st.st_mode & 0o022 or stat.S_ISLNK(st.st_mode):
            return False
    st = os.lstat(P(HIM_SUDOERS)) if os.path.lexists(P(HIM_SUDOERS)) else None
    if st is None or not stat.S_ISREG(st.st_mode) or st.st_uid != OWNER or st.st_mode & 0o7777 != 0o440 or read_regular(P(HIM_SUDOERS)) != fixed_line().encode():
        return False
    others = [q for q in set(walk(SUDOERS)) | set(walk(SUDOERS_D)) if q != HIM_SUDOERS]
    snap_others = [q for q in rows if (q == SUDOERS or q.startswith(SUDOERS_D)) and q != HIM_SUDOERS]
    if set(others) != set(snap_others) or any(not same_row(row_of(P(q)), rows[q]) for q in snap_others):
        return False
    try:
        st = os.lstat(P(CONFIG))
        cur = json.loads(read_regular(P(CONFIG), 1 << 20).decode("utf-8"))
        snap = json.loads(open(os.path.join(stage, "prev", "root") + CONFIG, "rb").read().decode("utf-8"))
        if not stat.S_ISREG(st.st_mode) or st.st_uid != OWNER or st.st_mode & 0o022 or not isinstance(cur, dict) or not subset(snap, cur, True):
            return False
    except (OSError, ValueError, AttributeError):
        return False
    env = base_env()
    if SEAM:
        env["AFK_SUDO_ROOT"] = ROOT
    try:
        r = subprocess.run([P(LX + "/afk-sudo"), "mode"], capture_output=True, env=env, timeout=20, stdin=subprocess.DEVNULL, cwd="/")
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and any(x.startswith("result=mode") for x in r.stdout.decode("utf-8", "replace").splitlines())


def lockdown_seen(t6):
    d = read_regular(P(LEDGER), 64 << 20)
    if d is None:
        return False
    for ln in d.decode("utf-8", "replace").splitlines()[-200:]:
        try:
            row = json.loads(ln)
            if row.get("event") == "lockdown" and row.get("result") == "locked" and calendar.timegm(time.strptime(row["ts"], "%Y-%m-%dT%H:%M:%SZ")) >= int(t6):
                return True
        except (ValueError, KeyError, TypeError):
            continue
    return False


def fetch_stage(repo, tree):
    os.makedirs(P(STAGES), mode=0o700, exist_ok=True)
    stage = tempfile.mkdtemp(prefix="stage.", dir=P(STAGES))
    argv = curl_base(30) + ["--max-filesize", str(MAX_FILE)]
    for p in sorted(tree):
        dst = os.path.join(stage, p)
        os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
        argv += ["--output", dst, "https://raw.githubusercontent.com/%s/%s/%s" % (repo, COMMIT, p)]
    try:
        r = subprocess.run(argv, capture_output=True, env=base_env(), timeout=40, stdin=subprocess.DEVNULL)
        ok = r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        ok = False
    if not ok:
        shutil.rmtree(stage, ignore_errors=True)
        fail("the raw fetch failed")
    for p, e in tree.items():
        d = read_regular(os.path.join(stage, p), MAX_FILE)
        if d is None or len(d) != e["size"] or blobid(d) != e["blob"]:
            shutil.rmtree(stage, ignore_errors=True)
            fail("fetched bytes differ from the tree listing: %s" % sname(p.rsplit("/", 1)[1], 60))
        os.chmod(os.path.join(stage, p), 0o755 if e["mode"] == "100755" else 0o644)
    return stage


def run_installer(stage):
    os.makedirs(P(LOGDIR), mode=0o755, exist_ok=True)
    fd = os.open(P(LOGDIR + "/" + RID + ".log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    env = base_env()
    env["TMPDIR"] = stage
    argv = [tool("timeout"), "-k", "5", "120", tool("bash"), os.path.join(stage, LIBP + "install.sh"), "--user", OPUSER]
    try:
        return subprocess.run(argv, env=env, cwd=stage, stdin=subprocess.DEVNULL, stdout=fd, stderr=subprocess.STDOUT, timeout=140).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 1
    finally:
        os.close(fd)


def main():
    cfg = load_config()
    checkout, repo = helper_update_block(cfg)
    lock = take_lock()
    if os.path.lexists(P(MARKER)):
        interrupted()
    for need in (LX + "/afk-sudo", SEED, NOTICE_ENV):
        if read_regular(P(need), 1 << 20) is None:
            fail("not installed: %s (this op re-installs, it never installs first)" % os.path.basename(need))
    rate_gate()
    f = fetch_facts(repo, CHECK)
    inst = installed_blobs()
    rec = read_record()
    rec_state = "none" if rec is None else "ok" if record_matches(rec, inst) else "stale"
    if rec_state != "ok":
        rec = None
    rng = None
    if rec is not None:
        j = gh("/repos/%s/compare/%s...%s" % (repo, rec["commit"], COMMIT), "range")
        if not isinstance(j, dict) or j.get("status") not in ("identical", "ahead"):
            fail("older than the installed commit %s" % rec["commit"][:12])
        rng = {"count": int(j.get("ahead_by") or 0), "files": [x for x in (j.get("files") or []) if isinstance(x, dict)]}
    tree = read_tree(repo)
    checkout_must_match(checkout, tree)
    mp, installed, source = lists(tree, rec, inst)
    if rec is not None and not installed and not source:
        if CHECK:
            fail("nothing differs; no request filed")
        say_raw("unchanged", "nothing differs at commit %s" % COMMIT[:12])
        raise Stop(0)
    if CHECK:
        pr = who(repo)
        say_raw("would-change", line(repo, f, rec, rec_state, rng, installed, source, pr))
        raise Stop(0)
    names = sorted(installed + (source or []), key=prio)
    # D3 step 3: stage
    stage = fetch_stage(repo, tree)
    if read_regular(os.path.join(stage, LIBP + "never_remote.py")) != read_regular(P(LX + "/never_remote.py")):
        shutil.rmtree(stage, ignore_errors=True)
        fail("floor-change: needs a terminal")
    t6 = now()
    rows, msha = save_snapshot(stage)
    ident = {"commit": COMMIT, "paths": {}, "gone": [LX + "/" + rel for rel in inst if rel not in mp and rel.startswith("ops/")]}
    for rel, tp in mp.items():
        ident["paths"][LX + "/" + rel] = sha256(read_regular(os.path.join(stage, tp)))
    ident["paths"][HIM_SUDOERS] = sha256(fixed_line().encode())
    m = {"v": 1, "stage": stage, "id": RID, "commit": COMMIT, "manifest_sha": msha, "identity": ident, "time": t6, "deadline": t6 + 305, "restoring": False}
    write_atomic(P(MARKER), json.dumps(m))
    kill_point("marker")
    why = None
    try:
        rc = run_installer(stage)
        kill_point("installed")
        if rc != 0:
            why = "install"
        elif not self_check(stage, m, rows, tree):
            why = "self-check"
    except Exception:
        why = "internal"
    if why:
        bad = restore(m, rows)
        if bad:
            fail("restore incomplete: %s; needs a terminal" % ", ".join(sname(disp_path(x), 50) for x in bad[:3]))
        retire_stage(stage)
        fail("rolled back: %s" % why)
    write_atomic(P(RECORD), json.dumps({"commit": COMMIT, "run": RID, "time": t6, "files": {p: {"mode": e["mode"], "blob": e["blob"], "sha256": sha256(read_regular(os.path.join(stage, p)))} for p, e in tree.items()}}), 0o644)
    lock_row = ""
    try:
        if json.loads(read_regular(P(CONFIG), 1 << 20).decode("utf-8")).get("enabled") is True and lockdown_seen(t6):
            lock_row = "LOCKDOWN-DURING-RUN: check enabled; "
    except (ValueError, AttributeError):
        pass
    retire_stage(stage)
    shown, tail = [], ""
    head = "%scommit %s; %d files: " % (lock_row, COMMIT[:12], len(names))
    for nm in names:
        rest = len(names) - len(shown) - 1
        if len(head + ", ".join(shown + [nm]) + (", +%d more" % rest if rest else "")) <= 300:
            shown.append(nm)
        else:
            break
    rest = len(names) - len(shown)
    say_raw("changed", head + ", ".join(shown) + (", +%d more" % rest if rest else ""))
    return 0


try:
    main()
except Stop as e:
    sys.exit(e.code)
except Exception as e:
    say_raw("failed", "internal error %s" % type(e).__name__)
    sys.exit(1)
PYEOF
)
exec python3 -I -c "$PY" "$ROOT" "$id" "$ouser" "$commit" "$check"
