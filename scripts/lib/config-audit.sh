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
#   config-audit.sh list                             backups, newest first, with a key-name diff
#   config-audit.sh restore <id> [--script NAME]     put a backup's set back (audited, backed up)
#   config-audit.sh watch                            alert on a deleted, truncated or key-losing file
#   config-audit.sh check                            the same comparison, read-only (the doctor)
#   config-audit.sh accept                           take the live set as healthy (a deliberate hand edit)
#   config-audit.sh denied <file> <action> [--script NAME] [--pid N]
#                                                    log a refused write (block-himmel-config-writes.sh)
#
# THE SET: every backup holds the whole station config together: the .env
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
# never fails a config write); 2 usage; check exits 3 when it finds a loss.
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

_ca_env_file() {
    if [ -n "${HIMMEL_CONFIG_AUDIT_ENV_FILE:-}" ]; then printf '%s' "$HIMMEL_CONFIG_AUDIT_ENV_FILE"; return; fi
    _load_dotenv_envfile ""
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
function writeFile600(p, buf) {
  const fd = fs.openSync(p, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeSync(fd, buf); } finally { fs.closeSync(fd); }
}
function appendRow(file, row) {
  mkdir(STATE);
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.appendFileSync(fd, JSON.stringify(row) + "\n"); } finally { fs.closeSync(fd); }
}

function pre(target, script) {
  if (!inScope(target)) return "";
  mkdir(BACK);
  const m = members(target);
  const files = {};
  for (const [n, p] of m) { const b = read(p); files[n] = { path: p, sha256: sha(b) }; }
  const digest = sha(Buffer.from(JSON.stringify(m.map(([n]) => [n, files[n].sha256]))));
  const newest = manifests().find((x) => x.target === real(target));
  if (newest && newest.digest === digest) return newest.id;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const id = stamp + "-" + crypto.randomBytes(2).toString("hex");
  const dir = path.join(BACK, id);
  fs.mkdirSync(dir, { mode: 0o700 });
  for (const [n, p] of m) {
    const b = read(p);
    if (b === null) continue;
    if (n.startsWith("extra/")) mkdir(path.join(dir, "extra"));
    writeFile600(path.join(dir, n), b);
  }
  writeFile600(path.join(dir, "manifest.json"), JSON.stringify({ ts: now(), ms: Date.now(), script, target: real(target), digest, files }, null, 1) + "\n");
  return id;
}

function prune() {
  const byTarget = new Map();
  for (const x of manifests()) {
    const l = byTarget.get(x.target) || [];
    l.push(x);
    byTarget.set(x.target, l);
  }
  for (const l of byTarget.values()) for (const x of l.slice(KEEP)) fs.rmSync(x.dir, { recursive: true, force: true });
}

function snapshot() {
  const snap = {};
  for (const [n, p] of Object.entries(SET)) {
    if (!p) continue;
    const b = read(p);
    const k = keys(n, b);
    snap[n] = { path: p, present: b !== null, size: b === null ? 0 : b.length, keys: k === null ? null : [...k.keys()].sort() };
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
    if (!is || !was.present) continue;
    if (!is.present) { out.push({ file: n, path: was.path, kind: "deleted", lost: was.keys || [] }); continue; }
    if ((is.size === 0 && was.size > 0) || (was.keys !== null && is.keys === null)) { out.push({ file: n, path: was.path, kind: "truncated", lost: was.keys || [] }); continue; }
    const lost = (was.keys || []).filter((k) => !(is.keys || []).includes(k));
    if (lost.length) out.push({ file: n, path: was.path, kind: "lost keys", lost });
  }
  return out;
}
// The newest backup whose copy of the file is present and holds every lost key.
function goodBackup(p) {
  for (const x of manifests()) {
    const b = read(path.join(x.dir, p.file));
    const k = keys(p.file, b);
    if (b !== null && k !== null && b.length && p.lost.every((key) => k.has(key))) return x.id;
  }
  return null;
}
const describe = (p) => `${p.path} ${p.kind}` + (p.lost.length ? `: ${p.lost.slice(0, 20).join(", ")}${p.lost.length > 20 ? ` (+${p.lost.length - 20} more)` : ""}` : "");

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

function watch(readOnly) {
  const live = snapshot();
  const snap = loadWatch();
  if (!snap) { if (!readOnly) saveWatch(live); return []; }
  const ps = problems(snap, live);
  if (readOnly) return ps;
  if (!ps.length) { saveWatch(live); try { fs.unlinkSync(path.join(STATE, "alerted")); } catch {} return []; }
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
  else if (verb === "watch") watch(false);
  else if (verb === "denied") appendRow(path.join(STATE, "audit.jsonl"), {
    ts: now(), pid: Number(opt("--pid", "")) || null, session: E.CLAUDE_SESSION_ID || E.CLAUDE_CODE_SESSION_ID || "",
    script: opt("--script", ""), file: real(argv[0]), action: argv[1], denied: true });
  else if (verb === "accept") { saveWatch(snapshot()); try { fs.unlinkSync(path.join(STATE, "alerted")); } catch {} console.log("result=accepted"); }
  else if (verb === "check") { for (const p of watch(true)) { p.backup = goodBackup(p); console.log(`LOSS\t${p.file}\t${p.kind}\t${p.lost.join(",")}\t${p.backup || "-"}\t${p.path}`); } }
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
    if chat="$(_ca_operator_chat)" && command -v bun >/dev/null 2>&1; then
        # shellcheck disable=SC2086 # $tmo is "" or "timeout ..."
        $tmo bun "$_CA_DIR/../telegram/chief-route.ts" reply "$chat" "$text" >/dev/null 2>&1 && ok=0
    fi
    return "$ok"
}

_ca_watch() {
    local out line fp text state
    out="$(_ca_node watch)" || return 1
    state="${HIMMEL_CONFIG_AUDIT_DIR:-$(_himmel_config_dir)/state/config-audit}"
    while IFS= read -r line; do
        case "$line" in ALERT*) ;; *) continue ;; esac
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
    return 0
}

# A restored .env that still holds behaviour or gate keys came from before the
# split: map them forward. migrate-env.sh asks for consent and verifies itself.
_ca_map_forward() {
    local envf key moved=""
    envf="$(_ca_env_file)"
    [ -f "$envf" ] || return 0
    # shellcheck disable=SC2013 # the sed prints identifiers, one name per word
    for key in $(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$envf"); do
        case "$(_himmel_key_class "$key")" in config|policy) moved="$moved $key" ;; esac
    done
    [ -n "$moved" ] || return 0
    echo "restore: the restored .env predates the split (${moved# }); mapping forward through migrate-env.sh"
    if bash "$_CA_DIR/../setup/migrate-env.sh" --env "$envf" </dev/null >/dev/null 2>&1; then
        echo "restore: migrate-env.sh moved them"
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
        restore) [ "$#" -eq 1 ] || _ca_usage; _ca_restore "$1" "${script:-config-audit restore}" ;;
        watch) _ca_watch ;;
        accept) _ca_node accept ;;
        denied) [ "$#" -eq 2 ] || _ca_usage; _ca_node denied "$1" "$2" --script "$script" --pid "$pid" ;;
        check) local out; out="$(_ca_node check)" || return 1; [ -z "$out" ] && return 0; printf '%s\n' "$out"; return 3 ;;
        *) _ca_usage ;;
    esac
}

# Shell writers source this file and wrap their write in these two calls.
config_audit_pre() { config_audit_main pre "$1" --script "$2" 2>/dev/null || { echo "config-audit: WARN: no backup before writing $1" >&2; return 0; }; }
config_audit_post() { config_audit_main post "$1" "$2" "$3" --script "$4" --pid "$$" || echo "config-audit: WARN: no audit row for $2" >&2; return 0; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    config_audit_main "$@"
fi
