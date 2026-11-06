// nav.test.ts and slow.test.ts run app.js with its import lines stripped, against hand-written stubs. A name app.js imports
// that those stubs lack is a free global: the first route that calls it throws, or hangs the row. Each harness
// keeps one APP_IMPORT_STUBS block; this reads app.js's imports and fails, naming each import a block lacks.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const read = (rel: string) => readFileSync(join(import.meta.dir, rel), "utf8");

// The local binding of every named import at the top of app.js (`renderConfigure as render` binds `render`).
function importedNames(appSrc: string): string[] {
  const names: string[] = [];
  for (const m of appSrc.matchAll(/^import\s*\{([^}]*)\}\s*from\s*["'][^"']+["'];?\s*$/gm)) {
    for (const part of m[1].split(",")) {
      const p = part.trim();
      if (p) names.push(p.split(/\s+as\s+/).pop()!.trim());
    }
  }
  return names;
}

// The keys of the `const APP_IMPORT_STUBS = { ... };` block (a plain object of arrow functions), or null when it is absent.
function stubbedNames(harnessSrc: string): string[] | null {
  const start = harnessSrc.search(/^const APP_IMPORT_STUBS\b/m);
  if (start < 0) return null;
  const open = harnessSrc.indexOf("= {", start) + 2;
  const end = harnessSrc.indexOf("\n};", open) + 2;
  return Object.keys(new Function(`return (${harnessSrc.slice(open, end)});`)());
}

const missingStubs = (appSrc: string, harnessSrc: string): string[] => {
  const have = new Set(stubbedNames(harnessSrc) ?? []);
  return importedNames(appSrc).filter((n) => !have.has(n));
};

test("the parser reads aliases and several import lines, and a missing name is reported by name", () => {
  const app = `// glue\nimport { a, b as c } from "/x.js";\nimport { d } from "/y.js";\nconst q = 1;\nimport { notAtTop } from "/z.js";\n`;
  expect(importedNames(app)).toEqual(["a", "c", "d", "notAtTop"]);
  const harness = `const APP_IMPORT_STUBS: Record<string, unknown> = {\n  a: () => "", c: () => "",\n  d: () => "",\n};\n`;
  expect(stubbedNames(harness)).toEqual(["a", "c", "d"]);
  expect(missingStubs(app, harness)).toEqual(["notAtTop"]);
  expect(stubbedNames("no block here")).toBeNull();
});

for (const file of ["nav.test.ts", "slow.test.ts"]) {
  test(`${file} stubs every name app.js imports`, () => {
    const harness = read(file);
    expect(stubbedNames(harness), `${file} has no APP_IMPORT_STUBS block`).not.toBeNull();
    expect(harness, `${file} must spread APP_IMPORT_STUBS into the globals it sets`).toContain("...APP_IMPORT_STUBS");
    const imports = importedNames(read("../public/app.js"));
    expect(imports.length, "no imports parsed from app.js").toBeGreaterThan(0);
    const missing = missingStubs(read("../public/app.js"), harness);
    expect(missing, `app.js imports with no stub in ${file}: ${missing.join(", ")}`).toEqual([]);
  });
}
