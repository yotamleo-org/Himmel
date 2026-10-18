#!/usr/bin/env node
// repo-security-scan.mjs — advisory, read-only scan of a GitHub repo's
// fetched content. Flags prompt injection in README / docs /
// skill+command markdown, install scripts, obfuscated payloads, exfiltration
// in setup scripts and suspicious dependencies.
//
// Advisory only: it reads text through `gh api`, never clones, never runs an
// install script, never rejects a repo. Findings carry a fixed `kind` +
// `detail` vocabulary and a sanitized path — never a snippet of the scanned
// text — so a finding can sit in a dossier / note without carrying the
// attacker's payload into a judge prompt.
//
// Usage: node repo-security-scan.mjs <owner>/<repo>      (prints JSON, exit 0)
//   Exit codes: 0 — scan ran (flagged or not); 1 — bad usage.
//   REPO_SCAN_GH_FIXTURE (file path or inline JSON keyed by `args.join(" ")`)
//   swaps `gh` for a hermetic fixture, mirroring FOLLOW_GH_FIXTURE.
//
// The prompt-injection patterns are NOT duplicated here: the default scanFn
// shells out to harvest-clip-body-batch.py --scan-only, the single source of
// truth (INJECTION_PATTERNS), and returns its matched class names.

import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const SCREENER = join(TOOLS_DIR, "harvest-clip-body-batch.py");

const MAX_FILES = 12;
const MAX_FILE_BYTES = 200 * 1024;
const MAX_LINE = 4000; // per-line cap keeps every regex below linear on bounded input
const SAFE_PATH_RE = /^[A-Za-z0-9_.@+\/-]{1,120}$/;
const REPO_RE = /^[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*$/;

/**
 * Real scanFn: runs harvest-clip-body-batch.py --scan-only over `tmpFile` and
 * returns the matched pattern-class names ([] = clean). Throws on spawn
 * failure or an unexpected exit so the caller fails closed.
 */
export function defaultScanFn(tmpFile) {
  const args = [process.env.FOLLOW_SCREENER || SCREENER, "--scan-only", tmpFile];
  const opts = { encoding: "utf-8", timeout: 20000, windowsHide: true };
  let res = spawnSync("python", args, opts);
  if (res.error && res.error.code === "ENOENT") res = spawnSync("python3", args, opts);
  if (res.error) throw new Error(`repo-security-scan: spawn failed: ${res.error.message}`);
  if (res.status === 0) return [];
  if (res.status === 1) return res.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
  throw new Error(`repo-security-scan: scanner exited ${res.status}`);
}

const INSTALL_HOOKS = ["preinstall", "install", "postinstall", "prepare"];
const SHELL_RULES = [
  ["setup-exfil", "pipe-to-shell", /\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/i],
  ["setup-exfil", "posts-secrets",
    /\b(curl|wget)\b[^\n]*(\s-d\b|--data|--upload-file|\s-F\b|\s-T\b|--post)[^\n]*(\.ssh|\.aws|\.env\b|\/etc\/passwd|\$\{?[A-Z_]*(TOKEN|SECRET|KEY|PASSWORD)\b)/i],
  ["setup-exfil", "posts-secrets", /\b(env|printenv)\b[^\n]*\|\s*(curl|wget|nc)\b/i],
  ["obfuscated-payload", "base64-exec", /\bbase64\s+(-d|--decode)\b[^\n]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/i],
  ["obfuscated-payload", "eval-decode", /\beval\s*\(\s*(atob|Buffer\.from|String\.fromCharCode)\b/i],
  ["obfuscated-payload", "powershell-encoded", /\bpowershell\b[^\n]*\s-e(nc|ncodedcommand)?\s/i],
  ["obfuscated-payload", "hex-escapes", /(\\x[0-9a-f]{2}){8,}/i],
  ["obfuscated-payload", "long-base64-blob", /[A-Za-z0-9+/]{200,}={0,2}/],
];
const SUSPICIOUS_DEP_RE = /^(git\+|git:|git@|https?:|github:|file:|ssh:)|^[\w.-]+\/[\w.-]+(#.*)?$/i;

function matchShellRules(text, path, findings) {
  const seen = new Set();
  for (const raw of String(text).split("\n")) {
    const line = raw.slice(0, MAX_LINE);
    for (const [kind, detail, re] of SHELL_RULES) {
      const key = `${kind}:${detail}`;
      if (!seen.has(key) && re.test(line)) {
        seen.add(key);
        findings.push({ kind, detail, path });
      }
    }
  }
}

function scanPackageJson(text, path, findings) {
  let pkg;
  try {
    pkg = JSON.parse(text);
  } catch {
    return;
  }
  const scripts = pkg && typeof pkg.scripts === "object" && pkg.scripts ? pkg.scripts : {};
  for (const hook of INSTALL_HOOKS) {
    if (typeof scripts[hook] === "string") {
      findings.push({ kind: "install-script", detail: hook, path });
      matchShellRules(scripts[hook], path, findings);
    }
  }
  for (const section of ["dependencies", "optionalDependencies", "devDependencies"]) {
    const deps = pkg && typeof pkg[section] === "object" && pkg[section] ? pkg[section] : {};
    for (const [name, spec] of Object.entries(deps)) {
      if (typeof spec === "string" && SUSPICIOUS_DEP_RE.test(spec)) {
        findings.push({ kind: "suspicious-dependency", detail: SAFE_PATH_RE.test(name) ? name : "[odd-name]", path });
      }
    }
  }
}

function safePath(path) {
  return SAFE_PATH_RE.test(path) ? path : "[odd-path]";
}

function injectionClasses(text, scanFn) {
  const tmp = join(tmpdir(), `repo-scan-${randomUUID()}.txt`);
  try {
    writeFileSync(tmp, text, "utf8");
    return scanFn(tmp) || [];
  } finally {
    try {
      unlinkSync(tmp);
    } catch {
      // best-effort cleanup only
    }
  }
}

/**
 * Pure scan of already-fetched `files` ([{path, text}]). Markdown goes through
 * `scanFn(tmpFile) -> string[]` (injection class names); package.json and
 * shell-like setup files go through the install-script / payload / exfil /
 * dependency heuristics. A scanFn that throws yields a fail-closed
 * `prompt-injection:screen-error` finding. Returns {findings}.
 */
export function scanRepoFiles(files, { scanFn = defaultScanFn } = {}) {
  const findings = [];
  for (const f of files) {
    const path = safePath(f.path);
    const base = f.path.split("/").pop();
    if (/\.(md|markdown|mdx)$/i.test(base)) {
      try {
        for (const cls of injectionClasses(f.text, scanFn)) {
          findings.push({ kind: "prompt-injection", detail: cls, path });
        }
      } catch {
        findings.push({ kind: "prompt-injection", detail: "screen-error", path });
      }
    } else if (base === "package.json") {
      scanPackageJson(f.text, path, findings);
    } else {
      matchShellRules(f.text, path, findings);
    }
  }
  return { findings };
}

function decode(blob) {
  if (!blob || typeof blob.content !== "string") throw new Error("no content");
  if (blob.encoding && blob.encoding !== "base64") throw new Error("unsupported encoding");
  return Buffer.from(blob.content, "base64").toString("utf8");
}

const ROOT_FILE_RE = /^(package\.json|(install|setup|bootstrap)(\.sh)?|[A-Za-z0-9_-]+\.md)$/i;
const MD_DIRS = ["commands", ".claude/commands"];
const SKILL_DIRS = ["skills", ".claude/skills"];
// an absent command/skill dir is normal; any other listing failure leaves content unscanned
const MISSING_RE = /404|not found|no [A-Z_]*FIXTURE entry/i;

// ponytail: root docs + one level of command/skill dirs only (<=12 files, 200 KB each), not a full tree walk — upgrade path: ghFn tree API when a real miss shows up.
function listFiles(fullName, ghFn, errors) {
  const wanted = ["README.md"];
  const rootDocs = [];
  const tryList = (path) => {
    try {
      const r = ghFn(["api", `repos/${fullName}/contents${path ? "/" + path : ""}`]);
      return Array.isArray(r) ? r : [];
    } catch (e) {
      if (!path || !MISSING_RE.test(String(e && e.message))) errors.push(`listing:${path}`);
      return [];
    }
  };
  for (const e of tryList("")) {
    if (e.type !== "file" || !ROOT_FILE_RE.test(e.name) || e.name.toLowerCase() === "readme.md") continue;
    (/\.md$/i.test(e.name) ? rootDocs : wanted).push(e.name);
  }
  for (const dir of MD_DIRS) {
    for (const e of tryList(dir)) if (e.type === "file" && /\.md$/i.test(e.name)) wanted.push(`${dir}/${e.name}`);
  }
  for (const dir of SKILL_DIRS) {
    for (const e of tryList(dir).filter((x) => x.type === "dir").slice(0, 5)) wanted.push(`${dir}/${e.name}/SKILL.md`);
  }
  // root docs go last so the file cap never crowds out package.json, setup scripts, commands or skills
  return [...new Set([...wanted, ...rootDocs])].slice(0, MAX_FILES);
}

/**
 * Fetches a repo's scannable files through `ghFn` (read-only `gh api`) and
 * scans them. Returns {repo, status, scanned, findings, summary};
 * status ∈ ok | partial (some file unreadable) | fetch_error (nothing read).
 */
export function scanRepo(fullName, { ghFn, scanFn } = {}) {
  const base = { repo: fullName, scanned: [], findings: [] };
  if (!ghFn || !REPO_RE.test(fullName || "")) return { ...base, status: "fetch_error", summary: "scan unavailable" };
  const errors = [];
  const files = [];
  for (const path of listFiles(fullName, ghFn, errors)) {
    try {
      const url = path === "README.md" ? `repos/${fullName}/readme` : `repos/${fullName}/contents/${path}`;
      const blob = ghFn(["api", url]);
      if (typeof blob.size === "number" && blob.size > MAX_FILE_BYTES) throw new Error("too large");
      const text = decode(blob);
      if (Buffer.byteLength(text) > MAX_FILE_BYTES) throw new Error("too large");
      files.push({ path, text });
    } catch {
      errors.push(path);
    }
  }
  if (files.length === 0) return { ...base, status: "fetch_error", summary: "scan unavailable" };
  const { findings } = scanRepoFiles(files, scanFn ? { scanFn } : {});
  const scanned = files.map((f) => f.path);
  const summary = findings.length
    ? `flagged: ${[...new Set(findings.map((f) => `${f.kind}:${f.detail}`))].join(", ")}`
    : errors.length
      ? `incomplete: ${scanned.length} file(s) scanned, ${errors.length} unreadable`
      : `clean: ${scanned.length} file(s) scanned`;
  return { repo: fullName, status: errors.length ? "partial" : "ok", scanned, findings, summary };
}

function makeGhFn() {
  const raw = process.env.REPO_SCAN_GH_FIXTURE;
  if (raw) {
    const map = JSON.parse(existsSync(raw) ? readFileSync(raw, "utf8") : raw);
    return (args) => {
      const key = args.join(" ");
      if (!(key in map)) throw new Error(`no REPO_SCAN_GH_FIXTURE entry for "gh ${key}"`);
      return map[key];
    };
  }
  return (args) => {
    const res = spawnSync("gh", args, { encoding: "utf-8", windowsHide: true, timeout: 30000, maxBuffer: 10 * 1024 * 1024 });
    if (res.error) throw res.error;
    if (res.status !== 0) throw new Error(`gh exited ${res.status}: ${String(res.stderr || "").slice(0, 200)}`);
    return JSON.parse(res.stdout);
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const target = process.argv[2];
  if (!target || !REPO_RE.test(target)) {
    console.error("Usage: repo-security-scan.mjs <owner>/<repo>");
    process.exit(1);
  }
  console.log(JSON.stringify(scanRepo(target, { ghFn: makeGhFn() }), null, 2));
}
