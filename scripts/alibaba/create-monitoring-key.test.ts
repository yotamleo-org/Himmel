// scripts/alibaba/create-monitoring-key.test.ts
// Rows S0-R0, S0-R2, S0-R3b of the secrets-resolver slice. The real scripts/lib/himmel-secrets runs over a
// stub keyring (secret-tool and busctl first on PATH); the Alibaba RAM API is a fake `call`.
// Every key and value here is a dummy; no row reaches the station keyring or a real .env.
import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stubKeyring } from "../config-ui/tests/keyring-stub";
import { main } from "./create-monitoring-key";

describe("create-monitoring-key secrets", () => {
  const TOUCHED = ["PATH", "KSTUB_STORE", "KSTUB_LOG", "KSTUB_LOCKED", "DBUS_SESSION_BUS_ADDRESS",
    "ALIBABA_QUOTA_AK", "ALIBABA_QUOTA_SK", "HIMMEL_SECRETS_KEYRING", "CREDENTIALS_DIRECTORY"];
  const saved: Record<string, string | undefined> = {};
  let dir: string;
  let stub: ReturnType<typeof stubKeyring>;
  let root: string;
  let log: string;

  beforeAll(() => {
    for (const k of TOUCHED) saved[k] = process.env[k];
    dir = mkdtempSync(join(tmpdir(), "cmk-test-"));
    stub = stubKeyring(dir);
    // Log every secret-tool call's argv (never the value, which travels on stdin).
    const bin = join(dir, "kbin");
    renameSync(join(bin, "secret-tool"), join(bin, "secret-tool.real"));
    writeFileSync(join(bin, "secret-tool"),
      '#!/usr/bin/env bash\nprintf "secret-tool %s\\n" "$*" >>"$KSTUB_LOG"\nexec "$(dirname "$0")/secret-tool.real" "$@"\n');
    chmodSync(join(bin, "secret-tool"), 0o755);
    log = join(dir, "keyring.log");
    Object.assign(process.env, stub.env, { KSTUB_LOG: log });
    // Suite guard: the resolver must find the stub, never a real secret-tool or busctl.
    for (const tool of ["secret-tool", "busctl"]) {
      const where = Bun.which(tool, { PATH: process.env.PATH }) ?? "";
      if (!where.startsWith(bin)) throw new Error(`${tool} resolves to ${where}, not the stub dir: aborting before any real keyring call`);
    }
  });

  afterAll(() => {
    for (const k of TOUCHED) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
    rmSync(dir, { recursive: true, force: true });
  });

  beforeEach(() => {
    for (const k of ["ALIBABA_QUOTA_AK", "ALIBABA_QUOTA_SK", "HIMMEL_SECRETS_KEYRING", "CREDENTIALS_DIRECTORY"]) delete process.env[k];
    process.env.KSTUB_LOCKED = "false";
    writeFileSync(stub.store, "");
    writeFileSync(log, "");
    root = mkdtempSync(join(dir, "root-"));
  });

  // A fake RAM API: records the master pair every call was signed with.
  function fakeRam() {
    const signedWith: string[] = [];
    const call = async (ak: string, _sk: string, action: string) => {
      signedWith.push(ak);
      if (action === "ListAccessKeys") return { ok: true, status: 200, body: { AccessKeys: { AccessKey: [] } } };
      if (action === "CreateAccessKey") return { ok: true, status: 200, body: { AccessKey: { AccessKeyId: "LTAIscoped-s0", AccessKeySecret: "scoped-sk-s0" } } };
      return { ok: true, status: 200, body: {} };
    };
    return { call, signedWith };
  }

  // main() prints progress and calls process.exit on a failure: mute the first, turn the second into a throw.
  const quiet = async (fn: () => Promise<void>) => {
    const { log: origLog, error: origErr } = console;
    const origExit = process.exit;
    console.log = () => {};
    console.error = () => {};
    process.exit = ((code?: number) => { throw new Error(`process.exit(${code})`); }) as typeof process.exit;
    try { await fn(); } finally { console.log = origLog; console.error = origErr; process.exit = origExit; }
  };

  describe("create-monitoring-key reads its master pair through the resolver", () => {
    test("S0-R0 a pair held only in the keyring is served, and the stub log shows lookups with no value", async () => {
      stub.put("ALIBABA_QUOTA_AK", "dummy-s0-ak");
      stub.put("ALIBABA_QUOTA_SK", "dummy-s0-sk");
      writeFileSync(join(root, ".env"), "OTHER=1\n");
      const ram = fakeRam();
      await quiet(() => main({ root, rotate: false, call: ram.call }));
      expect(ram.signedWith[0]).toBe("dummy-s0-ak");
      const logged = readFileSync(log, "utf8");
      expect(logged).toContain("secret-tool lookup service himmel key ALIBABA_QUOTA_AK scope user");
      expect(logged).not.toContain("dummy-s0");
    });

    test("S0-R2 a pair in both the keyring and .env resolves to the keyring value", async () => {
      stub.put("ALIBABA_QUOTA_AK", "dummy-keyring-ak");
      stub.put("ALIBABA_QUOTA_SK", "dummy-keyring-sk");
      writeFileSync(join(root, ".env"), "ALIBABA_QUOTA_AK=dummy-dotenv-ak\nALIBABA_QUOTA_SK=dummy-dotenv-sk\n");
      const ram = fakeRam();
      await quiet(() => main({ root, rotate: false, call: ram.call }));
      expect(ram.signedWith[0]).toBe("dummy-keyring-ak");
    });
  });

  describe("create-monitoring-key write-back of the scoped pair", () => {
    test("S0-R3b keyring unlocked: stored through put --stdin, no .env line added, argv holds no value", async () => {
      stub.put("ALIBABA_QUOTA_AK", "dummy-s0-ak");
      stub.put("ALIBABA_QUOTA_SK", "dummy-s0-sk");
      writeFileSync(join(root, ".env"), "OTHER=1\n");
      await quiet(() => main({ root, rotate: false, call: fakeRam().call }));
      expect(stub.get("ALIBABA_QUOTA_AK")).toBe("LTAIscoped-s0");
      expect(stub.get("ALIBABA_QUOTA_SK")).toBe("scoped-sk-s0");
      expect(readFileSync(join(root, ".env"), "utf8")).toBe("OTHER=1\n");
      const logged = readFileSync(log, "utf8");
      expect(logged).toContain("secret-tool store --label himmel: ALIBABA_QUOTA_AK service himmel key ALIBABA_QUOTA_AK scope user");
      expect(logged).not.toContain("scoped-sk-s0");
      expect(logged).not.toContain("LTAIscoped-s0");
    });

    test("S0-R3b keyring unlocked and no .env at all: still persists to the keyring", async () => {
      stub.put("ALIBABA_QUOTA_AK", "dummy-s0-ak");
      stub.put("ALIBABA_QUOTA_SK", "dummy-s0-sk");
      await quiet(() => main({ root, rotate: false, call: fakeRam().call }));
      expect(stub.get("ALIBABA_QUOTA_AK")).toBe("LTAIscoped-s0");
    });

    test("S0-R3b keyring locked: today's .env write, nothing stored", async () => {
      process.env.KSTUB_LOCKED = "true";
      writeFileSync(join(root, ".env"), "ALIBABA_QUOTA_AK=dummy-m-ak\nALIBABA_QUOTA_SK=dummy-m-sk\n");
      const ram = fakeRam();
      await quiet(() => main({ root, rotate: false, call: ram.call }));
      expect(ram.signedWith[0]).toBe("dummy-m-ak");
      expect(readFileSync(join(root, ".env"), "utf8")).toContain("ALIBABA_QUOTA_AK=LTAIscoped-s0");
      expect(readFileSync(join(root, ".env"), "utf8")).toContain("ALIBABA_QUOTA_SK=scoped-sk-s0");
      expect(readFileSync(stub.store, "utf8")).toBe("");
    });
  });
});
