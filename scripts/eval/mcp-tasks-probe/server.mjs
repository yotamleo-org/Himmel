// Probe MCP server: which Claude launch modes get MCP tasks and elicitation.
// Zero-dep JSON-RPC over newline-delimited stdio (spec 2025-11-25), so it runs on a bare
// test VM. Two tools: probe_task (execution.taskSupport optional) and probe_elicit (sends
// elicitation/create). Every observation goes to the JSONL file in MCP_PROBE_LOG, which
// probe.sh summarize turns into one row per launch mode.
// MCP_PROBE_ELICIT_TIMEOUT_MS: how long an unanswered elicitation is left before it is
// recorded as parked (default 20000).
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';

const LOG = process.env.MCP_PROBE_LOG;
if (!LOG) { process.stderr.write('server.mjs: MCP_PROBE_LOG is required\n'); process.exit(2); }
const ELICIT_TIMEOUT_MS = Number(process.env.MCP_PROBE_ELICIT_TIMEOUT_MS ?? 20000);

const log = (ev, data = {}) => appendFileSync(LOG, JSON.stringify({ ev, ts: new Date().toISOString(), ...data }) + '\n');
const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n');

const TOOLS = [
  { name: 'probe_task', description: 'Probe: a tool that may run as an MCP task.', inputSchema: { type: 'object', properties: {} }, execution: { taskSupport: 'optional' } },
  { name: 'probe_elicit', description: 'Probe: a tool that asks the user a question through MCP elicitation.', inputSchema: { type: 'object', properties: {} } },
];

let clientCaps = {};
let pending = 0;
let stdinClosed = false;
const tasks = new Map();
const waiters = new Map(); // elicitation request id -> resolver
let elicitSeq = 0;

const text = (t) => ({ content: [{ type: 'text', text: t }] });
const maybeExit = () => { if (stdinClosed && pending === 0) process.exit(0); };

const TASKS_EXT = 'io.modelcontextprotocol/tasks';
const hasTasksExt = (caps) => caps?.extensions?.[TASKS_EXT] !== undefined;

function createTask(ttl, ext) {
  const taskId = `probe-task-${tasks.size + 1}`;
  const now = new Date().toISOString();
  const task = { taskId, status: 'working', createdAt: now, lastUpdatedAt: now, ttl: ttl ?? 60000, pollInterval: 200, ext: ext || undefined };
  tasks.set(taskId, task);
  pending++;
  setTimeout(() => {
    if (task.status === 'working') { task.status = 'completed'; task.lastUpdatedAt = new Date().toISOString(); }
    pending--; maybeExit();
  }, 200);
  return task;
}

async function elicit() {
  if (!clientCaps.elicitation) { log('elicit_unavailable'); return text('elicit=not-offered'); }
  const id = `probe-elicit-${++elicitSeq}`;
  const started = Date.now();
  log('elicit_sent', { id });
  send({ id, method: 'elicitation/create', params: { mode: 'form', message: 'HIMMEL-7304 probe: any answer is fine.', requestedSchema: { type: 'object', properties: { ok: { type: 'boolean' } } } } });
  const reply = await new Promise((resolve) => {
    const timer = setTimeout(() => { waiters.delete(id); resolve(null); }, ELICIT_TIMEOUT_MS);
    waiters.set(id, (r) => { clearTimeout(timer); resolve(r); });
  });
  const ms = Date.now() - started;
  if (reply === null) { log('elicit_timeout', { id, ms }); return text('elicit=parked'); }
  const action = reply.result?.action ?? (reply.error ? 'error' : 'unknown');
  log('elicit_result', { id, action, ms, error: reply.error?.message });
  return text(`elicit=${action}`);
}

async function handle(m) {
  if (m.method === 'initialize') {
    clientCaps = m.params?.capabilities ?? {};
    log('initialize', { client: m.params?.clientInfo, protocol: m.params?.protocolVersion, caps: clientCaps });
    return send({ id: m.id, result: {
      protocolVersion: m.params?.protocolVersion ?? '2025-11-25',
      capabilities: { tools: {}, tasks: { list: {}, cancel: {}, requests: { tools: { call: {} } } }, extensions: { [TASKS_EXT]: {} } },
      serverInfo: { name: 'probe', version: '0.0.1' },
    } });
  }
  if (m.method === 'tools/list') return send({ id: m.id, result: { tools: TOOLS } });
  if (m.method === 'tools/call') {
    const name = m.params?.name;
    const augmented = m.params?.task !== undefined;
    const ext = hasTasksExt(clientCaps) || hasTasksExt(m.params?._meta?.['io.modelcontextprotocol/clientCapabilities']);
    log('call', { tool: name, task: augmented || ext, shape: augmented ? 'core' : ext ? 'extension' : 'none' });
    if (name === 'probe_task') {
      if (augmented) return send({ id: m.id, result: { task: createTask(m.params.task.ttl, false) } });
      if (ext) {
        const t = createTask(undefined, true);
        return send({ id: m.id, result: { resultType: 'task', taskId: t.taskId, status: t.status, createdAt: t.createdAt, lastUpdatedAt: t.lastUpdatedAt, ttlMs: t.ttl, pollIntervalMs: t.pollInterval } });
      }
      return send({ id: m.id, result: text('task=no') });
    }
    if (name === 'probe_elicit') return send({ id: m.id, result: await elicit() });
    return send({ id: m.id, error: { code: -32602, message: `unknown tool ${name}` } });
  }
  if (m.method === 'tasks/get' || m.method === 'tasks/result' || m.method === 'tasks/cancel') {
    log(m.method.replace('/', '_'), { taskId: m.params?.taskId });
    const task = tasks.get(m.params?.taskId);
    if (!task) return send({ id: m.id, error: { code: -32602, message: 'Failed to retrieve task: Task not found' } });
    if (task.ext && m.method === 'tasks/get') {
      const base = { resultType: 'complete', taskId: task.taskId, status: task.status, createdAt: task.createdAt, lastUpdatedAt: task.lastUpdatedAt, ttlMs: task.ttl, pollIntervalMs: task.pollInterval };
      return send({ id: m.id, result: task.status === 'completed' ? { ...base, result: text('task=yes') } : base });
    }
    if (m.method === 'tasks/result') return send({ id: m.id, result: { ...text('task=yes'), _meta: { 'io.modelcontextprotocol/related-task': { taskId: task.taskId } } } });
    if (m.method === 'tasks/cancel') { task.status = 'cancelled'; task.lastUpdatedAt = new Date().toISOString(); }
    return send({ id: m.id, result: task });
  }
  if (m.method === 'tasks/list') return send({ id: m.id, result: { tasks: [...tasks.values()] } });
  return send({ id: m.id, error: { code: -32601, message: 'method not found' } });
}

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.method === undefined) { // a response to one of our requests
    const w = waiters.get(m.id);
    if (w) { waiters.delete(m.id); w(m); }
    return;
  }
  if (m.id === undefined) { log('notification', { method: m.method }); return; }
  pending++;
  handle(m).catch((e) => send({ id: m.id, error: { code: -32603, message: String(e) } })).finally(() => { pending--; maybeExit(); });
});
rl.on('close', () => { stdinClosed = true; maybeExit(); });
