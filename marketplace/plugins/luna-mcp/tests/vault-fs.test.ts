import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { rename, rm, symlink } from "node:fs/promises";
import { join } from "node:path";
import { describe, it } from "node:test";
import { Denied, type DenyKind, type PolicyScope } from "../src/paths.js";
import { buildSnippet, listDir, loadRoots, parseQmdConfigRoots, readDoc, recentDocs, titleOf } from "../src/vault-fs.js";
import { buildFixture, PHI, put, scratch, LEAK } from "./helpers.js";

const reader: PolicyScope = { vault: true, roles: ["reader"], allowHandoversRead: false };
const manager: PolicyScope = { vault: true, roles: ["reader", "manager"], allowHandoversRead: false };

async function kindOf(fn: () => Promise<unknown>): Promise<DenyKind> {
  try {
    await fn();
  } catch (e) {
    assert.ok(e instanceof Denied, String(e));
    return e.kind;
  }
  assert.fail("expected a Denied error");
}

describe("parseQmdConfigRoots", () => {
  const yaml = [
    "global_context: ignored",
    "collections:",
    "  luna:",
    '    path: "~/vault/luna"',
    '    pattern: "**/*.md"',
    "    ignore:",
    '      - "sessions/**"',
    "  himmel:",
    "    path: /srv/checkouts/himmel",
    "    pattern: '**/*.md'",
    "  jira-himmel:",
    "    path: '/srv/mirror/jira'",
    "other:",
    "  luna:",
    "    path: /never",
    "",
  ].join("\n");

  it("reads the path of every collection and expands a leading tilde", () => {
    const roots = parseQmdConfigRoots(yaml, "/srv/example-home");
    assert.deepEqual([...roots.entries()], [
      ["luna", "/srv/example-home/vault/luna"],
      ["himmel", "/srv/checkouts/himmel"],
      ["jira-himmel", "/srv/mirror/jira"],
    ]);
  });

  it("refuses a duplicate collection, a missing path, a relative path and a tab", () => {
    assert.throws(() => parseQmdConfigRoots("collections:\n  a:\n    path: /x\n  a:\n    path: /y\n", "/h"), /defined twice/);
    assert.throws(() => parseQmdConfigRoots("collections:\n  a:\n    pattern: x\n", "/h"), /no path/);
    assert.throws(() => parseQmdConfigRoots("collections:\n  a:\n    path: relative/dir\n", "/h"), /not absolute/);
    assert.throws(() => parseQmdConfigRoots("collections:\n\ta:\n    path: /x\n", "/h"), /tab/);
  });
});

describe("loadRoots", () => {
  it("reads QMD_CONFIG_FILE, or an explicit collection-to-root map that wins over it", async (t) => {
    const dir = await scratch(t);
    const yamlFile = join(dir, "index.yml");
    await put(dir, "index.yml", "collections:\n  luna:\n    path: /srv/a\n");
    assert.deepEqual([...(await loadRoots({ QMD_CONFIG_FILE: yamlFile })).entries()], [["luna", "/srv/a"]]);
    const mapFile = join(dir, "roots.json");
    await put(dir, "roots.json", JSON.stringify({ luna: "/srv/b", himmel: "/srv/c" }));
    const both = await loadRoots({ QMD_CONFIG_FILE: yamlFile, LUNA_MCP_COLLECTION_ROOTS: mapFile });
    assert.deepEqual([...both.entries()], [["luna", "/srv/b"], ["himmel", "/srv/c"]]);
  });

  it("defaults to the QMD config under XDG_CONFIG_HOME and fails when nothing is readable", async (t) => {
    const dir = await scratch(t);
    await put(dir, "qmd/index.yml", "collections:\n  luna:\n    path: /srv/a\n");
    assert.equal((await loadRoots({ XDG_CONFIG_HOME: dir })).get("luna"), "/srv/a");
    await assert.rejects(loadRoots({ XDG_CONFIG_HOME: join(dir, "absent") }));
    await put(dir, "bad.json", JSON.stringify({ luna: 5 }));
    await assert.rejects(loadRoots({ LUNA_MCP_COLLECTION_ROOTS: join(dir, "bad.json") }));
  });
});

describe("readDoc", () => {
  it("returns collection, path, content, sha256, size and an ISO mtime", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const doc = await readDoc(root, "luna", "30-Resources/note one.md", reader);
    assert.equal(doc.collection, "luna");
    assert.equal(doc.path, "30-Resources/note one.md");
    assert.match(doc.content, /needle in spaced note/);
    assert.equal(doc.sha256, createHash("sha256").update(doc.content).digest("hex"));
    assert.equal(doc.size, Buffer.byteLength(doc.content));
    assert.match(doc.mtime, /^\d{4}-\d\d-\d\dT/);
  });

  it("reads CLAUDE.md, _Templates and docs for a reader", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    for (const p of ["CLAUDE.md", "_Templates/note.md", "docs/guide.md", "docs/deep/nested.md"]) {
      assert.ok((await readDoc(root, "luna", p, reader)).content.length > 0, p);
    }
  });

  const dotAndKernel = [
    ".pre-commit-config.yaml",
    ".gitignore",
    ".gitleaks.toml",
    ".git/config",
    ".env",
    ".npmrc",
    ".obsidian/plugins/x",
    "30-Resources/sub/.claude/x.md",
    "30-Resources/sub/.config/x.md",
    "60-Maps/.obsidian/x.md",
    "scripts/vault-autosync.sh",
    "sessions/2026/07/2026-07-15-0821-salus-master.md",
    "chats/c1.md",
    "handovers/h1.md",
    "../",
    "../outside/secret.md",
    "%2e%2e/outside/secret.md",
    "%2e/%2f",
    "30-Resources/%2eclaude/x.md",
    "e\u0301.md",
    "a\u200bb.md",
    "a\u0007b.md",
    "alias-sessions/2026/07/2026-07-15-0821-salus-master.md",
    "link-out.md",
    "linkdir/secret.md",
  ];
  for (const p of dotAndKernel) {
    it(`refuses ${JSON.stringify(p)} and returns no content`, async (t) => {
      const fx = await buildFixture(t);
      const kind = await kindOf(() => readDoc(fx.roots.get("luna")!, "luna", p, reader));
      assert.notEqual(kind, "not-found", `${p} must be refused by policy, not by absence`);
    });
  }

  it("refuses a repo: salus note and reports a missing note as not-found", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOf(() => readDoc(root, "luna", "30-Resources/salus-note.md", reader)), "salus");
    assert.equal(await kindOf(() => readDoc(root, "luna", "30-Resources/missing.md", reader)), "not-found");
  });

  it("lets a manager scope read sessions but never dot-segments", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.match((await readDoc(root, "luna", "sessions/2026/07/2026-07-15-0821-salus-master.md", manager)).content, new RegExp(PHI));
    assert.equal(await kindOf(() => readDoc(root, "luna", ".env", manager)), "dot-segment");
  });

  it("does not apply the vault kernel to a non-vault collection", async (t) => {
    const fx = await buildFixture(t);
    const doc = await readDoc(fx.roots.get("himmel")!, "himmel", "scripts/foo.md", { vault: false, roles: ["reader"], allowHandoversRead: false });
    assert.match(doc.content, /Scripts doc/);
  });
});

describe("listDir", () => {
  it("lists the vault root without dot entries, kernel dirs, gated dirs, non-markdown files or salus notes", async (t) => {
    const fx = await buildFixture(t);
    const page = await listDir(fx.roots.get("luna")!, undefined, reader, { limit: 100 });
    const names = page.entries.map((e) => e.name);
    for (const keep of ["CLAUDE.md", "_Templates", "docs", "30-Resources", "60-Maps"]) assert.ok(names.includes(keep), keep);
    for (const gone of ["sessions", "chats", "handovers", "scripts", "marketplace", "graphify-out", "to_be_deleted", ".git", ".env", ".obsidian", "notes.txt", "link-out.md", "linkdir", "alias-sessions", "alias-plain.md", "prefix.md"]) {
      assert.ok(!names.includes(gone), gone);
    }
    assert.equal(page.dir, "");
    assert.equal(page.nextCursor, null);
    const resources = await listDir(fx.roots.get("luna")!, "30-Resources", reader, { limit: 100 });
    assert.ok(!resources.entries.some((e) => e.name === "salus-note.md" || e.name === "stale.md"));
    assert.ok(resources.entries.some((e) => e.name === "plain.md" && e.type === "file" && typeof e.size === "number" && typeof e.mtime === "string"));
  });

  it("paginates with a stable cursor and no repeats", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const seen: string[] = [];
    let cursor: string | undefined;
    let pages = 0;
    do {
      const page = await listDir(root, "30-Resources", reader, { limit: 2, ...(cursor ? { cursor } : {}) });
      assert.ok(page.entries.length <= 2);
      seen.push(...page.entries.map((e) => e.name));
      cursor = page.nextCursor ?? undefined;
      pages++;
    } while (cursor && pages < 10);
    const all = await listDir(root, "30-Resources", reader, { limit: 100 });
    assert.deepEqual(seen, all.entries.map((e) => e.name));
    assert.ok(pages > 1);
    assert.equal(new Set(seen).size, seen.length);
  });

  it("refuses to list gated, dot, escaping and missing directories", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOf(() => listDir(root, "sessions", reader, { limit: 10 })), "role-path");
    assert.equal(await kindOf(() => listDir(root, "sessions/2026", reader, { limit: 10 })), "role-path");
    assert.equal(await kindOf(() => listDir(root, ".obsidian", reader, { limit: 10 })), "dot-segment");
    assert.equal(await kindOf(() => listDir(root, "../outside", reader, { limit: 10 })), "dot-segment");
    assert.equal(await kindOf(() => listDir(root, "linkdir", reader, { limit: 10 })), "escape");
    assert.equal(await kindOf(() => listDir(root, "scripts", reader, { limit: 10 })), "kernel");
    assert.equal(await kindOf(() => listDir(root, "nope", reader, { limit: 10 })), "not-found");
    assert.equal(await kindOf(() => listDir(root, "CLAUDE.md", reader, { limit: 10 })), "not-found");
  });

  it("shows sessions to a manager scope and accepts a trailing slash", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const page = await listDir(root, "sessions/", manager, { limit: 10 });
    assert.deepEqual(page.entries.map((e) => e.name), ["2026"]);
  });
});

describe("recentDocs", () => {
  it("returns markdown notes newest first and excludes gated, dot, kernel, symlinked and salus files", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const base = Date.now() + 3600_000;
    await put(root, "30-Resources/newest.md", "# Newest\n", base + 3000);
    await put(root, "docs/newer.md", "# Newer\n", base + 2000);
    await put(root, "sessions/2026/new-session.md", "# Hot session\n", base + 9000);
    await put(root, "30-Resources/salus-newest.md", "---\nrepo: salus\n---\n# Hot salus\n", base + 9500);
    await put(root, "30-Resources/.hidden.md", "# hidden\n", base + 9600);
    const out = await recentDocs(root, reader, 3, 10_000);
    assert.deepEqual(out.docs.map((d) => d.path).slice(0, 2), ["30-Resources/newest.md", "docs/newer.md"]);
    assert.equal(out.docs.length, 3);
    assert.equal(out.docs[0]!.title, "Newest");
    assert.equal(out.truncated, false);
    const all = (await recentDocs(root, reader, 50, 10_000)).docs.map((d) => d.path);
    for (const p of all) {
      assert.ok(!/^(sessions|chats|handovers|scripts|marketplace)\//.test(p), p);
      assert.ok(!p.split("/").some((s) => s.startsWith(".")), p);
      assert.ok(!/salus/.test(p), p);
    }
    assert.ok(!all.includes("link-out.md") && !all.includes("alias-plain.md") && !all.includes("linkdir/secret.md"));
  });

  it("reports truncation when the walk budget is exhausted", async (t) => {
    const fx = await buildFixture(t);
    const out = await recentDocs(fx.roots.get("luna")!, reader, 50, 3);
    assert.equal(out.truncated, true);
  });

  it("lets a manager scope see sessions", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const all = (await recentDocs(root, manager, 50, 10_000)).docs.map((d) => d.path);
    assert.ok(all.some((p) => p.startsWith("sessions/")));
    assert.ok(!all.some((p) => p.startsWith(".")));
  });
});

describe("titleOf and buildSnippet", () => {
  it("takes the first heading, then frontmatter title, then the file stem", () => {
    assert.equal(titleOf("# Heading\nbody", "a.md"), "Heading");
    assert.equal(titleOf("---\ntitle: Front\n---\nno heading", "a.md"), "Front");
    assert.equal(titleOf("---\ntitle: Front\n---\n# Heading", "a.md"), "Heading");
    assert.equal(titleOf("plain text", "My Note.md"), "My Note");
  });

  it("builds a bounded snippet around the first matching term with its line number", () => {
    const text = `# T\n${"filler line\n".repeat(20)}the Needle is here\nafter\n`;
    const s = buildSnippet(text, ["needle"]);
    assert.match(s.snippet, /Needle is here/);
    assert.equal(s.line, 22);
    assert.ok(s.snippet.length <= 300);
  });

  it("falls back to the start of the body when no term matches, skipping frontmatter", () => {
    const s = buildSnippet("---\ntitle: x\n---\n# H\nfirst real line\n", ["zzz"]);
    assert.match(s.snippet, /first real line/);
    assert.ok(!s.snippet.includes("title: x"));
    assert.ok(buildSnippet(`# T\n${"x".repeat(2000)}\n`, ["x"]).snippet.length <= 300);
  });

  it("never returns the secret or PHI marker from a clean note", () => {
    const s = buildSnippet("# Clean\nordinary text\n", ["ordinary"]);
    assert.ok(!s.snippet.includes(LEAK) && !s.snippet.includes(PHI));
  });
});

describe("directory reads verified after they are opened", () => {
  async function swapDocsForOutside(base: string, root: string) {
    const outside = join(base, "swapped-dir");
    await put(outside, "deep/leak.md", `# Leaked\n${LEAK}\n`);
    let swapped = 0;
    const beforeOpen = async (abs: string) => {
      if (swapped === 0 && abs.endsWith(join("docs", "deep"))) {
        swapped++;
        await rename(join(root, "docs"), join(root, "docs.moved"));
        await symlink(outside, join(root, "docs"));
      }
    };
    return { beforeOpen, swapped: () => swapped };
  }

  it("denies a listing when an ancestor directory is swapped for an escaping symlink after the pre-check", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const hooks = await swapDocsForOutside(fx.base, root);
    assert.equal(await kindOf(() => listDir(root, "docs/deep", reader, { limit: 100 }, hooks)), "escape");
    assert.equal(hooks.swapped(), 1);
  });

  it("lists normally when nothing changes under it", async (t) => {
    const fx = await buildFixture(t);
    const page = await listDir(fx.roots.get("luna")!, "docs/deep", reader, { limit: 100 }, { beforeOpen: () => undefined });
    assert.deepEqual(page.entries.map((e) => e.name), ["nested.md"]);
  });

  it("returns nothing from outside the root when a directory is swapped during the recent walk", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const hooks = await swapDocsForOutside(fx.base, root);
    const out = await recentDocs(root, reader, 50, 10_000, hooks);
    assert.equal(hooks.swapped(), 1);
    for (const d of out.docs) assert.ok(!/leak/i.test(d.path) && !/Leaked/.test(d.title), d.path);
  });
});

describe("the listed directory is the verified handle", () => {
  async function swapAndRestore(base: string, root: string) {
    const outside = join(base, "swapped-dir");
    await put(outside, "deep/leak.md", `# Leaked\n${LEAK}\n`);
    let swaps = 0;
    const here = (abs: string): boolean => abs.endsWith(join("docs", "deep"));
    return {
      swaps: () => swaps,
      afterOpen: async (abs: string) => {
        if (!here(abs)) return;
        swaps++;
        await rename(join(root, "docs"), join(root, "docs.moved"));
        await symlink(outside, join(root, "docs"));
      },
      afterRead: async (abs: string) => {
        if (!here(abs)) return;
        await rm(join(root, "docs"));
        await rename(join(root, "docs.moved"), join(root, "docs"));
      },
    };
  }

  it("lists the opened directory when an ancestor is swapped during the read and put back before the check", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const hooks = await swapAndRestore(fx.base, root);
    const page = await listDir(root, "docs/deep", reader, { limit: 100 }, hooks);
    assert.equal(hooks.swaps(), 1);
    assert.deepEqual(page.entries.map((e) => e.name), ["nested.md"]);
  });

  it("walks the opened directories when one is swapped and put back during the recent walk", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const hooks = await swapAndRestore(fx.base, root);
    const out = await recentDocs(root, reader, 50, 10_000, hooks);
    assert.equal(hooks.swaps(), 1);
    assert.ok(out.docs.some((d) => d.path === "docs/deep/nested.md"));
    for (const d of out.docs) assert.ok(!/leak/i.test(d.path), d.path);
  });

  it("denies a listing whose handle path is reported outside the root", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOf(() => listDir(root, "docs", reader, { limit: 10 }, { fdPath: async () => fx.outside })), "escape");
  });

  it("denies a listing when the path of the handle cannot be resolved", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const fdPath = async (): Promise<string> => {
      throw new Error("no /proc here");
    };
    assert.equal(await kindOf(() => listDir(root, "docs", reader, { limit: 10 }, { fdPath })), "unverifiable");
  });
});
