// a stubbed Jira CLI for the write-route tests. Records each argv as one JSON line in $STUB_JIRA_LOG;
// `get --json` answers with the labels in $STUB_JIRA_LABELS (comma separated) and a description from $STUB_JIRA_DESC;
// $STUB_JIRA_GET_RAW replaces the whole `get` output; $STUB_JIRA_FAIL=<verb> makes that verb exit 1. Never live Jira.
const { appendFileSync } = require("node:fs");
const argv = process.argv.slice(2);
if (process.env.STUB_JIRA_LOG) appendFileSync(process.env.STUB_JIRA_LOG, JSON.stringify(argv) + "\n");
// $STUB_JIRA_ENV_LOG: one JSON line per call with the child's project key and a planted secret, to see what environment the child got
if (process.env.STUB_JIRA_ENV_LOG) appendFileSync(process.env.STUB_JIRA_ENV_LOG, JSON.stringify({ verb: argv[0], key: process.env.JIRA_PROJECT_KEY ?? null, secret: process.env.PLANTED_SECRET ?? null }) + "\n");
if (process.env.STUB_JIRA_FAIL === argv[0]) { console.error("stub jira: refused " + argv[0]); process.exit(1); }
if (argv[0] === "get" && process.env.STUB_JIRA_GET_RAW !== undefined) console.log(process.env.STUB_JIRA_GET_RAW);
else if (argv[0] === "get") {
  const labels = (process.env.STUB_JIRA_LABELS || "").split(",").map((l) => l.trim()).filter(Boolean);
  console.log(JSON.stringify({ key: argv[1], fields: { summary: "stub title", description: process.env.STUB_JIRA_DESC || null, labels } }));
}
// `history <KEY> --json`: the changelog, oldest first. $STUB_JIRA_HISTORY_RAW replaces the whole output. By default: two status moves around one Fix Version change.
else if (argv[0] === "history") {
  const at = (created, field, from, to) => ({ created, author: { displayName: "Bot" }, items: [{ field, fromString: from, toString: to }] });
  if (process.env.STUB_JIRA_HISTORY_RAW !== undefined) console.log(process.env.STUB_JIRA_HISTORY_RAW);
  else console.log(JSON.stringify([at("2026-10-27T09:00:00.000+0000", "status", "To Do", "In Progress"), at("2026-10-27T12:00:00.000+0000", "Fix Version", null, "v1.1.3"),
    at("2026-10-28T08:00:00.000+0000", "status", "In Progress", "In Review")]));
}
