import { assertAdmissionsWritable, type AdmissionInput } from './admissions-ledger.js';
import { fetchVersions } from './versions.js';

export const INTAKE_GATES = 'critical|regression|must:<decision-ref>|receipt';

/** The `frozen: <date>` line of a version description; absent means the version takes intakes as before. */
export function frozenDate(description: string | undefined): string | undefined {
  return /^[ \t]*frozen:[ \t]*(\S+)[ \t]*\r?$/m.exec(description ?? '')?.[1];
}

// ponytail: the gate reason is recorded in the ledger, not verified against a decision or receipt, upgrade path: the RM signed-row design (HIMMEL-6796)
export function assertIntakeGate(gate: string): void {
  const valid = gate === 'critical' || gate === 'regression' || gate === 'receipt' || /^must:\S/.test(gate);
  if (!valid) throw new Error(`--gate must be one of ${INTAKE_GATES} (got "${gate}")`);
}

/**
 * Holds a filing into a frozen version to --gate. Returns the ledger row to
 * append once the ticket exists, or undefined when no gate applies: no frozen
 * version, or a console override (which writes its own row).
 */
export async function checkIntakeGate(
  project: string,
  fixVersions: unknown,
  o: { gate?: string; override: boolean },
): Promise<Pick<AdmissionInput, 'version' | 'gate'> | undefined> {
  const targets = ((fixVersions ?? []) as { name: string }[]).map((v) => v.name);
  if (targets.length === 0) return undefined;
  const known = await fetchVersions(project);
  for (const version of targets) {
    const date = frozenDate(known.find((v) => v.name === version)?.description);
    if (date === undefined || o.override) continue;
    if (o.gate === undefined) {
      throw new Error(`${version} is frozen (${date}): pass --gate ${INTAKE_GATES} to file into it, or file into a later version`);
    }
    assertAdmissionsWritable();
    return { version, gate: o.gate };
  }
  return undefined;
}
