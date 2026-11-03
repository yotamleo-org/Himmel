// Test seam CONFIG_UI_HIMMELCTL for the e2e suite: `report --json` prints the
// feed file named by $E2E_FEED; any other verb is recorded (argv) in $STUB_ARGV and succeeds.
// `config set tracker.teamMode` also runs the real himmelctl, so the switch writes the real line under the temp HOME.
const fs = require("node:fs");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
if (args[0] === "report") {
  // E2E_FEED_DELAY_MS holds the report so a test sees the pending feed.
  const delay = Number(process.env.E2E_FEED_DELAY_MS) || 0;
  // a held full report also writes probe-progress.cjs's step lines, spread across the delay.
  const steps = ["install items", "doctor checks", "pipeline cadence", "plugin profile"];
  if (delay > 0 && !args.includes("--items")) {
    steps.forEach((source, k) => setTimeout(() => process.stderr.write(`himmel-probe ${JSON.stringify({ i: k + 1, n: steps.length, source })}\n`), Math.floor((delay * k) / steps.length)));
  }
  setTimeout(() => process.stdout.write(fs.readFileSync(process.env.E2E_FEED, "utf8")), delay);
} else {
  // recorded last: a test that sees the argv line can read the written file
  if (args.slice(0, 3).join(" ") === "config set tracker.teamMode") {
    const real = spawnSync("node", [join(__dirname, "../../../himmelctl/bin.js"), ...args], { stdio: "inherit" });
    process.exitCode = real.status ?? 1;
  } else process.stdout.write(`did ${args.join(" ")}\n`);
  fs.appendFileSync(process.env.STUB_ARGV, `himmelctl ${args.join(" ")}\n`);
}
