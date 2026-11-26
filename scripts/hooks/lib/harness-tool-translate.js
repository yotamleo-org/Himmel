// Maps a Grok or Cursor tool call onto Claude's shape so every guard sees it.
//
// translateToolCall(text) takes the raw hook stdin and returns { text } (the
// payload the guards get) or { refuse: <reason> } (the caller exits 2).
//   - no string tool_name (SessionStart, Stop, unparseable stdin): the text
//     unchanged; the table is never read, so a table fault cannot refuse a
//     non-tool event.
//   - a string tool_name: harness-tool-map.json beside this file is read now.
//     Missing, unreadable, not JSON or the wrong shape refuses, Claude names
//     included, so a deleted table never lets a native call through.
//   - tools[name]: tool_name becomes its claude name, each keys entry renamed
//     when the target key is absent; both keys present with different values
//     refuses, since the guards would judge a value the harness does not use.
//   - <server>__<tool> with <server> in mcp_servers: tool_name becomes
//     mcp__<server>__<tool>, and Grok's use_tool wrapper is unwrapped.
//   - any other name: the original text, byte for byte.
// marketplace/plugins/himmel-guard/hooks/translate-tool-call.sh is the jq copy
// of these rules; test-harness-tool-translation.sh runs both. The runners
// require this module at call time, not at load: install-engine and the CI
// base gates load run-hook-with-bash.js for resolveBash with no lib/ beside it.
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const TABLE = path.join(__dirname, 'harness-tool-map.json');

const isObject = (v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v);
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function validEntry(entry) {
  if (!isObject(entry) || typeof entry.claude !== 'string') return false;
  if (!own(entry, 'keys')) return true;
  return isObject(entry.keys) && Object.values(entry.keys).every((v) => typeof v === 'string');
}

function loadTable() {
  let table;
  try {
    table = JSON.parse(fs.readFileSync(TABLE, 'utf8'));
  } catch (_e) {
    return null;
  }
  if (!isObject(table) || !isObject(table.tools) || !Array.isArray(table.mcp_servers)) return null;
  if (!Object.values(table.tools).every(validEntry)) return null;
  if (!table.mcp_servers.every((s) => typeof s === 'string')) return null;
  return table;
}

function renameKeys(input, keys) {
  let out = input;
  for (const [from, to] of Object.entries(keys || {})) {
    if (!own(out, from)) continue;
    if (own(out, to)) {
      if (JSON.stringify(out[from]) !== JSON.stringify(out[to])) return null;
      continue;
    }
    out = Object.fromEntries(Object.entries(out).map(([k, v]) => [k === from ? to : k, v]));
  }
  return out;
}

function mcpServer(name, servers) {
  if (name.startsWith('mcp__')) return null;
  const at = name.indexOf('__');
  if (at <= 0 || at + 2 >= name.length) return null;
  const server = name.slice(0, at);
  return servers.includes(server) ? server : null;
}

function translateToolCall(text) {
  let payload;
  try {
    payload = JSON.parse(text);
  } catch (_e) {
    return { text };
  }
  if (!isObject(payload) || typeof payload.tool_name !== 'string') return { text };

  const table = loadTable();
  if (!table) {
    return { refuse: `harness tool table ${TABLE} is missing, unreadable or malformed; refusing the tool call` };
  }

  const name = payload.tool_name;
  if (own(table.tools, name)) {
    const entry = table.tools[name];
    payload.tool_name = entry.claude;
    if (isObject(payload.tool_input)) {
      const renamed = renameKeys(payload.tool_input, entry.keys);
      if (renamed === null) return { refuse: `${name} names two different paths under a native key and its Claude key; refusing the tool call` };
      payload.tool_input = renamed;
    }
    return { text: JSON.stringify(payload) };
  }
  if (mcpServer(name, table.mcp_servers) !== null) {
    const ti = payload.tool_input;
    if (isObject(ti) && ti.tool_name === name && isObject(ti.tool_input)) payload.tool_input = ti.tool_input;
    payload.tool_name = `mcp__${name}`;
    return { text: JSON.stringify(payload) };
  }
  return { text };
}

module.exports = { translateToolCall };
