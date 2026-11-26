<!-- salus-posture-agy -->
### Posture A update — trusted processors (operator decision 1259)
- This supersedes the processor list in the posture block above: the trusted
  INTERACTIVE processors are Anthropic/Claude **in-session**, Codex, and Google
  Antigravity (`agy`, the Gemini harness, a trusted Google route).
- API-key Gemini (`GEMINI_API_KEY` / `GOOGLE_API_KEY`, the `gemini-subagent` tool,
  hermes) and every untrusted cloud stay DENIED.
- Antigravity hooks come from the user-scope backstop, never a repo-local
  `.agents/hooks.json`; its secret and provider-home read fences apply here too.
