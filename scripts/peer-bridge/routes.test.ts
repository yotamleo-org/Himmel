import { expect, test } from "bun:test";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { stateDir } from "./ids";

const REPO = join(import.meta.dir, "..", "..");

function walk(dir: string, out: string[] = []): string[] {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === "dist") continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const GATE_FILES = ["scripts/handover/merge-on-green.sh", "scripts/check-ci.sh", "scripts/lib/check-ci-watch.sh"];
const gateFiles = (root: string): string[] => [
  ...GATE_FILES.map(f => join(root, f)),
  ...walk(join(root, "scripts/jira/src")),
  ...fs.readdirSync(join(root, "scripts/ci")).filter(n => n.endsWith(".sh")).map(n => join(root, "scripts/ci", n)),
];

const NAMES_BRIDGE = /scripts\/peer-bridge|\.\.?\/peer-bridge|peer-bridge\/|\.himmel\/peer-bridge/;
const offenders = (files: string[]): string[] => files.filter(f => NAMES_BRIDGE.test(fs.readFileSync(f, "utf8")));

test("no merge, check or Jira script names or imports scripts/peer-bridge/", () => {
  const files = gateFiles(REPO);
  expect(files.length).toBeGreaterThan(100);
  for (const f of GATE_FILES) expect(fs.existsSync(join(REPO, f))).toBe(true);
  expect(offenders(files).map(f => relative(REPO, f))).toEqual([]);
});

test("RED control: the same check fails over a merge script with a peer-bridge reference planted", () => {
  const root = fs.mkdtempSync(join(tmpdir(), "peer-routes-"));
  try {
    for (const f of GATE_FILES) { fs.mkdirSync(join(root, f, ".."), { recursive: true }); fs.copyFileSync(join(REPO, f), join(root, f)); }
    fs.mkdirSync(join(root, "scripts/jira/src"), { recursive: true });
    fs.mkdirSync(join(root, "scripts/ci"), { recursive: true });
    expect(offenders(gateFiles(root))).toEqual([]);
    fs.appendFileSync(join(root, "scripts/handover/merge-on-green.sh"), "\nbun scripts/peer-bridge/jobs.ts show J1\n");
    expect(offenders(gateFiles(root)).map(f => relative(root, f))).toEqual(["scripts/handover/merge-on-green.sh"]);
    fs.writeFileSync(join(root, "scripts/jira/src/x.ts"), 'import "../../peer-bridge/resolve";\n');
    fs.writeFileSync(join(root, "scripts/ci/x.sh"), "cat ~/.himmel/peer-bridge/example/jobs.jsonl\n");
    expect(offenders(gateFiles(root)).map(f => relative(root, f)).sort()).toEqual(["scripts/ci/x.sh", "scripts/handover/merge-on-green.sh", "scripts/jira/src/x.ts"]);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

const INDEX_CONFIGS = ["scripts/qmd/qmd-collection-corpus.json", "scripts/luna/luna-index-hygiene.sh", ".graphifyignore"];

test("no qmd, graphify or luna-hygiene config root contains the peer bridge's state directory", () => {
  for (const f of INDEX_CONFIGS) {
    const text = fs.readFileSync(join(REPO, f), "utf8");
    expect([f, /peer-bridge/.test(text)]).toEqual([f, false]);
  }
  expect(stateDir().endsWith(join(".himmel", "peer-bridge"))).toBe(true);
  expect(relative(REPO, stateDir()).startsWith("..")).toBe(true);
});

test("RED control: a config that lists the state directory fails the same check", () => {
  const dir = fs.mkdtempSync(join(tmpdir(), "peer-routes-cfg-"));
  try {
    const cfg = join(dir, "qmd-collection-corpus.json");
    fs.writeFileSync(cfg, JSON.stringify({ "peer-state": `${stateDir()}/example` }));
    expect(/peer-bridge/.test(fs.readFileSync(cfg, "utf8"))).toBe(true);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("no script outside scripts/peer-bridge imports a peer-bridge module", () => {
  const importers = walk(join(REPO, "scripts"))
    .filter(f => /\.(ts|mjs|js)$/.test(f) && !f.includes(`${join("scripts", "peer-bridge")}/`) && !f.includes("/node_modules/"))
    .filter(f => /from\s+["'][^"']*peer-bridge\//.test(fs.readFileSync(f, "utf8")))
    .map(f => relative(REPO, f));
  expect(importers).toEqual([]);
});
