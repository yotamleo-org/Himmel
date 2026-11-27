#!/usr/bin/env node
'use strict';

const fs = require('fs');

/**
 * The dirs a list may sit in, in order; none without HOME. The bash resolver
 * prints one dir per line, so a dir holding a newline is refused in every form.
 */
function phiDirs(env = process.env) {
  const home = env.HOME;
  const override = env.CLAUDE_GLM_CONFIG_DIR;
  if (!home || `${home}${override || ''}`.includes('\n')) return [];
  const old = `${home}/.config/claude-glm`;
  const dirs = [`${home}/.config/himmel/phi`];
  if (override) dirs.push(override);
  if (override !== old) dirs.push(old);
  return dirs;
}

function canTraverse(p) {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * fs.existsSync is not used: it is false on any error, so a locked dir would
 * read as "no list here".
 */
function phiDirProvable(dir) {
  let d = dir;
  for (;;) {
    try {
      fs.lstatSync(d);
      break;
    } catch (e) {
      if (e.code !== 'ENOENT') break;
    }
    if (d === '/') return true;
    if (d === '.') return canTraverse('.');
    const cut = d.lastIndexOf('/');
    const up = cut < 0 ? '.' : d.slice(0, cut) || '/';
    if (up === d) return true;
    d = up;
  }
  let st;
  try {
    st = fs.statSync(d);
  } catch {
    return false;
  }
  if (!st.isDirectory()) return false;
  return canTraverse(d);
}

function presentUnlessEnoent(file) {
  try {
    fs.lstatSync(file);
    return true;
  } catch (e) {
    return e.code !== 'ENOENT';
  }
}

function phiListPaths(name, env = process.env) {
  const dirs = phiDirs(env);
  if (dirs.length === 0) return { rc: 2, paths: [], unprovable: '' };
  const paths = [];
  for (const d of dirs) {
    if (!phiDirProvable(d)) return { rc: 2, paths, unprovable: d };
    const file = `${d}/${name}`;
    if (presentUnlessEnoent(file)) paths.push(file);
  }
  return { rc: paths.length ? 0 : 3, paths, unprovable: '' };
}

module.exports = { phiDirs, phiListPaths };

if (require.main === module) {
  const { rc, paths, unprovable } = phiListPaths(process.argv[2]);
  for (const p of paths) process.stdout.write(`${p}\n`);
  if (unprovable) process.stderr.write(`unprovable: ${unprovable}\n`);
  process.exitCode = rc;
}
