// HIMMEL-5491: a stubbed Jira CLI for the write-route tests. Records each argv as one JSON line in $STUB_JIRA_LOG;
// `get --json` answers with the labels in $STUB_JIRA_LABELS (comma separated) and a description from $STUB_JIRA_DESC;
// $STUB_JIRA_GET_RAW replaces the whole `get` output; $STUB_JIRA_FAIL=<verb> makes that verb exit 1. Never live Jira.
const { appendFileSync } = require("node:fs");
const argv = process.argv.slice(2);
if (process.env.STUB_JIRA_LOG) appendFileSync(process.env.STUB_JIRA_LOG, JSON.stringify(argv) + "\n");
if (process.env.STUB_JIRA_FAIL === argv[0]) { console.error("stub jira: refused " + argv[0]); process.exit(1); }
if (argv[0] === "get" && process.env.STUB_JIRA_GET_RAW !== undefined) console.log(process.env.STUB_JIRA_GET_RAW);
else if (argv[0] === "get") {
  const labels = (process.env.STUB_JIRA_LABELS || "").split(",").map((l) => l.trim()).filter(Boolean);
  console.log(JSON.stringify({ key: argv[1], fields: { summary: "stub title", description: process.env.STUB_JIRA_DESC || null, labels } }));
}
