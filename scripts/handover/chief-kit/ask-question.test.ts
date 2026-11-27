import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseQuestion, shortAnswer } from "../../jira/src/release/verbatim";
import { recordAsk } from "../../telegram/chief-route";

const HELPER = resolve(import.meta.dir, "ask-question.ts");
const KEY = "HIMMEL-1";
const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "ask-question-")); dirs.push(d); return d; };

const run = (...args: string[]) => {
  const p = Bun.spawnSync(["bun", HELPER, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: p.exitCode, out: p.stdout.toString(), err: p.stderr.toString() };
};
const ask = (specs: string, ...more: string[]) =>
  run("ask", "--specs", specs, "--decision", "7", "--shift", "EA", "--key", KEY, "--ask", "sign it as it stands, or revise it?", ...more);
const twoOptions = ["--option", "a1=sign it as it stands", "--option", "a2=revise the spec"];
const answer = (specs: string, words: string) => run("answer", "--specs", specs, "--decision", "7", "--words", words);
const fileOf = (specs: string) => {
  const names = readdirSync(join(specs, "decisions"));
  expect(names).toHaveLength(1);
  return join(specs, "decisions", names[0]);
};
const asked = (...more: string[]) => {
  const specs = tmp();
  const r = ask(specs, ...(more.length ? more : twoOptions));
  expect(r.err).toBe(""); expect(r.code).toBe(0);
  return { specs, file: fileOf(specs), printed: r.out };
};

test("ask writes a well-formed block and prints one Needs you: line", () => {
  const { file, printed } = asked();
  expect(file).toMatch(/verbatim-decision-7-operator-\d\d-\d\d-EA\.txt$/);
  expect(parseQuestion(readFileSync(file, "utf8"))).toMatchObject({ ok: true, q: { answer: null, options: [{ answer: "a1" }, { answer: "a2" }] } });
  expect(printed.trimEnd().split("\n")).toHaveLength(1);
  expect(printed).toStartWith(`Needs you: ${KEY} decision 7: sign it as it stands, or revise it? Answer a1 (sign it as it stands) or a2 (revise the spec).`);
});

test("the printed ask is recorded by recordAsk", async () => {
  const { printed } = asked();
  const root = tmp();
  await recordAsk(root, 5, printed.trimEnd());
  expect(readFileSync(join(root, "consoles", "asks.ndjson"), "utf8").trimEnd().split("\n")).toHaveLength(1);
});

test("ask refuses an existing decision", () => {
  const specs = tmp(); mkdirSync(join(specs, "decisions"));
  const f = join(specs, "decisions", "verbatim-decision-7-operator.txt"); writeFileSync(f, "kept\n");
  const r = ask(specs, ...twoOptions);
  expect(r.code).toBe(1); expect(r.err).toContain("already");
  expect(readdirSync(join(specs, "decisions"))).toHaveLength(1);
  expect(readFileSync(f, "utf8")).toBe("kept\n");
});

test("ask refuses one option, a repeated answer, a line break and bad usage, writing nothing", () => {
  const specs = tmp();
  for (const more of [["--option", "a1=only"], ["--option", "a1=x", "--option", "A1=y"], [...twoOptions, "--option", "a3=x\n\na3"]]) {
    expect(ask(specs, ...more).code, more.join(" ")).toBe(1);
  }
  expect(run("ask", "--specs", specs).code).toBe(2);
  expect(existsSync(join(specs, "decisions")) ? readdirSync(join(specs, "decisions")) : []).toEqual([]);
});

test("answer refuses a non-option and a second answer", () => {
  const { specs, file } = asked(); const before = readFileSync(file, "utf8");
  const wrong = answer(specs, "a3");
  expect(wrong.code).toBe(1); expect(readFileSync(file, "utf8")).toBe(before);
  expect(wrong.out).toMatch(/^Needs you: .*"a3".*a1 .*a2 /m);
  const ok = answer(specs, "a1");
  expect(ok.err).toBe(""); expect(ok.code).toBe(0); expect(ok.out).toContain("--quote 'a1'");
  const after = readFileSync(file, "utf8");
  expect(shortAnswer(after, "a1", KEY)).toEqual({ ok: true });
  expect(answer(specs, "a1").code).toBe(1); expect(readFileSync(file, "utf8")).toBe(after);
});

test("answer takes 20 characters or more with no option check", () => {
  const { specs, file } = asked();
  expect(answer(specs, "sign it, but run the critic once more").code).toBe(0);
  expect(parseQuestion(readFileSync(file, "utf8"))).toMatchObject({ ok: true, q: { answer: "sign it, but run the critic once more" } });
});

test("the printed --quote reads back byte for byte through a shell", () => {
  const { specs } = asked(); const words = "don't run `date` or $(id) \"yet\"";
  const r = answer(specs, words);
  expect(r.code).toBe(0);
  const sh = Bun.spawnSync(["bash", "-c", `set -- ${r.out.trim()}; printf %s "$2"`]);
  expect(sh.stdout.toString()).toBe(words);
});

test("answer refuses words holding a blank line", () => {
  const { specs, file } = asked(); const before = readFileSync(file, "utf8");
  const r = answer(specs, "first part of the answer\n\nsecond part of the answer");
  expect(r.code).toBe(1); expect(r.err).toContain("blank line");
  expect(readFileSync(file, "utf8")).toBe(before);
});

test("ask --yes-no lists yes and no, and answer yes passes", () => {
  const { specs, file } = asked("--yes-no");
  expect(readFileSync(file, "utf8")).toMatch(/^Option: yes = .+\nOption: no = .+$/m);
  expect(answer(specs, "yes").code).toBe(0);
  expect(shortAnswer(readFileSync(file, "utf8"), "yes", KEY)).toEqual({ ok: true });
});
