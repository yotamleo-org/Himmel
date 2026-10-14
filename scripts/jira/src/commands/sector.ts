// The planning model's single-select "Sector" custom field.
export const SECTOR_FIELD = 'customfield_10212';

export const SECTORS = [
  'Fleet orchestration',
  'Ship loop',
  'Safety & enforcement',
  'Cost & efficiency',
  'Visibility',
  'Quality & proof',
  'Deployment',
  'Knowledge & steering',
  'Planning & tracking',
] as const;

// Case-insensitive match to the canonical option label; an unknown option is
// refused here so a typo never reaches Jira (which would answer a bare 400).
export function resolveSector(name: string): string {
  const want = name.trim().toLowerCase();
  const hit = SECTORS.find((s) => s.toLowerCase() === want);
  if (!hit) {
    throw new Error(`Unknown sector '${name}'. Valid sectors: ${SECTORS.join(', ')}`);
  }
  return hit;
}

export function sectorOf(fields: Record<string, unknown> | undefined): string | undefined {
  return (fields?.[SECTOR_FIELD] as { value?: string } | null | undefined)?.value;
}
