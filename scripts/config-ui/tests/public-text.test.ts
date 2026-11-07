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
