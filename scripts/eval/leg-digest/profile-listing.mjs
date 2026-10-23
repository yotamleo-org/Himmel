// Unbilled estimate of the Skill listing each launch profile pays per session, {profile: {Skill: tokens}}.
// Same method as the per-profile tool evals table: scan the installed plugin skills (characters over 4, uncapped;
// the live listing is capped by the listing budget) and sum them over the plugins a profile enables.
// Never spawns claude. MCP tool schemas have no source yet, so MCP tools carry no cost.
import { join } from 'node:path';
import { homedir } from 'node:os';
import { loadRegistry, resolveProfile, validateRegistry, PROFILE_ALIASES } from '../../lanes/plugin-profiles.mjs';
import { scanSkillCosts, pluginCacheOf } from '../../lanes/skill-cost.mjs';

export const LISTING_TOOL = 'Skill';
const TTL_MS = 10 * 60 * 1000;
const memo = new Map();

// plugin name -> estimated listing tokens. Several cached versions of one plugin count once per skill: the largest wins.
function tokensByPlugin(configDir) {
  const largest = new Map();
  for (const e of scanSkillCosts({ configDir, cwd: configDir }).entries) {
    if (e.scope !== 'plugin-skills') continue;
    const plugin = pluginCacheOf(e.path)?.plugin;
    if (!plugin) continue;
    const skills = largest.get(plugin) ?? new Map();
    skills.set(e.name, Math.max(skills.get(e.name) ?? 0, e.chars));
    largest.set(plugin, skills);
  }
  return new Map([...largest].map(([plugin, skills]) => [plugin, [...skills.values()].reduce((n, chars) => n + Math.ceil(chars / 4), 0)]));
}

export function estimateProfileListing({ configDir = join(homedir(), '.claude'), now = Date.now() } = {}) {
  const hit = memo.get(configDir);
  if (hit && now - hit.at < TTL_MS) return hit.listing;
  const listing = {};
  try {
    const registry = loadRegistry();
    if (validateRegistry(registry).length) throw new Error('registry invalid');
    const perPlugin = tokensByPlugin(configDir);
    for (const name of Object.keys(registry.profiles ?? {})) {
      const resolved = resolveProfile(registry, name);
      if (!resolved) continue; // operator injects nothing, so it has no profile-specific listing
      const tokens = Object.entries(resolved.enabledPlugins).filter(([, on]) => on).reduce((n, [id]) => n + (perPlugin.get(id.split('@')[0]) ?? 0), 0);
      if (tokens > 0) listing[name] = { [LISTING_TOOL]: tokens };
    }
    for (const [alias, name] of Object.entries(PROFILE_ALIASES)) if (listing[name]) listing[alias] = listing[name];
  } catch { /* registry or plugin cache unreadable: no estimate, the page reads "not measured" */ }
  memo.set(configDir, { at: now, listing });
  return listing;
}
