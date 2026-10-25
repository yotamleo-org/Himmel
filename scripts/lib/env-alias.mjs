// scripts/lib/env-alias.mjs -- JS twin of the direction-aware half of
// scripts/lib/env-alias.sh. Same rows, same answers: both are pinned to
// fixtures/env-alias-rows.tsv by env-alias.test.mjs and test-env-alias.sh.
//
//   envAliasRestrict(NEW, OLD, env)  true when either name is truthy
//                                    (markers that switch a guard ON)
//   envAliasPermit(NEW, OLD, env)    true only when at least one name is truthy
//                                    and no set name is falsy (*_OK overrides,
//                                    widening switches)
//
//   legacyNamesOn(env)               false when HIMMEL_LEGACY_NAMES is falsy
//
// "Set" is non-empty; "truthy" is set and not 0, false, no or off (any case).
// Legacy names off (scripts/lib/legacy-names.sh): restrict still reads both
// names; permit is granted by NEW only while a falsy OLD still vetoes.
// A name outside [A-Z_][A-Z0-9_]* throws an Error with code 2, the shell's rc 2.
// env defaults to process.env.
//
// CLI: node env-alias.mjs restrict|permit NEW OLD -> exit 0 true, 1 false,
// 2 invalid name, usage or any other error (message on stderr), so a caller that
// fails closed never reads an error as a plain false.
import { isMain } from './is-main.mjs';

const NAME = /^[A-Z_][A-Z0-9_]*$/;
const FALSY = /^(0|false|no|off)$/i;

function check(newName, oldName) {
  for (const n of [newName, oldName]) {
    if (typeof n !== 'string' || !NAME.test(n)) {
      const err = new Error(`env-alias: invalid name ${JSON.stringify(n)}`);
      err.code = 2;
      throw err;
    }
  }
}

function setValues(newName, oldName, env) {
  check(newName, oldName);
  return [env[newName], env[oldName]].filter((v) => typeof v === 'string' && v !== '');
}

export function legacyNamesOn(env = process.env) {
  return !FALSY.test(env.HIMMEL_LEGACY_NAMES ?? '');
}

export function envAliasRestrict(newName, oldName, env = process.env) {
  return setValues(newName, oldName, env).some((v) => !FALSY.test(v));
}

export function envAliasPermit(newName, oldName, env = process.env) {
  const set = setValues(newName, oldName, env);
  if (set.some((v) => FALSY.test(v))) return false;
  if (!legacyNamesOn(env)) return typeof env[newName] === 'string' && env[newName] !== '';
  return set.length > 0;
}

function main(argv) {
  const [fn, newName, oldName] = argv;
  const fns = new Map([['restrict', envAliasRestrict], ['permit', envAliasPermit]]);
  if (!fns.has(fn) || argv.length !== 3) {
    process.stderr.write('usage: env-alias.mjs restrict|permit NEW OLD\n');
    return 2;
  }
  try {
    return fns.get(fn)(newName, oldName) ? 0 : 1;
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    return 2;
  }
}

if (isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2));
