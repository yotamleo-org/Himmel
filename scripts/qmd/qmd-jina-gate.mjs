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
// Usage: node qmd-jina-gate.mjs <index.yml>
// Exit 0 allowed (also when no role is remote), 3 refused, 2 usage/unreadable.
// Environment overrides qmd itself honours are applied the same way:
// QMD_EMBED_MODEL, QMD_RERANK_MODEL, QMD_GENERATE_MODEL, QMD_OPENAI_BASE_URL.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const evalCli = join(here, "..", "guardrails", "egress-matrix-eval.mjs");
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
const collections = [];
const models = {};
const unsupported = [];
const modelsUnreadable = []; // a models line we cannot attribute may hide a remote role: refuse always
let section = "";
let childIndent = 0;
for (const line of text.split("\n")) {
  if (/^\s*(#.*)?$/.test(line)) continue;
  const inline = line.match(/^(collections|models):\s*([^#\s].*)$/);
  if (inline) { unsupported.push(`"${inline[1]}:" uses a flow/inline value`); section = ""; continue; }
  const top = line.match(/^([A-Za-z_][\w-]*):\s*(#.*)?$/);
  if (top) { section = top[1]; childIndent = 0; continue; }
  if (/^\S/.test(line)) { section = ""; continue; }
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
    else modelsUnreadable.push(`unparsed models entry: ${line.trim()}`);
  }
}

const baseUrl = process.env.QMD_OPENAI_BASE_URL || models.openai_base_url || "";
function providerOf() {
  if (!baseUrl) return "openai-unconfigured"; // cannot be proven local
  let url;
  try { url = new URL(baseUrl); } catch { return "openai-unparseable"; }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (["localhost", "127.0.0.1", "::1"].includes(host)) return null; // on-machine server
  if (url.protocol !== "https:") return `${host}-insecure-${url.protocol.replace(":", "")}`; // never matches an allow row
  if (host === "jina.ai" || host.endsWith(".jina.ai")) return "jina";
  return host;
}

// A role is local only when its value is plainly a local GGUF (hf: URI, a path,
// or *.gguf) with no YAML escape; anything else, an escaped "openai\x3a..."
// included, is treated as remote and checked.
const isLocalModel = (u) =>
  u === "" || (!u.includes("\\") && (/^hf:/.test(u) || /^(\/|~\/|\.\/)/.test(u) || (/\.gguf$/i.test(u) && !/^[A-Za-z][\w+.-]*:/.test(u))));

const refusals = [];
let remoteRoles = 0;
for (const [role, purpose] of Object.entries(PURPOSE)) {
  const uri = process.env[ENV_ROLE[role]] || models[role] || "";
  if (isLocalModel(uri)) continue;
  remoteRoles++;
  const provider = providerOf();
  if (provider === null) continue;
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

// Fail closed on a layout this reader does not understand: an `openai:` URI it
// did not attribute to a role, an unreadable collections/models block, or a
// remote role with no collection list to check.
const fileRemote = (text.replace(/#.*$/gm, "").match(/openai:/g) ?? []).length;
const fileRoleRemote = Object.keys(PURPOSE).filter((r) => !isLocalModel(models[r] ?? "")).length;
if (fileRemote > fileRoleRemote) refusals.push(`${fileRemote - fileRoleRemote} "openai:" model URI(s) in the config are not under models.embed/rerank/generate in a supported layout`);
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
