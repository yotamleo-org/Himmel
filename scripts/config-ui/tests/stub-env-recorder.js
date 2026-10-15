// Test seam CONFIG_UI_HIMMELCTL for the worktree-station test: a non-report call appends
// "<HIMMELCTL_REPO_ROOT> <argv>" to $STUB_ARGV; a report is answered by stub-recorder.js.
const { appendFileSync } = require("node:fs");
const args = process.argv.slice(2);
if (args[0] === "report") {
  require("./stub-recorder.js");
} else {
  appendFileSync(process.env.STUB_ARGV, (process.env.HIMMELCTL_REPO_ROOT || "(unset)") + " " + args.join(" ") + "\n");
  process.stdout.write("did " + args.join(" ") + "\n");
}
