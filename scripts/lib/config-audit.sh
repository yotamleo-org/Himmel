#!/usr/bin/env bash
# config-audit.sh — the station config audit log, its backups, the watcher and
# the restore.
#
# WHY: on 2026-10-31 ~/.himmel/config.json vanished and nothing said so. For
# about 5 hours the fleet cap fell to 4 and five gates switched off. No writer
# logged a write, so the deleter was never found, and only the operator at the
# keyboard could put it back.
#
#   config-audit.sh pre <file> [--script NAME]       back up the full set; prints the backup id
#   config-audit.sh post <id> <file> <action> [--script NAME] [--pid N]
#                                                    append the audit row; keep N backups
#   config-audit.sh list                             the newest 10 backups of both groups, newest first,
#                                                    with a key-name diff (restore by id reaches older ones)
#   config-audit.sh scrub [--dry-run] "<names>" "<secret names>"
#                                                    drop those names' lines from every backup's .env
#                                                    copy, keeping the manifest sha256 and digest true;
#                                                    names only (migrate-env.sh, after a keyring move)
#   config-audit.sh restore <id> [--script NAME]     put a backup's set back (audited, backed up)
#   config-audit.sh watch                            alert on a deleted, truncated or key-losing file;
#                                                    on a healthy read keep a value backup of the config files;
#                                                    a key whose value now sits under a new name is a rename:
#                                                    one information line on stderr, no alert
#   config-audit.sh check                            the same comparison, read-only (the doctor): LOSS rows
#                                                    (exit 3), RENAME <file> <old> <new> <path> rows (exit 0), then
#                                                    BACKUP <id> <age> and NOBACKUP <file> <path> for a present
#                                                    file no backup holds (exit 0); UNKNOWN .env no file found <path>
#                                                    when no .env is found (exit 0, never a deleted LOSS)
#   config-audit.sh accept                           take the live set as healthy (a deliberate hand edit);
#                                                    refuses (exit 1, watch.json unchanged) when no .env is found
#   config-audit.sh denied <file> <action> [--script NAME] [--pid N]
#                                                    log a refused write (block-himmel-config-writes.sh)
#
# THE SET: every audited backup holds the whole station config together (a
# watcher backup holds the config files only, never .env; see STATE): the .env
# load_dotenv reads, ~/.himmel/himmel.conf, himmel.conf.local and config.json
# (plus the written file when it is none of these, e.g. a settings.json). So a
# restore brings back every key, including keys that lived in .env before the
# split. A restore writes back the four set files a backup holds and nothing
# else: it never deletes a file the backup lacks, and a settings.json copy under
# extra/ is for recovery by hand (restoring hook wiring remotely could unwire a
# newer guard). When a restored .env still holds behaviour or gate keys (a pre-split
# backup), the restore runs scripts/setup/migrate-env.sh to map them forward;
# without the operator's consent key that prints the plan and the keys keep
# working from .env with a DEPRECATED notice.
#
# STATE under ~/.himmel/state/config-audit/ (mode 700, files 600):
#   audit.jsonl   one row per write: ts, pid, session, script, file, action,
#                 before and after sha256, keys_added / keys_removed /
#                 keys_changed (NAMES, never values), backup id
#   backups/<id>/ the set as it was before a write; HIMMEL_CONFIG_BACKUPS_KEEP
#                 (default 10) newest are kept per written file. An unchanged
#                 set reuses the newest backup instead of copying it again.
#                 watch and accept also back the config files up (config.json,
#                 himmel.conf, himmel.conf.local; never .env) whenever they read
#                 healthy (script "watch"), the first run included: a changed
#                 value is a new backup and never replaces the last one, a value
#                 that flips back reuses its earlier backup, and a deleted or
#                 key-losing file backs up nothing, so the last good copy stays.
#                 Watcher and audited backups reuse and prune apart. A backup
#                 that fails exits watch with 4 after the alerts are sent. A dir
#                 with no manifest, or one that is not JSON, is removed
#                 after 10 minutes. A value change
#                 under the same key names reads healthy: the earlier value is
#                 the previous backup. A deleted .env restores only from an
#                 audited backup (or a migrate-env copy in ~/.himmel/env-backups,
#                 by hand); newer watcher backups push the audited ones off
#                 list, but restore by id still reaches them.
#   watch.json    the last healthy key snapshot of the set; an audited write
#                 moves it, so only an unaudited loss alerts
#   alerts.jsonl  every alert the watcher raised; alerted = the last one sent
#
# An alert goes to the operator's Telegram DM (the bridge outbox, as
# merge-block-alert.sh does) and to every armed chief inbox
# (<bridge root>/consoles/*.md, appended only when the file exists). It names
# the file, the lost keys and the newest backup that still holds them.
#
# Values never reach stdout, stderr, the audit log or an alert: keys are read
# by name. Backups hold values (they are copies), so they are mode 600.
#
# Exit: 0 ok; 1 a step failed (a writer warns and carries on: an audit fault
# never fails a config write); 2 usage; check exits 3 when it finds a loss; watch
# exits 4 when a healthy backup could not be kept (after its alerts went out).
#
# ponytail: the backups and this script are as writable as the files they
# guard (same uid), so a session can plant a backup. The operator's TOTP code
# gates only the Telegram restore. This script's own restore needs no code and
# is kept from a session only by the block-himmel-config-writes.sh speed bump.
# The list shows each backup's key diff. Upgrade path: a root-owned store with
# the restore as an afk-sudo kind.
#
# Seams (tests): HIMMEL_CONFIG_DIR (the station dir), HIMMEL_CONFIG_AUDIT_DIR,
# HIMMEL_CONFIG_AUDIT_ENV_FILE (the .env of the set), HIMMEL_CONFIG_BACKUPS_KEEP,
# HIMMEL_CONFIG_ALERT_CMD (replaces both alert sinks; called as `$CMD <text>`),
# BRIDGE_ROOT, TELEGRAM_ACCESS_PATH. Under HIMMEL_TEST_FIXTURE=1 the default
# sinks refuse unless BRIDGE_ROOT names a sandbox.
# Platform: bash 3.2-safe; needs node.

_CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-dotenv.sh
. "$_CA_DIR/load-dotenv.sh"

_ca_usage() {
    sed -n 's/^#   config-audit.sh/config-audit.sh/p' "${BASH_SOURCE[0]}" >&2
    exit 2
}

# The .env of the set is resolved from the himmel checkout (HIMMEL_REPO, else the
# checkout holding this script), never from the caller's directory: from inside
# another repo that repo's absent .env would read as every key deleted.
_ca_env_file() {
    if [ -n "${HIMMEL_CONFIG_AUDIT_ENV_FILE:-}" ]; then printf '%s' "$HIMMEL_CONFIG_AUDIT_ENV_FILE"; return; fi
    local root="${HIMMEL_REPO:-}"
    [ -n "$root" ] && [ -d "$root" ] || root="$_CA_DIR/../.."
    ( cd "$root" 2>/dev/null && _load_dotenv_envfile "" )
}

# The engine. Every verb runs here; bash resolves the paths and the key classes.
# shellcheck disable=SC2016 # node source, not shell
_CA_JS='
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const E = process.env;
const [verb, ...argv] = process.argv.slice(1);
const STATE = E.CA_STATE, BACK = path.join(STATE, "backups");
const KEEP = Math.max(1, parseInt(E.HIMMEL_CONFIG_BACKUPS_KEEP || "10", 10) || 10);
const SET = { ".env": E.CA_ENV, "himmel.conf": E.CA_CONF, "himmel.conf.local": E.CA_LOCAL, "config.json": E.CA_JSON };
const ID = /^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$/;
const ORPHAN_GRACE_MS = 600000;
const sha = (b) => b === null ? null : crypto.createHash("sha256").update(b).digest("hex");
const read = (p) => { try { return fs.readFileSync(p); } catch { return null; } };
const opt = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const mkdir = (d) => { fs.mkdirSync(d, { recursive: true, mode: 0o700 }); };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

// Key names of one file, with a per-key value digest kept in memory only.
// JSON: dotted leaf paths through objects (an array is a leaf). null = unparseable.
function keys(name, buf) {
  const out = new Map();
  if (buf === null) return out;
  if (name.endsWith(".json")) {
    let doc;
    try { doc = JSON.parse(buf.toString("utf8")); } catch { return null; }
    if (!doc || typeof doc !== "object" || Array.isArray(doc)) return null;
    const walk = (o, pre) => {
      for (const k of Object.keys(o)) {
        const v = o[k], p = pre ? pre + "." + k : k;
        if (v && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length) walk(v, p);
        else out.set(p, sha(JSON.stringify(v)));
      }
    };
    walk(doc, "");
    return out;
  }
  for (const raw of buf.toString("utf8").split("\n")) {
    const l = raw.replace(/\r$/, "");
    if (/^\s*#/.test(l)) continue;
    const i = l.indexOf("=");
    if (i < 1) continue;
    const k = l.slice(0, i).trim().replace(/^export\s+/, "");
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) out.set(k, sha(l.slice(i + 1)));
  }
  return out;
}
function diff(before, after) {
  const b = before || new Map(), a = after || new Map();
  return {
    keys_added: [...a.keys()].filter((k) => !b.has(k)).sort(),
    keys_removed: [...b.keys()].filter((k) => !a.has(k)).sort(),
    keys_changed: [...a.keys()].filter((k) => b.has(k) && b.get(k) !== a.get(k)).sort(),
  };
}
// A path through its links; an absent file through the links of its directory.
const real = (p) => {
  const r = path.resolve(p);
  try { return fs.realpathSync(r); } catch {}
  try { return path.join(fs.realpathSync(path.dirname(r)), path.basename(r)); } catch { return r; }
};
const nameOf = (file) => {
  const r = real(file);
  for (const [n, p] of Object.entries(SET)) if (p && real(p) === r) return n;
  return null;
};
// Audited: a member of the set, or a file under ~/.claude (the settings the
// wire-* writers rewrite). Anything else (a test fixture, a scratch copy) is
// not station config, so it never backs up the live set.
const inScope = (file) => {
  if (nameOf(file)) return true;
  if (!E.HOME) return false;
  return real(file).startsWith(real(path.join(E.HOME, ".claude")) + path.sep);
};
// The members of a backup for a target: the set, plus the target when it is outside it.
function members(target) {
  const m = Object.entries(SET).filter(([, p]) => p).map(([n, p]) => [n, p]);
  if (target && !nameOf(target)) m.push(["extra/" + path.basename(target), real(target)]);
  return m;
}
function manifests() {
  let ids = [];
  try { ids = fs.readdirSync(BACK).filter((d) => ID.test(d)); } catch { return []; }
  const out = [];
  for (const id of ids) {
    const dir = path.join(BACK, id);
    try {
      if (!fs.lstatSync(dir).isDirectory()) continue;
      out.push(Object.assign(JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8")), { id, dir }));
    } catch { /* a half-written backup is skipped */ }
  }
  // Newest first: by write time (ms), then id; ids of one second differ only by
  // their random suffix.
  return out.sort((x, y) => ((y.ms || 0) - (x.ms || 0)) || (x.id < y.id ? 1 : -1));
}
function writeFile600(p, data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const fd = fs.openSync(p, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { for (let off = 0; off < buf.length;) off += fs.writeSync(fd, buf, off, buf.length - off); } finally { fs.closeSync(fd); }
}
function appendRow(file, row) {
  mkdir(STATE);
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.appendFileSync(fd, JSON.stringify(row) + "\n"); } finally { fs.closeSync(fd); }
}

function pre(target, script) {
  if (!inScope(target)) return "";
  mkdir(BACK);
  const watcher = script === "watch";
  // The watcher leaves .env out: it holds secrets, changes often, and a scrubbed
  // secret would be copied back within a minute. Only an audited write copies it.
  const m = members(target).filter(([n]) => !(watcher && n === ".env"));
  const files = {};
  for (const [n, p] of m) { const b = read(p); files[n] = { path: p, sha256: sha(b) }; }
  const digest = sha(Buffer.from(JSON.stringify(m.map(([n]) => [n, files[n].sha256]))));
  // Reuse is per group: a watcher pass never stands in for an audited pre-image.
  const group = manifests().filter((x) => x.target === real(target) && (x.script === "watch") === watcher);
  if (watcher) {
    // A value that flips back to an earlier state reuses that backup and moves it
    // to the front, so a flapping value writes nothing.
    const same = group.find((x) => x.digest === digest);
    if (same) { if (same !== group[0]) bump(same, group[0]); return same.id; }
  } else if (group[0] && group[0].digest === digest) return group[0].id;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const id = stamp + "-" + crypto.randomBytes(2).toString("hex");
  const dir = path.join(BACK, id);
  fs.mkdirSync(dir, { mode: 0o700 });
  try {
    for (const [n, p] of m) {
      const b = read(p);
      if (b === null) continue;
      if (n.startsWith("extra/")) mkdir(path.join(dir, "extra"));
      writeFile600(path.join(dir, n), b);
    }
    writeFile600(path.join(dir, "manifest.json"), JSON.stringify({ ts: now(), ms: Date.now(), script, target: real(target), digest, files }, null, 1) + "\n");
  } catch (e) {
    fs.rmSync(dir, { recursive: true, force: true });
    throw e;
  }
  return id;
}
// Moves a backup to the front of its group: a new write time in its manifest.
function bump(x, front) {
  const { id, dir, ...man } = x;
  man.ms = Math.max(Date.now(), (front.ms || 0) + 1);
  man.ts = now();
  const tmp = path.join(dir, "manifest.json.bump-" + process.pid);
  fs.rmSync(tmp, { force: true });
  writeFile600(tmp, JSON.stringify(man, null, 1) + "\n");
  fs.renameSync(tmp, path.join(dir, "manifest.json"));
}

function prune() {
  const byTarget = new Map();
  // Watcher backups are their own group, so watch churn never evicts the audited
  // history of the same file, nor the reverse.
  for (const x of manifests()) {
    const key = x.target + (x.script === "watch" ? "|watch" : "");
    const l = byTarget.get(key) || [];
    l.push(x);
    byTarget.set(key, l);
  }
  for (const l of byTarget.values()) for (const x of l.slice(KEEP)) fs.rmSync(x.dir, { recursive: true, force: true });
  // A killed or failed write can leave a backup dir whose manifest is missing or
  // not JSON, which manifests() skips and nothing else removes; it goes after a
  // grace period. Any other read error (a permission fault, an I/O error) says
  // nothing about the backup, so that dir stays.
  let ids = [];
  try { ids = fs.readdirSync(BACK).filter((d) => ID.test(d)); } catch { return; }
  for (const id of ids) {
    const dir = path.join(BACK, id);
    try {
      const st = fs.lstatSync(dir);
      if (!st.isDirectory() || Date.now() - st.mtimeMs <= ORPHAN_GRACE_MS) continue;
      try { JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8")); continue; } catch (e) {
        if (!(e instanceof SyntaxError || (e && e.code === "ENOENT"))) continue;
      }
      fs.rmSync(dir, { recursive: true, force: true });
    } catch { /* gone already */ }
  }
}

// A healthy read is a restore point. The watcher backs up the config files
// through pre() (not .env), so a deletion of any cause leaves a copy of the last
// healthy values; an unchanged digest writes nothing. It runs only on the healthy
// path, so a deleted or key-losing file never replaces a good copy, and it skips
// a set with no member present. A failure prints a WARN row; _ca_watch turns it
// into stderr text and a non-zero exit after the alerts are sent.
function keepHealthy() {
  try {
    if (!Object.entries(SET).some(([n, p]) => p && n !== ".env" && read(p) !== null)) return;
    pre(SET["config.json"], "watch");
    prune();
  } catch (e) { console.log("WARN\tno healthy backup was kept: " + (e && e.code ? e.code : "error")); }
}

function snapshot() {
  const snap = {};
  for (const [n, p] of Object.entries(SET)) {
    if (!p) continue;
    const b = read(p);
    const k = keys(n, b);
    snap[n] = { path: p, present: b !== null, size: b === null ? 0 : b.length, keys: k === null ? null : [...k.keys()].sort(),
      digests: k === null ? null : Object.fromEntries([...k.entries()].sort((x, y) => (x[0] < y[0] ? -1 : 1))) };
  }
  return snap;
}
const WATCH = path.join(STATE, "watch.json");
const loadWatch = () => { try { return JSON.parse(fs.readFileSync(WATCH, "utf8")); } catch { return null; } };
function saveWatch(snap) {
  mkdir(STATE);
  const tmp = WATCH + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(snap, null, 1) + "\n", { mode: 0o600 });
  fs.renameSync(tmp, WATCH);
}

function post(id, target, action, script, pid) {
  if (!inScope(target)) return;
  const name = nameOf(target) || "extra/" + path.basename(target);
  const backup = ID.test(id || "") ? path.join(BACK, id) : null;
  const before = backup ? read(path.join(backup, name)) : null;
  const after = read(target);
  const d = diff(keys(name, before), keys(name, after));
  appendRow(path.join(STATE, "audit.jsonl"), Object.assign({
    ts: now(), pid: Number(pid) || null, session: E.CLAUDE_SESSION_ID || E.CLAUDE_CODE_SESSION_ID || "", script,
    file: real(target), action, before_sha256: sha(before), after_sha256: sha(after),
  }, d, { backup: backup ? id : null }));
  prune();
  // An audited write is the new baseline for its file.
  if (nameOf(target)) {
    const w = loadWatch();
    if (w) { w[name] = snapshot()[name]; saveWatch(w); }
  }
}

// What is wrong with the live set against the snapshot.
function problems(snap, live) {
  const out = [];
  for (const [n, was] of Object.entries(snap)) {
    const is = live[n];
    // No .env found is unknown, never deleted: a wrong root reads the same as a deletion.
    if (n === ".env" && (!is || !is.present)) { out.push({ file: n, path: is ? is.path : "-", kind: "unknown", lost: [] }); continue; }
    if (!is || !was.present) continue;
    if (!is.present) { out.push({ file: n, path: was.path, kind: "deleted", lost: was.keys || [] }); continue; }
    if ((is.size === 0 && was.size > 0) || (was.keys !== null && is.keys === null)) { out.push({ file: n, path: was.path, kind: "truncated", lost: was.keys || [] }); continue; }
    let lost = (was.keys || []).filter((k) => !(is.keys || []).includes(k));
    const fresh = (is.keys || []).filter((k) => !(was.keys || []).includes(k)), taken = new Set(), renames = [];
    for (const k of lost) {
      const d = was.digests && was.digests[k];
      const to = d && is.digests ? fresh.find((f) => !taken.has(f) && is.digests[f] === d) : null;
      if (to) { taken.add(to); renames.push([k, to]); }
    }
    lost = lost.filter((k) => !renames.some((r) => r[0] === k));
    if (lost.length) out.push({ file: n, path: was.path, kind: "lost keys", lost, renames });
    else if (renames.length) out.push({ file: n, path: was.path, kind: "renamed", lost: [], renames });
  }
  return out;
}
const isLoss = (p) => p.kind !== "renamed" && p.kind !== "unknown";
const envFound = (snap) => Boolean(snap[".env"] && snap[".env"].present);
// An unknown .env keeps its last known keys in the baseline.
const keepEnv = (live, snap) => envFound(live) || !snap[".env"] ? live : Object.assign({}, live, { ".env": snap[".env"] });
const renamed = (p) => p.renames.map((r) => r[0] + " to " + r[1]).join(", ");
// The newest backup whose copy of the file is present and holds every lost key.
function goodBackup(p) {
  for (const x of manifests()) {
    const b = read(path.join(x.dir, p.file));
    const k = keys(p.file, b);
    if (b !== null && k !== null && b.length && p.lost.every((key) => k.has(key))) return x.id;
  }
  return null;
}
const describe = (p) => `${p.path} ${p.kind}` + (p.lost.length ? `: ${p.lost.slice(0, 20).join(", ")}${p.lost.length > 20 ? ` (+${p.lost.length - 20} more)` : ""}` : "")
  + (p.renames && p.renames.length ? ` (renamed: ${renamed(p)})` : "");

function list() {
  const live = snapshot();
  const rows = [];
  for (const x of manifests().slice(0, 10)) {
    const parts = [];
    for (const n of Object.keys(SET)) {
      if (!x.files || !x.files[n]) continue;
      const L = live[n] || { present: false, keys: null, path: "" };
      if (!x.files[n].sha256) { if (L.present) parts.push(`${n} absent`); continue; }
      const b = read(path.join(x.dir, n)) || Buffer.alloc(0);
      const k = keys(n, b);
      if (k === null) { parts.push(`${n} unparseable`); continue; }
      const was = [...k.keys()], is = L.keys || [];
      if (!L.present) { parts.push(`${n} back (${was.length} keys)`); continue; }
      const back = was.filter((key) => !is.includes(key)), drop = is.filter((key) => !was.includes(key));
      if (back.length || drop.length) parts.push(n + (back.length ? ` +${back.join(",")}` : "") + (drop.length ? ` -${drop.join(",")}` : ""));
      else if (!b.equals(read(L.path) || Buffer.alloc(0))) parts.push(`${n} values differ`);
    }
    rows.push(`${x.id} ${x.ts} ${x.script || "-"} :: ${parts.length ? parts.join("; ") : "same as live"}`);
  }
  console.log(rows.length ? rows.join("\n") : "no config backups");
}

// What check adds to the loss rows: BACKUP <id> <age> for the newest backup that holds a file, and
// NOBACKUP <file> <path> for each present set file that no backup holds.
function backupRows() {
  const ms = manifests(), live = snapshot(), rows = [];
  const holds = (x, n) => x.files && x.files[n] && x.files[n].sha256;
  const newest = ms.find((x) => Object.keys(x.files || {}).some((n) => holds(x, n)));
  if (newest) {
    const s = Math.max(0, Math.round((Date.now() - (newest.ms || 0)) / 1000));
    rows.push(`BACKUP\t${newest.id}\t` + (s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d"));
  }
  // .env is covered only by audited backups (the watcher leaves it out), so it is not warned on.
  for (const [n, L] of Object.entries(live)) {
    if (n !== ".env" && L.present && !ms.some((x) => holds(x, n))) rows.push(`NOBACKUP\t${n}\t${L.path}`);
  }
  return rows;
}

function restore(id) {
  const x = manifests().find((m) => m.id === id);
  if (!ID.test(id) || !x) { console.log(`result=no-backup id=${id}`); process.exit(1); }
  // Every member is checked before the first file is written.
  const todo = [];
  for (const [n, p] of Object.entries(SET)) {
    if (!p || !x.files || !x.files[n] || !x.files[n].sha256) continue;
    const b = read(path.join(x.dir, n));
    if (b === null || sha(b) !== x.files[n].sha256) { console.log(`result=corrupt id=${id} file=${n}`); process.exit(1); }
    todo.push([n, p, b]);
  }
  const out = [];
  for (const [n, p, b] of todo) {
    const live = read(p);
    if (live !== null && live.equals(b)) continue;
    let real = p;
    try { real = fs.realpathSync(p); } catch { /* absent: write at the path itself */ }
    mkdir(path.dirname(real));
    let mode = 0o600;
    try { mode = fs.statSync(real).mode & 0o777; } catch { /* new file keeps 600 */ }
    const tmp = real + ".config-restore.tmp-" + process.pid;
    writeFile600(tmp, b);
    fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, real);
    const d = diff(keys(n, live), keys(n, b));
    out.push(n + (d.keys_added.length ? ` +${d.keys_added.join(",")}` : "") + (d.keys_removed.length ? ` -${d.keys_removed.join(",")}` : ""));
    console.log(`restored ${n} ${p}`);
  }
  console.log(`result=restored id=${id} ${out.length ? out.join("; ") : "nothing differed"}`);
}

// Drops the lines of the names in <drop> from the .env copy of every backup, then
// rewrites the sha256 of that member and the manifest digest so a restore still
// verifies. <secrets> only decides which remaining lines are named as kept.
// Output: would-scrub|scrubbed <id> per changed backup, kept <id> NAME per
// secret-named line left. Names only.
function scrub(dry, drop, secrets) {
  const dropSet = new Set(drop.split(/\s+/).filter(Boolean)), secSet = new Set(secrets.split(/\s+/).filter(Boolean));
  const keyOf = (line) => {
    const l = line.replace(/\r$/, "");
    if (/^\s*#/.test(l)) return "";
    const i = l.indexOf("=");
    return i < 1 ? "" : l.slice(0, i).trim().replace(/^export\s+/, "");
  };
  for (const x of manifests()) {
    const f = x.files && x.files[".env"];
    if (!f || !f.sha256) continue;
    const p = path.join(x.dir, ".env");
    const b = read(p);
    if (b === null) continue;
    const lines = b.toString("latin1").split("\n");
    const kept = lines.filter((l) => !dropSet.has(keyOf(l)));
    if (kept.length !== lines.length) {
      if (dry) console.log("would-scrub " + x.id);
      else {
        const nb = Buffer.from(kept.join("\n"), "latin1");
        f.sha256 = sha(nb);
        x.digest = sha(Buffer.from(JSON.stringify(Object.keys(x.files).map((n) => [n, x.files[n].sha256]))));
        const { id, dir, ...man } = x;
        const tmpEnv = p + ".scrub-" + process.pid, tmpMan = path.join(dir, "manifest.json.scrub-" + process.pid);
        for (const t of [tmpEnv, tmpMan]) fs.rmSync(t, { force: true });
        writeFile600(tmpEnv, nb);
        writeFile600(tmpMan, JSON.stringify(man, null, 1) + "\n");
        fs.renameSync(tmpEnv, p);
        fs.renameSync(tmpMan, path.join(dir, "manifest.json"));
        console.log("scrubbed " + id);
      }
    }
    for (const k of new Set(kept.map(keyOf).filter((k) => secSet.has(k)))) console.log("kept " + x.id + " " + k);
  }
}

function watch(readOnly) {
  const live = snapshot();
  const snap = loadWatch();
  if (!snap) { if (!readOnly) { saveWatch(live); keepHealthy(); } return []; }
  const all = problems(snap, live), ps = all.filter(isLoss);
  if (readOnly) return all;
  if (!ps.length) {
    saveWatch(keepEnv(live, snap)); keepHealthy(); try { fs.unlinkSync(path.join(STATE, "alerted")); } catch {}
    const rn = all.filter((p) => p.kind === "renamed");
    if (rn.length) console.log("INFO\tℹ️ himmel station config: " + rn.map((p) => `${p.path} renamed: ${renamed(p)}`).join("; ") + " (same values, nothing lost)");
    return [];
  }
  for (const p of ps) p.backup = goodBackup(p);
  const text = "⚠️ himmel station config: " + ps.map((p) => describe(p) + (p.backup ? ` (newest good backup ${p.backup})` : " (no backup holds them)")).join("; ")
    + ". List: /config backups. Restore: /config restore <id> <code>";
  const fp = sha(Buffer.from(JSON.stringify(ps)));
  let was = null;
  try { was = fs.readFileSync(path.join(STATE, "alerted"), "utf8").trim(); } catch {}
  if (was === fp) return [];
  appendRow(path.join(STATE, "alerts.jsonl"), { ts: now(), problems: ps, text });
  console.log("ALERT\t" + fp + "\t" + text);
  return ps;
}

try {
  if (verb === "pre") console.log(pre(argv[0], opt("--script", "")));
  else if (verb === "post") post(argv[0], argv[1], argv[2], opt("--script", ""), opt("--pid", ""));
  else if (verb === "list") list();
  else if (verb === "restore") restore(argv[0]);
  else if (verb === "scrub") { const dry = argv[0] === "--dry-run", a = dry ? argv.slice(1) : argv; scrub(dry, a[0] || "", a[1] || ""); }
  else if (verb === "watch") watch(false);
  else if (verb === "denied") appendRow(path.join(STATE, "audit.jsonl"), {
    ts: now(), pid: Number(opt("--pid", "")) || null, session: E.CLAUDE_SESSION_ID || E.CLAUDE_CODE_SESSION_ID || "",
    script: opt("--script", ""), file: real(argv[0]), action: argv[1], denied: true });
  else if (verb === "accept") {
    const live = snapshot();
    if (!envFound(live)) { console.log(`result=refused: no .env found${SET[".env"] ? " at " + SET[".env"] : ""}, so its keys cannot be taken as healthy; watch.json is unchanged`); process.exit(1); }
    saveWatch(live); keepHealthy(); try { fs.unlinkSync(path.join(STATE, "alerted")); } catch {} console.log("result=accepted"); }
  else if (verb === "check") {
    const found = watch(true);
    for (const p of found.filter(isLoss)) { p.backup = goodBackup(p); console.log(`LOSS\t${p.file}\t${p.kind}\t${p.lost.join(",") || "-"}\t${p.backup || "-"}\t${p.path}`); }
    for (const p of found) for (const [from, to] of p.renames || []) console.log(`RENAME\t${p.file}\t${from}\t${to}\t${p.path}`);
    for (const p of found.filter((x) => x.kind === "unknown")) console.log(`UNKNOWN\t${p.file}\tno file found\t${p.path}`);
    for (const r of backupRows()) console.log(r);
  }
  else process.exit(2);
} catch (e) {
  console.error(`config-audit: ${verb} failed: ${e && e.code ? e.code : "error"} ${e && e.message ? e.message.replace(/\n.*/s, "") : ""}`);
  process.exit(1);
}
'

_ca_node() {
    local dir envf
    dir="$(_himmel_config_dir)"
    envf="$(_ca_env_file)"
    CA_STATE="${HIMMEL_CONFIG_AUDIT_DIR:-$dir/state/config-audit}" CA_ENV="$envf" \
        CA_CONF="$dir/himmel.conf" CA_LOCAL="$dir/himmel.conf.local" CA_JSON="$dir/config.json" \
        node -e "$_CA_JS" "$@"
}

_ca_operator_chat() {
    local access="${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}"
    [ -r "$access" ] || return 1
    node -e 'const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const id = (a.allowFrom || []).map(String).find((x) => /^[1-9][0-9]*$/.test(x));
        if (!id) process.exit(1); process.stdout.write(id);' "$access" 2>/dev/null
}

# A test on the station never sends the operator a real Telegram message. Only exit 77 refuses:
# a missing or crashing guard lets the send through.
_ca_sender_door() {
    local rc=0
    bash "$_CA_DIR/test-run-guard" check --quiet --tool bun config-audit-alert >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 77 ]
}

# Appends one line to every chief inbox that already exists (never creates one),
# then queues the operator DM. 0 when at least one sink took it.
_ca_alert() {
    local text="$1" root ok=1 f chat tmo=""
    if [ -n "${HIMMEL_CONFIG_ALERT_CMD:-}" ]; then
        "$HIMMEL_CONFIG_ALERT_CMD" "$text"
        return
    fi
    if [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ] && [ -z "${BRIDGE_ROOT:-}" ]; then return 1; fi
    root="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
    for f in "$root"/consoles/*.md; do
        [ -f "$f" ] || continue
        CA_FILE="$f" CA_LINE="[config-audit] $text" node -e '
            const fs = require("fs");
            const fd = fs.openSync(process.env.CA_FILE, fs.constants.O_WRONLY | fs.constants.O_APPEND);
            try { fs.appendFileSync(fd, process.env.CA_LINE + "\n"); } finally { fs.closeSync(fd); }' 2>/dev/null && ok=0
    done
    command -v timeout >/dev/null 2>&1 && tmo="timeout -k 5 30"
    if chat="$(_ca_operator_chat)" && command -v bun >/dev/null 2>&1 && _ca_sender_door; then
        # shellcheck disable=SC2086 # $tmo is "" or "timeout ..."
        $tmo bun "$_CA_DIR/../telegram/chief-route.ts" reply "$chat" "$text" >/dev/null 2>&1 && ok=0
    fi
    return "$ok"
}

_ca_watch() {
    local out line fp text state rc=0
    out="$(_ca_node watch)" || return 1
    state="${HIMMEL_CONFIG_AUDIT_DIR:-$(_himmel_config_dir)/state/config-audit}"
    while IFS= read -r line; do
        case "$line" in
            ALERT*) ;;
            WARN*) echo "config-audit: WARN: $(printf '%s' "$line" | cut -f2-)" >&2; rc=4; continue ;;
            INFO*) echo "config-audit: $(printf '%s' "$line" | cut -f2-)" >&2; continue ;;
            *) continue ;;
        esac
        fp="$(printf '%s' "$line" | cut -f2)"
        text="$(printf '%s' "$line" | cut -f3-)"
        echo "config-audit: $text" >&2
        if _ca_alert "$text"; then
            printf '%s\n' "$fp" > "$state/alerted"
        else
            echo "config-audit: the alert reached no sink; the next run retries" >&2
        fi
    done <<EOF
$out
EOF
    return "$rc"
}

# A restored .env that still holds behaviour or gate keys came from before the
# split: map them forward. migrate-env.sh asks for consent and verifies itself.
_ca_map_forward() {
    local envf conf pol key pv moved="" clash="" pclash="" punread="" wins=""
    envf="$(_ca_env_file)"
    conf="$(_himmel_config_dir)/himmel.conf"
    pol="$(_himmel_policy_dir)/config.json" || pol=""
    [ -f "$envf" ] || return 0
    # shellcheck disable=SC2013 # the sed prints identifiers, one name per word
    for key in $(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$envf"); do
        case "$(_himmel_key_class "$key")" in config|policy) moved="$moved $key" ;; *) continue ;; esac
        grep -q "^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}[[:space:]]*=" "$conf" 2>/dev/null && clash="$clash $key"
        # load_policy reads config.json .policy before .env and fails closed on a file it
        # cannot parse; only the key name is kept.
        if [ "$(_himmel_key_class "$key")" = policy ] && [ -f "$pol" ]; then
            if ! pv="$(_himmel_policy_json "$pol" "$key")"; then punread=1
            elif [ -n "$pv" ]; then pclash="$pclash $key"; fi
        fi
    done
    [ -z "$clash" ] || wins="himmel.conf still sets ${clash# }"
    [ -z "$pclash" ] || wins="${wins:+$wins and the live }config.json still sets ${pclash# }"
    [ -n "$moved" ] || return 0
    echo "restore: the restored .env predates the split (${moved# }); mapping forward through migrate-env.sh"
    if bash "$_CA_DIR/../setup/migrate-env.sh" --env "$envf" </dev/null >/dev/null 2>&1; then
        echo "restore: migrate-env.sh moved them"
    elif [ -n "$punread" ]; then
        echo "restore: migrate-env.sh left them in .env, and the live config.json cannot be read, so load_policy fails closed on it; the operator repairs it at a prompt"
    elif [ -n "$wins" ]; then
        echo "restore: migrate-env.sh left them in .env, and the live $wins, which wins over .env; the operator resolves each at a prompt"
    else
        echo "restore: migrate-env.sh left them in .env (they still work, with a DEPRECATED notice); the operator runs it at a prompt"
    fi
}

_ca_restore() {
    local id="$1" script="$2" out rc n f bid
    case "$id" in [0-9]*T[0-9]*Z-*) ;; *) echo "result=no-backup id=$id"; return 1 ;; esac
    # The live set first, so the restore itself can be undone; no undo backup, no restore.
    bid="$(_ca_node pre "$(_himmel_config_dir)/config.json" --script "$script")" \
        || { echo "result=no-undo-backup id=$id (the live set could not be backed up; nothing was written)"; return 1; }
    out="$(_ca_node restore "$id")"; rc=$?
    printf '%s\n' "$out" | grep -v '^restored '
    # A write that failed midway still audits the files it already replaced.
    while IFS= read -r n; do
        case "$n" in "restored "*) ;; *) continue ;; esac
        f="${n#restored * }"
        _ca_node post "$bid" "$f" restore --script "$script" --pid "$$" || echo "config-audit: WARN: no audit row for $f" >&2
        case "$n" in "restored .env "*) _ca_map_forward ;; esac
    done <<EOF
$out
EOF
    [ "$rc" -eq 0 ]
}

config_audit_main() {
    local verb="${1:-}" script="" pid="$PPID" a
    [ -n "$verb" ] || _ca_usage
    shift
    command -v node >/dev/null 2>&1 || { echo "config-audit: node is not on PATH" >&2; return 1; }
    local -a rest=()
    while [ "$#" -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            --script) script="${1:-}"; shift ;;
            --pid) pid="${1:-}"; shift ;;
            *) rest+=("$a") ;;
        esac
    done
    set -- ${rest[@]+"${rest[@]}"}
    case "$verb" in
        pre) [ "$#" -eq 1 ] || _ca_usage; _ca_node pre "$1" --script "$script" ;;
        post) [ "$#" -eq 3 ] || _ca_usage; _ca_node post "$1" "$2" "$3" --script "$script" --pid "$pid" ;;
        list) _ca_node list ;;
        scrub) _ca_node scrub "$@" ;;
        restore) [ "$#" -eq 1 ] || _ca_usage; _ca_restore "$1" "${script:-config-audit restore}" ;;
        watch) _ca_watch ;;
        accept) _ca_node accept ;;
        denied) [ "$#" -eq 2 ] || _ca_usage; _ca_node denied "$1" "$2" --script "$script" --pid "$pid" ;;
        check) local out; out="$(_ca_node check)" || return 1; [ -z "$out" ] && return 0; printf '%s\n' "$out"
            case "$out" in LOSS*|*"
LOSS"*) return 3 ;; esac
            return 0 ;;
        *) _ca_usage ;;
    esac
}

# Shell writers source this file and wrap their write in these two calls.
config_audit_pre() { config_audit_main pre "$1" --script "$2" 2>/dev/null || { echo "config-audit: WARN: no backup before writing $1" >&2; return 0; }; }
config_audit_post() { config_audit_main post "$1" "$2" "$3" --script "$4" --pid "$$" || echo "config-audit: WARN: no audit row for $2" >&2; return 0; }
config_audit_scrub() { config_audit_main scrub "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    config_audit_main "$@"
fi
