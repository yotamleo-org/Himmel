#!/usr/bin/env node
// egress-matrix-eval.mjs - CLI wrapper over the egress-matrix reference
// semantics for shell consumers, and an importable evaluator for in-process ones.
//
// Reuses the SAME first-match-wins evaluation as the reference evaluate() in
// test-egress-matrix.mjs: iterate `rules`, '*' wildcards, then `default`.
// Unlike that helper (which collapses allow+log -> allow for its invariant
// asserts), THIS wrapper PRESERVES the distinction the fence needs:
//   allow       -> permitted, no ledger
//   allow+log   -> permitted, ledger obligation
//   conditional -> permitted ONLY if the caller verifies the rule condition
//   deny        -> refused (pending-operator and any UNKNOWN verdict fail closed)
// No rule match returns `default` (asserted "deny" by the matrix test).
//
// Exports: loadMatrix(path?) reads the matrix (default: egress-matrix.json beside
// this file); evaluate(matrix, corpus, provider, purpose) returns {verdict, note}.
//
// Usage: node egress-matrix-eval.mjs <corpus> <provider> <purpose>
// Prints ONE line to stdout: "<verdict>\t<note>". Exit 0 on a clean
// evaluation, 2 on bad args / unreadable matrix (caller fails closed).
import { readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export function loadMatrix(path = join(dirname(fileURLToPath(import.meta.url)), "egress-matrix.json")) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function evaluate(m, c, p, u) {
  for (const r of m.rules) {
    const hit =
      (r.corpus === "*" || r.corpus === c) &&
      (r.provider === "*" || r.provider === p) &&
      (r.purpose === "*" || r.purpose === u);
    if (!hit) continue;
    const verdict =
      r.verdict === "allow" ? "allow" :
      r.verdict === "allow+log" ? "allow+log" :
      r.verdict === "conditional" ? "conditional" :
      "deny"; // deny, pending-operator, and any UNKNOWN verdict fail closed
    return { verdict, note: r.why || r.condition || "" };
  }
  // m.default is asserted "deny" by test-egress-matrix.mjs; treated as effective.
  return { verdict: m.default, note: "default (no rule matched)" };
}

function main() {
  const [corpus, provider, purpose] = process.argv.slice(2);
  if (!corpus || !provider || !purpose) {
    process.stderr.write("egress-matrix-eval: need <corpus> <provider> <purpose>\n");
    process.exit(2);
  }

  let m;
  try {
    m = loadMatrix();
  } catch (e) {
    process.stderr.write(`egress-matrix-eval: cannot read matrix: ${e?.message ?? e}\n`);
    process.exit(2);
  }

  const { verdict, note } = evaluate(m, corpus, provider, purpose);
  process.stdout.write(`${verdict}\t${note}\n`);
}

// Real paths on both sides: a caller may reach this file through a symlinked dir,
// and node reports the main module's real path in import.meta.url.
function invokedAsScript() {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedAsScript()) main();
