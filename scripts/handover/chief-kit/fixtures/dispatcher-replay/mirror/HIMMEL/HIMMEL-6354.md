---
key: "HIMMEL-6354"
type: "Bug"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T16:36:30.412+0200"
updated: "2026-10-19T16:16:02.156+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6354: gcp-net.sh proxy allowlist lists Ubuntu mirrors for a Debian 12 image, Squid install fails under deny policy

## Description

scripts/ci/gcp-net.sh:77: the proxy uses a Debian 12 image, but its egress allowlist contains Ubuntu package mirrors and no Debian mirrors. Once the deny policy is attached, the startup apt-get cannot install Squid. Found by the critic panel (codex-1, Important) during the PR 3076 review; the code i
- Cover the choice with a row in scripts/ci/test-gcp-net.sh.
- scripts/ci/test-gcp-net.sh has a row that fails without the fix.
Premise disproved. PROXY_HOSTS is squid's allowlist for runner traffic only; the proxy VM's own startup apt-get does not go through squid. It leaves via firewall rule 1015 (PRIO_PROXY_OUT, scripts/ci/gcp-net.sh:246-248): src proxy IP /32, tcp:80,443, dest 0.0.0.0/0, priority 1015, above the deny-all
Resolution: no allowlist change. scripts/ci/test-gcp-net.sh gains a row pinning rule 1015 (EGRESS, proxy /32, tcp:80/443, 0.0.0.0/0, outranks the deny-all egress); it fails when the rule's world destination is dropped and passes on the current script. Console closes the ticket as not-a-bug after mer
