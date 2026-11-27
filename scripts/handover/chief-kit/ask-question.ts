#!/usr/bin/env bun
import { appendFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { selectDecisionNames } from "../../jira/src/release/pinned";
import { isShort, parseQuestion, renderQuestion, shortAnswer, type Question } from "../../jira/src/release/verbatim";

const USAGE = `usage:
  bun ask-question.ts ask --specs <dir> --decision <d> --shift <SHIFT> --key <KEY> --ask "<text>" (--option "<answer>=<meaning>")... [--yes-no] [--chief <session>]
  bun ask-question.ts answer --specs <dir> --decision <d> --words "<the operator's answer>"`;

class Refusal extends Error {}
const BLANK = /\r?\n[ \t]*\r?\n/;

const decisionsIn = (specs: string, d: string): { dir: string; names: string[] } => {
  const dir = join(specs, "decisions");
  let all: string[] = [];
  try { all = readdirSync(dir); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
  return { dir, names: selectDecisionNames(all, d) };
};

const list = (o: Question["options"]) => {
  const items = o.map((x) => `${x.answer} (${x.meaning})`);
  return `${items.slice(0, -1).join(", ")} or ${items.at(-1)}`;
};

function ask(o: Record<string, string | string[] | boolean | undefined>): string {
  const { specs, decision, shift, key, ask: text, chief } = o as Record<string, string>;
  const options = ((o.option as string[] | undefined) ?? []).map((raw) => {
    const at = raw.indexOf("=");
    if (at < 0) throw new Refusal(`--option "${raw}" is not <answer>=<meaning>`);
    return { answer: raw.slice(0, at).trim(), meaning: raw.slice(at + 1).trim() };
  });
  if (o["yes-no"]) options.push({ answer: "yes", meaning: "go ahead" }, { answer: "no", meaning: "do not" });
  if (!/^[A-Z][A-Z0-9]+-[0-9]+$/.test(key)) throw new Refusal(`--key "${key}" is not a ticket key`);
  if (!/^[A-Za-z0-9]+$/.test(shift)) throw new Refusal(`--shift "${shift}" is letters and digits`);
  const fields = [text, chief ?? "", ...options.flatMap((x) => [x.answer, x.meaning])];
  if (fields.some((f) => /[\r\n]/.test(f))) throw new Refusal("a field holds a line break");
  const now = new Date();
  const block = renderQuestion({
    subject: `${key} decision ${decision}`,
    asked: `${now.toISOString().replace(/\.\d+Z$/, "Z")}${chief ? ` by ${chief}` : ""}`,
    ask: [text.trim()],
    options,
  });
  const parsed = parseQuestion(block);
  if (!("ok" in parsed) || !parsed.ok) throw new Refusal(`the question block would not hold (${"why" in parsed ? parsed.why : "no block"})`);
  const { dir, names } = decisionsIn(specs, decision);
  if (names.length) throw new Refusal(`decision ${decision} already has ${names.join(", ")}; take another number`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `verbatim-decision-${decision}-operator-${now.toISOString().slice(5, 10)}-${shift}.txt`), block, { flag: "wx" });
  return `Needs you: ${key} decision ${decision}: ${text.trim()} Answer ${list(parsed.q.options)}.`;
}

function answer(o: Record<string, string | string[] | boolean | undefined>): string {
  const { specs, decision, words } = o as Record<string, string>;
  const { dir, names } = decisionsIn(specs, decision);
  if (names.length !== 1) throw new Refusal(`${names.length} files match decision ${decision}, expected exactly one`);
  const path = join(dir, names[0]);
  const before = readFileSync(path, "utf8");
  const parsed = parseQuestion(before);
  if ("none" in parsed) throw new Refusal(`${names[0]} has no Question block`);
  if (!parsed.ok) throw new Refusal(`${names[0]} has a Question block that does not hold (${parsed.why})`);
  if (parsed.q.answer !== null) throw new Refusal(`decision ${decision} already has an answer`);
  if (!words.trim()) throw new Refusal("--words is empty");
  if (BLANK.test(words)) throw new Refusal("the words hold a blank line");
  const added = `\n${words.trim()}\n`;
  const after = parseQuestion(before + added);
  if (!("ok" in after) || !after.ok) throw new Refusal(`the answer would not hold (${"why" in after ? after.why : "no block"})`);
  if (after.q.answer !== words.trim()) throw new Refusal("the answer would not read back as written");
  if (isShort(words)) {
    const r = shortAnswer(before + added, words);
    if (!r.ok) {
      console.log(`Needs you: ${parsed.q.subject}: "${words.trim()}" is not one of the options. Answer ${list(parsed.q.options)}.`);
      throw new Refusal(`"${words.trim()}" cannot be recorded (${r.why})`);
    }
  }
  appendFileSync(path, added);
  return `--quote '${words.trim().replaceAll("'", "'\\''")}'`;
}

if (import.meta.main) {
  let verb: string | undefined;
  let values: Record<string, string | string[] | boolean | undefined> = {};
  try {
    const parsed = parseArgs({
      allowPositionals: true,
      options: {
        specs: { type: "string" }, decision: { type: "string" }, shift: { type: "string" }, key: { type: "string" },
        ask: { type: "string" }, option: { type: "string", multiple: true }, "yes-no": { type: "boolean" },
        chief: { type: "string" }, words: { type: "string" },
      },
    });
    values = parsed.values;
    verb = parsed.positionals.length === 1 ? parsed.positionals[0] : undefined;
  } catch (e) {
    console.error((e as Error).message);
  }
  const need = verb === "ask" ? ["specs", "decision", "shift", "key", "ask"] : verb === "answer" ? ["specs", "decision", "words"] : null;
  if (!need || need.some((n) => values[n] === undefined)) {
    console.error(USAGE);
    process.exit(2);
  }
  try {
    console.log(verb === "ask" ? ask(values) : answer(values));
  } catch (e) {
    console.error(`ask-question: ${(e as Error).message}`);
    process.exit(1);
  }
}
