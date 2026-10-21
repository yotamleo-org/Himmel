// Record shapes of the release engine (design §3, §5). Every row on disk is
// signed (mac) and every *.jsonl row also carries prev, the sha256 of the
// previous raw line.

export type OpKind = 'add' | 'remove' | 'move' | 'keep' | 'discharge' | 'none';
export type Phase = 'intent' | 'applied' | 'receipted' | 'void';
export type Verb = 'INTAKE' | 'REVERSION' | 'DISCHARGE';
export type PlacementClass = 'current' | 'next' | 'backlog';

export interface Op {
  kind: OpKind;
  from_v: string | null;
  to_v: string | null;
}

export interface Declaration {
  project: string;
  release: string;
  versions: string[];
  current: string;
  mode: 'observe' | 'live';
  decision: string;
  ts: string;
}

export interface Baseline {
  release: string;
  version: string;
  gen: number;
  keys: string[];
  decision: string;
  ts: string;
}

export interface Authority {
  kind: 'rm' | 'operator' | 'import';
  ref: string | null;
}

export interface RulingRow {
  id: string;
  epoch: number;
  req: string;
  ts: string;
  verb: Verb;
  key: string;
  op: Op;
  outcome: string;
  class: PlacementClass;
  sector: string;
  ground: string;
  reason: string;
  supersedes: string[];
  authority: Authority;
  phase: Phase;
  readback?: string;
  comment_id?: string;
  prev?: string;
  mac?: string;
}

export type OperatorKind = 'declare' | 'freeze' | 'decision' | 'takeover' | 'emergency';

export interface OperatorRow {
  id: string;
  kind: OperatorKind;
  ts: string;
  decision: string | null;
  keys?: string[];
  op?: string;
  from_v?: string | null;
  to_v?: string | null;
  verbatim?: string;
  file?: string;
  sha?: string;
  epoch?: number;
  doc?: string;
  prev?: string;
  mac?: string;
}

export interface RequestRow {
  req: string;
  ts: string;
  from: string;
  verb: Verb;
  key: string;
  from_v: string | null;
  to_v: string | null;
  why: string;
  evidence: unknown;
  state: string;
  prev?: string;
  mac?: string;
}

export type EventKind = 'ruled' | 'fold' | 'reopen' | 'out-of-band' | 'emergency';

export interface EventRow {
  ts: string;
  kind: EventKind;
  key: string;
  from: string | null;
  to: string | null;
  ruling?: string;
  pr?: number;
  sha?: string;
  readback?: 'ok' | 'mismatch';
  prev?: string;
  mac?: string;
}

export interface Lease {
  release: string;
  epoch: number;
  owner_session: string | null;
  owner_doc: string | null;
  acquired: string | null;
  released: boolean;
  prev_epoch: number | null;
  mac?: string;
}

export interface IssueSnap {
  key: string;
  status: string;
  type: string;
  priority: string;
  fixVersions: string[];
  resolution: string | null;
}
