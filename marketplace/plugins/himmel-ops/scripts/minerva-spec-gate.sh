#!/usr/bin/env bash
# minerva-spec-gate.sh <spec.md> — minerva Stage 2 runs this BEFORE
# dispatching the spec critic; a non-zero exit means "do not start the critic".
# A spec must carry:
#   1. `Estimate record: <path>` — an effort-assess record whose
#      dod.passed is true; the path is absolute or relative to the spec.
#   2. an `## Alternatives considered` section with at least one line;
#      `## Approaches`, the name superpowers 7.x brainstorming writes, counts.
#   3. a `## Definition of done` section with at least one line.
# Every missing item is named on stderr (all of them, not just the first).
# bash 3.2-safe; needs python3 (the same dependency as effort-assess).
#
# minerva-spec-gate.sh <spec.md> --readiness MANIFEST --source-head SHA — the
# optional critic-input readiness mode (skills/minerva/readiness.md). It runs the
# check above, then checks the manifest's inputs and asks the Judge delegate
# critic-findings.py validate-bundle, and prints one receipt JSON line on stdout:
# exit 0 ready, 2 malformed input, 3 stale, missing or incomplete input. A ready
# receipt authorizes no round, model or spend.
set -u

if [ "$#" -gt 1 ]; then
  exec python3 -I - "$0" "$@" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys, tempfile

SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
HEX64 = re.compile(r"[0-9a-f]{64}")
KEYS = {"schema", "critic_kind", "round", "artifact", "companion", "source_head", "estimate", "finding_intake",
        "previous_verdicts", "previous_findings", "dispositions", "unresolved_rulings"}
STATES = ("fixed", "accepted", "deferred")
MARKER = "scripts/lib/initiative-workers.sh"
DELEGATE = "scripts/handover/chief-kit/critic-findings.py"

receipt = {"schema": 1, "kind": "critic-readiness", "state": "refused", "critic_kind": None, "round": None,
           "manifest_sha256": None, "source_head": None, "artifact": None, "companion": None, "estimate": None,
           "finding_intake_sha256": None, "reasons": []}


class Stop(Exception):
    def __init__(self, code, reason):
        super().__init__(reason)
        self.code, self.reason = code, reason


def stop(code, reason):
    raise Stop(code, reason)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def unique_pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError("duplicate key")
        out[k] = v
    return out


def text(v):
    return isinstance(v, str) and v != "" and "\0" not in v


def is_ref(v):
    return (isinstance(v, dict) and set(v) == {"path", "sha256"} and text(v["path"])
            and isinstance(v["sha256"], str) and HEX64.fullmatch(v["sha256"]) is not None)


def unique(values):
    return len(values) == len(set(values))


def parse_flags(rest):
    opts = {}
    if len(rest) != 4:
        stop(2, "invalid")
    for flag, value in (rest[0:2], rest[2:4]):
        if flag not in ("--readiness", "--source-head") or flag in opts:
            stop(2, "invalid")
        opts[flag] = value
    if not SHA.fullmatch(opts["--source-head"]):
        stop(2, "invalid")
    receipt["source_head"] = opts["--source-head"]
    return opts["--readiness"], opts["--source-head"]


def load_manifest(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        stop(2, "invalid")
    receipt["manifest_sha256"] = sha256(data)
    def no_constant(name):
        raise ValueError(name)
    try:
        m = json.loads(data.decode("utf-8"), object_pairs_hook=unique_pairs, parse_constant=no_constant)
    except (ValueError, UnicodeError):
        stop(2, "invalid")
    if not isinstance(m, dict):
        stop(2, "invalid")
    if m.get("critic_kind") in ("spec", "plan"):
        receipt["critic_kind"] = m["critic_kind"]
    rnd = m.get("round")
    if type(rnd) is int and rnd > 0:
        receipt["round"] = rnd
    ok = (set(m) == KEYS and type(m["schema"]) is int and m["schema"] == 1
          and receipt["critic_kind"] is not None and receipt["round"] is not None
          and is_ref(m["artifact"]) and (m["companion"] is None or is_ref(m["companion"]))
          and isinstance(m["source_head"], str) and SHA.fullmatch(m["source_head"]) is not None
          and is_ref(m["estimate"]) and is_ref(m["finding_intake"])
          and isinstance(m["previous_verdicts"], list) and all(is_ref(v) for v in m["previous_verdicts"])
          and isinstance(m["previous_findings"], list)
          and all(isinstance(f, dict) and set(f) == {"finding_id", "verdict_sha256"} and text(f["finding_id"])
                  and isinstance(f["verdict_sha256"], str) and HEX64.fullmatch(f["verdict_sha256"]) is not None
                  for f in m["previous_findings"])
          and isinstance(m["dispositions"], list)
          and all(isinstance(d, dict) and set(d) == {"finding_id", "state", "evidence_path"} and text(d["finding_id"])
                  and d["state"] in STATES and text(d["evidence_path"]) for d in m["dispositions"])
          and isinstance(m["unresolved_rulings"], list) and all(text(u) for u in m["unresolved_rulings"]))
    if not ok:
        stop(2, "invalid")
    if not (unique([v["path"] for v in m["previous_verdicts"]])
            and unique([f["finding_id"] for f in m["previous_findings"]])
            and unique([d["finding_id"] for d in m["dispositions"]])
            and unique(m["unresolved_rulings"])):
        stop(2, "invalid")
    return m


def estimate_of(spec):
    with open(spec, encoding="utf-8", errors="replace") as f:
        for line in f:
            if re.match(r"\s*estimate record:", line, re.I):
                rec = line.split(":", 1)[1].strip().strip("`")
                return os.path.realpath(rec if os.path.isabs(rec) else os.path.join(os.path.dirname(spec), rec))
    return None


def within(path, root):
    return os.path.commonpath([path, root]) == root


def bind(m, spec, base):
    spec_real = os.path.realpath(spec)
    root = os.path.dirname(spec_real)

    def lexical(p):
        return os.path.normpath(p if os.path.isabs(p) else os.path.join(base, p))

    def real(p):
        return os.path.realpath(lexical(p))

    def plan_sibling(p):
        bucket = os.path.dirname(root)
        plans = os.path.join(bucket, "plans")
        lex = lexical(p)
        return (os.path.basename(root) in ("design", "designs") and os.path.basename(bucket) == "specs"
                and os.path.isdir(plans) and not os.path.islink(plans) and not os.path.islink(lex)
                and os.path.basename(os.path.dirname(lex)) == "plans" and os.path.dirname(real(p)) == plans)

    kind, art = m["critic_kind"], real(m["artifact"]["path"])
    if kind == "spec":
        if m["companion"] is not None or art != spec_real:
            stop(2, "invalid")
    else:
        if m["companion"] is None or real(m["companion"]["path"]) != spec_real or art == spec_real:
            stop(2, "invalid")
        if not (within(art, root) or plan_sibling(m["artifact"]["path"])):
            stop(2, "invalid")
    if real(m["estimate"]["path"]) != estimate_of(spec):
        stop(2, "invalid")
    evidence = [m["estimate"]["path"], m["finding_intake"]["path"]] + [v["path"] for v in m["previous_verdicts"]] \
        + [d["evidence_path"] for d in m["dispositions"]]
    if not all(within(real(p), root) for p in evidence):
        stop(2, "invalid")
    return spec_real, lexical, real


def current(ref, real, reason):
    path = real(ref["path"])
    if not os.path.isfile(path):
        stop(3, reason)
    try:
        with open(path, "rb") as f:
            digest = sha256(f.read())
    except OSError:
        stop(3, reason)
    if digest != ref["sha256"]:
        stop(3, reason)
    return {"path": path, "sha256": digest}


def anchor(gate):
    env = os.environ.get("HIMMEL_REPO", "")
    root = None
    if os.path.isabs(env) and os.path.isfile(os.path.join(os.path.realpath(env), MARKER)):
        root = os.path.realpath(env)
    else:
        d = os.path.dirname(os.path.realpath(gate))
        while True:
            if os.path.isfile(os.path.join(d, MARKER)):
                root = d
                break
            if os.path.dirname(d) == d:
                break
            d = os.path.dirname(d)
    if root is None:
        stop(3, "intake-incomplete")
    delegate = os.path.realpath(os.path.join(root, DELEGATE))
    if not (within(delegate, root) and delegate != root and os.path.isfile(delegate) and os.access(delegate, os.R_OK)):
        stop(3, "intake-incomplete")
    return delegate


def judge(delegate, bundle, spec_real, verdicts):
    private = tempfile.mkdtemp(prefix="minerva-readiness.")
    try:
        previous = os.path.join(private, "PREVIOUS.json")
        with open(previous, "w") as f:
            json.dump({"schema": 1, "verdicts": verdicts}, f)
        r = subprocess.run(["python3", delegate, "validate-bundle", bundle, "--spec", spec_real,
                            "--previous-verdicts", previous], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    finally:
        shutil.rmtree(private, ignore_errors=True)
    if r.returncode == 2:
        stop(2, "intake-invalid")
    if r.returncode != 0:
        stop(3, "intake-incomplete")
    try:
        return json.loads(r.stdout.decode("utf-8"))
    except (ValueError, UnicodeError):
        stop(3, "intake-incomplete")


def main(gate, spec, rest):
    manifest_path, head = parse_flags(rest)
    m = load_manifest(manifest_path)
    if subprocess.run(["bash", os.path.realpath(gate), spec], stdin=subprocess.DEVNULL,
                      stdout=subprocess.DEVNULL).returncode != 0:
        stop(3, "estimate-refused")
    spec_real, lexical, real = bind(m, spec, os.path.dirname(os.path.abspath(manifest_path)))
    if m["source_head"] != head:
        stop(3, "stale-source")
    receipt["artifact"] = current(m["artifact"], real, "stale-artifact")
    if m["companion"] is not None:
        receipt["companion"] = current(m["companion"], real, "stale-artifact")
    receipt["estimate"] = current(m["estimate"], real, "stale-artifact")
    intake = current(m["finding_intake"], real, "intake-incomplete")
    receipt["finding_intake_sha256"] = intake["sha256"]
    if not all(os.path.isfile(real(d["evidence_path"])) for d in m["dispositions"]):
        stop(3, "disposition-mismatch")
    if m["unresolved_rulings"]:
        stop(3, "unresolved-ruling")
    delegate = anchor(gate)
    verdicts = [{"path": os.path.join(os.path.realpath(os.path.dirname(lexical(v["path"]))), os.path.basename(v["path"])),
                 "sha256": v["sha256"]} for v in m["previous_verdicts"]]
    bundle_path = os.path.join(os.path.realpath(os.path.dirname(lexical(m["finding_intake"]["path"]))),
                               os.path.basename(m["finding_intake"]["path"]))
    bundle = judge(delegate, bundle_path, spec_real, verdicts)
    validated = bundle.get("previous_findings") if isinstance(bundle, dict) else None
    if not isinstance(validated, list):
        stop(3, "intake-incomplete")
    key = lambda f: json.dumps(f, sort_keys=True)
    if sorted(map(key, validated)) != sorted(map(key, m["previous_findings"])):
        stop(3, "intake-incomplete")
    if {f["finding_id"] for f in validated} != {d["finding_id"] for d in m["dispositions"]}:
        stop(3, "disposition-mismatch")
    receipt["state"] = "ready"
    return 0


try:
    code = main(sys.argv[1], sys.argv[2], sys.argv[3:])
except Stop as s:
    receipt["state"], receipt["reasons"], code = "refused", [s.reason], s.code
sys.stdout.write(json.dumps(receipt, separators=(",", ":")) + "\n")
sys.exit(code)
PY
fi

spec="${1:-}"
if [ ! -f "$spec" ]; then
  echo "minerva-spec-gate: spec file not found: ${spec:-<none>}" >&2
  exit 2
fi

missing=""
add(){ missing="${missing}  - $1
"; }

# section_has_body <heading text>: true when the section under that exact H2
# (case-insensitive, trailing space ok) has a non-blank line. Any H1 or H2 ends
# the section, so a later `# Notes` block is not counted as its content.
section_has_body(){
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    /^##?[[:space:]]/ {
      h = tolower($0); sub(/^#+[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      insec = ($0 ~ /^##[[:space:]]/ && h == want); next
    }
    insec && $0 ~ /[^[:space:]]/ { found = 1 }
    END { exit found ? 0 : 1 }' "$spec"
}

line="$(grep -i -m1 '^[[:space:]]*Estimate record:' "$spec" || true)"
rec="${line#*:}"
# shellcheck disable=SC2016  # the backticks are literal characters to strip, not a command substitution
rec="$(printf '%s' "$rec" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^`//; s/`$//')"
if [ -z "$rec" ]; then
  add "estimate record: no 'Estimate record: <path>' line (run effort-assess ticket, save its JSON, reference it)"
else
  case "$rec" in /*) path="$rec";; *) path="$(dirname "$spec")/$rec";; esac
  if [ ! -f "$path" ]; then
    add "estimate record: file not found: $rec"
  elif ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("dod",{}).get("passed") is True and "median_seq" in d and "sigma" in d else 1)' "$path" 2>/dev/null; then
    add "estimate record: $rec is not a passing effort-assess record (needs median_seq, sigma, dod.passed=true)"
  fi
fi

section_has_body 'Alternatives considered' || section_has_body 'Approaches' \
  || add "alternatives: no '## Alternatives considered' (or brainstorming's '## Approaches') section with content"
section_has_body 'Definition of done' || add "definition of done: no '## Definition of done' section with content"

if [ -n "$missing" ]; then
  printf 'minerva-spec-gate: REFUSED — do not start the spec critic. Missing:\n%s' "$missing" >&2
  exit 1
fi
echo "minerva-spec-gate: ok"
