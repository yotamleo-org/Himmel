import { Server, type Tool } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { flags, runCli, type CliRunner } from './mcp-cli.js';

/**
 * MCP surface for the himmel jira CLI: a thin compatibility bridge.
 */

export interface ToolDeps {
  runCli?: CliRunner;
}

const defaultDeps: ToolDeps = {};

/** JSON-Schema fragment for a tool's input. */
type JsonSchema = {
  type: 'object';
  properties: NonNullable<Tool['inputSchema']['properties']>;
  required?: string[];
  additionalProperties: false;
};

export interface JiraTool {
  name: string;
  description: string;
  inputSchema: JsonSchema;
  /** The CLI argument array for these arguments. */
  argv: (args: Record<string, unknown>) => string[];
  /** Run the verb through the CLI. Returns what the CLI printed. */
  handler: (args: Record<string, unknown>, deps: ToolDeps) => Promise<string>;
}

const str = (description: string) => ({ type: 'string', description });
const bool = (description: string) => ({ type: 'boolean', description });
const strs = (description: string) => ({ type: 'array', items: { type: 'string' }, description });
const s = (args: Record<string, unknown>, k: string): string => String(args[k]);
const opt = (args: Record<string, unknown>, k: string): string[] => (args[k] === undefined ? [] : [String(args[k])]);

type Def = Omit<JiraTool, 'handler'>;

const RELEASE_SUBS = ['state', 'request', 'claim', 'rule', 'apply', 'lease-acquire', 'lease-release'] as const;

function releaseArgv(a: Record<string, unknown>): string[] {
  const sub = a.sub as string;
  if (!(RELEASE_SUBS as readonly string[]).includes(sub)) throw new Error(`release: sub is one of ${RELEASE_SUBS.join('|')}`);
  if (!a.release) throw new Error(`release ${sub}: release is required`);
  const r = s(a, 'release');
  switch (sub) {
    case 'state':
      return ['release', 'state', r, ...flags(a, { json: '--json', mirrorRoot: '--mirror-root' })];
    case 'request':
      return ['release', 'request', r, ...flags(a, { verb: '--verb', key: '--key', from: '--from', to: '--to', why: '--why', evidence: '--evidence' })];
    case 'claim':
      return ['release', 'claim', r];
    case 'rule':
      return ['release', 'rule', r, ...flags(a, {
        req: '--req', outcome: '--outcome', op: '--op', from: '--from', to: '--to', sector: '--sector', ground: '--ground',
        reason: '--reason', supersedes: '--supersedes', authority: '--authority', ref: '--ref',
      })];
    case 'apply':
      if (!a.ruling) throw new Error('release apply: ruling is required');
      return ['release', 'apply', r, s(a, 'ruling')];
    case 'lease-acquire':
      return ['release', 'lease', 'acquire', r, ...flags(a, { expectEpoch: '--expect-epoch', doc: '--doc', session: '--session' })];
    default:
      return ['release', 'lease', 'release', r];
  }
}

const DEFS: Def[] = [
  {
    name: 'get',
    description: 'Get a Jira issue (with description body by default)',
    inputSchema: {
      type: 'object',
      properties: { key: str('Issue key (e.g. PROJ-1)'), json: bool('Output raw JSON'), short: bool('Suppress the description body (one-line header only)') },
      required: ['key'],
      additionalProperties: false,
    },
    argv: (a) => ['get', s(a, 'key'), ...flags(a, { json: '--json', short: '--short' })],
  },
  {
    name: 'create',
    description:
      'Create a Jira issue through `jira create`: the seven-section body, a home (parent or the standalone label, and a Sector when configured) and a placement (proposedVersion, backlog with proposedVersion backlog and why, fixVersion or gate) are checked by the CLI',
    inputSchema: {
      type: 'object',
      properties: {
        type: str('Issue type: Epic, Story, Task, Bug, Subtask'),
        title: str('Issue summary'),
        desc: str('Description (markdown supported)'),
        descFile: str('Read the markdown description from a file (overrides desc)'),
        adfFile: str('Path to pre-built ADF JSON document (overrides desc)'),
        parent: str('Parent issue key'),
        labels: str('Comma-separated labels to set (e.g. a,b); `standalone` marks a ticket with no parent epic'),
        sector: str('Sector (required for a Task, Story or Bug once JIRA_SECTOR_FIELD is set)'),
        project: str('Project key (default: JIRA_PROJECT_KEY env var)'),
        priority: str('Priority name (e.g. Highest)'),
        fixVersion: str('Place the ticket in this version'),
        proposedVersion: str('Propose a version (label proposed-<v> plus its INTAKE request); `backlog` needs backlog and why'),
        backlog: bool('File to the backlog (needs proposedVersion backlog and why)'),
        why: str('One line: why the ticket waits in the backlog'),
        gate: str('Why this may enter a version (critical, regression, ...)'),
        decision: str('The operator decision that places an operator-directed or High ticket into a version; needs words'),
        words: str('The operator\'s exact words in that decision\'s verbatim file'),
        attach: strs('File path(s) to attach'),
      },
      required: ['type', 'title'],
      additionalProperties: false,
    },
    argv: (a) => ['create', ...flags(a, {
      type: '--type', title: '--title', desc: '--desc', descFile: '--desc-file', adfFile: '--adf-file', parent: '--parent',
      labels: '--labels', sector: '--sector', project: '--project', priority: '--priority', fixVersion: '--fix-version',
      proposedVersion: '--proposed-version', backlog: '--backlog', why: '--why', gate: '--gate', decision: '--decision', words: '--words', attach: '--attach',
    })],
  },
  {
    name: 'list',
    description: 'List Jira issues',
    inputSchema: {
      type: 'object',
      properties: {
        project: str('Project key (default: JIRA_PROJECT_KEY)'),
        type: str('Filter by issue type (Epic, Story, Task, Subtask)'),
        status: str('Comma-separated status filter (default: "To Do,In Progress")'),
        label: str('Filter by a single label (composed into the built JQL)'),
        jql: str('Raw JQL passthrough (overrides project/type/status/label)'),
        limit: str('Max results (default 25)'),
      },
      additionalProperties: false,
    },
    argv: (a) => ['list', ...flags(a, { project: '--project', type: '--type', status: '--status', label: '--label', jql: '--jql', limit: '--limit' })],
  },
  {
    name: 'transition',
    description: 'Transition a Jira issue to a new status through `jira transition` (Done stamps the version, the status is read back)',
    inputSchema: {
      type: 'object',
      properties: {
        key: str('Issue key'),
        status: str('Target status NAME (not ID)'),
        noVersion: bool('Do not stamp the current fixVersion on a versionless Done close'),
      },
      required: ['key', 'status'],
      additionalProperties: false,
    },
    argv: (a) => ['transition', s(a, 'key'), s(a, 'status'), ...flags(a, { noVersion: '--no-version' })],
  },
  {
    name: 'transitions',
    description: 'List available transitions for a Jira issue (id<TAB>name per line)',
    inputSchema: { type: 'object', properties: { key: str('Issue key') }, required: ['key'], additionalProperties: false },
    argv: (a) => ['transitions', s(a, 'key')],
  },
  {
    name: 'comment',
    description: 'Add a comment to a Jira issue (text supports markdown)',
    inputSchema: {
      type: 'object',
      properties: {
        key: str('Issue key'),
        text: str('Comment body (markdown)'),
        adfFile: str('Path to pre-built ADF JSON document (overrides text)'),
        commentFile: str('Read the markdown comment body from a file (overrides text)'),
        attach: strs('File path(s) to attach to the parent issue'),
      },
      required: ['key'],
      additionalProperties: false,
    },
    argv: (a) => {
      if (a.text === undefined && !a.adfFile && !a.commentFile) throw new Error('comment requires text or commentFile or adfFile');
      return ['comment', ...flags(a, { adfFile: '--adf-file', commentFile: '--comment-file', attach: '--attach' }), '--', s(a, 'key'), ...opt(a, 'text')];
    },
  },
  {
    name: 'attach',
    description: 'Upload one or more files as attachments to an existing issue',
    inputSchema: {
      type: 'object',
      properties: { key: str('Issue key'), paths: strs('File path(s) to upload') },
      required: ['key', 'paths'],
      additionalProperties: false,
    },
    argv: (a) => ['attach', '--', s(a, 'key'), ...((a.paths as unknown[]) ?? []).map(String)],
  },
  {
    name: 'edit',
    description: 'Edit a Jira issue through `jira edit` (priority, severity, title, description, parent, labels, sector); the result is checked against the ticket standard and read back',
    inputSchema: {
      type: 'object',
      properties: {
        key: str('Issue key'),
        priority: str('Priority: Highest|High|Medium|Low|Lowest'),
        severity: str('Severity (custom field): free text'),
        title: str('New summary/title (plain text)'),
        desc: str('New description (markdown; converted to ADF). Alias of description.'),
        description: str('New description (markdown; converted to ADF)'),
        descFile: str('Read the markdown description from a file (overrides desc/description)'),
        parent: str('Parent issue key (e.g. epic) — re-parents the issue'),
        labels: str('REPLACE the issue labels with this comma-separated set (full-replace: existing labels not listed are removed)'),
        sector: str('Sector (single-select custom field; unknown option refused)'),
      },
      required: ['key'],
      additionalProperties: false,
    },
    argv: (a) => {
      const b = { ...a, description: a.description ?? (a.descFile === undefined ? a.desc : undefined) };
      return ['edit', s(a, 'key'), ...flags(b, {
        priority: '--priority', severity: '--severity', title: '--title', description: '--description', descFile: '--desc-file',
        parent: '--parent', labels: '--labels', sector: '--sector',
      })];
    },
  },
  {
    name: 'projects',
    description: 'List Jira projects visible to the authenticated user',
    inputSchema: { type: 'object', properties: { limit: str('Max results (default 50)') }, additionalProperties: false },
    argv: (a) => ['projects', ...flags(a, { limit: '--limit' })],
  },
  {
    name: 'project-create',
    description: 'Create a new Jira project (requires admin permissions)',
    inputSchema: {
      type: 'object',
      properties: {
        key: str('Project key (uppercase, 2-10 chars)'),
        name: str('Project display name'),
        type: str('Project type: software, business, service_desk (default software)'),
        template: str('Project template key'),
        lead: str('Lead account ID (defaults to authenticated user)'),
      },
      required: ['key', 'name'],
      additionalProperties: false,
    },
    argv: (a) => ['project-create', ...flags(a, { key: '--key', name: '--name', type: '--type', template: '--template', lead: '--lead' })],
  },
  {
    name: 'roadmap-set',
    description: 'Set roadmap fields on an issue, then recompute ROI (readiness is a declared score)',
    inputSchema: {
      type: 'object',
      properties: {
        key: str('Issue key'),
        readiness: str('Readiness 0-4'),
        theme: str('Legacy Theme option name; refused when HIMMEL_LEGACY_NAMES is off (set the Sector with edit instead)'),
        goals: str('Comma-separated goals: G1..G7, North Star, off, win'),
        impact: str('Impact 1-5'),
        alignment: str('Alignment 0.2-1.0 (default: derived from goals)'),
        effort: str('Effort XS, S, M, L or XL'),
        guard: bool('Non-trivial G1 guard work: effort x1.3'),
        auditDate: str('Audit date YYYY-MM-DD'),
        auditEvidence: str('Audit evidence URL'),
        closeCandidate: str('yes or no'),
        noRoi: bool('Do not recompute ROI'),
      },
      required: ['key'],
      additionalProperties: false,
    },
    argv: (a) => ['roadmap', 'set', s(a, 'key'), ...flags(a, {
      readiness: '--readiness', theme: '--theme', goals: '--goals', impact: '--impact', alignment: '--alignment', effort: '--effort',
      guard: '--guard', auditDate: '--audit-date', auditEvidence: '--audit-evidence', closeCandidate: '--close-candidate', noRoi: '--no-roi',
    })],
  },
  {
    name: 'roadmap-get',
    description: 'Print the roadmap fields of an issue',
    inputSchema: { type: 'object', properties: { key: str('Issue key') }, required: ['key'], additionalProperties: false },
    argv: (a) => ['roadmap', 'get', s(a, 'key')],
  },
  {
    name: 'rank',
    description: 'Rank an issue before or after another issue (board order)',
    inputSchema: {
      type: 'object',
      properties: { key: str('Issue key to move'), before: str('Rank above this issue'), after: str('Rank below this issue') },
      required: ['key'],
      additionalProperties: false,
    },
    argv: (a) => ['rank', s(a, 'key'), ...flags(a, { before: '--before', after: '--after' })],
  },
  {
    name: 'release',
    description: 'Release ledger twin of `jira release <sub>`: state, request, claim, rule, apply, lease-acquire, lease-release. The operator verbs stay CLI-only',
    inputSchema: {
      type: 'object',
      properties: {
        sub: { type: 'string', enum: [...RELEASE_SUBS], description: 'The release sub-verb' },
        release: str('Release name'),
        json: bool('state: print the full state as JSON'),
        mirrorRoot: str('state: Jira mirror directory'),
        verb: str('request: INTAKE | REVERSION | DISCHARGE'),
        key: str('request: issue key'),
        from: str('request, rule: source version, or backlog'),
        to: str('request, rule: target version, or backlog'),
        why: str('request: one line'),
        evidence: { type: 'object', description: 'request: evidence object' },
        req: str('rule: request id'),
        outcome: str('rule: ADMIT | BACKLOG | AD-HOC | MOVE | KEEP | ACCEPT | REJECT'),
        op: str('rule: add | remove | move | keep | discharge | none'),
        sector: str('rule: the ticket sector (required only when a Sector field is configured)'),
        ground: str('rule: the ground of the ruling'),
        reason: str('rule: one-line reason'),
        supersedes: str('rule: comma-separated rulings this replaces'),
        authority: str('rule: rm | operator | import'),
        ref: str('rule: the O- record or import source'),
        ruling: str('apply: ruling id'),
        expectEpoch: { type: 'number', description: 'lease-acquire: the epoch the brief names' },
        doc: str("lease-acquire: this session's absolute handover doc"),
        session: str("lease-acquire: this session's name"),
      },
      required: ['sub', 'release'],
      additionalProperties: false,
    },
    argv: releaseArgv,
  },
];

export function createTools(): JiraTool[] {
  return DEFS.map((d) => ({ ...d, handler: async (args, deps) => runCli(deps.runCli, d.argv(args)) }));
}

export function buildServer(deps: ToolDeps = defaultDeps): Server {
  const tools = createTools();
  const server = new Server({ name: 'jira', version: '1.0.0' }, { capabilities: { tools: {} } });

  server.setRequestHandler('tools/list', async () => ({
    tools: tools.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
  }));

  server.setRequestHandler('tools/call', async (req) => {
    const tool = tools.find((t) => t.name === req.params.name);
    if (!tool) {
      throw new Error(`Unknown tool: ${req.params.name}`);
    }
    try {
      const text = await tool.handler(req.params.arguments ?? {}, deps);
      return { content: [{ type: 'text', text }] };
    } catch (e) {
      return {
        content: [{ type: 'text', text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      };
    }
  });

  return server;
}

/** Boot the MCP server on stdio. Invoked by `jira mcp`. */
export async function runMcpServer(): Promise<void> {
  const server = buildServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
