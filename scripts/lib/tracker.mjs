#!/usr/bin/env node
// tracker.mjs — JS mirror of the tracker seam's normalisation. One owner of the normalised item shape
// {id,title,status,type,fix_version,epic}: tracker-jira.sh and tracker-local.sh
// shell out to it, and board / where-are-we / cloud-route import it.
//
//   node tracker.mjs normalize-jira        Jira `get --json` on stdin -> item JSON
//   node tracker.mjs local-get <file>      one local store item file -> item JSON
//   node tracker.mjs field <name>          item JSON on stdin -> one field, bare
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export function normalizeJiraIssue(d) {
    const f = d.fields || {};
    const fv = Array.isArray(f.fixVersions) && f.fixVersions.length ? f.fixVersions[0].name : '';
    return {
        id: d.key || '',
        title: f.summary || '',
        status: (f.status && f.status.name) || '',
        type: (f.issuetype && f.issuetype.name) || '',
        fix_version: fv || '',
        epic: (f.parent && f.parent.key) || '',
    };
}

// Front matter is flat `key: value` lines between the first two `---` lines; the
// `links:` list under it is not part of the normalised shape.
export function parseLocalItem(text) {
    const lines = text.split('\n');
    const out = { id: '', title: '', status: '', type: '', fix_version: '', epic: '' };
    if (lines[0] !== '---') return out;
    for (let i = 1; i < lines.length && lines[i] !== '---'; i++) {
        const m = /^([a-z_]+):(?: (.*))?$/.exec(lines[i]);
        if (m && m[1] in out) {
            let v = m[2] === undefined ? '' : m[2];
            // the writer double-quotes titles; JSON.parse undoes \" and \\ alike
            if (/^".*"$/.test(v)) { try { v = JSON.parse(v); } catch { /* keep raw */ } }
            out[m[1]] = v;
        }
    }
    return out;
}

function main(argv) {
    const [cmd, arg] = argv;
    const stdin = () => fs.readFileSync(0, 'utf8');
    if (cmd === 'normalize-jira') {
        process.stdout.write(JSON.stringify(normalizeJiraIssue(JSON.parse(stdin()))) + '\n');
    } else if (cmd === 'local-get') {
        process.stdout.write(JSON.stringify(parseLocalItem(fs.readFileSync(arg, 'utf8'))) + '\n');
    } else if (cmd === 'field') {
        const v = JSON.parse(stdin())[arg];
        process.stdout.write(v === undefined || v === null ? '' : String(v));
    } else {
        process.stderr.write('usage: tracker.mjs normalize-jira | local-get <file> | field <name>\n');
        process.exit(2);
    }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
