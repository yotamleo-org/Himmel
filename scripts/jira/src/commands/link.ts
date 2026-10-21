import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

interface IssueLinkType {
  name: string;
  inward?: string;
  outward?: string;
}

interface IssueLink {
  id: string;
  type: {
    name: string;
    inward: string;
    outward: string;
  };
  inwardIssue?: { key: string };
  outwardIssue?: { key: string };
}

interface IssueLinksResponse {
  fields: {
    issuelinks?: IssueLink[];
  };
}

type RequestFn = (
  method: string,
  path: string,
  body?: unknown,
) => Promise<unknown>;

interface DirectedIssueLink {
  link: IssueLink;
  inwardKey: string;
  outwardKey: string;
  currentSide: 'inward' | 'outward';
}

/**
 * Case-insensitive match of a requested link-type name against the available
 * Jira issue-link types. Mirrors findTransition() — keeps the I/O out of the
 * matcher so it's unit-testable.
 */
export function findLinkType(
  types: IssueLinkType[],
  name: string,
): IssueLinkType | undefined {
  return types.find((t) => t.name.toLowerCase() === name.toLowerCase());
}

/**
 * Create the link and return the relationship as Jira STORES it. Jira's POST
 * takes the inward issue as the SOURCE of the link: it reads with the type's
 * outward text ("HIM-1 blocks HIM-2") and the outward issue with the inward
 * text ("HIM-2 is blocked by HIM-1"), which is what `links` shows afterwards.
 * inwardKey/outwardKey map directly to Jira's inwardIssue/outwardIssue.
 */
export async function createIssueLink(
  inwardKey: string,
  outwardKey: string,
  type: IssueLinkType,
  requestFn: RequestFn = request,
): Promise<string> {
  await requestFn('POST', '/issueLink', {
    type: { name: type.name },
    inwardIssue: { key: inwardKey },
    outwardIssue: { key: outwardKey },
  });
  return `Linked: ${inwardKey} ${type.outward ?? type.name} ${outwardKey}`;
}

// A 2xx POST does not prove the link exists (Jira can accept and drop it), so
// read the inward issue back and fail loud when the pair is not there.
export async function verifyIssueLink(
  inwardKey: string,
  outwardKey: string,
  type: IssueLinkType,
  requestFn: RequestFn = request,
): Promise<void> {
  const issue = await requestFn('GET', `/issue/${inwardKey}?fields=issuelinks`) as IssueLinksResponse;
  const found = (issue.fields.issuelinks ?? []).some(
    (link) =>
      link.type.name.toLowerCase() === type.name.toLowerCase() &&
      link.outwardIssue !== undefined &&
      sameIssueKey(link.outwardIssue.key, outwardKey),
  );
  if (!found) {
    throw new Error(
      `Link ${inwardKey}: the ${type.name} link was not changed — requested inward=${inwardKey}, ` +
        `outward=${outwardKey} but the issue still shows no such link after the POST.`,
    );
  }
}

// A GET entry names the OTHER issue: `outwardIssue` means this issue reads with
// the type's outward text ("this blocks that") and is the inward (source) issue
// of the POST that made it; `inwardIssue` means this issue reads with the
// inward text ("this is blocked by that").
function directedIssueLink(
  currentKey: string,
  link: IssueLink,
): DirectedIssueLink | undefined {
  if (link.outwardIssue) {
    return {
      link,
      inwardKey: currentKey,
      outwardKey: link.outwardIssue.key,
      currentSide: 'inward',
    };
  }
  if (link.inwardIssue) {
    return {
      link,
      inwardKey: link.inwardIssue.key,
      outwardKey: currentKey,
      currentSide: 'outward',
    };
  }
  return undefined;
}

function formatDirectedIssueLink(currentKey: string, candidate: DirectedIssueLink): string {
  const { link, inwardKey, outwardKey, currentSide } = candidate;
  const otherKey = currentSide === 'inward' ? outwardKey : inwardKey;
  const relation = currentSide === 'inward' ? link.type.outward : link.type.inward;
  return `${link.id}\t${link.type.name}\tinward=${inwardKey}\toutward=${outwardKey}\t${currentKey} ${relation} ${otherKey}`;
}

export function formatIssueLinks(currentKey: string, links: IssueLink[]): string {
  const candidates = links
    .map((link) => directedIssueLink(currentKey, link))
    .filter((link): link is DirectedIssueLink => link !== undefined);
  if (!candidates.length) return `${currentKey}: no issue links`;
  return candidates
    .map((candidate) => formatDirectedIssueLink(currentKey, candidate))
    .join('\n');
}

function sameIssueKey(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function resolveIssueLink(
  links: IssueLink[],
  inwardKey: string,
  outwardKey: string,
  type?: string,
): DirectedIssueLink {
  const matches = links
    .map((link) => directedIssueLink(inwardKey, link))
    .filter((link): link is DirectedIssueLink => link !== undefined)
    .filter((candidate) =>
      sameIssueKey(candidate.inwardKey, inwardKey) &&
      sameIssueKey(candidate.outwardKey, outwardKey) &&
      (type === undefined || candidate.link.type.name.toLowerCase() === type.toLowerCase()),
    );
  const qualifier = type === undefined ? '' : `, type=${type}`;
  if (!matches.length) {
    throw new Error(
      `No issue link found with inward=${inwardKey}, outward=${outwardKey}${qualifier}.`,
    );
  }
  if (matches.length > 1) {
    const candidates = matches
      .map((candidate) => formatDirectedIssueLink(inwardKey, candidate))
      .join('\n');
    throw new Error(
      `Multiple issue links match inward=${inwardKey}, outward=${outwardKey}${qualifier}; refusing to delete:\n${candidates}`,
    );
  }
  return matches[0];
}

export async function unlinkIssueLink(
  inwardKey: string,
  outwardKey: string,
  type?: string,
  requestFn: RequestFn = request,
): Promise<IssueLink> {
  const issue = await requestFn(
    'GET',
    `/issue/${inwardKey}?fields=issuelinks`,
  ) as IssueLinksResponse;
  const match = resolveIssueLink(
    issue.fields.issuelinks ?? [],
    inwardKey,
    outwardKey,
    type,
  );
  await requestFn('DELETE', `/issueLink/${match.link.id}`);
  return match.link;
}

export function registerLink(program: Command): void {
  program
    .command('link <key> [otherKey]')
    .description(
      'Create an issue link: `link A B [--type T]` (first key is the inward issue). ' +
      'Blocks is refused in the bare two-key form because it stores "A blocks ' +
      'B"; use `link A --blocks B` ("A blocks B") or `link A --blocked-by B` ' +
      '("A is blocked by B").',
    )
    .option(
      '--type <type>',
      'Link type name (Relates, Blocks, Duplicate, Cloners)',
    )
    .option('--blocks <key>', 'Create `link A --blocks B`: A blocks B')
    .option('--blocked-by <key>', 'Create `link A --blocked-by B`: A is blocked by B')
    .action(
      async (
        key: string,
        otherKey: string | undefined,
        opts: { type?: string; blocks?: string; blockedBy?: string },
      ) => {
        const fail = (msg: string): never => {
          console.error(msg);
          process.exit(1);
        };
        const explicit = opts.blocks !== undefined || opts.blockedBy !== undefined;
        if (opts.blocks !== undefined && opts.blockedBy !== undefined) {
          fail('Use only one of --blocks and --blocked-by.');
        }
        if (explicit && otherKey !== undefined) {
          fail('--blocks/--blocked-by take the other key as their value; drop the second positional key.');
        }
        if (explicit && opts.type !== undefined && opts.type.toLowerCase() !== 'blocks') {
          fail(`--blocks/--blocked-by create Blocks links; --type ${opts.type} conflicts.`);
        }
        if (!explicit && otherKey === undefined) {
          fail('Missing second key: `link A B` (Relates), `link A --blocks B` or `link A --blocked-by B`.');
        }
        const typeName = explicit ? 'Blocks' : (opts.type ?? 'Relates');
        // Validate the type up front so an unknown --type yields the list of
        // valid types instead of a raw 404 from the create call.
        const { issueLinkTypes } = await request<{
          issueLinkTypes: IssueLinkType[];
        }>('GET', '/issueLinkType');
        const match = findLinkType(issueLinkTypes, typeName);
        if (!match) {
          console.error(`Link type "${typeName}" not found. Available:`);
          for (const t of issueLinkTypes) console.error(`- ${t.name}`);
          process.exit(1);
        }
        let inwardKey: string;
        let outwardKey: string;
        if (opts.blocks !== undefined) {
          // "key blocks X": the blocker is the inward (source) issue.
          inwardKey = key;
          outwardKey = opts.blocks;
        } else if (opts.blockedBy !== undefined) {
          inwardKey = opts.blockedBy;
          outwardKey = key;
        } else {
          if (match.name.toLowerCase() === 'blocks') {
            fail(
              'The bare two-key form is ambiguous for Blocks (it stores "A blocks B"). ' +
              'Use `link A --blocks B` (A blocks B) or `link A --blocked-by B` (A is blocked by B).',
            );
          }
          inwardKey = key;
          outwardKey = otherKey as string;
        }
        const line = await createIssueLink(inwardKey, outwardKey, match);
        await verifyIssueLink(inwardKey, outwardKey, match);
        writeJiraBreadcrumb(key);
        console.log(line);
      },
    );

  program
    .command('links <key>')
    .description('List issue links with canonical inward/outward direction')
    .action(async (key: string) => {
      const issue = await request<IssueLinksResponse>(
        'GET',
        `/issue/${key}?fields=issuelinks`,
      );
      console.log(formatIssueLinks(key, issue.fields.issuelinks ?? []));
    });

  program
    .command('unlink <inwardKey> <outwardKey>')
    .description('Delete exactly one directed issue link')
    .option('--type <type>', 'Link type name used to disambiguate the pair')
    .action(async (
      inwardKey: string,
      outwardKey: string,
      opts: { type?: string },
    ) => {
      const deleted = await unlinkIssueLink(inwardKey, outwardKey, opts.type);
      writeJiraBreadcrumb(inwardKey);
      console.log(
        `Unlinked inward=${inwardKey} outward=${outwardKey} type=${deleted.type.name} id=${deleted.id}`,
      );
    });
}
