// Self-heartbeat settings reader (C0p). Reads only the host-selected settings files it is handed and
// reports whether the queue lock's self-heartbeat PostToolUse hook is statically wired in them.
//
// API (ESM, no side effects on import):
//   readSelfHeartbeatEffectiveness({ layers }) -> { state, reason, provenance }
//     layers: ORDERED LOW -> HIGH precedence, each { name, path, sha256? }
//       name:   "user" | "project" | "local" | "generated" | "plugin", in that canonical order
//       path:   absolute path to a settings JSON file (no discovery, no env or home lookup)
//       sha256: optional expected lowercase or uppercase 64-hex digest of the file bytes
//     A missing optional file contributes nothing. A "plugin" entry is classified NON-NATIVE and
//     ignored: it never supplies the hook and never overrides disableAllHooks.
//     state:  "effective" | "ineffective" | "unknown"
//     reason: a reason code, e.g. "native-heartbeat-hook-wired", "no-native-heartbeat-hook",
//             "disable-all-hooks", "layer-malformed-json", "digest-mismatch", "unknown-precedence"
//     provenance: { layers: [{ name, path, status, sha256? }] }
//             status: "absent" | "read" | "ignored-plugin" | the reason code of the failing layer
//   Native hook: a PostToolUse group whose matcher is absent, null, "" or "*" and whose command
//   contains BOTH "queue-lock.sh" and "self-heartbeat" (matched-only groups do not count). A hook whose command
//   names both but is not type "command" or not an emitted command shape is unknown (layer-invalid-field).
//   disableAllHooks: the highest-defined boolean across the layers decides. true -> ineffective.
//   Any malformed, unreadable, invalid or unknown-precedence input -> unknown, never optimistic effective.
//   A static configuration check does NOT prove actual heartbeat delivery; runtime proof comes later.
//
// CLI: one JSON object {layers} on stdin -> one JSON result line on stdout.
//   exit 0 = effective, 1 = ineffective, 3 = unknown (including malformed input).
//   Output carries only state, reason codes, path and digest provenance; never settings content or
//   raw parse errors.

import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const ORDER = ['user', 'project', 'local', 'generated'];
const RANK = new Map(ORDER.map((name, i) => [name, i]));
const NAMES = new Set([...ORDER, 'plugin']);
const MAX_LAYERS = 8;
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_STDIN_BYTES = 64 * 1024;
const HEX64 = /^[0-9a-f]{64}$/i;
const EXIT = { effective: 0, ineffective: 1, unknown: 3 };

class Unknown extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const invalid = () => new Unknown('layer-invalid-field');

// Returns the file bytes, or null when the file is absent. Symlinks are followed; a dangling
// link, a directory or another non-regular file is unreadable and therefore unknown.
function readLayerBytes(path) {
  try {
    lstatSync(path);
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw new Unknown('layer-unreadable');
  }
  let st;
  try {
    st = statSync(path);
  } catch {
    throw new Unknown('layer-unreadable');
  }
  if (!st.isFile()) throw new Unknown('layer-not-regular-file');
  if (st.size > MAX_FILE_BYTES) throw new Unknown('layer-too-large');
  try {
    return readFileSync(path);
  } catch {
    throw new Unknown('layer-unreadable');
  }
}

const PATH_TOKEN = '(?:"(?:[^"`$\\\\\\n]|\\$(?:\\{[A-Za-z_]\\w*\\}|[A-Za-z_]\\w*(?!\\w)))*"|[A-Za-z0-9_./~-]+)';
const pathEnding = (tail) => `${PATH_TOKEN}(?<=(?:^|[\\s"/])${tail}"?)`;
const HB_SCRIPT = pathEnding('queue-lock\\.sh');
const HB_RUN_NODE = pathEnding('run-node\\.sh');
const HB_LAUNCHER = pathEnding('run-hook-with-bash\\.js');
const HB_PLAIN = new RegExp(`^(?:bash )?${HB_SCRIPT} self-heartbeat\\s*$`);
const HB_ROUTED = new RegExp(
  `^if \\[ -f (${HB_RUN_NODE}) \\]; then command -p sh \\1 (${HB_LAUNCHER}) (${HB_SCRIPT}) self-heartbeat; `
  + 'else node \\2 \\3 self-heartbeat; fi\\s*$',
);
const isEmittedHeartbeat = (command) => HB_PLAIN.test(command) || HB_ROUTED.test(command);

// Parses one layer and extracts only the consumed fields: disableAllHooks and the PostToolUse groups.
// Every other property is ignored. Any consumed field of the wrong type is unknown.
function parseLayer(text) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    throw new Unknown('layer-malformed-json');
  }
  if (!isObj(doc)) throw invalid();
  let disable;
  if ('disableAllHooks' in doc) {
    if (typeof doc.disableAllHooks !== 'boolean') throw invalid();
    disable = doc.disableAllHooks;
  }
  let native = false;
  if (doc.hooks !== undefined) {
    if (!isObj(doc.hooks)) throw invalid();
    const groups = doc.hooks.PostToolUse;
    if (groups !== undefined) {
      if (!Array.isArray(groups)) throw invalid();
      for (const group of groups) {
        if (!isObj(group)) throw invalid();
        const m = group.matcher;
        if (m !== undefined && m !== null && typeof m !== 'string') throw invalid();
        if (group.hooks !== undefined && !Array.isArray(group.hooks)) throw invalid();
        const matchesAll = m === undefined || m === null || m === '' || m === '*';
        for (const hook of group.hooks ?? []) {
          if (!isObj(hook)) throw invalid();
          if (hook.command !== undefined && typeof hook.command !== 'string') throw invalid();
          const c = hook.command;
          if (matchesAll && typeof c === 'string' && c.includes('queue-lock.sh') && c.includes('self-heartbeat')) {
            if (hook.type !== 'command' || !isEmittedHeartbeat(c)) throw invalid();
            native = true;
          }
        }
      }
    }
  }
  return { disable, native };
}

export function readSelfHeartbeatEffectiveness(input = {}) {
  const layers = isObj(input) ? input.layers : undefined;
  const provenance = { layers: [] };
  const result = (state, reason) => ({ state, reason, provenance });
  const docs = [];
  let current = null;
  try {
    if (!Array.isArray(layers) || layers.length > MAX_LAYERS) throw new Unknown('layers-invalid');
    let lastRank = -1;
    for (const layer of layers) {
      current = {
        name: isObj(layer) && NAMES.has(layer.name) ? layer.name : null,
        path: isObj(layer) && typeof layer.path === 'string' ? layer.path : null,
      };
      if (!isObj(layer)) throw invalid();
      if (typeof layer.path !== 'string' || !isAbsolute(layer.path)) throw new Unknown('layer-path-not-absolute');
      if (layer.name === 'plugin') {
        provenance.layers.push({ name: 'plugin', path: layer.path, status: 'ignored-plugin' });
        continue;
      }
      if (!RANK.has(layer.name)) throw new Unknown('unknown-precedence');
      const rank = RANK.get(layer.name);
      if (rank <= lastRank) throw new Unknown('unknown-precedence');
      lastRank = rank;
      if (layer.sha256 !== undefined && (typeof layer.sha256 !== 'string' || !HEX64.test(layer.sha256))) {
        throw new Unknown('digest-malformed');
      }
      const bytes = readLayerBytes(layer.path);
      if (bytes === null) {
        if (layer.sha256 !== undefined) throw new Unknown('digest-file-absent');
        provenance.layers.push({ name: layer.name, path: layer.path, status: 'absent' });
        continue;
      }
      const sha256 = createHash('sha256').update(bytes).digest('hex');
      if (layer.sha256 !== undefined && sha256 !== layer.sha256.toLowerCase()) throw new Unknown('digest-mismatch');
      docs.push(parseLayer(bytes.toString('utf8')));
      provenance.layers.push({ name: layer.name, path: layer.path, status: 'read', sha256 });
    }
  } catch (e) {
    const reason = e instanceof Unknown ? e.reason : 'internal-error';
    if (current) provenance.layers.push({ ...current, status: reason });
    return result('unknown', reason);
  }
  // Highest-defined disableAllHooks wins: docs are ordered low -> high, so search from the top.
  const defined = docs.findLast((d) => d.disable !== undefined);
  if (defined && defined.disable === true) return result('ineffective', 'disable-all-hooks');
  if (docs.some((d) => d.native)) return result('effective', 'native-heartbeat-hook-wired');
  return result('ineffective', 'no-native-heartbeat-hook');
}

async function readStdin() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_STDIN_BYTES) return null;
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function main() {
  const text = await readStdin();
  const unknownOut = (reason) => ({ state: 'unknown', reason, provenance: { layers: [] } });
  let out;
  if (text === null) {
    out = unknownOut('input-too-large');
  } else {
    let input;
    try {
      input = JSON.parse(text);
    } catch {
      out = unknownOut('input-malformed');
    }
    if (!out) out = readSelfHeartbeatEffectiveness(isObj(input) ? input : {});
  }
  process.stdout.write(`${JSON.stringify(out)}\n`);
  process.exitCode = EXIT[out.state];
}

let isMain = false;
try {
  isMain = !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
} catch {
  // An importer may have no filesystem entry point, such as node --eval.
}
if (isMain) {
  await main();
}
