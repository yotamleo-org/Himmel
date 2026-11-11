// What the request gate knows of a ticket: its labels, its priority, and whether it is still open.
export type TicketFacts = { labels: string[]; priority: string; open: boolean };

const HIGH = new Set(['High', 'Highest']);

/** A ticket the operator asked for: labelled operator-directed, or of priority High or Highest. */
export function asksOperator(t: TicketFacts | null): boolean {
  return !!t && (t.labels.includes('operator-directed') || HIGH.has(t.priority));
}

/** Why the ticket is operator work, in the words a refusal prints: "operator-directed", "High", or both. */
export function operatorWorkOf(t: TicketFacts): string {
  return [t.labels.includes('operator-directed') ? 'operator-directed' : null, HIGH.has(t.priority) ? t.priority : null]
    .filter((x) => x !== null).join(' and ');
}
