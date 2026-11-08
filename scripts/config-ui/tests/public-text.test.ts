// The text a user reads says what a thing does. Decision numbers, ticket keys and worker labels stay in the internal
// notes, so this reads every UI source with its comments dropped. The recorded replay agui-web/src/fixture.json is
// sample data, and not read here.
import { test, expect } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = join(import.meta.dir, "..");
const INTERNAL = /\b[Dd]ecisions?\s+#?\d{2,4}\b|\b\d{3}\s+default\b|\bHIMMEL-\d+\b|\bN\d{3,5}\b/g;

const loaderOf = (file: string) => (file.endsWith(".tsx") ? "tsx" : file.endsWith(".ts") ? "ts" : "js");
function internalRefs(file: string, source: string): string[] {
  const text = file.endsWith(".html") ? source.replace(/<!--[\s\S]*?-->/g, "") : new Bun.Transpiler({ loader: loaderOf(file) }).transformSync(source);
  return text.match(INTERNAL) ?? [];
}

const inDir = (dir: string, wanted: RegExp, recursive = true) =>
  readdirSync(join(ROOT, dir), { recursive, encoding: "utf8" }).filter((name) => wanted.test(name)).map((name) => join(ROOT, dir, name));
const uiSources = () => [
  ...inDir("public", /\.(js|html)$/),
  ...inDir("agui-web", /\.html$/, false),
  ...inDir("agui-web/src", /\.(ts|tsx)$/),
  ...inDir("agui", /\.ts$/),
  ...inDir(".", /\.ts$/, false),
];

test("the check catches a planted reference of each kind, in code and in HTML, and not in a comment", () => {
  const key = "HIMMEL" + "-1234";
  for (const planted of ["decision 525", "Decision 99", "525 default", key, "N5006"]) {
    expect(internalRefs("a.js", `export const t = \`<h3>${planted}</h3>\`;`)).toEqual([planted]);
    expect(internalRefs("a.tsx", `export const t = <h3>${planted}</h3>;`)).toEqual([planted]);
    expect(internalRefs("a.html", `<h3>${planted}</h3>`)).toEqual([planted]);
    expect(internalRefs("a.js", `// ${planted}\nexport const t = "plain";`)).toEqual([]);
    expect(internalRefs("a.html", `<!-- ${planted} --><h3>plain</h3>`)).toEqual([]);
  }
});

test("no UI source carries a decision number, ticket key or worker label", () => {
  const files = uiSources();
  expect(files).toContain(join(ROOT, "public/setup.js"));
  expect(files).toContain(join(ROOT, "server.ts"));
  const hits = files.flatMap((file) => internalRefs(file, readFileSync(file, "utf8")).map((ref) => `${relative(ROOT, file)}: ${ref}`));
  expect(hits).toEqual([]);
});

// The plugin menu shows the description fields of every marketplace.json and plugin.json, so they are read too.
// Test fixtures are not shown to a user and are left out.
const REPO = join(ROOT, "../..");
// Files another open PR holds, each named with the day it was allowed. Drop the entry when that PR merges.
const HELD: Record<string, string> = {
  "marketplace/plugins/himmel-ops/.claude-plugin/plugin.json": "PR 4905 rewrites this description, allowed 2026-11-07",
  "templates/luna-second-brain/marketplace/.claude-plugin/marketplace.json": "PR 4859 holds this file, allowed 2026-11-07",
};

function descriptionRefs(source: string): string[] {
  const refs: string[] = [];
  const walk = (node: unknown): void => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (node === null || typeof node !== "object") return;
    for (const [key, value] of Object.entries(node)) {
      if (key === "description" && typeof value === "string") refs.push(...(value.match(INTERNAL) ?? []));
      else walk(value);
    }
  };
  walk(JSON.parse(source));
  return refs;
}

const manifests = () =>
  new TextDecoder()
    .decode(Bun.spawnSync(["git", "ls-files", "-z", "--", "*.claude-plugin/marketplace.json", "*.claude-plugin/plugin.json"], { cwd: REPO }).stdout)
    .split("\0")
    .filter((path) => path !== "" && !path.includes("/fixtures/"));

test("the check catches a planted reference of each kind in a marketplace entry, the marketplace metadata and a plugin manifest", () => {
  const key = "HIMMEL" + "-1234";
  for (const planted of ["decision 525", "Decision 99", "525 default", key, "N5006"]) {
    const marketplace = { name: "m", metadata: { description: `A marketplace (${planted}).` }, plugins: [{ name: "p", description: `Does a thing (${planted}).` }] };
    expect(descriptionRefs(JSON.stringify(marketplace))).toEqual([planted, planted]);
    expect(descriptionRefs(JSON.stringify({ name: "p", version: "1.0.0", description: `Does a thing (${planted}).` }))).toEqual([planted]);
    expect(descriptionRefs(JSON.stringify({ name: "p", source: { ref: planted }, description: "Does a thing." }))).toEqual([]);
  }
});

test("no plugin or marketplace description carries a decision number, ticket key or worker label", () => {
  const files = manifests();
  expect(files).toContain("marketplace/.claude-plugin/marketplace.json");
  expect(files).toContain("marketplace/plugins/qmd/.claude-plugin/plugin.json");
  for (const held of Object.keys(HELD)) expect(files).toContain(held);
  const hits = files
    .filter((file) => !(file in HELD))
    .flatMap((file) => descriptionRefs(readFileSync(join(REPO, file), "utf8")).map((ref) => `${file}: ${ref}`));
  expect(hits).toEqual([]);
});
