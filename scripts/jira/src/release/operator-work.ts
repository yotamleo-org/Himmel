export type TicketFacts = { labels: string[]; priority: string; open: boolean };

const HIGH = new Set(['High', 'Highest']);

export const isSerious = (priority: string): boolean => HIGH.has(priority);

export function operatorAsk(t: TicketFacts & { evidence?: unknown }): boolean {
  const e = (t.evidence && typeof t.evidence === 'object' ? t.evidence : {}) as { filed_by?: unknown; operator_update?: unknown };
  return t.labels.includes('operator-directed') || (e.filed_by === 'bridge' && !!e.operator_update);
}

export function asksOperator(t: TicketFacts | null): boolean {
  return !!t && (operatorAsk(t) || isSerious(t.priority));
}

export function operatorWorkOf(t: TicketFacts): string {
  return [t.labels.includes('operator-directed') ? 'operator-directed' : null, HIGH.has(t.priority) ? t.priority : null]
    .filter((x) => x !== null).join(' and ');
}
