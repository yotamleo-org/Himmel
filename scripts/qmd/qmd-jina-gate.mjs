#!/usr/bin/env node
// qmd-jina-gate.mjs - refuse a remote qmd model for any index that
// holds a collection the egress matrix denies for that provider.
//
// qmd's model config is per INDEX (index.yml `models:`), not per collection, so
// "salus stays local" holds only if salus lives in its own index. This gate
// checks one index.yml: for every remote role (an `openai:` model URI that is
// not a loopback endpoint) x every collection in that index, the matrix must
// allow <corpus> x <provider> x <purpose>, where each collection maps to its
// corpora through qmd-collection-corpus.json. A collection with no mapping is
// denied. The matrix is evaluated by the shared egress-matrix-eval.mjs, never
// re-implemented here.
//
// A provider in PINNED additionally accepts only its pinned model per role.
//
// Names are not enough: a collection is also refused when its path overlaps a
// PHI root (equal, inside, or containing one), so a collection called
// "himmel" that points at the salus vault cannot ride an allowed name. PHI
// roots are the graphify fence lists (phi-roots, egress-denylist under
// CLAUDE_GLM_CONFIG_DIR, default ~/.config/claude-glm), a `.salus` marker at
// the path or any ancestor, and the path of every salus collection in the
// sibling index configs next to the checked one.
//
// Usage: node qmd-jina-gate.mjs <index.yml> [<index.sqlite>]
// Exit 0 allowed (also when no role is remote), 3 refused, 2 usage/unreadable.
// qmd reads the config first and these environment variables only when the
// config sets nothing: QMD_EMBED_MODEL, QMD_RERANK_MODEL, QMD_GENERATE_MODEL,
// QMD_OPENAI_BASE_URL. The gate does not rely on that order for the models: a
// role is remote when EITHER the config or the environment names a remote model.
// The base URL is resolved config-first, as qmd does.
import { execFileSync } from "node:child_process";
import { accessSync, constants, existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const evalCli = join(here, "..", "guardrails", "egress-matrix-eval.mjs");
// The matrix is per provider, not per model, so the consumer pins the models a
// provider may serve. A role with no entry has no pinned model and is refused.
const PINNED = { openrouter: { embed: "openai:qwen/qwen3-embedding-8b", rerank: "openai:cohere/rerank-4-fast" } };
const PURPOSE = { embed: "embedding", rerank: "rerank", generate: "inference" };
const ENV_ROLE = { embed: "QMD_EMBED_MODEL", rerank: "QMD_RERANK_MODEL", generate: "QMD_GENERATE_MODEL" };

const cfgPath = process.argv[2];
if (!cfgPath) {
  process.stderr.write("qmd-jina-gate: need <index.yml>\n");
  process.exit(2);
}

let text, map;
try {
  text = readFileSync(cfgPath, "utf8");
  map = JSON.parse(readFileSync(join(here, "qmd-collection-corpus.json"), "utf8")).collections;
} catch (e) {
  process.stderr.write(`qmd-jina-gate: cannot read ${e?.path ?? cfgPath}: ${e?.message ?? e}\n`);
  process.exit(2);
}

// index.yml is two levels of plain mappings; read only the keys the gate needs.
const unquote = (s) => s.replace(/\s+#.*$/, "").trim().replace(/^(['"])(.*)\1$/, "$2");
// collection name -> its configured path, read from a config text (two levels).
function collectionPaths(txt) {
  const out = {};
  let inCols = false, indent0 = 0, cur = "";
  for (const line of txt.split("\n")) {
    if (/^\s*(#.*)?$/.test(line)) continue;
    if (/^\S/.test(line)) { inCols = /^collections:\s*(#.*)?$/.test(line); indent0 = 0; cur = ""; continue; }
    if (!inCols) continue;
    const ind = line.length - line.trimStart().length;
    if (!indent0) indent0 = ind;
    const t = line.trim();
    if (ind === indent0) {
      const m = t.match(/^("[^"]+"|'[^']+'|[^\s:#]+):\s*(#.*)?$/);
      cur = m ? unquote(m[1]) : "";
    } else if (cur && !(cur in out)) {
      const pm = t.match(/^path:\s*(.+)$/);
      if (pm) out[cur] = unquote(pm[1]);
    }
  }
  return out;
}
const expand = (p) => (p === "~" || p.startsWith("~/") ? join(homedir(), p.slice(1)) : p);
const lc = (p) => p.toLowerCase();
const forms = (p) => {
  const abs = resolve(expand(p));
  const out = [lc(abs)];
  try { out.push(lc(realpathSync(abs))); } catch { /* not on disk: the lexical form is all there is */ }
  return out;
};
const under = (a, b) => a === b || a.startsWith(b.endsWith(sep) ? b : b + sep);
const overlaps = (a, b) => under(a, b) || under(b, a);

const collections = [];
const models = {};
const unsupported = [];
const modelsUnreadable = []; // a models line we cannot attribute may hide a remote role: refuse always
let section = "";
let childIndent = 0;
for (const line of text.split("\n")) {
  if (/^\s*(#.*)?$/.test(line)) continue;
  const inline = line.match(/^(collections|models):\s*([^#\s].*)$/);
  if (inline) {
    unsupported.push(`"${inline[1]}:" uses a flow/inline value`);
    // an inline models value can name a remote role the line reader never sees, even through a YAML escape
    if (inline[1] === "models") modelsUnreadable.push("inline models value (text withheld)");
    section = "";
    continue;
  }
  const top = line.match(/^([A-Za-z_][\w-]*):\s*(#.*)?$/);
  if (top) { section = top[1]; childIndent = 0; continue; }
  if (/^\S/.test(line)) {
    if (/^["']\s*(collections|models)\s*["']\s*:/.test(line)) modelsUnreadable.push("quoted top-level key (text withheld)");
    section = "";
    continue;
  }
  const indent = line.length - line.trimStart().length;
  if (section !== "collections" && section !== "models") continue;
  if (!childIndent) childIndent = indent;
  if (indent !== childIndent) continue; // deeper levels (collection fields) are not names
  if (section === "collections") {
    const m = line.trim().match(/^("[^"]+"|'[^']+'|[^\s:#]+):\s*(#.*)?$/);
    if (m) collections.push(unquote(m[1]));
    else unsupported.push(`unparsed collections entry: ${line.trim()}`);
  } else {
    const m = line.trim().match(/^(["']?)([A-Za-z_]+)\1:\s*(.+)$/);
    if (m) models[m[2]] = unquote(m[3]);
    else modelsUnreadable.push("unparsed models entry (text withheld)");
  }
}

// The index database counts too: qmd embeds every ACTIVE document in it, whatever
// the config lists, so a collection removed from index.yml but still active in
// the database would be sent to the remote model. A database that cannot be
// read fails closed; a database that does not exist yet holds nothing, since
// its collections can only come from the config checked above.
const cfgCollections = collections.slice();
const dbPath = process.argv[3];
const dbProblems = [];
if (dbPath && existsSync(dbPath)) {
  try {
    const out = execFileSync("sqlite3", ["-init", "/dev/null", "-readonly", dbPath, "SELECT DISTINCT collection FROM documents WHERE active = 1;"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    for (const c of out.split("\n").map((x) => x.trim()).filter(Boolean)) if (!collections.includes(c)) collections.push(c);
  } catch {
    dbProblems.push(`cannot read the active collections of ${dbPath} (sqlite3 missing or unreadable database)`);
  }
}

const baseUrl = models.openai_base_url || process.env.QMD_OPENAI_BASE_URL || "";
function providerOf() {
  if (!baseUrl) return "openai-unconfigured"; // cannot be proven local
  let url;
  try { url = new URL(baseUrl); } catch { return "openai-unparseable"; }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (["localhost", "127.0.0.1", "::1"].includes(host)) return null; // on-machine server
  if (url.protocol !== "https:") return `${host}-insecure-${url.protocol.replace(":", "")}`; // never matches an allow row
  if (host === "jina.ai" || host.endsWith(".jina.ai")) return "jina";
  if (host === "openrouter.ai") return "openrouter";
  return `${host}-unrecognised`; // a wildcard allow row must never approve a host nobody vetted
}

// A role is local only when its value is plainly a local GGUF (hf: URI, a path,
// or *.gguf) with no YAML escape; anything else, an escaped "openai\x3a..."
// included, is treated as remote and checked.
const isLocalModel = (u) =>
  u === "" || (!u.includes("\\") && (/^hf:/.test(u) || /^(\/|~\/|\.\/)/.test(u) || (/\.gguf$/i.test(u) && !/^[A-Za-z][\w+.-]*:/.test(u))));

const refusals = [];
let remoteRoles = 0;
for (const [role, purpose] of Object.entries(PURPOSE)) {
  if (isLocalModel(models[role] ?? "") && isLocalModel(process.env[ENV_ROLE[role]] ?? "")) continue;
  remoteRoles++;
  const provider = providerOf();
  if (provider === null) continue;
  if (provider.includes("-insecure-")) {
    refusals.push(`${role} endpoint ${baseUrl} is not https and not loopback`);
    continue;
  }
  if (provider === "openai-unconfigured" || provider === "openai-unparseable") {
    refusals.push(`${role} has a remote model but the base URL is ${provider === "openai-unconfigured" ? "not set" : "not a valid URL"} (models.openai_base_url or QMD_OPENAI_BASE_URL)`);
    continue;
  }
  if (provider.endsWith("-unrecognised")) {
    refusals.push(`${role} endpoint ${baseUrl} is not a recognised provider (jina, openrouter)`);
    continue;
  }
  if (PINNED[provider]) {
    const pin = PINNED[provider][role];
    for (const value of [models[role] ?? "", process.env[ENV_ROLE[role]] ?? ""]) {
      if (isLocalModel(value) || value === pin) continue;
      refusals.push(pin
        ? `${role} model "${value}" is not the pinned ${provider} model ${pin}`
        : `${role} on ${provider} has no pinned model (remote ${role} refused)`);
    }
  }
  for (const col of collections) {
    const corpora = map[col];
    if (!corpora) {
      refusals.push(`collection "${col}" has no corpus mapping (unmapped = denied) for ${role} on ${provider}`);
      continue;
    }
    for (const corpus of corpora) {
      let verdict = "deny";
      try {
        verdict = execFileSync(process.execPath, [evalCli, corpus, provider, purpose], { encoding: "utf8" }).split("\t")[0];
      } catch { /* evaluator failure fails closed */ }
      if (verdict !== "allow" && verdict !== "allow+log")
        refusals.push(`collection "${col}" (corpus ${corpus}) is ${verdict} for ${provider} ${purpose} (models.${role})`);
    }
  }
}

// A collection whose path overlaps a PHI root is PHI whatever it is called.
const pathRefusals = [];
if (remoteRoles > 0) {
  const roots = [];
  const cfgDir = process.env.CLAUDE_GLM_CONFIG_DIR || join(homedir(), ".config", "claude-glm");
  for (const name of ["phi-roots", "egress-denylist"]) {
    const f = join(cfgDir, name);
    if (!existsSync(f)) continue;
    try {
      accessSync(f, constants.R_OK);
      for (let l of readFileSync(f, "utf8").split("\n")) {
        l = l.replace(/\r$/, "").trim();
        if (l && !l.startsWith("#")) roots.push(l.replace(/[\\/]+$/, "") || sep);
      }
    } catch { pathRefusals.push(`cannot read the PHI root list ${f}`); }
  }
  const sibDir = process.env.QMD_CONFIG_DIR || join(homedir(), ".config", "qmd");
  try {
    for (const f of readdirSync(sibDir).filter((x) => x.endsWith(".yml"))) {
      const full = join(sibDir, f);
      if (resolve(full) === resolve(cfgPath)) continue;
      try {
        for (const [name, p] of Object.entries(collectionPaths(readFileSync(full, "utf8"))))
          if ((map[name] ?? []).includes("salus")) roots.push(p);
      } catch { pathRefusals.push(`cannot read the sibling index config ${full}`); }
    }
  } catch { /* no sibling directory: nothing to learn from it */ }
  const rootForms = roots.flatMap(forms);
  const own = collectionPaths(text);
  for (const col of cfgCollections) {
    const p = own[col];
    if (!p) { pathRefusals.push(`collection "${col}" has no path to check against the PHI roots`); continue; }
    let d = resolve(expand(p));
    let marked = false;
    for (let prev = ""; d !== prev; prev = d, d = dirname(d)) if (existsSync(join(d, ".salus"))) { marked = true; break; }
    if (marked) pathRefusals.push(`collection "${col}" path ${p} is inside a .salus vault`);
    else if (forms(p).some((a) => rootForms.some((b) => overlaps(a, b)))) pathRefusals.push(`collection "${col}" path ${p} overlaps a PHI root (salus)`);
  }
}
refusals.push(...pathRefusals);

// Fail closed on a layout this reader does not understand: an `openai:` URI it
// did not attribute to a role, an unreadable collections/models block, or a
// remote role with no collection list to check.
const fileRemote = (text.replace(/#.*$/gm, "").match(/openai:/g) ?? []).length;
const fileRoleRemote = Object.keys(PURPOSE).filter((r) => !isLocalModel(models[r] ?? "")).length;
if (fileRemote > fileRoleRemote) refusals.push(`${fileRemote - fileRoleRemote} "openai:" model URI(s) in the config are not under models.embed/rerank/generate in a supported layout`);
if (remoteRoles > 0 && models.openai_api_key) refusals.push("models.openai_api_key is set in the config: the provider key belongs only in the launching shell's environment (QMD_OPENAI_API_KEY)");
if (remoteRoles > 0) for (const p of dbProblems) refusals.push(p);
for (const u of modelsUnreadable) refusals.push(`unsupported config layout: ${u}`);
if (remoteRoles > 0) {
  for (const u of unsupported) refusals.push(`unsupported config layout: ${u}`);
  if (collections.length === 0) refusals.push("a remote model is configured but no collections could be read to check");
}

if (refusals.length) {
  process.stderr.write(`qmd-jina-gate: REFUSED ${cfgPath}\n`);
  for (const r of refusals) process.stderr.write(`  - ${r}\n`);
  process.stderr.write("  Keep a denied collection (salus) in its own index on local models: qmd --index salus (docs/internals/egress-matrix.md).\n");
  process.exit(3);
}
process.stdout.write(`qmd-jina-gate: OK ${cfgPath}\n`);
