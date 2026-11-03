#!/usr/bin/env node
// launch-guard-p.mjs - layer P of launch-guard-check.sh: does a himmel project
// settings file carry the full guard hook chain?
//
// Usage: node launch-guard-p.mjs <anchor> <settings-file>
//
// Imports rewriteSettingsText from the ANCHOR's trusted wire-hook-bash.mjs
// (never the candidate tree's), reads <settings-file> as data, and passes only
// when it parses and nothing would be rewritten (changed === 0). No lock, no write.
//
// Exit codes: 0 chain complete | 1 incomplete or unreadable (one line on stderr)
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [anchor, file] = process.argv.slice(2);
if (!anchor || !file) {
  console.error('usage: launch-guard-p.mjs <anchor> <settings-file>');
  process.exit(1);
}
try {
  const mod = await import(pathToFileURL(join(anchor, 'scripts', 'hooks', 'wire-hook-bash.mjs')).href);
  const res = mod.rewriteSettingsText(readFileSync(file, 'utf8'));
  if (res.changed !== 0) {
    console.error(`launch-guard-p: ${res.changed} hook command(s) would be rewritten`);
    process.exit(1);
  }
} catch (e) {
  console.error(`launch-guard-p: ${e && e.message ? e.message : e}`);
  process.exit(1);
}
