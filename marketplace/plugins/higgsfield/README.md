# higgsfield

himmel-owned wrapper plugin (HIMMEL-7826) that registers the hosted Higgsfield MCP
server for design workers, so they can generate images and video. The `.mcp.json`
carries the whole plugin: no skills, no hooks. Upstream publishes no repository or
license for a skill, so nothing is vendored.

- Server: `https://mcp.higgsfield.ai/mcp`, HTTP transport, browser OAuth, no API key.
  The URL and "no API key" are from the official page https://higgsfield.ai/mcp
  (fetched 2026-10-27). The HTTP transport and the tool names (`generate_image`,
  `generate_video`, `create_character`, `get_generation_status`, `list_characters`)
  come from third-party guides (techsy.io), not from Higgsfield, so
  `scripts/guardrails/mcp-policy.json` does not enumerate tools.
- Needs a Higgsfield subscription (the operator holds Plus).
- Carried by the `design-imagegen` add-on profile, not the `design` core:
  `--profile design --add-plugins higgsfield@himmel`, or `--profile design-imagegen`.
  Installed disabled at user scope; a profile enables it per session.
- Every prompt, file path and pasted file in a tool call goes to Higgsfield.
  `marketplace/plugins/himmel-ops/hooks/block-agent-native-egress.sh` denies the call
  from a salus session or when the payload names salus (egress-matrix
  `salus x higgsfield x * = hard deny`). There is no bypass.
- One-time OAuth by the operator, by hand: run `/mcp` in a session that has the
  plugin enabled, pick `plugin:higgsfield:higgsfield`, and complete the browser login.
