// `himmelctl ui --service install|uninstall|status|url` against a stub systemctl: the unit file, the token file and the
// systemctl calls. The real unit on a real systemd is proved on the test VM, never here.
import { test, expect } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = join(import.meta.dir, "..", "..", "himmelctl", "bin.js");

function sandbox() {
  const dir = mkdtempSync(join(tmpdir(), "ui-service-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const calls = join(dir, "calls");
  writeFileSync(join(bin, "systemctl"), `#!/bin/sh\necho "$@" >> ${calls}\ncase "$2" in is-active) echo active;; is-enabled) echo enabled;; esac\nexit 0\n`);
  chmodSync(join(bin, "systemctl"), 0o755);
  const env: Record<string, string | undefined> = {
    ...process.env, HOME: dir, HANDOVER_DIR: join(dir, "handovers"), HIMMELCTL_SYSTEMD_USER_UNIT_DIR: join(dir, "units"),
    PATH: `${bin}:${process.env.PATH}`,
  };
  for (const k of Object.keys(env)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete env[k];
  const run = async (...a: string[]) => {
    const p = Bun.spawn(["node", BIN, "ui", ...a], { env, stdout: "pipe", stderr: "pipe" });
    const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    return { rc: await p.exited, out, err };
  };
  return { dir, calls, run, unit: join(dir, "units", "himmel-ui.service"), token: join(dir, ".himmel", "state", "ui-token"), done: () => rmSync(dir, { recursive: true, force: true }) };
}

test("--service install writes the unit and a mode-600 token, url prints the bookmark, uninstall removes both", async () => {
  const s = sandbox();
  try {
    const inst = await s.run("--service", "install");
    expect(inst.rc).toBe(0);
    const unit = readFileSync(s.unit, "utf8");
    expect(unit).toMatch(/^ExecStart="[^"]*bun" ".*scripts\/config-ui\/server\.ts" --service --port 47391$/m);
    expect(unit).toContain(`Environment="HANDOVER_DIR=${s.dir}/handovers"`);
    expect(unit).toMatch(/^Restart=on-failure$/m);
    expect(statSync(s.token).mode & 0o777).toBe(0o600);
    const calls = readFileSync(s.calls, "utf8");
    expect(calls).toContain("--user daemon-reload");
    expect(calls).toContain("--user enable --now himmel-ui.service");

    const tok = readFileSync(s.token, "utf8").trim();
    const url = await s.run("--service", "url");
    expect(url.out.trim()).toBe(`http://127.0.0.1:47391/agui/#t=${tok}`);

    const again = await s.run("--service", "install");
    expect(again.rc).toBe(0);
    expect(readFileSync(s.token, "utf8").trim()).toBe(tok); // a re-install keeps the bookmark

    expect((await s.run("--service", "status")).out).toContain("himmel-ui.service: active (enabled)");

    expect((await s.run("--service", "uninstall")).rc).toBe(0);
    expect(existsSync(s.unit)).toBe(false);
    expect(existsSync(s.token)).toBe(false);
    expect((await s.run("--service", "url")).rc).toBe(1);
  } finally { s.done(); }
});

test("--service install --port N renders that port, and --dry-run writes nothing", async () => {
  const s = sandbox();
  try {
    const dry = await s.run("--service", "install", "--port", "48000", "--dry-run");
    expect(dry.rc).toBe(0);
    expect(existsSync(s.unit)).toBe(false);
    expect(existsSync(s.token)).toBe(false);
    await s.run("--service", "install", "--port", "48000");
    expect(readFileSync(s.unit, "utf8")).toContain("--service --port 48000");
    expect((await s.run("--service", "url")).out).toContain("127.0.0.1:48000/");
  } finally { s.done(); }
});

test("--service install refuses an existing token file the server would reject", async () => {
  const s = sandbox();
  try {
    mkdirSync(join(s.dir, ".himmel", "state"), { recursive: true });
    writeFileSync(s.token, "not-a-token\n", { mode: 0o600 });
    const bad = await s.run("--service", "install");
    expect(bad.rc).toBe(1);
    expect(bad.err).toContain("64-hex");
    expect(existsSync(s.unit)).toBe(false);
    chmodSync(s.token, 0o644);
    writeFileSync(s.token, "a".repeat(64) + "\n");
    chmodSync(s.token, 0o644);
    expect((await s.run("--service", "install")).rc).toBe(1);
  } finally { s.done(); }
});

test("--service uninstall keeps the token when the service could not be stopped", async () => {
  const s = sandbox();
  try {
    expect((await s.run("--service", "install")).rc).toBe(0);
    writeFileSync(join(s.dir, "bin", "systemctl"), `#!/bin/sh\ncase "$2" in disable) exit 1;; is-active) echo active;; esac\nexit 0\n`);
    const r = await s.run("--service", "uninstall");
    expect(r.rc).toBe(1);
    expect(r.err).toContain("not confirmed stopped");
    expect(existsSync(s.token)).toBe(true);
    expect(existsSync(s.unit)).toBe(true);
  } finally { s.done(); }
});

test("--service install refuses without HANDOVER_DIR, and a bad verb is rc 2", async () => {
  const s = sandbox();
  try {
    const p = Bun.spawn(["node", BIN, "ui", "--service", "install"], { env: { PATH: process.env.PATH, HOME: s.dir, HANDOVER_DIR: "", HIMMELCTL_SYSTEMD_USER_UNIT_DIR: join(s.dir, "units") }, stdout: "pipe", stderr: "pipe" });
    expect(await p.exited).toBe(1);
    expect(await new Response(p.stderr).text()).toContain("HANDOVER_DIR");
    expect((await s.run("--service", "bogus")).rc).toBe(2);
  } finally { s.done(); }
});
