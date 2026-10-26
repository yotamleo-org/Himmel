// actual fleet grouping and router functions over a two-chief fixture.
import { expect, test } from "bun:test";
import * as page from "../agui-web/src/fleet-model";
import * as stream from "../agui-web/src/fleet-model";

const row = (name: string, role: string, console: string | null, extra: any = {}) => ({
  name, role, console, parent: console, live: true, lock: "unknown", lane: "native",
  state: "idle", run: `run-${name}`, pid: 1, model: null, ticket: null, pr: null,
  activity: null, lastEventAt: null, agents: [], subagents: { total: 0, running: 0 },
  failures: 0, usage: null, runtime: null, cloud: null, predecessor: null, ...extra,
});
const rows = [
  row("roadmap-chief", "console", "roadmap-chief"),
  row("project-chief", "console", "project-chief"),
  row("native-worker", "leg", "roadmap-chief"),
  row("claudex-worker", "leg", "project-chief", { lane: "claudex" }),
  row("judge", "judge", "project-chief"),
  row("wrapped-chief", "console", "wrapped-chief", { state: "wrapped", live: false, lock: "released" }),
  row("wrapped-parent-worker", "leg", "wrapped-chief"),
  row("dead-parent-worker", "leg", "gone-chief"),
  row("no-edge-worker", "leg", null),
  row("cloud-unattended", "cloud", "roadmap-chief", { run: null, cloud: { phase: "working", url: null } }),
  row("old-cloud", "cloud", "wrapped-chief", { state: "wrapped", live: false, cloud: { phase: "merged", url: null } }),
  row("wrapped-worker", "leg", "roadmap-chief", { state: "wrapped", live: false }),
];

test("two console groups retain native, claudex and judge children; recent chiefs sort last", () => {
  const groups = (page as any).consoleGroups?.(rows);
  expect(groups?.map((g: any) => g.console.name)).toEqual(["project-chief", "roadmap-chief", "wrapped-chief"]);
  expect(groups?.[0].rows.map((r: any) => r.name)).toEqual(["claudex-worker", "judge"]);
  // a cloud session is a lane under its chief, never an orphan for want of a shepherd.
  expect(groups?.[1].rows.map((r: any) => r.name)).toEqual(["native-worker", "cloud-unattended", "wrapped-worker"]);
});

test("orphans name released console, dead process and absent edge causes; a cloud session without a shepherd is none", () => {
  const orphan = (page as any).orphanReason;
  expect(orphan?.(rows[6], rows)).toBe("chief wrapped / lock released");
  expect(orphan?.(rows[7], rows)).toBe("chief process gone");
  expect(orphan?.(rows[8], rows)).toBe("no console edge");
  expect(orphan?.(rows[9], rows)).toBeNull();
  expect(orphan?.(rows[2], rows)).toBeNull();
});

test("merged cloud under a retired console is dropped, wrapped workers remain collapsed", () => {
  const shown = (page as any).visibleRows?.(rows);
  expect(shown?.map((r: any) => r.name)).not.toContain("old-cloud");
  expect(shown?.map((r: any) => r.name)).toContain("wrapped-worker");
});

test("chief deep link selects only its page; menu and fleet use identical run drill-in hashes", () => {
  const hash = (stream as any).consoleHash?.("token", "project-chief");
  expect(hash).toBe("#t=token&console=project-chief");
  expect((stream as any).consoleFromHash?.(hash)).toBe("project-chief");
  expect(stream.fleetToken(hash ?? "")).toBe("token");
  expect((page as any).rowHref?.("token", rows[2])).toBe("#t=token&run=run-native-worker");
  expect((page as any).rowHref?.("token", rows[0])).toBe("#t=token&run=run-roadmap-chief");
});
