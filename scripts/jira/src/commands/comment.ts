import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';

function collect(value: string, prev: string[]): string[] {
  return [...prev, value];
}

export function registerComment(program: Command): void {
  program
    .command('comment <key> [text]')
    .description('Add a comment to a Jira issue, or replace one with --edit (text supports markdown)')
    .option('--edit <commentId>', 'Replace the body of an existing comment by id instead of adding a new one')
    .option('--adf-file <path>', 'Path to pre-built ADF JSON document (overrides <text>)')
    .option(
      '--comment-file <path>',
      'Read the markdown comment body from a file (overrides <text>; keeps the ' +
        'shell command single-line for multi-line bodies)',
    )
    .option('--print-id', 'Print only the comment id on stdout (the success line moves to stderr)')
    .option('--attach <path>', 'File to attach to the parent issue (repeatable)', collect, [])
    .action(
      async (
        key: string,
        text: string | undefined,
        options: { adfFile?: string; commentFile?: string; edit?: string; printId?: boolean; attach: string[] },
      ) => {
        if (options.edit === '') {
          console.error('jira: --edit requires a non-empty comment id');
          process.exit(1);
        }
        let body: unknown;
        if (options.adfFile) {
          try {
            body = JSON.parse(readFileSync(options.adfFile, 'utf8'));
          } catch (e) {
            console.error(`jira: cannot read --adf-file "${options.adfFile}": ${(e as Error).message}`);
            process.exit(1);
          }
        } else {
          const markdown = options.commentFile
            ? readBodyFile(options.commentFile, '--comment-file')
            : text;
          if (markdown === undefined) {
            console.error('jira: comment requires <text> or --comment-file or --adf-file');
            process.exit(1);
          }
          body = markdownToAdf(markdown);
        }
        let id: string | undefined;
        if (options.edit) {
          await request('PUT', `/issue/${key}/comment/${encodeURIComponent(options.edit)}`, { body });
          id = options.edit;
        } else {
          const created = await request<{ id?: string }>('POST', `/issue/${key}/comment`, { body });
          id = created?.id;
        }
        // Breadcrumb BEFORE attachments: the comment mutation has landed even
        // if a later attachment upload fails and we exit 1.
        writeJiraBreadcrumb(key);

        // Print the success indicator to STDOUT immediately, BEFORE
        // attempting attachments. Scripted callers piping stdout still
        // see the comment landed even if a subsequent attachment fails
        // and we exit 1. Attachment-failure message goes to stderr.
        const done = options.edit ? `Comment ${options.edit} edited on ${key}` : `Comment added to ${key}`;
        if (options.printId) {
          console.error(done);
          if (id) console.log(id);
          else console.error('jira: the response carried no comment id');
        } else {
          console.log(done);
        }

        const attachments = options.attach ?? [];
        if (attachments.length === 0) return;
        try {
          const n = await uploadAll(key, attachments);
          console.error(`  attachments: ${n}`);
        } catch (e) {
          console.error(`${done} but attachment failed: ${(e as Error).message}`);
          process.exit(1);
        }
      },
    );
}
