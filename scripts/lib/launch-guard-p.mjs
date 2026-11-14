#!/usr/bin/env node
// launch-guard-p.mjs - layer P of launch-guard-check.sh: does a himmel project
// settings file carry the full guard hook chain?
//
// Usage: node launch-guard-p.mjs <anchor> <settings-file> [added-hook.sh ...]
//
// Imports rewriteSettingsText from the ANCHOR's trusted wire-hook-bash.mjs
// (never the candidate tree's), reads <settings-file> as data, and passes only
// when it parses and nothing would be rewritten (changed === 0). No lock, no write.
//
// added-hook.sh: scripts/hooks/ names the folder's own branch adds (the caller
// proves each is in the branch diff and executable in the folder). Their wiring
// is taken out of a copy of the settings before the anchor judges it: a hook entry
// naming only added scripts is dropped, and an added member is cut from a --chain.
// Anything else in the file is judged as written.
//
// Exit codes: 0 chain complete | 1 incomplete or unreadable (one line on stderr)
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [anchor, file, ...added] = process.argv.slice(2);
if (!anchor || !file) {
  console.error('usage: launch-guard-p.mjs <anchor> <settings-file> [added-hook.sh ...]');
  process.exit(1);
}

function withoutAddedHooks(text, names) {
  const settings = JSON.parse(text);
  const hooks = settings && settings.hooks;
  if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) return text;
  const addedSet = new Set(names);
  for (const event of Object.keys(hooks)) {
    if (!Array.isArray(hooks[event])) continue;
    hooks[event] = hooks[event].filter((group) => {
      if (!group || !Array.isArray(group.hooks) || group.hooks.length === 0) return true;
      group.hooks = group.hooks.filter((hook) => {
        if (!hook || typeof hook.command !== 'string') return true;
        const used = [...hook.command.matchAll(/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)/g)].map((m) => m[1]);
        if (used.length > 0 && used.every((s) => addedSet.has(s))) return false;
        for (const s of used.filter((u) => addedSet.has(u))) {
          hook.command = hook.command.split(` "$CLAUDE_PROJECT_DIR/scripts/hooks/${s}"`).join('');
        }
        return true;
      });
      return group.hooks.length > 0;
    });
  }
  return JSON.stringify(settings, null, 2);
}

try {
  const mod = await import(pathToFileURL(join(anchor, 'scripts', 'hooks', 'wire-hook-bash.mjs')).href);
  const text = readFileSync(file, 'utf8');
  const res = mod.rewriteSettingsText(added.length > 0 ? withoutAddedHooks(text, added) : text);
  if (res.changed !== 0) {
    console.error(`launch-guard-p: ${res.changed} hook command(s) would be rewritten`);
    process.exit(1);
  }
} catch (e) {
  console.error(`launch-guard-p: ${e && e.message ? e.message : e}`);
  process.exit(1);
}
