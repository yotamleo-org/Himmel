#!/usr/bin/env bash
# scripts/upstreams/apply-drift-bump.sh — mechanically apply ONE upstream pin
# bump.
#
# WHY: the nightly fork-drift workflow only DETECTS drift and files a tracking
# issue; every resolution was a hand-driven ticket, and those stall (a pin
# silently advanced past a still-open bump ticket in unrelated PRs). The bump
# itself is two edits
# that MUST move together: the in-repo pin literal (what a fresh machine
# actually installs) and `synced_base` in scripts/upstreams.json (what the drift
# guard compares against). Split them and the guard lies in one direction or the
# other. This script is the structural fix: ONE call moves both, verifies the
# result, and restores both files untouched if anything is off.
#
# It deliberately does NOT resolve "what is upstream's latest" — that is
# scripts/check-plugin-drift.sh's job and it already owns the Releases-API /
# highest-stable-tag logic plus the latest_source escape hatch. Duplicating it
# here would mean a second version comparator to keep in sync (the first one is
# still being chased). So the caller reads the
# guard's BEHIND line and passes the target version in. That also keeps this
# script hermetic: no network, no gh, unit-testable offline.
#
# AUTO-BUMPABLE means the registry entry declares `version_pin`:
#     "version_pin": { "file": "<repo-relative path>",
#                      "template": "<literal with a {version} placeholder>" }
# The template must match EXACTLY ONCE in the file at the OLD version. An entry
# without `version_pin` is NOT auto-bumpable and exits 3 (SKIP) without writing
# anything — that is the correct answer for qmd, whose in-repo pin is a fork SHA
# rather than a version: moving its synced_base alone would flip the guard to
# CURRENT while the fork sits unrebased, laundering the signal.
#
# Usage:
#   bash scripts/upstreams/apply-drift-bump.sh <name> <new-version> --published <ISO-8601> [--sha256 <hex>] [--dry-run]
#
# Release-age gate: the npm rows already refuse a release younger than 72 h
# (minimumReleaseAge = 259200 s in bunfig.toml, min-release-age in .npmrc). A tag
# bump gets the same buffer: the caller passes the publish time of <new-version>
# (the Releases API `published_at`) and a tag younger than RELEASE_AGE_HOURS is
# refused (rc=5), never bumped. This script is offline, so it cannot look the date
# up; a bump without --published is refused too, else omitting the flag would
# skip the gate. DRIFT_NOW is the clock seam, for tests only.
#
# Split pins: an entry may add `companion_pins`, a list of
# {file, template} rows for literals that live elsewhere than `version_pin`
# (cli-proxy-api: the Linux twin's VERSION= and ASSET_SHA256=). Each template
# holds ONE placeholder, {version} or {sha256}; a {sha256} row needs --sha256
# <64-hex> (this script is offline and cannot derive a checksum). Every pin
# moves or none does; a companion not sitting at the old version aborts rc=4.
#
# Env / test seams:
#   DRIFT_REGISTRY    registry path (default: <repo>/scripts/upstreams.json).
#                     Same variable name check-plugin-drift.sh uses.
#   DRIFT_REPO_ROOT   root that `version_pin.file` resolves against
#                     (default: the repo this script lives in).
#   DRIFT_NOW         ISO-8601 clock for the release-age gate (test seam only;
#                     default: the real UTC time).
#
# Exit codes:
#   0  bumped (or, with --dry-run, would bump)
#   1  nothing to do — synced_base already equals <new-version>
#   2  usage / unknown entry / wrong kind+mode / malformed registry
#   3  SKIP — entry is not auto-bumpable (no version_pin); handle it manually
#   4  bump required but could NOT be applied safely (pin literal missing,
#      ambiguous, or post-write verification failed) — both files left untouched
#   5  release-age gate: --published missing, or <new-version> younger than 72 h
#      — nothing written; retry once the tag has aged
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${DRIFT_REPO_ROOT:-$(cd "$SELF_DIR/../.." && pwd)}"
REGISTRY="${DRIFT_REGISTRY:-$REPO_ROOT/scripts/upstreams.json}"

usage() {
  echo "usage: apply-drift-bump.sh <name> <new-version> --published <ISO-8601> [--sha256 <hex>] [--dry-run]" >&2
  echo "  <name>         a tag_release/base entry in scripts/upstreams.json" >&2
  echo "  <new-version>  the upstream version to pin to (leading 'v' optional)" >&2
  echo "  --published    when <new-version> was released (Releases API published_at);" >&2
  echo "                 a tag younger than 72 h is refused" >&2
  echo "  exit: 0 bumped | 1 already current | 2 usage/registry | 3 SKIP not" >&2
  echo "        auto-bumpable (no version_pin) | 4 bump failed, files restored |" >&2
  echo "        5 release younger than the 72 h buffer (or --published missing)" >&2
}

NAME=""
NEW_VER=""
DRY_RUN=0
NEW_SHA=""
PUBLISHED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --sha256)
      shift
      [ $# -gt 0 ] || { echo "apply-drift-bump: --sha256 needs a value" >&2; usage; exit 2; }
      NEW_SHA="$1"
      ;;
    --published)
      shift
      [ $# -gt 0 ] || { echo "apply-drift-bump: --published needs a value" >&2; usage; exit 2; }
      PUBLISHED="$1"
      ;;
    -h|--help) usage; exit 2 ;;
    -*) echo "apply-drift-bump: unknown flag '$1'" >&2; usage; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$NEW_VER" ]; then NEW_VER="$1"
      else echo "apply-drift-bump: unexpected extra argument '$1'" >&2; usage; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$NAME" ] || [ -z "$NEW_VER" ]; then
  usage
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "apply-drift-bump: python3 not on PATH — cannot parse the registry." >&2
  exit 2
fi
if [ ! -f "$REGISTRY" ]; then
  echo "apply-drift-bump: registry not found: $REGISTRY" >&2
  exit 2
fi

# The whole transaction (validate -> edit both files -> re-verify -> restore on
# any failure) lives in python: it is the only interpreter here that can re-parse
# the JSON to PROVE the edit landed as intended, and reading/writing with
# newline='' keeps CRLF/LF exactly as found (this repo is worked on from Windows).
python3 - "$REGISTRY" "$REPO_ROOT" "$NAME" "$NEW_VER" "$DRY_RUN" "$NEW_SHA" "$PUBLISHED" <<'PY'
import datetime, json, os, re, sys

reg_path, repo_root, name, new_raw, dry, new_sha, published = sys.argv[1:8]
dry = dry == "1"

# The same buffer the npm rows enforce (minimumReleaseAge = 259200 s = 72 h).
RELEASE_AGE_HOURS = 72

def die(code, msg):
    sys.stderr.write("apply-drift-bump: %s\n" % msg)
    sys.exit(code)

def read_text(p):
    with open(p, "r", encoding="utf-8", newline="") as fh:
        return fh.read()

def write_text(p, s):
    with open(p, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)

VER_RE = re.compile(r'^v?[0-9]+(\.[0-9]+)*([0-9A-Za-z.\-+]*)$')

def norm(v):
    return v[1:] if v.startswith("v") else v

def parse_utc(label, text):
    # fromisoformat only takes a trailing Z from 3.11 on; an offset-less time has
    # no zone to compare in, so it is refused rather than guessed.
    try:
        t = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        die(2, "%s %r is not an ISO-8601 timestamp" % (label, text))
    if t.tzinfo is None or "T" not in text:
        die(2, "%s %r needs a date, a time and a zone (e.g. 2026-10-22T12:00:00Z)" % (label, text))
    return t.astimezone(datetime.timezone.utc)

def numeric_key(v):
    # Compare only the leading dotted-numeric run; a trailing suffix
    # (-rc1, .post2, +local) is ignored for ordering. Enough for the ONE
    # question asked here: "is this a downgrade?".
    m = re.match(r'^([0-9]+(?:\.[0-9]+)*)', v)
    if not m:
        return ()
    return tuple(int(x) for x in m.group(1).split("."))

def cmp_ver(a, b):
    ka, kb = numeric_key(a), numeric_key(b)
    n = max(len(ka), len(kb))
    ka = ka + (0,) * (n - len(ka))
    kb = kb + (0,) * (n - len(kb))
    return (ka > kb) - (ka < kb)

if not VER_RE.match(new_raw):
    die(2, "target version %r is not a version string" % new_raw)
new_ver = norm(new_raw)
if new_sha and not re.match(r'^[0-9a-f]{64}$', new_sha):
    die(2, "--sha256 %r is not a lowercase 64-char hex sha256" % new_sha)

try:
    reg_text = read_text(reg_path)
    reg = json.loads(reg_text)
except Exception as exc:                     # malformed registry is never a bump
    die(2, "could not parse registry %s: %s" % (reg_path, exc))

entries = reg.get("entries", [])
match = [e for e in entries if e.get("name") == name]
if not match:
    die(2, "no registry entry named %r in %s" % (name, reg_path))
if len(match) > 1:
    die(2, "registry has %d entries named %r — names must be unique" % (len(match), name))
entry = match[0]

if entry.get("kind") != "tag_release" or entry.get("mode") != "base":
    die(2, "entry %r is kind=%s mode=%s — only tag_release/base carries an in-repo "
           "version pin this script can move" % (name, entry.get("kind"), entry.get("mode")))

old_ver = norm(entry.get("synced_base") or "")
if not old_ver:
    die(2, "entry %r has no synced_base" % name)

if old_ver == new_ver:
    print("nothing to do: %s synced_base is already %s" % (name, new_ver))
    sys.exit(1)

if cmp_ver(new_ver, old_ver) < 0:
    # A transient Releases-API blip (or a yanked release) must never roll a pin
    # BACKWARDS unattended — that would silently downgrade every fresh machine.
    die(2, "refusing to downgrade %s: synced_base %s > requested %s" % (name, old_ver, new_ver))

pin = entry.get("version_pin")
if not pin:
    print("SKIP %s: no version_pin declared — not auto-bumpable, handle manually "
          "(%s -> %s)" % (name, old_ver, new_ver))
    sys.exit(3)
if not isinstance(pin, dict) or not pin.get("file") or not pin.get("template"):
    die(2, "entry %r has a malformed version_pin (need {file, template})" % name)

# --- release-age gate ---------------------------------------------------------
# After SKIP / already-current / downgrade, so those verdicts are unchanged, and
# before any pin is read or written.
if not published:
    die(5, "refusing to bump %s: pass --published <ISO-8601 release time of %s> "
           "so the %d h release-age gate can run" % (name, new_ver, RELEASE_AGE_HOURS))
pub_t = parse_utc("--published", published)
now_env = os.environ.get("DRIFT_NOW", "")
now_t = parse_utc("DRIFT_NOW", now_env) if now_env else datetime.datetime.now(datetime.timezone.utc)
age_h = (now_t - pub_t).total_seconds() / 3600.0
if age_h < RELEASE_AGE_HOURS:
    die(5, "refusing to bump %s to %s: published %s, %.1f h old, inside the %d h "
           "release-age buffer — retry after it has aged" % (name, new_ver, published, age_h, RELEASE_AGE_HOURS))

pin_rel, template = pin["file"], pin["template"]
n_ph = template.count("{version}")
if n_ph != 1:
    # EXACTLY one, as documented (CR round-7 codex-2). The old check only
    # required at least one, so a two-placeholder template was accepted and then
    # silently expanded both — the file-level uniqueness check below would catch
    # most of the damage, but the registry is the place to reject a malformed
    # template, not the place to survive one.
    die(2, "entry %r version_pin.template must contain {version} exactly once "
           "(found %d)" % (name, n_ph))
# The registry is in-repo, but a pin path is still a write target: keep it
# provably inside the repo rather than trusting the field.
if os.path.isabs(pin_rel) or ".." in pin_rel.replace("\\", "/").split("/"):
    die(2, "entry %r version_pin.file must be a repo-relative path without '..' "
           "(got %r)" % (name, pin_rel))
pin_path = os.path.join(repo_root, pin_rel)
if not os.path.isfile(pin_path):
    die(4, "version_pin file not found: %s" % pin_path)

# --- companion pins -------------------------------------------
# An entry whose pin literal lives in more than one place (cli-proxy-api: the
# registry's version_pin is the .ps1, the Linux twin's VERSION= and ASSET_SHA256=
# are separate literals) declares the rest as `companion_pins`, each
# {file, template} with ONE placeholder: {version}, or {sha256} for a checksum
# the caller supplies with --sha256 (this script stays offline, so it cannot
# derive one). The bump moves every pin or none -- a half-moved split pin is the
# bug this exists to prevent.
companions = entry.get("companion_pins", [])
if not isinstance(companions, list):
    die(2, "entry %r companion_pins must be a list of {file, template}" % name)
need_sha = False
for c in companions:
    if (not isinstance(c, dict) or not isinstance(c.get("file"), str)
            or not isinstance(c.get("template"), str)
            or not c["file"] or not c["template"]):
        die(2, "entry %r has a malformed companion_pins row (need {file, template})" % name)
    tpl = c["template"]
    if tpl.count("{version}") + tpl.count("{sha256}") != 1:
        die(2, "entry %r companion template must hold exactly one {version} or "
               "{sha256} placeholder (got %r)" % (name, tpl))
    crel = c["file"]
    if os.path.isabs(crel) or ".." in crel.replace("\\", "/").split("/"):
        die(2, "entry %r companion file must be a repo-relative path without '..' "
               "(got %r)" % (name, crel))
    if "{sha256}" in tpl:
        need_sha = True
if need_sha and not new_sha:
    die(2, "entry %r pins a sha256: pass --sha256 <64-hex> of the new release asset" % name)
if new_sha and not need_sha:
    die(2, "entry %r declares no {sha256} companion pin; --sha256 does not apply" % name)

# path -> [original text, new text]; insertion order is the write order
edits = {}
def load(rel):
    p = os.path.join(repo_root, rel)
    if rel not in edits:
        if not os.path.isfile(p):
            die(4, "pin file not found: %s" % p)
        t = read_text(p)
        edits[rel] = [t, t]
    return edits[rel]

old_lit = template.replace("{version}", old_ver)
new_lit = template.replace("{version}", new_ver)

main = load(pin_rel)
hits = main[1].count(old_lit)
if hits != 1:
    die(4, "pin literal %r occurs %d time(s) in %s — expected exactly 1; "
           "fix version_pin.template in the registry" % (old_lit, hits, pin_rel))
main[1] = main[1].replace(old_lit, new_lit)

SHA_RE = r'[0-9a-f]{64}'
verify = [(pin_rel, new_lit, old_lit)]
for c in companions:
    crel, ctpl = c["file"], c["template"]
    pair = load(crel)
    pat = re.escape(ctpl).replace(re.escape("{version}"), re.escape(old_ver)) \
                         .replace(re.escape("{sha256}"), SHA_RE)
    found = re.findall(pat, pair[1])
    if len(found) != 1:
        die(4, "companion pin %r matches %d time(s) in %s at %s — expected "
               "exactly 1; the Linux and .ps1 pins have drifted apart, fix them "
               "by hand first" % (ctpl, len(found), crel, old_ver))
    c_new = ctpl.replace("{version}", new_ver).replace("{sha256}", new_sha or "")
    pair[1] = re.sub(pat, lambda _m: c_new, pair[1])
    verify.append((crel, c_new, found[0] if "{version}" in ctpl else None))

# --- registry edit: rewrite synced_base INSIDE this entry only ---------------
# A bare `"synced_base": "<old>"` replace would be ambiguous the moment two
# entries share a version, so anchor on this entry's "name" key and take the
# FIRST synced_base after it (name is the entry's leading key in this file).
name_m = re.search(r'"name"\s*:\s*"%s"' % re.escape(name), reg_text)
if not name_m:
    die(4, 'could not locate the "name": "%s" key in %s' % (name, reg_path))
sb_m = re.compile(r'("synced_base"\s*:\s*")%s(")' % re.escape(entry["synced_base"])) \
         .search(reg_text, name_m.end())
if not sb_m:
    die(4, "could not locate this entry's synced_base literal in %s" % reg_path)
new_reg_text = reg_text[:sb_m.start()] + sb_m.group(1) + new_ver + sb_m.group(2) \
             + reg_text[sb_m.end():]

files = ", ".join([os.path.relpath(reg_path, repo_root).replace("\\", "/")] + list(edits))
if dry:
    print("DRY %s %s -> %s (files: %s)" % (name, old_ver, new_ver, files))
    sys.exit(0)

# Every write is inside the restore-protected region: a failure part-way (disk
# full, a lock, a permissions flip) must never leave the registry or ANY pin file
# truncated or half-moved -- the one outcome this script exists to prevent. The
# failed open(p, "w") TRUNCATES before the write raises, so restoring from the
# originals read above is safe even when a given write never started.
def restore_all():
    write_text(reg_path, reg_text)
    for rel, pair in edits.items():
        write_text(os.path.join(repo_root, rel), pair[0])

def restore(msg):
    try:
        restore_all()
    except Exception as exc:
        die(4, "%s — AND the restore failed (%s); inspect the files by hand" % (msg, exc))
    die(4, "%s — %s restored" % (msg, "both files" if len(edits) == 1 else "all files"))

try:
    write_text(reg_path, new_reg_text)
    for rel, pair in edits.items():
        write_text(os.path.join(repo_root, rel), pair[1])
except Exception as exc:
    restore("could not write the bump (%s)" % exc)

# --- verify, or put every file back exactly as it was -------------------------
try:
    after = json.loads(read_text(reg_path))
except Exception as exc:
    restore("registry no longer parses after the edit (%s)" % exc)

def without_sb(e):
    return {k: v for k, v in e.items() if k != "synced_base"}

before_entries, after_entries = entries, after.get("entries", [])
if len(after_entries) != len(before_entries):
    restore("entry count changed (%d -> %d)" % (len(before_entries), len(after_entries)))
for b, a in zip(before_entries, after_entries):
    if b.get("name") == name:
        if a.get("synced_base") != new_ver:
            restore("entry %r synced_base is %r, expected %r"
                    % (name, a.get("synced_base"), new_ver))
        if without_sb(a) != without_sb(b):
            restore("entry %r changed beyond synced_base" % name)
    elif a != b:
        restore("unrelated entry %r was modified" % b.get("name"))

for rel, want, gone in verify:
    got = read_text(os.path.join(repo_root, rel))
    if got.count(want) != 1 or (gone and got.count(gone) != 0):
        restore("pin literal %r in %s did not land exactly once" % (want, rel))

print("BUMP %s %s -> %s (files: %s)" % (name, old_ver, new_ver, files))
sys.exit(0)
PY
exit $?
