#!/usr/bin/env node
// config-preflight.mjs <binding.json> -- the N2-r secret-free runtime configuration preflight.
//
// Runs in the exact nonsecret environment the qmd child will get (before any key is injected)
// and uses the PINNED qmd config loader (dist/collections.js), never a substitute parser, with
// the same index selection as the child (fixed QMD_CONFIG_DIR + explicit --index eval). It
// opens no database, constructs no model and makes no network call. It refuses (exit 3, one
// line on stderr) a missing/empty/non-regular config, a credential field, an unknown field, a
// byte-hash or sha256(JSON.stringify(loadConfig())) mismatch against the sealed config_hash, a
// model triple or endpoint that is not the locked treatment, a model/config/key override in
// the environment, and for Q any remote endpoint, openai: model or truthy CI.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { join } from "node:path";

const fail = (why) => { process.stderr.write(`config-preflight: refused: ${why}\n`); process.exit(3); };
const sha = (b) => createHash("sha256").update(b).digest("hex");
const CRED = /(api_?key|token|secret|password|bearer)/i;
const TOP = new Set(["collections", "global_context", "models"]);
const MODELS = new Set(["embed", "generate", "rerank", "openai_base_url"]);
const OVERRIDES = ["QMD_EMBED_MODEL", "QMD_GENERATE_MODEL", "QMD_RERANK_MODEL", "QMD_OPENAI_BASE_URL", "QMD_OPENAI_API_KEY",
  "QMD_OPENAI_PROVIDER", "JINA_API_KEY", "JINA_API", "XDG_CONFIG_HOME"];

let b;
try { b = JSON.parse(readFileSync(process.argv[2], "utf8")); } catch (e) { fail(`binding unreadable: ${e.message}`); }
if (b.arm !== "S" && b.arm !== "Q") fail(`unknown arm ${b.arm}`);
if (process.env.QMD_CONFIG_DIR !== b.config_dir) fail("QMD_CONFIG_DIR is not the locked config dir");
for (const k of OVERRIDES) if (process.env[k] !== undefined) fail(`environment override ${k} is set`);
const allowed = new Set(["PATH", "HOME", "LANG", "QMD_CONFIG_DIR", "INDEX_PATH", "XDG_CACHE_HOME", ...Object.keys(b.env || {})]);
for (const k of Object.keys(process.env)) if (!allowed.has(k)) fail(`unexpected environment variable ${k}`);
for (const [k, v] of Object.entries(b.env || {})) if (process.env[k] !== String(v)) fail(`locked environment ${k} differs`);
if (b.arm === "Q" && process.env.CI && !["0", "false"].includes(process.env.CI.toLowerCase())) fail("CI mode reaches the Q child");

const path = join(b.config_dir, "eval.yml");
let st;
try { st = lstatSync(path); } catch { fail(`no config at ${path}`); }
if (!st.isFile()) fail(`config is not a regular file: ${path}`);
const bytes = readFileSync(path);
if (!bytes.toString("utf8").trim()) fail("config is empty");
if (sha(bytes) !== b.config_sha256) fail("config bytes differ from the lock");

const c = await import(join(b.qmd_dist, "collections.js"));
c.setConfigIndexName("eval");
c.setConfigSource();
let cfg;
try { cfg = c.loadConfig(); } catch (e) { fail(`pinned loader: ${e.message}`); }
const walk = (v, where) => {
  if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) {
    if (CRED.test(k)) fail(`credential field ${where}.${k}`);
    walk(x, `${where}.${k}`);
  }
};
walk(cfg, "config");
for (const k of Object.keys(cfg)) if (!TOP.has(k)) fail(`unknown config field ${k}`);
const m = cfg.models || {};
for (const k of Object.keys(m)) if (!MODELS.has(k)) fail(`unknown models field ${k}`);
for (const role of ["embed", "generate", "rerank"]) {
  if (!m[role]) fail(`models.${role} missing: qmd would fall back to a default`);
  if (m[role] !== b.models[role]) fail(`models.${role} is not the locked treatment`);
}
if (!Object.keys(cfg.collections || {}).length) fail("no collections");
for (const [name, root] of Object.entries(b.collections || {})) {
  if ((cfg.collections[name] || {}).path !== root) fail(`collection ${name} path is not the locked root`);
}
if (b.arm === "S") {
  if (m.openai_base_url !== b.base_url) fail("S endpoint is not the locked base URL");
} else {
  if (m.openai_base_url) fail("Q config names a remote endpoint");
  for (const role of ["embed", "generate", "rerank"]) if (String(m[role]).startsWith("openai:")) fail(`Q ${role} is a remote model`);
}
const hash = sha(JSON.stringify(cfg));
if (hash !== b.config_hash) fail("config hash differs from the sealed store_config.config_hash");
process.stdout.write(JSON.stringify({ ok: true, config_hash: hash }) + "\n");
