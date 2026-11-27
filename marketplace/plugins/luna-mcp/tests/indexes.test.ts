import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, it, type TestContext } from "node:test";
import { isolatedCollections, loadNamedIndexes } from "../src/indexes.js";
import { scratch } from "./helpers.js";

const entry = (over: Record<string, unknown> = {}) => ({ url: "http://localhost:8183", tokenFile: "/run/tok", config: "", ...over });

async function load(t: TestContext, build: (dir: string) => Record<string, unknown>) {
  const dir = await scratch(t);
  await writeFile(join(dir, "gmail.yml"), "collections:\n  gmail:\n    path: /mail/gmail-md\n");
  await writeFile(join(dir, "other.yml"), "collections:\n  gmail:\n    path: /mail/other\n  extra:\n    path: /mail/extra\n");
  const file = join(dir, "indexes.json");
  await writeFile(file, JSON.stringify(build(dir)));
  return loadNamedIndexes({ LUNA_MCP_INDEXES: file, HOME: dir });
}

describe("named indexes", () => {
  it("loads nothing without LUNA_MCP_INDEXES", async () => {
    assert.deepEqual(await loadNamedIndexes({}), []);
  });

  it("reads the url, token file and collection roots of each index", async (t) => {
    const [gmail] = await load(t, (dir) => ({ gmail: entry({ config: join(dir, "gmail.yml") }) }));
    assert.equal(gmail!.name, "gmail");
    assert.equal(gmail!.url, "http://localhost:8183");
    assert.equal(gmail!.tokenFile, "/run/tok");
    assert.deepEqual([...gmail!.roots], [["gmail", "/mail/gmail-md"]]);
  });

  it("accepts loopback hosts and refuses every other url", async (t) => {
    for (const url of ["http://127.0.0.1:8183", "http://[::1]:8183", "https://localhost:8183"]) {
      assert.equal((await load(t, (dir) => ({ gmail: entry({ url, config: join(dir, "gmail.yml") }) })))[0]!.url, url);
    }
    for (const url of ["http://203.0.113.5:8183", "http://example.com:8183", "http://0.0.0.0:8183", "ftp://localhost", "localhost:8183", "http://user:pw@localhost:8183", 8183]) {
      await assert.rejects(load(t, (dir) => ({ gmail: entry({ url, config: join(dir, "gmail.yml") }) })), /url/, String(url));
    }
  });

  it("refuses a relative token file or config", async (t) => {
    await assert.rejects(load(t, (dir) => ({ gmail: entry({ tokenFile: "token", config: join(dir, "gmail.yml") }) })), /tokenFile must be an absolute path/);
    await assert.rejects(load(t, () => ({ gmail: entry({ config: "gmail.yml" }) })), /config must be an absolute path/);
  });

  it("refuses an entry that is not an object and a bad index name", async (t) => {
    await assert.rejects(load(t, () => ({ gmail: "http://localhost:8183" })), /not a valid entry/);
    await assert.rejects(load(t, (dir) => ({ "a/b": entry({ config: join(dir, "gmail.yml") }) })), /not a valid entry/);
  });

  it("refuses a collection defined twice, across indexes and against the shared index", async (t) => {
    const both = await load(t, (dir) => ({ gmail: entry({ config: join(dir, "gmail.yml") }), other: entry({ url: "http://localhost:8184", config: join(dir, "other.yml") }) }));
    assert.throws(() => isolatedCollections(both, ["luna"]), /gmail is defined in more than one qmd index/);
    const [gmail] = await load(t, (dir) => ({ gmail: entry({ config: join(dir, "gmail.yml") }) }));
    assert.throws(() => isolatedCollections([gmail!], ["luna", "gmail"]), /gmail is defined in more than one qmd index/);
    assert.equal(isolatedCollections([gmail!], ["luna"]).get("gmail"), gmail);
  });
});
