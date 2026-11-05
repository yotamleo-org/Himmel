#!/usr/bin/env node
// scripts/cr/blast-scope.cjs — the one owner of the blast-radius scope: the
// guard and gate paths whose change owes a `blast` row (clear-review-marker.sh
// gate 4f) and, for an outside PR, a blast row at its head (ready-check item 16g).
//
// module.exports.inScope(path) -> boolean
// CLI: NUL-separated paths on stdin; prints `touched` when any is in scope,
// else `untouched`; exit 2 when stdin cannot be read.
"use strict";

const SCOPE = [
  /^scripts\/hooks\//,
  /^scripts\/ci\/check-/,
  /^scripts\/cr\/clear-(cr|review)-marker\.sh$/,
  /^scripts\/testing\/check-/,
  /^scripts\/handover\/chief-kit\/ready-check\.sh$/,
];

function inScope(p) {
  return SCOPE.some((r) => r.test(p)) && !/(^|\/)test-[^\/]*$/.test(p) && !/\/fixtures\//.test(p);
}

module.exports = { inScope };

if (require.main === module) {
  let input;
  try {
    input = require("fs").readFileSync(0, "utf8");
  } catch (err) {
    process.stderr.write("blast-scope: cannot read stdin: " + err.message + "\n");
    process.exit(2);
  }
  process.stdout.write(input.split("\0").some(inScope) ? "touched\n" : "untouched\n");
}
