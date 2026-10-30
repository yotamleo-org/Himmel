#!/usr/bin/env bash
# Queued hooks carry POSIX runtime configuration, not retired host roots.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
node --input-type=module - "$HERE/stop-queue.mjs" <<'NODE'
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
const { jobEnv, snapshotEnv } = await import(pathToFileURL(process.argv[2]));

const retired = {
  SYSTEMROOT: 'retired-root', SYSTEMDRIVE: 'retired-drive', WINDIR: 'retired-root',
  COMSPEC: 'retired-shell', PATHEXT: 'retired-extensions', PROGRAMDATA: 'retired-data',
  PROGRAMFILES: 'retired-programs', 'PROGRAMFILES(X86)': 'retired-programs',
  PROGRAMW6432: 'retired-programs', HOMEDRIVE: 'retired-drive', HOMEPATH: 'retired-home',
  APPDATA: 'retired-data', LOCALAPPDATA: 'retired-data', USERNAME: 'retired-user',
  NUMBER_OF_PROCESSORS: '8', PROCESSOR_ARCHITECTURE: 'retired-arch',
  OS: 'Windows_NT', EXEPATH: 'retired-git', MSYS: 'retired-mode', MSYSTEM: 'MINGW64',
  MSYSTEM_PREFIX: 'retired-prefix', MSYSTEM_CHOST: 'retired-host',
  MSYS2_ARG_CONV_EXCL: '*', MSYS_NO_PATHCONV: '1',
};
const posix = {
  PATH: '/usr/bin:/bin', HOME: '/home/fixture', SHELL: '/bin/bash',
  LANG: 'en_US.UTF-8', LC_ALL: 'C', TZ: 'UTC', XDG_CONFIG_HOME: '/home/fixture/.config',
  NVM_DIR: '/home/fixture/.nvm', VOLTA_HOME: '/home/fixture/.volta',
};

test('new queue snapshots omit retired host roots and keep POSIX configuration', () => {
  assert.deepEqual(snapshotEnv({ ...retired, ...posix }), posix);
});

test('legacy queued jobs inherit POSIX configuration without retired host roots', () => {
  assert.deepEqual(jobEnv({}, { ...retired, ...posix }), { ...posix, HIMMEL_DETACH_INLINE: '1' });
});
NODE
