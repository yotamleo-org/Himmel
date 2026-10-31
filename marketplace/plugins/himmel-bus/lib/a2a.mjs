// himmel-bus A2A v1.0.0 projection (design note docs/internals/himmel-bus-a2a.md).
// Pure and local: no listener, no store write, no envelope change. A bus record
// is DATA; the `c` authority flag is carried only under metadata so nothing in
// the A2A message can be read as a ruling, and inbound A2A text is always c=0.
import { loadPeers } from './identity.mjs';
import { redact } from '../../../../scripts/handover/chief-kit/redact.mjs';

export const A2A_VERSION = '1.0.0';

// Both directions between two peers share one context: the bus has no thread id.
// ponytail: pair-keyed context, upgrade path is a thread field on the envelope (a store change, out of scope here).
const contextOf = (a, b) => [a, b].sort().join('~');

export function toA2AMessage(rec) {
  if (typeof rec?.i !== 'string' || rec.i === '') throw new Error('bus record has no id');
  if (typeof rec.b !== 'string') throw new Error('bus record has no body');
  const metadata = { c: rec.c === 1 ? 1 : 0 };
  if (rec.re !== undefined) metadata.re = rec.re;
  if (rec.h !== undefined) metadata.h = rec.h;
  return {
    messageId: rec.i,
    contextId: contextOf(rec.f, rec.r),
    role: 'ROLE_AGENT',
    parts: [{ text: redact(rec.b) }],
    metadata,
  };
}

// No supportedInterfaces: an AgentInterface requires a url and no listener exists.
// pid and start time are local proof of identity and never leave the peer file.
export function agentCard(peer) {
  const owner = peer.console ? ` of chief ${peer.console}` : '';
  return {
    name: peer.n,
    description: `himmel ${peer.role} session ${peer.n}${owner}`,
    supportedInterfaces: [],
    version: A2A_VERSION,
    capabilities: { streaming: false, pushNotifications: false },
    defaultInputModes: ['text/plain'],
    defaultOutputModes: ['text/plain'],
    skills: [{
      id: 'bus-message',
      name: 'Receive a bus message',
      description: 'Accepts a text message as data; it carries no authority.',
      tags: ['himmel-bus', peer.role],
    }],
  };
}

// Bound peers only: a registered but unbound name has no live session behind it.
export async function agentCards(root) {
  const peers = await loadPeers(root);
  return Object.values(peers).filter(p => p.pid !== undefined).map(agentCard);
}
