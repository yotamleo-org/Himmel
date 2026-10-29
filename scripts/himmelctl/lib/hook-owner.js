'use strict';
// hook-owner.js — which settings layer owns a guard hook.
// A himmel checkout's own .claude/settings.json (the project layer) wires the PreToolUse trio,
// so a user-level wire of the same scripts runs each of them twice per call. The installer
// skips the user-level wire, and the probe reads it as present, while the project layer
// carries all of them. Elsewhere the user layer stays the owner (guardrail-block-global
// installs the self-skipping form). Text match on the basename, like guardrail-skip-in-himmel.js.
const fs = require('node:fs');
const path = require('node:path');

const PRETOOLUSE_TRIO = ['auto-approve-safe-bash', 'block-edit-on-main', 'block-read-secrets'];

function projectLayerWiresTrio(repoRoot) {
  if (!repoRoot) return false;
  let text;
  try {
    text = fs.readFileSync(path.join(repoRoot, '.claude', 'settings.json'), 'utf8');
  } catch (_e) {
    return false;
  }
  return PRETOOLUSE_TRIO.every((name) => text.includes(`${name}.sh`));
}

module.exports = { PRETOOLUSE_TRIO, projectLayerWiresTrio };
