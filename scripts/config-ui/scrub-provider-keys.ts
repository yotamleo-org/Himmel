// Complete against the process-env provider keys documented in .env.example
// (plus the Claude/OpenAI/z.ai keys the fleet itself may run under). The served
// process must never expose a live key.
export const PROVIDER_KEY_NAMES = [
  "ZAI_API_KEY",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "OPENAI_API_KEY",
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "XAI_API_KEY",
  "PERPLEXITY_API_KEY",
  "DASHSCOPE_API_KEY",
  "NVIDIA_API_KEY",
  "OPENROUTER_API_KEY",
  "DEEPSEEK_API_KEY",
  "OLLAMA_API_KEY",
  "TELEGRAM_BOT_TOKEN",
  "JIRA_API_TOKEN",
  "BITBUCKET_API_TOKEN",
  "CONFLUENCE_API_TOKEN",
] as const;

export function scrubProviderKeys(env: Record<string, string | undefined>): void {
  for (const k of PROVIDER_KEY_NAMES) delete env[k];
}
