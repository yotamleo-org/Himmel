import { expect, test } from "bun:test";
import { join } from "node:path";
import { briefText, findDo } from "./key-brief";

// The fixture mirror holds only the five H1 lines the replay needs.
const MIRROR = join(import.meta.dir, "fixtures", "jira-mirror");
const NOT_READ = "summary not readable on the station";
const cut = (s: string) => (s.length > 80 ? `${s.slice(0, 79)}…` : s);
const S9503 = cut("Visibility: the operator's Telegram gets short escalations, routine goes to monitoring");
const S9012 = cut("Ship loop: an allowed contributor's PR gets our review with no checkout on the station");
const S1 = "HIMMEL-1";

test("a ticket key in the running text gets its summary inline", () => {
  expect(briefText("HIMMEL-9503 needs you", MIRROR, "PR")).toBe(`HIMMEL-9503 (${S9503}) needs you`);
});

test("the HOLD-ASK grant command keeps --key HIMMEL-9012 unchanged and gains a trailer line", () => {
  const cmd = "! bash go.sh grant --key HIMMEL-9012 --path scripts/cr/critic-panel.sh";
  const out = briefText(`A worker wants a file.\n${cmd}`, MIRROR, "PR");
  expect(out).toContain(cmd);
  expect(out).toContain(`HIMMEL-9012: ${S9012}`);
  expect(out.indexOf(cmd)).toBeLessThan(out.indexOf(`HIMMEL-9012: ${S9012}`));
});

test("a Do: step and a backtick span are byte-identical, and the trailer sits before ` Do: `", () => {
  const doText = "Merge refused. Do: go.sh HIMMEL-1 abc";
  const out = briefText(doText, MIRROR, "PR");
  expect(out.endsWith("Do: go.sh HIMMEL-1 abc")).toBe(true);
  expect(out.indexOf(`${S1}: ${NOT_READ}`)).toBeGreaterThan(-1);
  expect(out.indexOf(`${S1}: ${NOT_READ}`)).toBeLessThan(out.lastIndexOf("Do: "));
  expect(out.startsWith("Merge refused.")).toBe(true);
  const tick = "Run `jira get HIMMEL-1` now";
  const out2 = briefText(tick, MIRROR, "PR");
  expect(out2.startsWith(tick)).toBe(true);
  expect(out2.slice(tick.length)).toBe(`\n${S1}: ${NOT_READ}`);
});

test("a `!` line with no Do: and a line starting `$ ` are byte-identical", () => {
  for (const line of ["! bash /x/go.sh HIMMEL-1 abc123", "$ bash /x/go.sh HIMMEL-1 abc123"]) {
    const out = briefText(line, MIRROR, "PR");
    expect(out.startsWith(line)).toBe(true);
    expect(out.slice(line.length)).toBe(`\n${S1}: ${NOT_READ}`);
  }
});

test("a key of a known project with no mirror file gets the fixed text", () => {
  expect(briefText("HIMMEL-1 is stuck", MIRROR, "PR")).toBe(`HIMMEL-1 (${NOT_READ}) is stuck`);
});

test("SHA-256 and UTF-8 are untouched", () => {
  const text = "hash SHA-256 and UTF-8 are plain words";
  expect(briefText(text, MIRROR, "PR")).toBe(text);
});

test("a key already followed by its summary is left alone", () => {
  const text = `HIMMEL-9503 (${S9503}) needs you`;
  expect(briefText(text, MIRROR, "PR")).toBe(text);
  const colon = `HIMMEL-9503: ${S9503} needs you`;
  expect(briefText(colon, MIRROR, "PR")).toBe(colon);
});

test("PR numbers and worker labels get words outside Do:, and himmel#81843b5d stays", () => {
  expect(briefText("see yotamleo-org/Himmel#4882 now", MIRROR, "PR")).toBe("see PR 4882 in yotamleo-org/Himmel now");
  expect(briefText("N4992b is silent", MIRROR, "PR")).toBe("worker N4992b is silent");
  expect(briefText("worker N4992b is silent", MIRROR, "PR")).toBe("worker N4992b is silent");
  expect(briefText("session himmel#81843b5d paused", MIRROR, "PR")).toBe("session himmel#81843b5d paused");
  const kept = briefText("fix. Do: run N4992b and yotamleo-org/Himmel#4882", MIRROR, "PR");
  expect(kept).toBe("fix. Do: run N4992b and yotamleo-org/Himmel#4882");
});

test("a backtick span or a ! line that contains ` Do: ` stays whole, and the real Do: step is the last one outside them", () => {
  const span = "`jira get HIMMEL-1 Do: x`";
  const out = briefText(`A ${span} is shown`, MIRROR, "PR");
  expect(out.startsWith(`A ${span} is shown`)).toBe(true);
  expect(out.slice(`A ${span} is shown`.length)).toBe(`\n${S1}: ${NOT_READ}`);
  const bang = "! echo 1 Do: HIMMEL-1";
  const both = briefText(`First line.\n${bang}\nLast. Do: finish`, MIRROR, "PR");
  expect(both).toContain(`\n${bang}\n`);
  expect(both.endsWith("Do: finish")).toBe(true);
});

test("a trailer line leaves the Do: step findable by the cap's own search", () => {
  const out = briefText("Merge refused. Blocks: x. Do: go.sh HIMMEL-1 abc", MIRROR, "PR");
  expect(findDo(out)).toBeGreaterThan(0);
  expect(out.slice(findDo(out)).trimStart()).toBe("Do: go.sh HIMMEL-1 abc");
});

test("the ref word comes from the kind's row", () => {
  expect(briefText("octo/x#12 changed", MIRROR, "PR or issue")).toBe("PR or issue 12 in octo/x changed");
});
