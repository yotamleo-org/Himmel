export type ResidualClass = 'legacy' | 'qualified' | 'idList' | 'nearMiss' | 'prose';
export type ResidualRow = { line: string; context: string[]; cls: ResidualClass };

export const RESIDUAL_CONTEXT = ['- Round 3 (spec critic, SPEC FINDINGS 1; plan critic, PLAN FINDINGS 1)', '  - R3-F27: fixed', '  - P3-P17: fixed'];

export const RESIDUAL_RETURNS = {
  spec: { name: 'HIMMEL-1-shapes.md.critic-spec-r3.md', text: 'Reviewed: spec 0\n\n- **F27** (minor) a finding\n\nSPEC FINDINGS 1\n' },
  plan: { name: 'HIMMEL-1-shapes.md.critic-plan-r3.md', text: 'Reviewed: spec 0\n\n- **P17** (minor) a finding\n\nPLAN FINDINGS 1\n' },
};

const row = (line: string, cls: ResidualClass, context = RESIDUAL_CONTEXT): ResidualRow => ({ line, context, cls });

export const RESIDUAL_ROWS: ResidualRow[] = [
  row('- R2: fixed', 'legacy'),
  row('  - R3-F27: deferred → HIMMEL-1', 'qualified'),
  row('- R3 F27: deferred -> HIMMEL-1', 'qualified'),
  row('- P3-P17: fixed', 'qualified'),
  row('- R1: F1, F2 fixed', 'idList'),
  row('- R3: F27 fixed', 'idList'),
  row('- R1: codex-1, 3, 4 fixed', 'idList'),
  row('- R1-1: fixed', 'nearMiss', ['- R1-F1: fixed']),
  row('- R2-F9: deferred → the chief files', 'nearMiss', ['- R2-F1: fixed']),
  row('- R3-F2x: deferred → later', 'nearMiss'),
  row('- R1 F6: reopened in R2', 'prose'),
  row('  - R2 C4: Design 5;', 'prose'),
  row('- R4: superseded by round 2 R6', 'prose'),
  row('- Round 3 (spec critic, SPEC FINDINGS 1)', 'prose'),
  row('- R 3-F27: fixed', 'prose'),
  row('- advisory codex-5: fixed', 'prose'),
  row('- R2: deferred -> HIMMEL-9', 'prose'),
  row('- R1-1: fixed', 'prose', ['- R3-F1: fixed']),
];
