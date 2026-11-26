import { assertAdmissionsWritable, type AdmissionInput } from './admissions-ledger.js';
import { fetchVersions } from './versions.js';

export const INTAKE_GATES = 'critical|regression|must:<decision-ref>|receipt';

/** The `frozen: <date>` line of a version description; absent means the version takes intakes as before. */
export function frozenDate(description: string | undefined): string | undefined {
  return /^[ \t]*frozen:[ \t]*(\S+)[ \t]*\r?$/m.exec(description ?? '')?.[1];
}

export function assertIntakeGate(gate: string): void {
  const valid = gate === 'critical' || gate === 'regression' || gate === 'receipt' || /^must:\S/.test(gate);
  if (!valid) throw new Error(`--gate must be one of ${INTAKE_GATES} (got "${gate}")`);
}

/** The value of --chief-override; the old --console-override is an unknown option. */
export function chiefOverrideOf<T>(o: { chiefOverride?: T }): T | undefined {
  return o.chiefOverride;
}

/**
 * A chief override needs a reason, the chief marker and a ledger location.
 * Returns the trimmed reason; the ledger probe throws when no location is set
 * or the ledger cannot take an append, so no ticket is filed or moved without its row.
 */
export function checkConsoleOverride(reason: string): string {
  const trimmed = reason.trim();
  if (!trimmed) throw new Error('--chief-override needs a reason');
  if (process.env['HIMMEL_CONSOLE'] !== '1') {
    throw new Error('--chief-override is for the console session only (HIMMEL_CONSOLE=1 is not set)');
  }
  assertAdmissionsWritable();
  return trimmed;
}

/**
 * Holds a filing into a frozen version to --gate. Returns the ledger row to
 * append once the ticket exists, or undefined when no gate applies: no frozen
 * version, a chief override (which writes its own row), or a filing the rules
 * placed (`rules`): placeByRules already ruled on the freeze, and its filed row is the record.
 */
export async function checkIntakeGate(
  project: string,
  fixVersions: unknown,
  o: { gate?: string; override: boolean; rules?: boolean },
): Promise<Pick<AdmissionInput, 'version' | 'gate'> | undefined> {
  const targets = ((fixVersions ?? []) as { name: string }[]).map((v) => v.name);
  if (targets.length === 0) return undefined;
  const known = await fetchVersions(project);
  for (const version of targets) {
    const date = frozenDate(known.find((v) => v.name === version)?.description);
    if (date === undefined || o.override || o.rules) continue;
    if (o.gate === undefined) {
      throw new Error(`${version} is frozen (${date}): file with --proposed-version <v>, the version the operator named, or ${version} when the operator named none; the door places it (--gate ${INTAKE_GATES} still files into ${version} directly)`);
    }
    assertAdmissionsWritable();
    return { version, gate: o.gate };
  }
  return undefined;
}
