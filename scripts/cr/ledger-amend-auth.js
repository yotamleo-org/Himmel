// scripts/cr/ledger-amend-auth.js - who may lower a CR ledger finding.
//
// An `amend` row that can lower a finding's blocking effect (severity below
// crit, verdict disproved/fixed/deferred, a deferred_to ticket, or a head
// re-key) counts only when it is signed: ledger-append.sh, the ledger's single
// writer, stamps every amend it writes with src and amend_mac, an HMAC-SHA256
// under the console's GO key (~/.config/himmel/go-hmac.key, the key
// scripts/lib/go-gate.sh go_msg_mac signs with) over domain himmel-amend-v1,
// branch, target_head, finding_id, artifact, perspective, the set and src.
// A hand-appended row has no valid mac, so every gate reader drops it.
//
// Cutover: rows ABOVE the first row carrying an amend_mac predate signing and
// are honoured unsigned. File position, not the row ts, decides: an appended
// row cannot backdate itself. A station with no readable GO key has nothing to
// verify against, so every row is honoured, as before.
// ponytail: (HIMMEL-6772) same-uid ceiling and sanctioned writer - a leg runs
// as the console's user, so it can read the key through a helper or run
// ledger-append.sh amend itself, which signs any lowering it validates; this
// closes hand-written rows only. Upgrade path: a separate-uid signer that only
// a judge or the console can drive.
//
// Readers: filterLines(lines) / filterRows(rows) before collecting amends.
// Writer: sign(rec) just before the row is appended.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const DOMAIN = "himmel-amend-v1";
const SRC = "ledger-append";

function readKey() {
  const home = process.env.HOME;
  if (!home) return null;
  let first;
  try {
    first = fs.readFileSync(path.join(home, ".config", "himmel", "go-hmac.key"), "utf8").split("\n")[0];
  } catch {
    return null;
  }
  return /^[0-9a-f]{64}$/.test(first) ? Buffer.from(first, "hex") : null;
}

function mac(o, key) {
  const set = o.set || {};
  const canon = Object.keys(set).sort().map((k) => [k, set[k]]);
  const msg = DOMAIN + "|" + JSON.stringify([o.branch || "", o.target_head || "", o.finding_id || "",
    o.artifact || "diff", o.perspective || "off", canon, o.src || ""]);
  return crypto.createHmac("sha256", key).update(msg).digest("hex");
}

function lowers(set) {
  if ("severity" in set && !["crit", "critical"].includes(String(set.severity).trim().toLowerCase())) return true;
  if ("verdict" in set && ["disproved", "fixed", "deferred"].includes(String(set.verdict).trim().toLowerCase())) return true;
  return Boolean(set.deferred_to) || "head" in set;
}

function verified(o, key) {
  if (typeof o.amend_mac !== "string") return false;
  const want = Buffer.from(mac(o, key), "utf8");
  const got = Buffer.from(o.amend_mac, "utf8");
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

// rows: parsed ledger rows in file order (null for an unparseable line).
function filterRows(rows) {
  const key = readKey();
  if (!key) return rows;
  const cut = rows.findIndex((o) => o && o.kind === "amend" && "amend_mac" in o);
  if (cut < 0) return rows;
  return rows.filter((o, i) => i < cut || !o || o.kind !== "amend" || !o.set || typeof o.set !== "object"
    || !lowers(o.set) || verified(o, key));
}

// lines: raw ledger lines; an unparseable line is kept for the reader to count.
function filterLines(lines) {
  const rows = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } });
  const keep = new Set(filterRows(rows));
  return lines.filter((l, i) => rows[i] === null || keep.has(rows[i]));
}

function sign(rec) {
  const key = readKey();
  if (!key) return rec;
  rec.src = SRC;
  rec.amend_mac = mac(rec, key);
  return rec;
}

module.exports = { filterLines, filterRows, sign };
