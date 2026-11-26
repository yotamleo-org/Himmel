// Maps a Grok or Cursor tool call onto Claude's shape so every guard sees it.
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
  if (payload.toolInputTruncated === true) {
    return { refuse: `${payload.tool_name}: the harness marked this tool input truncated, so no guard can judge all of it; refusing the tool call` };
  }

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
