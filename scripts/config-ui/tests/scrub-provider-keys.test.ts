import { test, expect } from "bun:test";
import { scrubProviderKeys, PROVIDER_KEY_NAMES } from "../scrub-provider-keys";

test("scrubProviderKeys removes every known provider key from the env map", () => {
  const env: Record<string, string> = { ZAI_API_KEY: "x", PATH: "/usr/bin", ANTHROPIC_API_KEY: "y" };
  scrubProviderKeys(env);
  for (const k of PROVIDER_KEY_NAMES) expect(env[k]).toBeUndefined();
  expect(env.PATH).toBe("/usr/bin");
});

test("scrub removes each newly-covered provider key including xai/perplexity/dashscope/nvidia/openrouter/deepseek (finding 7)", () => {
  const env: Record<string, string | undefined> = {};
  for (const k of PROVIDER_KEY_NAMES) env[k] = "secret";
  env.PATH = "/usr/bin";
  scrubProviderKeys(env);
  for (const k of PROVIDER_KEY_NAMES) expect(env[k]).toBeUndefined();
  for (const k of ["XAI_API_KEY", "PERPLEXITY_API_KEY", "DASHSCOPE_API_KEY", "NVIDIA_API_KEY", "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY"]) {
    expect(PROVIDER_KEY_NAMES).toContain(k as any);
  }
  expect(env.PATH).toBe("/usr/bin");
});
