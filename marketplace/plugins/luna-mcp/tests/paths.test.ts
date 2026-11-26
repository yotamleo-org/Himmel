import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  checkSegments,
  decodeQmdUri,
  Denied,
  hasSalusFrontmatter,
  isVaultCollection,
  parseRelPath,
  readVerified,
  resolveDir,
  SCAN_BYTES,
  type DenyKind,
  type PolicyScope,
} from "../src/paths.js";
import { buildFixture, PHI, put, salusNote, LEAK } from "./helpers.js";

const reader: PolicyScope = { vault: true, roles: ["reader"], allowHandoversRead: false };
const readerPlain: PolicyScope = { vault: false, roles: ["reader"], allowHandoversRead: false };

function kindOf(fn: () => unknown): DenyKind {
  try {
    fn();
  } catch (e) {
    assert.ok(e instanceof Denied, `expected Denied, got ${String(e)}`);
    return e.kind;
  }
  assert.fail("expected a Denied error");
}

async function kindOfAsync(fn: () => Promise<unknown>): Promise<DenyKind> {
  try {
    await fn();
  } catch (e) {
    assert.ok(e instanceof Denied, `expected Denied, got ${String(e)}`);
    return e.kind;
  }
  assert.fail("expected a Denied error");
}

describe("decodeQmdUri", () => {
  it("round-trips percent-encoded spaces and a literal percent", () => {
    assert.deepEqual(decodeQmdUri("qmd://luna/30-Resources/note%20one.md"), {
      collection: "luna",
      segments: ["30-Resources", "note one.md"],
    });
    assert.deepEqual(decodeQmdUri("qmd://luna/30-Resources/100%25%20real.md").segments, ["30-Resources", "100% real.md"]);
  });

  it("refuses encoded separators and NUL inside a segment", () => {
    for (const uri of ["qmd://luna/a%2fb.md", "qmd://luna/a%2Fb.md", "qmd://luna/a%5cb.md", "qmd://luna/a%5Cb.md", "qmd://luna/a%00b.md", "qmd://luna/%2e%2e%2fetc/x.md"]) {
      assert.equal(kindOf(() => decodeQmdUri(uri)), "bad-uri", uri);
    }
  });

  it("refuses encoded dot-segments", () => {
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna/%2e%2e/x.md")), "dot-segment");
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna/30-Resources/%2eclaude/x.md")), "dot-segment");
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna/%252e%252e/x.md")), "dot-segment");
  });

  it("refuses a malformed escape, a foreign scheme and a missing path", () => {
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna/50%zz.md")), "bad-uri");
    assert.equal(kindOf(() => decodeQmdUri("file:///etc/passwd")), "bad-uri");
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna")), "bad-uri");
    assert.equal(kindOf(() => decodeQmdUri("qmd://luna//x.md")), "bad-path");
  });
});

describe("parseRelPath", () => {
  const refused = [
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
    "../",
    "../outside/secret.md",
    "a/../b.md",
    "./x.md",
    "%2e%2e/x.md",
    "%2eclaude/x.md",
    "a/%2e/b.md",
  ];
  for (const raw of refused) {
    it(`refuses ${JSON.stringify(raw)}`, () => {
      const kind = kindOf(() => parseRelPath(raw));
      assert.ok(kind === "dot-segment" || kind === "bad-path", kind);
    });
  }

  it("refuses encoded separators, NUL and a leading or doubled slash", () => {
    for (const raw of ["a%2fb.md", "a%5cb.md", "a%00b.md", "/abs.md", "a//b.md", "a\\b.md", "a\u0000b.md"]) {
      assert.equal(kindOf(() => parseRelPath(raw)), "bad-path", raw);
    }
  });

  it("refuses non-NFC, control and zero-width characters", () => {
    for (const raw of ["é.md", "a\u0007b.md", "a​b.md", "a‮b.md", "a­b﻿.md", "a\u0085b.md"]) {
      assert.equal(kindOf(() => parseRelPath(raw)), "bad-path", JSON.stringify(raw));
    }
  });

  it("accepts spaces, a literal percent and ordinary note paths", () => {
    assert.deepEqual(parseRelPath("30-Resources/note one.md"), ["30-Resources", "note one.md"]);
    assert.deepEqual(parseRelPath("30-Resources/100% real.md"), ["30-Resources", "100% real.md"]);
    assert.deepEqual(parseRelPath("30-Resources/a%20b.md"), ["30-Resources", "a%20b.md"]);
    assert.deepEqual(parseRelPath("_Templates/note.md"), ["_Templates", "note.md"]);
    assert.deepEqual(parseRelPath("docs/guide.md"), ["docs", "guide.md"]);
  });
});

describe("checkSegments", () => {
  it("denies the vault executable and control directories for vault collections only", () => {
    for (const p of ["scripts/vault-autosync.sh", "marketplace/m.md", "graphify-out/g.md", "to_be_deleted/d.md", "Scripts/x.md"]) {
      assert.equal(kindOf(() => checkSegments(parseRelPath(p), reader)), "kernel", p);
    }
    assert.doesNotThrow(() => checkSegments(["scripts", "foo.md"], readerPlain));
    assert.doesNotThrow(() => checkSegments(["30-Resources", "scripts", "x.md"], reader));
  });

  it("denies sessions, chats and handovers to a reader, including case variants", () => {
    for (const p of ["sessions/2026/07/2026-07-15-0821-salus-master.md", "chats/c1.md", "handovers/h1.md", "Sessions/x.md", "CHATS/x.md", "Handovers/x.md"]) {
      assert.equal(kindOf(() => checkSegments(parseRelPath(p), reader)), "role-path", p);
    }
  });

  it("lets a manager into sessions and chats, and into handovers only with the read flag", () => {
    const manager: PolicyScope = { vault: true, roles: ["reader", "manager"], allowHandoversRead: false };
    assert.doesNotThrow(() => checkSegments(["sessions", "x.md"], manager));
    assert.doesNotThrow(() => checkSegments(["chats", "x.md"], manager));
    assert.equal(kindOf(() => checkSegments(["handovers", "h.md"], manager)), "role-path");
    assert.doesNotThrow(() => checkSegments(["handovers", "h.md"], { ...manager, allowHandoversRead: true }));
    assert.equal(kindOf(() => checkSegments(["handovers", "h.md"], { vault: true, roles: ["reader"], allowHandoversRead: true })), "role-path");
  });

  it("still denies dot-segments to a manager and to non-vault collections", () => {
    const manager: PolicyScope = { vault: true, roles: ["reader", "manager"], allowHandoversRead: true };
    assert.equal(kindOf(() => checkSegments([".git", "config"], manager)), "dot-segment");
    assert.equal(kindOf(() => checkSegments(["a", ".env"], readerPlain)), "dot-segment");
  });

  it("allows CLAUDE.md, _Templates and docs for a reader", () => {
    for (const p of ["CLAUDE.md", "_Templates/note.md", "docs/guide.md", "30-Resources/note one.md"]) {
      assert.doesNotThrow(() => checkSegments(parseRelPath(p), reader), p);
    }
  });
});

describe("isVaultCollection", () => {
  it("recognises luna collections by name and by mapped corpus", () => {
    assert.equal(isVaultCollection("luna", ["luna-personal", "luna-clippings"]), true);
    assert.equal(isVaultCollection("luna-pa", []), true);
    assert.equal(isVaultCollection("brain", ["luna-personal"]), true);
    assert.equal(isVaultCollection("brain", ["luna-clippings"]), true);
    assert.equal(isVaultCollection("himmel", ["himmel-code"]), false);
  });
});

describe("hasSalusFrontmatter", () => {
  it("detects repo: salus in its spellings", () => {
    const yes = [
      "---\nrepo: salus\n---\nbody",
      '---\nrepo: "Salus"\n---\nbody',
      "---\nrepo: 'salus'  # clinical\n---\nbody",
      "---\ntitle: x\nrepo: [himmel, salus]\n---\nbody",
      "---\nrepo:\n  - himmel\n  - salus\n---\nbody",
      "---\r\nrepo: salus\r\n---\r\nbody",
      "﻿---\nrepo: salus\n---\nbody",
      "---\nRepo: SALUS\n---\nbody",
      "---\nrepo: salus\nunterminated",
    ];
    for (const text of yes) assert.equal(hasSalusFrontmatter(text), true, JSON.stringify(text));
  });

  it("ignores other repos, the body and files without frontmatter", () => {
    const no = [
      "---\nrepo: himmel\n---\nbody",
      "---\ntitle: x\n---\nrepo: salus\n",
      "repo: salus\nno frontmatter",
      "---\nrepository: salus\n---\nbody",
      "---\nnotes: repo is salus\n---\nbody",
      "# plain",
    ];
    for (const text of no) assert.equal(hasSalusFrontmatter(text), false, JSON.stringify(text));
  });
});

describe("readVerified", () => {
  it("returns the content, size, mtime and sha256 of an allowed note", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const file = await readVerified(root, ["30-Resources", "note one.md"], reader, "whole");
    assert.match(file.text, /needle in spaced note/);
    assert.equal(file.sha256, createHash("sha256").update(file.text).digest("hex"));
    assert.equal(file.size, Buffer.byteLength(file.text));
    assert.ok(file.mtimeMs > 0);
    for (const rel of [["CLAUDE.md"], ["_Templates", "note.md"], ["docs", "guide.md"], ["30-Resources", "100% real.md"]]) {
      await readVerified(root, rel, reader, "whole");
    }
  });

  it("refuses a final symlink that escapes the root", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["link-out.md"], reader, "whole")), "escape");
  });

  it("refuses a final symlink even when it stays inside the root", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["alias-plain.md"], reader, "whole")), "symlink");
  });

  it("refuses a directory symlink that escapes the root", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["linkdir", "secret.md"], reader, "whole")), "escape");
  });

  it("refuses a symlink into a sibling directory whose name starts with the root name", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["prefix.md"], reader, "whole")), "escape");
  });

  it("applies the role-path gate to the resolved path of an in-root directory symlink", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["alias-sessions", "2026", "07", "2026-07-15-0821-salus-master.md"], reader, "whole")), "role-path");
  });

  it("refuses a repo: salus note and a clean-looking note whose disk file is now salus", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["30-Resources", "salus-note.md"], reader, "whole")), "salus");
    assert.equal(await kindOfAsync(() => readVerified(root, ["30-Resources", "stale.md"], reader, "prefix")), "salus");
  });

  it("refuses non-markdown, oversized and binary files before returning content", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    await put(root, "big.md", Buffer.alloc(600 * 1024, 0x61));
    assert.equal(await kindOfAsync(() => readVerified(root, ["notes.txt"], reader, "whole")), "not-markdown");
    assert.equal(await kindOfAsync(() => readVerified(root, ["big.md"], reader, "whole")), "too-large");
    assert.equal(await kindOfAsync(() => readVerified(root, ["binary.md"], reader, "whole")), "not-text");
  });

  it("reads only the scan window in prefix mode and still catches salus frontmatter", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    await put(root, "30-Resources/long.md", `${"x".repeat(SCAN_BYTES * 2)}\n`);
    const file = await readVerified(root, ["30-Resources", "long.md"], reader, "prefix");
    assert.ok(Buffer.byteLength(file.text) <= SCAN_BYTES);
    await put(root, "30-Resources/long-salus.md", `${salusNote("Long")}${"y".repeat(SCAN_BYTES * 2)}`);
    assert.equal(await kindOfAsync(() => readVerified(root, ["30-Resources", "long-salus.md"], reader, "prefix")), "salus");
  });

  it("reports a missing file and a directory as not found", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    assert.equal(await kindOfAsync(() => readVerified(root, ["30-Resources", "claude", "nope.md"], reader, "whole")), "not-found");
    assert.equal(await kindOfAsync(() => readVerified(root, ["30-Resources", "sub", "claude", "x.md"], reader, "whole")), "not-found");
    assert.equal(await kindOfAsync(() => readVerified(root, ["docs.md"], reader, "whole")), "not-found");
  });

  it("never returns the content of a denied path", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const denied: string[][] = [
      [".env"],
      [".npmrc"],
      [".git", "config"],
      ["30-Resources", "sub", ".claude", "x.md"],
      ["scripts", "vault-autosync.sh"],
      ["sessions", "2026", "07", "2026-07-15-0821-salus-master.md"],
      ["chats", "c1.md"],
      ["handovers", "h1.md"],
      ["30-Resources", "salus-note.md"],
    ];
    for (const segs of denied) {
      try {
        const file = await readVerified(root, segs, reader, "whole");
        assert.fail(`read ${segs.join("/")}: ${file.text.slice(0, 20)}`);
      } catch (e) {
        assert.ok(e instanceof Denied, segs.join("/"));
        assert.ok(!e.message.includes(LEAK) && !e.message.includes(PHI));
      }
    }
  });
});

describe("resolveDir", () => {
  it("returns the real segments of an allowed directory and refuses escapes and gated dirs", async (t) => {
    const fx = await buildFixture(t);
    const root = fx.roots.get("luna")!;
    const ok = await resolveDir(root, ["docs"], reader);
    assert.equal(ok.real, join(root, "docs"));
    assert.deepEqual(ok.segments, ["docs"]);
    assert.deepEqual((await resolveDir(root, [], reader)).segments, []);
    assert.equal(await kindOfAsync(() => resolveDir(root, ["linkdir"], reader)), "escape");
    assert.equal(await kindOfAsync(() => resolveDir(root, ["alias-sessions"], reader)), "role-path");
    assert.equal(await kindOfAsync(() => resolveDir(root, ["sessions"], reader)), "role-path");
    assert.equal(await kindOfAsync(() => resolveDir(root, [".obsidian"], reader)), "dot-segment");
    assert.equal(await kindOfAsync(() => resolveDir(root, ["nope"], reader)), "not-found");
  });
});
