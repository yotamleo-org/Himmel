// HIMMEL-5491: a stubbed Jira CLI for the write-route tests. Records each argv as one JSON line in $STUB_JIRA_LOG;
// `get` answers with the Labels line in $STUB_JIRA_LABELS; $STUB_JIRA_FAIL=<verb> makes that verb exit 1. Never live Jira.
const { appendFileSync } = require("node:fs");
const argv = process.argv.slice(2);
if (process.env.STUB_JIRA_LOG) appendFileSync(process.env.STUB_JIRA_LOG, JSON.stringify(argv) + "\n");
if (process.env.STUB_JIRA_FAIL === argv[0]) { console.error("stub jira: refused " + argv[0]); process.exit(1); }
if (argv[0] === "get") console.log(`${argv[1]}\tStory\tTo Do\tstub title\n\nLabels: ${process.env.STUB_JIRA_LABELS || ""}\nPriority: Medium`);
